# NetBuilder AI — tester build & handoff notes
Build date: 2026-09-21  ·  App version: 1.0.0+1  ·  Sidecar version: 2026-09-20-offline-planner-wording

## 1. What changed in this build

1. **Composer overlap fixed (the reported bug).** The floating PAUSE / STOP
   buttons were rendered by `lib/main.dart` on the Chat tab and the build
   workspace, where the composer's Send button lives in the same bottom-right
   corner — so they covered it. Run controls are now:
   - **in the chat header** (a `Run:` row with Pause and Stop), and
   - **not floated at all** on the Chat tab / workspace (floats remain only on
     Analyze and PKT Files, which have no composer).
   `lib/main.dart`, `lib/screens/chat_screen.dart`.
2. **Enter now sends; Shift+Enter adds a line.** The composer TextField is
   wrapped in `CallbackShortcuts` (Enter / numpad-Enter -> send) and uses
   `TextInputAction.send` so an Android soft keyboard shows a Send key.
   `lib/screens/chat_screen.dart`.
3. **Responsive fix found by the new tests.** At a 360 px width the chat
   header's second row overflowed by 14 px, and at 360x640 the empty-state
   column overflowed by 11 px. The header now stacks below 420 dp and the
   empty state scrolls. `lib/screens/chat_screen.dart`.
4. **Android packaging fix.** `file_picker 8.3.7` compiles against android-34
   while `flutter_plugin_android_lifecycle` now requires compileSdk >= 36, so
   `assembleRelease` failed its AAR metadata check. Every Android subproject is
   now raised to compileSdk 36 (no dependency churn):
   `android/build.gradle.kts`, `android/app/build.gradle.kts`.
   Also added `INTERNET` permission, `usesCleartextTraffic`, and set the app
   label to `NetBuilder AI` in `android/app/src/main/AndroidManifest.xml`.
5. **Windows sidecar bundle now includes the RPA deps.** `packaging/build_installer.ps1`
   only installed PyInstaller, so the bundled sidecar reported `rpa: false`
   (no pyautogui/pynput). Installing `sidecar/requirements.txt` before the
   PyInstaller step fixes that; see section 4.

## 2. Artifacts (where the files are)

| Artifact | Path | Size | SHA-256 |
|---|---|---|---|
| Windows installer | `C:\ai\app\dist\NetBuilderAI-Tester-Setup.exe` | 100.7 MB | `20F22A9647A965C37901A365F69C0E4428B4C400A2A652DDFC79F78D99BEF7E8` |
| Android APK | `C:\ai\app\dist\NetBuilderAI-Tester.apk` | 58.3 MB | `0EB6F8D9004501FB7B656ABAFA3D2AEE22ECE8E948B270811CF73A5F5A223995` |

Build identifiers:
* App `1.0.0+1` (`versionCode 1`, `versionName 1.0.0`), applicationId `com.netbuilder.net_builder`
* Android: `compileSdk 36`, `minSdk 24`, `targetSdk 36`, debug-signed
* Sidecar: `pt_autopilot.py` `VERSION = "2026-09-20-offline-planner-wording"`
* Toolchain: Flutter 3.44.0 · Dart 3.12.0 · AGP 9.0.1 · Gradle (Flutter default) · JDK 17 · VS Build Tools 2026

### How to install / sideload

* **Windows:** run `NetBuilderAI-Tester-Setup.exe`. It extracts to
  `%LOCALAPPDATA%\NetBuilderAI` and launches the app; it starts its own
  bundled sidecar (no Python needed). Uninstall = delete that folder.
* **Android:** `adb install -r NetBuilderAI-Tester.apk`, or copy the APK to the
  phone and open it (allow "install unknown apps"). Launch as **NetBuilder AI**.

## 3. Verification performed (evidence)

| Check | Command / method | Result |
|---|---|---|
| Static analysis | `flutter analyze` | No issues found |
| Unit + widget tests | `flutter test` | 116 passed (6 new composer tests) |
| Sidecar tests | `py -3.14 -m pytest -q` (in `sidecar/`) | 368 passed, 1 known pre-existing failure (`test_ocr_perf` golden OCR, tesseract/env) |
| No overlap at narrow width | widget test, 360x640 | no overflow; Pause/Stop/Send all present |
| No overlap at wide width | widget test, 1600x900 | no overflow |
| Enter sends | widget test + real Android | composer cleared, message bubble added |
| Shift+Enter | widget test | does not send |
| Windows install | run the installer, then `GET /health` | files installed to `%LOCALAPPDATA%\NetBuilderAI`; sidecar healthy `ok:true` |
| Android install | `adb install -r` on a Pixel 7 emulator | `Success`; launched `com.netbuilder.net_builder/.MainActivity` |
| Android UI (real device) | `uiautomator` node bounds on the Chat tab | `Send [922,1970]-[1049,2096]`; `Pause [96,582]-[201,687]`; `Stop [201,582]-[306,687]` -> no intersection |
| APK metadata | `aapt dump badging` | `package=com.netbuilder.net_builder`, `sdkVersion 24`, `targetSdkVersion 36`, `INTERNET`, label `NetBuilder AI` |

## 4. How to rebuild from a clean checkout

Prerequisites: Flutter 3.44+ (windows desktop enabled), Visual Studio Build
Tools, Android SDK (platform 36 + build-tools + JDK 17), Python 3.13 on PATH,
and the Android licences accepted (`flutter doctor --android-licenses`).

### Windows installer
```powershell
cd C:\ai\app
python -m pip install -r sidecar\requirements.txt   # RPA deps for the bundle
python -m pip install pyinstaller
powershell -ExecutionPolicy Bypass -File packaging\build_installer.ps1
# -> dist\NetBuilderAI-Tester-Setup.exe
```
`-SkipFlutterBuild` reuses an existing `build\windows\x64\runner\Release`.

### Android APK
```powershell
cd C:\ai\app
flutter build apk --release
# -> build\app\outputs\flutter-apk\app-release.apk
Copy-Item build\app\outputs\flutter-apk\app-release.apk dist\NetBuilderAI-Tester.apk -Force
```

## 5. Known limitations

* **Android has no sidecar.** There is no Python/Packet Tracer on the phone, so
  PT Autopilot, live audit and `.pkt` generation are unavailable there. The
  offline planner, validator, config export, memory and the offline chat
  assistant all work without it.
* **The APK is debug-signed.** Fine for sideloading/testing; publishing to Play
  needs a release keystore (explicitly out of scope).
* **Live Packet Tracer automation on Windows** needs Packet Tracer installed and
  an API key is not required for planning, but the Gemini planner/chat upgrade
  is BYOK and optional.
* The `test_ocr_perf` sidecar test fails on this machine because its recorded
  golden OCR text depends on the local Tesseract build; it is pre-existing and
  unrelated to these changes.

## 6. How to report issues

Send: what you did, what you expected, what happened, and a screenshot.
Memory > Tester diagnostics produces a redacted report (no API keys, passwords,
raw configs, `.pkt` files or screenshots by default).
