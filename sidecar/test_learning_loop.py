"""The learning loop: a mistake recorded once must change the next run.

Before 2026-09-18 the engine recorded 1,519 journal events and 2,859
experience rows and consumed none of them outside a UI list:

* `journal_suggestions()` produced advice strings for a human;
* `experience_memory.jsonl` was read only by the Memory screen and the
  diagnostics zip;
* `llm_reset_run()` cleared the only "which lines did we already ask about"
  set, so the same line was re-asked every run;
* `_run_reset()` wiped phases, action results, link results and node
  outcomes, so run N+1 could not know where run N died;
* a strategy was keyed on project + exact device name + layout + ptVersion,
  so a verified spot vanished as soon as a prompt was reworded.

These tests pin the new contracts.  All of them run without Packet Tracer,
Tesseract or the RPA stack.
"""
from __future__ import annotations

import json
import os
from unittest.mock import patch

import pytest

import learning_memory as lm
import pt_autopilot as pt


@pytest.fixture
def stores(tmp_path, monkeypatch):
    """Point every cross-run store at a temp file, and clear the memos."""
    monkeypatch.setattr(
        pt, "JOURNAL_FILE", str(tmp_path / "failures.jsonl"))
    monkeypatch.setattr(
        pt, "EXPERIENCE_FILE", str(tmp_path / "experience.jsonl"))
    monkeypatch.setattr(
        pt, "LLM_MEMORY", lm.LlmRejectionStore(str(tmp_path / "llm.json")))
    monkeypatch.setattr(
        pt, "RUN_LEDGER", lm.RunLedger(str(tmp_path / "ledger.json")))
    monkeypatch.setattr(
        pt, "CAPABILITIES", lm.CapabilityMap(str(tmp_path / "cap.json")))
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
    yield tmp_path
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()


def _write_journal(path, rows):
    with open(path, "w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")


def _event(kind, detail, device="", recovered=None, ts="2026-09-18 10:00:00"):
    return {"ts": ts, "kind": kind, "device": device, "detail": detail,
            "recovered": recovered}


# --- Phase 0: blockers are extracted from the journal --------------------

def test_blockers_skip_bookkeeping_and_recovered_events(stores):
    _write_journal(pt.JOURNAL_FILE, [
        # bookkeeping: emitted by every run, never actionable
        _event("phase_state", "verification -> running", recovered=False),
        _event("phase_state", "verification -> running", recovered=False),
        _event("run_finished", "issues: unrecovered=2", recovered=False),
        # a mistake, but one the engine always recovers from
        _event("cli_line_error", "line failed then recovered",
               device="R1", recovered=True),
        _event("cli_line_error", "line failed then recovered",
               device="R1", recovered=True),
        # the real thing
        _event("srv_fill_mismatch", "row read back wrong",
               device="SRV1", recovered=False),
        _event("srv_fill_mismatch", "row read back wrong",
               device="SRV1", recovered=False),
    ])
    blockers = pt.journal_blockers("") if hasattr(pt, "journal_blockers") \
        else pt.known_blockers("")
    kinds = {row["kind"] for row in blockers}
    assert "phase_state" not in kinds
    assert "run_finished" not in kinds
    assert "cli_line_error" not in kinds, "recovered events are not blockers"
    assert kinds == {"srv_fill_mismatch"}, blockers


def test_blockers_need_two_sightings(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("srv_fill_mismatch", "one-off", device="SRV1", recovered=False),
        _event("cli_context_blocked", "twice", device="R1", recovered=False),
        _event("cli_context_blocked", "twice", device="R1", recovered=False),
    ])
    patterns = [row["pattern"] for row in pt.known_blockers("")]
    assert "one-off" not in patterns
    assert "twice" in patterns


def test_blockers_rank_by_recurrence(stores):
    rows = []
    for _ in range(5):
        rows.append(_event("cli_context_blocked", "most common",
                           device="R1", recovered=False))
    for _ in range(2):
        rows.append(_event("srv_save_failed", "less common",
                           device="SRV1", recovered=False))
    _write_journal(pt.JOURNAL_FILE, rows)
    blockers = pt.known_blockers("")
    assert blockers[0]["count"] == 5
    assert blockers[0]["devices"] == ["R1"]
    assert blockers[1]["count"] == 2


def test_blockers_are_bounded(stores):
    rows = []
    for index in range(40):
        for _ in range(2):
            rows.append(_event("some_failure", f"distinct {index}",
                               device="R1", recovered=False))
    _write_journal(pt.JOURNAL_FILE, rows)
    assert len(pt.known_blockers("")) == pt.JOURNAL_BLOCKER_LIMIT


def test_journal_stats_and_blockers_agree_on_identity(stores):
    """Both layers must derive 'the same mistake' the same way."""
    _write_journal(pt.JOURNAL_FILE, [
        _event("cli_context_blocked", "live CLI prompt was not proven",
               device="R1", recovered=False),
        _event("cli_context_blocked", "live CLI prompt was not proven",
               device="R1", recovered=False),
    ])
    signature = "cli_context_blocked:live cli prompt was not proven"
    assert signature in dict(pt.journal_stats()["signatures"])
    assert pt.known_blockers("")[0]["pattern"] == \
        "live cli prompt was not proven"


def test_journal_rows_are_cached_but_not_stale(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("cli_context_blocked", "first", device="R1", recovered=False)])
    assert len(pt._journal_rows()) == 1
    assert len(pt._journal_rows()) == 1, "second read must be served"
    with open(pt.JOURNAL_FILE, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(
            _event("cli_context_blocked", "second", device="R1",
                   recovered=False)) + "\n")
    assert len(pt._journal_rows()) == 2, "a write must invalidate the cache"


def test_journal_rotation_archives_only_past_the_cap(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("cli_context_blocked", "small", device="R1", recovered=False)])
    assert pt._rotate_jsonl(pt.JOURNAL_FILE, max_bytes=1024 * 1024) is False
    assert pt._rotate_jsonl(pt.JOURNAL_FILE, max_bytes=10) is True
    # The journal is *moved*, so the next append recreates the active file
    # and the history is preserved in the single archive.
    archive = pt.JOURNAL_FILE + ".1"
    assert os.path.isfile(archive)
    assert not os.path.exists(pt.JOURNAL_FILE)
    with open(archive, encoding="utf-8") as stream:
        assert "small" in stream.read()
    # An append after rotation starts a fresh, correctly cached active file.
    with open(pt.JOURNAL_FILE, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(
            _event("srv_save_failed", "after rotation", device="SRV1",
                   recovered=False)) + "\n")
    assert len(pt._journal_rows()) == 1


# --- Phase 3: the ledger is the cross-run stuck point -------------------

def test_repeat_offenders_come_from_the_ledger(stores):
    ledger = pt.RUN_LEDGER
    failed = [{"action": "config_servers", "device": "SRV1",
               "reason": "pool table never updated"}]
    ledger.record("office-net", ok=False, still_failed=failed)
    ledger.record("office-net", ok=False, still_failed=failed)
    assert ledger.repeat_offenders("office-net") == [{
        "action": "config_servers", "device": "SRV1",
        "reason": "pool table never updated", "runs": 2}]
    # The journal has no project, so this must be project-scoped.
    assert ledger.repeat_offenders("another-project") == []


def test_one_failure_is_not_a_repeat_offender(stores):
    pt.RUN_LEDGER.record("office-net", ok=False, still_failed=[
        {"action": "config_pcs", "device": "PC1", "reason": "no IP"}])
    assert pt.RUN_LEDGER.repeat_offenders("office-net") == []


def test_a_recovery_breaks_the_consecutive_run_chain(stores):
    failed = [{"action": "paste_cli", "device": "R1", "reason": "prompt"}]
    pt.RUN_LEDGER.record("p", ok=False, still_failed=failed)
    pt.RUN_LEDGER.record("p", ok=False, still_failed=failed)
    pt.RUN_LEDGER.record("p", ok=True, still_failed=[])
    assert pt.RUN_LEDGER.repeat_offenders("p") == [], \
        "the step verified in the last run, so it is not a repeat offender"


def test_ledger_marks_a_blocker_from_a_previous_run(stores):
    failed = [{"action": "config_servers", "device": "SRV1",
               "reason": "pool table never updated"}]
    pt.RUN_LEDGER.record("office-net", ok=False, still_failed=failed)
    pt.RUN_LEDGER.record("office-net", ok=False, still_failed=failed)
    blockers = pt.known_blockers("office-net")
    repeats = [row for row in blockers if row["repeat"]]
    assert len(repeats) == 1, blockers
    assert repeats[0]["kind"] == "repeat_offender"
    assert repeats[0]["count"] == 2
    # and it is prompt-ready, naming the step rather than the OCR text
    line = next(line for line in pt.blocker_lines("office-net")
                if "config_servers on SRV1" in line)
    assert "pool table never updated" in line
    assert "2 consecutive runs" in line


def test_ledger_history_is_bounded(stores):
    for index in range(40):
        pt.RUN_LEDGER.record("p", ok=True)
    assert len(pt.RUN_LEDGER.runs("p")) == lm.LEDGER_RUNS_PER_PROJECT
    assert pt.RUN_LEDGER.previous("p")["ok"] is True


def test_unverified_actions_shape_matches_the_ledger(stores):
    pt.RUN["action_results"] = {
        "paste_cli:R1": {"action": "paste_cli", "device": "R1",
                         "status": "verified", "observed": "ok"},
        "config_servers:SRV1": {"action": "config_servers", "device": "SRV1",
                                "status": "failed",
                                "observed": "pool table never updated"},
        "config_pcs:PC1": {"action": "config_pcs", "device": "PC1",
                           "status": "skipped", "observed": "no canvas slot"},
    }
    rows = pt._unverified_actions()
    assert rows == [{"action": "config_servers", "device": "SRV1",
                     "reason": "pool table never updated"}]


# --- Phase 3: escalate once, then skip - but always report --------------

def _offender_setup(stores):
    failed = [{"action": "config_servers", "device": "SRV1",
               "reason": "pool table never updated"}]
    pt.RUN_LEDGER.record("office-net", ok=False, still_failed=failed)
    pt.RUN_LEDGER.record("office-net", ok=False, still_failed=failed)
    pt.RUN["repeatOffenders"] = pt.RUN_LEDGER.repeat_offenders("office-net")
    pt.RUN["repeat_offenders_escalated"] = []
    pt.RUN["known_blockers_skipped"] = []
    pt.RUN["known_blockers_skipped_count"] = 0
    pt.RUN["action_results"] = {
        "config_servers:SRV1": {"action": "config_servers", "device": "SRV1",
                                "status": "failed",
                                "observed": "pool table never updated"}}
    pt.SKIPPED_ACTIONS.clear()


def test_repeat_offender_is_escalated_once_then_skipped_and_reported(stores):
    _offender_setup(stores)
    events, asks = [], []

    def fake_escalate(project, dev, dtype, action, reason):
        asks.append((project, dev, action))
        return {"asked": True, "commands": ["ip dhcp excluded-address 1.1.1.1"],
                "explanation": "the excluded range covers the pool base"}

    with patch.object(pt, "_llm_escalate_blocker", side_effect=fake_escalate), \
         patch.object(pt, "record_event",
                      side_effect=lambda kind, detail, **kw: events.append(
                          (kind, detail, kw))), \
         patch.object(pt, "log"):
        remaining = pt._apply_repeat_offender_policy(
            "office-net", [("config_servers", "SRV1")], {"SRV1": "Server-PT"})
        # A second pass must not escalate or re-skip it.
        again = pt._apply_repeat_offender_policy(
            "office-net", [("config_servers", "SRV1")], {"SRV1": "Server-PT"})

    assert remaining == [] and again == [], "the step is no longer retried"
    assert len(asks) == 1, "escalated exactly once"
    assert "config_servers:SRV1" in pt.SKIPPED_ACTIONS

    kinds = [kind for kind, _, _ in events]
    assert "known_blocker_escalated" in kinds
    assert "known_blocker_skipped" in kinds
    escalated = next(kw for kind, _, kw in events
                     if kind == "known_blocker_escalated")
    assert "excluded range" in escalated["extra"]["diagnosis"]

    # REPORTED, never silent: the summary list and the counter both name it.
    assert pt.RUN["known_blockers_skipped_count"] == 1
    label = pt.RUN["known_blockers_skipped"][0]
    assert "config_servers on SRV1" in label
    assert "2 consecutive runs" in label


def test_a_step_that_is_not_an_offender_is_retried(stores):
    _offender_setup(stores)
    with patch.object(pt, "_llm_escalate_blocker") as escalate, \
         patch.object(pt, "record_event"), patch.object(pt, "log"):
        remaining = pt._apply_repeat_offender_policy(
            "office-net", [("paste_cli", "R2")], {"R2": "2911"})
    assert remaining == [("paste_cli", "R2")]
    escalate.assert_not_called()
    assert pt.RUN["known_blockers_skipped"] == []


def test_skipped_actions_are_dropped_from_the_repair_queue(stores):
    _offender_setup(stores)
    with patch.object(pt, "_llm_escalate_blocker",
                      return_value={"asked": False,
                                    "reason": "no budget"}), \
         patch.object(pt, "record_event"), patch.object(pt, "log"):
        pt._apply_repeat_offender_policy(
            "office-net", [("config_servers", "SRV1")], {"SRV1": "Server-PT"})
        assert ("config_servers", "SRV1") not in pt._failed_action_names()
    assert "config_servers:SRV1" in pt.SKIPPED_ACTIONS


# --- Phase 2: the LLM loop stops re-asking ------------------------------

def _configured_llm():
    pt.llm_configure(api_key="test-key", model="gemini-3.8-flash",
                     enabled=True)
    pt.llm_reset_run()
    pt.RUN.setdefault("llm_calls", 0)


def test_llm_ask_is_skipped_after_two_rejections(stores):
    _configured_llm()
    key = pt.command_key("description to-HQ_Switch")
    sample = "% Invalid input detected at ^ marker"
    for _ in range(2):
        pt.LLM_MEMORY.record(key, "interface", sample, "no usable suggestion")
    assert pt.LLM_MEMORY.blocked(key, "interface", sample)

    with patch.object(pt, "_llm_request",
                      side_effect=AssertionError("must not be called")), \
         patch.object(pt, "record_event") as event, \
         patch.object(pt, "log"):
        result = pt._llm_try_fix(object(), "office-net", "HQ_Router", "router",
                                "description to-HQ_Switch", sample, "interface")

    assert result == []
    assert pt.RUN["llm_calls"] == 0, "a skipped ask costs no budget"
    assert pt.RUN["llm_asks_skipped"] == 1
    assert "llm_ask_skipped" in [
        call.args[0] for call in event.call_args_list]


def test_a_single_rejection_still_gets_one_more_try(stores):
    _configured_llm()
    key = pt.command_key("hostname R1")
    sample = "% Invalid input"
    pt.LLM_MEMORY.record(key, "privileged", sample, "no usable suggestion")
    assert not pt.LLM_MEMORY.blocked(key, "privileged", sample)
    with patch.object(pt, "_llm_request", return_value="not json"), \
         patch.object(pt, "record_event"), patch.object(pt, "log"):
        result = pt._llm_try_fix(object(), "p", "R1", "router", "hostname R1",
                                 sample, "privileged")
    assert result == []
    assert pt.RUN["llm_calls"] == 1, "one rejection is a flake, not a pattern"


def test_rejection_survives_llm_reset_run(stores):
    """The budget is per-run; the memory of a rejected ask must not be."""
    _configured_llm()
    key = pt.command_key("ip route 0.0.0.0 0.0.0.0 10.1.1.2")
    sample = "% Incomplete command"
    pt.LLM_MEMORY.record(key, "privileged", sample, "did not clear")
    pt.llm_reset_run()
    assert pt.LLM_MEMORY.blocked(key, "privileged", sample) is False
    pt.LLM_MEMORY.record(key, "privileged", sample, "did not clear")
    pt.llm_reset_run()
    assert pt.LLM_MEMORY.blocked(key, "privileged", sample) is True
    assert pt.LLM_ASKED == set(), "the per-run set is still cleared"


def test_verified_fix_retires_the_block(stores):
    _configured_llm()
    key = pt.command_key("description to-HQ_Switch")
    sample = "% Invalid input"
    pt.LLM_MEMORY.record(key, "interface", sample, "no usable suggestion")
    assert pt.LLM_MEMORY.row(key, "interface", sample)["rejections"] == 1

    answer = json.dumps({"commands": ["interface g0/2"],
                         "explanation": "use the second port"})
    with patch.object(pt, "_llm_request", return_value=answer), \
         patch.object(pt, "_term_error_signature",
                      side_effect=[(1, "err"), (0, "ok")]), \
         patch.object(pt, "_ensure_cli_context", return_value=True), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), patch.object(pt, "log"):
        result = pt._llm_try_fix(object(), "office-net", "HQ_Router", "router",
                                "description to-HQ_Switch", sample, "interface")
    assert result == ["interface g0/2"]
    assert pt.LLM_MEMORY.row(key, "interface", sample) == {}, \
        "a verified fix retires the recorded rejection"
    assert not pt.LLM_MEMORY.blocked(key, "interface", sample)


def test_prompt_carries_blockers_and_rejections(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("srv_fill_mismatch", "row read back wrong",
               device="SRV1", recovered=False),
        _event("srv_fill_mismatch", "row read back wrong",
               device="SRV1", recovered=False),
    ])
    prompt = pt._llm_prompt(
        "office-net", "SRV1", "server", "ip dhcp pool LAN", "% Invalid",
        "privileged",
        blockers=pt.blocker_lines("office-net"),
        rejected=["2 earlier attempt(s) were rejected (no usable suggestion)"])
    assert "Known blockers from previous runs" in prompt
    assert "row read back wrong" in prompt
    assert "Already tried and REJECTED" in prompt
    assert "failing line: ip dhcp pool LAN" in prompt


def test_prompt_is_unchanged_when_there_is_nothing_to_report(stores):
    _write_journal(pt.JOURNAL_FILE, [])
    prompt = pt._llm_prompt("p", "R1", "router", "hostname R1", "% Invalid",
                            "privileged", blockers=[], rejected=[])
    assert "Known blockers" not in prompt
    assert "REJECTED" not in prompt


# --- Phase 6: capability facts -----------------------------------------

def test_pt_rejection_marks_the_capability_for_the_model(stores):
    pt.DEV_MEM["office-net"] = {"HQ_Router": {"type": "router",
                                              "model": "2911"}}
    with patch.object(pt, "record_event"), patch.object(pt, "log"):
        pt._record_unsupported("HQ_Router", "crypto map",
                               ["crypto map SITE_VPN 10 ipsec-isakmp",
                                "set peer 10.1.1.2"])
    assert pt.CAPABILITIES.reason("crypto map", "2911") == "crypto map"
    families = {row["family"] for row in pt.CAPABILITIES.proven_families("2911")}
    assert "crypto map" in families
    # and the planner is told about it
    assert any("crypto map" in row["family"]
               for row in pt.CAPABILITIES.proven_families("2911"))


def test_capability_is_dropped_when_the_run_proves_it_supported(stores):
    """A family is only ever recorded, never silently assumed."""
    assert pt.CAPABILITIES.reason("ospf", "2911") == ""
    assert pt.CAPABILITIES.proven_families("2911") == []


# --- Phase 4: a learned tactic must transfer ----------------------------

def _context(project="office-net", device="SRV1", model="Server-PT",
             dtype="server"):
    return {"project": project, "device": device, "type": dtype,
            "model": model, "ptVersion": "unknown", "layout": 4}


def _store(tmp_path):
    from learning_controller import StrategyStore
    return StrategyStore(str(tmp_path / "strategy_memory.json"))


def test_a_strategy_learned_here_is_visible_in_another_project(tmp_path):
    store = _store(tmp_path)
    spot = {"fx": 0.382, "fy": 0.2424, "kind": "octets"}
    store.record("field_row", "dhcp:start", _context(project="office-net"),
                 spot, "success", detail="verified")
    row = store.get("field_row", "dhcp:start",
                    _context(project="branch-net", device="SRV9"), spot)
    assert row is not None, "re-keying on project made this invisible before"
    assert row["successes"] == 1
    assert row["project"] == "office-net", "origin is kept as metadata"


def test_a_strategy_never_transfers_across_device_types_or_models(tmp_path):
    store = _store(tmp_path)
    spot = {"fx": 0.382, "fy": 0.2424}
    store.record("field_row", "dhcp:start", _context(model="Server-PT"),
                 spot, "success")
    assert store.get("field_row", "dhcp:start",
                     _context(model="PC-PT", dtype="pc"), spot) is None
    assert store.get("field_row", "dhcp:start",
                     _context(model="2911", dtype="router"), spot) is None


def test_a_local_strategy_outranks_a_borrowed_one(tmp_path):
    store = _store(tmp_path)
    local = {"fx": 0.1, "fy": 0.1}
    borrowed = {"fx": 0.2, "fy": 0.2}
    for _ in range(3):
        store.record("field_row", "dns:address",
                     _context(project="office-net"), local, "success")
        store.record("field_row", "dns:address",
                     _context(project="other-net"), borrowed, "success")
    ordered = store.candidates("field_row", "dns:address",
                               _context(project="office-net"),
                               [borrowed, local])
    assert ordered[0] == local, "a local hit must win a confidence tie"


def test_v1_migration_is_idempotent_and_merges_duplicates(tmp_path):
    from learning_controller import StrategyStore
    path = tmp_path / "strategy_memory.json"
    spot = {"fx": 0.382, "fy": 0.2424}
    rows = {}
    for index, (project, successes, failures) in enumerate([
            ("office-net", 2, 0), ("branch-net", 1, 1)]):
        context = _context(project=project)
        key = f"legacy{index}"
        rows[key] = {
            "id": key, "kind": "field_row", "scope": "dhcp:start",
            "context": context, "candidate": spot, "attempts": successes
            + failures, "successes": successes, "failures": failures,
            "confidence": 0.5, "quarantined": False,
            "created": "2026-09-09 15:14:08",
            "last_seen": f"2026-09-1{index} 15:14:08",
            "last_seen_epoch": 1788956048.0 + index,
            "last_detail": f"sighting {index}",
        }
    path.write_text(json.dumps({"schema": 1, "strategies": rows}),
                    encoding="utf-8")

    store = StrategyStore(str(path))
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["schema"] == 2
    assert len(data["strategies"]) == 1, \
        "both v1 rows describe the same tactic and must merge"
    merged = next(iter(data["strategies"].values()))
    assert merged["successes"] == 3
    assert merged["failures"] == 1
    assert merged["attempts"] == 4
    assert merged["last_detail"] == "sighting 1", "newest sighting wins"
    assert os.path.isfile(str(path) + ".v1.bak"), "the old file is kept"

    # Idempotent: loading the migrated file again changes nothing.
    first = path.read_text(encoding="utf-8")
    StrategyStore(str(path))
    assert path.read_text(encoding="utf-8") == first


def test_migration_keeps_the_legacy_key_out_of_the_new_key(tmp_path):
    from learning_controller import StrategyStore
    path = tmp_path / "strategy_memory.json"
    spot = {"fx": 0.5, "fy": 0.5}
    path.write_text(json.dumps({
        "schema": 1,
        "strategies": {"legacy": {
            "id": "legacy", "kind": "ui_coordinate", "scope": "cmd",
            "context": _context(project="office-net"),
            "candidate": spot, "attempts": 1, "successes": 1, "failures": 0,
            "confidence": 0.75, "quarantined": False,
            "ptVersion": "unknown",
            "last_seen_epoch": 1788956048.0}}}), encoding="utf-8")
    store = StrategyStore(str(path))
    row = store.get("ui_coordinate", "cmd",
                    _context(project="renamed-net", device="OTHER"), spot)
    assert row is not None and row["successes"] == 1
    assert "ptVersion" not in row, "ptVersion was pure noise in the key"


def test_eviction_drops_cold_never_successful_tactics(tmp_path):
    import time as _time
    from learning_controller import StrategyStore
    path = tmp_path / "strategy_memory.json"
    old = _time.time() - 90 * 86400
    tried = {"fx": 0.3, "fy": 0.3}
    worked = {"fx": 0.4, "fy": 0.4}
    path.write_text(json.dumps({
        "schema": 2,
        "strategies": {
            "never": {"id": "never", "kind": "field_row", "scope": "dhcp:start",
                      "context": _context(), "candidate": tried,
                      "attempts": 6, "successes": 0, "failures": 6,
                      "confidence": 0.05, "quarantined": True,
                      "last_seen_epoch": old},
            "worked": {"id": "worked", "kind": "field_row", "scope": "dns:x",
                       "context": _context(), "candidate": worked,
                       "attempts": 6, "successes": 1, "failures": 5,
                       "confidence": 0.3, "quarantined": False,
                       "last_seen_epoch": old},
        }}), encoding="utf-8")
    store = StrategyStore(str(path))
    remaining = store.summary()["strategies"]
    ids = {row["id"] for row in remaining}
    assert "never" not in ids, "a cold row that never worked is evicted"
    assert "worked" in ids, "a row with a success is never evicted"


# --- Phase 5: a ban must come with a replacement -----------------------

def test_a_quarantined_tactic_exposes_its_verified_replacement(tmp_path):
    from learning_controller import SessionLearningController, StrategyStore
    store = StrategyStore(str(tmp_path / "strategy_memory.json"))
    session = SessionLearningController(store, "s")
    context = _context()
    bad = [{"fx": 0.9, "fy": 0.9}]
    good = [{"fx": 0.2, "fy": 0.2}]
    session.failure("field_row", "dhcp:start", context, bad, "missed",
                    replaces=good)
    row = store.get("field_row", "dhcp:start", context, bad)
    assert row["replacement_verified"] is True
    assert store.replacement_for(row) == good
    assert session.replacement_for("field_row", "dhcp:start", context, bad) \
        == good


def test_quarantine_still_filters_and_never_substitutes(tmp_path):
    """`candidates` stays a filter: a caller must never be handed back a
    different coordinate as if it were the one it measured."""
    from learning_controller import SessionLearningController, StrategyStore
    store = StrategyStore(str(tmp_path / "strategy_memory.json"))
    session = SessionLearningController(store, "s")
    context = _context()
    bad = [{"fx": 0.9, "fy": 0.9}]
    good = [{"fx": 0.2, "fy": 0.2}]
    for _ in range(2):
        session.failure("field_row", "dhcp:start", context, bad, "missed",
                        replaces=good)
    chosen = session.choose("field_row", "dhcp:start", context, [bad])
    assert chosen == [], "the quarantined candidate is dropped"
    assert good not in chosen, "substitution does not happen implicitly"


def test_a_banned_candidate_without_a_replacement_yields_nothing(tmp_path):
    from learning_controller import SessionLearningController, StrategyStore
    store = StrategyStore(str(tmp_path / "strategy_memory.json"))
    session = SessionLearningController(store, "s")
    context = _context()
    bad = [{"fx": 0.9, "fy": 0.9}]
    session.failure("field_row", "dhcp:start", context, bad, "missed")
    row = store.get("field_row", "dhcp:start", context, bad)
    assert row.get("replacement_verified") is None
    assert store.replacement_for(row) is None
    assert session.replacement_for("field_row", "dhcp:start", context, bad) \
        is None


def test_a_replacement_equal_to_the_candidate_is_not_a_replacement(tmp_path):
    from learning_controller import StrategyStore
    store = StrategyStore(str(tmp_path / "strategy_memory.json"))
    context = _context()
    bad = [{"fx": 0.9, "fy": 0.9}]
    store.record("field_row", "dhcp:start", context, bad, "failure",
                 replaces=bad)
    assert store.replacement_for(
        store.get("field_row", "dhcp:start", context, bad)) is None


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
