# Windows tester packaging and first-run readiness

The app now builds a reproducible per-user Windows package and explains its
own readiness on first launch. The package records exactly what was shipped,
the installer rechecks those hashes before extracting, and the uninstaller
keeps the user's work unless `-Purge` is explicit. A pilot kit captures the
first external-tester measurements for the follow-up report.

## Packaging behavior

- `build_installer.ps1` builds the Flutter release and frozen sidecar
  together, stages the payload, writes `bundle-manifest.json` (schema 1) and
  `release-manifest.json`, compresses the portable ZIP and writes
  `SHA256SUMS.txt`. Code signing is optional locally and required by the
  tag-only CI job (`-RequireSignature`).
- The bundle manifest records app and sidecar versions, the source revision,
  dirty state, signing status, and hashes for the app executable, the AOT code
  (`data/app.so`), core runtime DLLs, the frozen engine, the Packet Tracer
  template manifest, Tesseract, both READMEs and the uninstaller. Whole-archive
  coverage stays in the release manifest and `SHA256SUMS.txt`.
- `installer_install.ps1` validates every manifest hash and the ProductVersion
  before extracting, installs to `%LOCALAPPDATA%\NetBuilderAI` with no
  administrator prompt, creates Start Menu shortcuts and an HKCU uninstall
  entry, and writes `install.json` (schema 2) with `appVersion`,
  `sidecarVersion`, `sourceRevision` and the manifest hash. It refuses unsafe
  install roots and stops old processes from the same root first.
- The default uninstall removes the app, shortcuts and registry entry, keeps
  `data`, `output`, `logs` and `config`, and writes `UNINSTALLED.txt`;
  `uninstall.ps1 -Purge` removes the folder entirely. The IExpress wrapper
  exits with code 0 after launching the app instead of waiting on a hidden
  finish dialog.

## First-run readiness and diagnostics

- The chat screen shows a dismissible readiness checklist: local engine
  (start/recheck), optional model key, Packet Tracer detection, OCR
  availability from the engine, and the no-admin permission note. It is a
  checklist, not a gate: offline planning and `.pkt` generation work with
  every optional row missing.
- Settings > **Show setup checklist** restores a dismissed panel.
- Navigation events are recorded only in the redacted local app log.
- The diagnostics export header now includes the installed app version,
  engine version, source revision and bundle-manifest hash; the engine
  handshake distinguishes a different-major engine from a stale same-major
  build and tells the user to restart the engine.

## Pilot kit

`pilot/README.md` defines tasks T0-T6 and the metric definitions (time to
first valid topology, percent of plans needing manual repair, crash-free
sessions). `pilot/scorecard.csv` is the row format, and
`pilot/summarize_metrics.py` (with unit tests) rejects blank repair/crash
values and reports the first-topology success rate.

## Evidence (2026-10-22)

- Package revision `5fdb6501a5c59f707c81d28a77bfe680c14a6c5f`, built with
  `sourceDirty: false`; app `1.0.0+1`; engine
  `2026-10-20-app-schema-health-redaction`. Later commits touch only
  packaging tests and docs, not the payload.
- `verify_release.ps1`, `verify_bundle.ps1`, `test_install.ps1`,
  `test_upgrade.ps1` and the IExpress wrapper `verify_installer.ps1` all
  exited 0. The wrapper installed to `%LOCALAPPDATA%\NetBuilderAI` with a
  schema-2 `install.json`, and `/health` answered from the installed
  `sidecar\pt_autopilot.exe` with capabilities `pkt_build`, `pkt_audit`,
  `dry_run`, `memory`, `pt_autopilot` and `ocr`.
- The clean-install test also proves the default uninstall removes the
  binaries while keeping synthetic `data`, `output`, `logs` and `config`
  files; the upgrade test proves the same fixtures survive an upgrade.
- The extracted portable ZIP verifies: engine health came from the ZIP's own
  `sidecar\pt_autopilot.exe` and matched the manifest.
- Installer SHA256 `88eca6402f94d3e7860a1e195fb0af4507de0fc99623adcda0cfbcf8c126ed52`;
  portable ZIP SHA256
  `130432961ef954e8473b4743c477446379f9371282f0f5ce3ed668e355af6784`;
  bundle-manifest SHA256
  `b1e9e1b31d3e70a6f2188f47ec33f59ff597e31397da1180aa56ac703ab1a5a3`.
- Source gates: `dart format` 0 changed; `flutter analyze --fatal-infos`
  clean; `flutter test` 2525 passed; sidecar `python -m pytest -q` 577
  passed.

## Coverage and limits

- The local artifacts are unsigned; SmartScreen warns testers. A signed build
  requires the certificate secrets in the tag-only CI job and has not been
  run.
- The clean-VM/sandbox walkthrough in `CLEAN-VM-TEST.md`, including the
  first-launch screenshot and install timings, is a manual gate and has not
  been completed. The clean-install test isolates the install root but still
  runs on the development machine.
- The pilot has not been run; the kit is ready for 3-5 testers.
- Live Packet Tracer checks remain manual and are unchanged by this slice.
