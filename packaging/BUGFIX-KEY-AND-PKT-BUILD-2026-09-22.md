# Bugfix: key persistence and `.pkt` generation from chat

Date: 2026-09-22
Workspace: `C:\ai`, app at `C:\ai\app`

Two reports from the tester:

1. "the api key entered is not persistence, it disappears when I close the app
   and reopen it"
2. "why isn't there a button to generate the .pkt file here"

---

## 1. The API key did not survive a restart

### What was actually wrong

The key was always written to `flutter_secure_storage`, so the storage calls
were not the problem. Three things combined to make a saved key look like it
had vanished:

| Cause | Detail |
|---|---|
| No Android storage options | `const FlutterSecureStorage()` was used with defaults. The legacy Android implementation is the one that loses data across installs and restores. |
| Unhandled decryption failure | `getApiKey()` was a bare `_secure.read(...)`. When a keystore-encrypted value cannot be decrypted, that call throws - inside app startup. The failure surfaced as an empty key with no explanation, which reads as "the save never worked". |
| Backup included the key store | The encrypted file was eligible for Android auto-backup and device transfer. The keystore key that decrypts it is never backed up, so a restored copy can never be read. |

### The fix

- `SettingsService` now builds its storage explicitly:
  `AndroidOptions(encryptedSharedPreferences: true, resetOnError: true)` and
  `IOSOptions(accessibility: KeychainAccessibility.first_unlock)`.
  `resetOnError` makes an undecryptable value self-heal instead of throwing.
- `getApiKey()` never throws. It clears an unreadable entry so the next save
  succeeds, and records the event in `keyUnreadable` for the UI to explain.
- `setApiKey()` now returns `Future<bool>` and **verifies the value reads back**.
  A write that does not persist returns `false`; the UI no longer says "saved"
  about a write that did not stick.
- `AndroidManifest.xml` sets `android:allowBackup="false"` and
  `android:dataExtractionRules="@xml/data_extraction_rules"`, with
  `res/xml/data_extraction_rules.xml` excluding the `FlutterSecureStorage`
  prefs from both cloud backup and device-to-device transfer.
- The settings drawer now shows the real state on open - "A key is saved on
  this device (39 characters)", "No key saved", or "could not be read back,
  please enter it again" - driven by an actual read, never a guess.

### Also fixed while in there

- `/key <value>` claimed success unconditionally and echoed the **last four
  characters of the key** into the chat. It now verifies the write and reports
  only the key's length, so no part of the secret is displayed.
- A corrupted character sequence in that same message (mojibake in the source)
  was replaced.

---

## 2. No way to generate the `.pkt` from the chat screen

### What was actually wrong

The generator already existed and worked offline - `POST /pkt/generate` in the
sidecar, wrapped by `AutopilotService.pktGenerate(plan, ...)`. The only UI for it
was a button in `builder_detail_screen.dart`, a screen the chat-only shell never
routes to (`main.dart` only reaches `PktFilesScreen`). So from the screen the
user actually uses, there was no button and no command.

### The fix

Generation is now reachable three ways, all from the chat:

| Route | Where |
|---|---|
| A button in the composer | `Icons.build_circle_outlined`, tooltip "Build a .pkt from the current plan (offline)" - visible in every mode |
| A slash command | `/build` (also `/generate`, "build the pkt", "generate the pkt", "build a pkt") |
| An action card | `pkt_generate`, offered on every offline-planner reply; its button reads "Build .pkt" rather than "Approve" |

The plan is compiled from a structured parse of the user's **own words**
(`NetworkIntent.parseSimple`), recorded on every turn in `_lastIntent`, and
serialised with `PacketTracerAdapter.autopilotPlan(intent)`.

### What it gives with and without a Gemini key

This is now deterministic and stated in the UI, because it was the user's
question:

| | With a Gemini key | Without a key |
|---|---|---|
| Who writes the chat answer | The model | The offline assistant |
| Who produced the plan | The same structured parse of your words | The same structured parse of your words |
| `.pkt` generated | Yes | **Yes** |
| Difference | The explanation is richer, and the model can investigate the capture with the tool layer | The explanation is terser and offline |

A key changes how the app *explains* things, not what gets **built**. Generation
never depends on the model or on the network.

### Error paths handled

- No plan yet -> says so and shows how to describe one, rather than failing.
- Sidecar not running -> the existing `AutopilotService.startHint` text
  ("Sidecar not running on 127.0.0.1:5005" + the three start-up steps).
- Generator returns `ok:false` -> the engine's own error message is shown.
- Generator reports no file -> "the generator ran but reported no file, so
  nothing was written".
- Any other failure -> a readable chat message; no stack trace in the bubble.

On success the generated file becomes the active capture, so the tool layer can
read it immediately, and an "Analyze the generated file" action is offered so
the result can be checked without leaving the chat.

---

## Verification

```
flutter analyze                      -> No issues found
flutter test                         -> 215 passed   (203 before, +12 new)
cd sidecar && py -3.14 -m pytest -q  -> 389 passed, 1 failed
flutter build apk --release          -> 59.6 MB, exit 0
```

New tests:

- `test/settings_key_storage_test.dart` (5) - a key survives a fresh
  `SettingsService` over the same storage (the restart case); an undecryptable
  value returns null without throwing and is cleared; a write that does not
  persist returns `false` instead of reporting success; clearing works; blank
  input is treated as no key.
- `test/pkt_generate_test.dart` (4) - `pkt_generate` is in the action
  whitelist and does not claim to touch Packet Tracer; the **keyless** planner
  produces a plan with steps the generator can compile; a generator failure
  surfaces as a thrown message; a down sidecar is unhealthy and the hint names
  the port.
- `test/chat_build_interaction_test.dart` (3) - drives the real chat screen:
  the build button is present in the composer; pressing it with no plan gives
  the "describe a network first" message; and after describing one, pressing it
  with the sidecar down shows the start-up hint. These are UI interaction
  checks, not direct calls into the logic.

Merged manifest inside the release build confirms the storage hardening:

```
android:allowBackup="false"
android:dataExtractionRules="@xml/data_extraction_rules"
```

Published build: `dist/NetBuilderAI-Tester.apk`, 59.6 MB,
SHA-256 `47FD2C69A92D5834C29F6B3C09670CAF0F037DC483D758003563AEF7E2279D7C`.

---

## Risks and what is not verified

- **Not verified on a real device.** The resilience work is tested at the Dart
  layer with an injected storage that fails the two ways the platform fails.
  Real keystore behaviour on a specific phone cannot be reproduced in a unit
  test, so the strongest honest claim is: the failure is now handled and
  visible instead of silent. If a key still fails to persist on the tester's
  device, the settings screen will now say which of the three states it is in,
  which identifies the remaining cause immediately.
- **`allowBackup="false"`** also stops the app's other preferences from being
  restored onto a new device. That is the intended trade for not restoring an
  unreadable key, but it is a behaviour change worth knowing about.
- The generated `.pkt` has not been opened in Packet Tracer here. The generator
  itself is unchanged, and its warnings are surfaced verbatim in the chat.

## Rollback

Source revert. Nothing here migrates data or schema. Reverting the manifest
attributes alone restores the previous backup behaviour; reverting
`SettingsService` alone restores the old (silent) failure mode. The generated
`.pkt` files are new files - the app never edits an existing capture in place.
