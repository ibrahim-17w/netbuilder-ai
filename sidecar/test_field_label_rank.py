"""An exact field label must outrank a longer label that contains it.

The DNS service panel offers both "Name" and "Domain Name"; the old
topmost-substring pick could target the domain row when the flow wanted the
record Name. Exact matches now rank first - the same fix shape as DHCP vs
DHCPv6 in the sidebar, which did break a real run.
"""
from __future__ import annotations

import inspect

import pt_autopilot as pt

R = pt._label_rank


def test_exact_label_ranks_first():
    assert R("name", "Name") == 0
    assert R("name", "Domain Name") == 1
    assert R("gateway", "Gateway") == 0
    assert R("gateway", "Default Gateway") == 1
    assert R("dns", "DNS Server") == 1
    assert R("dns", "DNS") == 0


def test_case_spacing_and_punctuation_are_normalised():
    assert R("start", "Start IP Address") == 1
    assert R("start", "Start") == 0
    assert R("domain name", "DomainName") == 0
    assert R("domain-name", "Domain Name") == 0


def test_empty_token_never_claims_an_exact_hit():
    assert R("", "Name") == 1
    assert R("   ", "Name") == 1


def test_sort_puts_the_exact_row_first_even_when_lower():
    words = [("domainname", 40, 100, 60, 12), ("name", 40, 200, 30, 12)]
    ranked = sorted(words, key=lambda z: (R("name", z[0]), z[2], z[1]))
    assert ranked[0][0] == "name", ranked


def test_containing_label_wins_when_it_is_the_only_candidate():
    words = [("defaultgateway", 40, 100, 60, 12)]
    ranked = sorted(words, key=lambda z: (R("gateway", z[0]), z[2], z[1]))
    assert ranked[0][0] == "defaultgateway"


def test_field_lookup_uses_the_ranked_sort():
    src = inspect.getsource(pt._srv_find_field_live)
    assert "_label_rank(token, z[0])" in src
    assert "key=lambda z: (z[2], z[1])" not in src
