"""The serial-module remedy must reach the journal, not just the docstring.

The plan validator warns that a default Packet Tracer 2911 has no serial
module. The user pointed out the actual remedy they verified by hand: the
Physical tab's MODULES list contains HWIC-2T, so the router can be powered off,
given an HWIC-2T, powered back on, and then really has s0/0/0. Every place the
sidecar reports a missing serial interface must carry that remedy.
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


def test_hint_names_the_module_and_the_procedure():
    hint = pt.SERIAL_MODULE_HINT
    assert "HWIC-2T" in hint
    assert "Physical tab" in hint
    assert "power the router off" in hint
    assert "power it back on" in hint
    assert "\n" not in hint
    assert len(hint) <= 195, "must fit inside a 200-character journal detail"


def _preflight(available_by_dev, privileged=("HQ_Router",)):
    events = []

    def fake_open(rect, dev, slot, project):
        return {"dev": dev}

    def fake_read(win):
        return set(available_by_dev.get((win or {}).get("dev", ""), ())), ""

    with patch.object(
            pt, "record_event",
            side_effect=lambda *a, **k: events.append(
                (a[0] if a else k.get("kind"), a[1] if len(a) > 1 else "",
                 k.get("recovered")))), \
         patch.object(pt, "_open_device_window", side_effect=fake_open), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_focus_cli_input", return_value=True), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli",
                      side_effect=lambda win, dev, delay_ms=25:
                      dev in privileged), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_read_interface_capabilities",
                      side_effect=fake_read), \
         patch.object(pt, "_close_device_window", return_value=None), \
         patch.object(pt, "log"):
        return pt._preflight_link_capabilities(
            RECT, [dict(l) for l in LINKS], SLOT_OF, "test"), events


def test_proven_absence_records_the_remedy():
    pt.RUN["interface_remaps"] = {}
    pt.RUN["link_results"] = {}
    pt.RUN["interfaces_unverified"] = 0
    pt.RUN["interfaces_blocked"] = 0
    pt.RUN["interface_blocked_devices"] = []
    # Gi0/0 and Gi0/2 proven, no serial -> no spare?  Gi0/1 is free, so this
    # remaps; make the spare unusable by proving only Gi0/0.
    _blocked, events = _preflight({"HQ_Router": {"gigabitethernet0/0"}})
    hints = [(d, r) for k, d, r in events if k == "serial_module_hint"]
    assert hints, f"the remedy must be journaled: {[k for k, _, _ in events]}"
    detail, recovered = hints[0]
    assert detail == pt.SERIAL_MODULE_HINT
    assert recovered is None, "the hint must not count as an unrecovered error"


def test_remap_also_reports_the_remedy():
    pt.RUN["interface_remaps"] = {}
    pt.RUN["link_results"] = {}
    pt.RUN["interfaces_unverified"] = 0
    pt.RUN["interfaces_blocked"] = 0
    pt.RUN["interface_blocked_devices"] = []
    available = {"HQ_Router": {"gigabitethernet0/0", "gigabitethernet0/1",
                               "gigabitethernet0/2"}}
    _blocked, events = _preflight(available)
    kinds = [k for k, _, _ in events]
    assert "interface_remapped" in kinds, kinds
    assert "serial_module_hint" in kinds, kinds
