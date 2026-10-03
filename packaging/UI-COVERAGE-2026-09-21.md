# UI/UX coverage audit — 2026-09-21

Preset **03 Information Architects** (reading-first): system fonts, one accent
colour, generous spacing, a visible focus ring, zero decoration competing with
the text. Every item below is either **fixed** in this pass or explicitly
**accepted** as-is, with the reason.

| Area | Item | Change in this pass | Status |
|---|---|---|---|
| Global | Theme | `_readingFirstTheme` in `lib/main.dart`: Material 3, single indigo accent, `ThemeMode.system` (light/dark), 1.45 body line-height, flat elevation-0 cards with a hairline outline, `scrolledUnderElevation: 0` app bar | fixed |
| Global | Focus ring | `inputDecorationTheme.focusedBorder` = 2px primary — visible keyboard focus everywhere | fixed |
| Global | Spacing scale | Cards get a 4px vertical rhythm, dividers 1px, section gaps normalised to 6/8/12 | fixed |
| Chat | Landing | App opens on Chat (`_tab = 3`), composer autofocused | fixed |
| Chat | Composer | Multi-line (1–6 rows), `labelText: 'Message'` for accessibility, Enter sends / Shift+Enter newline, `TextInputAction.send`, hint documents the shortcuts, disabled while busy | fixed |
| Chat | Context meter | New line above the composer: `Context 131,699 / 262,144 tokens (50.24%)` + `N earlier message(s) summarized into memory` | fixed |
| Chat | Message list | `Semantics(label: 'Conversation with the NetBuilder assistant')`; bubbles carry `Semantics(label: 'You said' / 'Assistant said')` | fixed |
| Chat | Reading measure | Assistant/user bubbles capped at 660px (~66 characters) instead of 720px | fixed |
| Chat | Error + retry | A failed turn keeps the typed text and shows a **Retry** button (never loses the message) | fixed |
| Chat | Status strip | Now a row with the message on the left and Retry on the right | fixed |
| Chat | Run controls | Pause/Stop moved into the header (they used to float over Send) | fixed |
| Chat | Empty state | Scrollable, single clear prompt | fixed |
| Chat | Overflow at 360px | Header row stacks below 420dp; context meter is ellipsis-safe | fixed |
| Projects | Empty state | Unchanged copy ("No networks yet. Go to Build…"), now inherits the reading-first theme | accepted |
| Projects | List rows | Unchanged; tap target already > 44px | accepted |
| Build (wizard) | Plan card | Shows the plan + `Suggested fixes` (added in the earlier pass) | accepted |
| Analyze | Panels + fix flow | Unchanged; inherits theme | accepted |
| Build Workspace | Three phases | Thinking / Execution / Chat on one screen (earlier pass) | accepted |
| Memory | Rules, prefs, diagnostics | Unchanged; inherits theme | accepted |
| Settings | Context budget | **New** dropdown: 32k / 128k / 256k (default) / 1M + custom, writes `context_budget` | fixed |
| Settings | Model + key | Unchanged (BYOK) | accepted |
| PKT Files | Lifecycle copy + buttons | Unchanged; inherits theme | accepted |
| Dialogs | Clear-conversation confirm | Unchanged; inherits theme | accepted |
| Toasts | Pause/Resume/Stop/errors | SnackBars on every run control + error path | fixed (unified) |
| Dark/light | All screens | `themeMode: ThemeMode.system` with a matching dark scheme | fixed |
| Reduced motion | Animations | Flutter respects the platform setting for its built-in transitions; the app adds no custom motion beyond a 220ms scroll | accepted |

## Not changed (out of scope, stated for completeness)

* Brand/logo — explicitly out of scope.
* App-store visuals, marketing site, auth/billing screens — out of scope.
* The Packet-Tracer execution surfaces (run panes) keep their existing dense
  layout: operators want the raw evidence there, not a reading-optimised view.
