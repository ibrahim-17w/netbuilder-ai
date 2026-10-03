import 'package:flutter/material.dart';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/planner_suggestions_service.dart';
import '../services/validator_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import 'builder_detail_screen.dart';
import 'chat_screen.dart';

enum WorkspacePhase { thinking, execution, chat }

/// One screen for the whole build: the **thinking** (why the plan looks like
/// this), the **execution** (running it and proving it on screen) and the
/// **chat** (talking about it) live together instead of behind three tabs.
class BuildWorkspaceScreen extends StatefulWidget {
  final BuildRecord record;
  final NetworkIntent intent;
  final String configText;
  final bool monitorSidecar;

  /// The brief that produced this plan (for the planner-cache feedback loop).
  final String brief;

  const BuildWorkspaceScreen({
    super.key,
    required this.record,
    required this.intent,
    required this.configText,
    this.monitorSidecar = true,
    this.brief = '',
  });

  @override
  State<BuildWorkspaceScreen> createState() => _BuildWorkspaceScreenState();
}

class _BuildWorkspaceScreenState extends State<BuildWorkspaceScreen> {
  WorkspacePhase _phase = WorkspacePhase.thinking;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _phaseBar(),
        _statusStrip(),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _phaseBar() {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTheme.gutter(context),
        AppTheme.s14,
        AppTheme.gutter(context),
        AppTheme.s10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.record.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  'Planner: ${widget.intent.planningSource}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.s12),
          // The three phases are a sequence, not three tabs of equal weight:
          // reading the plan, then building it, then talking about it.
          SegmentedButton<WorkspacePhase>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: WorkspacePhase.thinking,
                icon: Icon(Icons.psychology_outlined, size: 16),
                label: Text('Thinking'),
              ),
              ButtonSegment(
                value: WorkspacePhase.execution,
                icon: Icon(Icons.play_circle_outline, size: 16),
                label: Text('Execution'),
              ),
              ButtonSegment(
                value: WorkspacePhase.chat,
                icon: Icon(Icons.chat_bubble_outline, size: 16),
                label: Text('Chat'),
              ),
            ],
            selected: {_phase},
            onSelectionChanged: (s) => setState(() => _phase = s.first),
          ),
        ],
      ),
    );
  }

  Widget _statusStrip() {
    final intent = widget.intent;
    final issues = ValidatorService.validate(
      intent,
      target: widget.record.target,
    );
    final errors = issues.where((i) => i.severity == 'error').length;
    final warnings = issues.where((i) => i.severity == 'warning').length;
    final tone = errors > 0
        ? AppTone.danger
        : warnings > 0
        ? AppTone.warning
        : AppTone.success;
    return AppBanner(
      tone: tone,
      dense: true,
      icon: errors > 0
          ? Icons.error_outline
          : warnings > 0
          ? Icons.warning_amber_rounded
          : Icons.verified_outlined,
      title: errors > 0
          ? 'The validator blocks this plan'
          : 'Ready to build',
      message:
          '${intent.nodes.length} devices, ${intent.links.length} links, '
          'routing ${intent.routing.isEmpty ? 'none' : intent.routing}  ·  '
          '$errors error(s), $warnings warning(s)  ·  '
          'target ${widget.record.target}',
      actions: [
        if (errors > 0)
          TextButton(
            onPressed: () => setState(() => _phase = WorkspacePhase.chat),
            child: const Text('Ask about the findings'),
          ),
      ],
    );
  }

  Widget _body() {
    switch (_phase) {
      case WorkspacePhase.execution:
        return BuilderDetailScreen(
          record: widget.record,
          intent: widget.intent,
          configText: widget.configText,
          monitorSidecar: widget.monitorSidecar,
          brief: widget.brief,
          target: widget.record.target,
        );
      case WorkspacePhase.chat:
        return ChatScreen(initialProject: widget.record.projectName);
      case WorkspacePhase.thinking:
        return _ThinkingPanel(
          record: widget.record,
          intent: widget.intent,
          onExecute: () => setState(() => _phase = WorkspacePhase.execution),
          onChat: () => setState(() => _phase = WorkspacePhase.chat),
        );
    }
  }
}

/// The "thinking": what was asked, what was understood, how it was decided,
/// what the checks say, and what the user may want to fix - all before any
/// device is touched.
class _ThinkingPanel extends StatelessWidget {
  final BuildRecord record;
  final NetworkIntent intent;
  final VoidCallback onExecute;
  final VoidCallback onChat;

  const _ThinkingPanel({
    required this.record,
    required this.intent,
    required this.onExecute,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final issues = ValidatorService.validate(intent, target: record.target);
    final suggestions = PlannerSuggestionsService.forIntent(
      intent,
      target: record.target,
    );
    final errors = issues.where((i) => i.severity == 'error').length;

    return AppPage(
      maxWidth: 900,
      children: [
        AppPageHeader(
          eyebrow: 'Thinking',
          title: 'Why this plan looks like this',
          description:
              'The brief, what was understood, what was assumed and what the '
              'checks say - before any device is touched.',
          actions: [
            FilledButton.icon(
              onPressed: onExecute,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Go to execution'),
            ),
            OutlinedButton.icon(
              onPressed: onChat,
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Ask in chat'),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.record_voice_over_outlined,
          tone: AppTone.accent,
          title: 'You asked',
          child: Text(record.instruction, style: theme.textTheme.bodyMedium),
        ),
        AppMetricGrid(
          metrics: [
            AppMetric(
              label: 'Devices',
              value: '${intent.nodes.length}',
              icon: Icons.devices_other_outlined,
            ),
            AppMetric(
              label: 'Links',
              value: '${intent.links.length}',
              icon: Icons.cable_outlined,
              tone: AppTone.info,
            ),
            AppMetric(
              label: 'Routing',
              value: intent.routing.isEmpty ? 'none' : intent.routing,
              icon: Icons.alt_route_outlined,
              tone: AppTone.info,
            ),
            AppMetric(
              label: 'Confidence',
              value: '${(intent.confidence * 100).round()}%',
              icon: Icons.insights_outlined,
              tone: AppTone.accent,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s14),
        AppPanel(
          icon: Icons.account_tree_outlined,
          title: 'What I understood',
          actions: [
            AppTag(
              label: 'rev ${intent.revision}',
              tone: AppTone.neutral,
              mono: true,
            ),
          ],
          children: [
            for (final n in intent.nodes.take(24))
              AppKeyValue(
                label: n.name,
                value: '${n.type}${n.model == null || n.model!.isEmpty ? '' : '  ·  ${n.model}'}'
                    '${n.services.isEmpty ? '' : '  ·  ${n.services.join(', ')}'}',
              ),
            if (intent.nodes.length > 24)
              Text(
                '+ ${intent.nodes.length - 24} more device(s)',
                style: theme.textTheme.bodySmall,
              ),
            if (intent.links.isNotEmpty) ...[
              const AppDivider(label: 'Links'),
              for (final l in intent.links.take(12))
                AppKeyValue(
                  label: l.a,
                  value: '${l.aIf}  <->  ${l.b} ${l.bIf}',
                  mono: true,
                ),
            ],
            if (intent.vlans.isNotEmpty) ...[
              const AppDivider(label: 'VLANs'),
              Wrap(
                spacing: AppTheme.s6,
                runSpacing: AppTheme.s6,
                children: [
                  for (final vlan in intent.vlans)
                    AppTag(label: 'VLAN $vlan', tone: AppTone.info, mono: true),
                ],
              ),
            ],
            if (intent.addressing.isNotEmpty) ...[
              const AppDivider(label: 'Addressing'),
              for (final a in intent.addressing.take(10))
                AppKeyValue(label: a.node, value: '${a.iface}  ${a.ipCidr}', mono: true),
            ],
          ],
        ),
        if (intent.assumptions.isNotEmpty)
          AppPanel(
            icon: Icons.help_outline,
            title: 'Assumptions I made',
            children: [
              for (final a in intent.assumptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Text(a, style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        if (intent.notes.isNotEmpty)
          AppPanel(
            icon: Icons.construction_outlined,
            title: 'How it was built',
            children: [
              for (final n in intent.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Text(n, style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        AppPanel(
          icon: errors > 0 ? Icons.error_outline : Icons.check_circle_outline,
          tone: errors > 0
              ? AppTone.danger
              : (issues.isEmpty ? AppTone.success : AppTone.warning),
          filled: issues.isNotEmpty,
          title: 'Checks',
          children: [
            if (issues.isEmpty)
              Text(
                'Validator: clean - nothing blocking.',
                style: theme.textTheme.bodyMedium,
              )
            else
              for (final issue in issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppTag(
                        label: issue.severity,
                        tone: issue.severity == 'error'
                            ? AppTone.danger
                            : AppTone.warning,
                      ),
                      const SizedBox(width: AppTheme.s8),
                      Expanded(
                        child: Text(
                          issue.message,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        if (suggestions.isNotEmpty)
          AppPanel(
            icon: Icons.tips_and_updates_outlined,
            tone: AppTone.warning,
            title: 'What you may want to fix',
            children: [
              for (final s in suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Text(s, style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        if (intent.questions.isNotEmpty)
          AppPanel(
            icon: Icons.live_help_outlined,
            title: 'Open questions',
            children: [
              for (final q in intent.questions)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Text(q, style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        AppBanner(
          tone: AppTone.info,
          message:
              'Nothing is typed into Packet Tracer until you approve it on '
              'the Execution tab; the assistant still only proposes.',
        ),
      ],
    );
  }
}
