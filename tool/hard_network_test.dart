// ignore_for_file: avoid_print, lines_longer_than_80_chars
//
// HARD-NETWORK TEST - the same code the Windows app's chat uses.
//
//   cd C:\ai\app
//   dart run tool/hard_network_test.dart
//
// Section A  what the chat answers for a brutal brief
// Section B  the plan the offline planner builds + validator + suggested fixes
// Section C  the auto-learning loop: same brief, taught corrections, 3 rounds
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';
import 'package:net_builder/services/validator_service.dart';

const hardBrief =
    'A 3-site enterprise WAN. HQ: 12 VLANs including voice VLAN 110, guest '
    'VLAN 200 and management VLAN 99, 40 PCs, 8 IP phones, 2 web servers, '
    'a DNS server and a DHCP server. Two branch sites, each with 2 routers, '
    '4 switches, 25 PCs, a printer and a wireless access point with guest '
    'wifi. Run OSPF multi-area between the sites, NAT to the internet at HQ, '
    'a site-to-site IPsec VPN, port security, DHCP snooping and an ACL on the '
    'guest VLAN, QoS for voice, EtherChannel between the HQ core switches, '
    'trunk links to the access switches, an NTP and a syslog server, and AAA '
    'authentication on all VTY lines';

void line(String title) {
  print('');
  print('=' * 78);
  print(title);
  print('=' * 78);
}

NetworkIntent plan(String text) => PlannerMemoryService.apply(
  NetworkIntent.parseSimple('hard-network', CasualEnglish.normalize(text)),
);

void describe(String label, NetworkIntent i) {
  final byType = <String, int>{};
  for (final n in i.nodes) {
    byType[n.type] = (byType[n.type] ?? 0) + 1;
  }
  final issues = ValidatorService.validate(i, target: 'pt');
  final errors = issues.where((x) => x.severity == 'error').length;
  final warnings = issues.where((x) => x.severity == 'warning').length;
  print(label);
  print('   devices      : ${i.nodes.length}  $byType');
  print('   links        : ${i.links.length}   vlans: ${i.vlans}');
  print('   routing      : ${i.routing}   security requested: '
      '${i.security.requested}');
  print('   addressing   : ${i.addressing.length} interfaces');
  print('   validator    : $errors error(s), $warnings warning(s)');
  print('   suggestions  : ${PlannerSuggestionsService.forIntent(i, target: 'pt').length}');
}

void main() {
  final normalized = CasualEnglish.normalize(hardBrief);

  line('A. WHAT THE CHAT ANSWERS');
  final first = plan(hardBrief);
  final reply = OfflineAssistantService.reply(
    rawText: hardBrief,
    normalized: normalized,
    target: 'pt',
    plan: first,
    suggestions: PlannerSuggestionsService.forIntent(first, target: 'pt'),
    history: const [],
  );
  print('intent: ${reply.intent}');
  print(reply.text);

  line('B. THE PLAN + WHAT IT DOES NOT HANDLE');
  describe('baseline plan', first);
  print('');
  print('--- suggested fixes (what the chat tells the user to do) ---');
  for (final s in PlannerSuggestionsService.forIntent(first, target: 'pt')) {
    print('- $s');
  }

  line('C. AUTO-LEARNING: SAME BRIEF, TAUGHT CORRECTIONS, 3 ROUNDS');
  const rules = <String>[
    'always use OSPF',
    'always add a DNS server',
  ];
  const prefs = <String, String>{
    'base_subnet': '10.10.0.0/24',
    'router_model': '4331',
    'switch_model': '2960',
  };
  for (var round = 1; round <= 3; round++) {
    final taught = PlannerMemoryService.apply(
      NetworkIntent.parseSimple('hard-network', normalized),
      rules: rules,
      preferences: prefs,
    );
    final threads = taught.nodes
        .where((n) => n.type == 'router')
        .map((n) => n.model)
        .toSet();
    final servers = taught.nodes.where((n) => n.type == 'server').toList();
    final dns = servers.any((n) => n.services.contains('dns'));
    final lans = taught.addressing
        .where((a) => a.ipCidr.endsWith('/24'))
        .map((a) => a.ipCidr)
        .toList();
    final onBase = lans.every((a) => a.startsWith('10.10.'));
    print('round $round: routing=${taught.routing}  router models=$threads  '
        'dns service=$dns  LANs on 10.10.x=$onBase (${lans.length} LANs)  '
        'switches=${taught.nodes.where((n) => n.type == 'switch').map((n) => n.model).toSet()}');
  }

  line('D. IS IT DETERMINISTIC? (same brief twice)');
  final a = plan(hardBrief);
  final b = plan(hardBrief);
  print('same devices : ${a.nodes.map((n) => n.name).join(',') == b.nodes.map((n) => n.name).join(',')}');
  print('same links   : ${a.links.length == b.links.length}');
  print('same addrs   : ${a.addressing.map((x) => x.ipCidr).join(',') == b.addressing.map((x) => x.ipCidr).join(',')}');
}
