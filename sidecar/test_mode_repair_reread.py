"""A repainted prompt must not make the mode repair give up.

2026-09-16 run: after `end` from (config-if) the OCR read the same sub-mode
again, `_normalize_to_privileged` returned it, and the caller then refused
`interface g0/0` - which cascaded into no router address and 14 failed pings.
One cache-free re-read distinguishes "still in the sub-mode" from "a stale
frame".
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "HQ_Router"
WIN = object()


def _run(actual, mode_send_results, fresh_prompt, latch=None):
    calls = []
    seq = list(mode_send_results)

    def fake_mode_send(win, dev, command, delay_ms, expected=None):
        calls.append(command)
        return seq.pop(0) if seq else (expected or "unknown")

    if latch is None:
        pt._CLI_MODE_LATCH.pop(DEV, None)
    else:
        pt._CLI_MODE_LATCH[DEV] = latch
    with patch.object(pt, "_confirmed_state",
                      return_value=("cli", fresh_prompt)), \
         patch.object(pt, "_mode_send", side_effect=fake_mode_send), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        result = pt._normalize_to_privileged(WIN, DEV, actual, 25)
    pt._CLI_MODE_LATCH.pop(DEV, None)
    return result, calls


def test_repainted_submode_is_re_read_and_privileged_wins():
    """`end` looked ineffective, but a fresh read proves Router#."""
    result, calls = _run("interface", ["interface"], "HQ_Router#",
                         latch="config")
    assert result == "privileged", result
    assert calls.count("end") == 1, f"exactly one `end` expected: {calls}"


def test_still_in_the_submode_after_a_fresh_read_gives_up():
    """No second `end`: that is what produced `Translating "end"`."""
    result, calls = _run("interface", ["interface"], "HQ_Router(config-if)#")
    assert result == "interface", result
    assert calls.count("end") == 1, f"exactly one `end` expected: {calls}"


def test_fresh_read_of_a_different_submode_is_adopted():
    result, calls = _run("interface", ["interface"], "HQ_Router(config)#")
    assert result == "config", result
