"""A failed security check must keep its reason readable in the journal.

`record_event` caps each extra value at 120 characters. Passing the whole
evidence dict as one value truncated it mid-word in the 2026-09-16 runs
(`'reason': 'prompt mode=user; CLI error/set`), so the operative fields are
now separate keys. These tests drive the real check loop with the device
window stubbed.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

WIN = object()
RECT = (0, 0, 1920, 1080)
SLOT_OF = {"BR_Router": 2}


def _drive(checks, prompt_text="BR_Router#", term_texts=()):
    """Run _verify_security_checks with every UI layer stubbed."""
    events = []
    seq = list(term_texts)

    def fake_term_texts(win):
        return seq.pop(0) if seq else ""

    with patch.object(pt, "stopped", return_value=False), \
         patch.object(pt, "_open_device_window", return_value=WIN), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli", return_value=True), \
         patch.object(pt, "_ensure_cli_context", return_value=True), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_term_texts", side_effect=fake_term_texts), \
         patch.object(pt, "_confirmed_state",
                      return_value=("cli", prompt_text)), \
         patch.object(pt, "_close_device_window", return_value=None), \
         patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          (a[0] if a else k.get("kind"),
                           k.get("recovered"), k.get("extra") or {}))), \
         patch.object(pt, "log"):
        ok = pt._verify_security_checks(RECT, checks, SLOT_OF, "secev-test")
    return ok, events


CHECK = [{"device": "BR_Router", "label": "branch ACL",
          "command": "show access-lists", "kind": "acl",
          "requiredMarkers": ["branch_to_hq"]}]


def test_failed_check_records_mode_and_full_reason():
    ok, events = _drive(CHECK, prompt_text="BR_Router>",
                        term_texts=["", "no access lists"])
    assert ok is False
    checks = [e for e in events if e[0] == "security_check"]
    assert checks, [e[0] for e in events]
    _kind, recovered, extra = checks[0]
    assert recovered is False
    assert extra["mode"] == "user", extra
    reason = extra["reason"]
    assert reason.startswith("prompt mode=user"), reason
    assert "CLI error/setup text present" in reason or reason, reason
    # the long stringified dict is still there for detail
    assert "evidence" in extra


def test_passing_check_records_privileged_mode():
    ok, events = _drive(
        [{"device": "BR_Router", "label": "route",
          "command": "show ip route", "requiredMarkers": ["10.1.1.0"]}],
        prompt_text="BR_Router#",
        term_texts=["", "O 10.1.1.0/30 via GigabitEthernet0/1"])
    assert ok is True
    checks = [e for e in events if e[0] == "security_check"]
    _kind, recovered, extra = checks[0]
    assert recovered is True
    assert extra["mode"] == "privileged", extra
    assert extra["typed"] in (True, "True"), extra


def test_evidence_reason_is_a_readable_string():
    ok, evidence = pt._security_check_evidence(
        {"kind": "generic", "requiredMarkers": ["enabled"]},
        "nothing useful here", "", "user", True)
    assert ok is False
    assert isinstance(evidence["reason"], str)
    assert "prompt mode=user" in evidence["reason"], evidence
    assert len(evidence["reason"]) <= 240
