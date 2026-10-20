import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/build_artifact_service.dart';
import '../services/pkt_plan_import_service.dart';
import '../services/settings_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// Reverse mode: open existing .pkt files and learn what is inside.
///
/// - Audit: devices, services, AAA state, findings with severity
/// - Diff:  what changed between two saves
/// - Grade: score a save against the plan currently open
class ImportScreen extends StatefulWidget {
  final Future<Map<String, dynamic>?> Function() planLoader;
  final void Function(
    BuildRecord record,
    NetworkIntent intent,
    String configText,
  )?
  onOpenImportedPlan;

  const ImportScreen({
    super.key,
    required this.planLoader,
    this.onOpenImportedPlan,
  });

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String? _lastPath;
  List<int>? _lastBytes;
  ImportedPktPlan? _lastImportedPlan;
  PlatformFile? _pickedFile;
  Map<String, dynamic>? _auditReport;
  Map<String, dynamic>? _diffReport;
  Map<String, dynamic>? _gradeReport;
  PktPlanImportTask? _importTask;
  String _parseStage = '';
  double _parseProgress = 0;

  Future<String?> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pkt'],
      withData: SettingsService.isMobile,
      dialogTitle: 'Pick a Packet Tracer save',
    );
    _pickedFile = result?.files.single;
    return _pickedFile?.path;
  }

  Future<void> _runAudit() async {
    final engine = AutopilotService.of(context);
    final path = await _pick();
    if (_pickedFile == null) return;
    if (SettingsService.isMobile) {
      setState(() => _busy = true);
      try {
        final bytes =
            _pickedFile?.bytes ??
            (path == null || path.isEmpty
                ? null
                : await File(path).readAsBytes());
        if (bytes == null) {
          throw StateError(
            'The selected .pkt file could not be read on this device.',
          );
        }
        final selectedName = path == null || path.isEmpty
            ? (_pickedFile?.name ?? 'Imported network.pkt')
            : path;
        final project = p.basenameWithoutExtension(selectedName).trim().isEmpty
            ? 'Imported network'
            : p.basenameWithoutExtension(selectedName).trim();
        final task = PktPlanImportTask();
        _importTask = task;
        final imported = await PktPlanImportService.fromBytesInBackground(
          bytes,
          projectName: project,
          task: task,
          onProgress: (stage, progress) {
            if (!mounted) return;
            setState(() {
              _parseStage = stage;
              _parseProgress = progress;
            });
          },
        );
        if (!mounted) return;
        setState(() {
          _lastPath = path;
          _lastBytes = bytes;
          _lastImportedPlan = imported;
          _auditReport = _localAuditReport(imported, path: path ?? '');
        });
      } catch (error) {
        if (error is PktPlanImportCancelled) return;
        _error(error);
      } finally {
        _importTask = null;
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (path == null) return;
    setState(() {
      _busy = true;
      _lastPath = path;
      _lastBytes = null;
      _lastImportedPlan = null;
      _auditReport = null;
    });
    try {
      final report = await engine.pktDeepAudit(path);
      setState(() => _auditReport = report);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runDiff() async {
    final engine = AutopilotService.of(context);
    final a = await _pick();
    if (a == null || !mounted) return;
    final b = await _pick();
    if (b == null) return;
    setState(() {
      _busy = true;
      _diffReport = null;
    });
    try {
      final report = await engine.pktDiff(a, b);
      setState(() => _diffReport = report);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runGrade() async {
    final engine = AutopilotService.of(context);
    final path = await _pick();
    if (path == null || !mounted) return;
    final intent = await widget.planLoader();
    if (intent == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No plan is open - open or create a plan first.'),
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _gradeReport = null;
    });
    try {
      final report = await engine.pktGrade(path, intent);
      setState(() => _gradeReport = report);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEditablePlan() async {
    final path = _lastPath;
    final bytes =
        _lastBytes ??
        (path == null || path.trim().isEmpty
            ? null
            : await File(path).readAsBytes());
    if (bytes == null) return;
    setState(() => _busy = true);
    try {
      final selectedName = path ?? _pickedFile?.name ?? 'Imported network.pkt';
      final project = p.basenameWithoutExtension(selectedName).trim().isEmpty
          ? 'Imported network'
          : p.basenameWithoutExtension(selectedName).trim();
      final task = _lastImportedPlan == null ? PktPlanImportTask() : null;
      _importTask = task;
      final imported =
          _lastImportedPlan ??
          await PktPlanImportService.fromBytesInBackground(
            bytes,
            projectName: project,
            task: task,
            onProgress: (stage, progress) {
              if (!mounted) return;
              setState(() {
                _parseStage = stage;
                _parseProgress = progress;
              });
            },
          );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Open an editable plan?'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'The plan will contain ${imported.intent.nodes.length} '
                    'devices and ${imported.intent.links.length} connections. '
                    'The selected .pkt will stay untouched. A new file built '
                    'from this plan may not retain details the editor cannot represent:',
                  ),
                  const SizedBox(height: 12),
                  if (imported.preservedDetails.isNotEmpty) ...[
                    const Text('Retained in the plan'),
                    const SizedBox(height: 6),
                    for (final detail in imported.preservedDetails)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $detail'),
                      ),
                    const SizedBox(height: 8),
                  ],
                  const Text('Review before building a new file'),
                  const SizedBox(height: 6),
                  for (final limitation in imported.limitations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• $limitation'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep inspecting'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Open editable plan'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final intent = imported.intent;
      final record = BuildRecord(
        projectName: intent.projectName,
        instruction: 'Imported topology from ${p.basename(selectedName)}',
        intentJson: jsonEncode(intent.toPlannerJson()),
        target: 'packet-tracer',
        success: false,
        status: 'planned',
        createdAt: DateTime.now(),
      );
      final configText = BuildArtifactService.renderLocal(
        intent,
        'packet-tracer',
      );
      widget.onOpenImportedPlan?.call(record, intent, configText);
    } catch (error) {
      if (error is PktPlanImportCancelled) return;
      _error(error);
    } finally {
      _importTask = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _localAuditReport(
    ImportedPktPlan imported, {
    required String path,
  }) {
    final intent = imported.intent;
    final serviceRows = <String, List<Map<String, dynamic>>>{};
    for (final node in intent.nodes) {
      if (node.services.isEmpty) continue;
      serviceRows[node.name] = [
        for (final role in node.services)
          {'service': role, 'enabled': true, 'detail': 'enabled in save'},
      ];
    }
    return {
      'mode': 'local-import',
      'path': path,
      'devices': [
        for (final node in intent.nodes)
          {
            'name': node.name,
            'kind': node.type,
            'model': node.model ?? '',
            'ips': [
              for (final address in intent.addressing.where(
                (a) => a.node == node.name,
              ))
                address.ipCidr,
            ],
            'services': node.services,
            'interfaces': [
              for (final address in intent.addressing.where(
                (a) => a.node == node.name,
              ))
                {
                  'name': address.iface,
                  'ip': address.ipCidr,
                  'ipv6': address.ip6Cidr,
                },
            ],
            'findings': const <String>[],
          },
      ],
      'links': [for (final link in intent.links) link.toJson()],
      'linkCount': intent.links.length,
      'findings': const <String>[],
      'services': serviceRows,
      'preservedDetails': imported.preservedDetails,
      'limitations': imported.limitations,
      'summary': {
        'devices': intent.nodes.length,
        'links': intent.links.length,
        'servicesEnabled': serviceRows.values.fold<int>(
          0,
          (count, rows) => count + rows.length,
        ),
        'findings': 'Not checked',
        'high': 'Not checked',
      },
      'note':
          'Topology structure was read locally. Semantic findings, live reachability, and simulation state were not tested.',
    };
  }

  void _error(Object e) {
    final text = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // No Scaffold or AppBar here: this screen is a destination inside the
    // app shell, which already supplies both. A second AppBar here drew a
    // second title bar inside the first one.
    final mobile = SettingsService.isMobile;
    return DefaultTabController(
      length: mobile ? 1 : 3,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppTheme.gutter(context),
              AppTheme.s20,
              AppTheme.gutter(context),
              AppTheme.s12,
            ),
            child: AppPageHeader(
              eyebrow: 'Inspect',
              title: 'Open & inspect .pkt',
              description: mobile
                  ? 'Read a Packet Tracer save on this device and open its recognized topology as an editable plan.'
                  : 'Inspect and compare saved .pkt files. When useful, convert recognized topology into a separate editable plan.',
            ),
          ),
          TabBar(
            tabs: mobile
                ? const [Tab(text: 'Inspect')]
                : const [
                    Tab(text: 'Audit'),
                    Tab(text: 'Diff'),
                    Tab(text: 'Grade'),
                  ],
          ),
          Expanded(
            child: _busy
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(
                              value: _parseProgress == 0
                                  ? null
                                  : _parseProgress,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _parseStage.isEmpty ? 'Working…' : _parseStage,
                              textAlign: TextAlign.center,
                            ),
                            if (_importTask != null) ...[
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: () => _importTask?.cancel(),
                                icon: const Icon(Icons.close),
                                label: const Text('Cancel import'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  )
                : TabBarView(
                    children: mobile
                        ? [_auditTab()]
                        : [_auditTab(), _diffTab(), _gradeTab()],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _auditTab() => ListView(
    padding: EdgeInsets.fromLTRB(
      AppTheme.gutter(context),
      AppTheme.s16,
      AppTheme.gutter(context),
      AppTheme.s32,
    ),
    children: [
      _intro(
        SettingsService.isMobile
            ? 'Inspect the file locally without a desktop engine. The app reads recognized devices, cables, interface addresses, and enabled service roles; live simulation results are not tested.'
            : 'Read any saved .pkt directly - no Packet Tracer opens. Shows devices, cabling, service panels, AAA state and a findings list with severity.',
      ),
      FilledButton.icon(
        onPressed: _runAudit,
        icon: const Icon(Icons.plagiarism_outlined),
        label: Text(
          SettingsService.isMobile
              ? 'Pick a .pkt and inspect locally'
              : 'Pick a .pkt and audit it',
        ),
      ),
      if ((_lastPath != null || _lastBytes != null) &&
          widget.onOpenImportedPlan != null) ...[
        const SizedBox(height: AppTheme.s8),
        OutlinedButton.icon(
          onPressed: _openEditablePlan,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Open this file as an editable plan'),
        ),
      ],
      if (_auditReport != null) ...[
        const SizedBox(height: AppTheme.s16),
        for (final detail
            in (_auditReport!['preservedDetails'] as List? ?? const []))
          AppBanner(tone: AppTone.success, dense: true, message: '$detail'),
        for (final detail
            in (_auditReport!['limitations'] as List? ?? const []))
          AppBanner(tone: AppTone.warning, dense: true, message: '$detail'),
        if ((_auditReport!['preservedDetails'] as List? ?? const [])
                .isNotEmpty ||
            (_auditReport!['limitations'] as List? ?? const []).isNotEmpty)
          const SizedBox(height: AppTheme.s8),
        _summaryCard(_auditReport!['summary'] as Map? ?? {}),
        const SizedBox(height: AppTheme.s12),
        if (_auditReport!['mode'] == 'local-import')
          AppBanner(
            dense: true,
            tone: AppTone.info,
            message: '${_auditReport!['note']}',
          )
        else
          ..._findingRows(_auditReport!['findings'] as List? ?? const []),
        const SizedBox(height: AppTheme.s12),
        _devicesCard(_auditReport!['devices'] as List? ?? const []),
        const SizedBox(height: AppTheme.s12),
        _servicesCard(_auditReport!['services'] as Map? ?? {}),
      ],
    ],
  );

  Widget _diffTab() => ListView(
    padding: EdgeInsets.fromLTRB(
      AppTheme.gutter(context),
      AppTheme.s16,
      AppTheme.gutter(context),
      AppTheme.s32,
    ),
    children: [
      _intro(
        'Compare two saves: devices and cables added or removed, '
        'config lines that changed, services switched on or off.',
      ),
      FilledButton.icon(
        onPressed: _runDiff,
        icon: const Icon(Icons.difference_outlined),
        label: const Text('Pick two saves to diff'),
      ),
      if (_diffReport != null) ...[
        const SizedBox(height: AppTheme.s16),
        if (_diffReport!['unchanged'] == true)
          const AppStatusPill(label: 'No differences found', ok: true),
        ..._changeSection('Devices added', _diffReport!['devicesAdded']),
        ..._changeSection('Devices removed', _diffReport!['devicesRemoved']),
        ..._changeSection('Cables added', _diffReport!['linksAdded']),
        ..._changeSection('Cables removed', _diffReport!['linksRemoved']),
        ..._configChangeRows(
          _diffReport!['configChanges'] as List? ?? const [],
        ),
        ..._serviceChangeRows(
          _diffReport!['serviceChanges'] as List? ?? const [],
        ),
      ],
    ],
  );

  Widget _gradeTab() => ListView(
    padding: EdgeInsets.fromLTRB(
      AppTheme.gutter(context),
      AppTheme.s16,
      AppTheme.gutter(context),
      AppTheme.s32,
    ),
    children: [
      _intro(
        'Score a saved .pkt against the plan that is open in the app: '
        'devices, cables, addresses, every planned service, and AAA on '
        'both ends.',
      ),
      FilledButton.icon(
        onPressed: _runGrade,
        icon: const Icon(Icons.fact_check_outlined),
        label: const Text('Pick a .pkt and grade it'),
      ),
      if (_gradeReport != null) ...[
        const SizedBox(height: AppTheme.s16),
        _scoreCard(_gradeReport!),
        const SizedBox(height: AppTheme.s12),
        ..._requirementRows(_gradeReport!['requirements'] as List? ?? const []),
      ],
    ],
  );

  Widget _intro(String text) => AppBanner(tone: AppTone.info, message: text);

  Widget _summaryCard(Map summary) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppTheme.s12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          _stat('Devices', summary['devices']),
          _stat('Cables', summary['links']),
          _stat('Services on', summary['servicesEnabled']),
          _stat('Findings', summary['findings']),
          _stat('High severity', summary['high']),
        ],
      ),
    ),
  );

  Widget _stat(String label, dynamic value) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$value', style: Theme.of(context).textTheme.titleLarge),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );

  List<Widget> _findingRows(List findings) {
    final scheme = Theme.of(context).colorScheme;
    if (findings.isEmpty) {
      return const [
        AppStatusPill(label: 'No findings - nothing looks wrong', ok: true),
      ];
    }
    return [
      for (final f in findings.whereType<Map>())
        ListTile(
          dense: true,
          leading: Icon(
            f['severity'] == 'high'
                ? Icons.error
                : f['severity'] == 'medium'
                ? Icons.warning_amber_rounded
                : Icons.info_outline,
            color: f['severity'] == 'high'
                ? AppPalette.danger(scheme)
                : f['severity'] == 'medium'
                ? AppPalette.warning(scheme)
                : null,
          ),
          title: Text(
            '${f['device']}: ${f['text']}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
    ];
  }

  Widget _devicesCard(List devices) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppTheme.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Devices', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final d in devices.whereType<Map>())
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${d['name']}  (${d['kind']}/${d['model']})'
                '${(d['ips'] as List?)?.isNotEmpty == true ? '  ${(d['ips'] as List).join(', ')}' : ''}',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _servicesCard(Map services) {
    final names = services.keys.toList()..sort();
    final scheme = Theme.of(context).colorScheme;
    if (names.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Service panels',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            for (final name in names)
              for (final row
                  in ((services[name] as List?) ?? const []).whereType<Map>())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '$name  ${row['service']}: '
                    '${row['enabled'] == true ? 'ON' : 'off'}'
                    '${row['detail']?.toString().isNotEmpty == true ? '  (${row['detail']})' : ''}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: row['enabled'] == true
                          ? AppPalette.success(scheme)
                          : null,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  List<Widget> _changeSection(String title, dynamic items) {
    final list = (items as List?) ?? const [];
    if (list.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: AppTheme.s8, bottom: 4),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      for (final item in list)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text('- $item', style: const TextStyle(fontSize: 12.5)),
        ),
    ];
  }

  List<Widget> _configChangeRows(List changes) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final c in changes.whereType<Map>()) ...[
        Padding(
          padding: const EdgeInsets.only(top: AppTheme.s8, bottom: 4),
          child: Text(
            '${c['device']} config changed',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        for (final line in (c['added'] as List? ?? const []))
          Text(
            '+ $line',
            style: TextStyle(fontSize: 12, color: AppPalette.success(scheme)),
          ),
        for (final line in (c['removed'] as List? ?? const []))
          Text(
            '- $line',
            style: TextStyle(fontSize: 12, color: AppPalette.danger(scheme)),
          ),
      ],
    ];
  }

  List<Widget> _serviceChangeRows(List changes) {
    if (changes.isEmpty) return [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: AppTheme.s8, bottom: 4),
        child: Text(
          'Service panels changed',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      for (final c in changes.whereType<Map>())
        Text(
          '${c['device']}: ${c['service']} '
          '${c['was'] == true ? 'ON' : 'off'} -> '
          '${c['now'] == true ? 'ON' : 'off'}',
          style: const TextStyle(fontSize: 12.5),
        ),
    ];
  }

  Widget _scoreCard(Map report) => Card(
    color: (report['percent'] as num?) == 100.0
        ? AppPalette.successFill(Theme.of(context).colorScheme)
        : null,
    child: Padding(
      padding: const EdgeInsets.all(AppTheme.s16),
      child: Row(
        children: [
          Text(
            '${report['percent'] ?? '?'}%',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: AppTheme.s16),
          Expanded(
            child: Text(
              '${report['score']} of ${report['max']} requirements met'
              '$_lastSuffix',
            ),
          ),
        ],
      ),
    ),
  );

  String get _lastSuffix => _lastPath == null ? '' : '\n$_lastPath';

  List<Widget> _requirementRows(List requirements) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final r in requirements.whereType<Map>())
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                r['ok'] == true ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: r['ok'] == true
                    ? AppPalette.success(scheme)
                    : AppPalette.danger(scheme),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${r['name']} - ${r['detail']}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
    ];
  }
}
