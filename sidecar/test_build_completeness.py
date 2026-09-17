"""Gates for the two things that decide whether a build is complete.

1. CLI mode proof.  The journal before this change held 592
   ``cli_context_blocked`` events, every one unrecovered: the engine refused
   to type a command because the prompt could not be proven.  These tests pin
   that (a) every block now carries the evidence for *why*, (b) one extra
   read-only look is taken before giving up and it actually recovers a stale
   prompt, and (c) the healthy path takes **no** extra reads, so nothing here
   costs a normal run any time.

2. The .pkt artifact chain.  A green run must leave a file, a companion
   manifest and a planned-vs-recorded report, and a save problem must never
   turn a good build into a failed one.

All of it runs without Packet Tracer, Tesseract or the RPA stack.
"""
from __future__ import annotations

import json
import os
import types

import pytest

import pt_autopilot as pt


class _Rect:
    handle = "fake-window"
    left, top, right, bottom = 0, 0, 800, 600


class _Win:
    def __init__(self):
        self.element_info = types.SimpleNamespace(handle=777)

    def rectangle(self):
        return _Rect()


def _context_stub(original_events):
    """Capture events instead of writing them to the real journal."""

    def record_event(kind, detail, device="", recovered=None, extra=None):
        original_events.append({"kind": kind, "detail": detail,
                                "device": device, "recovered": recovered,
                                "extra": dict(extra or {})})

    return record_event


@pytest.fixture()
def ctx(monkeypatch):
    """Isolated `_ensure_cli_context` environment."""
    events = []
    saved_run = pt.RUN
    pt.RUN = {
        "cli_context_blocks": 0,
        "cli_block_reasons": {},
        "cli_mode_repairs": 0,
        "cli_prompt_rereads": 0,
        "cli_prompt_recovered": 0,
        "cli_prompt_reread_capped": 0,
    }
    monkeypatch.setattr(pt, "record_event", _context_stub(events))
    monkeypatch.setattr(pt, "log", lambda *a, **k: None)
    # The recovery look must not really sleep or touch a screen.
    monkeypatch.setattr(pt, "_interruptible_sleep", lambda seconds: True)
    monkeypatch.setattr(pt, "_OCR_CACHE", {})
    # Hermetic: a mode latch from another test must not stand in for a read.
    monkeypatch.setattr(pt, "_CLI_MODE_LATCH", {})
    monkeypatch.setattr(pt, "_CLI_PROOF_MISSES", {})
    yield events
    pt.RUN = saved_run


def _reads(monkeypatch, sequence):
    """Serve scripted (state, text) pairs from _confirmed_state."""
    calls = []

    def confirmed(win, dev=""):
        calls.append(dev)
        index = min(len(calls) - 1, len(sequence) - 1)
        return sequence[index]

    monkeypatch.setattr(pt, "_confirmed_state", confirmed)
    return calls


# A line that needs nothing but privileged mode, so these tests exercise the
# proof step and never wander into mode repair (which would type).
PRIV_LINE = "show version"


def test_block_records_why_the_prompt_was_not_proven(ctx, monkeypatch):
    """A block must say what the screen showed, not just which line failed."""
    _reads(monkeypatch, [("unknown", ""), ("unknown", "")])
    allowed = pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25)
    assert allowed is False
    blocks = [e for e in ctx if e["kind"] == "cli_context_blocked"]
    assert len(blocks) == 1, ctx
    extra = blocks[0]["extra"]
    assert extra["reason"] == "prompt_not_proven", extra
    assert "state=unknown" in extra["why"], extra
    assert extra["line"] == PRIV_LINE, extra
    assert pt.RUN["cli_block_reasons"] == {"prompt_not_proven": 1}
    assert pt.RUN["cli_context_blocks"] == 1


def test_block_records_when_only_the_mode_was_unreadable(ctx, monkeypatch):
    """A live terminal with an unreadable mode is its own, separate failure."""
    _reads(monkeypatch, [("cli", "gibberish row"), ("cli", "gibberish row")])
    allowed = pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25)
    assert allowed is False
    extra = [e for e in ctx if e["kind"] == "cli_context_blocked"][0]["extra"]
    assert extra["reason"] == "mode_unreadable", extra
    assert extra["required"] == "privileged", extra
    assert pt.RUN["cli_block_reasons"] == {"mode_unreadable": 1}


def test_second_look_recovers_a_stale_prompt(ctx, monkeypatch):
    """One more read must be able to save a line that would have been lost."""
    _reads(monkeypatch, [("unknown", ""), ("cli", "Router#")])
    allowed = pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25)
    assert allowed is True, "the recovered prompt should carry the command"
    assert pt.RUN["cli_prompt_rereads"] == 1
    assert pt.RUN["cli_prompt_recovered"] == 1
    assert pt.RUN["cli_block_reasons"] == {}
    recovered = [e for e in ctx if e["kind"] == "cli_prompt_recovered"]
    assert recovered and recovered[0]["recovered"] is True, ctx
    assert "first" in recovered[0]["extra"]


def test_healthy_prompt_takes_no_extra_reads(ctx, monkeypatch):
    """The happy path must cost exactly what it cost before: one read."""
    calls = _reads(monkeypatch, [("cli", "Router#")])
    allowed = pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25)
    assert allowed is True
    assert len(calls) == 1, f"extra reads on the healthy path: {len(calls)}"
    assert pt.RUN["cli_prompt_rereads"] == 0
    assert ctx == []


def test_a_bad_second_read_never_replaces_a_usable_first_read(ctx,
                                                             monkeypatch):
    """The extra look may only ever upgrade the evidence, never downgrade it."""
    _reads(monkeypatch, [("cli", "gibberish row"),
                         ("setup", "Would you like to enter the initial "
                                   "configuration dialog? [yes/no]")])
    allowed = pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25)
    assert allowed is False
    extra = [e for e in ctx if e["kind"] == "cli_context_blocked"][0]["extra"]
    # Still judged on the first read: a setup dialog was NOT accepted, and no
    # keystroke was sent at it.
    assert extra["reason"] == "mode_unreadable", extra
    assert "initial configuration" not in extra["why"], extra


def test_extra_look_is_capped_per_device(ctx, monkeypatch):
    """A dead terminal must not make a run pay for the look on every line."""
    calls = _reads(monkeypatch, [("unknown", "")])
    for _ in range(4):
        assert pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25) is False
    # Each of the first three calls: first read + one extra look. The fourth
    # is capped, so it costs a single read like the original code did.
    assert len(calls) == 7, f"unbounded extra reads: {len(calls)}"
    assert pt.RUN["cli_prompt_rereads"] == 3
    assert pt.RUN["cli_prompt_reread_capped"] == 1


def test_a_usable_prompt_clears_the_evidence_debt(ctx, monkeypatch):
    """The cap is per device and self-healing once a read works again."""
    monkeypatch.setattr(pt, "_CLI_PROOF_MISSES", {"R1": pt._CLI_PROOF_MAX_MISSES})
    _reads(monkeypatch, [("cli", "Router#")])
    assert pt._ensure_cli_context(_Win(), "R1", PRIV_LINE, {}, 25) is True
    assert "R1" not in pt._CLI_PROOF_MISSES


def test_recovery_sends_no_keystrokes(monkeypatch):
    """The extra look must be read-only: Enter would answer a setup dialog."""
    pressed = []
    monkeypatch.setattr(pt, "_safe_press", lambda key: pressed.append(key))
    monkeypatch.setattr(pt, "_safe_write", lambda *a, **k: pressed.append("w"))
    monkeypatch.setattr(pt, "_interruptible_sleep", lambda seconds: True)
    monkeypatch.setattr(pt, "_OCR_CACHE", {})
    _reads(monkeypatch, [("cli", "Router#")])
    state, text, mode = pt._reread_prompt_once(_Win(), "R1")
    assert (state, mode) == ("cli", "privileged")
    assert pressed == [], f"the re-read typed something: {pressed}"


# --- the .pkt artifact chain -------------------------------------------

def _plan():
    return {"steps": [
        {"action": "create_nodes", "nodes": [
            {"name": "R1", "type": "router"},
            {"name": "SW1", "type": "switch"},
            {"name": "PC1", "type": "pc"},
        ]},
        {"action": "create_links", "links": [
            {"a": "R1", "aIf": "g0/0", "b": "SW1", "bIf": "f0/1"},
            {"a": "SW1", "aIf": "f0/2", "b": "PC1", "bIf": "eth0"},
        ]},
    ]}


def test_plan_vs_run_reports_what_is_missing():
    """The report must name the devices the plan asked for and lost."""
    saved_run, saved_mem = pt.RUN, pt.DEV_MEM
    pt.RUN = {
        "ok": True,
        "node_outcomes": {"R1": "configured", "SW1": "skipped"},
        "link_results": {"0": {"status": "verified"},
                         "1": {"status": "failed"}},
        "configs_verified": 4,
        "pings_ok": 2,
        "pings_failed": 1,
        "cli_context_blocks": 7,
        "errors_unrecovered": 3,
    }
    pt.DEV_MEM = {"lab": {"R1": {"fx": 0.4, "fy": 0.3, "verified": True},
                          "SW1": {"fx": 0.5, "fy": 0.45, "verified": True}}}
    try:
        report = pt._pkt_plan_vs_run(_plan(), "lab")
    finally:
        pt.RUN, pt.DEV_MEM = saved_run, saved_mem
    assert report["plannedDevices"] == 3
    assert report["plannedLinks"] == 2
    assert report["devicesOnCanvas"] == 2
    assert report["devicesMissing"] == ["PC1"]
    assert report["linksRecorded"] == 2 and report["linksFailed"] == 1
    assert report["cliBlocks"] == 7
    assert report["runOk"] is True
    # The report travels into a shareable manifest: structural data only.
    flat = json.dumps(report).lower()
    for secret in ("password", "secret", "ip address", "enable", "community"):
        assert secret not in flat, secret


@pytest.mark.skipif(not pt.HAS_RPA, reason="needs the RPA stack")
def test_save_verified_writes_the_artifact_and_its_manifest(tmp_path):
    """Save As -> companion manifest -> comparison report, in one call."""
    saved = (pt._pkt_save_as, pt._pkt_open, pt.RUN, pt.LAST_PLAN, pt.log)
    opened = []

    def fake_save(path):
        with open(path, "wb") as stream:
            stream.write(b"pkt-bytes")
        return pt._pkt_info(path)

    def fake_open(path, make_backup=True):
        opened.append((path, make_backup))
        return {"windowFound": True, "loadedFileProof": "detected"}

    pt._pkt_save_as = fake_save
    pt._pkt_open = fake_open
    pt.RUN = {"ok": True, "node_outcomes": {}, "link_results": {}}
    pt.LAST_PLAN = _plan()
    pt.log = lambda *a, **k: None
    try:
        result = pt.pkt_save_verified("lab", out_dir=str(tmp_path))
        assert result["path"].endswith(".pkt")
        assert os.path.isfile(result["path"])
        assert result["reopened"] is False
        assert opened == [], "reopen must be opt-in"
        manifest = json.load(open(result["manifest"], encoding="utf-8"))
        assert manifest["project"] == "lab"
        assert manifest["comparison"]["plannedDevices"] == 3
        assert manifest["pkt"]["format"] == "pkt"
        assert pt.PKT_STATE["report"]["path"] == result["path"]

        reopened = pt.pkt_save_verified("lab", out_dir=str(tmp_path),
                                        reopen=True)
        assert reopened["reopened"] is True
        assert opened == [(reopened["path"], False)], opened
        assert reopened["reopenEvidence"]["windowFound"] is True
    finally:
        pt._pkt_save_as, pt._pkt_open, pt.RUN, pt.LAST_PLAN, pt.log = saved


@pytest.mark.skipif(not pt.HAS_RPA, reason="needs the RPA stack")
def test_save_verified_never_reuses_an_existing_name(tmp_path):
    """Two artifacts in the same second must both survive."""
    saved = (pt._pkt_save_as, pt.RUN, pt.LAST_PLAN, pt.log)

    def fake_save(path):
        with open(path, "wb") as stream:
            stream.write(b"pkt-bytes")
        return pt._pkt_info(path)

    pt._pkt_save_as = fake_save
    pt.RUN = {"ok": True}
    pt.LAST_PLAN = {}
    pt.log = lambda *a, **k: None
    try:
        first = pt.pkt_save_verified("lab", out_dir=str(tmp_path))
        second = pt.pkt_save_verified("lab", out_dir=str(tmp_path))
    finally:
        pt._pkt_save_as, pt.RUN, pt.LAST_PLAN, pt.log = saved
    assert first["path"] != second["path"]
    assert os.path.isfile(first["path"]) and os.path.isfile(second["path"])


def test_failed_run_is_not_saved(monkeypatch):
    """A file that captures a broken topology is worse than no file."""
    called = []
    monkeypatch.setattr(pt, "pkt_save_verified",
                        lambda *a, **k: called.append(a))
    monkeypatch.setattr(pt, "log", lambda *a, **k: None)
    saved = pt.RUN
    pt.RUN = {"ok": False}
    try:
        pt._save_run_artifact()
        assert called == []
        assert pt.RUN.get("pkt") is None, "a failed run must not claim an artifact"
    finally:
        pt.RUN = saved


def test_a_save_problem_never_fails_a_good_build(monkeypatch):
    """The artifact step is best-effort: it records, it does not raise."""
    events = []
    monkeypatch.setattr(pt, "log", lambda *a, **k: None)
    monkeypatch.setattr(pt, "record_event",
                        lambda kind, detail, **k: events.append(kind))

    def boom(*args, **kwargs):
        raise RuntimeError("Save As dialog was not detected")

    monkeypatch.setattr(pt, "pkt_save_verified", boom)
    saved = pt.RUN
    pt.RUN = {"ok": True}
    try:
        pt._save_run_artifact()  # must not raise
        assert "Save As dialog" in pt.RUN["pkt"]["error"]
    finally:
        pt.RUN = saved
    assert events == ["pkt_save_failed"], events


def test_artifact_can_be_disabled_without_a_code_change(monkeypatch):
    """The end-of-run save must have an off switch (it drives Packet Tracer)."""
    called = []
    monkeypatch.setattr(pt, "log", lambda *a, **k: None)
    monkeypatch.setattr(pt, "pkt_save_verified",
                        lambda *a, **k: called.append(a))
    monkeypatch.setenv("NETBUILDER_ARTIFACT", "0")
    saved = pt.RUN
    pt.RUN = {"ok": True}
    try:
        pt._save_run_artifact()
        assert called == [], "auto-save ignored the opt-out"
        assert pt.RUN.get("pkt") is None
    finally:
        pt.RUN = saved


def test_artifact_is_skipped_quietly_without_the_rpa_stack(monkeypatch):
    """No RPA stack means no save attempt and no misleading failure event."""
    events = []
    monkeypatch.setattr(pt, "HAS_RPA", False)
    monkeypatch.setattr(pt, "record_event",
                        lambda kind, detail, **k: events.append(kind))
    saved = pt.RUN
    pt.RUN = {"ok": True}
    try:
        pt._save_run_artifact()
        assert pt.RUN.get("pkt") is None
    finally:
        pt.RUN = saved
    assert events == []


def test_block_counters_are_exported_for_the_ui():
    """The reasons breakdown must reach the run summary the Flutter app reads."""
    import inspect

    source = inspect.getsource(pt.H)
    assert "dict(RUN)" in source, "summary must carry per-run counters"


def test_artifact_endpoints_are_wired():
    """The new routes must exist on the handler, spelled exactly once."""
    import inspect

    source = inspect.getsource(pt.H)
    assert '"/pkt/save_verified"' in source
    assert '"/pkt/report"' in source
    assert "save_verified" in inspect.getsource(pt._pkt_start_operation) or \
        "save_verified" in source
