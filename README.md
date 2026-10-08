# NetBuilder AI

A local-first network builder: describe a lab in plain language and the app
turns it into a validated plan, compiles it into a real Packet Tracer `.pkt`
offline, and can drive Packet Tracer or talk to GNS3 to build and verify the
topology step by step.

It works with **no API key at all** - planning, the offline assistant, subnet
math and `.pkt` compilation all run locally. A Gemini API key is optional and
only adds model-written chat answers on top.

## Features

- **Chat that plans.** "2 routers, 2 switches and 50 PCs with OSPF" becomes a
  validated plan the app can explain, edit and build. Quantities across
  clauses, corrections ("actually 8"), "more than N" floors, multi-site
  briefs ("two sites and 50 PCs") and follow-ups ("add an AAA server as
  well") are all understood offline.
- **Offline intelligence.** With no key and no network, the assistant
  answers the networking corpus: config steps (SSH, port security, DHCP
  snooping, HSRP, OSPF auth...), troubleshooting ladders, Packet Tracer
  basics - and actually computes subnet facts, wildcard masks, summaries and
  reverse-DNS names.
- **Advice, not just builds.** Ask the design questions too: "what router
  should I use in this case?", "how many access points for 50 users?",
  "fiber or copper between two buildings?" - the offline advisor answers
  with a recommendation first, 2-4 options each carrying a "choose this
  when" and its trade-off, sizes computed from your own numbers, and the
  lab answer next to the real-world one. It never edits the plan, never
  invents prices, and every answer states what it is based on (the lab on
  the table, or "the gear is named as examples - check current prices").
  The answer renders as an advice card: the recommendation highlighted,
  and a **Plan this** button that sends the advisor's plan-able sentence
  through the normal pipeline (parse, validate, build card) when there is
  a plan to make.
- **It remembers your environment.** "This is for the office, 40 users,
  I'm a beginner" is folded into one remembered profile - venue, scale,
  budget, skill - that the advisor falls back to whenever a later message
  leaves a fact unsaid (a stated fact always wins). Review and edit it on
  the Memory screen's **Environment** tab; forget it with one tap.
- **Offline `.pkt` compilation.** "Build the .pkt" writes a real, openable
  file - no Packet Tracer window needed - and then audits it back and reports
  whether the file matches the plan.
- **Tap the file, see the network.** The `.pkt` path in a build answer is
  tappable. With Packet Tracer installed, the OS hands the file over and the
  real application opens it; where Packet Tracer was not found, the same tap
  opens the built-in viewer - the network drawn Packet Tracer-style from the
  plan the conversation built, at the positions the engine wrote into the
  file. No shell dialog asking how to open an unknown file type.
- **Skills at `/`.** Type `/` in the composer and the skill menu opens:
  read and write .pkt files, switch targets (GNS3, the real Packet Tracer
  window, Cisco over SSH, AWS VPC), design advice, subnet facts,
  troubleshooting - or `/skills` for the whole list in the chat. And with
  a key set, "build the .pkt" behaves exactly as it does without one: a
  plain build request compiles before any model is consulted, and the
  model prompt teaches the build card for everything else.
- **PT Autopilot (optional).** With Packet Tracer installed, a local Python
  sidecar drives the window: it clicks, types, verifies each step on screen,
  and is **fail-closed** - a step that cannot be proven is reported, never
  assumed.
- **Targets**: GNS3 (default), Cisco via SSH, Packet Tracer, AWS VPC - chosen
  in Settings.
- **Validator before everything.** Plans are validated locally before a file
  is written or a device is touched; a plan with findings is stopped with the
  findings spelled out.
- **Memory with control.** Learned rules, phrasing memory and a repair
  ledger live in a local database; you can review, teach, and forget.
- **Learning that runs itself.** After a run that keeps failing the same way,
  the engine proposes a fix and (with a Packet Tracer window present) proves
  it on screen - no button press. A fix is still only promoted after it
  verifies; the fail-closed rule is unchanged. Stuck steps are excluded from
  the next plan instead of being regenerated. Settings > **Learn
  automatically** controls it.
- **Works with no key.** With no Gemini key the engine still learns: a local
  table of Packet Tracer command quirks proposes a supported spelling and is
  trusted only once the terminal stops erroring.
- **Memory health.** The Memory screen shows every learning store's row count
  and flags one that failed to parse and silently loaded empty.
- **Exports & adapters**: Cisco IOS config, Packet Tracer config, GNS3
  topology, Terraform.
- **Pick the drawing before you build it.** "Choose a layout" shows every
  drawing the engine can make - site trees, wide, compact, straight rows -
  as live previews of *your* plan, side by side. Enlarge one for a full
  draggable view, pick it, and the build uses exactly that picture (the
  preview and the built `.pkt` share the same geometry).

## Requirements

- Flutter SDK (Dart ^3.12) for building/running from source.
- **Windows** for the Packet Tracer autopilot (it uses `pywinauto`).
- Python 3 for the sidecar engine: `pip install -r sidecar/requirements.txt`
  (`pyautogui`, `pywinauto`, `pillow`, `pynput`).
- Packet Tracer itself only when you run the autopilot or open the generated
  files. Nothing else needs it.

## Getting started

```powershell
flutter pub get
flutter run -d windows          # development
flutter build windows --release # a release build to run against
```

The app starts and stops its own engine (the Python sidecar) and shows the
engine status in the app; there is nothing to launch by hand. Windows
installer scripts live in `packaging/` (`build_installer.ps1`,
`installer_install.cmd`).

### Optional: a Gemini key

Settings > model key. Keys are stored in the OS secure storage, never in
logs. Without a key the app stays fully usable: chat falls back to the
offline assistant and says so.

## Using it

1. **Describe the lab** in the chat (or open a saved one). Watch the plan
   card: it shows what was understood, its confidence, and any open questions.
2. **Fix anything** by saying so ("use OSPF instead of static", "make it 2
   routers and 20 PCs"). Corrections stick for the conversation.
3. **Build the .pkt** - compiled offline, with a preflight (target, plan,
   open assumptions) and a post-build verification that reads the file back
   and compares it with the plan.
4. **Open it in Packet Tracer**, or use **Analyze** / the Network Inspector /
   the Action Hub for audits, validation, exports and diffs.
5. To have the app do the clicking too, run the **autopilot** against an
   open Packet Tracer window; every action it takes is verified on screen
   before it is reported as done.

## Where your data lives

- Memories, chat history, rules: `%USERPROFILE%\Documents\netbuilder\memory.db`
- API keys: OS secure storage (Windows Credential Manager via
  `flutter_secure_storage`).
- Built `.pkt` files: the engine's `pkt_output` folder, each with a
  `.netbuilder.json` manifest recording what the plan asked for. In-place
  edits keep a timestamped backup of the previous file.
- App preferences: `shared_preferences` under the app's roaming data.

## Troubleshooting

- **"Engine not running"** - the sidecar needs Python 3 with the packages
  above. The app shows the engine log; on phones the engine must run on a
  machine on your network (Settings > engine address).
- **A step is reported instead of completed** - that is the autopilot's
  fail-closed rule: it could not prove the screen matched, so it stopped
  instead of guessing. Read the report; nothing was assumed.
- **"The plan contains more than 50 devices..."** - plans above 50 devices
  are refused as unsafe/likely misparsed. Split the lab or reduce counts.
- **The model answered "the engine is unavailable"** - the request model
  failed (offline, rate limit); the message says which. Chat keeps working
  offline.
- **A truncated model reply** - the app keeps the readable part and says the
  answer was cut off; it never dumps raw JSON on screen.

## Development

- `flutter test` - the app test suite (planning, chat, UI, adapters).
- `flutter analyze` - static analysis.
- `sidecar/` - the Python engine (with its own pytest suite).
- Layout: `lib/models` (plan/intent), `lib/services` (planner, validator,
  offline assistant, knowledge, adapters, memory), `lib/screens` (chat and
  tools), `sidecar/` (autopilot + `.pkt` codec/builder).

## Safety

- Nothing is typed into Packet Tracer without an approved action card.
- Offline mode keeps everything on the machine; the app never needs a key
  to work.
- The design principle throughout is: **propose, verify, then claim** - if
  the app cannot prove something happened, it says exactly that.
