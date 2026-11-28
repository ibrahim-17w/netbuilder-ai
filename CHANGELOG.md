# Changelog

## Unreleased

### Added

- **Reading a saved lab on the phone.** "Analyze this capture" no longer
  waits on a desktop engine a phone cannot run: the file is decrypted, its
  devices, cables, addresses and saved configurations are audited in Dart, and
  the report offers to turn the file into the lab the conversation edits. When
  the engine is present it is still preferred; when it is not, the phone reads
  the file itself instead of blaming the platform.
- **The sample labs taught the library eight hardware variants.** Harvesting
  the 48 labs in the training folder added the module combinations they use -
  a serial 2911, a 2911 with an SFP WAN port, 3650 stack members with their
  built-in module and power supply, and Router/Switch-PT chassis with common
  NM modules - plus the rollover and fiber cable templates the saves contain.
  Every one of those labs now rebuilds to the same device list, and cables the
  library genuinely cannot reproduce are named in the build report rather than
  dropped.
- **Local training export.** A download action in the chat header exports
  every conversation, the plans, builds, attempts, changes, rules and learned
  answers behind them, questions the offline material could not answer, the
  generated `.pkt` files and chat attachments, and a redacted app log into one
  JSON document. Nothing is uploaded: the user reviews the document and sends
  it themselves. API keys, secure-storage values and local preferences are
  excluded; embedded files carry SHA-256 hashes and explicit size-limit
  omissions, and generated files are warned about because a lab `.pkt` can
  contain credentials.
- **Triage before technology.** The offline engineer now reads the shape of a
  fault report before it names a protocol. Scope is treated as evidence - one
  host, everyone, wireless-only, wired-only, VPN-only, one VLAN, one site, one
  application, intermittent, periodic, a fixed delay, small-packets-only,
  ping-but-no-TCP, IP-but-no-name, one direction, after a reboot, after a
  change or a steady state - and each finding states what it rules out and the
  test that proves the boundary. The notes are appended to the playbook ladder,
  never substituted for it. A named change is correlated with the failure it
  characteristically causes (MTU/PMTUD, VLAN trunk, ACL order, NAT order, route
  prefix, firmware, switch replacement, DNS, DHCP scope, certificate, QoS, ISP,
  wireless, AAA, addressing, power, hypervisor) and given a first test and a
  rollback. Two symptoms in separate clauses are checked for one shared cause
  before two ladders are worked. A pasted IOS/NX-OS or ASA syslog line is
  decoded by facility, severity and mnemonic with the check that proves it, and
  an unknown mnemonic still gets its severity and first step. "Connected but no
  internet" and "ping works but the browser does not" get ordered check
  ladders, and so do a device that pings while its service fails, a guest
  portal that will not load, a resource that works from one VLAN but not
  another, and a link that is up with no traffic. New ladders cover a host with
  an address but no gateway and a device that reloads by itself, and the
  playbooks now recognise the ticket spellings for vPC peer links, CAPWAP
  joins, console lockout, PoE night reboots, BGP looking-glass invisibility,
  split DNS, ACL host mismatches and late collisions on an uplink. A complaint
  with no symptom ("the network is acting weird") gets the three questions
  that narrow it.
- **The English layer.** A deterministic understanding pass now reads the
  question the way it was typed before any corpus sees it: symptom phrasing is
  expanded ("bgp keeps bouncing" gains "flapping", "is not carrying vlan 20"
  gains "not passing"), British spellings and split compounds fold onto the
  corpus token, tone frames ("quick q", "for my ccna", "can you tell me") are
  stripped, spoken prefixes become real ones ("slash twenty nine" is /29), and
  spelled numbers become digits only before a countable noun ("five hundred
  hosts" is 500 hosts, while "one way audio" stays a symptom). It leaves
  addresses, CIDRs and commands intact.
- **A second corpus wave: ninety-five playbooks, seventy-one fact sets and
  one hundred sixty-one technology entries.** New diagnoses for BGP/OSPF
  adjacency, AS-path loops, RPKI invalids, STP blocking the wrong port,
  BPDU Guard err-disable, native-VLAN mismatches, incomplete ARP, LACP
  imbalance, microbursts, voice registration and one-way audio, cloud egress,
  route black holes, Kubernetes service and DNS failures, SNMP/syslog/NetFlow
  silence, config drift, AP reboot loops and default-route failures. New
  entries for IPv6 RA Guard, TrustSec, MAC spoofing defence, IoT/OT
  segmentation, guest isolation, TLS inspection, serverless networking, cloud
  landing zones, VPC peering, sub-second failover, fibre testing, config
  backup, monitoring, runbooks, network documentation, floating statics,
  conditional defaults, flat-network judgement, redundancy cost, VLAN
  numbering plans and OSPF over a WAN. New facts: VPN and firewall capacity, DHCP lease timers, STP cost,
  EtherTypes, frame size, IPv6 allocation sizes and special addresses, AAA and
  802.1X timers, port-security and err-disable defaults, NetFlow cache timers,
  NTP values, well-known communities, ICMP types, Wi-Fi channels, EVPN route
  types, IS-IS timers and the IPv4 header.
- **Address plans and WAN circuits are computed, not described.** "How do I
  plan IP addresses for 40 branches" returns the reserved 10.20.0.0/16, the
  site formula (site 40 is 10.20.39.0/24), the /25 users and /26 voice split
  inside each /24, a separate /31 block and loopback block, the one summary
  route the WAN advertises and the cloud/VPN ranges to reserve first - with a
  banked layout when the site count outgrows one /16. "How many IP addresses
  do I need for 500 users" returns the block (/22, 1,022 usable) rather than a
  range. "How do I size the WAN link for 200 users" returns the busy-hour
  arithmetic (40 Mbps, 52 Mbps with headroom), the 20 percent concurrency
  voice budget and the circuit and second-provider rule.
- **Senior design sizing, not generic advice.** Wireless questions now
  compute access points from area and active clients (with PoE and uplink
  figures), explain 5 GHz channel width as a reuse decision, and give the
  SSID count and policy split. DNS redundancy names the minimum pair, the
  per-site resolver and the WAN dependency. Core and distribution counts
  explain the pair rule, the collapsed-core boundary and the pair per
  building. A bare multi-building brief gets a campus LAN (fiber type,
  diverse paths, per-building summary), and a DMZ brief gets a policy zone
  with no DMZ-to-inside path.
- **A senior fault corpus.** Ninety-five diagnostic playbooks answer a
  named fault state with what it proves, ranked causes, the read-only
  command that separates them, the fix and the rule that keeps it from
  coming back. They cover BGP/OSPF/IS-IS/EIGRP/BFD, VLANs, trunks,
  err-disabled, MAC flaps, loops, LACP, vPC/MLAG, DHCP, snooping, DAI, FHRP,
  NTP, DNS, IPsec, NAT, ACLs, 802.1X, wireless join and drops, VXLAN,
  multicast, voice, PoE, cloud, MTU black holes, asymmetric routing and more.
- **A fact book of exact numbers.** Seventy-one reference sets (timers,
  distances, VLAN and label ranges, port numbers, protocol numbers,
  overheads, DSCP/CoS, HSRP/VRRP/GLBP values, MTU/MSS, PoE classes, syslog,
  RADIUS/TACACS+, Wi-Fi standards, T1/DS1 rates, the voice latency budget,
  NTP server count, VPN and firewall capacity, lease and cache timers, ICMP
  types, EVPN route types and rack power) answer "what is the default ..."
  with the number, not a paragraph that contains it.
- **Sixty-eight new technology entries**, then a second wave, taking the
  catalog to one hundred sixty:
  EVPN, vPC/MLAG, segment routing, IS-IS, BFD, DMVPN, GRE, anycast, PTP,
  streaming telemetry, SASE, MACsec, DHCP snooping, DAI, IP Source Guard,
  QinQ, LACP, CAPWAP, Wi-Fi 6/7, roaming, EAP-TLS, transit gateway,
  PrivateLink, campus design, L2 vs L3 access, failure domains, convergence,
  CoPP, uRPF, RPKI, OSPFv3, SLAAC and IPv6 Neighbor Discovery. Each carries
  mechanism, when to use it, its trade-offs, commands, verification and
  pitfalls. Switch hardening covers the management, control and data planes
  with an ordered checklist and a parking VLAN.
- **Hosts-in-a-prefix arithmetic**: "how many hosts does a /28 support" now
  computes the count, mask, range, broadcast and the /31 exception instead
  of falling through to a definition.

### Fixed

- The chat's own answers now cover the questions people ask before anything
  else: what a MAC address is, what an IP address is, whether an API key is
  needed (it is not), what this app can do, and which features are not
  implemented. Each has an Arabic twin where the rest of the answer does.
- A bare "build it" that ends without a file now says why instead of "not
  completed; see the build status above" - the engine's own error is quoted,
  and a cancelled build is named as cancelled.
- Rebuilding an imported lab is honest about the hardware it cannot reproduce.
  A saved port the offline library has no template for no longer fails the
  whole build: an imported plan falls back to the base chassis and a free port
  of the same medium, changes a fiber record to copper when the rebuilt socket
  is copper, and writes each substitution into the build warnings. A plan the
  user typed keeps the strict behaviour, so a port that does not exist is
  still refused rather than moved.
- A judgement question is answered by an engineer, not deflected as a
  purchase. "Should I run OSPF over the WAN", "would you run OSPF over a
  wan", "what should I monitor on a switch" and "is a flat network ever ok"
  now reach the technical answer, while buying, device selection and sizing
  ("is a PoE switch worth it", "which router should I get", "how many access
  points do I need") still go to the advisor with the standing plan.
- Spelled numbers no longer half-convert: "twenty nine hosts" was becoming
  "twenty 9 hosts", and a repeated symptom no longer doubles its canonical
  phrase ("are not forming" produced "not forming not forming").
- Fault phrasing survives canonicalisation. Phrases such as "broadcast
  storm", "link down" and "peer link down" are rewritten for the concept
  layer, so the diagnosis layer now matches the user's words as well as the
  canonical form and no longer misses the very symptom it was given.
- Plural nouns match: "how many VLANs" reaches the VLAN answer, while "IP"
  still never matches "IPS".
- A definition is no longer mistaken for a fault ("what is a supplicant",
  "what is DHCP snooping"), and a port question is no longer answered with
  a TCP port list ("which ports need portfast with BPDUguard").

## 1.1.0 - 2026-11-25

### Fixed

- The parser now requires standalone numbers for device counts. Digits
  within passwords, addresses and names no longer change the inventory.
- A correction that rejects a count is read as a correction. The negation
  window reached across the rejected quantity, so "not 99 servers 3 servers
  AAA, dhcp, and http" negated the replacement too and the lab kept one
  server; the "not" now binds only to the number beside it. The same
  sentence on an existing lab is also treated as a count correction now,
  so it moves the server count and leaves the PCs, switches and routers
  standing instead of re-planning the turn down to five devices.
- An open question can no longer swallow an unrelated message. While a
  question asked about an older plan revision was open, any message was
  refused with "I did not apply that answer", including a correction that
  answered nothing, so the user's fix was lost. Only a message that actually
  resolves the question can be refused now; everything else is planned.
- A plan whose routers chain deeper than one hop builds again. The
  static-route walk asked the directly-connected table for a router two
  hops out, hit a null-check exception and produced no configuration at
  all: "4 routers 4 switches 8 pcs" could neither be built live nor
  exported offline, while the same intent planned cleanly. The hop now
  comes from the hop that reaches the current router.
- A generated `.pkt` no longer drops a cableable device out of the Physical
  Workspace. The builder now refuses a save whose model can carry a physical
  leaf but has none (the 48-device GUI-Services save Packet Tracer 9.0.0
  rejected as "corrupted Physical Workspace data"), borrows the placement
  schema from another saved variant of the same model or kind, and
  `tool/repair_physical_workspace.py` repairs a file built before the graft.
  The refused file is kept as a regression fixture.
- Explicit server bindings stay on the server the brief names. Reading only
  names BEFORE the service word made every clause after the first belong to
  the previous server, so "DHCP on SRV1, DNS on SRV2 ... TFTP on SRV9" arrived
  rotated by one. "role on NAME" and "NAME: role" now bind forwards.
- A requested lab name reaches the plan and the file: "lab named
  release-validation" is `release-validation.pkt`, not `chat.pkt`. The name
  extractor now requires an explicit cue ("named", "called", "network for
  company"), so ordinary prose is never mistaken for a name.
- "Active Directory domain controller" is a software role, not a generic
  controller device: the brief no longer gains an invented CTRL1, and the
  keyless answer says the capability is unsupported instead of planning it
  silently. DHCP failover, clustering, DNSSEC and advanced server
  configuration share that one list.
- The workspace follows the chat on every destination. Chat updates were
  ignored while another screen was showing, which left the header and the
  "No open plan" card describing an older lab than the chat, preview and
  export were acting on.
- A brief over the target's device limit no longer says "Enough to build"
  beside the build refusal. The brief card states the 50-device live limit
  and the 120-device offline limit with the actual count.
- The request ledger says "extracted requirements", not "requirements": green
  coverage of every captured clause is not a claim that nothing was missed,
  and open clauses are counted beside it.
- A legacy memory store whose `builds` table predates `projectName` no longer
  fails to open: the hot index is created only when its columns exist (the
  schema-10 upgrade test hit "no such column").
- Widget tests could not pass reliably: the chat's engine probe left a real
  request and its timeout timer open in the fake-async clock. The default
  probe answers "not there" under `flutter test`, and the chat only asks an
  engine for findings when one is actually up - a down engine no longer adds
  two ten-second timeouts to every turn.
- The build notice no longer pushes the conversation to a sliver. Its four
  evidence stages are one tap away, and the engine banner steps aside while a
  build notice is on screen.
- Concept retrieval re-read the whole library per ask. The store now caches
  the rows behind a count/newest-updated stamp and the overlap sweep reuses
  each row's token set: 10k-entry retrieval fell from ~110 ms to ~42 ms, the
  store-backed path from ~313 ms to ~139 ms (desktop, measured).

### Changed

- The phone layout works like a phone. Android back returns to the
  conversation instead of closing the app; the shell switches to its rail at
  700 px instead of 1000, so a tablet or narrow window keeps its content; the
  composer hides its suggestion chips while the keyboard is open, uses fewer
  visible lines on a phone, and its Return key inserts a newline so a
  multi-line brief can be written (a hardware Enter still sends).
- The build notice's evidence stages and the engine banner used to take
  almost the whole column at a laptop window; the stages are now a "Build
  details" toggle and the banner steps aside for a build notice.
- `flutter analyze` ignores `build/` and `dist/`: one-off diagnostic scripts
  written into `build/` were being linted as if they were product source.
- Version 1.1.0. The engine label advances to
  `2026-11-23-physical-workspace-gate-v1`, so a stale engine is visible in
  the header handshake.
- The offline assistant now speaks in the personality the user stored. The
  "Shorter answers" / "Less formal" choices written by the chat's feedback
  menu and the Settings panel used to reach only the model prompt; the
  keyless answers ignored them entirely. They now arrive at the offline
  path too: a casual tone picks warmer phrasings for greetings, thanks,
  yes, no and the advice closer, a formal one picks more precise wording,
  and a "shorter answers" preference drops the unsolicited extras (the
  build advice block, the advice notes and closer, the three-example form
  in the vague reply) while the lab description, the commands and every
  warning stay whole. A phrase in the message itself ("less formal",
  "briefly") still wins for the turn, matching the model path.
- The vague reply stopped repeating its own chips as a numbered list. The
  three example briefs and the three completing questions were already on
  the reply as tappable chips; the prose now names one example and the
  shape of a complete plan instead of a wall of text.
- Concept answers gained tappable follow-ups: related questions drawn from
  the same verified set as the near-miss topics ("how does spanning tree
  work" after the EtherChannel explainer), enforced by a test that walks
  every chip and asserts it routes to a real answer, so a tap never
  dead-ends.
- The welcome screen rotates two of four extra openers by the day of the
  year, so a returning user finds something new to tap while the fixed
  five front-door chips stay put; the same day is the same welcome
  everywhere, tests included.
- Confirm, deny and recall answers gained Arabic companions (with Arabic
  plural wording done by hand, not the English pluralizer), completing the
  parity for the conversational moves a mixed-language conversation hits
  first.
- The offline assistant's replies vary their wording the way its greetings
  and acknowledgements already did: advice answers pick among equivalent
  openers and carry a single-seed closing line instead of the identical
  "advice never edits the lab" paragraph under every reply (the advice
  card's "Plan this" button already carries that action); build answers
  vary the delta opener, the suggestions header and the build-button
  closer; confirm, deny, recall and missing-coverage answers gained a
  second or third phrasing; and unpinned offline prose now uses the
  contractions the app's own voice spec asks for ("I'll", "it's"). Test
  pins that named one wording now accept any of the equivalents or assert
  the stable content instead.
- Answer length and tone are settable in Settings ("Assistant style"
  section), reading and writing the same stored preferences the chat's
  per-message feedback menu writes, so both surfaces agree on one value.
- The pre-answer status line says what actually runs: a turn with no model
  key configured reads "Answering from the rules on this device..." instead
  of claiming a model is thinking; "Thinking..." stays for model turns.

### Fixed

- Generated `.pkt` files open in Packet Tracer again. Three separate defects
  made PT refuse a file that had cabled the devices in question, each checked
  by opening the built lab in Packet Tracer 9.0.0 itself: an access point, IP
  phone, hub, WLC or cloud was cabled by an invented interface name
  (`FastEthernet0`) where PT's own label is `Port 0` - now every kind except
  IOS gear and end hosts is cabled by its module pin, and coax/serial pins
  keep the names PT writes; a template saved without physical-workspace data
  (the module-bearing Cloud-PT) produced "Invalid File" - the builder now
  borrows the placement record from the same model, or from a sibling of the
  same kind, and names the donor in a warning; and a plan that still spells
  the old interface name for those kinds now resolves it to the same pin
  instead of failing the build. The 112-device heterogeneous stress lab opens
  in PT; an Analog-Phone-PT cabled to a VoIP adapter's Phone pin is still
  refused by PT itself, so that pair is left as unconnected inventory rather
  than claimed.
- A per-site quantity is read whichever way round the brief puts it. The
  reader only looked at the clause AFTER "each" or "per site", so "a server
  in each site" and "3 pcs per site" stated the count before the cue and
  were missed - a three-site brief asking for a server in every site produced
  one. The run-up to the cue is now read too, but only when the cue actually
  governs it: in "two sites with 4 switches, each site has 2 pcs" the four
  switches stay a total, not four per site.

### Added

- Four universal network designs in the layout gallery (18 drawings now):
  spine-leaf (the data-center fabric - spines across the top, leaves below,
  endpoints under their leaf), hub-spoke (the WAN map - hub top-centre, the
  aggregator stacked beneath it, each branch one column), security zones
  (outside, firewalls, DMZ and inside, each zone its own block), and a
  meshed core (the fabric cluster at the centre, switches on one ring,
  endpoints outside). Each appears in the preview gallery like the existing
  designs, is named by its own wording ("spine-leaf fabric", "WAN map",
  "security zones", "full mesh core"), stamps into the plan note
  (hyphenated names now read back whole), and builds with the exact
  positions the preview showed.
- The default site-tree drawing balances itself: a device cabled to several
  anchors of the same tier (a switch dual-homed to two routers, the
  redundant-core design's whole point) hangs under the anchor carrying the
  fewest children so far, in both the Dart engine and the sidecar mirror,
  so dual-homed subtrees spread across the core instead of piling onto the
  first router plan order names. Ties fall to plan order; the comparator is
  a total order, so the drawing stays deterministic and the sidecar and the
  preview still agree byte for byte.

- Concept knowledge travels with backups: Memory export/restore/merge now
  carry the concept library (export schema v6). Merge dedupes identical
  entries by concept + answer and reinforces the seen count; the same
  concept learned with a DIFFERENT answer on another device arrives as a
  conflict row for review instead of silently joining the library. v5
  backups without concepts still restore unchanged.
- Named-inventory briefs parse completely: a structured brief that cables
  its whole topology ("3 Cisco 2911 routers... 24 PCs... Connect R-HQ G0/0
  to SW-HQ-DIST Gi0/1...") no longer leaks the generic layout's guessed
  cables into the plan (48 links where the brief asked for 46), the
  router-on-a-stick sub-interfaces now ride the cabled uplink port
  (g0/0.10) instead of a filler link's port (f0.10), and a brief that
  excuses a kind from cabling ("do not cable the laptops" - wireless
  clients) no longer keeps the auto-attached Ethernet cable.

- Concept knowledge, the tier under the exact-question replay: answers a
  keyed model gave are now also filed under the THING the question is about
  (curated alias dictionary, ~65 networking concepts), so "Explain an IP
  address" reaches what "What is an IP?" learned, offline. Retrieval is
  confidence-aware - alias-anchored hits answer directly, overlap-only hits
  are phrased as qualified, and a question naming two concepts of which only
  one is known ("IP vs MAC addresses") is answered partially: the known part
  explained, the missing part named as missing, never invented. Explanation
  styles are served from what was learned (brief summary, beginner version,
  example) with honest fallbacks when a variant was never saved.
- Knowledge management in Memory > Q&A: a Concepts panel with search, source
  and verification status on every row, per-entry correction (the edit marks
  it verified), user-taught entries ("Add your own" - starts verified, says
  "you taught me"), delete, and clear-all with confirmation. Provenance lines
  on chat answers state where knowledge came from and whether it is
  verified; relevance is never presented as correctness.
- Contradictions are surfaced, not applied: an incoming provider answer that
  disagrees with stored knowledge (token containment + negation contrast +
  opening-overlap checks) becomes a status 'conflict' row for review - the
  validated entry is never silently overwritten.
- Schema v13: the `knowledge_concept` table, re-runnable migration like the
  rest of the store. `Clear all memory` now also clears learned answers and
  concepts. Measured performance, desktop FFI: retrieval ~2 ms/query at 100
  entries, ~6 ms at 1k, ~48 ms at 10k; store-backed ask (load + sweep)
  ~131 ms at 10k. Measured on an Android 15 (API 35, x86_64) emulator
  through the real sqflite plugin (integration_test/concept_perf_test.dart):
  retrieval ~5.4 ms/query at 100, ~7.7 ms at 1k, ~36 ms at 10k; store-backed
  ask ~22 ms at 100, ~46 ms at 1k, ~494 ms at 10k.
- IPv6 inspector in the Network toolkit: RFC 5952 canonical form, address
  classification (link-local, unique-local, multicast, IPv4-mapped,
  documentation, global), solicited-node multicast, EUI-64 and link-local
  derivation from a MAC, prefix sizes (BigInt-exact) and sequential /64
  children. Also an Action Hub feature ("IPv6 inspector").
- Port budget in Address plan checks: per-switch cables against the ports
  the switch's Packet Tracer model actually has (FastEthernet family, the
  ports the planner cables), with overfilled switches called out.

### Added

- Server roles spread across the server farm: "8 servers: DHCP, DNS, web,
  mail, FTP, AAA, syslog and NTP, CME" now gives every server its own role
  (the old reading piled all nine onto the first box), "mail" maps to the
  email role everywhere, and a colon-list after a server count
  ("8 servers: ...") is read as a role spread. Combined with the existing
  service-panel writer, the built .pkt carries a working server farm: DHCP
  pools per VLAN, 61 DNS records, HTTP/HTTPS, mail, FTP, AAA users and
  clients, syslog and NTP - verified in the decoded file, zero audit
  findings.
- Conversations are titled from the network named in the brief ("Build the
  enterprise network for company Contoso" -> "Contoso"), so ten enterprise
  labs no longer all read as their first troubleshooting topic.

### Fixed

- A follow-up design change could wreck the standing lab. "make it 60 PCs"
  was read as a file-edit ("it" looked like the .pkt artifact) and the
  correction's fragment replaced an entire enterprise lab with sixty orphan
  PCs; the make-it imperative is now a count correction of the standing
  plan, multi-kind readings ("make it 2 routers and 4 pcs") still re-plan,
  and the correction merge validates every kind before it is trusted.
- The words the standing plan was parsed from now travel in the session
  state, so a count correction or addition on a REOPENED conversation merges
  against the standing brief instead of declining and replacing the lab.
- Follow-up merges could duplicate transit links (the same serial WAN twice)
  and an interface then answered "used by 2 links"; merged plans dedupe by
  endpoint pair and interfaces.
- Router uplinks are spread by free copper ports per model (an ISR 4331 has
  three; the old round-robin asked one router for a fourth interface), a
  switch that fits nowhere trunks to a cabled sibling and shares its LAN,
  and the firewall chain starts at a router with a free port - the
  enterprise "2 firewalls, 3 routers, 6 switches" brief now lays out
  within every device's real port count.
- A count that sits inside a VLAN reference ("VLAN 20 servers") no longer
  reads as twenty servers; role adjectives between count and noun ("2 core
  routers") count again; and the CME telephony block appends to the voice
  gateway's config instead of replacing it - a plan with phones + a CME
  server built a router whose saved config had no addresses at all.
- The engine substitutes a cable the resolved ports can actually take
  before refusing a link (a fiber module port had absorbed a copper
  cable), and the audit recognizes dot1Q gateways stored in the running
  config, so router-on-a-stick plans stop reporting every host gateway as
  missing.
- A build whose target file already exists (another conversation, before a
  restart) now retries with the next free -N suffix instead of dead-ending,
  and a failed build suggests fixes the user can apply - each one waiting
  for approval before anything changes.

### Fixed

- The secret-vault snapshot no longer defeats its own write verification:
  reads used by the "did it persist" check went through the snapshot, so a
  failed secure write looked stored and a plaintext transcript could be
  saved. Verification reads the backend again, and swapping the storage
  backend invalidates the snapshot even when the instance is const.
- A GNS3 push answered 404 "Compute ID None doesn't exist" for every node:
  the template-instantiation body carried no compute id, and GNS3 2.2
  resolves the omission to null. The template's own compute id (local when
  unset) is sent now.
- GNS3 credentials had no save/test of their own - they only persisted as a
  side effect of saving the model provider. The GNS3 panel has a
  "Save and test GNS3" button that stores the fields and answers with the
  server version.
- Pasted diagnostics saved as rules steered every later plan: one failure
  report ("...base 2-device topology...") set every new brief's scale to 2.
  Rules that steer plans must be instruction-shaped; reports stay listed in
  Memory for review.
- "4 switches with VLAN 20 servers" built twenty servers: a VLAN ID in
  front of a device noun was read as a count. Count readers skip VLAN
  references.
- Duplicate addresses in multi-switch plans: end hosts restarted at .10 per
  switch sharing a subnet, and every switch uplink carrying the same VLAN
  repeated 192.168.<v>.0/24 with the same .1 gateway. Hosts continue per
  subnet and a second link claiming a VLAN takes the next free /24.
- A firewall at the internet edge hardcoded the router's g0/2 - the same
  interface a fourth switch had been given - and only the first firewall
  was ever cabled. Firewalls chain between the router (or the first switch,
  when no router exists) and the edge device on genuinely free interfaces.
- Servers all landed on the first switch: "8 servers, 30 PCs, 4 switches"
  ran SW1 past its 24 ports. Servers fill the first switch and overflow to
  the next with room.
- The suggested remedy "AAA client name admin password 123" did nothing
  when typed: the follow-up filed it under "no device named" and dropped
  the credentials. A credential the standing lab lacks now lands on its AAA
  server (or VPN tunnel); one already present is never overwritten.
- The window title and executable metadata say "NetBuilder AI".

### Added

- A generated application icon (rounded navy tile with a network-topology
  motif) wired into the Windows executable, the installer surface and the
  About panel, with the generator checked in at `tool/make_app_icon.py`.
- The About panel shows the app icon, name and version.


### Added

- Startup coordinator that paints the shell before settings, memory, build
  history and app version finish loading, with per-subsystem deadlines and a
  visible readiness/degraded banner.
- Screens reload once the local memory store becomes ready, instead of
  staying empty when they mounted first.
- Rotating, redacted local app log with `FlutterError.onError` and
  `PlatformDispatcher.onError` capture. The existing diagnostics archive now
  includes the app log alongside the sidecar journal.
- Windows stale-process cleanup helper
  (`tool/clean_windows_build.ps1`) for locked `sqlite3.dll` builds.
- Transient database-lock retry with a clear "close other NetBuilder windows"
  message; a live store is not moved aside as if it were corrupt.
- Windows Flutter tests, Windows sidecar pytest, a PR debug APK build, pinned
  Flutter/tool version logging, explicit formatting/analyzer gates, and a
  tagged signed-release APK workflow.
- A packaged Windows release smoke test and a named Linux golden-corpus gate
  in CI.
- Architecture, troubleshooting, supported-configuration, contributing,
  dependency and security documentation.
- Signed Windows packaging with a per-user installer, portable ZIP,
  bundle/release manifests and `SHA256SUMS.txt`.
- Per-user uninstall entry and Start Menu shortcut, with data-preserving
  uninstall by default and a `-Purge` mode.
- Clean-install and upgrade-preserves-data tests, plus a clean-VM checklist.
- First-run readiness panel covering the local engine, optional model key,
  Packet Tracer, OCR and the no-admin/local-diagnostics permission story.
- Local-only navigation instrumentation in the redacted app log.
- A pilot kit with scripted tasks, metrics definitions and a scorecard
  summarizer.

### Changed

- Extracted the chat composer, typing bubble, jump-to-latest pill, rule,
  slot-fix and in-conversation search widgets. Behavior and widget keys are
  unchanged.
- Context budgeting runs on a background isolate for real launches, keeping
  the 400-turn planning walk off the frame that sends a model request.
- Extracted sidecar credential redaction and the Packet Tracer device catalog
  into leaf modules; all existing names and call sites are preserved.
- Upgraded `cupertino_icons` to 2.x and staged `flutter_secure_storage` 10.3.1
  so its first run migrates keys before the v11 move.
- The engine handshake now distinguishes a different major version from a
  stale same-major build and tells the user to restart the engine.
- Applied `dart format` across the Dart tree and fixed the analyzer infos it
  exposed.

## 1.0.0 - 2026-10-20

- Initial release: local-first planning, offline assistant, on-device `.pkt`
  compilation, GNS3/Cisco/Packet Tracer targets, local memory, and the
  optional Packet Tracer autopilot.
