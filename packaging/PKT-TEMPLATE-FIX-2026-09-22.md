# `.pkt` build failed on an installed machine

Date: 2026-09-22
Workspace: `C:\ai`, app at `C:\ai\app`

## The report

The chat showed:

> I could not build the .pkt: Exception: no template library in
> `C:\a\app\build\windows\x64\runner\Release\sidecar\_internal\pkt_templates`.
> Build it from your own .pkt files first (POST /pkt/templates/build).

## Reproduced, not guessed

The sidecar serving port 5005 was the packaged one, so the same call was made
here:

```
POST /pkt/generate -> HTTP 400
{"ok": false, "error": "no template library in
  C:\ai\app\build\windows\x64\runner\Release\sidecar\_internal\pkt_templates.
  Build it from your own .pkt files first (POST /pkt/templates/build)."}
```

Identical message, same cause. This is a reproduced failure, not a candidate.

## Root cause

- `pkt_template_build.TEMPLATE_DIR` was a fixed path: `<sidecar directory>/pkt_templates`.
- That folder is built from the user's own `.pkt` saves and is machine-local
  (gitignored). It existed on the development machine and nowhere else.
- `packaging/build_installer.ps1` copied the frozen sidecar into the payload but
  **never copied `pkt_templates`**, so an installed app had no template library.
- The generator cannot synthesise a `.pkt` without one, so **`build a .pkt`
  could never work on any machine but this one**. That is the whole failure.

## The fix

| Change | File |
|---|---|
| The library is searched where it can actually live: the sidecar folder, the frozen app's bundled data (`sys._MEIPASS`), and a writable per-user folder (`%LOCALAPPDATA%\NetBuilderAI`). First one with a `manifest.json` wins. | `sidecar/pkt_template_build.py` (`candidate_dirs`, `find_library_dir`) |
| `load_library` asks that resolver instead of a hard-coded path | `sidecar/pkt_builder.py` |
| **Self-healing**: `ensure_library()` builds a library from bundled sample saves when none exists, so a machine that has never seen a `.pkt` still works | `sidecar/pkt_template_build.py` |
| `/pkt/generate` calls `ensure_library()` before generating | `sidecar/pt_autopilot.py` |
| **Three real Packet Tracer saves ship with the app** as seeds (~140 KB) | `sidecar/pkt_seed/` |
| **The installer now bundles both** `pkt_templates` (the good, full library) and `pkt_seed` into the frozen sidecar's `_internal` folder - the exact place the app looks | `packaging/build_installer.ps1` |

Two layers on purpose: the installer ships the *full* library built from real
saves, and if it is ever missing the app rebuilds a basic one by itself. Neither
path needs the user to supply a file first.

## Verification

### A machine that has never built a `.pkt`

A fresh install was simulated: a copy of the sidecar **without**
`pkt_templates`, with `pkt_seed` present, and an empty per-user folder so the
fallback could not cheat.

```
library before: False
ensure_library: {"built": true, "reason": "built from 3 bundled save(s)"}
library after:  True
generate: path ...\pkt_output\fresh-install-check.pkt
EXISTS True  SIZE 48242
AUDIT devices: ['R1', 'SW1', 'PC1']
```

The app built its own library and produced a real 48,242-byte `.pkt` that its
own audit can read back.

### A correct plan, on the normal path

```
path     : C:\ai\app\sidecar\pkt_output\e2e-links.pkt
devices  : 3   links: 2   bytes: 48330
warnings : []
audit    : ['R1', 'SW1', 'PC1']
```

Three devices, two links, no warnings.

### Honest caveat from the first run

The first fresh-install attempt reported `linkCount: 0` with warnings such as
`SW1: template 2960-24TT has no port for f0/1`. That was the test plan using
invented interface names, not a build defect: a library learned from three saves
knows fewer ports. With the correct port names the same build produced 2 links
and no warnings. It is recorded here because it is the reason the installer
ships the **full** library rather than relying on the seeds alone.

### Regression

```
cd sidecar && py -3.14 -m pytest -q  -> 389 passed, 1 failed
```
The one failure is `test_ocr_perf`'s golden OCR comparison, which is
pre-existing and environment-dependent. It is untouched by this change.

### The packaged sidecar, which is the layout that failed

The installer was rebuilt, and then the **packaged** sidecar was run and asked
to build a `.pkt` - the exact scenario from the report:

```
health: {"ok": true, "rpa": true, "ocr": true, ...}
devices=4 links=3 bytes=49679
warnings: []
path: ...\Release\sidecar\_internal\pkt_output\packaged-check.pkt
EXISTS True  SIZE 49679
identify isPkt: True
audit devices: ['R1', 'SW1', 'PC1', 'PC2']
second build: ...\packaged-check-2.pkt  49679
RESULT: the packaged app builds .pkt files
```

Four devices, three links, no warnings, the app's own identifier accepts the
file as a Packet Tracer save, its own audit reads all four devices back, and a
second build of the same plan produces the same 49,679 bytes. The failure that
started this is gone, on the packaged layout, not just in a simulation.

### The installer carries the library

```
build\tester-installer\payload\sidecar\_internal\pkt_templates -> 144 files
build\tester-installer\payload\sidecar\_internal\pkt_seed       -> 3 files
manifest: 118 device templates, 10 link templates, 259485 bytes
Installer: dist\NetBuilderAI-Tester-Setup.exe  104.7 MB
SHA-256 E521E0C8E76598ACF3F636FCF361D0EC7A6CD580944AC176EAECF2BD36EA3043
```

### A build-script bug found on the way

`packaging/build_installer.ps1` aborted because PyInstaller prints a
deprecation note on stderr and the script runs under
`$ErrorActionPreference = 'Stop'`, which turns native stderr into a terminating
error. The Flutter and PyInstaller calls now lower the preference for their own
duration and judge success by `$LASTEXITCODE`. It also had to be run with no
sidecar process holding `libcrypto-3.dll` in the release folder.

## The installer now arrives configured

`packaging/installer_install.ps1` creates the folders the app writes to and
records them, so a recipient never picks a path or edits a file:

```
cache  config  data  logs  output  sidecar  tesseract
```

```json
{
    "schemaVersion":  1,
    "installedAt":  "2026-09-22T21:39:41.5769573+03:00",
    "installRoot":  "C:\\Users\\L\\AppData\\Local\\Temp\\nb-install-test-213918\\NetBuilderAI",
    "outputDir":    "...\\NetBuilderAI\\output",
    "logsDir":      "...\\NetBuilderAI\\logs",
    "cacheDir":     "...\\NetBuilderAI\\cache",
    "dataDir":      "...\\NetBuilderAI\\data",
    "engineBase":   "http://127.0.0.1:5005"
}
```

Verified by an actual install run with `LOCALAPPDATA` pointed at a temporary
folder, so nothing on the real machine was touched. The paths are resolved from
that machine's own user profile at install time, which is the device adaptation:
**every machine gets its own correct paths without being asked.**

The app reads that file on start (`SettingsService._loadInstallInfo`). A fresh
install therefore opens with a working output folder. Four tests cover it:

- a fresh install adopts the folders the installer created;
- a folder the user chose is **never** overwritten by the installer;
- no install record at all is fine, and the platform-aware engine default still
  applies;
- an unreadable record does not break startup.

```
flutter analyze  -> No issues found
flutter test     -> 229 passed   (225 before, +4 install-config)
```

## Still to do

- The `Setup.exe` has been built, its payload verified, and its install script
  exercised into a temporary target - but it has **not been installed on a
  second machine** here. The strongest evidence produced is the packaged sidecar
  building a `.pkt` in place, plus the install run above.
- Moving the remaining chat-surface options (run controls, GNS3, ledger, live
  context, project context) into Settings: **not done**. The chat currently
  keeps the token counter, attach, the Tools sheet, the field and send.

## Rollback

Source revert of the four files plus `sidecar/pkt_seed/`. No storage format and
no `.pkt` format changed, and no existing file is moved or deleted; the library
is only ever *added* if missing.
