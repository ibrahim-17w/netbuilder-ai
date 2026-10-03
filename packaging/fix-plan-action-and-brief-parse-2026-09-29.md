# "Fix the plan" that did nothing, and the brief it misread (2026-09-29)

## What the user hit

One prompt, three failures, in a keyless chat (model answered `HTTP 503: {}`,
so the offline planner took the turn):

> Build a corporate network for 40 users across 2 physical sites. Site A is the
> headquarters with 2 routers, 2 switches, 3 Server-PT devices (1 DHCP server,
> 1 AAA/TACACS+ server, 1 DNS+HTTP server) and 15 PCs. Site B is a branch with
> 1 router, 1 switch, 1 Server-PT device (the DHCP server) and 10 PCs. Use
> 192.168.10.0/24 at HQ and 192.168.20.0/24 at the branch, OSPF area 0, and set
> up AAA with the client name admin and password 123.

1. **The brief was misread.** The plan came back as 3 routers, 3 switches,
   **10 PCs**, 4 servers (20 devices) where the brief asks for 25 PCs. The "15
   PCs" of Site A had silently vanished.
2. **The plan could not be built.** Validation reported
   `Duplicate IP 192.168.10.1 on R1 and R1 g0/0` — a finding whose message did
   not even name the second interface, and which **no phrasing could clear**.
3. **Neither escape hatch worked.** Saying "fix the plan" in the chat got the
   same broken plan described back (the word "fix" was not a change verb, so it
   fell through to the build branch). The build card said "Fix the plan first"
   and the button was **disabled** — advice with nothing behind it. In a second
   attempt the same button reported the plan had "moved on" (rev `f68cea3b` ->
   `eb5b6232`) for an identical network.

## Root causes (each fixed)

| # | Finding | Where it lived |
| - | - | - |
| 1 | A count was treated as a **correction** when a correction cue appeared anywhere in its clause, including *after* the number. "…and 10 PCs. **Use** 192.168.10.0/24 at HQ" made the last PC count replace every earlier site count (25 PCs -> 10). | `_correctionCue` in `lib/services/nlu/slots.dart` |
| 2 | Stated CIDRs were handed out **in order to transit links first**. `192.168.10.0/24` went to the R1-R2 link, the HQ LAN was then derived from the same block, and the plan collided with itself. Derived LANs also did not skip subnets already in use. | addressing block in `lib/models/network_intent.dart` |
| 3 | The duplicate-IP message printed the second node bare and the first as "node iface" (`Duplicate IP … on R1 and R1 g0/0`): the interface that needed changing was the one thing it did not name. | `lib/services/validator_service.dart` |
| 4 | The plan revision hashed the **project name**, so the same network planned as `chat` (model path) and `offline-chat` (keyless path) had two revisions. A build card written by one path was then "stale" against the other path's copy of the identical plan — the `Fix the plan first` button in the second screenshot. | `NetworkIntent.revision` |
| 5 | Nothing could **act** on a blocking finding: "fix" was not a change verb in the offline assistant, and the card's button was disabled. A 35-device plan was also refused because "Large topologies are slow in Packet Tracer autopilot" carried warning severity — advisory text that no phrasing could clear. | `lib/services/offline_assistant_service.dart`, `lib/screens/chat_screen.dart`, `lib/services/validator_service.dart` |
| 6 | One 503 from the provider ended the whole turn in the offline fallback. | request paths in `lib/services/chat_service.dart` / `openai_chat_service.dart` |

## What changed

1. **A correction cue must precede the count** (`_correctionBefore`), in the same
   clause: "actually 8", "make it 16 PCs", "use 2 routers" still correct;
   "…10 PCs. Use 192.168.10.0/24" no longer does. The reported brief now plans
   25 PCs, 3 routers, 3 switches, 4 servers.
2. **Stated subnets are placed where they belong.** A stated `/30`+ is a
   point-to-point link; anything wider is a LAN. Transit links that have no
   stated subnet take their own `10.0.0.x/30`. A LAN subnet qualified with a
   site word ("…/24 at the branch") lands on the LAN of the routers the brief
   put at that site (`BriefSlotPipeline.siteRouterCounts`), further LANs at the
   same site continue in the same block, and every derived subnet skips ones
   already in use. The reported brief now gives HQ `192.168.10.0/24` +
   `192.168.11.0/24`, the branch `192.168.20.0/24`, and no duplicate address.
3. **The duplicate-IP finding names both sides** and says what to do.
4. **`revision` no longer hashes the project name** (the rest of the hash, and
   its documented intent, are unchanged), so the two chat paths agree on the
   plan identity and cards stop going spuriously stale.
5. **New `PlanRepairService`** (`lib/services/plan_repair_service.dart`): a
   deterministic, offline repair pass over the blocking findings — an interface
   with two addresses keeps the first; a duplicate address moves to a free host
   on its own LAN (or the next free `/24`); a device needing Desktop > IP
   Configuration gets the next free `.10+` host on the LAN it is cabled to; an
   uncabled device is cabled to a switch with a free port. It reports exactly
   what it changed and never papers over what it cannot fix.
6. **"Fix the plan" now works, everywhere:**
   - the chat runs the repair *before* any model is consulted (so it works with
     or without a key) and answers with what changed;
   - the build card's blocked button is enabled, reads **"Fix the plan"**, and
     sends that turn — a fresh card stamped with the repaired plan comes back;
   - the offline assistant routes repair instructions ("fix the plan", "fix
     these", "can you fix it?", "solve the errors") to the same path and hands
     the repaired plan back to the caller (`AssistantReply.repairedPlan`);
   - the size heads-up is now `info` rather than a blocking warning, so a large
     but correct plan is buildable.
7. **A momentary provider failure is retried** (`AiRetry`, 3 attempts, 700ms /
   1.4s backoff) for 429 and 5xx on all four request paths (Gemini and
   OpenAI-compatible, streaming and one-shot). Only the *first byte* is
   retried, so a stream that has already started is never duplicated.

## Verification (this working tree)

| Check | Command | Result |
| - | - | - |
| Analyzer | `flutter analyze` (all touched files) | No issues |
| Reported brief | `flutter test test/chat_plan_repair_test.dart` | 19 passed |
| Provider retry | `flutter test test/ai_retry_test.dart` | 7 passed |
| Full suite | `flutter test` | **828 passed, 0 failed** (26 tests added) |

Concrete outcomes pinned by the new tests: 25 PCs / 3 routers / 3 switches /
4 servers with DHCP+AAA+DNS+HTTP roles; HQ LANs `192.168.10.1` and
`192.168.11.1`, branch `192.168.20.1`; no duplicate address; no blocking
findings for the reported brief; the offline answer says "25 PC(s)" and offers
`Build the .pkt`; a duplicate-address plan repairs to a clean plan and the
answer says "Fixed 1 thing(s)".

## Known limitations (not hidden)

- Findings only the user can settle (a serial WAN that needs an HWIC-2T module,
  VLAN 1 in use, a missing credential) are reported as still blocking; the
  repair says so and asks for the decision instead of guessing one.
- A repair is conservative on purpose: it never re-plans the topology, so a
  wrong-but-consistent network (e.g. a device cabled to a crowded router port)
  is left alone.
- The build card's new button is covered by unit tests of the repair path, not
  by a widget test: the chat screen's turn does not complete in the widget-test
  environment (settings load and the memory DB are unavailable there), so a
  card cannot be rendered in a test yet.
- Mobile/native release binaries were not rebuilt in this round.

## Rollback

All edits are uncommitted. To back out:
1. Revert `lib/services/nlu/slots.dart`, `lib/models/network_intent.dart`,
   `lib/services/validator_service.dart`,
   `lib/services/offline_assistant_service.dart`, `lib/screens/chat_screen.dart`,
   `lib/services/ai_provider.dart`, `lib/services/chat_service.dart`,
   `lib/services/openai_chat_service.dart` to their pre-round state.
2. Delete `lib/services/plan_repair_service.dart`,
   `test/chat_plan_repair_test.dart`, `test/ai_retry_test.dart`.
3. `flutter test` to confirm the previous behaviour (828 - 26 = 802 tests).

## Re-verify by hand

```
cd C:\ai\app
flutter analyze
flutter test test/chat_plan_repair_test.dart test/ai_retry_test.dart
flutter test
```

In the app: paste the corporate brief above -> the answer counts 25 PCs and
offers "Build the .pkt" with no "Fix these first" list, and the topology shows
`192.168.10.1` / `192.168.11.1` at HQ and `192.168.20.1` at the branch. Then
type "fix the plan" in the same conversation -> the answer says nothing blocks
the build and offers a fresh card.
