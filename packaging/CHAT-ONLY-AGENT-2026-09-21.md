# NetBuilder AI — chat-only networking agent (2026-09-21)

## What this build is

The app is **one screen**: a chat with a networking-engineer agent. Uploads,
analysis, fix proposals, approvals, the audit ledger and exports are all cards
in that conversation. There are no tabs, no settings page and **no Packet
Tracer window** — analysing a save is pure file work.

### Interpretation note (important)

"Packet Tracer" here means the **Cisco Packet Tracer `.pkt` save file**, not a
`.pcap` capture. That is what this codebase produces and consumes, and it is
what "decrypt it and encrypt it back" refers to: the `.pkt` container is
encrypted (Twofish/EAX + zlib), so the flow is decrypt → edit → re-encrypt.
If you actually meant Wireshark `.pcap` files, say so — that is a different
parser and a separate piece of work.

## The flow

1. **Attach** a `.pkt` with the router button in the composer, or type
   `/scan C:\path\to\lab.pkt`.
2. The sidecar **decrypts** it (`pkt_codec`) with no Packet Tracer and audits
   the saved configuration against the saved topology (`/pkt/audit`).
3. The chat shows a **findings card** with the prioritised faults, and one
   **Approve / Reject** card per fixable finding.
4. **Approve** applies exactly that one fix to the decrypted XML, syncs the
   saved port state, **re-encrypts** a valid `.pkt`, writes a manifest and a
   ledger entry, and replies with the diff and the new file path.
   **Reject** writes one ledger line and changes nothing.
5. **Undo** on an applied change restores the save from before it, as a new
   file, so both versions can be compared.

Typing `/help` in the chat lists all of this.

## In-chat commands

| Command | Effect |
|---|---|
| `/help` | what the agent can do |
| `/scan <path>` | decrypt + audit a `.pkt` offline |
| `/ledger` | every capture, decision, change, export and undo |
| `/key <value>` | store the Gemini key **without echoing it** |
| `/model <name>` | change the model |
| `/budget <tokens>` | change the context ceiling (8k–1M) |

A secret command is stored in the ledger as `••••••••`.

## Configuration

| Knob | Where |
|---|---|
| Context ceiling | `lib/services/context_budget.dart` → `ContextBudget.defaultContextTokens` (262144), or `/budget` |
| Model | SettingsService (`/model`), BYOK |
| Sidecar port | `AutopilotService.base` = `http://127.0.0.1:5005` |
| Fixed output dir | `sidecar/pkt_output/` (+ `versions/` for undo) |
| Ledger | `sidecar/pkt_fix_ledger.jsonl` |
| Fixed-save limit | `pkt_fix.MAX_BYTES` = 64 MB |

## Run it

```powershell
cd C:\ai\app\sidecar
python -m pip install -r requirements.txt      # once
python pt_autopilot.py                          # leave running on :5005
cd C:\ai\app
flutter run -d windows                          # or: flutter build windows --release
```

## Verify it yourself

```powershell
# engine (real .pkt files, real decrypt/encrypt)
cd C:\ai\app\sidecar
py -3.14 -m pytest -q test_pkt_fix.py

# the app
cd C:\ai\app
flutter analyze
flutter test
```

## Rollback

* **Undo a fix:** the Undo card, or `POST /pkt/undo` — restores the previous
  save as a new file. The fixed file stays, so you can diff them.
* **Revert the whole build:** restore `lib/main.dart` (the shell), and delete
  `lib/services/pkt_fix*` usage by reverting `lib/screens/chat_screen.dart`,
  `lib/services/autopilot_service.dart`, `lib/models/chat_message.dart`,
  `sidecar/pkt_fix.py` and the `/pkt/apply_fixes|reject|undo|ledger` blocks in
  `sidecar/pt_autopilot.py`. The engine writes only into `sidecar/pkt_output/`
  and `sidecar/pkt_fix_ledger.jsonl`, so deleting those two leaves no trace.
* **Restore the old tabbed UI:** the screens still exist
  (`builder_detail_screen.dart`, `new_build_screen.dart`, …); put back the
  `bottomNavigationBar`/`floatingActionButton` in `lib/main.dart`.

## Risks and open items

| # | Item | Owner | Next action |
|---|---|---|---|
| 1 | `.pcap`/`.pcapng` **parsing** is not implemented (out of scope: no full analyzer). A stray `.pcap` is now *identified by magic bytes* and explained in chat instead of failing to decode | user | confirm if `.pcap` parsing is wanted; the wrong-format path already fails clearly |
| 2 | ~~**Modify** on a fix card is not implemented~~ **DONE** - edit the commands in a dialog, then Approve edited | - | - |
| 3 | ~~`appliedFixes` counts config-line edits only~~ **DONE** - now counts every changed device (config or port state); a port-state-only fix reports `1` | - | - |
| 4 | The agent's answers without a key come from the offline knowledge base (routing OSPF/EIGRP/BGP/default, STP, EtherChannel, VLAN/trunk, DHCP/DNS, MTU/MSS, TCP internals, NAT, ACL, QoS, wireless roaming, IPv6, subnetting) - smaller than a model's, so add a key for open-ended answers | dev | add a key |
| 5 | Android has no sidecar, so capture work is Windows/desktop only | dev | — |
| 6 | Undo keeps every version forever | dev | add retention |

## Verified in this build (evidence)

* `flutter analyze` → No issues found
* `flutter test` → **131 passed** (incl. a UI test that the fix card shows Approve / Reject / Modify)
* The fix card carries **Approve / Reject / Modify**; every path goes through the same approval gate
* `sidecar py -3.14 -m pytest -q` → 372 passed, 1 known pre-existing OCR failure
* `py -3.14 -m pytest -q test_pkt_fix.py` → 5 passed (real `.pkt` decrypt →
  apply → re-encrypt → re-audit shows the finding gone → undo byte-identical)
* HTTP round trip against a live sidecar: audit (6 devices) → apply (new
  50,041-byte `.pkt`, sha `6f32a8a3…`, diff shown) → reject (recorded, nothing
  applied) → bad inputs (400 with a readable error) → undo (restored) →
  ledger (append-only), source file hash unchanged. Re-run: `applied=1` for the
  port-state-only fix (the counter bug is fixed).
* Format guard: `/pkt/identify` names a `.pcap` (magic d4 c3 b2 a1), a
  `.pcapng` (0a 0d 0d 0a) and a plain-XML file, and the chat shows that
  sentence instead of a decode error.

## Not verified

* No `.pcap` support (see risk 1) - this is the one scope question.
* The chat's own UI flow (attach button → card → Approve) was exercised at the
  widget level and the API behind it end-to-end, but not clicked through by a
  human in this session.
* Live Gemini answers need a key.
