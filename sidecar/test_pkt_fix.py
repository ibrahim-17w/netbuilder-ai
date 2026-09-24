"""Offline .pkt fix engine: decrypt, apply approved fixes, re-encrypt, undo.

These run against the real .pkt files already in pkt_output/ - a real save, a
real decrypt, a real re-encrypt - with the output and ledger redirected into
tmp so the repository is never touched.
"""
from __future__ import annotations

import hashlib
import json
import os

import pytest

import pkt_codec
import pkt_fix

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(HERE, "pkt_output")


def _sha(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def _fixtures() -> list[str]:
    if not os.path.isdir(FIXTURE_DIR):
        return []
    return [
        os.path.join(FIXTURE_DIR, name)
        for name in sorted(os.listdir(FIXTURE_DIR))
        if name.endswith(".pkt") and os.path.isfile(os.path.join(FIXTURE_DIR, name))
    ]


def _first_fixable() -> tuple[str, dict, str]:
    """A real capture + a real audit finding that carries fix_cli."""
    import pt_autopilot as pt

    for path in _fixtures():
        try:
            report = pt.pkt_audit_network(path, project="fixtest")
        except Exception:  # noqa: BLE001 - not every file is auditable
            continue
        for device in report.get("devices", []):
            for finding in device.get("findings", []):
                if finding.get("fix_cli"):
                    return path, {
                        "id": f"fix-{finding.get('id')}",
                        "device": device.get("name"),
                        "fix_cli": list(finding["fix_cli"]),
                        "severity": finding.get("severity", ""),
                        "text": finding.get("text", ""),
                    }, device.get("name") or ""
    return "", {}, ""


def test_apply_approved_fix_roundtrip(tmp_path, monkeypatch):
    path, fix, device = _first_fixable()
    if not path:
        pytest.skip("no auditable .pkt fixture with a fixable finding")

    monkeypatch.setenv("NETBUILDER_PKT_OUT", str(tmp_path / "out"))
    monkeypatch.setenv("NETBUILDER_FIX_LEDGER", str(tmp_path / "ledger.jsonl"))

    before = _sha(path)
    source_xml = pkt_codec.decrypt_pkt(open(path, "rb").read())
    devices_before = source_xml.count(b"<DEVICE>")

    result = pkt_fix.apply_fixes(
        path, [fix], out_name="fixtest", project="fixtest"
    )

    # 1. a real file came out, next to nothing else, and the source is intact
    assert os.path.isfile(result["path"])
    assert result["path"].endswith(".pkt")
    assert _sha(path) == before, "the source save must never be modified"

    # 2. it decrypts again, with the same device set (structure preserved)
    payload = open(result["path"], "rb").read()
    xml = pkt_codec.decrypt_pkt(payload)
    assert xml.count(b"<DEVICE>") == devices_before
    assert xml != source_xml, "the approved change must actually be in the file"

    # 3. the change is visible in the saved config, in the file itself
    command = fix["fix_cli"][-1].strip().lower()
    block = xml.split(b"<DEVICE>", 1)[1]
    config_lines = [
        line.strip().lower()
        for line in pkt_fix._lines_of(
            xml.split(b"<RUNNINGCONFIG>", 1)[1].split(b"</RUNNINGCONFIG>", 1)[0])
    ]
    assert command in config_lines, (command, config_lines[-12:])

    # 4. the diff names the device and the command
    assert result["diffs"], "a diff is required for every applied change"
    diff = result["diffs"][0]
    assert diff["device"] == device
    # the diff must name the change, whatever kind it was (config line or
    # the saved port state - the audit's fixes are one or the other)
    assert diff["changes"], diff
    added = [line[1:] for line in diff["diff"]
             if line.startswith("+") and not line.startswith("+++")]
    assert added, diff["diff"]
    payload_value = fix["fix_cli"][-1].split()[-2]      # e.g. 192.168.1.1
    assert any(payload_value in line for line in added), added
    assert any(line.startswith(("-", "+")) for line in diff["diff"])
    assert result["manifest"]

    # 5. the ledger recorded it
    ledger = pkt_fix.ledger()
    assert ledger["applied"] == 1
    entry = ledger["entries"][-1]
    assert entry["source"] == path
    assert entry["result"] == result["path"]
    assert entry["devices"] == [device]

    # 5b. re-auditing the RESULT shows the finding resolved
    import pt_autopilot as pt
    after_report = pt.pkt_audit_network(result["path"], project="fixtest")
    ids_after = {
        f.get("id")
        for d in after_report.get("devices", [])
        for f in d.get("findings", [])
    }
    assert fix["id"].replace("fix-", "") not in ids_after, (
        fix["id"], sorted(ids_after))

    # 6. undo restores the byte-for-byte original as a new file
    undone = pkt_fix.undo()
    assert undone["ok"] is True
    assert _sha(undone["path"]) == before
    assert pkt_fix.ledger()["undone"] == 1


def test_bad_input_fails_clearly(tmp_path, monkeypatch):
    monkeypatch.setenv("NETBUILDER_PKT_OUT", str(tmp_path / "out"))
    monkeypatch.setenv("NETBUILDER_FIX_LEDGER", str(tmp_path / "ledger.jsonl"))

    # missing file
    with pytest.raises(pkt_fix.FixError, match="not found"):
        pkt_fix.apply_fixes(str(tmp_path / "nope.pkt"), [{"device": "R1"}])

    # corrupt / truncated container
    bad = tmp_path / "broken.pkt"
    bad.write_bytes(b"not a packet tracer save" * 40)
    with pytest.raises(pkt_fix.FixError, match="not a Packet Tracer save"):
        pkt_fix.apply_fixes(str(bad), [{"device": "R1",
                                        "fix_cli": ["no shutdown"]}])

    # an empty fix list is refused (the approval gate)
    path = next((f for f in _fixtures()), "")
    if path:
        with pytest.raises(pkt_fix.FixError, match="no approved fixes"):
            pkt_fix.apply_fixes(path, [])


def test_secrets_are_redacted_everywhere(tmp_path, monkeypatch):
    monkeypatch.setenv("NETBUILDER_PKT_OUT", str(tmp_path / "out"))
    monkeypatch.setenv("NETBUILDER_FIX_LEDGER", str(tmp_path / "ledger.jsonl"))

    assert "SuperSecret123" not in pkt_fix.redact(
        "enable secret SuperSecret123")
    assert "preshared" not in pkt_fix.redact("pre-shared key preshared1")
    # a non-secret command is untouched
    assert pkt_fix.redact("switchport port-security maximum 1") == \
        "switchport port-security maximum 1"

    row = pkt_fix.record_decision(
        {"id": "f9", "device": "R1", "text": "harden vty",
         "fix_cli": ["enable secret SuperSecret123"]},
        "approved", capture="lab.pkt")
    assert "SuperSecret123" not in json.dumps(row)
    assert "\u2022" in row["commands"][0]


def test_ledger_is_queryable_and_counts_decisions(tmp_path, monkeypatch):
    monkeypatch.setenv("NETBUILDER_FIX_LEDGER", str(tmp_path / "ledger.jsonl"))
    monkeypatch.setenv("NETBUILDER_PKT_OUT", str(tmp_path / "out"))
    pkt_fix.record_decision({"id": "a", "device": "R1"}, "approved")
    pkt_fix.record_decision({"id": "b", "device": "SW1"}, "rejected")
    summary = pkt_fix.ledger()
    assert summary["count"] == 2
    assert summary["rejected"] == 1
    lines = [line for line in
             open(summary["path"], encoding="utf-8").read().splitlines()
             if line.strip()]
    assert len(lines) == 2
    assert all(json.loads(line)["event"] for line in lines)


def test_wrong_format_is_named_clearly(tmp_path, monkeypatch):
    """A .pcap handed to the engine must say so, not fail to decode."""
    monkeypatch.setenv("NETBUILDER_PKT_OUT", str(tmp_path / "out"))
    monkeypatch.setenv("NETBUILDER_FIX_LEDGER", str(tmp_path / "ledger.jsonl"))

    pcap = tmp_path / "capture.pcap"
    pcap.write_bytes(b"\xd4\xc3\xb2\xa1" + b"\x00" * 80)
    assert pkt_fix.describe_format(str(pcap)) == "pcap"
    with pytest.raises(pkt_fix.FixError) as caught:
        pkt_fix.apply_fixes(
            str(pcap), [{"device": "R1", "fix_cli": ["no shutdown"]}])
    message = str(caught.value)
    assert ".pcap" in message
    assert "not a Packet Tracer save" in message

    pcapng = tmp_path / "capture.pcapng"
    pcapng.write_bytes(b"\x0a\x0d\x0d\x0a" + b"\x00" * 60)
    assert pkt_fix.describe_format(str(pcapng)) == "pcapng"

    xml = tmp_path / "decrypted.xml"
    xml.write_bytes(b"<?xml version=\"1.0\"?><PACKETTRACER5></PACKETTRACER5>")
    assert pkt_fix.describe_format(str(xml)) == "xml"

    real = next((f for f in _fixtures()), "")
    if real:
        assert pkt_fix.describe_format(real) == "pkt"
