# The chat surface and conversational memory — 2026-09-25

Two parts of the app, and nothing else: the chat UI/UX and the
memory/context system. The networking engine is untouched — the planner
(`NetworkIntent.parseSimple`), the Cisco/Packet Tracer adapters, `pkt_builder`,
GNS3 and the validator's rules behave exactly as they did before; what changed
is how their output is presented and what the model is actually sent.

## Why the chat "forgot"

The symptom was a Settings ceiling of 1,024k tokens and a model that
remembered one or two messages. The cause was two different numbers
wearing the same name. Requests were assembled against the **configured
budget** (default 262,144; the UI accepts up to 1,048,576), while the
**runtime** allocates its own window: Ollama's default `num_ctx` is 4096,
and its OpenAI-compatible `/v1/chat/completions` ignores a per-request
`num_ctx` entirely. The window is whatever `OLLAMA_CONTEXT_LENGTH` or the
Modelfile's `PARAMETER num_ctx` says. An oversized prompt is truncated by
the runtime, and truncation keeps the newest turns — so the front of the
conversation vanished while the app's own numbers said there was room.

The chip was therefore honest about the plan and wrong about the request.
Everything below follows from that: find out the real window, and fit the
request to it.

## The runtime window

`lib/services/runtime_window.dart` (new) is the fix's core.

* `RuntimeWindow` carries the tokens, the model's own ceiling when
  published, the source, whether the number is certain, a note, plus
  `isAssumed`, `hint` and `effectiveBudget`.
* `RuntimeWindowProbe` asks the runtime that will actually serve the
  request (Ollama's `props`, `ps` and `show`). Parsing is one pure
  function taking a string and a map, so it is unit-tested without a
  server.
* Every fallback is the conservative direction: `conservativeLocal = 4096`
  (Ollama's documented default), `floorTokens = 2048`, and
  `remoteAssumed = 262144` for a remote gateway. `certain` is false when
  the number is an assumption, and the chip says "assumed" rather than
  printing a confident fiction.
* Probed on load (app start, opening a chat, starting a new one) and
  re-checked whenever the endpoint, the model or the user's override
  changes, so pinning a window takes effect without restarting the
  conversation.
* Settings → *Chat context* now has a **Runtime window** control
  (Detect automatically / 2k … 256k) whose helper text names the caveat:
  raise the real window with `OLLAMA_CONTEXT_LENGTH`, or a `PARAMETER
  num_ctx` in the Modelfile — a per-request `num_ctx` is ignored by that
  endpoint.

## The planner fits the request to it

`lib/services/context_budget.dart` (rewritten):

* A plan is fitted to `min(configured ceiling, runtime window)`, and the
  window used, with its source, travels with the plan.
* The system prompt is **measured**, not assumed — it used to be
  unaccounted for entirely. When it alone is too big it is trimmed with a
  note rather than silently overrunning the window.
* Optional blocks (retrieved memories, the network block) share a cap of
  `sectionFraction = 0.4` of the window.
* `summaryReserveTokens = 900` is held back **before** the history walk.
  This is the fix for the summary that could never fit: the reserve was
  computed after the walk, so history always ate the space it needed.
* The output reserve is subtracted from the window, and the final clamp
  can never exceed it.
* Every exclusion is recorded as a note on the plan, so the inspector can
  explain the request instead of merely describing it.

`lib/services/context_report.dart` (new): `RequestReport` is one request's
breakdown by section — turns sent verbatim, turns compacted, truncation
notes, percentage of the window — with `toText()`. `RequestLog` keeps the
last 20 in memory and prints a request to the debug console when the
Settings toggle is on; `context_debug` now really sets `RequestLog.verbose`
(previously the setting was read but never consumed).

## Three layers of memory

1. **A deterministic summary** (`conversation_memory.dart`): bounded
   asks (12, plus an explicit "earlier request(s) omitted"); pinned
   technical facts are read from user *and* assistant turns (addresses,
   models, VLANs, devices, interfaces) and kept verbatim.
2. **Structured session state** (`session_state.dart`, new): project,
   focus, source/destination, the problem, confirmed and open findings,
   changes made and proposed, topic, last message id. `promptBlock({
   userText})` is relevance-filtered — project, problem and the last
   change always ride along — and `devicesIn` understands both the
   `R1/SW1/PC1` and the `Router0/Switch1/PC0` spellings. It survives a
   restart: decoded from the conversation's stored JSON and replayed over
   the transcript.
3. **Retrieved long-term memory**: the app queries the store for the
   turns that matter to the current message (keyword retrieval over
   builds and attempts) and injects them as a bounded block. The context
   inspector names what was injected this turn.

Underneath: schema **v5** adds `conversations` (title, project, summary,
`summaryUpToId`, `stateJson`) and `changes` (the change log — device,
interface, field, old → new, source, undone). Search in the list hits the
title *and* the message text. Titles are generated deterministically
(`conversation_titles.dart`), and a rename is honoured over them.

## The chat surface

* **Conversation first**: a 268px list with New chat, a database-backed
  search, time groups (Today / Yesterday / Previous 7 days / Previous 30
  days / Older), rename and delete. It collapses to a rail, and on a
  narrow window it slides over the chat instead of squeezing it.
* **A welcome screen, not an empty box**: "What can I help you
  troubleshoot?", with five openers that fill the composer.
* **A real activity panel** (`chat_activity.dart`): entries come only from
  operations that actually ran — tool events, validator passes, `.pkt`
  reads — each marked ✓/!/✗, headed by what happened ("Checked the network
  - found 2 issue(s)"). A plain question produces no panel at all, and
  there is no generated reasoning text in it.
* **An optional network inspector** (≥1240px): devices, interfaces and
  addresses, VLANs, routing, security controls, the validator's own
  issues, and the change log with exact old → new values.
* **The context chip tells the truth**: plan size against the real window,
  whether the window was detected or assumed, how many turns were
  compacted, and an expandable report with the per-section breakdown, the
  truncation notes and the memories injected.
* **Undo without the model**: a change is recorded with its exact previous
  value when it is sent, and undo looks it up and reverts it locally —
  no model call, no guessing which route was there before.
* Two small corrections found while testing: the conversation-list toggle
  uses `Icons.view_sidebar_outlined` rather than a second hamburger beside
  the app drawer's, and the settings drawer's dropdowns are `isExpanded`
  so the longest item cannot overflow the sidebar at large text sizes.

## Verification

* `flutter analyze` clean; `flutter test` **453 passed**.
* New: `test/context_memory_test.dart` (28 cases — probe parsing, a
  4k-window regression, the report, session-state follow-ups, summary
  bounds), `test/conversation_store_test.dart` (metadata, search, delete
  cascade, change log and undo, titles), `test/chat_ui_test.dart` (12
  cases — sidebar and grouping, search by message text, collapse and
  reopen, the narrow overlay, the welcome screen, the activity panel, the
  inspector, the context chip), and `test/settings_drawer_test.dart` now
  covers the context controls.
* Widget tests use a fake store on purpose: real sqflite I/O inside a
  widget test hangs `pumpAndSettle`. The real schema is exercised against
  the database itself in `conversation_store_test.dart`.
* Expectations updated where the UI moved: `chat_landing_test.dart`,
  `app_shell_test.dart`, `openai_provider_test.dart`.

## Limits

* Token counts are estimates (chars/4 with per-section rules), not a
  tokenizer. They are for fitting and explaining, not for billing.
* The probe speaks the local runtime's HTTP API. A remote endpoint is
  planned against 262,144 unless a window is pinned — and the chip says
  "assumed" while that is true, so the number is never quietly wrong.
* The summary is deterministic, not model-written: it preserves technical
  values and the shape of the conversation, and it will not paraphrase the
  way a model would.
* A runtime whose window changes mid-session (someone restarts Ollama with
  a bigger `OLLAMA_CONTEXT_LENGTH`) is picked up on the next probe — load,
  model change or override change — not on every single message.
