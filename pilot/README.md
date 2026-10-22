# NetBuilder AI pilot kit

This folder is the runbook and metrics worksheet for a 3-5 person pilot of the
Windows tester package. The goal is not a general usability study. It is a
release gate: can someone who has never seen the repository install the app,
build a correct starter network, reopen it, and recover from a failure without
developer help?

## Before the session

1. Build a signed package with `packaging/build_installer.ps1 -RequireSignature`.
   For an unsigned internal dry run, omit `-RequireSignature` and expect
   SmartScreen to warn.
2. Run `packaging/test_install.ps1` and `packaging/test_upgrade.ps1` on the
   package.
3. Install Cisco Packet Tracer on the pilot machine if the session includes
   the autopilot. Offline planning and `.pkt` generation must work without it.
4. Give the tester `NetBuilderAI-Tester-Setup.exe`, `README-TESTER.txt`, and the
   SHA256 for the installer. Do not give them a checkout, Flutter, Python, or a
   pre-created API key.
5. Start a screen recording only with explicit consent. Record the app version,
   engine version, Windows version, and whether Packet Tracer was present.

## Session script

Use the tester's own words. Read only the task prompt; do not explain the UI
unless the tester is blocked for more than two minutes. Record the first
blocker, not the workaround you suggest.

| ID | Task | Start timing | Stop timing | Pass condition |
| --- | --- | --- | --- | --- |
| T0 | Install and open NetBuilder AI | Installer launches | First window is usable | App opens; no admin prompt; no missing-DLL dialog |
| T1 | Find what is missing on first run | Window is usable | Tester can name engine, model key, and Packet Tracer status | Readiness information is understandable without opening Settings |
| T2 | Build a small office LAN without an API key | Tester submits the prompt | A plan with the requested devices and links is shown | Plan is valid; no manual device/link repair |
| T3 | Add a guest Wi-Fi VLAN and keep the existing addressing | Tester submits the follow-up | Updated plan is shown and accepted | Existing devices/links remain; guest VLAN is present |
| T4 | Generate a `.pkt`, close the app, reopen the file | Generate starts | Reopened file shows the expected topology | Devices, links and addresses agree with the plan |
| T5 | Export diagnostics and identify the app/engine versions | Export starts | Tester can point to the archive and version fields | Archive is local; no secret is visible |
| T6 | Uninstall, then confirm whether saved work remains | Uninstall starts | Uninstall finishes | App removed; data-retention choice is clear |

If Packet Tracer is available, add one guided autopilot task after T4. Keep its
result separate: it exercises the GUI bridge, not offline planning.

## Metrics

Definitions are fixed before the first session so results are comparable.

- **Time to first valid topology (seconds):** T2 start to the first plan that
  passes validation with the requested device and link counts. If the tester
  repairs the plan, stop at the first valid repaired plan and record
  `plan_manual_repair=yes`. A session that never reaches a valid plan is
  recorded as a failure, not as a long duration.
- **Plan needing manual repair:** `yes` when the tester had to add, remove,
  relabel, or readdress a device/link after generation, or when a validator
  reported a blocking issue. Cosmetic changes (moving icons, renaming a plan)
  do not count.
- **Crash-free session:** `yes` when there was no unhandled app exception, no
  app process exit, and no engine crash requiring a restart. A rejected model
  response, a wrong plan, or a recoverable validation error is not a crash.

Enter one row per tester in `scorecard.csv`. Use `yes`/`no` (or `1`/`0`) for
the two repair/crash columns; an empty value is rejected rather than counted as
a success. `tasks_completed` is 0-7 for T0-T6. Leave `first_topology_seconds`
empty only when the tester never reached a valid topology; the summarizer
counts that row as a failure, not as missing time.

Summarize a completed sheet:

```powershell
python pilot\summarize_metrics.py pilot\scorecard.csv
```

The script prints participant count, mean and median time to first valid
topology, manual-repair rate, crash-free rate, and any blocking issues. It does
not upload or transmit the sheet.

## After the session

- File a reproducible defect for every blocker with the diagnostics archive,
  app/engine versions, and the task ID.
- Do not count a missing API key as a product failure for offline tasks; count
  it as an instruction/readiness issue instead.
- Re-run the affected task after a fix. Update the sheet, do not overwrite the
  original observation.
- A broader release needs every blocking defect fixed, no secret in any
  exported archive, and the clean-install/upgrade tests passing on the final
  package.
