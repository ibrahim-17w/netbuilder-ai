# Sidecar build-run performance - 2026-09-16

Goal: make a Packet Tracer build run finish faster **without changing behaviour**. Scope was the
sidecar CLI engine (the dominant cost); the Flutter UI/polling work is deferred (see "Still open").

## Verification (all run from `app/sidecar` unless noted)

```
python -m pytest -q              -> 122 passed        (109 before this change; +13 new gates)
python ocr_baseline.py --compare -> text diffs=0      (51 real reads, new build vs pre-change build)
flutter analyze  (from app/)     -> No issues found!
```

The `--compare` result is the important one: the baseline was recorded with the **pre-change**
`pt_autopilot.py` (backup: `backups/NetBuilderAI-before-perf-ocr-cache-20260916/`) and the new
build reproduces every character of extracted text on all 17 captures in `shots/` (3 reads each:
full-window psm 6, prompt-band psm 6, prompt-band psm 11).

## The measurement that redirected the work

| variant | mean read | spawn/read | vs current |
|---|---|---|---|
| current (upscale 3, LANCZOS, psm 6 -> 11) | 342.2 ms | 1.06 | - |
| upscale 2 + BICUBIC | 319.7 ms | 1.04 | 1.07x |
| upscale 2 + BICUBIC, no psm-11 fallback | 314.0 ms | 1.00 | 1.09x |
| no psm-11 fallback | 323.2 ms | 1.00 | 1.06x |
| tighter read band (0.62-0.94) | 294.3 ms | 1.08 | 1.16x |
| tighter band + upscale 2 + BICUBIC | 273.4 ms | 1.04 | 1.25x |

Halving Tesseract's input area buys ~5%: a terminal read is **~90% process start**, not pixels. The
psm-11 fallback fires on ~6% of reads here, so it is not the cost driver either. The lever that
matters is therefore the *number of reads/spawns per config line*, not the size of each crop - the
CLI loop issues 3+ terminal reads per line (`_confirmed_state`, the post-typing error count, the
pager probe, then a deliberate fresh read after `_OCR_CACHE.clear()`).

**No OCR default was changed.** Every candidate either changes text or is not worth the risk:

* `--compare --variant=fast` (upscale 3 -> 2, LANCZOS -> BICUBIC): **46 of 51 reads changed text**
  for a 5% gain. The 3x LANCZOS upscale really is load-bearing; the golden gate refuses it.
* `--variant=tight-band` / `fast-tight-band`: faster, but they read a smaller window, so error rows
  that scroll above the band can be missed by `_term_error_signature`. Not gated at all - do not use.

## What changed (`sidecar/pt_autopilot.py`, `VERSION = 2026-09-16-perf`)

| # | Change | Why it is safe |
|---|---|---|
| P0 | **Perf counters** (`PERF`) for reads / TTL hits / unchanged-frame hits / Tesseract spawns & psm split / ocr_ms / uia_ms / focus_ms+skips / typing_ms / sleep_ms; served on `/run_summary.perf` and printed as one `PERF ...` log line at run end | counting only |
| P1 | **Exact-content OCR cache** (`_PX_CACHE`): a repeat read of byte-identical pixels returns the stored text without a spawn | Tesseract is deterministic for identical input, so the same pixels can only produce the same text. Keyed on pixels + psm + polarity + band; bounded (96, FIFO); `clear()` sites still clear the TTL layer, `ocr_cache_clear()` clears both |
| P2 | **Focus fast path**: when the foreground window is already this window (or its root), skip `set_focus()` + two `SetForegroundWindow` calls | reads the same evidence the slow path ends on, and only when the focus call could not have moved anything; a covering window / sibling PT window still takes the full fail-closed path. The pre-read doubles as attempt 0's result, so foreground reads and focus attempts are unchanged in number |
| P3 | **Cheaper evidence PNGs**: `shot()` / `_shot_region()` / the OCR temp file save with `compress_level=1` | PNG is lossless - only encode time changes, never a decoded pixel (verified by `--compare`) |
| P4 | **`_ocr_region` tuning knobs** (`OCR_UPSCALE`, `OCR_RESAMPLE`, `OCR_PSM_PRIMARY/FALLBACK`, `OCR_MAX_PIXELS_WIDE`), pinned at today's values | defaults are byte-for-byte today's behaviour; they exist so the gate can measure alternatives |

Supporting files:

* `sidecar/ocr_baseline.py` - the golden gate. `--record` (write `ocr_golden.json` from the real
  captures), `--compare [--variant=X]` (**exit 1 on any text diff**), `--time` (ms + spawns/read for
  every variant), `--list`, `--shots DIR`. Recording with an *older* build and comparing with the
  new one is what proves a refactor changed nothing.
* `sidecar/ocr_golden.json` - recorded text of the 17 captures under the current defaults. Contains
  OCR'd device names/addresses from the dev screenshots (no credentials). Re-record only when the
  pipeline's intended output legitimately changes.
* `sidecar/test_ocr_perf.py` - 12 gates, no Tesseract needed: identical frame read once, `clear()`
  forces a re-read, changed frame always re-read, psm/band keying, psm 6 -> 11 fallback preserved,
  cache bounded, focus fast path taken/not taken, temp-file read path, counters wired to
  `_run_reset`, harness geometry, and the golden comparison itself.
* `sidecar/test_autopilot_safety.py` - `check_ocr_upscale_and_fallback` now stubs `_tesseract_run`
  instead of `_run_hidden`, so it runs with no Tesseract, and it is collected by pytest
  (`test_ocr_read_strategy_upscales_and_falls_back`) - it was previously only reachable by running
  the file directly, which is how a pinned contract rots.

## Rejected on evidence

* **Piping the PNG to Tesseract over stdin** (to skip the temp encode/write/decode). Implemented,
  then caught by `--compare`: Tesseract writing to a **pipe** emits CRLF line endings and
  ANSI-encoded bytes, while a file gets LF + UTF-8. 48 of 54 reads changed text (`\r` on every
  terminal line, mojibake where the CLI had punctuation) for ~1% of a read. Removed; the temp file
  path is now pinned by `test_tesseract_run_goes_through_the_temp_file`.
* **`--oem 0` (legacy engine)**: looked 4x faster on a crop that turned out to contain no text - it
  recognized *nothing* (0 chars vs 226). `--oem 1` was text-identical but only ~3% faster.

## Confirming it live (one run)

Nothing here was verified against a live Packet Tracer session. After a build:

1. Look at `/run_summary` (or the run log's final `PERF ...` line). Expected shape:
   `reads` > `tesseract` when the screen repeats, and `unchanged=` showing how many reads the
   content cache served. `focus_skips` should be most of `focus_calls` once a device window is
   focused.
2. Compare with the same build's previous run. The win comes from `tesseract` being lower than
   `reads`; if `unchanged=` stays at 0, Packet Tracer is repainting (blinking cursor) between reads
   and the cache is not earning its keep - that is the number to judge it by.
3. Check the run's outcomes match: `validation`, `devices_done`, `pings_ok`, `srv_*`.

## Still open

* **No live run was performed** by this change.
* **Deferred (UI side, untouched):** the single-threaded `HTTPServer` shared with the UI's 2s
  `/status` poll; full-file `json.loads` of `failures.jsonl` / `experience_memory.jsonl` on every
  `/stats`, `/suggest`, `/events`, `/learning` call (`journal_suggestions` parses the journal twice);
  the Memory screen's 5 sequential requests every 3s, each with a fresh `http.Client`; and
  `Process.runSync('where.exe')` on the UI isolate during startup.
* **Pre-existing, not caused by this change:** `python test_autopilot_safety.py` (direct run) fails
  at `check_cli_and_interface_guard` line 277 on a stale crypto-queue `required` expectation. The
  same failure reproduces against the pre-change backup. It is out of scope here, and should be
  reviewed rather than re-pinned - the assertion may be describing the intended behaviour.
* Also pre-existing: `RUN["action_results"]`/`node_outcomes`/`link_results` are mutated by the worker
  without `LOCK` while `/run_summary` serialises them, so an unlucky poll can raise. Left alone
  (unrelated to speed); the new `PERF` counters are lock-protected precisely to avoid adding a
  second instance of that bug.
