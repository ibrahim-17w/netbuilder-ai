# Implementation log

This log records verified work against [PLAN.md](PLAN.md). A task card is
complete only when its focused acceptance criteria pass; integration and
manual release checks remain in T15.

## T00 — Baseline and harness

Status: complete

Behavior before: The review baseline had focused service coverage but no
semantic snapshot test for an answer-only turn. The repository also contained
substantial unrelated uncommitted roadmap and product work.

Behavior after: A fixed two-site semantic fixture and an explanation-turn
regression assert the complete plan snapshot remains unchanged. The baseline
and current Phase A regression results are recorded below. Existing
uncommitted work was preserved; no reset or cleanup was performed.

Files changed: `test/request_understanding/fixtures.dart`,
`test/request_understanding/baseline_test.dart`, and this log. The complete
continuation working-tree path inventory is saved in
`CONTINUATION-WORKTREE.txt`.

Baseline environment: branch `p3-product`; Flutter stable 3.44.0; Dart 3.12.0.
The earlier full-suite run before pending-context changes passed 2,753 tests.
The review's original focused command passed 96 tests.

Commands and results:

- Focused acceptance command from `ACCEPTANCE.md`: **96 passed**.
- `flutter test --no-pub test/request_understanding --reporter expanded`:
  **26 passed**.
- `flutter test --no-pub test/chat_ui_test.dart --reporter expanded`:
  **50 passed**.
- `flutter test --no-pub test/networking_help_reader_test.dart --reporter expanded`:
  **9 passed**.
- `flutter test --no-pub test/clarification_service_test.dart --reporter expanded`:
  **14 passed**.
- An earlier full suite run, before the final Phase A additions, passed
  **2,765 tests**. The current full-suite result is deferred to T15.
- `flutter analyze --no-pub --fatal-infos`: **no issues found**.
- `flutter test --no-pub test/request_understanding/baseline_test.dart`:
  included in the 26-test request-understanding result; unchanged semantic
  snapshot assertion passed.

Limitations: The 2,753-test result was produced after earlier Phase A code had
already landed in the working tree, rather than on a clean checkout. No live
provider smoke test or Windows integration run was performed.

## T01 — Protect explicit decisions from remembered preferences

Status: complete

Behavior before: A remembered OSPF preference could replace a current
explicit EIGRP choice.

Behavior after: Current explicit routing, device-scoped models, subnets,
service exclusions and design choices are protected before memory is applied.
Memory can still fill unrelated unspecified fields. An explicit EIGRP request
survives an unrelated printer edit, appears in the brief and generated Cisco
configuration, and leaves stored OSPF untouched. A scoped office answer is
replayed into a later office brief with its remembered origin visible in the
chat response. The R1 model/subnet case protects R1 while memory fills R2 and
its separate LAN.

Files changed: `lib/services/planner_memory_service.dart`,
`lib/services/clarification_service.dart`, `lib/screens/chat_screen.dart`,
`test/request_understanding/precedence_test.dart`,
`test/request_understanding/clarification_test.dart`, and
`test/chat_ui_test.dart`.

Acceptance evidence: A01–A04 are covered by deterministic precedence, brief,
Cisco rendering, follow-up, scoped-memory and UI provenance checks.

Limitations: No live provider smoke test or Windows/manual acceptance was
performed. The buildable candidate remains the deterministic local plan; a
provider's conversational wording is not treated as a plan mutation.

## T02 — Fix scale reconciliation and number roles

Status: complete

Behavior before: A scale answer could add the desired total, a technical
number could be mistaken for scale, and user load could be treated as device
inventory.

Behavior after: Scale answers distinguish user load from physical devices,
reject VLAN/model/interface/prefix numbers, and set a requested device total
without adding the total on top of existing devices. Later scale answers keep
an earlier routing choice. User-load answers preserve inventory, disclose
that capacity for the stated user count has not been verified, avoid assuming
one device per user, and ask whether the user wants to keep or resize the
inventory. Exact PC lists, one-router/no-dynamic-routing topologies, and
switch-only topologies avoid irrelevant scale/routing questions.

Files changed: `lib/services/clarification_service.dart`,
`lib/services/design_brief_service.dart`, `lib/models/design_brief.dart`,
`lib/screens/chat_screen.dart`,
`test/request_understanding/clarification_test.dart`,
`test/design_brief_service_test.dart`, and `test/chat_ui_test.dart`.

Acceptance evidence: A05–A09 and A37 are covered by service and widget tests,
including saved totals, fixed inventory, user-load facts, capacity wording,
number-role rejection and exact/switch-only topologies.

Limitation: The app does not calculate user-to-device or interface capacity
from a load figure. It says that capacity is unverified and asks the user how
to proceed.

## T03 — Consume answers together and reconcile atomically

Status: complete

Behavior before: A pending reply could be reparsed as a new design before the
clarification handler saw it. Pending IDs were not anchored to a project and
plan revision, and local answers could be written to global clarification
memory.

Behavior after: Clear answers to multiple pending questions are staged into
one candidate and persisted before live plan/brief state changes. Unanswered
questions remain open and rebind to the new revision. Pending context stores
question ID, project, base revision and property, with a decoder for legacy
ID-only sessions. Stale answers are rejected visibly. Unsupported answers and
failed saves leave the prior plan/brief/question state intact. Explanations
and what-if messages do not consume pending answers. A direct explicit
“remember OSPF for future office labs” request uses venue-scoped clarification
memory, while the preceding one-off OSPF answer remains local. Later office
plans show the remembered provenance.

Files changed: `lib/screens/chat_screen.dart`,
`lib/services/session_state.dart`, `lib/services/clarification_service.dart`,
`lib/services/networking_help_reader.dart`, `test/chat_ui_test.dart`,
`test/request_understanding/pending_context_test.dart`,
`test/request_understanding/clarification_test.dart`, and
`test/networking_help_reader_test.dart`.

Acceptance evidence: A10–A13, A38–A39 and A49 pass through multi-answer,
unanswered-question reopen, stale-context, what-if, explanation, explicit
scoped-memory, reconciliation-failure and persistence-failure checks.

Commands and results: The 96-test focused acceptance group, 26 request-
understanding tests, 50 chat UI tests, 14 clarification-service tests, 9
networking-help-reader tests, and `flutter analyze --no-pub --fatal-infos` all
pass. The current full-suite and manual/integration acceptance remain T15.

## T04 — Introduce the typed contract without changing behavior

Status: complete

Behavior after: Added immutable, versioned request and coverage records while
keeping `NetworkIntent` as the plan model. The contract represents source
spans, typed/scoped requirements, closed plan operations, change sets,
pending-question targets, typed issues/actions/preferences, categorical
reliability labels, requirement coverage/evidence and a single request
outcome. Decoding rejects unknown fields, enum values and future schema
versions. Legacy request and requirement payloads default to unknown
provenance rather than invented user decisions. Source excerpts and unresolved
text are redacted before serialization; spans validate their UTF-16 range
against the original text.

Files changed: `lib/models/request_contract_utils.dart`,
`lib/models/request_requirement.dart`, `lib/models/plan_operation.dart`,
`lib/models/request_coverage.dart`, `lib/models/request_interpretation.dart`,
and `test/request_understanding/models_contract_test.dart`.

Acceptance evidence: Round-trip, equality/copy, legacy defaults, malformed
enum/schema input, unknown operation payload keys, rejected raw secret fields,
secret redaction and span-bound tests pass. The models remain data-only; they
are not yet connected to chat planning or mutation.

Commands and results: `flutter analyze --no-pub --fatal-infos` reports no
issues; `flutter test --no-pub test/request_understanding --reporter expanded`
passes **34 tests**; the focused acceptance group passes **96 tests**; and
`flutter test --no-pub test/chat_ui_test.dart --reporter expanded` passes
**50 tests**. The full suite and manual/integration checks remain in T15.

## T05 — Implement requirements, scope and precedence

Status: complete

Behavior after: Added a deterministic requirement merger keyed by subject,
scope kind/identity and property. It keeps compatible bounds, deduplicates
retries, resolves explicit correction links, marks lower-precedence conflicts
superseded, and keeps equal-precedence contradictions unresolved with reasons
and redacted source excerpts. Invalid correction targets and correction
cycles are surfaced as conflicts. Scoped model, subnet, routing and service
exclusion requirements produce a memory-protection value for the existing
planner-memory adapter. The same merged requirements can populate supported
exact fields in the brief adapter while preserving source provenance.

Files changed: `lib/services/request_understanding/requirement_merger.dart`,
`lib/services/planner_memory_service.dart`, and
`test/request_understanding/requirement_merger_test.dart`.

Acceptance evidence: Tests cover routing precedence, current-turn conflict,
correction, correction cycles, deterministic retry, same-value deduplication,
project/device scope, compatible and impossible quantity bounds, forbidden
values, brief provenance, router model and subnet protection, and DNS
exclusions. The chat has not yet switched to constructing typed requirements;
T06/T08 provide that extraction and orchestration path.

Commands and results: `flutter test --no-pub test/request_understanding
--reporter expanded` passes **47 tests**; the focused acceptance group passes
**96 tests**; `test/offline_evolution_test.dart` passes **3 tests**; and
`flutter analyze --no-pub --fatal-infos` reports no issues. The full suite and
manual/integration checks remain in T15.

## T06 — Normalize with source mapping; reuse existing readers

Status: complete as of 2026-11-06; acceptance evidence is recorded in the
final T06–T08 completion entry below.

Behavior after: Added a source-mapped bridge normalizer using UTF-16 offsets.
Copied text, phrase replacements, expansions and deletions map back to the
original message. The interpretation adapter reuses the existing quantity
pipeline and Packet Tracer brief reader to attach evidence to explicit device
counts, increments, bounds, user loads, sites, routing, exclusions, names and
exact models. Opaque SSIDs and credentials, addresses, paths, interface names
and device labels are protected from ordinary phrase rewriting; excerpts use
the existing secret redaction boundary. Candidate count and routing operations
are emitted only when project and base revision identities are supplied.

Files changed: `lib/models/normalized_message.dart`,
`lib/models/network_intent.dart`, `lib/services/nlu/parser.dart`,
`lib/services/nlu/slots.dart`, and
`lib/services/request_understanding/normalizer.dart`.

At the first implementation checkpoint, acceptance suites had not yet been
run and the active chat path had not yet called this adapter. The later T08
integration wired it into the coordinator; Arabic, inventory, source-span and
multiline named-device cases passed in the 2026-11-06 focused and full runs.

## T07 — Apply typed edits and preserve unrelated design

Status: complete as of 2026-11-06; acceptance evidence is recorded in the
final T06–T08 completion entry below.

Behavior after: Added a deep-copy, typed operation applier with project/base
revision checks, duplicate-operation rejection, ordered edits, candidate
validation and preservation checks. It returns a commit-ready candidate and
sanitized full-plan change set only when every operation is supported and
valid; otherwise it exposes a held diagnostic candidate and typed issues, with
no commit-ready change set. Implemented inventory additions/totals, explicit
device removal and rename, routing/model changes, service assignment/removal,
IPv4/IPv6 edits on representable rows, exact link edits, layout-note edits and
project/device preservation checks. Dependent link/address/layout cleanup is
listed as incidental change data. Validation compares issue multiplicities so
a new duplicate finding cannot hide behind the same pre-existing message.

Files changed: `lib/services/request_understanding/operation_applier.dart`.

At the first implementation checkpoint, T07 behavioral cases had not yet
been run. The shared coordinator now invokes the applier for supported general
planning turns. Build actions carry both the semantic plan revision and a
`buildRevision` that includes saved layout notes and canvas positions, so
layout-only edits expire older build cards. Per-device VLAN membership remains
unrepresented. Site ownership now persists in `NetNode.siteId`; site-scoped PC
additions use the matching branch switch and subnet, while ambiguous branches
and unsupported site-scoped non-PC additions are held. Total reductions use a
deterministic removal policy, preserve explicitly locked devices, and hold
only when the removable inventory cannot satisfy the request.

## T08 — Share one coordinator and persist one outcome

Status at this implementation checkpoint: in progress. T08 was completed on
2026-11-06 after the full acceptance gate; see the final continuation below.

Behavior after: Added a UI-independent coordinator that source-maps the
current message, merges it with stored requirements, applies typed operations
to the current plan, and returns one candidate/disposition. A typed candidate
is accepted only when its semantic revision agrees with the existing network
reader; disagreement holds the full turn. The normal chat planning path now
uses the coordinator. Explicit memory defaults are applied before arbitration
for both provider and offline paths. Provider failure reuses the in-flight
candidate and does not parse/apply the same turn again. The interpretation,
merged requirements, change set, brief and redacted plan are saved in the
existing versioned session JSON. If the session write fails, the candidate is
rolled back; when storage is unavailable, the response labels the chat as
temporary.

The next T08 slice adds an ordered, deterministic reader for requested
Packet Tracer builds and configuration exports. The coordinator now keeps
action-only exports bound to the standing plan, refuses to use a parser
default when there is no saved plan or explicit device inventory, and stores
actions in source order with the interpretation. After the plan/session
snapshot is saved, chat runs supported outputs sequentially: a requested
build uses the committed revision, and configuration export renders through
the existing target adapter and saves a redacted `.txt` file. A failed build
does not suppress a later configuration export; each result is reported
separately. Clear output requests bypass the help-only parser route.

Files changed: `lib/services/request_understanding/request_coordinator.dart`,
`lib/services/request_understanding/requested_action_reader.dart`,
`lib/services/request_understanding/normalizer.dart`,
`lib/services/session_state.dart`, and `lib/screens/chat_screen.dart`.

At this implementation checkpoint, route parity, cancellation, persistence
failure, reopen and provider-fallback scenarios remained unverified. The
reader supports ordered build and configuration-export actions; other action
kinds are reported as unsupported. Specialized file, layout, named-design and
early help/action readers retain their existing paths, with their ownership
covered by route-parity tests. Later continuations added the remaining
acceptance and persistence evidence recorded below.

### 2026-11-04 continuation — route parity and offline request retention

Status: additional T08 work in place; the full T08 acceptance gate remains
incomplete.

Changes: Added a side-effect-free route selector shared by online parsing and
offline fallback for help-only turns and named-design, layout, and file-edit
ownership. The specialized readers still perform their existing work; early
command/config/lab handlers and a single route/outcome across all provider
modes have not yet been extracted. When the settings service is unavailable,
chat now runs the offline planner against the already selected candidate
instead of stopping after a provider error. Clarification replies repeat the
inventory already understood before asking about missing scale or routing.
For direct additions whose typed candidate lacks structural support rows,
the coordinator accepts only a matching legacy device delta, preserves every
base node/configuration/link/address, rewires onto free ports, allocates
unused host addresses from the attached router subnet, and validates that no
new blocking findings were introduced. A project display-name difference in
the temporary legacy candidate is ignored because the committed candidate
retains the base plan's name and identity.

Files changed in this continuation: `lib/services/request_understanding/request_coordinator.dart`,
`lib/services/request_understanding/request_route_selector.dart`,
`lib/screens/chat_screen.dart`, `lib/services/offline_assistant_service.dart`,
their request-understanding/offline tests, and the viewport setup for the
question-chip and small-talk widget tests.

Verification:

- `flutter test --no-pub test/request_understanding --reporter expanded` —
  **58 passed**.
- `flutter test --no-pub test/chat_ui_test.dart --reporter expanded` —
  **50 passed**, including the polite direct PC addition.
- `flutter test --no-pub test/offline_brief_note_test.dart --reporter expanded`
  — **10 passed**.
- Isolated widget checks for missing-provider build flow, question-chip fill,
  and greeting followed by a real plan — **1 passed each**.
- `flutter test --no-pub --reporter compact` — **2,805 passed** across the
  full Flutter suite.
- Final `flutter analyze --no-pub --fatal-infos` — **no issues**.

Remaining T08 gaps recorded at the prior checkpoint: extract early
specialized-handler selection without changing handler order; unify the
outcome envelope for provider-enabled, provider-failed, and offline-only
turns; test cancellation/late results, storage failure and reopen parity, and
stale action checks; report transcript and final session-write failures to the user;
complete A24–A34, A38–A39, A43–A44, A49, A52–A53, A57–A58. Do not mark T08
complete until these checks are evidenced.

### 2026-11-04 continuation — early handler route parity

Status: early route selection extracted; T08 remains incomplete.

Changes: Added a side-effect-free early selection result with the existing
small-talk fast path and ordered specialized-handler candidates. Chat executes
the same handlers in their existing order, with config-paste and lab-report
matches inserted at their prior positions. Stateful and asynchronous readers
still make their own ownership decisions when invoked. Edits still bypass the
early route, and greetings still bypass it only when no attachments are
pending.

Files changed: `lib/services/request_understanding/request_route_selector.dart`,
`lib/screens/chat_screen.dart`, and
`test/request_understanding/request_route_selector_test.dart`.

Verification:

- Focused route-selector tests — **9 passed**.
- `flutter test --no-pub --reporter compact` — **2,809 passed** across the
  full Flutter suite.
- `flutter analyze --no-pub --fatal-infos` — **no issues** after removing one
  import made unused by the extraction.

Next T08 work: unify the saved/returned outcome across provider-enabled,
provider-failed, and offline-only turns; then add acceptance coverage for
cancellation/late results, memory/database failure and reopen parity, stale
actions, and transcript/final-session write errors. Complete A24–A34, A38–A39,
A43–A44, A49, A52–A53, and A57–A58 before changing the T08 checklist.

### 2026-11-04 continuation — canonical outcome persistence

Status: the coordinator now serializes the canonical typed outcome; provider
transport parity and the broader T08 acceptance gate remain unverified.

Changes: `RequestCoordinatorOutcome` now exposes and serializes the existing
`RequestOutcome` contract, including the redacted candidate plan, change set,
clarifications, requested actions, and disposition. The interpretation stays
at the top level, so existing requirement recovery still reads the same
versioned session field. The live provider and offline fallback already share
the same in-flight coordinator result; the offline planner consumes its
candidate instead of reparsing. Added checks that offline database state and a
typed encode/decode round trip restore the same candidate revision as the
standing plan.

Files changed: `lib/services/request_understanding/request_coordinator.dart`,
`test/request_understanding/requested_action_reader_test.dart`, and
`test/chat_plan_persistence_test.dart`.

Verification:

- `flutter test --no-pub test/request_understanding/requested_action_reader_test.dart --reporter expanded` — **5 passed**.
- `flutter test --no-pub test/chat_plan_persistence_test.dart --reporter expanded` — **2 passed**.
- `flutter test --no-pub --reporter compact` — **2,809 passed** across the
  full Flutter suite.
- `flutter analyze --no-pub --fatal-infos` — **no issues**.

Remaining at that checkpoint: tests prove offline persistence and canonical
round-trip, but do not exercise a successful live provider response or an actual provider
failure transport. Next, add a deterministic provider seam and prove all
three modes use the same candidate/outcome, then cover cancellation/late
results, failed session writes and reopen/stale-action behavior. T08 remains
unchecked.

### 2026-11-04 continuation — provider outcome parity

Status: deterministic UI coverage now exercises provider success and failure
alongside the existing offline-only persistence checks; T08 remains
incomplete.

Changes: Added an optional provider-facade injection point to `ChatScreen` so
tests can drive the real send flow without network access. The provider-success
case and synthetic provider-failure fallback both assert that the saved
`RequestOutcome.candidatePlan` and `SessionState.intentJson` share a revision
and preserve the requested inventory. The no-key database-backed tests cover
offline-only execution and session encode/decode. This verifies the same
coordinator candidate survives all three modes without asking a model to
re-interpret or re-apply the network plan.

Files changed: `lib/screens/chat_screen.dart`, `test/chat_ui_test.dart`, and
this log.

Verification:

- `flutter test --no-pub test/chat_ui_test.dart --reporter expanded` — **52 passed**.
- `flutter test --no-pub --reporter compact` — **2,811 passed** across the
  full Flutter suite.
- `flutter analyze --no-pub --fatal-infos` — **no issues** after cleaning up
  one unused optional argument in the test settings helper.

Remaining T08 work: verify cancellation/late-result rollback, database and
final-session-write failure behavior, actual UI reopen parity, and stale
requested-action checks; report transcript write failures rather than
silently swallowing them. The provider tests use a deterministic injected
facade, not a live external service. Keep T08 unchecked until A24–A34,
A38–A39, A43–A44, A49, A52–A53, and A57–A58 are covered.

### 2026-11-04 continuation — cancellation and late-result isolation

Status: cancellation before the plan snapshot write restores the prior
candidate; a late provider stream cannot finalize an answer or alter a newer
turn. The explicitly requested plan remains committed once its snapshot write
starts successfully, even if Stop prevents the reply or requested follow-up
actions. T08 remains incomplete.

Changes: Added a generation check after conversation setup and before the
snapshot write. Stop now rolls back a coordinated candidate while the user
transcript is still being saved. Snapshot progress is tracked per active turn;
failed persistence still restores the prior plan. Late provider completions
are rejected before answer finalization, and old-turn cleanup cannot clear a
new turn's busy state or request outcome. Offline candidate consumption and
cleanup remain tied to the creating generation token. If Stop arrives while
the local plan snapshot write is already pending, the composer shows that save
is finishing and blocks a second send until it settles, preventing writes from
two turns racing each other.

Files changed: `lib/screens/chat_screen.dart`, `lib/widgets/chat_composer.dart`,
`test/chat_ui_test.dart`, and this log.

Verification:

- Three focused cancellation/late-stream UI tests — **1 passed each**.
- `flutter test --no-pub test/chat_ui_test.dart --reporter expanded` — **55 passed**.
- `flutter test --no-pub --reporter expanded` — **2,814 passed** across the
  full Flutter suite.
- `flutter analyze --no-pub` — **no issues**.
- `git diff --check` reported one existing trailing blank line at EOF in
  `test/secret_vault_test.dart`; that unrelated file was left untouched.

Remaining T08 work: verify database/session write failures and actual UI
reopen parity, revalidate stale requested actions after conversation changes,
and report transcript/final-session write failures clearly. The provider
coverage still uses a deterministic injected facade rather than a live
external service. Keep T08 unchecked until A24–A34, A38–A39, A43–A44, A49,
A52–A53, and A57–A58 are covered.

## Working-tree preservation

At the start of this continuation, `git status --short` showed extensive
pre-existing product and roadmap work, including app screens, models,
services, Windows runner/icon files, sidecar builders/audits, integration and
unit tests, and untracked blueprints/project-check/package features. The
captured path inventory is retained in `CONTINUATION-WORKTREE.txt`. This work
was preserved; no unrelated files were reset or cleaned.

### 2026-11-04 continuation — write failures, reopen parity, and expired build cards

Status: persistence failure handling now has provider, offline, and real-database UI coverage. A build card stamped for an older plan is visibly expired and offers no action. T08 remains incomplete.

Changes: A failed user-message write now stops the turn before planning or provider work. Candidate plan snapshot failures preserve the prior saved plan. Provider and offline replies report final session-state and transcript write failures instead of silently swallowing them. The SQLite-backed persistence test remounts the chat over the same database and checks that the saved plan is restored in the Network inspector. Stale build cards now take precedence over the network-design prompt, show the revision mismatch, and have no build, repair, or design-selection button.

Files changed: `lib/screens/chat_screen.dart`, `test/chat_ui_test.dart`, `test/chat_plan_persistence_test.dart`, and this log.

Verification:

- `flutter test --no-pub test/chat_ui_test.dart test/chat_plan_persistence_test.dart --reporter expanded` — **64 passed**.
- `flutter analyze --no-pub` — **no issues**.
- `flutter test --no-pub --reporter expanded` — **2,821 passed** across the full Flutter suite.

T08 remains unchecked. This slice does not complete the full A24–A34, A38–A39, A43–A44, A49, A52–A53, A57–A58 matrix; in particular, the ordered multi-output and partial-output failure behavior in A58 remains to be verified. Provider coverage remains deterministic and does not exercise a live external model transport.

### 2026-11-04 continuation — ordered multi-output request (A58)

Status: the mixed edit/build/export path now has an end-to-end UI check for partial success. The plan change commits first, the requested `.pkt` is built, and a later configuration-export failure is reported without erasing the build result.

Changes: Added an A58 widget scenario using the real on-device builder and a deliberately unavailable file-picker platform. It verifies the OSPF revision is saved, the `.pkt` exists, and the final report names build success before configuration-export failure. The fake memory store now supplies the build-history methods required by the build path, and the test removes its scratch output folder on teardown.

Files changed: `test/chat_ui_test.dart` and this log.

Verification:

- Focused A58 UI test after scratch-folder cleanup — **1 passed**.
- `flutter test --no-pub test/chat_ui_test.dart test/chat_plan_persistence_test.dart --reporter expanded` — **65 passed** before the cleanup-only teardown was added.
- `flutter analyze --no-pub` — **no issues**.
- `flutter test --no-pub --reporter expanded` — **2,822 passed** before the cleanup-only teardown was added.

T08 remains unchecked: this verifies the A58 partial-success direction (build succeeds, configuration export fails), but does not yet exercise the reverse partial-success direction or close the rest of the A24–A34, A38–A39, A43–A44, A49, A52–A53, and A57–A58 matrix. Provider behavior is still tested with a deterministic facade rather than a live model service.

### 2026-11-04 continuation — reverse ordered multi-output request (A58)

Status: both A58 partial-output directions now have UI coverage. When the
requested Packet Tracer build is cancelled before completion, the later
configuration export still runs and its successful result is reported after
the incomplete build result. T08 remains incomplete.

Changes: Added a test-only configuration export destination chooser so the UI
test can provide a deterministic path while exercising the same configuration
file writer used by the real save dialog. The test selects a layout, cancels
the `.pkt` build, allows configuration export to succeed, checks the saved
file contents, and verifies that the final report lists the incomplete build
before the successful configuration export. It also confirms the changed plan
was retained without claiming that a `.pkt` artifact exists.

Files changed: `lib/screens/chat_screen.dart`, `test/chat_ui_test.dart`, and
this log.

Verification:

- Reverse A58 cancellation/export UI test — **1 passed**.
- `flutter test --no-pub test/chat_ui_test.dart test/chat_plan_persistence_test.dart --reporter expanded` — **66 passed**.
- `flutter analyze --no-pub` — **no issues**.
- `flutter test --no-pub --reporter expanded` — **2,823 passed** across the full Flutter suite.
- Focused `git diff --check` for the changed app, test, and log files — **clean**; Git reported only an existing line-ending normalization notice for `test/chat_plan_persistence_test.dart`.

T08 remains unchecked. This closes the two A58 partial-output directions but
does not complete the other requested scenarios in A24–A34, A38–A39, A43–A44,
A49, A52–A53, and A57. Provider coverage remains deterministic and does not
exercise a live external model transport.

### 2026-11-04 continuation — advice, exploration, and layout-only requests (A24–A27)

Status: exact UI acceptance cases now cover advice-only, what-if, current-layout
preview, and layout-only rearrangement. A27 exposed a fallthrough that dropped
the chosen layout when the generic offline planner processed the same request
again; layout requests now bypass that second plan pass.

Changes: Added BASE-fixture chat checks for `why is OSPF better than static
routing?`, `could we do it with 40 PCs?`, `show me the layout`, and `only
rearrange the layout; keep all IPs and cables`. The advice and what-if preserve
the committed plan and its explicit static-routing requirement. The preview
opens on the saved drawing style and writes no plan snapshot. A layout-only
request now commits its layout note directly, preserves the node inventory,
address assignments, cable endpoints and routing, and returns without offering
a build. The no-artifact layout choice is persisted before the chat claims it
was saved; a failed snapshot restores the previous layout and plan.

Files changed: `lib/screens/chat_screen.dart`, `test/chat_ui_test.dart`, and
this log.

Verification:

- `flutter test --no-pub test/chat_ui_test.dart test/layout_request_test.dart test/request_understanding/request_route_selector_test.dart --reporter compact` — **116 passed**.
- Focused A27 rerun after adding explicit no-build assertions — **1 passed**.
- A27 persistence-failure rollback UI test — **1 passed**.
- `flutter analyze --no-pub` — **no issues**.
- `flutter test --no-pub --reporter compact` — **2,827 passed** across the full Flutter suite after the source change; the strengthened A27 assertions and persistence-failure test then passed focused reruns.

T08 remains unchecked. This closes the requested A24–A27 UI cases. The
remaining acceptance gaps include A28–A34, A38–A39, A43–A44, A49, and A52–A53.
The existing A57 direct-action and both A58 partial-output directions have
targeted coverage. Provider behavior remains deterministic and does not
exercise a live external model transport.

### 2026-11-06 completion — T06/T07 dependency gates and T08 acceptance

Status: T06, T07, and T08 are complete against their documented deterministic
acceptance gates. Their checklist entries are checked in `PLAN.md`.

T06 is connected to the active request coordinator. The source-mapped
normalizer preserves original excerpts, protects opaque values such as a
quoted SSID, and carries explicit Arabic/English inventory, quantity,
routing, exclusion, site and named-device evidence into the typed request.
The original inventory and parser regression suites pass. `NetNode.siteId`
now serializes site ownership so a reopened plan retains branch assignments.

T07 uses the typed applier and coordinator for supported narrow edits, with
atomic hold behavior when a target or operation is unresolved. A site-scoped
PC addition selects the matching site switch and subnet, allocates a free
port/address and retains all other-site devices; an ambiguous branch is held
without a candidate. Total reductions use a deterministic policy and honor
explicitly protected devices. Unsupported site-scoped non-PC additions and
per-device VLAN membership remain fail-closed boundaries.

T08's acceptance matrix is covered for A24–A34, A38–A39, A43–A44, A49,
A52–A53 and A57–A58. Coverage includes the two-file clarification, exact-plan
build, expired build actions after inventory and layout-only edits, duplicate
build suppression, stopped/late provider results, SQLite reopen of pending
clarifications, scoped remembered preferences, timeout fallback, project and
revision rejection, injected persistence failures, review-only configuration
handling, quoted OCR prompt-injection content, polite direct edits, and both
ordered multi-output partial-success directions. The SQLite reopen tests
compare the persisted plan, brief, request outcome and remaining clarification
contexts. Deterministic offline, provider-success and provider-fallback turns
produce matching plans and outcomes.

Build cards now stamp both the semantic plan revision and
`NetworkIntent.buildRevision`, which includes saved layout notes and canvas
positions. Changing only the drawing keeps the semantic revision stable but
expires the old build card. The UI withholds the action and the compile path
rechecks the stamp, so a stale card cannot silently build the new drawing.

Verification on 2026-11-06:

- Focused T06–T08 suites — **263 passed**.
- A32 inventory-change and layout-only stale-card checks — **2 passed**.
- Exact-plan A29 build check — **1 passed**; build-revision model test —
  **1 passed**.
- `flutter analyze --no-pub` — **no issues**.
- `flutter test --no-pub --reporter compact` — **2,881 passed**, exit code 0.
- The changed-file diff check is recorded separately from the unrelated
  existing trailing blank line in `test/secret_vault_test.dart`.

Provider behavior is verified through a deterministic injected facade; no
live external model transport was exercised. No manual Packet Tracer or
Android end-to-end session was run as part of these T06–T08 gates. These are
separate live/platform checks, not claims established by the automated suite.
