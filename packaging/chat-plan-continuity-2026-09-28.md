# Chat-plan continuity: the "built 1 router, 1 switch, 1 server" case (2026-09-28)

## What happened

On 2026-09-28 between 12:33 and 12:36 the user held one chat with the app
(conversation `default`, project `packet-tracer`) about a two-site company
network:

1. "hello" -> the assistant introduced itself, **but the app's standing plan
   became a silent default R1 + SW1**.
2. "I need to build a network for a large company what is your
   recommendations ?" -> a good overview answer from the model, plan
   unchanged (still the silent default).
3. "two physical sites and like 50 PCs and i don't know how many phones" ->
   the model was down (HTTP 503), so the offline path answered. The plan
   became **50 PCs + PH1 (an invented phone), 0 links**, and the validator
   refused it (more than 50 devices).
4. "what about the routers and switches and servers?" -> model answer shown
   partially as raw JSON (truncated stream), plan untouched.
5. "I think we will need more than 1 router and 1 switch and 1 server and it
   should be secure" -> "more than 1 router" was read as exactly one; the
   standing plan **became R1 + SW1 + SRV1**.
6. "ok then build this network" -> assistant: **"Then we go with 1 router, 1
   switch, 1 server, OSPF."**
7. "waht's the final plan for this network ?" -> a rich prose plan from the
   model (HQ/BR routers, switches, servers, VLANs 10/20/30/40/100, OSPF,
   port security, SSH).
8. "ok build this network then" -> assistant again: **"Then we go with 1
   router, 1 switch, 1 server, OSPF."** The user pressed Build the .pkt.

What got built (the artifact the user reacted to):
`C:\ai\app\build\windows\x64\runner\Release\sidecar\_internal\pkt_output\netbuilder-202609281236.pkt`
- 66,213 bytes, built 2026-09-28 12:36:41
- manifest (`...pkt.netbuilder.json`): planned deviceCount **3**, linkCount **2**

So the built file faithfully compiled the app's standing plan - the plan
itself was wrong, and it never tracked what the chat discussed.

Evidence used to reconstruct this:
- Live app DB: `C:\Users\L\Documents\netbuilder\memory.db` (chat rows
  115-130, 12:33-12:36; conversation `default`; the plan JSON in
  `conversations.stateJson`).
- The built .pkt + its manifest above.
- 13 screenshots of the session (transcribed 2026-09-28).

## Root causes (each fixed)

| # | Finding | Where it lived |
| - | - | - |
| 1 | "more than 1 router and 1 switch and 1 server" was read as exactly 1 each - and the standing plan was **replaced** by those minimums, discarding the discussed network. | quantity reading in `lib/services/nlu/slots.dart`; re-plan semantics in `lib/models/network_intent.dart` (`followUp`) |
| 2 | "i don't know how many phones" turned an unknown into a device (PH1) because a bare mention counts as one. | bare-mention rule in `lib/services/nlu/slots.dart` |
| 3 | "two physical sites" was not even recognized as multiple sites ("physical" was not an accepted filler word), and with sites there was no infrastructure completion: 50 PCs became a link-less farm the validator refused. | `NetworkIntent.siteCount` + no multi-site completion in `lib/services/nlu/slots.dart` |
| 4 | Questions were parsed as specifications: "hello" seeded a default lab, and "what about the routers and switches and servers?" / "what's the final plan?" re-ran the parser over the discussion. | `lib/models/network_intent.dart` (`followUp` had no social/question guard) |
| 5 | "what is your recommendations ?" had no advice answer in the keyless path, so it fell through to the vague/default handling. | `lib/services/offline_assistant_service.dart` (`_concept`) |
| 6 | The confirmation line ("Then we go with ...") and the built .pkt both read the standing plan, so once the plan was wrong everything downstream was consistently wrong. | consequence of 1-4; no separate fix needed |

## The plan that was executed

1. **Counts as floors.** "more than N" now plans N+1 (the minimum that
   satisfies it) and adds an explicit assumption ("Give the exact count to
   pin it."). "at least N" keeps reading as N.
2. **Unknown counts become questions.** "i don't know how many phones" (or
   "how many ...") no longer creates a device; the plan asks "How many
   phones do you want?" instead.
3. **Multi-site completion.** Several sites + devices but no per-site
   breakdown and no infrastructure of its own -> each site gets a router and
   its share of access switches (22 ports per switch), a WAN link joins the
   sites, and the devices are split evenly. Stated as an assumption with a
   question. ("two physical sites" is now a recognized site phrase.)
4. **Questions and greetings don't re-plan.** "hello", "thanks" and pure
   questions keep the standing plan (or the absence of one). A question that
   proposes an action ("can we add an AAA server as well?", "can we use
   OSPF?") still plans.
5. **Growth floor-merge.** "we will need more than 1 router ..." merges into
   the standing lab with floor counts (max of both sides) - the lab can only
   grow toward what was discussed, never collapse back to the minimums.
6. **Advice answers.** "recommendations/advice" asks are answered with the
   enterprise starting points in the keyless path instead of drifting toward
   a default plan.

## Verification (all on this working tree)

| Check | Command | Result |
| - | - | - |
| Analyzer | `dart analyze lib/... test/...` (touched files) / `flutter analyze` | No issues |
| Conversation replay | `flutter test test/chat_plan_continuity_test.dart` | all pass |
| Golden set (incl. 2 new contract cases) | `flutter test test/nlu_golden_set_test.dart` | all pass |
| Full suite | `flutter test` | **719 passed, 0 failed** (703 before this round) |
| The replay, concretely | see `test/chat_plan_continuity_test.dart` | "hello" leads nowhere; the two-site message plans 2 routers + 4 switches + 50 PCs + a phone question; the growth message keeps the 50 PCs and adds the server and the security question; "ok then build this network" confirms "2 routers, 4 switches, 50 PCs, 1 server" |
| Smaller twin end-to-end | same file | "two physical sites and 20 PCs" cables every PC and passes the validator |
| Release rebuild | `flutter build windows --release` | rebuilt - the app in `build\windows\x64\runner\Release` now carries these fixes |

## Known limitations (not silently hidden)

- The model's prose plan for the two sites (core/access split, VLAN
  numbers, loopbacks, MD5 auth) is richer than what "two sites + 50 PCs"
  can deterministically imply. The completion matches the SCALE (routers
  per site, access switches, WAN, split devices); name the extra detail to
  plan it.
- 50 PCs + 2 routers + 4 switches = 56 devices, above the 50-device
  autopilot guard: the plan is correct and the validator says why it will
  not run as-is. The smaller twin compiles end to end.
- With several switches per site, the switch-to-router uplink spread is
  round-robin, not site-aware.
- A model reply that is cut off mid-stream can still show as raw JSON
  (screenshot 1559/1560); not fixed in this round.
- The floor reading of "more than N" is N+1; a bigger exact count is asked
  for via the assumption.

## Rollback

All edits are uncommitted. To back out:
1. Revert `lib/services/nlu/slots.dart`, `lib/models/network_intent.dart`,
   `lib/services/offline_assistant_service.dart` to their pre-round state
   (`git diff` shows the round's changes; they are additive to the earlier
   NLU work).
2. Delete `test/chat_plan_continuity_test.dart`; remove the two "multi-site
   completion" contract cases from `test/nlu_golden_set_test.dart`.
3. Re-run `flutter test` to confirm the app is back to the previous
   behaviour (719 -> 703 tests).

## Re-verify by hand

```
cd C:\ai\app
flutter test test/chat_plan_continuity_test.dart
flutter test test/nlu_golden_set_test.dart
flutter test
```

In the app: New chat -> send "hello" (no plan appears), then "two physical
sites and like 50 PCs and i don't know how many phones" (2 routers, 4
switches, 50 PCs, a question about phones), then "I think we will need more
than 1 router and 1 switch and 1 server and it should be secure" (50 PCs
still there, server added, security question), then "ok build this network
then" - the confirmation names the discussed scale, not "1 router".
