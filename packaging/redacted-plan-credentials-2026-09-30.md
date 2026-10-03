# A plan whose password was redacted came back "missing a password" (2026-09-30)

## Symptom

The 35-device two-site brief was permanently unbuildable, on **both** paths
(keyless and Gemini):

```
[error] SRV2 aaa rule has an account missing username or password; it will not be submitted.
Not buildable yet - 1 finding(s)   [Fix the plan]
```

"Fix the plan" answered *"I cannot repair these from here - each one needs a
choice only you can make"*, and telling the app the credential again
("the aaa username: admin and password 123") changed nothing. The brief states
the account, so the finding was a false one and nothing the user could type
would clear it.

## Diagnosis (from the app's own database, not from the code)

`C:\Users\L\Documents\netbuilder\memory.db` → `conversations.stateJson`:

| conversation | SRV1 | SRV2 `serviceRules.aaa.users` | security |
| --- | --- | --- | --- |
| `default` (29 Sep) | `[dhcp, dns]` | `[{"username": "admin"}]` | `aaaUsername: admin`, no password |
| `chat 13:4945` (keyless) | `[dhcp, dns]` | `[{"username": "admin"}]` | same |
| `chat 13:5426` (Gemini) | `[dhcp]` | `[{"username": "admin"}]` | same |

The third row was written minutes *after* the second by the same build, and its
plan is the current parser's output — so the missing password is not a parse
bug at all. It is the **redaction at rest**:

1. The standing plan is persisted with
   `jsonEncode(intent.toJson(includeSecrets: false))`
   (`chat_screen._rememberArtifact` and the `_state.withIntentJson(standing…)`
   write before every turn).
2. `_copyServiceValue` drops **every** key matching `password|secret|psk|token`
   at any depth — including the `password` inside an account row, which leaves
   `{"username": "admin"}`: an account that still names its user and no longer
   holds its password.
3. `_loadConversation` restores that JSON into `_lastIntent`, and the validator
   reads the row as an account the user never finished writing.
4. `PlanRepairService` cannot fix it and must not: inventing a password is the
   one repair this app refuses to make. So the finding blocked the build for
   good, and every follow-up re-merged into the same broken standing plan.

Second harm, silent: `pkt_builder` keeps a row that has a `username`
(`users = [u for u in aaa.get("users") if u.get("username")]`) and writes it
with an empty `PASSWORD`, so a plan in this state would build an AAA account
nobody can log in with. The blocking finding was, in a sense, the honest half
of the bug.

## Fix

`NetworkIntent.recoverRedactedSecrets(plan, transcript)` — the other half of the
same record is the conversation, whose user turns still hold the brief verbatim.
Redaction is reversed from there, never guessed at:

* every account row with a username and no password takes the password the
  transcript states for that username (`readCredentials`, the same reader the
  parser uses);
* `security.aaaUsername` / `aaaAccountPassword` / `aaaPassword` are filled the
  same way (`resolveAaaKey` for the shared key), plus a stated `enableSecret`
  and VPN pre-shared key;
* **only empty slots are filled** — a plan that genuinely has no credential
  still reports the gap and still asks the user for it.

`chat_screen._loadConversation` runs it over the transcript
(`history.where(role == 'user')`, the whole stored conversation) right after
decoding the saved plan, so a reopened conversation — including the one that was
stuck — comes back whole.

Revision stability matters here: `NetworkIntent.revision` hashes what the plan
*contains* (devices, links, addressing, services, non-secret security fields)
and not its secrets, so recovery does **not** move the revision and every build
card already written for that plan still fits it. A test asserts this — without
it the fix would have traded one dead end ("not buildable") for another
("stale card").

Also: `OfflineAssistantService.fixPlan` now names the one remedy this finding
has — *say "AAA username admin password 123"* — instead of only offering
topology examples ("move the branch onto 192.168.20.0/24"), which is advice a
missing login cannot use.

## Files

| file | change |
| --- | --- |
| `lib/models/network_intent.dart` | `recoverRedactedSecrets` + `_preSharedKeyIn` |
| `lib/screens/chat_screen.dart` | `_loadConversation` recovers the restored plan from the transcript |
| `lib/services/offline_assistant_service.dart` | `_credentialRemedy` in the "fix the plan" reply |
| `test/restored_plan_credentials_test.dart` | new — 9 checks |

## Verified

* `flutter analyze` — clean.
* `flutter test` — 873 passed / 0 failed (864 before + 9 new).
* The real stored plan, read out of `memory.db` and put through the fix:
  `SRV2` account `admin`/`123`, `aaaAccountPassword` and `aaaPassword` back,
  and **no blocking findings left** (it had exactly one before).
* Windows release rebuilt (`data/app.so`, 23:52) so the running dev build picks
  the fix up. No sidecar change, so the frozen engine stays as it is.

## Carry-over

The same redaction catches a *build record* whose project never wrote the
keychain copy (`SecretVault` is written by the new-build screen only), e.g. a
record made before that path existed: `BuildArtifactService.restore` has the
record's `instruction` in hand and could run the same recovery.
