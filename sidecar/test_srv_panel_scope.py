"""The Services list must not be read as the service panel.

Regression cover for the 2026-09-16 DHCP run. Its read-backs showed the DNS
panel while the flow believed it was filling the DHCP pool's DNS box:

  ``dns`` was filled and read back as
  ``wick ew ew wey 1J72.°1VU.t.t | DNS | DNG Conor Nnnnn``,
  ``mask`` / ``user`` / ``gateway`` / ``start`` were "not found".

Three code facts produced that: the sidebar row ``DNS`` is an EXACT token
match and outranked the panel's ``DNS Server`` row, the label search reached
out to 0.50 so the sidebar was inside it, and the fixed ``max_fy=0.58`` sat
above the real pool form. This file pins the evidence-based replacement: the
list band loses, a service word without a value box loses, the form bottom is
read from the panel's own button row, and a provably wrong panel is never
typed into. Runs without pyautogui/tesseract.

Run:  python test_srv_panel_scope.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402

PT_SIZE = (1000, 700)   # window px: many fractions land on round numbers


class DummyRPA:
    """Records every input action instead of moving the real mouse."""

    def __init__(self):
        self.calls = []

    def click(self, x, y):
        self.calls.append(("click", x, y))

    def hotkey(self, *keys):
        self.calls.append(("hotkey",) + keys)

    def write(self, text, interval=0.0):
        self.calls.append(("write", text))

    def press(self, key):
        self.calls.append(("press", key))


class FakeRect:
    left, top, right, bottom = 0, 0, PT_SIZE[0], PT_SIZE[1]


class FakeWin:
    _allow_unverified_focus_for_test = True

    def rectangle(self):
        return FakeRect()

    def set_focus(self):
        pass


TMP = tempfile.mkdtemp(prefix="srv_scope_")

# The real panel shape: the Services LIST occupies the left band (left of
# SRV_SIDEBAR_MAX_FX) and the DHCP pool FORM starts right of it - which is
# why the old 0.50 label ceiling admitted the list's own words while a
# ceiling of 0.35 would have cut the form away.  'dns' appears TWICE: once
# as the list entry (no value box on its line) and once as the first word of
# the panel's own 'DNS Server' row (digit box on its line, box still 0).
SIDEBAR_AND_FORM = [
    ("dhcp", 400, 40, 40, 14),           # panel title strip
    ("http", 40, 120, 34, 14),           # --- Services list ---
    ("dns", 40, 160, 28, 14),            # the row that stole the fill
    ("aaa", 40, 200, 28, 14),
    ("pool", 380, 250, 40, 14),          # --- panel form ---
    ("name", 425, 250, 44, 14),
    ("gateway", 380, 300, 40, 14),
    ("0", 700, 298, 14, 16),
    ("dns", 380, 340, 30, 14),           # 'DNS Server' row, same word
    ("server", 415, 340, 52, 14),
    ("0", 700, 338, 14, 16),
    ("start", 380, 380, 42, 14),
    ("ip", 427, 380, 16, 14),
    ("address", 448, 380, 56, 14),
    ("192", 560, 378, 28, 16),
    ("192", 600, 378, 28, 16),
    ("10", 640, 378, 20, 16),
    ("0", 680, 378, 14, 16),
    ("mask", 380, 420, 40, 14),
    ("add", 520, 470, 40, 16),           # the form's own bottom edge
    ("save", 600, 470, 40, 16),
    ("remove", 680, 470, 52, 16),
    ("pool", 380, 560, 40, 14),          # --- pool TABLE (under the form) ---
    ("startipaddress", 560, 560, 110, 14),
    ("serverpool", 380, 600, 80, 14),
]


def reset(words=SIDEBAR_AND_FORM):
    pt.SRV_MEM = {"fields": {}, "buttons": {}}
    pt.SRV_MEM_FILE = os.path.join(TMP, "srv_memory.json")
    pt.JOURNAL_FILE = os.path.join(TMP, "failures.jsonl")
    pt.RUN.pop("srv_probe", None)
    pt.pyautogui = DummyRPA()
    pt._win_words = lambda win: (words, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: ""
    pt._SRV_SHADOW_SEEN.clear()
    pt.ocr_cache_clear()
    return pt.pyautogui


def journal_kinds():
    try:
        with open(pt.JOURNAL_FILE, encoding="utf-8") as f:
            return [json.loads(line).get("kind") for line in f if line.strip()]
    except Exception:
        return []


def journal_rows():
    try:
        with open(pt.JOURNAL_FILE, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]
    except Exception:
        return []


# ---- the label search -------------------------------------------------

def test_sidebar_row_does_not_shadow_the_field_row():
    """'dns' as a list entry must not win over 'dns' as a field-row word."""
    reset()
    got = pt._srv_find_field_live(FakeWin(), "dns")
    assert got.get("fy") == round(347 / 700, 4), got   # the FORM row, not 167
    assert abs(got["fy"] - 167 / 700) > 0.05, "that is the sidebar row"
    assert got.get("kind") == "single", got
    assert "srv_sidebar_shadow" in journal_kinds(), journal_kinds()


def test_the_list_band_loses_when_no_value_box_is_available():
    """Both words spell 'dns' and neither has digits: the band decides."""
    words = [("dns", 40, 160, 28, 14),          # list entry
             ("dns", 420, 340, 30, 14)]         # panel row, box still empty
    reset(words)
    got = pt._srv_find_field_live(FakeWin(), "dns")
    assert got.get("fy") == round(347 / 700, 4), got


def test_a_service_word_loses_to_a_longer_panel_label():
    """An exact list entry must not beat the panel's own label word."""
    words = [("ftp", 40, 160, 28, 14),
             ("ftpserver", 420, 340, 90, 14)]
    reset(words)
    got = pt._srv_find_field_live(FakeWin(), "ftp")
    assert got.get("fy") == round(347 / 700, 4), got


def test_ordinary_empty_row_is_untouched_by_the_value_box_rule():
    """Pool Name has no digits yet - the box tier must not demote it."""
    reset()
    got = pt._srv_find_field_live(FakeWin(), "pool")
    assert got.get("fy") == round(257 / 700, 4), got
    # ...and the table's header row is not what got picked
    assert got.get("fy") < 0.5, got


# ---- the form bottom --------------------------------------------------

def test_form_bottom_is_read_from_the_panel_button_row():
    words = SIDEBAR_AND_FORM
    assert pt._srv_form_bottom(words, 700) == round(470 / 700 - 0.02, 4)
    # the table header sits UNDER that edge, so the token resolves to the form
    reset(words + [("mask", 380, 560, 40, 14)])
    got = pt._srv_find_field_live(FakeWin(), "mask")
    assert got.get("fy") == round(427 / 700, 4), got


def test_form_bottom_falls_back_to_the_old_constant():
    """No button row visible -> today's 0.58 ceiling, unchanged."""
    words = [("start", 160, 434, 42, 14), ("192", 300, 432, 28, 16)]
    assert pt._srv_form_bottom(words, 700) == pt.SRV_BODY_FALLBACK_FY
    reset(words)
    assert pt._srv_find_field_live(FakeWin(), "start") == {}


def test_a_deeper_form_keeps_the_octet_boxes():
    """The real pool form sits below the old 0.58 - its boxes must be seen."""
    words = [("start", 160, 434, 42, 14), ("ip", 207, 434, 16, 14),
             ("address", 228, 434, 56, 14),
             ("192", 300, 432, 28, 16), ("192", 340, 432, 28, 16),
             ("10", 380, 432, 20, 16), ("0", 420, 432, 14, 16),
             ("save", 380, 490, 40, 16), ("save", 380, 490, 40, 16)]
    reset(words)
    got = pt._srv_find_field_live(FakeWin(), "start")
    assert got.get("kind") == "octets", got
    assert len(got.get("boxes", [])) == 4, got


# ---- the read-back band -----------------------------------------------

def test_cell_span_and_read_back_fall_back_for_two_arg_doubles():
    span = pt._srv_cell_span(label_left=300, box_right=470, w=1000)
    assert 0.0 < span[0] <= 0.30 and 0.45 <= span[1] <= 0.97, span
    calls = []

    def four_arg(win, fy, fx0, fx1):
        calls.append((fy, fx0, fx1))
        return "row"

    with patch.object(pt, "_row_text", side_effect=four_arg):
        assert pt._row_read(FakeWin(), 0.5, (0.2, 0.6)) == "row"
    assert calls and calls[0][1:] == (0.2, 0.6), calls
    pt._row_text = lambda win, fy: "two-arg"
    assert pt._row_read(FakeWin(), 0.5, (0.2, 0.6)) == "two-arg"
    assert pt._row_read(FakeWin(), 0.5, None) == "two-arg"


# ---- the panel-identity gate ------------------------------------------

def test_fill_refuses_a_provably_wrong_panel():
    dummy = reset()
    win = FakeWin()
    pt._row_text = lambda win, fy: "dns server 192 168 10 11"
    selects = []
    with patch.object(pt, "_panel_title", return_value="dns server: name:"), \
         patch.object(pt, "_srv_select",
                      side_effect=lambda *a, **k: selects.append(a) or False), \
         patch.object(pt, "log"):
        ok, spot = pt._srv_fill(win, "DHCP1", "dhcp", "dns",
                                "192.168.10.11")
    assert (ok, spot) == (False, None)
    assert selects, "the requested service must be re-selected before giving up"
    assert [c for c in dummy.calls if c[0] == "write"] == [], dummy.calls
    rows = [r for r in journal_rows() if r.get("kind") == "srv_panel_mismatch"]
    assert rows and rows[0]["extra"].get("panel") == "dns", rows


def test_fill_proceeds_after_a_successful_re_select():
    dummy = reset()
    win = FakeWin()
    pt._row_text = lambda win, fy: "dns server 192 168 10 11"
    with patch.object(pt, "_panel_title", return_value="dns name: address:"), \
         patch.object(pt, "_srv_select", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "log"):
        ok, spot = pt._srv_fill(win, "DHCP1", "dhcp", "dns",
                                "192.168.10.11")
    assert ok, spot
    assert [c for c in dummy.calls if c[0] == "write"], dummy.calls


def test_an_unreadable_title_is_not_evidence():
    dummy = reset()
    win = FakeWin()
    pt._row_text = lambda win, fy: "dns server 192 168 10 11"
    with patch.object(pt, "_panel_title", return_value=""), \
         patch.object(pt, "_srv_select") as sel, \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "log"):
        ok, _spot = pt._srv_fill(win, "DHCP1", "dhcp", "dns",
                                 "192.168.10.11")
    assert ok and not sel.called, "no title read means no mismatch claim"


def test_panel_title_service_names_only_known_services():
    assert pt._srv_panel_service("dhcp pool: serverpool") == "dhcp"
    assert pt._srv_panel_service("DNS Server: Domain Name:") == "dns"
    assert pt._srv_panel_service("dhcpv6 pool") == "dhcpv6"
    assert pt._srv_panel_service("serverpool 0.0.0.0") == ""
    assert pt._srv_panel_service("") == ""


# ---- the probe --------------------------------------------------------

def test_probe_reports_the_evidence_and_types_nothing():
    dummy = reset()
    with patch.object(pt, "_srv_probe_window", return_value=FakeWin()), \
         patch.object(pt, "_panel_title", return_value="dhcp pool: serverpool"), \
         patch.object(pt, "log"):
        report = pt.srv_probe("DHCP1", "dhcp",
                              tokens=["dns", "gateway", "mask"])
    assert report["ok"] is True and report["panel_names"] == "dhcp"
    assert report["form_bottom"] == round(470 / 700 - 0.02, 4)
    dns = report["fields"]["dns"]
    assert len(dns["candidates"]) == 2, dns
    picked = dns["picked"]
    assert picked["fy"] == round(347 / 700, 4), picked
    assert picked["value_box_on_line"] is True, picked
    # both candidates are the word 'dns' - the band is what separates them
    by_band = {c["in_sidebar_band"]: c for c in dns["candidates"]}
    assert by_band[True]["x"] == 40 and by_band[True]["fy"] == round(
        167 / 700, 4), by_band
    assert by_band[True]["value_box_on_line"] is False, by_band
    assert by_band[False]["value_box_on_line"] is True, by_band
    assert report["resolved"] == ["dns", "gateway", "mask"] \
        and report["unresolved"] == [], report
    assert pt.RUN["srv_probe"] is report
    assert dummy.calls == [], f"the probe must not touch the UI: {dummy.calls}"


def test_probe_lists_a_token_it_cannot_resolve():
    reset()
    with patch.object(pt, "_srv_probe_window", return_value=FakeWin()), \
         patch.object(pt, "_panel_title", return_value="dhcp"), \
         patch.object(pt, "log"):
        report = pt.srv_probe("DHCP1", "dhcp", tokens=["dns", "zzz"])
    assert report["resolved"] == ["dns"], report
    assert report["unresolved"] == ["zzz"], report
    assert report["fields"]["zzz"]["candidates"] == [], report


def test_probe_needs_a_known_service_or_tokens():
    report = pt.srv_probe("DHCP1", "nope")
    assert report["ok"] is False and "tokens" in report["error"]


def test_probe_reports_a_missing_window():
    with patch.object(pt, "_srv_probe_window", return_value=None):
        report = pt.srv_probe("Ghost1", "dhcp")
    assert report["ok"] is False and "Ghost1" in report["error"]


def test_an_explicit_ceiling_still_clips_the_search():
    """A caller passing max_fy keeps the old clipping behaviour."""
    deeper = [("start", 160, 434, 42, 14), ("0", 300, 432, 14, 16),
              ("save", 380, 490, 40, 16)]
    reset(deeper)
    # the panel's own button row puts the form bottom below 0.58...
    assert pt._srv_find_field_live(FakeWin(), "start").get("fy") == \
        round(441 / 700, 4)
    # ...while an explicit ceiling is still honoured exactly
    assert pt._srv_find_field_live(FakeWin(), "start", max_fy=0.58) == {}


if __name__ == "__main__":
    test_sidebar_row_does_not_shadow_the_field_row()
    test_the_list_band_loses_when_no_value_box_is_available()
    test_a_service_word_loses_to_a_longer_panel_label()
    test_ordinary_empty_row_is_untouched_by_the_value_box_rule()
    test_form_bottom_is_read_from_the_panel_button_row()
    test_form_bottom_falls_back_to_the_old_constant()
    test_a_deeper_form_keeps_the_octet_boxes()
    test_cell_span_and_read_back_fall_back_for_two_arg_doubles()
    test_fill_refuses_a_provably_wrong_panel()
    test_fill_proceeds_after_a_successful_re_select()
    test_an_unreadable_title_is_not_evidence()
    test_panel_title_service_names_only_known_services()
    test_probe_reports_the_evidence_and_types_nothing()
    test_probe_needs_a_known_service_or_tokens()
    test_probe_lists_a_token_it_cannot_resolve()
    test_probe_reports_a_missing_window()
    test_an_explicit_ceiling_still_clips_the_search()
    print("ALL TESTS PASSED")
