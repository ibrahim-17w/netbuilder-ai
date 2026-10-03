# Review / handover note — AI providers (2026-09-21)

## What was asked

Add an OpenAI-compatible provider so free-tier models can be used with your own
key, and fix Gemini, which was failing because the app's model names were no
longer valid.

## What was delivered

| File | Role |
|---|---|
| `lib/services/ai_provider.dart` | provider config + the single place HTTP failures become actionable text; the real current Gemini default |
| `lib/services/openai_chat_service.dart` | `/chat/completions` client: base URL, key, model, extra headers, org; streaming with mid-line buffering; no key needed for localhost |
| `lib/services/provider_chat_service.dart` | picks the active brain; keeps context budget, memory and streaming identical for both; `testConnection()` |
| `lib/services/settings_service.dart` | provider prefs, a second secure key, and the model-migration fix |
| `lib/widgets/settings_drawer.dart` | provider dropdown, base URL, model, key, extra headers, Test connection |
| `lib/screens/chat_screen.dart` | chats through the facade instead of Gemini directly |
| `test/openai_provider_test.dart` | 12 tests: request shape, streaming split, 401/403/404/429/503, no-key, localhost, bad URL, arbitrary model, Gemini default, header parsing |
| `packaging/AI-PROVIDERS-2026-09-21.md` | setup, free-tier table, troubleshooting matrix, key handling, rollback |
| `dist/NetBuilderAI-Tester.apk` | the build to test |

## The Gemini root cause (observed in source)

`SettingsService.load()` contained:

```dart
if (retiredModels.contains(saved) || !supportedModels.contains(saved)) {
  saved = 'gemini-3.8-flash';
```

So any model **not in the suggestion list** was rewritten to a name Google does
not serve, and every request then 404'd. The counterfactual is the fix: only
`retiredModels` are migrated now, the fallback is `gemini-2.5-flash`, and an
unknown name is passed through untouched.

## Verified scenarios (exact commands)

```powershell
cd C:\ai\app
flutter analyze                                -> No issues found
flutter test                                   -> 147 passed
flutter test test\openai_provider_test.dart    -> 12 passed
flutter build apk --release                    -> 58.6 MB
```

Covered: non-streaming request shape (URL ends `/chat/completions`, `Bearer`
key, org header, extra header, model in body); streaming where a chunk splits a
JSON payload; 401; 403; 404 (message names the model and `/v1`); 429; 503;
missing key on a remote host; localhost with no key; malformed base URL; an
arbitrary never-before-seen model id; the Gemini default and suggestions; the
`Header: value` parser.

## Known limitations

1. **No live call to a real free-tier endpoint was made** — that requires your
   key, which I do not request or store. The **Test connection** button performs
   it; everything up to the network boundary is covered by mocked tests.
2. Streaming from some gateways that only send the full answer in the final
   chunk is handled (the parser falls back to `message.content`), but
   token-by-token smoothness depends on the provider.
3. Gemini's model names move; the list here is only a **suggestion** and the
   field accepts anything.
4. Free tiers' limits and availability are outside the app's control.

## Rollback

* Immediate: sidebar → Active provider → `Google Gemini`. The chat returns to
  the previous behaviour with no code change.
* Full revert: restore `settings_service.dart`, `chat_screen.dart`,
  `settings_drawer.dart`; delete `ai_provider.dart`,
  `openai_chat_service.dart`, `provider_chat_service.dart` and
  `test/openai_provider_test.dart`. All new preferences are additive, so an old
  build simply ignores them.
