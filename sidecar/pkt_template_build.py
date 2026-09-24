"""Build a machine-local .pkt template library from real Packet Tracer saves.

A generator needs three things it cannot invent:

* the **global skeleton** Packet Tracer writes around every topology
  (``VERSION``, ``PIXMAPBANK``, ``OPTIONS``, ``SCENARIOSET``,
  ``PHYSICALWORKSPACE``, script modules, ...),
* one known-good ``<DEVICE>`` block per model with its module layout,
* one known-good ``<LINK>`` block per cable kind.

This module extracts all three from ``.pkt`` files the user already has, so
nothing Cisco-authored needs to be committed to the repository.  The library
lands next to the sidecar in ``pkt_templates/`` (gitignored, machine-local).

Port names are worth a note: the XML stores a ``<PORT>`` element per
interface but *not* its name - Packet Tracer derives names such as
``FastEthernet0/2`` or ``Serial0/2/1`` from the module layout.  Instead of
hard-coding that layout for every model, the extractor reads the interface
names out of the device's own PT-authored running config, in order, and pairs
them with the ``<PORT>`` elements by interface family.  When a model has no
config to read (PCs, laptops, PDUs) it falls back to the host-module name the
links in the file prove (``FastEthernet0``) and says so in the manifest.

Everything here is offline: no Packet Tracer, no network, no RPA stack.
"""

from __future__ import annotations

import hashlib
import glob
import json
import os
import sys
import re
import time
import xml.etree.ElementTree as ET

import pkt_codec

def user_data_dir() -> str:
    """A per-user folder the app may write to without admin rights."""
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_DATA_HOME")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "NetBuilderAI")


TEMPLATE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "pkt_templates")
SKELETON_FILE = "skeleton.xml"
MANIFEST_FILE = "manifest.json"

# Real Packet Tracer saves shipped with the app, so a machine that has never
# seen a .pkt can still build the template library by itself. The generation
# is impossible without one, and asking the user to supply their own file
# first is exactly the manual step this is meant to remove.
SEED_DIR_NAME = "pkt_seed"


def candidate_dirs() -> list:
    """Everywhere the library may live, most specific first.

    The dev checkout keeps it beside the source. A frozen build unpacks its
    bundled copy under sys._MEIPASS. A machine that has neither can build one
    in the per-user folder. Whichever has a manifest wins.
    """
    out = [TEMPLATE_DIR]
    bundled = getattr(sys, "_MEIPASS", "")
    if bundled:
        out.append(os.path.join(bundled, TEMPLATE_DIR_NAME))
    here = os.path.dirname(os.path.abspath(__file__))
    out.append(os.path.join(here, TEMPLATE_DIR_NAME))
    out.append(os.path.join(user_data_dir(), TEMPLATE_DIR_NAME))
    seen, ordered = set(), []
    for path in out:
        key = os.path.normcase(os.path.abspath(path))
        if key not in seen:
            seen.add(key)
            ordered.append(path)
    return ordered


TEMPLATE_DIR_NAME = "pkt_templates"


def find_library_dir() -> str:
    """The folder holding a usable library, or where one should be built."""
    for path in candidate_dirs():
        if os.path.isfile(os.path.join(path, MANIFEST_FILE)):
            return path
    # Nothing usable: prefer a location this process can actually write to.
    for path in candidate_dirs():
        parent = os.path.dirname(path)
        if os.path.isdir(parent) and os.access(parent, os.W_OK):
            return path
    return TEMPLATE_DIR


def seed_sources() -> list:
    """Bundled sample saves, used only when no library exists yet."""
    roots = []
    bundled = getattr(sys, "_MEIPASS", "")
    if bundled:
        roots.append(os.path.join(bundled, SEED_DIR_NAME))
    here = os.path.dirname(os.path.abspath(__file__))
    roots.append(os.path.join(here, SEED_DIR_NAME))
    roots.append(os.path.join(user_data_dir(), SEED_DIR_NAME))
    found = []
    for root in roots:
        if os.path.isdir(root):
            found.extend(sorted(
                os.path.join(root, name) for name in os.listdir(root)
                if name.lower().endswith(".pkt")))
    return found


def library_ready() -> bool:
    return os.path.isfile(os.path.join(find_library_dir(), MANIFEST_FILE))


def ensure_library() -> dict:
    """Build the template library if this machine has none.

    Returns a small report either way. Never raises: a machine with no seeds
    should still get the original, explanatory error from the caller.
    """
    target = find_library_dir()
    if os.path.isfile(os.path.join(target, MANIFEST_FILE)):
        return {"built": False, "directory": target, "reason": "already there"}
    seeds = seed_sources()
    if not seeds:
        return {"built": False, "directory": target,
                "reason": "no template library and no sample saves to learn "
                          "from"}
    try:
        result = extract_templates(seeds, target)
    except Exception as exc:  # noqa: BLE001 - reported, never fatal here
        return {"built": False, "directory": target,
                "reason": f"could not build the library: {exc}"}
    return {"built": True, "directory": target,
            "reason": f"built from {len(seeds)} bundled save(s)",
            "result": result}

DEVICE_RE = re.compile(rb"<DEVICE>.*?</DEVICE>", re.S)
LINK_RE = re.compile(rb"<LINK>.*?</LINK>", re.S)
PORT_RE = re.compile(rb"<PORT>.*?</PORT>", re.S)
# Exactly the PORT element - never PORT_GATEWAY / PORT_DHCP_ENABLE / ...
PORT_TAG_RE = re.compile(rb"</?PORT(?=[\s/>])[^>]*>")
LINE_RE = re.compile(rb"<LINE>(.*?)</LINE>", re.S)


def iter_port_spans(block: bytes) -> list[tuple[int, int]]:
    """Byte spans of the block's own ``<PORT>`` elements, in document order.

    Depth-aware so a port nested inside another port's module tree can never
    be mistaken for a sibling.  The extractor and the builder both use this,
    which is what keeps a port index meaning the same thing in the manifest
    and in the generated file.
    """
    spans: list[tuple[int, int]] = []
    depth = 0
    start = None
    for match in PORT_TAG_RE.finditer(block):
        tag = match.group(0)
        if tag.startswith(b"</"):
            depth -= 1
            if depth <= 0 and start is not None:
                spans.append((start, match.end()))
                start = None
                depth = max(depth, 0)
            continue
        if tag.endswith(b"/>") or tag == b"<PORT />":  # self-closing
            if depth == 0:
                spans.append((match.start(), match.end()))
            continue
        if depth == 0:
            start = match.start()
        depth += 1
    if start is not None:
        spans.append((start, len(block)))
    return spans

# Interface types we can name, in the order the running config lists them.
PORT_FAMILIES = (
    ("fastethernet", "eCopperFastEthernet", "FastEthernet"),
    ("gigabitethernet", "eCopperGigabitEthernet", "GigabitEthernet"),
    ("ethernet", "eCopperEthernet", "Ethernet"),
    ("serial", "eSmartSerial", "Serial"),
    ("serial", "eSerial", "Serial"),
    ("fiber", "eFiber", "Fiber"),
    ("wireless", "eWireless", "Wireless"),
)
_TYPE_TO_FAMILY = {}
for _family, _type, _prefix in PORT_FAMILIES:
    _TYPE_TO_FAMILY.setdefault(_type, _family)

# Kinds whose ports never appear in a running config and are named by the
# host module instead.  `FastEthernet0` is what the links in a real save use.
HOST_FALLBACK_NAMES = {
    "pc": "FastEthernet0",
    "laptop": "FastEthernet0",
    "server": "FastEthernet0",
    "printer": "FastEthernet0",
    "tablet": "Wireless0",
    "smartphone": "Wireless0",
}


class TemplateError(RuntimeError):
    """The template library is missing or could not be built."""


def _safe_key(text: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._+-]+", "-", str(text).strip())
    return slug.strip("-") or "template"


def _one(pattern: bytes, block: bytes, default: str = "") -> str:
    match = re.search(pattern, block)
    if not match:
        return default
    return match.group(1).decode("utf-8", "replace")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# Reading one device block
# ---------------------------------------------------------------------------

def _device_model(block: bytes) -> str:
    return _one(rb"<TYPE customModel=\"[^\"]*\" model=\"([^\"]*)\"", block)


def _device_kind(block: bytes) -> str:
    return _one(
        rb"<TYPE customModel=\"[^\"]*\" model=\"[^\"]*\">([^<]*)<", block)


def _device_name(block: bytes) -> str:
    return _one(rb"<NAME translate=\"true\">([^<]*)</NAME>", block)


def has_physical_data(block: bytes) -> bool:
    """Whether this saved device block can be given a Physical Workspace leaf.

    Packet Tracer writes some models without any physical-workspace data at
    all (of the 1841 blocks in the saves on this machine, 115 have none), and
    such a block can only ever be a Logical-workspace device.
    """
    return b"<PHYSICAL_CPUR" in block


def _device_modules(block: bytes) -> list[str]:
    """Module models fitted to this device (HWIC-2T, PT-HOST-NM-1CFE, ...)."""
    found = []
    for slot in re.findall(rb"<SLOT>.*?</SLOT>", block, re.S):
        for model in re.findall(rb"<MODEL>\s*([^<\s]+)\s*</MODEL>", slot):
            text = model.decode("utf-8", "replace")
            if text and text not in found:
                found.append(text)
    return found


def _device_port_types(block: bytes) -> list[str]:
    types = []
    for start, end in iter_port_spans(block):
        types.append(_one(rb"<TYPE>([^<]*)</TYPE>", block[start:end], ""))
    return types


def _interface_names(block: bytes) -> list[str]:
    """Interface names from the device's own running config, in order."""
    config = re.search(rb"<RUNNINGCONFIG>(.*?)</RUNNINGCONFIG>", block, re.S)
    if not config:
        return []
    names = []
    for line in LINE_RE.findall(config.group(1)):
        text = line.decode("utf-8", "replace").strip()
        match = re.match(r"^interface\s+(\S+)$", text, re.I)
        if match:
            names.append(match.group(1))
    return names


def _family_of_type(port_type: str) -> str:
    return _TYPE_TO_FAMILY.get(port_type, "")


def _family_of_name(name: str) -> str:
    lowered = name.lower()
    if lowered.startswith("fastethernet"):
        return "fastethernet"
    if lowered.startswith("gigabitethernet"):
        return "gigabitethernet"
    if lowered.startswith("ethernet"):
        return "ethernet"
    if lowered.startswith("serial"):
        return "serial"
    if lowered.startswith("fiber"):
        return "fiber"
    if lowered.startswith("wireless"):
        return "wireless"
    return ""


def port_inventory(port_types: list[str], names: list[str],
                   kind: str) -> tuple[list[dict], list[str]]:
    """Pair ordered PORT element types with PT-authored interface names.

    Returns ``(ports, warnings)`` where each port carries its family, type and
    the name Packet Tracer uses for it (possibly empty when it cannot be
    known from the source file).
    """
    warnings = []
    by_family: dict[str, list[str]] = {}
    for name in names:
        family = _family_of_name(name)
        if family:
            by_family.setdefault(family, []).append(name)

    counters: dict[str, int] = {}
    ports = []
    for index, port_type in enumerate(port_types):
        family = _family_of_type(port_type)
        entry = {"index": index, "type": port_type, "family": family,
                 "name": ""}
        if family:
            seen = counters.get(family, 0)
            candidates = by_family.get(family, [])
            if seen < len(candidates):
                entry["name"] = candidates[seen]
            counters[family] = seen + 1
        ports.append(entry)

    unnamed = [p for p in ports if not p["name"]]
    if unnamed:
        fallback = HOST_FALLBACK_NAMES.get(kind.strip().lower(), "")
        if fallback and not any(p["family"] == "ethernet" for p in ports):
            for entry in ports:
                if entry["family"] in ("fastethernet", "ethernet"):
                    entry["name"] = fallback
                    break
        still = [p for p in ports if not p["name"] and p["family"]]
        if still:
            warnings.append(
                f"{kind or 'device'}: {len(still)} port(s) have no name in "
                "the source file; links to them will be refused")
    return ports, warnings


# ---------------------------------------------------------------------------
# Cleaning blocks for reuse
# ---------------------------------------------------------------------------

def clean_device(block: bytes, *, name: str = "Device") -> bytes:
    """A device block with identity, position, configs and IPs neutralised."""
    out = block
    out = re.sub(rb"<SAVE_REF_ID>[^<]*</SAVE_REF_ID>",
                 b"<SAVE_REF_ID>save-ref-id:0</SAVE_REF_ID>", out)
    out = _replace_first(out, rb"<NAME translate=\"true\">[^<]*</NAME>",
                         b"<NAME translate=\"true\">" + name.encode() +
                         b"</NAME>")
    # The CLI hostname is identity too: a generated device must never inherit
    # the source file's hostname (the builder writes a fresh one anyway).
    out = _replace_first(out, rb"<SYS_NAME>[^<]*</SYS_NAME>",
                         b"<SYS_NAME></SYS_NAME>")
    out = re.sub(rb"<(MACADDRESS|BIA)>[^<]*</\1>",
                 rb"<\1>0000.0000.0000</\1>", out)
    out = re.sub(rb"<RUNNINGCONFIG>.*?</RUNNINGCONFIG>",
                 b"<RUNNINGCONFIG/>", out, flags=re.S)
    # The startup config is the same trap: it carries the source device's
    # hostname, banners and password hashes, and a generated device that has
    # never run `write memory` must not answer `show startup-config` with
    # them.  (It is also where the one unparseable control character in a
    # harvested block came from.)
    out = re.sub(rb"<STARTUPCONFIG>.*?</STARTUPCONFIG>",
                 b"<STARTUPCONFIG/>", out, flags=re.S)
    out = re.sub(rb"<STARTUPCONFIG(?:\s[^>]*)?/>", b"<STARTUPCONFIG/>", out)
    out = re.sub(rb"<(IP|SUBNET|PORT_GATEWAY|PORT_DNS)>[^<]*</\1>",
                 rb"<\1/>", out)
    out = re.sub(rb"<PORT_DHCP_ENABLE>[^<]*</PORT_DHCP_ENABLE>",
                 b"<PORT_DHCP_ENABLE>false</PORT_DHCP_ENABLE>", out)
    out = re.sub(rb"<(MEM_ADDR|DEV_ADDR)>[^<]*</\1>",
                 rb"<\1>0</\1>", out)
    logical = re.search(rb"<LOGICAL>.*?</LOGICAL>", out, re.S)
    if logical:
        block_text = logical.group(0)
        fixed = re.sub(rb"<X>[^<]*</X>", b"<X>0</X>", block_text)
        fixed = re.sub(rb"<Y>[^<]*</Y>", b"<Y>0</Y>", fixed)
        out = out[:logical.start()] + fixed + out[logical.end():]
    return out


def clean_link(block: bytes) -> bytes:
    """A link block with stale runtime pointers removed."""
    return re.sub(rb"<([A-Z_]*MEM_ADDR)>[^<]*</\1>", rb"<\1>0</\1>", block)


def _replace_first(source: bytes, pattern: bytes, replacement: bytes) -> bytes:
    match = re.search(pattern, source)
    if not match:
        return source
    return source[:match.start()] + replacement + source[match.end():]


def skeleton_from(xml: bytes) -> bytes:
    """The source document with devices, links and command logs emptied."""
    out = re.sub(rb"<DEVICES>.*?</DEVICES>", b"<DEVICES>\n  </DEVICES>",
                 xml, flags=re.S)
    out = re.sub(rb"<LINKS>.*?</LINKS>", b"<LINKS>\n  </LINKS>", out,
                 flags=re.S)
    out = re.sub(rb"<COMMAND_LOGS>.*?</COMMAND_LOGS>",
                 b"<COMMAND_LOGS>\n </COMMAND_LOGS>", out, flags=re.S)
    try:
        ET.fromstring(out)
    except ET.ParseError as exc:
        raise TemplateError(f"emptied skeleton is not valid XML: {exc}")
    return out


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_from_xml(xml: bytes, source: str, library: dict) -> dict:
    """Merge one decrypted save into the library being built."""
    summary = pkt_codec.pkt_xml_summary(xml)
    library.setdefault("sources", []).append({
        "path": source,
        "sha256": _sha256(xml),
        "version": summary.get("version", ""),
        "devices": summary.get("deviceCount", 0),
        "links": summary.get("linkCount", 0),
    })
    if not library.get("version"):
        library["version"] = summary.get("version", "")

    if not library.get("skeleton"):
        library["skeleton"] = skeleton_from(xml).decode("utf-8", "replace")

    for block in DEVICE_RE.findall(xml):
        model = _device_model(block)
        if not model:
            continue
        modules = _device_modules(block)
        key = _safe_key(model + ("+" + "+".join(modules) if modules
                                 else ""))
        existing = next((entry for entry in library["devices"]
                         if entry["key"] == key), None)
        if existing is not None:
            # One model is saved in many labs, and not every save gives it
            # physical-workspace data.  Only a block that has it can be given
            # a physical leaf, so it wins over an earlier block without it -
            # otherwise the model would be logical-workspace-only for as long
            # as the library lives.
            if (has_physical_data(block)
                    and not has_physical_data(
                        library["_blocks"][existing["file"]])):
                library["_blocks"][existing["file"]] = clean_device(block)
                existing["hasPhysical"] = True
                existing["source"] = source
                existing["sourceName"] = _device_name(block)
            continue
        kind = _device_kind(block)
        ports, warnings = port_inventory(
            _device_port_types(block), _interface_names(block), kind)
        entry = {
            "key": key,
            "model": model,
            "kind": kind,
            "modules": modules,
            "file": f"devices/{key}.xml",
            "ports": ports,
            "source": source,
            "sourceName": _device_name(block),
            "hasConfig": bool(_interface_names(block)),
            "hasPhysical": has_physical_data(block),
            "warnings": warnings,
        }
        library["devices"].append(entry)
        library["_blocks"][entry["file"]] = clean_device(block)
        library["warnings"].extend(warnings)

    for block in LINK_RE.findall(xml):
        # A LINK block carries the medium first (eCopper/eSerial) and the
        # cable kind last (eStraightThrough/eCrossOver/eSerial).
        type_tags = re.findall(rb"<TYPE>([^<]*)</TYPE>", block)
        link_type = type_tags[0].decode("utf-8", "replace") if type_tags \
            else ""
        cable = type_tags[-1].decode("utf-8", "replace") \
            if len(type_tags) > 1 else ""
        key = _safe_key(f"{link_type}-{cable}")
        if any(entry["key"] == key for entry in library["links"]):
            continue
        entry = {
            "key": key,
            "type": link_type,
            "cable": cable,
            "file": f"links/{key}.xml",
        }
        library["links"].append(entry)
        library["_blocks"][entry["file"]] = clean_link(block)
    return library


def default_sample_roots() -> list:
    """Where Packet Tracer keeps the save files it ships with.

    Every install carries a `saves` tree with hundreds of real .pkt files
    (routers with serial modules, ASA firewalls, access points, wireless LAN
    controllers, IoT devices...), which is the cheapest honest way to make a
    plan's requested model exist as a template.  Nothing here is required:
    the caller decides which roots to read.
    """
    roots = []
    for pattern in (
        r"C:\\Program Files\\Cisco Packet Tracer*\\saves",
        r"C:\\Program Files (x86)\\Cisco Packet Tracer*\\saves",
        "/Applications/Cisco Packet Tracer.app/Contents/saves",
        os.path.expanduser("~/Cisco Packet Tracer/saves"),
    ):
        for match in glob.glob(pattern):
            if os.path.isdir(match):
                roots.append(match)
    return roots


def discover_pkt_files(roots, *, limit: int = 0) -> list:
    """Every .pkt under the given files and directories, first seen first."""
    found, seen = [], set()
    for raw in roots or []:
        path = os.path.abspath(os.path.expanduser(str(raw or "").strip()))
        if not path:
            continue
        if os.path.isfile(path) and path.lower().endswith(".pkt"):
            candidates = [path]
        elif os.path.isdir(path):
            candidates = []
            for directory, dirnames, filenames in os.walk(path):
                dirnames.sort()
                for name in sorted(filenames):
                    if name.lower().endswith(".pkt"):
                        candidates.append(os.path.join(directory, name))
        else:
            continue
        for candidate in candidates:
            key = os.path.normcase(candidate)
            if key in seen:
                continue
            seen.add(key)
            found.append(candidate)
            if limit and len(found) >= limit:
                return found
    return found


def harvest_templates(roots=None, out_dir: str = "", *, log=None,
                      include_existing: bool = True) -> dict:
    """Extend the template library with every model found in local .pkt files.

    The existing sources are read first, so a model already in the library
    keeps its winning block (extraction takes the first file that has it) and
    the harvest only ever *adds* models.
    """
    say = log or (lambda *_: None)
    directory = os.path.abspath(out_dir or TEMPLATE_DIR)
    existing = []
    if include_existing:
        manifest_path = os.path.join(directory, MANIFEST_FILE)
        try:
            with open(manifest_path, encoding="utf-8") as stream:
                existing = [entry.get("path", "")
                            for entry in (json.load(stream).get("sources")
                                          or [])]
        except Exception:  # noqa: BLE001 - a missing library is not an error
            existing = []
    requested = list(roots or [])
    if not requested:
        requested = default_sample_roots()
    files = discover_pkt_files([*existing, *requested])
    if not files:
        return {"ok": False, "added": [], "scanned": 0,
                "error": "no .pkt files found to harvest; point this at a "
                         "folder or save a topology from Packet Tracer first",
                "roots": requested}
    before = set()
    manifest_path = os.path.join(directory, MANIFEST_FILE)
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path, encoding="utf-8") as stream:
                before = {entry.get("key") for entry in
                          json.load(stream).get("devices", [])}
        except Exception:  # noqa: BLE001
            before = set()
    say(f"harvest: reading {len(files)} .pkt file(s)")
    manifest = extract_templates(files, directory, log=say)
    after = {entry.get("key") for entry in manifest.get("devices", [])}
    added = sorted(after - before)
    say(f"harvest: {len(added)} new model(s): {', '.join(added) or 'none'}")
    return {
        "ok": True,
        "scanned": len(files),
        "roots": requested,
        "added": added,
        "addedCount": len(added),
        "devices": [{k: entry.get(k) for k in
                     ("key", "model", "kind", "modules")}
                    for entry in manifest.get("devices", [])],
        "deviceCount": len(manifest.get("devices", [])),
        "version": manifest.get("version", ""),
        "directory": directory,
        "warnings": [w for w in manifest.get("warnings", [])
                     if "skipped" in str(w)][:20],
    }


def extract_templates(paths, out_dir: str = "", *, log=None) -> dict:
    """Read .pkt files and write (or refresh) the template library."""
    say = log or (lambda *_: None)
    directory = os.path.abspath(out_dir or TEMPLATE_DIR)
    library = {"devices": [], "links": [], "warnings": [], "_blocks": {},
               "sources": [], "version": ""}
    used = []
    for raw in paths:
        path = os.path.abspath(os.path.expanduser(str(raw or "").strip()))
        if not path or not os.path.isfile(path):
            library["warnings"].append(f"skipped missing file: {raw}")
            continue
        try:
            with open(path, "rb") as stream:
                xml = pkt_codec.decrypt_pkt(stream.read())
        except Exception as exc:  # noqa: BLE001 - reported per file
            library["warnings"].append(f"skipped {path}: {exc}")
            continue
        extract_from_xml(xml, path, library)
        used.append(path)
        say(f"templates: read {os.path.basename(path)} "
            f"({len(library['devices'])} device models so far)")
    if not used:
        raise TemplateError(
            "no readable .pkt files were given; nothing to extract")
    if not library.get("skeleton"):
        raise TemplateError("no file produced a usable skeleton")

    blocks = library.pop("_blocks")
    os.makedirs(directory, exist_ok=True)
    os.makedirs(os.path.join(directory, "devices"), exist_ok=True)
    os.makedirs(os.path.join(directory, "links"), exist_ok=True)
    with open(os.path.join(directory, SKELETON_FILE), "wb") as stream:
        stream.write(library["skeleton"].encode("utf-8"))
    for relative, block in blocks.items():
        # One choke point for what lands on disk: a control character Packet
        # Tracer tolerates inside its own save ( in a banner) is not
        # valid XML, and would make the block unusable to everything that
        # reads the library back.
        with open(os.path.join(directory, relative), "wb") as stream:
            stream.write(pkt_codec.xml_safe(block))
    manifest = {
        "schema": 1,
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "version": library["version"],
        "skeleton": SKELETON_FILE,
        "devices": library["devices"],
        "links": library["links"],
        "sources": library["sources"],
        "warnings": library["warnings"],
    }
    with open(os.path.join(directory, MANIFEST_FILE), "w",
              encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
    say(f"templates: wrote {len(manifest['devices'])} device models and "
        f"{len(manifest['links'])} link kinds to {directory}")
    return manifest


def library_status(directory: str = "") -> dict:
    """What the current library offers, for the app to show before a build."""
    path = os.path.join(os.path.abspath(directory or TEMPLATE_DIR),
                        MANIFEST_FILE)
    if not os.path.isfile(path):
        return {"ok": True, "ready": False, "directory": os.path.dirname(path),
                "devices": [], "links": [], "version": "",
                "message": "no template library yet - build it from your own "
                           ".pkt files first"}
    try:
        with open(path, encoding="utf-8") as stream:
            manifest = json.load(stream)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "ready": False,
                "directory": os.path.dirname(path),
                "error": f"template manifest unreadable: {exc}"}
    devices = manifest.get("devices", [])
    coverage = {}
    for entry in devices:
        coverage.setdefault(entry.get("kind", "unknown"), []).append(
            entry.get("key", ""))
    return {
        "ok": True,
        "ready": bool(devices) and bool(manifest.get("skeleton")),
        "directory": os.path.dirname(path),
        "version": manifest.get("version", ""),
        "generated": manifest.get("generated", ""),
        "skeleton": manifest.get("skeleton", ""),
        "devices": [{k: entry.get(k) for k in
                     ("key", "model", "kind", "modules", "hasConfig",
                      "hasPhysical")}
                    for entry in devices],
        "logicalOnly": sorted(entry.get("key", "") for entry in devices
                              if entry.get("hasPhysical") is False),
        "links": manifest.get("links", []),
        "coverage": coverage,
        "sources": manifest.get("sources", []),
        "warnings": manifest.get("warnings", []),
    }


if __name__ == "__main__":  # pragma: no cover - manual tool
    import sys
    args = sys.argv[1:]
    if not args:
        print("usage: python pkt_template_build.py <file.pkt> [file2.pkt ...]")
        raise SystemExit(2)
    print(json.dumps(extract_templates(args, log=print), indent=2))
