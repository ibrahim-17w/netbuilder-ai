import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_attempt.dart';
import '../models/build_record.dart';
import '../services/autopilot_service.dart';
import '../services/memory_service.dart';
import '../widgets/correction_badges.dart';
import '../theme/app_palette.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  List<LearnedRule> _rules = [];
  List<BuildAttempt> _attempts = [];
  Map<String, String> _prefs = {};
  final _ruleCtl = TextEditingController();
  final _kCtl = TextEditingController();
  final _vCtl = TextEditingController();
  // Autopilot learning (sidecar failure journal)
  List<String> _suggestions = [];
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _experiences = [];
  Map<String, dynamic>? _learningMemory;
  CorrectionSnapshot _corrections = const CorrectionSnapshot.empty();
  bool _correctionsBusy = false;
  String? _correctionsNote;
  bool _learnLoading = false;
  bool _learningRefreshing = false;
  String? _learnError;
  int _autoSaved = 0;
  Timer? _learningTimer;
  bool _includeScreenshots = false;
  bool _diagnosticsBusy = false;
  String? _diagnosticsPath;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshLearning();
    _refreshCorrections();
    _learningTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        _refreshLearning(quiet: true);
        // Cheaper than the journal poll: once a minute the teaching-loop
        // state re-syncs, so a stale badge never outlives the run that
        // cleared it.
        _correctionsTick++;
        if (_correctionsTick >= 20) {
          _correctionsTick = 0;
          _refreshCorrections(quiet: true);
        }
      }
    });
  }

  int _correctionsTick = 0;

  /// Read /corrections. Best-effort: the card hides when the sidecar is
  /// offline and shows what happened on revert failures.
  Future<void> _refreshCorrections({bool quiet = false}) async {
    if (_correctionsBusy) return;
    _correctionsBusy = true;
    if (!quiet && mounted) setState(() {});
    try {
      final snap = await AutopilotService().correctionSnapshot();
      if (!mounted) return;
      setState(() {
        _corrections = snap;
        _correctionsNote = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _correctionsNote = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _correctionsBusy = false;
      if (mounted) setState(() {});
    }
  }

  /// Un-teach a verified (possibly stale) correction: removes the promoted
  /// entry and flips the row to reverted. Kept next to the row it acts on.
  Future<void> _revertCorrection(CorrectionRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Un-teach this correction?'),
        content: Text(
          'Removes the entry it promoted on the sidecar '
          '(${row.summaryLine}) and marks it reverted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Un-teach'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AutopilotService().revertCorrection(row.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Un-taught ${row.summaryLine}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not un-teach: ${e.toString().replaceFirst("Exception: ", "")}',
          ),
        ),
      );
    }
    await _refreshCorrections();
  }

  @override
  void dispose() {
    _ruleCtl.dispose();
    _kCtl.dispose();
    _vCtl.dispose();
    _learningTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final mem = context.read<MemoryService>();
    if (!mem.ready) return;
    _rules = await mem.allRules();
    _attempts = await mem.recentAttempts(limit: 12);
    _prefs = await mem.allPrefs();
    if (mounted) setState(() {});
  }

  /// AUTO-LEARN: recurring failure patterns are saved as rules
  /// automatically - no manual click. Training phase: the more runs,
  /// the more rules accumulate (deduped by exact text).
  Future<int> _autoSaveSuggestions(List<String> suggestions) async {
    final mem = context.read<MemoryService>();
    if (!mem.ready || suggestions.isEmpty) return 0;
    final existing = (await mem.allRules()).map((r) => r.ruleText).toSet();
    var saved = 0;
    for (final s in suggestions) {
      if (!existing.contains(s)) {
        await mem.addRule(s, targets: 'autopilot');
        saved++;
      }
    }
    return saved;
  }

  Future<void> _refreshLearning({bool quiet = false}) async {
    if (_learningRefreshing) return;
    _learningRefreshing = true;
    if (!quiet && mounted) {
      setState(() {
        _learnLoading = true;
        _learnError = null;
        _autoSaved = 0;
      });
    }
    try {
      final svc = AutopilotService();
      final st = await svc.stats();
      final sug = await svc.suggestions();
      final ev = await svc.events(limit: 25);
      final experiences = await svc.learningExperiences();
      final liveMemory = await svc.learningMemory();
      final saved = await _autoSaveSuggestions(sug);
      if (!mounted) return;
      setState(() {
        _stats = st;
        _suggestions = sug;
        _events = ev.reversed.toList(); // newest first
        _experiences = experiences.reversed.toList();
        _learningMemory = liveMemory;
        _autoSaved = saved;
        _learnError = null;
      });
      if (saved > 0 && mounted) await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _learnError = e.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      _learningRefreshing = false;
      if (mounted) setState(() => _learnLoading = false);
    }
  }

  Future<void> _exportDiagnostics() async {
    setState(() => _diagnosticsBusy = true);
    try {
      final result = await AutopilotService().exportDiagnostics(
        includeScreenshots: _includeScreenshots,
      );
      if (!mounted) return;
      setState(() => _diagnosticsPath = result['path']?.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics archive created locally.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Diagnostics export failed: $e')));
    } finally {
      if (mounted) setState(() => _diagnosticsBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mem = context.read<MemoryService>();
    final kinds = (_stats?['kinds'] as Map? ?? {}).map(
      (k, v) => MapEntry(k.toString(), v as Map),
    );
    final kindLine = kinds.isEmpty
        ? 'no journal data yet - run the autopilot once'
        : kinds.entries.map((e) => '${e.key}=${e.value['count']}').join(', ');
    final live =
        (_learningMemory?['learning'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        <String, dynamic>{};
    final persistent =
        (live['persistent'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        <String, dynamic>{};
    final liveSession = live['session']?.toString() ?? 'not connected';
    final liveEvents = live['events']?.toString() ?? '0';
    final banned = live['bannedCandidates']?.toString() ?? '0';
    final trusted = persistent['trusted']?.toString() ?? '0';
    final quarantined = persistent['quarantined']?.toString() ?? '0';
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
                'The sidecar learns while it works: failed clicks and commands '
                'are rejected for the current run, verified corrections are '
                'reused immediately, and only safe successful strategies are '
                'saved automatically. Risky network changes still require '
                'approval.',
              ),
            ),
          ),
          if (_attempts.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Recent build attempts',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            for (final a in _attempts.take(8))
              Card(
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    a.status == 'verified'
                        ? Icons.verified
                        : a.status == 'failed'
                        ? Icons.error_outline
                        : Icons.pending_actions,
                    color: a.status == 'verified'
                        ? Colors.green
                        : a.status == 'failed'
                        ? Colors.red
                        : Colors.blueGrey,
                  ),
                  title: Text('${a.projectName} · ${a.status}'),
                  subtitle: Text(
                    '${a.failureKind ?? 'no failure recorded'}'
                    '${a.correction == null ? '' : ' · correction saved'}',
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Autopilot learning (failure journal)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            'Cross-run problem stats: $kindLine',
            style: TextStyle(fontSize: 12, color: AppPalette.mutedText(Theme.of(context).colorScheme)),
          ),
          const SizedBox(height: 8),
          Card(
            color: AppPalette.accentFill(Theme.of(context).colorScheme),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Live learning (updates during a run)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Session $liveSession · $liveEvents learning events · '
                    '$banned failed candidates blocked now',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    '$trusted safe strategies remembered · '
                    '$quarantined quarantined after repeated failure',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'This memory is automatic; no save/approve click is needed.',
                    style: TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ],
              ),
            ),
          ),
          if (_autoSaved > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'AUTO-LEARNED: $_autoSaved recurring pattern(s) saved '
                'as rules - future builds use them automatically.',
                style: const TextStyle(fontSize: 12, color: Colors.green),
              ),
            ),
          const SizedBox(height: 8),
          if (_learnLoading) const LinearProgressIndicator(),
          // TEACHING-LOOP CORRECTIONS: stale ones are taught fixes that
          // stopped verifying; rejected ones a teach run disproved. Both are
          // reported here instead of failing silently.
          CorrectionsCard(
            snapshot: _corrections,
            onRefresh: _correctionsBusy ? null : () => _refreshCorrections(),
            onRevert: _revertCorrection,
          ),
          if (_correctionsBusy && _corrections.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                'Reading corrections from the sidecar...',
                style: TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ),
          if (_correctionsNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _correctionsNote!,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ),
          if (_learnError != null)
            Text(
              'Sidecar offline - start sidecar/pt_autopilot.py to read '
              'the learning journal.\n$_learnError',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          for (final s in _suggestions)
            Card(
              color: AppPalette.warningFill(Theme.of(context).colorScheme),
              child: ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text(s, style: const TextStyle(fontSize: 13)),
                subtitle: const Text('Automatically recorded as a rule'),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _learnLoading ? null : () => _refreshLearning(),
                  child: const Text('Refresh learning'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  child: const Text('Clear journal'),
                  onPressed: () async {
                    try {
                      await AutopilotService().eventsClear();
                    } catch (_) {}
                    await _refreshLearning();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            color: AppPalette.infoFill(Theme.of(context).colorScheme),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tester diagnostics',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Creates a local redacted archive you can send to me. '
                    'It excludes API keys, passwords, raw configurations, '
                    'and .pkt files by default.',
                    style: TextStyle(fontSize: 12),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Include screenshots'),
                    subtitle: const Text(
                      'Screenshots may contain visible names or addresses.',
                    ),
                    value: _includeScreenshots,
                    onChanged: _diagnosticsBusy
                        ? null
                        : (value) =>
                              setState(() => _includeScreenshots = value),
                  ),
                  OutlinedButton.icon(
                    onPressed: _diagnosticsBusy ? null : _exportDiagnostics,
                    icon: const Icon(Icons.archive_outlined),
                    label: Text(
                      _diagnosticsBusy
                          ? 'Creating archive...'
                          : 'Export diagnostics',
                    ),
                  ),
                  if (_diagnosticsPath != null)
                    SelectableText(
                      'Created: $_diagnosticsPath',
                      style: const TextStyle(fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_experiences.isNotEmpty)
            Card(
              color: AppPalette.infoFill(Theme.of(context).colorScheme),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Structured experiences (${_experiences.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    for (final x in _experiences.take(6))
                      Text(
                        '${x['device'] ?? ''} · ${x['kind'] ?? ''} · '
                        '${x['result'] ?? ''}: ${x['detail'] ?? ''}',
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
          if (_experiences.isNotEmpty) const SizedBox(height: 8),
          if (_events.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Recent events (newest first)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    for (final e in _events.take(10))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          '${e['ts'] ?? ''} [${e['kind']}] ${e['detail'] ?? ''}'
                          ' ${(e['recovered'] == true)
                              ? "(recovered)"
                              : (e['recovered'] == false)
                              ? "(UNRECOVERED)"
                              : ""}',
                          style: TextStyle(
                            fontSize: 11,
                            color: e['recovered'] == false
                                ? AppPalette.danger(Theme.of(context).colorScheme)
                                : Colors.black87,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'Learned rules',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          for (final r in _rules)
            Card(
              child: ListTile(
                title: Text(r.ruleText),
                subtitle: Text('${r.targets}  hits=${r.hits} miss=${r.misses}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'helpful',
                      icon: const Icon(Icons.thumb_up),
                      onPressed: () async {
                        await mem.markRule(r.id!, true);
                        await _refresh();
                      },
                    ),
                    IconButton(
                      tooltip: 'not helpful',
                      icon: const Icon(Icons.thumb_down),
                      onPressed: () async {
                        await mem.markRule(r.id!, false);
                        await _refresh();
                      },
                    ),
                  ],
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ruleCtl,
                  decoration: const InputDecoration(
                    hintText: 'Add rule manually',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  if (_ruleCtl.text.trim().isEmpty) return;
                  await mem.addRule(_ruleCtl.text.trim());
                  _ruleCtl.clear();
                  await _refresh();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Preferences',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          for (final e in _prefs.entries) Text('${e.key} = ${e.value}'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _kCtl,
                  decoration: const InputDecoration(hintText: 'key'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _vCtl,
                  decoration: const InputDecoration(hintText: 'value'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: () async {
                  if (_kCtl.text.isEmpty) return;
                  await mem.setPref(_kCtl.text.trim(), _vCtl.text.trim());
                  _kCtl.clear();
                  _vCtl.clear();
                  await _refresh();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  child: const Text('Refresh'),
                  onPressed: () => _refresh(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade100,
                  ),
                  child: const Text('Clear all memory'),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Clear all local memory?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await mem.clearAll();
                      await _refresh();
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
