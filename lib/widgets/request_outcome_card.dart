import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../models/request_coverage.dart';
import '../models/request_interpretation.dart';
import '../models/request_requirement.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// A correction names the snapshot and fact the user actually saw.
class OutcomeCorrection {
  final String projectId;
  final String buildRevision;
  final String turnId;
  final String factId;
  final String slot;
  final String label;
  final String value;

  const OutcomeCorrection({
    required this.projectId,
    required this.buildRevision,
    required this.turnId,
    required this.factId,
    required this.slot,
    required this.label,
    required this.value,
  });
}

/// Presentation only: every claim comes from the recorded outcome, never a
/// second interpretation of the message or a provider's explanation.
///
/// A long brief turns the inventory chips and the requirement ledger into
/// dozens of small boxes that crowd the screen, so the detail section is
/// collapsed behind a "Show details" toggle once it grows past a few rows;
/// short briefs keep the at-a-glance layout they always had.
class RequestOutcomeCard extends StatefulWidget {
  final RequestOutcome outcome;
  final bool isCurrent;
  final String correctionNote;
  final ValueChanged<OutcomeCorrection>? onCorrect;
  final void Function(String issueId, String prompt)? onReply;

  const RequestOutcomeCard({
    super.key,
    required this.outcome,
    this.isCurrent = true,
    this.correctionNote = '',
    this.onCorrect,
    this.onReply,
  });

  @override
  State<RequestOutcomeCard> createState() => _RequestOutcomeCardState();
}

class _RequestOutcomeCardState extends State<RequestOutcomeCard> {
  /// Detail rows above which the card starts collapsed: a chat turn that
  /// understood this much needs a summary, not a wall of chips. A normal
  /// small brief stays under it; the 100+ requirement multi-turn briefs were
  /// what crowded the screen.
  static const _detailRowsBeforeCollapse = 14;

  bool? _expandedOverride;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final request = widget.outcome.interpretation;
    final arabic = request.responsePreferences.language.startsWith('ar');
    final plan = widget.outcome.candidatePlan;
    final active = request.requirements
        .where((fact) => fact.state != RequirementState.superseded)
        .toList();
    final coverage = widget.outcome.coverage;
    final satisfied = active.where(
      (fact) =>
          coverage?.forRequirement(fact.id)?.planning ==
          PlanningStatus.satisfied,
    );
    final issues = <String, String>{
      for (final issue in request.issues) issue.id: issue.message,
      for (final issue in widget.outcome.clarifications)
        issue.id: issue.message,
      for (final fragment in request.unresolvedFragments)
        fragment.id: fragment.text,
      for (final question in request.pendingQuestions)
        question.id: question.prompt,
    };
    final changes = _changes(widget.outcome);
    final counts = <String, int>{};
    for (final node in plan?.nodes ?? <NetNode>[]) {
      counts.update(node.type, (value) => value + 1, ifAbsent: () => 1);
    }
    final serviceChips = [
      for (final node in plan?.nodes ?? <NetNode>[])
        for (final service in node.services)
          '${node.name}: ${service.toUpperCase()}',
    ];
    final detailRows = plan == null
        ? 0
        : counts.length +
              plan.vlans.length +
              1 +
              serviceChips.length +
              active.length;
    final expanded =
        _expandedOverride ?? (detailRows <= _detailRowsBeforeCollapse);
    final isCurrent = widget.isCurrent;
    final onCorrect = widget.onCorrect;
    final onReply = widget.onReply;

    Widget chip(String text, {OutcomeCorrection? correction}) => ActionChip(
      key: correction == null
          ? null
          : ValueKey('outcome-correction-${correction.factId}'),
      label: Text(text),
      onPressed: isCurrent && onCorrect != null && correction != null
          ? () => onCorrect(correction)
          : null,
      visualDensity: VisualDensity.compact,
    );

    OutcomeCorrection correction(String slot, String label, String value) {
      final facts = active.where((fact) {
        if (slot == 'routing') return fact.property == 'routing';
        return slot == 'count:${fact.subject}' &&
            fact.property == 'device_count';
      });
      return OutcomeCorrection(
        projectId: request.projectId,
        buildRevision: plan?.buildRevision ?? request.basePlanRevision,
        turnId: request.turnId,
        factId: facts.isEmpty ? 'plan:$slot' : facts.first.id,
        slot: slot,
        label: label,
        value: value,
      );
    }

    final fileEntries = coverage?.requirements.where(
      (entry) => entry.delivery != DeliveryStatus.notRequested,
    );
    final fileVerified = fileEntries?.where(
      (entry) =>
          entry.delivery == DeliveryStatus.verified &&
          entry.evidence.any(
            (evidence) =>
                evidence.phase == RequirementPhase.artifact &&
                evidence.artifactHash.isNotEmpty,
          ),
    );
    final liveVerified = coverage?.requirements.where(
      (entry) =>
          entry.delivery == DeliveryStatus.verified &&
          entry.evidence.any(
            (evidence) => evidence.phase == RequirementPhase.liveVerification,
          ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.readingMeasure),
        child: Container(
          key: const ValueKey('request-outcome-card'),
          padding: const EdgeInsets.all(AppTheme.s12),
          decoration: BoxDecoration(
            color: AppPalette.neutralFill(scheme),
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            border: Border.all(color: AppPalette.accentBorder(scheme)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                arabic ? 'ما فهمته' : 'Understood',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: AppTheme.s6),
              Text(
                !isCurrent
                    ? (arabic
                          ? 'هذه نتيجة إصدار سابق؛ التصحيحات غير متاحة.'
                          : 'Earlier snapshot; corrections are unavailable.')
                    : active.isEmpty
                    ? (arabic
                          ? 'لا توجد متطلبات شبكة جديدة في هذا الطلب.'
                          : 'No new network requirements in this request.')
                    : arabic
                    ? '${satisfied.length} من ${active.length} متطلبات مستخرجة مطابقة للخطة'
                          '${issues.isEmpty ? '' : ' · ${issues.length} بند مفتوح'}'
                    // "extracted" is the honest word: the ledger can only judge
                    // the clauses the reader captured. Green coverage of every
                    // extracted clause is not a claim that nothing was missed -
                    // the open count below is what says how much was not read.
                    : '${satisfied.length}/${active.length} extracted '
                          'requirements satisfied in plan'
                          '${issues.isEmpty ? '' : ' · ${issues.length} open clause${issues.length == 1 ? '' : 's'} not counted'}',
                key: const ValueKey('request-planning-status'),
                style: theme.textTheme.labelSmall,
              ),
              if (plan != null &&
                  (counts.isNotEmpty || serviceChips.isNotEmpty)) ...[
                const SizedBox(height: AppTheme.s6),
                if (expanded)
                  Wrap(
                    spacing: AppTheme.s6,
                    runSpacing: AppTheme.s4,
                    children: [
                      for (final entry in counts.entries)
                        chip(
                          '${entry.value} ${_unit(entry.key, entry.value)}',
                          correction: correction(
                            'count:${entry.key}',
                            _unit(entry.key, entry.value),
                            '${entry.value}',
                          ),
                        ),
                      for (final vlan in plan.vlans) chip('VLAN $vlan'),
                      chip(
                        plan.routing.toUpperCase(),
                        correction: correction(
                          'routing',
                          'routing protocol',
                          plan.routing,
                        ),
                      ),
                      ...serviceChips.map(chip),
                    ],
                  ),
                if (detailRows > _detailRowsBeforeCollapse)
                  TextButton(
                    key: const ValueKey('request-detail-toggle'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    onPressed: () =>
                        setState(() => _expandedOverride = !expanded),
                    child: Text(
                      expanded
                          ? (arabic ? 'إخفاء التفاصيل' : 'Hide details')
                          : (arabic
                                ? 'إظهار كل التفاصيل (${active.length} متطلبات)'
                                : 'Show details (${active.length} requirements)'),
                    ),
                  ),
              ],
              if (expanded)
                for (final fact in active) ...[
                  const SizedBox(height: AppTheme.s4),
                  Text(
                    _factLine(fact, coverage?.forRequirement(fact.id)),
                    key: ValueKey('request-fact-${fact.id}'),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              if (changes.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  arabic ? 'التغييرات الفعلية:' : 'Changed:',
                  style: theme.textTheme.labelMedium,
                ),
                for (final change in changes)
                  Text(change, style: theme.textTheme.labelSmall),
              ] else if (request.mutationPolicy == MutationPolicy.none) ...[
                const SizedBox(height: AppTheme.s6),
                Text(
                  arabic ? 'لم تتغير الشبكة.' : 'No network changes applied.',
                  style: theme.textTheme.labelSmall,
                ),
              ],
              if (widget.correctionNote.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s6),
                Text(widget.correctionNote, style: theme.textTheme.labelSmall),
              ],
              if (issues.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  arabic ? 'بحاجة إلى توضيح:' : 'Need to resolve:',
                  style: theme.textTheme.labelMedium,
                ),
                for (final issue in issues.entries)
                  TextButton(
                    key: ValueKey('request-issue-${issue.key}'),
                    onPressed: isCurrent && onReply != null
                        ? () => onReply(issue.key, issue.value)
                        : null,
                    child: Text(issue.value),
                  ),
              ] else if (plan?.questions.isNotEmpty == true) ...[
                const SizedBox(height: AppTheme.s6),
                Text(
                  arabic ? 'أسئلة الخطة:' : 'Worth confirming:',
                  style: theme.textTheme.labelSmall,
                ),
                for (final question in plan!.questions.take(3))
                  TextButton(
                    onPressed: isCurrent && onReply != null
                        ? () => onReply('plan-question:$question', question)
                        : null,
                    child: Text(question),
                  ),
              ],
              if (fileEntries?.isNotEmpty == true) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  arabic
                      ? 'الملف المحفوظ: ${fileVerified?.length ?? 0}/${fileEntries!.length} متطلبات تم التحقق منها'
                      : 'Saved file: ${fileVerified?.length ?? 0}/${fileEntries!.length} requirements verified',
                  key: const ValueKey('request-artifact-status'),
                  style: theme.textTheme.labelSmall,
                ),
                for (final entry in fileEntries)
                  if (entry.delivery != DeliveryStatus.verified)
                    Text(
                      '${_deliveryLabel(entry.delivery)}: ${entry.explanation}',
                      style: theme.textTheme.labelSmall,
                    ),
              ],
              const SizedBox(height: AppTheme.s4),
              Text(
                liveVerified?.isNotEmpty == true
                    ? 'Live checks: ${liveVerified!.length} requirements verified'
                    : arabic
                    ? 'اختبارات الشبكة الفعلية: لم يتم التحقق منها'
                    : 'Live checks: not verified',
                key: const ValueKey('request-live-status'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _unit(String type, int count) => switch (type) {
    'pc' => count == 1 ? 'PC' : 'PCs',
    'switch' => count == 1 ? 'switch' : 'switches',
    'wireless' => count == 1 ? 'AP' : 'APs',
    'wireless-router' => count == 1 ? 'wireless router' : 'wireless routers',
    _ => count == 1 ? type : '${type}s',
  };

  static String _origin(Requirement fact) => switch (fact.origin.name) {
    'currentExplicit' => 'your request',
    'establishedProject' => 'established project',
    'imported' => 'imported source',
    'scopedRememberedPreference' => 'remembered preference',
    'environmentProfile' => 'environment profile',
    'derivedDefault' => 'assumed default',
    _ => 'source not recorded',
  };

  static String _factLine(Requirement fact, RequirementCoverage? coverage) {
    final requested = fact.sourceSpans.isNotEmpty
        ? fact.sourceSpans.map((span) => span.excerpt).toSet().join(' · ')
        : '${fact.subject}: ${fact.property.replaceAll('_', ' ')}';
    final prefix = fact.comparator == RequirementComparator.forbidden
        ? 'Excluded'
        : fact.comparator == RequirementComparator.preserve
        ? 'Preserve'
        : 'Requested';
    final status = switch (coverage?.planning) {
      PlanningStatus.satisfied => 'satisfied in plan',
      PlanningStatus.violated => 'not satisfied',
      PlanningStatus.unsupported => 'unsupported',
      PlanningStatus.superseded => 'superseded',
      _ => 'unresolved',
    };
    final scope = fact.scope.kind == RequirementScopeKind.project
        ? ''
        : '; ${fact.scope.scopeId}';
    return '$prefix: $requested (${_origin(fact)}$scope; $status)';
  }

  static String _deliveryLabel(DeliveryStatus status) => switch (status) {
    DeliveryStatus.mismatch => 'Mismatch',
    DeliveryStatus.unverified => 'Unverified',
    DeliveryStatus.pending => 'Awaiting saved-file checks',
    DeliveryStatus.verified => 'Verified',
    DeliveryStatus.notRequested => 'Not requested',
  };

  static List<String> _changes(RequestOutcome outcome) {
    final change = outcome.changeSet;
    if (change == null || outcome.disposition != RequestDisposition.commit) {
      return const [];
    }
    final lines = <String>[];
    final oldPlan = change.oldValues['plan'];
    final newPlan = change.newValues['plan'];
    void compare(Object? before, Object? after, String path) {
      if (jsonEncode(before) == jsonEncode(after)) return;
      if (before is Map && after is Map) {
        for (final key in {...before.keys, ...after.keys}) {
          if (key == 'confidence' || key == 'questions' || key == 'notes') {
            continue;
          }
          compare(
            before[key],
            after[key],
            path.isEmpty ? '$key' : '$path.$key',
          );
        }
      } else if (before is List && after is List) {
        final namedBefore = _namedItems(before);
        final namedAfter = _namedItems(after);
        if (namedBefore != null && namedAfter != null) {
          compare(namedBefore, namedAfter, path);
        } else {
          lines.add('$path: ${_short(before)} → ${_short(after)}');
        }
      } else {
        lines.add('$path: ${_short(before)} → ${_short(after)}');
      }
    }

    compare(oldPlan ?? change.oldValues, newPlan ?? change.newValues, '');
    lines.addAll(change.incidentalChanges);
    return lines;
  }

  static Map<String, Object?>? _namedItems(List<dynamic> values) {
    final result = <String, Object?>{};
    for (final value in values) {
      if (value is! Map || value['name'] is! String) return null;
      final name = value['name'] as String;
      if (result.containsKey(name)) return null;
      result[name] = value;
    }
    return result;
  }

  static String _short(Object? value) {
    if (value == null) return 'absent';
    final text = NetworkIntent.redactSecrets(
      value is String ? value : jsonEncode(value),
    );
    return text.length <= 120 ? text : '${text.substring(0, 117)}…';
  }
}
