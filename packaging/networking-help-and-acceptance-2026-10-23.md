# Networking help without a build, and the 2026-10-23 acceptance pass

The app now answers networking requests - explanations, configuration
guidance, design advice, troubleshooting - as first-class conversations
that never require a topology, an engine, an API key, or a `.pkt` file,
and the tester package was rebuilt and re-verified from that source.

## What changed for intent understanding

- `lib/services/networking_help_reader.dart` recognizes help asks:
  explain/teach/describe wording, how-to shapes, whole-message WH
  questions, symptoms ("cannot ping", "no internet"), bare topics
  ("and vlans?"), and short follow-ups ("give me an example"). Device
  counts and imperative change verbs keep their planning paths.
- Help turns are classified `howto` by `NetworkIntent.classifyBrief` and
  treated as non-planning by `NetworkIntent.followUp`, so a help question
  never re-plans or shrinks the standing lab. In the chat screen a help
  turn skips re-parsing, file-edit/redraw intents, the tool loop, and the
  build card; the model path still streams a plain answer with the
  conversation context.
- Pending clarification questions are resolved BEFORE the help gate, so
  typing "OSPF" still answers the routing question the app just asked.
- Offline, a help ask the corpus does not cover keeps the guided
  near-miss reply; follow-ups re-resolve to the previous networking topic
  rather than the standing topology. How-to answers offer the guide chip,
  not the build chip.
- `GuideRequestReader` only claims whole-message plan instructions
  ("how do I build this?", "walk me through it", "just the steps").
  A topic how-to ("how to configure a trunk port") is answered, not
  opened as the standing plan's guide; `/guide` and `/steps` remain
  explicit.
- The keyed-model system prompt now states the help contract: answers
  need no topology/engine/key, `.pkt` creation requires an explicit file
  request or card approval, plain help carries no actions, and
  troubleshooting leads with read-only checks and credential caution.
- `/help` and the `/` skill menu advertise the help paths (listed last;
  the menu is capped at eight entries).

## Source gates (2026-10-23, revision `1fe55bd`)

- `dart format` 0 changed; `flutter analyze --fatal-infos` clean.
- `flutter test` 2543 passed (includes the new
  `networking_help_reader_test.dart`, `offline_help_intent_test.dart`,
  `guide_request_reader_test.dart`, `build_guide_test.dart`, and the
  updated `device_support_contract_test.dart` offline-only contract).
- Sidecar `python -m pytest -q`: 579 passed twice - once with
  `PYTHONUTF8=1` and once with it unset.

## OCR locale fix found by the full run

`sidecar/test_ocr_perf.py::test_golden_ocr_text_matches_recorded_baseline`
failed under `PYTHONUTF8=1` because `_tesseract_run` decoded Tesseract's
UTF-8 stdout with the console locale (`text=True`): the recorded
baseline carried cp1252 mojibake from the shell that recorded it, and
any UTF-8 shell disagreed. The engine now decodes bytes as UTF-8 and
normalizes CRLF to LF; the baseline's 25 mojibake entries were repaired
by exact cp1252/UTF-8 round-trip (no re-recording); the contract test
pins the new decode with a stubbed UTF-8/CRLF answer. The suite now
passes identically under both locale modes.

## Packaged release (2026-10-23)

- Package revision `1fe55bddc093f2c44ff40b479b7bddeb7403e8b4`, built
  with `sourceDirty: false`; app `1.0.0`; engine
  `2026-10-23-offline-kinds-ocr-utf8`.
- `packaging/verify_release.ps1` exited 0: bundle and release manifests
  and `SHA256SUMS.txt` agree on every artifact hash and size.
- `packaging/test_install.ps1` exited 0: per-user install into a temp
  root, schema-2 `install.json` matching the bundle manifest, the
  installed app started, the bundled engine auto-started and answered
  `/health` with the manifest version, the default uninstall kept the
  synthetic `data`/`output`/`logs`/`config` fixtures, and `-Purge`
  removed the folder.
- `packaging/test_upgrade.ps1` exited 0: install over synthetic user
  data, all fixtures byte-identical after the upgrade, the upgraded app
  and engine started and the engine version matched `install.json`.
- Installer SHA256
  `605ede853b4aadb104d26f5361b332b2269a4416482bdbb307c13ba514e73223`;
  portable ZIP SHA256
  `591e3afd354d708389a0464f67f6ffbcc9ebef21b9de3477c9136fd196872934`;
  bundle-manifest SHA256
  `fb945712534ecc9e6959d457d4921ed4122a7cffdfda04ce11c2ad341a75f076`.

# Help-first feature batch (2026-10-24, `ff68fde`..`d02d64a`)

Six features deepened the help-first direction. Each was committed
separately after its own checks (targeted suites + analyzer; features 5
and 6 additionally ran the FULL Flutter suite / full sidecar suite).

1. **Verified addressing after a build** (`1fe55bd` line of work,
   committed as the addressing extension): the plan-vs-file comparison
   now reads the audit's per-port saved IPs, resolves plan interfaces
   through the generator's port-remap table, matches Cisco shorthand to
   full save names, and reports unconfigured, wrong and leftover
   (template) addresses. A device whose interfaces the audit cannot
   read is marked "not comparable" instead of failed.
2. **Keyless OCR for attachments** (`ff68fde`): the engine gained a
   local `/ocr` endpoint (base64 image in, UTF-8 text out, no window,
   nothing typed; `sidecar/test_ocr_endpoint.py` 4 tests). The app reads
   attached screenshots through it and the offline reply quotes the
   machine-read text as evidence; an image-only turn shows the text and
   asks what to make of it; without the engine the reply says so.
3. **Pasted-config review** (`deab1b4`): a pasted `show run` is
   recognized before parsing (a single line never matches) and answered
   with a deterministic offline review - plain-English sections for what
   the config actually contains, classic mistakes as findings with
   reasons (telnet vty, shared vty password, enable password without
   secret, plaintext without encryption, access ports on VLAN 1).
   Absent sections are not described.
4. **Device questions from the plan** (`b773f21`): "what does SW1 do?"
   is answered from the standing plan - type, addresses, cables with
   both ports, service roles, and the read-only commands that show the
   same facts on the device. Uncovered help keeps the guided near-miss
   with the plan's devices named as ground; follow-ups find their topic
   past acknowledgements; a gap answer never advertises the build.
5. **Scan-side reachability** (`3aa384a`): "why can't PC1 ping PC2?"
   against a scanned .pkt walks the file's own rows - addresses, cable
   path (BFS over the link table), admin-down interfaces on the path -
   and reports the first blocking rung with its fix; a clean file earns
   the honest limit plus the live checks (mask, gateway, route).
6. **Industrial kinds place live** (`3e5cf30`): hub, sniffer, plc,
   historian, cyber-observer, controller and power-distribution gained
   taught DEVICE_PALETTE paths, so a live run places them instead of
   recording `offline_only`. Both offline-only sets are now empty (kept
   as the landing place for the next template-backed kind without a
   click-path) and the palette gate tests pin both directions, including
   that a graduated kind keeps its offline template compile. Engine
   version `2026-10-24-industrial-palette-paths`.
7. **Real-hardware guide + export** (`d02d64a`): a non-PT target speaks
   console/rack (rack and console, physical cabling, PT-equivalent model
   note) and leaves out the ASA/offline-only notes; the guide dialog
   gained Save to file, writing `guide-<network>.md` (same network
   naming the .pkt uses, numbered when taken) beside the .pkt files.
   Persisted checkboxes in the dialog are deliberately NOT in this
   slice.

## Batch gates (2026-10-24, final state `d02d64a`)

- `flutter analyze --fatal-infos` clean; `flutter test` 2581 passed.
- Sidecar `python -m pytest -q` (PYTHONUTF8=1): 584 passed, 1 skipped -
  the skip is the offline-only compile test, legitimately vacuous now
  that the set is empty.

## What is still not verified here

- The 2026-10-23 package artifacts predate this batch: rebuild the
  tester package from `d02d64a` before handing it to testers.
- The build is unsigned; SmartScreen will warn testers. A signed build
  still needs the certificate secrets in the tag-only CI job.
- The clean-VM walkthrough in `CLEAN-VM-TEST.md` remains a manual gate;
  the 3-5 tester pilot has not been run.
- The new live palette paths are pinned by mocked click tests only -
  real Packet Tracer acceptance (does the IoT submenu actually hold
  these rows on the pilot machine's PT build?) is a recorded manual
  gate, same as the rest of the live simulator checks.
