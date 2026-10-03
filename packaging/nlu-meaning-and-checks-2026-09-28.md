# NLU: meaning-preserving parses and safe learned phrasings (2026-09-28)

Session note for the NLU improvement pass in this working tree. Nothing was
committed, published or deployed - the changes live as uncommitted edits,
per the task instructions.

## Scope

Five focused improvements to how NetBuilder AI turns plain English into a
verified plan, each with regression tests:

1. Offline interpretation preserves meaning: quantities across clauses,
   negation/contrast/replacement for routing.
2. Phrasing memory is merge-only for near matches (never drops what the new
   message adds; asks when uncertain).
3. The keyless chat can run existing app capabilities (read-only checks)
   from natural language; the model path gained the `check_plan` action.
4. Confidence reflects what was actually understood; guessed plans say so.
5. Planning stays consistent across providers: the Gemini structured planner
   is untouched and every candidate plan is still validated before build.

## Changed files

| File | What changed |
| --- | --- |
| `lib/services/nlu/slots.dart` | Quantities across clauses (`quantityRecords`, `_quantityTotal`, `_ellipse`, `_clauses`/`_clauseOf`, `_siteWord`/`_siteLabel`, `_correctionCue`/`_negationBefore`); `extractCounts` numeric part now aggregated; bare mentions plural-tolerant; `extractRouting` delegates to `NetworkIntent.resolveRouting`. |
| `lib/models/network_intent.dart` | New `resolveRouting` (negation/replacement aware); `parseSimple` near-match merge via `PhrasingMatch`; `_localConfidence` + defaulted-plan assumption/question; `applyFollowUpChange`, the security-branch lab and the security return use `resolveRouting`. |
| `lib/services/phrasing_memory_service.dart` | New `PhrasingMatch` + `lookupMatch` (exact vs near, with score); `lookup` kept as a thin wrapper. |
| `lib/services/chat_capabilities.dart` | NEW - read-only chat capabilities (validate / duplicates / overlaps / improve) reusing `ValidatorService`, `NetworkTools`, `NetworkMath`, `PlannerSuggestionsService`; alias table + strict matcher. |
| `lib/services/offline_assistant_service.dart` | Capability branch after the scope gate; answers with real findings; read-only and says so. |
| `lib/models/chat_message.dart` | `check_plan` action kind + label. |
| `lib/services/chat_service.dart` | System context lists `check_plan`. |
| `lib/screens/chat_screen.dart` | `_runAction` runs the validator for `check_plan` and shows the findings; payload card line. |
| `test/nlu_golden_set_test.dart` | Known quantity gap promoted to contract; new cases: multi-clause totals, restatement, correction, addition, routing negation/contrast, memory-merge safety, uncertain-match question, confidence. |
| `test/chat_capabilities_test.dart` | NEW - alias routing (every alias provably routes), negative non-capture cases, real-service answers, `check_plan` card. |

## Behaviors improved (each pinned by a test)

- "the second floor needs 6 access points and the ground floor 4" plans
  **10** (was 6). Restatements don't double: "6, 3 on the second floor and
  3 on the ground floor" stays **6**. Corrections replace: "actually 8" ->
  **8**. Additions add: "and 4 more" -> **10**. Same site + same number
  restated -> unchanged.
- "Don't use OSPF; use EIGRP" -> **eigrp**; "use OSPF ... , not EIGRP" ->
  **ospf**; "use static routing instead of OSPF" -> **static**.
- Learned phrasings: exact wording replays as before; a NEAR match now
  merges - devices/services named in the new message survive; briefs with
  explicit counts still parse as written; a partial-coverage match adds a
  confirmation question and lowers confidence slightly.
- Chat capabilities: "validate the plan", "any duplicate ips", "check the
  subnets for overlaps", "what should I improve" run the same services as
  the Action Hub buttons and answer read-only with real findings. No plan -
  or only the tiny-office fallback guess - is refused honestly instead of
  checked as if real.
- Confidence: detailed briefs land >= 0.75; guessed plans 0.35 plus an
  explicit assumption and an open question. Build-time validation is
  unchanged (`new_build_screen` blocks on validator errors), and the new
  chat check path reuses the same `ValidatorService`.

## Checks run (this working tree, 2026-09-28)

| Check | Command | Result |
| --- | --- | --- |
| Analyzer, whole project | `flutter analyze` | **No issues found** |
| Focused NLU suites | `flutter test test/nlu_golden_set_test.dart test/memory_phrasings_test.dart test/offline_planner_test.dart test/intent_secret_redaction_test.dart test/follow_up_plan_test.dart` | all pass (89 tests) |
| Capability suites | `flutter test test/chat_capabilities_test.dart test/offline_conversation_test.dart test/offline_assistant_test.dart test/offline_guidance_test.dart test/chat_service_test.dart` | all pass (61 tests) |
| Full test suite | `flutter test` | **696 passed, 0 failed** |

## Limitations / known boundaries

- Elliptical quantities are recognized only in strict shapes ("the ground
  floor 4", "4 on the ground floor", "and 4 more", "actually 8"); other
  phrasings fall back to the previous behavior.
- "6 access points and 4 more access points" (device word repeated after
  the modifier) still reads 6: full phrases with a between-word modifier are
  deliberately not added, to protect merged-brief texts from double
  counting. The terse "and 4 more" form is the supported addition.
- The routing resolver prefers the last INSTRUCTED mention; plain-only
  multiple mentions keep the previous priority order.
- Chat capability answers run against the plan the chat holds; a plan that
  is only the parser's fallback is refused via its assumption marker
  (string-level marker, not a schema field).
- No new provider dependency; the Gemini planner prompt and flow untouched.

## Rollback

All edits are uncommitted. To back out: revert the files listed above to
their pre-session state (review each with `git diff`), and delete the two
new files (`lib/services/chat_capabilities.dart`,
`test/chat_capabilities_test.dart`). The four check commands above are the
regression net either way; re-running them after any back-out shows whether
the app is intact.

## Review record

- Automated second-reader reviews: two attempts to run an independent review
  pass over these edits (a full-scope and a focused one) both failed at the
  tooling level before producing findings - no review content was returned by
  either attempt, so no findings from them are pending or unresolved.
- Substitute independent verification, all run against this working tree:
  1. `flutter analyze` - **No issues found** (whole project).
  2. `flutter test` (full suite) - **703 passed, 0 failed**.
  3. Adversarial probe set, added to the golden file and run explicitly:
     cross-sentence totals ("...6 access points. The ground floor needs 4."
     -> 10), a rejected protocol alone changes nothing, and a follow-up
     "use eigrp instead of ospf" resolves to eigrp.
- Residual limitation stated openly: an automated second-reader pass was
  attempted but not completed; the mechanical verification above is the
  strongest evidence available from this session.
