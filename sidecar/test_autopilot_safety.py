"""Deterministic safety tests for the Packet Tracer sidecar.

These tests do not open Packet Tracer. They exercise the activity lock,
stop-latch lifecycle, mode-preserving CLI preparation, hardware filtering,
and the stop-aware mouse/keyboard boundary with a fake UI driver.
"""
from __future__ import annotations

import sys
import os
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, "sidecar")
import pt_autopilot as pt  # noqa: E402


class FakeUi:
    def __init__(self):
        self.writes = []
        self.clicks = []
        self.presses = []

    def write(self, value, interval=0.0):
        self.writes.append((value, interval))
        if len(self.writes) == 1:
            pt.JOB.stop_requested = True

    def click(self, *args, **kwargs):
        self.clicks.append((args, kwargs))

    def press(self, key):
        self.presses.append(key)


def check_activity_lock():
    pt.JOB.running = False
    pt.JOB.stop_requested = True
    pt.AUDIT["running"] = False
    pt.CALIBRATION["running"] = False

    original_press_esc = pt._press_esc
    pt._press_esc = lambda: None
    try:
        pt.request_stop("idle test")
        assert pt.JOB.stop_requested is False
    finally:
        pt._press_esc = original_press_esc

    ok, reason = pt.begin_activity("audit")
    assert ok and not reason
    assert pt.AUDIT["running"] is True
    assert pt.JOB.stop_requested is False

    ok, reason = pt.begin_activity("build")
    assert not ok and reason == "audit"
    pt.end_activity("audit")

    ok, reason = pt.begin_activity("calibration")
    assert ok and not reason
    ok, reason = pt.begin_activity("build")
    assert not ok and reason == "calibration"
    pt.end_activity("calibration")
    assert pt.activity_snapshot()["running"] is False


def check_stop_aware_ui_boundary():
    fake = FakeUi()
    original_ui = pt.pyautogui
    try:
        pt.pyautogui = fake
        pt.JOB.stop_requested = False
        assert pt._safe_write("abcdefgh", interval=0.0) is False
        assert len(fake.writes) == 1
        assert pt._safe_click(10, 20) is False
        assert fake.clicks == []
    finally:
        pt.pyautogui = original_ui
        pt.JOB.stop_requested = False


def check_cli_and_interface_guard():
    cfg = """interface s0/0/0
 description wan
 ip address 10.0.0.1 255.255.255.252
 no shutdown
exit
interface g0/0
 ip address 192.168.1.1 255.255.255.0
 no shutdown
exit
ip route 192.168.2.0 255.255.255.0 10.0.0.2
    """
    lines = pt.cli_lines_for_device(cfg)
    assert lines[:5] == [
        "interface s0/0/0",
        "description wan",
        "ip address 10.0.0.1 255.255.255.252",
        "no shutdown",
        "exit",
    ]
    assert lines[-2:] == ["end", "show ip interface brief"]
    assert "enable" not in lines
    assert "configure terminal" not in lines
    assert pt._remove_blind_mode_entries(
        ["enable", "configure terminal", "hostname R1", "exit"]
    ) == ["hostname R1", "exit"]
    original_bad_cmd_mem = pt.BAD_CMD_MEM
    try:
        pt.BAD_CMD_MEM = {
            "p": {"R1": {
                pt.command_key("hostname R1"): {
                    "replacement": ["enable", "configure terminal",
                                    "hostname R1"],
                    "replacement_verified": True,
                }
            }}
        }
        learned = pt.learned_cli_lines("p", "R1", "hostname R1",
                                       dtype="router")
        assert "enable" not in learned
        assert "configure terminal" not in learned
    finally:
        pt.BAD_CMD_MEM = original_bad_cmd_mem
    assert pt.cli_lines_for_device(
        "enable\nconfigure terminal\nhostname R1\n"
    ) == ["hostname R1", "end", "show ip interface brief"]
    assert pt._cli_prompt_mode("Router>") == "user"
    assert pt._cli_prompt_mode("Router#") == "privileged"
    assert pt._cli_prompt_mode("Router# enable") == "privileged"
    assert pt._cli_prompt_mode("Router> enable") == "user"
    # Packet Tracer's light terminal can repaint a user prompt's `>` as `?`.
    # Treating that uncertain glyph as privileged would allow configuration
    # commands at Router>, so it must fail toward the harmless user mode.
    assert pt._cli_prompt_mode("Router?") == "user"
    assert pt._cli_prompt_mode("Router(config)# hostname R1") == "config"
    assert pt._cli_prompt_mode("Router(config)#") == "config"
    assert pt._looks_like_packet_tracer("HQ_Router", "PacketTracer.exe")
    assert not pt._looks_like_packet_tracer(
        "Find and rebuild broken feature", "Codex.exe"
    )

    # Keyboard input must fail closed while a covering app owns the
    # foreground. The real failed run captured Codex in front of PT, so a
    # stale device window could not be treated as a live IOS terminal.
    class FocusWindow:
        def __init__(self):
            self.focus_calls = 0
            self.element_info = type("Info", (), {"handle": 123})()

        def set_focus(self):
            self.focus_calls += 1

    original_foreground_info = pt._foreground_window_info
    original_activate = pt._activate_window_handle
    original_focus_log = pt.log
    original_focus_record = pt.record_event
    original_focus_sleep = pt._interruptible_sleep
    try:
        foreign = {
            "active_title": "Find and rebuild broken feature",
            "active_path": "Codex.exe",
            "is_packet_tracer": False,
        }
        recovered = {
            "active_title": "HQ_Router",
            "active_path": "PacketTracer.exe",
            "is_packet_tracer": True,
        }
        focus_window = FocusWindow()
        reads = iter([foreign, foreign])
        events = []
        pt._foreground_window_info = lambda win=None: next(reads)
        pt._activate_window_handle = lambda win: True
        pt.log = lambda *args, **kwargs: None
        pt.record_event = lambda kind, *args, **kwargs: events.append(kind)
        pt._interruptible_sleep = lambda *args, **kwargs: True
        pt.JOB.stop_requested = False
        assert pt._focus_pt_window(focus_window, "R1", "test overlay") \
            is False
        assert focus_window.focus_calls == 2
        assert "pt_focus_blocked" in events

        focus_window = FocusWindow()
        reads = iter([foreign, recovered])
        pt._foreground_window_info = lambda win=None: next(reads)
        assert pt._focus_pt_window(focus_window, "R1", "test recovery") \
            is True
        assert focus_window.focus_calls == 2
    finally:
        pt._foreground_window_info = original_foreground_info
        pt._activate_window_handle = original_activate
        pt.log = original_focus_log
        pt.record_event = original_focus_record
        pt._interruptible_sleep = original_focus_sleep

    original_input_focus = pt._focus_cli_input
    try:
        pt._focus_cli_input = lambda *args, **kwargs: False
        assert pt._type_line("enable", 25, win=object(), dev="R1") \
            is False
    finally:
        pt._focus_cli_input = original_input_focus

    assert pt._live_prompt_after_boot(
        "Would you like to enter the initial configuration dialog? [yes/no]: no\n"
        "Press RETURN to get started!\nRouter> no\n"
        "Translating \"no\"... domain server (255.255.255.255)"
    )
    # The boot banner itself is not an IOS prompt.  In particular, the
    # trailing `t` in `RETURN` must not be treated as OCR'd `>`/`#`.
    assert pt._term_state("Press RETURN to get started!") == "return"
    assert pt._term_state(
        "Would you like to enter the initial configuration dialog? [yes/no]: no\n"
        "Press RETURN to get started!"
    ) == "return"
    assert not pt._prompt_seen("Press RETURN to get started!")
    assert pt._cli_prompt_mode("Press RETURN to get started!") == "unknown"
    # Screenshot (1230) is a light PT terminal; it must not be inverted into
    # an OCR-hostile black crop. Dark PT terminals still use inversion.
    assert not pt._terminal_ocr_should_invert(228.0)
    assert pt._terminal_ocr_should_invert(60.0)
    assert not pt._live_prompt_after_boot(
        "Router>\nWould you like to enter the initial configuration dialog? "
        "[yes/no]:"
    )
    assert pt._cli_prompt_mode("Router(config-if)#") == "interface"
    assert pt._cli_prompt_mode("Switch (config) # configure terminal") == "config"
    assert pt._cli_prompt_mode("Switen (confic) # hostname SW1") == "config"
    assert pt._cli_prompt_mode("BR_ Router (config) +") == "config"
    assert pt._cli_prompt_mode("BR Router (config) #") == "config"
    assert pt._cli_prompt_mode("BR_Router(config-isakmp)#") == "crypto"
    assert pt._cli_prompt_mode("BR_Router(cfg-crypto-trans)#") == "crypto"
    assert pt._cli_prompt_mode("BR_Router(config-time-range)#") == "time_range"
    assert pt._cli_prompt_mode("BR_Router(config-dhcp)#") == "dhcp"
    assert pt._cli_prompt_mode("Router$") == "privileged"
    assert pt._cli_prompt_mode(
        'Ri (config)? end\nRig\nTranslating "end"...'
    ) == "privileged"
    assert pt._fallback_lines("end", False, False) == []
    assert pt._available_interfaces(
        "GigabitEthernet0/0 unassigned\nGigabitEthernet0/1 unassigned"
    ) == {"gigabitethernet0/0", "gigabitethernet0/1"}
    assert pt._available_interfaces(
        "Gi0/0\nGigabitEtherneto/o\nFastEthernet0/S"
    ) == {"gigabitethernet0/0", "fastethernet0/5"}
    assert pt._command_requirement("end", {}) == "privileged"
    assert pt._command_requirement("ip address 192.168.1.1 255.255.255.0",
                                   {}) == "interface"
    assert pt._command_requirement("network 10.0.0.0 0.0.0.3", {}) == "router"
    assert pt._command_requirement("permit ip any any", {}) == "acl"
    assert pt._command_requirement("encr aes", {}) == "crypto"
    assert pt._command_requirement("set peer 10.1.1.2", {}) == "crypto"
    assert pt._command_requirement("periodic weekdays 08:00 to 17:00", {}) \
        == "time_range"

    crypto_queue = pt._compile_cli_queue([
        "crypto isakmp policy 10",
        "encr aes",
        "hash sha",
        "authentication pre-share",
        "group 5",
        "exit",
        "crypto isakmp key NetBuilderLab2026 address 10.1.1.2",
        "crypto ipsec transform-set SITE_VPN_SET esp-aes esp-sha-hmac",
        "exit",
        "crypto map SITE_VPN 10 ipsec-isakmp",
        "set peer 10.1.1.2",
        "set transform-set SITE_VPN_SET",
        "match address SITE_VPN_TRAFFIC",
        "exit",
        "interface s0/0/0",
        "crypto map SITE_VPN",
        "exit",
    ])
    assert [item["required"] for item in crypto_queue] == [
        "config", "crypto", "crypto", "crypto", "crypto", "live",
        "config", "config", "live", "config", "crypto", "crypto",
        "crypto", "live", "config", "interface", "live",
    ]
    assert [item["after_mode"] for item in crypto_queue] == [
        "crypto", "crypto", "crypto", "crypto", "crypto", "config",
        "config", "crypto", "config", "crypto", "crypto", "crypto",
        "crypto", "config", "interface", "interface", "config",
    ]

    planned = pt._compile_cli_queue([
        "interface g0/0",
        "description LAN",
        "ip address 192.168.1.1 255.255.255.0",
        "no shutdown",
        "exit",
        "router ospf 1",
        "network 192.168.1.0 0.0.0.255",
        "end",
        "show ip interface brief",
    ])
    assert [item["required"] for item in planned] == [
        "config", "interface", "interface", "interface", "interface",
        "config", "router", "router", "privileged",
    ]
    assert [item["after_mode"] for item in planned] == [
        "interface", "interface", "interface", "interface", "config",
        "router", "router", "privileged", "privileged",
    ]
    assert planned[6]["fallbacks"] == ["network 192.168.1.0 0.0.0.255"]
    trunk_plan = pt._compile_cli_queue([
        "interface g0/0", "encapsulation dot1q 10"
    ])
    assert trunk_plan[-1]["fallbacks"] == [
        "switchport", "switchport mode trunk", "encapsulation dot1q 10"
    ]
    assert pt._compile_cli_queue(["end", "show version"])[0]["command"] \
        == "show version"
    assert [item["command"] for item in pt._compile_cli_queue([
        "configure terminal", "hostname SW1", "enable", "show version"
    ])] == ["hostname SW1", "show version"]

    # The normal crop can preserve the older `Router> enable` echo while
    # missing the newer privileged row.  The tight prompt-band read must
    # promote the verified `Router#` row for both routers and switches.
    original_ocr_region = pt._ocr_region
    try:
        pt._ocr_region = lambda win, fy0=0.40, fy1=0.94, **kwargs: (
            "Router> enable" if fy0 < 0.80 else "Router> enable\nRouter#"
        )
        state, text = pt._confirmed_state(object(), "R4")
        assert state == "cli"
        assert pt._cli_prompt_mode(text) == "privileged"
    finally:
        pt._ocr_region = original_ocr_region
    assert pt._cli_prompt_mode("Switen> enable Switen?") == "privileged"
    assert pt._cli_prompt_mode("Switen> enable Switen>") == "user"

    # A successful enable must be reusable immediately.  A stale Switch>
    # repaint must not cause another enable at Switch#.
    original_mode_send = pt._mode_send
    original_record = pt.record_event
    original_log = pt.log
    try:
        sent = []
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_ENABLE_ATTEMPTS.clear()
        pt._mode_send = lambda win, dev, command, delay_ms, expected=None: (
            sent.append(command) or "privileged"
        )
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        assert pt._normalize_to_privileged(object(), "SW1", "user", 25) \
            == "privileged"
        assert pt._normalize_to_privileged(object(), "SW1", "user", 25) \
            == "privileged"
        assert sent == ["enable"]

        # If two enable attempts cannot be verified, later lines block
        # rather than stacking repeated enable commands.  A single OCR
        # flake gets one bounded retry (enable is a safe no-op at both
        # prompts), but the third enable is refused.
        sent.clear()
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_ENABLE_ATTEMPTS.clear()
        pt._mode_send = lambda win, dev, command, delay_ms, expected=None: (
            sent.append(command) or "user"
        )
        assert pt._normalize_to_privileged(object(), "SW2", "user", 25) \
            == "unknown"
        assert pt._normalize_to_privileged(object(), "SW2", "user", 25) \
            == "unknown"
        assert sent == ["enable", "enable"]

        # A verified `end` transition must not be repeated when a repaint
        # still exposes the older config prompt.
        sent.clear()
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_MODE_LATCH["R3"] = "privileged"
        assert pt._normalize_to_privileged(object(), "R3", "config", 25) \
            == "privileged"
        assert sent == []
    finally:
        pt._mode_send = original_mode_send
        pt.record_event = original_record
        pt.log = original_log
        pt._CLI_MODE_LATCH.clear()

    # After answering the setup dialog, the terminal may remain at
    # Press RETURN.  The helper must focus the console, send exactly one
    # Return, and require a fresh Router> prompt before succeeding.
    original_confirmed = pt._confirmed_state
    original_focus_boot = pt._focus_boot_terminal
    original_sleep = pt._interruptible_sleep
    original_safe_press = pt._safe_press
    original_record = pt.record_event
    original_log = pt.log
    try:
        boot_reads = iter([
            ("return", "Press RETURN to get started!"),
            ("cli", "Router>"),
        ])
        boot_actions = []
        pt._BOOT_RETURN_ATTEMPTS.clear()
        pt._confirmed_state = lambda *args, **kwargs: next(boot_reads)
        pt._focus_boot_terminal = lambda *args, **kwargs: (
            boot_actions.append("focus") or True
        )
        pt._safe_press = lambda key: boot_actions.append(key) or True
        pt._interruptible_sleep = lambda *args, **kwargs: True
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        assert pt._finish_boot_return(object(), "R1", 25) is True
        assert boot_actions == ["focus", "enter"]
    finally:
        pt._confirmed_state = original_confirmed
        pt._focus_boot_terminal = original_focus_boot
        pt._interruptible_sleep = original_sleep
        pt._safe_press = original_safe_press
        pt.record_event = original_record
        pt.log = original_log

    # The settle loop must route the screenshot's exact boot transcript
    # through the Return handler before it ever considers CLI ready.
    original_confirmed = pt._confirmed_state
    original_finish = pt._finish_boot_return
    original_sleep = pt._interruptible_sleep
    original_record = pt.record_event
    original_log = pt.log
    try:
        settle_reads = iter([
            ("return", "Press RETURN to get started!"),
            ("cli", "Router>"),
        ])
        settle_calls = []
        pt._confirmed_state = lambda *args, **kwargs: next(settle_reads)
        pt._finish_boot_return = lambda win, dev, delay_ms: (
            settle_calls.append(dev) or True
        )
        pt._interruptible_sleep = lambda *args, **kwargs: True
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        assert pt._settle_boot_dialogs(object(), "R2", rounds=2) is True
        assert settle_calls == ["R2"]
    finally:
        pt._confirmed_state = original_confirmed
        pt._finish_boot_return = original_finish
        pt._interruptible_sleep = original_sleep
        pt.record_event = original_record
        pt.log = original_log

    original_record = pt.record_event
    original_log = pt.log
    try:
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        pt.RUN = {}
        filtered, blocked = pt._filter_unavailable_interface_blocks(
            lines, cfg, "R1", {"gigabitethernet0/0"}
        )
        assert blocked == ["serial0/0/0"]
        assert not any("serial0/0/0" in line for line in filtered)
        assert "interface g0/0" in filtered
        assert "ip route 192.168.2.0 255.255.255.0 10.0.0.2" in filtered
    finally:
        pt.record_event = original_record
        pt.log = original_log


def check_ocr_upscale_and_fallback():
    """Pin the read strategy: configured upscale, then the psm 6 -> 11 fallback.

    The Tesseract boundary (_tesseract_run) is stubbed, so this check runs on
    a machine with no Tesseract installed: what it pins is the engine's own
    decision, not Tesseract's output.  The *text* produced from real
    screenshots is verified separately by ocr_baseline.py --compare.
    """
    import os as _os

    class FakeRect:
        left, top, right, bottom = 0, 0, 100, 40
        handle = "fake-window"

    class FakeWin:
        def rectangle(self):
            return FakeRect()

    from PIL import Image as PILImage

    # A light-theme terminal crop: small, mostly white, tiny dark text.
    screen = PILImage.new("L", (100, 40), 255)
    original_screenshot = pt.pyautogui.screenshot
    original_tesseract = pt._tesseract_run
    original_cmd = pt.TESSERACT_CMD
    pt.ocr_cache_clear()
    try:
        pt.TESSERACT_CMD = original_cmd or "tesseract-not-really"
        pt.pyautogui.screenshot = lambda region=None: screen

        # psm 6 reads nothing at native scale on this theme (the real
        # failure), so the engine must upscale the crop AND fall back to
        # the sparse psm 11 read before giving up.
        calls = []

        def fake_tesseract(img, psm):
            calls.append((int(psm), img.size))
            return "" if int(psm) == 6 else "Router#"

        pt._tesseract_run = fake_tesseract
        text = pt._ocr_region(FakeWin())
        assert text == "Router#"
        assert [psm for psm, _ in calls] == [6, 11]
        # The upscale the module is configured for must actually be applied
        # to the submitted image.  The default of 3 is only ever changed
        # after ocr_baseline.py --compare reports identical text.
        scale = pt.OCR_UPSCALE
        assert calls[0][1] == (100 * scale, 40 * scale), calls[0]
        assert calls[1][1] == calls[0][1], calls[1]

        # When the primary psm 6 read works there is no fallback call.
        calls.clear()
        pt.ocr_cache_clear()

        def fake_tesseract_ok(img, psm):
            calls.append((int(psm), img.size))
            return "Router> enable\nRouter#"
        pt._tesseract_run = fake_tesseract_ok
        text = pt._ocr_region(FakeWin())
        assert text == "Router> enable\nRouter#"
        assert [psm for psm, _ in calls] == [6]
    finally:
        pt.pyautogui.screenshot = original_screenshot
        pt._tesseract_run = original_tesseract
        pt.TESSERACT_CMD = original_cmd
        pt.ocr_cache_clear()
        tmp = _os.path.join(pt.SHOTS, "_ocr_tmp.png")
        if _os.path.exists(tmp):
            _os.remove(tmp)

    # Terminal text prefers OCR; the UIA walk is reserved for frames OCR
    # cannot read (it was also the unbounded hang risk).
    original_ocr = pt._ocr_region
    original_uia = pt._uia_texts
    try:
        pt._ocr_region = lambda win, *a, **k: "Router#"
        pt._uia_texts = lambda win, cap=80: "should-not-be-read"
        assert pt._term_texts(object()) == "Router#"
        pt._ocr_region = lambda win, *a, **k: ""
        assert pt._term_texts(object()) == "should-not-be-read"
    finally:
        pt._ocr_region = original_ocr
        pt._uia_texts = original_uia


def test_ocr_read_strategy_upscales_and_falls_back():
    """The pinned OCR read strategy must hold in the pytest suite too.

    check_ocr_upscale_and_fallback was only reachable by running this file
    directly (pytest collects test_* functions), so a pinned OCR contract
    could rot unnoticed.  It no longer needs a real Tesseract install.
    """
    check_ocr_upscale_and_fallback()


def test_focus_guard_rejects_unverifiable_production_window():
    """A native UI lookup failure must block input, not trust stale OCR."""
    original_has_rpa = pt.HAS_RPA
    original_run = pt.RUN
    original_log = pt.log
    original_record = pt.record_event
    try:
        class NoNativeHandle:
            def set_focus(self):
                pass

        events = []
        pt.HAS_RPA = True
        pt.RUN = {"focus_blocks": 0}
        pt.log = lambda *args, **kwargs: None
        pt.record_event = lambda kind, *args, **kwargs: events.append(kind)
        assert not pt._focus_pt_window(NoNativeHandle(), "R1", "guard")
        assert pt.RUN["focus_blocks"] == 1
        assert events == ["pt_focus_blocked"]
    finally:
        pt.HAS_RPA = original_has_rpa
        pt.RUN = original_run
        pt.log = original_log
        pt.record_event = original_record


def test_privileged_gate_never_latches_after_failed_enable():
    """Two unverified enables block the config/security path."""
    original_confirmed = pt._confirmed_state
    original_mode_send = pt._mode_send
    original_record = pt.record_event
    original_log = pt.log
    original_run = pt.RUN
    try:
        sent = []
        pt._confirmed_state = lambda *args, **kwargs: ("cli", "Switch>")
        pt._mode_send = lambda win, dev, command, delay_ms, expected=None: (
            sent.append(command) or "user"
        )
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        pt.RUN = {"cli_context_blocks": 0}
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_ENABLE_ATTEMPTS.clear()
        assert not pt._ensure_privileged_cli(object(), "SW1", 25)
        assert sent == ["enable", "enable"]
        assert "SW1" not in pt._CLI_MODE_LATCH
        assert pt.RUN["cli_context_blocks"] == 1
    finally:
        pt._confirmed_state = original_confirmed
        pt._mode_send = original_mode_send
        pt.record_event = original_record
        pt.log = original_log
        pt.RUN = original_run
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_ENABLE_ATTEMPTS.clear()


def test_mode_send_uses_safe_deterministic_submode_transition():
    """A stale Router# repaint must not cause a second configure terminal."""
    original_type = pt._type_line
    original_confirmed = pt._confirmed_state
    original_errors = pt._term_error_signature
    original_sleep = pt._interruptible_sleep
    original_record = pt.record_event
    original_log = pt.log
    original_latch = dict(pt._CLI_MODE_LATCH)
    original_attempts = dict(pt._CLI_ENABLE_ATTEMPTS)
    try:
        sent = []
        pt._type_line = lambda *args, **kwargs: (
            sent.append(args[0] if args else kwargs.get("line", ""))
            or True
        )
        # `_mode_send` takes one baseline error read, then one fresh error
        # read. Both remain unchanged, while OCR exposes the stale privileged
        # row rather than the newly painted config row.
        pt._term_error_signature = lambda *args, **kwargs: (0, "")
        pt._confirmed_state = lambda *args, **kwargs: ("cli", "Router#")
        pt._interruptible_sleep = lambda *args, **kwargs: True
        pt.record_event = lambda *args, **kwargs: None
        pt.log = lambda *args, **kwargs: None
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_ENABLE_ATTEMPTS.clear()
        assert pt._mode_send(
            object(), "R1", "configure terminal", 25,
            expected="config"
        ) == "config"
        assert sent == ["configure terminal"]
        assert pt._CLI_MODE_LATCH["R1"] == "config"
    finally:
        pt._type_line = original_type
        pt._confirmed_state = original_confirmed
        pt._term_error_signature = original_errors
        pt._interruptible_sleep = original_sleep
        pt.record_event = original_record
        pt.log = original_log
        pt._CLI_MODE_LATCH.clear()
        pt._CLI_MODE_LATCH.update(original_latch)
        pt._CLI_ENABLE_ATTEMPTS.clear()
        pt._CLI_ENABLE_ATTEMPTS.update(original_attempts)


def test_cli_transition_guard_fails_closed_outside_submode():
    """`end`/`exit` are skipped or blocked unless a live submode is proven."""
    original_confirmed = pt._confirmed_state
    original_record = pt.record_event
    original_run = pt.RUN
    try:
        events = []
        pt.record_event = lambda kind, *args, **kwargs: events.append(kind)
        pt.RUN = {"cli_context_blocks": 0}

        pt._confirmed_state = lambda *args, **kwargs: ("cli", "Router#")
        assert pt._guard_cli_transition(
            object(), "R1", "end", "config"
        ) == ("skip", "privileged")

        pt._confirmed_state = lambda *args, **kwargs: (
            "cli", "Router(config-if)#"
        )
        assert pt._guard_cli_transition(
            object(), "R1", "end", "interface"
        ) == ("allow", "interface")

        pt._confirmed_state = lambda *args, **kwargs: ("cli", "Router>")
        assert pt._guard_cli_transition(
            object(), "R1", "exit", "config"
        ) == ("skip", "user")

        pt._confirmed_state = lambda *args, **kwargs: ("unknown", "")
        assert pt._guard_cli_transition(
            object(), "R1", "end", "config"
        ) == ("block", "unknown")
        assert pt.RUN["cli_context_blocks"] == 1
        assert "cli_transition_skipped" in events
        assert "cli_context_blocked" in events
    finally:
        pt._confirmed_state = original_confirmed
        pt.record_event = original_record
        pt.RUN = original_run


def test_cli_tab_selection_verifies_the_active_parent_tab():
    """A successful UIA click is not enough unless Packet Tracer is on CLI."""
    active = {"name": "Config"}

    class TabItem:
        element_info = SimpleNamespace(control_type="TabItem", name="CLI")

        def rectangle(self):
            return SimpleNamespace(left=10, top=10, right=60, bottom=30)

        def select(self):
            active["name"] = "CLI"

        def click_input(self):
            raise AssertionError("select() should handle Packet Tracer tabs")

        def invoke(self):
            raise AssertionError("select() should handle Packet Tracer tabs")

        def click(self):
            raise AssertionError("select() should handle Packet Tracer tabs")

    class ActiveTab:
        element_info = SimpleNamespace(control_type="Tab", name="Config")

        def window_text(self):
            return active["name"]

    class Root:
        def descendants(self):
            tab = ActiveTab()
            tab.element_info.name = active["name"]
            return [tab, TabItem()]

    class Window:
        element_info = SimpleNamespace(handle=123)

    original_focus = pt._focus_pt_window
    original_input = pt._focus_cli_input
    original_desktop = pt.Desktop
    original_sleep = pt._interruptible_sleep
    try:
        pt._focus_pt_window = lambda *args, **kwargs: True
        pt._focus_cli_input = lambda *args, **kwargs: True
        pt._interruptible_sleep = lambda *args, **kwargs: True
        pt.Desktop = lambda backend=None: SimpleNamespace(
            window=lambda handle=None: Root()
        )
        assert pt._focus_cli_tab(Window(), "R1")
        assert active["name"] == "CLI"
    finally:
        pt._focus_pt_window = original_focus
        pt._focus_cli_input = original_input
        pt.Desktop = original_desktop
        pt._interruptible_sleep = original_sleep


def test_maximize_activation_never_restores_normal_window():
    """Maximizing must not issue SW_RESTORE to an already normal window."""
    class NativeWindow:
        element_info = SimpleNamespace(handle=20)

    class FakeUser32:
        def __init__(self, iconic=False):
            self.iconic = iconic
            self.calls = []

        def GetAncestor(self, hwnd, relation):
            return 10

        def IsIconic(self, hwnd):
            return self.iconic

        def ShowWindow(self, hwnd, command):
            self.calls.append(("show", hwnd, command))
            return 1

        def SetForegroundWindow(self, hwnd):
            self.calls.append(("foreground", hwnd))
            return 1

    import ctypes

    user32 = FakeUser32(iconic=False)
    with patch.object(ctypes, "windll", SimpleNamespace(user32=user32)):
        assert pt._activate_window_handle(NativeWindow(), maximize=True)
    assert ("show", 10, 9) not in user32.calls  # no restore/toggle
    assert ("show", 10, 3) in user32.calls  # explicit maximize

    user32 = FakeUser32(iconic=True)
    with patch.object(ctypes, "windll", SimpleNamespace(user32=user32)):
        assert pt._activate_window_handle(NativeWindow(), maximize=False)
    assert ("show", 10, 9) in user32.calls  # minimized windows recover


def test_serial_fallback_and_cli_rewrite_are_explicit():
    assert pt._serial_fallback_candidate(
        {"gigabitethernet0/0", "gigabitethernet0/1"}, set()
    ) == ("gigabitethernet0/1", "g0/1")
    assert pt._serial_fallback_candidate(
        {"gigabitethernet0/0", "gigabitethernet0/1"},
        {"gigabitethernet0/1"},
    ) == ("", "")

    original_run = pt.RUN
    original_record = pt.record_event
    try:
        pt.RUN = {"interface_remaps": {
            "HQ_Router": {"s0/0/0": "g0/1"},
        }}
        pt.record_event = lambda *args, **kwargs: None
        steps = [{"action": "paste_cli", "configs": {
            "HQ_Router": "interface s0/0/0\n ip address 10.0.0.1 255.255.255.252\nexit",
        }}]
        pt._apply_interface_remaps_to_plan(steps)
        assert "interface g0/1" in steps[0]["configs"]["HQ_Router"]
        assert "interface s0/0/0" not in steps[0]["configs"]["HQ_Router"]
    finally:
        pt.RUN = original_run
        pt.record_event = original_record


def test_validation_rejects_a_spare_port_for_an_exact_interface_plan():
    """Functional WAN recovery must not masquerade as exact S0/0/0 wiring."""
    original_run = pt.RUN
    original_phase = pt.phase_update
    original_record = pt.record_event
    try:
        pt.RUN = {
            "interface_remaps": {
                "HQ_Router": {"s0/0/0": "g0/1"},
            },
            "interfaces_blocked": 0,
        }
        pt.phase_update = lambda *args, **kwargs: None
        pt.record_event = lambda *args, **kwargs: None
        report = pt.validate_run({}, "exact-interface-test", {}, {})
        fidelity = next(
            row for row in report["checks"]
            if row["name"] == "interface_fidelity"
        )
        assert fidelity["ok"] is False
        assert "g0/1" in fidelity["observed"]
    finally:
        pt.RUN = original_run
        pt.phase_update = original_phase
        pt.record_event = original_record


def test_security_evidence_rejects_stale_and_invalid_output():
    check = {
        "kind": "port_security",
        "requiredMarkers": [
            "port security", "enabled", "maximum mac addresses",
        ],
    }
    good = (
        "Switch# show port-security interface f0/2\n"
        "Port Security : Enabled\n"
        "Maximum MAC Addresses : 1\nSwitch#"
    )
    ok, evidence = pt._security_check_evidence(
        check, good, "Switch#\n", "privileged", True
    )
    assert ok and evidence["fresh_output"]
    stale, stale_evidence = pt._security_check_evidence(
        check, good, good, "privileged", True
    )
    assert not stale and not stale_evidence["fresh_output"]
    invalid, _ = pt._security_check_evidence(
        check, "Switch#\n% Invalid input detected", "Switch#\n",
        "privileged", True
    )
    assert not invalid


def test_link_evidence_requires_a_real_dark_corridor():
    from PIL import Image, ImageDraw

    original_mem = pt.DEV_MEM
    original_slot = pt.JOB.slot_of
    original_project = pt.JOB.project
    path = ""
    try:
        pt.DEV_MEM = {}
        pt.JOB.slot_of = {"A": 0, "B": 1}
        pt.JOB.project = "line-test"
        image = Image.new("RGB", (400, 400), (155, 155, 155))
        ImageDraw.Draw(image).line((140, 180, 180, 180), fill=(0, 0, 0), width=3)
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            path = tmp.name
        image.save(path)
        ok, evidence = pt._link_line_evidence(
            path, (0, 0, 400, 400), "line-test", "A", "B"
        )
        assert ok
        assert evidence["dark_corridor_hits"] >= evidence["required_hits"]
    finally:
        pt.DEV_MEM = original_mem
        pt.JOB.slot_of = original_slot
        pt.JOB.project = original_project
        if path and os.path.exists(path):
            os.remove(path)


def test_validation_cannot_pass_without_real_ping_results():
    original_run = pt.RUN
    original_phase = pt.phase_update
    original_record = pt.record_event
    try:
        pt.RUN = {
            "action_results": {
                "config_pc:PC0": {"status": "verified"},
            },
            "pcs_configured": 1,
            "pings_expected": 1,
            "ping_results": [],
            "pings_failed": 0,
            "pings_ok": 0,
            "inventory": {},
            "fullscreen_verified": True,
            "focus_blocks": 0,
            "devices_skipped": 0,
            "devices_reuse_blocked": 0,
            "errors_unrecovered": 0,
            "interfaces_blocked": 0,
            "red_link_check_ran": False,
            "links_red": 0,
            "links_failed": 0,
        }
        pt.phase_update = lambda *args, **kwargs: None
        pt.record_event = lambda *args, **kwargs: None
        plan = {"steps": [{"action": "config_pcs", "pcs": {
            "PC0": {"ip": "192.168.1.10", "gw": "192.168.1.1"},
        }}]}
        report = pt.validate_run(plan, "validation-test", {"PC0": 0}, {})
        ping = next(row for row in report["checks"] if row["name"] == "pings")
        assert ping["ok"] is False
        inventory = next(
            row for row in report["checks"] if row["name"] == "inventory"
        )
        assert inventory["ok"] is False
        assert report["ok"] is False
        empty_security = pt.validate_run(
            {"steps": [{"action": "verify_security", "checks": []}]},
            "security-validation-test", {}, {}
        )
        security = next(
            row for row in empty_security["checks"] if row["name"] == "security"
        )
        assert security["ok"] is False
        assert empty_security["ok"] is False
    finally:
        pt.RUN = original_run
        pt.phase_update = original_phase
        pt.record_event = original_record


def main():
    check_activity_lock()
    check_stop_aware_ui_boundary()
    check_cli_and_interface_guard()
    check_ocr_upscale_and_fallback()
    nodes = [
        {"name": f"PC{i}", "type": "pc"}
        for i in range(1, 5)
    ] + [{"name": "SRV1", "type": "server"}]
    spots = pt._layout_spot(nodes)
    pc_y = {spots[i][1] for i in range(4)}
    assert len(pc_y) == 1
    assert spots[4][1] - next(iter(pc_y)) >= 0.10
    assert len(set(spots.values())) == len(nodes)
    print("ALL SAFETY TESTS PASSED")


if __name__ == "__main__":
    main()
