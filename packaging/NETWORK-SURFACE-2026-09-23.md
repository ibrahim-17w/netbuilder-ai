# Network surface, capability registry and chat upgrade — 2026-09-23

## AAA, firewalls and full server services (second pass, same day)

### The reported bug: "both servers has the AAA service tab empty"

Root cause chain, all fixed:

1. **Server side** (the screenshots): the PT ACS panel is only *On* when it
   has at least one user AND one client entry. The builder writes
   `ACS_SERVER` with users (admin/operator by default), the client router
   (IP + shared key + RADIUS/TACACS), and the Radius port (1645). Verified
   in a generated `.pkt`: `ENABLED=1`, 2 users, 1 client, port 1645.
2. **Planner side**: a brief that *asked* for AAA ("2 routers ... with an
   AAA server") never filled `SecurityIntent`, so the router side was
   never configured and the server had no client to answer. The generic
   parser now detects `aaa`/`tacacs+`/`radius` (also when no server count
   was named — it provisions the server), picks the AAA server and router,
   reads the protocol (`radius` vs `tacacs+`), and extracts a shared key
   ("using key S3cret").
3. **Both ends agree on the key**: the router writes
   `tacacs|radius-server key` from the same field the server's client
   entry uses; default `cisco` on both ends when the user supplied none.

### Firewalls are now configured, not just placed

`CiscoAdapter.firewallConfigs` generates a real ASA config per firewall
node: inside (security-level 100, addressed from the router transit),
outside (level 0, 172.16.2.0/30 edge), stateful inspection (dns+icmp), and
routes. The router gets `ip route 0.0.0.0 0.0.0.0 <firewall>` so the ASA
carries traffic. The parser addresses router–firewall links from the
transit pool. Live typing still skips firewalls (ASA is not IOS); the
generated config lands in the saved device inside the `.pkt`.

### Service coverage per server

Every PT 9 Services panel is written from the plan: dhcp, dhcpv6 (stateful
pools), dns, http/https, aaa, email, ftp, ntp, tftp, syslog, snmp
(communities/agent), iot (registration server + accounts), vm (IOx VM
list). Roles `snmp`/`vm` added to the parser and validator.

### RADIUS protocol

`security.aaaProtocol: 'radius'` drives the router (`radius-server host
... group radius`), the server client entry (`SERVER_TYPE=RADIUS`), and
the verification markers.

Tests: `test/aaa_firewall_services_test.dart` (8 cases) plus the sidecar
AAA semantics tests; full suites at the time of writing: 314 Dart, 92
pytest.

---

Three requests, one pass: make the chats better, make the app able to do
everything network-related, and make sure every feature in the code has a
button a user can press.

The third one was the real finding. The app had **implemented, tested and
then never shown** a whole layer of itself:

| Feature in the code | Was it reachable? |
|---|---|
| `HomeScreen` (saved networks) | No — `_tab` was only ever set to 3, 2 or 7 |
| `NewBuildScreen` (the wizard) | No |
| `MemoryScreen` (corrections, rules, journal) | No |
| `SettingsScreen` | No |
| `PktFilesScreen` (.pkt lifecycle) | No |
| `NetworkTools` (subnet, gateway, duplicates) | No — used by the validator only |
| `TerraformAdapter.renderAwsVpc` | No — tested in `app_test.dart`, no UI |
| `.pkt` engine: ledger, inventory, events, shots, template harvest, `pktAudit` | No |
| `MemoryService.exportJson` | No |
| `PrivacySearchService` preview | Partly (one path in the execution screen) |

A feature without a button is not a feature. This pass closes that.

## What changed

| Area | Change |
|---|---|
| **Capability registry** (`lib/services/capability_registry.dart`) | Every user-facing capability declared once: id, label, description, group, icon, keywords, `needsPlan`, `touchesDevices`, and the runner. 62 entries across 8 groups. `CapabilityRegistry.reaches(destination)` answers "does a button lead here?" for every screen. |
| **Action Hub** (`lib/widgets/action_hub.dart`) | A searchable palette of the registry: one dialog (wide) or sheet (phone), **Ctrl+K / Cmd+K from anywhere**, and an app-bar button on every screen. Plan-dependent capabilities stay *visible* but disabled with "Open a plan first"; device-touching ones are labelled; Enter runs the top match. |
| **Network toolkit** (`lib/screens/network_toolkit_screen.dart`) | Eight sections, each a tool: subnet calculator (mask, wildcard, broadcast, host range, scope, classful, reverse DNS, binary with a network/host split marker), VLSM + equal splitting, summarization + range→CIDR, address-plan checks (duplicates, overlaps, reserved addresses, validator), ACL/mask helper with an IOS ACL line generator, **live diagnostics**, **this machine** (interfaces, ARP, route table, connections), and the exporters (Cisco IOS, Packet Tracer CLI, GNS3 JSON, Terraform AWS VPC, plan JSON). |
| **Network math** (`lib/services/network_math.dart`) | New pure IPv4 arithmetic: prefix↔mask, ACL inverse masks, scope classification (RFC 1918 / loopback / link-local / CGNAT / documentation / benchmarking), prefix sizing, equal splitting, VLSM allocation (largest-first, smallest-fit, "does not fit" reporting), overlap detection, route summarization, range→CIDR, reverse DNS name and zone, neighbouring blocks, covering prefix. |
| **Live diagnostics** (`lib/services/diagnostics_service.dart`) | DNS lookup, reverse lookup, TCP port probe (single, list, or the well-known set with capped concurrency), HTTP probe, ICMP ping and traceroute through the OS (desktop), local interfaces, ARP table, route table, open connections. Timeouts everywhere; Windows/Linux/macOS ping and ARP formats parsed and unit-tested. Nothing leaves the machine except the probe the user starts. |
| **Design system** (`lib/theme/app_theme.dart`) | One place for the look: 4-point spacing scale, radii, reading measure, light + dark schemes, and themes for app bar, cards, inputs, buttons, chips, lists, dialogs, sheets, snackbars, segmented buttons, tooltips, scrollbars. Plus `AppSection`, `AppStatusPill`, `AppEmptyState`, `AppKeyValue`. |
| **Shell** (`lib/main.dart`) | Named destinations (`AppDestination`) instead of magic tab integers, a desktop rail listing every screen plus "All features" and "Run build", an app bar with toolkit + hub, Ctrl+K, the theme mode from settings, and a fix for a real bug: dialogs, sheets and pushes were created from a context *above* `MaterialApp`, so opening the hub threw `No MaterialLocalizations found`. Navigation now goes through a `navigatorKey`. |
| **Chat** | Conversation header (name, message count, target, New chat, Clear — icon-only under 420px); per-message avatar, name and time; under every message a row of **Copy / Answer again / Remember as a rule** (assistant) or **Copy / Edit and resend** (user); a typing bubble while the assistant owes an answer; a "new messages" pill that appears only when the reader has scrolled away, with a count; five opener chips in the empty state; code blocks with a language header and a copy button (and selectable text). |
| **Saved networks** | Redesigned with the design system: search, status pill, target tag, relative time, error line, and an empty state that leads to the wizard. |
| **Settings sidebar** | Gains "All features" and "Network toolkit" launchers (this is the phone's main way around), and an Appearance section with System / Light / Dark. |
| **Settings** | `theme_mode` preference (system/light/dark) persisted in prefs. |

## The rule this pass leaves behind

Adding a capability is now: write the code, then add one entry to the registry.
Two tests enforce the contract:

* every entry has a unique id, a label, a description and a group the hub renders;
* **every `AppDestination` is reachable from a button** — a screen that exists
  in the switch but nowhere in the registry fails the suite.

## Verification

* `flutter analyze` — clean.
* `flutter test` — **306 tests pass** (231 before this pass, 75 new):
  * `network_math_test.dart` (31) — masks, wildcards, scope, sizing, splitting,
    VLSM, overlaps, summarization, ranges, DNS names, facts map. Found and fixed
    two real bugs while being written: the wildcard was computed as
    `prefixToMask(32 - prefix)` (which gives `252.0.0.0` for `/26` instead of
    `0.0.0.63`), and the binary view read the wrong bits.
  * `diagnostics_service_test.dart` (13) — Windows and Linux ping summaries,
    packet loss, ARP rows on both platforms.
  * `capability_registry_test.dart` (8) — the contract above.
  * `action_hub_test.dart` (6) — groups, search, disabled-without-plan,
    navigation, chat openers.
  * `network_toolkit_test.dart` (8) — calculator, invalid input, VLSM, ACL
    helper, exporters, addressing checks, no probing until asked.
  * `app_shell_test.dart` (8) — the rail lists and *reaches* every screen, the
    hub from the app bar, Ctrl+K, the toolkit from the app bar, chat header,
    openers, message actions.

## Known limits (stated rather than implied)

* `ping` and `traceroute` need a desktop: a phone has no such binary. The
  probes say that instead of reporting the target as down.
* The diagnostics are IPv4-oriented, like the rest of the app. IPv6 math
  (`/64` thinking, `::` compression) is not in this pass.
* `AnalyzeScreen`, `MemoryScreen`, `PktFilesScreen`, `NewBuildScreen` and
  `SettingsScreen` inherit the new theme (cards, inputs, buttons, app bar,
  spacing) but their internal layouts were not rewritten. The shared widgets
  they need now exist.
* The toolkit is a pushed route, not a rail destination: it is a tool, not a
  place, and the hub opens it at the right section.
