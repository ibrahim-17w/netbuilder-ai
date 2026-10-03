import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/plan_repair_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The brief a user actually typed into the app: two sites, per-site device
/// lists, an address plan per site, OSPF area 0 and an AAA account.
const _corporateBrief =
    'Build a corporate network for 40 users across 2 physical sites. '
    'Site A is the headquarters with 2 routers, 2 switches, 3 Server-PT '
    'devices (1 DHCP server, 1 AAA/TACACS+ server, 1 DNS+HTTP server) and '
    '15 PCs. Site B is a branch with 1 router, 1 switch, 1 Server-PT device '
    '(the DHCP server) and 10 PCs. Use 192.168.10.0/24 at HQ and '
    '192.168.20.0/24 at the branch, OSPF area 0, and set up AAA with the '
    'client name admin and password 123.';

NetworkIntent _plan(String brief, [String project = 'repair']) =>
    NetworkIntent.parseSimple(project, CasualEnglish.normalize(brief));

/// Exactly the finding set the build card withholds on
/// (`ValidationIssue.blocks`), so a test can never call a plan buildable that
/// the card still refuses.
List<ValidationIssue> _blocking(NetworkIntent plan) =>
    ValidatorService.validate(plan, target: 'packet-tracer')
        .where((i) => i.blocks)
        .toList();

int _of(NetworkIntent plan, String type) =>
    plan.nodes.where((n) => n.type == type).length;

String _cidrOf(NetworkIntent plan, String node, String iface) => plan.addressing
    .firstWhere((a) => a.node == node && a.iface == iface)
    .ipCidr;

void main() {
  group('the reported corporate brief', () {
    final plan = _plan(_corporateBrief);

    test('every device in a site list survives, parents and all', () {
      expect(_of(plan, 'router'), 3, reason: '2 at HQ + 1 at the branch');
      expect(_of(plan, 'switch'), 3, reason: '2 at HQ + 1 at the branch');
      expect(_of(plan, 'pc'), 25, reason: '15 at HQ + 10 at the branch');
      expect(_of(plan, 'server'), 4, reason: '3 at HQ + 1 at the branch');
      expect(plan.nodes.length, 35);
    });

    test('the servers keep the roles the brief gave them', () {
      final roles = <String>{
        for (final s in plan.nodes.where((n) => n.type == 'server'))
          s.services.join(','),
      };
      expect(roles, containsAll(<String>['dhcp', 'aaa', 'dns', 'http']));
    });

    test('the stated subnets land where the brief said', () {
      // HQ is on 192.168.10.0/24 and the branch on 192.168.20.0/24. The
      // router-to-router links used to be given the stated /24s, which left
      // the LANs to be derived from the same block - the plan then carried
      // "Duplicate IP 192.168.10.1 on R1 and R1 g0/0" and could never be
      // built, whatever the user said next.
      expect(_cidrOf(plan, 'R1', 'g0/1'), '192.168.10.1/24');
      expect(_cidrOf(plan, 'R2', 'g0/1'), '192.168.11.1/24');
      expect(_cidrOf(plan, 'R3', 'g0/1'), '192.168.20.1/24');
      // The HQ site's devices are on the HQ block, the branch's on its own:
      // the 15 HQ PCs plus the HQ servers, then the 10 branch PCs.
      expect(_cidrOf(plan, 'PC1', 'f0'), '192.168.10.10/24');
      expect(_cidrOf(plan, 'PC10', 'f0'), '192.168.11.10/24');
      expect(_cidrOf(plan, 'PC18', 'f0'), '192.168.20.10/24');
      expect(_cidrOf(plan, 'PC25', 'f0'), '192.168.20.17/24');
      // The point-to-point links are their own subnets, not a LAN block.
      expect(plan.addressing.any((a) => a.ipCidr.endsWith('/30')), isTrue);
    });

    test('no address is used twice', () {
      final ips = plan.addressing.map((a) => a.ipCidr.split('/').first).toList();
      expect(ips.toSet().length, ips.length);
    });

    test('the plan passes the checks the build card uses', () {
      expect(
        _blocking(plan).map((i) => i.message),
        isEmpty,
        reason: 'a correct brief must not arrive at a refused Build card',
      );
    });

    test('the offline answer counts what the plan holds', () {
      final reply = OfflineAssistantService.reply(
        rawText: _corporateBrief,
        normalized: CasualEnglish.normalize(_corporateBrief),
        target: 'packet-tracer',
        plan: plan,
        suggestions: PlannerSuggestionsService.forIntent(
          plan,
          target: 'packet-tracer',
        ),
        history: const [],
        modelError: 'HTTP 503: {}',
      );
      expect(reply.intent, 'build');
      expect(reply.text, contains('25 PC(s)'));
      expect(reply.text, contains('3 router(s)'));
      expect(reply.text, contains('35 device(s) in total'));
      expect(reply.text, isNot(contains('Fix these first')));
      expect(reply.quickReplies, contains('Build the .pkt'));
    });
  });

  group('a count is not a correction just because "use" follows it', () {
    test('the trailing address sentence does not replace a site count', () {
      final plan = _plan(
        'Build a network across 2 physical sites. Site A is the headquarters '
        'with 2 routers, 2 switches, 3 servers and 15 PCs. Site B is a branch '
        'with 1 router, 1 switch, 1 server and 10 PCs. Use 192.168.10.0/24 at '
        'HQ and 192.168.20.0/24 at the branch, OSPF area 0.',
      );
      expect(_of(plan, 'pc'), 25);
      expect(_of(plan, 'router'), 3);
    });

    test('a real correction still replaces what was counted before', () {
      final plan = _plan('2 routers 2 switches 4 pcs, actually 10 pcs');
      expect(_of(plan, 'pc'), 10);
    });

    test('a trailing "use" is not a correction either', () {
      // "use" corrects only in FRONT of a count ("use 2 routers"). Behind it
      // it introduces the routing or the addressing of what was just counted.
      final plan = _plan('2 routers 2 switches 4 pcs use ospf');
      expect(_of(plan, 'pc'), 4);
      expect(_of(plan, 'router'), 2);
      expect(plan.routing, 'ospf');
    });
  });

  group('the repair pass', () {
    test('moves the second holder of a duplicate address', () {
      final plan = _plan(
        '1 router 1 switch 4 pcs, PC1 is 192.168.1.10 and '
        'PC2 is 192.168.1.10',
      );
      expect(_blocking(plan), isNotEmpty, reason: 'the brief really is broken');

      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(repair.changes, hasLength(1));
      expect(repair.changes.first, contains('PC2'));
      expect(repair.remaining, isEmpty);
      final ips = repair.plan.addressing
          .map((a) => a.ipCidr.split('/').first)
          .toList();
      expect(ips.toSet().length, ips.length);
    });

    test('cables a device the plan left standing alone, then addresses it', () {
      const orphan = NetworkIntent(
        projectName: 'island',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '2911'),
          NetNode(name: 'SW1', type: 'switch', model: '2960'),
          NetNode(name: 'PC1', type: 'pc', model: 'PC-PT'),
        ],
        links: [
          NetLink(a: 'R1', aIf: 'g0/1', b: 'SW1', bIf: 'f0/1'),
        ],
        addressing: [
          InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '192.168.1.1/24'),
        ],
      );
      expect(_blocking(orphan), isNotEmpty);

      final repair = PlanRepairService.repair(orphan, target: 'packet-tracer');
      expect(repair.changes.join(' '), contains('cabled PC1'));
      expect(
        repair.plan.links.any((l) => l.a == 'PC1' || l.b == 'PC1'),
        isTrue,
      );
      expect(
        repair.plan.addressing.any((a) => a.node == 'PC1'),
        isTrue,
        reason: 'a cabled endpoint still needs its Desktop address',
      );
      expect(repair.remaining, isEmpty);
    });

    test('gives an unaddressed endpoint the next free LAN host', () {
      const plan = NetworkIntent(
        projectName: 'blank-pc',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '2911'),
          NetNode(name: 'SW1', type: 'switch', model: '2960'),
          NetNode(name: 'PC1', type: 'pc', model: 'PC-PT'),
          NetNode(name: 'PC2', type: 'pc', model: 'PC-PT'),
        ],
        links: [
          NetLink(a: 'R1', aIf: 'g0/1', b: 'SW1', bIf: 'f0/1'),
          NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
          NetLink(a: 'SW1', aIf: 'f0/3', b: 'PC2', bIf: 'f0'),
        ],
        addressing: [
          InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '192.168.5.1/24'),
          InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.5.10/24'),
        ],
      );
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      final pc2 = repair.plan.addressing.firstWhere((a) => a.node == 'PC2');
      expect(pc2.ipCidr, '192.168.5.11/24');
      expect(repair.changes.join(' '), contains('PC2'));
      expect(repair.remaining, isEmpty);
    });

    test('a plan with nothing wrong is left exactly as it is', () {
      final plan = _plan('2 routers 2 switches 4 pcs, use ospf');
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(repair.changes, isEmpty);
      expect(repair.remaining, isEmpty);
      expect(repair.plan.revision, plan.revision);
    });
  });

  group('the chat understands "fix the plan"', () {
    final broken = _plan(
      '1 router 1 switch 4 pcs, PC1 is 192.168.1.10 and PC2 is 192.168.1.10',
    );

    test('what counts as a repair instruction', () {
      for (final t in const [
        'fix the plan',
        'Fix these',
        'can you fix it?',
        'please fix the plan',
        'repair the network',
        'solve the errors',
        'fix',
      ]) {
        expect(
          OfflineAssistantService.looksLikeRepairRequest(t),
          isTrue,
          reason: t,
        );
      }
      for (final t in const [
        'how do I fix an OSPF neighbour?',
        'why is my trunk broken?',
        'fix 2 routers',
        'what should I fix',
        'thanks',
        '',
      ]) {
        expect(
          OfflineAssistantService.looksLikeRepairRequest(t),
          isFalse,
          reason: t,
        );
      }
    });

    test('the reply reports the fix and hands back the repaired plan', () {
      final reply = OfflineAssistantService.reply(
        rawText: 'fix the plan',
        normalized: 'fix the plan',
        target: 'packet-tracer',
        plan: broken,
        history: const [],
        modelError: 'HTTP 503: {}',
      );
      expect(reply.intent, 'fix');
      expect(reply.text, contains('Fixed 1 thing(s)'));
      expect(reply.text, contains('PC2'));
      expect(reply.text, contains('buildable now'));
      expect(reply.repairedPlan, isNotNull);
      expect(_blocking(reply.repairedPlan!), isEmpty);
      expect(reply.quickReplies, contains('Build the .pkt'));
    });

    test('a plan with nothing blocking says so instead of stalling', () {
      final clean = _plan('2 routers 2 switches 4 pcs, use ospf');
      final reply = OfflineAssistantService.fixPlan(
        plan: clean,
        target: 'packet-tracer',
      );
      expect(reply.intent, 'fix');
      expect(reply.text, contains('Nothing in this plan blocks the build'));
      // The plan still travels back, so the caller can re-stamp a fresh card
      // over a card that was written for an older revision of it.
      expect(reply.repairedPlan, isNotNull);
      expect(reply.quickReplies, contains('Build the .pkt'));
    });

    test('with no plan on the table it asks for the lab', () {
      final reply = OfflineAssistantService.fixPlan(
        plan: null,
        target: 'packet-tracer',
      );
      expect(reply.intent, 'fix');
      expect(reply.text, contains('no plan on the table'));
      expect(reply.repairedPlan, isNull);
    });

    test('a finding only the user can settle is named, not papered over', () {
      // AAA with no account: nothing in the plan can invent the login, so it
      // says what is left instead of claiming a clean plan. A warning the
      // build handles BY ITSELF is a different case (below): the two must not
      // be flattened into one "not buildable".
      final aaa = _plan('1 router 1 switch and 5 pcs with aaa on the vty lines');
      final reply = OfflineAssistantService.fixPlan(
        plan: aaa,
        target: 'packet-tracer',
      );
      expect(reply.intent, 'fix');
      expect(reply.text, contains('cannot repair these from here'));
      expect(reply.text, contains('holds no account'));
      expect(reply.text, contains('AAA username admin password 123'));
      expect(reply.text, isNot(contains('buildable now')));
      expect(reply.repairedPlan, isNotNull);
      expect(_blocking(reply.repairedPlan!), isNotEmpty);
    });

    test('a note the build acts on itself no longer withholds the build', () {
      // A serial WAN needs a module no stock PT ISR has, and the build REMAPS
      // the cable to a spare routed port. The note is still given - it just
      // cannot be a decision the user has to make, because withholding the
      // build over it left an ordinary brief ("two routers over a serial
      // link") unbuildable, with no reply able to clear it.
      final serial = _plan('connect two routers over a serial WAN with 1 switch');
      final reply = OfflineAssistantService.fixPlan(
        plan: serial,
        target: 'packet-tracer',
      );
      expect(reply.intent, 'fix');
      expect(
        ValidatorService.validate(serial, target: 'packet-tracer')
            .map((i) => i.message)
            .any((m) => m.contains('serial module')),
        isTrue,
        reason: 'the note is still reported',
      );
      expect(_blocking(serial), isEmpty);
      expect(reply.text, isNot(contains('cannot repair these from here')));
    });
  });

  group('a large but correct plan still builds', () {
    test('the size heads-up no longer withholds the Build card', () {
      final plan = _plan(_corporateBrief);
      expect(plan.nodes.length, greaterThan(20));
      final issues = ValidatorService.validate(plan, target: 'packet-tracer');
      expect(
        issues.where((i) => i.severity == 'warning').map((i) => i.message),
        isEmpty,
      );
      expect(
        issues.where((i) => i.message.contains('Large topologies')),
        isNotEmpty,
        reason: 'the advice is still given, as info',
      );
    });
  });
}
