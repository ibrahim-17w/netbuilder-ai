# NetBuilder roadmap implementation

Implemented and reviewed locally on 2026-10-27. Changes have not been committed,
pushed, or deployed.

## Review of items 1–4

- Plan fingerprinting: checked the existing complete-design revision and cache
  invalidation tests.
- Saved cable verification: require actual saved cable evidence; a generated
  port mapping alone cannot mark the saved file verified.
- Version history: query all versions of the selected project rather than a
  limited recent-build list. Chat builds now join saved-project history and
  unchanged rebuilds reuse their version.
- Address table: reject malformed IPv4/IPv6 entries, wait for persistence before
  displaying an edit, and retain the previous value when persistence fails.

## Additions 5–10

| Item | Where to use it | Behavior |
| --- | --- | --- |
| 5. DHCP/DNS import fidelity | Import a Packet Tracer file | Recognized server GUI DHCP pools and IPv4 DNS A records join the existing IOS import. Supported Standard Server data is checked through build/import/rebuild round trips. Unsupported service fields remain subject to the import fidelity notice. |
| 6. Saved project checks | Saved network menu → Project checks | Save source/destination reachability goals, inspect offline explanations, and request desktop Packet Tracer evidence. Edited designs make old results stale. Blocking policies require manual evidence; a timeout never proves a policy. Phones retain offline checks and explicitly disable the desktop-only action. |
| 7. Shared labs and progress | Guided network labs | Chat and the lab screen share definitions and grading. Local progress retains the plan, completed goals, hint count, and the latest 20 attempts. Continue opens the saved project in chat. |
| 8. User blueprints | Saved network menu → Save as blueprint; Your blueprints | Search, rename, describe, tag, delete, and reuse local templates. Each use creates independent, unverified history without source credentials. |
| 9. Project packages | Saved network menu → Export project package; Import project package | Export a versioned `.nbproject` with the sanitized plan, checks, configuration/report attachments, and optionally a newly generated `.pkt`. Imports validate size, format, checksums, and attachment names before an atomic database write. Each import gets a fresh identity and unverified checks. Attachments remain inert until explicitly saved. |
| 10. Device workflow coverage | Integration test and CI | The real app workflow cancels and accepts layout selection, writes/decrypts a `.pkt`, saves an edit, reopens the local database, opens the latest version, and imports a package. Windows and Android CI jobs run the same scenario. |

## Verification

Each addition received focused checks before moving to the next:

- Item 5 / reviewed baseline: 45 Flutter checks passed.
- Item 6: 3 Flutter checks and 18 targeted Python checks passed; later evidence
  and mobile-action assertions were added to the Flutter checks.
- Item 7: 25 focused Flutter checks passed.
- Item 8: 4 focused Flutter checks passed.
- Item 9: 7 focused Flutter checks passed.
- Additional package/blueprint credential and atomic-write tests: 9 passed.
- Address-save and saved-history integration regressions: 18 passed.
- Full Python suite: 600 passed, 1 skipped.
- Windows real-app integration: passed.
- Android API 35 emulator real-app integration: passed. The initial build hit a
  dependency-server DNS failure; a retry built, installed, and passed the test.
- Static analysis with `--fatal-infos`: no issues.
- Formatting for all 32 changed/new Dart files: passed.
- CI workflow YAML: parsed successfully; Android emulator job is present.

The final combined Flutter run passed 2,688 tests; one file could not load its
SQLite native library while a concurrent Windows build replaced shared build
assets. After a successful sequential Windows rebuild, all 3 tests in that file
passed on retry (2,691 tests in total, no remaining test failures).
Local logs are under `build/roadmap-*.log`,
`build/item*-check.log`, and `build/item10-*.log` (generated, not committed).

The repository-wide formatter currently reports six pre-existing files outside
this feature work: `config_paste_reader.dart`, `networking_help_reader.dart`,
`nlu/lexicon.dart`, `pkt_analysis_chat.dart`, `validator_service.dart`, and
`device_support_contract_test.dart`. These are left untouched to avoid mixing
unrelated formatting into the implementation.

## Manual boundaries

Live Packet Tracer ping execution and native operating-system file-picker/share
dialogs still require manual validation. A generated or imported project is not
automatically marked live-verified. Remote GitHub CI has not been run by this
local change. Packages preserve supported editable design data rather than a
complete Packet Tracer scenario, and omit source credentials intentionally.
