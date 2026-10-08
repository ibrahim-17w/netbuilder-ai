import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/network_tools.dart';
import 'package:net_builder/services/topology_reasoner.dart';

/// Tests for the topology reachability reasoner: plans are the real output
/// of NetworkIntent.parseSimple (the same briefs the planner tests use), and
/// expectations about which PC sits in which subnet are read FROM the plan,
/// so the tests pin the reasoning, not the planner's naming choices.
void main() {
  /// The reference two-site lab: transit 10.0.0.0/30, two PC LANs
  /// (192.168.1.0/24 and 192.168.2.0/24), OSPF between the routers.
  NetworkIntent ospfLab() => NetworkIntent.parseSimple(
    'reasoner-chat',
    '2 routers, 2 switches and 4 PCs with OSPF',
  );

  NetworkIntent plainLab() => NetworkIntent.parseSimple(
    'reasoner-chat',
    '2 routers, 2 switches and 4 PCs',
  );

  List<String> pcNames(NetworkIntent plan) => [
    for (final n in plan.nodes)
      if (n.type == 'pc') n.name,
  ];

  String addressOf(NetworkIntent plan, String node) => plan.addressing
      .firstWhere((a) => a.node.toLowerCase() == node.toLowerCase())
      .ipCidr;

  /// Two PCs that share a subnet, per the plan's own addressing rows.
  (String, String) sameSubnetPair(NetworkIntent plan) {
    final pcs = pcNames(plan);
    for (var i = 0; i < pcs.length; i++) {
      for (var j = i + 1; j < pcs.length; j++) {
        if (NetworkTools.sameSubnet(
          addressOf(plan, pcs[i]),
          addressOf(plan, pcs[j]),
        )) {
          return (pcs[i], pcs[j]);
        }
      }
    }
    throw StateError('no same-subnet PC pair in this plan');
  }

  /// Two PCs in different subnets, per the plan's own addressing rows.
  (String, String) crossSubnetPair(NetworkIntent plan) {
    final pcs = pcNames(plan);
    for (var i = 0; i < pcs.length; i++) {
      for (var j = i + 1; j < pcs.length; j++) {
        if (!NetworkTools.sameSubnet(
          addressOf(plan, pcs[i]),
          addressOf(plan, pcs[j]),
        )) {
          return (pcs[i], pcs[j]);
        }
      }
    }
    throw StateError('no cross-subnet PC pair in this plan');
  }

  group('question parsing', () {
    test('the classic fault question resolves both ends', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      final q = ReachabilityQuestion.parse(
        "why can't $a ping $b",
        plan,
      );
      expect(q, isNotNull);
      expect(q!.from.toLowerCase(), a.toLowerCase());
      expect(q.to.toLowerCase(), b.toLowerCase());
    });

    test('lowercase and no punctuation still parse', () {
      final plan = ospfLab();
      final (a, b) = crossSubnetPair(plan);
      final q = ReachabilityQuestion.parse(
        'can ${a.toLowerCase()} reach ${b.toLowerCase()}',
        plan,
      );
      expect(q, isNotNull);
    });

    test('troubleshoot-between phrasing parses', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      expect(
        ReachabilityQuestion.parse(
          'troubleshoot connectivity between $a and $b',
          plan,
        ),
        isNotNull,
      );
    });

    test('an unknown device names the miss, not a fake answer', () {
      final plan = ospfLab();
      final (a, _) = sameSubnetPair(plan);
      final result = ReachabilityQuestion.parseQuestion(
        "why can't $a ping PX9",
        plan,
      );
      expect(result.question, isNull);
      expect(result.failure, isNotNull);
      expect(result.failure!, contains('PX9'));
    });

    test('non-questions stay null with no failure claimed', () {
      final plan = ospfLab();
      final result = ReachabilityQuestion.parseQuestion(
        'what is a vlan',
        plan,
      );
      expect(result.question, isNull);
      expect(result.failure, isNull);
    });
  });

  group('the check ladder', () {
    test('same-subnet PCs are reachable with a full ladder', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isTrue);
      expect(v.ladder, isNotEmpty);
      expect(v.ladder.any((s) => s.blocked), isFalse);
      expect(
        v.ladder.map((s) => s.check),
        containsAll(<String>['Link', 'Addressing', 'Subnet']),
      );
      expect(v.toText(), isNotEmpty);
    });

    test('cross-subnet with OSPF passes the routing check', () {
      final plan = ospfLab();
      final (a, b) = crossSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isTrue);
      final routing = v.ladder.firstWhere((s) => s.check == 'Routing');
      expect(routing.detail.toLowerCase(), contains('ospf'));
    });

    test('cross-subnet without routing intent is blocked with a fix', () {
      // The planner defaults a plain brief to static routing, so a plan
      // with genuinely NO routing intent is built by stripping it here.
      final plan = plainLab().copyWith(routing: '');
      final (a, b) = crossSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isFalse);
      final blocked = v.ladder.firstWhere((s) => s.blocked);
      expect(blocked.check, 'Routing');
      expect(blocked.fixes, isNotEmpty);
      expect(v.quickReplies, isNotEmpty);
    });

    test('different subnets across a bare switch are called out as L2', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      // Move one end to a foreign subnet: the path keeps only a switch, so
      // the subnet check must refuse, not silently assume routing.
      final idx = plan.addressing.indexWhere(
        (x) => x.node.toLowerCase() == a.toLowerCase(),
      );
      final row = plan.addressing[idx];
      plan.addressing[idx] = InterfaceAddr(
        node: row.node,
        iface: row.iface,
        ipCidr: '10.9.9.10/24',
      );
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isFalse);
      final blocked = v.ladder.firstWhere((s) => s.blocked);
      expect(blocked.check, 'Subnet');
    });

    test('an uncabled pair is blocked at the link check', () {
      final plan = ospfLab();
      plan.links.clear();
      final (a, b) = sameSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isFalse);
      expect(v.ladder.single.check, 'Link');
      expect(v.ladder.single.blocked, isTrue);
    });

    test('a PC with no addressing stops at the addressing check', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      plan.addressing.removeWhere(
        (x) => x.node.toLowerCase() == a.toLowerCase(),
      );
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: b,
        target: 'pt',
      );
      expect(v.reachable, isFalse);
      final blocked = v.ladder.firstWhere((s) => s.blocked);
      expect(blocked.check, 'Addressing');
      expect(blocked.detail, contains(a));
    });

    test('the same device named twice is refused, not reasoned about', () {
      final plan = ospfLab();
      final (a, _) = sameSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: a,
        target: 'pt',
      );
      expect(v.reachable, isFalse);
      expect(v.ladder.single.check, 'Same device');
    });

    test('an unknown device fails closed with a cannot-tell step', () {
      final plan = ospfLab();
      final (a, b) = sameSubnetPair(plan);
      final v = TopologyReasoner.explain(
        plan: plan,
        from: a,
        to: 'PX9',
        target: 'pt',
      );
      expect(v.reachable, isNull);
      expect(v.ladder.single.cannotTell, isTrue);
      expect(v.ladder.single.detail, contains('PX9'));
    });
  });
}
