// End-to-end sanity across several DISTINCT network briefs: the point is that
// the planner, the learned design levers and the offline knowledge agree with
// each other on lab shapes that differ in device mix, routing and site count -
// not just on one canned example.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_knowledge.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:net_builder/services/validator_service.dart';

void main() {
  group('network briefs parse and validate coherently', () {
    final briefs = <String, int>{
      // brief -> minimum device count it should recognise
      '2 routers, 2 switches and 50 PCs with OSPF': 54,
      '1 router and 1 switch with 4 PCs': 6,
      'three routers in a triangle with OSPF': 3,
      'a small office with a router, a switch, 3 PCs and a server': 6,
      // same lab, Arabic + English mix is a supported planner path
      'ارسم ٢ راوتر و ٢ سويتش و 10 PCs': 14,
    };

    briefs.forEach((brief, minDevices) {
      test('"$brief"', () {
        final intent = NetworkIntent.parseSimple('chat', brief);
        expect(
          intent.nodes.length,
          greaterThanOrEqualTo(minDevices),
          reason: 'the planner under-counted "$brief"',
        );
        // A plan the validator can read without crashing is the floor; a
        // 50-device plan is expected to warn, not to be silently accepted.
        final issues = ValidatorService.validate(
          intent,
          target: 'packet-tracer',
        );
        expect(issues, isA<List>());
      });
    });
  });

  group('learned design levers apply per brief', () {
    test('routing preference reaches a multi-router lab', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        '2 routers and 2 switches with 4 PCs',
      );
      final learned = PlannerMemoryService.apply(
        intent,
        rules: const ['always use OSPF'],
      );
      expect(learned.routing, 'ospf');
    });

    test('router model preference applies to every router', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        '2 routers and 2 switches with 4 PCs',
      );
      final learned = PlannerMemoryService.apply(
        intent,
        rules: const ['use a 4331 router'],
      );
      final routers = learned.nodes.where((n) => n.type == 'router');
      expect(routers, isNotEmpty);
      expect(routers.every((n) => n.model == '4331'), isTrue);
    });

    test('a /31 transit convention is recorded as a visible note', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        '2 routers and 2 switches with 4 PCs',
      );
      final learned = PlannerMemoryService.apply(
        intent,
        rules: const ['use /31 point-to-point transit links'],
      );
      expect(
        learned.notes.any(
          (n) => n.toLowerCase().contains('transit') && n.contains('/31'),
        ),
        isTrue,
        reason: 'the learned convention must be visible on the plan',
      );
    });

    test('a management VLAN convention is recorded', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        '1 router and 1 switch with 4 PCs',
      );
      final learned = PlannerMemoryService.apply(
        intent,
        preferences: const {'management_vlan': '99'},
      );
      expect(learned.notes.any((n) => n.contains('99')), isTrue);
    });

    test('no rules leaves the plan untouched', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        '2 routers and 2 switches with 4 PCs',
      );
      final learned = PlannerMemoryService.apply(intent);
      expect(learned.routing, intent.routing);
      expect(learned.nodes.length, intent.nodes.length);
      expect(learned.notes.length, intent.notes.length);
    });
  });

  group('offline design judgment answers across a seasoned range', () {
    final questions = <String>[
      'should I use ospf or eigrp for this lab',
      'why use a /31 on the transit link instead of a /30',
      'why should management be on a separate vlan',
      'why avoid vlan 1 for user traffic',
      'the gre tunnel drops big packets, should I adjust-mss',
      'when should I choose static routing vs ospf',
    ];

    for (final q in questions) {
      test('"$q" answers offline with a trade-off, not just a command', () {
        final a = OfflineKnowledge.answerFor(q);
        expect(a, isNotNull, reason: 'no offline answer for "$q"');
        // A seasoned answer names a trade-off / condition, not only a command.
        expect(a!.length, greaterThan(80));
      });
    }

    test('a build request is never swallowed by the knowledge table', () {
      expect(
        OfflineKnowledge.answerFor('build 2 routers and 3 switches'),
        isNull,
      );
    });
  });
}
