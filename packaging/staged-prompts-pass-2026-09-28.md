# The staged-prompts pass: prompts 1-8 in the recommended order (2026-09-28)

This note records the pass over the eight staged prompts the user supplied,
executed in the recommended order, with what each phase changed, what was
verified and how, and what remains open. Per the staged prompts' shared
instructions: no commits, no resets, no new tests added to the suite - every
check below is an actually-run command, and the temporary probes were deleted
after their runs.

## Execution order and results

| Order | Phase (prompt) | State | Key files |
| - | - | - | - |
| 1 | P3.3 - stream hardening; verify P3.1/P3.2 | done | `lib/services/chat_service.dart`, `lib/screens/chat_screen.dart` |
| 2 | P5 - build preflight + plan-vs-file verification | done | `lib/services/build_preflight.dart` (new), `lib/screens/chat_screen.dart` |
| 3 | P8.3 - README | done | `README.md` |
| 4 | P1 - structured message understanding | done | `lib/services/message_understanding.dart` (new), `lib/models/network_intent.dart` (`classifyBrief`), `lib/services/file_edit_intent.dart` (`referenceIn`), `lib/screens/chat_screen.dart` (Understood card) |
| 5 | P6 - file references, ambiguity, version linkage | done | `lib/services/session_state.dart` (artifacts list), `lib/screens/chat_screen.dart` |
| 6 | P4 - language + missing-coverage honesty | done | `lib/services/offline_assistant_service.dart` |
| 7 | P2 - capability routing (saved networks, GNS3 export) | done | `lib/services/chat_capabilities.dart`, `lib/services/offline_assistant_service.dart` |
| 8 | P7 - export support notes + IPv6 where it fits | done | `lib/services/export_support.dart` (new), `lib/services/capability_registry.dart`, `lib/services/network_math.dart`, `lib/services/offline_knowledge.dart` |

## Phase 1 - stream hardening (P3.3)

Problem (observed in the user's own screenshots): a model reply cut off
mid-stream was displayed as raw JSON because `parseReply` had no salvage
path. Now:

* `ChatService.streamPreview` shows the growing `"reply"` text during
  streaming (escapes resolved), never the JSON scaffolding; non-JSON pieces
  (status lines, offline answers) pass through untouched.
* `parseReply` keeps what a truncated object still says (`_salvageTruncated`):
  readable reply text + any complete action list, with an explicit note that
  the answer was cut off; JSON-looking garbage gets a human sentence instead
  of punctuation on screen.
* Verified with a temporary probe reading the REAL truncated reply from the
  chat DB (`chat#122`): text kept ("To support 2 physical sites..."), no
  `"reply"` scaffolding, cut-off noted, full-shape parse and prose fallback
  unchanged. P3.1/P3.2 (provider planning, validator gating) were
  re-inspected: unchanged and still in force.

## Phase 2 - build preflight + verification (P5)

* `BuildPreflight.lines` (target, plan summary, open assumptions/open
  questions) is assembled before compiling and shown as a **Preflight**
  section in the build message.
* After writing, the file is read back through the engine audit
  (`/pkt/audit`); `BuildPreflight.compare` checks devices by name and links
  by endpoint pairs. The message says "the file audit agrees with the plan
  (N devices, M links read back)" **only** when that audit ran; otherwise it
  says "not collected ... unverified" in those words.
* Repairs already re-audit (`_verifyRepair`); no change needed there.

## Phase 3 - README (P8.3)

The 650-byte Flutter starter was replaced with practical setup, features,
platform requirements, data locations, and troubleshooting, all from what
the code actually does (offline-first, optional Gemini key, PT autopilot via
the Python sidecar, targets and adapters).

## Phase 4 - structured message understanding (P1)

* `MessageUnderstanding.read` returns one structured result: turn kind
  (social/howto/question/confirm/growth/addition/build/change/statement -
  from the planner's new public `NetworkIntent.classifyBrief`, one
  implementation shared with the runtime rules), recognized details with
  excerpts AND offsets (counts, subnets, VLANs, routing), corrections
  ("not OSPF", "actually 8", "more than 2"), the first file reference
  ("it", "that file") via `FileEditIntentReader.referenceIn`, open questions
  and confidence.
* The Understood card now shows "Read as: ..." plus "Corrections read: ..."
  and "Points at the file: ..." lines - what was understood and why, with
  the words it came from. (Documented but intentionally not yet fed into
  Action Hub features, per the prompt's scope limit.)

## Phase 5 - files, ambiguity, versions (P6)

* `SessionState` now keeps a list of artifacts (path, name, written-at,
  verification note), capped at 12, most-recent first; old conversations
  decode unchanged (single latest pointer still kept and folded in).
* A message naming a known file ("edit netbuilder-...1236.pkt") resolves to
  THAT file regardless of phrasing.
* When a conversation has produced several files and the request is
  ambiguous ("edit it"), the chat asks which one - with each version's write
  time and verification note listed - and offers the file names as quick
  replies. One file behaves exactly as before.
* The build message's verification result is stored per file, so the
  version list can say what is known about each build.

## Phase 6 - language + honest gaps (P4)

* Arabic (or mixed Arabic/English) messages: Arabic greetings and
  acknowledgements get Arabic texts; technical answers keep their English
  commands (which are English on real devices) with an Arabic framing line;
  Arabic question forms route to missing-coverage; mixed terminology
  ("كيف أعمل ssh...") still reaches the knowledge topics.
* A real question the offline material does not cover now says exactly that
  ("not in my offline material ... try naming the device or protocol, or add
  a model key") instead of a guess - in English or Arabic. Deliberately
  narrow: anything naming devices or the plan still goes to the planner or
  the continuity answer; short openers keep the old "tell me what you want".

## Phase 7 - capability routing (P2)

* New capabilities in `ChatCapabilities` with an explicit
  read-vs-modify/prerequisite table (`meta`): every chat capability is
  read-only by design; approval-gated actions stay in the Action Hub.
* "show saved networks" -> lists the conversation's real files with their
  verification notes and points at the Files view.
* "export this for gns3" -> read-only preview of the GNS3 JSON (produced by
  the same adapter the Action Hub uses) + pointers at the create and push
  actions.
* "export the plan" with no format -> offers IOS / PT / GNS3 / Terraform
  and asks which one.

## Phase 8 - export notes + IPv6 (P7)

* `ExportSupport.notesFor` powers a "Support notes" block on the Cisco, PT,
  GNS3 and Terraform export dialogs: adapter characteristics (e.g. GNS3's
  c3725 mapping, servers/APs importing as generic nodes) + the validator's
  own non-error findings + the always-present line "producing this export
  does not deploy or verify it - that is a separate, approval-gated step".
* IPv6 where it fits: `NetworkMath.ipv6ToBig` / `ipv6Compress` /
  `ipv6Facts` (RFC 4291 parsing, RFC 5952 printing, network / first / last /
  address count) and an offline knowledge topic that computes address facts
  for "…/prefix" questions. Verified with exact values
  (2001:db8::1/64 -> network 2001:db8::/64, last ::ffff:ffff:ffff:ffff,
  18,446,744,073,709,551,616 addresses). The v4-only VLSM planner and
  summarizer are deliberately untouched.

## Verification (commands actually run)

* `dart analyze` on every touched file - no issues found.
* Targeted suites, all green: chat_service/streaming (20), intent card +
  chat UI + file-edit (106), capability/registry/action-hub (26),
  offline suites + chat UI (103), memory/file suites (66), conversation
  replay (22).
* Temporary probes (created, run, deleted): truncation salvage against the
  real DB sample; Arabic framing + missing coverage; saved networks + GNS3
  export + IPv6 exact values.
* Full suite: see the final run recorded in the session log
  (`full_after_phases.txt` in the session's scratch directory).

## Limitations / open items (stated plainly)

* Phase 4's understanding result is surfaced on the card but intentionally
  not yet connected to Action Hub features beyond chat.
* Arabic support is framing + detection, not a full translation of every
  knowledge answer.
* IPv6 support is address facts; dual-stack routing/planning is not in the
  toolkit (v4 VLSM/summary remain IPv4-only by design).
* Export support notes summarise; they are not a guarantee about any
  specific external environment (the produce-vs-deploy line says so).

## Rollback

All edits are uncommitted. The phase changes are additive; to back out any
phase, revert its files from the table above (and delete the three new
service files: `build_preflight.dart`, `message_understanding.dart`,
`export_support.dart`). Re-run `flutter test` to confirm the previous
behaviour returns.
