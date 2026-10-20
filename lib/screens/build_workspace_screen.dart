import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/build_artifact_service.dart';
import '../services/layout_engine.dart' show layoutStyleLabel, resolveSideNames;
import '../services/layout_intent.dart';
import '../services/pkt/on_device_pkt_builder.dart';
import '../services/pkt_build_job_service.dart';
import '../services/pkt/pkt_export_service.dart';
import '../services/planner_suggestions_service.dart';
import '../services/settings_service.dart';
import '../services/validator_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import 'builder_detail_screen.dart';
import 'chat_screen.dart';
import 'layout_gallery_screen.dart';

enum WorkspacePhase { thinking, execution, chat }

String _chosenLayoutStyle(NetworkIntent intent) {
  for (final note in intent.notes) {
    final style = LayoutRequest.styleFromNote(note);
    if (style.isNotEmpty) return style;
  }
  return '';
}

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
  final ValueChanged<NetworkIntent>? onIntentChanged;
  final ValueChanged<Map<String, dynamic>>? onReviewFailure;

  const BuildWorkspaceScreen({
    super.key,
    required this.record,
    required this.intent,
    required this.configText,
    this.monitorSidecar = true,
    this.brief = '',
    this.onIntentChanged,
    this.onReviewFailure,
  });

  @override
  State<BuildWorkspaceScreen> createState() => _BuildWorkspaceScreenState();
}

class _BuildWorkspaceScreenState extends State<BuildWorkspaceScreen> {
  WorkspacePhase _phase = WorkspacePhase.thinking;
  late NetworkIntent _intent;

  @override
  void initState() {
    super.initState();
    _intent = widget.intent;
  }

  @override
  void didUpdateWidget(covariant BuildWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.intent, widget.intent)) _intent = widget.intent;
  }

  bool get _hasChosenDesign => _chosenLayoutStyle(_intent).isNotEmpty;

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
                  'Planner: ${_intent.planningSource}',
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
            segments: [
              ButtonSegment(
                value: WorkspacePhase.thinking,
                icon: Icon(Icons.psychology_outlined, size: 16),
                label: const Text('Plan'),
              ),
              ButtonSegment(
                value: WorkspacePhase.execution,
                icon: Icon(
                  !_hasChosenDesign
                      ? Icons.dashboard_customize_outlined
                      : Icons.play_circle_outline,
                  size: 16,
                ),
                label: Text(_hasChosenDesign ? 'Build' : 'Design'),
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
    final intent = _intent;
    final issues = ValidatorService.validate(
      intent,
      target: widget.record.target,
    );
    final errors = issues.where((i) => i.severity == 'error').length;
    final warnings = issues.where((i) => i.severity == 'warning').length;
    final needsDesign = !_hasChosenDesign;
    final tone = errors > 0
        ? AppTone.danger
        : needsDesign
        ? AppTone.info
        : warnings > 0
        ? AppTone.warning
        : AppTone.success;
    return AppBanner(
      tone: tone,
      dense: true,
      icon: errors > 0
          ? Icons.error_outline
          : needsDesign
          ? Icons.dashboard_customize_outlined
          : warnings > 0
          ? Icons.warning_amber_rounded
          : Icons.verified_outlined,
      title: errors > 0
          ? 'The validator blocks this plan'
          : needsDesign
          ? 'Choose a network design'
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
        if (SettingsService.isMobile) {
          return _PhoneBuildPanel(
            record: widget.record,
            intent: _intent,
            onDesignChosen: (intent) {
              setState(() => _intent = intent);
              widget.onIntentChanged?.call(intent);
            },
          );
        }
        if (!_hasChosenDesign) {
          return _WindowsDesignGate(
            intent: _intent,
            onDesignChosen: (intent) {
              setState(() => _intent = intent);
              widget.onIntentChanged?.call(intent);
            },
          );
        }
        return BuilderDetailScreen(
          record: widget.record,
          intent: _intent,
          configText: widget.configText,
          monitorSidecar: widget.monitorSidecar,
          brief: widget.brief,
          target: widget.record.target,
          onReviewFailure: widget.onReviewFailure,
        );
      case WorkspacePhase.chat:
        return ChatScreen(initialProject: widget.record.projectName);
      case WorkspacePhase.thinking:
        return _ThinkingPanel(
          record: widget.record,
          intent: _intent,
          hasChosenDesign: _hasChosenDesign,
          onExecute: () => setState(() => _phase = WorkspacePhase.execution),
          onChat: () => setState(() => _phase = WorkspacePhase.chat),
        );
    }
  }
}

/// A phone build has no Packet Tracer window to drive. It compiles the plan
/// with the bundled library and saves the finished file through Android.
class _PhoneBuildPanel extends StatefulWidget {
  final BuildRecord record;
  final NetworkIntent intent;
  final ValueChanged<NetworkIntent> onDesignChosen;

  const _PhoneBuildPanel({
    required this.record,
    required this.intent,
    required this.onDesignChosen,
  });

  @override
  State<_PhoneBuildPanel> createState() => _PhoneBuildPanelState();
}

class _PhoneBuildPanelState extends State<_PhoneBuildPanel> {
  bool _busy = false;

  String get _designStyle => _chosenLayoutStyle(widget.intent);

  Future<void> _chooseDesign() async {
    final intent = widget.intent;
    final picked = await LayoutGalleryScreen.show(
      context,
      intent: intent,
      currentStyle: _designStyle.isEmpty ? 'tree' : _designStyle,
    );
    if (!mounted || picked == null) return;
    final parked = picked == 'grouped'
        ? resolveSideNames(intent, kinds: LayoutRequest.defaultSideKinds)
        : const <String>[];
    final notes = [
      for (final note in intent.notes)
        if (!note.toLowerCase().startsWith('layout:')) note,
      LayoutRequest.noteFor(
        picked,
        sideKinds: parked.isEmpty
            ? const <String>[]
            : LayoutRequest.defaultSideKinds,
        sideNames: parked,
      ),
    ];
    widget.onDesignChosen(intent.copyWith(notes: notes));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Design selected: ${layoutStyleLabel(picked)}. The build is ready.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _build() async {
    if (_busy) return;
    final intent = widget.intent;
    if (_designStyle.isEmpty) {
      await _chooseDesign();
      return;
    }
    final errors = ValidatorService.validate(
      intent,
      target: widget.record.target,
    ).where((issue) => issue.severity == 'error').toList();
    if (errors.isNotEmpty) {
      await showLinesDialog(
        context,
        title: 'Fix these plan errors first',
        subtitle:
            '${intent.nodes.length} devices, ${intent.links.length} links',
        icon: Icons.error_outline,
        warn: true,
        lines: [for (final issue in errors) issue.message],
      );
      return;
    }

    setState(() => _busy = true);
    final layout = PacketTracerAdapter.intentLayoutFromNotes(intent);
    final plan = PacketTracerAdapter.autopilotPlan(intent, layout: layout);
    final jobs = PktBuildJobService.instance;
    final built = await jobs.start(
      project: intent.projectName,
      sourceRecordId: widget.record.id,
      planRevision: intent.revision,
      planJson: jsonEncode(intent.toPlannerJson()),
      build: (reportProgress) async {
        final appDir = await getApplicationDocumentsDirectory();
        final outputDir = OnDevicePktBuilder.outDirIn(appDir);
        final taken = <String>{};
        if (outputDir.existsSync()) {
          for (final entry in outputDir.listSync(followLinks: false)) {
            if (entry is File) {
              taken.add(entry.uri.pathSegments.last.toLowerCase());
            }
          }
        }
        final filename = BuildArtifactService.networkFileName(
          plan: intent,
          taken: taken,
        );
        return OnDevicePktBuilder.buildFromPlan(
          plan: plan,
          appDir: getApplicationDocumentsDirectory,
          filename: filename,
          project: intent.projectName,
          onProgress: reportProgress,
          isCancelled: () => jobs.cancelRequested,
        );
      },
    );
    if (!mounted) return;
    if (built == null) {
      setState(() => _busy = false);
      return;
    }

    final exported = await PktExportService.saveToChosenFolder(
      built.file,
      suggestedName: built.file.uri.pathSegments.last,
    );
    if (!mounted) return;
    if (!exported.cancelled && exported.path.isNotEmpty) {
      jobs.markSaved(exported.path);
    }
    setState(() => _busy = false);

    final report = built.report ?? const <String, dynamic>{};
    final warnings = (report['warnings'] as List? ?? const [])
        .map((warning) => warning.toString())
        .toList();
    final saved = !exported.cancelled && exported.path.isNotEmpty;
    final reportLayout = report['layout'];
    final layoutName = reportLayout is Map ? reportLayout['style'] : null;
    await showArtifactDialog(
      context,
      title: saved ? 'The .pkt is saved' : 'The .pkt is ready',
      subtitle: exported.message,
      text: [
        'Built on this phone using the bundled Packet Tracer device library.',
        'Devices: ${report['deviceCount'] ?? intent.nodes.length}',
        'Cables: ${report['linkCount'] ?? intent.links.length}',
        'Layout: ${layoutName ?? layout['style'] ?? 'saved design'}',
        if (saved) 'Saved file: ${exported.path}',
        if (!saved)
          'The built file remains in app storage at ${built.file.path}. '
              'Choose a save location to make it visible in Android Files.',
        if (warnings.isNotEmpty) '',
        if (warnings.isNotEmpty) 'Warnings:',
        ...warnings.map((warning) => '- $warning'),
      ].join('\n'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    return AppPage(
      maxWidth: 820,
      header: AppPageHeader(
        eyebrow: _designStyle.isEmpty ? 'Network design' : 'Packet Tracer file',
        title: _designStyle.isEmpty
            ? 'Choose network design'
            : 'Build on this phone',
        description: _designStyle.isEmpty
            ? 'Preview the available drawings and choose one before the phone build is shown.'
            : 'Create a .pkt from the design you chose, then pick where Android saves it.',
      ),
      children: [
        AppPanel(
          icon: Icons.hub_outlined,
          title: intent.projectName,
          subtitle:
              '${intent.nodes.length} devices · ${intent.links.length} '
              'cables · ${_designStyle.isEmpty ? 'design not chosen' : 'layout ${layoutStyleLabel(_designStyle)}'}',
          children: [
            AppBanner(
              tone: _designStyle.isEmpty ? AppTone.info : AppTone.success,
              dense: true,
              icon: _designStyle.isEmpty
                  ? Icons.dashboard_customize_outlined
                  : Icons.phone_android_outlined,
              message: _designStyle.isEmpty
                  ? 'Choose a drawing first. The phone build action appears after your selection.'
                  : 'This build runs locally. It does not need the desktop engine or Packet Tracer open.',
            ),
            const SizedBox(height: AppTheme.s12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : _designStyle.isEmpty
                    ? _chooseDesign
                    : _build,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _designStyle.isEmpty
                            ? Icons.dashboard_customize_outlined
                            : Icons.download_outlined,
                      ),
                label: Text(
                  _busy
                      ? 'Building...'
                      : _designStyle.isEmpty
                      ? 'Choose network design'
                      : 'Build and save .pkt',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Windows starts in the same design-first state as Android. Selecting a
/// drawing updates the shared plan; the next frame opens the normal desktop
/// execution and verification controls.
class _WindowsDesignGate extends StatelessWidget {
  final NetworkIntent intent;
  final ValueChanged<NetworkIntent> onDesignChosen;

  const _WindowsDesignGate({
    required this.intent,
    required this.onDesignChosen,
  });

  Future<void> _choose(BuildContext context) async {
    final current = _chosenLayoutStyle(intent);
    final picked = await LayoutGalleryScreen.show(
      context,
      intent: intent,
      currentStyle: current.isEmpty ? 'tree' : current,
    );
    if (!context.mounted || picked == null) return;
    final parked = picked == 'grouped'
        ? resolveSideNames(intent, kinds: LayoutRequest.defaultSideKinds)
        : const <String>[];
    final updated = intent.copyWith(
      notes: [
        for (final note in intent.notes)
          if (!note.toLowerCase().startsWith('layout:')) note,
        LayoutRequest.noteFor(
          picked,
          sideKinds: parked.isEmpty
              ? const <String>[]
              : LayoutRequest.defaultSideKinds,
          sideNames: parked,
        ),
      ],
    );
    onDesignChosen(updated);
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      maxWidth: 820,
      header: AppPageHeader(
        eyebrow: 'Network design',
        title: 'Choose network design',
        description:
            'Preview the drawings first. The selected device positions carry '
            'into the Windows build and Packet Tracer file.',
      ),
      children: [
        AppPanel(
          icon: Icons.dashboard_customize_outlined,
          title: intent.projectName,
          subtitle:
              '${intent.nodes.length} devices · ${intent.links.length} cables',
          children: [
            const AppBanner(
              tone: AppTone.info,
              dense: true,
              icon: Icons.visibility_outlined,
              message:
                  'This step saves your design choice. It does not start Packet Tracer or run the lab.',
            ),
            const SizedBox(height: AppTheme.s12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _choose(context),
                icon: const Icon(Icons.dashboard_customize_outlined),
                label: const Text('Choose network design'),
              ),
            ),
          ],
        ),
      ],
    );
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
  final bool hasChosenDesign;

  const _ThinkingPanel({
    required this.record,
    required this.intent,
    required this.onExecute,
    required this.onChat,
    required this.hasChosenDesign,
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
              label: Text(
                hasChosenDesign ? 'Continue to build' : 'Choose network design',
              ),
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
                value:
                    '${n.type}${n.model == null || n.model!.isEmpty ? '' : '  ·  ${n.model}'}'
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
                AppKeyValue(
                  label: a.node,
                  value: '${a.iface}  ${a.ipCidr}',
                  mono: true,
                ),
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
          title: hasChosenDesign
              ? 'Design selected: ${layoutStyleLabel(_chosenLayoutStyle(intent))}'
              : 'Choose network design',
          message: hasChosenDesign
              ? 'The workspace and Packet Tracer builder use this drawing.'
              : 'Choose a drawing before opening the build controls.',
        ),
      ],
    );
  }
}
