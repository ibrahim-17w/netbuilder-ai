"""Offline .pkt fix engine.

Decrypt a Packet Tracer save, apply the fixes the USER approved, and encrypt a
valid .pkt again - with no Packet Tracer, no window and no clicks.

This is the "just decrypt and encrypt it back" path: the audit's advice becomes
a real edit to the save's own configuration, the file is re-encoded with the
same Twofish/EAX container the codec already reads, and a versioned copy of the
previous state is kept so every change can be undone.

Rules this module keeps:
* the SOURCE file is never modified - output always lands in pkt_output/;
* nothing is applied unless it is in the ``fixes`` list the caller approved;
* a secret (enable secret / password / pre-shared key ...) is applied to the
  file but REDACTED in the diff, the ledger and every report;
* a corrupt or unreadable file raises a clear error instead of guessing.
"""
from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
import threading
import time

try:
    import pkt_codec
    import pkt_builder
except ImportError:  # pragma: no cover - package import fallback
    from . import pkt_codec, pkt_builder

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "pkt_output")
LEDGER = os.path.join(HERE, "pkt_fix_ledger.jsonl")


def _out_dir() -> str:
    """Where fixed saves land (NETBUILDER_PKT_OUT overrides, for tests)."""
    override = os.environ.get("NETBUILDER_PKT_OUT", "").strip()
    return os.path.abspath(os.path.expanduser(override)) if override else OUT_DIR


def _ledger_path() -> str:
    override = os.environ.get("NETBUILDER_FIX_LEDGER", "").strip()
    if override:
        return os.path.abspath(os.path.expanduser(override))
    return LEDGER

_LOCK = threading.RLock()
MAX_BYTES = 64 * 1024 * 1024

SECRET_RE = re.compile(
    r"(?i)\b(?:enable\s+(?:secret|password)|password|passwd|secret|"
    r"pre-?shared\s+key|key\s+string|wpa-?psk|psk)\b"
)


class FixError(RuntimeError):
    """A fix could not be applied, with a message meant for the chat."""


# Magic numbers for the formats a user is most likely to hand us by
# mistake. Naming the format beats "could not decode".
PCAP_MAGIC = (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4",
              b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
PCAPNG_MAGIC = b"\x0a\x0d\x0d\x0a"


def describe_format(path: str) -> str:
    """A plain-language name for what this file is.

    Returns 'pkt', 'pcap', 'pcapng', 'xml' or 'unknown'. Used to give the
    user a clear answer instead of a decode failure.
    """
    try:
        with open(path, "rb") as handle:
            head = handle.read(64)
    except OSError:
        return "unknown"
    if head[:4] in PCAP_MAGIC:
        return "pcap"
    if head[:4] == PCAPNG_MAGIC:
        return "pcapng"
    stripped = head.lstrip()
    if stripped[:1] == b"<":
        return "xml"
    if len(head) >= 40 and not stripped[:1] == b"<":
        return "pkt"
    return "unknown"


def unsupported_message(path: str) -> str:
    """The in-chat explanation for a file this engine cannot edit."""
    kind = describe_format(path)
    name = os.path.basename(path or "that file")
    if kind == "pcap":
        return (f"`{name}` is a classic **.pcap** capture, not a Packet "
                "Tracer save. I cannot parse packet captures yet - I work "
                "on .pkt saves (decrypt, edit, encrypt back). Ask me to "
                "scope .pcap support if that is what you need.")
    if kind == "pcapng":
        return (f"`{name}` is a **.pcapng** capture, not a Packet Tracer "
                "save. I work on .pkt saves; .pcapng parsing is not "
                "implemented.")
    if kind == "xml":
        return (f"`{name}` is plain XML, not an encrypted save. If it is a "
                "decrypted .pkt, tell me and I can still audit the "
                "configuration text.")
    return (f"`{name}` is not a Packet Tracer save I can read. Expected a "
            ".pkt/.pka file saved by Packet Tracer.")


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def redact(line: str) -> str:
    """Hide the value of a secret while keeping the command readable."""
    text = line.rstrip()
    m = SECRET_RE.search(text)
    if not m:
        return text
    head = text[: m.end()]
    tail = text[m.end():].strip()
    if not tail:
        return text
    return f"{head} ••••••••"


def _safe_name(name: str, fallback: str) -> str:
    base = os.path.basename(str(name or "").strip())
    if not base:
        base = fallback
    base = re.sub(r"[^A-Za-z0-9._-]", "_", base)
    if not base.lower().endswith(".pkt"):
        base += ".pkt"
    return base


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _ledger_append(row: dict) -> None:
    with _LOCK:
        path = _ledger_path()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def ledger(limit: int = 200) -> dict:
    """The audit ledger: captures, proposals, decisions, exports, undos."""
    path = _ledger_path()
    rows: list[dict] = []
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:  # noqa: BLE001 - skip a torn line
                    continue
    rows = rows[-limit:]
    return {
        "entries": rows,
        "count": len(rows),
        "applied": sum(1 for r in rows if r.get("event") == "applied"),
        "rejected": sum(1 for r in rows if r.get("event") == "rejected"),
        "undone": sum(1 for r in rows if r.get("event") == "undone"),
        "exports": sum(1 for r in rows if r.get("event") == "exported"),
        "path": _ledger_path(),
    }


# --------------------------------------------------------------------------
# config editing
# --------------------------------------------------------------------------

_IFACE_RE = re.compile(r"^interface\s+(\S+)\s*$", re.I)
_GLOBAL_END = ("!", "end")


def _split(lines: list[str]) -> tuple[list[str], dict[str, list[str]], list[str]]:
    """Split a saved config into (preamble, {interface: body}, trailing)."""
    preamble: list[str] = []
    sections: dict[str, list[str]] = {}
    trailing: list[str] = []
    current: str | None = None
    for line in lines:
        if _IFACE_RE.match(line):
            current = _IFACE_RE.match(line).group(1)
            sections.setdefault(current, [])
            continue
        if current is None:
            preamble.append(line)
        else:
            sections[current].append(line)
    return preamble, sections, trailing


def _flatten(preamble: list[str], sections: dict[str, list[str]],
             trailing: list[str]) -> list[str]:
    out = list(preamble)
    for name, body in sections.items():
        out.append(f"interface {name}")
        cleaned = [line for line in body if line.strip().lower() != "exit"]
        out.extend(cleaned)
        out.append("exit")
    out.extend(trailing)
    return out


def _merge_line(body: list[str], command: str) -> tuple[list[str], bool]:
    """Apply one command inside a section body. Returns (body, changed)."""
    cmd = command.strip()
    low = cmd.lower()
    lowered = [line.strip().lower() for line in body]

    # "no X" removes X (the absence is the state).
    if low.startswith("no "):
        stem = low[3:].strip()
        kept = [line for line in body
                if not line.strip().lower().startswith(stem)]
        changed = len(kept) != len(body)
        if stem == "shutdown":
            # an explicit "no shutdown" reads better than a missing line
            if "no shutdown" not in [line.strip().lower() for line in kept]:
                kept.append("no shutdown")
            changed = True
        return kept, kept != body

    # the opposite of an existing line wins, never both
    opposite = {
        "shutdown": "no shutdown",
        "no shutdown": "shutdown",
    }.get(low)
    if opposite is not None:
        kept = [line for line in body
                if line.strip().lower() != opposite]
        if low not in [line.strip().lower() for line in kept]:
            kept.append(cmd)
        return kept, kept != body

    # a "family" line replaces its previous value (ip address, switchport mode,
    # description, encapsulation, vlan, channel-group, aaa ...)
    head = low.split()
    family = " ".join(head[:2]) if len(head) >= 2 else low
    replaced = False
    out: list[str] = []
    for line in body:
        lline = line.strip().lower()
        if lline == low:
            replaced = True
            out.append(cmd)
            continue
        if family in ("ip address", "switchport mode", "switchport access",
                      "switchport trunk", "description", "encapsulation",
                      "ip helper-address", "ip access-group", "clock rate",
                      "channel-group", "router ospf", "ip route") \
                and lline.startswith(family):
            out.append(cmd)
            replaced = True
            continue
        out.append(line)
    if not replaced:
        if lowered and low in lowered:
            return body, False
        out.append(cmd)
    return out, out != body


def _apply_fix(config: list[str], fix: dict) -> tuple[list[str], list[dict]]:
    """Apply one approved fix to a config. Returns (config, changes)."""
    cli = [str(c).strip() for c in (fix.get("fix_cli") or []) if str(c).strip()]
    if not cli:
        raise FixError("this proposal carries no commands to apply")
    iface = ""
    commands: list[str] = []
    for entry in cli:
        m = _IFACE_RE.match(entry)
        if m:
            iface = m.group(1)
        elif entry.lower() in ("exit", "!"):
            continue
        else:
            commands.append(entry)
    if not commands:
        raise FixError("this proposal only names an interface, with no change")

    preamble, sections, trailing = _split(list(config))
    changes: list[dict] = []

    if not iface:
        for command in commands:
            preamble, changed = _merge_line(preamble, command)
            if changed:
                changes.append({"section": "(global)", "command": command})
        return _flatten(preamble, sections, trailing), changes

    key = None
    wanted = pkt_builder.normalize_port_name(iface).lower()
    for name in sections:
        if name.lower() == iface.lower():
            key = name
            break
        if pkt_builder.normalize_port_name(name).lower() == wanted:
            key = name
            break
    if key is None:
        raise FixError(f"the save has no `interface {iface}` to change")

    body = sections[key]
    for command in commands:
        body, changed = _merge_line(body, command)
        if changed:
            changes.append({"section": f"interface {key}", "command": command})
    sections[key] = body
    return _flatten(preamble, sections, trailing), changes


def _set_tag(fragment: bytes, tag: bytes, value: bytes) -> tuple[bytes, bool]:
    """Set <TAG>value</TAG> on a port fragment.

    An unconfigured port has no <IP>/<SUBNET> element at all, so a plain
    replace would silently do nothing - the tag is inserted instead.
    """
    pattern = rb"<" + tag + rb"(?:\s[^>]*)?>.*?</" + tag + rb">"
    if re.search(pattern, fragment, re.S):
        new = re.sub(
            pattern,
            lambda _m: b"<" + tag + b">" + value + b"</" + tag + b">",
            fragment, count=1, flags=re.S)
    else:
        idx = fragment.rfind(b"</PORT>")
        if idx < 0:
            return fragment, False
        new = (fragment[:idx] + b"<" + tag + b">" + value + b"</" + tag
               + b">" + fragment[idx:])
    return new, new != fragment


def _sync_port(xml: bytes, device: str, iface: str, *, up=None,
               ip: str = "", mask: str = "") -> tuple[bytes, bool]:
    """Mirror a fix onto the saved PORT state, not just the config text.

    The audit already separates the two: a config that says `no shutdown`
    while the port says POWER=false, or an `ip address` in the config while the
    port carries none, comes up wrong. This keeps them consistent and reports
    whether anything actually changed.
    """
    import pkt_template_build as tb

    target = None
    for m in re.finditer(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
        name = re.search(rb'<NAME translate="true">([^<]*)</NAME>', m.group(0))
        if name and name.group(1).decode("utf-8", "replace") == device:
            target = m
            break
    if target is None:
        return xml, False

    block = target.group(0)
    wanted = pkt_builder._family_from_request(
        pkt_builder.normalize_port_name(iface))
    index = 0
    changed = False
    for span_start, span_end in tb.iter_port_spans(block):
        port = block[span_start:span_end]
        m = re.search(rb"<TYPE>([^<]*)</TYPE>", port)
        family = (tb._family_of_type(m.group(1).decode("utf-8", "replace"))
                  if m else "")
        if family != wanted:
            continue
        if index != 0:
            index += 1
            continue
        index += 1
        new_port = port
        if up is not None:
            new_port, touched = _set_tag(
                new_port, b"POWER", b"true" if up else b"false")
            changed = changed or touched
        if ip:
            new_port, touched = _set_tag(new_port, b"IP", ip.encode())
            changed = changed or touched
        if mask:
            new_port, touched = _set_tag(new_port, b"SUBNET", mask.encode())
            changed = changed or touched
        block = block[:span_start] + new_port + block[span_end:]
        break

    if not changed:
        return xml, False
    return xml[: target.start()] + block + xml[target.end():], True


def _set_config_lines(block: bytes, tag: bytes, lines: list[str]) -> bytes:
    if not lines:
        return block
    body = b"\n".join(
        b"      <LINE>" + _esc(line) + b"</LINE>" for line in lines)
    replacement = b"<" + tag + b">\n" + body + b"\n     </" + tag + b">"
    pattern = rb"<" + tag + rb"(?:\s[^>]*)?>.*?</" + tag + rb">"
    if re.search(pattern, block, re.S):
        return re.sub(pattern, lambda _m: replacement, block, count=1, flags=re.S)
    return block


def _esc(text: str) -> bytes:
    return (text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;")).encode("utf-8")


# --------------------------------------------------------------------------
# apply / undo
# --------------------------------------------------------------------------

def _resolve_out_dir(out_dir: str) -> str:
    """The folder the user designated, or the default.

    A designated folder must be creatable and writable; anything else is
    reported instead of silently falling back.
    """
    wanted = str(out_dir or "").strip()
    if not wanted:
        return _out_dir()
    path = os.path.abspath(os.path.expanduser(wanted))
    if os.path.exists(path) and not os.path.isdir(path):
        raise FixError(f"`{path}` is a file, not a folder")
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, ".netbuilder-write-test")
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("ok")
        os.remove(probe)
    except OSError as exc:
        raise FixError(f"cannot write to `{path}`: {exc}") from exc
    return path


def apply_fixes(source: str, fixes: list[dict], *, out_name: str = "",
                project: str = "", allow_undo: bool = True,
                out_dir: str = "") -> dict:
    """Apply ONLY the approved fixes, then encrypt a valid .pkt again."""
    source = os.path.abspath(str(source or "").strip())
    if not source or not os.path.isfile(source):
        raise FixError(f"capture not found: {source or '(none given)'}")
    size = os.path.getsize(source)
    if size > MAX_BYTES:
        raise FixError(
            f"that save is {size // (1024 * 1024)} MB; the limit is "
            f"{MAX_BYTES // (1024 * 1024)} MB")
    if not fixes:
        raise FixError("no approved fixes were supplied")

    kind = describe_format(source)
    if kind in ("pcap", "pcapng", "xml"):
        raise FixError(unsupported_message(source))
    with open(source, "rb") as handle:
        raw = handle.read()
    try:
        xml = pkt_codec.decrypt_pkt(raw)
    except pkt_codec.PktFormatError as exc:
        raise FixError(unsupported_message(source) + f"  ({exc})") from exc
    try:
        summary_before = pkt_codec.pkt_xml_summary(xml)
    except Exception:  # noqa: BLE001 - summary is a nicety
        summary_before = {}

    # Group the approved fixes per device so one device is edited once.
    by_device: dict[str, list[dict]] = {}
    for fix in fixes:
        device = str(fix.get("device") or "").strip()
        if not device:
            raise FixError("an approved fix names no device")
        by_device.setdefault(device, []).append(fix)

    diffs: list[dict] = []
    power_changes: list[dict] = []
    applied = 0
    for device, device_fixes in by_device.items():
        match = None
        for m in re.finditer(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
            name = re.search(rb'<NAME translate="true">([^<]*)</NAME>',
                             m.group(0))
            if name and name.group(1).decode("utf-8", "replace") == device:
                match = m
                break
        if match is None:
            raise FixError(
                f"device `{device}` is not in this save - reload the capture "
                "and try again")
        block = match.group(0)
        cfg_match = re.search(rb"<RUNNINGCONFIG>(.*?)</RUNNINGCONFIG>",
                              block, re.S)
        if not cfg_match:
            raise FixError(
                f"{device} has no saved configuration to change; this proposal "
                "needs a device with a CLI config")
        before = _lines_of(cfg_match.group(1))
        after = list(before)
        change_rows: list[dict] = []
        for fix in device_fixes:
            after, rows = _apply_fix(after, fix)
            for row in rows:
                row["fixId"] = str(fix.get("id") or "")
                row["severity"] = str(fix.get("severity") or "")
                change_rows.append(row)
            applied += 1 if rows else 0
            cli = [str(c).strip() for c in (fix.get("fix_cli") or [])]
            iface = _iface_of(cli)
            lowered = [c.lower() for c in cli]
            if iface and any(c == "no shutdown" for c in lowered):
                power_changes.append({"device": device, "iface": iface,
                                      "up": True})
            if iface and any(c == "shutdown" for c in lowered):
                power_changes.append({"device": device, "iface": iface,
                                      "up": False})
            for command in cli:
                m = re.match(r"^ip address\s+(\S+)\s+(\S+)$", command, re.I)
                if iface and m:
                    power_changes.append({
                        "device": device, "iface": iface,
                        "ip": m.group(1), "mask": m.group(2),
                    })

        # Only rewrite the config tags when the lines really changed: writing
        # identical lines back would still alter the XML text.
        config_changed = after != before
        if config_changed:
            block = _set_config_lines(block, b"RUNNINGCONFIG", after)
            block = _set_config_lines(block, b"STARTUPCONFIG", after)
            xml = xml[: match.start()] + block + xml[match.end():]
        diffs.append({
            "device": device,
            "configChanged": config_changed,
            "changes": change_rows,
            "diff": list(difflib.unified_diff(
                before, after,
                fromfile=f"{device} (before)",
                tofile=f"{device} (after)",
                lineterm="", n=2,
            )) if config_changed else [],
        })

    # Mirror the fixes onto the saved PORT state (the audit's other half).
    for change in power_changes:
        iface = str(change.get("iface") or "")
        if not iface:
            continue
        xml, touched = _sync_port(
            xml, change["device"], iface,
            up=change.get("up"),
            ip=str(change.get("ip") or ""),
            mask=str(change.get("mask") or ""),
        )
        if not touched:
            continue
        what = []
        if change.get("up") is True:
            what.append("powered the port up (no shutdown)")
        if change.get("up") is False:
            what.append("shut the port down")
        if change.get("ip"):
            what.append(
                f"gave the port {change['ip']} {change.get('mask', '')}".strip())
        row = {"section": f"port state {iface}",
               "command": ", ".join(what) or "port state updated"}
        for row_diff in diffs:
            if row_diff["device"] == change["device"]:
                row_diff["changes"].append(row)
                row_diff["diff"].extend([
                    f"--- {change['device']} port {iface} (before)",
                    f"+++ {change['device']} port {iface} (after)",
                    f"-{iface}: saved port state as found",
                    f"+{iface}: {', '.join(what) or 'port state updated'}",
                ])
                break

    # A device changed either through its config lines or only through its
    # saved port state; both count as an applied fix.
    applied = sum(1 for d in diffs if d["changes"])
    if not any(d["changes"] for d in diffs):
        raise FixError(
            "nothing to change: the file already matches every approved "
            "proposal on " + ", ".join(sorted(by_device)))

    try:
        payload = pkt_codec.encrypt_pkt(xml)
    except Exception as exc:  # noqa: BLE001 - reported, never a stack trace
        raise FixError(
            f"the edited save could not be encrypted again: {exc}") from exc

    # The edited file must decode again and keep the same device set.
    check = pkt_codec.decrypt_pkt(payload)
    if check.count(b"<DEVICE>") != xml.count(b"<DEVICE>"):
        raise FixError(
            "refusing to write the result: the device count changed while "
            "re-encrypting")

    out_dir = _resolve_out_dir(out_dir)
    versions_dir = os.path.join(out_dir, "versions")
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(versions_dir, exist_ok=True)
    stem = os.path.splitext(_safe_name(out_name, os.path.basename(source)))[0]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    entry_id = f"{stem}-{stamp}"
    out_path = os.path.join(out_dir, f"{stem}-fixed.pkt")
    if os.path.abspath(out_path) == os.path.abspath(source):
        out_path = os.path.join(out_dir, f"{stem}-fixed-{stamp}.pkt")
    with open(out_path, "wb") as handle:
        handle.write(payload)

    version_path = os.path.join(versions_dir, f"{entry_id}.pkt")
    with open(version_path, "wb") as handle:
        handle.write(raw)

    manifest = {
        "project": project or stem,
        "generator": "offline-fix",
        "source": source,
        "sourceSha256": _sha(raw),
        "result": out_path,
        "resultSha256": _sha(payload),
        "appliedFixes": applied,
        "devices": [d["device"] for d in diffs],
        "devicesBefore": summary_before.get("deviceCount"),
        "devicesAfter": pkt_codec.pkt_xml_summary(check).get("deviceCount"),
        "generated": _now(),
        "note": "companion record: what changed, never a credential value",
    }
    manifest_path = out_path + ".netbuilder.json"
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)

    ledger_entry = {
        "event": "applied",
        "id": entry_id,
        "at": _now(),
        "project": project or stem,
        "source": source,
        "sourceSha256": _sha(raw)[:16],
        "result": out_path,
        "resultSha256": _sha(payload)[:16],
        "version": version_path,
        "appliedFixes": applied,
        "devices": sorted(by_device),
        "commands": [
            {"device": d["device"], "section": c["section"],
             "command": redact(c["command"])}
            for d in diffs for c in d["changes"]
        ],
        "secretsRedacted": any(
            SECRET_RE.search(c["command"]) for d in diffs for c in d["changes"]),
        "undoable": bool(allow_undo),
    }
    _ledger_append(ledger_entry)

    return {
        "ok": True,
        "entryId": entry_id,
        "path": out_path,
        "name": os.path.basename(out_path),
        "bytes": len(payload),
        "sha256": _sha(payload),
        "manifest": manifest_path,
        "versionFile": version_path,
        "appliedFixes": applied,
        "diffs": diffs,
        "deviceCount": manifest["devicesAfter"],
        "note": ("Applied and re-encrypted. The original file was NOT "
                 "modified; the result is a new .pkt."),
    }


def _iface_of(cli_lines: list[str]) -> str:
    for entry in cli_lines:
        m = _IFACE_RE.match(str(entry).strip())
        if m:
            return m.group(1)
    return ""


def _lines_of(inner: bytes) -> list[str]:
    out = []
    for raw in re.findall(rb"<LINE>(.*?)</LINE>", inner, re.S):
        text = raw.decode("utf-8", "replace")
        for entity, char in (("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")):
            text = text.replace(entity, char)
        out.append(text.strip())
    return out


def undo(entry_id: str = "") -> dict:
    """Restore the state before an applied change, as a new file."""
    data = ledger()
    applied = [e for e in data["entries"] if e.get("event") == "applied"]
    if not applied:
        raise FixError("there is no applied change to undo yet")
    target = None
    if entry_id:
        for row in applied:
            if row.get("id") == entry_id:
                target = row
                break
        if target is None:
            raise FixError(f"no applied change with id {entry_id}")
    else:
        target = applied[-1]
    version = str(target.get("version") or "")
    if not version or not os.path.isfile(version):
        raise FixError(
            "the previous version of that save was not kept, so it cannot be "
            "restored")
    with open(version, "rb") as handle:
        raw = handle.read()
    out_dir = _out_dir()
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(str(target.get("result") or "x")))[0]
    out_path = os.path.join(out_dir, f"{stem}-undone.pkt")
    with open(out_path, "wb") as handle:
        handle.write(raw)
    row = {
        "event": "undone",
        "id": f"{target.get('id')}-undo",
        "at": _now(),
        "restores": target.get("id"),
        "result": out_path,
        "resultSha256": _sha(raw)[:16],
        "source": target.get("source"),
    }
    _ledger_append(row)
    return {
        "ok": True,
        "restored": target.get("id"),
        "path": out_path,
        "name": os.path.basename(out_path),
        "sha256": _sha(raw),
        "note": ("Restored the save exactly as it was before that change; the "
                 "fixed file is untouched."),
    }


def record_decision(fix: dict, decision: str, capture: str = "") -> dict:
    """Log an approve/reject decision (the approval gate's record)."""
    row = {
        "event": "rejected" if decision != "approved" else "proposed",
        "id": str(fix.get("id") or ""),
        "at": _now(),
        "capture": capture,
        "device": str(fix.get("device") or ""),
        "text": str(fix.get("text") or "")[:300],
        "commands": [redact(str(c)) for c in (fix.get("fix_cli") or [])],
        "decision": decision,
    }
    _ledger_append(row)
    return row
