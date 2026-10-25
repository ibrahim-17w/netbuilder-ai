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

# Adoption, diff and guided labs (2026-10-24, `cbf49d2`..`62a0ed5`)

Three features closed the biggest remaining gaps after the help-first
batch. Each was committed after its own check; the final tree passes
the full suite.

1. **Any scanned file becomes the lab** (`cbf49d2`): the scan card now
   carries "Make this file the lab this conversation edits", and typed
   "use this file as my lab" runs the same import - the save becomes
   the standing plan, the reply names what was kept, what the save
   cannot prove, and what it replaced. The guide, build, edit and
   change machinery now work on any Packet Tracer file the user brings.
2. **Scan diff** (`e06a2bd`): "diff A.pkt and B.pkt" (or "compare this
   file with B.pkt" against the current scan) audits both files
   read-only and reports devices added/removed, addresses moved per
   interface, cable endpoint pairs, and findings cleared/introduced -
   matched by text, never per-scan ids. Interface state flapping is not
   reported; identical files say so.
3. **Guided labs** (`62a0ed5`): three starter labs (VLANs with DHCP,
   two-router OSPF WAN, secure management) with `/lab`, "start the
   <name> lab", and "check my lab" - the standing plan graded step by
   step, each check reading fields the planner actually writes, with a
   remedy per open step. Progress survives a reopen via the session
   state; the grade is always recomputed, never replayed.

# Correctness batch: revision, cables, history, addresses (2026-10-24,
# `a1b2f6d`..`1012f46`)

Four items from the external reliability review, each inspected first,
implemented as the smallest working slice, and committed after its own
focused checks; the final tree passes the combined regression.

1. **Plan revision covers every validator input** — the revision now
   hashes the service rules (through the sanitized, key-sorted planner
   copy, so no password/PSK/token ever enters the identifier), management
   addresses and IPv6 assignments. A configuration-only edit on the SAME
   plan object therefore invalidates the memoized validation by
   construction; a canvas-shaped edit (notes) still does not move it.
   Regression tests pin each direction; the perf gates still pass.
2. **Saved cables verified** — the build verification reads the audit's
   LINK rows back out of the save and compares endpoint pairs against the
   plan (shorthand normalized, order ignored). A removed or miswired
   cable fails verification even when device and cable counts match.
   Link data is only comparable when the audit states its count; older
   audits keep the ports-based verdict with the honest note.
3. **Plan version history** — every version shares a stable projectKey
   and names its parent (schema v12; nullable for legacy rows, whose
   timelines fall back to the project name). A pure PlanVersionDiff
   (devices, cables, addresses, routing, VLANs, services; secrets
   stripped) replaces the home screen's inline compare, and the row menu
   gains Restore: the old plan becomes a NEW version parented to the
   project's newest row - originals retained.
4. **Project address table** — the toolkit's addressing section shows
   the plan's addresses as one table (device, interface, IPv4, IPv6,
   dot1Q-derived VLAN) with live filtering, RFC-4180 CSV copy, and tap-
   to-edit: dialog-side validation, then a new plan through the pure
   applyEdit saved via the host's plan-save path (the same versioned
   chain as any edit).

Also fixed en route: `_addColumnIfMissing` compared camelCase arguments
against a lowercased readout, so any non-lowercase column was re-ALTERed
on every launch - latent since the helper was written, exposed by the
first camelCase column. The recovery tests cover it.

## Batch gates (2026-10-24, final state `1012f46`)

- `flutter analyze --fatal-infos` clean; `flutter test` 2659 passed
  (combined regression after the batch, per the process; item 1's commit
  landed after that run, and its own focused checks - cache tests, perf
  gates, the revision-sensitive chat suites - all passed).

## What is still not verified here

- Items 5-10 of the review (importer DHCP/DNS fidelity, user checks,
  unified labs, blueprints, project packages, the offline workflow
  integration test) are not started.
- The 2026-10-23 tester package predates all of today's work.
- The clean-VM walkthrough, the 3-5 tester pilot and live Packet Tracer
  acceptance remain manual gates.

1. **Unanswered-questions loop** (`aec68b5`): a keyless miss (the
   guided near-miss reply) is recorded in a local backlog - one row per
   distinct ask, deduped on normalized wording, hit-counted, capped at
   the newest 200. The Memory screen's learned tab shows the list
   newest-first with hit counts and a clear button. Deliberately NOT in
   the backup export: it is a local to-do, not memory to reproduce.
   DB schema version 11; the migration is re-runnable.
2. **Lab report export** (`4790eff`): "export a lab report" (or
   /report) assembles one Markdown file beside the .pkt ones - the plan
   with its addressing, the design review with its score, every build
   with its verification note, the offline scan findings, and the full
   build guide. The report invents nothing: missing evidence (no build
   yet, no scan) says so in words.
3. **Persisted guide checkboxes** (`8a42067`): the guide dialog renders
   the verification checklist as real checkboxes, keyed by plan
   revision in the session state, so a long build can be put down and
   picked up. The markdown stays the one truth: copied or saved text
   always reflects the ticks.

Also: the file-edit widget tests' pump budget widened - the in-place
compile does real CPU work between pumps and the old 9-second budget
ran out on a loaded machine (the behavior itself was and is correct).

## Batch gates (2026-10-24, final state `8a42067`)

- `flutter analyze --fatal-infos` clean; `flutter test` 2631 passed.

## What is still not verified here

- The 2026-10-23 package artifacts predate all of today's batches:
  rebuild the tester package from `8a42067` before handing it to
  testers.
- The build is unsigned; SmartScreen will warn testers. A signed build
  still needs the certificate secrets in the tag-only CI job.
- The clean-VM walkthrough and the 3-5 tester pilot remain manual gates.
- Live Packet Tracer checks (industrial palette rows, DHCP/HTTP probes)
  remain recorded manual acceptance runs.

# Security hardening under the push gate (2026-10-25/26, `ce3c086`..)

The project's Mimosa security gate blocked the first push with 38 sealed
findings (31 path-traversal, 6 XML entity expansion, 1 CLI-arg taint).
Rather than bypass, each class is being fixed honestly:

1. **Engine-supplied .pkt paths refuse traversal** (`ce3c086`): `_pkt_path`
   checks the RAW input for `..` segments before abspath folds them away
   (post-resolution parts can never show the probe) - the engine can serve
   another device, and a client sending `..` is probing, not auditing.
2. **Untrusted save XML cannot expand entities** (`0126e5e`): a shared
   `xml_guard` refuses any document declaring a DOCTYPE or ENTITY before
   ElementTree parses it - a billion-laughs save could pin the engine
   during an audit or build, and Packet Tracer saves never declare either.
   All five `fromstring` sites in the builder/template-builder route
   through it.
3. **Path sweep** (in flight): the remaining flagged IO sites - the
   engine's own state files (journals, learned memory, OCR temp) and the
   CLI tools' user-arg paths - route through a shared
   `path_guard.ensure_no_traversal` / `open_state`.

## What is still not verified here

- Items 6-9 of the review (user checks, unified labs, blueprints,
  packages) are not started - deliberately: the pilot's findings should
  rank them.
- The clean-VM walkthrough and the 3-5 tester pilot remain manual gates;
  the pilot kit is staged with the fresh package once the rebuild lands.
