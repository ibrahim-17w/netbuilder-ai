"""Offline .pkt generator: turn a NetBuilder plan into a Packet Tracer save.

The plan is exactly what the app already sends to the Packet Tracer executor
(``PacketTracerAdapter.autopilotPlan``): ``create_nodes``, ``create_links``,
``paste_cli``, ``config_pcs`` and ``config_servers``.  This module turns it
into the XML document Packet Tracer stores, using the machine-local template
library extracted by :mod:`pkt_template_build`, and then encodes it with
:mod:`pkt_codec`.  No Packet Tracer, no screen, no clicks.

What ends up inside the generated file:

* one ``<DEVICE>`` per planned node, cloned from the matching model template
  with a fresh id, name, MACs, canvas position and (for routers/switches) the
  compiled running config as ``<RUNNINGCONFIG>`` lines,
* one ``<LINK>`` per planned link, with both endpoints resolved to the port
  names Packet Tracer derives from the module layout,
* the interface IP settings of every end device (PC/laptop/server/printer) on
  the port that actually carries the link.

Everything the generator cannot know is reported in ``warnings`` instead of
being invented: an unknown model, a port the model does not have, a cable
kind the template library has never seen.  A run that produced warnings still
returns a file - the caller decides whether to show it as complete.

Server *services* (DHCP/DNS/FTP panels) are deliberately not encoded: Packet
Tracer keeps them in runtime state, not in the save file.  ``config_servers``
steps are reported as a known limitation.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
import copy
import uuid
import xml.etree.ElementTree as ET

import pkt_codec
import pkt_template_build as template_build

__all__ = [
    "BuildError",
    "load_library",
    "build_pkt",
    "generate_pkt_file",
    "normalize_port_name",
    "resolve_port",
]

# Node types (the app's vocabulary) -> substrings of Packet Tracer's kind text
# inside <TYPE ...>Router</TYPE>.
KIND_PATTERNS = {
    "router": ("router",),
    "wireless-router": ("wirelessrouter", "wireless router", "homerouter"),
    "switch": ("switch", "multilayerswitch", "internetswitch"),
    "pc": ("pc", "workstation"),
    "laptop": ("laptop",),
    "server": ("server",),
    "printer": ("printer",),
    "firewall": ("firewall", "asa", "securityappliance"),
    "wireless": ("accesspoint", "wirelessaccesspoint", "wireless"),
    "wlc": ("wirelesslancontroller", "wlc"),
    "phone": ("ipphone", "phone"),
    "modem": ("modem", "dslmodem", "cablemodem"),
    "tv": ("tv", "smarttv"),
    "cloud": ("cloud",),
    "iot": ("iot", "mcu", "homegateway"),
    "tablet": ("tablet",),
    "smartphone": ("smartphone", "cellphone", "pda"),
}

CLI_KINDS = ("router", "switch", "multilayer switch")

# Canvas rows per node type.  Packet Tracer's logical workspace is roughly
# 2000x1200 at 100% zoom; this keeps routers on top, switches in the middle
# and end devices below them, like the executor's own layout.
ROW_Y = {
    "router": 120, "firewall": 120, "wireless-router": 120,
    "switch": 300,
    "pc": 480, "laptop": 480, "server": 480, "printer": 480,
    "wireless": 480, "iot": 480, "tablet": 660, "smartphone": 660,
    "cloud": 660,
}
DEFAULT_ROW_Y = 660
X_START = 240
X_STEP = 200

_POSITION_RE = re.compile(r"^([a-z]+)((?:[0-9]+(?:/[0-9]+)*)?)$")
_PORT_ALIASES = {
    "f": "fastethernet", "fa": "fastethernet", "fe": "fastethernet",
    "g": "gigabitethernet", "gi": "gigabitethernet", "ge": "gigabitethernet",
    "e": "ethernet", "eth": "ethernet",
    "s": "serial", "se": "serial", "ser": "serial",
    "w": "wireless", "wlan": "wireless",
}
_PORT_FAMILIES = ("fastethernet", "gigabitethernet", "ethernet", "serial",
                  "fiber", "wireless")

# Cable kind -> (link medium, cable type) as Packet Tracer names them.
LINK_MEDIUMS = {
    "copper": ("eCopper", "eStraightThrough"),
    "straight": ("eCopper", "eStraightThrough"),
    "copper-cross": ("eCopper", "eCrossOver"),
    "cross": ("eCopper", "eCrossOver"),
    "crossover": ("eCopper", "eCrossOver"),
    "serial": ("eSerial", "eSerial"),
    "serial-dce": ("eSerial", "eSerial"),
    "serial-dte": ("eSerial", "eSerial"),
    "fiber": ("eFiber", "eFiber"),
    "console": ("eConsole", "eConsole"),
}

# Exec-mode lines the app types at the CLI but that must not live inside a
# saved running config: Packet Tracer replays this text in config mode.
_NON_CONFIG_LINES = {
    "write memory", "write", "wr", "copy running-config startup-config",
    "copy run start", "configure terminal", "conf t", "enable",
    "terminal length 0", "end",
}


class BuildError(RuntimeError):
    """The plan or the template library cannot produce a file."""


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

def load_library(directory: str = "") -> dict:
    """Load the template manifest plus every block it references."""
    # Search the places a library can live before giving up: an
    # installed app keeps its bundled copy somewhere the source
    # checkout never sees.
    root = os.path.abspath(
        directory or template_build.find_library_dir())
    manifest_path = os.path.join(root, template_build.MANIFEST_FILE)
    if not os.path.isfile(manifest_path):
        raise BuildError(
            f"no template library in {root}. Build it from your own .pkt "
            "files first (POST /pkt/templates/build).")
    try:
        with open(manifest_path, encoding="utf-8") as stream:
            manifest = json.load(stream)
    except Exception as exc:  # noqa: BLE001
        raise BuildError(f"template manifest unreadable: {exc}") from exc

    blocks = {}
    for entry in list(manifest.get("devices", [])) + \
            list(manifest.get("links", [])):
        relative = str(entry.get("file", ""))
        path = os.path.join(root, relative)
        if relative and os.path.isfile(path):
            with open(path, "rb") as stream:
                blocks[relative] = xml_safe(stream.read())
    skeleton_file = str(manifest.get("skeleton")
                        or template_build.SKELETON_FILE)
    skeleton_path = os.path.join(root, skeleton_file)
    if not os.path.isfile(skeleton_path):
        raise BuildError(f"skeleton template missing: {skeleton_path}")
    with open(skeleton_path, "rb") as stream:
        manifest["_skeleton"] = stream.read()
    manifest["_blocks"] = blocks
    manifest["_directory"] = root
    return manifest


# ---------------------------------------------------------------------------
# Port naming
# ---------------------------------------------------------------------------

def normalize_port_name(name: str) -> str:
    """'g0/1' and 'GigabitEthernet0/1' become 'gigabitethernet0/1'."""
    text = re.sub(r"[\s_-]+", "", str(name or "").strip().lower())
    match = _POSITION_RE.match(text)
    if not match:
        return text
    prefix = _PORT_ALIASES.get(match.group(1), match.group(1))
    return prefix + (match.group(2) or "")


def _family_from_request(want: str) -> str:
    for family in _PORT_FAMILIES:
        if want.startswith(family):
            return family
    return ""


def resolve_port(variant: dict, requested: str,
                 taken=()) -> tuple[dict | None, str]:
    """Find the template port a plan/config name refers to.

    Returns ``(port, note)``; ``note`` is non-empty when the name had to be
    interpreted (bare family, or a serial slot that differs per hardware).

    ``taken`` is the set of port names this device has already given to
    another interface.  A device has a fixed number of ports, so the second
    of two names on a two-port model must not land on the port the first one
    took: 'g0/0' and 'g0/1' on a 2811 are FastEthernet0/0 and
    FastEthernet0/1, never FastEthernet0/0 twice (which is what Packet Tracer
    refuses when the same port is cabled twice).
    """
    want = normalize_port_name(requested)
    if not want:
        return None, ""
    ports = variant.get("ports") or []
    claimed = {str(name) for name in taken or () if str(name)}
    for port in ports:
        if port.get("name") and normalize_port_name(port["name"]) == want:
            return port, ""
    # A bare family ("f0", "eth0", "g0") means the first free port of it.
    for port in ports:
        if port.get("name") and want == str(port.get("family") or ""):
            if port["name"] in claimed:
                continue
            return port, f"{requested} -> {port['name']} (first of family)"
    family = _family_from_request(want)
    # Inside the copper Ethernet family the models are interchangeable: a
    # plan that says GigabitEthernet on a FastEthernet-only model is remapped
    # (the executor does the same - "a LAN on a different slot is still a
    # LAN").  The note keeps the remap visible.
    families = {"ethernet": ("ethernet", "fastethernet", "gigabitethernet"),
                "fastethernet": ("fastethernet", "ethernet",
                                 "gigabitethernet"),
                "gigabitethernet": ("gigabitethernet", "fastethernet",
                                    "ethernet")}
    candidates = families.get(family, (family,))
    for candidate in candidates:
        if not candidate:
            continue
        for port in ports:
            if not port.get("name") or port.get("family") != candidate:
                continue
            if port["name"] in claimed:
                continue
            return port, f"{requested} -> {port['name']} (slot remap)"
    return None, ""


def _resolve_cached(variant: dict, spec: str,
                    resolved: dict) -> tuple[dict | None, str]:
    """Resolve one interface name for this device, once, claiming its port.

    ``resolved`` maps the normalized name to the port it got, so a link and
    the config line for the same interface always agree, and two different
    names never share one port (see :func:`resolve_port`).
    """
    key = normalize_port_name(spec)
    if not key:
        return None, ""
    if key in resolved:
        return resolved[key], ""
    taken = {str(port.get("name")) for port in resolved.values()}
    port, note = resolve_port(variant, spec, taken)
    if port:
        resolved[key] = port
    return port, note


def _kind_matches(kind: str, node_type: str) -> bool:
    text = re.sub(r"[^a-z0-9]+", "", str(kind or "").lower())
    node = str(node_type or "").strip().lower()
    for pattern in KIND_PATTERNS.get(node, (node,)):
        if re.sub(r"[^a-z0-9]+", "", pattern) in text:
            return True
    return False


def _kind_text_matches(kind: str, node_type: str) -> bool:
    text = str(kind or "").strip().lower().replace(" ", "").replace("-", "")
    node = str(node_type or "").strip().lower().replace(" ", "")
    return bool(text) and bool(node) and (text == node or node in text
                                          or text in node)


def _template_identity_mismatch(library: dict, entry: dict) -> str:
    """Reject a library record whose saved device block identifies another kind.

    The manifest is editable machine-local data.  A stale or hand-built record
    can claim to be a model while pointing at a block cloned from a different
    device (for example, a TV record backed by a TabletPC block).  Packet
    Tracer may reject that otherwise well-formed XML while loading its
    Physical Workspace.
    """
    block = (library.get("_blocks") or {}).get(str(entry.get("file") or ""))
    if not block:
        return "template block is missing"
    try:
        device = ET.fromstring(block)
    except ET.ParseError:
        return "template block is not valid XML"
    device_type = device.find("./ENGINE/TYPE")
    if device_type is None:
        # The offline generator's minimal fixtures and older PT saves may put
        # the device identity directly under DEVICE. The same model/kind
        # comparison below still guards against a mismatched template block.
        device_type = device.find("./TYPE")
    if device_type is None:
        return "template has no ENGINE/TYPE identity"

    def identity(value: str) -> str:
        return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())

    actual_model = device_type.get("model", "")
    actual_kind = (device_type.text or "").strip()
    expected_model = str(entry.get("model") or "").strip()
    expected_kind = str(entry.get("kind") or "").strip()
    mismatches = []
    if identity(actual_model) != identity(expected_model):
        mismatches.append(
            f"model is {actual_model or '(empty)'}, expected "
            f"{expected_model or '(empty)'}")
    if identity(actual_kind) != identity(expected_kind):
        mismatches.append(
            f"device kind is {actual_kind or '(empty)'}, expected "
            f"{expected_kind or '(empty)'}")
    return "; ".join(mismatches)


def select_variant(library: dict, node: dict,
                   wanted_ports) -> tuple[dict | None, list[str]]:
    """Pick the model template that best covers this node and its ports."""
    node_type = str(node.get("type") or "").strip().lower()
    wanted = [str(port) for port in (wanted_ports or []) if str(port).strip()]
    candidates = [entry for entry in library.get("devices", [])
                  if _kind_matches(entry.get("kind", ""), node_type)]
    if not candidates:
        candidates = [entry for entry in library.get("devices", [])
                      if _kind_text_matches(entry.get("kind", ""), node_type)]
    valid_candidates = []
    rejected = []
    for entry in candidates:
        mismatch = _template_identity_mismatch(library, entry)
        if mismatch:
            rejected.append(f"{node.get('name')}: ignored incompatible "
                            f"template {entry.get('key')}: {mismatch}")
        else:
            valid_candidates.append(entry)
    candidates = valid_candidates
    if not candidates:
        return None, rejected + [
            f"{node.get('name')}: no {node_type or 'device'} model has a "
            "valid template - node skipped"]
    model_hint = str(node.get("model") or "").strip().lower()

    def coverage(entry):
        hits = 0
        for port in wanted:
            resolved, _ = resolve_port(entry, port)
            hits += 1 if resolved else 0
        return hits

    def score(entry):
        model = str(entry.get("model") or "").lower()
        hint = 1 if model_hint and (model == model_hint
                                    or model.startswith(model_hint)) else 0
        return (coverage(entry), hint, -len(entry.get("ports") or []))

    best = max(candidates, key=score)
    # A rejected template is reported even when another model can take its
    # place: "used 2811 instead of 1941" with no reason reads like the model
    # does not exist, when the real answer is that its harvested block needs
    # to be rebuilt.
    notes = list(rejected)
    missing = [port for port in wanted
               if not resolve_port(best, port)[0]]
    if missing:
        notes.append(f"{node.get('name')}: template {best.get('key')} has no "
                     f"port for {', '.join(missing)}")
    if model_hint and model_hint not in str(best.get("model", "")).lower():
        # Say *why*, not just that: a 2911 template usually exists and was
        # passed over because it has no port for one of the requested
        # interfaces (the serial WAN, on a machine whose 2911 has no HWIC).
        hinted = next((entry for entry in candidates
                       if str(entry.get("model") or "").lower()
                       .startswith(model_hint)), None)
        miss = [port for port in wanted
                if hinted is not None
                and not resolve_port(hinted, port)[0]]
        reason = (f" (its template has no port for {', '.join(miss)})"
                  if miss else "")
        notes.append(f"{node.get('name')}: used {best.get('model')} "
                     f"instead of {model_hint}{reason}")
    return best, notes


# ---------------------------------------------------------------------------
# Block surgery
# ---------------------------------------------------------------------------

# Every block the library hands over is sanitized before use: a control
# character that is legal in a Packet Tracer save but not in XML 1.0 (the ^C
# in a banner, for one) sits in the 1941 template on this machine, and one of
# them makes that whole block unparseable - the model then looks like it was
# never harvested.
xml_safe = pkt_codec.xml_safe


def _esc(text: str) -> bytes:
    return xml_safe(
        str(text).replace("&", "&amp;").replace("<", "&lt;")
        .replace(">", "&gt;").encode("utf-8"))


def _replace_first(source: bytes, pattern: bytes, replacement: bytes) -> bytes:
    match = re.search(pattern, source)
    if not match:
        return source
    return source[:match.start()] + replacement + source[match.end():]


def _set_name(block: bytes, name: str) -> bytes:
    """Fresh identity: the display name and, when the template carries one,
    the CLI hostname (SYS_NAME).  A non-CLI device must not inherit the
    template source's stale hostname either, so SYS_NAME is always rewritten
    when present."""
    out = _replace_first(
        block, rb"<NAME translate=\"true\">[^<]*</NAME>",
        b"<NAME translate=\"true\">" + _esc(name) + b"</NAME>")
    return _replace_first(out, rb"<SYS_NAME>[^<]*</SYS_NAME>",
                          b"<SYS_NAME>" + _esc(name) + b"</SYS_NAME>")


def _set_ref_id(block: bytes, ref: int) -> bytes:
    """Write this device's save id, adding the field when the model has none.

    Packet Tracer's own sample labs (the files it ships in ``saves/``) write a
    compact shape: 29 of the 118 templates this machine harvested carry no
    ``SAVE_REF_ID`` at all and their links address devices positionally.  A
    file this builder writes addresses devices by save-ref-id, so the field
    is added - where every save that has it keeps it, at the end of ENGINE.
    """
    value = b"<SAVE_REF_ID>save-ref-id:" + str(ref).encode() \
        + b"</SAVE_REF_ID>"
    if _has_tag(block, "SAVE_REF_ID"):
        return _replace_first(
            block, rb"<SAVE_REF_ID(?:\s[^>]*)?>[^<]*</SAVE_REF_ID>", value)
    close = block.find(b"</ENGINE>")
    if close >= 0:
        return block[:close] + b"   " + value + b"\n  " + block[close:]
    # A host template can have no ENGINE; the field still belongs to DEVICE.
    match = re.search(rb"<DEVICE(?:\s[^>]*)?>", block)
    if not match:
        return block
    return block[:match.end()] + b"\n   " + value + block[match.end():]


def _set_position(block: bytes, x: int, y: int) -> bytes:
    logical = re.search(rb"<LOGICAL>.*?</LOGICAL>", block, re.S)
    if not logical:
        return block
    fixed = re.sub(rb"<X>[^<]*</X>", b"<X>" + str(x).encode() + b"</X>",
                   logical.group(0), count=1)
    fixed = re.sub(rb"<Y>[^<]*</Y>", b"<Y>" + str(y).encode() + b"</Y>",
                   fixed, count=1)
    return block[:logical.start()] + fixed + block[logical.end():]


def _stable_guid(*parts: str) -> str:
    """A Packet Tracer UUID string that is unique and stable per device."""
    seed = "netbuilder-pkt:" + ":".join(str(part) for part in parts)
    return "{" + str(uuid.uuid5(uuid.NAMESPACE_URL, seed)) + "}"


def _set_physical_identity(block: bytes, *, name: str, physical_path: str,
                           parent_path: str, container_id: str,
                           x: int, y: int, identity: str) -> bytes:
    """Point one device at its rebuilt physical-workspace leaf."""
    block = _set_tag(block, "PHYSICAL", physical_path)
    cpur = re.search(rb"<PHYSICAL_CPUR>.*?</PHYSICAL_CPUR>", block, re.S)
    if not cpur:
        raise BuildError(f"{name}: device template has no PHYSICAL_CPUR data")
    chunk = cpur.group(0)
    # Most models keep the immediate container in its own field, but 58 of the
    # 118 templates this machine harvested (the 1841, the 2811, the 7960...)
    # have no CONTAINER_ID at all and write the whole ancestry into
    # PARENT_PATH instead.  Adding a field a model never carries would be
    # guessing at its schema, so the joined path is written in that case and
    # the container is the path's last element.
    if _has_tag(chunk, "CONTAINER_ID"):
        fields = (("PARENT_PATH", parent_path),
                  ("CONTAINER_ID", container_id),
                  ("X", str(x)), ("Y", str(y)))
    else:
        fields = (("PARENT_PATH", ",".join(
            part for part in (parent_path, container_id) if part)),
            ("X", str(x)), ("Y", str(y)))
    for tag, value in fields:
        if not _has_tag(chunk, tag):
            raise BuildError(f"{name}: physical workspace is missing {tag}")
        chunk = _set_tag(chunk, tag, value)
    # This field is present in most PT-authored devices but absent in some
    # models (for example Server-PT). Preserve that model-specific schema.
    if _has_tag(chunk, "ORIGINAL_DEVICE_UUID"):
        chunk = _set_tag(chunk, "ORIGINAL_DEVICE_UUID", identity)
    return block[:cpur.start()] + chunk + block[cpur.end():]


def _rebuild_physical_workspace(skeleton: bytes, device_blocks: list[bytes],
                                device_report: list[dict], project: str,
                                notes: list | None = None
                                ) -> tuple[bytes, list[bytes]]:
    """Recreate physical device leaves so the workspace matches the output.

    Packet Tracer stores physical devices twice: a TYPE=6 leaf in the global
    PHYSICALWORKSPACE tree, and a comma-separated ancestry path in each
    DEVICE/WORKSPACE/PHYSICAL. Reusing device templates without rebuilding
    both sides leaves stale, duplicated, or foreign UUIDs and Packet Tracer
    rejects the save as corrupted Physical Workspace data.

    ``notes`` (optional) collects one message per device that could not be
    placed physically; the caller shows them as build warnings.
    """
    match = re.search(rb"<PHYSICALWORKSPACE(?:\s[^>]*)?>.*?"
                      rb"</PHYSICALWORKSPACE>", skeleton, re.S)
    has_device_paths = any(_has_tag(block, "PHYSICAL")
                           for block in device_blocks)
    if not match:
        if has_device_paths:
            raise BuildError("the device templates contain Physical Workspace "
                             "paths but the skeleton has no PHYSICALWORKSPACE")
        return skeleton, device_blocks
    if len(device_blocks) != len(device_report):
        raise BuildError("device report does not match the generated devices")

    try:
        workspace = ET.fromstring(match.group(0))
    except ET.ParseError as exc:
        raise BuildError(f"invalid PHYSICALWORKSPACE template: {exc}") from exc

    # Index real container ancestry and keep a PT-authored type-6 example for
    # each likely destination (rack for network equipment, office for hosts).
    containers: list[dict] = []
    prototypes: dict[str, ET.Element] = {}

    def walk(node: ET.Element, ancestor_path: list[str]) -> None:
        kind = (node.findtext("TYPE") or "").strip()
        node_uuid = (node.findtext("UUID_STR") or "").strip()
        path = ancestor_path + ([node_uuid] if node_uuid else [])
        children = node.find("CHILDREN")
        if kind == "6":
            if ancestor_path:
                prototypes.setdefault(ancestor_path[-1], node)
            return
        if kind in {"0", "1", "2", "3", "4"} and children is not None:
            containers.append({"node": node, "type": kind,
                               "uuid": node_uuid, "path": path})
        if children is not None:
            for child in children.findall("NODE"):
                walk(child, path)

    for node in workspace.findall("./NODE"):
        walk(node, [])

    if not containers:
        raise BuildError("PHYSICALWORKSPACE has no usable device containers")
    # Keep the first PT-authored leaf of each direct container as a cloning
    # prototype, then clear every old device leaf (the network is replaced).
    def clear_device_leaves(node: ET.Element) -> None:
        children = node.find("CHILDREN")
        if children is None:
            return
        for child in list(children.findall("NODE")):
            if (child.findtext("TYPE") or "").strip() == "6":
                children.remove(child)
            else:
                clear_device_leaves(child)

    for root_node in workspace.findall("./NODE"):
        clear_device_leaves(root_node)
    used_uuids = {
        (element.text or "").strip()
        for element in workspace.iter("UUID_STR")
        if (element.text or "").strip()
    }
    used_names: set[str] = set()
    per_container: dict[str, int] = {}
    rebuilt_blocks: list[bytes] = []

    for index, (block, report) in enumerate(zip(device_blocks,
                                                device_report)):
        name = str(report.get("name") or "").strip()
        kind = str(report.get("type") or "").strip().lower()
        if b"<PHYSICAL_CPUR" not in block:
            # Packet Tracer's own sample labs save a few models (1941, 1841,
            # 2950-24, the 5505 ASA...) with no physical-workspace data at all
            # - of the 1841 saves found on this machine, 115 device blocks
            # carry none.  Such a block has nowhere to point a physical leaf,
            # so it is placed in the Logical workspace only: the file stays
            # valid and the device is still fully cabled and configured,
            # instead of failing the whole build over a missing optional
            # section.
            if _has_tag(block, "PHYSICAL"):
                # A leftover path would point at a leaf of the source file's
                # workspace, which this build never created.
                block = _set_tag(block, "PHYSICAL", "")
            rebuilt_blocks.append(block)
            if notes is not None:
                notes.append(f"{name}: its saved model has no physical-"
                             "workspace data; the device is placed in the "
                             "Logical workspace only")
            continue
        if not name:
            raise BuildError("a generated device has no name for its physical "
                             "workspace entry")
        if name in used_names:
            raise BuildError(f"duplicate device name in Physical Workspace: "
                             f"{name}")
        used_names.add(name)
        want_rack = kind in {"router", "switch", "firewall", "wireless-router"}
        preferred_type = "4" if want_rack else "2"
        candidates = [entry for entry in containers
                      if entry["type"] == preferred_type and entry["uuid"]]
        if not candidates:
            fallback_types = ("2", "3", "1", "0") if want_rack else (
                "3", "4", "1", "0")
            for fallback_type in fallback_types:
                candidates = [entry for entry in containers
                              if entry["type"] == fallback_type
                              and entry["uuid"]]
                if candidates:
                    break
        if not candidates:
            raise BuildError(f"{name}: no compatible physical container has a "
                             "UUID in PHYSICALWORKSPACE")
        container = candidates[0]
        container_uuid = container["uuid"]
        if not all(container["path"]):
            raise BuildError(f"{name}: physical container ancestry has a "
                             "missing UUID")
        prototype = prototypes.get(container_uuid)
        if prototype is None:
            # Some valid templates have a container with no saved occupants.
            # A leaf is generic in Packet Tracer's schema, so clone a genuine
            # type-6 leaf from another container while preserving its fields.
            prototype = next(iter(prototypes.values()), None)
        if prototype is None:
            raise BuildError("PHYSICALWORKSPACE has no PT-authored device leaf "
                             "to clone")

        slot = per_container.get(container_uuid, 0)
        per_container[container_uuid] = slot + 1
        if want_rack:
            x, y = 4 + slot * 4, 0
        else:
            x, y = 86 + slot * 86, 215 + (slot // 8) * 86

        leaf_uuid = _stable_guid(project, name, str(index), "physical-leaf")
        suffix = 1
        while leaf_uuid in used_uuids:
            leaf_uuid = _stable_guid(project, name, str(index),
                                     f"physical-leaf-{suffix}")
            suffix += 1
        used_uuids.add(leaf_uuid)
        leaf = copy.deepcopy(prototype)
        name_element = leaf.find("NAME")
        if name_element is None:
            name_element = ET.SubElement(leaf, "NAME")
        name_element.attrib.setdefault("translate", "true")
        name_element.text = name
        uuid_element = leaf.find("UUID_STR")
        if uuid_element is None:
            uuid_element = ET.SubElement(leaf, "UUID_STR")
        uuid_element.text = leaf_uuid
        for tag, value in (("X", str(x)), ("Y", str(y))):
            element = leaf.find(tag)
            if element is None:
                element = ET.SubElement(leaf, tag)
            element.text = value
        children = container["node"].find("CHILDREN")
        if children is None:
            children = ET.SubElement(container["node"], "CHILDREN")
        children.append(leaf)

        physical_path = ",".join(container["path"] + [leaf_uuid])
        parent_path = ",".join(container["path"][:-1])
        identity = _stable_guid(project, name, str(index), "device-identity")
        rebuilt_blocks.append(_set_physical_identity(
            block, name=name, physical_path=physical_path,
            parent_path=parent_path, container_id=container_uuid,
            x=x, y=y, identity=identity))

    pws_xml = ET.tostring(workspace, encoding="utf-8")
    return (skeleton[:match.start()] + pws_xml + skeleton[match.end():],
            rebuilt_blocks)


def _mac(seed: str, index: int) -> str:
    digest = hashlib.sha1(f"{seed}:{index}".encode("utf-8")).digest()
    first = digest[0] | 0x02  # locally administered, never all-zero
    return (f"{first:02X}{digest[1]:02X}.{digest[2]:02X}{digest[3]:02X}."
            f"{digest[4]:02X}{digest[5]:02X}")


def _set_macs(block: bytes, seed: str) -> bytes:
    spans = template_build.iter_port_spans(block)
    if not spans:
        return block
    out = bytearray()
    cursor = 0
    for index, (start, end) in enumerate(spans):
        out.extend(block[cursor:start])
        port = block[start:end]
        mac = _mac(seed, index).encode()
        port = re.sub(rb"<(MACADDRESS|BIA)>[^<]*</\1>",
                      rb"<\1>" + mac + rb"</\1>", port)
        out.extend(port)
        cursor = end
    out.extend(block[cursor:])
    return bytes(out)


# An XML attribute list, as PT writes it (`translate="true"`): optional
# name="value" pairs.  Matched separately from the tag name so a self-closing
# tag's slash is never mistaken for an attribute.
_ATTRS = rb"((?:\s+[^>\s/]+(?:\s*=\s*(?:\"[^\"]*\"|'[^']*'))?)*)"


def _tag_pattern(tag: str, *, closing: bool = False) -> bytes:
    """Match ``<TAG ...>`` / ``<TAG .../>`` (or the closing form)."""
    name = tag.encode()
    return rb"<" + (b"/" if closing else b"") + name + _ATTRS + rb"\s*/?>"


def _has_tag(block: bytes, tag: str) -> bool:
    """Whether the block has this element, with or without attributes.

    Packet Tracer writes attributes on some fields - ``<NAME
    translate="true">`` always, and ``<PHYSICAL translate="true">`` in 57 of
    the 118 templates on this machine - so a matcher that only knows the
    plain form silently skips a tag that is really there.
    """
    return bool(re.search(_tag_pattern(tag), block))


def _set_tag(block: bytes, tag: str, value: str) -> bytes:
    """Replace the first TAG element's text, keeping its own attributes."""
    name = tag.encode()
    pattern = (rb"<" + name + _ATTRS + rb"\s*/>|"
               rb"<" + name + _ATTRS + rb"\s*>.*?</" + name + rb">")

    def replace(match: "re.Match") -> bytes:
        attributes = match.group(1) or match.group(2) or b""
        return (b"<" + name + attributes + b">" + _esc(value)
                + b"</" + name + b">")
    return re.sub(pattern, replace, block, count=1)


def _patch_port(block: bytes, port_index: int, fields: dict) -> bytes:
    spans = template_build.iter_port_spans(block)
    if port_index < 0 or port_index >= len(spans):
        return block
    start, end = spans[port_index]
    port = block[start:end]
    for tag, value in fields.items():
        port = _set_tag(port, tag, str(value))
    return block[:start] + port + block[end:]


def _sanitize_config_lines(text: str) -> tuple[list[str], list[str]]:
    """Config text -> the lines Packet Tracer stores, plus dropped notes."""
    lines = []
    dropped = []
    for raw in str(text or "").replace("\r\n", "\n").split("\n"):
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            lines.append("!")
            continue
        if stripped.lower() in _NON_CONFIG_LINES:
            dropped.append(stripped)
            continue
        lines.append(stripped)
    while lines and lines[-1] == "!":
        lines.pop()
    return lines, dropped


def _interface_lines(lines: list[str]) -> list[str]:
    names = []
    for line in lines:
        match = re.match(r"^interface\s+(\S+)\s*$", line, re.I)
        if match:
            # A virtual interface (an ASA's Vlan1) has no port to claim, so
            # it is config to write, not hardware to find.
            if not _VIRTUAL_INTERFACES.match(match.group(1)):
                names.append(match.group(1))
            continue
        match = re.match(r"^interface\s+range\s+(\S+)\s*-\s*(\S+)\s*$",
                         line, re.I)
        if match:
            names.append(match.group(1))
            # `interface range f0/2 - 24` names the second end as a bare
            # number: it is a range boundary, not a port this device must
            # have, so only a fully qualified end is claimed.
            last = match.group(2)
            if _family_from_request(normalize_port_name(last)):
                names.append(last)
    return names


# ASA (Firewall-PT) interfaces that are not physical ports: an ASA-5505
# routes through `interface Vlan1`, and Packet Tracer stores no <PORT> for
# one.  They are real config lines and must survive untouched, and they must
# never be counted as a port requirement - demanding one made every firewall
# plan warn that the template "has no port for Vlan1".
_VIRTUAL_INTERFACES = re.compile(r"^(vlan|bvi|management|inside|outside|dmz)"
                                 r"[0-9]*$", re.I)


def _remap_config_interfaces(variant: dict, lines: list[str],
                             resolved: dict | None = None,
                             ) -> tuple[list[str], list[str]]:
    """Rewrite interface names to the ports this model really has.

    ``resolved`` (shared with the link resolution for the same device) maps
    each interface name to the port it owns, so the config's interfaces and
    the cables land on the same ports and never on each other's.
    """
    resolved = {} if resolved is None else resolved
    notes = []
    out = []
    for line in lines:
        match = re.match(r"^interface\s+(\S+)\s*$", line, re.I)
        if match:
            requested = match.group(1)
            if _VIRTUAL_INTERFACES.match(requested):
                out.append(line)
                continue
            port, note = _resolve_cached(variant, requested, resolved)
            if port:
                if note:
                    notes.append(f"config: {note}")
                line = f"interface {port['name']}"
            elif _family_from_request(normalize_port_name(requested)):
                notes.append(f"config references {requested}, which "
                             f"{variant.get('key')} does not have")
            out.append(line)
            continue
        match = re.match(r"^interface\s+range\s+(\S+)\s*-\s*(\S+)\s*$",
                         line, re.I)
        if match:
            first, _ = _resolve_cached(variant, match.group(1), resolved)
            last, _ = _resolve_cached(variant, match.group(2), resolved)
            if first and last:
                line = f"interface range {first['name']} - {last['name']}"
            out.append(line)
            continue
        out.append(line)
    return out, notes


def _set_config_tag(block: bytes, tag: bytes, lines: list[str]) -> bytes:
    """Write one config element: the lines, or an empty self-closed tag."""
    if not _has_tag(block, tag.decode()):
        return block
    if lines:
        body = b"\n".join(
            b"      <LINE>" + _esc(line) + b"</LINE>" for line in lines)
        replacement = (b"<" + tag + b">\n" + body + b"\n     </" + tag + b">")
    else:
        replacement = b"<" + tag + b"/>"
    pattern = (rb"<" + tag + rb"(?:\s[^>]*)?>.*?</" + tag + rb">|"
               rb"<" + tag + rb"(?:\s[^>]*)?/>")
    return re.sub(pattern, lambda _m: replacement, block, count=1, flags=re.S)


def _set_config(block: bytes, lines: list[str]) -> bytes:
    """The plan's config becomes both the running and the startup config.

    A generated device has never run `write memory` (it is dropped as
    exec-only), so the two would differ - except that every harvested block
    still carries the STARTUPCONFIG of the save it came from, which holds the
    *source* device's identity: `hostname R1`, its banners and its password
    hashes.  Leaving that in place means a generated R2 can answer `show
    startup-config` with R1's config and its secrets, so the plan's text is
    written to both elements and the leftover is never shipped.
    """
    out = _set_config_tag(block, b"RUNNINGCONFIG", lines)
    return _set_config_tag(out, b"STARTUPCONFIG", lines)


def _interface_blocks(lines: list[str]) -> dict[str, list[str]]:
    """Config lines grouped by interface, subcommands in order."""
    blocks: dict[str, list[str]] = {}
    current = ""
    for line in lines:
        match = re.match(r"^interface\s+(\S+)\s*$", line, re.I)
        if match:
            current = match.group(1)
            blocks.setdefault(current, [])
            continue
        if current:
            blocks[current].append(line)
    return blocks


def _clock_rate_for(lines: list[str], port_name: str) -> str:
    """The `clock rate N` configured on one interface, if any."""
    wanted = normalize_port_name(port_name)
    current = ""
    for line in lines:
        match = re.match(r"^interface\s+(\S+)\s*$", line, re.I)
        if match:
            current = normalize_port_name(match.group(1))
            continue
        match = re.match(r"^clock rate\s+(\d+)\s*$", line, re.I)
        if match and current == wanted:
            return match.group(1)
    return ""


def _ref_id(seed: str, used: set) -> int:
    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    ref = int.from_bytes(digest[:8], "big") & 0x7FFFFFFFFFFFFFFF
    guard = 0
    while (not ref or ref in used) and guard < 64:
        ref = ((ref * 6364136223846793005 + 1442695040888963407)
               & 0x7FFFFFFFFFFFFFFF)
        guard += 1
    used.add(ref)
    return ref


# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------

def _pick_link_template(library: dict, cable: str) -> tuple[dict | None,
                                                            str]:
    medium, cable_type = LINK_MEDIUMS.get(
        str(cable or "copper").strip().lower(), ("eCopper", "eStraightThrough"))
    entries = library.get("links", [])
    for entry in entries:
        if entry.get("type") == medium and entry.get("cable") == cable_type:
            return entry, ""
    for entry in entries:  # the right medium, any cable of it
        if entry.get("type") == medium:
            return entry, ""
    if medium == "eCopper":
        return None, ""  # caller reports "library has no copper link"
    return None, f"no {medium} cable template in the library"


# Copper LAN families a spare-port remap may use (never serial/wireless).
ETHERNET_FAMILIES = ("fastethernet", "gigabitethernet", "ethernet")


def _spare_ethernet_port(used: dict, device: str, ports: list) -> str:
    """A free copper Ethernet port for `device`, or "".

    `used` maps (device, port) -> True for every port already claimed by a
    link or by a config interface.  Only link-capable families are offered
    (never a serial or wireless port for a copper link), in template order.
    """
    taken = {port for (dev, port) in used if dev == device}
    for port in ports or []:
        name = str(port.get("name") or "")
        if not name or port.get("family") not in ETHERNET_FAMILIES:
            continue
        if name not in taken:
            return name
    return ""


def _build_link(library: dict, link: dict, refs: dict, port_names: dict,
                warnings: list, dce_ports: dict | None = None,
                used_ports: dict | None = None,
                variants: dict | None = None) -> bytes | None:
    name_a = str(link.get("a") or "")
    name_b = str(link.get("b") or "")
    if name_a not in refs or name_b not in refs:
        warnings.append(f"link {name_a}-{name_b}: endpoint was skipped")
        return None
    requested_cable = str(link.get("cable") or "copper")
    template, note = _pick_link_template(library, requested_cable)
    if template is None:
        warnings.append(
            f"link {name_a}-{name_b}: "
            + (note or "the library has no copper cable template"))
        return None
    if note:
        warnings.append(f"link {name_a}-{name_b}: {note}")
    block = library["_blocks"].get(template["file"])
    if not block:
        warnings.append(f"link {name_a}-{name_b}: template block missing")
        return None
    port_a = port_names.get((name_a, str(link.get("aIf") or "")))
    port_b = port_names.get((name_b, str(link.get("bIf") or "")))
    # A copper LAN whose interface could not be resolved can fall back to a
    # free Ethernet port - a LAN on another Ethernet slot is still a LAN.
    # Serial, fiber, and console links must retain their requested medium and
    # endpoint family; remapping one to Ethernet creates a misleading cable
    # record that Packet Tracer cannot use as requested.  First come, first
    # served: each Ethernet claim is recorded so the next link cannot reuse it.
    medium, _cable_type = LINK_MEDIUMS.get(
        requested_cable.strip().lower(), ("eCopper", "eStraightThrough"))
    allow_ethernet_remap = medium == "eCopper"
    if allow_ethernet_remap and not port_a and name_a in refs:
        spare = _spare_ethernet_port(used_ports or {}, name_a,
                                     (variants or {}).get(name_a, {}).get(
                                         "ports", []))
        if spare:
            port_a = spare
            port_names[(name_a, str(link.get("aIf") or ""))] = spare
            warnings.append(
                f"link {name_a}-{name_b}: {link.get('aIf')} not usable on "
                f"{name_a}; cabled on {spare} (spare-port remap)")
    if allow_ethernet_remap and not port_b and name_b in refs:
        spare = _spare_ethernet_port(used_ports or {}, name_b,
                                     (variants or {}).get(name_b, {}).get(
                                         "ports", []))
        if spare:
            port_b = spare
            port_names[(name_b, str(link.get("bIf") or ""))] = spare
            warnings.append(
                f"link {name_a}-{name_b}: {link.get('bIf')} not usable on "
                f"{name_b}; cabled on {spare} (spare-port remap)")
    if not port_a:
        warnings.append(f"link {name_a}-{name_b}: {link.get('aIf')} not "
                        f"usable on {name_a}")
        return None
    if not port_b:
        warnings.append(f"link {name_a}-{name_b}: {link.get('bIf')} not "
                        f"usable on {name_b}")
        return None
    out = block
    out = _replace_first(out, rb"<FROM>[^<]*</FROM>",
                         b"<FROM>save-ref-id:" + str(refs[name_a]).encode()
                         + b"</FROM>")
    out = _replace_first(out, rb"<PORT>[^<]*</PORT>",
                         b"<PORT>" + _esc(port_a) + b"</PORT>")
    out = _replace_first(out, rb"<TO>[^<]*</TO>",
                         b"<TO>save-ref-id:" + str(refs[name_b]).encode()
                         + b"</TO>")
    # Second <PORT> belongs to the TO side.
    match = re.search(rb"<TO>[^<]*</TO>\s*<PORT>[^<]*</PORT>", out)
    if match:
        segment = match.group(0)
        out = out[:match.start()] + re.sub(
            rb"<PORT>[^<]*</PORT>",
            lambda _m: b"<PORT>" + _esc(port_b) + b"</PORT>",
            segment) + out[match.end():]
    out = re.sub(rb"<([A-Z_]*MEM_ADDR)>[^<]*</\1>", rb"<\1>0</\1>", out)
    # A serial link records which end is DCE.  That is only knowable from the
    # `clock rate` the plan's config gave one of the two ports; without it the
    # stale pointer to a foreign device must go, not stay.
    dce_ports = dce_ports or {}
    dce_side = "a" if (name_a, port_a) in dce_ports else (
        "b" if (name_b, port_b) in dce_ports else "")
    if dce_side:
        if dce_side == "a":
            dce_name, dce_port = name_a, port_a
        else:
            dce_name, dce_port = name_b, port_b
        out = _replace_first(
            out, rb"<DCEDEV>[^<]*</DCEDEV>",
            b"<DCEDEV>save-ref-id:" + str(refs[dce_name]).encode()
            + b"</DCEDEV>")
        out = _replace_first(out, rb"<DCEPORT>[^<]*</DCEPORT>",
                             b"<DCEPORT>" + _esc(dce_port) + b"</DCEPORT>")
    elif b"<DCEDEV>" in out:
        out = re.sub(rb"<DCEDEV>[^<]*</DCEDEV>\s*", b"", out)
        out = re.sub(rb"<DCEPORT>[^<]*</DCEPORT>\s*", b"", out)
        warnings.append(
            f"link {name_a}-{name_b}: the plan gave neither end a clock rate, "
            "so the serial link has no DCE side")
    # The template's cable kind may differ from the one the plan asked for
    # (a crossover on the straight-through block is the same structure).
    _medium, wanted_cable = LINK_MEDIUMS.get(requested_cable.strip().lower(),
                                             ("eCopper", "eStraightThrough"))
    if wanted_cable and template.get("cable") \
            and template["cable"] != wanted_cable:
        cable_segment = re.search(rb"<CABLE>.*?</CABLE>", out, re.S)
        if cable_segment:
            fixed = re.sub(
                rb"<TYPE>[^<]*</TYPE>",
                b"<TYPE>" + wanted_cable.encode() + b"</TYPE>",
                cable_segment.group(0), count=1)
            out = (out[:cable_segment.start()] + fixed
                   + out[cable_segment.end():])
    return out


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

def _plan_sections(plan: dict) -> dict:
    steps = [step for step in (plan or {}).get("steps") or []
             if isinstance(step, dict)]
    nodes, links, configs, pcs, servers = [], [], {}, {}, {}
    for step in steps:
        action = step.get("action")
        if action == "create_nodes":
            nodes.extend(step.get("nodes") or [])
        elif action == "create_links":
            links.extend(step.get("links") or [])
        elif action == "paste_cli":
            configs.update({
                str(key): str(value)
                for key, value in (step.get("configs") or {}).items()})
        elif action == "config_pcs":
            for key, value in (step.get("pcs") or {}).items():
                if isinstance(value, dict):
                    pcs[str(key)] = value
        elif action == "config_servers":
            for key, value in (step.get("servers") or {}).items():
                servers[str(key)] = value
    return {"nodes": nodes, "links": links, "configs": configs,
            "pcs": pcs, "servers": servers}


# ---------------------------------------------------------------------------
# Services tab (DHCP / DNS / HTTP / AAA / FTP / email / syslog / NTP)
# ---------------------------------------------------------------------------
#
# A Packet Tracer save carries the whole Services tab inside each server's
# <ENGINE> block, which is why the extracted Server-PT template ships the
# *source* save's stale pool and leases.  The offline generator therefore
# rewrites those elements from the plan: DHCP pools, DNS records, HTTP/HTTPS,
# FTP/email, and the ACS/TACACS+ users plus the router client entry.

_SERVICE_TAGS = (b"NTP_SERVER", b"HTTP_SERVER", b"HTTPS_SERVER", b"DNS_SERVER",
                 b"DHCP_SERVERS", b"FTP_SERVER", b"SYSLOG_SERVER",
                 b"ACS_SERVER", b"EMAIL_SERVER", b"TFTP_SERVER",
                 b"DHCPV6_SERVER_LIST", b"IOE_USER_MANAGER",
                 b"IOX_VM_MANAGER", b"REGISTRATION_SEVER", b"SNMP_MANAGER")

# Packet Tracer writes the AAA server type as RADIUS or TACACS (the ACS tab
# spells TACACS+ that way in every save on this machine).
def _server_type(value) -> str:
    text = str(value or "").strip().upper()
    return "RADIUS" if "RADIUS" in text else "TACACS"


def _indexed(tag: str, index: int, value) -> bytes:
    """PT's indexed list elements: ``<USER0>``, ``<PASSWORD0>``, ...

    The mail server panel stores its mailboxes that way, so the tag name
    carries the index rather than an attribute.
    """
    name = (tag + str(index)).encode()
    return b"<" + name + b">" + _svc(value) + b"</" + name + b">"



_ETHERNET_FAMILIES = ("fastethernet", "gigabitethernet", "ethernet")


def _element_span(block: bytes, tag: str) -> tuple[int, int] | None:
    """Span of the first <TAG>...</TAG>, or of a self-closing <TAG/>."""
    match = re.search(rb"<" + tag.encode() + rb"(?:\s[^>]*)?>", block)
    if not match:
        return None
    if match.group(0).endswith(b"/>"):
        return (match.start(), match.end())
    close = block.find(b"</" + tag.encode() + b">", match.end())
    if close < 0:
        return None
    return (match.start(), close + len(tag) + 3)


def _net_and_last_ip(ip: str, mask: str) -> tuple[str, str]:
    """Network address and last usable address for a pool start + mask."""
    try:
        parts = [int(part) for part in str(ip).split(".")]
        bits = [int(part) for part in str(mask).split(".")]
    except ValueError:
        return str(ip), str(ip)
    if len(parts) != 4 or len(bits) != 4:
        return str(ip), str(ip)
    net = [part & bit for part, bit in zip(parts, bits)]
    last = [net[i] + (255 - bits[i]) for i in range(4)]
    last[3] = max(last[3] - 1, net[3])
    return ".".join(str(p) for p in net), ".".join(str(p) for p in last)


def _svc(text) -> bytes:
    return _esc(text)


def build_pkt(plan: dict, library: dict | None = None, *, project: str = "",
              version: str = "") -> dict:
    """Compile a plan into save-file XML.  Returns a report, never a file."""
    library = library or load_library()
    sections = _plan_sections(plan)
    nodes = [node for node in sections["nodes"] if node.get("name")]
    project = str(project or plan.get("project") or "default").strip() \
        or "default"
    warnings: list[str] = []

    # What ports does each node need?  Links say it directly; the compiled
    # config says it for every interface it touches.
    wanted: dict[str, list[str]] = {}
    for link in sections["links"]:
        for side, iface in (("a", "aIf"), ("b", "bIf")):
            name = str(link.get(side) or "")
            spec = str(link.get(iface) or "")
            if name and spec:
                wanted.setdefault(name, []).append(spec)
    for name, text in sections["configs"].items():
        lines, _dropped = _sanitize_config_lines(text)
        for interface in _interface_lines(lines):
            wanted.setdefault(name, []).append(interface)
    # One entry per interface: a port wanted by a link *and* named in the
    # config is one requirement, not three, and the same port repeated in a
    # note ("has no port for s0/0/0, s0/0/0, s0/0/0") reads like noise.
    for name, specs in list(wanted.items()):
        unique = []
        for spec in specs:
            if spec not in unique:
                unique.append(spec)
        wanted[name] = unique

    used_refs: set = set()
    refs: dict[str, int] = {}
    port_names: dict[tuple, str] = {}
    # (device, interface) -> clock rate: which ports the plan made DCE.
    dce_ports: dict[tuple, str] = {}
    # (device, port) -> True: every port claimed by a resolved link, a spare
    # remap, or a config interface - so two links never share a port.
    used_ports: dict[tuple, bool] = {}
    device_blocks: list[bytes] = []
    device_report = []
    variants_used: dict[str, dict] = {}
    columns: dict[int, int] = {}

    for node in nodes:
        name = str(node["name"])
        device_report_services: dict = {}
        variant, notes = select_variant(library, node, wanted.get(name, []))
        warnings.extend(notes)
        if variant is None:
            continue
        block = library["_blocks"].get(variant["file"])
        if not block:
            warnings.append(f"{name}: template block {variant['file']} is "
                            "missing from the library")
            continue
        variants_used[name] = variant
        node_type = str(node.get("type") or "").strip().lower()
        row = ROW_Y.get(node_type, DEFAULT_ROW_Y)
        column = columns.get(row, 0)
        columns[row] = column + 1
        x, y = X_START + column * X_STEP, row
        block = _set_name(block, name)
        ref = _ref_id(f"{project}:{name}", used_refs)
        refs[name] = ref
        block = _set_ref_id(block, ref)
        block = _set_macs(block, f"{project}:{name}")
        block = _set_position(block, x, y)

        config_lines: list[str] = []
        # (normalized interface name) -> template port: one resolution per
        # interface per device, shared by the config and the links, so a
        # two-port router cannot put its WAN and its LAN on one port.
        resolved_ports: dict[str, dict] = {}
        if name in sections["configs"]:
            config_lines, dropped = _sanitize_config_lines(
                sections["configs"][name])
            if dropped:
                warnings.append(f"{name}: dropped exec-only line(s) from the "
                                f"saved config: {', '.join(sorted(set(dropped)))}")
            config_lines, notes = _remap_config_interfaces(
                variant, config_lines, resolved_ports)
            warnings.extend(notes)
            block = _set_config(block, config_lines)

        # Every port the plan named, resolved once, so links and IP config
        # both use the name Packet Tracer actually knows.  `plan_ports` keeps
        # the plan's own spelling for the report; `resolved_ports` is the
        # per-device claim table shared with the config remap above.
        plan_ports: dict[str, dict] = {}
        for spec in wanted.get(name, []):
            port, note = _resolve_cached(variant, spec, resolved_ports)
            if port:
                plan_ports[spec] = port
                port_names[(name, spec)] = port["name"]
                used_ports[(name, port["name"])] = True
                if note and note not in warnings:
                    warnings.append(f"{name}: {note}")
        # Clocking: a serial DCE end needs the flag set on the port itself.
        for spec, port in plan_ports.items():
            clock = _clock_rate_for(config_lines, port["name"])
            if clock:
                dce_ports[(name, port["name"])] = clock
                block = _patch_port(block, port["index"],
                                    {"CLOCKRATE": clock,
                                     "CLOCKRATEFLAG": "true"})

        # Mirror interface runtime state into the PORT elements.  Packet
        # Tracer loads up/down and the IP from the port, NOT by replaying
        # the running config - a generated file that only embeds config
        # text opens with every referenced interface down (the serial link
        # shows red).  `no shutdown` and `ip address` therefore land on the
        # port element too.
        for ifname, sub in _interface_blocks(config_lines).items():
            port, _note = _resolve_cached(variant, ifname, resolved_ports)
            if not port:
                continue
            used_ports[(name, port["name"])] = True
            fields: dict[str, str] = {}
            lowered = [s.strip().lower() for s in sub]
            if "no shutdown" in lowered:
                fields["POWER"] = "true"
            elif "shutdown" in lowered:
                fields["POWER"] = "false"
            for line in lowered:
                match = re.match(r"^ip address\s+(\S+)\s+(\S+)$", line)
                if match:
                    fields["IP"] = match.group(1)
                    fields["SUBNET"] = match.group(2)
            if fields:
                block = _patch_port(block, port["index"], fields)

        # End-device IP settings land on the port that carries the link,
        # falling back to the first named Ethernet port.  Servers carry the
        # same shape under config_servers (ip/mask/gw next to their
        # services), so they get identical treatment.
        endpoint_settings = None
        if name in sections["pcs"]:
            endpoint_settings = sections["pcs"][name] or {}
        elif name in sections["servers"]:
            entry = sections["servers"][name] or {}
            if isinstance(entry, dict) and entry.get("ip"):
                endpoint_settings = entry
        if endpoint_settings is not None:
            settings = endpoint_settings
            target = None
            for spec, port in plan_ports.items():
                if port.get("family") in ("fastethernet", "gigabitethernet",
                                          "ethernet"):
                    target = port
                    break
            if target is None:
                for port in variant.get("ports", []):
                    if port.get("name") and port.get("family") in (
                            "fastethernet", "gigabitethernet", "ethernet"):
                        target = port
                        break
            if target is None:
                warnings.append(f"{name}: no Ethernet port found for its IP "
                                "settings")
            else:
                fields = {"PORT_DHCP_ENABLE": "false"}
                if settings.get("ip"):
                    fields["IP"] = str(settings["ip"])
                if settings.get("mask"):
                    fields["SUBNET"] = str(settings["mask"])
                if settings.get("gw"):
                    fields["PORT_GATEWAY"] = str(settings["gw"])
                if settings.get("dns"):
                    fields["PORT_DNS"] = str(settings["dns"])
                if str(settings.get("ipv6", "")).lower() == "true":
                    # Dual-stack: endpoints autoconfigure from the router's
                    # advertisements (SLAAC) rather than a spelled-out
                    # address.  Verified against real saves: the port
                    # carries IPV6_ENABLED + IPV6_ADDRESS_AUTOCONFIG.
                    fields["IPV6_ENABLED"] = "true"
                    fields["IPV6_ADDRESS_AUTOCONFIG"] = "true"
                block = _patch_port(block, target["index"], fields)

        # SERVICES TAB: the save file really does carry it (DHCP pools, DNS
        # records, HTTP/HTTPS, FTP/email accounts, the ACS/TACACS+ users and
        # clients, syslog and NTP switches all live in the server's <ENGINE>
        # block), so an offline .pkt is configured, not just placed.  The
        # template's own leftovers - a stale 10.0.0.0/8 pool and its leases -
        # are replaced either way, never shipped.
        server_entry = sections["servers"].get(name) or {}
        server_services = server_entry.get("services") \
            if isinstance(server_entry.get("services"), dict) else server_entry
        # Wireless rules ride on the NODE itself (serviceRules.wireless) -
        # they apply to APs, home routers and any device with a wireless
        # ENGINE, none of which are servers.
        node_wireless = (node.get("serviceRules") or {}).get("wireless") \
            if isinstance(node.get("serviceRules"), dict) else None
        if node_wireless and isinstance(server_services, dict):
            server_services = {**server_services,
                               "wireless": node_wireless}
        elif node_wireless:
            server_services = {"wireless": node_wireless}
        block, service_notes, service_report = _apply_services(
            block, variant, server_services)
        warnings.extend(f"{name}: {note}" for note in service_notes)
        if service_report:
            device_report_services = service_report

        device_blocks.append(block)
        device_report.append({
            "name": name,
            "type": node_type,
            **({"services": device_report_services}
               if device_report_services else {}),
            "model": variant.get("model"),
            "template": variant.get("key"),
            "x": x, "y": y,
            "configLines": len(config_lines),
            "ports": {spec: port["name"] for spec, port in plan_ports.items()},
        })

    link_blocks = []
    link_report = []
    for link in sections["links"]:
        block = _build_link(library, link, refs, port_names, warnings,
                            dce_ports, used_ports, variants_used)
        if block is None:
            continue
        # The link's own port claims (resolved or spare-remapped) count
        # toward the used set, so a later link cannot take them.
        for side in ("a", "b"):
            dev = str(link.get(side) or "")
            port = port_names.get((dev, str(link.get(f"{side}If") or "")))
            if dev and port:
                used_ports[(dev, port)] = True
        link_blocks.append(block)
        link_report.append({
            "a": str(link.get("a") or ""),
            "aIf": port_names.get((str(link.get("a") or ""),
                                   str(link.get("aIf") or "")), ""),
            "b": str(link.get("b") or ""),
            "bIf": port_names.get((str(link.get("b") or ""),
                                   str(link.get("bIf") or "")), ""),
            "cable": str(link.get("cable") or "copper"),
        })

    if not sections["servers"]:
        pass
    elif not any(entry.get("services") for entry in device_report):
        warnings.append(
            "no server in this plan declares a service role, so every "
            "Services tab was left at its off state")

    xml = library["_skeleton"]
    xml = _replace_first(xml, rb"<VERSION>[^<]*</VERSION>",
                         b"<VERSION>" + _esc(version or
                                             library.get("version") or
                                             "9.0.0.0810")
                         + b"</VERSION>")
    xml, device_blocks = _rebuild_physical_workspace(
        xml, device_blocks, device_report, project, warnings)
    devices_doc = b"\n".join(
        b"\n".join(b"   " + line for line in block.split(b"\n"))
        for block in device_blocks)
    links_doc = b"\n".join(
        b"\n".join(b"   " + line for line in block.split(b"\n"))
        for block in link_blocks)
    xml = re.sub(rb"<DEVICES\s*>\s*</DEVICES>",
                 lambda _m: b"<DEVICES>\n" + devices_doc + b"\n  </DEVICES>",
                 xml, count=1)
    xml = re.sub(rb"<LINKS\s*>\s*</LINKS>",
                 lambda _m: b"<LINKS>\n" + links_doc + b"\n  </LINKS>",
                 xml, count=1)
    if b"<DEVICE>" not in xml:
        raise BuildError("no device could be built from this plan; the "
                         "template library may not cover the planned models")

    _validate(xml, refs)
    return {
        "xml": xml,
        "version": version or library.get("version") or "",
        "project": project,
        "devices": device_report,
        "links": link_report,
        "warnings": _dedupe(warnings),
        "deviceCount": len(device_blocks),
        "linkCount": len(link_blocks),
        "plannedDevices": len(nodes),
        "plannedLinks": len(sections["links"]),
        "templateVersion": library.get("version") or "",
        "templateDirectory": library.get("_directory") or "",
    }


def _service_elements(services: dict, port_name: str, report: dict,
                      notes: list) -> dict:
    """The <ENGINE> service elements for one server, from the plan payload.

    Only what the plan declares is switched on: an undeclared service is left
    off (never inherited from the template).
    """
    def flag(on: bool) -> bytes:
        return b"1" if on else b"0"

    def plan_for(role: str) -> dict:
        value = services.get(role)
        return value if isinstance(value, dict) else {}

    out: dict = {}

    # --- HTTP / HTTPS -----------------------------------------------------
    # Every panel is rewritten even when the plan does not ask for it, so a
    # template's leftover state can never ship inside a generated file.
    http = plan_for("http")
    out["HTTP_SERVER"] = (
        b"<HTTP_SERVER><ENABLED>" + flag(bool(http)) + b"</ENABLED>"
        b"<USERNAME>" + _svc(http.get("username") or "") + b"</USERNAME>"
        b"<PASSWORD>" + _svc(http.get("password") or "") + b"</PASSWORD>"
        b"</HTTP_SERVER>")
    out["HTTPS_SERVER"] = (
        b"<HTTPS_SERVER><HTTPSENABLED>"
        + flag(bool(http.get("https"))) + b"</HTTPSENABLED></HTTPS_SERVER>")
    if http:
        report["http"] = {"on": True, "https": bool(http.get("https"))}

    # --- DNS --------------------------------------------------------------
    rows = []
    for record in (plan_for("dns").get("records") or []):
        if not isinstance(record, dict):
            continue
        name = str(record.get("name") or "").strip()
        address = str(record.get("address") or "").strip()
        if not name or not address:
            continue
        rows.append(
            b"<RESOURCE-RECORD><TYPE>A-REC</TYPE><NAME>" + _svc(name)
            + b"</NAME><TTL>86400</TTL><IPADDRESS>" + _svc(address)
            + b"</IPADDRESS></RESOURCE-RECORD>")
    out["DNS_SERVER"] = (
        b"<DNS_SERVER><ENABLED>" + flag(bool(rows))
        + b"</ENABLED><NAMESERVER-DATABASE>" + b"".join(rows)
        + b"</NAMESERVER-DATABASE></DNS_SERVER>")
    if rows:
        report["dns"] = {"records": len(rows)}

    # --- DHCP -------------------------------------------------------------
    dhcp = plan_for("dhcp")
    pools = dhcp.get("pools") if isinstance(dhcp.get("pools"), list) \
        else ([dhcp] if dhcp.get("startIp") else [])
    rows, seen = [], set()
    for index, pool in enumerate(p for p in pools if isinstance(p, dict)):
        start = str(pool.get("startIp") or "")
        mask = str(pool.get("mask") or "255.255.255.0")
        if not start:
            continue
        network, end = _net_and_last_ip(start, mask)
        pool_name = str(pool.get("poolName") or "").strip() \
            or f"pool{index + 1}"
        if pool_name in seen:
            pool_name = f"{pool_name}_{index + 1}"
        seen.add(pool_name)
        rows.append(
            b"<POOL><NAME>" + _svc(pool_name) + b"</NAME><NETWORK>"
            + _svc(network) + b"</NETWORK><MASK>" + _svc(mask)
            + b"</MASK><DEFAULT_ROUTER>"
            + _svc(pool.get("gateway") or "0.0.0.0")
            + b"</DEFAULT_ROUTER><TFTP_ADDRESS>0.0.0.0</TFTP_ADDRESS>"
            b"<START_IP>" + _svc(start) + b"</START_IP><END_IP>"
            + _svc(end) + b"</END_IP><DNS_SERVER>"
            + _svc(pool.get("dnsServer") or "0.0.0.0")
            + b"</DNS_SERVER><MAX_USERS>"
            + _svc(pool.get("maxUsers") or "100")
            + b"</MAX_USERS><DOMAIN_NAME/><DHCP_POOL_LEASES/>"
            b"<LEASE_TIME>86400000</LEASE_TIME>"
            b"<WLC_ADDRESS>0.0.0.0</WLC_ADDRESS></POOL>")
    out["DHCP_SERVERS"] = (
        b"<DHCP_SERVERS><ASSOCIATED_PORTS><ASSOCIATED_PORT><NAME>"
        + _svc(port_name) + b"</NAME><DHCP_SERVER><ENABLED>"
        + flag(bool(rows)) + b"</ENABLED><POOLS>" + b"".join(rows)
        + b"</POOLS><DHCP_RESERVATIONS/><AUTOCONFIG/>"
        b"</DHCP_SERVER></ASSOCIATED_PORT></ASSOCIATED_PORTS>"
        b"</DHCP_SERVERS>")
    if rows:
        report["dhcp"] = {"pools": len(rows)}

    # --- AAA (the PT ACS server: TACACS+/RADIUS users and clients) ---------
    aaa = plan_for("aaa")
    users = [u for u in (aaa.get("users") or [])
             if isinstance(u, dict) and u.get("username")]
    # clients carry the router IP as `hostIp` (or `ip` from the Dart
    # planner) - a client without an IP can never match a NAS, so it is
    # reported rather than silently dropped
    clients = [c for c in (aaa.get("clients") or [])
               if isinstance(c, dict) and (c.get("hostIp") or c.get("ip"))]
    for c in clients:
        if not c.get("hostIp"):
            c["hostIp"] = c["ip"]
    user_rows = [
        b"<USER><NAME>" + _svc(u.get("username")) + b"</NAME><PASSWORD>"
        + _svc(u.get("password") or "") + b"</PASSWORD><DESCRIPTION>"
        + _svc(u.get("description") or "") + b"</DESCRIPTION></USER>"
        for u in users]
    client_rows = [
        b"<CLIENT><HOST_IP>" + _svc(c.get("hostIp")) + b"</HOST_IP><KEY>"
        + _svc(c.get("key") or "") + b"</KEY><DESCRIPTION>"
        + _svc(c.get("description") or c.get("name") or "") + b"</DESCRIPTION>"
        b"<SERVER_TYPE>"
        + _svc(_server_type(c.get("serverType") or c.get("type")))
        + b"</SERVER_TYPE></CLIENT>" for c in clients]
    # Packet Tracer leaves AAA *Off* and its tab empty unless the server has
    # at least one account and one client, so an enabled-but-empty panel is
    # reported rather than silently shipped.
    aaa_on = bool(aaa) and aaa.get("enabled") is not False \
        and bool(user_rows or client_rows)
    auth_port = str(aaa.get("authPort") or "").strip()
    if not auth_port.isdigit():
        auth_port = "1645"
    out["ACS_SERVER"] = (
        b"<ACS_SERVER><ENABLED>" + flag(aaa_on)
        + b"</ENABLED><USERS>" + b"".join(user_rows) + b"</USERS>"
        b"<ACS_CLIENTS>" + b"".join(client_rows) + b"</ACS_CLIENTS>"
        b"<RADIUS_SETTINGS><AUTH_PORT>" + _svc(auth_port) + b"</AUTH_PORT>"
        b"</RADIUS_SETTINGS></ACS_SERVER>")
    if aaa:
        report["aaa"] = {"on": aaa_on, "users": len(user_rows),
                         "clients": len(client_rows),
                         "serverType": _server_type(
                             (clients[0].get("serverType") if clients else "")),
                         "authPort": auth_port}
        if not users:
            notes.append(
                "AAA is enabled on the server but the plan names no user, so "
                "no login can succeed until one is added")
        if not clients:
            notes.append(
                "AAA is enabled but the plan names no client router, so the "
                "router IP and shared key are missing from the server")

    # --- DHCPv6 -----------------------------------------------------------
    # The v6 server panel lives in DHCPV6_SERVER_LIST: one ASSOCIATED_PORT
    # with the running panel state, plus the pools in DHCPv6_POOLS.
    v6 = plan_for("dhcpv6")
    pools6 = [p for p in (v6.get("pools") or []) if isinstance(p, dict)]
    names6: list[str] = []
    pool6_rows = []
    for index, pool in enumerate(pools6):
        prefix = str(pool.get("prefix") or "").strip()
        if not prefix:
            continue
        name = str(pool.get("poolName") or "").strip() \
            or f"pool{index + 1}"
        if name in names6:
            name = f"{name}_{index + 1}"
        names6.append(name)
        length = str(pool.get("prefixLength") or "").strip() or "64"
        cidr = f"{prefix}/{length}"
        pool6_rows.append(
            b"<DHCPV6_POOL><POOL_NAME>" + _svc(name) + b"</POOL_NAME>"
            b"<DNS_SERVER>" + _svc(pool.get("dnsServer") or "")
            + b"</DNS_SERVER><DOMAIN_NAME>"
            + _svc(pool.get("domainName") or "") + b"</DOMAIN_NAME>"
            b"<PORT_NAME>" + _svc(port_name) + b"</PORT_NAME><STATIC_PDS/>"
            b"<ADDRESS_PREFIXES><ADDRESS_PREFIX><PREFIX_ID>" + _svc(cidr)
            + b"</PREFIX_ID><DHCPV6_PREFIX_DELEGATION><PREFIX_ID>"
            + _svc(cidr) + b"</PREFIX_ID><PREFIX_POOL_NAME>" + _svc(name)
            + b"</PREFIX_POOL_NAME><VALID_LIFETIME>2592000"
            b"</VALID_LIFETIME><PREFERRED_LIFETIME>604800"
            b"</PREFERRED_LIFETIME><PREFIX_LENGTH>" + _svc(length)
            + b"</PREFIX_LENGTH><PREFIX>" + _svc(prefix)
            + b"</PREFIX></DHCPV6_PREFIX_DELEGATION></ADDRESS_PREFIX>"
            b"</ADDRESS_PREFIXES></DHCPV6_POOL>")
    port6 = b""
    if pool6_rows:
        port6 = (
            b"<ASSOCIATED_PORTS><ASSOCIATED_PORT><PORT_NAME>"
            + _svc(port_name) + b"</PORT_NAME><DHCPV6_SERVER>"
            b"<DHCPV6_SERVER_PORT_DATA><ENABLED>1</ENABLED>"
            b"<RAPID_COMMIT>0</RAPID_COMMIT><HINT>0</HINT><POOL_NAME>"
            + _svc(names6[0]) + b"</POOL_NAME>"
            b"<INITIAL_ADVERTISE_TIME></INITIAL_ADVERTISE_TIME>"
            b"<LAST_ADVERTISE_TIME></LAST_ADVERTISE_TIME>"
            b"<ADVERTISE_MSG_COUNT>0</ADVERTISE_MSG_COUNT>"
            b"<INITIAL_REPLY_TIME></INITIAL_REPLY_TIME>"
            b"<LAST_REPLY_TIME></LAST_REPLY_TIME>"
            b"<REPLY_MSG_COUNT>0</REPLY_MSG_COUNT>"
            b"</DHCPV6_SERVER_PORT_DATA><BINDING_TABLE/>"
            b"</DHCPV6_SERVER></ASSOCIATED_PORT></ASSOCIATED_PORTS>")
    out["DHCPV6_SERVER_LIST"] = (
        b"<DHCPV6_SERVER_LIST>" + port6 + b"<DHCPv6_POOLS>"
        + b"".join(pool6_rows) + b"</DHCPv6_POOLS><IPv6_LOCAL_POOLS/>"
        b"</DHCPV6_SERVER_LIST>")
    if pool6_rows:
        report["dhcpv6"] = {"pools": len(pool6_rows)}

    # --- FTP / email ------------------------------------------------------
    ftp = plan_for("ftp")
    accounts = [a for a in (ftp.get("users") or [])
                if isinstance(a, dict) and a.get("username")]
    ftp_rows = [
        b"<ACCOUNT><USERNAME>" + _svc(a.get("username")) + b"</USERNAME>"
        b"<PASSWORD>" + _svc(a.get("password") or "") + b"</PASSWORD>"
        b"<PERMISSIONS>" + _svc(a.get("permissions") or "RWDNL")
        + b"</PERMISSIONS></ACCOUNT>" for a in accounts]
    out["FTP_SERVER"] = (
        b"<FTP_SERVER><ENABLED>" + flag(bool(ftp)) + b"</ENABLED>"
        b"<USER_ACCOUNT_MNGR>" + b"".join(ftp_rows)
        + b"</USER_ACCOUNT_MNGR></FTP_SERVER>")
    if ftp:
        report["ftp"] = {"on": True, "accounts": len(ftp_rows)}

    # The mail panel stores each mailbox as indexed elements (USER0,
    # PASSWORD0, NO_OF_MAILS0) and NO_OF_USERS has to match the count, or
    # Packet Tracer shows an account it will not authenticate.
    email = plan_for("email")
    mail_users = [u for u in (email.get("users") or [])
                  if isinstance(u, dict) and u.get("username")]
    mailboxes = b"".join(
        _indexed("USER", index, user.get("username"))
        + _indexed("PASSWORD", index, user.get("password") or "")
        + _indexed("NO_OF_MAILS", index, "0")
        for index, user in enumerate(mail_users))
    email_on = bool(email) and email.get("enabled") is not False
    out["EMAIL_SERVER"] = (
        b"<EMAIL_SERVER><SMTP_ENABLED>" + flag(email_on)
        + b"</SMTP_ENABLED><SMTP_DOMAIN>"
        + _svc(email.get("domain") or "") + b"</SMTP_DOMAIN>"
        b"<POP3_ENABLED>" + flag(email_on) + b"</POP3_ENABLED>"
        b"<FORWARD_MAIL>" + flag(bool(email.get("forward")))
        + b"</FORWARD_MAIL><NO_OF_USERS>" + _svc(len(mail_users))
        + b"</NO_OF_USERS>" + mailboxes + b"</EMAIL_SERVER>")
    if email:
        report["email"] = {"on": email_on,
                           "domain": email.get("domain") or "",
                           "users": len(mail_users)}

    # --- IoT registration server and VM manager ---------------------------
    # PT's "IoT" panel is the registration server's user list, and the VM
    # tab lists the containers a server can run.  Both are in the ENGINE.
    iot = plan_for("iot")
    iot_users = [u for u in (iot.get("users") or [])
                 if isinstance(u, dict) and u.get("username")]
    iot_rows = [
        b"<USER><NAME>" + _svc(u.get("username")) + b"</NAME><PASSWORD>"
        + _svc(u.get("password") or "") + b"</PASSWORD><DEVICES/>"
        b"<IOE_CONDITIONS/><IOE_RULES/></USER>" for u in iot_users]
    out["IOE_USER_MANAGER"] = (
        b"<IOE_USER_MANAGER><USERS>" + b"".join(iot_rows)
        + b"</USERS></IOE_USER_MANAGER>")
    if iot:
        registration = iot.get("registration") is not False
        out["REGISTRATION_SEVER"] = (
            b"<REGISTRATION_SEVER>"
            + (b"true" if registration else b"false")
            + b"</REGISTRATION_SEVER>")
        report["iot"] = {"users": len(iot_rows),
                         "registration": registration}
    vm = plan_for("vm")
    vms = [v for v in (vm.get("vms") or [])
           if isinstance(v, dict) and v.get("id")]
    vm_rows = [
        b"<VM><VM_ID>" + _svc(v.get("id")) + b"</VM_ID><VM_PATH>"
        + _svc(v.get("path") or v.get("id")) + b"</VM_PATH><VM_STATUS>"
        + _svc(v.get("status") or "1") + b"</VM_STATUS></VM>" for v in vms]
    out["IOX_VM_MANAGER"] = (
        b"<IOX_VM_MANAGER><VMS>" + b"".join(vm_rows) + b"</VMS>"
        b"</IOX_VM_MANAGER>")
    if vm:
        report["vm"] = {"vms": len(vm_rows)}

    # --- RADIUS EAP (wireless client authentication) ----------------------
    # The Server-PT ENGINE carries an <EAP_METHODS/> slot next to the
    # registration flag: one <EAP_METHOD><NAME> per accepted method
    # (PT offers PEAP, TLS, TTLS, FAST, LEAP).  WPA-Enterprise asks mean the
    # AAA server should accept EAP, not just RADIUS PAP from a NAS.
    eap = plan_for("radiusEap")
    methods = [str(m).strip().upper()
               for m in (eap.get("methods") or []) if str(m).strip()]
    if methods:
        rows = [b"<EAP_METHOD><NAME>" + _svc(m) + b"</NAME></EAP_METHOD>"
                for m in methods]
        out["EAP_METHODS"] = (
            b"<EAP_METHODS>" + b"".join(rows) + b"</EAP_METHODS>")
        report["radiusEap"] = {"methods": methods}

    # --- one-switch services ---------------------------------------------
    for role, tag in (("syslog", "SYSLOG_SERVER"), ("ntp", "NTP_SERVER"),
                      ("tftp", "TFTP_SERVER")):
        plan = plan_for(role)
        on = bool(plan) and plan.get("enabled") is not False
        if tag == "NTP_SERVER":
            # The panel's authentication fields are real state; the server
            # list is a live NTP client list and is left empty on purpose.
            out[tag] = (
                b"<NTP_SERVER><ENABLED>" + flag(on) + b"</ENABLED>"
                b"<ENABLED_SERVER_AUTHENTICATE>"
                + flag(bool(plan.get("authenticate")))
                + b"</ENABLED_SERVER_AUTHENTICATE><KEY>"
                + _svc(plan.get("key") or "0") + b"</KEY><MD5PASSWORD>"
                + _svc(plan.get("md5Password") or "")
                + b"</MD5PASSWORD><SERVER_IP_LIST/></NTP_SERVER>")
        else:
            out[tag] = (b"<" + tag.encode() + b"><ENABLED>" + flag(on)
                        + b"</ENABLED></" + tag.encode() + b">")
        if on:
            report[role] = {"on": True}

    # --- SNMP -------------------------------------------------------------
    snmp = plan_for("snmp")
    snmp_on = bool(snmp) and snmp.get("enabled") is not False
    out["SNMP_MANAGER"] = (
        b"<SNMP_MANAGER><AGENT_IP>"
        + _svc(snmp.get("agentIp") or "0.0.0.0") + b"</AGENT_IP>"
        b"<AGENT_PORT>" + _svc(snmp.get("agentPort") or "161")
        + b"</AGENT_PORT><MANAGER_PORT>"
        + _svc(snmp.get("managerPort") or "161")
        + b"</MANAGER_PORT><READ_COMMUNITY>"
        + _svc((snmp.get("readCommunity") or "") if snmp_on else "")
        + b"</READ_COMMUNITY><WRITE_COMMUNITY>"
        + _svc((snmp.get("writeCommunity") or "") if snmp_on else "")
        + b"</WRITE_COMMUNITY><SNMP_VERSION>"
        + _svc(snmp.get("version") or "1")
        + b"</SNMP_VERSION></SNMP_MANAGER>")
    if snmp_on:
        report["snmp"] = {"on": True,
                          "readCommunity": snmp.get("readCommunity") or ""}
    return out


# ---------------------------------------------------------------------------
# Wireless (SSID / WEP / WPA-PSK) - schema verified against real saves:
# every AP / home-router ENGINE carries a WIRELESS_SERVER > WIRELESS_COMMON
# block (SSID, ENCRYPT_TYPE, AUTHEN_TYPE, SSID_BROADCAST_ENABLED, WEP_KEY),
# and wireless endpoints carry the mirrored WIRELESS_PROFILE.
# Codes: ENCRYPT/AUTHEN 0 = none/open, 1/1 = WEP with the key in WEP_KEY
# (the only non-open pairing observed in real saves).
# ---------------------------------------------------------------------------
def _wireless_elements(services: dict, report: dict, notes: list) -> dict:
    wl = services.get("wireless")
    if not isinstance(wl, dict):
        return {}
    ssid = str(wl.get("ssid") or "").strip()
    if not ssid:
        return {}
    body = bytearray()

    def _common(sub: bytes) -> bytes:
        return (
            b"<WIRELESS_COMMON>\r\n"
            b"       <NETWORK_MODE>7</NETWORK_MODE>\r\n"
            b"       <SSID>" + _esc(ssid) + b"</SSID>\r\n"
            b"       <ENCRYPT_TYPE>" + sub + b"</ENCRYPT_TYPE>\r\n"
            b"       <AUTHEN_TYPE>" + sub + b"</AUTHEN_TYPE>\r\n"
            b"       <RADIO_BAND>0</RADIO_BAND>\r\n"
            b"       <WIDE_CHANNEL>0</WIDE_CHANNEL>\r\n"
            b"       <STANDARD_CHANNEL>0</STANDARD_CHANNEL>\r\n"
            b"       <STANDARD_CHANNEL5G>112</STANDARD_CHANNEL5G>\r\n"
            b"      </WIRELESS_COMMON>\r\n"
        )

    code = b"0"
    wep = wl.get("wep") or ("" if wl.get("wpa2") else "")
    if str(wl.get("wpa2", "")).lower() in ("1", "true") or wl.get("psk"):
        # PT's WPA2-PSK pairing is not reproducible from the saves on this
        # machine (every sampled save ships open/WEP); the SSID is written
        # and the pairing reported as manual-step.
        code = b"0"
        report["wireless"] = {
            "ssid": ssid,
            "wpa2": True,
            "verification": "manual_step",
        }
        notes.append(
            "wireless: WPA2-PSK must be confirmed in the device GUI; "
            "the SSID is set")
    elif str(wl.get("wep", "")).strip():
        code = b"1"
        wep = str(wl["wep"])
        report["wireless"] = {
            "ssid": ssid,
            "wep": True,
            "verification": "state_only",
        }
    else:
        report["wireless"] = {"ssid": ssid, "open": True,
                              "verification": "state_only"}

    ap_body = (
        b"<WIRELESS_SERVER>\r\n      "
        + _common(code)
        + b"      <SSID_BROADCAST_ENABLED>"
        + (b"1" if wl.get("broadcast", True) else b"0")
        + b"</SSID_BROADCAST_ENABLED>\r\n"
        b"      <MAC_FILTER_ENABLED>0</MAC_FILTER_ENABLED>\r\n"
        b"      <ALLOW_ACCESS>0</ALLOW_ACCESS>\r\n"
        b"     </WIRELESS_SERVER>\r\n"
    )
    if wep:
        ap_body += (b"      <WEP_KEY>" + _esc(wep) + b"</WEP_KEY>\r\n")

    client_body = (
        b"<WIRELESS_CLIENT>\r\n         "
        + _common(code)
        + b"         <PROFILES>\r\n"
        b"          <WIRELESS_PROFILE>\r\n"
        b"           <NAME>" + _esc(ssid) + b"</NAME>\r\n"
        b"           <SSID>" + _esc(ssid) + b"</SSID>\r\n"
        b"           <NETWORK_TYPE>7</NETWORK_TYPE>\r\n"
        b"           <RADIO_BAND>0</RADIO_BAND>\r\n"
        b"           <AUTHEN_TYPE>" + code + b"</AUTHEN_TYPE>\r\n"
        b"           <ENCRYPT_TYPE>" + code + b"</ENCRYPT_TYPE>\r\n"
        b"           <WEP_KEY>" + _esc(wep) + b"</WEP_KEY>\r\n"
        b"           <WPA_EAP_USERID></WPA_EAP_USERID>\r\n"
        b"           <WPA_EAP_PASSWORD></WPA_EAP_PASSWORD>\r\n"
        b"           <DHCP_ENABLED>1</DHCP_ENABLED>\r\n"
        b"           <DHCPV6_ENABLED>1</DHCPV6_ENABLED>\r\n"
        b"           <IP_ADDRESS/>\r\n"
        b"          </WIRELESS_PROFILE>\r\n"
        b"         </PROFILES>\r\n"
        b"        </WIRELESS_CLIENT>\r\n"
    )
    return {b"WIRELESS_SERVER": ap_body, b"WIRELESS_CLIENT": client_body}


def _apply_services(block: bytes, variant: dict,
                    services: dict) -> tuple[bytes, list, dict]:
    """Rewrite a device's <ENGINE> service elements from the plan payload."""
    report: dict = {}
    notes: list = []
    replacements = dict(
        _wireless_elements(services if isinstance(services, dict) else {},
                           report, notes))
    span = _element_span(block, "ENGINE")
    if not span:
        # Wireless lives outside the ENGINE for some devices (the AP's own
        # GUI schema), so still apply the wireless blocks before bailing.
        if replacements:
            for tag, body in replacements.items():
                tag_span = _element_span(block, tag.decode("ascii", "replace"))
                if tag_span:
                    block = (block[:tag_span[0]] + body + block[tag_span[1]:])
            return block, notes, report
        return block, [], {}
    head, engine, tail = block[:span[0]], block[span[0]:span[1]], block[span[1]:]
    if replacements:
        # Wireless spans the whole device, not just the ENGINE slice.
        for tag, body in replacements.items():
            whole = _element_span(block, tag.decode("ascii", "replace"))
            if whole:
                block = block[:whole[0]] + body + block[whole[1]:]
        span = _element_span(block, "ENGINE")
        if not span:
            return block, notes, report
        head, engine, tail = (block[:span[0]], block[span[0]:span[1]],
                              block[span[1]:])
    if not any(b"<" + tag + b">" in engine for tag in _SERVICE_TAGS):
        return block, notes, {}
    port_name = ""
    for port in variant.get("ports", []):
        if port.get("family") in _ETHERNET_FAMILIES:
            port_name = str(port.get("name") or "")
            break
    for tag, body in _service_elements(services, port_name, report,
                                       notes).items():
        tag_span = _element_span(engine, tag)
        if tag_span:
            engine = engine[:tag_span[0]] + body + engine[tag_span[1]:]
            continue
        # The template came from a save where this service was never
        # configured, so there is no element to rewrite. Skipping it left the
        # service silently off - the empty DHCP and AAA tabs that were
        # reported. Insert it before the closing </ENGINE> instead.
        close = engine.rfind(b"</ENGINE>")
        if close < 0:
            notes.append(
                f"{tag.decode('ascii', 'replace')}: the device template has "
                "nowhere to put this service, so it was left unset")
            continue
        engine = engine[:close] + body + engine[close:]
    return head + engine + tail, notes, report


def _dedupe(messages: list) -> list:
    """Keep the first occurrence of each distinct note, in order.

    One decision is often re-reported for every interface that used it (the
    same slot remap for five interface lines, the same model substitution for
    every port), which made a correct build look alarming in the UI.  Nothing
    is hidden: a genuinely different note still gets its own line.
    """
    seen, out = set(), []
    for message in messages or []:
        if message in seen:
            continue
        seen.add(message)
        out.append(message)
    return out


def _validate(xml: bytes, refs: dict) -> None:
    try:
        ET.fromstring(xml)
    except ET.ParseError as exc:
        raise BuildError(f"generated XML does not parse: {exc}") from exc
    ids = re.findall(rb"<SAVE_REF_ID>save-ref-id:(\d+)</SAVE_REF_ID>", xml)
    if len(ids) != len(set(ids)):
        raise BuildError("generated file has duplicate device ids")
    present = {int(value) for value in ids}
    for name, ref in refs.items():
        if ref not in present:
            raise BuildError(f"{name}: its device id is missing from the "
                             "generated document")
    for match in re.finditer(rb"<(FROM|TO)>save-ref-id:(\d+)</(FROM|TO)>", xml):
        if int(match.group(2)) not in present:
            raise BuildError("a link points at a device that is not in the "
                             "generated document")
    _validate_physical_workspace(xml)


def _validate_physical_workspace(xml: bytes) -> None:
    """Reject device/workspace UUID paths Packet Tracer cannot resolve."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as exc:
        raise BuildError(f"generated XML does not parse: {exc}") from exc
    workspace = root.find(".//PHYSICALWORKSPACE")
    if workspace is None:
        return  # Small synthetic fixtures can omit Packet Tracer's PWS block.

    leaves: dict[str, str] = {}
    path_by_uuid: dict[str, list[str]] = {}

    def index_paths(node: ET.Element, ancestors: list[str]) -> None:
        node_uuid = (node.findtext("UUID_STR") or "").strip()
        path = ancestors + ([node_uuid] if node_uuid else [])
        if node_uuid:
            if node_uuid in path_by_uuid:
                raise BuildError(f"duplicate Physical Workspace UUID: "
                                 f"{node_uuid}")
            path_by_uuid[node_uuid] = path
        children = node.find("CHILDREN")
        if children is not None:
            for child in children.findall("NODE"):
                index_paths(child, path)

    for node in workspace.findall("./NODE"):
        index_paths(node, [])
    for node in workspace.iter("NODE"):
        if (node.findtext("TYPE") or "").strip() != "6":
            continue
        node_uuid = (node.findtext("UUID_STR") or "").strip()
        name = (node.findtext("NAME") or "").strip()
        if not node_uuid or not name:
            raise BuildError("a Physical Workspace device leaf has no name or "
                             "UUID")
        if node_uuid in leaves:
            raise BuildError(f"duplicate Physical Workspace UUID: {node_uuid}")
        leaves[node_uuid] = name
    if len(set(leaves.values())) != len(leaves):
        raise BuildError("duplicate device names in Physical Workspace leaves")

    all_uuids = {
        (element.text or "").strip()
        for element in workspace.iter("UUID_STR")
        if (element.text or "").strip()
    }
    devices = root.findall(".//DEVICES/DEVICE")
    device_names = {
        (device.findtext(".//NAME") or "").strip()
        for device in devices
    }
    device_names.discard("")
    # A device whose saved model carries no Physical Workspace data is placed
    # in the Logical workspace only, so it is expected to have no leaf.
    logical_only = {
        (device.findtext(".//NAME") or "").strip()
        for device in devices
        if not (device.findtext(".//WORKSPACE/PHYSICAL") or "").strip()
    }
    logical_only.discard("")
    expected = device_names - logical_only
    if set(leaves.values()) != expected:
        stale = sorted(set(leaves.values()) - expected)
        missing = sorted(expected - set(leaves.values()))
        details = []
        if stale:
            details.append("stale=" + ", ".join(stale))
        if missing:
            details.append("missing=" + ", ".join(missing))
        raise BuildError("Physical Workspace leaves do not match network "
                         "devices (" + "; ".join(details) + ")")
    for device in devices:
        name = (device.findtext(".//NAME") or "").strip()
        physical = (device.findtext(".//WORKSPACE/PHYSICAL") or "").strip()
        if not physical:
            # Packet Tracer saves some models with no physical-workspace data
            # (see pkt_builder._rebuild_physical_workspace): such a device is
            # in the Logical workspace only, which is a valid file, but it
            # must not still carry the template's ancestry fields.
            if device.find(".//WORKSPACE/PHYSICAL_CPUR") is not None:
                raise BuildError(f"{name or 'device'} has Physical Workspace "
                                 "data but no leaf path")
            continue
        path = [part.strip() for part in physical.split(",") if part.strip()]
        unresolved = [part for part in path if part not in all_uuids]
        if unresolved:
            raise BuildError(f"{name or 'device'} has unresolved Physical "
                             f"Workspace UUID(s): {', '.join(unresolved)}")
        if not path or path[-1] not in leaves:
            raise BuildError(f"{name or 'device'} does not end at a physical "
                             "device leaf")
        if path != path_by_uuid.get(path[-1]):
            raise BuildError(f"{name or 'device'} Physical Workspace path "
                             "is not its leaf's actual ancestry")
        if leaves[path[-1]] != name:
            raise BuildError(f"{name or 'device'} points at the Physical "
                             f"Workspace leaf for {leaves[path[-1]]}")
        cpur = device.find(".//WORKSPACE/PHYSICAL_CPUR")
        if cpur is None:
            raise BuildError(f"{name or 'device'} has no PHYSICAL_CPUR data")
        parent_path = (cpur.findtext("PARENT_PATH") or "").strip()
        container_id = (cpur.findtext("CONTAINER_ID") or "").strip()
        parts = [part.strip() for part in parent_path.split(",")
                 if part.strip()]
        if container_id:
            parts.append(container_id)
        parts.append(path[-1])
        if parts != path:
            raise BuildError(f"{name or 'device'} Physical Workspace path "
                             "does not match PHYSICAL_CPUR ancestry")
        leaf = next(node for node in workspace.iter("NODE")
                    if (node.findtext("UUID_STR") or "").strip() == path[-1])
        for tag in ("X", "Y"):
            device_position = (cpur.findtext(tag) or "").strip()
            leaf_position = (leaf.findtext(tag) or "").strip()
            if device_position != leaf_position:
                raise BuildError(f"{name or 'device'} physical {tag} does not "
                                 "match its workspace leaf")


def generate_pkt_file(plan: dict, out_path: str, *, project: str = "",
                      library: dict | None = None, version: str = "",
                      replace: bool = False, log=None) -> dict:
    """Build the topology and write it as a .pkt.  Returns the report."""
    say = log or (lambda *_: None)
    target = os.path.abspath(os.path.expanduser(str(out_path or "").strip()))
    if not target.lower().endswith(".pkt"):
        raise BuildError("the output path must end in .pkt")
    if os.path.exists(target) and not replace:
        raise FileExistsError(f"refusing to overwrite an existing file: "
                              f"{target}")
    parent = os.path.dirname(target)
    if parent and not os.path.isdir(parent):
        raise BuildError(f"output directory does not exist: {parent}")
    built = build_pkt(plan, library, project=project, version=version)
    started = time.perf_counter()
    payload = pkt_codec.encrypt_pkt(built["xml"])
    temp = target + ".tmp"
    with open(temp, "wb") as stream:
        stream.write(payload)
    os.replace(temp, target)
    elapsed = time.perf_counter() - started
    report = {
        "path": target,
        "name": os.path.basename(target),
        "bytes": len(payload),
        "xmlBytes": len(built["xml"]),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "version": built["version"],
        "deviceCount": built["deviceCount"],
        "linkCount": built["linkCount"],
        "plannedDevices": built["plannedDevices"],
        "plannedLinks": built["plannedLinks"],
        "devices": built["devices"],
        "links": built["links"],
        "warnings": built["warnings"],
        "encodeMs": round(elapsed * 1000, 1),
        "authority": "NetBuilder offline generator",
        "binaryAuthority": "NetBuilder pkt_codec (verified container format)",
    }
    say(f"generated {target} ({report['bytes']} bytes, "
        f"{report['deviceCount']} devices, {report['linkCount']} links)")
    return report


def decode_pkt_file(path: str) -> bytes:
    """Read a .pkt back to XML (used to prove what was written)."""
    with open(path, "rb") as stream:
        return pkt_codec.decrypt_pkt(stream.read())


if __name__ == "__main__":  # pragma: no cover - manual tool
    import sys
    if len(sys.argv) < 3:
        print("usage: python pkt_builder.py <plan.json> <out.pkt>")
        raise SystemExit(2)
    with open(sys.argv[1], encoding="utf-8") as stream:
        plan_json = json.load(stream)
    print(json.dumps(generate_pkt_file(plan_json, sys.argv[2],
                                       replace=True, log=print), indent=2))
