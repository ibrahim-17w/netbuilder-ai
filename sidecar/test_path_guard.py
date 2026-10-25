"""The shared path gate refuses traversal before any file IO happens.

The engine serves HTTP for another device and the CLI tools take user
args, so a path reaching open()/os.replace is not necessarily ours: the
RAW check must run before abspath folds `..` out of sight.  These tests
pin the two halves of that contract - the refusal itself, and the fact
that well-formed paths (ours and the caller's) go through unchanged.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import path_guard  # noqa: E402
import pkt_builder  # noqa: E402


def test_real_paths_pass_through_unchanged():
    with tempfile.TemporaryDirectory() as tmp:
        deep = os.path.join(tmp, "a", "b", "state.json")
        assert path_guard.ensure_no_traversal(deep) == deep
        assert path_guard.ensure_no_traversal("shots/R1_panel.png") \
            == "shots/R1_panel.png"
        # A doubled dot INSIDE a segment is a filename, not a climb.
        assert path_guard.ensure_no_traversal("my..file.pkt") == "my..file.pkt"
        assert path_guard.ensure_no_traversal(Path(deep)) == deep


def test_traversal_is_refused_in_any_segment_and_both_separators():
    for raw in (
        r"..\..\..\Windows\system.ini",
        r"C:\labs\..\..\secret.pkt",
        "..",
        "a/..",
        "C:/labs/../other.pkt",
        r"mixed/separators\..\escape.pkt",
    ):
        try:
            path_guard.ensure_no_traversal(raw)
        except ValueError as caught:
            assert "'..'" in str(caught)
        else:
            raise AssertionError(f"traversal accepted: {raw}")


def test_a_state_write_through_open_state_round_trips():
    with tempfile.TemporaryDirectory() as tmp:
        state = os.path.join(tmp, "config_memory.json")
        with path_guard.open_state(state, "w") as stream:
            json.dump({"R1": {"line": "hostname R1"}}, stream)
        with path_guard.open_state(state) as stream:
            assert json.load(stream)["R1"]["line"] == "hostname R1"


def test_open_state_refuses_a_traversal_path():
    for raw in (r"..\pc_tiles.json", "C:/labs/../pc_tiles.json"):
        try:
            path_guard.open_state(raw, "w")
        except ValueError:
            pass
        else:
            raise AssertionError(f"open_state accepted traversal: {raw}")


def test_a_cli_style_output_path_with_traversal_is_refused():
    # generate_pkt_file is the offline tool's entry point (sys.argv[2]) and
    # the engine's generate endpoint; both go through the same gate.
    try:
        pkt_builder.generate_pkt_file({"steps": []}, r"..\escape.pkt")
    except ValueError as caught:
        assert "'..'" in str(caught)
    else:
        raise AssertionError("CLI output path with '..' was accepted")


if __name__ == "__main__":
    test_real_paths_pass_through_unchanged()
    test_traversal_is_refused_in_any_segment_and_both_separators()
    test_a_state_write_through_open_state_round_trips()
    test_open_state_refuses_a_traversal_path()
    test_a_cli_style_output_path_with_traversal_is_refused()
    print("ALL TESTS PASSED")
