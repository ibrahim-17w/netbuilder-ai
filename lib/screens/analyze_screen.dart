import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/validator_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// Read-only network review with an explicit approval gate before fixes.
class AnalyzeScreen extends StatefulWidget {
  final String initialProject;
  final NetworkIntent? intent;

  const AnalyzeScreen({
    super.key,
    this.initialProject = 'default',
    this.intent,
  });

  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  late final TextEditingController _project;
  Map<String, dynamic>? _report;
  final Set<String> _selectedFixes = {};
  final Map<String, List<TextEditingController>> _pcFixFields = {};
  List<ValidationIssue> _planIssues = const [];
  bool _busy = false;
  bool _analyzing = false;
  String _message =
      'Read-only mode: analysis opens devices and runs checks. '
      'Nothing changes until you approve selected fixes.';

  @override
  void initState() {
    super.initState();
    _project = TextEditingController(
      text: widget.initialProject.trim().isEmpty
          ? 'default'
          : widget.initialProject.trim(),
    );
    if (widget.intent != null) {
      _planIssues = ValidatorService.validate(
        widget.intent!,
        target: 'packet-tracer',
      );
    }
  }

  @override
  void dispose() {
    _project.dispose();
    _disposePcFields();
    super.dispose();
  }

  void _disposePcFields() {
    for (final fields in _pcFixFields.values) {
      for (final field in fields) {
        field.dispose();
      }
    }
    _pcFixFields.clear();
  }

  bool _hasFix(Map finding) =>
      finding['fix_pc'] == true ||
      ((finding['fix_cli'] as List?) ?? const []).isNotEmpty;

  List<Map> _devices() =>
      (_report?['devices'] as List? ?? []).whereType<Map>().toList();

  void _prepareSelection() {
    _selectedFixes.clear();
    _disposePcFields();
    for (final raw in _devices()) {
      final dev = Map<String, dynamic>.from(raw);
      final name = (dev['name'] ?? '').toString();
      for (final findingRaw in (dev['findings'] as List? ?? [])) {
        final finding = Map<String, dynamic>.from(findingRaw as Map);
        final id = (finding['id'] ?? '').toString();
        if (id.isNotEmpty &&
            finding['severity'] == 'high' &&
            _hasFix(finding)) {
          _selectedFixes.add(id);
        }
        if (finding['fix_pc'] == true && !_pcFixFields.containsKey(name)) {
          final ipcfg = Map<String, dynamic>.from(
            (dev['ipcfg'] as Map? ?? const {}),
          );
          _pcFixFields[name] = [
            TextEditingController(text: (ipcfg['ip'] ?? '').toString()),
            TextEditingController(
              text: (ipcfg['mask'] ?? '255.255.255.0').toString(),
            ),
            TextEditingController(),
          ];
        }
      }
    }
  }

  Future<void> _analyze() async {
    final project = _project.text.trim();
    if (project.isEmpty) {
      setState(() => _message = 'Enter the Packet Tracer project name first.');
      return;
    }
    setState(() {
      _busy = true;
      _analyzing = true;
      _report = null;
      _selectedFixes.clear();
      _disposePcFields();
      _message =
          'Analyzing $project: reading devices, interfaces, routing, '
          'PC/server addressing, CLI evidence, link indicators, then '
          'running live endpoint pings...';
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() {
          _message = svc.hint;
          _analyzing = false;
        });
        return;
      }
      await svc.auditStart(project);
      for (var i = 0; i < 300; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final response = await svc.auditReport();
        if (response['running'] == false) {
          final report = response['report'] as Map?;
          if (!mounted) return;
          setState(() {
            _report = report == null
                ? <String, dynamic>{
                    'project': project,
                    'error': 'The analyzer returned no report.',
                  }
                : Map<String, dynamic>.from(report);
            _analyzing = false;
          });
          _prepareSelection();
          if (!mounted) return;
          setState(
            () => _message =
                'Analysis finished. Review the findings below. '
                'No changes were made.',
          );
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _message = 'Analysis timed out. Check Packet Tracer and try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _message =
            'Analysis failed: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewAndApply() async {
    if (_selectedFixes.isEmpty) {
      setState(() => _message = 'Select at least one suggested fix first.');
      return;
    }
    final selectedText = <String>[];
    for (final dev in _devices()) {
      for (final raw in (dev['findings'] as List? ?? [])) {
        final finding = raw as Map;
        if (_selectedFixes.contains(finding['id'])) {
          selectedText.add('${dev['name']}: ${finding['text']}');
        }
      }
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve network fixes?'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'The following changes will be typed into Packet Tracer. '
                  'Review them before approving:',
                ),
                const SizedBox(height: 8),
                for (final text in selectedText)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text('• $text'),
                  ),
                const SizedBox(height: 8),
                Text(
                  'The app will verify the result after the run. '
                  'It will not apply unselected findings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.mutedText(Theme.of(context).colorScheme),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve and apply'),
          ),
        ],
      ),
    );
    if (approved == true) await _applyApprovedFixes();
  }

  Future<void> _applyApprovedFixes() async {
    final report = _report;
    if (report == null) return;
    final configs = <String, String>{};
    final pcs = <String, Map<String, String>>{};
    var count = 0;
    for (final raw in _devices()) {
      final dev = Map<String, dynamic>.from(raw);
      final name = (dev['name'] ?? '').toString();
      for (final findingRaw in (dev['findings'] as List? ?? [])) {
        final finding = Map<String, dynamic>.from(findingRaw as Map);
        if (!_selectedFixes.contains(finding['id'])) continue;
        final cli = (finding['fix_cli'] as List? ?? [])
            .map((e) => e.toString())
            .toList();
        if (cli.isNotEmpty) {
          configs[name] =
              '${configs[name] == null ? '' : '${configs[name]}\n'}${cli.join('\n')}';
          count++;
        }
        if (finding['fix_pc'] == true) {
          final fields = _pcFixFields[name];
          if (fields == null) continue;
          final ip = fields[0].text.trim();
          final mask = fields[1].text.trim();
          final gateway = fields[2].text.trim();
          if (ip.isEmpty || gateway.isEmpty) {
            setState(
              () => _message =
                  'PC $name needs both an IP address and gateway before '
                  'approval can be applied.',
            );
            return;
          }
          pcs[name] = {
            'ip': ip,
            'mask': mask.isEmpty ? '255.255.255.0' : mask,
            'gw': gateway,
          };
          count++;
        }
      }
    }
    if (count == 0) {
      setState(() => _message = 'No actionable fixes were selected.');
      return;
    }
    final steps = <Map<String, dynamic>>[
      if (configs.isNotEmpty)
        {'action': 'paste_cli', 'configs': configs, 'typing_delay_ms': 25},
      if (pcs.isNotEmpty) {'action': 'config_pcs', 'pcs': pcs},
    ];
    setState(() {
      _busy = true;
      _message =
          'Approved. Applying $count fix(es) and preparing verification...';
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _message = svc.hint);
        return;
      }
      await svc.start({
        'project': _project.text.trim(),
        'steps': steps,
        'mode': 'fixes',
      });
      await _waitForFixResult(svc);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message =
            'Fix run failed: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waitForFixResult(AutopilotService svc) async {
    var started = false;
    for (var i = 0; i < 180; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final status = jsonDecode(await svc.status()) as Map<String, dynamic>;
        if (status['running'] == true) started = true;
        if (started && status['running'] != true) break;
      } catch (_) {}
    }
    if (!mounted) return;
    final summary = await svc.runSummary();
    final validation = summary['validation'] as Map?;
    final ok = summary['ok'] == true;
    final failed = ((validation?['checks'] as List?) ?? [])
        .whereType<Map>()
        .where((check) => check['ok'] != true)
        .map((check) => check['name'].toString())
        .toList();
    setState(
      () => _message =
          'Fix run finished: ${ok ? 'verified' : 'issues remain'}\n'
          'Validation: ${validation == null
              ? 'not recorded'
              : ok
              ? 'OK'
              : 'FAILED'}'
          '${failed.isEmpty ? '' : ' (${failed.join(', ')})'}\n'
          'Review the findings again before approving another change.',
    );
  }

  // The numbers the results header reports, all derived from the one report
  // so the strip and the panels below it cannot disagree.
  ({int devices, int findings, int high, int redDots}) get _totals {
    final summary = Map<String, dynamic>.from(
      (_report?['summary'] as Map? ?? const {}),
    );
    final severity = Map<String, dynamic>.from(
      (summary['severity'] as Map? ?? const {}),
    );
    final redDots = _report?['red_dots'] ?? 0;
    return (
      devices: (summary['device_count'] as num?)?.toInt() ?? _devices().length,
      findings: (summary['finding_count'] as num?)?.toInt() ?? 0,
      high: (severity['high'] as num?)?.toInt() ?? 0,
      redDots: redDots is num ? redDots.toInt() : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totals = _totals;
    final results = _report;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToolbar(
          leading: SizedBox(
            width: 320,
            child: TextField(
              controller: _project,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Packet Tracer project name',
                hintText: 'office-net',
                prefixIcon: Icon(Icons.folder_open_outlined, size: 18),
              ),
            ),
          ),
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : _analyze,
              icon: Icon(
                _analyzing ? Icons.hourglass_top : Icons.fact_check_outlined,
                size: 18,
              ),
              label: Text(
                _analyzing
                    ? 'Analyzing and testing...'
                    : 'Analyze + test network',
              ),
            ),
          ],
        ),
        Expanded(
          child: AppPage(
            maxWidth: 1080,
            children: [
              AppPageHeader(
                eyebrow: 'Inspect',
                title: 'Analyze and fix',
                description:
                    'Analyze is read-only. It reads the live Packet Tracer '
                    'devices, interfaces, routing state, PC/server '
                    'addressing, server service panels, and red link '
                    'indicators. Connectivity is tested with real Packet '
                    'Tracer pings from endpoint command prompts.',
              ),
              // A screen reader has to be told when a multi-minute analysis
              // starts and finishes: this line is the only place the state is
              // reported.
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppTheme.s10),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Analysis in progress',
                  ),
                ),
              AppPanel(
                icon: _analyzing
                    ? Icons.hourglass_top
                    : Icons.radio_button_checked,
                title: 'Status',
                tone: _busy ? AppTone.accent : AppTone.neutral,
                filled: _busy,
                child: AppLiveText(
                  text: _message,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (_planIssues.isNotEmpty)
                AppSection(
                  title: 'Current plan checks',
                  subtitle: 'What the validator says about the open plan.',
                  children: [
                    for (final issue in _planIssues)
                      AppBanner(
                        tone: issue.severity == 'error'
                            ? AppTone.danger
                            : AppTone.warning,
                        title: issue.severity,
                        message: issue.message,
                      ),
                  ],
                ),
              if (results != null) ...[
                AppMetricGrid(
                  metrics: [
                    AppMetric(
                      label: 'Devices',
                      value: '${totals.devices}',
                      icon: Icons.devices_other_outlined,
                      tone: AppTone.accent,
                    ),
                    AppMetric(
                      label: 'Findings',
                      value: '${totals.findings}',
                      icon: Icons.fact_check_outlined,
                      tone: totals.findings == 0
                          ? AppTone.success
                          : AppTone.warning,
                    ),
                    AppMetric(
                      label: 'High severity',
                      value: '${totals.high}',
                      icon: Icons.priority_high,
                      tone: totals.high == 0 ? AppTone.success : AppTone.danger,
                    ),
                    AppMetric(
                      label: 'Red links',
                      value: '${totals.redDots}',
                      icon: Icons.link_off,
                      tone: totals.redDots == 0
                          ? AppTone.success
                          : AppTone.danger,
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.s14),
                _resultsPanel(results),
                if ((results['reachability'] as Map? ?? {}).isNotEmpty)
                  _buildReachability(
                    Map<String, dynamic>.from(results['reachability'] as Map),
                  ),
                for (final dev in _devices()) _buildDevice(dev),
                const SizedBox(height: AppTheme.s8),
                _approvalBar(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _resultsPanel(Map<String, dynamic> results) {
    final summary = Map<String, dynamic>.from(
      (results['summary'] as Map? ?? const {}),
    );
    final byType = Map<String, dynamic>.from(
      (summary['by_type'] as Map? ?? const {}),
    );
    final severity = Map<String, dynamic>.from(
      (summary['severity'] as Map? ?? const {}),
    );
    final interfaces = Map<String, dynamic>.from(
      (summary['interfaces'] as Map? ?? const {}),
    );
    final services = Map<String, dynamic>.from(
      (summary['services'] as Map? ?? const {}),
    );
    final error = (results['error'] ?? '').toString();
    final note = (results['note'] ?? '').toString();
    final scope = (results['scope'] as List? ?? const []);
    return AppPanel(
      icon: Icons.analytics_outlined,
      title: 'Analysis results',
      subtitle: 'Project: ${results['project'] ?? _project.text}',
      actions: [
        if (byType.isNotEmpty)
          Wrap(
            spacing: AppTheme.s6,
            runSpacing: AppTheme.s6,
            children: [
              for (final entry in byType.entries)
                AppTag(
                  label: '${entry.key} ${entry.value}',
                  tone: AppTone.neutral,
                ),
            ],
          ),
      ],
      children: [
        if (error.isNotEmpty)
          AppBanner(tone: AppTone.danger, message: error),
        if (summary.isNotEmpty) ...[
          AppKeyValue(
            label: 'Scope',
            value:
                '${summary['device_count'] ?? 0} device(s), '
                '${summary['finding_count'] ?? 0} finding(s)',
          ),
          AppKeyValue(
            label: 'Severity',
            value:
                'high ${severity['high'] ?? 0}, '
                'medium ${severity['medium'] ?? 0}, '
                'info ${severity['info'] ?? 0}',
          ),
          AppKeyValue(
            label: 'Interfaces',
            value:
                'up ${interfaces['up'] ?? 0}, '
                'down ${interfaces['down'] ?? 0}, '
                'admin-down ${interfaces['administratively_down'] ?? 0}',
          ),
          if ((services['checked'] ?? 0) != 0)
            AppKeyValue(
              label: 'Services',
              value:
                  'checked ${services['checked']}, on ${services['on'] ?? 0}, '
                  'off ${services['off'] ?? 0}, '
                  'unknown ${services['unknown'] ?? 0}, '
                  'saved tables ${services['saved_data'] ?? 0}, '
                  'rules verified ${services['rules_verified'] ?? 0}, '
                  'state only ${services['state_only'] ?? 0}',
            ),
          if (scope.isNotEmpty)
            AppKeyValue(label: 'Evidence', value: scope.join('  ·  ')),
        ],
        if (note.isNotEmpty) ...[
          const AppDivider(label: 'Note'),
          Text(note, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }

  /// The approval gate: one bar that says what is selected and what the
  /// button will do. It is the last thing on the page, because it is the last
  /// decision.
  Widget _approvalBar() {
    final count = _selectedFixes.length;
    return AppPanel(
      tone: count == 0 ? AppTone.info : AppTone.warning,
      filled: count > 0,
      icon: count == 0 ? Icons.lock_outline : Icons.approval_outlined,
      title: count == 0
          ? 'No fixes selected'
          : 'Review and approve $count fix(es)',
      subtitle: count == 0
          ? 'Tick a suggested fix on a device below. Nothing is applied '
                'without this step.'
          : 'The exact commands are shown before anything is typed.',
      actions: [
        FilledButton.icon(
          onPressed: _busy || count == 0 ? null : _reviewAndApply,
          icon: const Icon(Icons.approval, size: 18),
          label: Text(
            count == 0
                ? 'Select suggested fixes first'
                : 'Review and approve $count fix(es)',
          ),
        ),
      ],
    );
  }

  Widget _buildDevice(Map dev) {
    final findings = (dev['findings'] as List? ?? []).whereType<Map>().toList();
    final interfaces = (dev['interfaces'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final services = (dev['services'] as List? ?? []).whereType<Map>().toList();
    final probes = (dev['probes'] as List? ?? []).whereType<Map>().toList();
    final ipcfg = Map<String, dynamic>.from((dev['ipcfg'] as Map? ?? const {}));
    final ospf = (dev['ospf'] as List? ?? []).join(', ');
    final name = (dev['name'] ?? 'device').toString();
    final high =
        findings.where((f) => f['severity'] == 'high').length;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s8),
      child: AppPanel(
        padding: EdgeInsets.zero,
        dense: true,
        tone: high > 0 ? AppTone.danger : AppTone.neutral,
        framed: true,
        child: Theme(
          // The panel draws the surfaces; the tile must not paint its own.
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: ExpansionTile(
            initiallyExpanded: high > 0,
            shape: const RoundedRectangleBorder(),
            collapsedShape: const RoundedRectangleBorder(),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s12,
              vertical: AppTheme.s2,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppTheme.s12,
              0,
              AppTheme.s12,
              AppTheme.s12,
            ),
            leading: AppIconBubble(
              icon: high > 0 ? Icons.report_gmailerrorred : Icons.devices_other,
              tone: high > 0 ? AppTone.danger : AppTone.success,
              size: 30,
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text('$name (${dev['type'] ?? 'device'})'),
                ),
                const SizedBox(width: AppTheme.s8),
                AppTag(
                  label: '${findings.length} finding(s)',
                  tone: findings.isEmpty ? AppTone.success : AppTone.warning,
                ),
              ],
            ),
            subtitle: Text(
              findings.isEmpty
                  ? 'No findings'
                  : '${findings.where((f) => f['severity'] == 'high').length} '
                        'high, ${findings.where((f) => f['severity'] == 'medium').length} '
                        'medium',
            ),
            children: [
              if (interfaces.isNotEmpty)
                AppKeyValue(
                  label: 'Interfaces',
                  value: interfaces
                      .map((i) => '${i['name']} ${i['status']}')
                      .join('  ·  '),
                  mono: true,
                ),
              if (ospf.isNotEmpty)
                AppKeyValue(label: 'OSPF networks', value: ospf, mono: true),
              if (ipcfg.values.any((value) => value.toString().isNotEmpty))
                AppKeyValue(
                  label: 'IPv4',
                  value:
                      '${ipcfg['ip'] ?? 'unreadable'}'
                      '${(ipcfg['mask'] ?? '').toString().isEmpty ? '' : ' / ${ipcfg['mask']}'}'
                      '${(ipcfg['gw'] ?? '').toString().isEmpty ? '' : '  gateway ${ipcfg['gw']}'}',
                  mono: true,
                ),
              if (services.isNotEmpty) ...[
                const AppDivider(label: 'Services'),
                for (final service in services)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.s4),
                    child: Row(
                      children: [
                        AppTag(
                          label: (service['state'] ?? 'unknown').toString(),
                          tone: service['state'] == 'on'
                              ? AppTone.success
                              : AppTone.neutral,
                        ),
                        const SizedBox(width: AppTheme.s8),
                        Expanded(
                          child: Text(
                            '${service['name'] ?? 'service'}'
                            '${service['saved_data'] == true ? '  ·  saved data' : ''}'
                            '${service['verification_mode'] == 'state_only' ? '  ·  state only' : '  ·  rules verified'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final service in services)
                  if ((service['evidence'] as List? ?? []).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: AppTheme.s4),
                      child: Text(
                        '${service['name']}: ${(service['evidence'] as List).join(' | ')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
              ],
              if (probes.isNotEmpty) ...[
                const AppDivider(label: 'CLI probes'),
                for (final probe in probes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.s4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppTag(
                          label: probe['readable'] == true ? 'read' : 'unreadable',
                          tone: probe['readable'] == true
                              ? AppTone.success
                              : AppTone.warning,
                        ),
                        const SizedBox(width: AppTheme.s8),
                        Expanded(
                          child: Text(
                            '${probe['command']}'
                            '${(probe['evidence'] as List? ?? []).isEmpty ? '' : '  ·  ${(probe['evidence'] as List).take(3).join(' | ')}'}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFamily: AppTheme.monoFont,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (findings.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.s4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 16,
                        color: AppPalette.success(Theme.of(context).colorScheme),
                      ),
                      const SizedBox(width: AppTheme.s8),
                      Text(
                        'Clean - no actionable issue found.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppPalette.success(
                            Theme.of(context).colorScheme,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              for (final finding in findings) _buildFinding(name, finding),
              if (_pcFixFields[name] != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.s6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _pcFixFields[name]![0],
                          decoration: const InputDecoration(
                            labelText: 'PC IP',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppTheme.s6),
                      Expanded(
                        child: TextField(
                          controller: _pcFixFields[name]![1],
                          decoration: const InputDecoration(
                            labelText: 'Mask',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppTheme.s6),
                      Expanded(
                        child: TextField(
                          controller: _pcFixFields[name]![2],
                          decoration: const InputDecoration(
                            labelText: 'Gateway',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFinding(String device, Map finding) {
    final id = (finding['id'] ?? '').toString();
    final canFix = _hasFix(finding);
    final severity = (finding['severity'] ?? 'info').toString();
    final tone = severity == 'high'
        ? AppTone.danger
        : severity == 'medium'
        ? AppTone.warning
        : AppTone.neutral;
    final selected = _selectedFixes.contains(id);
    if (!canFix) {
      return Padding(
        padding: const EdgeInsets.only(top: AppTheme.s6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIconBubble(
              icon: Icons.info_outline,
              tone: tone,
              size: 24,
            ),
            const SizedBox(width: AppTheme.s10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(finding['text'].toString()),
                  const SizedBox(height: 2),
                  Text(
                    '$severity - informational only',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s6),
      child: Material(
        color: selected
            ? AppPalette.tone(Theme.of(context).colorScheme, AppTone.accent).fill
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: _busy
              ? null
              : () => setState(() {
                  selected ? _selectedFixes.remove(id) : _selectedFixes.add(id);
                }),
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: selected,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          value == true
                              ? _selectedFixes.add(id)
                              : _selectedFixes.remove(id);
                        }),
                ),
                const SizedBox(width: AppTheme.s4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(finding['text'].toString()),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          AppTag(label: severity, tone: tone),
                          const SizedBox(width: AppTheme.s6),
                          Flexible(
                            child: Text(
                              'suggested fix available'
                              '${finding['fix_pc'] == true ? ' - enter the gateway below' : ''}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReachability(Map<String, dynamic> reachability) {
    final results = (reachability['results'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final skipped = (reachability['skipped'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final error = (reachability['error'] ?? '').toString();
    final passed = reachability['passed'] ?? 0;
    final failed = reachability['failed'] ?? 0;
    final bad = failed is num && failed > 0;
    return AppPanel(
      icon: bad ? Icons.wifi_tethering_error : Icons.wifi_tethering,
      tone: bad ? AppTone.danger : AppTone.success,
      filled: true,
      title: 'Live connectivity tests',
      subtitle:
          'Attempted ${reachability['attempted'] ?? 0}  ·  '
          'passed $passed  ·  failed $failed  ·  skipped ${skipped.length}',
      children: [
        if (error.isNotEmpty)
          AppBanner(tone: AppTone.danger, message: error, dense: true),
        for (final result in results)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIconBubble(
                  icon: result['ok'] == true
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  tone: result['ok'] == true
                      ? AppTone.success
                      : AppTone.danger,
                  size: 26,
                ),
                const SizedBox(width: AppTheme.s10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${result['source']} → ${result['target']}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${result['ok'] == true ? 'Reply received' : 'No verified reply'}  ·  '
                        'attempts ${result['attempts'] ?? '?'}'
                        '${(result['evidence'] ?? '').toString().isEmpty ? '' : '\n${result['evidence']}'}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        for (final item in skipped)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s4),
            child: Text(
              'Skipped ${item['source']}: ${item['reason']}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (reachability['note'] != null)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s4),
            child: Text(
              reachability['note'].toString(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
