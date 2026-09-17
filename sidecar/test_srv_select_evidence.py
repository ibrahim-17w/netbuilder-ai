"""A service row that cannot be opened must leave an explanation.

Both 2026-09-16 runs ended with `srv_service AAA1 aaa FAILED` and no supporting
event, because `_srv_select` only logged. The failure is now journalled with the
observed panel title, the OCR tail and a screenshot path.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

DEV = "AAA1"
WIN = object()


def _run_select(words, titles, svc="aaa"):
    events, shots, clicks = [], [], []

    def fake_win_words(win, psm=None):
        return words, 0, 0, 1000, 700

    title_seq = list(titles)

    def fake_panel_title(win):
        return title_seq.pop(0) if title_seq else ""

    with patch.object(pt, "_focus_pt_window", return_value=True), \
         patch.object(pt, "_win_words", side_effect=fake_win_words), \
         patch.object(pt, "_panel_title", side_effect=fake_panel_title), \
         patch.object(pt, "_safe_click",
                      side_effect=lambda x, y: clicks.append((x, y))), \
         patch.object(pt, "_close_open_panel", return_value=True), \
         patch.object(pt, "_safe_press", return_value=True), \
         patch.object(pt, "_fail_shot",
                      side_effect=lambda win, name: shots.append(name)), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_ocr_region",
                      return_value="SERVICES\nHTTP\nDHCP\nDHCPv6"), \
         patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          (a[0] if a else k.get("kind"),
                           k.get("extra") or {}))), \
         patch.object(pt, "log"):
        ok = pt._srv_select(WIN, DEV, svc)
    return ok, events, shots, clicks


def test_missing_row_reports_service_tail_and_shot():
    ok, events, shots, _clicks = _run_select(words=[], titles=[])
    assert ok is False
    failures = [e for e in events if e[0] == "srv_select_failed"]
    assert failures, [e[0] for e in events]
    _kind, extra = failures[0]
    assert extra["service"] == "aaa"
    assert extra["shot"].startswith("shots/") and extra["shot"].endswith(
        "_aaa_select_fail.png"), extra
    assert "DHCP" in extra["tail"], extra
    assert shots == [f"{DEV}_aaa_select_fail.png"], shots


def test_wrong_panel_reports_the_title_it_saw():
    """A click that lands on a different service must say which one."""
    words = [("aaa", 40, 300, 30, 12)]
    ok, events, _shots, clicks = _run_select(words=words,
                                             titles=["DNS"] * 4)
    assert ok is False
    assert clicks, "the row should still have been clicked once"
    mismatches = [e for e in events if e[0] == "srv_panel_mismatch"]
    assert mismatches, [e[0] for e in events]
    _kind, extra = mismatches[0]
    assert extra["service"] == "aaa"
    assert "DNS" in extra["title"], extra
    # and the dead end still explains itself
    assert [e for e in events if e[0] == "srv_select_failed"],         [e[0] for e in events]


def test_a_valid_aaa_panel_title_is_accepted():
    """The AAA pane is titled "AAA ..." - that must still verify."""
    words = [("aaa", 40, 300, 30, 12)]
    ok, events, _shots, _clicks = _run_select(words=words,
                                              titles=["AAA Accounting"])
    assert ok is True
    assert not [e for e in events if e[0] == "srv_panel_mismatch"]


def test_aaa_flow_reports_an_unverified_user():
    """The AAA flow's other silent exit: fields read back, no user row."""
    events = []
    with patch.object(pt, "_srv_select", return_value=True),          patch.object(pt, "_srv_radio_on", return_value=True),          patch.object(pt, "_srv_fill",
                      return_value=(True, {"fy": 0.3, "fx": 0.4})),          patch.object(pt, "_srv_button", return_value=True),          patch.object(pt, "_srv_panel_has", return_value=False),          patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          (a[0] if a else k.get("kind"),
                           k.get("extra") or {}))),          patch.object(pt, "log"):
        ok = pt._svc_flow_aaa(WIN, "AAA1",
                              {"users": [{"username": "netadmin",
                                           "password": "LabAdmin2026"}]})
    assert ok is False
    unverified = [e for e in events if e[0] == "aaa_user_unverified"]
    assert unverified, [e[0] for e in events]
    assert unverified[0][1]["username"] == "netadmin"


def test_aaa_flow_still_reports_a_missing_user():
    events = []
    with patch.object(pt, "_srv_select", return_value=True),          patch.object(pt, "_srv_radio_on", return_value=True),          patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(
                          a[0] if a else k.get("kind"))),          patch.object(pt, "log"):
        ok = pt._svc_flow_aaa(WIN, "AAA1", {})
    assert ok is False
    assert "aaa_user_missing" in events, events
