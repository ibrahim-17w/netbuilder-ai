import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/validator_service.dart';

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
      final svc = AutopilotService();
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() {
          _message = AutopilotService.startHint;
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
                const Text(
                  'The app will verify the result after the run. '
                  'It will not apply unselected findings.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
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
      final svc = AutopilotService();
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _message = AutopilotService.startHint);
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
    return ExpansionTile(
      initiallyExpanded: findings.any((f) => f['severity'] == 'high'),
      title: Text('$name (${dev['type'] ?? 'device'})'),
      subtitle: Text(
        findings.isEmpty ? 'No findings' : '${findings.length} finding(s)',
      ),
      children: [
        if (interfaces.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Interfaces: ${interfaces.map((i) => '${i['name']} ${i['status']}').join(' · ')}'
                '${ospf.isEmpty ? '' : '\nOSPF networks: $ospf'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        if (ipcfg.values.any((value) => value.toString().isNotEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'IPv4: ${ipcfg['ip'] ?? 'unreadable'}'
                '${(ipcfg['mask'] ?? '').toString().isEmpty ? '' : ' / ${ipcfg['mask']}'}'
                '${(ipcfg['gw'] ?? '').toString().isEmpty ? '' : '  gateway ${ipcfg['gw']}'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        if (services.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Services: ${services.map((service) {
                  final state = (service['state'] ?? 'unknown').toString();
                  final saved = service['saved_data'] == true ? ', saved data' : '';
                  final mode = service['verification_mode'] == 'state_only' ? ', state only' : ', rules verified';
                  return '${service['name'] ?? 'service'} ($state$saved$mode)';
                }).join(' · ')}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        for (final service in services)
          if ((service['evidence'] as List? ?? []).isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${service['name']}: ${(service['evidence'] as List).join(' | ')}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              ),
            ),
        for (final probe in probes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${probe['command']}: '
                '${probe['readable'] == true ? 'read' : 'unreadable'}'
                '${(probe['evidence'] as List? ?? []).isEmpty ? '' : ' · ${(probe['evidence'] as List).take(3).join(' | ')}'}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
            ),
          ),
        if (findings.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Clean - no actionable issue found.',
                style: TextStyle(color: Colors.green),
              ),
            ),
          ),
        for (final finding in findings) _buildFinding(name, finding),
        if (_pcFixFields[name] != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _pcFixFields[name]![1],
                    decoration: const InputDecoration(
                      labelText: 'Mask',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
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
    );
  }

  Widget _buildFinding(String device, Map finding) {
    final id = (finding['id'] ?? '').toString();
    final canFix = _hasFix(finding);
    final severity = (finding['severity'] ?? 'info').toString();
    final color = severity == 'high'
        ? Colors.red
        : severity == 'medium'
        ? Colors.orange
        : Colors.blueGrey;
    if (!canFix) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.info_outline, color: color),
        title: Text(finding['text'].toString()),
        subtitle: Text('$severity - informational only'),
      );
    }
    return CheckboxListTile(
      dense: true,
      value: _selectedFixes.contains(id),
      onChanged: _busy
          ? null
          : (value) => setState(() {
              value == true
                  ? _selectedFixes.add(id)
                  : _selectedFixes.remove(id);
            }),
      title: Text(finding['text'].toString()),
      subtitle: Text(
        '$severity - suggested fix available${finding['fix_pc'] == true ? ' - enter the gateway below' : ''}',
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
    return Card(
      color: failed is num && failed > 0
          ? Colors.red.shade50
          : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live connectivity tests',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Attempted ${reachability['attempted'] ?? 0} · '
              'passed $passed · failed $failed · skipped ${skipped.length}',
            ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.red)),
            for (final result in results)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  result['ok'] == true ? Icons.check_circle : Icons.error,
                  color: result['ok'] == true ? Colors.green : Colors.red,
                ),
                title: Text('${result['source']} → ${result['target']}'),
                subtitle: Text(
                  '${result['ok'] == true ? 'Reply received' : 'No verified reply'} · '
                  'attempts ${result['attempts'] ?? '?'}'
                  '${(result['evidence'] ?? '').toString().isEmpty ? '' : '\n${result['evidence']}'}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            for (final item in skipped)
              Text(
                'Skipped ${item['source']}: ${item['reason']}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            if (reachability['note'] != null)
              Text(
                reachability['note'].toString(),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final redDots = _report?['red_dots'] ?? 0;
    final error = (_report?['error'] ?? '').toString();
    final summary = Map<String, dynamic>.from(
      (_report?['summary'] as Map? ?? const {}),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Card(
            color: Color(0xFFE3F2FD),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Analyze is read-only. It reads the live Packet Tracer '
                'devices, interfaces, routing state, PC/server addressing, '
                'server service panels, and red link indicators. It never '
                'presses service On/Off or Add/Save. Connectivity is tested '
                'with real Packet Tracer pings from endpoint command prompts. '
                'Suggested fixes wait for your explicit approval before '
                'anything is changed.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _project,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Packet Tracer project name',
              hintText: 'office-net',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _analyze,
            icon: Icon(_analyzing ? Icons.hourglass_top : Icons.fact_check),
            label: Text(
              _analyzing
                  ? 'Analyzing and testing...'
                  : 'Analyze + test network',
            ),
          ),
          const SizedBox(height: 8),
          Text(_message, style: const TextStyle(fontSize: 12)),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_planIssues.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Current plan checks',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            for (final issue in _planIssues)
              Card(
                color: issue.severity == 'error'
                    ? Colors.red.shade50
                    : Colors.amber.shade50,
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    issue.severity == 'error'
                        ? Icons.error_outline
                        : Icons.warning_amber,
                  ),
                  title: Text(issue.message),
                  subtitle: Text(issue.severity),
                ),
              ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Analysis results',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('Project: ${_report!['project'] ?? _project.text}'),
                    Text(
                      'Red link indicators: $redDots',
                      style: TextStyle(
                        color: redDots is num && redDots > 0
                            ? Colors.red
                            : Colors.green,
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Scope: ${summary['device_count'] ?? 0} device(s) · '
                        '${summary['finding_count'] ?? 0} finding(s) · '
                        'types ${byType.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        'Severity: high ${severity['high'] ?? 0}, '
                        'medium ${severity['medium'] ?? 0}, '
                        'info ${severity['info'] ?? 0} · '
                        'interfaces up ${interfaces['up'] ?? 0}, '
                        'down ${interfaces['down'] ?? 0}, '
                        'admin-down ${interfaces['administratively_down'] ?? 0}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      if ((services['checked'] ?? 0) != 0)
                        Text(
                          'Services checked ${services['checked']}: '
                          'on ${services['on'] ?? 0}, off ${services['off'] ?? 0}, '
                          'unknown ${services['unknown'] ?? 0}, saved tables '
                          '${services['saved_data'] ?? 0}, rules verified '
                          '${services['rules_verified'] ?? 0}, state only '
                          '${services['state_only'] ?? 0}',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                    if ((_report!['scope'] as List? ?? []).isNotEmpty)
                      Text(
                        'Evidence: ${(_report!['scope'] as List).join(' · ')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    if (error.isNotEmpty)
                      Text(error, style: const TextStyle(color: Colors.red)),
                    if ((_report!['note'] ?? '').toString().isNotEmpty)
                      Text(_report!['note'].toString()),
                  ],
                ),
              ),
            ),
            if ((_report!['reachability'] as Map? ?? {}).isNotEmpty)
              _buildReachability(
                Map<String, dynamic>.from(_report!['reachability'] as Map),
              ),
            for (final dev in _devices()) _buildDevice(dev),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy || _selectedFixes.isEmpty
                  ? null
                  : _reviewAndApply,
              icon: const Icon(Icons.approval),
              label: Text(
                _selectedFixes.isEmpty
                    ? 'Select suggested fixes first'
                    : 'Review and approve ${_selectedFixes.length} fix(es)',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
