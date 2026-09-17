"""Packet Tracer-unsupported command handling: classifier + elision."""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

# Exactly the commands the live Packet Tracer CLI rejected with
# "% Invalid input detected" during the 2026-09-15 build run.
OBSERVED_UNSUPPORTED = [
    "time-range OFFICE_HOURS",
    "permit host 192.168.1.50 time-range OFFICE_HOURS",
    "crypto isakmp policy 10",
    "encr aes",
    "hash sha",
    "crypto isakmp key NetBuilderLab2026 address 10.1.1.1",
    "crypto ipsec transform-set SITE_VPN_SET esp-aes esp-sha-hmac",
    "crypto map SITE_VPN 10 ipsec-isakmp",
    "set transform-set SITE_VPN_SET",
    "crypto map SITE_VPN",
]

SUPPORTED = [
    "interface g0/0",
    "ip address 192.168.1.1 255.255.255.0",
    "router ospf 1",
    "network 10.1.1.0 0.0.0.3 area 0",
    "access-class VTY_MANAGER_ONLY in",
    "switchport port-security",
    "tacacs-server host 192.168.1.100",
    "ip route 192.168.1.0 255.255.255.0 10.1.1.1",
]


def _fresh_run():
    pt.RUN["unsupported_features"] = []
    pt.RUN["unsupported_features_count"] = 0
    pt.RUN["errors_unrecovered"] = 0


def test_observed_commands_classify_unsupported():
    for line in OBSERVED_UNSUPPORTED:
        assert pt._pt_unsupported_reason(line), f"not classified: {line}"


def test_supported_commands_are_not_classified():
    for line in SUPPORTED:
        assert pt._pt_unsupported_reason(line) == "", f"misclassified: {line}"


def test_crypto_map_block_is_elided_whole_with_one_event():
    cfg = "\n".join([
        "interface g0/0",
        "ip address 10.1.1.1 255.255.255.252",
        "no shutdown",
        "exit",
        "crypto map SITE_VPN 10 ipsec-isakmp",
        "set peer 10.1.1.2",
        "set transform-set SITE_VPN_SET",
        "match address SITE_VPN_TRAFFIC",
        "ip route 0.0.0.0 0.0.0.0 10.1.1.2",
    ])
    _fresh_run()
    events = []
    with patch.object(pt, "record_event",
                      side_effect=lambda *a, **k: events.append(k.get("kind", a[0] if a else ""))):
        lines = pt.cli_lines_for_device(cfg, "HQ_Router", report=True)

    joined = "\n".join(lines)
    assert "crypto map" not in joined
    assert "set peer" not in joined
    assert "set transform-set" not in joined
    assert "match address" not in joined
    assert "ip address 10.1.1.1 255.255.255.252" in joined
    assert "ip route 0.0.0.0 0.0.0.0 10.1.1.2" in joined
    assert events.count("unsupported_by_packet_tracer") == 1, events
    assert pt.RUN["unsupported_features_count"] == 4, pt.RUN["unsupported_features"]


def test_elision_does_not_increment_errors_unrecovered():
    cfg = "\n".join(["crypto isakmp policy 10", "encr aes", "hash sha"])
    _fresh_run()
    with patch.object(pt, "record_event"):
        pt.cli_lines_for_device(cfg, "HQ_Router", report=True)
    assert pt.RUN["errors_unrecovered"] == 0


def test_empty_interface_block_left_by_elision_is_removed():
    cfg = "\n".join([
        "interface g0/1",
        "crypto map SITE_VPN",
        "exit",
        "hostname HQ_Router",
    ])
    _fresh_run()
    with patch.object(pt, "record_event"):
        lines = pt.cli_lines_for_device(cfg, "HQ_Router", report=True)
    joined = "\n".join(lines)
    assert "interface g0/1" not in joined, joined
    assert "crypto map" not in joined
    assert "hostname HQ_Router" in joined
