import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/network_intent.dart';
import '../services/autopilot_service.dart';

/// Safe Packet Tracer file workflow.
///
/// The sidecar owns backups and all Packet Tracer interaction. A native picker
/// is used for the normal Windows flow; the path field remains available for
/// automation and test environments.
class PktFilesScreen extends StatefulWidget {
  final String initialProject;
  final NetworkIntent? intent;
  final ValueChanged<String>? onAnalyze;

  const PktFilesScreen({
    super.key,
    this.initialProject = 'default',
    this.intent,
    this.onAnalyze,
  });

  @override
  State<PktFilesScreen> createState() => _PktFilesScreenState();
}

class _PktFilesScreenState extends State<PktFilesScreen> {
  late final TextEditingController _path;
  late final TextEditingController _output;
  late final TextEditingController _project;
  Map<String, dynamic>? _report;
  Map<String, dynamic>? _analysis;
  Map<String, dynamic>? _lastOperation;
  /// Last saved artifact plus its planned-vs-recorded comparison.
  Map<String, dynamic>? _artifact;
  bool _busy = false;
  String _message =
      'Choose a .pkt file. Read checks the file and companion data; '
      'Open + analyze loads it in Packet Tracer and runs a read-only audit.';

  @override
  void initState() {
    super.initState();
    _project = TextEditingController(
      text: widget.initialProject.trim().isEmpty
          ? 'default'
          : widget.initialProject.trim(),
    );
    _path = TextEditingController();
    _output = TextEditingController();
  }

  Future<void> _pickPkt() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pkt'],
        allowMultiple: false,
        dialogTitle: 'Choose a Packet Tracer .pkt file',
      );
      final selected = result?.files.single.path;
      if (selected == null || selected.trim().isEmpty) return;
      if (p.extension(selected).toLowerCase() != '.pkt') {
        setState(
          () => _message = 'Choose a Packet Tracer file ending in .pkt.',
        );
        return;
      }
      final stem = p.basenameWithoutExtension(selected).trim();
      setState(() {
        _path.text = selected;
        if (_project.text.trim().isEmpty ||
            _project.text.trim().toLowerCase() == 'default') {
          _project.text = stem.isEmpty ? 'default' : stem;
        }
        _report = null;
        _analysis = null;
        _message =
            'Selected ${p.basename(selected)}. Read it or open and analyze it.';
      });
    } catch (e) {
      if (mounted) setState(() => _message = _cleanError(e));
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _output.dispose();
    _project.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _message = 'Enter the full path to a .pkt file first.');
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Reading the .pkt file without changing it...';
    });
    try {
      final report = await AutopilotService().pktRead(
        path,
        project: _project.text.trim().isEmpty
            ? 'default'
            : _project.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _message =
            'Read complete. The binary was not rewritten. Use Analyze after '
            'opening it to verify the live topology contents.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _message = 'Enter the full path to a .pkt file first.');
      return;
    }
    setState(() {
      _busy = true;
      _message =
          'Opening in Packet Tracer and creating a recoverable backup...';
    });
    try {
      await AutopilotService().pktOpen(path);
      final result = await _waitForPktOperation();
      if (!mounted) return;
      final ok = result['ok'] == true;
      setState(() {
        _lastOperation = result;
        _message = ok
            ? 'Opened and backed up. Packet Tracer is visible; run Analyze '
                  'to verify devices, links, and configuration.'
            : 'Open failed: ${result['error'] ?? 'unknown error'}';
      });
      if (ok) await _readSilently();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAndAnalyze() async {
    final path = _path.text.trim();
    final project = _project.text.trim().isEmpty
        ? 'default'
        : _project.text.trim();
    if (path.isEmpty) {
      setState(() => _message = 'Choose a .pkt file first.');
      return;
    }
    setState(() {
      _busy = true;
      _analysis = null;
      _message =
          'Reading the file, opening Packet Tracer, then starting a read-only analysis...';
    });
    try {
      final svc = AutopilotService();
      final report = await svc.pktRead(path, project: project);
      if (mounted) setState(() => _report = report);
      await svc.pktOpen(path);
      final opened = await _waitForPktOperation();
      if (opened['ok'] != true) {
        if (mounted) {
          setState(
            () => _message =
                'The .pkt was not opened: ${opened['error'] ?? 'unknown error'}',
          );
        }
        return;
      }
      await svc.auditStart(project);
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        final response = await svc.auditReport();
        if (response['running'] == false) {
          final audit = response['report'] as Map?;
          setState(() {
            _analysis = audit == null
                ? <String, dynamic>{'error': 'The analyzer returned no report.'}
                : Map<String, dynamic>.from(audit);
            _message = audit == null
                ? 'Packet Tracer opened, but no analysis report was returned.'
                : 'Read-only analysis finished. No network changes were made.';
          });
          return;
        }
      }
      if (mounted) {
        setState(
          () => _message =
              'Analysis timed out. Press Stop if Packet Tracer is still busy.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAs() async {
    final output = _output.text.trim();
    if (output.isEmpty) {
      setState(
        () => _message = 'Enter a new output path for the generated .pkt.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Saving the current Packet Tracer topology as a new .pkt...';
    });
    try {
      await AutopilotService().pktSaveAs(
        output,
        manifest:
            widget.intent?.toPlannerJson() ??
            <String, dynamic>{'projectName': _project.text.trim()},
      );
      final result = await _waitForPktOperation();
      if (!mounted) return;
      final ok = result['ok'] == true;
      setState(() {
        _lastOperation = result;
        _message = ok
            ? 'Saved a new .pkt and companion manifest. Verify it by reopening '
                  'the saved file.'
            : 'Save failed: ${result['error'] ?? 'unknown error'}';
      });
      if (ok) {
        _path.text = output;
        await _readSilently();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Save the live topology with its companion manifest and comparison, then
  /// reopen it. This is what a green build run does automatically.
  Future<void> _saveVerified() async {
    setState(() {
      _busy = true;
      _message = 'Saving the live topology as a verified .pkt '
          'artifact...';
    });
    try {
      await AutopilotService().pktSaveVerified(
        project: _project.text.trim().isEmpty
            ? 'default'
            : _project.text.trim(),
        reopen: true,
      );
      final result = await _waitForPktOperation();
      final report = await AutopilotService().pktReport();
      if (!mounted) return;
      final ok = result['ok'] == true;
      final comparison = (report?['comparison'] as Map?) ?? const {};
      setState(() {
        _lastOperation = result;
        _artifact = report;
        _message = ok
            ? 'Saved ${report?['path'] ?? result['path'] ?? 'the artifact'} '
                  'with its companion manifest. '
                  'devices=${comparison['devicesOnCanvas'] ?? '?'}'
                  '/${comparison['plannedDevices'] ?? '?'}, '
                  'links failed=${comparison['linksFailed'] ?? 0}, '
                  'CLI blocks=${comparison['cliBlocks'] ?? 0}.'
            : 'Verified save failed: ${result['error'] ?? 'unknown error'}';
      });
      if (ok) {
        final saved = report?['path'] as String?;
        if (saved != null && saved.isNotEmpty) {
          _path.text = saved;
          await _readSilently();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _message = 'Enter the saved .pkt path first.');
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Reopening the saved file for Packet Tracer verification...';
    });
    try {
      await AutopilotService().pktVerify(path);
      final result = await _waitForPktOperation();
      if (!mounted) return;
      final ok = result['ok'] == true;
      setState(() {
        _lastOperation = result;
        _message = ok
            ? 'Reopen check passed: Packet Tracer became available. Run Analyze '
                  'for content-level verification.'
            : 'Reopen check failed: ${result['error'] ?? 'unknown error'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readSilently() async {
    try {
      final report = await AutopilotService().pktRead(
        _path.text.trim(),
        project: _project.text.trim().isEmpty
            ? 'default'
            : _project.text.trim(),
      );
      if (mounted) setState(() => _report = report);
    } catch (_) {
      // The operation result is more useful than replacing it with a second
      // metadata error; the user can press Read explicitly.
    }
  }

  Future<Map<String, dynamic>> _waitForPktOperation() async {
    for (var i = 0; i < 160; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final status = await AutopilotService().pktStatus();
      if (status['operation'] == null) {
        return Map<String, dynamic>.from(
          (status['last'] as Map?) ?? <String, dynamic>{'ok': false},
        );
      }
      if (!mounted) break;
    }
    return <String, dynamic>{
      'ok': false,
      'error':
          'Operation timed out. Press Stop if Packet Tracer is still busy.',
    };
  }

  Future<void> _stop() async {
    try {
      await AutopilotService().stop();
      if (mounted) setState(() => _message = 'Stop requested.');
    } catch (e) {
      if (mounted) setState(() => _message = _cleanError(e));
    }
  }

  String _cleanError(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  /// The saved artifact: where it is and what the run proved about it.
  Widget _artifactCard() {
    final artifact = _artifact!;
    final comparison = (artifact['comparison'] as Map?) ?? const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SelectableText(
          'Verified artifact:\n'
          '  file: ${artifact['path'] ?? 'unknown'}\n'
          '  bytes: ${artifact['bytes'] ?? '?'}'
          '${artifact['sha256'] == null ? '' : '  sha256: ${artifact['sha256']}'}\n'
          '  manifest: ${artifact['manifest'] ?? 'none'}\n'
          '  reopened: ${artifact['reopened'] == true ? 'yes' : 'no'}\n'
          '  planned: ${comparison['plannedDevices'] ?? '?'} devices, '
          '${comparison['plannedLinks'] ?? '?'} links\n'
          '  recorded: ${comparison['devicesOnCanvas'] ?? '?'} devices, '
          '${comparison['linksRecorded'] ?? '?'} links '
          '(${comparison['linksFailed'] ?? 0} failed)\n'
          '  missing: '
          '${(comparison['devicesMissing'] as List?)?.join(', ') ?? 'none'}\n'
          '  CLI blocks: ${comparison['cliBlocks'] ?? 0}  '
          'configs verified: ${comparison['configsVerified'] ?? 0}  '
          'pings: ${comparison['pingsOk'] ?? 0} ok / '
          '${comparison['pingsFailed'] ?? 0} failed',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _infoCard() {
    final report = _report;
    if (report == null) return const SizedBox.shrink();
    final manifest = report['manifest'];
    final live = report['liveInventory'];
    final pkt = jsonEncode({
      'name': report['name'],
      'bytes': report['bytes'],
      'modified': report['modified'],
      'sha256': report['sha256'],
    });
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'File report',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SelectableText(pkt, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            Text(
              manifest == null
                  ? 'No NetBuilder companion manifest found.'
                  : 'Companion manifest found: generated intent is available.',
            ),
            Text(
              live == null
                  ? 'Live topology contents: not verified yet.'
                  : 'Live inventory is available for this project.',
            ),
            if (report['backup'] != null)
              SelectableText(
                'Backup: ${report['backup']}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _analysisCard() {
    final analysis = _analysis;
    if (analysis == null) return const SizedBox.shrink();
    final devices = (analysis['devices'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final error = (analysis['error'] ?? '').toString();
    return Card(
      color: error.isEmpty ? Colors.green.shade50 : Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Topology analysis',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.red)),
            Text('Devices inspected: ${devices.length}'),
            Text('Red link indicators: ${analysis['red_dots'] ?? 0}'),
            if ((analysis['note'] ?? '').toString().isNotEmpty)
              Text(analysis['note'].toString()),
            if (devices.isNotEmpty)
              for (final device in devices)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${device['name'] ?? 'device'} (${device['type'] ?? 'unknown'})',
                  ),
                  subtitle: Text(
                    '${((device['findings'] as List?) ?? const []).length} finding(s)',
                  ),
                ),
            const Text(
              'This report is read-only. Suggested fixes still require approval in Analyze.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Card(
            color: Color(0xFFE8F5E9),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Choose a .pkt file with the file picker. Read checks its metadata '
                'and companion manifest without rewriting it. Open + analyze makes '
                'a backup, loads it in Packet Tracer, and runs a read-only audit. '
                'No fixes are applied automatically.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _project,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Project name for live analysis',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _path,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Existing .pkt path',
              hintText: r'C:\Labs\office.pkt',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pickPkt,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose .pkt file'),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _read,
                icon: const Icon(Icons.description),
                label: const Text('Inspect .pkt'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _open,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open + backup'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _openAndAnalyze,
                icon: const Icon(Icons.analytics),
                label: const Text('Open + analyze'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _verify,
                icon: const Icon(Icons.verified),
                label: const Text('Reopen verify'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _output,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'New output .pkt path',
              hintText: r'C:\Labs\office-generated.pkt',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _saveAs,
            icon: const Icon(Icons.save_as),
            label: const Text('Save current topology as new .pkt'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _saveVerified,
            icon: const Icon(Icons.inventory_2),
            label: const Text('Save verified artifact (.pkt + report)'),
          ),
          const SizedBox(height: 8),
          if (_artifact != null) _artifactCard(),
          if (_busy) const LinearProgressIndicator(),
          Text(_message, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          _infoCard(),
          _analysisCard(),
          if (_lastOperation != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  'Last operation:\n${const JsonEncoder.withIndent('  ').convert(_lastOperation)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _stop,
            icon: const Icon(Icons.stop_circle),
            label: const Text('Stop Packet Tracer file activity'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: widget.onAnalyze == null || _busy
                ? null
                : () => widget.onAnalyze!(_project.text.trim()),
            icon: const Icon(Icons.fact_check),
            label: const Text('Analyze loaded topology'),
          ),
        ],
      ),
    );
  }
}
