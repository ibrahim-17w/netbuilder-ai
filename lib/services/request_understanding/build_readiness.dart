import '../../models/design_brief.dart';
import '../../models/network_intent.dart';
import '../../models/request_coverage.dart';
import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import '../validator_service.dart';
import 'coverage_checker.dart';
import 'requirement_validator.dart';
import 'target_capability_service.dart';

class BuildReadinessBlocker {
  final String code;
  final String reason;
  final List<String> alternatives;
  final String? requirementId;

  const BuildReadinessBlocker({
    required this.code,
    required this.reason,
    this.alternatives = const [],
    this.requirementId,
  });
}

class BuildReadinessResult {
  final bool hasPlan;
  final CoverageReport coverage;
  final List<BuildReadinessBlocker> blockers;
  final List<BuildReadinessBlocker> warnings;
  final List<ValidationIssue> validation;

  BuildReadinessResult({
    required this.hasPlan,
    required this.coverage,
    required List<BuildReadinessBlocker> blockers,
    required List<BuildReadinessBlocker> warnings,
    required List<ValidationIssue> validation,
  }) : blockers = List.unmodifiable(blockers),
       warnings = List.unmodifiable(warnings),
       validation = List.unmodifiable(validation);

  bool get canBuild => hasPlan && blockers.isEmpty;

  /// Repair/explanation must remain available for an invalid or unsupported
  /// candidate. It is not authorization to build or silently weaken a request.
  bool get canImprove => hasPlan;
}

/// One UI-independent gate for chat, build workspace and automation. A valid
/// topology is necessary but not sufficient: hard request coverage matters.
class BuildReadiness {
  const BuildReadiness._();

  static BuildReadinessResult evaluate({
    required NetworkIntent? plan,
    required String target,
    bool offlineBuild = false,
    Iterable<Requirement> requirements = const [],
    CoverageReport? coverage,
    RequestInterpretation? interpretation,
    NetworkIntent? base,
    DesignBrief? brief,
  }) {
    final supplied = requirements.toList();
    final contract = supplied.isNotEmpty
        ? supplied
        : interpretation?.requirements ?? const <Requirement>[];
    // Always recheck planning against THIS final candidate. A caller's cached
    // coverage or a prior artifact's verification must never bypass the gate.
    final checked = CoverageChecker.check(
      plan: plan,
      requirements: contract,
      target: target,
      base: base,
    );
    final blockers = <BuildReadinessBlocker>[];
    final warnings = <BuildReadinessBlocker>[];
    final seen = <String>{};
    void add(BuildReadinessBlocker finding, {bool warning = false}) {
      if (seen.add(
        '${warning ? 'warning' : 'block'}|${finding.code}|${finding.requirementId}|${finding.reason}',
      )) {
        (warning ? warnings : blockers).add(finding);
      }
    }

    final hasPlan = plan != null && plan.nodes.isNotEmpty;
    final validation = plan == null
        ? const <ValidationIssue>[]
        : ValidatorService.validate(
            plan,
            target: TargetCapabilityService.canonicalTarget(target),
            offlineBuild: offlineBuild,
          );
    if (!hasPlan) {
      add(
        const BuildReadinessBlocker(
          code: 'no_plan',
          reason: 'Describe or open a non-empty network plan before building.',
          alternatives: ['Create a plan', 'Open an existing project'],
        ),
      );
    }
    for (final finding in validation) {
      add(
        BuildReadinessBlocker(
          code: 'validation_${finding.severity}',
          reason: finding.message,
        ),
        warning: !finding.blocks,
      );
    }
    if (plan != null) {
      final routerCount = plan.nodes
          .where((n) => n.type.toLowerCase() == 'router')
          .length;
      // Reuse the existing clarification applicability rule: routing requires
      // a decision only for multiple routers. Empty generic brief slots do
      // not invalidate an already concrete flat LAN or fixed inventory.
      for (final prompt in plan.prompts) {
        if (routerCount < 2 && prompt.id.toLowerCase().contains('routing')) {
          continue;
        }
        add(
          BuildReadinessBlocker(
            code: 'plan_prompt_${prompt.id}',
            reason: prompt.message.isEmpty ? prompt.title : prompt.message,
            alternatives: prompt.options.map((option) => option.label).toList(),
          ),
        );
      }
      if (brief?.fact(DesignBrief.scale)?.quantityKind ==
              QuantityKind.userLoad &&
          !contract.any(
            (r) =>
                r.state == RequirementState.active &&
                r.property == 'device_count' &&
                r.quantityRole != QuantityRole.userLoad,
          )) {
        add(
          const BuildReadinessBlocker(
            code: 'unbound_user_load',
            reason:
                'A people count is not an inventory or a checked capacity policy. Confirm the device inventory or sizing policy.',
            alternatives: [
              'Specify the actual device count',
              'Choose an explicit people-to-device sizing policy',
            ],
          ),
        );
      }
      for (final capability in TargetCapabilityService.forPlan(
        plan,
        target: target,
      )) {
        for (final phase in [
          TargetCapabilityPhase.model,
          TargetCapabilityPhase.generate,
        ]) {
          final support = capability.forPhase(phase);
          if (!support.isSupported) {
            add(
              BuildReadinessBlocker(
                code: 'target_${phase.name}_${capability.feature}',
                reason: support.reason,
                alternatives: support.alternatives,
              ),
            );
          }
        }
      }
    }
    for (final issue in const RequirementValidator().validate(contract)) {
      add(BuildReadinessBlocker(code: issue.code, reason: issue.message));
    }
    for (final issue in interpretation?.issues ?? const <RequestIssue>[]) {
      add(BuildReadinessBlocker(code: issue.code, reason: issue.message));
    }
    for (final fragment
        in interpretation?.unresolvedFragments ??
            const <UnresolvedFragment>[]) {
      add(
        BuildReadinessBlocker(
          code: 'unresolved_fragment_${fragment.id}',
          reason: 'An unchecked request clause remains: ${fragment.text}',
          alternatives: const [
            'Clarify the clause using supported properties',
            'Review the request without building',
          ],
        ),
      );
    }
    for (final question
        in interpretation?.pendingQuestions ??
            const <PendingRequestQuestion>[]) {
      add(
        BuildReadinessBlocker(
          code: 'pending_${question.id}',
          reason: question.prompt,
        ),
      );
    }
    for (final r in contract) {
      if (r.state == RequirementState.superseded) continue;
      final hard = r.strength == RequirementStrength.explicit;
      final entry = checked.forRequirement(r.id);
      final capability = TargetCapabilityService.forRequirement(
        r,
        target: target,
        plan: plan,
      );
      if (entry == null || entry.planning != PlanningStatus.satisfied) {
        final alternatives = {
          ...capability.model.alternatives,
          ...capability.generate.alternatives,
        }.toList();
        add(
          BuildReadinessBlocker(
            code: 'coverage_${entry?.planning.name ?? 'missing'}',
            reason:
                entry?.explanation ??
                'No coverage was recorded for ${r.property}.',
            requirementId: r.id,
            alternatives: alternatives.isEmpty
                ? const [
                    'Clarify the original requirement or explicitly choose a supported alternative',
                  ]
                : alternatives,
          ),
          warning: !hard,
        );
      }
      for (final phase in [
        TargetCapabilityPhase.model,
        TargetCapabilityPhase.generate,
      ]) {
        final support = capability.forPhase(phase);
        if (!support.isSupported) {
          add(
            BuildReadinessBlocker(
              code: 'requirement_${phase.name}_${support.status.name}',
              reason: support.reason,
              alternatives: support.alternatives,
              requirementId: r.id,
            ),
            warning: !hard,
          );
        }
      }
      if (r.phase == RequirementPhase.artifact &&
          !capability.readBack.isSupported) {
        // An artifact may still be generated honestly as unverified. Missing
        // read-back is never promoted to verification and is not live support.
        add(
          BuildReadinessBlocker(
            code: 'artifact_readback_unavailable',
            reason: capability.readBack.reason,
            requirementId: r.id,
          ),
          warning: true,
        );
      }
      if (r.phase == RequirementPhase.liveVerification &&
          !capability.liveCheck.isSupported) {
        add(
          BuildReadinessBlocker(
            code: 'requested_live_check_unavailable',
            reason: capability.liveCheck.reason,
            requirementId: r.id,
            alternatives: const [
              'Explicitly request an artifact-only output instead',
              'Provide a supported independent live check',
            ],
          ),
          warning: !hard,
        );
      }
    }
    return BuildReadinessResult(
      hasPlan: hasPlan,
      coverage: checked,
      blockers: blockers,
      warnings: warnings,
      validation: validation,
    );
  }
}
