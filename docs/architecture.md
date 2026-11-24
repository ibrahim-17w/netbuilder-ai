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

1. **Interpret and reconcile.** The source-mapped request reader produces typed
   requirements, exclusions and operations. `RequestCoordinator` merges project
   constraints and applies supported edits to a candidate, preserving the prior
   plan when a clause, reference or operation cannot be resolved. Read-only
   questions do not become new design requirements.
2. **Check coverage.** `CoverageChecker` compares exact/bounded inventory,
   names/models, scopes, subnets, service roles and preservation requirements.
   `BuildReadiness` combines this with validation and explicit target support.
   Model, generation, saved-file read-back and live-check capabilities are
   independent; unknown policy support is not assumed.
3. **Assist only when needed.** The configured provider may propose a bounded
   structured interpretation for an unresolved supported edit. Closed-schema,
   source-span, scope, value and exclusion checks run locally, with at most one
   repair. Proposals are revalidated at the coordinator boundary; ordinary
   answer generation cannot execute them. Clear offline requests need no key.
4. **Budget the real request.** `SessionState.mandatoryRequestContext()` retains
   requirements/exclusions, active scope, actions and pending questions.
   `ContextBudget` fits optional history around those mandatory blocks and the
   runtime window. The transport uses the budgeted system text and checks each
   tool round; an oversized mandatory request is refused, not truncated.
5. **Persist and present one outcome.** The plan and `RequestOutcome` share the
   existing session save boundary. `RequestOutcomeCard` renders recorded facts,
   actual diffs, provenance and separate planning/file/live statuses. Corrections
   are explicit turns through the same coordinator, bound to the displayed
   project, revision and fact identity.
6. **Build the bound snapshot.** `.pkt` readiness uses Packet Tracer capabilities,
   not an unrelated chat export target. `BuildActionIdentity` covers project,
   semantic/build revision, requirement digest, site/scope, layout and output.
   The existing job service deduplicates identical active requests and rejects
   conflicting ones; per-run tokens guard late callbacks.
7. **Audit actual saved bytes.** Engine and on-device readers normalize observed
   device, interface/mask, service-flag, link and position evidence. Artifact
   SHA-256 is computed from the same bytes decoded. A missing field is unverified,
   an observed discrepancy is a mismatch, and a replaced file or stale action
   invalidates prior proof while retaining its history. Generator reports and
   live network checks remain separate.

Attachments are data, not instructions. Explicit explain/compare/import/edit/
build-from intent is required. OCR records original-byte identity and uncertainty;
critical unreadable values require confirmation. Packet Tracer imports retain
observed imported provenance rather than relabeling inferred defaults as user
facts or verified evidence. Legacy sessions remain readable without fabricated
provenance.

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

## Learned knowledge (offline replay)

Answers a keyed model gave to a question-shaped ask are kept so the app can
answer offline later. Two tiers, both local:

1. **Exact replay** - `lib/services/learned_answers_service.dart` +
   the `learned_answer` table. "Same question, same answer": the normalized
   question is the key, the answer replays verbatim. Capture is picky
   (refusals, error stubs, out-of-scope asks and computable-fact conflicts
   are never stored), and repetition across independent answers confirms.
2. **Concept knowledge** - `lib/services/concept_knowledge.dart` +
   the `knowledge_concept` table (schema v13). The same learning, filed
   under the THING the question is about via a curated alias dictionary, so
   a differently-worded ask retrieves it with an honest confidence tier:
   alias-anchored hits answer directly, token-overlap hits are phrased as
   qualified, and a question naming two concepts of which only one is known
   is answered partially - the known part explained, the missing part named
   as missing, never invented. Contradicting answers become `conflict` rows
   for the user to resolve in Memory > Q&A; stored knowledge is never
   silently overwritten.

Rules both tiers share: stored answers are TEXT replayed into the chat -
nothing parses or executes them, and nothing feeds them to the planner;
every entry carries its source and verification status, shown in the answer's
provenance line and editable/deletable in the Memory screen; the app never
enables search grounding and never trains on outputs, so retention stays the
user's own local replay with attribution.

## Code map

| Area | Where |
| --- | --- |
| App shell, routing, startup | `lib/main.dart`, `lib/services/startup_service.dart` |
| Plans and validation | `lib/models/network_intent.dart`, `lib/services/validator_service.dart` |
| Chat and context | `lib/screens/chat_screen.dart`, `lib/services/chat_service.dart`, `lib/services/context_budget.dart` |
| Provider transport | `lib/services/ai_provider.dart`, `lib/services/provider_chat_service.dart` |
| Engine model calls | `sidecar/model_gateway.py` (in-process Respan Gateway), `sidecar/pt_autopilot.py` (`_llm_request`) |
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
