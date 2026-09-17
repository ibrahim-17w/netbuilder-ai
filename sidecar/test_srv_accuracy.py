"""Unit tests for the server-services accuracy/learning engine.

Runs WITHOUT pyautogui/tesseract: pt_autopilot's RPA layer is stubbed,
OCR reads are scripted, and memory/journal files point at a tmp dir.
Covers the mistakes from the real DHCP run (Start IP typed across the
wrong octet boxes, pool table never updated) as regression cases.

Run:  python test_srv_accuracy.py
"""
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402


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
    left, top, right, bottom = 100, 200, 940, 1250  # 840x1050


class FakeWin:
    # The production focus gate requires a native PT handle.  This marker is
    # deliberately test-only: the fake window replaces the native UI driver.
    _allow_unverified_focus_for_test = True

    def rectangle(self):
        return FakeRect()

    def set_focus(self):
        pass


TMP = tempfile.mkdtemp(prefix="srv_test_")
PT_SIZE = (840, 1050)

# Fake DHCP panel word boxes (window px): labels + value-box digits,
# pool TABLE header below 0.58h must stay out of label detection.
WORDS_FULL = [
    ("dhcp", 300, 60, 50, 20),
    ("on", 700, 120, 24, 14),
    ("pool", 60, 240, 40, 16),              # form: Pool Name row
    ("name", 105, 240, 44, 16),
    ("default", 190, 288, 58, 16),
    ("gateway", 252, 288, 60, 16),
    ("0", 523, 286, 14, 18),
    ("dns", 190, 353, 30, 16),
    ("server", 225, 353, 52, 16),
    ("0", 523, 351, 14, 18),
    ("start", 193, 318, 42, 16),
    ("ip", 240, 318, 16, 16),
    ("address", 260, 318, 56, 16),
    ("192", 345, 316, 28, 18),
    ("192", 385, 316, 28, 18),
    ("10", 425, 316, 20, 18),
    ("0", 465, 316, 14, 18),
    ("pool", 60, 655, 40, 16),              # table header row
    ("name", 105, 655, 44, 16),
    ("startipaddress", 490, 655, 110, 16),  # header contains 'start'
    ("add", 350, 588, 40, 18),              # panel buttons row
    ("save", 500, 588, 40, 18),
    ("remove", 600, 588, 52, 18),
    ("serverpool", 60, 680, 80, 16),        # the pool's TABLE row
]
WORDS_NO_DIGITS = [w for w in WORDS_FULL if not w[0].isdigit()]
WORDS_NO_LABELS = [w for w in WORDS_FULL if w[0] in ("dhcp", "on", "0")]


def reset():
    pt.SRV_MEM = {"fields": {}, "buttons": {}}
    pt.SRV_MEM_FILE = os.path.join(TMP, "srv_memory.json")
    pt.JOURNAL_FILE = os.path.join(TMP, "failures.jsonl")
    pt.pyautogui = DummyRPA()
    pt._win_words = lambda win: (WORDS_FULL, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: ""
    # Both OCR cache layers: a warm exact-content entry would otherwise
    # outlive this reset even though the screenshots are scripted.
    pt.ocr_cache_clear()
    return pt.pyautogui


def journal_kinds():
    try:
        with open(pt.JOURNAL_FILE, encoding="utf-8") as f:
            return [json.loads(l).get("kind") for l in f if l.strip()]
    except Exception:
        return []


# ---- verification helpers -------------------------------------------

def test_value_in_text():
    assert pt._value_in_text("192.168.10.1", "gw 192.168.10.1 set")
    # the OLD digit-substring check passed these two (real bugs):
    assert not pt._value_in_text("192.168.10.1", "192.168.10.100")
    assert not pt._value_in_text("192.168.10.100", "192 192 10 0")
    assert pt._value_in_text("192.168.10.1", "192.168.1O.l")  # OCR fix
    assert pt._value_in_text("100", "512 100")
    assert not pt._value_in_text("100", "512")
    assert pt._value_in_text("", "anything")  # nothing to prove
    print("ok  _value_in_text")


def test_prefix_in_text():
    assert pt._prefix_in_text("192.168.10.100",
                              "192.168... 255.255... 100 0.0.0.0")
    assert not pt._prefix_in_text("10.20.30.40", "0.0.0.0 512")
    print("ok  _prefix_in_text")


# ---- live field detection -------------------------------------------

def test_find_field_live():
    reset()  # point _win_words at the fake panel words
    win = FakeWin()
    got = pt._srv_find_field_live(win, "start")
    assert got.get("kind") == "octets", got
    assert abs(got["fx"] - (345 + 4) / 840) < 0.01, got   # box 1 edge
    assert abs(got["fy"] - 326 / 1050) < 0.01, got
    got = pt._srv_find_field_live(win, "gateway")
    assert got.get("kind") == "single", got
    assert abs(got["fx"] - (523 + 2) / 840) < 0.01, got
    # the table header word 'startipaddress' must NOT win (y >= 0.58h):
    # the FORM 'Pool Name' row (fy~0.23) is the topmost candidate
    got = pt._srv_find_field_live(win, "pool")
    assert set(got) == {"fy"}, got
    assert abs(got["fy"] - 248 / 1050) < 0.01, got
    # label without readable digits -> fy only (caller: learned/tab)
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    got = pt._srv_find_field_live(win, "start")
    assert set(got) == {"fy"}, got
    # no label at all
    pt._win_words = lambda win: (WORDS_NO_LABELS, 0, 0, *PT_SIZE)
    assert pt._srv_find_field_live(win, "start") == {}
    print("ok  _srv_find_field_live")


# ---- fill ladder ------------------------------------------------------

def test_fill_live_and_learn():
    dummy = reset()
    win = FakeWin()
    pt._row_text = lambda win, fy: "start ip 192 168 10 100"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "start",
                            "192.168.10.100")
    assert ok and spot and abs(spot["fx"] - 0.4156) < 0.01, (ok, spot)
    # OCTET ROW: each octet typed into its OWN detected box (real run:
    # dotted auto-advance left '.100' stuck in box 4 as 0)
    clicks = [c for c in dummy.calls if c[0] == "click"]
    writes = [c for c in dummy.calls if c[0] == "write"]
    assert len(clicks) == 4 and len(writes) == 4, dummy.calls
    assert [w[1] for w in writes] == ["192", "168", "10", "100"], writes
    assert abs(clicks[0][1] - (100 + 840 * 0.4156)) <= 2, clicks[0]
    mem = pt.SRV_MEM["fields"].get("dhcp:start")
    assert mem and abs(mem["fx"] - 0.4156) < 0.01, mem  # LEARNED
    assert mem.get("boxes") and len(mem["boxes"]) == 4, mem
    # second run: digits unreadable live -> learned boxes reused
    reset()
    pt.SRV_MEM["fields"]["dhcp:start"] = {
        "fx": 0.4156, "fy": round(326 / 1050, 4), "kind": "octets",
        "boxes": [0.4156, 0.4643, 0.5095, 0.5565]}
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "start ip 192 168 10 100"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "start",
                            "192.168.10.100")
    assert ok, "learned-spot fill should verify"
    writes = [c for c in dummy.calls if c[0] == "write"]
    assert [w[1] for w in writes] == ["192", "168", "10", "100"], writes
    print("ok  fill ladder: live detect -> per-octet type -> learn")


def test_fill_skips_blind_typing():
    dummy = reset()
    win = FakeWin()
    pt._win_words = lambda win: (WORDS_NO_LABELS, 0, 0, *PT_SIZE)
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "start",
                            "192.168.10.100")
    assert not ok and spot is None
    assert dummy.calls == [], f"must not type blind: {dummy.calls}"
    assert "srv_field_missing" in journal_kinds()
    print("ok  fill refuses to type without a detected/learned box")


def test_fill_mismatch_bounded_and_journaled():
    dummy = reset()
    win = FakeWin()
    pt._row_text = lambda win, fy: "start ip 192 192 10 0"  # garbage row
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "start",
                            "192.168.10.100")
    assert not ok and spot is None
    # octet row: two bounded PASSES of 4 octet-writes each, then stop
    writes = [c for c in dummy.calls if c[0] == "write"]
    assert [w[1] for w in writes] == ["192", "168", "10", "100"] * 2, \
        dummy.calls
    kinds = journal_kinds()
    assert kinds.count("srv_fill_mismatch") == 1, kinds
    print("ok  fill mismatch: bounded retries + journaled read-back")


def test_fill_tab_walk_after_verified_row():
    dummy = reset()
    win = FakeWin()
    # gateway row detected + verifies; dns row has label only
    pt._win_words = lambda win: (WORDS_FULL, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "default gateway 192 168 10 1"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "gateway",
                            "192.168.10.1")
    assert ok
    # next row: label only, tab allowed because gateway VERIFIED
    n_before = len(dummy.calls)
    pt._row_text = lambda win, fy: "dns server 192 168 10 1"
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "dns",
                            "192.168.10.1", tab_from_ok=True)
    assert ok
    seq = [c[0] for c in dummy.calls[n_before:]]
    assert "press" == seq[0] and "hotkey" == seq[1], dummy.calls[:3]
    # WITHOUT a verified previous row, no tab walk happens
    dummy = reset()
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "dns server 192 168 10 1"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "dns",
                            "192.168.10.1", tab_from_ok=False)
    assert ok  # rowclick fallback verified it
    clicks = [c for c in dummy.calls if c[0] == "click"]
    # rowclick starts at 0.60 (inside the wide single boxes)
    assert len(clicks) == 1 and abs(clicks[0][1] - (100 + 840 * 0.60)) <= 2
    # A FAILED tab fill retries as a rowclick (real case: the DNS panel's
    # Type dropdown ate the Tab) - still bounded at two typings
    dummy = reset()
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    reads = ["type a record", "type a record", "address 192 168 10 20"]
    pt._row_text = lambda win, fy: \
        reads.pop(0) if len(reads) > 1 else reads[0]
    ok, spot = pt._srv_fill(win, "Server1", "dns", "address",
                            "192.168.10.20", tab_from_ok=True)
    assert ok, "rowclick retry must rescue a tab fill that hit a combo"
    seq = [c[0] for c in dummy.calls]
    assert seq[0] == "press" and "click" in seq, dummy.calls
    writes = [c for c in dummy.calls if c[0] == "write"]
    assert len(writes) == 2, f"max two typings: {dummy.calls}"
    mem = pt.SRV_MEM["fields"].get("dns:address")
    assert mem, "the working rowclick spot must be learned"
    print("ok  fill tab-walk gated on a verified previous row")


def test_stale_learned_spot_evicted():
    reset()
    win = FakeWin()
    # digits unreadable live -> the learned spot is the only candidate
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._srv_learn_field("dhcp:start", 0.4156, 0.20, "octets")  # wrong fy
    pt._row_text = lambda win, fy: "start ip 192 192 10 0"
    ok, _ = pt._srv_fill(win, "Server1", "dhcp", "start",
                         "192.168.10.100")
    assert not ok
    mem = pt.SRV_MEM["fields"].get("dhcp:start")
    assert mem and mem.get("misses") == 1, mem  # one miss: kept
    ok, _ = pt._srv_fill(win, "Server1", "dhcp", "start",
                         "192.168.10.100")
    assert "dhcp:start" not in pt.SRV_MEM["fields"], "evict at 2 misses"
    assert "srv_spot_stale" in journal_kinds()
    print("ok  stale learned spot: miss-counted then evicted")


# ---- pool table acceptance ------------------------------------------

def test_dhcp_pool_saved():
    win = FakeWin()
    p = {"gateway": "192.168.10.1", "startIp": "192.168.10.100",
         "maxUsers": "100"}

    def table(text):
        pt._ocr_region = lambda *a, **k: text

    table("Pool Name  Default Gateway  DNS Server  Start IP Address\n"
          "serverPool 192.168.10.1 192.168.10.1 192.168.10.100 "
          "255.255.255.0 100 0.0.0.0")
    ok, row = pt._dhcp_pool_saved(win, p)
    assert ok and "serverpool" in row, (ok, row)
    # the user's screenshot state: typed fields, table still default
    table("serverPool 0.0.0.0 0.0.0.0 192.168.10.0 255.255.255.0 512 "
          "0.0.0.0 0.0.0.0")
    ok, row = pt._dhcp_pool_saved(win, p)
    assert not ok, "default row must NOT pass as saved"
    # truncated cells fall back to prefix match; 100 users discriminates
    table("serverPool 192.168... 192.168... 192.168... 255.255... 100 "
          "0.0.0.0")
    ok, row = pt._dhcp_pool_saved(win, p)
    assert ok, "truncated-but-saved row must pass"
    table("no pool table here")
    ok, row = pt._dhcp_pool_saved(win, p)
    assert not ok and row == ""
    # region fix: a row at fy~0.53 (tall window) must be found even
    # though the scan starts at 0.42, and the BOTTOM-most match wins -
    # a stale same-name line above must not shadow the table row.
    table("serverPool\n"                       # form-area ghost (no digits)
          "serverPool 0.0.0.0 0.0.0.0 192.168.10.100 "
          "255.255.255.0 100 0.0.0.0")         # the real table row
    ok, row = pt._dhcp_pool_saved(win, p)
    assert ok and "100" in row, (ok, row)
    # NAMED pool (new strategy): the named row must match, the default
    # serverPool row next to it must be ignored
    p_named = dict(p, poolName="pool192_168_10")
    table("serverPool 0.0.0.0 0.0.0.0 192.168.10.0 255.255.255.0 512 "
          "0.0.0.0\n"
          "pool192_168_10 192.168.10.1 192.168.10.20 192.168.10.100 "
          "255.255.255.0 100 0.0.0.0")
    ok, row = pt._dhcp_pool_saved(win, p_named)
    assert ok and "pool192_168_10" in row, (ok, row)
    p_wrong = dict(p_named, startIp="10.0.0.50")
    ok, row = pt._dhcp_pool_saved(win, p_wrong)
    assert not ok, "named row with wrong values must NOT pass"
    # REAL RUN regression: the Pool Name column truncates the row name
    # ('pool192_168...') - the 8-char alnum prefix must still match
    table("serverPool 0.0.0.0 0.0.0.0 192.168.1.0 255.255.255.0 512 "
          "0.0.0.0\n"
          "pool192_168... 192.168.1.1 192.168.1.12 192.168.1.100 "
          "255.255.255.0 100 0.0.0.0")
    ok, row = pt._dhcp_pool_saved(win, dict(p, poolName="pool192_168_1"))
    assert ok and "pool192" in row, "truncated pool name must match"
    print("ok  _dhcp_pool_saved: saved/default/truncated/missing")


def test_fill_name_value_verified():
    reset()
    win = FakeWin()
    # Pool Name row: label found, box holds 'serverPool' (no digits)
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "pool name pool192 168 10"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "pool",
                            "pool192_168_10")
    assert ok, "name-ish values verify via alnum containment"
    assert "dhcp:pool" in pt.SRV_MEM["fields"], "spot must be learned"
    # REAL RUN regression: OCR read the typed '1' as 't' - the value is
    # IN the box, the confusable fold must recognize it, not retype
    reset()
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "Pool Name poolt92_168_1"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "pool",
                            "pool192_168_1")
    assert ok, "OCR confusable (t for 1) must not fail a correct fill"
    # but a genuinely different value still fails
    reset()
    pt._win_words = lambda win: (WORDS_NO_DIGITS, 0, 0, *PT_SIZE)
    pt._row_text = lambda win, fy: "Pool Name serverPool"
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "pool",
                            "pool192_168_1")
    assert not ok, "wrong pool name must NOT verify"
    print("ok  fill name-ish value: verified, confusable-tolerant")


def test_fill_ocr_flake_reread():
    dummy = reset()
    win = FakeWin()
    # first read-back: digitless junk (real run: 'ons OMe @aner'),
    # free re-read sees the value -> verified with a SINGLE typing pass
    reads = ["ons ome aner", "default gateway 192 168 1 1"]
    pt._row_text = lambda win, fy: \
        reads.pop(0) if len(reads) > 1 else reads[0]
    ok, spot = pt._srv_fill(win, "Server1", "dhcp", "gateway",
                            "192.168.1.1")
    assert ok, "OCR flake must be re-read, not retried with keystrokes"
    writes = [c for c in dummy.calls if c[0] == "write"]
    assert len(writes) == 1, dummy.calls
    print("ok  fill digitless OCR band re-read free (no retype)")


def test_derive_pool_name():
    assert pt._derive_pool_name(
        {"startIp": "192.168.10.100"}) == "pool192_168_10"
    assert pt._derive_pool_name(
        {"startIp": "10.20.30.40", "poolName": "Office-LAN"}) == "office_lan"
    assert pt._derive_pool_name({}) == "poolLAN"
    print("ok  _derive_pool_name")


def test_validate_pool_plan():
    reset()
    good = {"gateway": "192.168.10.1", "startIp": "192.168.10.100",
            "mask": "255.255.255.0", "maxUsers": "100"}
    pt._validate_pool_plan(good, "Server1")
    assert "srv_plan_suspicious" not in journal_kinds(), "good plan flagged"
    pt._validate_pool_plan(dict(good, startIp="10.0.0.50"), "Server1")
    assert "srv_plan_suspicious" in journal_kinds(), "subnet miss missed"
    pt._validate_pool_plan(dict(good, maxUsers="lots"), "Server1")
    kinds = journal_kinds()
    assert kinds.count("srv_plan_suspicious") == 2, kinds
    print("ok  _validate_pool_plan flags wrong plan values")


def test_dns_record_saved():
    # record row below the Add button: name AND address in one line
    pt._ocr_region = lambda *a, **k: \
        "No.  Name  Type  Detail\n1  srv1  A Record  192.168.10.20"
    ok, row = pt._dns_record_saved(None, "srv1", "192.168.10.20", 0.4)
    assert ok and "srv1" in row, (ok, row)
    # the user's DNS run: form typed, record TABLE empty
    pt._ocr_region = lambda *a, **k: "No.  Name  Type  Detail"
    ok, row = pt._dns_record_saved(None, "srv1", "192.168.10.20", 0.4)
    assert not ok and row == ""
    print("ok  _dns_record_saved: table row found / empty table caught")


def test_select_pool_row():
    dummy = reset()
    win = FakeWin()
    # table row word at y=560 (> 0.44*1050=462): clicked, form box at
    # y=250 never qualifies
    got = pt._srv_select_pool_row(win, {"poolName": "serverPool"})
    assert got, "visible table row must be selectable"
    clicks = [c for c in dummy.calls if c[0] == "click"]
    assert len(clicks) == 1
    # _win_words origin is (0,0) in the fixture: word x=60+ww/2=100,
    # y=680+hh/2=688
    assert abs(clicks[0][1] - 100) <= 2, clicks
    assert abs(clicks[0][2] - 688) <= 2, clicks
    # only the FORM box (y < 0.44h) shows the name: no click, no crash
    dummy = reset()
    pt._win_words = lambda win: ([("serverpool", 60, 250, 80, 16)],
                                 0, 0, *PT_SIZE)
    got = pt._srv_select_pool_row(win, {"poolName": "serverPool"})
    assert not got and dummy.calls == []
    print("ok  _srv_select_pool_row: clicks the table row only")


# ---- buttons + suggestions ------------------------------------------

def test_button_learning():
    dummy = reset()
    win = FakeWin()
    spot = pt._srv_button(win, "Server1", "save", below_fy=0.4,
                          svc="dhcp")
    assert spot and not spot["learned"]
    assert any(c[0] == "click" for c in dummy.calls)
    pt._srv_learn_button("dhcp:save", spot["fx"], spot["fy"])
    dummy = reset()  # fresh recorder + blind OCR
    pt.SRV_MEM["buttons"]["dhcp:save"] = {"fx": spot["fx"],
                                          "fy": spot["fy"]}
    pt._win_words = lambda win: ([], 0, 0, *PT_SIZE)  # OCR blind
    spot2 = pt._srv_button(win, "Server1", "save", below_fy=0.4,
                           svc="dhcp")
    assert spot2 and spot2["learned"], "learned spot clicks without OCR"
    pt._srv_evict_button("dhcp:save")
    assert "dhcp:save" not in pt.SRV_MEM["buttons"]
    print("ok  button learning/eviction")


def test_button_infers_add_when_light_text_is_missed():
    """The real DHCP screenshot had Save/Remove visible but Add missed."""
    dummy = reset()
    win = FakeWin()
    # Normal OCR misses Add; sparse OCR sees its two neighbors.
    pt._win_words = lambda win: (
        [("save", 469, 359, 26, 10), ("remove", 655, 359, 44, 10)],
        0, 0, *PT_SIZE)
    original = pt._win_words

    def sparse(win, psm=6):
        if psm == 11:
            return original(win)
        return original(win)

    pt._win_words = sparse
    spot = pt._srv_button(win, "Server1", "add", below_fy=0.30,
                          svc="dhcp")
    assert spot and any(c[0] == "click" for c in dummy.calls), dummy.calls
    # Save center 482 and Remove center 677 imply Add center ~287.
    click = next(c for c in dummy.calls if c[0] == "click")
    assert abs(click[1] - 287) <= 3, click
    assert abs(click[2] - 364) <= 3, click
    print("ok  button inference clicks Add when OCR misses its label")


def test_dns_never_adds_unverified_address():
    """An empty DNS address must not trigger PT's invalid-IP modal."""
    reset()
    win = FakeWin()
    calls = []
    old_select = pt._srv_select
    old_radio = pt._srv_radio_on
    old_fill = pt._srv_fill
    old_button = pt._srv_button
    old_fail = pt._fail_shot
    try:
        pt._srv_select = lambda *args, **kwargs: True
        pt._srv_radio_on = lambda *args, **kwargs: True

        def fill(_win, _dev, _svc, token, _val, tab_from_ok=False):
            if token == "name":
                return True, {"fy": 0.30}
            return False, None

        pt._srv_fill = fill
        pt._srv_button = lambda _win, _dev, label, **kwargs: calls.append(label)
        pt._fail_shot = lambda *args, **kwargs: calls.append("shot")
        ok = pt._svc_flow_dns(
            win, "Server1", {"records": [{"name": "srv1",
                                           "address": "192.168.10.11"}]})
        assert not ok
        assert "add" not in calls, calls
        assert "srv_record_blocked" in journal_kinds()
    finally:
        pt._srv_select = old_select
        pt._srv_radio_on = old_radio
        pt._srv_fill = old_fill
        pt._srv_button = old_button
        pt._fail_shot = old_fail
    print("ok  DNS refuses Add when a required field is unverified")


def test_journal_suggestions_cover_new_kinds():
    reset()
    rows = [{"ts": "t", "kind": "srv_save_failed", "detail": "x",
             "device": "Server1", "recovered": False}] * 2
    rows += [{"ts": "t", "kind": "srv_fill_mismatch", "detail": "x",
              "device": "Server1", "recovered": False}] * 3
    with open(pt.JOURNAL_FILE, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    out = " ".join(pt.journal_suggestions())
    assert "pool table" in out, out
    assert "read-back" in out, out
    print("ok  journal_suggestions surface the new failure kinds")


if __name__ == "__main__":
    # keep the suite fast: the code sleeps between real UI steps
    pt.time = type("T", (), {
        "sleep": staticmethod(lambda s: None),
        "strftime": staticmethod(time.strftime),
        "time": staticmethod(time.time),
    })
    test_value_in_text()
    test_prefix_in_text()
    test_find_field_live()
    test_fill_live_and_learn()
    test_fill_skips_blind_typing()
    test_fill_mismatch_bounded_and_journaled()
    test_fill_tab_walk_after_verified_row()
    test_stale_learned_spot_evicted()
    test_dhcp_pool_saved()
    test_fill_name_value_verified()
    test_fill_ocr_flake_reread()
    test_derive_pool_name()
    test_validate_pool_plan()
    test_dns_record_saved()
    test_select_pool_row()
    test_button_learning()
    test_button_infers_add_when_light_text_is_missed()
    test_dns_never_adds_unverified_address()
    test_journal_suggestions_cover_new_kinds()
    print("ALL TESTS PASSED")
