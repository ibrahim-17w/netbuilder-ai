# Changelog

## Unreleased

### Added

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
