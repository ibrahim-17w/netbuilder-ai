"""Sidebar service matching must not confuse DHCP with DHCPv6.

Packet Tracer lists DHCP directly above DHCPv6.  A substring test made
`_srv_select("dhcp")` click the DHCPv6 row, and the matching substring check on
the panel title accepted DHCPv6 as DHCP - so every IPv4 pool field looked
missing and the DHCP pool was never created (2026-09-16 12:10, DHCP1;
evidence: shots/DHCP1_dhcp_fail.png).
"""
from __future__ import annotations

import pt_autopilot as pt

M = pt._svc_word_matches


def test_dhcp_does_not_match_dhcpv6():
    assert M("DHCP", "dhcp") is True
    assert M("DHCPv6", "dhcp") is False
    assert M("dhcpv6", "dhcp") is False
    assert M("DHCPv6", "dhcpv6") is True


def test_http_does_not_match_https():
    assert M("HTTP", "http") is True
    assert M("HTTPS", "http") is False
    assert M("HTTPS", "https") is True


def test_every_service_matches_only_its_own_label():
    for token in ("dns", "tftp", "syslog", "aaa", "ntp", "email", "ftp",
                  "iot", "prp"):
        for label in pt._SVC_LABELS:
            expected = (label == token)
            assert M(label.upper(), token) is expected, (label, token)


def test_case_and_whitespace_are_tolerated():
    assert M("  dhcp  ", "DHCP") is True
    assert M("dns", " DNS ") is True


def test_empty_inputs_never_match():
    assert M("", "dhcp") is False
    assert M("dhcp", "") is False
    assert M(None, "dhcp") is False


def test_srv_select_uses_the_strict_matcher():
    import inspect
    src = inspect.getsource(pt._srv_select)
    assert "_svc_word_matches(wd, token)" in src
    assert "token in wd" not in src
    assert "if token in title" not in src
