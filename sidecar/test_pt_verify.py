"""Tests for pt_verify: test derivation, address resolution, result shaping.

Pure module - no Packet Tracer, no UIA, runs in CI anywhere.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pt_verify  # noqa: E402
import pt_autopilot as autopilot  # noqa: E402


def _plan(**over):
    plan = {
        "projectName": "office",
        "nodes": [
            {"name": "R1", "type": "router"},
            {"name": "SW1", "type": "switch"},
            {"name": "PC1", "type": "pc"},
            {"name": "PC2", "type": "laptop"},
            {"name": "SRV1", "type": "server", "services": ["dhcp", "dns", "http"]},
            {"name": "SRV2", "type": "server", "services": ["aaa"]},
        ],
        "links": [
            {"a": "PC1", "aIf": "f0/1", "b": "SW1", "bIf": "f0/2"},
            {"a": "PC2", "aIf": "f0/1", "b": "SW1", "bIf": "f0/3"},
            {"a": "SW1", "aIf": "f0/1", "b": "R1", "bIf": "g0/0"},
            {"a": "SRV1", "aIf": "f0", "b": "SW1", "bIf": "f0/4"},
            {"a": "SRV2", "aIf": "f0", "b": "SW1", "bIf": "f0/5"},
        ],
        "addressing": [
            {"node": "PC1", "iface": "f0/1", "ipCidr": "192.168.1.10/24"},
            {"node": "PC2", "iface": "f0/1", "ipCidr": "192.168.1.11/24"},
            {"node": "R1", "iface": "g0/0", "ipCidr": "192.168.1.1/24"},
            {"node": "R1", "iface": "g0/1", "ipCidr": "203.0.113.1/30"},
            {"node": "SRV1", "iface": "f0", "ipCidr": "192.168.1.20/24"},
            {"node": "SRV2", "iface": "f0", "ipCidr": "192.168.1.21/24"},
        ],
    }
    plan.update(over)
    return plan


# --------------------------------------------------------------------------
# derive_tests
# --------------------------------------------------------------------------

def test_gateway_tests_for_every_endpoint():
    tests = pt_verify.derive_tests(_plan())
    gw = [t for t in tests if t["kind"] == "gateway"]
    assert {t["src"] for t in gw} == {"PC1", "PC2"}
    assert all(t["dst"] == "R1" for t in gw)


def test_service_tests_skip_dhcp_and_dedup():
    tests = pt_verify.derive_tests(_plan())
    svc = [t for t in tests if t["kind"] == "service"]
    # SRV1 offers dns+http (dhcp excluded), SRV2 offers aaa
    pairs = {(t["src"], t["dst"]) for t in svc}
    assert ("PC1", "SRV1") in pairs and ("PC1", "SRV2") in pairs
    assert ("PC2", "SRV1") in pairs and ("PC2", "SRV2") in pairs


def test_dns_check_is_separate_from_server_ping_and_uses_a_configured_record():
    plan = _plan()
    plan["nodes"][4]["serviceRules"] = {
        "dns": {"records": [{"name": "web.lab", "address": "192.168.1.20"}]}
    }
    tests = pt_verify.derive_tests(plan)
    dns = [t for t in tests if t["kind"] == "dns"]
    assert len(dns) == 2
    assert {(t["src"], t["query"], t["expectedIp"]) for t in dns} == {
        ("PC1", "web.lab", "192.168.1.20"),
        ("PC2", "web.lab", "192.168.1.20"),
    }


def test_dns_requires_a_reachable_dns_server_and_usable_record():
    plan = _plan()
    plan["nodes"][4]["serviceRules"] = {
        "dns": {"records": [{"name": "bad.lab", "address": "not-an-ip"}]}
    }
    assert not [t for t in pt_verify.derive_tests(plan) if t["kind"] == "dns"]

    plan["nodes"][4]["serviceRules"]["dns"]["records"] = [
        {"name": "web.lab", "address": "192.168.1.20"}
    ]
    plan["links"] = [l for l in plan["links"] if l["a"] != "PC1" and l["b"] != "PC1"]
    dns = [t for t in pt_verify.derive_tests(plan) if t["kind"] == "dns"]
    assert {t["src"] for t in dns} == {"PC2"}


def test_dns_result_needs_the_expected_lookup_evidence():
    test = {
        "src": "PC1", "dst": "SRV1", "kind": "dns",
        "query": "web.lab", "expectedIp": "192.168.1.20",
        "detail": "Resolve web.lab",
    }
    passed = pt_verify.shape_results([
        {"source": "PC1", "target": "web.lab", "ok": True,
         "available": True, "evidence": "Name: web.lab Address: 192.168.1.20"}
    ], [test])
    assert passed[0]["status"] == "passed"
    failed = pt_verify.shape_results([
        {"source": "PC1", "target": "web.lab", "ok": False,
         "available": True, "evidence": "DNS request timed out"}
    ], [test])
    assert failed[0]["status"] == "failed"
    skipped = pt_verify.shape_results([
        {"source": "PC1", "target": "web.lab", "ok": False,
         "available": False, "evidence": "Command Prompt unavailable"}
    ], [test])
    assert skipped[0]["status"] == "skipped"


def test_live_dns_probe_types_nslookup_and_captures_the_expected_address(monkeypatch):
    class Window:
        def rectangle(self):
            return type("Rect", (), {"left": 0, "top": 0, "right": 100, "bottom": 100})()

    window = Window()
    output = {"text": "Name: web.lab\nAddress: 192.168.1.20"}
    commands = []
    monkeypatch.setattr(autopilot, "_open_device_window", lambda *args: window)
    monkeypatch.setattr(autopilot, "_pc_open_desktop_app", lambda *args: True)
    monkeypatch.setattr(autopilot, "_safe_click", lambda *args: None)
    monkeypatch.setattr(autopilot, "_interruptible_sleep", lambda *args: None)
    monkeypatch.setattr(autopilot, "_type_line", lambda command, *args, **kwargs: commands.append(command) or True)
    monkeypatch.setattr(autopilot, "_ocr_region", lambda *args: output["text"])
    monkeypatch.setattr(autopilot, "_close_device_window", lambda *args: None)
    monkeypatch.setattr(autopilot, "record_event", lambda *args, **kwargs: None)
    monkeypatch.setattr(autopilot, "log", lambda *args, **kwargs: None)
    monkeypatch.setattr(autopilot, "_OCR_CACHE", {})
    results = []
    autopilot._pc_dns_lookups(
        None,
        "PC1",
        0,
        [{"query": "web.lab", "expectedIp": "192.168.1.20"}],
        "office",
        results,
    )
    assert commands == ["nslookup web.lab"]
    assert results[0]["ok"] is True
    assert "192.168.1.20" in results[0]["evidence"]

    output["text"] = "Name: web.lab\nAddress: 192.168.1.99"
    results.clear()
    autopilot._pc_dns_lookups(
        None,
        "PC1",
        0,
        [{"query": "web.lab", "expectedIp": "192.168.1.20"}],
        "office",
        results,
    )
    assert results[0]["ok"] is False


def test_custom_tests_from_plan_are_appended():
    tests = pt_verify.derive_tests(_plan(tests=["PC1 must reach PC2"]))
    custom = [t for t in tests if t["kind"] == "custom"]
    assert len(custom) == 1
    assert "PC1 must reach PC2" in custom[0]["detail"]


def test_no_endpoints_means_no_tests():
    plan = _plan(nodes=[{"name": "R1", "type": "router"}], links=[], addressing=[])
    assert pt_verify.derive_tests(plan) == []


def test_cap_limits_test_count():
    nodes = [{"name": "R1", "type": "router"}]
    links = []
    addressing = [{"node": "R1", "iface": "g0/0", "ipCidr": "10.0.0.1/24"}]
    for i in range(70):
        nodes.append({"name": f"PC{i}", "type": "pc"})
        links.append({"a": f"PC{i}", "aIf": "f0/1", "b": "SW1", "bIf": f"f0/{i}"})
    nodes.append({"name": "SW1", "type": "switch"})
    links.append({"a": "SW1", "aIf": "f0/1", "b": "R1", "bIf": "g0/0"})
    tests = pt_verify.derive_tests({"nodes": nodes, "links": links,
                                    "addressing": addressing})
    assert len(tests) <= pt_verify._MAX_TESTS
    coverage = [t for t in tests if "Coverage limit:" in t.get("detail", "")]
    assert len(coverage) == 1
    assert "11 automatic checks were not run" in coverage[0]["detail"]


def test_cap_reports_manual_checks_hidden_by_coverage_row():
    services = ["dhcp", "dns", "http", "aaa", "ftp", "email", "ntp", "tftp", "syslog"]
    plan = {
        "nodes": [{"name": "SRV1", "type": "server", "services": services}],
        "security": {
            "extendedAcl": True,
            "portSecurity": True,
            "dhcpSnooping": True,
            "tests": [f"Policy check {i}" for i in range(10)],
        },
    }
    tests = pt_verify.derive_tests(plan)
    coverage = [t for t in tests if "Coverage limit:" in t.get("detail", "")]
    assert len(tests) == 20
    assert len(coverage) == 1
    assert "3 manual checks are not shown" in coverage[0]["detail"]


# --------------------------------------------------------------------------
# ip_index / gateway_ip_for
# --------------------------------------------------------------------------

def test_ip_index_skips_zero_and_invalid():
    ips = pt_verify.ip_index(_plan(addressing=[
        {"node": "A", "iface": "f0", "ipCidr": "0.0.0.0/24"},
        {"node": "B", "iface": "f0", "ipCidr": "not-an-ip/24"},
        {"node": "C", "iface": "f0", "ipCidr": "10.1.1.1/24"},
        {"node": "D", "iface": "f0", "ipCidr": "2001:db8::1/64"},
    ]))
    assert ips == {"C": "10.1.1.1"}


def test_gateway_ip_same_subnet_match():
    # R1 has two addresses; the one sharing PC1's subnet must be chosen
    # (it is the only candidate, but the function must not raise on multi-
    # addressed routers).
    assert pt_verify.gateway_ip_for(_plan(), "PC1", "R1") == "192.168.1.1"


def test_gateway_ip_falls_back_to_router_address():
    plan = _plan(addressing=[
        {"node": "PC1", "iface": "f0/1", "ipCidr": "192.168.1.10/24"},
        {"node": "R1", "iface": "g0/1", "ipCidr": "203.0.113.1/30"},
    ])
    # no shared subnet: still returns the router's address (best effort)
    assert pt_verify.gateway_ip_for(plan, "PC1", "R1") == "203.0.113.1"


# --------------------------------------------------------------------------
# shape_results / summarize
# --------------------------------------------------------------------------

def test_shape_results_matches_by_ip_and_prefers_pass():
    tests = pt_verify.derive_tests(_plan())
    rows = [
        {"source": "PC1", "target": "192.168.1.1", "ok": True,
         "attempts": 1, "evidence": "Reply from ... TTL 128"},
        {"source": "PC1", "target": "192.168.1.1", "ok": False,
         "attempts": 2, "evidence": "Request timed out"},
        {"source": "PC1", "target": "192.168.1.20", "ok": True,
         "attempts": 1, "evidence": "Reply from ..."},
        {"source": "PC1", "target": "192.168.1.21", "ok": False,
         "attempts": 2, "evidence": "Request timed out"},
        {"source": "PC2", "target": "192.168.1.1", "ok": True,
         "attempts": 1, "evidence": "Reply from ..."},
    ]
    shaped = pt_verify.shape_results(rows, tests, plan=_plan())
    by_pair = {(r["src"], r["dst"]): r for r in shaped}
    assert by_pair[("PC1", "R1")]["status"] == "passed"  # pass wins over fail
    assert by_pair[("PC1", "SRV1")]["status"] == "passed"
    assert by_pair[("PC1", "SRV2")]["status"] == "failed"
    assert by_pair[("PC2", "R1")]["status"] == "passed"
    assert by_pair[("PC2", "SRV1")]["status"] == "skipped"


def test_shape_results_marks_custom_skipped():
    tests = pt_verify.derive_tests(_plan(tests=["manual check"]))
    shaped = pt_verify.shape_results([], tests)
    custom = [r for r in shaped if r["kind"] == "custom"]
    assert len(custom) == 1 and custom[0]["status"] == "skipped"


def test_summarize_counts_and_ok():
    results = [
        {"status": "passed"}, {"status": "passed"}, {"status": "failed"},
        {"status": "skipped"},
    ]
    s = pt_verify.summarize(results)
    assert s["passed"] == 2 and s["failed"] == 1 and s["skipped"] == 1
    assert s["ok"] is False
    assert pt_verify.summarize([{"status": "passed"}])["ok"] is True
    assert pt_verify.summarize([])["ok"] is False
