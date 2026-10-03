# What a sweep of real briefs found (2026-10-01)

The request was broad — *"run some more tests on the app, try different
networks and tell it to fix them or change the layout and make these
improvements into it"*. So the sweep did what the user does: **type a network,
then walk the whole chain** — `CasualEnglish.normalize` → `parseSimple` →
follow-up edits → `ValidatorService.validate(target: packet-tracer)` →
`PlanRepairService.repair` → the write/read pair the chat persists with
(`toJson(includeSecrets: false)` → `fromJson`) → `recoverRedactedSecrets` →
`LayoutRequest.read` for drawing asks.

Twenty-four briefs, nine follow-up edits, fourteen layout asks and six repair
asks were run this way. Every one is now a permanent case in
`app/test/plan_audit_test.dart` (37 checks) — the sweep itself was scratch and
was deleted, so nothing here depends on a file nobody keeps.

## The findings, in the order they were fixed

| # | Brief (as typed) | What came out | Cause | Fix |
| --- | --- | --- | --- | --- |
| 1 | `1 router and 3 pcs` | every PC on **one** router port (`r1:g0/0 is used by N links`), no LAN addressing at all | a switch-less brief had no LAN pass | one interface per endpoint, spread over the routers; a switch is added when the endpoints outnumber the free ports; the router gets `.1` and the endpoint `.10` on a real subnet |
| 2 | `harden the network: port security…, dhcp snooping, ssh instead of telnet and aaa on the vty lines` | a **one-device** plan (SRV1) with four fault findings and no reply able to clear it | the security-lab profile required a *device noun* to fire | a brief that names controls and **no device** is the profile's own case (`_namesNoDevice`) |
| 3 | `VLANs 10, 20, 30 and 40` | `vlans = []` — a router-on-a-stick lab planned flat | the normalizer trims commas, and the list regex needed them | the separators are optional: `10 20 30 and 40` reads as four VLANs |
| 4 | `a wireless router with SSID HOME and WPA2, 3 laptops and a printer` | "WR1 has rules for wireless but did not request that service" | an AP's own SSID rule counted as "not requested" | `_roleIsIntrinsicTo`: wireless is intrinsic to the wireless kinds (there is no Services tab for them) |
| 5 | `a home iot network with a wireless router, 4 smart bulbs and 2 laptops` | "no links are defined, so all 4 devices would ship standing alone" — a **blocking** error | association is not a cable | wireless kinds are not islands (they join), and the uncabled ones are said out loud instead |
| 6 | `2 routers over a serial link…` | unbuildable by anything the user could type: the note that the *build itself* remaps the cable withheld the build | one severity for two different things | see below |
| 7 | `3 routers, 2 swtichs and 10 pcs with ospf` | **one** switch — the brief's second switch was gone | the typo table listed `swtich` (singular) and not `swtichs` | plural typos fall back to their singular (`swtichs` → `switches`) |
| 8 | `a wireless router and 4 laptops` | a plain **2911** instead of the Wireless Router-PT | fix 7's fallback turned `wireless` into `wirelesses` (the singular of `wireles` ends in an s) | never put a suffix back on a word that already carries one; the typo repair is now asserted not to touch real words |
| 9 | `a wireless router and 4 smart bulbs` | **no** IoT devices at all ("bulbs" was not a device noun) | the catalog knew the word `iot` and not the things | `smart bulb`, `bulb`, `smart plug`, `smart camera`, `smart lock`, `thermostat`, `doorbell`, `sensor` are IoT nouns |
| 10 | `site-to-site ipsec vpn with pre-shared key LabKey1` (with its own device counts) | `ipsecVpn: false` — the user asked for a tunnel and the plan said nothing about one | only the device-less security profile ever set the VPN fields | the tunnel is now planned on the generic path too (below) |
| 11 | `a wireless lan controller with 2 access points and 8 laptops` | `WLC1 has no link… cable it or say so` — **blocking**, and uncurable: the plan deliberately cannot name that port | the device catalog's own rule ("empty port = do not invent a cable") was not the validator's rule | a kind with no port name is placed-not-wired: an `info` note, never a refusal |

## The core change: a finding can be advice

`ValidationIssue` gained `final bool? blocking` and `bool get blocks =>
blocking ?? severity != 'info'`.

An **error** always withholds the build. A **warning** withholds it unless the
app already acts on the finding by itself. Marked `blocking: false` (reported,
never withholding):

- a serial WAN whose module the executor fits and remaps itself,
- an unsupported-service rule staged for review,
- explicit advice (VLAN 1, avoid-VLAN-1-on-a-name),
- the IPsec/`securityk9` licensing note,
- Packet Tracer's missing `time-range`,
- a manager-only VTY rule with no office hours,
- Packet Tracer's limited BGP,
- a device that is placed but not cabled by design (the WLC).

Wired into the one gate everywhere: `chat_screen._blockingFindings`,
`OfflineAssistantService._blocking`, `PlanRepairService.remaining` and the
repair test helper. Six bugs in this sweep were findings that blocked a build
nobody could clear; that class is what this distinction removes.

## The tunnel asked for is the tunnel planned

The generic path now sets the VPN from the brief, and every value is read off
the plan it just built rather than from one profile's constants:

- `_tunnelEnds()` — the two routers sharing a WAN link are the peers
  (`vpnPeerA/B`), and each one's LAN is what the tunnel protects
  (`vpnLocalNetwork/RemoteNetwork`).
- The key is only ever what the brief states (`_preSharedKeyIn`), so a tunnel
  asked for without one is staged, not invented.
- `cisco_adapter` applies the crypto map to **the device's own WAN port** and
  decides which end it is by which subnet it owns. The old rule was
  `device.name == 'HQ_Router'`: in any other plan both routers took the A side,
  protecting the same LAN and pointing at the same peer.
- `packet_tracer_adapter` pings a host that exists (the first addressed
  endpoint on the far side of the tunnel) instead of the profile's
  `192.168.2.10` / `192.168.1.102`.
- The IPv6 dual-stack pass moved **above** the security return. It used to sit
  after it, so `2 routers and 4 pcs with ipv6 and ssh` silently lost every
  IPv6 address.

### The probes are advisory, on purpose

Packet Tracer's ISR images elide `crypto isakmp` / `crypto ipsec` / `crypto
map` until the Security Technology package is licensed — the executor has
always reported that as an unsupported feature. A probe that expects `QM_IDLE`
therefore *cannot* pass on the image the app is driving, so it was a guaranteed
false failure. The IKE/IPsec checks now carry `"advisory": true`: they still
run, their evidence is still recorded, and they no longer withhold the run
(`RUN["security_failed"]` excludes them, `RUN["security_advisory"]` counts
them). New sidecar test: `test_advisory_check_is_reported_but_cannot_fail_the_run`.

## Verified

- `flutter analyze` clean; **`flutter test` 911 passed / 0 failed** (9 new in
  `plan_audit_test.dart`).
- Sidecar: **427 passed / 0 failed** (`--ignore=test_ocr_perf.py`, the known
  environment failure).
- End to end through the freshly rebuilt frozen engine
  (`POST /pkt/generate`, no Packet Tracer):
  the two-site IPsec plan builds — **12 planned devices / 11 planned links ==
  12 devices / 11 links in the file** — and the decoded file carries the tunnel
  on both ends:

  ```
  R1: crypto isakmp key LabKey1 address 10.0.0.2   set peer 10.0.0.2
      permit ip 192.168.1.0 0.0.0.255 192.168.2.0 0.0.0.255
  R2: crypto isakmp key LabKey1 address 10.0.0.1   set peer 10.0.0.1
      permit ip 192.168.2.0 0.0.0.255 192.168.1.0 0.0.0.255
  ```

  Kept: `Release/sidecar/_internal/pkt_output/ipsec-e2e.pkt`.
- Windows release rebuilt; the frozen engine rebuilt and installed
  (`_internal/pkt_templates` + `pkt_seed` included, `/health` ok,
  pid running from `build/windows/x64/runner/Release/sidecar`).

## Still open (carried, with the reason)

- A 3-router/2-site brief states one transit subnet and needs two: generate the
  second or ask — the decision is the user's, not the parser's.
- `"fix every finding you got then build"` is still a no-op: the app reports
  its findings but cannot apply their remedies itself. That is a feature, not a
  one-liner.
- The build preflight still mis-compares plan-vs-file links ("34 planned
  link(s) not found in the file" on a file that has all 34).
- The live-canvas layout (`pt_autopilot._layout_spot`) still draws type rows
  and does not reuse the tier model the .pkt generator uses.
- `SecretVault` is written only by `new_build_screen.dart`, so a **build
  record** whose project never wrote the keychain copy hits the same redaction
  the plan did. `BuildArtifactService.restore` has `record.instruction` in hand
  and could run the same recovery.
