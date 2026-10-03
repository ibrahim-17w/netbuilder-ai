# Diagram layout + headcount confirmation - 2026-09-29

Two defects reported from the same 35-device build
(`netbuilder-202609292127.pkt`, a 40-user two-site brief).

## 1. The canvas layout was a parts list, not a diagram

**Reported:** "it put all of them on top each other at the end so I can't see
what devices it added."

**What the file actually contained:** decoded from the user's own save, the
offline generator placed the 3 routers on y=120, the 3 switches on y=300, and
then *all 29 end devices* - 25 PCs and 4 servers - on one row at y=480, x from
240 to 5,840 in 200-pixel steps. Every link from a switch fanned back to one
point.

**Cause:** `pkt_builder.layout_positions` banded devices by type only. A band
with more devices than fit in a row wrapped, but the band's own width was
`devices x 180`, so 29 end devices became a 5,840-pixel line regardless of the
topology that connected them.

**Fix:** the layout is now driven by the plan's OWN link list, the way a network
engineer draws a site:

* tiers - core (routers/firewalls/cloud) → aggregation (L3 switch/WLC) → access
  (2960) → servers → hosts;
* a device's parent is its neighbour one tier closer to the core, so an access
  switch hangs under the router it uplinks to and hosts cluster under the
  switch that serves them;
* a parent is centred over its children, sibling sub-trees get their own column
  of canvas, and a block with more hosts than fit on one row wraps four to a
  row;
* a link between equals (two routers on a WAN, two switches trunked) does not
  nest them: they stay on their tier's row, side by side, which is how the two
  sites of a site-to-site lab are drawn;
* only the tiers a plan uses get a band, so a router/switch/PC lab is compact.

The same file, relaid out: R1/R2/R3 on y=60, SW1/SW2/SW3 on y=250 directly
under their own router, the 4 servers on y=440 under SW1, the PCs in 4-wide
blocks under their own switch (200-560, 830-1190, 1460-1820). Widest span 1,820
instead of 5,840; 35 devices, 35 distinct points.

## 2. "40 users" vs the 25 PCs it built

**Reported:** the brief asked for a network for 40 users and the app built 25
PCs.

**Answer:** the 25 were literal - the brief also said "15 PCs" at the HQ and
"10 PCs" at the branch - so the build was not wrong, but it was SILENT. Nothing
in the answer, the assumptions or the plan mentioned the other 15, and the
audit of the file said "nothing to fix". A headcount and a device list that
disagree is a decision for the user.

**Fix (at the user's direction: options, not prose):**

* `NetworkIntent.statedUserCount` reads the headcount the brief states ("for 40
  users", "12 staff"), narrowly - a subnet question, a credential and a server
  role are not headcounts;
* `NetworkIntent.headcountPrompt` compares it with the desks the plan seats
  (PCs + laptops) and, when they disagree, attaches a `PlanPrompt` to the plan
  plus one assumption saying what was built and what it was sized for;
* the chat screen shows the prompt as a **list of options directly above the
  message box** - title, the reason, then one chip per answer, the recommended
  one first and ticked: **"Add 15 PCs (make it 40)"** or **"Keep the 25 PCs I
  listed"**. A modal dialog was tried first and rejected: it covers the very
  plan the question is about. The chip that changes the plan sends its reply as
  the user's own next message, so the change travels the same planning path a
  typed request does; "keep" changes nothing. One answer per disagreement,
  remembered for the conversation.

## 3. Why the first fix looked like it had done nothing

The user rebuilt after the layout fix and got the same flat line. The cause was
not the layout: **the app was still talking to the engine process from 20:08**,
started before the rebuilt executable was installed at 22:15. The app reuses
whatever answers on `127.0.0.1:5005`, and that process was still serving the old
code - so the rebuild produced the old picture and the fix looked like a no-op.

Fixes, so an update can never look like that again:

* the engine reports what it IS on `/health` - `engine: {pid, file, builtAt,
  frozen, version, layoutRevision}` - with `builtAt` captured at import time, so
  a process keeps reporting the build it actually started from even after the
  file on disk has been replaced under it;
* `EngineStatus.isStaleEngine` compares the answering engine with the one this
  build ships, conservatively: nothing shipped (a dev checkout) = nothing to
  compare; an engine reporting no identity at all predates the field and IS
  older; a reported identity is only judged when the file is this app's own
  engine, so a sidecar somebody started by hand is never killed;
* on start, a stale engine is replaced automatically: `SidecarSupervisor`
  finds the pid from the engine's own report (`netstat -ano` fallback, parsed
  by a tested pure function), kills it, waits for the port to go quiet and
  starts the shipped engine; if the pid cannot be found, the Engine screen says
  so instead of pretending;
* `pkt_builder.LAYOUT_REVISION` (now 2) travels in that identity, so a change
  to the drawing is a number rather than a hope.

## Gates

* `flutter analyze`: clean.
* Dart: **844 passed / 0 failed** (new: `test/headcount_prompt_test.dart`, 7
  checks - including "the option really produces 40 PCs"; new
  `test/engine_staleness_test.dart`, 9 checks on the stale-engine rules and the
  netstat parsing).
* Sidecar: full suite except the pre-existing `test_ocr_perf.py` environment
  failure - **358 passed, 0 failed, 0 errors**. The layout assertions were
  rewritten from a hard-coded coordinate pair to the rule (tier order, parent
  centring, block width, distinct points) plus a 35-device regression test
  covering the reported brief.
* Frozen engine rebuilt with PyInstaller and installed into
  `build/windows/x64/runner/Release/sidecar/`; verified by reading
  `layout_positions` back out of the frozen PYZ (new constants, no `ROW_Y`), and
  by checking the new app.so carries the new strings.
* END-TO-END, through the running engine's own API: the reported plan was
  regenerated with `POST /pkt/generate` (35 devices, 34 links) and the file
  decoded again - the routers on one row, each switch under its own router, the
  servers under SW1, the PCs in 4-wide blocks under their own switch, x span
  200 -> 1820 in 6 rows instead of one 5,840-pixel line. That check file is
  kept as `sidecar/_internal/pkt_output/layout-check-*.pkt` so the drawing can
  be opened in Packet Tracer directly.
