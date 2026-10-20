# NetBuilder AI

A local-first network builder: describe a lab in plain language and the app
turns it into a validated plan, compiles it into a real Packet Tracer `.pkt`
offline, and can drive Packet Tracer or talk to GNS3 to build and verify the
topology step by step.

It works with **no API key at all** - planning, the offline assistant, subnet
math and `.pkt` compilation all run locally. A Gemini key is optional and only
adds model-written chat answers on top.

## Quickstart

Requirements: Flutter 3.44 (Dart ^3.12). The Packet Tracer autopilot and the
local engine need Windows and Python 3; see the
[supported configuration matrix](docs/supported-configurations.md).

```powershell
flutter pub get
flutter run -d windows
```

To run the local engine by hand instead of letting the app start it:

```powershell
pip install -r sidecar/requirements.txt
python sidecar/pt_autopilot.py
```

The app normally starts and stops its own engine and shows its state in the
top bar. The Windows installer scripts live in `packaging/`.

### Optional: a model key

Settings > model key. Keys are stored in the OS secure storage, never in logs
or diagnostics. Without a key the app stays fully usable: chat falls back to
the offline assistant and says so.

## What you can do

- **Plan in a sentence.** "2 routers, 2 switches and 50 PCs with OSPF" becomes
  a validated plan you can explain, edit and build.
- **Build offline.** "Build the .pkt" writes a real file with no Packet
  Tracer window, then reads it back and reports whether it matches the plan.
- **Use the optional autopilot.** With Packet Tracer installed, the local
  Python sidecar drives the window and verifies each step on screen. It is
  fail-closed: a step it cannot prove is reported, never assumed.
- **Keep the knowledge.** Rules, phrasings, preferences and repair history
  live in a local database you can review, teach and forget.
- **Choose a target.** GNS3, Cisco over SSH, Packet Tracer and AWS VPC.
- **Get advice.** Ask design questions ("how many access points for 50
  users?") and get a recommendation with trade-offs, not just a build.

## Documentation

- [Architecture](docs/architecture.md) - how the app, engine and memory fit
  together, and where the security boundaries are.
- [Troubleshooting](docs/troubleshooting.md) - engine, startup, database and
  autopilot failures, plus where the local logs are.
- [Supported configurations](docs/supported-configurations.md) - platforms,
  providers and what is deliberately unsupported.
- [Contributing](CONTRIBUTING.md) - setup, test commands and PR rules.
- [Security](SECURITY.md) - reporting and privacy guarantees.
- [Changelog](CHANGELOG.md) - what changed.

## Privacy

- Memories, transcripts and rules stay in the local SQLite store.
- API keys stay in OS secure storage. The local engine receives provider
  settings only over loopback and keeps the key in memory. A remote engine is
  refused so a key cannot be shipped to another host.
- Diagnostics are local-only and redacted; exporting them is a deliberate
  action, and screenshots are opt-in.
- Phones build `.pkt` files on-device. Remote engine control is experimental
  and unsupported.

## License

MIT - see [LICENSE](LICENSE).
