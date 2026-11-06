# NetBuilder: understand the request and deliver the requested result

Prepared 2026-11-03. This is an implementation specification for another AI.
No product changes are implemented by this document.

Read [EXECUTION.md](EXECUTION.md) for ordered task cards and the copyable
executor prompt. Read [ACCEPTANCE.md](ACCEPTANCE.md) for behavioral examples.

## 1. Product outcome and priorities

The user should be able to describe a network, correct it conversationally,
and receive a result that preserves every supported explicit requirement.
When an instruction is ambiguous, contradictory, impossible, or unsupported,
the app must identify that part instead of silently substituting a design.
Do not promise perfect comprehension of arbitrary language.

Implement these priorities in this order:

1. Fix existing precedence and clarification defects.
2. Give all request paths one typed interpretation and one commit decision.
3. Preserve exclusions, quantities, named devices, and unrelated plan fields.
4. Verify the requirements against both the plan and the produced artifact.
5. Improve Arabic, English, mixed-language, and unfamiliar phrasing.
6. Add optional model assistance behind the same deterministic checks.

Luna is the implementation assistant for this work. This does not require
adding Luna, or any particular model, as an application dependency.

## 2. Review findings grounded in this checkout

File paths below are relative to `C:\netbuilder`. Line numbers are navigation
hints for the reviewed checkout and will move during implementation.

| Finding | Evidence | Consequence / proposed change |
| --- | --- | --- |
| Explicit requests can lose to memory | `lib/services/planner_memory_service.dart`, `apply`, assigns routing and models after parsing without explicit-field protection | Add provenance-aware precedence before applying memory; do not infer explicitness from a field merely having a value |
| Scale reconciliation adds the desired total | `lib/screens/chat_screen.dart`, `_reconcilePlanWithFact` around 9088, creates `add $wanted pcs` | Separate load from inventory; for an established PC-sizing decision, target 40 from 10 means add 30, not 40 |
| Clarification answers are loosely matched | `lib/services/clarification_service.dart`, `_resolveScale`, accepts the first integer; `_resolvePendingClarification` in chat returns the first answer | Bind numbers to the question/quantity role, consume multiple clear answers, retain unresolved questions |
| The brief can diverge from the plan | `_reconcilePlanWithFact` returns null on errors and does not implement segmentation/security reconciliation; `_applyClarificationAnswer` can acknowledge a fact anyway | A resolved answer must either reach the candidate plan or remain visibly unresolved; no completed-looking decision on failure |
| Request handling is distributed | `_send` around 4485, `_appendOfflinePlan` around 5285, `NetworkIntent.followUp`, specialized readers | Preserve specialized readers, but arbitrate their results through one coordinator; avoid online and fallback parsing/mutating independently |
| Explanation has another extraction pass | `MessageUnderstanding.read` and the Understood card around chat line 8081 | Render actual interpretation data; stop reclassifying the message just to explain it |
| Much of the right infrastructure exists | `DesignBrief`, `BriefFact.rank`, `BriefSlotPipeline`, `SessionState`, `GenerationControl`, version history, validator, artifact audits | Extend these components; do not replace working capabilities with a second assistant stack |
| Structured model helper is not the active chat parser | `GeminiService.generateIntent` exists, but repository search found no call sites outside that service | Updating its prompt alone will not improve chat; connect a new typed extractor through the active provider/request path |
| Current audits primarily compare artifact with plan | `BuildPreflight.compare`, `test/semantic_verification_test.dart`, saved-file link evidence | Retain these checks and add requirement-to-plan coverage: a file matching a misread plan is still wrong for the user |
| Readiness and supported behavior already have contracts | `DesignBrief.criticalSlots`, `ClarificationService.neededFor`, validator and supported-configuration docs | Unify readiness around applicability and capability evidence; don't add a second conflicting build gate |

### Review verification

This review ran the following existing suites together with `--no-pub`:
`follow_up_plan_test.dart`, `clarification_service_test.dart`,
`design_brief_service_test.dart`, `tentative_language_test.dart`,
`intent_card_test.dart`, and `planner_rule_hygiene_test.dart`.
Result: **96 tests passed**. This is focused coverage, not a full-suite result.

Two diagnostic probes under the ignored `build/request-understanding-review/`
directory also passed, demonstrating the current behaviors to fix:

- Parse an explicit EIGRP request, then apply a remembered OSPF preference:
  routing becomes OSPF.
- Starting with 10 PCs, run the `add 40 pcs` follow-up currently constructed
  by scale reconciliation: the result has 50 PCs.

The second probe exercises the exact follow-up operation, not a full UI
clarification interaction. Add the UI regression during implementation.
The probes assert the old behavior and must not become acceptance tests.

The working tree already contains substantial modified and untracked work.
`docs/roadmap-implementation.md` records existing roadmap features and manual
validation boundaries. Preserve that work. None of the historical test counts
in that report substitute for testing the new implementation.

## 3. Desired request flow

```text
User message + attachments + current project snapshot
  -> normalize with original-text span mapping
  -> specialized readers propose interpretations (no side effects)
  -> coordinator resolves turn mode, references, facts and operations
  -> optional model proposes missing interpretations
  -> merge requirements using explicit source precedence
  -> apply typed operations to a candidate plan
  -> validate candidate + check requirement coverage + target support
  -> either ask a focused question, answer without editing, or commit once
  -> build the committed snapshot when the user requests that action
  -> audit actual output + attach evidence for each requirement
  -> explain what changed, what was delivered, and what remains unresolved
```

An explicit supported request should proceed without a new approval ritual.
Clarification is for missing decisions that would materially change the
result, not for asking permission to perform an already clear instruction.
Keep existing layout and other product decisions while migrating; unify
their applicability later rather than bypassing them.

## 4. Data contract to implement

These are new **proposed** types, not names of existing APIs. Implement only
the fields needed by the current task card, then extend them in order.
Use hand-written Dart serialization consistent with this repository; do not
add code-generation packages for this work.

### SourceSpan and normalization

- `SourceSpan`: `messageId`, `start`, `end` (exclusive), `excerpt`.
- Offsets use Dart string UTF-16 code-unit indexing in the original message.
- `NormalizedMessage`: original text, normalized text, and segment mapping
  from normalized ranges to original ranges. A mapping segment can represent
  a replacement, deletion, or expansion; do not assume one-to-one characters.
- Preserve line breaks and list structure for inventory/connection readers.
- Keep names, paths, CIDRs, interface names, SSIDs, and secrets intact.
- Do not persist or transmit a raw secret in an excerpt. Use a redacted
  excerpt plus existing secret-vault references at the privacy boundary.

### RequestInterpretation

- `schemaVersion`: initially 1.
- Identity: turn ID, conversation ID, project identity, base plan revision.
- `mode`: one of `social`, `explain`, `advise`, `compare`, `explore`,
  `create`, `edit`, `build`, `verify`, `export`, `undo`, `clarify`, `unknown`.
- Facts/requirements, typed operations, resolved reference, and unresolved
  fragments. Every fact and operation has provenance and source spans.
- `pendingQuestions`: IDs plus target fact/operation, not only question text.
- `issues`: typed conflict, ambiguity, unsupported, invalid, or missing input.
- `mutationPolicy`: `none`, `candidateOnly`, or `commitIfValid`.
- `requestedActions`: ordered follow-on actions and requested deliverables,
  such as build, export configuration, and export `.pkt`. Each records its
  target, dependencies and requested output options. This allows "change
  routing to OSPF, build it and export the configs" in one turn.
- `responsePreferences`: requested language, brevity, output format and
  explanation preference. These control presentation, never validation.
- Categorical reliability information: exact extraction, rule inference,
  model proposal, unresolved. Do not use a model's self-reported confidence
  percentage as permission to mutate or execute.

### Requirement

- Stable ID; typed subject and property; typed value; quantity role/unit.
- Comparator: `equals`, `atLeast`, `atMost`, `forbidden`, `preserve`.
- Scope: project, site, device, link/interface, VLAN, service, or output.
- Origin: current explicit user instruction, established project decision,
  scoped remembered preference, environment profile, derived/default.
- Source turn/span, state (`active`, `superseded`, `unresolved`), and the
  requirement ID replaced by a correction if applicable.
- Strength: explicit requirement versus advisory preference. An explicit
  "do not add devices" is hard even when the parser would prefer more ports.
- Phase: planning, artifact, or live verification.

Start with typed properties for device counts/models/names, routing,
subnets, server roles, excluded types/services, and preservation. Add policy,
wireless, layout, and export properties in subsequent task cards.
Do not create a generic expression language or interpret arbitrary code.
Keep an unknown user clause as unresolved text, never as silently fulfilled.

### PlanOperation and PlanChangeSet

Use a closed operation enum with validated payloads:
`addDevices`, `setDeviceCount`, `removeDevices`, `renameDevice`,
`setRouting`, `setDeviceModel`, `assignService`, `removeService`,
`setAddress`, `setVlanMembership`, `setLink`, `setLayout`, `preserve`.
Operations needing missing domain support remain unresolved until supported.

Each operation carries source requirement IDs and an explicit scope. A count
change needs a device kind, count, and site/global scope. A service assignment
needs the resolved device identity and role; "another server" implies a
distinct server from the one already assigned in that clause.

`PlanChangeSet` contains base/candidate revisions, the ordered operations,
old/new values, incidental changes, and reasons. Operations apply to a deep
candidate copy and are deterministic. Dependent changes needed for validity
(e.g. gateway updates when a subnet changes) are explicit in this change set.
Unrelated data is preserved by default.

Use these initial payloads so execution does not invent incompatible shapes.
All operations also carry `operationId`, `requirementIds`, `sourceSpans`,
`projectId`, and `baseRevision`. Canonical device/service tokens come from
the existing domain vocabulary, not user-facing synonyms.

| Operation | Required payload | Preservation / failure rule |
| --- | --- | --- |
| `addDevices` | `kind`, positive integer `count`, explicit `siteId` or global scope, optional exact names | Add the delta; keep existing identity/configuration; duplicate exact names are an error |
| `setDeviceCount` | `kind`, nonnegative integer `total`, explicit site/global scope | Use a deterministic generated-device policy; never remove named/protected devices arbitrarily |
| `removeDevices` | resolved `deviceIds` | Remove dependent references; a missing/ambiguous name is unresolved |
| `renameDevice` | resolved `deviceId`, `newName` | Update references using existing rename logic; name collision is an error |
| `setRouting` | supported `protocol`, scope representable by the current model | Do not claim per-router/per-site support if the model only represents a global protocol |
| `setDeviceModel` | resolved `deviceIds`, exact `model` | Check ports/modules and target support; no fallback model without a user decision |
| `assignService` / `removeService` | resolved `deviceId`, canonical `service`, supported typed service settings if specified | Preserve other roles/settings; passwords use vault references |
| `setAddress` | resolved `deviceId`, exact `interfaceId`, IPv4/IPv6 field and value | Validate subnet/gateway dependencies; list dependent changes explicitly |
| `setVlanMembership` | resolved endpoints, VLAN ID, supported mode | Require representable membership; a list of VLAN IDs alone is insufficient |
| `setLink` | resolved endpoints/interfaces, cable type, explicit add/remove/replace action | One cable per supported port; preserve unrelated links |
| `setLayout` | supported style/zones and resolved device references | Preserve network semantics; unsupported geometry remains unresolved |
| `preserve` | explicit scoped property set or entire semantic design | A guard checked against the candidate; it does not synthesize a change |

Reject arbitrary property paths and unknown fields in provider operation
payloads. Put structured error codes next to user-readable issues; do not
attempt to apply a partially decoded operation.

`NetNode` currently identifies devices by name; do not assume it already has
an immutable UUID field. In v1, resolve a device reference as project identity
+ base revision + exact canonical name. A rename must atomically rebind
affected active requirement subjects and references along with the plan.
Stale references remain stale. Introducing permanent graph IDs throughout
imports/builders is a separate migration, not a prerequisite for these fixes.

### Coverage and request outcome

For each requirement record planning status and delivery status separately:

- Planning: satisfied, violated, unresolved, unsupported, or superseded.
- Delivery: not requested, pending, verified, mismatch, or unverified.
- Evidence: requirement ID, plan revision, target, phase, artifact content
  hash where applicable, measured value, checker, time, and explanation.

`RequestOutcome` contains one authoritative interpretation, candidate plan,
change set, coverage report, clarification(s), requested follow-on actions,
and a disposition: answer only, ask, commit, or blocked.

Suggested initial files:

```text
lib/models/request_interpretation.dart
lib/models/request_requirement.dart
lib/models/plan_operation.dart
lib/models/request_coverage.dart
lib/services/request_understanding/normalizer.dart
lib/services/request_understanding/requirement_merger.dart
lib/services/request_understanding/operation_applier.dart
lib/services/request_understanding/request_coordinator.dart
lib/services/request_understanding/coverage_checker.dart
```

Keep capability checks alongside the existing validator/adapters. Do not use
the UI action registry as proof that a particular device feature is supported.

## 5. Required semantics

### Precedence and correction

1. A clear current user correction overrides the earlier decision **for the
   same property and scope**. It does not erase other project requirements.
2. Established explicit project requirements beat remembered preferences.
3. Scoped remembered preferences beat a general profile/default only where
   no explicit decision exists. Never change a fixed inventory just because
   a preferred model or service was remembered.
4. Derived defaults remain labeled as assumptions. A default is not proof
   that the user chose it.
5. Two incompatible current instructions remain a conflict unless correction
   wording clearly supersedes the earlier one. Do not resolve every same-turn
   contradiction by taking the last keyword.
6. Resolve references against the selected project and artifact, not whichever
   file happens to have the newest timestamp globally.

Example: remembered OSPF + current "EIGRP on this lab" yields EIGRP; a later
"add a printer" preserves EIGRP. "Use OSPF and EIGRP as the only routing
protocol" needs clarification. "OSPF—actually EIGRP" is a clear correction.

### Quantities, scope, exclusions

- "Add 5 PCs" is an increment; "make it 5 PCs" sets the total.
- "At least 5" is a lower bound; "no more than 5" is an upper bound.
- "3 branches, 10 PCs each" means 30 PCs with separate site ownership.
- VLAN 10, model 2911, area 0, interface g0/1 and /24 are not device counts.
- People, simultaneous clients, available ports, and physical PCs are
  different quantities. Ask or disclose a sizing assumption when no relation
  is known. "40 users" must not silently become 40 extra PCs.
- "Only change the layout" preserves all semantic network configuration.
- "Without DNS" prohibits DNS service; it does not prohibit a server used
  for DHCP. Bind negation to the relevant phrase and scope.
- In "do not use OSPF, use EIGRP", the positive selection is EIGRP and OSPF
  is forbidden. "Not OSPF" alone gives no permission to invent another
  explicit user choice.
- A protected exact inventory that cannot meet a port budget is blocked with
  a specific reason and alternatives. Do not silently add a switch, drop
  clients, or mislabel an approximation as exact fulfillment.

### Clarification and readiness

- Parse clear answers to all applicable pending questions in one message.
- Bare "40" can answer an active scale question; "VLAN 40" cannot.
- Apply a proposed fact and its dependent plan changes together. If the
  change fails, keep the earlier state and keep that fact unresolved.
- Keep pending questions not answered by the reply. Bind question IDs to
  project + base revision + property; revalidate after context changes.
- Ask one focused question at a time by default, at most two when independent.
- Readiness is contextual: do not ask for users just because the message is
  an exact topology specification, or for multi-router routing in a switch-only
  lab. A required capability or contradictory hard constraint blocks building.
- A hypothetical reply is an exploration, not a clarification answer.
- Punctuation is not intent: "can you add 2 PCs?" is a direct request, while
  "what would happen if we added 2 PCs?" is exploration. Resolve the complete
  wording instead of treating every question mark or "can/could" as read-only.
- Honor a clear "choose sensible defaults" for unspecified supported choices;
  display those assumptions. It cannot authorize violating explicit limits.
- Reuse answers in the same project; do not automatically promote a one-off
  answer to a global preference. Remember across projects only when the user
  requests it or has explicitly enabled such a policy.

### Edits and execution

- Apply all supported explicit edits in a turn atomically. If one dependent
  clause is unresolved, hold the candidate and ask; do not partially mutate
  the committed plan while implying the entire request landed.
- Answer-only/exploration turns cannot update the plan, facts, learned rules,
  or persisted decisions. They may update ordinary conversational focus.
- Preserve stable device identities, addresses, links, services and unrelated
  settings. Reuse `TopologyEditService` for consistent device renames.
- "Build it" uses the current committed snapshot. A request with no available
  project asks what to build instead of invoking an empty-brief default lab.
- After a clear edit, build/export in the same turn if requested and valid.
- Honor all supported requested deliverables in dependency order, and report
  partial delivery accurately if a later export fails. An export failure does
  not silently undo a completed plan edit or claim every deliverable succeeded.
- Honor "configuration only", "answer in Arabic", "brief answer" and similar
  output instructions. Suppress optional explanation when requested while
  still surfacing a necessary unresolved decision or actual failure.
- Bind actions to project identity, semantic revision, requirement-set version,
  selected target, and separate layout/output revision when applicable.
  Do not modify the existing `NetworkIntent.revision` semantics casually.
- Reuse cancellation tokens. A late provider result, old clarification button,
  stale build card, or duplicate callback cannot commit another change.
- Repeated build clicks for the same active job reuse that job. Do not prevent
  an explicit later rebuild/export simply because identical content existed.

### Capability and evidence

For each requirement distinguish: can model it, can generate it for this
target, can read it back, and can verify it live. These are separate facts.
Start with Packet Tracer and explicitly declare narrower coverage elsewhere.
Unknown capability is unresolved, never assumed supported.

Before building, check requirement-to-plan coverage plus the existing
validator. After building, run existing saved-file audits and map their actual
evidence to the requirements. A missing saved field is unverified or mismatch,
not verified merely because the generator says it wrote that field.

"Guest VLAN cannot reach staff VLAN" requires ACL/policy representation and
appropriate evidence. Until supported, keep it unresolved/unsupported and
offer a valid alternative. A VLAN tag or natural-language note alone cannot
prove isolation. A timeout cannot prove traffic was blocked.

Retain artifacts produced during a failed audit as clearly labeled results,
but do not present the task as fully delivered. Invalidate evidence after a
relevant plan, requirement, target, layout, or file-content change. Cosmetic
layout evidence can be invalidated separately from connectivity evidence.

## 6. Optional model assistance

Use the existing configured provider, not a new hard-coded provider. Keep
offline planning fully functional. The model proposes an interpretation or
typed operations; it never directly executes changes or determines truth.

- Invoke assistance only for unresolved clauses/conflicting interpretations,
  or an explicit request, rather than adding a second model call to every turn.
- Send current instruction, relevant sanitized project facts, available
  capabilities, pending questions and the closed response schema.
- Use the provider's supported structured-output mechanism when available.
  Compatible endpoints differ: record schema support, JSON-only support, or
  unsupported. Do not silently ignore an endpoint's schema rejection.
- Strictly validate enums, types, scope, bounds, referenced devices and source
  spans. Reject unknown mutation fields and unsupported operations.
- Accept only claims grounded in supplied input/current project. Model
  inference remains an assumption. It cannot invent credentials or override
  an established explicit constraint.
- At most one repair request after a validation failure, with field errors;
  then keep the safe local interpretation and ask a concise question.
- Reuse existing abort/timeout behavior. Failure or cancellation never mutates
  the plan or silently discards the user's unresolved clauses.
- Cache identity must include project/base revision, requirement-set version,
  input/attachment content identity, target capability version, schema version,
  relevant preferences and provider/model configuration. Never cache secrets.
- Keep documents, OCR, configurations and tool output labeled as data.
  Embedded instructions cannot grant authority to modify a project.

Google's official guidance distinguishes valid structured JSON from correct
values and calls for application validation. The API syntax must be checked
against the configured provider when implementing; do not copy an unrelated
new API into the current transport solely because it appears in documentation.
References: [structured output](https://ai.google.dev/gemini-api/docs/structured-output),
[function calling](https://ai.google.dev/gemini-api/docs/function-calling).

## 7. UX changes that make understanding visible

Render these from `RequestOutcome`, not a fresh parsing pass:

- "I understood": important explicit facts, scoped changes and exclusions.
- "Changed": actual old/new values and dependent changes, with Undo where
  the existing version/change-log implementation supports it.
- "Assumed": defaults and their origin, editable in the brief.
- "Need to resolve": one focused issue, with replies tied to that issue.
- "Delivered": requirements satisfied in the plan versus verified in the
  actual file versus still awaiting live checks.

Do not show a heuristic "92% understood" as a reliability guarantee. Prefer
"3 requested changes applied; 1 policy needs clarification". Match the user's
response language where supported; preserve literal technical names. Keep
typed operation payloads, schema names and internal parser details out of
the normal product interface.

## 8. Completion and rollout

Complete phases in order. The deterministic fixes are independently useful;
do not postpone them until a model integration exists.

1. Phase A: T00–T03, baseline and immediate regressions.
2. Phase B: T04–T08, typed state, operations, and shared orchestration.
3. Phase C: T09–T11, coverage, evidence, and clear UI.
4. Phase D: T12–T14, language/OCR and optional provider assistance.
5. Phase E: T15, full acceptance, integration and manual validation.

Task status checklist (all implementation work starts pending):

Progress and verification notes are in
[IMPLEMENTATION-LOG.md](IMPLEMENTATION-LOG.md). Partial work does not count as
a completed task; the checklist below changes only when a full card passes.

- [x] T00 Baseline and harness
- [x] T01 Explicit choices beat memory
- [x] T02 Clarification quantity semantics
- [x] T03 Multiple answers and atomic reconciliation
- [x] T04 Typed contract
- [x] T05 Requirements and precedence
- [x] T06 Original-text normalization and extraction
- [x] T07 Operations and preservation
- [x] T08 Shared coordinator and persistence
- [ ] T09 Requirement-to-plan coverage
- [ ] T10 Artifact evidence and action freshness
- [ ] T11 Understanding and result UI
- [ ] T12 Arabic/English/mixed-language coverage
- [ ] T13 Optional structured model proposals
- [ ] T14 Attachment intent and context retention
- [ ] T15 Full regression and manual acceptance

Release gates: all deterministic acceptance cases pass, all relevant existing
regressions pass, no explicit hard constraint is silently violated, no
answer-only case changes the design, no unsupported feature is labeled
delivered, and stored conversations reopen consistently. Report optional
provider and manual evidence separately; an untested platform stays untested.
