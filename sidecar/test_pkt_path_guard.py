"""The .pkt path resolver refuses traversal, whatever the caller sends.

The path arrives over HTTP when the engine serves another device, so
`..` segments are rejected outright: a legitimate client names a real
file, and one that games the resolver is probing, not auditing.
"""
from __future__ import annotations

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402


def test_a_real_file_resolves():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "lab.pkt")
        with open(path, "wb") as stream:
            stream.write(b"PKT")
        # abspath preserves the caller's casing; resolution is identity for
        # a well-formed absolute path.
        assert pt._pkt_path(path) == os.path.abspath(path)


def test_traversal_segments_are_rejected_before_anything_else():
    for raw in (
        r"..\..\..\Windows\system.ini.pkt",
        r"C:\labs\..\..\secret.pkt",
        r"..\lab.pkt",
        "C:/labs/../other.pkt",
    ):
        try:
            pt._pkt_path(raw, must_exist=False)
        except ValueError as caught:
            assert "''" not in str(caught) and "'..'" in str(caught)
        else:
            raise AssertionError(f"traversal accepted: {raw}")


def test_a_missing_file_still_reports_itself():
    try:
        pt._pkt_path(os.path.join(tempfile.gettempdir(), "no-such-lab.pkt"))
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("a missing file must not resolve")


def test_the_extension_gate_stands():
    try:
        pt._pkt_path("C:\\labs\\notes.txt", must_exist=False)
    except ValueError as caught:
        assert "Only Packet Tracer" in str(caught)
    else:
        raise AssertionError("a non-pkt path must not resolve")


if __name__ == "__main__":
    test_a_real_file_resolves()
    test_traversal_segments_are_rejected_before_anything_else()
    test_a_missing_file_still_reports_itself()
    test_the_extension_gate_stands()
    print("ALL TESTS PASSED")
