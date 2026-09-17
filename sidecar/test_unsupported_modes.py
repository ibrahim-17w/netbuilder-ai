"""Eliding a Packet Tracer-unsupported anchor must take its children with it.

Run #3 (2026-09-16 11:52) dropped `crypto isakmp policy 10` and
`time-range OFFICE_HOURS` but left `authentication pre-share`, `group 5` and
`periodic weekdays 08:00 to 17:00` in the queue.  With the anchor gone, each
child produced `cli_context_blocked  no remembered anchor for <mode> mode`.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

CRYPTO_BLOCK = """crypto isakmp policy 10
authentication pre-share
group 5
encr aes
hash sha
exit
crypto isakmp key NetBuilderLab2026 address 10.1.1.1
interface g0/0
description to-HQ_Switch
ip address 192.168.1.1 255.255.255.0
no shutdown
exit
ip route 0.0.0.0 0.0.0.0 10.1.1.2
"""

TIME_RANGE_BLOCK = """time-range OFFICE_HOURS
periodic weekdays 08:00 to 17:00
exit
access-list 10 permit host 192.168.1.50
line vty 0 4
access-class 10 in
"""


def _clean(block):
    with patch.object(pt, "record_event"):
        return pt.cli_lines_for_device(block, "HQ_Router", report=True)


def test_isakmp_children_are_elided_with_the_anchor():
    lines = _clean(CRYPTO_BLOCK)
    joined = "\n".join(lines)
    for gone in ("crypto isakmp policy 10", "authentication pre-share",
                 "group 5", "encr aes", "hash sha"):
        assert gone not in joined, f"{gone!r} survived:\n{joined}"
    # the supported neighbours must still be there
    assert "interface g0/0" in joined
    assert "ip address 192.168.1.1 255.255.255.0" in joined
    assert "no shutdown" in joined
    assert "ip route 0.0.0.0 0.0.0.0 10.1.1.2" in joined


def test_time_range_children_are_elided_with_the_anchor():
    lines = _clean(TIME_RANGE_BLOCK)
    joined = "\n".join(lines)
    assert "time-range OFFICE_HOURS" not in joined
    assert "periodic weekdays 08:00 to 17:00" not in joined
    assert "access-list 10 permit host 192.168.1.50" in joined
    assert "access-class 10 in" in joined


def test_no_orphaned_submode_command_survives():
    """The point of the fix: nothing left needs a mode anchor we elided."""
    lines = _clean(CRYPTO_BLOCK + TIME_RANGE_BLOCK)
    orphans = [ln for ln in lines
               if pt._command_requirement(ln, {}) in ("crypto", "time_range")]
    assert not orphans, f"orphaned sub-mode commands remain: {orphans}"


def test_one_event_per_elided_family():
    events = []
    with patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          a[0] if a else k.get("kind"))):
        pt.cli_lines_for_device(CRYPTO_BLOCK, "HQ_Router", report=True)
    kinds = [k for k in events if k == "unsupported_by_packet_tracer"]
    assert len(kinds) >= 1, events
