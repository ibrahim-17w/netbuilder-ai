"""Auto-learning: the engine must learn without a user click.

These pin the features added so the (already built) learning pipeline runs on
the engine's own triggers rather than only when a human presses a button:

* `maybe_auto_suggest` fires a bounded suggest pass after a run with recurring
  failures, honouring the master switch, the gap, and the LLM budget;
* `excluded_actions` gives the planner a machine-readable list of steps that
  must not be re-emitted verbatim after failing the same way twice;
* the offline CLI fallback proposes a supported spelling with NO model, and is
  only trusted after the terminal error clears;
* the journal aggregate is incremental, bounded, and rebuilds when the journal
  changes underneath it;
* `/memory/health` surfaces the otherwise-silent store parse failure;
* a verified replacement forces an immediate strategy write while an ordinary
  counter bump is coalesced.
"""
from __future__ import annotations

import json
import os

import pytest

import learning_controller as lc
import learning_memory as lm
import pt_autopilot as pt


@pytest.fixture
def stores(tmp_path, monkeypatch):
    """Point every cross-run store (and the aggregate) at temp files."""
    monkeypatch.setattr(
        pt, "JOURNAL_FILE", str(tmp_path / "failures.jsonl"))
    monkeypatch.setattr(
        pt, "EXPERIENCE_FILE", str(tmp_path / "experience.jsonl"))
    monkeypatch.setattr(
        pt, "JOURNAL_AGG_FILE", str(tmp_path / "agg.json"))
    monkeypatch.setattr(
        pt, "STRATEGY_MEM_FILE", str(tmp_path / "strategy.json"))
    monkeypatch.setattr(
        pt, "LLM_MEMORY", lm.LlmRejectionStore(str(tmp_path / "llm.json")))
    monkeypatch.setattr(
        pt, "RUN_LEDGER", lm.RunLedger(str(tmp_path / "ledger.json")))
    monkeypatch.setattr(
        pt, "CAPABILITIES", lm.CapabilityMap(str(tmp_path / "cap.json")))
    monkeypatch.setattr(
        pt, "CORRECTIONS", lm.CorrectionStore(str(tmp_path / "corr.json")))
    monkeypatch.setattr(
        pt, "STRATEGY_STORE", lc.StrategyStore(str(tmp_path / "strategy.json")))
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
    pt.JOURNAL_AGG = {"events": -1, "kinds": {}, "signatures": {}}
    pt.AUTO_LEARN.update({"enabled": True, "suggestAfterRun": True,
                          "autoTeach": True})
    pt._AUTO_SUGGEST_LAST.clear()
    yield tmp_path
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()


def _write_journal(path, rows):
    with open(path, "w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")


def _event(kind, detail, device="", recovered=None):
    return {"ts": "2026-10-01 10:00:00", "kind": kind, "device": device,
            "detail": detail, "recovered": recovered}


# --- the aggregate -------------------------------------------------------

def test_aggregate_counts_events_and_kinds(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("pc_wrong_panel", "Desktop tile opened the wrong panel",
               device="PC1", recovered=False),
        _event("pc_wrong_panel", "Desktop tile opened the wrong panel",
               device="PC2", recovered=False),
        _event("link_red", "red triangle after build", recovered=False),
    ])
    st = pt.journal_stats()
    assert st["total"] == 3
    assert st["kinds"]["pc_wrong_panel"]["count"] == 2
    assert st["kinds"]["link_red"]["count"] == 1


def test_aggregate_rebuilds_when_journal_changes_underneath(stores):
    _write_journal(pt.JOURNAL_FILE, [_event("link_red", "one", recovered=False)])
    assert pt.journal_stats()["total"] == 1
    # An external write (as a test or a manual edit would do) must be seen.
    _write_journal(pt.JOURNAL_FILE, [
        _event("link_red", "one", recovered=False),
        _event("link_red", "two", recovered=False),
    ])
    assert pt.journal_stats()["total"] == 2


def test_aggregate_is_bounded(stores):
    rows = [_event("cli_line_error", f"unique error {i}", recovered=False)
            for i in range(pt.JOURNAL_AGG_MAX_SIGNATURES + 60)]
    _write_journal(pt.JOURNAL_FILE, rows)
    agg = pt.journal_aggregate()
    assert len(agg["signatures"]) <= pt.JOURNAL_AGG_MAX_SIGNATURES


def test_experience_entries_are_capped(stores, monkeypatch):
    monkeypatch.setattr(pt, "EXPERIENCE_MAX_ENTRIES", 10)
    for i in range(25):
        pt._write_experience(_event("cli_line_error", f"e{i}", recovered=False))
    with open(pt.EXPERIENCE_FILE, encoding="utf-8") as stream:
        lines = [l for l in stream if l.strip()]
    assert len(lines) == 10
    # The newest survive.
    assert json.loads(lines[-1])["detail"] == "e24"


# --- excluded actions (planner enforcement) ------------------------------

def test_excluded_actions_lists_repeat_offenders(stores):
    pt.RUN_LEDGER.record("lab", ok=False, final_phase="verify",
                         still_failed=[{"action": "config_servers",
                                        "device": "SRV1",
                                        "reason": "field row missed"}])
    pt.RUN_LEDGER.record("lab", ok=False, final_phase="verify",
                         still_failed=[{"action": "config_servers",
                                        "device": "SRV1",
                                        "reason": "field row missed"}])
    excluded = pt.excluded_actions("lab")
    assert len(excluded) == 1
    assert excluded[0]["action"] == "config_servers"
    assert excluded[0]["device"] == "SRV1"


def test_excluded_actions_empty_for_unknown_project(stores):
    assert pt.excluded_actions("") == []
    assert pt.excluded_actions("never-seen") == []


# --- offline CLI fallback ------------------------------------------------

def test_offline_fallback_proposes_a_different_spelling():
    assert pt.offline_cli_proposal("conf t") == ["configure terminal"]
    assert pt.offline_cli_proposal("write memory") == ["write"]
    assert pt.offline_cli_proposal("exec-timeout 0") == ["exec-timeout 0 0"]


def test_offline_fallback_ignores_unknown_and_unsupported_lines():
    assert pt.offline_cli_proposal("router ospf 1") == []
    # A proven-unsupported family has no spelling that works.
    assert pt.offline_cli_proposal("crypto isakmp policy 10") == []


def test_offline_fallback_prerequisite_is_reported_not_guessed(stores):
    # `login local` needs a username first; the table says so instead of
    # inventing a re-spelling.
    assert pt.offline_cli_proposal("login local") == []


def test_offline_try_fix_only_returns_when_error_clears(monkeypatch):
    typed = []

    class FakeWin:
        pass

    monkeypatch.setattr(pt, "_ensure_cli_context",
                        lambda *a, **k: True)
    monkeypatch.setattr(pt, "_type_line",
                        lambda cmd, *a, **k: typed.append(cmd) or True)
    # before=2, after=3 -> a NEW error appeared -> fallback rejected.
    seq = iter([(2, "err"), (3, "err")])
    monkeypatch.setattr(pt, "_term_error_signature", lambda win: next(seq))
    monkeypatch.setattr(pt, "_OCR_CACHE", {})
    monkeypatch.setattr(pt, "_interruptible_sleep", lambda *a, **k: None)
    monkeypatch.setattr(pt, "record_event", lambda *a, **k: None)
    monkeypatch.setattr(pt, "stopped", lambda: False)
    out = pt.offline_cli_try_fix(FakeWin(), "p", "R1", "router", "conf t",
                                 "syntax error", "config")
    assert out == []
    assert typed == ["configure terminal"]


def test_offline_try_fix_returns_when_error_clears(monkeypatch):
    class FakeWin:
        pass

    monkeypatch.setattr(pt, "_ensure_cli_context", lambda *a, **k: True)
    monkeypatch.setattr(pt, "_type_line", lambda *a, **k: True)
    # before=2, after=2 -> no NEW error -> the fallback cleared it.
    seq = iter([(2, "err"), (2, "err")])
    monkeypatch.setattr(pt, "_term_error_signature", lambda win: next(seq))
    monkeypatch.setattr(pt, "_OCR_CACHE", {})
    monkeypatch.setattr(pt, "_interruptible_sleep", lambda *a, **k: None)
    monkeypatch.setattr(pt, "record_event", lambda *a, **k: None)
    monkeypatch.setattr(pt, "stopped", lambda: False)
    out = pt.offline_cli_try_fix(FakeWin(), "p", "R1", "router", "conf t",
                                 "syntax error", "config")
    assert out == ["configure terminal"]


# --- auto-suggest trigger ------------------------------------------------

def test_auto_suggest_skipped_without_recurring_failures(stores):
    # An empty journal has nothing to learn from.
    out = pt.maybe_auto_suggest("lab")
    assert out["started"] is False
    assert "no recurring failures" in out["reason"]


def test_auto_suggest_skipped_when_master_switch_off(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
    ])
    pt.AUTO_LEARN["enabled"] = False
    out = pt.maybe_auto_suggest("lab")
    assert out["started"] is False
    assert "off" in out["reason"]


def test_auto_suggest_refuses_without_llm_budget(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
    ])
    # No key configured -> llm_available() is False.
    out = pt.maybe_auto_suggest("lab")
    assert out["started"] is False
    assert "LLM" in out["reason"] or "budget" in out["reason"]


def test_auto_suggest_honours_gap_between_passes(stores, monkeypatch):
    _write_journal(pt.JOURNAL_FILE, [
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
        _event("pc_wrong_panel", "wrong panel", device="PC1", recovered=False),
    ])
    started = {"n": 0}

    def fake_suggest(project=""):
        started["n"] += 1
        return {"ok": True, "started": True}

    monkeypatch.setattr(pt, "ai_suggest_fixes", fake_suggest)
    monkeypatch.setattr(pt, "llm_available", lambda *a, **k: True)
    monkeypatch.setattr(pt, "AUTO_LEARN", {"enabled": True,
                                           "suggestAfterRun": True,
                                           "autoTeach": False,
                                           "lastAutoSuggest": "",
                                           "autoTeachRuns": 0,
                                           "autoSuggestRuns": 0,
                                           "lastAutoTeach": ""})
    pt._AUTO_SUGGEST_LAST.clear()
    first = pt.maybe_auto_suggest("lab")
    assert first["started"] is True
    # A second immediate call must be refused by the gap.
    second = pt.maybe_auto_suggest("lab")
    assert second["started"] is False
    assert "ago" in second["reason"]
    assert started["n"] == 1


# --- memory health -------------------------------------------------------

def test_memory_health_reports_stores(stores):
    health = pt.memory_health()
    assert "stores" in health
    assert isinstance(health["parseFailed"], list)
    names = {s["store"] for s in health["stores"]}
    assert "strategies" in names or "strategy" in names
    assert "journal" in names


def test_memory_health_flags_unreadable_store(stores):
    # Write a deliberately corrupt strategy file and point the store at it.
    with open(pt.STRATEGY_MEM_FILE, "w", encoding="utf-8") as stream:
        stream.write("{ this is not json")
    health = pt.memory_health()
    assert "strategy" in health["parseFailed"]
    assert health["ok"] is False
    assert health["warning"]


# --- coalesced strategy writes -------------------------------------------

def test_verified_replacement_is_written_immediately(tmp_path):
    store = lc.StrategyStore(str(tmp_path / "s.json"))
    ctx = {"project": "p", "device": "R1", "type": "router", "model": "2911"}
    store.record("cli_fallback", "command", ctx, ["bad line"], "failure",
                 persist=True, detail="x", replaces=["good line"])
    # The file must exist and contain the replacement without a flush().
    with open(str(tmp_path / "s.json"), encoding="utf-8") as stream:
        data = json.load(stream)
    rows = list(data["strategies"].values())
    assert any(r.get("replacement_verified") for r in rows)


def test_flush_persists_coalesced_counter_bumps(tmp_path):
    store = lc.StrategyStore(str(tmp_path / "s.json"))
    ctx = {"project": "p", "device": "R1", "type": "router", "model": "2911"}
    # A failure with no replacement only bumps a counter; it may be coalesced.
    store.record("ui_coordinate", "spot", ctx, [1, 2], "failure", persist=True)
    store.flush()
    with open(str(tmp_path / "s.json"), encoding="utf-8") as stream:
        data = json.load(stream)
    assert data["strategies"]



# --- idle learning pass --------------------------------------------------

def test_idle_pass_reports_journal_size(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("cli_line_error", "'crypto isakmp policy 10' still failing",
               device="R1", recovered=False),
    ])
    summary = pt.idle_learning_pass()
    assert summary["journalEvents"] == 1
    assert pt.IDLE_LEARN["runs"] >= 1


def test_idle_pass_marks_recurring_cli_family_as_suspect(stores):
    # The same command family failing three times should become a suspicion
    # even without any live run having marked it.
    rows = [_event("cli_line_error",
                   "'ip sla 1' still failing after fallback", recovered=False)
            for _ in range(lm.CAPABILITY_SUSPECT_AFTER)]
    _write_journal(pt.JOURNAL_FILE, rows)
    pt.idle_learning_pass()
    assert pt.CAPABILITIES.reason("ip sla", "any")


def test_idle_pass_folds_recovered_experience(stores):
    _write_journal(pt.JOURNAL_FILE, [
        _event("link_red", "red triangle", recovered=False),
    ])
    before = pt.journal_aggregate()["events"]
    pt.idle_learning_pass()
    after = pt.journal_aggregate()["events"]
    assert before == after == 1


# --- capability global promotion -----------------------------------------

def test_capability_promotes_after_three_distinct_models(tmp_path):
    cap = lm.CapabilityMap(str(tmp_path / "cap.json"))
    cap.mark("crypto isakmp", "2911", "unsupported", proven=False)
    cap.mark("crypto isakmp", "4331", "unsupported", proven=False)
    assert not cap.row("crypto isakmp", "2911").get("proven")
    cap.mark("crypto isakmp", "1941", "unsupported", proven=False)
    # Three distinct models -> install-wide gap -> proven.
    assert cap.row("crypto isakmp", "1941").get("proven")
    assert any(r["family"] == "crypto isakmp"
               for r in cap.proven_families())


def test_capability_never_demotes(tmp_path):
    cap = lm.CapabilityMap(str(tmp_path / "cap.json"))
    cap.mark("ip sla", "2911", "proven gap", proven=True)
    cap.mark("ip sla", "2911", "a later failure", proven=False)
    assert cap.row("ip sla", "2911").get("proven")


# --- correction identity uses model --------------------------------------

def test_correction_identity_distinguishes_models():
    a = lm.CorrectionStore.identity(
        {"kind": "label", "label": "Gateway", "scope": "model"},
        device="R1", dtype="router", model="2911")
    b = lm.CorrectionStore.identity(
        {"kind": "label", "label": "Gateway", "scope": "model"},
        device="R1", dtype="router", model="4331")
    assert a != b
    # Same model -> same identity.
    c = lm.CorrectionStore.identity(
        {"kind": "label", "label": "Gateway", "scope": "model"},
        device="R1", dtype="router", model="2911")
    assert a == c


def test_correction_identity_falls_back_to_dtype_without_model():
    a = lm.CorrectionStore.identity(
        {"kind": "label", "label": "Gateway", "scope": "model"},
        device="R1", dtype="router", model="")
    b = lm.CorrectionStore.identity(
        {"kind": "label", "label": "Gateway", "scope": "model"},
        device="R1", dtype="router", model="")
    assert a == b


# --- norm_target bool guard ----------------------------------------------

def test_norm_target_drops_bool_coordinates():
    out = lm._norm_target({"kind": "point", "fx": True, "fy": False})
    assert "fx" not in out
    assert "fy" not in out


def test_norm_target_keeps_zero_and_one():
    out = lm._norm_target({"kind": "point", "fx": 0.0, "fy": 1.0})
    assert out["fx"] == 0.0
    assert out["fy"] == 1.0
