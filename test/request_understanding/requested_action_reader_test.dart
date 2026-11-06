import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/request_interpretation.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/services/request_understanding/request_coordinator.dart';
import 'package:net_builder/services/request_understanding/requested_action_reader.dart';
import 'package:net_builder/services/session_state.dart';

import 'fixtures.dart';

void main() {
  test('reads build and configuration outputs in the order requested', () {
    final actions = RequestedActionReader.read(
      text: 'change to OSPF, build the .pkt, and export the configurations',
      turnId: 'turn-1',
    );

    expect(actions.map((action) => action.kind), [
      RequestedActionKind.build,
      RequestedActionKind.exportConfiguration,
    ]);
    expect(actions.map((action) => action.id).toSet(), hasLength(2));
  });

  test(
    'resolves a pronoun build request for the coordinator to bind safely',
    () {
      final actions = RequestedActionReader.read(
        text: 'build it',
        turnId: 'turn-pronoun-build',
      );

      expect(actions, hasLength(1));
      expect(actions.single.kind, RequestedActionKind.build);
    },
  );

  test('does not turn questions, hypotheticals, or negation into outputs', () {
    for (final text in [
      'how do I build the .pkt?',
      'do not build the .pkt',
      'what if we export the configurations?',
    ]) {
      expect(
        RequestedActionReader.read(text: text, turnId: 'turn-1'),
        isEmpty,
        reason: text,
      );
    }
  });

  test('output-only request stays bound to the current plan', () {
    final base = basePlan();
    final outcome = RequestCoordinator.coordinate(
      text: 'export the configurations only, no explanation',
      turnId: 'turn-2',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'packet-tracer',
      base: base,
      legacyCandidate: base,
      legacyBrief: 'export the configurations only, no explanation',
      baseBrief: 'the standing lab plan',
    );

    expect(outcome.isBlocked, isFalse);
    expect(outcome.disposition, RequestDisposition.answerOnly);
    expect(outcome.candidate!.revision, base.revision);
    expect(outcome.brief, 'the standing lab plan');
    expect(
      outcome.interpretation.requestedActions.single.kind,
      RequestedActionKind.exportConfiguration,
    );
  });

  test('A29 build it preserves the committed plan and its requirements', () {
    final base = basePlan();
    final routing = Requirement(
      id: 'req-static-routing',
      subject: 'routing',
      property: 'protocol',
      value: 'static',
      scope: RequirementScope.project('P1'),
      origin: RequirementOrigin.establishedProject,
      sourceTurnId: 'base-turn',
      strength: RequirementStrength.explicit,
    );
    final outcome = RequestCoordinator.coordinate(
      text: 'build it',
      turnId: 'turn-build',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'packet-tracer',
      base: base,
      legacyCandidate: base,
      legacyBrief: 'build the saved lab',
      baseBrief: '2 routers, 2 switches, 10 PCs; use static routing',
      existingRequirements: [routing],
    );

    expect(outcome.isBlocked, isFalse);
    expect(outcome.disposition, RequestDisposition.answerOnly);
    expect(outcome.candidate?.revision, base.revision);
    expect(semanticSnapshot(outcome.candidate!), semanticSnapshot(base));
    expect(outcome.interpretation.requestedActions, hasLength(1));
    expect(
      outcome.interpretation.requestedActions.single.kind,
      RequestedActionKind.build,
    );
    expect(outcome.interpretation.requirements, [routing]);
    expect(
      outcome.candidate!.nodes.where((node) => node.exactModel),
      hasLength(4),
      reason: 'the build outcome retains the selected router and switch models',
    );
  });

  test('output request without a plan is held instead of using a default', () {
    final outcome = RequestCoordinator.coordinate(
      text: 'export the configurations only, no explanation',
      turnId: 'turn-3',
      conversationId: 'P3',
      projectId: 'P3',
      target: 'packet-tracer',
      base: null,
      legacyCandidate: NetworkIntent(projectName: 'P3'),
      legacyBrief: 'export the configurations only, no explanation',
    );

    expect(outcome.isBlocked, isTrue);
    expect(outcome.candidate, isNull);
    expect(
      outcome.interpretation.issues.single.code,
      'no_plan_for_requested_output',
    );
  });

  test('a polite direct device addition commits against the standing plan', () {
    const text = 'can you add 2 PCs?';
    const brief = '2 routers, 2 switches, 10 PCs; use static routing';
    final base = basePlan();
    final parsed = NetworkIntent.parseSimple('P1', text);
    final legacy = NetworkIntent.followUp(
      previous: base,
      previousBrief: brief,
      brief: text,
      parsed: parsed,
      project: 'P1',
    );
    final outcome = RequestCoordinator.coordinate(
      text: text,
      turnId: 'turn-4',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'packet-tracer',
      base: base,
      legacyCandidate: legacy.plan,
      legacyBrief: legacy.brief,
      baseBrief: brief,
    );
    expect(
      outcome.isBlocked,
      isFalse,
      reason: outcome.interpretation.issues
          .map((issue) => '${issue.code}: ${issue.message}')
          .join('\n'),
    );
    final candidate = outcome.candidate!;
    expect(candidate.nodes.where((node) => node.type == 'pc'), hasLength(12));
    expect(candidate.routing, 'static');
    expect(candidate.nodes.map((node) => node.name), contains('PC10'));
    for (final old in base.nodes) {
      expect(
        candidate.nodes
            .where((node) => node.name == old.name)
            .single
            .toJson(includeSecrets: false),
        old.toJson(includeSecrets: false),
      );
    }
    expect(
      candidate.links.map((link) => link.toJson()),
      containsAll(base.links.map((link) => link.toJson())),
    );
    expect(
      candidate.addressing.map((address) => address.toJson()),
      containsAll(base.addressing.map((address) => address.toJson())),
    );

    // The same result that provider context and local fallback receive is
    // serialized as the versioned RequestOutcome contract. Reopening restores
    // both that result and the standing plan from one matching revision.
    final storedState = SessionState()
      ..requestOutcomeJson = outcome.encode()
      ..intentJson = jsonEncode(candidate.toJson(includeSecrets: false))
      ..lastBrief = outcome.brief;
    final reopened = SessionState.decode(storedState.encode());
    final restoredOutcome = RequestOutcome.fromJson(
      jsonDecode(reopened.requestOutcomeJson),
    );
    final restoredPlan = NetworkIntent.fromJson(
      Map<String, dynamic>.from(jsonDecode(reopened.intentJson) as Map),
    );

    expect(restoredOutcome, outcome.requestOutcome);
    expect(restoredOutcome.disposition, RequestDisposition.commit);
    expect(restoredOutcome.candidatePlan?.revision, restoredPlan.revision);
    expect(reopened.lastBrief, outcome.brief);
  });
}
