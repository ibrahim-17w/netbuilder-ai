"""Tests for pkt_audit: audit, diff, grade (pure, no Packet Tracer)."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

import pkt_audit  # noqa: E402
import pkt_builder  # noqa: E402


def _proof_plan():
    return {
        "projectName": "audit-test",
        "steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router"},
                {"name": "SW1", "type": "switch"},
                {"name": "PC1", "type": "pc"},
                {"name": "PC2", "type": "pc"},
                {"name": "SRV1", "type": "server", "services": ["dhcp"]},
                {"name": "SRV2", "type": "server", "services": ["aaa"]},
            ]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "g0/0", "b": "SW1", "bIf": "f0/1"},
                {"a": "SW1", "aIf": "f0/2", "b": "PC1", "bIf": "f0"},
                {"a": "SW1", "aIf": "f0/3", "b": "PC2", "bIf": "f0"},
                {"a": "SW1", "aIf": "f0/4", "b": "SRV1", "bIf": "f0"},
                {"a": "SW1", "aIf": "f0/5", "b": "SRV2", "bIf": "f0"},
            ]},
            {"action": "config_pcs", "pcs": {
                "PC1": {"ip": "192.168.1.10", "mask": "255.255.255.0",
                        "gw": "192.168.1.1"},
                "PC2": {"ip": "192.168.1.11", "mask": "255.255.255.0",
                        "gw": "192.168.1.1"},
            }},
            {"action": "config_servers", "servers": {
                "SRV1": {"services": {"dhcp": {"pools": [
                    {"poolName": "pool1", "gateway": "192.168.1.1",
                     "startIp": "192.168.1.50", "mask": "255.255.255.0",
                     "maxUsers": "100", "dnsServer": "192.168.1.20"}]}},
                    "ip": "192.168.1.20", "mask": "255.255.255.0",
                    "gw": "192.168.1.1"},
                "SRV2": {"services": {"aaa": {"enabled": True,
                          "users": [{"username": "admin",
                                     "password": "cisco"}],
                          "clients": [{"name": "R1", "ip": "192.168.1.1",
                                       "key": "cisco",
                                       "type": "RADIUS"}]}},
                    "ip": "192.168.1.21", "mask": "255.255.255.0",
                    "gw": "192.168.1.1"},
            }},
            {"action": "paste_cli", "configs": {
                "R1": "hostname R1\ninterface g0/0\n"
                      "ip address 192.168.1.1 255.255.255.0\nno shutdown\n"
                      "aaa new-model\n"
                      "radius-server host 192.168.1.21 auth-port 1645 "
                      "key cisco\n"
                      "aaa authentication login default group radius local\n"}},
        ],
    }


def _intent_plan():
    return {
        "nodes": [
            {"name": "R1", "type": "router"},
            {"name": "SW1", "type": "switch"},
            {"name": "PC1", "type": "pc"},
            {"name": "PC2", "type": "pc"},
            {"name": "SRV1", "type": "server", "services": ["dhcp"]},
            {"name": "SRV2", "type": "server", "services": ["aaa"]},
        ],
        "links": _proof_plan()["steps"][1]["links"],
        "addressing": [
            {"node": "R1", "iface": "g0/0", "ipCidr": "192.168.1.1/24"},
            {"node": "PC1", "iface": "f0", "ipCidr": "192.168.1.10/24"},
            {"node": "PC2", "iface": "f0", "ipCidr": "192.168.1.11/24"},
            {"node": "SRV1", "iface": "f0", "ipCidr": "192.168.1.20/24"},
            {"node": "SRV2", "iface": "f0", "ipCidr": "192.168.1.21/24"},
        ],
        "security": {"requested": True, "aaaProtocol": "radius",
                     "aaaServer": "SRV2"},
    }


@pytest.fixture(scope="module")
def proof_pkt(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("audit")
    path = str(tmp / "proof.pkt")
    pkt_builder.generate_pkt_file(_proof_plan(), path, project="audit-test",
                                  replace=True)
    return path


def test_devices_found(proof_pkt):
    xml = pkt_audit.decode(proof_pkt)
    devs = pkt_audit.devices(xml)
    names = {d["name"] for d in devs}
    assert {"R1", "SW1", "PC1", "PC2", "SRV1", "SRV2"} <= names
    pc1 = next(d for d in devs if d["name"] == "PC1")
    assert "192.168.1.10" in pc1["ips"]


def test_links_reference_names(proof_pkt):
    xml = pkt_audit.decode(proof_pkt)
    lks = pkt_audit.links(xml)
    assert len(lks) == 5
    pair = {frozenset((l["a"], l["b"])) for l in lks}
    assert frozenset(("R1", "SW1")) in pair


def test_aaa_state_roundtrip(proof_pkt):
    xml = pkt_audit.decode(proof_pkt)
    aaa = pkt_audit.aaa_state(xml)
    srv2 = aaa["SRV2"]
    assert srv2["enabled"] is True
    assert "admin" in srv2["users"]
    assert srv2["clients"] and srv2["clients"][0]["ip"] == "192.168.1.1"
    assert srv2["clients"][0]["type"] == "RADIUS"


def test_audit_reports_findings(proof_pkt):
    rep = pkt_audit.audit(proof_pkt, "audit-test")
    assert rep["summary"]["devices"] == 6
    assert rep["summary"]["links"] == 5
    # AAA on SRV2 is complete: no empty-panel high finding for it
    aaa_findings = [f for f in rep["findings"]
                    if "AAA" in f["text"] and f["device"] == "SRV2"]
    assert aaa_findings == []


def test_grade_full_score(proof_pkt):
    g = pkt_audit.grade(proof_pkt, _intent_plan())
    assert g["score"] == g["max"], [r for r in g["requirements"]
                                    if not r["ok"]]
    assert g["percent"] == 100.0


def test_grade_flags_missing_device(proof_pkt):
    plan = _intent_plan()
    plan["nodes"].append({"name": "GONE", "type": "router"})
    plan["links"].append({"a": "GONE", "aIf": "g0/1", "b": "SW1",
                          "bIf": "f0/9"})
    g = pkt_audit.grade(proof_pkt, plan)
    assert g["score"] < g["max"]
    failed = [r["name"] for r in g["requirements"] if not r["ok"]]
    assert any("GONE" in n for n in failed)


def test_grade_flags_disabled_service(proof_pkt):
    # grade against a plan that ALSO wants dns on SRV1 (it is not configured)
    plan = _intent_plan()
    plan["nodes"][4]["services"] = ["dhcp", "dns"]
    g = pkt_audit.grade(proof_pkt, plan)
    failed = [r["name"] for r in g["requirements"] if not r["ok"]]
    assert any("dns on SRV1" in n for n in failed)


def test_diff_reports_changes(proof_pkt, tmp_path):
    # a second save: same topology, one device removed by rebuilding smaller
    plan = _proof_plan()
    plan["steps"][0]["nodes"] = [n for n in plan["steps"][0]["nodes"]
                                 if n["name"] != "PC2"]
    plan["steps"][1]["links"] = [l for l in plan["steps"][1]["links"]
                                 if "PC2" not in (l["a"], l["b"])]
    plan["steps"][2]["pcs"].pop("PC2", None)
    path_b = str(tmp_path / "smaller.pkt")
    pkt_builder.generate_pkt_file(plan, path_b, project="audit-test",
                                  replace=True)
    d = pkt_audit.diff(proof_pkt, path_b)
    assert d["devicesRemoved"] == ["PC2"]
    assert any("PC2" in l for l in d["linksRemoved"])
    assert d["unchanged"] is False


def test_diff_unchanged_detects_identical(proof_pkt, tmp_path):
    path_b = str(tmp_path / "same.pkt")
    pkt_builder.generate_pkt_file(_proof_plan(), path_b, project="audit-test",
                                  replace=True)
    d = pkt_audit.diff(proof_pkt, path_b)
    assert d["unchanged"] is True


def test_aaa_broken_server_produces_findings(tmp_path):
    plan = _proof_plan()
    # SRV2 AAA enabled but NO users and NO clients -> PT turns the tab Off,
    # so the audit must say something useful either way
    plan["steps"][3]["servers"]["SRV2"]["services"]["aaa"] = {"enabled": True}
    path = str(tmp_path / "broken.pkt")
    pkt_builder.generate_pkt_file(plan, path, project="audit-test",
                                  replace=True)
    rep = pkt_audit.audit(path, "audit-test")
    g = pkt_audit.grade(path, _intent_plan())
    # grading must NOT give a full score when AAA has no users/clients
    assert g["score"] < g["max"]
