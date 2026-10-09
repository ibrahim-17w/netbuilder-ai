import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/plan_repair_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The brief from the user's own screenshots: two sites, 35 devices, OSPF,
/// an AAA account. It builds - and it used to open in Packet Tracer with the
/// transit links red and every simulated packet dropped.
const _twoSiteBrief =
    'Build a corporate network for 40 users across 2 physical sites. '
    'Site A is the headquarters with 2 routers, 2 switches, 3 Server-PT '
    'devices (1 DHCP server, 1 AAA/TACACS+ server, 1 DNS+HTTP server) and '
    '15 PCs. Site B is a branch with 1 router, 1 switch, 1 Server-PT device '
    '(the DHCP server) and 10 PCs. Use 192.168.10.0/24 at HQ and '
    '192.168.20.0/24 at the branch, OSPF area 0, and set up AAA with the '
    'client name admin and password 123.';

NetworkIntent _plan(String brief, [String project = 'cables']) =>
    NetworkIntent.parseSimple(project, CasualEnglish.normalize(brief));

/// The plan payload the offline compiler and the live run both build from.
List<Map<String, dynamic>> _planLinks(NetworkIntent plan) {
  final payload = PacketTracerAdapter.autopilotPlan(plan);
  final steps = (payload['steps'] as List).cast<Map>();
  final create = steps.firstWhere((s) => s['action'] == 'create_links');
  return (create['links'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

String? _cableFor(NetworkIntent plan, String a, String b) {
  for (final l in _planLinks(plan)) {
    if ((l['a'] == a && l['b'] == b) || (l['a'] == b && l['b'] == a)) {
      return l['cable'] as String?;
    }
  }
  return null;
}

void main() {
  group('a copper cable is chosen for the pair, not by default', () {
    test('like devices need a crossover; a switch port does not', () {
      // Two routers (or two switches, or two hosts, or a host straight into a
      // router) put transmit on the pin the other end transmits on.
      expect(NetLink.pairNeedsCrossover('router', 'router'), isTrue);
      expect(NetLink.pairNeedsCrossover('switch', 'switch'), isTrue);
      expect(NetLink.pairNeedsCrossover('pc', 'pc'), isTrue);
      expect(NetLink.pairNeedsCrossover('pc', 'router'), isTrue);
      expect(NetLink.pairNeedsCrossover('router', 'firewall'), isTrue);
      // A switch port is what a straight-through cable exists for.
      expect(NetLink.pairNeedsCrossover('switch', 'router'), isFalse);
      expect(NetLink.pairNeedsCrossover('switch', 'pc'), isFalse);
      expect(NetLink.pairNeedsCrossover('switch', 'server'), isFalse);
      expect(NetLink.pairNeedsCrossover('switch', 'wireless'), isFalse);
      expect(NetLink.pairNeedsCrossover('switch', 'phone'), isFalse);
      // Hub-like devices present switch ports too.
      expect(NetLink.pairNeedsCrossover('cloud', 'router'), isFalse);
      expect(NetLink.pairNeedsCrossover('cloud', 'switch'), isTrue);
    });

    test('the plan payload carries the crossover for the transit links', () {
      final plan = _plan(_twoSiteBrief);
      // Every router-to-router link in the payload - this is the exact thing
      // Packet Tracer holds DOWN with a straight-through.
      final routers = {
        for (final n in plan.nodes.where((n) => n.type == 'router')) n.name,
      };
      final transit = plan.links
          .where((l) => routers.contains(l.a) && routers.contains(l.b))
          .toList();
      expect(transit, isNotEmpty, reason: 'R1-R2 and R2-R3');
      for (final l in transit) {
        expect(
          _cableFor(plan, l.a, l.b),
          'copper-cross',
          reason: '${l.a}-${l.b} is router-to-router',
        );
      }
      // A switch uplink stays straight-through.
      expect(_cableFor(plan, 'R1', 'SW1'), isNot('copper-cross'));
      // A PC on a switch port stays straight-through.
      expect(_cableFor(plan, 'SW1', 'PC1'), isNot('copper-cross'));
    });

    test('an explicit cable, and a serial link, are left alone', () {
      const plan = NetworkIntent(
        projectName: 'p',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '2911'),
          NetNode(name: 'R2', type: 'router', model: '2911'),
        ],
        links: [
          NetLink(a: 'R1', aIf: 'g0/0', b: 'R2', bIf: 'g0/0', cable: 'serial'),
          NetLink(a: 'R1', aIf: 's0/0/0', b: 'R2', bIf: 's0/0/0'),
        ],
      );
      expect(plan.wiredLinks.first.cable, 'serial');
      // Serial interfaces are wired as serial whatever the field says.
      expect(plan.wiredLinks.last.cable, isNull);
      expect(plan.wiredLinks.last.isSerial, isTrue);
    });

    test('filling the cable in does not move the revision', () {
      // A build card is stamped with a revision; a plan whose cable kind is
      // corrected must not invalidate a card that is already on screen.
      final plan = _plan(_twoSiteBrief);
      expect(
        NetworkIntent(
          projectName: plan.projectName,
          nodes: plan.nodes,
          links: plan.wiredLinks,
          addressing: plan.addressing,
          vlans: plan.vlans,
          routing: plan.routing,
          security: plan.security,
        ).revision,
        plan.revision,
      );
    });
  });

  group('the repair pass applies the remedies it can', () {
    test('two cables on one interface move to a free port', () {
      const plan = NetworkIntent(
        projectName: 'conflict',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '2911'),
          NetNode(name: 'SW1', type: 'switch', model: '2960'),
          NetNode(name: 'PC1', type: 'pc'),
          NetNode(name: 'PC2', type: 'pc'),
        ],
        links: [
          NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
          NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
          // Both PCs on the SAME switch port - the parse artefact the
          // validator reports as "Interface SW1:f0/2 is used by 2 links".
          NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC2', bIf: 'f0'),
        ],
        addressing: [
          InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.9.1/24'),
          InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.9.10/24'),
          InterfaceAddr(node: 'PC2', iface: 'f0', ipCidr: '192.168.9.11/24'),
        ],
      );
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      final ports = <String>[
        for (final l in repair.plan.links)
          if (l.a == 'SW1') l.aIf,
        for (final l in repair.plan.links)
          if (l.b == 'SW1') l.bIf,
      ];
      expect(ports.toSet().length, ports.length, reason: 'one cable per port');
      expect(repair.changes, isNotEmpty);
      expect(repair.remaining, isEmpty);
    });

    test('a switch with more cables than ports moves the overflow', () {
      // 30 PCs plus the router uplink on one 24-port 2960: exactly the plan
      // the validator refuses with "a Packet Tracer 2960 has only 24 ports".
      final nodes = <NetNode>[
        const NetNode(name: 'R1', type: 'router', model: '2911'),
        const NetNode(name: 'SW1', type: 'switch', model: '2960'),
        const NetNode(name: 'SW2', type: 'switch', model: '2960'),
        for (var i = 1; i <= 30; i++) NetNode(name: 'PC$i', type: 'pc'),
      ];
      final overflow = NetworkIntent(
        projectName: 'capacity',
        nodes: nodes,
        links: [
          const NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
          // SW2 has its own router port, so a PC that moves onto it has a
          // LAN to be addressed on.
          const NetLink(a: 'R1', aIf: 'g0/1', b: 'SW2', bIf: 'f0/1'),
          for (var i = 1; i <= 30; i++)
            NetLink(a: 'SW1', aIf: 'f0/${i + 1}', b: 'PC$i', bIf: 'f0'),
        ],
        addressing: [
          const InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '10.9.0.1/24'),
          const InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.9.1.1/24'),
          for (var i = 1; i <= 30; i++)
            InterfaceAddr(node: 'PC$i', iface: 'f0', ipCidr: '10.9.0.${i + 9}/24'),
        ],
      );
      final before = ValidatorService.validate(
        overflow,
        target: 'packet-tracer',
      ).where((i) => i.blocks).toList();
      expect(
        before.map((i) => i.message).join(' '),
        contains('only 24 ports'),
        reason: '31 cables on a 24-port switch',
      );

      final repair = PlanRepairService.repair(
        overflow,
        target: 'packet-tracer',
      );
      final onSw1 = repair.plan.links
          .where((l) => l.a == 'SW1' || l.b == 'SW1')
          .length;
      final onSw2 = repair.plan.links
          .where((l) => l.a == 'SW2' || l.b == 'SW2')
          .length;
      expect(onSw1, lessThanOrEqualTo(24), reason: 'SW1 fits its ports');
      expect(onSw2, greaterThan(1), reason: 'the overflow really moved');
      expect(repair.changes.join(' '), contains('moved'));
      expect(repair.remaining, isEmpty);
      // A device that moved onto another switch is addressed on THAT LAN, not
      // left holding an address from the switch it left.
      final moved = repair.plan.links
          .where((l) => l.a == 'SW2' || l.b == 'SW2')
          .map((l) => l.a == 'SW2' ? l.b : l.a)
          .where((n) => n.startsWith('PC'))
          .toList();
      expect(moved, isNotEmpty);
      for (final pc in moved) {
        final ip = repair.plan.addressing
            .firstWhere((a) => a.node == pc)
            .ipCidr;
        expect(ip, startsWith('10.9.1.'), reason: pc);
      }
    });
  });

  group('"fix every finding then build" is one request', () {
    test('the build half is read, and only after a repair verb', () {
      for (final t in const [
        'fix every finding you got then build',
        'fix the plan and build it',
        'repair the plan and compile it',
        'solve these findings then build the pkt',
        'fix everything and build',
      ]) {
        expect(
          OfflineAssistantService.asksToBuildAfterRepair(t),
          isTrue,
          reason: t,
        );
      }
      for (final t in const [
        'fix the plan',
        'how do I fix an OSPF neighbour?',
        'build the .pkt',
        'build 2 routers and 4 pcs',
        '',
      ]) {
        expect(
          OfflineAssistantService.asksToBuildAfterRepair(t),
          isFalse,
          reason: t,
        );
      }
    });

    test('a cleared plan promises the build instead of asking for a click', () {
      final broken = _plan(
        '1 router 1 switch 4 pcs, PC1 is 192.168.1.10 and PC2 is 192.168.1.10',
      );
      final reply = OfflineAssistantService.fixPlan(
        plan: broken,
        target: 'packet-tracer',
        andBuild: true,
      );
      expect(reply.text, contains('I am compiling it'));
      expect(reply.text, isNot(contains('Press "Build the .pkt"')));
      expect(reply.repairedPlan, isNotNull);
      expect(
        OfflineAssistantService.blockingFindings(
          reply.repairedPlan!,
          target: 'packet-tracer',
        ),
        isEmpty,
      );
    });

    test('a login finding is repaired before the build, not begged for', () {
      // AAA on the vty lines with no account anywhere used to answer "I did
      // not build it" and tell the user to type "AAA username admin password
      // 123". That sentence parses to nothing, so the build never happened no
      // matter how it was phrased. The repair now writes the placeholder
      // account itself, which unblocks the build in the same turn.
      final plan = _plan(
        '1 router 1 switch and 5 pcs with aaa on the vty lines',
      );
      final reply = OfflineAssistantService.fixPlan(
        plan: plan,
        target: 'packet-tracer',
        andBuild: true,
      );
      expect(reply.repairedPlan, isNotNull);
      expect(
        (reply.repairedPlan!.security.aaaAccountPassword ?? '').isNotEmpty,
        isTrue,
        reason: 'the placeholder account must exist for the build to proceed',
      );
      expect(reply.text, isNot(contains('I did not build it')));
      expect(reply.text, contains('placeholder'));
    });

    test('a clean plan builds as it stands', () {
      final clean = _plan('2 routers 2 switches 4 pcs, use ospf');
      final reply = OfflineAssistantService.fixPlan(
        plan: clean,
        target: 'packet-tracer',
        andBuild: true,
      );
      expect(reply.text, contains('Nothing to repair'));
      expect(reply.text, contains('compiling it as it stands'));
    });
  });
}
