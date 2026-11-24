import 'dart:ui' show Offset;
import 'dart:convert';

import '../../models/network_intent.dart';
import '../../models/plan_operation.dart';
import '../../models/request_contract_utils.dart';
import '../../models/request_coverage.dart';
import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import 'normalizer.dart';
import 'model_proposal_service.dart';
import '../human_language.dart';
import 'coverage_checker.dart';
import 'operation_applier.dart';
import 'requirement_merger.dart';
import 'requirement_validator.dart';
import '../validator_service.dart';
import '../network_tools.dart';
import '../packet_tracer/catalog.dart';
import '../topology_edit_service.dart';

enum CoordinatedRequestRoute { answerOnly, legacyPlan, typedMutation, blocked }

/// The single plan decision for a turn. [requestOutcome] is the canonical
/// typed envelope; [toJson] stores its redacted candidate beside the session's
/// standing-plan snapshot without storing raw user text or credentials.
class RequestCoordinatorOutcome {
  final RequestInterpretation interpretation;
  final RequirementMergeResult merge;
  final NetworkIntent? candidate;
  final PlanChangeSet? changeSet;
  final RequestDisposition disposition;
  final CoordinatedRequestRoute route;
  final String brief;
  final CoverageReport coverage;

  RequestCoordinatorOutcome({
    required this.interpretation,
    required this.merge,
    required this.candidate,
    required this.changeSet,
    required this.disposition,
    required this.route,
    required this.brief,
    required String target,
    NetworkIntent? base,
    CoverageReport? coverage,
  }) : coverage =
           coverage ??
           CoverageChecker.check(
             plan: candidate,
             requirements: interpretation.requirements,
             target: target,
             base: base,
           );

  bool get isBlocked => route == CoordinatedRequestRoute.blocked;

  /// The canonical result shared with provider context, local fallback and
  /// persisted session state. The plan snapshot is stored both here and in
  /// SessionState.intentJson so reopen can verify they describe one revision.
  RequestOutcome get requestOutcome => RequestOutcome(
    interpretation: interpretation,
    candidatePlan: candidate,
    changeSet: changeSet,
    coverage: coverage,
    clarifications: interpretation.issues,
    requestedActions: interpretation.requestedActions,
    disposition: disposition,
  );

  Map<String, dynamic> toJson() => requestOutcome.toJson();

  String encode() => jsonEncode(toJson());
}

/// Coordinates the deterministic interpretation, precedence merge, plan
/// candidate and one disposition. It is UI-independent so chat, offline
/// fallback and future provider paths can use the same result.
class RequestCoordinator {
  const RequestCoordinator._();

  /// Revalidate a provider proposal at the commit boundary. Its schema result
  /// never bypasses deterministic application, preservation, or coverage.
  static RequestCoordinatorOutcome acceptProposal({
    required RequestCoordinatorOutcome local,
    required ProposalResult proposal,
    required NetworkIntent base,
    required String target,
  }) {
    final interpretation = proposal.interpretation;
    if (interpretation == null ||
        interpretation.projectId != local.interpretation.projectId ||
        interpretation.turnId != local.interpretation.turnId ||
        interpretation.basePlanRevision != base.revision ||
        interpretation.issues.isNotEmpty ||
        interpretation.unresolvedFragments.isNotEmpty) {
      return local;
    }
    final applied = OperationApplier.apply(
      base: base,
      baseRevision: base.revision,
      projectId: interpretation.projectId,
      operations: interpretation.operations,
      target: target,
    );
    if (!applied.canCommit) return local;
    final requirements = RequirementMerger.bindToBase(
      requirements: interpretation.requirements,
      base: base,
      operations: interpretation.operations,
    );
    final merge = RequirementMerger.merge(
      RequirementMerger.rebindAcceptedRenames(
        requirements: requirements,
        operations: interpretation.operations,
      ),
    );
    if (merge.conflicts.isNotEmpty) return local;
    return RequestCoordinatorOutcome(
      interpretation: interpretation.copyWith(requirements: merge.requirements),
      merge: merge,
      candidate: applied.candidate,
      changeSet: applied.changeSet,
      disposition: RequestDisposition.commit,
      route: CoordinatedRequestRoute.typedMutation,
      brief: local.brief,
      target: target,
      base: base,
    );
  }

  static RequestCoordinatorOutcome coordinate({
    required String text,
    required String turnId,
    required String conversationId,
    required String projectId,
    required String target,
    required NetworkIntent? base,
    required NetworkIntent? legacyCandidate,
    required String legacyBrief,
    String? baseBrief,
    Iterable<Requirement> existingRequirements = const [],
    Iterable<PendingRequestQuestion> existingPendingQuestions = const [],
    String messageId = 'current-message',
  }) {
    final identityRevision = base?.revision ?? legacyCandidate?.revision ?? '';
    var interpretation = RequestInterpretationAdapter.adapt(
      originalText: text,
      projectName: legacyCandidate?.projectName ?? base?.projectName ?? '',
      turnId: turnId,
      conversationId: conversationId,
      projectId: projectId,
      basePlanRevision: identityRevision,
      messageId: messageId,
    );

    if (const {
      RequestMode.social,
      RequestMode.explain,
      RequestMode.advise,
      RequestMode.compare,
      RequestMode.explore,
    }.contains(interpretation.mode)) {
      final merge = RequirementMergeResult(
        requirements: existingRequirements.toList(),
        conflicts: const [],
      );
      return RequestCoordinatorOutcome(
        interpretation: interpretation.copyWith(
          requirements: merge.requirements,
          operations: const [],
          issues: const [],
          unresolvedFragments: const [],
          pendingQuestions: existingPendingQuestions.toList(),
          mutationPolicy: MutationPolicy.none,
        ),
        merge: merge,
        candidate: base,
        changeSet: null,
        disposition: RequestDisposition.answerOnly,
        route: CoordinatedRequestRoute.answerOnly,
        brief: baseBrief ?? legacyBrief,
        target: target,
        base: base,
      );
    }
    final confirmationTargets = existingPendingQuestions
        .where(
          (question) =>
              question.targetKind == PendingQuestionTargetKind.requirement,
        )
        .map((question) => question.targetId)
        .toSet();
    final confirmed = <String>{};
    final currentFacts = interpretation.requirements.map((fact) {
      final matches = existingRequirements
          .where(
            (prior) =>
                confirmationTargets.contains(prior.id) &&
                prior.origin == RequirementOrigin.imported &&
                prior.state == RequirementState.unresolved &&
                prior.property == fact.property &&
                prior.subject == fact.subject &&
                prior.scope == fact.scope &&
                fact.origin == RequirementOrigin.currentExplicit &&
                fact.state == RequirementState.active &&
                fact.value != null,
          )
          .toList();
      if (matches.length != 1) return fact;
      confirmed.add(matches.single.id);
      return fact.copyWith(supersedesId: matches.single.id);
    }).toList();
    interpretation = interpretation.copyWith(
      pendingQuestions: [
        ...existingPendingQuestions.where(
          (question) =>
              !confirmed.contains(question.targetId) &&
              question.targetId != 'attachment-action' &&
              !question.targetId.endsWith('-incomplete'),
        ),
        ...interpretation.pendingQuestions,
      ],
      requirements: RequirementMerger.bindToBase(
        requirements: currentFacts,
        base: base,
        operations: interpretation.operations,
      ),
    );
    final priorRequirements = [
      for (final requirement in existingRequirements)
        requirement.origin == RequirementOrigin.currentExplicit &&
                requirement.state == RequirementState.active
            ? requirement.copyWith(origin: RequirementOrigin.establishedProject)
            : requirement,
    ];
    RequirementMergeResult merge;
    try {
      merge = RequirementMerger.merge([
        ...priorRequirements,
        ...interpretation.requirements,
      ]);
    } on FormatException catch (error) {
      final uniqueRequirements = <String, Requirement>{};
      for (final requirement in [
        ...priorRequirements,
        ...interpretation.requirements,
      ]) {
        uniqueRequirements.putIfAbsent(requirement.id, () => requirement);
      }
      final issue = RequestIssue(
        id: 'request-$turnId-requirement-history',
        kind: RequestIssueKind.conflict,
        code: 'requirement_history_conflict',
        message: error.message.toString(),
      );
      final emptyMerge = RequirementMergeResult(
        requirements: uniqueRequirements.values.toList(),
        conflicts: const [],
      );
      interpretation = interpretation.copyWith(
        requirements: emptyMerge.requirements,
        issues: [issue],
      );
      return RequestCoordinatorOutcome(
        target: target,
        base: base,
        interpretation: interpretation,
        merge: emptyMerge,
        candidate: null,
        changeSet: null,
        disposition: RequestDisposition.ask,
        route: CoordinatedRequestRoute.blocked,
        brief: legacyBrief,
      );
    }

    final issues = <RequestIssue>[
      ...interpretation.issues,
      ...const RequirementValidator()
          .validate(merge.active)
          .where(
            (issue) => !interpretation.issues.any(
              (existing) => existing.requirementIds.toSet().containsAll(
                issue.requirementIds,
              ),
            ),
          ),
      for (var index = 0; index < merge.conflicts.length; index++)
        _conflictIssue(
          merge.conflicts[index],
          merge.requirements,
          turnId,
          index,
        ),
    ];
    if (issues.isNotEmpty) {
      interpretation = interpretation.copyWith(
        requirements: merge.requirements,
        issues: issues,
      );
      return RequestCoordinatorOutcome(
        target: target,
        base: base,
        interpretation: interpretation,
        merge: merge,
        candidate: null,
        changeSet: null,
        disposition: RequestDisposition.ask,
        route: CoordinatedRequestRoute.blocked,
        brief: legacyBrief,
      );
    }

    final actionOnly =
        interpretation.requestedActions.isNotEmpty &&
        interpretation.operations.isEmpty &&
        interpretation.requirements.isEmpty;
    final hasExplicitTopology = merge.requirements.any(
      (requirement) =>
          requirement.origin == RequirementOrigin.currentExplicit &&
          requirement.comparator != RequirementComparator.forbidden &&
          const {
            'device_count',
            'device_name',
            'device_model',
            'router_model',
            'switch_model',
          }.contains(requirement.property),
    );
    if (interpretation.requestedActions.isNotEmpty &&
        base == null &&
        !hasExplicitTopology) {
      final issue = RequestIssue(
        id: 'request-$turnId-output-needs-plan',
        kind: RequestIssueKind.missingInput,
        code: 'no_plan_for_requested_output',
        message:
            'There is no saved network plan or explicit device inventory to use for this output. Describe the network first or open the conversation that contains its plan.',
      );
      interpretation = interpretation.copyWith(issues: [issue]);
      return RequestCoordinatorOutcome(
        target: target,
        base: base,
        interpretation: interpretation,
        merge: merge,
        candidate: null,
        changeSet: null,
        disposition: RequestDisposition.ask,
        route: CoordinatedRequestRoute.blocked,
        brief: legacyBrief,
      );
    }

    if (actionOnly && base != null) {
      interpretation = interpretation.copyWith(
        requirements: merge.requirements,
        mutationPolicy: MutationPolicy.none,
      );
      return RequestCoordinatorOutcome(
        target: target,
        base: base,
        interpretation: interpretation,
        merge: merge,
        candidate: base,
        changeSet: null,
        disposition: RequestDisposition.answerOnly,
        route: CoordinatedRequestRoute.answerOnly,
        brief: baseBrief ?? legacyBrief,
      );
    }

    if (interpretation.operations.isNotEmpty && base != null) {
      final replacingRouting =
          interpretation.operations.any(
            (operation) => operation.kind == PlanOperationKind.setRouting,
          ) &&
          RegExp(
            r'\b(?:replace|substitute|swap)\b|(?:بدل|بدّل|استبدل)',
            caseSensitive: false,
          ).hasMatch(text);
      final replacedProtocol = interpretation.requirements
          .where(
            (requirement) =>
                requirement.property == 'routing_protocol' &&
                requirement.comparator == RequirementComparator.forbidden &&
                requirement.value is String,
          )
          .firstOrNull;
      if (replacingRouting &&
          replacedProtocol != null &&
          base.routing.toLowerCase() !=
              (replacedProtocol.value as String).toLowerCase()) {
        final issue = RequestIssue(
          id: 'request-$turnId-routing-replacement-base',
          kind: RequestIssueKind.conflict,
          code: 'routing_replacement_source_missing',
          message:
              'The saved plan uses ${base.routing}, not ${replacedProtocol.value}. Confirm whether to replace the current protocol; no part of this edit was applied.',
          requirementIds: [replacedProtocol.id],
          sourceSpans: replacedProtocol.sourceSpans,
        );
        return RequestCoordinatorOutcome(
          target: target,
          base: base,
          interpretation: interpretation.copyWith(
            requirements: merge.requirements,
            issues: [issue],
          ),
          merge: merge,
          candidate: null,
          changeSet: null,
          disposition: RequestDisposition.ask,
          route: CoordinatedRequestRoute.blocked,
          brief: legacyBrief,
        );
      }
      final applied = OperationApplier.apply(
        base: base,
        projectId: projectId,
        baseRevision: identityRevision,
        operations: interpretation.operations,
        target: target,
      );
      if (!applied.canCommit) {
        final supplemented = _supplementValidatedAdditions(
          base: base,
          typedCandidate: applied.heldCandidate,
          legacyCandidate: legacyCandidate,
          operations: interpretation.operations,
          target: target,
          issues: applied.issues,
        );
        if (supplemented != null) {
          final candidate = supplemented.candidate;
          final changeSet = PlanChangeSet(
            projectId: projectId,
            baseRevision: identityRevision,
            candidateRevision: candidate.revision,
            operations: interpretation.operations,
            oldValues: {'plan': base.toJson(includeSecrets: false)},
            newValues: {'plan': candidate.toJson(includeSecrets: false)},
            incidentalChanges: supplemented.incidentalChanges,
            reasons: [
              for (final operation in interpretation.operations)
                operation.kind.name,
            ],
          );
          interpretation = interpretation.copyWith(
            requirements: merge.requirements,
            mutationPolicy: MutationPolicy.commitIfValid,
          );
          return RequestCoordinatorOutcome(
            target: target,
            base: base,
            interpretation: interpretation,
            merge: merge,
            candidate: candidate,
            changeSet: changeSet,
            disposition: RequestDisposition.commit,
            route: CoordinatedRequestRoute.typedMutation,
            brief: legacyBrief,
          );
        }
        final capacityIssue = _routerTotalCapacityIssue(
          base: base,
          operations: interpretation.operations,
          applicationIssues: applied.issues,
          turnId: turnId,
        );
        interpretation = interpretation.copyWith(
          requirements: merge.requirements,
          issues: capacityIssue == null ? applied.issues : [capacityIssue],
        );
        return RequestCoordinatorOutcome(
          target: target,
          base: base,
          interpretation: interpretation,
          merge: merge,
          candidate: null,
          changeSet: null,
          disposition: RequestDisposition.ask,
          route: CoordinatedRequestRoute.blocked,
          brief: legacyBrief,
        );
      }

      // The typed patch and the established reader must agree on the semantic
      // network before this first integration can become authoritative. This
      // prevents a partially interpreted turn from dropping another clause.
      if (legacyCandidate != null &&
          applied.candidate!.revision != legacyCandidate.revision &&
          !_typedEditExplainsLegacyDifference(
            base: base,
            typedCandidate: applied.candidate!,
            legacyCandidate: legacyCandidate,
            operations: interpretation.operations,
            text: text,
          )) {
        final issue = RequestIssue(
          id: 'request-$turnId-candidate-disagreement',
          kind: RequestIssueKind.conflict,
          code: 'candidate_interpretation_disagreement',
          message:
              'The typed edits and the existing network reader produce different designs. The request is held so no part is applied until the wording is resolved.',
          requirementIds: {
            for (final operation in interpretation.operations)
              ...operation.requirementIds,
          }.toList(),
          sourceSpans: [
            for (final operation in interpretation.operations)
              ...operation.sourceSpans,
          ],
        );
        interpretation = interpretation.copyWith(
          requirements: merge.requirements,
          issues: [issue],
        );
        return RequestCoordinatorOutcome(
          target: target,
          base: base,
          interpretation: interpretation,
          merge: merge,
          candidate: null,
          changeSet: null,
          disposition: RequestDisposition.ask,
          route: CoordinatedRequestRoute.blocked,
          brief: legacyBrief,
        );
      }

      final candidate = applied.candidate!;
      merge = RequirementMerger.merge(
        RequirementMerger.rebindAcceptedRenames(
          requirements: merge.requirements,
          operations:
              applied.changeSet?.operations ?? interpretation.operations,
        ),
      );
      final disposition = _sameSnapshot(candidate, base)
          ? RequestDisposition.answerOnly
          : RequestDisposition.commit;
      interpretation = interpretation.copyWith(
        requirements: merge.requirements,
        mutationPolicy: disposition == RequestDisposition.commit
            ? MutationPolicy.commitIfValid
            : MutationPolicy.none,
      );
      return RequestCoordinatorOutcome(
        target: target,
        base: base,
        interpretation: interpretation,
        merge: merge,
        candidate: candidate,
        changeSet: applied.changeSet,
        disposition: disposition,
        route: CoordinatedRequestRoute.typedMutation,
        brief: legacyBrief,
      );
    }

    final onlySatisfiedBounds =
        base != null &&
        interpretation.requirements.isNotEmpty &&
        interpretation.requirements.every(
          (requirement) =>
              requirement.property == 'device_count' &&
              const {
                RequirementComparator.atLeast,
                RequirementComparator.atMost,
              }.contains(requirement.comparator),
        ) &&
        CoverageChecker.check(
          plan: base,
          requirements: interpretation.requirements,
          target: target,
        ).requirements.every(
          (entry) => entry.planning == PlanningStatus.satisfied,
        );
    // A lower/upper bound is not an instruction to resize a plan already
    // within it. In particular, "at least 10" must keep an existing 12 PCs.
    final candidate = onlySatisfiedBounds ? base : legacyCandidate;
    final disposition =
        candidate != null && (base == null || !_sameSnapshot(candidate, base))
        ? RequestDisposition.commit
        : RequestDisposition.answerOnly;
    interpretation = interpretation.copyWith(
      requirements: merge.requirements,
      mutationPolicy: disposition == RequestDisposition.commit
          ? MutationPolicy.candidateOnly
          : MutationPolicy.none,
    );
    return RequestCoordinatorOutcome(
      target: target,
      base: base,
      interpretation: interpretation,
      merge: merge,
      candidate: candidate,
      changeSet: null,
      disposition: disposition,
      route: candidate == null
          ? CoordinatedRequestRoute.answerOnly
          : CoordinatedRequestRoute.legacyPlan,
      brief: legacyBrief,
    );
  }

  /// Recheck after the caller chooses a named design or applies a final
  /// deterministic repair. This does not reapply deltas or reuse delivery
  /// evidence from a different candidate.
  static RequestCoordinatorOutcome recomputeCoverage({
    required RequestCoordinatorOutcome outcome,
    required NetworkIntent candidate,
    required String target,
    NetworkIntent? base,
  }) {
    final old = outcome.changeSet;
    final changed = old == null
        ? null
        : PlanChangeSet(
            projectId: old.projectId,
            baseRevision: old.baseRevision,
            candidateRevision: candidate.revision,
            operations: old.operations,
            oldValues: old.oldValues,
            newValues: {'plan': candidate.toJson(includeSecrets: false)},
            incidentalChanges: old.incidentalChanges,
            reasons: old.reasons,
          );
    return RequestCoordinatorOutcome(
      target: target,
      base: base,
      interpretation: outcome.interpretation,
      merge: outcome.merge,
      candidate: candidate,
      changeSet: changed,
      disposition: outcome.disposition,
      route: outcome.route,
      brief: outcome.brief,
    );
  }

  static List<Requirement> requirementsFromSession(String raw) {
    if (raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['schemaVersion'] != 1) return const [];
      final rawInterpretation = decoded['interpretation'];
      if (rawInterpretation is! Map) return const [];
      return RequestInterpretation.fromJson(rawInterpretation).requirements;
    } catch (_) {
      return const [];
    }
  }

  static RequestIssue _conflictIssue(
    RequirementConflict conflict,
    List<Requirement> requirements,
    String turnId,
    int index,
  ) {
    final selected = requirements
        .where((item) => conflict.requirementIds.contains(item.id))
        .toList();
    return RequestIssue(
      id: 'request-$turnId-requirement-conflict-$index',
      kind: RequestIssueKind.conflict,
      code: 'requirement_conflict',
      message: conflict.reason,
      requirementIds: conflict.requirementIds,
      sourceSpans: [for (final item in selected) ...item.sourceSpans],
    );
  }

  /// A total correction is not implicit permission to unplug a full router
  /// or replace its model. Explain this concrete capacity case before asking
  /// the caller to choose recabling or hardware changes.
  static RequestIssue? _routerTotalCapacityIssue({
    required NetworkIntent base,
    required List<PlanOperation> operations,
    required List<RequestIssue> applicationIssues,
    required String turnId,
  }) {
    if (operations.isEmpty ||
        operations.any(
          (operation) =>
              operation.kind != PlanOperationKind.setDeviceCount ||
              operation.scope.kind != RequirementScopeKind.project ||
              operation.payload['kind'] != 'router',
        ) ||
        applicationIssues.isEmpty ||
        applicationIssues.any(
          (issue) => issue.code != 'candidate_validation_failed',
        )) {
      return null;
    }
    final routers = base.nodes
        .where((node) => node.type.toLowerCase() == 'router')
        .toList();
    final requested = operations.last.payload['total'];
    if (routers.isEmpty || requested is! int || requested <= routers.length) {
      return null;
    }
    final catalog = PacketTracerCatalog.instance;
    for (final router in routers) {
      final device = catalog.device(router.model ?? '');
      if (device == null) return null;
      final occupied = {
        for (final link in base.links)
          if (link.a == router.name) ptPortName(link.aIf),
        for (final link in base.links)
          if (link.b == router.name) ptPortName(link.bIf),
      };
      final routedCopper = device.ports
          .where((port) => port.medium == 'copper')
          .toList();
      if (routedCopper.isEmpty ||
          routedCopper.any(
            (port) => !occupied.contains(ptPortName(port.name)),
          )) {
        return null;
      }
    }
    return RequestIssue(
      id: 'request-$turnId-router-total-capacity',
      kind: RequestIssueKind.conflict,
      code: 'router_total_requires_capacity_decision',
      message:
          'The requested total is $requested routers, but ${routers.map((router) => router.name).join(', ')} have no free routed copper ports while their existing links are preserved. The previous plan is unchanged. Allow recabling the existing topology, or choose a compatible router/model module with additional routed ports before applying this total.',
      requirementIds: {
        for (final operation in operations) ...operation.requirementIds,
      }.toList(),
      sourceSpans: [
        for (final operation in operations) ...operation.sourceSpans,
      ],
    );
  }

  /// A typed inventory edit can be structurally correct while missing the
  /// links and addresses the established topology reader knows how to create.
  /// Reuse only those supporting rows from the legacy candidate, after proving
  /// its device deltas match the typed operations. Existing nodes, links,
  /// addresses, and layout entries always come from [base].
  static _SupplementedAddition? _supplementValidatedAdditions({
    required NetworkIntent base,
    required NetworkIntent typedCandidate,
    required NetworkIntent? legacyCandidate,
    required List<PlanOperation> operations,
    required String target,
    required List<RequestIssue> issues,
  }) {
    if (legacyCandidate == null ||
        operations.isEmpty ||
        operations.any(
          (operation) =>
              !{
                PlanOperationKind.addDevices,
                PlanOperationKind.setDeviceCount,
              }.contains(operation.kind) ||
              operation.scope.kind != RequirementScopeKind.project,
        ) ||
        issues.isEmpty ||
        issues.any((issue) => issue.code != 'candidate_validation_failed')) {
      return null;
    }

    final expectedCounts = <String, int>{};
    for (final node in base.nodes) {
      expectedCounts.update(
        node.type.toLowerCase(),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final operation in operations) {
      final rawKind = operation.payload['kind'];
      if (rawKind is! String || rawKind.trim().isEmpty) return null;
      final kind = rawKind.trim().toLowerCase();
      final current = expectedCounts[kind] ?? 0;
      final amount = operation.kind == PlanOperationKind.addDevices
          ? operation.payload['count']
          : operation.payload['total'];
      if (amount is! int || amount < 0) return null;
      if (operation.kind == PlanOperationKind.setDeviceCount &&
          amount < current) {
        return null;
      }
      expectedCounts[kind] = operation.kind == PlanOperationKind.addDevices
          ? current + amount
          : amount;
    }

    final actualCounts = <String, int>{};
    for (final node in legacyCandidate.nodes) {
      actualCounts.update(
        node.type.toLowerCase(),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final kind in {...expectedCounts.keys, ...actualCounts.keys}) {
      if ((expectedCounts[kind] ?? 0) != (actualCounts[kind] ?? 0)) {
        return null;
      }
    }

    if (legacyCandidate.routing != typedCandidate.routing ||
        !jsonValueEquals(legacyCandidate.vlans, base.vlans) ||
        !jsonValueEquals(
          legacyCandidate.security.toJson(includeSecrets: false),
          base.security.toJson(includeSecrets: false),
        )) {
      return null;
    }

    final baseNames = base.nodes.map((node) => node.name).toSet();
    final legacyByName = {
      for (final node in legacyCandidate.nodes) node.name: node,
    };
    if (base.nodes.any((node) {
      final legacyNode = legacyByName[node.name];
      return legacyNode == null || legacyNode.type != node.type;
    })) {
      return null;
    }
    final addedNodes = legacyCandidate.nodes
        .where((node) => !baseNames.contains(node.name))
        .toList();
    final expectedAdded =
        expectedCounts.values.fold<int>(0, (sum, value) => sum + value) -
        base.nodes.length;
    if (addedNodes.length != expectedAdded) return null;

    for (final operation in operations) {
      if (operation.kind != PlanOperationKind.addDevices) continue;
      final names = operation.payload['names'];
      if (names is List &&
          names.any(
            (name) =>
                name is! String || !addedNodes.any((node) => node.name == name),
          )) {
        return null;
      }
    }

    final addedNames = addedNodes.map((node) => node.name).toSet();
    final additionsByName = {for (final node in addedNodes) node.name: node};
    final nodes = [
      ...base.nodes,
      for (final node in addedNodes) additionsByName[node.name]!,
    ];
    final groups = <String, Set<String>>{};
    String? anchorFor(String start) {
      final visited = <String>{start};
      final queue = <String>[start];
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        for (final link in legacyCandidate.links) {
          final next = link.a == current
              ? link.b
              : link.b == current
              ? link.a
              : null;
          if (next == null || !visited.add(next)) continue;
          if (baseNames.contains(next)) return next;
          if (addedNames.contains(next)) queue.add(next);
        }
      }
      return null;
    }

    for (final name in addedNames) {
      final anchor = anchorFor(name);
      if (anchor == null) return null;
      groups.putIfAbsent(anchor, () => <String>{anchor}).add(name);
    }

    var candidate = typedCandidate.copyWith(
      nodes: nodes,
      links: base.links,
      addressing: base.addressing,
      layout: <String, Offset?>{
        ...base.layout,
        for (final name in addedNames)
          if (legacyCandidate.layout.containsKey(name))
            name: legacyCandidate.layout[name],
      },
    );
    final additionalAddresses = <InterfaceAddr>[];
    final usedIpv4 = <String>{
      for (final address in base.addressing)
        if (address.ipCidr.trim().isNotEmpty)
          address.ipCidr.split('/').first.trim(),
    };
    for (final group in groups.entries) {
      for (final name in group.value.where((name) => name != group.key)) {
        final node = additionsByName[name]!;
        final legacyAddresses = legacyCandidate.addressing
            .where((address) => address.node == name)
            .toList();
        final primary = legacyAddresses
            .where((address) => address.ipCidr.trim().isNotEmpty)
            .firstOrNull;
        if (const {
          'pc',
          'laptop',
          'tablet',
          'phone',
          'printer',
          'server',
        }.contains(node.type.toLowerCase())) {
          final routerLink = base.links.where((link) {
            final other = link.a == group.key
                ? link.b
                : link.b == group.key
                ? link.a
                : '';
            final otherNode = base.nodes
                .where((candidate) => candidate.name == other)
                .firstOrNull;
            return otherNode?.type.toLowerCase() == 'router';
          }).firstOrNull;
          if (routerLink == null) return null;
          final routerName = routerLink.a == group.key
              ? routerLink.b
              : routerLink.a;
          final routerInterface = routerLink.a == routerName
              ? routerLink.aIf
              : routerLink.bIf;
          final gateway = base.addressing
              .where(
                (address) =>
                    address.node == routerName &&
                    address.iface.toLowerCase() ==
                        routerInterface.toLowerCase(),
              )
              .firstOrNull;
          final subnet = gateway == null
              ? null
              : NetworkTools.subnet(gateway.ipCidr);
          if (subnet == null || subnet.usableHosts < 2) return null;
          final firstHost = NetworkTools.ipToInt(subnet.firstHost);
          final lastHost = NetworkTools.ipToInt(subnet.lastHost);
          final network = NetworkTools.ipToInt(subnet.network);
          if (firstHost == null || lastHost == null || network == null) {
            return null;
          }
          final preferred = network + 10;
          var addressValue = preferred <= lastHost
              ? (preferred > firstHost ? preferred : firstHost)
              : firstHost;
          while (addressValue <= lastHost &&
              usedIpv4.contains(NetworkTools.intToIp(addressValue))) {
            addressValue++;
          }
          if (addressValue > lastHost) return null;
          final ip = NetworkTools.intToIp(addressValue);
          usedIpv4.add(ip);
          final endpointInterface =
              primary?.iface ??
              legacyCandidate.links
                  .where((link) => link.a == name || link.b == name)
                  .map((link) => link.a == name ? link.aIf : link.bIf)
                  .firstOrNull ??
              '';
          if (endpointInterface.isEmpty) return null;
          additionalAddresses.add(
            InterfaceAddr(
              node: name,
              iface: endpointInterface,
              ipCidr: '$ip/${subnet.prefix}',
              ip6Cidr: primary?.ip6Cidr,
            ),
          );
          for (final address in legacyAddresses.skip(1)) {
            if (address.ip6Cidr?.trim().isNotEmpty == true) {
              additionalAddresses.add(address);
            }
          }
        } else {
          additionalAddresses.addAll(legacyAddresses);
        }
      }
    }
    candidate = candidate.copyWith(
      addressing: [...base.addressing, ...additionalAddresses],
    );
    for (final group in groups.values) {
      final wired = TopologyEditService.autoWire(candidate, group);
      if (wired.notConnected.isNotEmpty) return null;
      candidate = wired.intent;
    }

    final beforeBlocking = <String, int>{};
    for (final finding in ValidatorService.validate(base, target: target)) {
      if (finding.blocks) {
        beforeBlocking.update(
          finding.message,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    for (final finding in ValidatorService.validate(
      candidate,
      target: target,
    )) {
      if (!finding.blocks) continue;
      final existing = beforeBlocking[finding.message] ?? 0;
      if (existing > 0) {
        beforeBlocking[finding.message] = existing - 1;
      } else {
        return null;
      }
    }

    final incidental = <String>[
      if (candidate.links.length > base.links.length)
        'Added ${HumanLanguage.count(candidate.links.length - base.links.length, 'link')} needed by the new devices.',
      if (candidate.addressing.length > base.addressing.length)
        'Added ${HumanLanguage.count(candidate.addressing.length - base.addressing.length, 'address assignment')} for the new devices.',
      if (candidate.layout.length > base.layout.length)
        'Added layout positions for ${HumanLanguage.count(candidate.layout.length - base.layout.length, 'new device')}.',
    ];
    return _SupplementedAddition(candidate, incidental);
  }

  static bool _sameSnapshot(NetworkIntent left, NetworkIntent right) =>
      jsonValueEquals(
        left.toJson(includeSecrets: false),
        right.toJson(includeSecrets: false),
      );

  static bool _typedEditExplainsLegacyDifference({
    required NetworkIntent base,
    required NetworkIntent typedCandidate,
    required NetworkIntent legacyCandidate,
    required List<PlanOperation> operations,
    required String text,
  }) {
    if (operations.isEmpty ||
        operations.any(
          (operation) => !{
            PlanOperationKind.removeDevices,
            PlanOperationKind.renameDevice,
            PlanOperationKind.assignService,
            PlanOperationKind.removeService,
            PlanOperationKind.setDeviceCount,
          }.contains(operation.kind),
        ) ||
        !_explicitMutationVerbsAreCovered(text, operations)) {
      return false;
    }
    if (legacyCandidate.revision == base.revision) return true;
    final countReductionOnly = operations.every(
      (operation) => operation.kind == PlanOperationKind.setDeviceCount,
    );
    if (countReductionOnly &&
        _isValidCountReduction(base, typedCandidate, operations)) {
      // The old follow-up path re-reads a corrected count as a fresh brief,
      // which can redistribute cables and addresses across the smaller
      // inventory. The typed operation is grounded to the current project and
      // revision, has already passed validation, and every explicit mutation
      // verb is covered by its source span, so retain its deterministic
      // removal plan instead of accepting that unrelated re-plan.
      return true;
    }
    final serviceOnly = operations.every(
      (operation) =>
          operation.kind == PlanOperationKind.assignService ||
          operation.kind == PlanOperationKind.removeService,
    );
    return serviceOnly && _samePlanExceptServerRoles(base, legacyCandidate);
  }

  static bool _isValidCountReduction(
    NetworkIntent base,
    NetworkIntent typedCandidate,
    List<PlanOperation> operations,
  ) {
    if (operations.isEmpty) return false;
    for (final operation in operations) {
      if (operation.scope.kind != RequirementScopeKind.project) return false;
      final rawKind = operation.payload['kind'];
      final rawTotal = operation.payload['total'];
      if (rawKind is! String || rawTotal is! int) return false;
      final kind = rawKind.toLowerCase();
      final previousCount = base.nodes
          .where((node) => node.type.toLowerCase() == kind)
          .length;
      if (rawTotal >= previousCount) return false;
      final resultingCount = typedCandidate.nodes
          .where((node) => node.type.toLowerCase() == kind)
          .length;
      if (resultingCount != rawTotal) return false;
    }
    return true;
  }

  static bool _explicitMutationVerbsAreCovered(
    String text,
    List<PlanOperation> operations,
  ) {
    final pattern = RegExp(
      r'\b(?:add|remove|delete|rename|change|update|set|make|put|assign|enable|configure|connect|use|run|switch|keep|preserve|retain)\b',
      caseSensitive: false,
    );
    final spans = [
      for (final operation in operations) ...operation.sourceSpans,
    ];
    final lower = text.toLowerCase();
    for (final match in pattern.allMatches(text)) {
      int previous(String value) =>
          match.start == 0 ? -1 : lower.lastIndexOf(value, match.start - 1);
      final clausePrefix = lower.substring(
        [
              previous(','),
              previous(';'),
              previous('.'),
              previous('\n'),
            ].reduce((a, b) => a > b ? a : b) +
            1,
        match.start,
      );
      final negated = RegExp(
        r"(?:do\s+not|don't|never|must\s+not|should\s+not|without)\s*$",
        caseSensitive: false,
      ).hasMatch(clausePrefix);
      final action = match.group(0)!.toLowerCase();
      if (negated &&
          !{'change', 'set', 'keep', 'preserve', 'retain'}.contains(action)) {
        continue;
      }
      if (!spans.any(
        (span) => span.start <= match.start && span.end >= match.end,
      )) {
        return false;
      }
    }
    return true;
  }

  static bool _samePlanExceptServerRoles(
    NetworkIntent base,
    NetworkIntent legacyCandidate,
  ) {
    Map<String, dynamic> withoutServerRoles(NetworkIntent plan) {
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(plan.toJson(includeSecrets: false))) as Map,
      );
      for (final field in const [
        'projectName',
        'notes',
        'assumptions',
        'questions',
        'confidence',
        'planningSource',
        'layout',
        'prompts',
      ]) {
        snapshot.remove(field);
      }
      final nodes = snapshot['nodes'];
      if (nodes is! List) return snapshot;
      for (final rawNode in nodes) {
        if (rawNode is! Map) continue;
        if ('${rawNode['type']}'.toLowerCase() != 'server') continue;
        rawNode.remove('services');
        rawNode.remove('serviceRules');
      }
      return snapshot;
    }

    return jsonValueEquals(
      withoutServerRoles(base),
      withoutServerRoles(legacyCandidate),
    );
  }
}

class _SupplementedAddition {
  final NetworkIntent candidate;
  final List<String> incidentalChanges;

  const _SupplementedAddition(this.candidate, this.incidentalChanges);
}
