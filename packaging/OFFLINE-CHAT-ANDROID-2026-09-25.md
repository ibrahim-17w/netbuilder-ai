# The keyless chat, and the app on a phone — 2026-09-25

Two things: what a conversation looks like when there is no model to answer
it, and what the app does on Android, where the .pkt engine cannot exist.
The networking engine itself is untouched — the planner, the adapters,
`pkt_builder`, GNS3 and the validator behave exactly as they did.

## What was wrong with the keyless chat

The offline assistant existed and answered, but it answered like a form:

* **Every answer opened with the same disclaimer** — "Answering offline - no
  API key needed." or "The AI model is unavailable (HTTP 429: ...), so I am
  answering offline." Read once it is useful; read on every turn it is a
  machine talking about itself.
* **It did not know what a turn was.** "thanks" got a plan dump, "yes" got a
  plan dump, and "and vlans?" got the generic "I just need a bit more to go
  on" — because a two-word message was treated as a fresh, empty request.
* **Its own advice was not true.** The build answer ends with "say \"use
  ospf\" to switch", but a follow-up that names no device kept the standing
  plan, so OSPF never arrived and the same static plan came back. A promise
  the app cannot keep is worse than no advice.
* **The answer described the wrong plan.** "Use OSPF" parses to an empty
  brief, and the parser's fallback invents a router and a switch — so the
  reply described a lab the user never asked for, not the one on screen.
* **Offline turns were never stored.** They were appended to the screen and
  nowhere else, so reopening a keyless conversation showed the user's
  questions with none of the answers: half the chat, gone.
* **The next steps named a screen that does not exist** ("Open the Build tab
  and paste the same request with \"Plan offline only\" on").

## What the offline chat does now

* **One notice, then conversation.** The offline line is said once per
  conversation (and a new model failure is reported once, then the
  conversation resumes).
* **Conversational moves.** Greetings are answered as greetings, with two
  deterministic variants so consecutive turns do not read identically.
  Acknowledgements ("thanks", "ok", "got it") keep the plan in view instead
  of re-planning it. "yes" confirms the lab on the table and points at the
  build action; "no" asks what to change. A short question that names a
  topic ("and vlans?", "why stp?") is a follow-up, and is answered as one.
* **Continuity.** The standing plan is named in one clause, plural-aware
  (`2 routers, 1 switch, 4 PCs, OSPF`), and a turn that changed it says what
  changed — "That updates the lab you had: +1 switch, routing is now ospf
  (was static)". A short follow-up is prefixed with "For the lab you have
  planned (...)" rather than restarting from nothing.
* **Advice that works.** `NetworkIntent.applyFollowUpChange` applies a
  protocol change to the standing plan: "use ospf", "switch to static
  routing" now do what the app says they do. It refuses when the message
  names devices (that is a re-plan, the parser's job) and when nothing would
  change, so it can never quietly rewrite a lab.
* **The answer describes the plan that stands**, not the one this message
  parsed to on its own.
* **Suggestions are taps.** The assistant's next steps appear as chips above
  the composer — "Build the .pkt", "Use OSPF for routing" — and each one is
  a message the app can actually act on: tapping "Build the .pkt" now
  compiles (the command path accepts that exact wording), and "Use OSPF for
  routing" changes the plan and says so.
* **The answer arrives at a reading pace**: 24 characters per 12 ms, one
  cancellable `Timer` at a time, finished (never dropped) when the next turn
  or the screen arrives.
* **Offline turns are written down** — message, session state and title — so
  a keyless conversation survives a restart.
* **Next steps point at this app**: press "Build the .pkt" on the reply,
  open the file in Packet Tracer, say what to change.

## Android: no sidecar, and no pretending

The engine is a Python program that drives a Packet Tracer window. A phone
has no Python process to start and no Packet Tracer to drive. That is a
fact, not a bug — and the app now says it instead of hunting for an
interpreter that cannot exist:

* `SidecarSupervisor.canRunLocally` (from `SettingsService.canHostEngine`)
  with `phoneEngineMessage` as the single sentence every caller uses.
  `ensureStarted` short-circuits on a phone, `searchRoots` returns nothing,
  and nothing is spawned or walked.
* `EngineStatus.canStartLocally`: `ensure()` refuses and reports where the
  engine actually is; the diagnostics report names the platform and whether
  it can host the engine at all.
* The chat banner keeps "Set address" and the recheck, and drops "Start
  engine" — a button that cannot work is worse than no button. The message
  names the trap: on a phone the address must be the PC, never
  `127.0.0.1`.
* The engine screen replaces the three process controls with the three steps
  that work: start it on the PC, find that PC's address, enter it here
  (`10.0.2.2` is the emulator's host).
* `AutopilotService.startHint` is platform-aware: a desktop keeps the Python
  steps, a phone gets the PC sentence. The hub's "Start the local engine
  now" capability does the same.
* **The back gesture closes the panel over the chat** (`PopScope`): a user
  who opened the conversation list on Android no longer has to discover the
  barrier tap to get out.

Already right, and deliberately left alone: the manifest (INTERNET, cleartext
for a LAN engine, `allowBackup=false` with the extraction rules), the
`10.0.2.2` defaults for the engine and GNS3, the mobile-wording engine hint,
the `/pc` command help, `.pkt` picking through `FileType.any` (Android
mishandles custom extensions), and the SQLite factory branch in
`MemoryService` (ffi on Windows/Linux, the platform factory elsewhere).

Testing a phone without a phone: `SettingsService.mobileOverrideForTests`.
Deliberately **not** `defaultTargetPlatform` — the widget-test binding
reports android for every test, so using that as the switch turned the whole
suite into phone tests (which is how the engine tests caught it).

## Verification

* `flutter analyze` clean; `flutter test` **483 passed**.
* `flutter build apk --debug` and `flutter build apk --release` both succeed
  (release APK 62.8 MB, icon tree-shaken) with the Android SDK 36 toolchain.
* New: `test/offline_conversation_test.dart` (17 cases: the notice said
  once, acknowledgements, continuity, the protocol change and its refusal
  cases, suggestions that are actionable) and `test/phone_platform_test.dart`
  (10 cases: platform facts, no spawn, the engine screen, the chat banner,
  the platform-aware hint — plus the same assertions on a desktop so the
  phone behaviour cannot leak into it). `test/chat_ui_test.dart` gained the
  keyless conversation end to end (answer stored, chip tapped, plan changed)
  and the back gesture.
* No physical Android device was available in this environment: the phone
  paths are proven by tests and by building the release APK, not by an
  install on hardware.

## What still needs a PC

Generating, repairing and auditing `.pkt` files, driving Packet Tracer,
GNS3 automation and OCR of the PT CLI all need the engine, so on a phone
they need a PC on the same network. The chat, the planner, the validator,
the memory and every screen work on the phone alone. The latency of a
`.pkt` job on a phone is the round trip to that PC; the app's own screens
never block on it (the engine probe is short and cached).
