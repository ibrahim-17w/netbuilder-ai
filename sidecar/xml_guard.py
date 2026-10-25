"""XML parsing that refuses DTD entity expansion.

A .pkt save is untrusted input: it comes from a tester's machine, a
classmate, a download. Python's ElementTree honors internal DTD entity
expansion, so a hand-crafted save can carry a billion-laughs document
that pins the engine's CPU and memory while it "audits" - the file asks
for the resources, the engine pays. Packet Tracer's own saves are plain
data XML and never declare a DOCTYPE or an ENTITY, so refusing both
costs nothing legitimate and closes the class.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET

_FORBIDDEN = ("<!doctype", "<!entity")


class UntrustedXmlError(ValueError):
    """The document declares something a Packet Tracer save never does."""


def fromstring(source: bytes | str) -> ET.Element:
    """Parse an untrusted XML document, refusing DTD/entity declarations."""
    if isinstance(source, bytes):
        try:
            text = source.decode("utf-8")
        except UnicodeDecodeError:
            # Packet Tracer saves are UTF-8; an undecodable document is not
            # one, and decode errors surface as the parse error callers
            # already handle.
            raise ET.ParseError("not utf-8: not a Packet Tracer document")
    else:
        text = source
    lowered = text.lower()
    for marker in _FORBIDDEN:
        if marker in lowered:
            raise UntrustedXmlError(
                "the document declares a DTD or entity - Packet Tracer "
                "saves never do, so this is not a save (and the entity "
                "expansion it asks for is exactly what this parser must "
                "refuse)"
            )
    return ET.fromstring(text)
