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
| Packet Tracer | Windows desktop installation with a visible window for autopilot; exact version recorded by native verification |
| GNS3 | Current 2.x server with its API reachable |

The exact Packet Tracer build varies by installation. Bundled device templates
and save-format/version metadata are not a compatibility promise. There is **no
cross-version guarantee**: a native result applies only to the recorded Packet
Tracer version, exact saved bytes and build action. Offline decoder/fixture tests
do not establish that a generated file opens in Packet Tracer or works there.
The autopilot reports actions it cannot prove rather than guessing success.

### Packet Tracer evidence stages

- **Generated** records creation of the file, not target acceptance.
- **File read-back checked** records a bound read of the saved bytes, not a
  native Packet Tracer open or live network result. Request-delivery comparisons
  remain separate and can still report missing or mismatched fields.
- **Opened in Packet Tracer** requires native evidence for the current file and
  action, including matching loaded-file/topology evidence and the exact version.
- **Connectivity tested** is independent of opening the file. Only actual
  completed native probes with evidence count as passes; skipped/manual checks
  leave coverage partial, and no tests means NOT CHECKED.

A running report is not complete even if it contains tests. Reports are tied to
an explicit run ID; missing file/action binding, stale bytes, stop, timeout, or
missing native proof must not become a pass. Legacy history without evidence
starts at NOT CHECKED. DHCP, HTTP, wireless association, routing/security
semantics and isolation stay manual/unverified unless separately evidenced.

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

## Request and evidence limits

- English, Arabic-Indic digits and a controlled set of Arabic/Syrian and mixed
  networking phrases are supported offline. Exact names, interfaces, addresses
  and quoted SSIDs remain literals; this is not a general translation service.
- A valid plan is not sufficient to claim that every explicit request is met.
  Exact counts/models, exclusions, scope and preserve constraints are checked
  separately; a declined alternative does not erase the original constraint.
- Arbitrary guest/staff isolation is unresolved without a faithful typed policy
  and evidence. Generic ACL/VLAN flags and probe timeouts do not prove isolation.
- Saved-artifact evidence covers fields actually observed by the decoder. Missing
  or ambiguous interface names, IPv6-only evidence, unobserved routing/security
  fields and automatic layout-style claims remain unverified. Offline file checks
  never establish live DHCP, adjacency, reachability or isolation.
- GNS3 hardware remapping does not satisfy an exact Packet Tracer model request;
  server Services-tab settings are not treated as a faithful GNS3 export.
  IOS configuration export does not provision or prove a hardware model.
- Optional model interpretation supports a closed subset of operations and is
  locally validated. Provider schema refusal, timeout, cancellation and malformed
  proposals retain the local interpretation. JSON-only endpoints receive the
  same local validation; no provider API migration or account setup is required.
- The OCR backend returns text without reliable confidence/coverage metadata.
  Critical values therefore require user confirmation before an image changes
  a project. Imported facts and uncertain readings keep their own provenance.
- Legacy projects without stored request provenance can be edited and inspected,
  but their history does not gain a retroactive full-delivery verification claim.

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
