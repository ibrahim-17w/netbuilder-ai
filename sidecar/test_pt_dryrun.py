"""Tests for pt_dryrun: offline plan walk-through, no Packet Tracer."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pt_dryrun  # noqa: E402


def _plan(**overrides):
    plan = {
        "project": "demo",
        "addressing": [
            {"node": "R1", "iface": "s0/0/0", "ipCidr": "10.1.0.1/30"},
            {"node": "R2", "iface": "s0/0/0", "ipCidr": "10.1.0.2/30"},
        ],
        "steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router"},
                {"name": "R2", "type": "router"},
                {"name": "PC1", "type": "pc"},
            ]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "s0/0/0", "b": "R2", "bIf": "s0/0/0"},
            ]},
            {"action": "paste_cli", "configs": {"R1": "hostname R1\nend"}},
            {"action": "config_pcs", "pcs": {
                "PC1": {"ip": "10.0.0.10", "mask": "255.255.255.0",
                        "gw": "10.0.0.1"}}},
        ],
    }
    plan.update(overrides)
    return plan


def test_summary_counts_match_plan():
    rep = pt_dryrun.dry_run_plan(_plan())
    assert rep["ok"] and rep["dryRun"]
    assert rep["summary"]["devices"] == 3
    assert rep["summary"]["links"] == 1
    assert rep["summary"]["cliDevices"] == 1
    assert rep["summary"]["ipConfigured"] == 1


def test_fully_addressed_transit_has_no_dead_link_warning():
    rep = pt_dryrun.dry_run_plan(_plan())
    dead = [w for w in rep["warnings"] if "dead transit" in w]
    assert dead == []


def test_unaddressed_transit_end_is_flagged():
    plan = _plan()
    plan["addressing"] = [plan["addressing"][0]]  # drop R2's address
    rep = pt_dryrun.dry_run_plan(plan)
    assert any("dead transit" in w for w in rep["warnings"])


def test_incomplete_endpoint_ip_config_is_flagged():
    plan = _plan()
    plan["steps"][3]["pcs"]["PC1"] = {"ip": "10.0.0.10", "gw": "10.0.0.1"}
    rep = pt_dryrun.dry_run_plan(plan)
    assert any("missing mask" in w for w in rep["warnings"])


def test_unknown_link_endpoint_is_flagged():
    plan = _plan()
    plan["steps"][1]["links"].append(
        {"a": "GHOST", "aIf": "f0", "b": "SW1", "bIf": "f0/9"})
    rep = pt_dryrun.dry_run_plan(plan)
    assert any("unknown device" in w for w in rep["warnings"])


def test_actions_list_every_placement_and_cable():
    rep = pt_dryrun.dry_run_plan(_plan())
    places = [a for a in rep["actions"] if a["action"] == "place"]
    cables = [a for a in rep["actions"] if a["action"] == "cable"]
    assert len(places) == 3
    assert len(cables) == 1
