"""Golden-text harness for the sidecar's Tesseract terminal reads.

Why this exists: the OCR path dominates the wall-clock cost of a build run
(every read screenshots the device pane, upscales it and spawns Tesseract -
twice when the psm 6 pass reads nothing).  The cheap levers - upscale factor,
psm strategy, read band, resampling filter - all trade accuracy for speed, so
none of them may be shipped on "looks fine".  This tool records the text the
CURRENT pipeline extracts from the real captures in ``shots/``, then re-runs a
candidate against that record and reports every difference.

Workflow (from ``app/sidecar``, with Tesseract installed):

    python ocr_baseline.py --record                  # write ocr_golden.json
    python ocr_baseline.py --record --only before.png  # refresh ONE capture
    python ocr_baseline.py --compare                 # current defaults
    python ocr_baseline.py --compare --variant fast   # gate a candidate
    python ocr_baseline.py --time                     # ms for all variants

``--compare`` exits non-zero on any text difference, so it can gate a change.
Only flip a default in ``pt_autopilot.py`` (OCR_UPSCALE, OCR_RESAMPLE,
OCR_PSM_FALLBACK, the read band) after ``--compare`` reports zero diffs for
the variant AND ``--time`` shows the expected saving.

A DIFF has two possible causes and only one of them is a code change.  The
other is the capture: shots/before.png, after.png and link0_after.png are
written by live runs, so pixels can be replaced between ``--record`` and a
``--compare``.  ``--only`` is how the second cause is handled - refresh the
named captures alone and leave every other recorded text in place -
whereas a pipeline change is a whole-file ``--record``.

The images are real Packet Tracer captures; each one is treated as the device
window itself, so a fractional band reads the same fraction of the window a
live read would.  Nothing here drives Packet Tracer: it is pure offline OCR
over pixels that are already on disk.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
import time

import pt_autopilot as pt

BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "ocr_golden.json")
CLI_READ = {"fy0": 0.40, "fy1": 0.94, "psm": 6}
PROMPT_P6 = {"fy0": 0.82, "fy1": 0.94, "psm": 6}
PROMPT_P11 = {"fy0": 0.82, "fy1": 0.94, "psm": 11}
READS = (("cli", CLI_READ), ("prompt6", PROMPT_P6), ("prompt11", PROMPT_P11))

# Candidate tunings.  `band` replaces the default read band, `cli_psm`
# replaces the psm of the full-window read only.  Everything else is a module
# constant in pt_autopilot.
VARIANTS: dict = {
    "current": {},
    "fast": {"OCR_UPSCALE": 2, "OCR_RESAMPLE": "BICUBIC"},
    "fast-sparse": {"OCR_UPSCALE": 2, "OCR_RESAMPLE": "BICUBIC",
                    "OCR_PSM_FALLBACK": None},
    "sparse-only": {"OCR_PSM_FALLBACK": None},
    "fast-lanczos": {"OCR_UPSCALE": 2, "OCR_RESAMPLE": "LANCZOS"},
    "tight-band": {"band": (0.62, 0.94)},
    "fast-tight-band": {"OCR_UPSCALE": 2, "OCR_RESAMPLE": "BICUBIC",
                        "band": (0.62, 0.94)},
}
# Variants offered by --compare/--time when none is named.
CANDIDATES = ("fast", "fast-sparse", "sparse-only", "fast-lanczos",
              "tight-band", "fast-tight-band")


class _Rect:
    def __init__(self, width: int, height: int, handle: str):
        self.left, self.top = 0, 0
        self.right, self.bottom = int(width), int(height)
        self.handle = handle


class _GoldenWindow:
    """A device window backed by one on-disk screenshot."""

    def __init__(self, path: str):
        from PIL import Image

        self.path = path
        self.name = os.path.basename(path)
        self.image = Image.open(path)
        self.handle = f"golden:{self.name}"

    def rectangle(self):
        return _Rect(self.image.width, self.image.height, self.handle)


class _ScreenshotSource:
    """Serve crops of the current golden window to pyautogui.screenshot."""

    window: _GoldenWindow | None = None

    @classmethod
    def grab(cls, region=None):
        image = cls.window.image
        if region is None:
            return image.copy()
        left, top, width, height = (int(v) for v in region)
        return image.crop((left, top, left + width, top + height))


def _images(only=None) -> list:
    """The real captures to sweep, optionally narrowed to named ones.

    shots/_ocr_tmp.png and shots/_reuse_ocr.png are deliberately NOT inputs:
    they are written by the pipeline itself, so sweeping them would mean
    comparing against a file the sweep keeps overwriting - a self-referential
    baseline that can mask a change instead of catching it.

    `only` selects captures by file name (case-insensitive), so one capture
    can be looked at - or re-recorded - on its own.  A name that matches
    nothing is an error, never an empty sweep: silently sweeping nothing
    would look like a pass.
    """
    names = sorted(glob.glob(os.path.join(pt.SHOTS, "cli_*.png")))
    names += [os.path.join(pt.SHOTS, name) for name in (
        "_text.png", "_srv.png", "_labels.png", "PC1_panel.png",
        "diag_region.png", "before.png", "after.png", "link0_after.png",
    )]
    found = [p for p in names if os.path.isfile(p)]
    if not only:
        return found
    wanted = [str(x).strip().lower() for x in only if str(x).strip()]
    picked = [p for p in found
              if os.path.basename(p).lower() in wanted]
    missing = [n for n in wanted
               if n not in {os.path.basename(p).lower() for p in found}]
    if missing:
        raise SystemExit(f"no capture named {', '.join(missing)} in "
                         f"{pt.SHOTS}; available: "
                         f"{', '.join(sorted(os.path.basename(p) for p in found))}")
    return picked


def _apply_variant(variant: str) -> tuple:
    """Set the module knobs for a variant; return (band, cli_psm, names)."""
    if variant not in VARIANTS:
        raise SystemExit(f"unknown variant {variant!r}; "
                         f"known: {', '.join(sorted(VARIANTS))}")
    spec = VARIANTS[variant]
    pt.OCR_UPSCALE = int(spec.get("OCR_UPSCALE", 3))
    pt.OCR_RESAMPLE = str(spec.get("OCR_RESAMPLE", "LANCZOS"))
    pt.OCR_PSM_FALLBACK = spec.get("OCR_PSM_FALLBACK", 11)
    return spec.get("band"), spec.get("cli_psm"), {
        "upscale": pt.OCR_UPSCALE,
        "resample": pt.OCR_RESAMPLE,
        "psmFallback": pt.OCR_PSM_FALLBACK,
        "band": list(spec.get("band", (0.40, 0.94))),
        "cliPsm": spec.get("cli_psm", 6),
    }


def _read(window: _GoldenWindow, name: str, spec: dict, band, cli_psm):
    """One timed read.  Caches are cleared so every read really spawns."""
    kwargs = dict(spec)
    if name == "cli" and cli_psm:
        kwargs["psm"] = int(cli_psm)
    if band and name == "cli":
        kwargs["fy0"], kwargs["fy1"] = band
    _clear_caches()
    start = time.time()
    text = pt._ocr_region(window, ttl=0, **kwargs)
    return text, (time.time() - start) * 1000.0


def _clear_caches() -> None:
    """Drop the OCR caches on an old build and a new one alike.

    Being able to sweep an older pt_autopilot.py is the point: recording
    with the pre-change build and comparing with the new one is what proves
    a refactor did not change a single character of extracted text.
    """
    clear = getattr(pt, "ocr_cache_clear", None)
    if callable(clear):
        clear()
    else:
        pt._OCR_CACHE.clear()


def _sweep(variant: str, only=None) -> dict:
    band, cli_psm, settings = _apply_variant(variant)
    pt.perf_reset()
    out = {}
    for path in _images(only):
        window = _GoldenWindow(path)
        _ScreenshotSource.window = window
        entry = {}
        for name, spec in READS:
            text, ms = _read(window, name, spec, band, cli_psm)
            entry[name] = {"text": text, "ms": round(ms, 1)}
        out[window.name] = entry
    return {"settings": settings, "images": out,
            "spawns": pt.PERF.get("ocr_spawns", 0),
            "reads": pt.PERF.get("ocr_reads", 0),
            "ocrMs": pt.PERF.get("ocr_ms", 0.0)}


def _mean_ms(sweep: dict) -> float:
    values = [read["ms"] for entry in sweep["images"].values()
              for read in entry.values()]
    return round(statistics.mean(values), 1) if values else 0.0


def _install_stubs() -> None:
    """Point the pipeline's screenshot at the on-disk images.

    Only the screenshot source is replaced; Tesseract itself runs exactly
    as it does live, so the recorded text is the real pipeline's text.
    """
    if not pt.TESSERACT_CMD:
        raise SystemExit(
            "Tesseract not found. Set TESSERACT_CMD to tesseract.exe or "
            "install it at the standard path, then re-run.")
    pt.pyautogui.screenshot = _ScreenshotSource.grab


def _load_baseline() -> dict:
    if not os.path.isfile(BASELINE):
        raise SystemExit(
            f"no baseline at {BASELINE}.  Record one first (on the machine "
            "that will run the builds):\n    python ocr_baseline.py --record")
    with open(BASELINE, encoding="utf-8") as stream:
        return json.load(stream)


def _write_baseline(payload: dict) -> None:
    with open(BASELINE, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=1, sort_keys=True)
        stream.write("\n")


def _diff_lines(expected: str, actual: str, limit: int = 6) -> list:
    import difflib

    diff = list(difflib.unified_diff(
        expected.splitlines(), actual.splitlines(),
        fromfile="baseline", tofile="candidate", lineterm=""))
    return diff[:limit]


def _compare(variant: str, only=None) -> int:
    baseline = _load_baseline()
    sweep = _sweep(variant, only=only)
    diffs = 0
    checked = 0
    for image, reads in sorted(sweep["images"].items()):
        recorded = baseline["images"].get(image)
        if recorded is None:
            continue
        for name, observed in reads.items():
            want = (recorded.get(name) or {}).get("text")
            if want is None:
                continue
            checked += 1
            if want == observed["text"]:
                continue
            diffs += 1
            print(f"DIFF {image} [{name}]")
            for line in _diff_lines(want, observed["text"]):
                print(f"     {line}")
    base_ms = _mean_ms(baseline)
    cand_ms = _mean_ms(sweep)
    print(f"\nvariant={variant} settings={sweep['settings']}"
          + (f" images={','.join(sorted(sweep['images']))}" if only else ""))
    print(f"reads compared={checked} text diffs={diffs}")
    print(f"mean read: baseline={base_ms}ms candidate={cand_ms}ms "
          f"({_speedup(base_ms, cand_ms)})")
    if diffs:
        print("\nFAIL - a faster read must return the same text.  Do not "
              "change the default for this variant.")
        return 1
    print("\nOK - text identical on every recorded image.")
    return 0


def _speedup(base_ms: float, cand_ms: float) -> str:
    if not cand_ms or not base_ms:
        return "n/a"
    if abs(base_ms - cand_ms) < 1.0:
        return "about the same"
    if cand_ms < base_ms:
        return f"{base_ms / cand_ms:.2f}x faster"
    return f"{cand_ms / base_ms:.2f}x slower"


def _time_all() -> int:
    base_ms = None
    if os.path.isfile(BASELINE):
        with open(BASELINE, encoding="utf-8") as stream:
            base_ms = _mean_ms(json.load(stream))
    rows = []
    for variant in ("current",) + CANDIDATES:
        sweep = _sweep(variant)
        spawns = sweep["spawns"] / max(1, sweep["reads"])
        rows.append((variant, _mean_ms(sweep), spawns))
    print(f"{'variant':<18}{'mean ms':>9}{'spawn/read':>12}   vs current")
    current = rows[0][1]
    for name, ms, spawns in rows:
        note = ""
        if base_ms:
            note = f"  (recorded baseline {base_ms}ms)"
        print(f"{name:<18}{ms:>9.1f}{spawns:>12.2f}   "
              f"{_speedup(current, ms)}{note}")
    print("\nspawn/read is what a read actually costs: a Tesseract process "
          "start dominates the crop it reads.")
    return 0


def _record(only=None) -> int:
    """Record the current pipeline's text as the baseline.

    A whole-file ``--record`` re-records every capture and re-stamps the
    run metadata; it is the only correct move when the PIPELINE's intended
    output changes, because accepting new text everywhere is what it does.

    ``--record --only before.png`` exists for the other cause of drift: the
    capture itself was overwritten.  shots/before.png, after.png and
    link0_after.png are written by live runs, so a build between two
    ``--record`` calls can replace the pixels whose text was recorded, and
    the gate then reports a difference that the pipeline did not cause
    (2026-09-17: a 22:58 live run rewrote before.png, and the next pytest
    showed three diffs on that image while the other 48 reads matched).
    Re-recording one capture must not wave through drift on the others, so
    the merge replaces only the named images' reads, keeps every other
    entry byte-for-byte, and stamps what it refreshed.
    """
    if not only:
        sweep = _sweep("current")
        payload = {
            "schema": 1,
            "recorded": time.strftime("%Y-%m-%d %H:%M:%S"),
            "sidecarVersion": pt.VERSION,
            "note": ("Text the pipeline extracted from the real captures in "
                     "shots/ with the DEFAULT settings.  Regenerate only when "
                     "the pipeline's intended output legitimately changes."),
            "settings": sweep["settings"],
            "meanMs": _mean_ms(sweep),
            "images": sweep["images"],
        }
        _write_baseline(payload)
        print(f"recorded {len(payload['images'])} image(s) -> {BASELINE}")
        print(f"mean read: {payload['meanMs']}ms "
              f"settings={payload['settings']}")
        return 0

    sweep = _sweep("current", only=only)
    payload = _load_baseline()
    images = payload.setdefault("images", {})
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    refreshed = payload.setdefault("refreshed", {})
    for name, reads in sorted(sweep["images"].items()):
        known = name in images
        images[name] = reads
        refreshed[name] = stamp
        print(f"re-recorded {name} "
              f"({'refreshed capture' if known else 'new capture'})")
    payload["meanMs"] = _mean_ms(payload)
    _write_baseline(payload)
    print(f"refreshed {len(sweep['images'])} of {len(images)} image(s) "
          f"-> {BASELINE}")
    print("every other capture kept its recorded text - a full "
          "--record is still what a pipeline change needs")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--record", action="store_true",
                        help="record the current pipeline as the baseline")
    parser.add_argument("--compare", action="store_true",
                        help="compare a variant against the recorded baseline")
    parser.add_argument("--time", action="store_true",
                        help="report mean read ms for every variant")
    parser.add_argument("--variant", default="current",
                        help="variant name (see --list)")
    parser.add_argument("--list", action="store_true",
                        help="list variants")
    parser.add_argument("--shots", default="",
                        help="directory holding the captures to sweep "
                             "(default: the build's own shots/)")
    parser.add_argument("--only", default="",
                        help="comma-separated capture file names to sweep "
                             "(default: all of them).  With --record this "
                             "re-records just those captures, leaving every "
                             "other recorded text untouched")
    args = parser.parse_args(argv)
    if args.shots:
        pt.SHOTS = os.path.abspath(args.shots)

    if args.list:
        for name in ("current",) + CANDIDATES:
            print(f"{name:<18}{VARIANTS[name]}")
        return 0

    only = [name for name in (args.only or "").split(",") if name.strip()]
    _install_stubs()
    if args.record:
        return _record(only)
    if args.time:
        return _time_all()
    return _compare(args.variant, only)


if __name__ == "__main__":
    sys.exit(main())
