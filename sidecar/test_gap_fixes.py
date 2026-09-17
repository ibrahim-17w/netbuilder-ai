"""Gap-fix coverage: DNS Add-button recovery + learning, DHCP-client PCs,
missing config-mode requirements, and newly elided PT-unsupported families."""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt


# ---------------------------------------------------------------- DNS Add

def test_dns_add_miss_evicts_learns_and_recovers():
    """First Add misses, second lands: evict + learn 'dns:add', record ok."""
    add_clicks = {"n": 0}
    learned, evicted = [], []

    def fake_button(win, dev, label, below_fy=0.0, svc=""):
        if label == "save":
            return {}  # trailing best-effort Save button
        assert label == "add" and svc == "dns"
        add_clicks["n"] += 1
        # first call: a learned (stale) spot; after eviction: fresh OCR spot
        if add_clicks["n"] == 1:
            return {"fx": 0.9, "fy": 0.8, "learned": True}
        return {"fx": 0.88, "fy": 0.79, "learned": False}

    saved_results = [  # first read: MISS, second read: HIT
        (False, ""), (True, "srv1 10.0.0.99"),
    ]

    with patch.object(pt, "_srv_select", return_value=True), \
         patch.object(pt, "_srv_radio_on", return_value=True), \
         patch.object(pt, "_srv_fill",
                      side_effect=[(True, {"fy": 0.40}),
                                   (True, {"fy": 0.44})]), \
         patch.object(pt, "_srv_button", side_effect=fake_button), \
         patch.object(pt, "_dns_record_saved",
                      side_effect=lambda *a, **k: saved_results.pop(0)), \
         patch.object(pt, "_dismiss_error_dialog", return_value=True), \
         patch.object(pt, "_srv_evict_button",
                      lambda key, dev="": evicted.append(key)), \
         patch.object(pt, "_srv_learn_button",
                      lambda key, fx, fy, dev="": learned.append(key)), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        ok = pt._svc_flow_dns(object(), "SRV1",
                              {"records": [{"name": "srv1",
                                            "address": "10.0.0.99"}]})
    assert ok is True
    assert evicted == ["dns:add"], "stale learned Add spot must be evicted"
    assert learned == ["dns:add"], "verified Add spot must be learned"
    assert add_clicks["n"] >= 2


def test_dns_add_double_miss_reports_honestly():
    saved_results = [(False, ""), (False, "")]

    with patch.object(pt, "_srv_select", return_value=True), \
         patch.object(pt, "_srv_radio_on", return_value=True), \
         patch.object(pt, "_srv_fill",
                      side_effect=[(True, {"fy": 0.40}),
                                   (True, {"fy": 0.44})]), \
         patch.object(pt, "_srv_button",
                      return_value={"fx": 0.9, "fy": 0.8,
                                    "learned": False}), \
         patch.object(pt, "_dns_record_saved",
                      side_effect=lambda *a, **k: saved_results.pop(0)), \
         patch.object(pt, "_dismiss_error_dialog", return_value=False), \
         patch.object(pt, "_srv_learn_button",
                      side_effect=AssertionError(
                          "must NOT learn a spot that never verified")), \
         patch.object(pt, "_fail_shot", return_value=None), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        ok = pt._svc_flow_dns(object(), "SRV1",
                              {"records": [{"name": "srv1",
                                            "address": "10.0.0.99"}]})
    assert ok is False
    assert pt._dns_record_saved not in (None,)


# ------------------------------------------------------------ DHCP client

class _FakeRect:
    left, top, right, bottom = 0, 0, 1000, 800


def test_pc_select_dhcp_clicks_label_and_verifies_lease():
    # OCR word list entry: (word, x, y, w, h) in window pixels.
    # window 1000x800: DHCP label at y ~ 0.21*800 = 168
    words = [("Static", 60, 140, 60, 18), ("DHCP", 60, 168, 50, 18)]

    def fake_words(win, psm=None):
        return words, 0, 0, 1000, 800

    clicks = []

    def fake_click(x, y):
        clicks.append((x, y))
        return True

    with patch.object(pt, "_win_words", side_effect=fake_words), \
         patch.object(pt, "_safe_click", side_effect=fake_click), \
         patch.object(pt, "_ocr_region",
                      return_value="IP Address 192.168.10.50\n"
                                   "Subnet Mask 255.255.255.0"), \
         patch.object(pt, "_OCR_CACHE", pt._OCR_CACHE), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        assert pt._pc_select_dhcp(object(), "PC1") is True
    assert clicks, "the DHCP radio must actually be clicked"
    assert abs(clicks[0][1] - 177) <= 1  # label center y


def test_pc_select_dhcp_never_clicks_without_a_label():
    with patch.object(pt, "_win_words",
                      return_value=([], 0, 0, 1000, 800)), \
         patch.object(pt, "_safe_click",
                      side_effect=AssertionError("no blind clicks")), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        assert pt._pc_select_dhcp(object(), "PC1") is False


def test_config_pc_desktop_dhcp_mode_short_circuits_static_fill():
    """dhcp: true must not type static values into the panel."""
    opened = {"app": False}

    with patch.object(pt, "_open_device_window", return_value=object()), \
         patch.object(pt, "_pc_open_desktop_app",
                      side_effect=lambda *a, **k: opened.__setitem__(
                          "app", True) or True), \
         patch.object(pt, "_resolve_pc_field_rows",
                      return_value=(0.3, {}, "fixed")), \
         patch.object(pt, "_pc_select_dhcp", return_value=True) as dhcp, \
         patch.object(pt, "_fill_field",
                      side_effect=AssertionError(
                          "static fill must not run for a DHCP client")), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        ok = pt._config_pc_desktop((0, 0, 1000, 800), "PC1", 0,
                                   {"dhcp": True}, "p")
    assert ok is True
    assert dhcp.called
    assert opened["app"]


# ------------------------------------------------- mode requirements

def test_config_mode_requirements_added():
    req = pt._command_requirement
    assert req("enable secret cisco", {}) == "config"
    assert req("enable password cisco", {}) == "config"
    assert req("banner motd #hi#", {}) == "config"
    assert req("ip domain-name lab.local", {}) == "config"
    assert req("ip name-server 8.8.8.8", {}) == "config"
    assert req("ip default-gateway 192.168.1.1", {}) == "config"
    assert req("login", {}) == "line"
    assert req("login local", {}) == "line"
    # unchanged behaviour for interface commands
    assert req("ip address 10.0.0.1 255.0.0.0", {}) == "interface"


# ------------------------------------- newly unsupported families

def test_new_unsupported_families():
    reason = pt._pt_unsupported_reason
    assert reason("ip sla 1") == "IP SLA"
    assert reason("ip sla schedule 1 life forever") == "IP SLA"
    assert reason("class-map VOICE") == "QoS class/policy maps"
    assert reason("policy-map QOS-POLICY") == "QoS class/policy maps"
    assert reason("shape average 512000") == "QoS class/policy maps"
    assert reason("bandwidth percent 40") == "QoS class/policy maps"
    assert reason("zone security INSIDE") == "zone-based firewall"
    assert reason("zone-pair security ZP source INSIDE") == \
        "zone-based firewall"
    # PT-VALID lines must still pass through untouched:
    assert reason("permit ip host 1.1.1.1 host 2.2.2.2") == ""
    assert reason("match ip address 100") == ""     # route-map match stays
    assert reason("bandwidth 128") == ""            # plain bandwidth stays
    assert reason("ip route 0.0.0.0 0.0.0.0 10.0.0.1") == ""


def test_policy_map_family_elided_with_children():
    lines = [
        "hostname R1",
        "policy-map QOS",
        "shape average 512000",
        "exit",
        "interface g0/0",
        "ip address 10.0.0.1 255.0.0.0",
    ]
    kept = pt._elide_pt_unsupported(lines, "R1", report=False)
    assert "policy-map QOS" not in kept
    assert "shape average 512000" not in kept
    assert "hostname R1" in kept
    assert "interface g0/0" in kept
    assert "ip address 10.0.0.1 255.0.0.0" in kept


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok {name}")
    print("all gap-fix tests passed")
