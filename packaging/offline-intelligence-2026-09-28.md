# Offline intelligence: no API key needed for the networking corpus (2026-09-28)

## Goal (the user's words)

"improve its intelligence, feed it more info until it reaches a point where
it doesn't need any api key and answer everything offline"

## What was built

1. **`lib/services/offline_knowledge.dart`** - the offline brain. A table of
   ~35 topics covering the networking corpus people actually ask about,
   each with a concrete, command-level answer:

   * **Computed for real** (via the same `NetworkTools`/`NetworkMath`
     services the rest of the app trusts - the keyless answer and the
     offline tools can never disagree):
     subnet facts (network / mask / broadcast / first / last / usable),
     host counts for a prefix, wildcard masks (from /nn or a dotted mask),
     route summarization, reverse DNS names.
   * **Corpus**: connectivity troubleshooting ladder, ping steps,
     traceroute reading, ARP, serial clocking (DCE/DTE), cabling, SSH
     setup, port security, DHCP snooping, HSRP/VRRP, static routes,
     default gateway, saving config, PT file saving, show-command cheat
     sheet, duplex mismatch, red links in Packet Tracer, switchport
     modes/DTP, MAC table, Wi-Fi security (WPA2), WLC, server service
     panels (HTTP/FTP/email/NTP/syslog/IoT), Packet Tracer basics,
     joining wireless, ipconfig + 169.254, loopback, VPN/IPsec, VLSM,
     subnetting method, router-on-a-stick, inter-VLAN routing, OSPF
     authentication, OSPF adjacency faults, device access passwords,
     hostname, STP root, DHCP relay.

   Guard rails: device counts and build/setup asks never reach the table -
   they belong to the planner.

2. **Wired into the keyless path** (`offline_assistant_service.dart`):
   concepts first (existing curated answers), then the knowledge table.
   Short questions ("ssh?") now reach the table too.

3. **Fixed the matcher bugs the new battery exposed** (each made a keyless
   answer wrong or blank before):

   | Bug | Effect | Fix |
   | - | - | - |
   | `t.contains('dr')` in the OSPF-DR matcher | matched "address", "hundred" | `\bdr\b` |
   | `t.contains('nd ')` in the IPv6 matcher | matched "and ", "find " | `\bnd\b` |
   | `t.contains('loop')` in the STP matcher | matched "loopback" | `\bloops?\b` |
   | `has('vlan')` without plural | "vlans" missed | accepts both, minus relay/snoop phrases |
   | dhcp/dns/subnet matchers too greedy | ate snooping / relay / reverse-dns / numeric questions | narrowed |
   | device-count guard ate model numbers | "a 2960 switch" in a how-to became a *build* | questions skip the count guard |
   | ipconfig matcher | missed "mac address of" / 169.254 | added |

4. **ScopeGate** accepts the services vocabulary now (ssh, telnet, ipsec,
   hsrp, vrrp, ftp, tftp, ntp, syslog, smtp).

5. **Planner**: "5 computers" / "3 workstations" now count as PCs, so more
   phrasings plan offline.

## How "answers everything offline" is measured

`test/offline_intelligence_test.dart` - the battery. No key is ever set
anywhere in the file, so a pass proves the answer came from the offline
table. Three groups:

* computed answers checked for exact values (broadcast 192.168.10.63 for
  .5/26, 14 hosts on a /28, wildcard 0.0.0.31 for /27, summary
  10.10.0.0/24, PTR 10.1.168.192.in-addr.arpa);
* 45 corpus questions, each asserting the answer contains the thing that
  makes it correct (a command, a value, a step);
* boundary checks: off-topic is still declined; build requests still plan;
  device-counted asks are not answered as lectures.

Run: `flutter test test/offline_intelligence_test.dart` -> **52 passed**

## Verification (this working tree)

| Check | Command | Result |
| - | - | - |
| Analyzer | `dart analyze` (touched files) | No issues |
| Offline battery | `flutter test test/offline_intelligence_test.dart` | 52 passed |
| Full suite | `flutter test` | **771 passed, 0 failed** (+52 vs the previous 719) |
| Release rebuild | `flutter build windows --release` | built; `data\app.so` 15:42, 9.85 MB |

## Adding more knowledge (the recipe)

One entry in `OfflineKnowledge._topics` (a matcher + an answer) and one
battery line in the test. Keep answers concrete (commands, values), and
keep the `_deviceCount` / `_buildAsk` guards so build requests keep
planning. Computed answers should go through NetworkTools/NetworkMath
rather than hand-rolled math.

## Limitations (honest)

* This covers the networking corpus and every planning flow keylessly.
  Open-ended, novel reasoning is still where a model adds value; the model
  stays optional and its absence no longer blocks any battery question.
* The battery measures the *covered* corpus; it is not proof about
  arbitrary questions. Extend the table + battery together.
* Answers are deterministic and conservative (Packet Tracer-flavoured);
  they do not do live discovery.

## Rollback

All uncommitted. Delete `lib/services/offline_knowledge.dart` and
`test/offline_intelligence_test.dart`; revert the matcher/guard edits in
`lib/services/offline_assistant_service.dart`, `lib/services/scope_gate.dart`
and the PC-phrasing widenings in `lib/services/nlu/slots.dart`. Re-run
`flutter test` to confirm the previous behaviour (771 -> 719 tests).
