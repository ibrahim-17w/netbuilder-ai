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
import math
import os
import re
import shutil
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

# Drawing bands per node role, top to bottom: routed core, aggregation,
# access, servers, then the hosts.  A device's band follows what it is FOR,
# not just its raw type, so servers get their own row instead of sharing the
# hosts'.
CORE_TYPES = ("router", "firewall", "cloud", "modem", "wireless-router")
AGGREGATION_TYPES = ("multilayer switch", "wlc")
ACCESS_TYPES = ("switch", "wireless", "accesspoint", "wireless access point")
SERVICE_TYPES = ("server",)
TIER_CORE, TIER_AGGREGATION, TIER_ACCESS, TIER_SERVICES, TIER_HOSTS = range(5)


def _tier_of(node_type: str) -> int:
    """Which drawing band a device belongs in, by what it does in the design."""
    kind = str(node_type or "").strip().lower()
    if kind in CORE_TYPES:
        return TIER_CORE
    if kind in AGGREGATION_TYPES:
        return TIER_AGGREGATION
    if kind in ACCESS_TYPES:
        return TIER_ACCESS
    if kind in SERVICE_TYPES:
        return TIER_SERVICES
    return TIER_HOSTS


# Vertical rhythm.  Only the tiers a plan actually uses get a band, so a
# router/switch/PC lab is drawn compactly instead of leaving empty rows for
# device kinds it does not have.
# The drawing algorithm's own version, reported by the engine over /health so
# an app can tell whether the engine answering on the port is the one it ships.
# Bump it whenever the placement changes in a way a person would SEE - a stale
# engine holding the port is why a layout fix can look like it never happened.
LAYOUT_REVISION = 5

ROW_TOP = 60
BAND_STEP = 190
# Second and later rows inside one band (a switch with more hosts than fit on
# one row) and the pitch that keeps devices readable side by side.
ROW_STEP = 130
DEVICE_PITCH = 120
BLOCK_GAP = 150
GRID_COLUMNS = 4
# The part of the workspace a person sees at 100% zoom (about 1600x900 on a
# full-screen Packet Tracer).  Wider plans scroll, but no row is ever allowed
# to grow without a wrap.
CANVAS_WIDTH = 1400
X_START = 140
DEFAULT_ROW_Y = ROW_TOP + BAND_STEP
# How far out each ring of the `radial` drawing sits, as a multiple of the
# device pitch. A ring has to clear the one inside it, so the step is a little
# over one pitch rather than exactly one.
RADIAL_FIRST_RING = 1.4
RADIAL_RING_STEP = 1.6

# The drawings a plan can ask for.  A person who says "the layout is ugly" or
# "spread them out" is asking for a DIFFERENT picture, not the same one again,
# so the layout is an input the plan carries rather than a constant:
#
#   tree     the default: each site a tree, hosts blocked under their switch;
#   wide     same tree, more room: bigger pitch and gaps, more hosts to a row;
#   compact  the whole lab on one screen: tighter pitch, fewer to a row;
#   rows     the textbook drawing: one band per device kind, left to right;
#   grouped  a tree, but the devices named in `side` are lifted out of their
#            own sub-tree and parked in one column at `sideEdge`, so "move the
#            servers to the side" has a drawing it can actually mean.
#   layered  the same hierarchy drawn left to right: ranks become COLUMNS.
#            The industry "hierarchical" diagram, and the one to reach for when
#            a lab reads better across than down;
#   radial   concentric rings by role: the core sits in the middle and the
#            hosts on the outside, so the shape of the lab is the shape of the
#            drawing;
#   circle   every device on one ring, ordered core-first, for an overview;
#   grid     an evenly spaced box that ignores the topology entirely - the
#            fastest way to read a lab with forty endpoints in it;
#   split    one vertical column per kind of device, so "servers on one side,
#            routers on the other" is a drawing rather than a hope.
#
# The five new drawings are deliberately different ALGORITHMS, not different
# scales of the same one: `tree`, `wide` and `compact` are the same tree at
# three sizes, which is why offering them side by side read as three near
# identical pictures.
LAYOUT_STYLES = ("tree", "wide", "compact", "rows", "grouped", "layered",
                 "backbone", "campus", "star", "radial", "ring", "circle",
                 "grid", "split")
# Drawings that place every device from the plan's shape alone, without
# nesting anything under an uplink.
LAYOUT_FLAT_STYLES = ("radial", "ring", "star", "circle", "grid", "split",
                      "backbone", "campus")
# How many devices a band holds before it wraps in the `rows` style.
ROWS_PER_ROW = 8
# What each style changes about the geometry.  `spacing` from the plan scales
# the pitch and the gaps on top of this, so "a bit more room" is expressible
# without inventing a new style.
LAYOUT_STYLE_SHAPES = {
    "tree": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "wide": {"spacing": 1.3, "columns": 6},
    "compact": {"spacing": 0.75, "columns": 4},
    "rows": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "grouped": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "layered": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "backbone": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "campus": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "star": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "radial": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "ring": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "circle": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "grid": {"spacing": 1.0, "columns": GRID_COLUMNS},
    "split": {"spacing": 1.0, "columns": GRID_COLUMNS},
}
DEFAULT_LAYOUT = {"style": "tree",
                  "spacing": 1.0,
                  "columns": GRID_COLUMNS}

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
    exact_taken = False
    for port in ports:
        if port.get("name") and normalize_port_name(port["name"]) == want:
            if port["name"] in claimed:
                # The name matches, but this device already gave that port to
                # another interface.  Returning it anyway is how R2 ended up
                # with two cables on GigabitEthernet0/1: the plan's invented
                # 'g1/0' was remapped onto Gi0/1 first, and the plan's real
                # 'g0/1' then claimed the same port by name - one interface,
                # two links, and the second `interface` block overwrote the
                # first so a whole subnet (and its OSPF network) vanished.
                exact_taken = True
                continue
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
            if exact_taken:
                return port, (f"{requested} -> {port['name']} "
                              f"({requested} is already carrying a cable)")
            return port, f"{requested} -> {port['name']} (slot remap)"
    return None, ""


def exact_port(variant: dict, spec: str) -> dict | None:
    """The port under exactly the name the plan spelled, or None.

    Used to reserve a model's OWN interfaces before any name it does not have
    is remapped onto a spare: the plan's real interfaces must keep the ports
    they name, and only the invented ones may take what is left.  Without the
    reservation a remapped name resolved first can swallow a port a real name
    needs (see :func:`resolve_port`).
    """
    want = normalize_port_name(spec)
    if not want or _SUBINTERFACE.match(str(spec or "").strip()):
        return None
    for port in variant.get("ports") or []:
        if port.get("name") and normalize_port_name(port["name"]) == want:
            return port
    return None


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

    def fits(entry):
        """1 when every requested interface gets its own physical port.

        The plan's cabling is only buildable if the hardware has a port per
        link.  A candidate that cannot host the whole device list would remap
        two names onto one port - two cables, one interface, and the second
        config block overwriting the first - so it must lose to one that can,
        even when both "cover" the names (resolve_port happily answers with a
        substitute port, which is what made coverage blind to this).
        """
        if not wanted:
            return 1
        claimed: dict[str, dict] = {}
        for spec in wanted:
            port, _note = _resolve_cached(entry, spec, claimed)
            if port is None:
                return 0
        return 1

    def score(entry):
        model = str(entry.get("model") or "").lower()
        hint = 1 if model_hint and (model == model_hint
                                    or model.startswith(model_hint)) else 0
        return (fits(entry), coverage(entry), hint,
                -len(entry.get("ports") or []))

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
        # Which of the plan's interfaces the hinted model cannot host - asked
        # with the same one-port-per-interface allocation the build will use,
        # so the reason names the interface that really forced the swap.
        miss: list[str] = []
        if hinted is not None:
            claimed: dict[str, dict] = {}
            for port in wanted:
                if _resolve_cached(hinted, port, claimed)[0] is None:
                    miss.append(port)
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


def _by_tier(names: list[str], tier: dict[str, int]) -> dict[int, list[str]]:
    """Group devices by drawing band, keeping plan order inside a band."""
    groups: dict[int, list[str]] = {}
    for name in names:
        groups.setdefault(tier[name], []).append(name)
    return groups


def layout_options(raw) -> dict:
    """The drawing a plan asks for, in the vocabulary this module speaks.

    Accepts ``layout: {"style": "wide", "columns": 6, "spacing": 1.3}`` and
    drops anything it does not understand, so a plan carrying a style this
    build never heard of still draws (as the default tree) instead of failing.
    """
    if not isinstance(raw, dict):
        return {}
    out: dict = {}
    style = str(raw.get("style") or "").strip().lower()
    if style in LAYOUT_STYLES:
        out["style"] = style
    try:
        columns = int(raw.get("columns") or 0)
    except (TypeError, ValueError):
        columns = 0
    if 1 <= columns <= 12:
        out["columns"] = columns
    try:
        spacing = float(raw.get("spacing") or 0)
    except (TypeError, ValueError):
        spacing = 0.0
    if 0.5 <= spacing <= 2.0:
        out["spacing"] = round(spacing, 2)
    side = raw.get("side")
    if isinstance(side, (list, tuple)):
        names = [str(item).strip() for item in side]
        names = [name for name in names if name][:128]
        if names:
            out["side"] = names
    edge = str(raw.get("sideEdge") or raw.get("side_edge") or "").strip().lower()
    if edge in ("left", "right"):
        out["sideEdge"] = edge
    zones = raw.get("zones")
    if isinstance(zones, (list, tuple)):
        out["zones"] = [_zone(item) for item in zones if _zone(item)]
    return out


def _zone(raw) -> dict | None:
    """One group of devices parked at one edge.

    Accepts ``{"side": ["SRV1"], "edge": "left"}`` and drops anything it
    cannot use, so a plan carrying a zone this build does not understand still
    draws.
    """
    if not isinstance(raw, dict):
        return None
    side = raw.get("side") or raw.get("sideNames") or raw.get("names")
    if not isinstance(side, (list, tuple)):
        return None
    names = [str(item).strip() for item in side]
    names = [name for name in names if name][:128]
    if not names:
        return None
    edge = str(raw.get("edge") or raw.get("sideEdge") or "").strip().lower()
    return {"side": names, "edge": edge if edge in ("left", "right") else ""}


def _resolved_positions(raw) -> dict[str, tuple[int, int]]:
    """The spot every device was already drawn at, when the plan carries one.

    Accepts ``positions: {"R1": [700, 60]}`` - the coordinates the app showed
    the user in the preview and the layout gallery - and drops anything it
    cannot use: a name that is not a pair of whole numbers, and a point that
    is nowhere near the canvas. A plan that sends nothing usable still draws,
    because the caller falls back to computing its own.
    """
    if not isinstance(raw, dict):
        return {}
    out: dict[str, tuple[int, int]] = {}
    for name, point in list(raw.items())[:4096]:
        key = str(name).strip()
        if not key or not isinstance(point, (list, tuple)) or len(point) < 2:
            continue
        try:
            x = int(round(float(point[0])))
            y = int(round(float(point[1])))
        except (TypeError, ValueError):
            continue
        if not (-10000 <= x <= 100000 and -10000 <= y <= 100000):
            continue
        out[key] = (x, y)
    return out


def layout_settings(raw=None) -> dict:
    """The options a plan asked for merged over the default drawing, so the
    report can state exactly which drawing was used."""
    options = layout_options(raw if raw is not None else {})
    style = str(options.get("style") or DEFAULT_LAYOUT["style"])
    shape = LAYOUT_STYLE_SHAPES.get(style, LAYOUT_STYLE_SHAPES["tree"])
    return {
        "style": style,
        "spacing": options.get("spacing", shape["spacing"]),
        "columns": options.get("columns", shape["columns"]),
        "side": list(options.get("side") or []),
        "sideEdge": str(options.get("sideEdge") or "left"),
        "zones": list(options.get("zones") or []),
        "positions": _resolved_positions(raw.get("positions") if isinstance(raw, dict) else None),
    }


def layout_positions(nodes: list[dict], links: list[dict] | None = None,
                     *, style: str = "", columns: int = 0,
                     spacing: float = 0.0, side: list[str] | None = None,
                     side_edge: str = "", zones: list | None = None,
                     positions: dict | None = None
                     ) -> dict[str, tuple[int, int]]:
    """A network-diagram spot on the canvas for every device in one plan.

    When ``positions`` carries the drawing the user was already shown, those
    spots win: the preview is the picture that gets built, so the `.pkt` is
    parked exactly where the app drew it instead of a second implementation of
    the same ten algorithms being trusted to agree with the first. Any device
    the resolved drawing does not name still gets a computed spot, so a partial
    or stale map degrades to the old behaviour rather than losing a device.

    The plan's link list is read as a topology, the way an engineer draws one:
    a device's parent is the neighbour one band closer to the core, so access
    switches hang under the router they uplink to, servers sit under their own
    switch, and hosts cluster in a compact block under the switch that serves
    them.  A parent is centred over its children, sibling sub-trees get their
    own columns of canvas, and a block with more hosts than fit on one row
    wraps instead of running off the edge.

    A link between two equals (two routers joined by a WAN, two switches
    trunked together) does not nest them: both stay on their own band's row,
    side by side, which is exactly how the two sites of a site-to-site lab are
    drawn.  Devices with no links at all keep their own place, by band.

    ``style``, ``columns`` and ``spacing`` choose the drawing itself (see
    LAYOUT_STYLES): a person who asks for a different layout must get a
    visibly different picture, not the same coordinates again.  Positions are
    returned by name so the caller can place each device as it builds it, and
    they are deterministic: the same plan and the same style always draw the
    same picture.

    Five of the drawings do not nest anything (`layered`, `radial`, `circle`,
    `grid`, `split`): they place every device from the plan's own shape - its
    links, or its role per device - and ignore the tree the others build.
    Those are the ones that read differently at a glance rather than the same
    picture at a different size.
    """
    settings = layout_settings({"style": style, "columns": columns,
                                "spacing": spacing,
                                "side": list(side or []),
                                "sideEdge": side_edge,
                                "zones": list(zones or [])})
    style = settings["style"]
    # Geometry is local, so one call with a style cannot change the drawing of
    # the next plan - the module constants stay the defaults of the default
    # style.
    scale = float(settings["spacing"])
    pitch = DEVICE_PITCH * scale
    gap = BLOCK_GAP * scale
    band_step = BAND_STEP * scale
    row_step = ROW_STEP * scale
    grid_columns = max(1, min(int(settings["columns"]), 12))
    tree_aware = style not in ("rows",) + LAYOUT_FLAT_STYLES

    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for node in nodes:
        name = str(node.get("name") or "").strip()
        if not name or name in seen:
            continue
        seen.add(name)
        entries.append((name, str(node.get("type") or "").strip().lower()))
    if not entries:
        return {}
    order = {name: index for index, (name, _kind) in enumerate(entries)}
    tier = {name: _tier_of(kind) for name, kind in entries}

    neighbours: dict[str, list[str]] = {name: [] for name, _kind in entries}
    for link in links or []:
        if not isinstance(link, dict):
            continue
        a = str(link.get("a") or "").strip()
        b = str(link.get("b") or "").strip()
        if a in neighbours and b in neighbours and a != b:
            neighbours[a].append(b)
            neighbours[b].append(a)

    children: dict[str, list[str]] = {name: [] for name, _kind in entries}
    roots: list[str] = []
    for name, _kind in entries:
        uphill = [other for other in neighbours[name] if tier[other] < tier[name]]
        if uphill:
            # Its uplink, not just any neighbour: the one closest to the core,
            # ties broken in plan order so the drawing is stable.
            parent = min(uphill, key=lambda other: (tier[other], order[other]))
            children[parent].append(name)
        else:
            roots.append(name)

    width: dict[str, float] = {}

    def span(name: str) -> float:
        """Canvas width this device's whole sub-tree needs."""
        if name in width:
            return width[name]
        kids = children[name]
        branches = [kid for kid in kids if children[kid]]
        leaves = [kid for kid in kids if not children[kid]]
        need = float(pitch)
        if branches:
            need = max(need, sum(span(kid) for kid in branches)
                       + gap * (len(branches) - 1))
        for group in _by_tier(leaves, tier).values():
            need = max(need, min(len(group), grid_columns) * pitch)
        width[name] = need
        return need

    bands = {value: ROW_TOP + index * band_step for index, value in enumerate(
        sorted({tier[name] for name, _kind in entries}))}
    spots: dict[str, tuple[float, float]] = {}

    def place(name: str, left: float) -> None:
        need = span(name)
        spots[name] = (left + need / 2, float(bands[tier[name]]))
        # The `rows` style is the textbook drawing: no nesting at all, every
        # device of a kind on its own row, left to right in plan order.
        if not tree_aware:
            return
        kids = children[name]
        # Sub-trees sit side by side inside this device's span; leaf children
        # (hosts, servers) form compact grids centred on the same axis, one
        # grid per band, so hosts stay visibly under their own switch.
        branches = [kid for kid in kids if children[kid]]
        if branches:
            block = sum(span(kid) for kid in branches) \
                + gap * (len(branches) - 1)
            cursor = left + (need - block) / 2
            for kid in branches:
                place(kid, cursor)
                cursor += span(kid) + gap
        for band, group in _by_tier(
                [kid for kid in kids if not children[kid]], tier).items():
            columns = min(len(group), grid_columns)
            grid = columns * pitch
            grid_left = left + (need - grid) / 2
            for index, kid in enumerate(group):
                row, column = divmod(index, columns)
                in_row = min(columns, len(group) - row * columns)
                row_left = grid_left + (grid - in_row * pitch) / 2
                spots[kid] = (
                    row_left + column * pitch + pitch / 2,
                    float(bands[band] + row * row_step),
                )

    if not tree_aware:
        # One row per kind, each device beside the last, every band centred on
        # the canvas, wrapped at ROWS_PER_ROW so a 40-PC band still fits the
        # visible workspace.
        for band, group in _by_tier([name for name, _kind in entries],
                                    tier).items():
            columns = min(len(group), max(grid_columns, ROWS_PER_ROW))
            for index, name in enumerate(group):
                row, column = divmod(index, columns)
                in_row = min(columns, len(group) - row * columns)
                row_left = X_START + max(
                    (CANVAS_WIDTH - 2 * X_START - in_row * pitch) / 2, 0)
                spots[name] = (row_left + column * pitch + pitch / 2,
                               float(bands[band] + row * row_step))
        spots = {name: spots[name] for name, _kind in entries if name in spots}

    total = sum(span(root) for root in roots) \
        + gap * max(len(roots) - 1, 0)
    cursor = X_START + max((CANVAS_WIDTH - 2 * X_START - total) / 2, 0)
    for root in roots:
        place(root, cursor)
        cursor += span(root) + gap

    # Whole-pixel spots, and never two devices on the same point.
    if style in LAYOUT_FLAT_STYLES:
        spots = _flat_positions(style, entries, tier, children, roots,
                                pitch, gap, row_step)
    elif style == "layered":
        spots = _layered_positions(entries, tier, children, roots, pitch,
                                   band_step, row_step)
    elif style == "grouped":
        spots = _grouped_positions(entries, tier, bands, spots, settings,
                                   pitch, gap, row_step)

    placed: dict[str, tuple[int, int]] = {}
    resolved = _resolved_positions(positions)
    # The drawing the user was shown wins, spot for spot. Collisions are still
    # broken (the app resolves them the same way) but never against a resolved
    # point: nudging a device the user agreed to would move the preview.
    taken: set[tuple[int, int]] = set()
    for name, (x, y) in spots.items():
        point = (int(round(x)), int(round(y)))
        if name in resolved:
            point = resolved[name]
            if point in taken:
                continue
        else:
            while point in taken:
                point = (point[0] + int(pitch), point[1])
        taken.add(point)
        placed[name] = point
    # A device the resolved drawing named but this plan does not have, or one
    # this plan has and the drawing does not, are both left out rather than
    # invented: the file is built from the plan, not from the drawing.
    return placed


def _by_role(entries: list[tuple[str, str]], tier: dict) -> list[str]:
    """Every device name, core first then outward, plan order inside a role."""
    ordered = sorted(
        (tier[name], index, name)
        for index, (name, _kind) in enumerate(entries)
    )
    return [name for _role, _index, name in ordered]


def _flat_positions(style: str, entries: list[tuple[str, str]], tier: dict,
                    children: dict, roots: list[str], pitch: float,
                    gap: float, row_step: float) -> dict[str, tuple[float, float]]:
    """The drawings that place every device from its role, not its uplink.

    Each of these ignores the tree the other styles build, which is the whole
    point: the same lab has to be readable in more than one silhouette.
    """
    by_role: dict[int, list[str]] = {}
    for name, _kind in entries:
        by_role.setdefault(tier[name], []).append(name)
    roles = sorted(by_role)
    spots: dict[str, tuple[float, float]] = {}

    if style == "grid":
        # An evenly spaced box, core first. Reads top-to-bottom like a table of
        # contents and stays inside the visible canvas no matter how many hosts
        # a plan has.
        columns = max(1, min(int(len(entries) ** 0.5 + 0.9999), 12))
        step = pitch + gap
        for index, name in enumerate(_by_role(entries, tier)):
            row, column = divmod(index, columns)
            spots[name] = (float(X_START + column * step),
                           float(ROW_TOP + row * step))
        return spots

    if style == "split":
        # One vertical column per kind of device, so a lab reads left to right
        # as core -> access -> services -> endpoints. This is the drawing that
        # makes "servers on one side, routers on the other" true by default.
        columns = max(1, min(max(len(group) for group in by_role.values()),
                             ROWS_PER_ROW))
        column_width = columns * pitch + gap
        for index, role in enumerate(roles):
            group = by_role[role]
            left = float(X_START + index * column_width)
            for row, name in enumerate(group):
                spots[name] = (left + min(len(group), columns) * pitch / 2,
                               float(ROW_TOP + row * row_step))
        return spots

    if style == "circle":
        # One ring for the whole lab, ordered so the core is together and the
        # hosts follow. An overview, not a place to read a config off.
        count = len(entries)
        radius = max(float(pitch) * (count / (2 * math.pi)) + pitch,
                     float(pitch) * 1.5)
        centre_x = CANVAS_WIDTH / 2
        centre_y = ROW_TOP + radius
        for index, name in enumerate(_by_role(entries, tier)):
            angle = -math.pi / 2 + 2 * math.pi * index / count
            spots[name] = (centre_x + radius * math.cos(angle),
                           centre_y + radius * math.sin(angle))
        return spots

    if style == "radial":
        # Concentric rings by role: the core in the middle, the endpoints on
        # the outside, so the drawing has the shape of the lab.
        radius = float(pitch) * RADIAL_FIRST_RING
        centre_x = CANVAS_WIDTH / 2
        centre_y = ROW_TOP + radius
        for index, role in enumerate(roles):
            group = by_role[role]
            ring = float(pitch) * (RADIAL_FIRST_RING
                                   + RADIAL_RING_STEP * index)
            # Each ring is drawn around the same centre, which sits far enough
            # down the page that the OUTERMOST ring still starts on the canvas.
            centre_y = ROW_TOP + radius + ring
            for position, name in enumerate(group):
                angle = -math.pi / 2 + 2 * math.pi * position / len(group)
                spots[name] = (centre_x + ring * math.cos(angle),
                               centre_y + ring * math.sin(angle))

    if style in ("circle", "radial"):
        return _keep_on_canvas(spots)

    if style == "ring":
        # Switches and endpoints interleaved around one circle; the core
        # parks in the middle. The fallback recompute of the app's ring -
        # the carried positions from the gallery are used verbatim when the
        # plan has them, so this only draws when nothing was carried.
        core = by_role.get(TIER_CORE, [])
        switches = by_role.get(TIER_ACCESS, []) + by_role.get(
            TIER_AGGREGATION, [])
        hosts = by_role.get(TIER_HOSTS, []) + by_role.get(TIER_SERVICES, [])
        ring_order: list[str] = []
        for i in range(max(len(switches), len(hosts), 1)):
            if i < len(switches):
                ring_order.append(switches[i])
            if i < len(hosts):
                ring_order.append(hosts[i])
        if not ring_order:
            ring_order = core
        count = len(ring_order)
        radius = max(float(pitch) * (count / (2 * math.pi)) + pitch,
                     float(pitch) * 1.8)
        centre_x = CANVAS_WIDTH / 2
        centre_y = ROW_TOP + radius
        for index, name in enumerate(ring_order):
            angle = -math.pi / 2 + 2 * math.pi * index / count
            spots[name] = (centre_x + radius * math.cos(angle),
                           centre_y + radius * math.sin(angle))
        for index, name in enumerate(core):
            spots[name] = (centre_x + (index - (len(core) - 1) / 2) * pitch,
                           centre_y)
        return _keep_on_canvas(spots)

    if style == "star":
        # Routers in the middle, every other tier on rays: switches at even
        # angles, each switch's hosts fanned beside its own spoke.
        core = by_role.get(TIER_CORE, [])
        switches = (by_role.get(TIER_AGGREGATION, [])
                    + by_role.get(TIER_ACCESS, []))
        hosts = by_role.get(TIER_HOSTS, []) + by_role.get(TIER_SERVICES, [])
        centre_x = CANVAS_WIDTH / 2
        centre_y = ROW_TOP + float(pitch) * 2
        per_switch = max(1, math.ceil(len(hosts) / max(1, len(switches))))
        rays = len(switches) if switches else max(1, len(hosts))
        spots.update(
            _keep_on_canvas({
                name: (centre_x + (index - (len(core) - 1) / 2) * pitch,
                       centre_y)
                for index, name in enumerate(core)
            })
        )
        for ray in range(rays):
            angle = -math.pi / 2 + 2 * math.pi * ray / rays
            if ray < len(switches):
                sx = centre_x + pitch * 1.6 * math.cos(angle)
                sy = centre_y + pitch * 1.6 * math.sin(angle)
                spots[switches[ray]] = (sx, sy)
            for offset in range(per_switch):
                host_index = ray * per_switch + offset
                if host_index >= len(hosts):
                    break
                distance = pitch * (2.6 + 0.9 * offset)
                spots[hosts[host_index]] = (
                    centre_x + distance * math.cos(angle),
                    centre_y + distance * math.sin(angle),
                )
        return _keep_on_canvas(spots)

    if style == "backbone":
        # One horizontal line of routers and switches; servers ride above
        # the line on drops, PCs below - the campus riser drawing.
        line = (by_role.get(TIER_CORE, []) + by_role.get(TIER_ACCESS, [])
                + by_role.get(TIER_AGGREGATION, []))
        above = by_role.get(TIER_SERVICES, [])
        below = by_role.get(TIER_HOSTS, [])
        pitch_count = max(1, len(line))
        line_y = ROW_TOP + float(pitch) * 1.5
        for index, name in enumerate(line):
            spots[name] = (CANVAS_WIDTH / 2
                           + (index - (pitch_count - 1) / 2) * float(pitch),
                           line_y)
        for index, name in enumerate(above):
            column = index % max(1, pitch_count)
            spots[name] = (
                CANVAS_WIDTH / 2
                + (column - (pitch_count - 1) / 2) * float(pitch),
                line_y - float(pitch) * (1 + index // max(1, pitch_count)),
            )
        for index, name in enumerate(below):
            column = index % max(1, pitch_count)
            spots[name] = (
                CANVAS_WIDTH / 2
                + (column - (pitch_count - 1) / 2) * float(pitch),
                line_y + float(pitch) * (1 + index // max(1, pitch_count)),
            )
        return _keep_on_canvas(spots)

    if style == "campus":
        # Three tiers: core on top, access in the middle, hosts at the
        # bottom, hosts column-aligned under the access switch above them.
        tiers = [
            (ROW_TOP, by_role.get(TIER_CORE, [])),
            (ROW_TOP + float(pitch) * 2,
             by_role.get(TIER_ACCESS, []) + by_role.get(TIER_AGGREGATION, [])),
            (ROW_TOP + float(pitch) * 4,
             by_role.get(TIER_HOSTS, []) + by_role.get(TIER_SERVICES, [])),
        ]
        for y, group in tiers:
            for index, name in enumerate(group):
                spots[name] = (
                    CANVAS_WIDTH / 2
                    + (index - (len(group) - 1) / 2) * float(pitch),
                    y,
                )
        return _keep_on_canvas(spots)

    raise ValueError(f"{style} is not a flat drawing")


def _keep_on_canvas(spots: dict[str, tuple[float, float]]
                    ) -> dict[str, tuple[float, float]]:
    """A drawing centred on the canvas can reach past its left edge.

    The ring layouts put devices all the way round a centre, so with enough
    roles the leftmost one lands at a negative x - which is off the visible
    workspace in Packet Tracer. Nudging the whole drawing right is the same
    picture on the canvas rather than one device lost off the side.
    """
    if not spots:
        return spots
    min_x = min(x for x, _ in spots.values())
    if min_x < X_START:
        shift = X_START - min_x
        for name, (x, y) in spots.items():
            spots[name] = (x + shift, y)
    return spots


def _layered_positions(entries: list[tuple[str, str]], tier: dict,
                       children: dict, roots: list[str], pitch: float,
                       band_step: float, row_step: float
                       ) -> dict[str, tuple[float, float]]:
    """The industry hierarchical drawing, read left to right.

    Ranks come from the links, so a device sits in the column of how far it is
    from a root; devices inside a rank are ordered by a breadth-first walk so
    a child stays beside the parent it hangs from and the cables stop
    crossing. This is `rows` turned on its side, and it follows the topology
    where `split` follows the role - the two disagree exactly when a lab has
    more than one layer of the same kind of device.
    """
    depth: dict[str, int] = {}
    # Rank is computed DOWN from the roots, because a leaf cannot know how far
    # it is from the top: ranking from the leaves gives every leaf rank 0, the
    # same column as the router it hangs from. Each device takes one column
    # more than its furthest parent, so a node reached twice by two paths keeps
    # the deeper of the two.
    queue: list[str] = []
    for name in roots:
        if name not in depth:
            depth[name] = 0
            queue.append(name)
    while queue:
        name = queue.pop(0)
        if name not in depth:
            depth[name] = 0
        rank = depth[name] + 1
        for kid in children[name]:
            if depth.get(kid, -1) < rank:
                depth[kid] = rank
                if kid not in queue:
                    queue.append(kid)

    order: list[str] = []
    seen: set[str] = set()
    queue = list(roots)
    while queue:
        name = queue.pop(0)
        if name in seen or name not in depth:
            continue
        seen.add(name)
        order.append(name)
        queue.extend(children[name])
    for name, _kind in entries:
        if name not in seen:
            order.append(name)

    ranks: dict[int, list[str]] = {}
    for name in order:
        ranks.setdefault(depth[name], []).append(name)

    spots: dict[str, tuple[float, float]] = {}
    for index in sorted(ranks):
        for row, name in enumerate(ranks[index]):
            spots[name] = (float(X_START + index * band_step),
                           float(ROW_TOP + row * row_step))
    return spots


def _grouped_positions(entries: list[tuple[str, str]], tier: dict,
                       bands: dict, spots: dict, settings: dict, pitch: float,
                       gap: float, row_step: float
                       ) -> dict[str, tuple[float, float]]:
    """Park the named devices in columns at the edges they were sent to.

    A `zones` list is the multi-group form the app sends for "the servers on
    one side and the routers on the other": one column per zone, in the order
    the request listed them, each at its own edge. A single `side` list with no
    zones is the one-group form and behaves exactly as it always did.
    """
    zones = [zone for zone in settings.get("zones") or []
             if isinstance(zone, dict) and zone.get("side")]
    if not zones and settings.get("side"):
        zones = [{"side": list(settings["side"]),
                  "edge": str(settings.get("sideEdge") or "")}]

    parked: list[dict] = []
    claimed: set[str] = set()
    for zone in zones:
        names = [name for name in zone.get("side") or [] if name in spots]
        names = [name for name in names if name not in claimed]
        if not names or len(names) == len(spots):
            continue
        claimed.update(names)
        parked.append({"names": names, "edge": str(zone.get("edge") or "")})
    if not parked:
        return spots

    left_zones = [zone for zone in parked if zone["edge"] != "right"]
    right_zones = [zone for zone in parked if zone["edge"] == "right"]
    shift = gap + pitch
    rest = [name for name in spots if name not in claimed]

    # The left columns start at the canvas edge and the rest of the lab moves
    # right to clear them, so nothing is ever placed off-canvas.
    for index, zone in enumerate(left_zones):
        zone["x"] = float(X_START + index * shift)
    if left_zones:
        for name in rest:
            spots[name] = (spots[name][0] + shift * len(left_zones),
                           spots[name][1])

    edge = max((spots[name][0] for name in rest), default=float(X_START))
    for index, zone in enumerate(right_zones):
        zone["x"] = float(edge + (index + 1) * shift)

    for zone in parked:
        row_in_band: dict[int, int] = {}
        for name in zone["names"]:
            band = tier[name]
            row = row_in_band.get(band, 0)
            row_in_band[band] = row + 1
            spots[name] = (zone["x"], float(bands[band] + row * row_step))
    return spots


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
            # A dot1Q sub-interface (router-on-a-stick: `g0/0.10`) rides on
            # its parent's hardware, so it must not claim a port of its own.
            if _SUBINTERFACE.match(match.group(1)):
                continue
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

# A dot1Q sub-interface: `<parent-port>.<vlan>` (router-on-a-stick).  The
# parent is the hardware; the suffix is config on it.
_SUBINTERFACE = re.compile(r"^(\S+)\.(\d+)$")


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
        sub = re.match(r"^interface\s+(\S+?)\.(\d+)\s*$", line, re.I)
        if sub:
            # Sub-interface: rewrite only the parent to the port this model
            # really has (`g0/0.10` on a 2811 is `FastEthernet0/0.10`) and
            # keep the VLAN suffix.  The parent resolution is shared with
            # the links, so the trunk and the sub-interfaces land on the
            # same physical port.
            base = sub.group(1)
            if not _VIRTUAL_INTERFACES.match(base):
                port, _note = _resolve_cached(variant, base, resolved)
                if port:
                    line = f"interface {port['name']}.{sub.group(2)}"
            out.append(line)
            continue
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
    # Every device's canvas spot, decided once for the whole plan from its own
    # topology, so each site is drawn as a tree instead of one endless row.
    # `layout` (see LAYOUT_STYLES) is what a person's "redraw this, spread it
    # out" turns into - the drawing is an input, so asking for a different one
    # produces a different file instead of the same coordinates again.
    layout = layout_settings(plan.get("layout"))
    positions = layout_positions(nodes, sections["links"],
                                 positions=layout.get("positions"),
                                 style=layout["style"],
                                 columns=layout["columns"],
                                 spacing=layout["spacing"],
                                 side=layout["side"],
                                 side_edge=layout["sideEdge"],
                                 zones=layout["zones"])

    for node in nodes:
        name = str(node["name"])
        # The device report carries the plan's own kind for every device (the
        # audit and the "does the file match the plan" check read it back), so
        # it is normalized exactly as select_variant normalizes it.
        node_type = str(node.get("type") or "").strip().lower()
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
        x, y = positions.get(name, (X_START, DEFAULT_ROW_Y))
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
        # Reserve the ports this model really has BEFORE anything is remapped.
        # A plan names both the ports its hardware has ('g0/1') and ports it
        # invented to keep a chain apart ('g1/0' on a machine whose slots stop
        # at 0/2).  Reserving the real names first means the invented one takes
        # what is left, instead of stealing the port a real name needs - the
        # exact-name lookup in resolve_port is what let both land on Gi0/1.
        for spec in wanted.get(name, []):
            exact = exact_port(variant, spec)
            if exact is not None:
                resolved_ports.setdefault(normalize_port_name(spec), exact)
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
        by_name = {normalize_port_name(port.get("name")): port
                   for port in variant.get("ports") or [] if port.get("name")}
        for ifname, sub in _interface_blocks(config_lines).items():
            # A dot1Q sub-interface resolves to its parent's port; its own
            # address must NOT be mirrored onto that physical port (the
            # parent is a trunk - the address lives in PT's sub-interface
            # config text, which the saved <LINE> list already carries).
            if _SUBINTERFACE.match(ifname):
                continue
            # The config was already rewritten to the model's own port names
            # above, so this is a plain lookup - asking the allocator again
            # would look like a second interface trying to take a port that
            # is (correctly) already spoken for.
            port = by_name.get(normalize_port_name(ifname))
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

    # ONE INTERFACE, ONE CABLE.  A plan may name the same port twice (the
    # validator reports that), but the generator must never *create* it: two
    # <LINK> records on one port is what Packet Tracer refuses to load, and
    # the second `interface` block in the config silently overwrites the
    # first, which is how a whole transit subnet and its OSPF network went
    # missing while the file still looked complete.  Report it rather than
    # ship it quietly.
    cable_count: dict[tuple, int] = {}
    for link in link_report:
        for side in ("a", "b"):
            device = str(link.get(side) or "")
            port = str(link.get(f"{side}If") or "")
            if device and port:
                cable_count[(device, port)] = cable_count.get(
                    (device, port), 0) + 1
    for (device, port), count in sorted(cable_count.items()):
        if count > 1:
            warnings.append(
                f"{device}: {port} is cabled {count} times - one interface "
                "cannot carry two cables, so only one of them can work")

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
        # Which drawing was used, so the app can tell the user what changed
        # instead of asserting that something did.
        "layout": layout,
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


def _backup_existing(target: str) -> str:
    """Copy the file about to be replaced aside; return the copy's path.

    The name carries a timestamp so repeated edits keep every generation, and
    a second in the same second never overwrites the first backup.
    """
    stem, ext = os.path.splitext(target)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    candidate = f"{stem}.backup-{stamp}{ext or '.pkt'}"
    n = 2
    while os.path.exists(candidate):
        candidate = f"{stem}.backup-{stamp}-{n}{ext or '.pkt'}"
        n += 1
    shutil.copy2(target, candidate)
    return candidate


def generate_pkt_file(plan: dict, out_path: str, *, project: str = "",
                      library: dict | None = None, version: str = "",
                      replace: bool = False, backup: bool = True,
                      log=None) -> dict:
    """Build the topology and write it as a .pkt.  Returns the report."""
    say = log or (lambda *_: None)
    target = os.path.abspath(os.path.expanduser(str(out_path or "").strip()))
    if not target.lower().endswith(".pkt"):
        raise BuildError("the output path must end in .pkt")
    if os.path.exists(target) and not replace:
        raise FileExistsError(f"refusing to overwrite an existing file: "
                              f"{target}")
    # Editing a project in place must never cost the user the file they had.
    # The replaced build is copied aside first and its name is reported, so an
    # in-place edit is reversible without a separate backup habit.
    backup_path = ""
    if replace and backup and os.path.exists(target):
        backup_path = _backup_existing(target)
        if backup_path:
            say(f"kept the previous build as {backup_path}")
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
        # The drawing this file was actually written with, so the app can
        # remember it and the next build keeps it.  Dropping it here is what
        # made a chosen layout silently revert to the default one: the app
        # asked for it, the engine honoured it, and then the answer said
        # nothing about what had been used.
        "layout": built["layout"],
        "encodeMs": round(elapsed * 1000, 1),
        "authority": "NetBuilder offline generator",
        "binaryAuthority": "NetBuilder pkt_codec (verified container format)",
    }
    if backup_path:
        report["backupPath"] = backup_path
        report["backupName"] = os.path.basename(backup_path)
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
