import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:net_builder/services/request_understanding/requirement_merger.dart';

import 'fixtures.dart';

Requirement _routing({
  required String id,
  required String value,
  required RequirementOrigin origin,
  RequirementStrength strength = RequirementStrength.explicit,
  String turn = '',
  String? supersedesId,
  String project = 'P1',
}) => Requirement(
  id: id,
  subject: 'network',
  property: 'routing',
  value: value,
  scope: RequirementScope.project(project),
  origin: origin,
  strength: strength,
  sourceTurnId: turn,
  supersedesId: supersedesId,
  sourceSpans: [
    SourceSpan(
      messageId: turn.isEmpty ? id : turn,
      start: 0,
      end: value.length,
      excerpt: 'use $value',
    ),
  ],
);

void main() {
  test('current explicit choices outrank scoped memory deterministically', () {
    final explicit = _routing(
      id: 'req-current',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-2',
    );
    final remembered = _routing(
      id: 'req-memory',
      value: 'ospf',
      origin: RequirementOrigin.scopedRememberedPreference,
      strength: RequirementStrength.advisory,
    );

    final forward = RequirementMerger.merge([explicit, remembered]);
    final reversed = RequirementMerger.merge([remembered, explicit]);

    expect(forward.active, [explicit]);
    expect(
      forward.requirements.singleWhere((item) => item.id == 'req-memory').state,
      RequirementState.superseded,
    );
    expect(reversed.requirements, forward.requirements);
    expect(forward.conflicts, isEmpty);
    final brief = forward.applyToBrief(const DesignBrief());
    expect(brief.value(DesignBrief.routing), 'eigrp');
    expect(brief.fact(DesignBrief.routing)?.origin, BriefSource.user);
  });

  test('incompatible current same-turn choices remain unresolved', () {
    final result = RequirementMerger.merge([
      _routing(
        id: 'req-ospf',
        value: 'ospf',
        origin: RequirementOrigin.currentExplicit,
        turn: 'turn-3',
      ),
      _routing(
        id: 'req-eigrp',
        value: 'eigrp',
        origin: RequirementOrigin.currentExplicit,
        turn: 'turn-3',
      ),
    ]);

    expect(result.active, isEmpty);
    expect(result.unresolved.map((item) => item.id), ['req-eigrp', 'req-ospf']);
    expect(result.conflicts, hasLength(1));
    expect(result.conflicts.single.reason, contains('req-eigrp="eigrp"'));
    expect(result.conflicts.single.sourceExcerpts, contains('use ospf'));
    expect(result.conflicts.single.sourceExcerpts, contains('use eigrp'));
  });

  test('a clear correction supersedes the named earlier requirement', () {
    final previous = _routing(
      id: 'req-old',
      value: 'ospf',
      origin: RequirementOrigin.establishedProject,
      turn: 'turn-1',
    );
    final correction = _routing(
      id: 'req-new',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-2',
      supersedesId: 'req-old',
    );
    final result = RequirementMerger.merge([previous, correction]);

    expect(result.active, [correction]);
    expect(
      result.requirements.singleWhere((item) => item.id == 'req-old').state,
      RequirementState.superseded,
    );
    expect(result.conflicts, isEmpty);
  });

  test('correction cycles become visible unresolved conflicts', () {
    final first = _routing(
      id: 'req-first',
      value: 'ospf',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-cycle',
      supersedesId: 'req-second',
    );
    final second = _routing(
      id: 'req-second',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-cycle',
      supersedesId: 'req-first',
    );
    final result = RequirementMerger.merge([first, second]);

    expect(result.active, isEmpty);
    expect(result.unresolved.map((item) => item.id), [
      'req-first',
      'req-second',
    ]);
    expect(result.conflicts.single.reason, contains('contains a cycle'));
  });

  test('equal value from different origins is represented once', () {
    final established = _routing(
      id: 'req-established',
      value: 'eigrp',
      origin: RequirementOrigin.establishedProject,
      turn: 'turn-1',
    );
    final current = _routing(
      id: 'req-current',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-2',
    );
    final result = RequirementMerger.merge([established, current]);

    expect(result.active, [current]);
    expect(
      result.requirements
          .singleWhere((item) => item.id == 'req-established')
          .state,
      RequirementState.superseded,
    );
    expect(result.conflicts, isEmpty);
  });

  test('a forbidden value conflicts with the same explicit selection', () {
    final selected = _routing(
      id: 'req-select',
      value: 'ospf',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-contradiction',
    );
    final forbidden = selected.copyWith(
      id: 'req-forbid',
      comparator: RequirementComparator.forbidden,
    );
    final result = RequirementMerger.merge([selected, forbidden]);

    expect(result.active, isEmpty);
    expect(result.unresolved, hasLength(2));
    expect(result.conflicts, hasLength(1));
  });

  test('identical requirements merge idempotently with stable history', () {
    final requirement = _routing(
      id: 'req-eigrp',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-4',
    );
    final once = RequirementMerger.merge([requirement, requirement]);
    final twice = RequirementMerger.merge(once.requirements);

    expect(once.requirements, [requirement]);
    expect(twice.requirements, once.requirements);
    expect(twice.conflicts, once.conflicts);
  });

  test('scope keys allow different device and project choices to coexist', () {
    final r1 = Requirement(
      id: 'r1-model',
      subject: 'router',
      property: 'model',
      value: '2911',
      scope: const RequirementScope(
        kind: RequirementScopeKind.device,
        scopeId: 'R1',
      ),
      origin: RequirementOrigin.currentExplicit,
      strength: RequirementStrength.explicit,
      sourceTurnId: 'turn-1',
    );
    final r2 = r1.copyWith(
      id: 'r2-model',
      value: '4331',
      scope: const RequirementScope(
        kind: RequirementScopeKind.device,
        scopeId: 'R2',
      ),
    );
    final p2 = _routing(
      id: 'p2-routing',
      value: 'ospf',
      origin: RequirementOrigin.currentExplicit,
      project: 'P2',
      turn: 'turn-2',
    );
    final result = RequirementMerger.merge([r1, r2, p2]);

    expect(result.active, hasLength(3));
    expect(result.conflicts, isEmpty);
  });

  test('compatible quantity bounds coexist and impossible bounds conflict', () {
    final minimum = Requirement(
      id: 'min-5',
      subject: 'pc',
      property: 'deviceCount',
      value: 5,
      comparator: RequirementComparator.atLeast,
      scope: RequirementScope.project('P1'),
      origin: RequirementOrigin.currentExplicit,
      strength: RequirementStrength.explicit,
      quantityRole: QuantityRole.minimum,
      unit: 'devices',
      sourceTurnId: 'turn-1',
    );
    final maximum = minimum.copyWith(
      id: 'max-10',
      value: 10,
      comparator: RequirementComparator.atMost,
      quantityRole: QuantityRole.maximum,
    );
    expect(RequirementMerger.merge([minimum, maximum]).conflicts, isEmpty);

    final impossible = maximum.copyWith(
      id: 'max-4',
      value: 4,
      quantityRole: QuantityRole.maximum,
    );
    final conflict = RequirementMerger.merge([minimum, impossible]);
    expect(conflict.conflicts, hasLength(1));
    expect(conflict.unresolved, hasLength(2));
  });

  test('merged explicit requirements protect planner memory fields', () {
    final explicit = _routing(
      id: 'req-eigrp',
      value: 'eigrp',
      origin: RequirementOrigin.currentExplicit,
      turn: 'turn-5',
    );
    final merge = RequirementMerger.merge([explicit]);
    final parsed = NetworkIntent.parseSimple(
      'P1',
      '2 routers, 2 switches, 4 PCs',
    ).copyWith(routing: 'eigrp');
    final result = PlannerMemoryService.apply(
      parsed,
      preferences: const {'routing': 'ospf'},
      requirementProtection: merge.memoryProtection,
    );

    expect(merge.memoryProtection.protectedFields, contains('routing'));
    expect(result.routing, 'eigrp');
  });

  test(
    'device-scoped model protection leaves other routers open to memory',
    () {
      final r1Model = Requirement(
        id: 'r1-model',
        subject: 'router',
        property: 'model',
        value: '2911',
        scope: const RequirementScope(
          kind: RequirementScopeKind.device,
          scopeId: 'R1',
        ),
        origin: RequirementOrigin.currentExplicit,
        strength: RequirementStrength.explicit,
        sourceTurnId: 'turn-model',
      );
      final merge = RequirementMerger.merge([r1Model]);
      final result = PlannerMemoryService.apply(
        basePlan(),
        preferences: const {'router_model': '4331'},
        requirementProtection: merge.memoryProtection,
      );

      expect(
        result.nodes.firstWhere((node) => node.name == 'R1').model,
        '2911',
      );
      expect(
        result.nodes.firstWhere((node) => node.name == 'R2').model,
        '4331',
      );
    },
  );

  test('device-scoped subnet protection leaves other LANs open to memory', () {
    final r1Subnet = Requirement(
      id: 'r1-subnet',
      subject: 'router',
      property: 'subnet',
      value: '192.168.10.0/24',
      scope: const RequirementScope(
        kind: RequirementScopeKind.device,
        scopeId: 'R1',
      ),
      origin: RequirementOrigin.currentExplicit,
      strength: RequirementStrength.explicit,
      sourceTurnId: 'turn-subnet',
    );
    final merge = RequirementMerger.merge([r1Subnet]);
    final result = PlannerMemoryService.apply(
      basePlan(),
      preferences: const {'base_subnet': '10.88.0.0/24'},
      requirementProtection: merge.memoryProtection,
    );

    expect(
      result.addressing
          .firstWhere(
            (address) => address.node == 'R1' && address.iface == 'g0/0',
          )
          .ipCidr,
      '192.168.10.1/24',
    );
    expect(
      result.addressing
          .firstWhere(
            (address) => address.node == 'R2' && address.iface == 'g0/0',
          )
          .ipCidr,
      '10.88.20.1/24',
    );
  });

  test('an explicit DNS exclusion blocks a remembered service addition', () {
    final excludedDns = Requirement(
      id: 'dns-excluded',
      subject: 'service',
      property: 'excluded_service',
      value: 'dns',
      comparator: RequirementComparator.forbidden,
      scope: RequirementScope.project('P1'),
      origin: RequirementOrigin.currentExplicit,
      strength: RequirementStrength.explicit,
      sourceTurnId: 'turn-dns',
    );
    final merge = RequirementMerger.merge([excludedDns]);
    final result = PlannerMemoryService.apply(
      basePlan(),
      rules: const ['always add a DNS server'],
      requirementProtection: merge.memoryProtection,
    );

    expect(
      merge.memoryProtection.protectedFields,
      containsAll(['dns_excluded', 'add_dns']),
    );
    expect(
      result.nodes.where((node) => node.services.contains('dns')),
      isEmpty,
    );
  });
}
