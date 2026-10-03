# AI providers — setup, free tiers, troubleshooting (2026-09-21)

## What changed

The chat can now run on **either** brain, chosen in the sidebar:

| Provider | What it talks to |
|---|---|
| **Google Gemini** | the original integration |
| **OpenAI-compatible** | anything serving `/chat/completions` — the free-tier gateways **and** a local server |

Nothing in the request path is hardcoded any more: the **base URL, the API key
and the model id all come from Settings**. Changing them takes effect on the
next message, with no code edit.

### The Gemini bug that was fixed

`SettingsService.load()` used to rewrite any model that was not in its
suggestion list back to `gemini-3.8-flash` — a name Google does not serve. So a
user who picked a *newer* model ("above the suggested ones") had it silently
replaced and every call 404'd. Now:

* the default is `gemini-2.5-flash` (a model that exists);
* only genuinely **retired** names are migrated;
* anything you type is left alone;
* a 404 names the offending model and tells you to type a current one.

## Setup

Sidebar (hamburger) → **AI provider**.

### Gemini
1. Provider: `Google Gemini`.
2. Paste the key, press **Save key**, then **Test connection (Gemini)**.
3. Model is free text — `gemini-2.5-flash`, `gemini-2.5-pro`,
   `gemini-2.0-flash` are suggested, but any id works.

### OpenAI-compatible (free models)
1. Provider: `OpenAI-compatible (free models OK)`.
2. **Base URL** — everything up to `/v1`:

| Service | Base URL | Notes |
|---|---|---|
| Groq | `https://api.groq.com/openai/v1` | fast free tier |
| OpenRouter | `https://openrouter.ai/api/v1` | has `:free` models |
| Cerebras | `https://api.cerebras.ai/v1` | fast free tier |
| Together | `https://api.together.xyz/v1` | free models available |
| **Local (Ollama)** | `http://127.0.0.1:11434/v1` | **no key needed** |

3. **Model id** — exactly as the provider lists it, e.g.
   `llama-3.3-70b-versatile` (Groq) or `llama3.1` (Ollama).
4. **API key for this provider** — stored separately from the Gemini key.
   Leave empty for a local server (the app detects localhost and omits the
   `Authorization` header).
5. **Extra headers** — `Header: value` per line, if the gateway asks for one.
6. Press **Test connection**. It makes one real call and reports the outcome
   with the latency, e.g. *"Connected to … with `llama-3.3-70b-versatile` -
   'ready' in 412 ms."*

> Free tiers change without warning. The app never pools, proxies or rotates
> keys — you supply your own, and only you pay the provider's terms.

## Troubleshooting matrix

Every message below is produced by the app and is asserted in
`test/openai_provider_test.dart`.

| Symptom | What the app says | Fix |
|---|---|---|
| 401 | "The API key was rejected (401)…" | wrong/expired key, or it belongs to another provider |
| 403 | "The key is valid but not allowed to use `X` (403)…" | pick another model, or check account permissions |
| 404 (OpenAI-compatible) | "Nothing at that address, or the model `X` is unknown (404)… base URL … usually `/v1`" | fix the base URL path or the model id |
| 404 (Gemini) | "Google does not serve that name - type a current model such as `gemini-2.5-flash`" | type a current model |
| 429 | "Rate limited or out of quota (429). Free tiers reset on their own schedule…" | wait or switch provider |
| timeout | "The request timed out… firewall, or unreachable" | check network/proxy |
| bad base URL | "That base URL is not a valid address: `X`" | fix the URL |
| no key (remote) | "No API key for OpenAI-compatible… or point the base URL at a local server" | add a key, or use localhost |
| 5xx | "The provider is having trouble… the offline planner still works with no key" | retry |

## Key handling

* Keys live in the platform secure store (`flutter_secure_storage`), the Gemini
  key and the OpenAI-compatible key under **separate** names.
* The UI masks them and shows only whether one is stored.
* They are never written to the conversation, the audit ledger, logs or error
  text, and never committed (no key is in the repo).
* Clearing a field and saving removes the stored key.

## Migration and rollback

* **Additive only.** The new preferences (`ai_provider`, `openai_base_url`,
  `openai_model`, `openai_headers`, `openai_organization`) and the second key
  are new keys; an existing Gemini-only install keeps working and simply stays
  on `gemini`.
* The only automatic change is the retired-model migration described above.
* **Rollback (one step):** set the provider back to `Google Gemini` in the
  sidebar — the chat returns to the previous behaviour immediately.
* **Full revert:** restore `lib/services/settings_service.dart`,
  `lib/screens/chat_screen.dart`, `lib/widgets/settings_drawer.dart` and delete
  `lib/services/ai_provider.dart`, `openai_chat_service.dart`,
  `provider_chat_service.dart`.

## Verification commands

```powershell
cd C:\ai\app
flutter analyze                       # No issues found
flutter test                          # 147 passed
flutter test test\openai_provider_test.dart   # the provider + failure matrix
```

Layers covered: non-streaming call shape (URL, auth, org, extra headers, model),
streaming with a payload split across chunks, 401/403/404/429/503 messages,
missing key, localhost-without-key, malformed base URL, an arbitrary model id,
and the Gemini default.
