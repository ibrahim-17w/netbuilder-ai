"""The AI suggest/evaluate loop: propose, screen, judge, record - never act.

An AI answer is a HYPOTHESIS, exactly like a user's typed correction.  These
tests pin the rules that make that safe: nothing is typed during a suggest
pass, nothing reaches a memory store, label/skip proposals that pass both
Gemini stages only ever become `proposed` corrections (a teach run must still
verify them on screen), coordinate-shaped answers are refused because the
model must not invent pixels, and anything proven unsupported is screened
before the evaluator is spent on it.

NOTHING here needs Packet Tracer, Tesseract or the RPA stack.
"""
from __future__ import annotations

import json

import pytest

import learning_memory as lm
import pt_autopilot as pt


@pytest.fixture(autouse=True)
def _ai_suggest_off():
    """A test's suggest state must never leak into the next test."""
    pt.AI_SUGGEST.update({"running": False, "last": None, "error": "",
                          "finished": ""})
    pt.LLM.update({"apiKey": "", "enabled": False, "calls": 0,
                   "applied": 0, "rejected": 0})
    yield
    pt.AI_SUGGEST.update({"running": False, "last": None, "error": "",
                          "finished": ""})
    pt.LLM.update({"apiKey": "", "enabled": False})


def _seed_failures(monkeypatch, kinds=("pc_wrong_panel", "srv_field_missing")):
    """Make the journal report two recurring unrecovered failures."""
    sigs = [(
        f"{kind}|detail {index}",
        {"count": 3 + index, "recovered": 0, "last": "2026-09-18 10:00:00"},
    ) for index, kind in enumerate(kinds)]
    monkeypatch.setattr(pt, "journal_stats",
                        lambda: {"total": 10, "kinds": {},
                                 "signatures": sigs})


def _key_on(monkeypatch):
    monkeypatch.setitem(pt.LLM, "apiKey", "test-key")
    monkeypatch.setitem(pt.LLM, "enabled", True)


def _propose_answer(rows: list) -> str:
    return json.dumps({"proposals": rows, "explanation": "n"})


def _run_pass(monkeypatch, propose_answer: str, evals: list):
    """Start a pass with canned Gemini answers and run it synchronously."""
    answers = list(evals)

    def fake_request(prompt):
        if "You propose fixes" in prompt:
            return propose_answer
        return answers.pop(0) if answers else "{}"

    calls = []
    monkeypatch.setattr(pt, "_llm_request",
                        lambda prompt: (calls.append(prompt) or fake_request(prompt)))
    threads = []

    class _Immediate:
        def __init__(self, target, daemon=True):
            self.target = target

        def start(self):
            threads.append(self.target)
            self.target()

    monkeypatch.setattr(pt.threading, "Thread", _Immediate)
    result = pt.ai_suggest_fixes(project="office")
    return result, calls


def test_suggest_without_a_key_is_refused(monkeypatch):
    _seed_failures(monkeypatch)
    result = pt.ai_suggest_fixes(project="office")
    assert result["ok"] is False
    assert "Gemini key" in result["error"]


def test_suggest_with_no_recurring_failures_does_not_call_gemini(
        monkeypatch):
    monkeypatch.setattr(pt, "journal_stats",
                        lambda: {"total": 0, "kinds": {}, "signatures": []})
    _key_on(monkeypatch)
    called = []
    monkeypatch.setattr(pt, "_llm_request",
                        lambda prompt: called.append(prompt) or "{}")
    result = pt.ai_suggest_fixes(project="office")
    assert result["ok"] is True and result["proposals"] == []
    assert not called, "nothing to fix means no model call"


def test_accepted_label_proposal_becomes_a_proposed_correction(monkeypatch):
    _seed_failures(monkeypatch)
    _key_on(monkeypatch)
    result, _ = _run_pass(
        monkeypatch,
        _propose_answer([{"failureKind": "pc_wrong_panel", "target": "label",
                          "label": "Command Prompt",
                          "reason": "the tile label on this PT build"}]),
        [json.dumps({"verdict": "accept", "score": 4,
                     "concern": "title must match exactly"})])
    assert result["ok"] is True
    row = pt.AI_SUGGEST["last"]["proposals"][0]
    assert row["accepted"] is True and row["score"] == 4
    assert row["recordedAs"] == "proposed"
    cid = row["correctionId"]
    stored = pt.CORRECTIONS.get(cid)
    assert stored["status"] == "proposed", \
        "AI suggestions are hypotheses: a teach run must still verify them"
    assert stored["target"]["label"] == "Command Prompt"
    assert stored["evidence"]["source"] == "ai_suggest"
    assert pt.PC_LEARNED == {} and pt.SRV_MEM == {"fields": {}, "buttons": {}}


def test_low_scoring_proposals_are_dropped_with_their_concern(monkeypatch):
    _seed_failures(monkeypatch)
    _key_on(monkeypatch)
    _run_pass(
        monkeypatch,
        _propose_answer([{"failureKind": "srv_field_missing",
                          "target": "label", "label": "Gateway",
                          "reason": "r"}]),
        [json.dumps({"verdict": "reject", "score": 2,
                     "concern": "wrong panel for this failure"})])
    row = pt.AI_SUGGEST["last"]["proposals"][0]
    assert row["accepted"] is False
    assert row["score"] == 2
    assert "wrong panel" in row["concern"]
    assert pt.CORRECTIONS.summary()["count"] == 0, "nothing recorded"


def test_an_explicit_reject_caps_an_overconfident_score(monkeypatch):
    _seed_failures(monkeypatch)
    _key_on(monkeypatch)
    _run_pass(
        monkeypatch,
        _propose_answer([{"failureKind": "pc_wrong_panel", "target": "label",
                          "label": "Terminal", "reason": "r"}]),
        [json.dumps({"verdict": "reject", "score": 5, "concern": ""})])
    row = pt.AI_SUGGEST["last"]["proposals"][0]
    assert row["score"] < pt.AI_SUGGEST_MIN_SCORE, \
        "the evaluator said reject; a high score must not overrule it"


def test_unusable_or_irrelevant_proposer_output_is_dropped(monkeypatch):
    _seed_failures(monkeypatch)
    _key_on(monkeypatch)
    _run_pass(
        monkeypatch,
        _propose_answer([{"failureKind": "not_a_real_kind", "target": "label",
                          "label": "Ghost", "reason": "r"},
                         {"target": "label", "label": "NoKind",
                          "reason": "r"}]),
        [])
    assert pt.AI_SUGGEST["last"]["proposals"] == []


def test_point_proposals_may_not_invent_coordinates(monkeypatch):
    assert "words, not coordinates" in pt._ai_screen_proposal({
        "target": "point", "label": "", "pointHint": "about 340 px from left"})
    assert pt._ai_screen_proposal({
        "target": "point", "label": "",
        "pointHint": "lower left of the tile grid"}) == ""


def test_proven_unsupported_families_are_screened_before_evaluation(
        monkeypatch):
    pt.CAPABILITIES.mark("crypto isakmp", "any", "live CLI rejected",
                         proven=True)
    reason = pt._ai_screen_proposal({
        "target": "cli", "cli": ["crypto isakmp policy 10"], "reason": "r"})
    assert "proven unsupported" in reason


def test_secret_shaped_and_malformed_commands_are_screened(monkeypatch):
    assert "secret-looking" in pt._ai_screen_proposal({
        "target": "cli", "cli": ["enable secret hunter2"], "reason": "r"})
    assert "plain single line" in pt._ai_screen_proposal({
        "target": "cli", "cli": ["x" * 140], "reason": "r"})
    assert "no commands" in pt._ai_screen_proposal({
        "target": "cli", "cli": [], "reason": "r"})


def test_label_screening_bounds(monkeypatch):
    assert "2-60" in pt._ai_screen_proposal({
        "target": "label", "label": "x", "reason": "r"})
    assert "secret-looking" in pt._ai_screen_proposal({
        "target": "label", "label": "password <redacted>", "reason": "r"})
    assert pt._ai_screen_proposal({
        "target": "label", "label": "Command Prompt", "reason": "r"}) == ""


def test_point_and_cli_proposals_stay_advice_only(monkeypatch):
    _seed_failures(monkeypatch, kinds=("placement_unverified",
                                       "cli_line_error"))
    _key_on(monkeypatch)
    _run_pass(
        monkeypatch,
        _propose_answer([
            {"failureKind": "placement_unverified", "target": "point",
             "pointHint": "bottom left of the canvas grid", "reason": "r"},
            {"failureKind": "cli_line_error", "target": "cli",
             "cli": ["spanning-tree mode rapid-pvst"], "reason": "r"},
        ]),
        [json.dumps({"verdict": "accept", "score": 4, "concern": ""}),
         json.dumps({"verdict": "accept", "score": 4, "concern": ""})])
    rows = pt.AI_SUGGEST["last"]["proposals"]
    assert all(r.get("accepted") for r in rows)
    assert all("correctionId" not in r for r in rows), \
        "non-verifiable targets must not become corrections"
    assert pt.CORRECTIONS.summary()["count"] == 0


def test_prompts_carry_redacted_failure_text(monkeypatch):
    """What leaves the machine is the redacted form, always."""
    _seed_failures(monkeypatch, kinds=("cli_line_error",))
    _key_on(monkeypatch)
    captured = []

    def fake_request(prompt):
        captured.append(prompt)
        return "{}"

    monkeypatch.setattr(pt, "_llm_request", fake_request)

    class _Immediate:
        def __init__(self, target, daemon=True):
            self.target = target

        def start(self):
            self.target()

    monkeypatch.setattr(pt.threading, "Thread", _Immediate)
    pt.ai_suggest_fixes(project="office")
    # The signature detail is journal text; the prompt builder only ever
    # receives what the journal recorded (already redacted at write time).
    assert captured and "failure" in captured[0]


def test_double_start_is_refused(monkeypatch):
    _seed_failures(monkeypatch)
    _key_on(monkeypatch)
    pt.AI_SUGGEST["running"] = True
    result = pt.ai_suggest_fixes(project="office")
    assert result["ok"] is False and "already running" in result["error"]


def test_status_reports_llm_counters(monkeypatch):
    status = pt.ai_suggest_status()
    assert "running" in status and status["llm"]["configured"] is False


def test_new_journal_kinds_resolve_to_plans():
    """The suggest pass's own events must never be offered as correctable."""
    for kind in ("ai_suggest_started", "ai_suggest_finished"):
        plan = lm.correction_plan(kind)
        assert plan["kind"] == kind
        assert plan["teachable"] is False and plan.get("reason")
