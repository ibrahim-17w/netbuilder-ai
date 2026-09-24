"""Offline .pkt generation learning.

These tests answer the user's requirement directly: generate .pkt files
repeatedly with NO Packet Tracer and prove the auto-learning accumulates
knowledge that is stable and reusable.
"""
from __future__ import annotations

import json
import os
import re

import pytest

import pkt_learning


def test_warning_parsing_does_not_guess():
    subs, remaps, other = pkt_learning.parse_warnings([
        "HQ_Router: used 2811 instead of 2911 "
        "(its template has no port for s0/0/0)",
        "config: s0/0/0 -> Serial0/2/0 (slot remap)",
        "HQ_Router: s0/0/0 -> Serial0/2/0 (slot remap)",
        "HQ_Switch: dropped exec-only line(s) from the saved config: "
        "end, write memory",
        "",
    ])
    assert subs["2911->2811"]["used"] == "2811"
    assert subs["2911->2811"]["count"] == 1
    assert subs["2911->2811"]["devices"] == ["HQ_Router"]
    assert remaps["s0/0/0->Serial0/2/0"]["count"] == 2
    assert set(remaps["s0/0/0->Serial0/2/0"]["devices"]) == {"config",
                                                             "HQ_Router"}
    assert other == [
        "HQ_Switch: dropped exec-only line(s) from the saved config: "
        "end, write memory"]


def _result():
    return {
        "name": "x.pkt", "bytes": 1234, "sha256": "ab" * 32,
        "deviceCount": 2, "linkCount": 1,
        "warnings": [
            "R1: used 2811 instead of 2911 (its template has no port for "
            "s0/0/0)",
            "R1: s0/0/0 -> Serial0/2/0 (slot remap)",
            "config: g0/0 -> FastEthernet0/0 (slot remap)",
        ],
    }


def test_repeated_generations_accumulate_and_stabilize(tmp_path, monkeypatch):
    store_path = tmp_path / "learn.json"
    monkeypatch.setenv("NETBUILDER_PKT_LEARNING", str(store_path))
    pkt_learning.reset()

    reports = []
    for i in range(1, 6):
        rep = pkt_learning.record_generation("lab", _result())
        reports.append(rep)
        assert rep["generations"] == i
        assert rep["repeat"] == (i > 1)
        assert any("2911 -> 2811" in s for s in rep["known"]["substitutions"])
        assert any("s0/0/0 -> Serial0/2/0" in r for r in rep["known"]["remaps"])
        if i == 1:
            assert rep["new"], "the first run must learn the machine"
        else:
            assert rep["new"] == [], "nothing is new after the first run"

    last = reports[-1]
    assert "2911 -> 2811 (5x)" in last["known"]["substitutions"]
    assert last["repeat"] is True
    assert "stable" in last["note"]

    summary = pkt_learning.summary()
    assert summary["generations"] == 5
    assert "2911->2811" in summary["substitutions"]
    assert "s0/0/0->Serial0/2/0" in summary["remaps"]

    on_disk = json.loads(store_path.read_text(encoding="utf-8"))
    assert on_disk["projects"]["lab"]["generations"] == 5


def test_summary_is_per_project(tmp_path, monkeypatch):
    monkeypatch.setenv("NETBUILDER_PKT_LEARNING", str(tmp_path / "learn.json"))
    pkt_learning.reset()
    pkt_learning.record_generation("a", _result())
    pkt_learning.record_generation("b", {"warnings": [], "deviceCount": 1})
    summary = pkt_learning.summary()
    assert summary["generations"] == 2
    assert summary["projects"] == 2
    assert sorted(summary["detail"]) == ["a", "b"]


HERE = os.path.dirname(os.path.abspath(__file__))
LIBRARY = os.path.join(HERE, "pkt_templates", "manifest.json")
PLAN = os.path.join(HERE, "_offline_plan_brief.json")


@pytest.mark.skipif(not (os.path.exists(LIBRARY) and os.path.exists(PLAN)),
                    reason="requires a local template library and plan fixture")
def test_generate_pkt_repeatedly_learns(tmp_path, monkeypatch):
    """Integration: the real generator + this machine's library, 4 runs."""
    import pt_autopilot as pt

    monkeypatch.setenv("NETBUILDER_PKT_DIR", str(tmp_path / "out"))
    monkeypatch.setenv("NETBUILDER_PKT_LEARNING", str(tmp_path / "learn.json"))
    monkeypatch.setattr(pt, "PKT_BACKUP_DIR", str(tmp_path / "backups"))
    pkt_learning.reset()

    plan = json.loads(open(PLAN, encoding="utf-8").read())
    hashes, reports = [], []
    for i in range(1, 5):
        rep = pt.pkt_generate(plan, project="learn-lab",
                              filename="learn-lab", replace=True)
        reports.append(rep)
        hashes.append(rep["sha256"])
        assert rep["deviceCount"] == 10 and rep["linkCount"] == 9
        assert os.path.isfile(rep["path"])
        assert rep["learning"]["generations"] == i
        # the companion manifest is written every time
        assert os.path.isfile(rep["path"] + ".netbuilder.json")

    # Deterministic: the same plan produces the same bytes every time.
    assert len(set(hashes)) == 1, hashes

    final = reports[-1]["learning"]
    assert final["repeat"] is True
    assert final["new"] == [], "after the first run nothing is new"
    assert "stable" in final["note"]

    # Whatever substitutions the machine made are captured, not lost.
    joined = " ".join(reports[-1]["warnings"])
    for used, requested in re.findall(r"used (\S+) instead of (\S+)", joined):
        assert any("%s -> %s" % (requested, used) in s
                   for s in final["known"]["substitutions"]), joined

    # A fresh store re-learns the same machine behaviour from scratch.
    pkt_learning.reset(str(tmp_path / "learn2.json"))
    again = pt.pkt_generate(plan, project="learn-lab", filename="learn-lab",
                            replace=True)
    assert again["learning"]["generations"] == 1
    if re.search(r"used \S+ instead of \S+", " ".join(again["warnings"])):
        assert again["learning"]["new"]
