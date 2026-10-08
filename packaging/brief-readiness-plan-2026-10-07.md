# The brief conversation: readiness gate, tentative-language gate, ask-before-plan (2026-10-07)

> **Status (2026-10-08): all three steps are wired into the chat and green.**
> What was built, the two conflicts the integration forced, and what is
> deliberately left: `brief-gates-done-2026-10-08.md`.

Three features, one goal: the app should hold a design CONVERSATION instead
of jumping to a `.pkt` the moment a sentence carries device counts.

Division of labour (strict file ownership to avoid collisions):

| Piece | Owner | Files |
|---|---|---|
| Contract model | done (main) | `lib/models/design_brief.dart` |
| Brief state machine + card | Agent A | `lib/services/design_brief_service.dart`, `lib/widgets/brief_card.dart`, `test/design_brief_service_test.dart` |
| Tentative-language gate | Agent B | `lib/services/tentative_language.dart`, `test/tentative_language_test.dart` |
| Ask-before-plan + remembered answers | Agent C | `lib/services/clarification_service.dart`, `MemoryService` (schema v10), `test/clarification_service_test.dart` |
| Chat integration of all three | main (after A+B+C) | `chat_screen.dart`, `offline_assistant_service.dart`, `session_state.dart` |

## The contract (lib/models/design_brief.dart)

`DesignBrief` = facts map over closed slot vocabulary
(`scale, routing, wireless, segmentation, security, venue`), `BriefFact`
(canonical value + display + source + origin + setAt), origin precedence
user > remembered > profile > plan, `criticalSlots = [scale, routing]`,
`ready = missingCritical.isEmpty`, JSON round-trip.

## Agent A - DesignBriefService (state machine) + BriefCardWidget

`DesignBriefService.briefForTurn({DesignBrief? previous, required String
normalizedText, NetworkIntent? parsedPlan, EnvironmentProfile? profile})`:

* start from `previous`; fold, in precedence order: explicit statements in
  the text ("use OSPF", "no VLANs / one flat network", "wireless", "make
  security maximum", "N users/PCs"), the parsed plan (routing ONLY when the
  text mentions routing words - the planner defaults routing, so a default
  must never masquerade as a user decision; PC count from nodes only when
  the text carries a count), remembered answers are NOT applied here (that
  is the chat's/ClarificationService's job), the profile last.
* never downgrade: `withFact` precedence handles it; a "could we"-style
  sentence never reaches here anyway (tentative gate runs first in chat).
* return `(DesignBrief brief, bool changed, List<String> announced)` where
  `announced` are short lines the chat can say ("Venue: office - from your
  environment profile") for facts that changed this turn.

`BriefCardWidget(brief)`: the "what I know so far / what's still open"
card - filled slots with display + provenance small-print, open slots as
muted chips (critical ones visually louder), `ValueKey('brief-card')`,
readiness line when `ready`. Follow the app's widget style (AppTheme
constants, colorScheme, the advice card as the shape reference). Read-only
in v1; tap-to-fix comes later.

## Agent B - TentativeLanguageService

`TentativeVerdict analyze(String text)` -> `{tentative, cues}`. TENTATIVE:
"what if", "suppose", "hypothetically", "maybe", "could we", "can we do",
"would X work", "instead of X, would Y", "or should we", "thinking about",
"what about". NOT tentative (definite - must mutate): "add ...", "make it",
"actually ...", "use X instead of Y" (declarative), "switch to", "replace",
"remove", and POLITE IMPERATIVES: "can you add 2 APs" is a request, not
exploration - the imperative verb wins over the interrogative frame.
Expect lowercase normalized text (CasualEnglish already ran); handle
punctuation. Pure static, no imports beyond the model. The chat will call
this BEFORE `NetworkIntent.followUp`: tentative turns answer
conversationally and never mutate the standing plan.

## Agent C - ClarificationService + remembered answers

`ClarificationQuestion {id, question, quickReplies}` with a small catalog:
`scale` (ask when missing), `routing` (ask when missing AND the plan has
2+ routers), `segmentation` (ask when missing AND plan has a server or the
venue is office/school). At most TWO questions per turn, most critical
first. `ClarificationService.neededFor({required DesignBrief brief,
NetworkIntent? plan, EnvironmentProfile? profile, required Set<String>
rememberedQuestionIds})` - never ask an id the profile already answered.

Each question gets `resolve(String answerText) -> BriefFact?` mapping the
reply to a canonical fact (quick replies are canonical already; free text
via keyword match: ospf/static/eigrp/rip; a bare number for scale; "flat"
-> segmentation none, "vlan" -> yes). Unresolvable answers return null
(fail-closed: ask again rather than guess).

MemoryService (schema version 9 -> **10**, export 3 -> **4**): new table
`clarification_answer(id INTEGER PK AUTOINCREMENT, question_id TEXT NOT
NULL, answer TEXT NOT NULL, venue TEXT NOT NULL DEFAULT '', scale INTEGER
NOT NULL DEFAULT 0, created_at TEXT NOT NULL)` + CRUD:
`rememberClarification(questionId, answer, {venue, scale})`,
`clarificationAnswers()`, `answerForClarification(questionId, profile)`
(venue-matching row first, then a venue-less global row; null otherwise),
`forgetClarification(id)`; include in exportJson and clearAll.

## Chat integration (main, after A+B+C) - the shape

In `_appendOfflinePlan`, before plan mutation:
1. B's verdict on the turn: tentative && no definite request -> answer
   conversationally (advisor/design-review style), no plan mutation, no
   build card, brief untouched.
2. Definite: A's `briefForTurn` updates the brief (persist in SessionState
   alongside intent JSON); announced lines go into the reply.
3. If the turn is build-shaped and the brief is not `ready` and the user
   has not said "just build it": C's questions become the reply (quick
   replies attached); the answer is remembered (with venue/scale from the
   profile) so the same person is never asked twice.
4. When `ready` (or "just build it"): plan + build card as today, with the
   BriefCard attached; remembered facts that pre-filled a slot are
   announced ("Routing: OSPF - from your earlier answer, say 'static' to
   change").

"Just build it" detection lives in the chat integration (B provides the
definite-verb signals).
