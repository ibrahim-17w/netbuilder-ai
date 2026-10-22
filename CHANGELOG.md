# Changelog

## Unreleased

### Added

- Startup coordinator that paints the shell before settings, memory, build
  history and app version finish loading, with per-subsystem deadlines and a
  visible readiness/degraded banner.
- Screens reload once the local memory store becomes ready, instead of
  staying empty when they mounted first.
- Rotating, redacted local app log with `FlutterError.onError` and
  `PlatformDispatcher.onError` capture. The existing diagnostics archive now
  includes the app log alongside the sidecar journal.
- Windows stale-process cleanup helper
  (`tool/clean_windows_build.ps1`) for locked `sqlite3.dll` builds.
- Transient database-lock retry with a clear "close other NetBuilder windows"
  message; a live store is not moved aside as if it were corrupt.
- Windows Flutter tests, Windows sidecar pytest, a PR debug APK build, pinned
  Flutter/tool version logging, explicit formatting/analyzer gates, and a
  tagged signed-release APK workflow.
- A packaged Windows release smoke test and a named Linux golden-corpus gate
  in CI.
- Architecture, troubleshooting, supported-configuration, contributing,
  dependency and security documentation.
- Signed Windows packaging with a per-user installer, portable ZIP,
  bundle/release manifests and `SHA256SUMS.txt`.
- Per-user uninstall entry and Start Menu shortcut, with data-preserving
  uninstall by default and a `-Purge` mode.
- Clean-install and upgrade-preserves-data tests, plus a clean-VM checklist.
- A pilot kit with scripted tasks, metrics definitions and a scorecard
  summarizer.

### Changed

- Extracted the chat composer, typing bubble, jump-to-latest pill, rule,
  slot-fix and in-conversation search widgets. Behavior and widget keys are
  unchanged.
- Context budgeting runs on a background isolate for real launches, keeping
  the 400-turn planning walk off the frame that sends a model request.
- Extracted sidecar credential redaction and the Packet Tracer device catalog
  into leaf modules; all existing names and call sites are preserved.
- Upgraded `cupertino_icons` to 2.x and staged `flutter_secure_storage` 10.3.1
  so its first run migrates keys before the v11 move.
- Applied `dart format` across the Dart tree and fixed the analyzer infos it
  exposed.

## 1.0.0 - 2026-10-20

- Initial release: local-first planning, offline assistant, on-device `.pkt`
  compilation, GNS3/Cisco/Packet Tracer targets, local memory, and the
  optional Packet Tracer autopilot.
