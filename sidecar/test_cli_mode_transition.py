"""CLI mode transitions must be driven by a fresh prompt, not by a stale latch.

Regression cover for the 2026-09-15 run: `configure terminal` was typed inside a
(config-if) prompt, and a stray `end` was typed at a privileged prompt, where
Packet Tracer answered `Translating "end"` / `% Unknown command or computer
name`. A partial line also turned the final save into `writ write memory`.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "HQ_Router"
WIN = object()


def _run_ensure(line, prompt_text, latch=None):
    calls = {"mode_send": [], "normalize": []}

    def fake_mode_send(win, dev, command, delay_ms, expected=None):
        calls["mode_send"].append(command)
        return expected or "config"

    def fake_normalize(win, dev, actual, delay_ms):
        calls["normalize"].append(actual)
        return "privileged"

    if latch is None:
        pt._CLI_MODE_LATCH.pop(DEV, None)
    else:
        pt._CLI_MODE_LATCH[DEV] = latch
    with patch.object(pt, "_confirmed_state",
                      return_value=("cli", prompt_text)), \
         patch.object(pt, "_mode_send", side_effect=fake_mode_send), \
         patch.object(pt, "_normalize_to_privileged",
                      side_effect=fake_normalize), \
         patch.object(pt, "_safe_hotkey", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        ok = pt._ensure_cli_context(WIN, DEV, line, {}, 25)
    pt._CLI_MODE_LATCH.pop(DEV, None)
    return ok, calls


def _run_clear(prompt_text):
    hotkeys = []

    with patch.object(pt, "_confirmed_state",
                      return_value=("cli", prompt_text)), \
         patch.object(pt, "_safe_hotkey",
                      side_effect=lambda *k: hotkeys.append(k)), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        ok = pt._clear_pending_command(WIN, DEV, 25)
    return ok, hotkeys


def test_end_is_skipped_at_a_verified_privileged_prompt():
    ok, calls = _run_ensure("end", "HQ_Router#", latch="config")
    assert ok is True
    assert calls["mode_send"] == [], \
        "a stray `end` must not be typed at a privileged prompt"
    assert calls["normalize"] == [], \
        "no mode repair is needed when the prompt is already privileged"


def test_transition_line_ignores_a_stale_latch():
    """A stale privileged latch must not satisfy a transition command."""
    ok, calls = _run_ensure("end", "HQ_Router>", latch="privileged")
    assert ok is True
    assert calls["normalize"], \
        "the stale latch was trusted for a transition line"


def test_non_transition_line_still_uses_the_verified_latch():
    """The repaint guard must keep working for ordinary commands."""
    ok, calls = _run_ensure("show ip interface brief", "HQ_Router>",
                            latch="privileged")
    assert ok is True
    assert calls["normalize"] == [], \
        "the verified privileged latch should still cover a repaint race"


def test_pending_partial_line_is_cleared_before_saving():
    ok, hotkeys = _run_clear("HQ_Router#\nwrit")
    assert ok is True
    assert hotkeys, "a pending partial line must be abandoned with Ctrl+C"


def test_clean_prompt_is_left_alone():
    ok, hotkeys = _run_clear("HQ_Router#\nBuilding configuration...\n[OK]")
    assert ok is True
    assert hotkeys == [], "a clean prompt must not receive Ctrl+C"
