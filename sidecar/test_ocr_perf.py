"""Offline gates for the sidecar's OCR cost work.

These are the tests that make "fewer Tesseract spawns, same text" a fact
rather than a hope.  They stub the OCR boundary (screenshot + Tesseract) so
they need neither Tesseract nor Packet Tracer and still assert the exact
behaviour the speed work depends on:

* an identical crop is OCR'd once, not once per read
* a *changed* crop is always read again (the fresh-read-after-typing contract)
* the psm 6 -> psm 11 fallback still runs when the primary read is empty
* the focus fast path never skips a focus call it actually needed
* the exact-content cache cannot grow without bound
* the per-read cost counters move when reads happen

The golden-text comparison against real screenshots lives in
ocr_baseline.py and is skipped here when no baseline or no Tesseract is
present, so this suite stays green on a machine that cannot OCR.
"""
from __future__ import annotations

import contextlib
import json
import os
import types

import pytest

import pt_autopilot as pt

pytestmark = pytest.mark.skipif(
    not pt.HAS_RPA, reason="pyautogui/PIL are required for OCR tests")


class _Rect:
    handle = "fake-window"

    def __init__(self, width=200, height=120):
        self.left, self.top = 0, 0
        self.right, self.bottom = width, height


class _Win:
    """Minimal device window double."""

    def __init__(self, width=200, height=120, handle=4242):
        self._rect = _Rect(width, height)
        self.element_info = types.SimpleNamespace(handle=handle)
        self.focus_calls = 0

    def rectangle(self):
        return self._rect

    def set_focus(self):
        self.focus_calls += 1


def _image(width=200, height=120, value=255):
    from PIL import Image

    return Image.new("L", (width, height), value)


@contextlib.contextmanager
def _boundary(images=None, script=None, shots_dir=None):
    """Replace the screenshot source and Tesseract, restoring everything.

    `images` maps a read index to the PIL image the next read should see;
    the last entry is reused once the list runs out.
    """
    from PIL import Image

    saved = {
        "TESSERACT_CMD": pt.TESSERACT_CMD,
        "SHOTS": pt.SHOTS,
        "_run_hidden": pt._run_hidden,
        "_tesseract_run": pt._tesseract_run,
        "screenshot": pt.pyautogui.screenshot,
        "_OCR_CACHE": dict(pt._OCR_CACHE),
        "_PX_CACHE": dict(pt._PX_CACHE),
        "_PX_CACHE_MAX": pt._PX_CACHE_MAX,
        "record_event": pt.record_event,
        "log": pt.log,
    }
    calls = []
    frames = list(images or [Image.new("L", (200, 120), 255)])

    def screenshot(region=None):
        index = min(len(calls), len(frames) - 1)
        return frames[index]

    def tesseract(img, psm):
        calls.append((int(psm), img.size))
        return "" if script is None else str(script(int(psm)))

    pt.TESSERACT_CMD = "tesseract-not-really"
    if shots_dir is not None:
        pt.SHOTS = str(shots_dir)
    pt.pyautogui.screenshot = screenshot
    pt._tesseract_run = tesseract
    # These tests must never write to the real failure journal.
    pt.record_event = lambda *a, **k: None
    pt.log = lambda *a, **k: None
    pt.ocr_cache_clear()
    pt.perf_reset()
    try:
        yield calls
    finally:
        pt.TESSERACT_CMD = saved["TESSERACT_CMD"]
        pt.SHOTS = saved["SHOTS"]
        pt._run_hidden = saved["_run_hidden"]
        pt._tesseract_run = saved["_tesseract_run"]
        pt.pyautogui.screenshot = saved["screenshot"]
        pt._OCR_CACHE.clear()
        pt._OCR_CACHE.update(saved["_OCR_CACHE"])
        pt._PX_CACHE.clear()
        pt._PX_CACHE.update(saved["_PX_CACHE"])
        pt._PX_CACHE_MAX = saved["_PX_CACHE_MAX"]
        pt.record_event = saved["record_event"]
        pt.log = saved["log"]


def test_identical_frame_is_ocred_once():
    """A repeated read of an unchanged screen must not spawn Tesseract."""
    with _boundary(script=lambda psm: "Router> enable\nRouter#") as calls:
        win = _Win()
        first = pt._ocr_region(win, ttl=0)
        second = pt._ocr_region(win, ttl=0)
    assert first == second == "Router> enable\nRouter#"
    assert len(calls) == 1, f"expected one spawn, saw {calls}"
    assert pt.PERF["ocr_reads"] == 2
    assert pt.PERF["ocr_px_hits"] == 1
    assert pt.PERF["ocr_spawns"] == 1


def test_ocr_cache_clear_forces_a_fresh_read():
    """ocr_cache_clear() must drop the exact-content layer too."""
    with _boundary(script=lambda psm: "Router#") as calls:
        win = _Win()
        pt._ocr_region(win, ttl=0)
        pt.ocr_cache_clear()
        text = pt._ocr_region(win, ttl=0)
    assert text == "Router#"
    assert len(calls) == 2, f"clear() must force a new spawn, saw {calls}"


def test_changed_frame_is_always_read_again():
    """The fresh-read-after-typing contract: new pixels, new OCR."""
    frames = [_image(value=255), _image(value=254)]
    with _boundary(images=frames, script=lambda psm: "Router#") as calls:
        win = _Win()
        pt._ocr_region(win, ttl=0)
        pt._ocr_region(win, ttl=0)
    assert len(calls) == 2, f"a changed frame must be re-read, saw {calls}"
    assert pt.PERF["ocr_px_hits"] == 0


def test_tight_prompt_band_read_is_cached_separately():
    """psm/polarity/band are part of the content-cache key."""
    with _boundary(script=lambda psm: f"psm{psm}") as calls:
        win = _Win()
        primary = pt._ocr_region(win, ttl=0)
        sparse = pt._ocr_region(win, 0.82, 0.94, ttl=0, psm=11)
        sparse_again = pt._ocr_region(win, 0.82, 0.94, ttl=0, psm=11)
    assert (primary, sparse, sparse_again) == ("psm6", "psm11", "psm11")
    assert [psm for psm, _ in calls] == [6, 11], calls


def test_empty_primary_read_still_falls_back_to_sparse_psm():
    """psm 6 returning nothing must still trigger the psm 11 read."""
    with _boundary(script=lambda psm: "" if psm == 6 else "Router#") as calls:
        text = pt._ocr_region(_Win(), ttl=0)
    assert text == "Router#"
    assert [psm for psm, _ in calls] == [6, 11], calls
    assert pt.PERF["ocr_psm6"] == 1 and pt.PERF["ocr_psm11"] == 1


def test_content_cache_is_bounded():
    """A long run must not accumulate unbounded cached frames."""
    frames = [_image(value=value) for value in range(250, 240, -1)]
    with _boundary(images=frames, script=lambda psm: "x") as calls:
        win = _Win()
        pt._PX_CACHE_MAX = 3
        for value in range(200, 194, -1):
            # A distinct frame each read: without eviction the cache would
            # grow once per read for the whole run.
            pt.pyautogui.screenshot = (
                lambda region=None, value=value: _image(value=value))
            pt._ocr_region(win, ttl=0)
        size = len(pt._PX_CACHE)
    assert len(calls) == 6, calls
    assert size <= 3, f"cache grew to {size}"


def test_focus_fast_path_skips_activation_for_the_focused_window():
    """When PT already owns the foreground, no UIA/Win32 focus call runs."""
    win = _Win()
    info = {
        "active_handle": 4242, "active_title": "HQ_Router",
        "active_pid": 77, "active_path": "C:/PT/PacketTracer.exe",
        "expected_handle": 4242, "expected_pid": 77,
        "expected_path": "C:/PT/PacketTracer.exe",
        "is_packet_tracer": True,
    }
    saved = (pt._foreground_window_info, pt._win32_root_handle,
             pt._activate_window_handle)
    pt._foreground_window_info = lambda expected_win=None: dict(info)
    pt._win32_root_handle = lambda hwnd: int(hwnd)
    pt._activate_window_handle = lambda *a, **k: True
    try:
        pt.perf_reset()
        assert pt._focus_pt_window(win, "R1", "CLI read") is True
    finally:
        pt._foreground_window_info, pt._win32_root_handle, \
            pt._activate_window_handle = saved
    assert win.focus_calls == 0, "fast path must not call set_focus()"
    assert pt.PERF["focus_skips"] == 1


def test_focus_fast_path_not_taken_when_another_window_is_focused():
    """A covering window must still take the full, fail-closed path."""
    win = _Win()
    info = {
        "active_handle": 999, "active_title": "Codex",
        "active_pid": 88, "active_path": "C:/Codex/codex.exe",
        "expected_handle": 4242, "expected_pid": 77,
        "expected_path": "C:/PT/PacketTracer.exe",
        "is_packet_tracer": False,
    }
    saved = (pt._foreground_window_info, pt._win32_root_handle,
             pt._activate_window_handle, pt._interruptible_sleep)
    pt._foreground_window_info = lambda expected_win=None: dict(info)
    pt._win32_root_handle = lambda hwnd: int(hwnd)
    pt._activate_window_handle = lambda *a, **k: True
    pt._interruptible_sleep = lambda seconds: True
    try:
        pt.perf_reset()
        assert pt._focus_pt_window(win, "R1", "CLI read") is False
    finally:
        pt._foreground_window_info, pt._win32_root_handle, \
            pt._activate_window_handle, pt._interruptible_sleep = saved
    assert win.focus_calls == 2, "the full path must still try to focus"
    assert pt.PERF["focus_skips"] == 0


def test_tesseract_run_goes_through_the_temp_file(tmp_path):
    """The image must reach Tesseract as a file, never as a pipe.

    Piping the PNG over stdin was implemented, measured (~1% of a read) and
    rejected: a pipe makes Tesseract emit CRLF line endings and ANSI bytes
    where a file gets LF and UTF-8, so every multi-line read changed.
    ocr_baseline.py --compare is what caught it; this pins the file path so
    the "cheaper" pipe cannot return without re-running that gate.
    """
    from PIL import Image

    saved = (pt.TESSERACT_CMD, pt._run_hidden, pt.SHOTS, pt.log)
    seen = []

    def run_hidden(command, **kwargs):
        seen.append((list(command), kwargs))
        return types.SimpleNamespace(returncode=0, stdout="from-file")

    pt.TESSERACT_CMD = "tesseract-not-really"
    pt.SHOTS = str(tmp_path)
    pt._run_hidden = run_hidden
    pt.log = lambda *a, **k: None
    try:
        pt.perf_reset()
        text = pt._tesseract_run(Image.new("L", (40, 20), 255), 6)
    finally:
        pt.TESSERACT_CMD, pt._run_hidden, pt.SHOTS, pt.log = saved
    assert text == "from-file"
    assert len(seen) == 1, seen
    assert seen[0][0][1].endswith("_ocr_tmp.png"), seen[0][0]
    assert seen[0][0][-1] == "6", seen[0][0]
    assert seen[0][1].get("text") is True, seen[0][1]
    assert os.path.isfile(os.path.join(str(tmp_path), "_ocr_tmp.png"))


def test_perf_counters_report_reads_and_sleeps():
    """The run summary must be able to show where the time went."""
    with _boundary(script=lambda psm: "Router#") as calls:
        pt._run_reset()
        assert pt.RUN["perf"] is pt.PERF, "perf must be served on /run_summary"
        assert pt.PERF["ocr_reads"] == 0, "_run_reset must zero the counters"
        pt._ocr_region(_Win(), ttl=0)
        pt._interruptible_sleep(0.05)
        line = pt.perf_summary_line()
    assert len(calls) == 1
    assert "reads=1" in line and "tesseract=1" in line and "reads/line" in line
    assert pt.PERF["sleep_ms"] >= 40.0, pt.PERF


def test_baseline_harness_reads_real_screenshots():
    """The gate tool itself must work before anyone trusts its verdict.

    Runs the recorder's sweep with a stubbed Tesseract over the real
    captures: it pins the crop geometry (the width cap reduces the upscale
    on a 1920x1080 window), the three reads per image, and the record shape
    that --compare and --record share.
    """
    import ocr_baseline

    images = ocr_baseline._images()
    if not images:
        pytest.skip("no captures in shots/ to sweep")
    sizes = []

    def tesseract(img, psm):
        sizes.append((int(psm), img.size))
        return "cli-text" if int(psm) == 6 else "sparse-text"

    saved = (pt.TESSERACT_CMD, pt._tesseract_run, pt.pyautogui.screenshot)
    pt.TESSERACT_CMD = "tesseract-not-really"
    pt._tesseract_run = tesseract
    try:
        ocr_baseline._install_stubs()
        sweep = ocr_baseline._sweep("current")
    finally:
        pt.TESSERACT_CMD, pt._tesseract_run, pt.pyautogui.screenshot = saved

    assert len(sweep["images"]) == len(images)
    assert len(sizes) == 3 * len(images), f"{len(sizes)} reads"
    first = os.path.basename(images[0])
    assert first.startswith("cli_"), first
    # 1920x1080 window: crop 1766x583, 3x would be 5298 wide, so the cap
    # pulls the upscale down to 2x.  The harness must crop the same way the
    # live read does, or its verdict would not transfer.
    assert sizes[0][1] == (3532, 1166), sizes[0]
    entry = sweep["images"][first]
    assert entry["cli"]["text"] == "cli-text"
    assert entry["prompt11"]["text"] == "sparse-text"
    assert all(read["ms"] >= 0 for read in entry.values())
    assert sweep["settings"]["upscale"] == pt.OCR_UPSCALE


def test_golden_ocr_text_matches_recorded_baseline():
    """Gate on the recorded text from the real screenshots, when present."""
    baseline = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "ocr_golden.json")
    if not pt.TESSERACT_CMD:
        pytest.skip("Tesseract not installed")
    if not os.path.isfile(baseline):
        pytest.skip("no ocr_golden.json - run: python ocr_baseline.py --record")
    import ocr_baseline

    with open(baseline, encoding="utf-8") as stream:
        recorded = json.load(stream)
    # The sweep must run against the on-disk captures, never the live screen.
    original_screenshot = pt.pyautogui.screenshot
    try:
        ocr_baseline._install_stubs()
        sweep = ocr_baseline._sweep("current")
    finally:
        pt.pyautogui.screenshot = original_screenshot
    diffs = []
    for image, reads in sweep["images"].items():
        want = recorded["images"].get(image) or {}
        for name, observed in reads.items():
            expected = (want.get(name) or {}).get("text")
            if expected is not None and expected != observed["text"]:
                diffs.append(f"{image}[{name}]")
    assert not diffs, f"OCR text changed for: {', '.join(diffs)}"


def test_images_can_be_narrowed_to_one_capture():
    """`--only` picks named captures and refuses a name it cannot find."""
    import ocr_baseline

    available = ocr_baseline._images()
    if not available:
        pytest.skip("no captures in shots/ to sweep")
    one = os.path.basename(available[0])
    assert ocr_baseline._images([one]) == [available[0]]
    assert ocr_baseline._images([one.upper()]) == [available[0]], \
        "a capture name is matched case-insensitively"
    with pytest.raises(SystemExit) as excinfo:
        ocr_baseline._images(["definitely-not-here.png"])
    message = str(excinfo.value)
    assert "definitely-not-here.png" in message
    assert one in message, \
        "the error has to list what could have been swept instead"


def test_record_only_refreshes_one_capture_and_keeps_the_rest(tmp_path,
                                                              monkeypatch):
    """A live run overwrote a capture: only that image may be re-recorded.

    shots/before.png, after.png and link0_after.png are written by runs, so
    a build can replace the pixels behind a recorded entry.  Refreshing that
    one entry must not double as "re-record everything", which would accept
    genuine pipeline drift on the 16 captures nobody looked at.
    """
    import ocr_baseline

    golden = tmp_path / "ocr_golden.json"
    golden.write_text(json.dumps({
        "schema": 1,
        "recorded": "2026-09-16 22:11:22",
        "sidecarVersion": "2026-09-15-f",
        "settings": {"upscale": 3},
        "meanMs": 333.8,
        "images": {
            "before.png": {"cli": {"text": "OLD before", "ms": 1.0}},
            "after.png": {"cli": {"text": "KEEP this", "ms": 2.0}},
        },
    }), encoding="utf-8")
    monkeypatch.setattr(ocr_baseline, "BASELINE", str(golden))
    monkeypatch.setattr(
        ocr_baseline, "_sweep",
        lambda variant, only=None: {
            "settings": {"upscale": 3},
            "images": {"before.png": {"cli": {"text": "NEW before",
                                                "ms": 3.0}}},
        })

    assert ocr_baseline._record(["before.png"]) == 0

    merged = json.loads(golden.read_text(encoding="utf-8"))
    assert merged["images"]["before.png"]["cli"]["text"] == "NEW before"
    assert merged["images"]["after.png"]["cli"]["text"] == "KEEP this", \
        "an image that was not named must keep its recorded text"
    assert merged["recorded"] == "2026-09-16 22:11:22", \
        "a partial refresh does not re-stamp the whole baseline"
    assert merged["settings"] == {"upscale": 3}
    assert list(merged["refreshed"]) == ["before.png"], merged["refreshed"]
