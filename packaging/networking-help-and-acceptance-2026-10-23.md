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
- Offline, a help ask the corpus does not cover says what it needs
  (topic or symptom, real equipment or simulator, one read-only check)
  instead of dumping the plan; follow-ups re-resolve to the previous
  networking topic rather than the standing topology. How-to answers
  offer the guide chip, not the build chip.
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

## What is still not verified here

- The build is unsigned; SmartScreen will warn testers. A signed build
  still needs the certificate secrets in the tag-only CI job.
- The clean-VM walkthrough in `CLEAN-VM-TEST.md` remains a manual gate:
  the install/upgrade tests above isolate the install root but run on
  the development machine, not on a machine without Flutter, Python, or
  this checkout.
- The 3-5 tester pilot (`pilot/README.md`, tasks T0-T6) has not been
  run; the kit and metrics summarizer are ready.
- Live Packet Tracer autopilot workflows (device placement, DHCP/DNS/
  HTTP probes, SSH) were not exercised in this pass; offline `.pkt`
  generation is covered by the widget-level build test and the packaged
  engine health check. The offline-only device kinds are skipped, never
  substituted, in a live run.
