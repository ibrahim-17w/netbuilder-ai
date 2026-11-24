import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../models/pkt_verification.dart';
import '../services/autopilot_service.dart';
import '../services/memory_service.dart';
import '../services/project_checks.dart';
import '../services/plan_version_service.dart';
import '../services/settings_service.dart';
import '../services/pkt_build_job_service.dart';
import '../services/request_understanding/artifact_evidence_service.dart';
import '../services/request_understanding/build_action_identity.dart';
import '../widgets/pkt_verification_status.dart';

class ProjectChecksScreen extends StatefulWidget {
  final BuildRecord record;
  const ProjectChecksScreen({super.key, required this.record});
  @override
  State<ProjectChecksScreen> createState() => _ProjectChecksScreenState();
}

class _ProjectChecksScreenState extends State<ProjectChecksScreen> {
  late NetworkIntent plan = NetworkIntent.fromJson(
    Map<String, dynamic>.from(jsonDecode(widget.record.intentJson)),
  );
  late ProjectChecks store;
  List<ProjectCheck> checks = [];
  bool busy = true;
  bool _running = false;
  bool _stopRequested = false;
  int _runSequence = 0;
  String _runId = '';
  AutopilotService? _runEngine;
  String error = '';

  BuildActionIdentity get _action {
    final outcome = PlanVersionService.requestOutcomeOf(widget.record);
    final stored = PlanVersionService.actionIdentityOf(widget.record);
    final outcomeProject = outcome?.interpretation.projectId;
    final projectId = stored?.projectId.isNotEmpty == true
        ? stored!.projectId
        : outcomeProject?.isNotEmpty == true
        ? outcomeProject!
        : PlanVersionService.projectKeyOf(widget.record);
    return BuildActionIdentity.forPlan(
      plan: plan,
      requirements: outcome?.interpretation.requirements ?? const [],
      target: widget.record.target,
      projectId: projectId,
    );
  }

  @override
  void dispose() {
    _runSequence++;
    final engine = _runEngine;
    if (engine != null && _runId.isNotEmpty) {
      unawaited(_stopMatchingRun(engine, _runId));
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    store = ProjectChecks(
      context.read<MemoryService>(),
      PlanVersionService.projectKeyOf(widget.record),
    );
    _load();
    unawaited(PktBuildJobService.instance.loadHistory());
  }

  @override
  void didUpdateWidget(covariant ProjectChecksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.intentJson != widget.record.intentJson ||
        oldWidget.record.projectKey != widget.record.projectKey ||
        oldWidget.record.projectName != widget.record.projectName ||
        oldWidget.record.target != widget.record.target) {
      final engine = _runEngine;
      if (engine != null && _runId.isNotEmpty) {
        unawaited(_stopMatchingRun(engine, _runId));
      }
      _runSequence++;
      _running = false;
      _runId = '';
      _runEngine = null;
      plan = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(widget.record.intentJson)),
      );
      store = ProjectChecks(
        context.read<MemoryService>(),
        PlanVersionService.projectKeyOf(widget.record),
      );
      checks = [];
      busy = true;
      error = '';
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final loadingStore = store;
    try {
      final rows = await loadingStore.load();
      if (mounted && identical(store, loadingStore)) {
        setState(() => checks = rows);
      }
    } catch (_) {
      if (mounted && identical(store, loadingStore)) {
        setState(() => error = 'Saved checks could not be loaded.');
      }
    } finally {
      if (mounted && identical(store, loadingStore)) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _save(List<ProjectCheck> rows) async {
    final savingStore = store;
    await savingStore.save(rows);
    if (mounted && identical(store, savingStore)) {
      setState(() => checks = rows);
    }
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
    if (busy) return;
    final action = _action;
    final sequence = ++_runSequence;
    final engine = AutopilotService.of(context);
    final jobs = PktBuildJobService.instance;
    _runEngine = engine;
    setState(() {
      busy = true;
      _running = true;
      _stopRequested = false;
      _runId = '';
      error = '';
    });
    bool current() => mounted && sequence == _runSequence && _action == action;
    try {
      await jobs.loadHistory();
      final entry = jobs.history
          .where(
            (entry) =>
                entry.actionIdentity == action &&
                entry.filePath.isNotEmpty &&
                ArtifactEvidenceService.validHash(entry.artifactHash),
          )
          .firstOrNull;
      if (entry == null) {
        throw StateError(
          'No current saved file is bound to this plan and action. Generate '
          'the .pkt first; live checks remain unverified.',
        );
      }
      final hash = await ArtifactEvidenceService.contentHash(
        File(entry.filePath),
      );
      if (!entry.matchesArtifact(action, hash)) {
        throw StateError(
          'The saved file changed. Rebuild or re-audit the current file '
          'before native testing; live checks remain unverified.',
        );
      }
      if (!current() || _stopRequested) return;
      if (!await engine.healthy) throw StateError(engine.hint);
      if (!current() || _stopRequested) return;
      final runId = await engine.verifyRun(
        ProjectChecks.request(plan, checks),
        artifactPath: entry.filePath,
        artifactHash: hash,
        actionIdentity: action,
      );
      if (!current()) {
        await _stopMatchingRun(engine, runId);
        return;
      }
      _runId = runId;
      if (runId.isEmpty) throw StateError('Native engine returned no run ID.');
      if (_stopRequested) await _stopMatchingRun(engine, runId);
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (!current()) {
          await _stopMatchingRun(engine, runId);
          return;
        }
        final report = await engine.verifyReport(runId: runId);
        if (!current()) {
          await _stopMatchingRun(engine, runId);
          return;
        }
        if (report != null &&
            report['runId'] == runId &&
            report['running'] == false &&
            const [
              'completed',
              'failed',
              'cancelled',
            ].contains(report['state'])) {
          if (_stopRequested || report['state'] != 'completed') {
            throw StateError(
              'Live checks were stopped or failed; no successful '
              'completion was recorded.',
            );
          }
          final recorded = await jobs.recordNativeVerification(
            report,
            jobId: entry.id,
            expectedRunId: runId,
          );
          if (!current()) return;
          if (!recorded) {
            throw StateError(
              'The completed report does not match the current '
              'saved file and action. Live checks remain unverified.',
            );
          }
          final summary = jobs.history
              .where((row) => row.id == entry.id)
              .firstOrNull
              ?.verification;
          // The job service validates native identity and file-open proof.
          // Raw per-test counters alone must not promote saved project checks.
          if (summary?.nativeOpenState != PktVerificationCheckState.passed) {
            throw StateError(
              'Native file-open/topology evidence was not proven. '
              'Saved project checks remain unverified.',
            );
          }
          final normalized = <String, dynamic>{
            ...report,
            'tests': [
              for (final raw
                  in (report['tests'] as List? ?? const []).whereType<Map>())
                {
                  ...raw,
                  'status': switch (raw['status']) {
                    'pass' => 'passed',
                    'fail' => 'failed',
                    _ => raw['status'],
                  },
                },
            ],
          };
          await _save([
            for (final check in checks)
              ProjectChecks.applyReport(check, plan, normalized),
          ]);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final stopSent = await _stopMatchingRun(engine, runId);
      throw TimeoutException(
        'Live checks timed out. '
        '${stopSent ? 'Stop was requested.' : 'The active run could not be confirmed; use Stop in the engine.'} '
        'No completed evidence was recorded. Check the engine before retrying.',
      );
    } catch (failure) {
      if (_runId.isNotEmpty) await _stopMatchingRun(engine, _runId);
      if (current()) {
        setState(
          () => error = failure
              .toString()
              .replaceFirst('Bad state: ', '')
              .replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted && sequence == _runSequence) {
        setState(() {
          busy = false;
          _running = false;
          _runId = '';
          _runEngine = null;
        });
      }
    }
  }

  Future<bool> _stopMatchingRun(AutopilotService engine, String runId) async {
    try {
      final report = await engine.verifyReport(runId: runId);
      if (report?['runId'] == runId && report?['running'] == true) {
        await engine.stop();
        return true;
      }
    } catch (_) {
      // No successful stop claim without a correlated engine response.
    }
    return false;
  }

  Future<void> _stop() async {
    if (!_running || _stopRequested) return;
    setState(() {
      _stopRequested = true;
      error =
          'Stop requested. Waiting for the native worker to release; '
          'live checks remain unverified.';
    });
    final engine = _runEngine;
    if (engine != null && _runId.isNotEmpty) {
      await _stopMatchingRun(engine, _runId);
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
          'Saved design assessments and live evidence are shown separately. '
          'Live tests require the current .pkt file and build-action binding; '
          'an arbitrary open canvas is not verification of this plan.',
        ),
        ListenableBuilder(
          listenable: PktBuildJobService.instance,
          builder: (context, _) => PktVerificationStatus(
            verification: PktBuildJobService.instance.history
                .where((entry) => entry.actionIdentity == _action)
                .firstOrNull
                ?.verification,
          ),
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
            if (_running)
              OutlinedButton.icon(
                onPressed: _stopRequested ? null : _stop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(
                  _stopRequested ? 'Stopping...' : 'Stop live checks',
                ),
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
