"""Tests for the wireless (SSID/WEP) writer in pkt_builder.

Schema verified against real saves: AP ENGINE carries WIRELESS_SERVER >
WIRELESS_COMMON (SSID, ENCRYPT_TYPE, AUTHEN_TYPE) plus SSID_BROADCAST_ENABLED
and WEP_KEY; endpoints carry the mirrored WIRELESS_CLIENT profile.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pkt_builder  # noqa: E402

LIB = pkt_builder.load_library()


def _build(rules):
    plan = {
        "steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "AP1", "type": "accesspoint",
                 "model": "AccessPoint-PT", "serviceRules": rules},
            ]},
        ],
    }
    return pkt_builder.build_pkt(plan, LIB)["xml"]


def test_ssid_and_wep_land_on_the_ap():
    xml = _build({"wireless": {"ssid": "CORP", "wep": "1234567890"}})
    assert b"<SSID>CORP</SSID>" in xml
    assert xml.count(b"<AUTHEN_TYPE>1</AUTHEN_TYPE>") >= 1
    assert b"<WEP_KEY>1234567890</WEP_KEY>" in xml


def test_open_ssid_keeps_auth_open():
    xml = _build({"wireless": {"ssid": "GUEST"}})
    assert b"<SSID>GUEST</SSID>" in xml
    m = re.search(
        rb"<WIRELESS_COMMON>.*?<SSID>GUEST</SSID>.*?"
        rb"<ENCRYPT_TYPE>(\d+)</ENCRYPT_TYPE>",
        xml, re.S)
    assert m and m.group(1) == b"0"


def test_ssid_broadcast_can_be_disabled():
    xml = _build({"wireless": {"ssid": "HIDDEN", "broadcast": False}})
    m = re.search(rb"<SSID_BROADCAST_ENABLED>(\d)</SSID_BROADCAST_ENABLED>", xml)
    assert m and m.group(1) == b"0"


def test_no_wireless_rule_leaves_template_untouched():
    xml = _build({})
    assert b"<SSID>Default</SSID>" in xml
