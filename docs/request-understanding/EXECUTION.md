# Implementation handoff for GPT-6 Luna

Read [PLAN.md](PLAN.md), then [ACCEPTANCE.md](ACCEPTANCE.md). Implement one
task card at a time in this order. Proposed symbols in these documents are
new APIs to create, not existing functions to search for indefinitely.

## Executor prompt

Copy the following into the implementation chat:

```text
Work in C:\netbuilder. Implement the request-understanding improvements in
docs/request-understanding/PLAN.md using the ordered task cards in
docs/request-understanding/EXECUTION.md and acceptance requirements in
docs/request-understanding/ACCEPTANCE.md.

Start at the first unchecked task in PLAN.md. Inspect the current checkout
and any applicable AGENTS.md before edits. There is substantial existing
uncommitted work: preserve it, including the roadmap features. Do not reset,
clean, replace whole large files, change dependencies, or implement an
unrelated redesign. Planning documents describe intended changes; they do
not prove those changes already exist.

Implement one card at a time. Add a meaningful regression reproducing the
behavior before fixing it. Keep all previously supported behavior unless
the specification deliberately changes it; then update the obsolete test
with a clear reason. Never weaken an assertion merely to get a green run.

Keep the app useful without an API key. Current explicit requirements must
beat memory. Questions and hypothetical requests must not change the plan.
Do not claim success for unsupported or unverified requirements. Reuse the
existing parser, validator, versioning, adapters, privacy and cancellation
services. Do not build a second planning system or rewrite the monoliths.

After each card: format changed files, analyze, run the focused tests, and
inspect the diff. Record files, exact commands/results, and unresolved
limitations in docs/request-understanding/IMPLEMENTATION-LOG.md. Mark the
task checked only after its acceptance checks pass. Continue to the next
card while work remains. If a real blocker prevents a card, record the
specific evidence; do not mark it complete or proceed past a dependency.

Do not run Flutter tests and Windows builds concurrently. Do not publish,
deploy, push, or change a real network. Complete local implementation and
local verification. Summarize what passed and what still needs manual or
provider testing. Never call a task complete solely because code compiles.
```

## Working rules for every card

1. Read only the relevant files and tests listed for that card first.
2. Identify the current behavior and write a regression/fixture that asserts
   the intended behavior. Observe its expected failure before the fix.
3. Implement the smallest compatible change. New pure logic belongs in small
   services, not in more branches of `chat_screen.dart`.
4. Run focused checks and applicable earlier-card tests. When a new failure
   appears, repair it before adding another feature.
5. Format only changed Dart files. Run `flutter analyze --fatal-infos`.
6. Update the implementation log and the checklist in PLAN.md. Keep the
   source evidence and limitations specific.

For extraction cards, first move existing behavior and prove parity, then
change behavior in the next card/change. The repository's CONTRIBUTING.md
requires one extraction per PR; do not mix a broad refactor into a bug fix.
If a card has too many independently testable parts, split it into lettered
substeps in the implementation log and complete them sequentially.

## T00 — Establish the actual baseline

**Depends on:** none.

**Read:** `CONTRIBUTING.md`, `docs/architecture.md`,
`docs/roadmap-implementation.md`, `.github/workflows/ci.yml`, current git status.

**Do:**

- Inventory existing modifications without altering them. Record branch,
  toolchain, changed/untracked files, and baseline test results in the log.
- Run the focused command in ACCEPTANCE.md and the full app suite
  sequentially. Capture existing failures as baseline issues, not regressions
  introduced by this task. Don't assume the review's 96-test count persists.
- Start `test/request_understanding/` with helpers to create an explicit plan,
  snapshot all semantic fields and run a multi-turn scenario.
- Use deterministic fake provider, fake clock and fake artifact audit for
  new tests. No network/model key should be required in CI.

**Done when:** baseline evidence exists and the fixture helper can assert an
unchanged semantic snapshot across an explanation turn.

## T01 — Protect explicit decisions from remembered preferences

**Depends on:** T00.

**Read/edit:** `planner_memory_service.dart`, `design_brief_service.dart`,
`models/design_brief.dart`, callers in chat, `planner_rule_hygiene_test.dart`,
`auto_learning_e2e_test.dart`, `offline_evolution_test.dart`.

**Do:**

- Add an explicit-field/scope protection input to memory application, with a
  backward-compatible default for callers not yet migrated. Derive protection
  from the user's source facts/brief, never a generated field's presence.
- Protect routing, explicit per-device models, subnets, service exclusions,
  and fixed inventory. Scoped values do not protect unrelated sites/devices.
- A clear new correction wins; a later unrelated edit preserves the prior
  explicit choice. Keep filtering autopilot advice out of planning memory.
- If a remembered choice is skipped, record its reason for the later outcome
  UI. Do not rewrite the stored preference as a side effect.

**Tests:** A01–A04. Include EIGRP + remembered OSPF and the same project after
an unrelated printer addition. Check explicit models/addresses unchanged.

**Done when:** online/local fallback candidates and brief agree about which
explicit choices won. Memory still supplies genuinely unspecified values.

## T02 — Fix scale reconciliation and number roles

**Depends on:** T01.

**Read/edit:** `_reconcilePlanWithFact` in chat, `ClarificationService`,
`DesignBriefService`, existing headcount/sizing tests.

**Do:**

- Introduce typed meaning for people/load versus PC inventory. Preserve the
  existing supported PC-sizing policy only where it is an actual established
  decision; do not silently infer a new one for mixed-device requirements.
- For an established PC target, calculate the desired total and change only
  the difference. Never issue `add desiredTotal pcs`.
- Keep explicitly named/fixed inventory protected. If 10 named PCs must stay
  and the user needs 40 users, explain capacity assumptions or ask whether to
  expand; don't silently replace the named inventory.
- Resolve bare numbers only in a matching active question. Reject VLAN IDs,
  model numbers, prefixes, ports, and unrelated numeric replies as scale.
- Remove unconditional scale/routing prompts where the exact topology and
  applicable routing already determine a buildable result. Centralize this
  applicability policy for later coordinator reuse.

**Tests:** A05–A09, A37. Include 10→40=40, not 50, with the PC-sizing policy
explicitly established; 40 users with no sizing policy remains load.

**Done when:** the UI clarification regression checks both the displayed
answer and actual saved plan; no inventory inflation occurs.

## T03 — Consume answers together and reconcile atomically

**Depends on:** T02.

**Read/edit:** `_resolvePendingClarification`, `_applyClarificationAnswer`,
`_clarificationsFor`, `ClarificationService`, `SessionState`.

**Do:**

- Return a collection of unambiguous answers instead of first-match wins.
  Support "40 devices, OSPF, one flat LAN" as multiple scoped answers.
- Stage facts and candidate plan changes together; commit only after
  validation. Do not acknowledge a successfully applied segmentation change
  when the plan has not actually changed or support is unavailable.
- Clear only answered question IDs; keep unanswered ones. Store the pending
  question's project/revision/property association, with a legacy decoder.
- Resolve subject changes and what-if replies before consuming answers.
- Keep direct action questions distinct from what-if wording; the question
  mark in "can you add 2 PCs?" does not make it an exploration.
- Stop automatic promotion of local answers into global preference memory.
  Reuse within the project. Explicit "remember for future labs" still works.

**Tests:** A10–A13, A38–A39, A49. Inject reconciliation/persistence failures;
assert no half-applied brief/plan and no global memory write.

**Done when:** reopen resumes the remaining questions, and the brief never
claims an answer was applied when the committed plan contradicts it.

## T04 — Introduce the typed contract without changing behavior

**Depends on:** T03.

**Create:** the four model files in PLAN.md section 4.

**Do:**

- Add immutable types, enums, equality/copy helpers, strict decode errors and
  versioned JSON serialization. Unknown fields in model-generated mutations
  are rejected; persisted future schema versions fail visibly without deletion.
- Include mode, source span, requirement scope/origin, operations, coverage,
  pending issue IDs and base project/revision identity.
- Keep `NetworkIntent` the plan model and `DesignBrief` the current brief UI
  adapter. Do not duplicate their full data in another mutable store.
- Legacy sessions decode with unknown provenance, not fabricated user facts.
  Missing new fields must not prevent an existing project from reopening.

**Tests:** round trips, malformed payloads, unknown enums/versions, absent
legacy fields, secret redaction and span bounds.

**Done when:** types are tested and existing product behavior is unchanged.

## T05 — Implement requirements, scope and precedence

**Depends on:** T04.

**Create:** `requirement_merger.dart`. **Integrate:** T01 protection adapter.

**Do:**

- Implement PLAN.md precedence exactly, with immutable active/superseded
  history. A property is identified by subject + scope + property, not name
  alone. Site-specific choices can coexist.
- Support exact/min/max counts, routing, model, subnet, service/exclusion and
  preserve requirements first. Preserve unsupported clauses as unresolved.
- Distinguish a contradiction from a clearly signaled correction. Include a
  conflict reason plus source excerpts; no arbitrary last-keyword selection.
- Make the merged requirement set the source for memory protection and the
  brief adapter. Remove duplicated precedence decisions as callers migrate.

**Tests:** A01–A04, A14–A17, A40. Check merger determinism and that the same
input does not duplicate requirements or history on retry.

**Done when:** one source determines the winning value for brief and plan.

## T06 — Normalize with source mapping; reuse existing readers

**Depends on:** T05.

**Read:** `nlu/parser.dart`, `nlu/slots.dart`, `nlu/lexicon.dart`,
`packet_tracer/brief_reader.dart`, `CasualEnglish`, existing inventory tests.

**Create:** `normalizer.dart` and an adapter that converts existing extracted
data into `RequestInterpretation` facts/operations.

**Do:**

- Extract the existing bridge behavior without changing output first. Add
  span mapping as a separate step; preserve original inventory formatting.
- Mark source spans only when grounded. Defaults and planner-derived values
  have their own origin and must not claim an explicit user excerpt.
- Extract clause-scoped negation, increment/set/min/max quantity roles,
  named inventory and site scope. Keep existing exact-model handling.
- Protect literals from normalization: do not fuzzy-rewrite `R10`, an SSID,
  address, file path, or secret as ordinary language.
- Specialized file, layout, config, help and lab readers remain in use. This
  adapter supplies evidence; do not implement another competing network parser.

**Tests:** A14–A23, A35–A36, A40 and original inventory/Arabic tests.

**Done when:** displayed excerpts refer to original text and existing parsing
fixtures remain valid, including multiline named devices.

## T07 — Apply typed edits and preserve unrelated design

**Depends on:** T06.

**Create:** `operation_applier.dart`. **Reuse:** `TopologyEditService`,
`NetworkIntent.followUp` where lossless, validators, existing plan diff.

**Do:**

- Implement one operation family at a time: counts; routing/models; services;
  addressing/links; then layout/VLAN operations the current model supports.
- Avoid rebuilding the entire plan from a concatenated prose brief for a
  narrow edit. Use the legacy follow-up path only if preservation tests prove
  it retains unrelated fields; otherwise apply a direct typed patch.
- Detect unresolved pronouns or multiple matching devices. Use an explicitly
  named/selected file or device before recent conversational focus.
- Apply multiple edits to a deep candidate copy. If one cannot be resolved,
  return a held candidate with issues; do not commit a partial plan.
- Report required incidental changes (e.g. dependent address updates) and
  block if they violate an explicit preserve constraint.
- Enforce resource limits through existing validators; report oversized or
  unsupported requests rather than truncating device counts.

**Tests:** A18–A28, A41–A42, A50. Compare complete semantic JSON before/after,
not just device counts. Check idempotent retry with the same turn identity.

**Done when:** named devices keep identity and unrelated configuration survives
all narrow edits; a failed edit leaves the committed revision unchanged.

## T08 — Share one coordinator and persist one outcome

**Depends on:** T07.

**Create:** `request_coordinator.dart`. **Edit:** `_send`, `_appendOfflinePlan`,
`SessionState`, persistence entry points and provider context assembly.

**Do in substeps:**

1. Extract route selection into a side-effect-free coordinator with legacy
   parity tests. Preserve config/lab/file/layout/help handling and action order.
2. Route parsing, clarification and candidate generation through it. Supply
   dependencies so service tests don't need a mounted chat widget.
3. Return the same outcome for offline, provider-enabled, and provider-failed
   modes. A failed provider response must not parse/apply the turn again.
4. Commit the outcome once. Persist the compatible plan/brief/requirements
   envelope together through the existing store. Publish UI state after a
   successful persistent commit; use a clearly labeled transient session
   when the store is unavailable, never claim it was saved.
5. Persist new interpretation/requirements in the existing versioned session
   JSON where feasible; do not add SQLite tables without a demonstrated need.
6. Reuse `GenerationControl` and project/revision checks before every commit.
   Revalidate question actions after a conversation switch or edit.

**Tests:** A24–A34, A38–A39, A43–A44, A49, A52–A53. Include cancellation,
late results, memory unavailable, database failure and online fallback parity.
Also cover A57–A58: direct polite requests and multiple requested outputs.

**Done when:** one user turn produces at most one committed change and one
consistent reopen snapshot across all three provider modes.

## T09 — Check requests against the candidate plan

**Depends on:** T08.

**Create:** `coverage_checker.dart`. **Read/edit:** validator, device support,
adapters, readiness panel. Add a small target-feature capability service if
needed; derive facts from implemented adapters/templates and their tests.

**Do:**

- Implement coverage by requirement type. Compare exact/bounded counts,
  names, models, subnets, roles, exclusions and preserve constraints.
- Add typed support statuses for model/generate/read-back/live-check phases.
  Do not infer support from a UI button or a natural-language note.
- Build readiness is one policy combining applicability, validation, support,
  unresolved hard requirements and coverage. Replace conflicting gates.
- Unknown policy/language constraints stay unresolved until a checker exists.
- Give every blocker a user-readable reason and supported alternatives. A
  declined alternative does not weaken or erase the user's hard constraint.

**Tests:** A16–A17, A35–A37, A45–A48, A51. A technically valid plan missing a
requested feature must fail coverage even if every validator check passes.

**Done when:** the app cannot call a misread-but-valid plan fully compliant.

## T10 — Verify artifact delivery and bind action freshness

**Depends on:** T09.

**Read/edit:** `BuildPreflight`, compile paths in chat, on-device and engine
builders, `PktBuildJobService`, version history, project checks, saved-file
audits; edit Python only where an actual evidence field is missing.

**Do:**

- Connect each supported requirement to actual saved-file audit evidence.
  Retain existing saved cable/address/service checks and fail-closed behavior.
- Extend evidence only for fields really read from the saved artifact. If
  the decoder cannot observe a field, delivery status is unverified.
- Bind actions/evidence to project, semantic revision, requirement-set version,
  target, artifact content hash and relevant layout/output identity.
- Keep generator reports separate from independent saved-file evidence.
- Invalidate stale results after file replacement even when the path is the
  same. Preserve forensic information without reporting stale success.
- Prevent duplicate active builds/late callbacks; keep intentional rebuilds
  available. Use the current job mechanism instead of another queue.
- For an explicitly requested layout-only edit, compare semantic content
  before/after and separately check supported layout evidence.

**Tests:** A29–A34, A45–A48, A50–A51. Include both engine and on-device paths,
and sidecar test equivalents only when Python behavior changes.

**Done when:** "delivered" means the requested artifact was produced and its
claimed properties were actually verified; live checks remain distinct.

## T11 — Show the actual interpretation and outcome

**Depends on:** T10.

**Read/edit:** `MessageUnderstanding`, Understood card, brief/readiness widgets,
correction badges and verification report. Prefer an extracted outcome widget.

**Do:**

- Render facts, exclusions, provenance, actual diff and unresolved clauses
  from the coordinator outcome. Remove the explanation-only reparse.
- Show planning versus artifact versus live evidence with plain wording.
- Replace heuristic confidence percentages with concrete counts/statuses.
- Provide quick corrections attached to fact/issue IDs and revisions. A
  stale button must not modify a newly selected project.
- Keep keyboard/free-text replies; do not force users into predefined options.
- Apply requested response language/format/brevity from the outcome. A
  configuration-only request gets the requested output plus only necessary
  errors or unresolved decisions, rather than a compulsory long explanation.
- Do not add confirmation for every supported clear request. An impossible or
  ambiguous request gets a focused decision, not a generic "proceed?".

**Tests:** widget coverage for one edit, one exclusion, one unresolved policy,
one saved-file mismatch, and one stale correction button.
Include output-instruction cases A59–A60.

**Done when:** the displayed claims match the exact committed/built snapshot.

## T12 — Improve English, Arabic and mixed-language understanding

**Depends on:** T11.

**Read/edit:** normalizer/reader adapters, `nlu/lexicon.dart`, ScopeGate,
tentative-language/clarification readers and response templates.

**Do:**

- Support the explicit Arabic/mixed examples in ACCEPTANCE.md offline.
  Cover Arabic-Indic digits, common Arabic networking terms, and a small
  controlled set of Syrian phrasing for add/remove/replace/keep/no/only.
- Resolve Arabic request mode, negation and pending answers as well as noun
  translation. Do not translate nouns while leaving an Arabic exclusion lost.
- Add typo aliases only for known domain words; ambiguous misspellings remain
  unresolved. Do not fuzzily change device names or exact technical literals.
- Match response language with compact localized status/question templates.
  Avoid adding a broad translation service dependency for this task.
- Test English/Arabic equivalent requests for semantic equivalence with
  original-text provenance preserved.

**Tests:** A14–A23, A35–A36, A40, A54–A56. Add paraphrase pairs and negative
minimal pairs such as "add" versus "don't add".

**Done when:** all selected language cases work offline and mixed technical
tokens are preserved exactly.

## T13 — Add optional structured model proposals

**Depends on:** T12.

**Read/edit:** `AiProviderConfig`, provider chat/transport services, context
budget, existing schema helper in `GeminiService`, tool protocol/runtime.

**Do in substeps:**

1. Add a fakeable `extractInterpretation` interface through the existing
   provider abstraction. Keep ordinary answer generation separate.
2. Add capability-aware structured output. Use PLAN.md's closed schema;
   JSON-only providers still require strict local validation.
3. Validate grounding, payload sizes, types, source spans, scopes, names and
   capability support. Reject malicious/unknown operations and invented facts.
4. Merge only validated proposals into unresolved parts. The deterministic
   requirement checks remain authoritative; retry/repair at most once.
5. Add cancellation and cache identity. Version the schema; store only
   sanitized proposals when caching is appropriate.

**Tests:** fake valid response, malformed JSON, unknown operation, wrong
project/device, invented span/credential, ignored exclusion, schema refusal,
timeout, cancellation and wrong-revision cache hit. A07/A43–A44 remain safe.

**Done when:** assistance improves unresolved supported phrasing in fake
fixtures, all offline acceptance cases still pass without a key, and a live
provider smoke test is reported separately if credentials are available.
No provider-account setup or provider API migration is required by this plan.

## T14 — Treat attachments and long context as grounded input

**Depends on:** T13.

**Read/edit:** attachment OCR, config paste reader, Packet Tracer imports,
`SessionState`, `ContextBudget`, `NetworkBlockService`, context tests.

**Do:**

- Interpret the requested attachment action: explain, compare, import, edit,
  or build from it. Attachment presence alone is not permission to redesign.
- Record source attachment identity/page or OCR region, uncertainty and content
  hash. Ask about an unreadable critical value; don't fabricate it.
- Keep instructions embedded in attachments/config/tool output as data.
- Protect compact current requirements, exclusions, active scope, requested
  action and pending questions from being lost during history compaction.
  If required state cannot fit, return a specific limit instead of sending a
  truncated mutation request. Never exceed the runtime window.
- Ensure imported project facts have imported provenance; avoid inventing
  proof that they were verified or stated by the user.

**Tests:** A22–A23, A43, A52–A53 plus tiny-context fixtures. Include fake OCR
with an uncertain count and an embedded "ignore the user" instruction.

**Done when:** attachment requests keep their intended mode and long chats
cannot silently lose a hard exclusion during an edit/build.

## T15 — Validate the complete workflow

**Depends on:** all prior cards.

**Do:**

- Run every acceptance case as a deterministic scenario. Report results by
  group (turn mode, quantities, scope, language, memory, artifact evidence),
  not only a single average that hides a serious failure.
- Run the full Flutter suite and analyzer. Run the Python suite when sidecar
  behavior/contracts changed. Run existing real-app integration sequentially
  on Windows and Android; document unavailable environments precisely.
- Exercise manual scenarios in ACCEPTANCE.md on the app and Packet Tracer.
  Do not mark live reachability/isolation verified from offline file checks.
- Compare final changed-file list with baseline, review privacy and supported
  target behavior, and ensure no unrelated work was discarded.
- Update architecture/support docs to describe the actual implementation,
  including targets/requirements still unsupported and offline limitations.

**Done when:** every release gate in PLAN.md is evidenced or explicitly listed
as incomplete. Missing manual/provider checks do not become invented passes.

## Implementation log format

Create `IMPLEMENTATION-LOG.md` during T00 with one entry per card/substep:

```markdown
## Txx — title
Status: pending / in progress / complete / blocked
Behavior before:
Behavior after:
Files changed:
Regression observed before fix:
Commands and results:
Existing failures / manual limitations:
Next dependency:
```

This file is a handoff tool, not a replacement for executable tests. Never
change the checklist merely because a status report says work was attempted.
