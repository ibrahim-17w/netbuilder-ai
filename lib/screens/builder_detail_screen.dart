import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../models/build_attempt.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/adapters/gns3_adapter.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/autopilot_service.dart';
import '../services/build_artifact_service.dart';
import '../services/gemini_service.dart';
import '../services/memory_service.dart';
import '../services/privacy_search_service.dart';
import '../services/settings_service.dart';
import '../services/validator_service.dart';
import '../widgets/correction_badges.dart';
import '../widgets/verification_report.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

class BuilderDetailScreen extends StatefulWidget {
  final BuildRecord record;
  final NetworkIntent intent;
  final String configText;
  final bool monitorSidecar;

  /// The brief that produced this plan; the feedback loop uses it to
  /// invalidate the planner cache when the build fails. Empty when unknown
  /// (older records).
  final String brief;
  final String target;
  const BuilderDetailScreen({
    super.key,
    required this.record,
    required this.intent,
    required this.configText,
    this.monitorSidecar = true,
    this.brief = '',
    this.target = 'packet-tracer',
  });

  @override
  State<BuilderDetailScreen> createState() => _BuilderDetailScreenState();
}

class _BuilderDetailScreenState extends State<BuilderDetailScreen> {
  final _fix = TextEditingController();
  String _log = '';
  bool _busy = false;
  bool _watching = false;
  bool _stopPending = false;
  bool _pausePending = false;
  bool _sidecarIsPaused = false;
  bool _statusRefreshInFlight = false;
  Timer? _statusTimer;
  String _sidecarState = 'Checking live sidecar status...';
  String _searchPreview = '';
  double _gridX0 = 0.35;
  double _gridStep = 0.10;
  double _gridY = 0.45;
  bool _calLoaded = false;
  // Network audit (analyze an already-built network, suggest fixes)
  Map<String, dynamic>? _audit;
  bool _auditing = false;
  final Set<String> _selectedFixes = {};
  final Map<String, List<TextEditingController>> _pcFixFields = {};
  // AI suggest + evaluate: Gemini proposes fixes for the journal's
  // recurring failures, a second Gemini call judges each one, and
  // accepted label/skip proposals become `proposed` corrections that a
  // teach run has to verify on screen. Nothing is auto-promoted.
  bool _aiSuggesting = false;
  Map<String, dynamic>? _aiSuggest;
  // Teaching-loop state for the badges: stale/rejected/pending corrections
  // from /corrections, plus the last teach run's verdicts from /status.
  CorrectionSnapshot _corrections = const CorrectionSnapshot.empty();
  TeachRunSnapshot _teachRun = const TeachRunSnapshot.empty();
  int _correctionsTick = 0;
  // Post-build verification (PDU/ping evidence from the live canvas).
  Map<String, dynamic>? _verifyReport;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    if (!widget.monitorSidecar) return;
    // A previous error message is local Flutter state, not proof that the
    // sidecar is still busy. Refresh immediately and keep the status chip in
    // sync when Stop is pressed outside this screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshSidecarState());
    });
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) unawaited(_refreshSidecarState());
    });
  }

  /// Refresh the stale/rejected/pending correction badges.  Throttled to
  /// every 5th status tick (10 s) - the corrections file only changes when
  /// a teach run or a learn attempt settles something.
  /// Start ONE bounded teach run for a proposed correction.
  ///
  /// Nothing is taught by this call: it asks the sidecar to re-attempt the
  /// single step the correction names, with the correction armed as a
  /// one-shot override. The run promotes it only if the screen verifies the
  /// step, and rejects it with the observed reason if not - and the card's
  /// badges show which happened on the next refresh. A correction the sidecar
  /// cannot resolve says so here instead of starting something unverifiable.
  Future<void> _teachCorrection(CorrectionRow row) async {
    if (row.id.isEmpty) return;
    final engine = AutopilotService.of(context);
    setState(() => _log = 'Teach run started for ${row.summaryLine}...');
    try {
      final out = await engine.teachCorrection(
        correctionId: row.id,
        project: row.project.isEmpty ? widget.record.projectName : row.project,
      );
      if (!mounted) return;
      final ok = out['ok'] == true;
      setState(() {
        _log = ok
            ? '${out['message'] ?? 'Teach run started.'}\n'
                  'It is promoted only if the step verifies; poll this screen '
                  'for the verdict.'
            : 'Cannot teach this one: '
                  '${out['error'] ?? out['reason'] ?? 'the sidecar refused it'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _log = 'Teach run refused: '
            '${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
    await _refreshCorrections(force: true);
  }

  Future<void> _refreshCorrections({bool force = false}) async {
    if (!force) {
      _correctionsTick++;
      if (_correctionsTick % 5 != 0) return;
    }
    try {
      final snap = await AutopilotService.of(context).correctionSnapshot();
      if (!mounted) return;
      setState(() => _corrections = snap);
    } catch (_) {
      // Badges are additive; a missed poll just leaves them as they were.
    }
  }

  /// Badge strip for one AI proposal: PENDING while it waits for a teach
  /// run, VERIFIED/REJECTED once the run settled it, STALE when a taught
  /// fix later stopped verifying, `x<n>` when the same element keeps being
  /// corrected. Lookup order: pending first (the common case), then stale,
  /// then rejected.
  Widget _proposalBadges(Map<String, dynamic> p) {
    final cid = p['correctionId']?.toString() ?? '';
    CorrectionRow? row;
    if (cid.isNotEmpty) {
      for (final r in [
        ..._corrections.pending,
        ..._corrections.stale,
        ..._corrections.rejected,
      ]) {
        if (r.id == cid) {
          row = r;
          break;
        }
      }
    }
    final teach = cid.isEmpty ? null : _teachRun.byId[cid];
    if (row == null && teach == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: CorrectionBadges(
        stale: row?.stale == true && row?.status == 'verified',
        rejected: row?.status == 'rejected' || teach?.promoted == false,
        pending: row?.status == 'proposed' && teach == null,
        verified:
            teach?.promoted == true ||
            (row?.status == 'verified' && row?.stale != true),
        thrash: (row?.thrash ?? 0) > 0,
        thrashCount: row?.thrash ?? 0,
      ),
    );
  }

  bool _executionPreflight(String target) {
    final issues = ValidatorService.validate(widget.intent, target: target);
    final errors = issues.where((issue) => issue.severity == 'error').toList();
    if (errors.isEmpty) return true;
    if (mounted) {
      setState(
        () => _log =
            'Execution blocked by preflight. Fix these ${errors.length} '
            'error(s) before changing the live network:\n'
            '${errors.map((issue) => '• ${issue.message}').join('\n')}',
      );
    }
    return false;
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _fix.dispose();
    for (final ctrls in _pcFixFields.values) {
      for (final c in ctrls) {
        c.dispose();
      }
    }
    super.dispose();
  }

  bool _sidecarPaused(Map<String, dynamic> status) {
    final pause = status['pause'];
    if (pause is Map) {
      return pause['paused'] == true || pause['pauseRequested'] == true;
    }
    return false;
  }

  String _describeSidecarState(Map<String, dynamic> status) {
    if (status['running'] != true) return 'Idle - no active sidecar job.';
    final activity = (status['activity'] ?? 'job').toString();
    if (_sidecarPaused(status)) {
      return 'Busy - $activity (PAUSED; press Pause to resume).';
    }
    final suffix = status['stopRequested'] == true
        ? ' (stop requested; releasing)'
        : '';
    return 'Busy - $activity$suffix.';
  }

  Future<void> _refreshSidecarState({bool showInLog = false}) async {
    if (_statusRefreshInFlight) return;
    _statusRefreshInFlight = true;
    try {
      final status = await AutopilotService.of(context).statusDetails();
      if (!mounted) return;
      final state = _describeSidecarState(status);
      setState(() {
        _sidecarState = state;
        _sidecarIsPaused = _sidecarPaused(status);
        // /status carries the last teach run's verdicts; deriving them here
        // costs nothing extra and keeps the proposal badges current.
        _teachRun = TeachRunSnapshot.fromJson(status);
        if (showInLog || _log.trim().isEmpty) {
          _log = 'Live sidecar status: $state';
        }
      });
      unawaited(_refreshCorrections());
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _sidecarState = 'Unavailable - $message';
        if (showInLog || _log.trim().isEmpty) _log = message;
      });
    } finally {
      _statusRefreshInFlight = false;
    }
  }

  Future<void> _showExecutionError(Object error) async {
    final message = error.toString().replaceFirst('Exception: ', '');
    try {
      final status = await AutopilotService.of(context).statusDetails();
      if (!mounted) return;
      final state = _describeSidecarState(status);
      setState(() {
        _sidecarState = state;
        _log = '$message\nLive sidecar status: $state';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _log = message);
    }
  }

  /// AI fix suggestions: push the user's Gemini key (same one builds use),
  /// then start one suggest+evaluate pass and poll until it finishes.
  /// The sidecar proposes fixes for recurring failures and evaluates each
  /// with an independent second call; accepted label/skip proposals are
  /// recorded as `proposed` corrections. Nothing is typed or promoted -
  /// a teach run still has to verify a correction on screen.
  Future<void> _runAiSuggest() async {
    setState(() => _busy = true);
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      await _pushLlmConfig();
      final res = await svc.aiSuggest(project: widget.intent.projectName);
      if (res['ok'] != true) {
        if (!mounted) return;
        setState(
          () =>
              _log = 'AI suggestions unavailable: ${res['error'] ?? 'unknown'}',
        );
        return;
      }
      if (res['started'] != true) {
        if (!mounted) return;
        setState(
          () => _log =
              res['message']?.toString() ??
              'Nothing for the AI to fix right now.',
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _aiSuggesting = true;
        _log =
            'AI is proposing and evaluating fixes for recurring '
            'failures (two Gemini passes)...';
      });
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        try {
          final st = await svc.aiSuggestStatus();
          if (st['running'] == true) continue;
          if (!mounted) return;
          setState(() {
            _aiSuggesting = false;
            _aiSuggest = st['last'] == null
                ? null
                : Map<String, dynamic>.from(st['last'] as Map);
            _log = st['error']?.toString().isNotEmpty == true
                ? 'AI suggest pass failed: ${st['error']}'
                : 'AI suggestions ready (${_aiSuggest?['acceptedCount'] ?? 0} '
                      'accepted - see the AI suggestions card).';
          });
          // Accepted proposals just became PENDING corrections on the
          // sidecar - pull them in now instead of waiting for the tick.
          unawaited(_refreshCorrections(force: true));
          return;
        } catch (_) {
          // transient sidecar hiccup - keep polling
        }
      }
      if (!mounted) return;
      setState(() {
        _aiSuggesting = false;
        _log = 'AI suggest pass timed out - check the sidecar log.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _log =
            'AI suggestions failed: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Audit an ALREADY-BUILT network. `offline: true` reads the most recent
  /// generated/saved .pkt directly - no Packet Tracer, no windows. The live
  /// mode opens each device and reads its real runtime state.
  Future<void> _runAudit({bool offline = false}) async {
    setState(() {
      _busy = true;
      _auditing = true;
      _audit = null;
      _selectedFixes.clear();
      _log = offline
          ? 'Auditing offline - reading the saved .pkt (no Packet Tracer)...'
          : 'Auditing network - opening each device and reading its '
                'state (this opens/closes PT windows)...';
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() {
          _log = svc.hint;
          _auditing = false;
        });
        return;
      }
      if (offline) {
        final path = await _latestPktPath();
        if (path == null) {
          if (!mounted) return;
          setState(() {
            _log =
                'No .pkt found in the sidecar\'s output folder '
                '(pkt_output). Generate or save one first.';
            _auditing = false;
          });
          return;
        }
        final rep = await svc.pktAudit(
          path,
          project: widget.intent.projectName,
        );
        if (!mounted) return;
        setState(() {
          _audit = rep;
          _auditing = false;
        });
        _prepareAuditSelection();
        setState(
          () => _log =
              'Offline audit finished (read from ${rep['path'] ?? 'the file'}). '
              'Findings are ADVICE ONLY - Packet Tracer was not opened. Run a '
              'live audit to apply fixes to the real devices.',
        );
        return;
      }
      await svc.auditStart(widget.intent.projectName);
      for (var i = 0; i < 300; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        try {
          final r = await svc.auditReport();
          if (r['running'] == false) {
            final rep = r['report'] as Map?;
            if (!mounted) return;
            setState(() {
              _audit = rep == null ? null : Map<String, dynamic>.from(rep);
              _auditing = false;
            });
            _prepareAuditSelection();
            if (!mounted) return;
            setState(
              () => _log =
                  'Audit finished - review the findings below and choose '
                  'what to fix. Selected fixes run through the same '
                  'autopilot (typed into the real devices).',
            );
            return;
          }
        } catch (_) {
          continue;
        }
      }
      if (!mounted) return;
      setState(() => _log = 'Audit timed out - check the sidecar log.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _log = 'Audit failed: ${e.toString().replaceFirst('Exception: ', '')}';
        _auditing = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The .pkt the offline audit should read: the last generated/saved
  /// artifact the sidecar remembers (generate or save_verified).
  Future<String?> _latestPktPath() async {
    final svc = AutopilotService.of(context);
    final report = await svc.pktReport();
    final path = (report?['path'] ?? '').toString();
    return path.isEmpty ? null : path;
  }

  void _prepareAuditSelection() {
    _selectedFixes.clear();
    for (final ctrls in _pcFixFields.values) {
      for (final c in ctrls) {
        c.dispose();
      }
    }
    _pcFixFields.clear();
    for (final devRaw in (_audit?['devices'] as List? ?? [])) {
      final dev = devRaw as Map;
      final name = dev['name'] as String;
      for (final fRaw in (dev['findings'] as List? ?? [])) {
        final f = fRaw as Map;
        if (f['severity'] == 'high') {
          _selectedFixes.add(f['id'] as String);
        }
        if (f['fix_pc'] == true && !_pcFixFields.containsKey(name)) {
          final ipcfg = (dev['ipcfg'] as Map? ?? {});
          final mask = (ipcfg['mask'] ?? '').toString();
          _pcFixFields[name] = [
            TextEditingController(text: (ipcfg['ip'] ?? '').toString()),
            TextEditingController(text: mask.isEmpty ? '255.255.255.0' : mask),
            TextEditingController(), // gateway - user must fill this
          ];
        }
      }
    }
  }

  /// Apply the user-selected fixes through the regular autopilot
  /// (fixes mode: typed into the real devices, saved with write memory).
  Future<void> _applyFixes() async {
    final report = _audit;
    if (report == null) return;
    final configs = <String, String>{};
    final pcs = <String, Map<String, String>>{};
    var count = 0;
    for (final devRaw in (report['devices'] as List? ?? [])) {
      final dev = devRaw as Map;
      final name = dev['name'] as String;
      for (final fRaw in (dev['findings'] as List? ?? [])) {
        final f = fRaw as Map;
        if (!_selectedFixes.contains(f['id'])) continue;
        final cli =
            (f['fix_cli'] as List?)?.map((e) => e.toString()).toList() ?? [];
        if (cli.isNotEmpty) {
          configs[name] =
              (configs[name] == null ? '' : '${configs[name]}\n') +
              cli.join('\n');
          count++;
        }
        if (f['fix_pc'] == true) {
          final c = _pcFixFields[name];
          if (c == null) continue;
          final ip = c[0].text.trim();
          final mask = c[1].text.trim();
          final gw = c[2].text.trim();
          if (ip.isEmpty || gw.isEmpty) {
            setState(
              () => _log =
                  'PC $name selected but IP/Gateway is empty - fill them '
                  'in (gateway = the router interface on that LAN).',
            );
            return;
          }
          pcs[name] = {
            'ip': ip,
            'mask': mask.isEmpty ? '255.255.255.0' : mask,
            'gw': gw,
          };
          count++;
        }
      }
    }
    if (count == 0) {
      setState(() => _log = 'Select at least one fix to apply.');
      return;
    }
    final steps = <Map<String, dynamic>>[
      if (configs.isNotEmpty)
        {'action': 'paste_cli', 'configs': configs, 'typing_delay_ms': 25},
      if (pcs.isNotEmpty) {'action': 'config_pcs', 'pcs': pcs},
    ];
    setState(() {
      _busy = true;
      _log = 'Applying $count fix(es)... keep Packet Tracer in front.';
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      final res = await svc.start({
        'project': widget.intent.projectName,
        'steps': steps,
        'mode': 'fixes',
      });
      await _markAttemptExecuting();
      if (!mounted) return;
      setState(
        () => _log =
            'Fixes started: $res\nWATCH PT - the autopilot will apply each '
            'selected fix and save with write memory.',
      );
      await Future.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      _watchRun();
    } catch (e) {
      await _showExecutionError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildAuditCard() {
    final devices = (_audit?['devices'] as List? ?? []);
    final reds = (_audit?['red_dots'] ?? 0) as num;
    final summary = Map<String, dynamic>.from(
      (_audit?['summary'] as Map? ?? const {}),
    );
    final byType = Map<String, dynamic>.from(
      (summary['by_type'] as Map? ?? const {}),
    );
    final severity = Map<String, dynamic>.from(
      (summary['severity'] as Map? ?? const {}),
    );
    final services = Map<String, dynamic>.from(
      (summary['services'] as Map? ?? const {}),
    );
    return AppPanel(
      icon: Icons.fact_check_outlined,
      tone: reds > 0 ? AppTone.warning : AppTone.success,
      title: 'Audit results',
      subtitle: _audit?['generated'] != null
          ? 'Generated ${_audit!['generated']}'
          : null,
      children: [
        AppBanner(
          dense: true,
          tone: reds > 0 ? AppTone.danger : AppTone.success,
          icon: reds > 0 ? Icons.link_off_outlined : Icons.check_circle_outline,
          message: reds > 0
              ? 'Red link indicators on canvas: $reds - something is not '
                    'passing traffic.'
              : 'No red link indicators on canvas.',
        ),
        if (summary.isNotEmpty) ...[
          Wrap(
            spacing: AppTheme.s8,
            runSpacing: AppTheme.s8,
            children: [
              AppTag(
                label: '${summary['device_count'] ?? 0} device(s)',
                tone: AppTone.accent,
                icon: Icons.devices_other_outlined,
              ),
              AppTag(
                label: '${summary['finding_count'] ?? 0} finding(s)',
                tone: (summary['finding_count'] ?? 0) == 0
                    ? AppTone.success
                    : AppTone.warning,
                icon: Icons.report_outlined,
              ),
              for (final e in byType.entries)
                AppTag(
                  label: '${e.key}=${e.value}',
                  tone: AppTone.neutral,
                  mono: true,
                ),
              AppTag(
                label:
                    'H/M/I ${severity['high'] ?? 0}/'
                    '${severity['medium'] ?? 0}/${severity['info'] ?? 0}',
                tone: AppTone.info,
                icon: Icons.priority_high,
              ),
            ],
          ),
          const SizedBox(height: AppTheme.s10),
          if ((services['checked'] ?? 0) != 0)
            Text(
              'Services: ${services['checked']} checked · '
              '${services['on'] ?? 0} on · ${services['off'] ?? 0} off · '
              '${services['unknown'] ?? 0} unknown · '
              '${services['saved_data'] ?? 0} saved tables · '
              '${services['rules_verified'] ?? 0} rules verified · '
              '${services['state_only'] ?? 0} state only',
              style: const TextStyle(fontSize: 12),
            ),
        ],
        if ((_audit?['scope'] as List? ?? []).isNotEmpty)
          Text(
            'Evidence: ${(_audit!['scope'] as List).join(' · ')}',
            style: TextStyle(
              fontSize: 11,
              color: AppPalette.mutedText(Theme.of(context).colorScheme),
            ),
          ),
        if ((_audit?['error'] ?? '').toString().isNotEmpty)
          AppBanner(
            dense: true,
            tone: AppTone.danger,
            message: 'Audit error: ${_audit!['error']}',
          ),
        if ((_audit?['note'] ?? '').toString().isNotEmpty)
          Text(
            _audit!['note'].toString(),
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 4),
        if ((_audit?['reachability'] as Map? ?? {}).isNotEmpty)
          _buildReachabilityCard(
            Map<String, dynamic>.from(_audit!['reachability'] as Map),
          ),
        for (final devRaw in devices) _buildDeviceAudit(devRaw as Map),
        const SizedBox(height: 8),
        if (_audit?['mode'] == 'offline')
          const AppBanner(
            dense: true,
            tone: AppTone.warning,
            icon: Icons.visibility_off_outlined,
            message:
                'Offline mode: findings are advice only - nothing can be '
                'applied from here. Run a live audit (Audit Network) to fix '
                'the real devices.',
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            onPressed:
                _audit?['mode'] == 'offline' || _selectedFixes.isEmpty || _busy
                ? null
                : _applyFixes,
            icon: const Icon(Icons.build_outlined, size: 18),
            label: Text('Apply ${_selectedFixes.length} selected fix(es)'),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceAudit(Map dev) {
    final findings = (dev['findings'] as List? ?? []);
    final name = dev['name'] as String;
    final ipcfg = Map<String, dynamic>.from((dev['ipcfg'] as Map? ?? const {}));
    final serviceList = (dev['services'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final probes = (dev['probes'] as List? ?? []).whereType<Map>().toList();
    return ExpansionTile(
      initiallyExpanded: findings.any((f) => (f as Map)['severity'] == 'high'),
      title: Text('$name (${dev['type']})'),
      subtitle: Text(
        findings.isEmpty ? 'no issues found' : '${findings.length} finding(s)',
      ),
      children: [
        if (ipcfg.values.any((value) => value.toString().isNotEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'IPv4 ${ipcfg['ip'] ?? 'unreadable'}'
                '${(ipcfg['mask'] ?? '').toString().isEmpty ? '' : ' / ${ipcfg['mask']}'}'
                '${(ipcfg['gw'] ?? '').toString().isEmpty ? '' : ' · gateway ${ipcfg['gw']}'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        if (serviceList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Services: ${serviceList.map((service) {
                  final state = (service['state'] ?? 'unknown').toString();
                  final saved = service['saved_data'] == true ? ', table data' : '';
                  return '${service['name'] ?? 'service'} ($state$saved)';
                }).join(' · ')}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        for (final probe in probes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${probe['command']}: ${probe['readable'] == true ? 'read' : 'unreadable'}'
                '${(probe['evidence'] as List? ?? []).isEmpty ? '' : ' · ${(probe['evidence'] as List).take(3).join(' | ')}'}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.mutedText(Theme.of(context).colorScheme),
                ),
              ),
            ),
          ),
        if (findings.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Clean - nothing to fix.',
              style: TextStyle(
                color: AppPalette.success(Theme.of(context).colorScheme),
              ),
            ),
          ),
        for (final fRaw in findings)
          if (_audit?['mode'] == 'offline')
            ListTile(
              dense: true,
              leading: Icon(
                fRaw['severity'] == 'high'
                    ? Icons.error_outline
                    : Icons.info_outline,
                color: fRaw['severity'] == 'high'
                    ? AppPalette.danger(Theme.of(context).colorScheme)
                    : AppPalette.mutedText(Theme.of(context).colorScheme),
                size: 20,
              ),
              title: Text(
                fRaw['text'].toString(),
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                'advice only'
                '${((fRaw['fix_cli'] as List? ?? []).isNotEmpty) ? ' - suggested commands: ${(fRaw['fix_cli'] as List).join(' → ')}' : ''}',
                style: const TextStyle(fontSize: 11),
              ),
            )
          else
            CheckboxListTile(
              dense: true,
              value: _selectedFixes.contains(fRaw['id']),
              onChanged: (v) => setState(() {
                v == true
                    ? _selectedFixes.add(fRaw['id'] as String)
                    : _selectedFixes.remove(fRaw['id']);
              }),
              title: Text(
                fRaw['text'].toString(),
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${fRaw['severity']}'
                '${fRaw['fix_pc'] == true ? ' - fill PC IP below' : ((fRaw['fix_cli'] as List? ?? []).isNotEmpty ? ' - auto-fix available' : ' - informational')}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
        if (_pcFixFields[name] != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pcFixFields[name]![0],
                    decoration: const InputDecoration(
                      labelText: 'PC IP',
                      hintText: '192.168.10.10',
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
                      hintText: '192.168.10.1',
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

  Widget _buildReachabilityCard(Map<String, dynamic> reachability) {
    final results = (reachability['results'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final skipped = (reachability['skipped'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final failed = reachability['failed'] ?? 0;
    final anyFailed = failed is num && failed > 0;
    return AppPanel(
      dense: true,
      framed: false,
      tone: anyFailed ? AppTone.danger : AppTone.success,
      icon: Icons.network_ping,
      title: 'Live connectivity tests',
      subtitle:
          'Attempted ${reachability['attempted'] ?? 0} · '
          'passed ${reachability['passed'] ?? 0} · failed $failed · '
          'skipped ${skipped.length}',
      children: [
        for (final result in results)
          AppRowTile(
            dense: true,
            icon: result['ok'] == true
                ? Icons.check_circle_outline
                : Icons.error_outline,
            tone: result['ok'] == true ? AppTone.success : AppTone.danger,
            title: '${result['source']} → ${result['target']}',
            subtitle:
                '${result['ok'] == true ? 'Reply received' : 'No verified reply'} · '
                'attempts ${result['attempts'] ?? '?'}'
                '${(result['evidence'] ?? '').toString().isEmpty ? '' : '\n${result['evidence']}'}',
          ),
        for (final item in skipped)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s4),
            child: Text(
              'Skipped ${item['source']}: ${item['reason']}',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.mutedText(Theme.of(context).colorScheme),
              ),
            ),
          ),
        if (reachability['note'] != null)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s4),
            child: Text(
              reachability['note'].toString(),
              style: TextStyle(
                fontSize: 11,
                color: AppPalette.mutedText(Theme.of(context).colorScheme),
              ),
            ),
          ),
      ],
    );
  }

  String _failureKind(
    Map<String, dynamic> summary,
    List<Map<String, dynamic>> events,
  ) {
    final unrecovered = events.where((e) => e['recovered'] == false);
    if (unrecovered.isNotEmpty) {
      return (unrecovered.first['kind'] ?? 'unrecovered_error').toString();
    }
    if ((summary['links_red'] ?? 0) != 0) return 'link_red';
    if ((summary['pings_failed'] ?? 0) != 0) return 'ping_failed';
    if ((summary['security_failed'] ?? 0) != 0) return 'security_check_failed';
    if ((summary['devices_skipped'] ?? 0) != 0) return 'device_skipped';
    if ((summary['errors_unrecovered'] ?? 0) != 0) {
      return 'unrecovered_error';
    }
    return '';
  }

  Future<void> _saveExecutionEvidence({
    required Map<String, dynamic> summary,
    required List<Map<String, dynamic>> events,
  }) async {
    final mem = context.read<MemoryService>();
    if (!mem.ready) return;
    final ok = summary['ok'] == true;
    final failureKind = _failureKind(summary, events);
    final failureDetail = ok
        ? null
        : 'devices_skipped=${summary['devices_skipped'] ?? 0}; '
              'unrecovered=${summary['errors_unrecovered'] ?? 0}; '
              'red_links=${summary['links_red'] ?? 0}; '
              'pings_failed=${summary['pings_failed'] ?? 0}';
    final evidence = BuildAttempt.evidence({
      'summary': summary,
      'events': events,
      'verification': ok ? 'passed' : 'failed',
    });
    if (widget.record.id != null) {
      await mem.updateBuildOutcome(
        id: widget.record.id!,
        success: ok,
        status: ok ? 'verified' : 'failed',
        error: failureDetail,
      );
      final attempt = await mem.latestAttemptForBuild(widget.record.id!);
      if (attempt != null) {
        await mem.updateAttempt(
          id: attempt.id!,
          status: ok ? 'verified' : 'failed',
          failureKind: failureKind.isEmpty ? null : failureKind,
          failureDetail: failureDetail,
          evidenceJson: evidence,
          correction: attempt.correction,
        );
      }
      // FEEDBACK LOOP: a failed build invalidates the cached plan for its
      // brief, so the next attempt re-plans with the failure in view instead
      // of replaying the same broken plan from cache.
      if (!ok && widget.brief.isNotEmpty) {
        await GeminiService.invalidateCachedPlan(widget.brief, widget.target);
      }
    }
  }

  Future<void> _markAttemptExecuting() async {
    if (!mounted) return;
    final mem = context.read<MemoryService>();
    if (!mem.ready || widget.record.id == null) return;
    final attempt = await mem.latestAttemptForBuild(widget.record.id!);
    if (attempt == null) return;
    await mem.updateAttempt(
      id: attempt.id!,
      status: 'executing',
      failureKind: attempt.failureKind,
      failureDetail: attempt.failureDetail,
      evidenceJson: attempt.evidenceJson,
      correction: attempt.correction,
    );
  }

  /// Watches the autopilot run until it finishes, then AUTO-LOGS the
  /// outcome into memory.db - failures finally persist with zero manual
  /// steps and shape future Gemini prompts (similar-build context).
  Future<void> _watchRun() async {
    final engine = AutopilotService.of(context);
    if (_watching) return;
    _watching = true;
    try {
      // wait for the run to actually start (max 60s)
      var started = false;
      for (var i = 0; i < 12; i++) {
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        try {
          final s = jsonDecode(await engine.status()) as Map<String, dynamic>;
          if (s['running'] == true) {
            started = true;
            break;
          }
        } catch (_) {}
      }
      if (!started) return;
      // poll until finished (runs can take a while; cap ~30 min)
      for (var i = 0; i < 360; i++) {
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        var running = true;
        try {
          final s = jsonDecode(await engine.status()) as Map<String, dynamic>;
          running = s['running'] == true;
        } catch (_) {
          continue; // transient sidecar hiccup - keep watching
        }
        if (!running) break;
      }
      if (!mounted) return;
      final summary = await engine.runSummary();
      final ok = summary['ok'] == true;
      final skipped = summary['devices_skipped'] ?? 0;
      final unrec = summary['errors_unrecovered'] ?? 0;
      final red = summary['links_red'] ?? 0;
      final rec = summary['errors_recovered'] ?? 0;
      final pingsOk = summary['pings_ok'] ?? 0;
      final pingsFail = summary['pings_failed'] ?? 0;
      final devicesPlaced = (summary['devices_placed'] ?? 0) as int;
      final devicesReused = (summary['devices_reused'] ?? 0) as int;
      final devicesVisible = devicesPlaced + devicesReused;
      final serviceRulesUnverified = summary['srv_rules_unverified'] ?? 0;
      final serviceRulesVerified = summary['srv_rules_verified'] ?? 0;
      final cliModeRepairs = summary['cli_mode_repairs'] ?? 0;
      final sessionCorrectionsLearned =
          summary['session_corrections_learned'] ?? 0;
      final sessionCorrectionsApplied =
          summary['session_corrections_applied'] ?? 0;
      final sessionCorrectionsRejected =
          summary['session_corrections_rejected'] ?? 0;
      final pcsDone = summary['pcs_configured'] ?? 0;
      final securityFailed = summary['security_failed'] ?? 0;
      final securityChecks = (summary['security_checks'] as List?)?.length ?? 0;
      final validation = summary['validation'] as Map?;
      final failedChecks = ((validation?['checks'] as List?) ?? [])
          .whereType<Map>()
          .where((c) => c['ok'] != true)
          .map((c) => c['name'].toString())
          .toList();
      final validationLine = validation == null
          ? 'validation=not recorded'
          : 'validation=${validation['ok'] == true ? 'OK' : 'FAILED'}'
                '${failedChecks.isEmpty ? '' : ' (${failedChecks.join(', ')})'}';
      // CLI mode proof: which evidence was missing, and how often the extra
      // settled read rescued a line that would otherwise have been dropped.
      final blockReasons = (summary['cli_block_reasons'] as Map?) ?? const {};
      final promptRecovered = summary['cli_prompt_recovered'] ?? 0;
      final cliProofLine = (blockReasons.isEmpty && promptRecovered == 0)
          ? ''
          : 'CLI PROOF: lines saved by the settled re-read=$promptRecovered'
                '${blockReasons.isEmpty ? '' : '  blocked: '
                          '${blockReasons.entries.map((e) => '${e.key}=${e.value}').join(', ')}'}'
                '\n';
      // CROSS-RUN LEARNING: what the engine escalated once and then stopped
      // retrying, plus the lines it stopped re-asking the model about. A
      // skipped step is always named here - a smaller network with an
      // explanation, never a silently incomplete one.
      final skippedBlockers =
          (summary['known_blockers_skipped'] as List? ?? const [])
              .map((e) => e.toString())
              .toList();
      final escalations = summary['repeat_offender_escalations'] ?? 0;
      final llmSkipped = summary['llm_asks_skipped'] ?? 0;
      final learningLine =
          (skippedBlockers.isEmpty && escalations == 0 && llmSkipped == 0)
          ? ''
          : 'LEARNING LOOP: escalated=$escalations '
                'skippedKnownBlockers=${skippedBlockers.length} '
                'llmAsksSkipped=$llmSkipped\n'
                '${skippedBlockers.map((s) => '  SKIPPED: $s').join('\n')}'
                '${skippedBlockers.isEmpty ? '' : '\n'}';
      // The .pkt the run left behind, plus what it should contain. The file
      // is only saved for a green run, so an error here never hides a build
      // failure - it explains why no file was produced.
      final pkt = summary['pkt'] as Map?;
      final comparison = (pkt?['comparison'] as Map?) ?? const {};
      final artifactLine = pkt == null || pkt.isEmpty
          ? ''
          : (pkt['path'] != null
                ? 'ARTIFACT ${pkt['path']}\n'
                      '  devices=${comparison['devicesOnCanvas'] ?? '?'}'
                      '/${comparison['plannedDevices'] ?? '?'} '
                      'linksFailed=${comparison['linksFailed'] ?? 0} '
                      'cliBlocks=${comparison['cliBlocks'] ?? 0} '
                      'saved in ${pkt['saveMs'] ?? '?'}ms\n'
                : 'ARTIFACT not saved: ${pkt['error'] ?? 'unknown reason'}\n');
      if (!mounted) return;
      final mem = context.read<MemoryService>();
      if (mem.ready) {
        List<Map<String, dynamic>> events = [];
        try {
          events = await engine.events(limit: 80);
        } catch (_) {}
        await _saveExecutionEvidence(summary: summary, events: events);
        // AUTO-LEARN: recurring failure patterns are filed with no manual
        // step. They carry an `autopilot` target so planners and model
        // prompts skip them - advice only changes a plan when the user
        // teaches a rule that says so.
        try {
          final sug = await engine.suggestions();
          final existing = (await mem.allRules())
              .map((r) => r.ruleText)
              .toSet();
          var learned = 0;
          for (final s in sug) {
            if (!existing.contains(s)) {
              await mem.addRule(s, targets: 'autopilot');
              learned++;
            }
          }
          if (!mounted) return;
          if (learned > 0) {
            setState(
              () => _log =
                  'RUN FINISHED ${ok ? "OK" : "WITH ISSUES"}\n'
                  'configured=${summary['devices_done'] ?? 0} '
                  'placed=$devicesVisible skipped=$skipped '
                  'recoveredErrors=$rec unrecovered=$unrec redLinks=$red '
                  'autoHeals=${summary['admin_heals'] ?? 0}\n'
                  'PCs configured=$pcsDone  PINGS: $pingsOk passed, '
                  '$pingsFail failed  security: $securityChecks checks, '
                  '$securityFailed failed  service rules verified=$serviceRulesVerified '
                  'state-only=$serviceRulesUnverified  CLI mode repairs=$cliModeRepairs  '
                  'session fixes learned=$sessionCorrectionsLearned '
                  'applied=$sessionCorrectionsApplied '
                  'rejected=$sessionCorrectionsRejected  '
                  'llm asked=${summary['llm_calls'] ?? 0} '
                  'llm fixed=${summary['llm_fixes_applied'] ?? 0} '
                  'llm rejected=${summary['llm_fixes_rejected'] ?? 0}  '
                  '$validationLine\n'
                  '$cliProofLine'
                  '$learningLine'
                  '$artifactLine'
                  'RECORDED $learned recurring pattern(s) for review - '
                  'not applied to plans.',
            );
            return;
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _log =
            'RUN FINISHED ${ok ? "OK" : "WITH ISSUES"}\n'
            'configured=${summary['devices_done'] ?? 0} '
            'placed=$devicesVisible skipped=$skipped '
            'recoveredErrors=$rec unrecovered=$unrec redLinks=$red '
            'autoHeals=${summary['admin_heals'] ?? 0}\n'
            'PCs configured=$pcsDone  PINGS: $pingsOk passed, '
            '$pingsFail failed  security: $securityChecks checks, '
            '$securityFailed failed  service rules verified=$serviceRulesVerified '
            'state-only=$serviceRulesUnverified  CLI mode repairs=$cliModeRepairs  '
            'session fixes learned=$sessionCorrectionsLearned '
            'applied=$sessionCorrectionsApplied '
            'rejected=$sessionCorrectionsRejected  '
            'llm asked=${summary['llm_calls'] ?? 0} '
            'llm fixed=${summary['llm_fixes_applied'] ?? 0} '
            'llm rejected=${summary['llm_fixes_rejected'] ?? 0}  '
            '$validationLine\n'
            '$cliProofLine'
            '$learningLine'
            '$artifactLine'
            'Outcome saved to memory. '
            '${ok ? "" : "See the Memory tab - recurring problems become suggested rules."}';
      });
    } catch (_) {
      // learning must never break the run UX
    } finally {
      _watching = false;
    }
  }

  /// Rows for the AI suggestions card: each proposal with its evaluation
  /// score, the evaluator's concern, and where it was recorded.
  List<Widget> _aiSuggestRows() {
    final proposals = (_aiSuggest?['proposals'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (proposals.isEmpty) {
      return const [
        Text(
          'No usable proposals for the current failures.',
          style: TextStyle(fontSize: 12),
        ),
      ];
    }
    return [
      for (final p in proposals)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _aiProposalRow(p),
        ),
    ];
  }

  /// One proposal row: verdict glyph, what it proposes, its AI score and
  /// (when present) why the evaluator or screener turned it down - plus the
  /// teaching-loop badge strip for its correction id.
  Widget _aiProposalRow(Map<String, dynamic> p) {
    final what = (p['target'] == 'cli')
        ? (p['cli'] as List? ?? []).join(' ; ')
        : (p['label']?.toString().isNotEmpty == true
              ? p['label']
              : p['pointHint'] ?? p['reason'] ?? '');
    final score = p['score'] != null ? '  (AI score ${p['score']}/5)' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "${p['accepted'] == true ? '\u2713' : '\u2717'} "
          "${p['failureKind']}: $what$score",
          style: const TextStyle(fontSize: 12),
        ),
        if (p['screenedOut'] != null)
          Text(
            '  rejected before evaluation: ${p['screenedOut']}',
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
        if (p['accepted'] == true && p['correctionId'] != null)
          const Text(
            '  saved as a proposed correction - verify it '
            'with a teach run',
            style: TextStyle(fontSize: 11),
          ),
        if (p['accepted'] != true &&
            p['concern']?.toString().isNotEmpty == true)
          Text(
            '  why not: ${p['concern']}',
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
        _proposalBadges(p),
      ],
    );
  }

  Future<void> _saveCorrection() async {
    final mem = context.read<MemoryService>();
    if (!mem.ready) {
      setState(() => _log = 'Memory not ready yet.');
      return;
    }
    final fix = _fix.text.trim();
    if (fix.isEmpty) {
      setState(() => _log = 'Type the correction first.');
      return;
    }
    final rule = MemoryService.distillRule(intent: widget.intent, userFix: fix);
    await mem.addRule(rule, targets: widget.record.target);
    if (widget.record.id != null) {
      final attempt = await mem.latestAttemptForBuild(widget.record.id!);
      if (attempt != null) {
        await mem.updateAttempt(
          id: attempt.id!,
          status: 'corrected',
          correction: fix,
          failureKind: attempt.failureKind,
          failureDetail: attempt.failureDetail,
          evidenceJson: attempt.evidenceJson,
        );
      }
      await mem.updateBuildOutcome(
        id: widget.record.id!,
        success: false,
        status: 'corrected',
        error: 'Correction recorded; run again to verify it.',
        fix: fix,
      );
    }
    setState(() => _log = 'Learned rule saved:\n$rule');
    _fix.clear();
  }

  void _previewSearch() {
    final err = _fix.text.trim().isEmpty ? _log : _fix.text.trim();
    final q = PrivacySearchService.buildQuery(
      errorText: err.isEmpty ? widget.record.instruction : err,
      target: widget.record.target,
      vendorHint: 'cisco',
    );
    setState(() {
      _searchPreview = q;
      _log = PrivacySearchService.previewPayload(q);
    });
  }

  Future<void> _runSearch() async {
    if (_searchPreview.isEmpty) {
      _previewSearch();
      return;
    }
    setState(() {
      _busy = true;
      _log = 'Searching web for: "$_searchPreview" ...';
    });
    try {
      // DuckDuckGo instant-answer API: no key required. Only the generic
      // query leaves the device (after user pressed Search = Approve).
      final uri = Uri.parse(
        'https://api.duckduckgo.com/?q=${Uri.encodeComponent(_searchPreview)}&format=json&no_html=1',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final abs = (j['AbstractText'] as String? ?? '').trim();
      final topics = (j['RelatedTopics'] as List? ?? [])
          .take(3)
          .map((t) {
            if (t is Map && t['Text'] != null) return '- ${t['Text']}';
            return null;
          })
          .whereType<String>()
          .join('\n');
      setState(() {
        _log = abs.isEmpty && topics.isEmpty
            ? 'No instant answer. Open in browser with the query above.'
            : 'Result:\n$abs\n$topics';
      });
      // Learn from it: store the query as context for next time
      if (!mounted) return;
      final mem = context.read<MemoryService>();
      if (mem.ready) {
        await mem.setPref(
          'last_search_${widget.record.projectName}',
          _searchPreview,
        );
      }
    } catch (e) {
      setState(() => _log = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushGns3() async {
    if (!_executionPreflight('gns3')) return;
    setState(() {
      _busy = true;
      _log = 'Pushing topology to GNS3 (project + nodes + links)...';
    });
    try {
      final s = context.read<SettingsService>();
      final report = await Gns3Adapter.push(
        widget.intent,
        endpoint: s.gns3Endpoint,
        user: s.gns3User,
        pass: s.gns3Pass,
      );
      final partial = RegExp(r'^(FAIL|SKIP)', multiLine: true).hasMatch(report);
      if (!mounted) return;
      final mem = context.read<MemoryService>();
      if (mem.ready && widget.record.id != null) {
        await mem.updateBuildOutcome(
          id: widget.record.id!,
          success: !partial,
          status: partial ? 'failed' : 'verified',
          error: partial ? report : null,
        );
        final attempt = await mem.latestAttemptForBuild(widget.record.id!);
        if (attempt != null) {
          await mem.updateAttempt(
            id: attempt.id!,
            status: partial ? 'failed' : 'verified',
            failureKind: partial ? 'gns3_partial_push' : null,
            failureDetail: partial ? report : null,
            evidenceJson: BuildAttempt.evidence({'report': report}),
            correction: attempt.correction,
          );
        }
      }
      if (!mounted) return;
      setState(
        () => _log =
            'GNS3 push done.\n$report\nOpen the project in the GNS3 GUI to '
            'see it. Missing templates? Install c3725 / Ethernet switch / '
            'VPCS templates in GNS3 first.',
      );
    } on Gns3ApiException catch (e) {
      setState(
        () => _log = e.status == 401
            ? 'GNS3 rejected the credentials (401). GNS3 2.2+ ships with '
                  'HTTP auth enabled - set user/password in Settings '
                  '(default user: admin). If you disabled auth on the '
                  'server, leave the password blank.\nRaw: ${e.message}'
            : 'GNS3 error ${e.status}: ${e.message}\nIs the server '
                  'running at the Settings endpoint?',
      );
    } catch (e) {
      setState(
        () => _log =
            'GNS3 push failed: $e\nIs GNS3 server running at that endpoint? '
            'Export JSON still works.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSidecar() async {
    final svc = AutopilotService.of(context);
    setState(() {
      _busy = true;
      _log = 'Checking sidecar ${svc.base}/health ...';
    });
    try {
      final health = await svc.healthDetails();
      final status = await svc.statusDetails();
      if (!mounted) return;
      final esc = health['emergencyEsc'] as Map?;
      final escText = esc?['available'] == true
          ? 'Global Esc stop is ENABLED on the sidecar (it intercepts keys '
                'system-wide; start the sidecar with '
                'NETBUILDER_ENABLE_GLOBAL_HOTKEYS=1 to get it).'
          : 'Global Esc stop is off: ${esc?['error'] ?? 'not enabled on the sidecar'}. '
                'Use the Stop button here, or POST /stop to the engine.';
      final state = _describeSidecarState(status);
      setState(() {
        _sidecarState = state;
        _log =
            'Sidecar OK. $state\n$escText\n'
            'The red Stop button also sends the same stop signal.';
      });
    } catch (e) {
      await _showExecutionError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ptStop() async {
    if (_stopPending) return;
    _stopPending = true;
    if (mounted) {
      setState(() {
        _sidecarState = 'Stop requested - waiting for the worker to release...';
        _log = 'Stop requested. Waiting for the sidecar to become idle...';
      });
    }
    try {
      final svc = AutopilotService.of(context);
      final res = await svc.stop();
      Map<String, dynamic>? latest;
      // /stop is deliberately an acknowledgement, not a false claim that
      // the current UI action has already finished. Wait for the authoritative
      // status transition before telling the user it is safe to start again.
      for (var i = 0; i < 30; i++) {
        try {
          latest = await svc.statusDetails();
          if (latest['running'] != true) break;
        } catch (_) {
          // A brief response hiccup should not turn a successful stop into a
          // misleading failure message.
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (!mounted) return;
      if (latest == null) {
        setState(
          () => _log = 'Stop sent: $res\nLive status could not be read yet.',
        );
      } else {
        final state = _describeSidecarState(latest);
        setState(() {
          _sidecarState = state;
          _log = latest?['running'] == true
              ? 'Stop sent, but the sidecar is still releasing its current action.\n'
                    'Live sidecar status: $state'
              : 'Sidecar is idle. No job is still running.\nStop response: $res';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      _stopPending = false;
    }
  }

  /// Pause/resume the active run. Pause holds the worker at its next safe
  /// boundary and keeps all progress; the app's Pause button and the
  /// sidecar's HTTP /pause_toggle both do this from anywhere.
  Future<void> _ptPauseToggle() async {
    if (_pausePending) return;
    _pausePending = true;
    final wantPause = !_sidecarIsPaused;
    if (mounted) {
      setState(() {
        _log = wantPause
            ? 'Pause requested - the worker will hold at the next safe '
                  'boundary (progress is kept)...'
            : 'Resume requested - continuing the run...';
      });
    }
    try {
      final svc = AutopilotService.of(context);
      final res = wantPause ? await svc.pause() : await svc.resume();
      if (!mounted) return;
      final msg = (res['message'] ?? '').toString();
      final pause = res['pause'];
      setState(() {
        if (pause is Map) {
          _sidecarIsPaused =
              pause['paused'] == true || pause['pauseRequested'] == true;
          _sidecarState = _sidecarIsPaused
              ? 'Busy - job (PAUSED; press Pause to resume).'
              : _sidecarState;
        }
        _log = msg.isEmpty
            ? (wantPause ? 'Pause acknowledged.' : 'Resume acknowledged.')
            : msg;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      _pausePending = false;
      if (mounted) {
        // Let the status poll confirm the authoritative state shortly.
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _refreshSidecarState();
        });
      }
    }
  }

  Future<void> _proveMove() async {
    setState(() {
      _busy = true;
      _log =
          'Mouse test: watch Packet Tracer - the cursor should draw a square...';
    });
    try {
      final res = await AutopilotService.of(context).prove();
      if (!mounted) return;
      setState(
        () => _log =
            'Prove result: $res\nDid the mouse move? NO = focus/permission issue (run sidecar as admin, keep PT focused). YES = press PT Autopilot Start.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadCal() async {
    try {
      final cal = await AutopilotService.of(context).calGet();
      if (!mounted) return;
      setState(() {
        _gridX0 = ((cal['grid_x0'] as num?)?.toDouble() ?? _gridX0).clamp(
          0.05,
          0.9,
        );
        _gridStep = ((cal['grid_step'] as num?)?.toDouble() ?? _gridStep).clamp(
          0.02,
          0.3,
        );
        _gridY = ((cal['grid_y'] as num?)?.toDouble() ?? _gridY).clamp(
          0.05,
          0.9,
        );
        _calLoaded = true;
        _log = 'Calibration loaded: x0=$_gridX0 step=$_gridStep y=$_gridY';
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _log =
            'Cal load failed: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<void> _saveCal() async {
    setState(() {
      _busy = true;
      _log = 'Saving calibration...';
    });
    try {
      final res = await AutopilotService.of(
        context,
      ).calSet({'grid_x0': _gridX0, 'grid_step': _gridStep, 'grid_y': _gridY});
      if (!mounted) return;
      setState(() => _log = 'Saved: $res');
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clickSlot(int idx) async {
    setState(() => _log = 'Click test grid$idx - watch PT...');
    try {
      final res = await AutopilotService.of(context).clickTest('grid$idx');
      if (!mounted) return;
      setState(
        () => _log =
            'Click test grid$idx: $res\nWrong spot? Move sliders + Save, retry.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _showRemembered() async {
    setState(() => _log = 'Loading remembered devices...');
    try {
      final devs = await AutopilotService.of(
        context,
      ).devicesGet(widget.record.projectName);
      if (!mounted) return;
      if (devs.isEmpty) {
        setState(
          () => _log =
              'No remembered devices for "${widget.record.projectName}" yet. Run autopilot once - it memorizes every drop spot automatically.',
        );
      } else {
        final lines = devs.entries
            .map(
              (e) =>
                  '- ${e.key} at (${(e.value as Map)['fx']},${(e.value as Map)['fy']})',
            )
            .join('\n');
        setState(
          () => _log =
              'Remembered ${devs.length} device(s) for "${widget.record.projectName}" (reused next run):\n$lines',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _forgetRemembered() async {
    try {
      final res = await AutopilotService.of(
        context,
      ).devicesClear(widget.record.projectName);
      if (!mounted) return;
      setState(() => _log = 'Forgot spots: $res');
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _inspectPt() async {
    setState(() => _log = 'Inspecting Packet Tracer buttons by name...');
    try {
      final res = await AutopilotService.of(context).inspect();
      if (!mounted) return;
      setState(
        () => _log =
            'PT buttons found (autopilot now clicks these BY NAME, no guessing):\n$res\n\nMissing "Network Devices"? Maximize PT and retry.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _teach(String key, String hint) async {
    setState(
      () => _log =
          'TEACH $key: you have 3 seconds - HOVER the $hint in Packet Tracer NOW, then keep still...',
    );
    try {
      final res = await AutopilotService.of(context).teach(key);
      if (!mounted) return;
      setState(
        () => _log =
            'Teach started: $res\nHover $hint NOW. Press Logs in 5s to see saved position, then Load to refresh sliders.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _pollLogs() async {
    try {
      final s = await AutopilotService.of(context).status();
      if (!mounted) return;
      setState(() => _log = 'Sidecar log:\n$s');
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _showInventory() async {
    setState(() => _log = 'Reading the latest live Packet Tracer inventory...');
    try {
      final report =
          (await AutopilotService.of(context).inventory())['report'] as Map?;
      if (!mounted) return;
      final data = report == null ? null : Map<String, dynamic>.from(report);
      setState(() {
        final counts = (data?['counts'] as Map? ?? {}).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        _log = data == null
            ? 'No live inventory has been captured yet. Start a run first.'
            : 'Live inventory for ${data['project']}: '
                  'match=${counts['match'] ?? 0}, '
                  'empty=${counts['empty'] ?? 0}, '
                  'uncertain=${counts['occupied_unknown'] ?? 0} '
                  '+ ${counts['unknown'] ?? 0}.\n'
                  'Unexpected remembered devices: '
                  '${(data['unexpected_remembered'] as List? ?? []).join(', ')}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Devices already on canvas (like now): skip placement, only cable + CLI.
  /// Uses remembered spots so no duplicates.
  Future<void> _ptCablesOnly() async {
    if (!_executionPreflight('packet-tracer')) return;
    setState(() {
      _busy = true;
      _log = 'Cables+CLI only (devices already placed, no duplicates)...';
    });
    try {
      final svc = AutopilotService.of(context);
      final ok = await svc.healthy;
      if (!ok) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      await _pushLlmConfig();
      final full = PacketTracerAdapter.autopilotPlan(widget.intent);
      final steps = ((full['steps'] as List)
          .where(
            (s) =>
                (s as Map)['action'] == 'create_links' ||
                (s)['action'] == 'paste_cli' ||
                (s)['action'] == 'config_pcs',
          )
          .toList());
      final res = await svc.start({
        'project': widget.intent.projectName,
        'requirement': full['requirement'],
        'steps': steps,
        'mode': 'cables_only',
      });
      await _markAttemptExecuting();
      if (!mounted) return;
      setState(
        () => _log =
            'Cables-only started: $res\nWATCH PT - cables need remembered spots. Press Logs for progress.',
      );
      await Future.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      try {
        final s = await svc.status();
        if (!mounted) return;
        setState(() => _log = 'Started: $res\n\nSidecar log:\n$s');
      } catch (_) {}
      _watchRun(); // learn from the outcome when the run finishes
    } catch (e) {
      await _showExecutionError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Give the sidecar the Gemini credential for this run. Best effort: a
  /// missing key or an unreachable sidecar must never block a build.
  Future<void> _pushLlmConfig() async {
    final engine = AutopilotService.of(context);
    try {
      final s = context.read<SettingsService>();
      final key = await s.getApiKey() ?? '';
      await engine.pushLlmConfig(
        apiKey: key,
        model: s.model,
        enabled: key.isNotEmpty && !s.privateMode && s.llmFix,
        // Auto-learning rides along with the key: with it on, a failing run
        // proposes and (when a PT window is present) verifies a correction
        // with no button press.  The fail-closed gate is unchanged.
        autoLearn: s.autoLearn,
        autoSuggest: s.autoLearn && s.autoSuggest,
        autoTeach: s.autoLearn && s.autoTeach,
      );
    } catch (_) {
      // optional helper - never fail the run over it
    }
  }

  Future<void> _ptAutopilot() async {
    if (!_executionPreflight('packet-tracer')) return;
    setState(() {
      _busy = true;
      _log = 'Checking sidecar first...';
    });
    try {
      final svc = AutopilotService.of(context);
      final ok = await svc.healthy;
      if (!ok) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      await _pushLlmConfig();
      final plan = PacketTracerAdapter.autopilotPlan(widget.intent);
      final res = await svc.start(plan);
      await _markAttemptExecuting();
      if (!mounted) return;
      setState(
        () => _log =
            'Sidecar accepted plan: $res\nWATCH PT NOW - mouse must move in a square first.\nRepeat-run safety is enabled: matching remembered devices and previously verified commands are reused. Recoverable misclicks and command errors are retried and recorded as learning evidence. An occupied but uncertain slot is blocked instead of duplicated. Fixes mode always re-applies its selected commands.\nPress "Logs" every few seconds to see clicks. Do not touch mouse/keyboard. Use Stop to abort.',
      );
      // auto-fetch logs after a few seconds so "nothing happens" is visible
      await Future.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      try {
        final s = await svc.status();
        if (!mounted) return;
        setState(() => _log = 'Started: $res\n\nSidecar log:\n$s');
      } catch (_) {}
      _watchRun(); // learn from the outcome when the run finishes
    } catch (e) {
      await _showExecutionError(e);
      if (mounted && !_log.contains('Plan JSON is in the config above')) {
        setState(
          () => _log =
              '$_log\nPlan JSON is in the config above; paste manually meanwhile.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Post-build verification: run the plan's derived test list in the live
  /// Packet Tracer window (gateway + service pings from every endpoint) and
  /// show pass/fail evidence per test. Read-only: it types pings, nothing else.
  Future<void> _verifyBuild() async {
    setState(() {
      _verifying = true;
      _verifyReport = null;
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      final plan = PacketTracerAdapter.autopilotPlan(widget.intent);
      await svc.verifyRun(plan);
      // poll until the runner finishes (bounded: 25 tests * ~12s)
      for (var i = 0; i < 150; i++) {
        await Future.delayed(const Duration(seconds: 4));
        if (!mounted) return;
        final rep = await svc.verifyReport();
        if (rep != null) {
          setState(() => _verifyReport = rep);
          if (rep['error'] != null) break;
          if ((rep['total'] ?? 0) > 0) break; // a finished report has tests
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _log = 'Verification failed: $e');
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// Offline .pkt generation: the same plan the autopilot would drive the
  /// GUI with, compiled straight to a save file by the sidecar - no Packet
  /// Tracer, no mouse, no screen. A timestamped filename means a repeat
  /// click never overwrites an earlier artifact.
  Future<void> _generatePkt() async {
    setState(() {
      _busy = true;
      _log = 'Generating .pkt offline (no Packet Tracer needed)...';
    });
    try {
      final svc = AutopilotService.of(context);
      final ok = await svc.healthy;
      if (!ok) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      final plan = PacketTracerAdapter.autopilotPlan(widget.intent);
      final res = await svc.pktGenerate(
        plan,
        // Named for the network: the record's own instruction is the
        // description, so the file in the folder reads like the lab it is.
        filename: BuildArtifactService.networkFileName(
          plan: widget.intent,
          brief: widget.record.instruction,
          taken: const {},
        ),
      );
      if (!mounted) return;
      final warnings = (res['warnings'] as List?) ?? const [];
      final path = (res['path'] ?? '').toString();
      final warningText = warnings.isEmpty
          ? 'No warnings.'
          : 'Warnings:\n- ${warnings.join('\n- ')}';
      final substituted = warnings.any(
        (w) => w.toString().contains('instead of'),
      );
      final learning = res['learning'];
      final learningText = (learning is Map && learning['note'] != null)
          ? "\nOffline learning (#${learning['generations']}): "
                "${learning['note']}"
          : '';
      setState(() {
        _log =
            'Generated: $path\n'
            'devices: ${res['deviceCount']}, links: ${res['linkCount']}\n'
            '$warningText\n'
            '${substituted ? 'A model this plan asked for was not in the library, '
                      'so the nearest match was used. Press "Extend model library" to '
                      'read the models Packet Tracer ships with, then generate again.\n' : ''}'
            'Open it in Packet Tracer to verify, then run Analyze on it.'
            '$learningText';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Read every .pkt Packet Tracer ships with (plus anything the sidecar
  /// already knows) into the template library, so a plan's requested model
  /// becomes a real template instead of a nearest-match substitution.
  /// Additive only: an existing model keeps its block.
  Future<void> _harvestModels() async {
    setState(() {
      _busy = true;
      _log = 'Reading local .pkt files for device models...';
    });
    try {
      final svc = AutopilotService.of(context);
      if (!await svc.healthy) {
        if (!mounted) return;
        setState(() => _log = svc.hint);
        return;
      }
      final res = await svc.pktTemplatesHarvest();
      if (!mounted) return;
      final added = ((res['added'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      setState(() {
        _log =
            'Model library now covers ${res['deviceCount']} models, '
            'read from ${res['scanned']} .pkt file(s).'
            '${added.isEmpty ? '\nNo new models: this machine already had them all.' : '\nAdded ${added.length}:\n- ${added.take(40).join('\n- ')}'}'
            '${added.length > 40 ? '\n- ...' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _calSlider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text('$label ${value.toStringAsFixed(2)}')),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final issues = ValidatorService.validate(
      widget.intent,
      target: widget.record.target,
    );
    return AppPage(
      maxWidth: 980,
      header: AppPageHeader(
        eyebrow: 'Build',
        title: widget.record.projectName,
        trailing: AppTag(
          label: widget.record.target,
          tone: AppTone.info,
          icon: Icons.place_outlined,
          mono: true,
        ),
        description: widget.record.instruction,
        actions: [
          AppTag(
            label: 'Plan ${widget.record.status.toUpperCase()}',
            tone: AppTone.neutral,
            icon: Icons.assignment_outlined,
          ),
        ],
      ),
      children: [
        AppBanner(
          tone: AppTone.accent,
          title: 'Compiled locally',
          icon: Icons.psychology_outlined,
          message:
              'The AI interpreted the request and the app compiled this output '
              'locally. No external network or Packet Tracer change happens '
              'until you choose an execution button. Execution results, '
              'failures, and misclicks are saved as evidence.\n'
              'Planning source: ${widget.intent.planningSource}',
        ),
        if (widget.intent.questions.isNotEmpty)
          AppPanel(
            icon: Icons.help_outline,
            tone: AppTone.warning,
            filled: true,
            title: 'Review these open questions',
            children: [
              for (final q in widget.intent.questions)
                AppRowTile(
                  dense: true,
                  icon: Icons.arrow_right_alt,
                  tone: AppTone.warning,
                  title: q,
                ),
            ],
          ),
        if (issues.isEmpty)
          const AppBanner(
            tone: AppTone.success,
            icon: Icons.verified_outlined,
            message: 'Validator: clean.',
          )
        else
          AppPanel(
            icon: Icons.rule_outlined,
            title: 'Validator',
            subtitle:
                '${issues.where((i) => i.severity == 'error').length} error(s), '
                '${issues.where((i) => i.severity != 'error').length} warning(s)',
            children: [
              for (final i in issues)
                AppBanner(
                  dense: true,
                  tone: i.severity == 'error'
                      ? AppTone.danger
                      : AppTone.warning,
                  message: '[${i.severity}] ${i.message}',
                ),
              if (issues.any((i) => i.severity == 'error'))
                const AppBanner(
                  dense: true,
                  tone: AppTone.danger,
                  icon: Icons.block,
                  message:
                      'Execution is blocked until the validator errors above '
                      'are fixed. Warnings are review items and do not block a '
                      'run.',
                ),
            ],
          ),
        AppPanel(
          icon: Icons.play_circle_outline,
          title: 'Run this plan',
          subtitle:
              'Each button starts one kind of run; nothing runs on its own.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _busy ? null : _pushGns3,
                  icon: const Icon(Icons.hub_outlined, size: 18),
                  label: const Text('Push to GNS3'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _ptAutopilot,
                  icon: const Icon(Icons.smart_toy_outlined, size: 18),
                  label: const Text('PT Autopilot Start'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _ptCablesOnly,
                  icon: const Icon(Icons.cable_outlined, size: 18),
                  label: const Text('Cables + CLI only'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _generatePkt,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Generate .pkt (no PT)'),
                ),
                ElevatedButton.icon(
                  onPressed: (_busy || _verifying) ? null : _verifyBuild,
                  icon: const Icon(Icons.network_ping, size: 18),
                  label: const Text('Verify (ping tests)'),
                ),
              ],
            ),
          ],
        ),
        AppPanel(
          icon: Icons.build_outlined,
          title: 'Diagnostics',
          subtitle: 'Read-only tools that inspect the app, the sidecar and PT.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _harvestModels,
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text('Extend model library'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _checkSidecar,
                  icon: const Icon(Icons.health_and_safety_outlined, size: 18),
                  label: const Text('Check Sidecar'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _showInventory,
                  icon: const Icon(Icons.devices_other_outlined, size: 18),
                  label: const Text('Live Inventory'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _proveMove,
                  icon: const Icon(Icons.mouse_outlined, size: 18),
                  label: const Text('Test Mouse Move'),
                ),
                OutlinedButton.icon(
                  onPressed: _inspectPt,
                  icon: const Icon(Icons.troubleshoot_outlined, size: 18),
                  label: const Text('Inspect PT'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pollLogs,
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: const Text('Logs'),
                ),
              ],
            ),
          ],
        ),
        AppPanel(
          icon: Icons.travel_explore_outlined,
          title: 'Search for a fix',
          subtitle:
              'Searches leave this machine only when you press the button.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _previewSearch,
                  icon: const Icon(Icons.preview_outlined, size: 18),
                  label: const Text('Preview Web Search'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _runSearch,
                  icon: const Icon(Icons.travel_explore_outlined, size: 18),
                  label: const Text('Search Web For Fix'),
                ),
              ],
            ),
          ],
        ),
        AppBanner(
          tone: _sidecarState.startsWith('Busy')
              ? AppTone.warning
              : _sidecarState.startsWith('Idle')
              ? AppTone.success
              : AppTone.info,
          title: 'Sidecar live status',
          icon: _sidecarState.startsWith('Busy')
              ? Icons.hourglass_top
              : _sidecarState.startsWith('Idle')
              ? Icons.pause_circle_outline
              : Icons.help_outline,
          message: _sidecarState,
          actions: [
            TextButton.icon(
              onPressed: _busy ? null : _checkSidecar,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.description_outlined,
          title: 'Deterministic config / export from this plan',
          children: [
            AppCodeBlock(
              text: widget.configText,
              title: 'Generated config',
              maxHeight: 320,
            ),
          ],
        ),
        AppPanel(
          icon: Icons.account_tree_outlined,
          title: 'Topology',
          subtitle:
              '${widget.intent.nodes.length} device(s), '
              '${widget.intent.links.length} link(s)',
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in widget.intent.nodes)
                  AppTag(
                    label: '${n.name} · ${n.type}',
                    tone: AppTone.accent,
                    mono: true,
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.s10),
            AppCodeBlock(
              text: widget.intent.links
                  .map((l) => '${l.a}:${l.aIf}  <->  ${l.b}:${l.bIf}')
                  .join('\n'),
              title: 'Links',
              maxHeight: 200,
              compact: true,
            ),
          ],
        ),
        const AppBanner(
          tone: AppTone.info,
          icon: Icons.shield_outlined,
          title: 'Repeat-run safety',
          message:
              'The autopilot checks each remembered canvas slot before acting. '
              'A matching device skips placement, and an exact previously '
              'verified router/switch configuration skips retyping. Recoverable '
              'placement and command errors are retried and saved to learning '
              'memory. If the screen is still uncertain, it stops that device '
              'rather than stacking another one. Use "Cables + CLI only" for an '
              'existing topology; the Fixes action intentionally re-applies '
              'selected commands.',
        ),
        if (_busy) const LinearProgressIndicator(),
        AppPanel(
          tone: _sidecarIsPaused ? AppTone.success : AppTone.warning,
          filled: true,
          icon: _sidecarIsPaused
              ? Icons.play_circle_outline
              : Icons.pause_circle_outline,
          title: _sidecarIsPaused
              ? 'The run is paused at a safe boundary'
              : 'Pause the run',
          subtitle: _sidecarIsPaused
              ? 'All progress is kept. Resume to continue where it stopped.'
              : 'A pause is non-destructive: it parks at the next safe '
                    'boundary and keeps every step.',
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _sidecarIsPaused
                      ? AppPalette.success(Theme.of(context).colorScheme)
                      : AppPalette.warning(Theme.of(context).colorScheme),
                  side: BorderSide(
                    color: _sidecarIsPaused
                        ? AppPalette.success(Theme.of(context).colorScheme)
                        : AppPalette.warning(Theme.of(context).colorScheme),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: Icon(
                  _sidecarIsPaused ? Icons.play_circle : Icons.pause_circle,
                  size: 28,
                ),
                label: Text(
                  _sidecarIsPaused ? 'RESUME AUTOPILOT' : 'PAUSE AUTOPILOT',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: _pausePending ? null : _ptPauseToggle,
              ),
            ),
          ],
        ),
        AppPanel(
          tone: AppTone.danger,
          filled: true,
          icon: Icons.stop_circle_outlined,
          title: 'Emergency stop',
          subtitle: 'Cancels all autopilot work immediately.',
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.stop_circle, size: 28),
                label: const Text(
                  'STOP AUTOPILOT',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                onPressed: _stopPending ? null : _ptStop,
              ),
            ),
            const SizedBox(height: AppTheme.s10),
            Text(
              'Safety: press STOP to cancel all autopilot work. If needed, '
              'move the mouse to a screen corner for the emergency failsafe.',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.mutedText(Theme.of(context).colorScheme),
              ),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.fact_check_outlined,
          title: 'Audit',
          subtitle:
              'Offline reads the .pkt without Packet Tracer; live opens each '
              'device and checks the real network.',
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final offline = OutlinedButton.icon(
                  onPressed: _busy || _auditing
                      ? null
                      : () => _runAudit(offline: true),
                  icon: const Icon(Icons.description, size: 18),
                  label: Text(
                    _auditing
                        ? 'Auditing offline...'
                        : 'Audit .pkt (offline, no PT)',
                  ),
                );
                final live = OutlinedButton.icon(
                  onPressed: _busy || _auditing ? null : _runAudit,
                  icon: const Icon(Icons.fact_check, size: 18),
                  label: Text(
                    _auditing
                        ? 'Auditing network (opens each device)...'
                        : 'Audit Network (live)',
                  ),
                );
                if (constraints.maxWidth < 620) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      offline,
                      const SizedBox(height: AppTheme.s8),
                      live,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: offline),
                    const SizedBox(width: 8),
                    Expanded(child: live),
                  ],
                );
              },
            ),
          ],
        ),
        if (_audit != null) _buildAuditCard(),
        const SizedBox(height: 8),
        VerificationReport(
          report: _verifyReport,
          busy: _verifying,
          onRerun: _verifyBuild,
        ),
        // The run log is the only place a long build reports its own state,
        // so a screen reader is told when it changes.
        AppPanel(
          icon: Icons.terminal_outlined,
          title: 'Execution log',
          subtitle: 'Everything this run has done, newest last.',
          children: [
            Semantics(
              liveRegion: true,
              label: 'Execution log',
              child: AppCodeBlock(
                text: _log,
                title: 'Run log',
                maxHeight: 280,
                emptyText: 'Nothing has run yet.',
                copyable: false,
              ),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.my_location_outlined,
          title: 'PT click calibration',
          subtitle: _calLoaded
              ? 'x0=$_gridX0 step=$_gridStep y=$_gridY'
              : 'Clicks land off? Load, adjust, then Save. Tap Load first.',
          children: [
            Row(
              children: [
                OutlinedButton(onPressed: _loadCal, child: const Text('Load')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _busy ? null : _saveCal,
                  child: const Text('Save'),
                ),
              ],
            ),
            _calSlider(
              'Grid start X',
              _gridX0,
              0.05,
              0.9,
              (v) => setState(() => _gridX0 = v),
            ),
            _calSlider(
              'Grid step',
              _gridStep,
              0.02,
              0.3,
              (v) => setState(() => _gridStep = v),
            ),
            _calSlider(
              'Grid Y',
              _gridY,
              0.05,
              0.9,
              (v) => setState(() => _gridY = v),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _clickSlot(0),
                  child: const Text('Test slot 0'),
                ),
                OutlinedButton(
                  onPressed: () => _clickSlot(1),
                  child: const Text('Test slot 1'),
                ),
                OutlinedButton(
                  onPressed: () => _clickSlot(2),
                  child: const Text('Test slot 2'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _showRemembered,
                  child: const Text('Remembered spots'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _forgetRemembered,
                  child: const Text('Forget spots'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'One-time teach (fixes category-only clicks forever):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: () => _teach(
                    'pal_router',
                    'Routers CATEGORY icon (bottom bar)',
                  ),
                  child: const Text('Teach Router icon'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      _teach('pal_switch', 'Switches CATEGORY icon'),
                  child: const Text('Teach Switch icon'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      _teach('model_col0', 'FIRST router MODEL thumbnail'),
                  child: const Text('Teach Model'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Category-only bug = MODEL click lands on empty space so PT never arms placement. '
                'Fix: Teach Router icon, Teach Switch icon, Teach Model once each '
                '(hover exact spot within 3s, Logs to confirm, Load to refresh). '
                'Then autopilot drops real devices. Shots in sidecar/shots/.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // TEACHING-LOOP ALERTS: stale corrections (taught but no longer
        // verifying) and rejected ones (a teach run disproved them) shown
        // right where the user decides what to fix next.
        CorrectionsCard(
          snapshot: _corrections,
          onRefresh: () => _refreshCorrections(force: true),
          onTeach: _teachCorrection,
        ),
        // AI FIX SUGGESTIONS: uses the Gemini key from Settings. Proposals
        // are evaluated by a second Gemini call; accepted ones only ever
        // become `proposed` corrections - teach runs still verify them.
        AppPanel(
          icon: Icons.auto_awesome_outlined,
          title: 'AI fix suggestions (Gemini)',
          subtitle:
              'Proposes fixes for steps that keep failing, then judges each '
              'proposal with a second AI pass. Accepted label/skip fixes are '
              'saved as PROPOSED corrections - run Verify to prove one on '
              'screen. Point/CLI suggestions stay as advice.',
          children: [
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: (_busy || _aiSuggesting) ? null : _runAiSuggest,
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(
                    _aiSuggesting ? 'AI thinking...' : 'Suggest fixes with AI',
                  ),
                ),
              ],
            ),
            if (_aiSuggest != null) ..._aiSuggestRows(),
          ],
        ),
        AppPanel(
          icon: Icons.school_outlined,
          title: 'Teach a correction',
          subtitle:
              'The rule is saved to memory and reused for matching targets.',
          children: [
            TextField(
              controller: _fix,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText:
                    'e.g. always use OSPF area 0 with auth, VLAN 10 users',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _saveCorrection,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save correction as rule'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
