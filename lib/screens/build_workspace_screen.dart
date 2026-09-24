import 'package:flutter/material.dart';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/planner_suggestions_service.dart';
import '../services/validator_service.dart';
import '../theme/app_palette.dart';
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: SegmentedButton<WorkspacePhase>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: WorkspacePhase.thinking,
            icon: Icon(Icons.psychology_outlined),
            label: Text('Thinking'),
          ),
          ButtonSegment(
            value: WorkspacePhase.execution,
            icon: Icon(Icons.play_circle_outline),
            label: Text('Execution'),
          ),
          ButtonSegment(
            value: WorkspacePhase.chat,
            icon: Icon(Icons.chat_bubble_outline),
            label: Text('Chat'),
          ),
        ],
        selected: {_phase},
        onSelectionChanged: (s) => setState(() => _phase = s.first),
      ),
    );
  }

  Widget _statusStrip() {
    final intent = widget.intent;
    final issues =
        ValidatorService.validate(intent, target: widget.record.target);
    final errors = issues.where((i) => i.severity == 'error').length;
    final warnings = issues.where((i) => i.severity == 'warning').length;
    final color = errors > 0
        ? AppPalette.dangerFill(Theme.of(context).colorScheme)
        : warnings > 0
        ? AppPalette.warningFill(Theme.of(context).colorScheme)
        : AppPalette.successFill(Theme.of(context).colorScheme);
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        '${widget.record.projectName} [${widget.record.target}]  -  '
        '${intent.nodes.length} devices, ${intent.links.length} links, '
        'routing ${intent.routing}  -  planner: ${intent.planningSource}  -  '
        '$errors error(s), $warnings warning(s)',
        style: const TextStyle(fontSize: 12),
      ),
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
    final issues = ValidatorService.validate(intent, target: record.target);
    final suggestions =
        PlannerSuggestionsService.forIntent(intent, target: record.target);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card('You asked', [record.instruction], AppPalette.accentFill(Theme.of(context).colorScheme)),
          _card('What I understood', [
            'Devices (${intent.nodes.length}): '
                '${intent.nodes.map((n) => '${n.name} (${n.type}${n.model == null ? '' : ', ${n.model}'})').join(', ')}',
            'Links: ${intent.links.length}'
                '${intent.links.isEmpty ? '' : ' - ${intent.links.take(8).map((l) => '${l.a} ${l.aIf} <-> ${l.b} ${l.bIf}').join('; ')}'}',
            'Routing: ${intent.routing}',
            if (intent.vlans.isNotEmpty) 'VLANs: ${intent.vlans.join(', ')}',
            if (intent.addressing.isNotEmpty)
              'Addressing: ${intent.addressing.take(10).map((a) => '${a.node} ${a.iface}=${a.ipCidr}').join(', ')}'
                  '${intent.addressing.length > 10 ? ' ...' : ''}',
            'Planner: ${intent.planningSource}   '
                'Confidence: ${(intent.confidence * 100).round()}%',
          ], null),
          if (intent.assumptions.isNotEmpty)
            _card('Assumptions I made', intent.assumptions, null),
          if (intent.notes.isNotEmpty)
            _card('How it was built', intent.notes, null),
          _card(
            'Checks',
            issues.isEmpty
                ? ['Validator: clean - nothing blocking.']
                : issues.map((i) => '[${i.severity}] ${i.message}').toList(),
            null,
          ),
          if (suggestions.isNotEmpty)
            _card('What you may want to fix', suggestions, AppPalette.warningFill(Theme.of(context).colorScheme)),
          if (intent.questions.isNotEmpty)
            _card('Open questions', intent.questions, null),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onExecute,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Go to execution'),
              ),
              OutlinedButton.icon(
                onPressed: onChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Ask in chat'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Nothing is typed into Packet Tracer until you approve it on the '
            'Execution tab; the assistant still only proposes.',
            style: TextStyle(fontSize: 12, color: AppPalette.mutedText(Theme.of(context).colorScheme)),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<String> lines, Color? color) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            for (final line in lines) Text('- $line'),
          ],
        ),
      ),
    );
  }
}
