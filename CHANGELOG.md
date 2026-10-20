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
- Architecture, troubleshooting, supported-configuration, contributing and
  security documentation.

### Changed

- Extracted the chat composer, typing bubble and jump-to-latest pill into
  reusable widgets. Behavior and widget keys are unchanged.
- Applied `dart format` across the Dart tree and fixed the analyzer infos it
  exposed.

## 1.0.0 - 2026-10-20

- Initial release: local-first planning, offline assistant, on-device `.pkt`
  compilation, GNS3/Cisco/Packet Tracer targets, local memory, and the
  optional Packet Tracer autopilot.
