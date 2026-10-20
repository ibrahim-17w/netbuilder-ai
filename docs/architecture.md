# Architecture

NetBuilder is two processes and one local store:

```
Flutter app (Dart)
  lib/screens, lib/services, lib/models
        |
        | HTTP over 127.0.0.1 only
        v
Python engine (sidecar/pt_autopilot.py)
  planner, executor, Packet Tracer automation, .pkt codec
        |
        v
Packet Tracer / GNS3 / Cisco SSH / AWS (user-selected target)

Flutter app <-> local SQLite (memory, chat, rules, history)
Flutter app <-> OS secure storage (provider keys)
```

The app is useful without the engine: planning, the offline assistant, subnet
math and on-device `.pkt` compilation do not require Python or Packet Tracer.
The engine adds live automation and the desktop autopilot.

## Startup

`main.dart` paints the shell first. A `StartupCoordinator` loads these in
parallel, each with its own deadline:

- `settings.load()`
- `memory.init()`
- `PktBuildJobService.instance.loadHistory()`
- `AppVersion.load()`

A slow keychain or a locked database becomes a visible "reduced startup"
banner with safe defaults. Screens that need memory (chat, saved networks,
memory) listen for the store becoming ready and reload once; they do not
silently stay empty because they mounted first.

The engine is independent of this sequencing. A missing engine is a state the
UI reports, not a launch failure.

## Request path

1. **Parse and plan.** `NetworkIntent` and the planner turn language into
   nodes, links, addressing and routing. Local validation runs before any file
   is written or device is touched.
2. **Budget context.** `ContextBudget.plan` chooses the turns and fixed blocks
   that fit the runtime window. The plan is built against
   `min(user budget, real runtime window)`, so a 4k runtime is never handed a
   256k request.
3. **Answer.** `ProviderChatService` talks to the configured provider (Gemini
   or an OpenAI-compatible endpoint), or the offline assistant answers locally
   when there is no key.
4. **Build.** The on-device `.pkt` builder writes a Packet Tracer save from
   bundled templates. The desktop engine can also drive Packet Tracer and
   verify each action on screen.
5. **Verify.** The generated file is read back and compared with the plan.
   A step that cannot be verified is reported as unverified, not claimed.

## Memory and privacy boundaries

- `lib/services/memory_service.dart` owns the SQLite store. It is local and
  per-user; do not put it on a shared network drive.
- `lib/services/settings_service.dart` owns provider settings and the canonical
  loopback check, `SettingsService.isLoopbackEngineBase`.
- Provider keys are read from OS secure storage only when the engine is
  loopback. They are never sent to a remote engine and never written to logs.
- `CredentialRedaction` is the last choke point for error text, diagnostics
  and copied reports.
- `AppDiagnostics` writes a rotating local log under the app support directory
  and installs `FlutterError.onError` plus `PlatformDispatcher.onError`.
  Diagnostics exports include that log and are redacted again by the sidecar.
- Release Android builds keep cleartext traffic disabled. The debug manifest
  may allow local HTTP for development only.

## Code map

| Area | Where |
| --- | --- |
| App shell, routing, startup | `lib/main.dart`, `lib/services/startup_service.dart` |
| Plans and validation | `lib/models/network_intent.dart`, `lib/services/validator_service.dart` |
| Chat and context | `lib/screens/chat_screen.dart`, `lib/services/chat_service.dart`, `lib/services/context_budget.dart` |
| Provider transport | `lib/services/ai_provider.dart`, `lib/services/provider_chat_service.dart` |
| Local memory | `lib/services/memory_service.dart` |
| On-device `.pkt` | `lib/services/pkt/`, `sidecar/pkt_template_build.py` |
| Python engine | `sidecar/pt_autopilot.py` (HTTP routes, planner, executor, automation) |
| Packaging and CI | `packaging/`, `.github/workflows/ci.yml` |

`chat_screen.dart` and `pt_autopilot.py` are still large. The decomposition
direction is leaf-first: chat has already moved its composer, typing bubble
and jump-to-latest pill into `lib/widgets/`. The intended sidecar split is
`routes/`, `planner/`, `executor/`, `catalog/`, `llm/` and `pkt/`, one
extraction at a time, without changing the CLI or process behavior.

## Tests

- `flutter test` - app unit, widget and golden tests.
- `flutter analyze --fatal-infos` - analyzer gate.
- `dart format --output=none --set-exit-if-changed .` - formatting gate.
- `cd sidecar && python -m pytest -q` - engine tests.

CI runs the app suite and a release build on Linux and Windows, the sidecar
suite on Linux and Windows, a debug APK on pull requests, and a signed APK
for `v*` tags.
