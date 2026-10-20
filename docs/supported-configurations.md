# Supported configurations

This is the support boundary, not a list of everything that might compile. A
configuration outside it may work, but it is not covered by CI or by the
security guarantees.

## Platform matrix

| Platform | App | Local engine | Packet Tracer autopilot | CI coverage |
| --- | --- | --- | --- | --- |
| Windows 10/11 x64 | Supported | Supported | Supported (visible desktop) | Windows tests + release build |
| Android | Supported | Not used | No | Debug APK on PRs; signed APK on tags |
| Linux x64 | Development/build supported | Sidecar tests supported | No (`pywinauto` is Windows-only) | Linux tests + release build |
| macOS | Not supported | Not supported for autopilot | No | None |
| iOS / web | Not supported | No | No | None |

Phones are standalone: planning, offline answers and `.pkt` compilation run
on-device. Remote engine control from a phone is experimental and unsupported.

## Toolchain

| Tool | Version |
| --- | --- |
| Flutter | 3.44.0 (pinned in CI) |
| Dart | ^3.12 (from `pubspec.yaml`) |
| Python | 3.12 for the engine |
| JDK | 17 for Android builds |
| Packet Tracer | Desktop 8.x with a visible window for autopilot |
| GNS3 | Current 2.x server with its API reachable |

The exact Packet Tracer build varies by installation. The autopilot verifies
each action against the screen and reports anything it cannot prove, so an
unexpected build is a reported failure rather than a guessed success.

## Providers and targets

| Capability | Supported |
| --- | --- |
| Offline assistant and planner | Yes, no key or network |
| Google Gemini | Yes, key stored in OS secure storage |
| OpenAI-compatible endpoint | Yes, key stored in OS secure storage |
| GNS3 | Yes, via the local engine |
| Packet Tracer offline `.pkt` | Yes, on desktop and phone |
| Packet Tracer autopilot | Windows desktop only |
| Cisco over SSH | Yes, target-dependent |
| AWS VPC / Terraform export | Yes, export only; credentials stay local |

## Security boundary

- The engine binds to `127.0.0.1`; there is no supported `0.0.0.0` or LAN
  binding.
- Provider keys are refused for a remote engine and are never written to logs
  or diagnostics.
- Release Android builds keep cleartext traffic disabled.
- Diagnostics are local-only and redacted; screenshots are opt-in.
- The local SQLite store is per-user. Network shares, roaming profiles that
  copy the file while the app is running, and multi-user shared installs are
  not supported.

## Deliberately unsupported

- Remote engine control as a supported workflow (it remains experimental and
  fails closed around credentials).
- Driving Packet Tracer without a visible desktop session.
- iOS and web builds.
- Multiple NetBuilder processes sharing one memory database.
- A release APK signed with a debug key. Tagged CI builds require the release
  keystore secrets; local builds fall back to debug signing for development.
