"""The boot-return dead end must leave evidence behind.

2026-09-16 run #2: ten `boot_return_blocked` events on HQ_Router, then
`boot_return_unresolvable`, and no screenshot - so the cause could not be
determined. The screen and the OCR tail are captured now.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "HQ_Router"
WIN = object()
BOOT_TEXT = ("Press RETURN to get started!\n"
             "Router>\n"
             "Press RETURN to get started!")


def _run_settle(rounds=3):
    events, shots = [], []

    with patch.object(pt, "_confirmed_state",
                      return_value=("return", BOOT_TEXT)), \
         patch.object(pt, "_finish_boot_return", return_value=False), \
         patch.object(pt, "_fail_shot",
                      side_effect=lambda win, name: shots.append(name)), \
         patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          (a[0] if a else k.get("kind"),
                           a[1] if len(a) > 1 else "",
                           k.get("extra") or {}))), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "log"):
        ok = pt._settle_boot_dialogs(WIN, DEV, rounds)
    return ok, events, shots


def test_unresolvable_keeps_a_screenshot_and_the_ocr_tail():
    ok, events, shots = _run_settle()
    assert ok is False
    unresolvable = [e for e in events if e[0] == "boot_return_unresolvable"]
    assert unresolvable, [e[0] for e in events]
    _kind, _detail, extra = unresolvable[0]
    assert extra.get("shot"), f"no screenshot recorded: {extra}"
    assert extra["shot"].startswith("shots/")
    assert extra["shot"].endswith("_boot_return_fail.png")
    assert "press return" in str(extra.get("tail", "")).lower(), extra
    assert shots == [f"{DEV}_boot_return_fail.png"], shots


def test_cli_unresolvable_also_keeps_a_screenshot():
    events, shots = [], []
    with patch.object(pt, "_confirmed_state",
                      return_value=("unknown", "garbled screen")), \
         patch.object(pt, "_fail_shot",
                      side_effect=lambda win, name: shots.append(name)), \
         patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          (a[0] if a else k.get("kind"),
                           k.get("extra") or {}))), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "log"):
        ok = pt._settle_boot_dialogs(WIN, DEV, 3)
    assert ok is False
    unresolvable = [e for e in events if e[0] == "cli_unresolvable"]
    assert unresolvable, [e[0] for e in events]
    extra = unresolvable[0][1]
    assert extra.get("shot", "").endswith("_cli_unresolvable.png"), extra
    assert shots == [f"{DEV}_cli_unresolvable.png"], shots
