import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/memory_service.dart';
import '../services/project_checks.dart';
import '../services/plan_version_service.dart';
import '../services/settings_service.dart';

class ProjectChecksScreen extends StatefulWidget {
  final BuildRecord record;
  const ProjectChecksScreen({super.key, required this.record});
  @override
  State<ProjectChecksScreen> createState() => _ProjectChecksScreenState();
}

class _ProjectChecksScreenState extends State<ProjectChecksScreen> {
  late final plan = NetworkIntent.fromJson(
    Map<String, dynamic>.from(jsonDecode(widget.record.intentJson)),
  );
  late ProjectChecks store;
  List<ProjectCheck> checks = [];
  bool busy = true;
  String error = '';
  @override
  void initState() {
    super.initState();
    store = ProjectChecks(
      context.read<MemoryService>(),
      PlanVersionService.projectKeyOf(widget.record),
    );
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await store.load();
      if (mounted) setState(() => checks = rows);
    } catch (_) {
      if (mounted) setState(() => error = 'Saved checks could not be loaded.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save(List<ProjectCheck> rows) async {
    await store.save(rows);
    if (mounted) setState(() => checks = rows);
  }

  Future<void> _add() async {
    String? source, destination;
    var allow = true;
    final result = await showDialog<ProjectCheck>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Add a network check'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Source'),
                  items: [
                    for (final n in plan.nodes)
                      DropdownMenuItem(value: n.name, child: Text(n.name)),
                  ],
                  onChanged: (v) => update(() => source = v),
                ),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Destination'),
                  items: [
                    for (final n in plan.nodes)
                      DropdownMenuItem(value: n.name, child: Text(n.name)),
                  ],
                  onChanged: (v) => update(() => destination = v),
                ),
                SwitchListTile(
                  title: const Text('Must respond to ping'),
                  subtitle: Text(
                    allow
                        ? 'Live check where supported'
                        : 'Blocking policy requires manual evidence',
                  ),
                  value: allow,
                  onChanged: (v) => update(() => allow = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  source == null || destination == null || source == destination
                  ? null
                  : () => Navigator.pop(
                      ctx,
                      ProjectChecks.create(
                        plan,
                        source!,
                        destination!,
                        allow: allow,
                      ),
                    ),
              child: const Text('Save check'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      try {
        await _save([...checks, result]);
      } catch (_) {
        if (mounted) setState(() => error = 'The check could not be saved.');
      }
    }
  }

  Future<void> _run() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final engine = AutopilotService.of(context);
      if (!await engine.healthy) throw StateError('engine unavailable');
      await engine.verifyRun(ProjectChecks.request(plan, checks));
      Map<String, dynamic>? report;
      for (var i = 0; i < 90; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        report = await engine.verifyReport();
        if (report != null && report['running'] != true) break;
      }
      if (report == null || report['running'] == true) {
        throw StateError('no completed report');
      }
      await _save([
        for (final c in checks) ProjectChecks.applyReport(c, plan, report),
      ]);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Live checks were not completed. Open the matching project in Packet Tracer and check the local engine.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Project checks')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          widget.record.projectName,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text(
          'Saved design assessments and live evidence are shown separately. Open this exact plan in Packet Tracer before running live checks.',
        ),
        if (!SettingsService.canHostEngine)
          const Text(
            'Live checks require Packet Tracer on a desktop. Saved checks and offline assessments work on this device.',
          ),
        if (error.isNotEmpty) Text(error),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : _add,
              icon: const Icon(Icons.add),
              label: const Text('Add check'),
            ),
            OutlinedButton(
              onPressed:
                  busy || checks.isEmpty || !SettingsService.canHostEngine
                  ? null
                  : _run,
              child: const Text('Run in Packet Tracer'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (!busy && checks.isEmpty) const Text('No checks saved yet.'),
        for (final c in checks)
          Card(
            child: ListTile(
              title: Text(c.label),
              subtitle: Text(
                '${c.statusFor(plan)}${c.evidence.isEmpty ? '' : '\n${c.evidence}'}',
              ),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Offline design assessment'),
                  content: SingleChildScrollView(
                    child: Text(ProjectChecks.preview(c, plan)),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              trailing: IconButton(
                tooltip: 'Delete check',
                icon: const Icon(Icons.delete_outline),
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await _save(
                            checks.where((x) => x.id != c.id).toList(),
                          );
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => error = 'The check could not be removed.',
                            );
                          }
                        }
                      },
              ),
            ),
          ),
      ],
    ),
  );
}
