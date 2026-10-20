# Contributing

Thanks for helping. NetBuilder is safety-sensitive: a wrong plan or an
unverified autopilot step can change a real lab, so the project prefers small,
provable changes over large rewrites.

## Setup

```powershell
flutter pub get
pip install -r sidecar/requirements.txt
```

Open the app with `flutter run -d windows`. The app starts its own engine; you
can also run `python sidecar/pt_autopilot.py` by hand when debugging the
sidecar.

## Before opening a pull request

Run all of these from the repository root unless noted:

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos
flutter test
cd sidecar
python -m pytest -q
```

If a Windows build is blocked by a stale `sqlite3.dll`, run:

```powershell
powershell -ExecutionPolicy Bypass -File tool/clean_windows_build.ps1 -Force
```

Add or update tests with the change. UI changes need a widget test unless the
change is purely visual and is covered by an existing golden. Security-relevant
changes need a test that proves the refusal or redaction, not just a comment.

## Pull request shape

- **One extraction per PR.** Moving a widget, a service or a sidecar subsystem
  out of a monolith should not also change behavior. Keep the old public
  behavior and widget keys; let tests prove the move.
- **One dependency major per PR.** `file_picker`, `flutter_secure_storage`,
  `share_plus` and similar upgrades are separate from feature work and include
  a platform smoke test.
- **No behavior changes hidden in formatting.** Mechanical formatting is its
  own commit or PR.
- **Security boundaries do not widen casually.** The engine stays on
  `127.0.0.1`; provider keys never leave the loopback engine; release
  cleartext stays disabled; diagnostics stay redacted.
- **Version source stays `package_info_plus`.** Do not add a second hard-coded
  release number.

A PR description should say what changed, what did not change, which commands
were run, and which platforms were exercised.

## Code style

- `dart format` is the formatter; `flutter analyze --fatal-infos` is the gate.
- Prefer a small widget with data and callbacks over reaching back into a
  screen's state. The composer and chat presence widgets are the pattern.
- Keep comments about *why*, especially where a safety rule or an estimation
  choice is not obvious.
- Never log API keys, passwords, raw configurations or full provider
  responses. Use `CredentialRedaction` before writing error text.
- Do not add secrets to fixtures. Use obviously fake values.

## Tests and CI

CI runs on Linux and Windows, plus a debug APK on pull requests and a signed
APK for `v*` tags. The tag job requires these repository secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Without them a tagged release fails on purpose; a release must not silently
ship with the debug key. Local builds without `android/key.properties` still
use the debug signing config.

## Reporting security issues

Do not open a public issue with a key, password or a reproducible credential
leak. Follow [SECURITY.md](SECURITY.md).
