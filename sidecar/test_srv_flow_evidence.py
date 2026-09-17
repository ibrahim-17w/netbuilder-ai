"""A service flow that fails without explaining itself must be caught.

Run #2 (2026-09-16 01:10) recorded SRV1 dns/ftp/ntp/tftp FAILED with no
explanatory event. The backstop in `_config_server_services` compares the
journalled-event count around each flow and records a reason when a failure
explained nothing.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "SRV1"
WIN = object()
RECT = (0, 0, 1920, 1080)


def _drive(flow, cfg=None):
    """Run one service through _config_server_services with the UI stubbed."""
    events = []

    def counting_record_event(kind, detail, device="", recovered=None,
                              extra=None):
        # mirrors the real function: count it and remember it
        pt._EventCounter.total += 1
        events.append((kind, extra or {}))

    with patch.object(pt, "_open_device_window", return_value=WIN), \
         patch.object(pt, "_dismiss_error_dialog", return_value=None), \
         patch.object(pt, "_srv_open_services", return_value=True), \
         patch.object(pt, "_svc_flow_http", side_effect=flow), \
         patch.object(pt, "_ocr_region",
                      return_value="HTTP\nOn\nOff\nFile Manager"), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event", side_effect=counting_record_event), \
         patch.object(pt, "log"):
        ok = pt._config_server_services(
            RECT, DEV, 7, {"services": cfg or {"http": {"on": True}}},
            "srvflow-test")
    return ok, events


def test_silent_failure_gets_a_generic_reason():
    pt._EventCounter.total = 0

    def silent_flow(win, dev, params):
        return False

    ok, events = _drive(silent_flow)
    assert ok is False
    kinds = [k for k, _ in events]
    assert "srv_flow_failed" in kinds, kinds
    extra = [e for k, e in events if k == "srv_flow_failed"][0]
    assert extra.get("service") == "http", extra
    assert "File Manager" in str(extra.get("panel", "")), extra
    assert "srv_service" in kinds, kinds


def test_self_explaining_failure_gets_no_duplicate():
    """A flow that journals its own reason must not get a second event."""
    pt._EventCounter.total = 0

    def explaining_flow(win, dev, params):
        pt.record_event("srv_field_missing", "label 'x' not found",
                        device=dev, recovered=False)
        return False

    ok, events = _drive(explaining_flow)
    assert ok is False
    kinds = [k for k, _ in events]
    assert "srv_field_missing" in kinds, kinds
    assert "srv_flow_failed" not in kinds, \
        "the backstop duplicated an existing explanation"


def test_success_records_no_backstop():
    pt._EventCounter.total = 0
    ok, events = _drive(lambda win, dev, params: True)
    assert ok is True
    kinds = [k for k, _ in events]
    assert "srv_flow_failed" not in kinds, kinds


def test_event_counter_tracks_real_record_event():
    """The counter the backstop relies on must move with record_event."""
    before = pt._EventCounter.total
    with patch.object(pt, "_write_experience"), \
         patch.object(pt, "log"):
        pt.record_event("counter_probe", "must increment", device=DEV)
    assert pt._EventCounter.total == before + 1
