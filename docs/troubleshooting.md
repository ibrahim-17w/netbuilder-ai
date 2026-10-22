# Troubleshooting

## The app starts with a "Reduced startup" banner

A subsystem did not finish within its deadline. The rest of the app is still
usable with safe defaults.

- **Memory** - the local database could not be opened. Close any other
  NetBuilder window and retry. The existing store is preserved, not
  overwritten; if it was unreadable it is kept beside the new one as
  `memory.db.unreadable-<timestamp>`.
- **Settings** - preferences or secure storage did not answer. The app uses
  defaults until they do.
- **Build history / app version** - the history list or About version may be
  empty until the next launch.

The banner's **Details** action explains the memory failure. The same failure
also appears in the app log.

## The first-run readiness panel says something is missing

The panel is a checklist, not a gate. Offline planning, the offline assistant
and `.pkt` generation work with every optional item still missing.

- **Local engine** - start it from the panel or close the old engine process.
  The panel rechecks the configured loopback address.
- **Online model key** - optional. Add one in Settings only for
  model-written chat answers; Private Mode keeps the app offline by choice.
- **Packet Tracer** - optional for offline `.pkt` work. Install it, then press
  Recheck; live autopilot also needs it open, maximized and focused.
- **OCR and permissions** - OCR comes from the bundled engine. No
  administrator rights are required. If OCR is unavailable, live CLI checks
  may need manual review.

Use **Settings > Show setup checklist** to bring the panel back after hiding it.

## "Engine not running"

The sidecar needs Python 3 and its packages, and runs on the same PC as the
app:

```powershell
pip install -r sidecar/requirements.txt
```

The engine status is in the top bar, and the app shows the engine log when a
request fails. Phones build `.pkt` files on-device; remote engine control is
unsupported. A remote engine is refused rather than being sent a provider
key.

## A build step is reported instead of completed

That is the autopilot's fail-closed rule. It could not prove the Packet Tracer
screen matched the expected state, so it stopped rather than guessing. Read
the report; nothing was assumed as done.

## "The plan contains more than 50 devices..."

Plans above 50 devices are refused as unsafe or likely misparsed. Split the
lab or reduce counts, then validate again.

## The model answered "the engine is unavailable"

The request to the model failed (offline, rate limit or provider outage). The
message names the cause. Chat keeps working with the offline assistant.

## A truncated model reply

The app keeps the readable part and says the answer was cut off. It does not
dump raw JSON on screen.

## sqlite3.dll is locked on Windows

A previous app, test run or file scanner still holds the DLL. Close NetBuilder
and run the cleanup helper from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tool/clean_windows_build.ps1 -Force
flutter clean
flutter pub get
```

The helper stops stale `net_builder`, `netbuilder` and `flutter_tester`
processes, then retries removal of `build\windows` and
`.dart_tool\flutter_build` with backoff. If it still fails, close Explorer
previews and pause antivirus scanning for the retry.

For a single locked test process, close the test window or run:

```powershell
Get-Process flutter_tester -ErrorAction SilentlyContinue | Stop-Process -Force
```

## Where the logs are

- **App log:** `<app support directory>\netbuilder\logs\netbuilder.log`, with
  `netbuilder.log.1` and `.2` rotations. It is local-only and redacted.
- **Engine log:** shown by the app's engine diagnostics; also written by the
  sidecar next to its runtime files.

To collect a bundle, open **Memory > Tester diagnostics** and choose
**Export diagnostics**. The archive contains the redacted sidecar journal and
the app log. Screenshots are opt-in because they may show names or addresses.
The archive is created locally; nothing is uploaded.

## Resetting local state

Prefer the in-app controls first:

- **Memory > Clear all memory** removes learned rules, preferences and
  history, but not your API keys.
- **Settings** has the provider and target controls.

Removing the SQLite file by hand loses the recovery copy and is not
recommended. If you need to move it, close the app first.
