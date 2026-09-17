"""A latched privileged mode must not stand in for a fresh prompt read.

Regression cover for the 2026-09-15/16 runs where `configure terminal` was typed
into a live (config-if) prompt: `_normalize_to_privileged` returned "privileged"
straight off `_CLI_MODE_LATCH` instead of sending the `end` that would have made
it true. That rejected command failed the CLI stage, so no router interface got
an address and every ping timed out.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "HQ_Router"
WIN = object()


def _run(actual, prompt_text, mode_send_results, latch=None):
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
                      return_value=("cli", prompt_text)), \
         patch.object(pt, "_mode_send", side_effect=fake_mode_send), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        result = pt._normalize_to_privileged(WIN, DEV, actual, 25)
    pt._CLI_MODE_LATCH.pop(DEV, None)
    return result, calls


def test_latch_does_not_prove_privileged_out_of_a_submode():
    """The stale latch must not skip the `end` that actually leaves config."""
    result, calls = _run("interface", "HQ_Router(config-if)#",
                         ["privileged"], latch="privileged")
    assert "end" in calls, \
        f"a stale latch skipped the mode-repair `end`: {calls}"
    assert result == "privileged"


def test_no_second_end_when_the_fresh_read_is_privileged():
    """`end` reported a different sub-mode; a privileged re-read ends it."""
    result, calls = _run("interface", "HQ_Router#", ["config"],
                         latch="privileged")
    assert calls.count("end") == 1, f"expected exactly one `end`: {calls}"
    assert result == "privileged"


def test_no_second_end_while_a_submode_is_still_live():
    """Endless `end` retries are what produced `Translating "end"`."""
    result, calls = _run("interface", "HQ_Router(config)#", ["config"],
                         latch="privileged")
    assert calls.count("end") == 1, f"expected exactly one `end`: {calls}"
    assert result == "config"


def test_privileged_actual_types_nothing():
    result, calls = _run("privileged", "HQ_Router#", [], latch=None)
    assert result == "privileged"
    assert calls == []


def test_user_prompt_with_verified_latch_skips_enable():
    """The documented repaint race after `enable` is preserved."""
    result, calls = _run("user", "HQ_Router>", [], latch="privileged")
    assert result == "privileged"
    assert calls == []
