# The simulation killer, and "fix every finding then build"

2026-10-01, Round 12. Reported as: *"when I try the simulation it doesn't work,
all messages show red X not green checkmarks"*, plus *"fix every finding you got
then build is still a no-op"*.

## 1. Why the lab was dead in Packet Tracer

The file the app built was **structurally complete and electrically broken**:

| check | result on `netbuilder-202610011111.pkt` |
| --- | --- |
| devices | 35 / 35 |
| cables | 34 / 34 |
| every cabled port powered | yes (`<POWER>true</POWER>`) |
| addressing | no duplicates, no overlap, gateways correct |
| OSPF / AAA config | present and spelled correctly |
| **cable kind on the two router-to-router links** | **`eStraightThrough`** |

A copper straight-through cable is only correct between a **switch port** and a
non-switch port. Two routers (or two switches, or two PCs, or a host straight
into a router) put transmit on the pin the other end transmits on, so the pair
needs a **crossover**. Packet Tracer holds both ports DOWN when it gets a
straight-through for such a pair: the cable is drawn red and every packet that
has to cross it is dropped.

Both transit links in the two-site lab were router-to-router
(`R1 g0/0 - R2 g0/0` and `R2 g0/2 - R3 g0/0`), so **the whole inter-segment
network was dead**: nothing at HQ could reach the branch or the second HQ LAN,
and the simulation panel showed a red X on every PDU that had to cross. The
screenshot's red `R2-R3` cable was the visible half of it.

Root cause: `NetLink.cable` exists, `LINK_MEDIUMS` knows `copper-cross`, the
provider prompt even tells the model to use it for like-device links - but the
deterministic planner only ever set it when the user typed the word
"crossover". Every other copper link fell through to the straight-through
default, including router-to-router.

### Fix

* `NetLink.pairNeedsCrossover(typeA, typeB)` - crossover when both ends are the
  same shape ("is a switch port" on both sides, or on neither). This is the
  physical rule, written once.
* `NetworkIntent.wiredLinks` - the plan's links with the cable kind filled in;
  an explicitly stated cable (serial, fibre, a crossover asked for by name) and
  any serial-interface link are left untouched. The revision does not hash the
  cable kind, so **existing build cards stay valid**.
* `PacketTracerAdapter.autopilotPlan` writes its `create_links` step from
  `intent.wiredLinks`, and that payload is the single choke point the offline
  compiler *and* the live run both build from - so both get the right cable.
* Sidecar: `pkt_audit.links()` now reports the cable kind, and
  `pkt_audit.cable_findings()` flags a copper link whose kind cannot carry
  traffic between those two devices (high) or a crossover where a
  straight-through belongs (medium, "may be held down").
* `pt_autopilot.pkt_audit_network` (the report behind **"Analyze this capture
  offline"**) runs that check and attaches it to the first device of the pair,
  and finally reports `linkCount`. The card used to say
  `Devices: 35, links: ?, findings: 0` - and "Nothing to fix: the saved
  configuration matches the topology" - about a lab where nothing routed.

### Verified end-to-end

* Old file, through the freshly installed frozen engine's `/pkt/audit`:
  `Devices: 35, links: 34, findings: 2 (2 high)` - both transit cables named.
* Same 35-device plan re-planned and rebuilt through the engine
  (`cable-e2e.pkt`): **2 crossovers (R1-R2, R2-R3), 32 straight-throughs,
  0 findings**. Kept at
  `Release/sidecar/_internal/pkt_output/cable-e2e.pkt`.

## 2. "fix every finding then build" is not a no-op any more

Three parts:

1. **`OfflineAssistantService.asksToBuildAfterRepair(text)`** reads the build
   half of `"fix every finding you got then build"`, `"repair the plan and
   compile it"`, `"fix everything and build"`. `_fixTarget` gained
   `everything|all`, so those phrasings are repair requests at all now.
2. **`chat_screen._handlePlanRepair`** runs the repair, then - only when the
   repaired plan has no blocking finding - builds it in the same turn. No
   second click on a card the user had already asked for.
3. **The reply is told about it** (`fixPlan(andBuild: true)`): it says
   *"I am compiling it"*, or *"I did not build it: these findings ... need your
   call"* with the one sentence that clears them.

`PlanRepairService` gained two more remedies, so more findings the app reports
are findings it can act on:

* **two cables on one interface** - keep the first claim, move the rest to a
  free port on the same device (a port can only hold one cable, and the second
  was silently dropped on the way into the .pkt);
* **a switch with more cables than ports** - move the overflow onto a switch
  that has room, and re-address what moved onto the LAN it now sits on (a move
  that would leave a device with no LAN is refused, not performed).

`_credentialRemedy` became `_remedyFor`: it still names the login sentence for
an account finding, and now also names the sentence that settles an
over-capacity switch, a device with no LAN, and missing VLAN work.

## 3. The visible `links: ?`

`chat_screen._linkCount` reads `summary.links`, `linkCount`, or the `links`
array - and the offline report now carries `linkCount` and `links`, so the
card says a number.

## Gates

* `flutter analyze`: clean.
* `flutter test`: **921 passed / 0 failed** (10 new in
  `test/simulation_cables_and_repairs_test.dart`).
* sidecar `pytest --ignore=test_ocr_perf.py`: **433 passed / 0 failed**
  (6 new: 4 cable-kind, 2 offline-audit card).
* Windows release rebuilt (`net_builder.exe`, engine `builtAt` 12:04);
  frozen engine reinstalled into `build/windows/x64/runner/Release/sidecar/`,
  `/health` ok, `pkt_output` artifacts preserved (copy over `_internal`, never
  delete it).
