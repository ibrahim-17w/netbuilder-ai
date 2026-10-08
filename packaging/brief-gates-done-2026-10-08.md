# The three brief gates are in the chat (2026-10-08)

Closes the plan in `brief-readiness-plan-2026-10-07.md`. Agents A, B and C
had landed their services and their own tests; what was missing was the
chat actually running them, plus two fixes the integration exposed.

State: `flutter analyze` clean, `flutter test` 2320/2320.

## What each step now does

**1. Readiness gate (brief before plan).**
`DesignBriefService` folds each definite turn into a `DesignBrief`;
`ClarificationService.neededFor` turns the open critical slots (`scale`,
`routing`) into at most two questions, which the chat sends as the reply
with quick replies attached. The `BriefCard` (`ValueKey('brief-card')`)
shows the filled/open slots once questions are resolved - it is suppressed
while questions are still being asked, because the questions ARE the
still-open list and two lists at once reads as the app losing track.

**2. Tentative-language gate (step 2 - was written but never wired).**
`TentativeLanguageService.analyze` now runs in two places in
`lib/screens/chat_screen.dart`, and both are needed:

* `_send`, BEFORE `NetworkIntent.followUp` - so an exploring sentence never
  reaches the parser, the phrasing teacher or the design catalog.
* `_appendOfflinePlan`, as the very first branch, before pending-question
  resolution - so "what if we used OSPF instead?" cannot be read as the
  ANSWER to the routing question that is open.

Exploring turns go to `_answerTentative`, which answers through
`OfflineAssistantService.reply` with the standing plan as *context only*
(`clarifyingQuestions: const []`), appends `Nothing in your lab changed -
that was a what-if, not a change`, writes the turn to the transcript (a
conversation the app does not write down is one it cannot continue after a
reopen), and touches none of `_planPrompt`, `_brief`, `_lastIntent`.

**3. Ask-before-plan with remembered answers.**
A turn that resolves a pending question applies the fact, remembers it via
`MemoryService.rememberClarification` (schema v10) and does not re-parse it
as a new request. Unresolvable answers fall through, so the question stays
open rather than being guessed at.

## Decisions worth knowing

**"can we add X" is a REQUEST, not exploration.** The tentative service as
first written read any `can/could we ...` as wondering, which broke the
pre-existing regression test `chat_ui_test.dart: a follow-up about the same
lab does not become a new one` - the reported bug where "can we add AAA
server to it as well?" rebuilt a 13-device lab as one server. Resolved in
favour of the existing behaviour and of the plan's own rule that a definite
verb ("add", "make it", "use", "replace") is a real edit whatever frame it
sits in:

* new `_weRequest` definite pattern: `can/could/would we + <edit verb>`,
  guarded by the exploration openers, so "what if we could add a dmz" is
  still the wondering it looks like;
* `_weEditVerbs` is derived from `_editVerbs` minus the build family, so
  "could we build it with 2 routers instead" keeps its what-if reading
  (`_executionAsk` owns "can we build it now");
* "could we do it with 40 PCs?" has no edit verb and stays tentative -
  that is the sentence the gate exists for.

`test/tentative_language_test.dart` was updated to match
(`can/could we + an edit verb is a request, not musing`).

**The offline answer's structured state is written before the reveal
animation, not in its `onDone`.** `_appendOfflinePlan` now calls
`_state.observe` + `setSessionState` the moment the answer exists, so a
conversation reopened (or an app killed) halfway through the progressive
reveal comes back to the plan on screen instead of the turn's first parse.
The transcript log, preference teaching and environment profile still land
in `onDone`, when the answer is whole.

## Tests added

`test/chat_ui_test.dart`, group *a keyless conversation is a conversation*:

* **a what-if about the lab does not change the lab** - asks the brief,
  sends "what if we had 40 pcs instead?", asserts no plan/`40` appears, no
  build card, the guarantee line is said out loud, and that the question it
  did not answer is still answerable ("25" -> `Scale: 25 users`).
* **a what-if does not answer the open question either** - the routing
  question is open, "what if we used OSPF instead?" must not fill it in;
  afterwards routing is still asked.

`test/chat_plan_persistence_test.dart`: `settle` budget raised 16 -> 32
pumps. Each store write is a round trip to the ffi isolate and needs its
own real-time window, in order; a loaded machine makes each one slower, not
optional. The property under test is the plan, never how fast the disk was.

## Known flake

`chat_plan_persistence_test.dart: the offline answer shows and records the
same plan` failed once during this pass under machine load and has passed
every run since (5 full-suite runs). The budget raise above is aimed at it;
if it recurs, the next thing to look at is whether the first parse's
`setSessionState` can still be observed by `recordedPlan` before the
reconciled plan overwrites it.

## Not done (deliberately)

* BriefCard tap-to-fix (v1 is read-only, as the plan says).
* The `announced` provenance lines ("Routing: OSPF - from your earlier
  answer") are only partially surfaced: the readiness line and the card's
  small-print carry provenance, but the reply does not narrate every fact.
* "Just build it" still bypasses the readiness gate as its own quick reply;
  it is not yet folded into the tentative service's definite signals.
