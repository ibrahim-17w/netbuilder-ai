"""Auto-verification: a fix is only "fixed" if the re-audit says so."""
from __future__ import annotations

import net_tools


def _audit(devices):
    return {"devices": devices}


def _device(name, findings):
    return {"name": name, "findings": findings}


def _finding(fid, severity="error"):
    return {"id": fid, "severity": severity, "title": fid.split(":")[-1]}


BEFORE = _audit([
    _device("PC1", [_finding("PC1:gateway-outside-subnet")]),
    _device("SW1", [_finding("SW1:vlan-mismatch", "warning")]),
])


def test_a_cleared_finding_is_verified_fixed():
    after = _audit([
        _device("PC1", []),
        _device("SW1", [_finding("SW1:vlan-mismatch", "warning")]),
    ])
    result = net_tools.verify_repair(
        BEFORE, after, [{"id": "PC1:gateway-outside-subnet"}])
    assert result["verdict"] == "fixed"
    assert result["verified"] is True
    assert [f["id"] for f in result["resolved"]] == ["PC1:gateway-outside-subnet"]
    assert result["stillBroken"] == []
    assert "Verified" in result["summary"]


def test_a_surviving_finding_is_reported_as_still_broken():
    result = net_tools.verify_repair(
        BEFORE, BEFORE, [{"id": "PC1:gateway-outside-subnet"}])
    assert result["verdict"] == "not_fixed"
    assert result["verified"] is False
    assert [f["id"] for f in result["stillBroken"]] == ["PC1:gateway-outside-subnet"]
    assert "Still broken" in result["summary"]


def test_a_partial_fix_is_neither_claimed_nor_hidden():
    after = _audit([
        _device("PC1", []),
        _device("SW1", [_finding("SW1:vlan-mismatch", "warning")]),
    ])
    result = net_tools.verify_repair(BEFORE, after, [
        {"id": "PC1:gateway-outside-subnet"},
        {"id": "SW1:vlan-mismatch"},
    ])
    assert result["verdict"] == "partly_fixed"
    assert result["verified"] is False
    assert len(result["resolved"]) == 1 and len(result["stillBroken"]) == 1


def test_a_fix_that_breaks_something_else_says_so():
    after = _audit([
        _device("PC1", []),
        _device("SW1", [_finding("SW1:vlan-mismatch", "warning")]),
        _device("R1", [_finding("R1:duplicate-address")]),
    ])
    result = net_tools.verify_repair(
        BEFORE, after, [{"id": "PC1:gateway-outside-subnet"}])
    assert result["verdict"] == "fixed"
    assert [f["id"] for f in result["introduced"]] == ["R1:duplicate-address"]
    assert "introduced" in result["summary"]


def test_an_empty_re_audit_is_unverified_not_a_pass():
    result = net_tools.verify_repair(
        BEFORE, _audit([]), [{"id": "PC1:gateway-outside-subnet"}])
    assert result["verdict"] == "unverified"
    assert result["verified"] is False
    assert "not the same as the problem being gone" in result["summary"]


def test_the_tool_is_reachable_through_the_dispatcher():
    tools = {t["name"]: t for t in net_tools.list_tools()["tools"]}
    assert tools["verify_repair"]["kind"] == "read"

    # SW1 keeps its own finding, so the re-audit is readable but PC1 is clean.
    after = _audit([
        _device("PC1", []),
        _device("SW1", [_finding("SW1:vlan-mismatch", "warning")]),
    ])
    result = net_tools.call(
        "verify_repair",
        {"before": BEFORE, "after": after, "fixes": [{"id": "PC1:gateway-outside-subnet"}]},
        {},
    )
    assert result["verdict"] == "fixed"

    # even with no capture supplied to the dispatcher, the verifier works
    result = net_tools.call(
        "verify_repair",
        {"before": BEFORE, "after": after, "fixes": []},
        {},
    )
    assert result["verdict"] == "unverified"
