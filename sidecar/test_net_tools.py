"""The model-facing tool layer: reads are facts, writes are proposals."""
from __future__ import annotations

import hashlib
import os

import pytest

import net_tools

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(HERE, "pkt_output")


def _sha(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def _real_audit():
    """An audit of a real .pkt, or skip when the fixtures are absent."""
    import glob
    import pt_autopilot as pt
    for path in sorted(glob.glob(os.path.join(FIXTURE_DIR, "*.pkt"))):
        try:
            report = pt.pkt_audit_network(path, project="tools")
        except Exception:  # noqa: BLE001
            continue
        if isinstance(report, dict) and report.get("devices"):
            return path, report
    pytest.skip("no auditable .pkt fixture")


def test_subnet_maths_is_exact():
    facts = net_tools.subnet_facts("192.168.1.37/24")
    assert facts["network"] == "192.168.1.0"
    assert facts["broadcast"] == "192.168.1.255"
    assert facts["netmask"] == "255.255.255.0"
    assert facts["usableHosts"] == 254
    transit = net_tools.subnet_facts("10.1.1.2/30")
    assert transit["netmask"] == "255.255.255.252"
    assert transit["usableHosts"] == 2


def test_rubbish_is_null_not_a_guess():
    assert net_tools.subnet_facts("300.1.1.1/24") is None
    assert net_tools.subnet_facts("nonsense") is None


def test_subnet_membership_and_gateway_rules():
    assert net_tools.same_subnet("192.168.1.10/24", "192.168.1.20/24") is True
    assert net_tools.same_subnet("192.168.1.10/24", "192.168.2.20/24") is False
    assert net_tools.same_subnet("10.0.0.1/24", "10.0.0.1/16") is False
    assert net_tools.contains("10.0.0.0/22", "10.0.1.5") is True
    assert net_tools.contains("10.0.0.0/22", "10.0.4.5") is False

    assert net_tools.check_gateway("192.168.1.10/24", "192.168.1.1")["ok"] is True
    outside = net_tools.check_gateway("192.168.1.10/24", "192.168.2.1")
    assert outside["ok"] is False and "outside" in outside["reason"]
    assert net_tools.check_gateway("10.0.0.5/24", "10.0.0.0")["ok"] is False
    assert net_tools.check_gateway("10.0.0.5/24", "10.0.0.255")["ok"] is False
    assert net_tools.check_gateway("10.0.0.5/24", "10.0.0.5")["ok"] is False


def test_duplicate_addresses_are_found():
    dupes = net_tools.duplicate_addresses([
        {"node": "PC1", "iface": "f0", "ipCidr": "192.168.1.10/24"},
        {"node": "PC2", "iface": "f0", "ipCidr": "192.168.1.10/24"},
    ])
    assert dupes and dupes[0]["address"] == "192.168.1.10"
    assert len(dupes[0]["usedBy"]) == 2


def test_the_registry_covers_the_spec_and_classifies_every_tool():
    result = net_tools.list_tools()
    names = {t["name"] for t in result["tools"]}
    for required in [
        "get_topology", "get_devices", "get_device", "get_interfaces",
        "get_device_config", "get_routing_table", "get_vlans", "get_links",
        "get_network_summary", "check_connectivity", "check_subnet",
        "check_gateway", "check_routes", "check_vlans", "check_dhcp",
        "check_acls", "analyze_network", "validate_network", "save_pkt",
        "set_ip", "set_subnet_mask", "set_gateway",
        "enable_interface", "disable_interface", "configure_vlan",
        "configure_route", "configure_ospf", "configure_dhcp",
        "connect_devices", "disconnect_devices",
    ]:
        assert required in names, required
    assert result["count"] == len(names)
    # every tool must say whether it changes anything
    assert all(t["kind"] in ("read", "modify") for t in result["tools"])
    assert sum(1 for t in result["tools"] if t["kind"] == "read") >= 15
    assert sum(1 for t in result["tools"] if t["kind"] == "modify") >= 8


def test_an_unknown_tool_is_refused():
    with pytest.raises(net_tools.ToolError):
        net_tools.call("delete_everything", {}, {})


def test_a_modify_tool_returns_a_proposal_and_writes_nothing(tmp_path):
    path, _audit = _real_audit()
    before = _sha(path)
    result = net_tools.call(
        "set_gateway", {"device": "R1", "gateway": "10.0.0.1"}, _audit)
    assert result["kind"] == "modify"
    assert result["requiresApproval"] is True
    assert result["proposal"]["tool"] == "set_gateway"
    assert _sha(path) == before, "a tool call must never modify the capture"


def test_read_tools_answer_from_a_real_capture():
    path, audit = _real_audit()

    topology = net_tools.call("get_topology", {}, audit)
    assert topology["devices"], topology
    assert "links" in topology

    summary = net_tools.call("get_network_summary", {}, audit)
    assert summary["devices"] >= 1
    assert "duplicateAddresses" in summary

    first = topology["devices"][0]["name"]
    one = net_tools.call("get_device", {"device": first}, audit)
    assert one["device"]["name"] == first
    interfaces = net_tools.call("get_interfaces", {"device": first}, audit)
    assert "interfaces" in interfaces

    analysis = net_tools.call("analyze_network", {}, audit)
    assert "findings" in analysis and "verdict" in analysis
    assert net_tools.call("validate_network", {}, audit)["verdict"]


def test_a_missing_device_is_reported_not_guessed():
    _path, audit = _real_audit()
    with pytest.raises(net_tools.ToolError):
        net_tools.call("get_device", {"device": "NOT_A_DEVICE"}, audit)


def test_connectivity_says_what_the_file_proves():
    _path, audit = _real_audit()
    devices = [d["name"] for d in
               net_tools.call("get_devices", {}, audit)["devices"]]
    result = net_tools.call(
        "check_connectivity",
        {"source": devices[0], "destination": devices[-1]}, audit)
    assert result["source"] == devices[0]
    # reachable is True / False / None, never a claim without a reason
    assert result["reachable"] in (True, False, None)
    assert result["reason"]
