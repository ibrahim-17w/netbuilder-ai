"""Evidence screenshots, served read-only for the chat to look at.

The chat can attach a frame the run already captured, so "what is it stuck
on?" is answered from the actual pixels rather than from a description of
them.  The endpoint reads only: it never captures, never writes, and never
leaves the sidecar directory.
"""
from __future__ import annotations

import base64
import os

import pytest

import pt_autopilot as pt

PNG = b"\x89PNG\r\n\x1a\n" + b"fake-pixels" * 8


@pytest.fixture
def shots(tmp_path, monkeypatch):
    folder = tmp_path / "shots"
    folder.mkdir()
    monkeypatch.setattr(pt, "SHOTS", str(folder))
    return folder


def _write(folder, name: str, data: bytes = PNG):
    path = folder / name
    path.write_bytes(data)
    return path


def test_listing_returns_only_png_newest_first(shots):
    _write(shots, "before.png")
    _write(shots, "after.png")
    _write(shots, "notes.txt", b"not an image")
    # OCR scratch files are not evidence and must stay out of the picker.
    _write(shots, "_ocr_tmp.png")
    os.utime(shots / "before.png", (1_700_000_000, 1_700_000_000))
    os.utime(shots / "after.png", (1_700_000_500, 1_700_000_500))

    rows = pt.shot_listing()
    assert [row["name"] for row in rows] == ["after.png", "before.png"]
    assert rows[0]["bytes"] == len(PNG)
    assert rows[0]["modified"].startswith("20")
    assert rows[0]["epoch"] > rows[1]["epoch"]


def test_listing_is_empty_and_silent_when_there_is_no_folder(
        tmp_path, monkeypatch):
    monkeypatch.setattr(pt, "SHOTS", str(tmp_path / "nope"))
    assert pt.shot_listing() == []


def test_listing_respects_its_limit(shots):
    for index in range(5):
        _write(shots, f"shot_{index}.png")
    assert len(pt.shot_listing(limit=2)) == 2


def test_a_real_screenshot_comes_back_as_base64(shots):
    _write(shots, "before.png")
    row = pt.read_shot("before.png")
    assert row["name"] == "before.png"
    assert row["mimeType"] == "image/png"
    assert row["bytes"] == len(PNG)
    assert base64.b64decode(row["data"]) == PNG


def test_sanitizing_is_stable_so_written_names_are_readable(shots):
    """`shot()` sanitizes both halves of a name, so a read must sanitize too.

    The property that matters is that sanitizing is idempotent: a name the
    writer produced has to survive a second pass unchanged, or every device
    screenshot would 404 on a cosmetic difference.
    """
    for name in ("cli_HQ_Switch.png", "before.png", "link_0_canvas_before.png"):
        _write(shots, name)
        assert pt._shot_name(name) == name
        assert pt._shot_name(pt._shot_name(name)) == name
        assert pt.read_shot(name)["name"] == name

    # An unsafe request is normalized deterministically (same rule the writer
    # uses) rather than rejected or allowed to reach the filesystem raw.
    assert pt._shot_name("cli: HQ Switch.png") == "cli__HQ_Switch.png"


def test_missing_empty_and_oversized_files_yield_nothing(shots):
    assert pt.read_shot("never_existed.png") == {}
    _write(shots, "empty.png", b"")
    assert pt.read_shot("empty.png") == {}
    _write(shots, "huge.png")
    assert pt.read_shot("huge.png", limit_bytes=4) == {}


def test_non_png_requests_are_refused(shots):
    _write(shots, "secret.txt", b"nope")
    assert pt._shot_name("secret.txt") == ""
    assert pt.read_shot("secret.txt") == {}
    assert pt.read_shot("") == {}
    assert pt.read_shot("   ") == {}


def test_path_traversal_cannot_escape_the_sidecar_dir(shots, tmp_path):
    outside = tmp_path / "outside.png"
    outside.write_bytes(PNG)
    for attack in ("../outside.png", r"..\outside.png",
                   "../../windows/system32/ok.png",
                   "shots/../../outside.png"):
        assert pt.read_shot(attack) == {}, attack


def test_a_read_never_writes_to_the_evidence_folder(shots):
    _write(shots, "before.png")
    before = sorted(os.listdir(shots))
    pt.read_shot("before.png")
    pt.shot_listing()
    assert sorted(os.listdir(shots)) == before


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
