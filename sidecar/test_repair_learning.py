"""Verified repairs become learning; everything else stays out of it.

`pkt_fix.apply_fixes` is an APPROVAL gate: the user says yes and the change is
written to a new .pkt. Approval is not proof - the file can be approved and
still be wrong. The proof already exists (`net_tools.verify_repair` re-audits
the repaired save), and it was simply being thrown away.

These tests pin the store behind that hook:

* only a `verified` verdict is ever learned from;
* what is learned is the finding's CLASS with this network's names removed,
  so the lesson carries to another save instead of memorising "R1 g0/0";
* the read side only ever reports what a re-audit actually proved.

No Packet Tracer, no .pkt, no screen.
"""
from __future__ import annotations

import pytest

import pkt_learning as pl


@pytest.fixture(autouse=True)
def _store(tmp_path):
    pl.reset(str(tmp_path / "learn.json"))
    yield
    pl.reset()


def _before():
    return {
        "project": "lab",
        "devices": [{
            "name": "R1",
            "findings": [{
                "id": "R1:offline:1",
                "severity": "high",
                "text": "GigabitEthernet0/0 is shut down in the saved config",
                "fix_cli": ["interface GigabitEthernet0/0", "no shutdown"],
            }],
        }],
    }


def _fix(fid="R1:offline:1", commands=("interface GigabitEthernet0/0",
                                      "no shutdown")):
    return [{"id": fid, "device": "R1", "fix_cli": list(commands)}]


def _fixed():
    return {
        "verdict": "fixed",
        "verified": True,
        "resolved": [{"id": "R1:offline:1", "severity": "high"}],
        "stillBroken": [],
        "introduced": [],
    }


def test_a_verified_repair_is_learned():
    out = pl.record_repair("lab", _fixed(), _before(), _fix())
    assert out["recorded"] == 1
    proven = pl.verified_repairs("lab")
    assert len(proven) == 1
    row = next(iter(proven.values()))
    assert row["count"] == 1
    assert "no shutdown" in row["commands"]
    assert row["devices"] == ["R1"]


def test_a_repair_that_was_not_verified_teaches_nothing():
    for verdict in ({"verdict": "not_fixed", "verified": False,
                     "resolved": [], "stillBroken": [{"id": "R1:offline:1"}]},
                    {"verdict": "unchanged", "verified": False},
                    {"verdict": "partly_fixed", "verified": False},
                    {"verdict": "unverified", "verified": False}):
        pl.record_repair("lab", verdict, _before(), _fix())
    assert pl.verified_repairs("lab") == {}
    # And it is not smuggled in through a truthy `verified` value either.
    pl.record_repair("lab", {"verdict": "fixed", "verified": "yes"},
                     _before(), _fix())
    assert pl.verified_repairs("lab") == {}


def test_the_lesson_is_the_finding_class_not_this_network():
    pl.record_repair("lab", _fixed(), _before(), _fix())
    klass = next(iter(pl.verified_repairs("lab")))
    # The device name, the interface name and the words around them are gone:
    # what remains is the shape, so the next save of the same lab matches.
    assert "r1" not in klass
    assert "gigabit" not in klass
    assert klass.startswith("high|")
    other = {"severity": "high",
             "text": "GigabitEthernet0/1 is shut down in the saved config"}
    assert pl.finding_class(other) == klass


def test_a_repair_is_only_learned_for_the_finding_it_names():
    verdict = dict(_fixed(), resolved=[{"id": "OTHER:offline:9",
                                        "severity": "low"}])
    out = pl.record_repair("lab", verdict, _before(), _fix())
    assert out["recorded"] == 0
    assert pl.verified_repairs("lab") == {}


def test_a_repair_without_commands_is_not_a_lesson():
    out = pl.record_repair("lab", _fixed(), _before(),
                           [{"id": "R1:offline:1", "device": "R1"}])
    assert out["recorded"] == 0
    assert pl.verified_repairs("lab") == {}


def test_repeats_are_counted_once_per_class():
    for _ in range(3):
        pl.record_repair("lab", _fixed(), _before(), _fix())
    proven = pl.verified_repairs("lab")
    assert len(proven) == 1
    assert next(iter(proven.values()))["count"] == 3


def test_repair_memory_is_per_project():
    pl.record_repair("lab", _fixed(), _before(), _fix())
    assert pl.verified_repairs("branch") == {}
    summary = pl.summary()
    assert summary["verifiedRepairs"] == 1
    assert summary["generations"] == 0, (
        "a repair is not a generation and must not be counted as one")


def test_the_audit_only_reports_proof():
    """The read side: a class is 'fixed before' only from a verified repair."""
    import pt_autopilot as pt

    klass = pt.pkt_learning.finding_class({
        "severity": "high",
        "text": "GigabitEthernet0/0 is shut down in the saved config"})
    # Nothing proven yet: the audit must not invent a `fixedBefore`.
    assert (pl.verified_repairs("lab").get(klass) or {}).get("count", 0) == 0
    pl.record_repair("lab", _fixed(), _before(), _fix())
    assert (pl.verified_repairs("lab").get(klass) or {}).get("count") == 1


def _plan(shutdown: bool):
    return {
        "projectName": "learn",
        "steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router"},
                {"name": "PC1", "type": "pc"},
            ]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "g0/0", "b": "PC1", "bIf": "f0"},
            ]},
            {"action": "config_pcs", "pcs": {"PC1": {
                "ip": "192.168.1.10", "mask": "255.255.255.0",
                "gw": "192.168.1.1"}}},
            {"action": "paste_cli", "configs": {"R1":
                "hostname R1\ninterface g0/0\n"
                "ip address 192.168.1.1 255.255.255.0\n"
                + ("shutdown\n" if shutdown else "no shutdown\n")}},
        ],
    }


def test_the_wire_path_records_a_verified_repair_and_audits_read_it_back(
        tmp_path):
    """End to end: POST /tools/call -> store -> the next audit.

    The unit tests above pin the store's rules; this pins that the real HTTP
    entry point the app uses actually calls it, and that the audit that
    produced the finding is the one that reads the lesson back. A hook that
    is only correct in theory is not a loop.
    """
    import http.client
    import json as _json
    import threading
    from http.server import HTTPServer

    import pkt_builder
    import pt_autopilot as pt

    before_path = str(tmp_path / "before.pkt")
    after_path = str(tmp_path / "after.pkt")
    pkt_builder.generate_pkt_file(_plan(True), before_path, project="learn",
                                  replace=True)
    pkt_builder.generate_pkt_file(_plan(False), after_path, project="learn",
                                  replace=True)

    before = pt.pkt_audit_network(before_path, project="learn")
    after = pt.pkt_audit_network(after_path, project="learn")
    shut = [f for d in before["devices"] for f in d["findings"]
            if "shut down" in f["text"]]
    assert shut, "the fixture must produce a finding the fix clears"
    finding = shut[0]
    assert finding["fixedBefore"] == 0, (
        "nothing is proven before a repair is verified")

    server = HTTPServer(("127.0.0.1", 0), pt.H)
    port = server.server_address[1]
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    reply = {}

    def probe():
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            conn.request(
                "POST", "/tools/call",
                body=_json.dumps({
                    "name": "verify_repair",
                    "path": before_path,
                    "project": "learn",
                    "args": {"before": before, "after": after,
                             "fixes": [{"id": finding["id"],
                                        "device": "R1",
                                        "fix_cli": finding["fix_cli"]}]},
                }),
                headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            reply["status"] = response.status
            reply["body"] = _json.loads(response.read().decode())
            conn.close()
        except Exception as exc:  # noqa: BLE001 - reported via the assertion
            reply["error"] = exc

    worker = threading.Thread(target=probe, daemon=True)
    worker.start()
    worker.join(30)
    try:
        assert not worker.is_alive(), "/tools/call did not answer within 30s"
        assert "error" not in reply, reply.get("error")
        assert reply["status"] == 200, reply["body"]
        assert reply["body"]["result"]["verified"] is True, reply["body"]
    finally:
        server.shutdown()
        server.server_close()

    proven = pl.verified_repairs("learn")
    assert len(proven) == 1, "a verified repair reached the store"
    assert pt.RUN.get("repairsVerified") == 1

    # READ SIDE: the next audit of the same project says this class of
    # finding was fixed here before, and says so ONLY from real proof.
    again = pt.pkt_audit_network(before_path, project="learn")
    same = [f for d in again["devices"] for f in d["findings"]
            if "shut down" in f["text"]]
    assert same, "the unfixed save still reports the finding"
    assert same[0]["fixedBefore"] == 1, same[0]
    # And an untouched project is unaffected by another project's lesson.
    other = pt.pkt_audit_network(before_path, project="elsewhere")
    other_shut = [f for d in other["devices"] for f in d["findings"]
                  if "shut down" in f["text"]]
    assert other_shut[0]["fixedBefore"] == 0, (
        "a repair proven on one project is not proof on another")
