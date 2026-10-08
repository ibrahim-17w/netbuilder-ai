import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_attempt.dart';
import '../models/build_record.dart';
import '../models/environment_profile.dart';
import '../services/autopilot_service.dart';
import '../services/memory_service.dart';
import '../services/misparse_ledger.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/correction_badges.dart';

/// The memory console: everything this app has learned, in one place.
///
/// The screen used to be one very long column: health, phrasings, attempts,
/// the failure journal, corrections, diagnostics, rules and preferences, in
/// the order the features had been added. All of it was real and none of it
/// was findable. It is now a header that always answers "is my memory
/// healthy?", a strip of live numbers, and five tabs - Rules, Phrasings,
/// Learning, Attempts, Tools - so a person can go straight to the store they
/// are thinking about.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

enum _MemoryTab { rules, phrasings, learned, environment, learning, attempts, tools }

class _MemoryScreenState extends State<MemoryScreen> {
  List<LearnedRule> _rules = [];
  List<BuildAttempt> _attempts = [];
  Map<String, String> _prefs = {};
  /// Learned answers from keyed-model replies (question -> answer),
  /// newest-seen first. Each row replays offline when the same question is
  /// asked with no key - and can be dropped here.
  List<Map<String, dynamic>> _learnedAnswers = [];
  /// Learned phrasings (words -> resolved brief), newest first. The app's
  /// own replay index: each row is a lesson the user can review and drop.
  List<Map<String, dynamic>> _phrasings = [];
  /// The misparse ledger: corrections the user made to a parse, newest
  /// first. Counted by [MemoryService], not by the sidecar - so the review
  /// list and the rate below still read when the sidecar is offline.
  List<MisparseEntry> _misparse = [];
  /// The rate's own numbers (turns, corrections, and what became of each
  /// row), kept apart from the sidecar health so a missing sidecar never
  /// blanks the strip.
  ({
    int turns,
    int corrections,
    int proposed,
    int taught,
    int dismissed,
  })? _misparseStats;
  /// One decision at a time: teach/dismiss are writes to the same blob, and
  /// a double tap would file the same lesson twice.
  bool _misparseBusy = false;
  /// The remembered environment (venue, scale, budget, skill), with its
  /// editor's working values. Learned automatically when the user states a
  /// fact in chat; edited here by hand.
  EnvironmentProfile? _envProfile;
  String _envVenue = '';
  final _envScaleCtl = TextEditingController();
  bool _envBudget = false;
  String _envSkill = '';
  final _ruleCtl = TextEditingController();
  final _kCtl = TextEditingController();
  final _vCtl = TextEditingController();
  // Autopilot learning (sidecar failure journal)
  List<String> _suggestions = [];
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _experiences = [];
  Map<String, dynamic>? _learningMemory;
  Map<String, dynamic>? _memoryHealth;
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
  _MemoryTab _tab = _MemoryTab.rules;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshLearning();
    _refreshCorrections();
    _refreshMemoryHealth();
    _refreshMisparse();
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
          _refreshMemoryHealth(quiet: true);
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
      final snap = await AutopilotService.of(context).correctionSnapshot();
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

  /// Read /memory/health: which stores exist, how many rows, and whether any
  /// failed to parse (the case that is otherwise invisible). Best-effort.
  Future<void> _refreshMemoryHealth({bool quiet = false}) async {
    try {
      final health = await AutopilotService.of(context).memoryHealth();
      if (!mounted) return;
      setState(() => _memoryHealth = health);
    } catch (_) {
      // Sidecar offline: keep the last value rather than flapping to empty.
    }
  }

  /// Read the misparse ledger: the rate for the health strip, the rows for
  /// the review above the phrasings. It lives in a pref, not in the sidecar
  /// journal, so it reads with the sidecar offline - and a store that is not
  /// there leaves the metric at n/a rather than opening an error banner on
  /// the strip.
  Future<void> _refreshMisparse() async {
    final mem = context.read<MemoryService>();
    if (!mem.ready) return;
    try {
      final stats = await mem.misparseStats();
      final entries = await mem.misparseLedger();
      if (!mounted) return;
      setState(() {
        _misparseStats = stats;
        _misparse = entries;
      });
    } catch (_) {
      // Nothing measured is a number the strip can show; a failure is not.
    }
  }

  ({int stores, int rows, List<String> failed, String autoLearn}) get _health {
    final h = _memoryHealth;
    if (h == null) return (stores: 0, rows: 0, failed: const [], autoLearn: '');
    final failed = (h['parseFailed'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final stores = (h['stores'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final auto = (h['autoLearn'] as Map?) ?? const {};
    final totalRows = stores.fold<int>(
      0,
      (sum, s) => sum + ((s['rows'] as num?)?.toInt() ?? 0),
    );
    return (
      stores: stores.length,
      rows: totalRows,
      failed: failed,
      autoLearn:
          'Auto-learn: ${auto['enabled'] == true ? 'on' : 'off'}'
          '${auto['suggestAfterRun'] == true ? '  ·  propose after run' : ''}'
          '${auto['autoTeach'] == true ? '  ·  verify on screen' : ''}',
    );
  }

  /// Un-teach a verified (possibly stale) correction: removes the promoted
  /// entry and flips the row to reverted. Kept next to the row it acts on.
  Future<void> _revertCorrection(CorrectionRow row) async {
    final engine = AutopilotService.of(context);
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
      await engine.revertCorrection(row.id);
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
    _envScaleCtl.dispose();
    _learningTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final mem = context.read<MemoryService>();
    if (!mem.ready) return;
    _rules = await mem.allRules();
    _attempts = await mem.recentAttempts(limit: 12);
    _prefs = await mem.allPrefs();
    _phrasings = await mem.allPhrasings();
    _learnedAnswers = await mem.allLearnedAnswers();
    _envProfile = await mem.environmentProfile();
    _loadEnvEditor();
    if (mounted) setState(() {});
  }

  /// Fill the environment editor's fields from the stored profile. Called
  /// by [_refresh] and after a save/forget, so user edits are never
  /// clobbered mid-typing by anything but an explicit reload.
  void _loadEnvEditor() {
    final p = _envProfile ?? const EnvironmentProfile();
    setStateSafe(() {
      _envVenue = p.venue;
      _envScaleCtl.text = p.scale > 0 ? '${p.scale}' : '';
      _envBudget = p.budget == true;
      _envSkill = p.skill;
    });
  }

  void setStateSafe(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// Save the edited environment. Writes the whole profile: the editor is
  /// the authority once the user has touched it, and the source line says
  /// so.
  Future<void> _saveEnvironment() async {
    final mem = context.read<MemoryService>();
    final scale = int.tryParse(_envScaleCtl.text.trim()) ?? 0;
    final profile = EnvironmentProfile(
      venue: _envVenue,
      scale: scale.clamp(0, 5000),
      budget: _envBudget ? true : null,
      skill: _envSkill,
      source: 'edited on the Memory screen',
    );
    try {
      await mem.setEnvironmentProfile(profile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            profile.isEmpty
                ? 'Environment cleared'
                : 'Environment saved: ${profile.summaryLine}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
    await _refresh();
  }

  /// Forget the environment: the advisor goes back to deriving everything
  /// from each message.
  Future<void> _forgetEnvironment() async {
    final mem = context.read<MemoryService>();
    await mem.forgetEnvironmentProfile();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Environment forgotten')),
    );
    await _refresh();
  }

  /// Drop one learned answer. The offline assistant stops replaying it for
  /// that question immediately - the lookup reads the store live.
  Future<void> _forgetLearnedAnswer(int id) async {
    final mem = context.read<MemoryService>();
    await mem.forgetLearnedAnswer(id);
    if (!mounted) return;
    setState(() => _learnedAnswers.removeWhere((a) => a['id'] == id));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Learned answer forgotten')),
    );
  }

  /// Drop one learned phrasing. The store also refreshes the live index,
  /// so the lesson stops replaying immediately - not after a restart.
  Future<void> _forgetPhrasing(String key) async {
    final mem = context.read<MemoryService>();
    await mem.forgetPhrasing(key);
    if (!mounted) return;
    setState(() => _phrasings.removeWhere((p) => p['phrasing'] == key));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Phrasing forgotten')),
    );
  }

  /// AUTO-LEARN: recurring failure patterns are filed automatically - no
  /// manual click. They carry an `autopilot` target so they stay review-only
  /// (MemoryService.plannerRuleTexts excludes them): a troubleshooting
  /// sentence must never rewrite a plan on its own. The more runs, the more
  /// advice accumulates (deduped by exact text).
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
      final svc = AutopilotService.of(context);
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
    final engine = AutopilotService.of(context);
    setState(() => _diagnosticsBusy = true);
    try {
      final result = await engine.exportDiagnostics(
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
    final health = _health;
    return AppPage(
      maxWidth: 1000,
      header: AppPageHeader(
        eyebrow: 'Learn',
        title: 'Memory and learning',
        description:
            'The app gets better at your networks on this device only: '
            'corrections, learned rules, replayable phrasings and the failure '
            'journal. Nothing is sent anywhere, and you can review or forget '
            'any of it here.',
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              _refresh();
              _refreshLearning();
              _refreshCorrections();
              _refreshMemoryHealth();
              _refreshMisparse();
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
          ),
          OutlinedButton.icon(
            onPressed: () => _confirmClearAll(mem),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Clear all memory'),
          ),
        ],
      ),
      children: [
        AppBanner(
          tone: AppTone.success,
          title: 'What it learns',
          message:
              'The sidecar learns while it works: failed clicks and commands '
              'are rejected for the current run, verified corrections are '
              'reused immediately, and only safe successful strategies are '
              'saved automatically. Risky network changes still require '
              'approval.',
        ),
        _healthStrip(health, _misparseStats),
        const SizedBox(height: AppTheme.s14),
        SegmentedButton<_MemoryTab>(
          showSelectedIcon: false,
          segments: [
            _tabSegment(
              _MemoryTab.rules,
              Icons.rule_folder_outlined,
              'Rules',
              _rules.length,
            ),
            _tabSegment(
              _MemoryTab.phrasings,
              Icons.replay,
              'Phrasings',
              _phrasings.length,
            ),
            _tabSegment(
              _MemoryTab.learned,
              Icons.lightbulb_outline,
              'Q&A',
              _learnedAnswers.length,
            ),
            _tabSegment(
              _MemoryTab.environment,
              Icons.home_work_outlined,
              'Environment',
              _envProfile == null ? 0 : 1,
            ),
            _tabSegment(
              _MemoryTab.learning,
              Icons.psychology_outlined,
              'Learning',
              _suggestions.length,
            ),
            _tabSegment(
              _MemoryTab.attempts,
              Icons.history_toggle_off,
              'Attempts',
              _attempts.length,
            ),
            _tabSegment(
              _MemoryTab.tools,
              Icons.build_outlined,
              'Tools',
              null,
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (values) => setState(() => _tab = values.first),
        ),
        const SizedBox(height: AppTheme.s16),
        if (_learnLoading) const LinearProgressIndicator(),
        if (_learnError != null)
          AppBanner(
            tone: AppTone.warning,
            title: 'Sidecar offline',
            message:
                'Start sidecar/pt_autopilot.py to read the learning journal.'
                '\n$_learnError',
          ),
        switch (_tab) {
          _MemoryTab.rules => _rulesTab(mem),
          _MemoryTab.phrasings => _phrasingsTab(),
          _MemoryTab.learned => _learnedAnswersTab(),
          _MemoryTab.environment => _environmentTab(mem),
          _MemoryTab.learning => _learningTab(),
          _MemoryTab.attempts => _attemptsTab(),
          _MemoryTab.tools => _toolsTab(),
        },
      ],
    );
  }

  ButtonSegment<_MemoryTab> _tabSegment(
    _MemoryTab tab,
    IconData icon,
    String label,
    int? count,
  ) {
    return ButtonSegment(
      value: tab,
      icon: Icon(icon, size: 16),
      label: Text(count == null ? label : '$label ($count)'),
    );
  }

  /// The health strip: the numbers that answer "is my memory intact?", which
  /// is the one question this screen must never make the user hunt for.
  ///
  /// [misparse] comes from the ledger rather than the sidecar health, so the
  /// rate is still there when the sidecar is not.
  Widget _healthStrip(
    ({int stores, int rows, List<String> failed, String autoLearn}) health,
    ({
      int turns,
      int corrections,
      int proposed,
      int taught,
      int dismissed,
    })? misparse,
  ) {
    // The rate is a measurement, not an alarm: it counts what the user had
    // to fix, so red would punish the one number meant to show progress.
    final turns = misparse?.turns ?? 0;
    final corrections = misparse?.corrections ?? 0;
    final measured = turns > 0;
    return AppMetricGrid(
      metrics: [
        AppMetric(
          label: 'Learning stores',
          value: '${health.stores}',
          icon: Icons.storage_outlined,
          tone: AppTone.accent,
        ),
        AppMetric(
          label: 'Rows on disk',
          value: '${health.rows}',
          icon: Icons.table_rows_outlined,
          tone: AppTone.info,
        ),
        AppMetric(
          label: 'Parse failures',
          value: '${health.failed.length}',
          icon: health.failed.isEmpty
              ? Icons.check_circle_outline
              : Icons.error_outline,
          tone: health.failed.isEmpty ? AppTone.success : AppTone.danger,
          hint: health.failed.isEmpty
              ? 'All stores readable'
              : 'Loaded EMPTY - data on disk is unreadable',
        ),
        AppMetric(
          label: 'Auto-learn',
          value: health.autoLearn.contains('on') ? 'on' : 'off',
          icon: Icons.bolt_outlined,
          tone: health.autoLearn.contains('on')
              ? AppTone.success
              : AppTone.neutral,
        ),
        AppMetric(
          label: 'Misparse rate',
          value: measured
              ? '${(corrections / turns * 100).toStringAsFixed(1)}%'
              : 'n/a',
          icon: Icons.fact_check_outlined,
          tone: measured && corrections == 0
              ? AppTone.success
              : AppTone.neutral,
          hint: measured
              ? 'Your corrections per parsed turn - falling means the '
                  'learned phrasings are landing.'
              : 'Nothing measured yet - one parsed turn starts the count.',
        ),
      ],
    );
  }

  // --- rules ---------------------------------------------------------------

  Widget _rulesTab(MemoryService mem) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          icon: Icons.rule_folder_outlined,
          title: 'Learned rules',
          subtitle:
              'Rules change the next plan. Rate one to keep the good ones '
              'trusted - a rule with more misses is ranked lower.',
          children: [
            if (_rules.isEmpty)
              Text(
                'No rules learned yet. Teach the app in the chat ("always use '
                'OSPF") or add one below.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final r in _rules)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s6),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.s12,
                      AppTheme.s8,
                      AppTheme.s6,
                      AppTheme.s8,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.panelAlt(theme.colorScheme),
                      borderRadius: BorderRadius.circular(AppTheme.rMd),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.ruleText),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  AppTag(
                                    label: r.targets,
                                    tone: AppTone.neutral,
                                  ),
                                  const SizedBox(width: AppTheme.s6),
                                  Text(
                                    'hits ${r.hits}  ·  miss ${r.misses}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'This rule helped',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.thumb_up_outlined, size: 16),
                          onPressed: () async {
                            await mem.markRule(r.id!, true);
                            await _refresh();
                          },
                        ),
                        IconButton(
                          tooltip: 'This rule did not help',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.thumb_down_outlined, size: 16),
                          onPressed: () async {
                            await mem.markRule(r.id!, false);
                            await _refresh();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: AppTheme.s6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ruleCtl,
                    decoration: const InputDecoration(
                      hintText: 'Add rule manually, e.g. always use OSPF',
                      prefixIcon: Icon(Icons.add, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s8),
                FilledButton(
                  onPressed: () async {
                    if (_ruleCtl.text.trim().isEmpty) return;
                    await mem.addRule(_ruleCtl.text.trim());
                    _ruleCtl.clear();
                    await _refresh();
                  },
                  child: const Text('Add rule'),
                ),
              ],
            ),
          ],
        ),
        AppPanel(
          icon: Icons.tune,
          title: 'Preferences',
          subtitle:
              'Key = value pairs the planner consults, e.g. '
              'addressing=10.0.0.0/16.',
          children: [
            if (_prefs.isEmpty)
              Text(
                'No preferences set.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final e in _prefs.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s4),
                  child: Row(
                    children: [
                      AppTag(label: e.key, tone: AppTone.info, mono: true),
                      const SizedBox(width: AppTheme.s8),
                      Expanded(
                        child: SelectableText(
                          e.value,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: AppTheme.monoFont,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: AppTheme.s8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _kCtl,
                    decoration: const InputDecoration(hintText: 'key'),
                  ),
                ),
                const SizedBox(width: AppTheme.s8),
                Expanded(
                  child: TextField(
                    controller: _vCtl,
                    decoration: const InputDecoration(hintText: 'value'),
                  ),
                ),
                const SizedBox(width: AppTheme.s8),
                FilledButton(
                  onPressed: () async {
                    if (_kCtl.text.isEmpty) return;
                    await mem.setPref(_kCtl.text.trim(), _vCtl.text.trim());
                    _kCtl.clear();
                    _vCtl.clear();
                    await _refresh();
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  // --- phrasings -----------------------------------------------------------

  /// The phrasings tab: corrections waiting for a decision first, then the
  /// lessons already in the replay index. Review comes first because it is
  /// the same question - "is this lesson right?" - asked before the lesson
  /// is allowed to replay.
  Widget _phrasingsTab() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _misparseReview(theme),
        _phrasingsPanel(theme),
      ],
    );
  }

  Widget _phrasingsPanel(ThemeData theme) {
    return AppPanel(
      icon: Icons.replay,
      title: 'Learned phrasings',
      subtitle:
          'When a vague request got clarified, the pair "your words -> the '
          'resolved brief" is remembered. Next time you say it, the parser '
          'replays the plan instead of guessing. On this device only.',
      children: [
        if (_phrasings.isEmpty)
          Text(
            'Nothing learned yet. Clarify a vague request in chat and the '
            'words that worked are kept here as a replayable plan.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final p in _phrasings)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s8),
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s12,
                  AppTheme.s8,
                  AppTheme.s4,
                  AppTheme.s8,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.panelAlt(theme.colorScheme),
                  borderRadius: BorderRadius.circular(AppTheme.rMd),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (p['phrasing'] ?? '').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.arrow_forward,
                                size: 13,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: AppTheme.s6),
                              Expanded(
                                child: Text(
                                  (p['rewrite'] ?? '').toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Forget this phrasing',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          _forgetPhrasing((p['phrasing'] ?? '').toString()),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  // --- misparse review -----------------------------------------------------

  /// The corrections the user made to a parse, waiting for a decision.
  ///
  /// Nothing here reaches the parser until Teach is tapped: the ledger only
  /// counts, review decides - the same fail-closed rule the autopilot
  /// teaching loop follows, because an unreviewed guess must not rewrite how
  /// a sentence is read.
  Widget _misparseReview(ThemeData theme) {
    final scheme = theme.colorScheme;
    final proposed = <MisparseEntry>[];
    final history = <MisparseEntry>[];
    for (final e in _misparse) {
      if (e.status == 'proposed') {
        proposed.add(e);
      } else if (e.status == 'taught' || e.status == 'dismissed') {
        history.add(e);
      }
    }
    return AppPanel(
      icon: Icons.fact_check_outlined,
      title: 'Misparse review',
      subtitle:
          'What the app understood, what you meant, and how many times it '
          'took you to fix it. Teach replays your fix on the next parse; '
          'dismiss keeps it out of the parser for good.',
      children: [
        if (proposed.isEmpty)
          Text(
            'No corrections yet. When the same words needed the same fix '
            'three times, the correction is proposed here - and taught only '
            'after you approve it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          for (final e in proposed) _misparseRow(theme, e),
        if (history.isNotEmpty) ...[
          const SizedBox(height: AppTheme.s4),
          Text(
            'Reviewed (${history.length})',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
          for (final e in history)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s4),
              child: Text(
                '${e.original}  ->  ${e.corrected}  ·  ${e.status}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// One proposed correction: the three lines the decision needs (the words,
  /// what the app made of them, what they meant) plus how often and how it
  /// arrived, with the two decisions beside them.
  Widget _misparseRow(ThemeData theme, MisparseEntry e) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.s12,
          AppTheme.s8,
          AppTheme.s8,
          AppTheme.s8,
        ),
        decoration: BoxDecoration(
          color: AppPalette.panelAlt(scheme),
          borderRadius: BorderRadius.circular(AppTheme.rMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.original,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.arrow_forward,
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppTheme.s6),
                      Expanded(
                        child: Text(
                          '${e.understood}  ->  ${e.corrected}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.s4),
                  Wrap(
                    spacing: AppTheme.s6,
                    runSpacing: AppTheme.s4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppTag(label: '${e.count}x', tone: AppTone.warning),
                      AppTag(label: e.source, tone: AppTone.neutral),
                      if (e.slot != 'free')
                        AppTag(label: e.slot, tone: AppTone.info, mono: true),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: _misparseBusy ? null : () => _teachMisparse(e),
                  child: const Text('Teach'),
                ),
                const SizedBox(width: AppTheme.s4),
                TextButton(
                  onPressed: _misparseBusy ? null : () => _dismissMisparse(e),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Teach one proposed correction. This is the only way a misparse lesson
  /// becomes a lesson: the row is marked taught, the fix enters the live
  /// phrasing index, and the phrasing list is re-read so the new lesson is
  /// visible under the very row it came from.
  Future<void> _teachMisparse(MisparseEntry e) async {
    final mem = context.read<MemoryService>();
    setState(() => _misparseBusy = true);
    try {
      final ok = await mem.teachMisparse(e.key, e.corrected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Taught: ${e.corrected}' : 'Could not teach this correction',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _misparseBusy = false);
    }
    await _refreshMisparse();
    await _refresh();
  }

  /// Reject one proposed correction. It stays in the ledger - the rate still
  /// counts it as a fix you had to make - but it never reaches the parser.
  Future<void> _dismissMisparse(MisparseEntry e) async {
    final mem = context.read<MemoryService>();
    setState(() => _misparseBusy = true);
    try {
      await mem.dismissMisparse(e.key, e.corrected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dismissed - counted, never taught'),
        ),
      );
    } finally {
      if (mounted) setState(() => _misparseBusy = false);
    }
    await _refreshMisparse();
  }

  // --- learning ------------------------------------------------------------

  /// Answers the app learned from keyed-model replies and replays offline.
  /// Review is the point: a wrong lesson is dropped here and the offline
  /// assistant stops giving it immediately.
  Widget _learnedAnswersTab() {
    final theme = Theme.of(context);
    return AppPanel(
      icon: Icons.lightbulb_outline,
      title: 'Learned answers',
      subtitle:
          'When an API key was active and the model answered a question, '
          'the answer is kept and replayed offline for the same question. '
          'An answer seen twice is confirmed. Drop any lesson you do not '
          'trust. On this device only.',
      children: [
        if (_learnedAnswers.isEmpty)
          Text(
            'Nothing learned yet. Ask a question while your API key is '
            'active and the answer is kept here for offline replay.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final a in _learnedAnswers)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s8),
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s12,
                  AppTheme.s8,
                  AppTheme.s4,
                  AppTheme.s8,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.panelAlt(theme.colorScheme),
                  borderRadius: BorderRadius.circular(AppTheme.rMd),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (a['question'] ?? '').toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              const SizedBox(width: AppTheme.s8),
                              Text(
                                '${a['seenCount'] ?? 1}x'
                                '${(a['confirmed'] ?? 0) == 1 ? ' · confirmed' : ''}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: (a['confirmed'] ?? 0) == 1
                                      ? AppPalette.success(theme.colorScheme)
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            (a['answer'] ?? '').toString(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Forget this answer',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _forgetLearnedAnswer(
                        (a['id'] as num?)?.toInt() ?? 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  // --- environment ---------------------------------------------------------

  /// The remembered environment: what the advisor knows about the user's
  /// site, learned automatically from stated facts ("this is for the
  /// office, 40 users") and editable here. One profile, not a history -
  /// the newest merge wins, so this screen is where "it remembered wrong"
  /// gets fixed.
  Widget _environmentTab(MemoryService mem) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = _envProfile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          icon: Icons.home_work_outlined,
          title: 'Environment',
          subtitle:
              'What the advisor remembers about your site. Facts you state '
              'in chat ("this is for the office, 40 users", "I\'m a '
              'beginner") are learned automatically while Learn '
              'automatically is on; anything you edit here is the '
              'authority until you change it.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s12),
                  child: Text(
                    'Nothing learned yet. The advisor currently derives '
                    'everything from each message, exactly as it always has.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s12),
                  child: Text(
                    'Remembered now: ${p.summaryLine.isEmpty ? '(empty)' : p.summaryLine}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (p.updatedAt.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.s12),
                    child: Text(
                      'Last changed ${p.updatedAt}'
                      '${p.source.isNotEmpty ? ' - ${p.source}' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
              DropdownButtonFormField<String>(
                key: const ValueKey('env-venue'),
                initialValue: _envVenue,
                decoration: const InputDecoration(
                  labelText: 'Where the network lives',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: '', child: Text('(not set)')),
                  DropdownMenuItem(value: 'home', child: Text('Home')),
                  DropdownMenuItem(value: 'office', child: Text('Office')),
                  DropdownMenuItem(value: 'school', child: Text('School / campus')),
                  DropdownMenuItem(value: 'clinic', child: Text('Clinic / hospital')),
                  DropdownMenuItem(value: 'hospitality', child: Text('Cafe / hotel / shop')),
                  DropdownMenuItem(value: 'industrial', child: Text('Industrial / warehouse')),
                ],
                onChanged: (v) => setStateSafe(() => _envVenue = v ?? ''),
              ),
              const SizedBox(height: AppTheme.s12),
              TextField(
                key: const ValueKey('env-scale'),
                controller: _envScaleCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'How many people or devices it serves',
                  border: OutlineInputBorder(),
                  hintText: 'e.g. 40',
                ),
              ),
              const SizedBox(height: AppTheme.s12),
              DropdownButtonFormField<String>(
                key: const ValueKey('env-skill'),
                initialValue: _envSkill,
                decoration: const InputDecoration(
                  labelText: 'Networking experience',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: '', child: Text('(not set)')),
                  DropdownMenuItem(value: 'beginner', child: Text('Beginner')),
                  DropdownMenuItem(value: 'intermediate', child: Text('Intermediate')),
                  DropdownMenuItem(value: 'advanced', child: Text('Advanced')),
                ],
                onChanged: (v) => setStateSafe(() => _envSkill = v ?? ''),
              ),
              const SizedBox(height: AppTheme.s8),
              SwitchListTile(
                key: const ValueKey('env-budget'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Budget-conscious'),
                subtitle: const Text(
                  'Advice then prefers the affordable option first',
                ),
                value: _envBudget,
                onChanged: (v) => setStateSafe(() => _envBudget = v),
              ),
              const SizedBox(height: AppTheme.s8),
              Row(
                children: [
                  FilledButton(
                    key: const ValueKey('env-save'),
                    onPressed: _saveEnvironment,
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: AppTheme.s12),
                  if (_envProfile != null)
                    TextButton(
                      onPressed: _forgetEnvironment,
                      child: const Text('Forget environment'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _learningTab() {
    final theme = Theme.of(context);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppMetricGrid(
          metrics: [
            AppMetric(
              label: 'Session',
              value: liveSession,
              icon: Icons.memory,
              tone: liveSession == 'not connected'
                  ? AppTone.warning
                  : AppTone.success,
            ),
            AppMetric(
              label: 'Learning events',
              value: liveEvents,
              icon: Icons.bolt_outlined,
              tone: AppTone.info,
            ),
            AppMetric(
              label: 'Blocked now',
              value: banned,
              icon: Icons.block_outlined,
              tone: AppTone.warning,
              hint: 'failed candidates',
            ),
            AppMetric(
              label: 'Trusted',
              value: trusted,
              icon: Icons.verified_outlined,
              tone: AppTone.success,
            ),
            AppMetric(
              label: 'Quarantined',
              value: quarantined,
              icon: Icons.gavel_outlined,
              tone: quarantined == '0' ? AppTone.neutral : AppTone.danger,
              hint: 'after repeated failure',
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s12),
        AppPanel(
          icon: Icons.psychology_outlined,
          title: 'Autopilot learning (failure journal)',
          subtitle: 'Cross-run problem stats: $kindLine',
          children: [
            Text(
              'This memory is automatic; no save/approve click is needed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.success(theme.colorScheme),
              ),
            ),
            if (_autoSaved > 0) ...[
              const SizedBox(height: AppTheme.s6),
              AppBanner(
                tone: AppTone.success,
                dense: true,
                message:
                    'RECORDED: $_autoSaved recurring pattern(s) filed below '
                    'for review - they do not change plans until you teach a '
                    'rule that says so.',
              ),
            ],
            const SizedBox(height: AppTheme.s8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _learnLoading ? null : () => _refreshLearning(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh learning'),
                ),
                const SizedBox(width: AppTheme.s8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await AutopilotService.of(context).eventsClear();
                    } catch (_) {}
                    await _refreshLearning();
                  },
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear journal'),
                ),
              ],
            ),
          ],
        ),
        // TEACHING-LOOP CORRECTIONS: stale ones are taught fixes that
        // stopped verifying; rejected ones a teach run disproved. Both are
        // reported here instead of failing silently.
        CorrectionsCard(
          snapshot: _corrections,
          onRefresh: _correctionsBusy ? null : () => _refreshCorrections(),
          onRevert: _revertCorrection,
        ),
        if (_correctionsBusy && _corrections.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s8),
            child: Text(
              'Reading corrections from the sidecar...',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (_correctionsNote != null)
          AppBanner(
            tone: AppTone.danger,
            dense: true,
            message: _correctionsNote!,
          ),
        for (final s in _suggestions)
          AppBanner(
            tone: AppTone.warning,
            title: s,
            message: 'Recorded for review - not applied to plans',
          ),
        if (_experiences.isNotEmpty)
          AppPanel(
            icon: Icons.school_outlined,
            title: 'Structured experiences (${_experiences.length})',
            children: [
              for (final x in _experiences.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s4),
                  child: Text(
                    '${x['device'] ?? ''}  ·  ${x['kind'] ?? ''}  ·  '
                    '${x['result'] ?? ''}: ${x['detail'] ?? ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        if (_events.isNotEmpty)
          AppPanel(
            icon: Icons.event_note_outlined,
            title: 'Recent events (newest first)',
            actions: [
              AppTag(label: '${_events.length}', tone: AppTone.neutral),
            ],
            child: AppCodeBlock(
              text: _events
                  .take(10)
                  .map(
                    (e) =>
                        '${e['ts'] ?? ''} [${e['kind']}] ${e['detail'] ?? ''}'
                        ' ${(e['recovered'] == true)
                            ? "(recovered)"
                            : (e['recovered'] == false)
                            ? "(UNRECOVERED)"
                            : ""}',
                  )
                  .join('\n'),
              title: 'failure journal',
              maxHeight: 240,
              compact: true,
            ),
          ),
      ],
    );
  }

  // --- attempts ------------------------------------------------------------

  Widget _attemptsTab() {
    final theme = Theme.of(context);
    return AppPanel(
      icon: Icons.history_toggle_off,
      title: 'Recent build attempts',
      subtitle: 'What each run actually did, including the failures.',
      children: [
        if (_attempts.isEmpty)
          Text(
            'No attempts recorded yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final a in _attempts)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s6),
              child: AppRowTile(
                icon: a.status == 'verified'
                    ? Icons.verified_outlined
                    : a.status == 'failed'
                    ? Icons.error_outline
                    : Icons.pending_actions,
                tone: a.status == 'verified'
                    ? AppTone.success
                    : a.status == 'failed'
                    ? AppTone.danger
                    : AppTone.neutral,
                title: '${a.projectName}  ·  ${a.status}',
                subtitle:
                    '${a.failureKind ?? 'no failure recorded'}'
                    '${a.correction == null ? '' : '  ·  correction saved'}',
                badges: [
                  if (a.correction != null)
                    const AppTag(
                      label: 'corrected',
                      tone: AppTone.warning,
                    ),
                ],
              ),
            ),
      ],
    );
  }

  // --- tools ---------------------------------------------------------------

  Widget _toolsTab() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPanel(
          icon: Icons.archive_outlined,
          title: 'Tester diagnostics',
          subtitle:
              'Creates a local redacted archive you can send to me. It '
              'excludes API keys, passwords, raw configurations, and .pkt '
              'files by default.',
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Include screenshots',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'Screenshots may contain visible names or addresses.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _includeScreenshots,
                  onChanged: _diagnosticsBusy
                      ? null
                      : (value) =>
                            setState(() => _includeScreenshots = value),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.s10),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _diagnosticsBusy ? null : _exportDiagnostics,
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: Text(
                    _diagnosticsBusy
                        ? 'Creating archive...'
                        : 'Export diagnostics',
                  ),
                ),
              ],
            ),
            if (_diagnosticsPath != null) ...[
              const SizedBox(height: AppTheme.s8),
              SelectableText(
                'Created: $_diagnosticsPath',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: AppTheme.monoFont,
                ),
              ),
            ],
          ],
        ),
        AppPanel(
          icon: Icons.dangerous_outlined,
          title: 'Clear all memory',
          tone: AppTone.danger,
          subtitle:
              'Deletes every learned rule, phrasing, preference and the '
              'attempt history from this device. It cannot be undone.',
          children: [
            OutlinedButton.icon(
              onPressed: () => _confirmClearAll(context.read<MemoryService>()),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Clear all memory'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmClearAll(MemoryService mem) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear all local memory?'),
        content: const Text(
          'Every learned rule, phrasing and preference on this device is '
          'deleted. Saved networks are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
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
  }
}
