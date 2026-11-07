# Windows tester packaging

`build_installer.ps1` builds one payload and wraps it in two deliverables:

| Artifact | Purpose |
| --- | --- |
| `dist/NetBuilderAI-Tester-Setup.exe` | Per-user installer; no administrator prompt |
| `dist/NetBuilderAI-Tester-Portable.zip` | Unzip-and-run fallback for locked-down machines |
| `dist/bundle-manifest.json` | App version, engine version, source revision, hashes |
| `dist/release-manifest.json` | Artifact hashes plus the bundle-manifest hash |
| `dist/SHA256SUMS.txt` | Human-checkable checksums for the release |

The installer and the portable ZIP contain the same staged app, frozen sidecar,
Packet Tracer templates, OCR payload, uninstaller, READMEs and the tester
runbook (`TESTER-RUNBOOK.md`, the walkthrough a pilot user is handed).

## Build

From the repository root:

```powershell
# Unsigned local build (SmartScreen will warn).
powershell -ExecutionPolicy Bypass -File packaging\build_installer.ps1

# Signed release build. Prefer the environment variable over the parameter so
# the password does not appear in the process list or shell history.
$env:NETBUILDER_SIGN_PASSWORD = '...'
powershell -ExecutionPolicy Bypass -File packaging\build_installer.ps1 `
  -SignCertificatePath C:\keys\netbuilder.pfx `
  -TimestampUrl http://timestamp.digicert.com `
  -RequireSignature
```

Use `-SignCertificateThumbprint` instead of `-SignCertificatePath` for a
certificate already installed in the current user's certificate store.
`signtool.exe` comes from the Windows SDK; the script also searches the standard
Windows Kits install locations. The app executable, bundled engine and installer
are signed before their hashes are recorded. A signing or timestamp failure
stops the build.

`-SkipFlutterBuild` reuses the existing release folder; the frozen sidecar and
payload are still rebuilt. Use it only when the Flutter binary is known current.

## Verify the artifacts

```powershell
powershell -ExecutionPolicy Bypass -File packaging\verify_release.ps1
powershell -ExecutionPolicy Bypass -File packaging\verify_bundle.ps1 `
  -BundleRoot build\tester-installer\payload
```

`verify_release.ps1` checks the release manifest, artifact sizes and hashes, the
`SHA256SUMS.txt` lines, and signatures when the release says it is signed.
`verify_bundle.ps1` starts the staged engine, rejects a stale process on port
5005, checks that the process serving `/health` is the shipped executable, and
compares its version with the bundle manifest.

## Install, upgrade and uninstall tests

```powershell
powershell -ExecutionPolicy Bypass -File packaging\test_install.ps1
powershell -ExecutionPolicy Bypass -File packaging\test_upgrade.ps1
```

`test_install.ps1` installs into an isolated temporary root with no shortcuts or
registry writes, verifies every manifest hash, starts the packaged app, checks
that it started the bundled engine, checks the version handshake, exercises the
default uninstall against synthetic user files, then purges the install.
`test_upgrade.ps1` installs a payload, writes synthetic history,
settings, output and logs, installs the new payload over it, and proves those
files survive unchanged.

To exercise the actual IExpress wrapper on a normal account, run
`packaging\verify_installer.ps1`; it installs to `%LOCALAPPDATA%\NetBuilderAI`
and starts the app. Use `test_install.ps1` for the repeatable CI-style check.

## Version handshake

`install.json` (schema 2) records `appVersion`, `sidecarVersion`,
`sourceRevision` and `bundleManifestSha256`. The app compares the engine's
reported `appVersion` with its own build and warns when a stale engine is
serving the configured endpoint; a differing major version or API schema is
still reported separately. The bundle manifest is also available beside the
installed app for support.

## Uninstall behavior

The installer creates a per-user uninstall entry under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetBuilderAI` and a
Start Menu uninstall shortcut. The default uninstall removes the app and keeps
`data`, `output`, `logs` and `config` for recovery; `uninstall.ps1 -Purge`
removes the whole folder. No step requires administrator rights.

## CI and release gate

A signed public build needs a code-signing certificate in CI. The tag-only
`windows-package` job in `.github/workflows/ci.yml` expects:

- `WINDOWS_CERT_PFX_BASE64` - the PFX file, base64 encoded;
- `WINDOWS_CERT_PASSWORD` - its password.

The job writes the PFX to the runner's temp folder, sets
`NETBUILDER_SIGN_PASSWORD`, and calls the builder with `-RequireSignature`.
Never commit the PFX or its password. The Android release job has an analogous
keystore gate.

Before a pilot release, require all of the following:

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze --fatal-infos`
- `flutter test`
- sidecar `python -m pytest -q`
- `verify_release.ps1 -RequireSigned`
- `test_install.ps1` and `test_upgrade.ps1` on the final package
- the clean-VM checklist in `CLEAN-VM-TEST.md`
