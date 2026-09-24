import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The keyless planner has no model to learn from, so it evolves through the
/// rules and preferences the user accepts. These tests stand in for that
/// loop: plan a faulty brief, accept a correction, re-plan the SAME brief,
/// and check the plan is strictly better - repeated several times, so a
/// flaky result cannot pass by luck.
void main() {
  const faultyBrief = 'lab network with 2 routers 2 switches 1 server and 4 pcs';

  List<String> errors(NetworkIntent i) =>
      ValidatorService.validate(i, target: 'pt')
          .where((x) => x.severity == 'error')
          .map((x) => x.message)
          .toList();

  test('round 0: the faulty brief is planned with suggestions, not a crash', () {
    final intent = NetworkIntent.parseSimple('evo', faultyBrief);
    expect(intent.nodes, isNotEmpty);
    // The brief names no routing protocol and gives the server no role.
    expect(intent.routing, 'static');
    expect(
      intent.nodes.firstWhere((n) => n.type == 'server').services,
      isEmpty,
    );
    final suggestions = PlannerSuggestionsService.forIntent(intent);
    expect(
      suggestions.any((s) => s.toLowerCase().contains('service role')),
      isTrue,
      reason: 'the empty server role must be suggested to the user',
    );
  });

  test('a saved correction improves the SAME brief, stable over 3 rounds', () {
    // What the user accepted after reading the suggestions.
    const rules = <String>['always use OSPF', 'always add a DNS server'];
    const prefs = <String, String>{
      'base_subnet': '10.20.0.0/24',
      'router_model': '4331',
    };

    for (var round = 0; round < 3; round++) {
      final evolved = PlannerMemoryService.apply(
        NetworkIntent.parseSimple('evo', faultyBrief),
        rules: rules,
        preferences: prefs,
      );

      // 1. routing protocol now follows the learned rule
      expect(evolved.routing, 'ospf', reason: 'round $round');

      // 2. the server gained the learned default service
      expect(
        evolved.nodes.firstWhere((n) => n.type == 'server').services,
        contains('dns'),
        reason: 'round $round',
      );

      // 3. the preferred router model was applied
      expect(
        evolved.nodes.firstWhere((n) => n.type == 'router').model,
        '4331',
        reason: 'round $round',
      );

      // 4. every LAN moved onto the preferred base, each LAN still distinct
      final lans = evolved.addressing.where((a) => a.ipCidr.endsWith('/24'));
      expect(lans, isNotEmpty, reason: 'round $round');
      expect(
        lans.every((a) => a.ipCidr.startsWith('10.20.')),
        isTrue,
        reason: 'round $round',
      );
      expect(
        lans.map((a) => a.ipCidr.split('.').sublist(0, 3).join('.')).toSet().length,
        greaterThan(1),
        reason: 'the two LANs must stay separate subnets',
      );

      // 5. the improved plan is still valid, so the correction helped
      expect(errors(evolved), isEmpty, reason: 'round $round');

      // 6. the suggestions that drove the change are now resolved
      final after = PlannerSuggestionsService.forIntent(evolved);
      expect(
        after.any((s) => s.toLowerCase().contains('service role')),
        isFalse,
        reason: 'round $round',
      );
    }
  });

  test('no rule means no change: memory only fires when taught', () {
    final plan = NetworkIntent.parseSimple('evo', faultyBrief);
    final same = PlannerMemoryService.apply(plan);
    expect(same.routing, plan.routing);
    expect(
      same.nodes.firstWhere((n) => n.type == 'server').services,
      isEmpty,
    );
  });
}
