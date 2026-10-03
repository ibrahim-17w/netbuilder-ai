# Requirement inventory + gap analysis — 2026-09-22

Source of every requirement below: the pasted specification
"redesign the chat system in my network-analysis application" (12 numbered
sections), supplied by the user on 2026-09-22. Nothing here is invented; each
row cites the file that carries the evidence.

Status vocabulary: **applied** (works today) · **partial** (partly there) ·
**missing** (not built) · **n/a**.

| ID | Requirement (spec §) | Status | Evidence | Gap to close |
|---|---|---|---|---|
| R1 | Understand natural language instead of manual keyword phrases; keep conversation history and follow-ups (§1) | **partial** | `lib/services/provider_chat_service.dart` (provider-agnostic brain), `lib/services/chat_service.dart` + `openai_chat_service.dart` (real LLM, full history + memory block), `lib/services/conversation_memory.dart` + `context_budget.dart` (history survives, 256k) | The keyword parser (`network_intent.dart`) is still the **fallback** when no key/provider is set. Decision needed: keep it as an explicit offline fallback (current) or make the LLM strictly required. |
| R2 | A **tool layer** between the LLM and the .pkt engine; the model must never touch the file (§2) | **missing** | the engine exists (`sidecar/pkt_fix.py`, `/pkt/audit`, `/pkt/apply_fixes`, `/pkt/undo`, `/pkt/ledger`, `/pkt/read`) but exposes **no callable tools to the model**; the chat asks for JSON *proposals* (`chat_message.dart` action kinds) instead of tool calls | Build the tool registry + dispatcher (`get_topology`, `get_devices`, `get_device`, `get_interfaces`, `get_device_config`, `get_vlans`, `get_links`, `check_connectivity`, `check_subnet`, `check_gateway`, `check_routes`, `check_dhcp`, `analyze_network`, `validate_network`, `save_pkt`, plus the `set_*`/`configure_*` modifiers) over the functions that already exist |
| R3 | Multi-step analysis: several tool calls before the final answer, with an iteration cap (§3) | **missing** | `chat_screen.dart` makes exactly one LLM call per turn | Tool-calling loop with a max-iteration guard and a stop condition |
| R4 | Never show chain-of-thought; show useful progress ("Analyzing topology…", "Checking routing…") (§4) | **partial** | `chat_screen.dart` shows a single status line + a busy bar; the final answer streams | Replace the single status with per-tool progress derived from the loop, and keep reasoning hidden (the API already never returns raw reasoning) |
| R5 | Deterministic networking code for all calculations (§5) | **partial** | deterministic today: the whole sidecar audit/validator (`pt_autopilot.pkt_audit_network`, `validator_service.dart`), the `pkt_fix` engine, `network_intent` addressing | No standalone deterministic helpers exposed as tools: subnet math, network/broadcast, subnet membership, duplicate-IP detection, gateway check, route existence, ACL evaluation, DHCP ranges |
| R6 | Send the model a clean **structured** representation, never binary .pkt data (§6) | **partial** | the audit returns structured devices/findings (`/pkt/audit`); `chat_screen._auditText` renders it; `.pkt` bytes never go to the model | One canonical `{devices, interfaces, links, vlans, routes, services}` context object + a size-bounded serialiser |
| R7 | Networking system prompt with the listed rules (§7) | **applied** | `chat_service.systemContext` — "use the conversation", "never invent credentials", "distinguish observed vs assumed", "lead with the answer", plus the app's evidence rules; `ProviderChatService` sends it on both providers | Add the two lines that only make sense once R2 exists ("use the tools instead of guessing network state", "verify changes after making them") |
| R8 | Separate READ-ONLY from MODIFYING operations; confirm before broad changes (§8) | **applied** | `chat_message.dart` action kinds + `chat_screen._actionCard` render **Approve / Reject / Modify**; `sidecar/pkt_fix.apply_fixes` refuses an empty fix list; `/pkt/reject` records a refusal with no side effects | Classify each tool as read/modify so the confirmation gate applies automatically to every `set_*`/`configure_*` call |
| R9 | Automatically verify a repair and only then report success (§9) | **partial** | after a fix the chat shows the diff and a fresh file (`pkt_fix.apply_fixes`), and `test_pkt_fix.py` re-audits the result | The app does not auto-run `check_gateway` + `check_connectivity` + `validate_network` after applying and report "verified fixed / still broken" |
| R10 | Modern chat UI: history, markdown, code blocks, tables, streaming, loading, tool activity, cancel, retry, clear (§10) | **partial** | applied: history, multi-turn, streaming (`chat_service.stream`), loading bar, Retry button, Clear conversation | Missing: **Markdown / code blocks / tables** (bodies are plain text), **per-tool activity status**, **cancel generation** |
| R11 | Model-independent provider abstraction with `sendMessage` / `streamMessage` / `executeToolConversation` (§11); keys never in the client (§11) | **partial** | `lib/services/ai_provider.dart` (config), `provider_chat_service.dart` (dispatches Gemini or OpenAI-compatible), keys in the platform secure store, masked | No `executeToolConversation()`; no formal interface type. Note: this app is local-first, so the key necessarily lives on the device — it is stored in the OS secure store and never logged (documented in `packaging/AI-PROVIDERS-2026-09-21.md`) |
| R12 | Preserve existing functionality; inspect the project first; no duplicate networking; upgrade in small stages; report the architecture (§12) | **applied** | no engine was rewritten; the chat/AI layer was added on top (`provider_chat_service`, `openai_chat_service`, `ai_provider`); `.pkt` read/edit/repair untouched and still covered by `test_pkt_fix.py` (5 tests) | The written architecture report is this document + `packaging/AI-PROVIDERS-*.md` |

## Definition of done for the open items

| Item | Done when |
|---|---|
| R2 tool layer | every tool in the list resolves to an existing engine function (or is marked n/a with a reason), each declared read-only or modifying, and a test dispatches each one against a real `.pkt` |
| R3 loop | a scripted conversation calling ≥3 tools in one turn terminates with a final answer, and a forced runaway loop stops at the cap and reports it |
| R4 progress | each tool call emits its own status line; no raw reasoning reaches the UI |
| R5 deterministic | unit tests for subnet math, duplicate IP, gateway check, route existence against fixed fixtures |
| R6 context | one serialiser emits the documented object for a real `.pkt`, with a byte cap |
| R9 auto-verify | after an approved fix the app runs validate + the relevant checks and reports the verified outcome (or says it is still broken) |
| R10 UI | Markdown/code/table rendering, tool activity list, and cancel-generation all reachable from the chat |
| R11 | `executeToolConversation()` on the provider abstraction, implemented for both providers |

## Suggested build order (small, testable stages)

1. R6 + R5 — structured context + deterministic helpers (pure, fully testable, no LLM).
2. R2 — tool registry over those helpers and the existing engine, with read/modify classification.
3. R3 + R4 — the loop and its progress stream.
4. R9 — auto-verification after a repair.
5. R11 — `executeToolConversation()` on both providers.
6. R10 — Markdown rendering, tool activity, cancel.

## Not in scope

* Rewriting working engine code for style.
* Destructive/bulk data migrations.
* Third-party accounts or paid services.
* New requirements beyond the 12 above (they will be listed as suggestions only).

---

## Status update - tool layer and loop delivered

This section records what was built after the matrix above, and is the
acceptance basis for the remaining work.

### Delivered

| Piece | File | Evidence |
|---|---|---|
| Deterministic networking | `lib/services/network_tools.dart` | exact IPv4 maths, membership, duplicate IPs, gateway rules; 15 tests |
| Structured context | same module, `buildContext()` | devices/interfaces/links/vlans/routes/findings, size-bounded |
| **Tool layer (R2)** | `sidecar/net_tools.py` | **31 tools** (19 read, 12 modify); `GET /tools/list`, `POST /tools/call`; 10 tests |
| **Tool protocol** | `lib/services/tool_protocol.dart` | declarations + call parsing for Gemini and OpenAI; 9 tests |
| **Bounded loop (R3)** | `lib/services/tool_loop.dart` | max-iteration cap reported, tool errors fed back; 5 tests |
| **Runtime wiring** | `lib/services/tool_runtime.dart` | provider + `/tools/call` joined; 9 tests, incl. end-to-end |
| **Service turn** | `lib/services/provider_chat_service.dart` | `streamWithTools()`; falls back to the existing path; 4 tests |
| **Live chat** | `lib/screens/chat_screen.dart` | `_withTools()` attaches the runtime once a real `.pkt` is scanned |
| **Auto-verify (R9)** | `sidecar/net_tools.py` -> `verify_repair` | re-audit compared against the original; 6 tests |

### Requirement status

- **Applied**: R1 (model is the brain; keyword parser retained only as the
  offline/no-key fallback), R2, R3, R4 (a progress line per tool call), R5, R6,
  R7 (both provider dialects), R8, R9 (the verification logic and its tool),
  R11 (both providers behind one abstraction), R12 (no engine code rewritten).
- **All twelve are now applied.** The last three landed after the block above:
  markdown/tables/fenced-code rendering in chat bubbles
  (`lib/widgets/chat_markdown.dart`, wired into the assistant bubble inside a
  `SelectionArea`), cancel-generation
  (`lib/services/generation_control.dart`, with the composer's send control
  becoming a stop control while a turn streams), and R11's
  `executeToolConversation()` returning `ToolLoopEvent`s rather than text.
  R9's auto-trigger is wired too: `_applyPktFix` re-audits both the original
  capture and the new file and appends the engine's verdict to the message.

### Invariants held

- The model never reads or writes a `.pkt`: tools answer from a server-side
  audit, and every `modify` tool returns
  `{kind: modify, requiresApproval: true, proposal: ...}`. A test asserts the
  capture's SHA-256 is unchanged after a tool call.
- Nothing that worked before was rewritten: when the sidecar or a capture is
  absent, chat follows the original code path exactly.

### Verification commands

```
flutter analyze                      -> No issues found
flutter test                         -> 203 passed
cd sidecar && py -3.14 -m pytest -q  -> 389 passed, 1 failed
                                        (test_ocr_perf golden OCR: pre-existing,
                                         tesseract/environment dependent)
python -c "import net_tools; ..."    -> count=31 read=19 modify=12
flutter build apk --release          -> 59.5 MB, exit 0
```

Build published to `dist/NetBuilderAI-Tester.apk`
(59.5 MB, SHA-256 `1D9D7572528500056227B07A3957D2E755D38E708F0D03491C42D791BAFBA7BF`).

### Not verified by AutoCoder

No turn has been run against a live model key with a real `.pkt`. Every
boundary up to the network is covered by injected-client tests; the final hop
to a real provider endpoint is untested here.
