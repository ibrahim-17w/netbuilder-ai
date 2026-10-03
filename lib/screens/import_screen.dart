import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/autopilot_service.dart';
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

  const ImportScreen({super.key, required this.planLoader});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String? _lastPath;
  Map<String, dynamic>? _auditReport;
  Map<String, dynamic>? _diffReport;
  Map<String, dynamic>? _gradeReport;

  Future<String?> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Pick a Packet Tracer save',
    );
    return result?.files.single.path;
  }

  Future<void> _runAudit() async {
    final engine = AutopilotService.of(context);
    final path = await _pick();
    if (path == null) return;
    setState(() {
      _busy = true;
      _lastPath = path;
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No plan is open - open or create a plan first.'),
      ));
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
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppTheme.gutter(context),
              AppTheme.s20,
              AppTheme.gutter(context),
              AppTheme.s12,
            ),
            child: const AppPageHeader(
              eyebrow: 'Inspect',
              title: 'Open & inspect .pkt',
              description:
                  'Audit, diff and grade any saved .pkt without opening '
                  'Packet Tracer. Everything here is read-only.',
            ),
          ),
          const TabBar(tabs: [
            Tab(text: 'Audit'),
            Tab(text: 'Diff'),
            Tab(text: 'Grade'),
          ]),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(children: [_auditTab(), _diffTab(), _gradeTab()]),
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
        _intro('Read any saved .pkt directly - no Packet Tracer opens. '
            'Shows devices, cabling, service panels, AAA state and a '
            'findings list with severity.'),
        FilledButton.icon(
          onPressed: _runAudit,
          icon: const Icon(Icons.plagiarism_outlined),
          label: const Text('Pick a .pkt and audit it'),
        ),
        if (_auditReport != null) ...[
          const SizedBox(height: AppTheme.s16),
          _summaryCard(_auditReport!['summary'] as Map? ?? {}),
          const SizedBox(height: AppTheme.s12),
          ..._findingRows(_auditReport!['findings'] as List? ?? const []),
          const SizedBox(height: AppTheme.s12),
          _devicesCard(_auditReport!['devices'] as List? ?? const []),
          const SizedBox(height: AppTheme.s12),
          _servicesCard(_auditReport!['services'] as Map? ?? {}),
        ],
      ]);

  Widget _diffTab() => ListView(
      padding: EdgeInsets.fromLTRB(
        AppTheme.gutter(context),
        AppTheme.s16,
        AppTheme.gutter(context),
        AppTheme.s32,
      ),
      children: [
        _intro('Compare two saves: devices and cables added or removed, '
            'config lines that changed, services switched on or off.'),
        FilledButton.icon(
          onPressed: _runDiff,
          icon: const Icon(Icons.difference_outlined),
          label: const Text('Pick two saves to diff'),
        ),          if (_diffReport != null) ...[
          const SizedBox(height: AppTheme.s16),
          if (_diffReport!['unchanged'] == true)
            const AppStatusPill(label: 'No differences found', ok: true),
          ..._changeSection('Devices added', _diffReport!['devicesAdded']),
          ..._changeSection('Devices removed', _diffReport!['devicesRemoved']),
          ..._changeSection('Cables added', _diffReport!['linksAdded']),
          ..._changeSection('Cables removed', _diffReport!['linksRemoved']),
          ..._configChangeRows(
              _diffReport!['configChanges'] as List? ?? const []),
          ..._serviceChangeRows(
              _diffReport!['serviceChanges'] as List? ?? const []),
        ],
      ]);

  Widget _gradeTab() => ListView(
      padding: EdgeInsets.fromLTRB(
        AppTheme.gutter(context),
        AppTheme.s16,
        AppTheme.gutter(context),
        AppTheme.s32,
      ),
      children: [
        _intro('Score a saved .pkt against the plan that is open in the app: '
            'devices, cables, addresses, every planned service, and AAA on '
            'both ends.'),
        FilledButton.icon(
          onPressed: _runGrade,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Pick a .pkt and grade it'),
        ),
        if (_gradeReport != null) ...[
          const SizedBox(height: AppTheme.s16),
          _scoreCard(_gradeReport!),
          const SizedBox(height: AppTheme.s12),
          ..._requirementRows(
              _gradeReport!['requirements'] as List? ?? const []),
        ],
      ]);

  Widget _intro(String text) => AppBanner(
        tone: AppTone.info,
        message: text,
      );

  Widget _summaryCard(Map summary) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Wrap(spacing: 16, runSpacing: 8, children: [
            _stat('Devices', summary['devices']),
            _stat('Cables', summary['links']),
            _stat('Services on', summary['servicesEnabled']),
            _stat('Findings', summary['findings']),
            _stat('High severity', summary['high']),
          ]),
        ),
      );

  Widget _stat(String label, dynamic value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value',
              style: Theme.of(context).textTheme.titleLarge),
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
          title: Text('${f['device']}: ${f['text']}',
              style: const TextStyle(fontSize: 13)),
        ),
    ];
  }

  Widget _devicesCard(List devices) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Devices',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                for (final d in devices.whereType<Map>())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${d['name']}  (${d['kind']}/${d['model']})'
                      '${(d['ips'] as List?)?.isNotEmpty == true ? '  ${(d['ips'] as List).join(', ')}' : ''}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ]),
        ),
      );

  Widget _servicesCard(Map services) {
    final names = services.keys.toList()..sort();
    final scheme = Theme.of(context).colorScheme;
    if (names.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.s12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Service panels',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final name in names)
            for (final row in ((services[name] as List?) ?? const [])
                .whereType<Map>())
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
        ]),
      ),
    );
  }

  List<Widget> _changeSection(String title, dynamic items) {
    final list = (items as List?) ?? const [];
    if (list.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: AppTheme.s8, bottom: 4),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
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
            child: Text('${c['device']} config changed',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final line in (c['added'] as List? ?? const []))
            Text('+ $line',
                style: TextStyle(
                    fontSize: 12, color: AppPalette.success(scheme))),
          for (final line in (c['removed'] as List? ?? const []))
            Text('- $line',
                style: TextStyle(
                    fontSize: 12, color: AppPalette.danger(scheme))),
        ],
      ];
  }

  List<Widget> _serviceChangeRows(List changes) {
    if (changes.isEmpty) return [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: AppTheme.s8, bottom: 4),
        child: Text('Service panels changed',
            style: TextStyle(fontWeight: FontWeight.bold)),
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
          child: Row(children: [
            Text(
              '${report['percent'] ?? '?'}%',
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: AppTheme.s16),
            Expanded(
              child: Text(
                '${report['score']} of ${report['max']} requirements met'
                '$_lastSuffix',
              ),
            ),
          ]),
        ),
      );

  String get _lastSuffix =>
      _lastPath == null ? '' : '\n$_lastPath';

  List<Widget> _requirementRows(List requirements) {
    final scheme = Theme.of(context).colorScheme;
    return [
        for (final r in requirements.whereType<Map>())
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(
                r['ok'] == true ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: r['ok'] == true
                    ? AppPalette.success(scheme)
                    : AppPalette.danger(scheme),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${r['name']} - ${r['detail']}',
                    style: const TextStyle(fontSize: 12.5)),
              ),
            ]),
          ),
      ];
  }
}
