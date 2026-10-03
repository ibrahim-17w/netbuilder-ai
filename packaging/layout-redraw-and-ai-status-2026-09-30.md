# Layout redraw ("make it look better") + the AI status sign - 2026-09-30

Two pieces of work finished this morning, plus one regression the finishing
pass caught. This closes the last "NOT STARTED" item from Round 7 and gives
the drawing its own request type.

## 1. A request about the DRAWING now changes the drawing

**Reported:** "can you edit the layout of the devices to make them better
looking?" was read as an ordinary edit, so the app recompiled the same plan
and the deterministic layout produced byte-identical coordinates - and
answered as if it had done something.

**Fix - the drawing is an input to the build, not a property of it:**

* `lib/services/layout_intent.dart` (new): `LayoutRequest.read()` decides
  from words alone, before any model is consulted, so it behaves identically
  online and offline. It recognises the topic (layout / drawing / arrange /
  spread / overlap / "looks better" / row ...), rejects device changes
  ("add 2 switches to the layout" is an edit), rejects approval ("the layout
  is fine"), and extracts either a named style or a column count.
* Four named drawings, cycled in order for a vague request:
  `tree` (site trees, the default) → `wide` (more room) → `compact`
  (closer together) → `rows` (one band per kind of device - the textbook
  picture). A vague request is a decision: it picks the one AFTER the
  current drawing, never the same one again, and says so honestly
  ("The drawing you had was already the default one, so I redrew it as ...").
  "6 devices per row" / "four pcs to a row" sets the row width (2-12).
* `chat_screen`: the request is read before the file-edit reader and before
  any provider; `_redrawPkt` recompiles the SAME plan revision (the card
  stamp check and the validator still gate it) with
  `layout: {style, columns?}` in the plan payload. The drawing is sticky for
  the conversation, and the file's note records it
  (`...; layout: wide`) so a vague request after a restart still changes
  something. Nothing built yet? The choice is noted for the next build.
  The other styles come back as one-tap chips.
* `pkt_builder`: `LAYOUT_STYLES` + `layout_settings()`. The engine accepts
  `layout: {style, columns, spacing}` and drops anything it does not
  understand, so a plan from an older app still builds. The style is
  deterministic per plan: the same plan + style always draws the same
  picture. `LAYOUT_REVISION` bumped to 3 and travels in the engine's
  `/health` identity.

## 2. The model state is a header sign, not a disclaimer

**Round 7 carry-over:** the "model unavailable" notice was inlined in every
offline reply.

**Fix:** `AiStatus` (in `ai_provider.dart`) computes the backend state once -
`ready` (with provider + model), `keyless`, `private mode`, `not answering`
(with the failure) - from keys, private-mode switch and last error. The chat
header shows it as a small live sign (`_aiSign`); the tooltip carries the
detail. The turn's `source` line carries provenance ("via OpenAI-compatible
(llama-3.3-70b-versatile)" / "the built-in planner - no API key").
`offline_assistant_service` no longer repeats the state inside the prose; the
first answer explains the situation once, later answers just answer.

## 3. The finishing-pass catch: a 28px overflow at 360px

The full-suite gate failed: `composer + run controls hold at a narrow phone
width` - "A RenderFlex overflowed by 28 pixels on the right" at 360x640.
Cause: `_aiSign(theme)` sat in the header Row as a RIGID child (a padded
Container around a Text), so at 360px it could not shrink and pushed the row
past the right edge. Fix: wrapped in `Flexible` - the sign's label
ellipsizes, the buttons keep their hit targets. This is exactly why the
narrow-width widget test exists.

## 4. The Round-8 lesson, applied again

The frozen engine at `build/windows/x64/runner/Release/sidecar/` was from
22:50 last night - it predated this morning's `pkt_builder.py` (styles were
engine-side). Rebuilt with PyInstaller (onedir, same flags as
`build_installer.ps1`) and installed exe + `_internal`, plus
`pkt_templates` / `pkt_seed` beside it. `/health` now reports
`layoutRevision: 3`, `frozen: true`, and the file it was started from.

## Gates

* `flutter analyze`: clean.
* Dart: **864 passed / 0 failed** (new: `test/layout_request_test.dart` 13
  checks, `test/ai_status_test.dart`, `test/offline_conversation_test.dart`
  rewritten around the once-not-every-turn contract; narrow-width composer
  test passes again after the Flexible fix).
* Sidecar: full suite except the pre-existing `test_ocr_perf.py` environment
  failure - **426 passed / 0 failed** (88 generator tests include the four
  style assertions).
* END-TO-END through the live frozen engine's own API, the 35-device
  two-site plan built in all four styles - same network (35 devices, 34
  links, same configs), four different drawings, 35 distinct spots each:
  * tree:    x 200-1820,  y 60-890
  * compact: x 185-1400,  y 60-682
  * rows:    x 280-1640,  y 60-1020
  * wide:    x 218-3260,  y 60-970
  Files kept for Packet Tracer:
  `build/windows/x64/runner/Release/sidecar/_internal/pkt_output/layout-e2e-*.pkt`.
* Frozen engine installed (13:31); Windows release rebuilt (app.so 13:39,
  new strings confirmed inside).
