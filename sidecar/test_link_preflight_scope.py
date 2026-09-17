"""Link-preflight scoping: a serial probe problem must not block LAN links.

Regression cover for the 2026-09-15 run where a serial probe failure on
HQ_Router blocked BOTH of its cables - including the unrelated
``g0/0 <-> HQ_Switch:f0/1`` link - leaving the router with no connections.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

LINKS = [
    {"a": "HQ_Router", "aIf": "s0/0/0", "b": "BR_Router", "bIf": "g0/1"},
    {"a": "HQ_Router", "aIf": "g0/0", "b": "HQ_Switch", "bIf": "f0/1"},
]
SLOT_OF = {"HQ_Router": 0, "BR_Router": 1, "HQ_Switch": 2}
RECT = (0, 0, 1920, 1080)


def _fresh_run():
    pt.RUN["interface_remaps"] = {}
    pt.RUN["link_results"] = {}
    pt.RUN["interfaces_unverified"] = 0
    pt.RUN["interfaces_blocked"] = 0
    pt.RUN["interface_blocked_devices"] = []


def _preflight(privileged_devs, available_by_dev, links=None):
    """Drive the preflight with every UI/OCR layer stubbed."""
    links = links if links is not None else [dict(l) for l in LINKS]
    events = []

    def fake_open(rect, dev, slot, project):
        return {"dev": dev}

    def fake_read(win):
        return set(available_by_dev.get((win or {}).get("dev", ""), ())), ""

    with patch.object(
            pt, "record_event",
            side_effect=lambda *a, **k: events.append(
                (a[0] if a else k.get("kind"), k.get("extra", {})))), \
         patch.object(pt, "_open_device_window", side_effect=fake_open), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_focus_cli_input", return_value=True), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli",
                      side_effect=lambda win, dev, delay_ms=25:
                      dev in privileged_devs), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_read_interface_capabilities",
                      side_effect=fake_read), \
         patch.object(pt, "_close_device_window", return_value=None):
        blocked = pt._preflight_link_capabilities(RECT, links, SLOT_OF, "test")
    return blocked, events, links


def test_probe_failure_holds_back_only_the_serial_link():
    """Link 0 asks for s0/0/0; link 1 (g0/0 <-> f0/1) must still be cabled."""
    _fresh_run()
    blocked, events, _ = _preflight(privileged_devs=set(), available_by_dev={})
    kinds = [k for k, _ in events]
    assert 1 not in blocked, f"the LAN link must not be blocked: {blocked}"
    assert blocked == {0}, f"only the serial link may be held back: {blocked}"
    assert "interface_probe_unverified" in kinds, kinds
    assert "link_blocked" in kinds, kinds


def test_probe_failure_never_marks_the_device_interface_blocked():
    _fresh_run()
    _preflight(privileged_devs=set(), available_by_dev={})
    assert pt.RUN.get("interface_blocked_devices") == [], \
        "a probe failure must not set a device-wide interface block"
    assert pt.RUN.get("interfaces_unverified", 0) >= 1
    assert pt.RUN.get("interfaces_blocked", 0) == 0


def test_proven_absence_remaps_the_wan_and_keeps_it_wired():
    """Serial0/0/0 missing while Gi0/1 is proven -> remap, do not block."""
    _fresh_run()
    available = {
        "HQ_Router": {"gigabitethernet0/0", "gigabitethernet0/1",
                      "gigabitethernet0/2"},
    }
    blocked, events, links = _preflight(privileged_devs={"HQ_Router"},
                                        available_by_dev=available)
    kinds = [k for k, _ in events]
    assert "interface_remapped" in kinds, kinds
    assert blocked == set(), f"the remapped WAN link must still be wired: {blocked}"
    assert pt.RUN["interface_remaps"].get("HQ_Router", {}).get("s0/0/0") == "g0/1"
    assert links[0]["aIf"] == "g0/1", links[0]
