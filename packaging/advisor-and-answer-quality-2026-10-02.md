# The advisor and answer quality - 2026-10-02

## Why

The app planned labs and answered how-to questions, but a plain design
question - the user's own example, *"what router should I use in this
case?"* - was answered badly:

* `NetworkIntent.classifyBrief` had no advice kind, and `_readsAsNonPlanning`
  read the sentence as a specification ("use" is a change verb), so the
  question could re-plan the lab it was asking about;
* `OfflineAssistantService._openQuestion` refused the missing-coverage reply
  whenever the text named a router/switch/lab, so the question fell through
  to a plan dump (or, with no plan, to "I need a bit more to go on");
* `OfflineKnowledge` had no hardware selection, sizing, ISP or vendor
  content, and `ChatService.systemContext` gave the model how-to rules but
  no advisory contract.

## The contract

An advisory answer is:

1. **a recommendation first** - what the advisor would actually do;
2. **2-4 options**, each with a "choose this when" and its trade-off;
3. **grounded**: the reasons use the user's own scale (users, rooms,
   budget) and the plan on the table (real device counts, Packet Tracer
   models), so one answer serves the lab and the real world;
4. **at most two questions**, and only ones whose answer changes the
   recommendation;
5. **one next step**, plus quick replies that are all actionable;
6. **provenance**: `Based on:` says whether the answer stands on the lab on
   the table, the simulators, or the user's description of their site - and
   real-world gear is explicitly "named as examples; check current prices";
7. **read-only**: advice never mutates the plan. Nothing in
   `AdvisorService` returns a plan, and `AdviceAnswer.planBrief` is only
   offered when there is no lab yet.

No prices, no invented part numbers or availability. Gear is named as
classes, with vendor examples where they help.

## Where the pieces live

| Piece | File |
| --- | --- |
| `AdviceKind` + `AdviceIntentReader` (taxonomy) | `lib/models/network_intent.dart` |
| Reader consulted by `_readsAsAdvice` so advice keeps the plan | same |
| `AdvisorService`, `AdviceAnswer`, `AdviceOption`, topics | `lib/services/advisor_service.dart` (new) |
| Routing: advice before capabilities and before `_openQuestion`/`_buildAnswer` | `lib/services/offline_assistant_service.dart` |
| Advisory contract for the model (Gemini + OpenAI paths) | `lib/services/chat_service.dart` (`systemContext`) |
| Real-world vocabulary so gear/ISP questions are never declined | `lib/services/scope_gate.dart` |
| "The plan is untouched" on the Understood card | `lib/services/message_understanding.dart` |

### Topics (21 + the design review fallback)

router selection, firewall selection, router-vs-switch, switch selection,
access points/mesh, Wi-Fi generations, PoE budgets, camera networks, ISP
edge (PPPoE, CGNAT, double NAT, static IP), guest Wi-Fi, segmentation
("should X be on its own VLAN?"), remote access (port forward vs VPN vs
DMZ), VPN types, cabling (copper/fiber/wireless bridge), L3-vs-router,
backup WAN, server placement, rack + UPS, lab models (Packet Tracer/GNS3
Cisco device choice), slow-Wi-Fi triage, generic sizing (bandwidth/ports/
APs computed from the stated count), and a design review for "what do you
recommend?" with no object named.

### Taxonomy guards

* a stated device count stays a BUILD when the sentence asks to build
  ("recommend 2 routers and 4 pcs" plans) - but a count inside a pure
  question is the subject of the advice ("what switch do I need for 30
  PCs?") and does not re-plan anything;
* configuration questions stay how-to ("what cable do I use between two
  switches" belongs to the knowledge table, not to switch selection);
* "layer 3 switch" is not a count: `_deviceCountWording` has a negative
  lookbehind for `layer`.

## Answer-quality guarantees (Phase 2)

* `test/advisor_golden_test.dart` - **60 questions** across home / office /
  school / clinic / cafe / industrial / lab / comparisons / design, each
  asserting the recommendation, options with trade-offs, ≤2 questions, a
  next step, provenance, `intent == 'advice'`, **plan immutability**, and
  that every quick reply is a real next step (never `vague`, `missing` or
  `offtopic`).
* `test/advisor_test.dart` - the routing and boundary battery, including
  "a router question does not re-plan the standing lab".
* `test/offline_intelligence_test.dart` - the `answers(...)` battery gained
  the advisor lines, so "answers offline" remains a measured claim.
* `ChatService.systemContext` is pinned by a test: the model path must carry
  `ADVICE GETS A RECOMMENDATION`, `ADVICE NEVER CHANGES THE PLAN` and
  `NO INVENTED PRICES OR STOCK`, so a key adds depth, not a different
  contract.
* The battery found and fixed a real parser crash: a brief that parses to
  an edge device only (`"should i use ... cloud services?"` -> Cloud-PT
  with no router/switch/firewall) called `switches.first` on an empty list
  and threw into the chat's catch-all.

### Sharpening pass (reviewing real replies, then fixing them)

`test/zz_preview_advice_test.dart` prints the full reply for twelve real
prompts through `OfflineAssistantService.reply` - the same entry the chat
uses - so the answers can be read, not just asserted. Reading them led to:

* **lab-first leads**: router, firewall and switch recommendations open
  with `For the lab on the table (...), the models are the ones Packet
  Tracer ships ... for the real hardware behind your question:` when a
  plan exists, instead of answering only the real world;
* **a direct verdict on Wi-Fi 5/6/7** - the recommendation now says the
  generations cannot be told apart by speed at home, pick by clients-per-AP
  and keep every AP on one generation;
* **AP math from the dense end** - one AP per ~25 active devices stated as
  an explicit number (`$aps AP(s)`) with the ~50-per-AP light-use case
  beside it, so the sizing answer is countable, not vibes;
* **every chip on-topic and answerable** - slow-Wi-Fi gained "Is mesh or
  wired access points better?", camera advice gained "How many cameras can
  a PoE switch handle?", and a plan review gained "Should I segment this
  plan into VLANs?"; the golden battery asserts no chip is dead-end.

## Accessibility (Phase 3, started)

* Quick-reply chips are exposed as `Suggested next step: <message>` with
  `button: true` and an `onTap`, so a screen reader hears what a tap sends
  rather than only the label.
* The typing bubble has `Semantics(label: 'The assistant is answering',
  liveRegion: true)`.
* `test/chat_ui_test.dart` drives the chat with `ensureSemantics()` and
  asserts the chip label really reaches the semantics tree.

## CI (Phase 3)

`.github/workflows/ci.yml` now runs the **whole pure-Python sidecar suite**
with coverage, not two files. The seven tests that need the Windows RPA/OCR
stack are deselected by name. The list was measured, not guessed: running
the suite in a clean venv with only `pytest pytest-cov` installed (exactly
the CI dependency set) leaves those 7 failures - **470 passed, 17 skipped,
7 deselected** - and `sidecar/.coveragerc` keeps the report to the modules.
The one casualty that exposed (`test_link_evidence_requires_a_real_dark_
corridor` imports Pillow to fabricate its fixture image) now
`pytest.importorskip("PIL.Image")`s, so it skips honestly instead of erroring
in CI. Locally, with the full stack installed: **493 passed**, plus the
pre-existing environment-only `test_golden_ocr` baseline diff.

## Release build (verified)

* `flutter build windows --release` ->
  `build/windows/x64/runner/Release/net_builder.exe`, with `data/app.so`
  rebuilt from this source (the launcher exe itself is unchanged - Flutter
  ships Dart code inside the DLL);
* the packaged app launches and stays up: alive at 15s and at 60s (~92 MB
  working set, main window present), and the Windows Application log / WER
  queue show **no** error or crash record for it;
* prompt-level behaviour was verified through
  `test/zz_preview_advice_test.dart`, which drives twelve representative
  prompts (lab, office, home, cameras, Wi-Fi 7, CGNAT, design review)
  through `OfflineAssistantService.reply` - the exact code path the chat
  runs keyless.

## Still open

* Environment profile (home/office/school, scale, budget, skill) remembered
  across turns and reviewable on the Memory screen - the advisor re-derives
  it from each message today.
* A dedicated advice card with a highlighted recommendation and a "Plan
  this" button (the markdown table + tappable quick replies cover the
  function today).
* Arabic/RTL as its own track (`flutter_localizations`, ARB extraction,
  RTL audit that keeps topology canvases LTR).
* The rest of the platform sweep: `ChatTurnRouter` owning branch order,
  file splits, streaming performance and the 1,000-message benchmark,
  `SecretVault` on every build path, routing trace/diagnostics bundle,
  packaging fix, mobile advisor.
