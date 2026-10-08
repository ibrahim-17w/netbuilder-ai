"""The auto-teach loop: a proposal must reach a REAL, verified teach run.

Audit weakness #2: `_auto_teach_after_suggest` returned `started: True`
without starting anything, so accepted suggestions sat `proposed` forever and
verified advice never became a taught rule.  These tests pin the closure:

* a pending correction is only started when it can name its own verification
  (store, slot key, device, and a step from the failing run's plan);
* the run is the same bounded path a human teach run uses, under the same
  activity lock, and one pass starts at most one run;
* anything unresolvable stays `proposed` with the reason recorded - nothing
  is ever promoted on faith;
* a correction the run never reached gets NO verdict (neither a promotion
  nor a false rejection), even when the run finished OK;
* the suggest pass can finally see real failures (signature separator) and
  lifts the device/slot evidence a teach run needs.

NOTHING here needs Packet Tracer, Tesseract or the RPA stack.
"""
from __future__ import annotations

import json

import pytest

import learning_memory as lm
import pt_autopilot as pt


@pytest.fixture(autouse=True)
def _journal_isolation(tmp_path, monkeypatch):
    """The journal and experience files must not be the developer's own."""
    monkeypatch.setattr(pt, "JOURNAL_FILE", str(tmp_path / "failures.jsonl"))
    monkeypatch.setattr(pt, "EXPERIENCE_FILE",
                        str(tmp_path / "experience.jsonl"))
    monkeypatch.setattr(pt, "JOURNAL_AGG_FILE", str(tmp_path / "agg.json"))
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
    pt.JOURNAL_AGG = {"events": -1, "kinds": {}, "signatures": {}}
    yield tmp_path
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()


def _pending_label_correction(slot_key="cmd", device="MGR1"):
    return pt.CORRECTIONS.propose(
        failure_kind="pc_wrong_panel", project="office", device=device,
        dtype="PC-PT",
        target={"kind": "label", "label": "Command Prompt",
                "scope": "dtype", "key": slot_key})


def _last_plan(project="office"):
    return {
        "project": project,
        "mode": "full",
        "steps": [
            {"action": "create_nodes",
             "nodes": [{"name": "PC1", "type": "pc"}]},
            {"action": "config_pcs",
             "pcs": {"MGR1": {"ip": "192.168.10.10"}}},
            {"action": "config_pcs",
             "pcs": {"PC2": {"ip": "192.168.10.11"}}},
        ],
    }


# --- resolving a teach spec -------------------------------------------

def test_teach_spec_needs_the_slot_key():
    _pending_label_correction(slot_key="")
    row = pt.CORRECTIONS.pending()[0]
    spec, why = pt._teach_spec_for(row, "office")
    assert spec == {}
    assert "slot key" in why


def test_teach_spec_needs_the_device():
    pt.CORRECTIONS.propose(failure_kind="pc_wrong_panel", project="office",
                           target={"kind": "label", "label": "Command Prompt",
                                   "key": "cmd"})
    row = pt.CORRECTIONS.pending()[0]
    spec, why = pt._teach_spec_for(row, "office")
    assert spec == {}
    assert "device" in why


def test_teach_spec_narrows_the_failing_step_to_the_device(monkeypatch):
    _pending_label_correction()
    row = pt.CORRECTIONS.pending()[0]
    monkeypatch.setattr(pt, "LAST_PLAN", _last_plan())
    spec, why = pt._teach_spec_for(row, "office")
    assert why == ""
    assert spec["store"] == "pc_tile" and spec["key"] == "cmd"
    assert spec["device"] == "MGR1"
    assert len(spec["steps"]) == 1, "one re-attempt, not a rebuild"
    step = spec["steps"][0]
    assert step["action"] == "config_pcs"
    assert list(step["pcs"]) == ["MGR1"], "only the failing device is retried"


def test_teach_spec_refuses_when_the_plan_is_gone(monkeypatch):
    _pending_label_correction()
    row = pt.CORRECTIONS.pending()[0]
    monkeypatch.setattr(pt, "LAST_PLAN", {})
    spec, why = pt._teach_spec_for(row, "office")
    assert spec == {}
    assert "plan" in why


# --- starting the run --------------------------------------------------

def test_auto_teach_starts_the_same_run_a_human_would(monkeypatch):
    row = _pending_label_correction()
    monkeypatch.setattr(pt, "LAST_PLAN", _last_plan())
    monkeypatch.setattr(pt, "HAS_RPA", True)
    monkeypatch.setattr(pt, "begin_activity", lambda kind: (True, ""))
    started = []
    monkeypatch.setattr(pt, "run_plan", lambda plan: started.append(plan))
    monkeypatch.setattr(pt, "AUTO_LEARN", {
        "enabled": True, "suggestAfterRun": True, "autoTeach": True,
        "lastAutoSuggest": "", "lastAutoTeach": "",
        "autoSuggestRuns": 0, "autoTeachRuns": 0})
    pt.AI_SUGGEST["running"] = False
    out = pt._auto_teach_after_suggest("office")
    assert out["started"] is True
    assert out["correctionId"] == row["id"]
    assert len(started) == 1, "one pass starts at most one bounded run"
    plan = started[0]
    assert plan["teach"][0]["store"] == "pc_tile"
    assert plan["teach"][0]["key"] == "cmd"
    assert plan["teach"][0]["device"] == "MGR1"
    assert plan["teach"][0]["correctionId"] == row["id"]
    assert plan["teachOf"] == row["id"]
    assert plan["steps"][0]["action"] == "config_pcs"
    assert pt.AUTO_LEARN["autoTeachRuns"] == 1
    assert pt.CORRECTIONS.get(row["id"])["teachRunAt"], \
        "the row records that a teach run was attempted"


def test_auto_teach_leaves_the_unresolvable_proposed(monkeypatch):
    pt.CORRECTIONS.propose(failure_kind="pc_wrong_panel", project="office",
                           device="MGR1", dtype="PC-PT",
                           target={"kind": "label",
                                   "label": "Command Prompt"})
    monkeypatch.setattr(pt, "LAST_PLAN", _last_plan())
    monkeypatch.setattr(pt, "HAS_RPA", True)
    started = []
    monkeypatch.setattr(pt, "run_plan", lambda plan: started.append(plan))
    pt.AI_SUGGEST["running"] = False
    out = pt._auto_teach_after_suggest("office")
    assert out["started"] is False
    assert started == [], "nothing verifiable means nothing runs"
    assert pt.CORRECTIONS.pending()[0]["status"] == "proposed"


# --- settlement only judges what the run reached -----------------------

def test_unreached_correction_gets_no_verdict_even_on_a_green_run():
    row = _pending_label_correction()
    # Armed but never looked up: the run reached the plan without the PC step
    # asking for this tile, so nothing on screen could prove the label.
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "label": "Command Prompt",
                               "correctionId": row["id"]}])
    pt.RUN["teachRun"] = [{"store": "pc_tile", "key": "cmd",
                           "device": "MGR1", "correctionId": row["id"]}]
    pt.RUN.pop("teachConsulted", None)
    results = pt._settle_teach_run(True)
    assert results[0]["pending"] is True
    assert pt.CORRECTIONS.get(row["id"])["status"] == "proposed"
    assert pt.PC_LEARNED == {}, "no promotion without proof"


def test_label_only_correction_promotes_the_verified_spot():
    row = _pending_label_correction()
    # The teach run reached the tile THROUGH the taught label and learned the
    # spot it verified; the correction itself carries no coordinates.
    pt._learn_spot("cmd", 0.31, 0.42, "MGR1")
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "label": "Command Prompt",
                               "correctionId": row["id"]}])
    pt.RUN["teachRun"] = [{"store": "pc_tile", "key": "cmd",
                           "device": "MGR1", "correctionId": row["id"]}]
    pt.RUN.pop("teachConsulted", None)
    pt._teach_override("pc_tile", "cmd", "MGR1")
    results = pt._settle_teach_run(True)
    assert results[0]["promoted"] is True
    entry = pt.PC_LEARNED[pt._pc_spot_key("cmd", "MGR1")]
    assert entry["taught"] is True and entry["correctionId"] == row["id"]
    assert (entry["fx"], entry["fy"]) == (0.31, 0.42)


def test_no_rpa_means_no_auto_run(monkeypatch):
    _pending_label_correction()
    monkeypatch.setattr(pt, "LAST_PLAN", _last_plan())
    monkeypatch.setattr(pt, "HAS_RPA", False)
    started = []
    monkeypatch.setattr(pt, "run_plan", lambda plan: started.append(plan))
    pt.AI_SUGGEST["running"] = False
    out = pt._auto_teach_after_suggest("office")
    assert out["started"] is False and out["reason"] == "no RPA"
    assert started == []


# --- the evidence the loop depends on ----------------------------------

def test_failure_context_carries_the_slot_the_journal_named():
    rows = [
        {"ts": "2026-10-01 10:00:00", "kind": "pc_wrong_panel",
         "device": "MGR1", "detail": "Terminal configuration",
         "recovered": False, "extra": {"tile": "cmd"}},
        {"ts": "2026-10-01 10:00:01", "kind": "pc_wrong_panel",
         "device": "MGR1", "detail": "Terminal configuration",
         "recovered": False, "extra": {"tile": "cmd"}},
    ]
    with open(pt.JOURNAL_FILE, "w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
    failures = pt._ai_failure_context("office")
    panel = [f for f in failures if f["kind"] == "pc_wrong_panel"]
    assert panel, ("the suggest pass must see a real kind:detail signature, "
                   "not only the test-only pipe form")
    assert panel[0]["slotKey"] == "cmd"
    assert panel[0]["device"] == "MGR1"


def test_corrections_may_carry_the_slot_key():
    norm = lm._norm_target({"kind": "label", "label": "X", "key": "cmd"})
    assert norm["key"] == "cmd"
    assert "key" not in lm._norm_target({"kind": "label", "label": "X"})


def test_unreached_event_is_not_offered_as_correctable():
    plan = lm.correction_plan("correction_unreached")
    assert plan["teachable"] is False


def test_teach_endpoint_starts_a_run_from_the_correction_alone(monkeypatch):
    """The app's "teach this one" path: POST /teach with just the id.

    Before this, `POST /teach` demanded store + key + steps, so the only
    caller that could start one was a caller that had already done the
    engine's resolution - which is why the app had no call site at all. The
    correction and the failing run's plan are enough; this drives it over
    real HTTP so the wire contract is what is under test.
    """
    import http.client
    import json as _json
    import threading
    from http.server import HTTPServer

    row = _pending_label_correction()
    monkeypatch.setattr(pt, "LAST_PLAN", _last_plan())
    monkeypatch.setattr(pt, "HAS_RPA", True)
    monkeypatch.setattr(pt, "begin_activity", lambda kind: (True, ""))
    started = []
    monkeypatch.setattr(pt, "run_plan", lambda plan: started.append(plan))

    server = HTTPServer(("127.0.0.1", 0), pt.H)
    port = server.server_address[1]
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    reply = {}

    def probe():
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request("POST", "/teach",
                         body=_json.dumps({"correctionId": row["id"],
                                           "project": "office"}),
                         headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            reply["status"] = response.status
            reply["body"] = _json.loads(response.read().decode())
            conn.close()
        except Exception as exc:  # noqa: BLE001 - reported via the assertion
            reply["error"] = exc

    worker = threading.Thread(target=probe, daemon=True)
    worker.start()
    worker.join(20)
    try:
        assert not worker.is_alive(), "/teach did not answer within 20s"
        assert "error" not in reply, reply.get("error")
        assert reply["status"] == 200, reply["body"]
        assert reply["body"]["ok"] is True
        assert len(started) == 1, "one POST must start exactly one bounded run"
        plan = started[0]
        assert plan["teachOf"] == row["id"]
        assert plan["teach"][0]["store"] == "pc_tile"
        assert plan["steps"][0]["action"] == "config_pcs"
    finally:
        server.shutdown()
        server.server_close()


def test_teach_endpoint_refuses_what_it_cannot_resolve(monkeypatch):
    """No plan in memory: refused with the reason, and nothing runs."""
    import http.client
    import json as _json
    import threading
    from http.server import HTTPServer

    row = _pending_label_correction()
    monkeypatch.setattr(pt, "LAST_PLAN", {})
    monkeypatch.setattr(pt, "HAS_RPA", True)
    monkeypatch.setattr(pt, "begin_activity", lambda kind: (True, ""))
    started = []
    monkeypatch.setattr(pt, "run_plan", lambda plan: started.append(plan))

    server = HTTPServer(("127.0.0.1", 0), pt.H)
    port = server.server_address[1]
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    reply = {}

    def probe():
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request("POST", "/teach",
                         body=_json.dumps({"correctionId": row["id"],
                                           "project": "office"}),
                         headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            reply["status"] = response.status
            reply["body"] = _json.loads(response.read().decode())
            conn.close()
        except Exception as exc:  # noqa: BLE001 - reported via the assertion
            reply["error"] = exc

    worker = threading.Thread(target=probe, daemon=True)
    worker.start()
    worker.join(20)
    try:
        assert not worker.is_alive(), "/teach did not answer within 20s"
        assert "error" not in reply, reply.get("error")
        assert reply["status"] == 409, reply["body"]
        assert reply["body"]["ok"] is False
        assert "plan" in reply["body"]["reason"], reply["body"]
        assert started == [], "an unverifiable correction starts nothing"
    finally:
        server.shutdown()
        server.server_close()
