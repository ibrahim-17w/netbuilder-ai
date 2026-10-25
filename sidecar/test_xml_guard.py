"""The XML guard: untrusted saves cannot expand entities.

A .pkt is untrusted input, and ElementTree honors internal DTD entity
expansion - a billion-laughs document pins the engine while it "audits".
Packet Tracer saves are plain data XML and never declare a DTD, so the
guard refuses the declaration class outright.
"""
from __future__ import annotations

import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xml_guard  # noqa: E402


def test_a_billion_laughs_document_is_refused():
    lol = (b'<?xml version="1.0"?>'
           b'<!DOCTYPE lolz [<!ENTITY lol "lol">'
           b'<!ENTITY lol2 "&lol;&lol;&lol;&lol;">]>'
           b'<root>&lol2;</root>')
    try:
        xml_guard.fromstring(lol)
    except xml_guard.UntrustedXmlError:
        pass
    except ET.ParseError as exc:
        raise AssertionError(f"refused, but as a parse error: {exc}")
    else:
        raise AssertionError("an entity-expansion document was parsed")


def test_case_evasion_is_refused_too():
    for doc in (b"<!doctype x><root/>", b"<!DoCtYpE x><root/>"):
        try:
            xml_guard.fromstring(doc)
        except xml_guard.UntrustedXmlError:
            continue
        raise AssertionError(f"case-evasion accepted: {doc!r}")


def test_plain_data_xml_parses_to_its_root():
    root = xml_guard.fromstring(
        b"<DEVICES><DEVICE><NAME>R1</NAME></DEVICE></DEVICES>"
    )
    assert root.tag == "DEVICES"


def test_str_is_accepted_bytes_are_accepted():
    assert xml_guard.fromstring("<root><A/></root>").tag == "root"
    assert xml_guard.fromstring(b"<root><B/></root>").tag == "root"


def test_undecodable_bytes_surface_as_a_parse_error():
    try:
        xml_guard.fromstring(b"\xff\xfe\x00\x01")
    except ET.ParseError:
        pass
    else:
        raise AssertionError("binary junk parsed")


if __name__ == "__main__":
    test_a_billion_laughs_document_is_refused()
    test_case_evasion_is_refused_too()
    test_plain_data_xml_parses_to_its_root()
    test_str_is_accepted_bytes_are_accepted()
    test_undecodable_bytes_surface_as_a_parse_error()
    print("ALL TESTS PASSED")
