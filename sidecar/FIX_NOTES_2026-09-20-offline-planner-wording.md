# Offline planner: understand the brief, need no key (2026-09-20)

The offline planner is the path that has to work when there is no Gemini key,
no quota and no network - and it is the path a user lands on the moment the
key is rate-limited. Two things were wrong with it: it only understood a
narrow English wording, and the app still made the AI step look required.

## The wording bridge (`lib/models/network_intent.dart`)

`NetworkIntent.bridgeBrief()` runs before the parser and rewrites only the
phrases the parser keys on, leaving everything else - and Latin case, so a
password survives - untouched:

* **Arabic** phrase table (`جهاز التوجيه` -> router, `المبدله` -> switch,
  `خادم` -> server, `الفرع الرئيسي` -> headquarters, `امن المنافذ` ->
  port security, `نفق` -> vpn tunnel, ...), applied longest-first so
  `جهاز التوجيه` (router) wins over the bare `جهاز` (pc) inside it.
* **Arabic-Indic digits** (`٢٣`, `۲۳`) -> ASCII, plus right-to-left marks,
  tashkeel and the Arabic letters that have several spellings
  (`أ/إ/آ` -> `ا`, `ى` -> `ي`, `ة` -> `ه`) folded so one table entry matches
  every way a brief is written.
* **Dotted masks**: `192.168.1.0 255.255.255.0` and its
  `subnet mask` / `قناع الشبكة` spellings become `192.168.1.0/24`, so the
  address tables course briefs use feed the same CIDR logic. A pair of plain
  addresses (`192.168.1.1 192.168.2.1`) is not a mask and is left alone.
* **Spelled-out numbers**: `two routers`, `اثنين موجه` -> `2 routers`.
* **English synonyms** the parser used to miss: `business/working hours` ->
  office hours, `site to site` -> site-to-site, `user ports` and
  `centralized authentication` recognised as security intent.

Security-intent detection was widened with the same idea: `rogue dhcp`,
`sticky mac`, `mac address`, `vty`, `radius`, `vpn`/`tunnel`, `network
security`, `layer 2 security`, `access ports`. Office hours now parse
`09:00 to 17:00`, `9:00-17:00`, `from 8 until 16`, `9 am to 5 pm` and the
Arabic connectors.

Credentials are **read from the brief, never invented** - a rule the existing
suite enforces. `username labadmin password LabAdmin2026`,
`اسم المستخدم labadmin كلمة المرور LabAdmin2026` and
`pre-shared key NetBuilderLab2026` all parse; two guards keep a *description*
out of it (a bare `user` needs an explicit separator, and neither half may be
one of the keywords), so "the router asks the server for the username and the
password" is not read as a credential.

## The app no longer needs the key (`new_build_screen.dart`, `chat_screen.dart`)

* New Build has a **"Plan offline only"** switch, on by default: the
  deterministic local planner runs with no key, no quota and no network.
* When the AI planner is asked for and fails, the log says one short line
  (`AI planner unavailable (rate limited); planned offline instead.`) instead
  of dumping an exception - the offline plan is already complete.
* Chat no longer stops at "Could not reach the model": it answers from the
  local planner with the devices, links, addressing, routing and security
  controls it understood, plus where to build it.

## Validator wording (`validator_service.dart`)

The IPsec warning claimed Packet Tracer "does not implement crypto isakmp".
That is not true of PT itself - PT ships the feature set; its ISR images
reject the crypto commands until the Security Technology package is licensed.
The warning now says exactly that, including the enabling command and the fact
that the block is already in the generated config for pasting by hand. The
time-range warning now also says what is applied instead (the plain
manager-only ACL).

## Sidecar (`pkt_builder.py`)

`warnings` is de-duplicated before it reaches the UI: one decision was
re-reported for every interface that used it (the same slot remap five times,
the same model substitution once per port), which made a correct build look
alarming.

## Verification

* `flutter analyze`: clean; `flutter test`: **78 passed** (15 new in
  `test/offline_planner_test.dart`, including the real Arabic course brief as
  `test/fixtures/security_brief_ar.txt`).
* Sidecar `python -m pytest -q`: **342 passed**, 1 pre-existing failure
  (`test_ocr_perf.py` golden OCR text, environment/tesseract dependent and
  untouched by this change).
* End-to-end offline proof, no Gemini key and no Packet Tracer open: the
  Arabic brief went through `NetworkIntent.parseSimple` ->
  `PacketTracerAdapter.autopilotPlan` -> `pkt_generate` and produced
  `pkt_output/*.pkt` with 10 devices and 9 links (114 KB, manifest stamped
  `"generator": "offline"`).

## Still not possible (reported, never silently skipped)

* Server **service panels** (DHCP/DNS/HTTP/AAA tabs) are Packet Tracer runtime
  state, not save-file data: an offline `.pkt` has the servers placed and
  addressed, with their service tabs empty. A live run configures them.
* Model fidelity follows the machine-local template library: this machine has
  a 2811 (router) and 2960-24TT (switch) saved, so a plan asking for 2911
  gets 2811 with a warning, and `g0/0` lands on `FastEthernet0/0`
  (`s0/0/0` -> `Serial0/2/0`).
* The live executor still elides the crypto family (`crypto isakmp`,
  `crypto ipsec`, `crypto map`) and `time-range`, IP SLA, QoS policy maps and
  zone-based firewall blocks, because those were observed rejected by the
  live CLI. Enabling the security package before typing the crypto block is
  the fix, and it needs a live run to verify.
