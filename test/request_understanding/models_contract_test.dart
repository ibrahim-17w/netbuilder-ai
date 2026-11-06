import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/plan_operation.dart';
import 'package:net_builder/models/request_coverage.dart';
import 'package:net_builder/models/request_interpretation.dart';
import 'package:net_builder/models/request_requirement.dart';

SourceSpan _span(String original, {int? end}) => SourceSpan.fromText(
  messageId: 'turn-1',
  originalText: original,
  start: 0,
  end: end ?? original.length,
);

PlanOperation _routingOperation({Map<String, Object?>? payload}) =>
    PlanOperation(
      operationId: 'op-routing',
      kind: PlanOperationKind.setRouting,
      requirementIds: const ['req-routing'],
      sourceSpans: [_span('use EIGRP')],
      projectId: 'P1',
      baseRevision: 'rev-1',
      scope: RequirementScope.project('P1'),
      payload: payload ?? const {'protocol': 'eigrp'},
    );

Requirement _routingRequirement({SourceSpan? span}) => Requirement(
  id: 'req-routing',
  subject: 'network',
  property: 'routing',
  value: 'eigrp',
  scope: RequirementScope.project('P1'),
  origin: RequirementOrigin.currentExplicit,
  sourceTurnId: 'turn-1',
  sourceSpans: span == null ? const [] : [span],
  strength: RequirementStrength.explicit,
  phase: RequirementPhase.planning,
);

void main() {
  group('source provenance', () {
    test('SourceSpan uses UTF-16 bounds and redacts secret excerpts', () {
      const original = '😀 use password: hunter2 for the lab';
      final span = _span(original);

      expect(span.start, 0);
      expect(span.end, original.length);
      expect(span.excerpt, contains(NetworkIntent.redacted));
      expect(span.excerpt, isNot(contains('hunter2')));
      expect(SourceSpan.fromJson(span.toJson()), span);
      expect(() => span.validateAgainst('short'), throwsFormatException);
      expect(
        () => SourceSpan.fromText(
          messageId: 'turn-1',
          originalText: original,
          start: 0,
          end: original.length + 1,
        ),
        throwsFormatException,
      );
    });

    test('Requirement round trip keeps typed fields and source span', () {
      final requirement = _routingRequirement(span: _span('use EIGRP'));
      final restored = Requirement.fromJson(
        jsonDecode(jsonEncode(requirement.toJson())),
      );

      expect(restored, requirement);
      expect(restored.origin, RequirementOrigin.currentExplicit);
      expect(restored.sourceSpans.single.excerpt, 'use EIGRP');
      expect(requirement.copyWith(property: 'routing'), requirement);
    });

    test('legacy requirement data has unknown rather than invented origin', () {
      final legacy = Requirement.fromJson({
        'id': 'legacy-routing',
        'subject': 'network',
        'property': 'routing',
        'value': 'ospf',
      });

      expect(legacy.origin, RequirementOrigin.unknown);
      expect(legacy.strength, RequirementStrength.advisory);
      expect(legacy.scope.kind, RequirementScopeKind.project);
      expect(legacy.sourceSpans, isEmpty);
    });
  });

  group('operations and change sets', () {
    test('closed operation and PlanChangeSet round trip', () {
      final operation = _routingOperation();
      final changeSet = PlanChangeSet(
        projectId: 'P1',
        baseRevision: 'rev-1',
        candidateRevision: 'rev-2',
        operations: [operation],
        oldValues: const {'routing': 'static'},
        newValues: const {'routing': 'eigrp'},
        reasons: const ['Current explicit request'],
      );
      final restored = PlanChangeSet.fromJson(
        jsonDecode(jsonEncode(changeSet.toJson())),
      );

      expect(restored, changeSet);
      expect(restored.operations.single, operation);
      expect(operation.copyWith(payload: const {'protocol': 'ospf'}).payload, {
        'protocol': 'ospf',
      });
      expect(
        () => operation.payload['protocol'] = 'ospf',
        throwsUnsupportedError,
      );
    });

    test('unknown operation fields and unsafe values fail closed', () {
      final unknownField = _routingOperation().toJson();
      (unknownField['payload'] as Map<String, dynamic>)['expression'] =
          'delete everything';
      expect(() => PlanOperation.fromJson(unknownField), throwsFormatException);

      final unknownKind = _routingOperation().toJson()..['kind'] = 'runCode';
      expect(() => PlanOperation.fromJson(unknownKind), throwsFormatException);

      expect(
        () => _routingOperation(payload: const {'protocol': 'rip'}),
        throwsFormatException,
      );
      expect(
        () => PlanOperation(
          operationId: 'op-dhcp',
          kind: PlanOperationKind.assignService,
          requirementIds: const ['req-dhcp'],
          projectId: 'P1',
          baseRevision: 'rev-1',
          scope: RequirementScope.project('P1'),
          payload: const {
            'deviceId': 'SRV1',
            'service': 'dhcp',
            'settings': {'password': 'hunter2'},
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('request interpretation and outcomes', () {
    test('interpretation and outcome round trip as one typed result', () {
      final operation = _routingOperation();
      final requirement = _routingRequirement(span: _span('use EIGRP'));
      final interpretation = RequestInterpretation(
        turnId: 'turn-1',
        conversationId: 'chat-1',
        projectId: 'P1',
        basePlanRevision: 'rev-1',
        mode: RequestMode.edit,
        requirements: [requirement],
        operations: [operation],
        pendingQuestions: [
          PendingRequestQuestion(
            id: 'q-routing',
            targetKind: PendingQuestionTargetKind.requirement,
            targetId: 'req-routing',
            prompt: 'Which routing protocol?',
          ),
        ],
        requestedActions: [
          RequestedAction(
            id: 'build-1',
            kind: RequestedActionKind.build,
            target: 'P1',
            dependsOn: ['op-routing'],
            outputOptions: {'format': 'pkt'},
          ),
        ],
        responsePreferences: const ResponsePreferences(
          language: 'en',
          brevity: ResponseBrevity.concise,
          format: ResponseFormat.markdown,
        ),
        reliability: const {ReliabilityLabel.exactExtraction},
        mutationPolicy: MutationPolicy.commitIfValid,
      );
      final coverage = CoverageReport(
        requirements: [
          RequirementCoverage(
            requirementId: 'req-routing',
            planning: PlanningStatus.satisfied,
            delivery: DeliveryStatus.unverified,
            evidence: [
              RequirementEvidence(
                requirementId: 'req-routing',
                planRevision: 'rev-2',
                target: 'P1',
                phase: RequirementPhase.planning,
                measuredValue: 'eigrp',
                checker: 'plan comparison',
                checkedAt: '2026-11-03T12:00:00Z',
                explanation: 'The candidate plan uses EIGRP.',
              ),
            ],
          ),
        ],
      );
      final outcome = RequestOutcome(
        interpretation: interpretation,
        candidatePlan: NetworkIntent.parseSimple('P1', '2 routers use EIGRP'),
        changeSet: PlanChangeSet(
          projectId: 'P1',
          baseRevision: 'rev-1',
          candidateRevision: 'rev-2',
          operations: [operation],
        ),
        coverage: coverage,
        disposition: RequestDisposition.commit,
      );

      final restored = RequestOutcome.fromJson(
        jsonDecode(jsonEncode(outcome.toJson())),
      );
      expect(restored.interpretation, interpretation);
      expect(restored.changeSet, outcome.changeSet);
      expect(restored.coverage, coverage);
      expect(restored.disposition, RequestDisposition.commit);
      expect(restored.candidatePlan?.projectName, 'P1');
    });

    test('legacy and future interpretation versions decode safely', () {
      final legacy = RequestInterpretation.fromJson({'turnId': 'old-turn'});

      expect(legacy.turnId, 'old-turn');
      expect(legacy.mode, RequestMode.unknown);
      expect(legacy.mutationPolicy, MutationPolicy.none);
      expect(legacy.requirements, isEmpty);
      expect(legacy.reliability, {ReliabilityLabel.unresolved});
      expect(
        () => RequestInterpretation.fromJson({'schemaVersion': 2}),
        throwsFormatException,
      );
      expect(
        () => RequestInterpretation.fromJson({
          'schemaVersion': 1,
          'mode': 'arbitraryCommand',
        }),
        throwsFormatException,
      );
      expect(
        () => RequestInterpretation.fromJson({
          'schemaVersion': 1,
          'unauthorizedField': true,
        }),
        throwsFormatException,
      );
    });

    test('unresolved request text and spans redact secrets', () {
      final original = 'Use password: hunter2 in this request';
      final fragment = UnresolvedFragment(
        id: 'fragment-1',
        text: original,
        sourceSpans: [_span(original)],
      );
      final json = jsonEncode(fragment.toJson());

      expect(json, isNot(contains('hunter2')));
      expect(json, contains(NetworkIntent.redacted));
    });
  });
}
