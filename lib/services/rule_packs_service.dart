import 'package:flutter/services.dart';

/// Bundled rule packs (assets/rule_packs/*.yaml) + learned rules.
/// v1: packs are embedded as Dart maps (no yaml dep) and mirrored as
/// asset files for user editing. Learned rules come from SQLite.
///
/// The packs are the AI planner's hard-won networking knowledge: every rule
/// here is injected into the Gemini context block and mirrored into
/// assets/rule_packs/*.yaml. `test/parser_render_test.dart` asserts the two
/// stay in sync and that every severity/target value is one the validator
/// understands - add the rule in BOTH places, or the sync gate fails.
class RulePack {
  final String id;
  final List<String> targets;
  final String rule;
  final String severity;
  const RulePack({
    required this.id,
    required this.targets,
    required this.rule,
    this.severity = 'info',
  });
}

class RulePacksService {
  static const packs = <RulePack>[
    // ---- Core addressing / design (every target) -------------------------
    RulePack(
      id: 'core-01',
      targets: ['all'],
      rule: 'Management gateway must be inside its subnet.',
    ),
    RulePack(
      id: 'core-02',
      targets: ['all'],
      rule: 'No overlapping subnets across interfaces unless VRF.',
    ),
    RulePack(
      id: 'core-03',
      targets: ['all'],
      rule: 'Every L3 interface needs description + no shutdown.',
    ),
    RulePack(
      id: 'core-04',
      targets: ['all'],
      rule:
          'One server role per device unless the brief says otherwise: '
          'DHCP, DHCPv6, DNS, HTTP(S), FTP, EMAIL, AAA, NTP, TFTP, SYSLOG, IoT.',
    ),
    RulePack(
      id: 'core-05',
      targets: ['all'],
      rule:
          'A WAN/transit subnet is /30 or smaller on a private range and is '
          'never reused for a LAN.',
    ),
    RulePack(
      id: 'core-06',
      targets: ['all'],
      rule:
          'User LANs get addressing from one block (e.g. 192.168.x.0/24 per '
          'VLAN/site); infrastructure (/30 transit) and user ranges never mix.',
    ),
    RulePack(
      id: 'core-07',
      targets: ['all'],
      rule:
          'The router LAN interface is the first usable host (.1) and the DHCP '
          'pool never contains it, the server .10x range or the broadcast '
          'address - exclude them explicitly.',
    ),
    RulePack(
      id: 'core-08',
      targets: ['all'],
      rule:
          'Every end device needs a working default gateway: PCs/servers point '
          'at the router LAN interface, routers at the next-hop transit IP.',
    ),
    RulePack(
      id: 'core-09',
      targets: ['all'],
      rule:
          'A subnet must be sized for its stated hosts: 50 users never fits a '
          '/29; size the pool and state the assumption when the brief is '
          'silent.',
    ),
    RulePack(
      id: 'core-10',
      targets: ['all'],
      rule:
          'Loopback0 is the router ID source: give every router a unique '
          'loopback (10.255.0.x/32) and use it for router-id, iBGP peering and '
          'management.',
    ),
    RulePack(
      id: 'core-11',
      targets: ['all'],
      rule:
          'VLAN numbering follows purpose, not randomness: 1 is never used, '
          '10/20/30... for users, 99 for native, 100+ for management/voice; '
          'each VLAN gets a name.',
    ),
    RulePack(
      id: 'core-12',
      targets: ['all'],
      rule:
          'Every subnet and VLAN the plan creates must be used by at least one '
          'interface or explained in the notes; nothing is configured that the '
          'brief did not ask for.',
    ),

    // ---- Cisco IOS (GNS3, SSH, Packet Tracer) ----------------------------
    RulePack(
      id: 'cisco-01',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule: 'Set hostname, no ip domain-lookup, service password-encryption.',
    ),
    RulePack(
      id: 'cisco-02',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule: 'OSPF: consistent wildcard masks, same area, auth together.',
    ),
    RulePack(
      id: 'cisco-03',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule: 'Avoid VLAN 1 for users; create dedicated VLANs + trunk prune.',
    ),
    RulePack(
      id: 'cisco-04',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'Passwords are never plain: enable secret (not enable password), '
          'service password-encryption, and line console/vty get login local.',
    ),
    RulePack(
      id: 'cisco-05',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'VTY access is locked to the manager subnet with an ACL, uses SSH '
          'version 2 (transport input ssh), and a banner warns against '
          'unauthorized use.',
    ),
    RulePack(
      id: 'cisco-06',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'Access ports get switchport mode access, their VLAN, and '
          'spanning-tree portfast; trunks get mode trunk plus an allowed-VLAN '
          'list, never DTP auto.',
    ),
    RulePack(
      id: 'cisco-07',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'OSPF networks use precise wildcard masks (area borders on the '
          'router, not the interface), and passive-interface on every user '
          'facing port.',
    ),
    RulePack(
      id: 'cisco-08',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'A static default route (or default-information originate) points '
          'at the ISP/cloud edge; internal routers never point defaults at '
          'each other in a loop.',
    ),
    RulePack(
      id: 'cisco-09',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'ACLs are written top-down most-specific-first, applied close to the '
          'destination for extended, close to the source for standard, with an '
          'explicit deny any only where the brief says to block.',
    ),
    RulePack(
      id: 'cisco-10',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'NAT: inside/outside roles on the right interfaces, an ACL matching '
          'only private ranges, and overload for many-to-one. NAT is never '
          'applied to both sides of one link.',
    ),
    RulePack(
      id: 'cisco-11',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'DHCP: one pool per subnet with default-router = that subnet gateway '
          'and dns-server pointing at the DNS server; ip helper-address on the '
          'router interface when the server is remote.',
    ),
    RulePack(
      id: 'cisco-12',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'Inter-VLAN routing uses router-on-a-stick subinterfaces (g0/0.10, '
          'encapsulation dot1Q 10) or an L3 switch SVI per VLAN - never both '
          'for the same VLAN.',
    ),
    RulePack(
      id: 'cisco-13',
      targets: ['gns3', 'cisco-ssh', 'packet-tracer'],
      rule:
          'Every router and switch gets a unique hostname matching the plan '
          'name (R1, SW1...); interface descriptions name the far end.',
    ),

    // ---- GNS3 ------------------------------------------------------------
    RulePack(
      id: 'gns3-01',
      targets: ['gns3'],
      rule: 'Use c3725/c7200 templates; start with 2GB RAM per router max.',
    ),
    RulePack(
      id: 'gns3-02',
      targets: ['gns3'],
      rule:
          'Idle PC values are set after boot so the host CPU stays sane; a '
          'router at 100% host CPU for no reason is misconfigured, not busy.',
    ),

    // ---- Packet Tracer executor reality ---------------------------------
    RulePack(
      id: 'pt-01',
      targets: ['packet-tracer'],
      rule:
          'Packet Tracer supports a subset of IOS; prefer static/OSPF/VLAN basics for autopilot.',
    ),
    RulePack(
      id: 'pt-02',
      targets: ['packet-tracer'],
      rule:
          'A router-to-router WAN is Serial0/0/0 with exactly one DCE end '
          '(clock rate 64000); the executor fits the HWIC-2T serial module '
          'and reports the port it actually gets.',
    ),
    RulePack(
      id: 'pt-03',
      targets: ['packet-tracer'],
      rule:
          'PC/server/laptop/printer are configured through Desktop > IP '
          'Configuration; phones, access points, cloud/modem and IoT '
          'devices have only their own GUI - never type IOS at them.',
    ),
    RulePack(
      id: 'pt-04',
      targets: ['packet-tracer'],
      rule:
          'Firewall-PT (ASA) syntax is not IOS: place and cable the '
          'firewall, and report its configuration as manual.',
    ),
    RulePack(
      id: 'pt-05',
      targets: ['packet-tracer'],
      rule:
          'Wireless clients (tablet, smartphone, smart TV) associate with '
          'the access point; they are never cabled.',
    ),
    RulePack(
      id: 'pt-06',
      targets: ['packet-tracer'],
      rule:
          'PT cabling is physical: router-switch and switch-PC take copper '
          'straight-through, like-device links (router-router, PC-PC) take '
          'copper cross-over, serial ports take serial DCE/DTE, and fiber '
          'ports take fiber - the wrong cable kind shows link lights down.',
    ),
    RulePack(
      id: 'pt-07',
      targets: ['packet-tracer'],
      rule:
          'Switch ports used by routers/APs/servers are access ports in their '
          'VLAN; only switch-to-switch links are trunks. A port is never both.',
    ),
    RulePack(
      id: 'pt-08',
      targets: ['packet-tracer'],
      rule:
          'Port security is set on user access ports only (sticky or static '
          'MAC, violation restrict), never on uplinks, trunk or router-facing '
          'ports.',
    ),
    RulePack(
      id: 'pt-09',
      targets: ['packet-tracer'],
      rule:
          'DHCP snooping trusts only the port toward the DHCP server/router '
          'and is enabled per-VLAN; every other port stays untrusted.',
    ),
    RulePack(
      id: 'pt-10',
      targets: ['packet-tracer'],
      rule:
          'An ASA needs its interfaces named and security-levels set '
          '(inside 100, outside 0) before any ACL or NAT on it applies; '
          'same-security traffic is explicitly permitted when used.',
    ),
    RulePack(
      id: 'pt-11',
      targets: ['packet-tracer'],
      rule:
          'IPSec site-to-site on PT routers: matching ISAKMP policies (aes, '
          'sha, pre-share) and transform sets on both peers, crypto maps with '
          'each other peer address, and ACLs defining exactly the interesting '
          'traffic both ways.',
    ),
    RulePack(
      id: 'pt-12',
      targets: ['packet-tracer'],
      rule:
          'A wireless AP bridges its clients onto the VLAN of the SSID; the '
          'AP port toward the switch is a trunk (or access in that VLAN) and '
          'the router/WLC serves DHCP to that VLAN or the clients get none.',
    ),
    RulePack(
      id: 'pt-13',
      targets: ['packet-tracer'],
      rule:
          'The executor believes only the live device: an interface is used '
          'when `show ip interface brief` lists it up, a service is set only '
          'when its panel read-back shows the value, and every fallback is '
          'journaled - the plan is corrected, never silently guessed.',
    ),

    // ---- Security controls ----------------------------------------------
    RulePack(
      id: 'sec-01',
      targets: ['all'],
      rule:
          'Security controls are verified, not assumed: each requested control '
          'maps to a test (ACL blocks the branch, AAA rejects bad credentials, '
          'snooping drops rogue offers) and the plan lists those tests.',
    ),
    RulePack(
      id: 'sec-02',
      targets: ['all'],
      rule:
          'Credentials are never invented: missing usernames, passwords or '
          'pre-shared keys become questions in the plan, and redacted values '
          'are never echoed into notes or exports.',
    ),
    RulePack(
      id: 'sec-03',
      targets: ['all'],
      rule:
          'AAA is configured with the server address, shared key and method '
          'lists together - a router pointing at a nonexistent AAA server '
          'locks every VTY session out.',
    ),
    RulePack(
      id: 'sec-04',
      targets: ['all'],
      rule:
          'An ACL that mentions a manager subnet or office hours is a '
          'time-range ACL: the time-range is created, referenced, and its '
          'period matches the brief (weekdays 08:00-17:00 by default).',
    ),

    // ---- AWS VPC ---------------------------------------------------------
    RulePack(
      id: 'aws-01',
      targets: ['aws-vpc'],
      rule: 'VPC CIDR /16, public /24 per AZ + IGW, private + NAT.',
    ),
    RulePack(
      id: 'aws-02',
      targets: ['aws-vpc'],
      rule:
          'Route tables are split: private subnets point at the NAT gateway, '
          'public at the IGW; 0.0.0.0/0 routes never cross between the two '
          'tables.',
    ),

    // ---- Validation gates ------------------------------------------------
    RulePack(
      id: 'val-01',
      targets: ['all'],
      rule: 'Block deploy on validator errors; warnings need explicit approve.',
      severity: 'block',
    ),
    RulePack(
      id: 'val-02',
      targets: ['all'],
      rule:
          'The plan must be internally consistent before execution: every link '
          'endpoints at interfaces the named models actually have, and every '
          'addressed interface appears on a link or is a loopback.',
      severity: 'warn',
    ),
  ];

  /// Filter packs relevant to a target.
  static List<RulePack> forTarget(String target) => packs
      .where((p) => p.targets.contains('all') || p.targets.contains(target))
      .toList();

  /// Build the context block injected into Gemini prompt.
  ///
  /// [knownBlockers] and [unsupportedCapabilities] are the cross-run failure
  /// signal: what real runs kept failing to do, and what Packet Tracer has
  /// already proven it cannot do on this setup. Without them the planner
  /// regenerated the same unusable steps on every run.
  static String contextBlock({
    required String target,
    required List<String> pastBuildSummaries,
    required List<String> learnedRules,
    required Map<String, String> preferences,
    List<String> recentAttemptSummaries = const [],
    List<String> knownBlockers = const [],
    List<String> unsupportedCapabilities = const [],
  }) {
    final sb = StringBuffer();
    sb.writeln('## Target rules ($target)');
    for (final p in forTarget(target)) {
      sb.writeln('- [${p.id}] ${p.rule}');
    }
    if (knownBlockers.isNotEmpty) {
      sb.writeln('## Known blockers from previous runs');
      sb.writeln(
        'These steps have already failed, repeatedly and without ever '
        'recovering. Do NOT generate them again. Propose a supported '
        'alternative, or leave the step out and explain the omission.',
      );
      for (final line in knownBlockers.take(12)) {
        sb.writeln(line.startsWith('-') ? line : '- $line');
      }
    }
    if (unsupportedCapabilities.isNotEmpty) {
      sb.writeln('## Packet Tracer cannot do these (proven on this setup)');
      for (final line in unsupportedCapabilities.take(12)) {
        sb.writeln(line.startsWith('-') ? line : '- $line');
      }
    }
    if (learnedRules.isNotEmpty) {
      sb.writeln('## Learned from user corrections');
      for (final r in learnedRules.take(20)) {
        sb.writeln('- $r');
      }
    }
    if (pastBuildSummaries.isNotEmpty) {
      sb.writeln('## Similar past builds');
      for (final s in pastBuildSummaries.take(5)) {
        sb.writeln('- $s');
      }
    }
    if (recentAttemptSummaries.isNotEmpty) {
      sb.writeln('## Verified execution outcomes');
      for (final s in recentAttemptSummaries.take(10)) {
        sb.writeln('- $s');
      }
    }
    if (preferences.isNotEmpty) {
      sb.writeln('## User preferences');
      preferences.forEach((k, v) => sb.writeln('- $k=$v'));
    }
    // Best-effort: also try loading asset copy (ignored if missing, e.g. tests)
    return sb.toString();
  }

  static Future<String> tryLoadAsset(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return '';
    }
  }
}
