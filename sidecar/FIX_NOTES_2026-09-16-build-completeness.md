# 2026-09-16 — Why builds came out incomplete, and what the run leaves behind

Two changes, both aimed at the same question: *did the build I asked for actually
happen, and what proves it?* Neither adds cost to a healthy run.

Evidence base: `failures.jsonl` (1477 events) aggregated by kind and recovery
status. The ranking is what drove the order of work.

| kind | count | unrecovered |
|---|---|---|
| `cli_context_blocked` | 592 | **592** |
| `phase_state` | 241 | 170 |
| `setup_dialog` | 55 | 25 |
| `cli_line_error` | 42 | 20 |
| `unsupported_by_packet_tracer` | 24 | 24 |
| `srv_service` | 23 | 18 |
| `srv_field_missing` | 18 | 18 |
| `ping_test` | 21 | 16 |

The single biggest cause of a partial network was that the engine **refused to
type** a command 592 times, and every one of those refusals was unrecoverable.
It was not a clicking problem and not a placement problem. Note that
`cli_mode_repaired` succeeded 45 times, so the repair machinery worked; it was
the *proof* step that starved.

---

## 1. CLI mode proof: record why, then take one more look

### What changed

**Every block now carries its evidence.** The old event recorded only the
command text, which is why 592 blocks could not be diagnosed. Each block now
records `reason`, `required`, `line`, and a `why` string with the state, the
parsed mode, the character count and the tail of what OCR actually read:

```
cli_context_blocked  reason=prompt_not_proven   why=state=unknown mode=unknown chars=0 tail=''
cli_context_blocked  reason=mode_unreadable     required=config  why=state=cli mode=unknown chars=214 tail='...Switch#'
```

Two distinct reasons, because the fixes are different: nothing readable at all
(the band is wrong, the window is covered, the CLI tab is closed) versus a live
terminal whose mode glyph could not be parsed (a repaint race or a bad crop).

**One extra look before a line is dropped, and it never types.** When the read
cannot prove a terminal, the engine settles 0.4 s and reads once more with a
cleared cache. `_reread_prompt_once` deliberately sends **no keystrokes**: a
bare Enter is harmless at an IOS prompt but is an *answer* in front of the
initial-configuration / autoinstall dialog, and a failed read cannot prove
which frame it is looking at. The boot-dialog paths already own the keystrokes
they need.

**The extra look can only ever upgrade the evidence.** It replaces the first
read solely when it proves strictly more (a live CLI *with* a readable mode).
So a stale-but-usable first read is never downgraded by a worse second one, and
every downstream decision — the staleness latches included — still sees the
best available evidence. A setup dialog showing up in the second read is not
accepted and nothing is typed at it.

### Why this does not cost a normal run anything

- **The healthy path takes exactly the reads it took before: one.** Pinned by
  a test that counts the calls.
- The extra look fires only on the path that was about to be blocked, i.e.
  only where the alternative was silently dropping a config line.
- **It is capped per device.** A terminal that is genuinely unavailable
  (powered off, no CLI tab, wrong window) fails every one of its commands, so
  without a cap the look would run for each one and add its settle delay to a
  run that was already going to drop those lines. After
  `_CLI_PROOF_MAX_MISSES = 3` consecutive unproven reads for one device the
  look is abandoned, and any usable prompt clears the debt. Bounded cost: about
  1.2 s per dead device per run, independent of line count.

The payoff depends on how many of the 592 were repaints rather than dead
terminals. `cli_prompt_recovered` is the number that answers that;
`cli_prompt_reread_capped` tells you the opposite — how often the cap was the
thing standing between you and a slower run.

### New counters (all on `/run_summary`, printed in the run log)

| key | meaning |
|---|---|
| `cli_block_reasons` | blocked lines by reason, so you can see which evidence was missing |
| `cli_prompt_rereads` | extra looks actually taken |
| `cli_prompt_recovered` | lines rescued by one |
| `cli_prompt_reread_capped` | extra looks skipped because the device already burned its three |

The run log prints `CLI PROOF: lines saved by the settled re-read=N blocked: ...`
and the builder screen shows the same line.

---

## 2. The run now leaves a `.pkt`, its manifest, and a comparison

A topology that only exists on the canvas is not a deliverable. The pieces
already existed (`_pkt_save_as` drives Ctrl+Shift+S correctly, `_pkt_info`
hashes the result, `_pkt_write_manifest` writes companion data) but **nothing
ever joined them** — no build called Save As, and success only proved "a
non-empty file appeared".

`pkt_save_verified(project, out_dir, force, reopen)` is that join:

1. Generate a unique `<project>-<timestamp>.pkt` under `NETBUILDER_PKT_DIR`
   (default `pkt_output/`) — never silently overwriting; `force` keeps a
   backup first, and same-second saves get a suffix instead of clobbering.
2. Save through Packet Tracer's own Save As. The format is proprietary and PT
   is its only reliable writer, so the binary is never rewritten here.
3. Write the companion manifest: project, sidecar version, the plan, and the
   planned-vs-recorded comparison.
4. Optionally reopen to prove PT can load the file (off by default so the
   auto-save stays fast).

`_pkt_plan_vs_run` is the comparison the user actually cares about: planned
devices and links against what the run recorded — `devicesMissing`,
`linksFailed`, `configsVerified`, `pingsOk`/`pingsFailed`, `cliBlocks`,
`errorsUnrecovered`. It carries **structural data only** (names, counts,
statuses) so the manifest is safe to share: no configuration text, no
credentials, no addresses.

### Wired into the run

`_save_run_artifact()` runs once at the end of a run:

- **Only for a green run.** A file that silently captures a broken topology is
  worse than no file; a failed run records nothing.
- **Never fails the build.** A save problem is recorded as its own
  `pkt_save_failed` event and surfaced in the run summary instead of turning a
  good build into a failed one.
- **Bounded and measured.** No reopen, so no 20 s open wait. Its own wall time
  is reported separately (`pkt.saveMs`, and the log says "outside the build
  cost above") so it can never be mistaken for build time.
- **Skippable without a code change:** `NETBUILDER_ARTIFACT=0`.
- **Skipped quietly when there is no RPA stack**, rather than reporting a
  misleading failure.

### Reaching it from the app

- `POST /pkt/save_verified` (`project`, `outDir`, `force`, `reopen`) starts it
  in the background; poll `/pkt/status`, read `/pkt/report` for the artifact
  and its comparison. It takes the `pkt` activity slot, so it refuses to run
  during a build rather than fighting it for the mouse.
- `GET /pkt/report` — the last artifact plus its comparison.
- `AutopilotService.pktSaveVerified()` / `pktReport()` in the Dart client, and
  a **Save verified artifact (.pkt + report)** button on the Packet Tracer
  files screen that shows file, bytes, sha256, reopen result and the full
  comparison.
- The build screen's run log prints the artifact path and its device/link/
  CLI-block counts. Everything above also arrives in `run_summary.pkt`, so no
  extra polling was added to the UI.

---

## Verification

- `pytest` — **139 passed** (was 122 before this work; 17 new gates in
  `test_build_completeness.py`). The new file runs without Packet Tracer,
  Tesseract or the RPA stack.
- `flutter analyze` — clean.
- The direct-run safety script `test_autopilot_safety.py` fails at
  `check_cli_and_interface_guard` — **confirmed pre-existing** by running the
  identical assertion against the pre-change backup, which fails the same way.
  Everything after it in `main()` was run separately and passes.

### What is still unproven here

No live run has been executed, so the artifact chain has not driven a real Save
As and the re-read has not faced a real repaint race. Both paths are exercised
with stubs and the logic is pinned, but the first live build is the real test.
After it, read: `cli_block_reasons`, `cli_prompt_recovered`,
`cli_prompt_reread_capped`, and `pkt.comparison.devicesMissing`.
