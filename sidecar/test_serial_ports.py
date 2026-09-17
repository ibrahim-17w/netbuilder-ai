"""Serial WAN support: the module, the cable, and the clocking end.

A 2026-09-16 plan-to-PT reality check found two gaps that always ended the
same way - a WAN that was never wired:

* the router has no serial port (HWIC-2T is a Physical-tab module), and
* every link was cabled with ``select_copper()``, so even a router that DID
  have Serial0/0/0 could not be joined to another one: PT refuses a serial
  port on a copper cable, and a serial cable has one clocking (DCE) end that
  must carry ``clock rate``.

Both are now decisions the run makes, and both are still judged by evidence:
the module is only believed when the live interface table shows the new port,
and the cable kind follows the interfaces the link is actually wired on.

Runs without pyautogui/tesseract/Packet Tracer.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402


class _Rect:
    left, top, right, bottom = 0, 0, 1000, 700


class _Win:
    _allow_unverified_focus_for_test = True

    def rectangle(self):
        return _Rect()


TMP = tempfile.mkdtemp(prefix="serial_")


def reset_hw_memory():
    pt.HW_MEM = {}
    pt.HW_MEM_FILE = os.path.join(TMP, "hardware_memory.json")
    pt._SERIAL_INSTALL_TRIED.clear()


@pytest.fixture(autouse=True)
def _isolated_hardware_memory():
    """Every test starts with no learned module and no attempt debt."""
    reset_hw_memory()
    yield


# ---- the cable decision -----------------------------------------------

def test_serial_interfaces_need_a_serial_cable():
    link = {"a": "HQ_Router", "aIf": "s0/0/0",
            "b": "BR_Router", "bIf": "s0/0/0"}
    assert pt.cable_kind_for_link(link, "a") == pt.CABLE_SERIAL_DCE
    assert pt.cable_kind_for_link(link, "b") == pt.CABLE_SERIAL_DTE


def test_a_remapped_wan_is_not_cabled_with_a_serial_cable():
    """The interfaces decide: Serial0/0/0 remapped to g0/1 is copper."""
    link = {"a": "HQ_Router", "aIf": "g0/1", "b": "BR_Router", "bIf": "g0/1",
            "cable": "serial"}
    assert pt.cable_kind_for_link(link, "a") == pt.CABLE_COPPER


def test_copper_links_stay_copper():
    link = {"a": "HQ_Router", "aIf": "g0/0", "b": "HQ_Switch", "bIf": "f0/1"}
    assert pt.cable_kind_for_link(link, "a") == pt.CABLE_COPPER


def test_a_cable_hint_refines_only_where_interfaces_cannot():
    fiber = {"a": "SW1", "aIf": "g0/1", "b": "SW2", "bIf": "g0/1",
             "cable": "fiber"}
    console = {"a": "PC1", "aIf": "rs232", "b": "R1", "bIf": "console",
               "cable": "console"}
    assert pt.cable_kind_for_link(fiber, "a") == pt.CABLE_FIBER
    assert pt.cable_kind_for_link(console, "a") == pt.CABLE_CONSOLE


def test_the_dce_end_is_deterministic_and_honours_the_plan():
    link = {"a": "HQ_Router", "aIf": "s0/0/0", "b": "BR_Router",
            "bIf": "s0/0/0"}
    assert pt.serial_dce_end(link) == "a", "default: the 'a' end clocks"
    assert pt.serial_dce_end({**link, "dce": "b"}) == "b"
    assert pt.serial_dce_end({**link, "dce": "BR_Router"}) == "b"
    assert pt.serial_dce_end({**link, "dce": "HQ_Router"}) == "a"
    # PT attaches the end named by the palette entry to the FIRST-clicked
    # port, and this run always clicks 'a' first: so a link clocked on 'b'
    # is wired starting with the DTE cable and ends up with the DCE half on
    # 'b' - which is exactly the side that will carry `clock rate`.
    assert pt.cable_kind_for_link({**link, "dce": "BR_Router"}, "b") == \
        pt.CABLE_SERIAL_DTE


# ---- the palette click -------------------------------------------------

def test_select_cable_picks_the_named_palette_entry():
    asked = []

    def by_names(names, why, **kwargs):
        asked.append((tuple(names), why))
        return True

    with patch.object(pt, "click_by_names", side_effect=by_names):
        assert pt.select_cable(pt.CABLE_SERIAL_DTE) is True
    assert asked[0][0] == ("Connections",)
    assert asked[1][0] == ("Serial DTE",), asked
    # copper is what the old code always clicked - the wrapper must not drift
    asked.clear()
    with patch.object(pt, "click_by_names", side_effect=by_names):
        pt.select_copper()
    assert asked[1][0] == ("Copper Straight", "Copper Straight-Through",
                           "Copper"), asked


def test_select_cable_falls_back_to_its_cal_column():
    """Name clicks can miss; each kind has its own teachable column."""
    clicks = []

    with patch.object(pt, "click_by_names", return_value=False), \
         patch.object(pt, "find_pt_window", return_value=_Win()), \
         patch.object(pt, "click_frac",
                      side_effect=lambda *a, **k: clicks.append(a)):
        assert pt.select_cable(pt.CABLE_SERIAL_DCE) is True
    assert clicks, "the CAL fallback must still click"
    assert clicks[-1][1] == pt.CAL["conn_serial_dce_col"], clicks[-1]
    # ...and a kind that has no CAL key of its own never silently clicks
    # the copper column with a serial label attached.
    assert "conn_serial_dce_col" in pt.CAL_DEFAULTS


# ---- the HWIC install --------------------------------------------------

def _install(available_after, words=None, names_click=True):
    """Run _install_serial_module against a stubbed Physical tab."""
    reset_hw_memory()
    clicks, events, reads = [], [], {"rounds": 0}

    def read_ifaces(win):
        reads["rounds"] += 1
        return set(available_after), "table"

    def by_names(names, why, **kwargs):
        clicks.append(("name", tuple(names)))
        return names_click

    def words_for(win, psm=6):
        return list(words or []), 0, 0, 1000, 700

    with patch.object(pt, "click_by_names", side_effect=by_names), \
         patch.object(pt, "_win_words", side_effect=words_for), \
         patch.object(pt, "_click_text_in_window", return_value=None), \
         patch.object(pt, "_safe_click",
                      side_effect=lambda x, y: clicks.append(("click", x, y))), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli", return_value=True), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_read_interface_capabilities",
                      side_effect=read_ifaces), \
         patch.object(pt, "record_event",
                      side_effect=lambda kind, detail="", **k:
                      events.append((kind, detail, k.get("recovered"), k))), \
         patch.object(pt, "log"):
        result = pt._install_serial_module(_Win(), "HQ_Router", "test",
                                          "serial0/0/0",
                                          {"gigabitethernet0/0"})
    return result, clicks, events, reads


def test_the_module_is_believed_only_when_the_live_table_shows_it():
    module_row = [("HWIC-2T", 120, 430, 70, 14)]
    (available, reason), clicks, events, reads = _install(
        {"gigabitethernet0/0", "serial0/0/0"}, words=module_row)
    assert reason == "" and "serial0/0/0" in available, (available, reason)
    kinds = [k for k, _d, _r, _kw in events]
    assert "serial_module_installed" in kinds, kinds
    installed = [e for e in events if e[0] == "serial_module_installed"][0]
    assert installed[2] is True and installed[3]["extra"]["ports"] == [
        "serial0/0/0"]
    # power off BEFORE the module, power on after: two toggles
    power_clicks = [c for c in clicks if c[0] == "click" and
                    c[2] == int(700 * pt.CAL["hw_power"][1])]
    assert len(power_clicks) == 2, clicks
    assert any(c[0] == "click" and c[2] == 437 for c in clicks), \
        "the module name row must be clicked where OCR read it"
    assert reads["rounds"] == 1, "one proven read is enough"


def test_the_install_is_attempted_once_per_device_per_run():
    module_row = [("HWIC-2T", 120, 430, 70, 14)]
    reset_hw_memory()
    with patch.object(pt, "click_by_names", return_value=True), \
         patch.object(pt, "_win_words",
                      return_value=(module_row, 0, 0, 1000, 700)), \
         patch.object(pt, "_safe_click"), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli", return_value=True), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_read_interface_capabilities",
                      return_value=({"serial0/0/0"}, "")), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "record_event"), patch.object(pt, "log"):
        first = pt._install_serial_module(_Win(), "HQ_Router", "test",
                                          "serial0/0/0", set())
        second = pt._install_serial_module(_Win(), "HQ_Router", "test",
                                           "serial0/0/0", set())
    assert first[0] and "serial0/0/0" in first[0], first
    assert second == (None, "already attempted in this run"), second


def test_a_module_that_never_appears_is_journaled_as_a_failure():
    module_row = [("HWIC-2T", 120, 430, 70, 14)]
    (available, reason), _clicks, events, reads = _install(
        {"gigabitethernet0/0"}, words=module_row)
    assert available is None and reason, (available, reason)
    kinds = [k for k, _d, _r, _kw in events]
    assert "serial_module_install_failed" in kinds, kinds
    failed = [e for e in events if e[0] == "serial_module_install_failed"][0]
    assert failed[2] is False
    assert "no serial port appeared" in failed[1], failed
    assert reads["rounds"] == pt._SERIAL_INSTALL_ROUNDS, reads


def test_an_unmeasurable_window_is_not_a_device_failure():
    """Nothing was attempted, so nothing may be blamed on the router."""
    reset_hw_memory()
    events = []
    with patch.object(pt, "record_event",
                      side_effect=lambda kind, *a, **k: events.append(kind)), \
         patch.object(pt, "log"):
        available, reason = pt._install_serial_module(
            {"dev": "HQ_Router"}, "HQ_Router", "test", "serial0/0/0", set())
    assert available is None and reason
    assert events == [], f"no event may be blamed on the device: {events}"


def test_the_install_can_be_switched_off():
    reset_hw_memory()
    with patch.object(pt, "SERIAL_AUTO_MODULE", False), \
         patch.object(pt, "log"):
        available, reason = pt._install_serial_module(
            _Win(), "HQ_Router", "test", "serial0/0/0", set())
    assert available is None
    assert "NETBUILDER_SERIAL_MODULE" in reason, reason


def test_the_working_slot_is_remembered_for_the_next_run():
    module_row = [("HWIC-2T", 120, 430, 70, 14)]
    _result, clicks, _events, _reads = _install(
        {"serial0/0/0"}, words=module_row)
    with open(pt.HW_MEM_FILE, encoding="utf-8") as f:
        saved = json.load(f)
    entry = saved["test"]["HQ_Router"]
    assert entry["module"] == "HWIC-2T"
    assert entry["ports"] == ["serial0/0/0"]
    assert entry["slot"] == "hw_slot0", entry
    # the learned slot is clicked FIRST next time
    _result, clicks2, _events2, _reads2 = _install(
        {"serial0/0/0"}, words=module_row)
    first_slot = [c for c in clicks2 if c[0] == "click" and
                  c[2] == int(700 * pt.CAL["hw_slot0"][1])]
    assert first_slot, clicks2


# ---- the preflight prefers a serial port over the LAN -----------------

# ---- device-specific port names ---------------------------------------

def test_device_specific_ports_map_to_their_printed_names():
    """An AP/IP phone has 'Port 1'; a cloud has 'Ethernet1'/'Coaxial1'."""
    assert pt.iface_port_wants("port1") == ["Port 1", "Port1"]
    assert "Ethernet1" in pt.iface_port_wants("ethernet1")
    assert pt.iface_port_wants("internet") == ["Internet"]
    # Never a bare 'port': the match is a substring, so that would also
    # satisfy 'Port 2' and cable the wrong interface on an IP phone.
    assert all(k.lower() != "port" for k in pt.iface_port_wants("port1"))
    # ...and the Cisco forms keep their own contract
    assert pt.iface_port_wants("g0/1")[0] == "GigabitEthernet0/1"
    assert pt.iface_port_wants("s0/0/0")[0] == "Serial0/0/0"


def test_place_links_wires_a_wan_with_the_serial_cable():
    """The link that was copper-only now picks serial and records the DCE."""
    pt.RUN["link_results"] = {}
    pt.RUN.pop("serial_links", None)
    cables, events = [], []
    links = [{"a": "HQ_Router", "aIf": "s0/0/0",
              "b": "BR_Router", "bIf": "s0/0/0", "cable": "serial"}]
    with patch.object(pt, "find_pt_window", return_value=_Win()), \
         patch.object(pt, "_focus_pt_window", return_value=True), \
         patch.object(pt, "shot_path", side_effect=lambda n: n), \
         patch.object(pt, "shot"), \
         patch.object(pt, "_shot_region", return_value="png"), \
         patch.object(pt, "_link_endpoint", return_value=True), \
         patch.object(pt, "canvas_changed", return_value=(True, 0.9)), \
         patch.object(pt, "_link_line_evidence",
                      side_effect=[(False, {}),
                                   (True, {"dark_corridor_hits": 9})]), \
         patch.object(pt, "select_cable",
                      side_effect=lambda k: cables.append(k) or True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event",
                      side_effect=lambda kind, detail="", **k:
                      events.append((kind, detail, k.get("extra")))), \
         patch.object(pt, "log"):
        pt.place_links(_Rect(), links, {"HQ_Router": 0, "BR_Router": 1},
                       "test",
                       {("HQ_Router", "BR_Router"): ("s0/0/0", "s0/0/0")})
    assert cables == [pt.CABLE_SERIAL_DCE], cables
    result = pt.RUN["link_results"]["0"]
    assert result["cable"] == pt.CABLE_SERIAL_DCE and \
        result["status"] == "verified", result
    assert pt.RUN["serial_links"]["HQ_Router:s0/0/0<->BR_Router:s0/0/0"] \
        ["dce"] == "HQ_Router"
    kinds = [k for k, _d, _e in events]
    assert "serial_cable_selected" in kinds, kinds
    chosen = [e for e in events if e[0] == "serial_cable_selected"][0]
    assert chosen[2]["dce"] == "HQ_Router", chosen


def test_preflight_prefers_another_serial_port_over_gigabit_ethernet():
    """A module in the wrong slot is still the serial WAN that was asked for."""
    reset_hw_memory()
    pt.RUN["interface_remaps"] = {}
    pt.RUN["link_results"] = {}
    pt.RUN["interfaces_unverified"] = 0
    pt.RUN["interfaces_blocked"] = 0
    pt.RUN["interface_blocked_devices"] = []
    links = [{"a": "HQ_Router", "aIf": "s0/0/0",
              "b": "BR_Router", "bIf": "s0/0/0"}]
    usable = [dict(l) for l in links]
    events = []
    with patch.object(pt, "_open_device_window", return_value=_Win()), \
         patch.object(pt, "_focus_cli_tab", return_value=True), \
         patch.object(pt, "_focus_cli_input", return_value=True), \
         patch.object(pt, "_settle_boot_dialogs", return_value=True), \
         patch.object(pt, "_ensure_privileged_cli", return_value=True), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "_read_interface_capabilities",
                      return_value=({"gigabitethernet0/0",
                                     "gigabitethernet0/1"}, "")), \
         patch.object(pt, "_install_serial_module",
                      return_value=({"gigabitethernet0/0",
                                     "gigabitethernet0/1",
                                     "serial0/1/0"}, "done")), \
         patch.object(pt, "_close_device_window", return_value=None), \
         patch.object(pt, "record_event",
                      side_effect=lambda kind, detail="", **k:
                      events.append((kind, detail, k.get("extra")))), \
         patch.object(pt, "log"):
        blocked = pt._preflight_link_capabilities(
            _Rect(), usable, {"HQ_Router": 0, "BR_Router": 1}, "test")
    assert pt.RUN["interface_remaps"]["HQ_Router"]["s0/0/0"] == "s0/1/0", \
        pt.RUN["interface_remaps"]
    assert usable[0]["aIf"] == "s0/1/0", usable
    assert blocked == set(), "a usable serial port must not block the link"
    kinds = [k for k, _d, _e in events]
    assert "interface_remapped" in kinds
    remap = [e for e in events if e[0] == "interface_remapped"][0]
    assert remap[2]["actual"] == "serial0/1/0", remap


if __name__ == "__main__":
    test_serial_interfaces_need_a_serial_cable()
    test_a_remapped_wan_is_not_cabled_with_a_serial_cable()
    test_copper_links_stay_copper()
    test_a_cable_hint_refines_only_where_interfaces_cannot()
    test_the_dce_end_is_deterministic_and_honours_the_plan()
    test_select_cable_picks_the_named_palette_entry()
    test_select_cable_falls_back_to_its_cal_column()
    test_the_module_is_believed_only_when_the_live_table_shows_it()
    test_the_install_is_attempted_once_per_device_per_run()
    test_a_module_that_never_appears_is_journaled_as_a_failure()
    test_an_unmeasurable_window_is_not_a_device_failure()
    test_the_install_can_be_switched_off()
    test_the_working_slot_is_remembered_for_the_next_run()
    test_preflight_prefers_another_serial_port_over_gigabit_ethernet()
    print("ALL TESTS PASSED")
