# Chat upgrade — changelog & handover (2026-09-21)

## What changed and why

The chat used to forget. Three separate caps caused it:

| Where | Old | New |
|---|---|---|
| `ChatService.send` history cap | last **20 turns** sent | no turn cap — a **token budget** decides |
| `ChatScreen._load` | last **60 messages** loaded | last **5000** loaded (the budget decides what is sent) |
| `MemoryService.chatRetention` | **200** rows kept | **5000** rows kept |

On top of that the assistant had no memory of its own: the keyless path
answered each message from scratch.

## The context budget (the knob)

* **Code:** `lib/services/context_budget.dart` → `ContextBudget.defaultContextTokens`
  = `262144` (256k). This is the single documented ceiling; nothing else hardcodes one.
* **Settings → "Chat context budget (tokens)"** writes the `context_budget`
  preference (clamped 8k … 1M). Change it there to see the effect immediately —
  the context meter above the composer re-reads it.
* **How it is applied** (`ContextBudget.plan`):
  1. start from the system prompt + the pending turn + an output reserve;
  2. keep the newest turns while they fit under `budget × workingFraction`
     (0.5, so a 256k ceiling does not inflate latency/cost for a chat);
  3. compact the remainder with `ConversationMemory.summarize` into one memory
     block — which always carries the user's **original request**, the asks that
     followed, facts the user stated (CIDRs, models, VLANs, device names) and an
     instruction to treat "it/that/as I asked" as that original request;
  4. re-inject the block into the request's `systemInstruction`.
* The estimate is ~4 ASCII chars/token and 1 token per non-ASCII char, which is
  conservative: the real request is smaller than the number shown.
* The app never sends a request larger than the budget (`test/context_budget_test.dart`,
  `test/chat_memory_test.dart`).

## The guidance layer

`ChatService.systemContext` gained a **"How to answer"** section: use the
conversation, never ask the user to repeat something they said, lead with the
answer, give 2–5 concrete steps, ask one clarifying question when it matters
while still answering the likely reading, use the real device names, stay honest.

The keyless path (`lib/services/offline_assistant_service.dart`) now takes the
conversation history: a vague follow-up recalls the original request by name,
and a build answer says which earlier request it continues.

## Routing change

`lib/main.dart`: `_tab = 3` (Chat) instead of `0` (Projects) — the app opens
straight into the conversation. Every other screen is one tap away, deep links
are unaffected (this is only the initial index), and the last conversation is
remembered via the `last_project` preference.

## Rollback

1. `git checkout` (or restore) these files: `lib/main.dart`,
   `lib/screens/chat_screen.dart`, `lib/screens/settings_screen.dart`,
   `lib/services/chat_service.dart`, `lib/services/settings_service.dart`,
   `lib/services/memory_service.dart`,
   `lib/services/offline_assistant_service.dart`, and delete
   `lib/services/context_budget.dart` + `lib/services/conversation_memory.dart`.
2. Or, for a partial rollback with no code change:
   * open on Projects again → set `_tab = 0` in `lib/main.dart`;
   * smaller window → Settings → Chat context budget → 32k.
3. The new preferences (`context_budget`, `last_project`) are additive; old
   versions ignore them, and no stored conversation is migrated or deleted.
