# Advice card, environment profile, and the tappable .pkt path (2026-10-07)

Three additions, plus one pre-existing bug found and fixed along the way.
`flutter analyze` clean; **2,254 tests pass** (2,214 before; 40 new).

## 1. The advice card with "Plan this"

The advisor's structured answer (`AdviceAnswer`: recommendation, options
with trade-offs, reasons, next step, planBrief, basis) used to be flattened
to markdown and thrown away. Now it rides the reply:

* `AssistantReply.advice` (typed `AdviceAnswer?`) carries the parts
  (offline_assistant_service.dart). The service text is unchanged, so the
  golden battery still holds.
* The chat attaches an **`advice_card` ChatAction** whose payload is a JSON
  projection (topic/kind/recommendation/options/reasons/nextStep/planBrief/
  basis). Riding the allowlist means the card survives a conversation
  reopen exactly like a build card does.
* `lib/widgets/advice_card.dart` renders it COMPACT: header, the
  recommendation highlighted in `primaryContainer`, and a **Plan this**
  button when `planBrief` is non-empty (advice on a standing plan has
  nothing to re-plan). The options/reasons/basis stay in the markdown above
  - the first card draft repeated the whole answer and the accessibility
  test caught it (`find.textContaining('What I would do') findsOneWidget`).
  Keep the split: markdown = the answer, card = the action.
* "Plan this" sends `planBrief` via `_sendQuickReply` - a normal turn the
  planner parses and the validator gates - and marks the card done
  (`_markActionExecuted`, the same record `_runAction` keeps). The advice
  itself still never edits the plan; the user's tap does.

## 2. The remembered environment profile

* `lib/models/environment_profile.dart`: venue / scale / budget / skill +
  updatedAt + source; `merge` (stated fields win, unstated survive),
  `sameFactsAs` (ignores timestamps), tolerant `tryDecode`.
* `lib/services/environment_profile_service.dart`: `statedIn(text)` mirrors
  the advisor's `_AdvisorContext` word lists (CHANGE BOTH OR NEITHER);
  `learnFrom(text, current)` is the whole chat auto-learn step (returns
  null when nothing new - re-stating a known fact is not a notification).
  Skill: advanced checked BEFORE beginner, so "no longer a beginner" works.
* Store: `environment_profile` table (one row, JSON) in memory.db,
  **schema version 9**; export schema version **3**. `setEnvironmentProfile`
  writes what it is given - merging is the caller's job (the Memory screen
  is the authority once edited).
* Chat: `_updateEnvironmentProfile` beside `_autoTeachPreference`, on BOTH
  completion paths, gated by `settings.autoTeach`, snackbar "Noted: ..."
  only when something changed. The profile also flows to the advisor
  (`AdvisorService.advise(environmentProfile:)` - message beats profile,
  profile fills the unsaid) and into the model prompt context.
* Memory screen: **Environment tab** with an editor (venue/skill dropdowns,
  scale field, budget switch), Save, and Forget.

## 3. The tappable .pkt path + viewer

* `lib/services/packet_tracer_locator.dart`: any one of App Paths
  (`reg query HKLM/HKCU ...PacketTracer.exe`), the `C:\Program Files*\Cisco
  Packet Tracer *\bin\PacketTracer.exe` layout, or a live `.pkt`
  association counts as installed. Injectable `runProcess`/`listDir`/
  `exists`/`forcePlatform` for tests; result cached per session.
* `chat_markdown.dart`: `ChatMarkdown.isPktFilePath` (needs `.pkt` AND a
  path separator, so bare backup names stay inert) + `ChatFilePathSpan`
  widget; `ChatMarkdownView(onFilePathTap:)` threads to every inline site.
* Chat: `_openPktArtifact(path)` is the ONE decision point - PT installed
  → `_openExternally`; not installed → `PktViewerScreen(filePath, intent:
  _lastIntent, positions: _layoutPositions())`. Used by BOTH the path tap
  (`_onPktPathTap`, snackbar says what happened) and the `pkt_open` card in
  `_runAction`. New build cards label themselves by detection:
  "View the network (no Packet Tracer found)" when absent.
* `lib/screens/pkt_viewer_screen.dart`: TopologyCanvas (the PT-style
  glyphs) + device/cable tags + an honest note; "Nothing to draw yet" when
  the conversation holds no plan (plan travels with the session, so a
  reopened chat still has it).

## Bug found by the explorer: `pkt_open` was not in `ChatAction.supported`

Cards rendered live but were DROPPED by `ChatAction.parseList` on any
conversation reopen - the "Open in Packet Tracer" button silently
vanished after a restart. Fixed by adding `pkt_open` (and `advice_card`)
to the allowlist with regression coverage in advice_card_test.dart.

## Tests (all new files)

* `environment_profile_test.dart` - reader, merge, learnFrom, store CRUD,
  corrupt row, export v3, clearAll.
* `advisor_profile_test.dart` - scale/venue/budget fallbacks; message
  beats profile; structured advice rides the reply.
* `advice_card_test.dart` - structured reply, allowlist round trip for
  advice_card AND pkt_open, widget render + Plan this tap.
* `pkt_path_and_locator_test.dart` - path predicate, inline span emission,
  tap fires, locator (registry/glob/assoc/which, caching, crash→false).
* `pkt_viewer_test.dart` - draws plan + counts, empty-plan honesty.

House pattern notes: MemoryService tests use a temp-FILE db per test
(`inMemoryDatabasePath` broke with "table builds already exists" across
tests); a MemoryScreen widget test was attempted and dropped - its
3-second sidecar polling timer fights the test binding's pump guard; the
tab logic is covered via the service/store tests instead.

## Not done / next candidates

* "Plan this" for standing-plan advice (topic-authored edit phrases, e.g.
  "add 2 access points" after AP sizing on a standing plan) - needs
  per-topic verified parser phrases.
* The sidecar `/pkt/open` route and `os.startfile` are unused by the chat
  path (pure Dart `Process.run` won); unify later if the sidecar gains
  non-Windows open support.
* Skill level is stored, shown, and sent to the model, but the offline
  advisor topics do not yet change their wording for beginners.
