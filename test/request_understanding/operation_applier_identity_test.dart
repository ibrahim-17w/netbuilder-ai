import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/plan_operation.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/services/request_understanding/operation_applier.dart';

import 'fixtures.dart';

void main() {
  test(
    'A44 an operation from another project is rejected without a commit',
    () {
      final base = basePlan(project: 'P1');
      final stale = PlanOperation(
        operationId: 'cached-project-proposal',
        kind: PlanOperationKind.setRouting,
        requirementIds: const ['req-routing'],
        projectId: 'P2',
        baseRevision: base.revision,
        scope: RequirementScope.project('P2'),
        payload: const {'protocol': 'ospf'},
      );

      final result = OperationApplier.apply(
        base: base,
        projectId: 'P1',
        baseRevision: base.revision,
        operations: [stale],
        target: 'packet-tracer',
      );

      expect(result.canCommit, isFalse);
      expect(result.candidate, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('stale_operation_identity'),
      );
      expect(base.routing, 'static', reason: 'the committed plan is immutable');
    },
  );

  test('A44 an operation for an old revision cannot commit', () {
    final base = basePlan(project: 'P1');
    final staleRevision = '${base.revision}-old';
    final stale = PlanOperation(
      operationId: 'cached-old-revision-proposal',
      kind: PlanOperationKind.setRouting,
      requirementIds: const ['req-routing'],
      projectId: 'P1',
      baseRevision: staleRevision,
      scope: RequirementScope.project('P1'),
      payload: const {'protocol': 'ospf'},
    );

    final result = OperationApplier.apply(
      base: base,
      projectId: 'P1',
      baseRevision: staleRevision,
      operations: [stale],
      target: 'packet-tracer',
    );

    expect(result.canCommit, isFalse);
    expect(result.candidate, isNull);
    expect(
      result.issues.map((issue) => issue.code),
      contains('stale_base_revision'),
    );
    expect(base.routing, 'static', reason: 'the committed plan is immutable');
  });
}
