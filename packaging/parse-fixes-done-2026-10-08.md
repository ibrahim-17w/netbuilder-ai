# Features 4-6: tap-to-fix, the misparse ledger, two intents in one turn

Shipped 2026-10-08. Follows `brief-readiness-plan-2026-10-07.md` (features 1-3
in `brief-gates-done-2026-10-08.md`). All three land the same idea from
different sides: **when the offline reader gets it wrong, the correction is
captured, counted, and only taught after a human agrees with it.**

`flutter analyze` clean. `flutter test` **2352/2352**.

---

## 4. Tap to fix a parse slot

**Before.** The "Understood" card showed what the parser read and let the user
edit it only indirectly: retype the sentence and hope the second read is
better.

**Now.** The counts, the VLANs and the routing protocol on the card are all
tappable. Tapping asks for the value, re-reads *this turn's* words with that
value in them (`MisparseLedger.correctedBrief`), re-plans
(`NetworkIntent.followUp`), persists `intentJson`/`briefJson`, and prints
`Fixed: 5 routers - remembered for "2 routers and 4 switches"` under the chips.
A correction is never silent, and never re-typed English.

- `lib/screens/chat_screen.dart` - `_fixSlot` and the `_SlotFixDialog`
  stateful widget (it owns its own `TextEditingController`: the dialog route
  is still animating and still listening when `showDialog` returns).
- The routing chip is now **always** shown, including when it says `STATIC`.
  A slot the card does not display is a slot the user cannot correct, and a
  default nobody chose is exactly the thing worth arguing with.
- `_slotFixNote` is cleared on the next send: a correction belongs to the turn
  that was corrected.

## 5. The misparse ledger

**The triple is the point: what they said, what the app made of it, what they
meant.** Unlike a lesson inferred from free text, every row is labeled by the
user themselves, so there is no ambiguity to resolve.

- `lib/services/misparse_ledger.dart` - `MisparseEntry` (key, original,
  understood, corrected, slot, source, status, count), `MisparseLedger.record`
  (merge by `normalizeKey(original)` + identical `corrected`; a *different*
  correction for the same wording is a *different* row, because two rows cannot
  both be right), `promoteAfter = 3`, `maxEntries = 100`,
  `briefFromPlan`/`unit`/`correctedBrief`.
- `MemoryService` - `noteParsedTurn()` (the denominator of the rate),
  `recordMisparse`, `misparseLedger`, `misparseStats`, `teachMisparse`,
  `dismissMisparse`. Write path is fail-closed: no DB, no-op.

**Nothing here teaches anything by itself.** `ledger` -> at three sightings
`proposed` -> `taught` only after the user presses Teach on the Memory screen.
An unreviewed guess must never rewrite someone's parses - same contract as the
autopilot learning loop.

- `Memory screen`: a fifth health-strip metric, **Misparse rate =
  corrections / parsed turns** (one decimal, `n/a` before the first turn), and
  a review panel above the phrasings with Teach / Dismiss.

## 6. Two intents, one turn

**Before.** "2 routers and 4 switches, what is the best colour for the cable?"
got whichever half the branch caught first and dropped the other: a covered
question got its explainer with no mention of the lab, an uncovered one got a
plan dump with no mention of the question. Worse, a WH-word in the *middle* of
a sentence was never seen as a question at all, because `_howtoShaped` only
looks at the start of the message.

**Now** (`lib/services/offline_assistant_service.dart`):

- `_whWord` matches a WH-word anywhere. `mixed = device count && (wh | wh-shaped | raw "?")`.
- `_briefNote(plan, clarifying)` - one line, appended to the concept,
  knowledge and rescue answers: *"You are also describing a lab with 2 routers,
  4 switches, 50 PCs - say "build the .pkt" ..."*, or the not-planned variant
  carrying the open questions. It renders with `_labLine`, the same call the
  ack/change/nothing-changed replies use, so a lab reads one way everywhere.
- The rescue guard now also opens when `mixed`, so a counted question reaches
  the composed lab answer instead of the plan dump.
- **The lines it does not cross**, each pinned by a test:
  - a plain build request still builds;
  - a **yes/no** turn about the lab still gets the lab (trading
    `"Here is the lab I understand"` for `"not in my offline material"` would
    answer worse), so the build branch is only downgraded for WH-questions;
  - the advice branch is untouched - it already names the lab.

## Tests

| file | covers |
| --- | --- |
| `test/misparse_ledger_test.dart` | 14 - rewriting (in place, unit kept, fallback to plan, routing, VLAN, refusal), rendering, counting/threshold/status |
| `test/offline_brief_note_test.dart` | 9 - the note on covered/uncovered/mid-sentence/not-ready turns, and the three lines not crossed |
| `test/chat_ui_test.dart` (new group) | 3 - fix from a chip, cancel changes nothing, routing chip always shown and fixable |

## Deliberately not done

- **Typed corrections** (`source: 'typed'`) are not wired yet:
  `MessageUnderstanding.corrections` already carries recognized details, but
  the chat does not read them into the ledger. The tap path is unambiguous;
  the typed path needs a decision about which recognized detail counts.
- **Role chips** (server roles) are not tappable - `correctedBrief` has no
  `role:` slot yet.
- The ledger is per-conversation *state* but stored in the app-wide `prefs`
  table; keying by conversation would let a wording be re-counted per lab.
