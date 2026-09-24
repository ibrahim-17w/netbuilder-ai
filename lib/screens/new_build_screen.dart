import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_attempt.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/build_artifact_service.dart';
import '../services/gemini_service.dart';
import '../services/memory_service.dart';
import '../services/planner_memory_service.dart';
import '../services/secret_vault.dart';
import '../services/casual_english.dart';
import '../services/planner_suggestions_service.dart';
import '../services/rule_packs_service.dart';
import '../services/settings_service.dart';
import '../services/validator_service.dart';
import '../theme/app_palette.dart';

/// New Build Wizard: instruction -> intent preview -> generate -> approve+save.
class NewBuildScreen extends StatefulWidget {
  final void Function(
    BuildRecord intentJson,
    NetworkIntent intent,
    String configText,
  )
  onBuilt;
  const NewBuildScreen({super.key, required this.onBuilt});

  @override
  State<NewBuildScreen> createState() => _NewBuildScreenState();
}

class _NewBuildScreenState extends State<NewBuildScreen> {
  final _name = TextEditingController(text: 'office-net');
  final _instr = TextEditingController(
    text: '2 routers 1 switch with OSPF on 192.168.1.0/24',
  );
  String _target = 'gns3';
  bool _busy = false;
  String _log = '';

  /// Plan with the deterministic local parser only: no API key, no quota, no
  /// network.  On by default because that is the path that always works; the
  /// AI planner is a quality upgrade, never a requirement.
  bool _offlineOnly = true;

  /// One-line reason the AI planner was skipped or failed, shown next to the
  /// plan.  Never a stack trace: the plan is still valid and reviewable.
  String _aiNote = '';
  NetworkIntent? _intent;
  String _plannerSource = 'Not planned yet';

  @override
  void initState() {
    super.initState();
    _target = context.read<SettingsService>().defaultTarget;
  }

  @override
  void dispose() {
    _name.dispose();
    _instr.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final mem = context.read<MemoryService>();
    var parsed = NetworkIntent.parseSimple(
      _name.text.trim(),
      CasualEnglish.normalize(_instr.text),
    );
    if (mem.ready) {
      try {
        parsed = PlannerMemoryService.apply(
          parsed,
          rules: (await mem.allRules()).map((r) => r.ruleText).toList(),
          preferences: await mem.allPrefs(),
        );
      } catch (_) {}
    }
    setState(() {
      _intent = parsed;
      _plannerSource = 'Local offline planner';
      _log =
          'Parsed offline intent: ${_intent!.nodes.length} nodes, '
          '${_intent!.links.length} links, routing=${_intent!.routing}';
    });
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _log = 'Working...';
    });
    try {
      final settings = context.read<SettingsService>();
      final mem = context.read<MemoryService>();
      var offlineCandidate = NetworkIntent.parseSimple(
        _name.text.trim(),
        CasualEnglish.normalize(_instr.text),
      );
      // EVOLUTION: a rule or preference the user taught the app (for
      // example "always use OSPF") changes the keyless plan too, so a
      // repeated brief improves instead of repeating the same result.
      if (mem.ready) {
        try {
          offlineCandidate = PlannerMemoryService.apply(
            offlineCandidate,
            rules: (await mem.allRules()).map((r) => r.ruleText).toList(),
            preferences: await mem.allPrefs(),
          );
        } catch (_) {}
      }
      var intent = offlineCandidate;
      var plannerSource = 'Local offline planner';
      var aiNote = '';

      if (!settings.privateMode && !_offlineOnly) {
        final key = await settings.getApiKey();
        if (key != null && key.isNotEmpty) {
          List<String> past = [];
          List<String> attempts = [];
          List<String> rules = [];
          Map<String, String> prefs = {};
          if (mem.ready) {
            final sim = await mem.searchSimilar(_instr.text);
            past = MemoryService.summaries(sim);
            attempts = MemoryService.attemptSummaries(
              await mem.recentAttempts(limit: 10),
            );
            rules = (await mem.allRules()).map((r) => r.ruleText).toList();
            prefs = await mem.allPrefs();
          }
          // CROSS-RUN FAILURE SIGNAL: what real runs kept failing to do, and
          // what Packet Tracer has already proven it cannot do. Both are
          // best-effort reads of the sidecar - a stopped sidecar yields
          // empty lists rather than blocking the plan.
          final svc = AutopilotService();
          final blockers = await svc.blockerLines(project: _name.text.trim());
          final unsupported = await svc.provenUnsupported();
          final ctx = RulePacksService.contextBlock(
            target: _target,
            pastBuildSummaries: past,
            learnedRules: rules,
            preferences: prefs,
            recentAttemptSummaries: attempts,
            knownBlockers: blockers,
            unsupportedCapabilities: unsupported,
          );
          try {
            // PLANNER CACHE: an identical brief (same instruction + target)
            // reuses its last successful plan instead of re-hitting the API.
            final cached = await GeminiService.cachedPlan(
              _instr.text,
              _target,
            );
            if (cached != null) {
              intent = cached;
              plannerSource = 'Gemini plan (cached)';
              aiNote = 'Reused the saved plan for this exact brief.';
            } else {
              intent = await GeminiService().generateIntent(
                apiKey: key,
                model: settings.model,
                instruction: _instr.text,
                contextBlock: ctx,
                target: _target,
                offlineCandidate: offlineCandidate.toPlannerJson(),
              );
              plannerSource = 'Gemini structured planner';
            }
          } catch (e) {
            // Expected whenever the key is unset, out of quota or the model
            // is busy.  The offline plan is already complete, so this is a
            // note, not an error.
            plannerSource = 'Local offline planner (AI unavailable)';
            aiNote =
                'AI planner unavailable (${_briefReason(e)}); '
                'planned offline instead.';
          }
        } else {
          plannerSource = 'Local offline planner (no AI key)';
        }
      } else {
        plannerSource = _offlineOnly
            ? 'Local offline planner (offline mode)'
            : 'Local offline planner (Private Mode)';
      }

      // The local planner has no model to steer, so the cross-run failure
      // signal is surfaced to the user directly instead of being dropped.
      final offlineBlockers = await AutopilotService().blockerLines(
        project: _name.text.trim(),
      );

      intent = intent.copyWith(planningSource: plannerSource);
      _aiNote = aiNote;
      final issues = ValidatorService.validate(intent, target: _target);
      final suggestions = PlannerSuggestionsService.forIntent(
        intent,
        target: _target,
      );
      if (ValidatorService.hasErrors(issues)) {
        setState(() {
          _intent = intent;
          _plannerSource = plannerSource;
          _log =
              'Blocked by validator (planner: $plannerSource):\n${issues.map((e) => '- [${e.severity}] ${e.message}').join('\n')}';
          _busy = false;
        });
        return;
      }

      // Config is always compiled locally from the validated intent. Gemini
      // interprets language; it never writes executable device commands.
      final configText = BuildArtifactService.renderLocal(intent, _target);
      final warnings = issues.where((i) => i.severity == 'warning').length;

      setState(() {
        _intent = intent;
        _plannerSource = plannerSource;
        _busy = false;
        _log =
            'Plan ready. Source: $plannerSource. '
            '${intent.nodes.length} devices, ${intent.links.length} links, '
            '$warnings warning(s). Review the plan before execution.'
            '${suggestions.isEmpty ? '' : '\n\n${PlannerSuggestionsService.summaryLine(intent, target: _target)}'}'
            '${aiNote.isEmpty ? '' : '\n$aiNote'}'
            '${offlineBlockers.isEmpty ? '' : '\n\nKnown blockers from previous runs - expect these to be reported as skipped rather than retried:\n${offlineBlockers.take(6).join('\n')}'}';
      });

      // Persist + learn.  Secrets (AAA key, VPN PSK) go to the OS keychain,
      // and the stored intent is saved WITHOUT them - the keychain is the
      // only place they exist at rest (see SecretVault).
      if (mem.ready) {
        await SecretVault.store(
          intent.projectName,
          SecretVault.extract(intent.toJson()),
        );
        final now = DateTime.now();
        final rec = BuildRecord(
          projectName: intent.projectName,
          instruction: _instr.text,
          intentJson: jsonEncode(intent.toJson(includeSecrets: false)),
          target: _target,
          success: false,
          status: 'planned',
          createdAt: now,
        );
        final id = await mem.logBuild(rec);
        await mem.logAttempt(
          BuildAttempt(
            buildId: id,
            projectName: rec.projectName,
            instruction: rec.instruction,
            intentJson: rec.intentJson,
            target: rec.target,
            status: 'planned',
            evidenceJson: BuildAttempt.evidence({
              'planner': plannerSource,
              'warnings': issues
                  .map((i) => {'severity': i.severity, 'message': i.message})
                  .toList(),
            }),
            createdAt: now,
            updatedAt: now,
          ),
        );
        widget.onBuilt(
          BuildRecord(
            id: id,
            projectName: rec.projectName,
            instruction: rec.instruction,
            intentJson: rec.intentJson,
            target: rec.target,
            success: false,
            status: 'planned',
            createdAt: rec.createdAt,
          ),
          intent,
          configText,
        );
      } else {
        widget.onBuilt(
          BuildRecord(
            projectName: intent.projectName,
            instruction: _instr.text,
            intentJson: jsonEncode(intent.toJson(includeSecrets: false)),
            target: _target,
            status: 'planned',
            success: false,
            createdAt: DateTime.now(),
          ),
          intent,
          configText,
        );
      }
    } catch (e) {
      setState(() {
        _busy = false;
        _log = 'Error: $e';
      });
    }
  }

  /// A short, human reason from a planner exception - never a stack trace.
  String _briefReason(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '').trim();
    final line = text.split('\n').first.trim();
    return line.length <= 120 ? line : '${line.substring(0, 120)}...';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Project name'),
          ),
          const SizedBox(height: 8),
          Card(
            color: AppPalette.accentFill(Theme.of(context).colorScheme),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What will happen',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '1. The AI interprets your request into a visible network plan.\n'
                    '2. The app validates the plan and compiles configs locally.\n'
                    '3. Nothing touches Packet Tracer or GNS3 until you press an execution button.\n'
                    '4. Results, failures, and misclicks are saved as evidence for future learning.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _instr,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Instruction (e.g. 2 routers 1 switch OSPF)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _target,
            items: SettingsService.supportedTargets
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) => setState(() => _target = v ?? 'gns3'),
            decoration: const InputDecoration(labelText: 'Target'),
          ),
          SwitchListTile(
            value: _offlineOnly,
            onChanged: (v) => setState(() => _offlineOnly = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('Plan offline only'),
            subtitle: const Text(
              'Deterministic local planner: no API key, no quota, no network. '
              'Turn off to let Gemini re-interpret the request when a key is set.',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _parse,
                  child: const Text('Preview intent'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _generate,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Review plan + save'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_intent != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Plan source: $_plannerSource'),
                    if (_aiNote.isNotEmpty)
                      Text(
                        _aiNote,
                        style: const TextStyle(color: Colors.orange),
                      ),
                    Text(
                      'Devices: ${_intent!.nodes.map((n) => '${n.name} (${n.type})').join(', ')}',
                    ),
                    Text(
                      'Links: ${_intent!.links.length} | Routing: ${_intent!.routing}',
                    ),
                    if (_intent!.nodes.any((n) => n.services.isNotEmpty))
                      Text(
                        'Server services: ${_intent!.nodes.where((n) => n.services.isNotEmpty).map((n) {
                          final rules = n.serviceRules.keys.toList();
                          final suffix = rules.isEmpty ? 'state only' : 'rules: ${rules.join(', ')}';
                          return '${n.name} (${n.services.join(', ')}; $suffix)';
                        }).join(' · ')}',
                      ),
                    if (_intent!.security.requested)
                      Text(
                        'Security: ${_securitySummary(_intent!.security)} | '
                        'live checks: ${_intent!.security.tests.length}',
                      ),
                    Text(
                      'Planning confidence: ${(_intent!.confidence * 100).round()}%',
                    ),
                    if (_intent!.assumptions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Assumptions:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      for (final a in _intent!.assumptions) Text('• $a'),
                    ],
                    if (PlannerSuggestionsService.forIntent(
                      _intent!,
                      target: _target,
                    ).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Suggested fixes:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      for (final s in PlannerSuggestionsService.forIntent(
                        _intent!,
                        target: _target,
                      ))
                        Text('- $s'),
                    ],
                    if (_intent!.questions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Questions to review:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      for (final q in _intent!.questions) Text('• $q'),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          SelectableText(_log),
        ],
      ),
    );
  }

  String _securitySummary(SecurityIntent s) {
    final controls = <String>[];
    if (s.portSecurity) controls.add('port security');
    if (s.dhcpSnooping) controls.add('DHCP snooping');
    if (s.aaa) controls.add('AAA/Telnet');
    if (s.managerIp != null) controls.add('time-based VTY');
    if (s.extendedAcl) controls.add('branch ACL');
    if (s.ipsecVpn) controls.add('IPSec VPN');
    return controls.isEmpty ? 'none' : controls.join(', ');
  }
}
