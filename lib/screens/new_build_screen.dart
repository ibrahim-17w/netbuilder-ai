import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/build_attempt.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/autopilot_service.dart';
import '../services/build_artifact_service.dart';
import '../services/casual_english.dart';
import '../services/gemini_service.dart';
import '../services/memory_service.dart';
import '../services/planner_memory_service.dart';
import '../services/planner_suggestions_service.dart';
import '../services/rule_packs_service.dart';
import '../services/secret_vault.dart';
import '../services/settings_service.dart';
import '../services/validator_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// The build wizard: **describe** a network, **review** the plan the app made
/// of it, then **build** it.
///
/// The screen this replaces was one long form: fields, a run button, and a
/// wall of text under it. Everything was on screen at once, so nothing was
/// emphasised - and the plan was only visible *after* you had already
/// committed to it. The wizard splits the flow into the three decisions a
/// person actually makes, and shows the live reading of the brief as they
/// type, so a misparsed count is caught while it is still being typed.
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

  /// The compiled config for the reviewed plan, kept so Step 3 can show
  /// exactly what will be pushed before anything is pushed.
  String _configText = '';
  BuildRecord? _draft;

  /// Which step the wizard is on: 0 describe, 1 review, 2 build.
  int _step = 0;

  /// Validation findings for the plan on the table, kept so the review step
  /// can show one banner instead of re-deriving them on every rebuild.
  List<ValidationIssue> _issues = const [];

  /// The live reading of the brief, as the user types. Cheap (the local
  /// parser), debounced, and never authoritative - it is the app showing its
  /// work, not a second plan.
  NetworkIntent? _preview;
  Timer? _previewDebounce;

  /// Examples that fill the brief. Each one exercises a different part of
  /// the planner (quantity words, multi-site, routing, security).
  static const _examples = <(String, String, String)>[
    ('Office LAN', '2 routers, 2 switches and 50 PCs with OSPF', 'ospf'),
    ('Two sites', 'Two sites with a WAN link, 20 PCs each, OSPF', 'wan'),
    (
      'Guest Wi-Fi + AAA',
      '1 router, 2 switches, 20 PCs, a guest Wi-Fi and an AAA server',
      'security',
    ),
    ('Branch with VLANs', 'VLAN 10 and 20 with DHCP, 1 router and 1 switch', 'vlan'),
  ];

  @override
  void initState() {
    super.initState();
    _target = context.read<SettingsService>().defaultTarget;
    _instr.addListener(_onBriefChanged);
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _instr.removeListener(_onBriefChanged);
    _name.dispose();
    _instr.dispose();
    super.dispose();
  }

  /// Re-read the brief after the typing stops. The parse is local and cheap,
  /// but running it on every keystroke would still stutter on a long brief.
  void _onBriefChanged() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final text = _instr.text.trim();
      if (text.isEmpty) {
        setState(() => _preview = null);
        return;
      }
      try {
        final parsed = NetworkIntent.parseSimple(
          _name.text.trim(),
          CasualEnglish.normalize(text),
        );
        if (mounted) setState(() => _preview = parsed);
      } catch (_) {
        // A brief the parser cannot read yet is not an error: it is a brief
        // that is still being typed.
      }
    });
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
          rules: await mem.plannerRuleTexts(),
          preferences: await mem.allPrefs(),
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _intent = parsed;
      _plannerSource = 'Local offline planner';
      _step = 1;
      _issues = ValidatorService.validate(parsed, target: _target);
      _log =
          'Parsed offline intent: ${parsed.nodes.length} nodes, '
          '${parsed.links.length} links, routing=${parsed.routing}';
    });
  }

  /// Plan the brief, validate it, and stop at the review step. The build is
  /// only handed to the workspace when the user has seen the plan.
  Future<void> _generate() async {
    final engine = AutopilotService.of(context);
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
            rules: await mem.plannerRuleTexts(),
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
            rules = await mem.plannerRuleTexts();
            prefs = await mem.allPrefs();
          }
          // CROSS-RUN FAILURE SIGNAL: what real runs kept failing to do, and
          // what Packet Tracer has already proven it cannot do. Both are
          // best-effort reads of the sidecar - a stopped sidecar yields
          // empty lists rather than blocking the plan.
          final blockers = await engine.blockerLines(
            project: _name.text.trim(),
          );
          final unsupported = await engine.provenUnsupported();
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
      final offlineBlockers = await engine.blockerLines(
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
        if (!mounted) return;
        setState(() {
          _intent = intent;
          _issues = issues;
          _plannerSource = plannerSource;
          _step = 1;
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

      if (!mounted) return;
      setState(() {
        _intent = intent;
        _issues = issues;
        _plannerSource = plannerSource;
        _configText = configText;
        _busy = false;
        _step = 1;
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
        if (mounted) {
          setState(() {
            _draft = BuildRecord(
              id: id,
              projectName: rec.projectName,
              instruction: rec.instruction,
              intentJson: rec.intentJson,
              target: rec.target,
              success: false,
              status: 'planned',
              createdAt: rec.createdAt,
            );
          });
        }
      } else if (mounted) {
        setState(() {
          _draft = BuildRecord(
            projectName: intent.projectName,
            instruction: _instr.text,
            intentJson: jsonEncode(intent.toJson(includeSecrets: false)),
            target: _target,
            status: 'planned',
            success: false,
            createdAt: DateTime.now(),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _log = 'Error: $e';
        });
      }
    }
  }

  /// Hand the reviewed plan to the workspace. This is the only path out of
  /// the wizard, so nothing is executed before it is on screen.
  void _openWorkspace() {
    final intent = _intent;
    final draft = _draft;
    if (intent == null || draft == null) return;
    widget.onBuilt(draft, intent, _configText);
  }

  /// A short, human reason from a planner exception - never a stack trace.
  String _briefReason(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '').trim();
    final line = text.split('\n').first.trim();
    return line.length <= 120 ? line : '${line.substring(0, 120)}...';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _wizardHeader(),
        const Divider(height: 1),
        Expanded(
          child: switch (_step) {
            0 => _describeStep(),
            1 => _reviewStep(),
            _ => _buildStep(),
          },
        ),
      ],
    );
  }

  Widget _wizardHeader() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTheme.gutter(context),
        AppTheme.s16,
        AppTheme.gutter(context),
        AppTheme.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSteps(
            current: _step,
            onSelect: (index) => setState(() => _step = index),
            steps: const [
              AppStep('Describe', subtitle: 'Say it in a sentence'),
              AppStep('Review', subtitle: 'Check the plan'),
              AppStep('Build', subtitle: 'Compile and run'),
            ],
          ),
        ],
      ),
    );
  }

  // --- step 1: describe ----------------------------------------------------

  Widget _describeStep() {
    final preview = _preview;
    return AppPage(
      maxWidth: 1080,
      children: [
        AppPageHeader(
          eyebrow: 'Step 1 - Describe',
          title: 'What should I build?',
          description:
              'Describe the lab the way you would say it out loud: how many '
              'routers, switches and PCs, the routing, the addressing, any '
              'servers or security. The app turns it into a validated plan - '
              'and nothing touches a device until you approve it on the last '
              'step.',
        ),
        AppPanel(
          icon: Icons.edit_note_outlined,
          title: 'The brief',
          subtitle: 'One or two sentences is normally enough.',
          children: [
            AppField(
              label: 'Project name',
              help: 'Used for the saved build, the .pkt file and the '
                  'conversation about it.',
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  hintText: 'office-net',
                  prefixIcon: Icon(Icons.folder_outlined, size: 18),
                ),
              ),
            ),
            AppField(
              label: 'Instruction',
              help: 'Quantities, routing (OSPF, static), addressing, VLANs, '
                  'servers and security are all understood offline.',
              child: TextField(
                controller: _instr,
                maxLines: 5,
                minLines: 3,
                decoration: const InputDecoration(
                  hintText:
                      'e.g. 2 routers, 2 switches and 50 PCs with OSPF on '
                      '192.168.10.0/24',
                ),
              ),
            ),
            Text(
              'Examples',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.s8),
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                for (final (title, brief, _) in _examples)
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 14),
                    label: Text(title),
                    tooltip: brief,
                    onPressed: () {
                      setState(() => _instr.text = brief);
                      _onBriefChanged();
                    },
                  ),
              ],
            ),
          ],
        ),
        AppPanel(
          icon: Icons.my_location_outlined,
          title: 'Where it will be built',
          subtitle: 'The target decides what the plan may use.',
          children: [
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                for (final target in SettingsService.supportedTargets)
                  _TargetChip(
                    target: target,
                    selected: _target == target,
                    onTap: () => setState(() => _target = target),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.s10),
            SwitchListTile(
              value: _offlineOnly,
              onChanged: (v) => setState(() => _offlineOnly = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('Plan offline only'),
              subtitle: const Text(
                'Deterministic local planner: no API key, no quota, no '
                'network. Turn off to let Gemini re-interpret the request '
                'when a key is set.',
              ),
            ),
          ],
        ),
        if (preview != null) _UnderstandingPanel(intent: preview),
        if (_aiNote.trim().isNotEmpty && _step == 0)
          AppBanner(
            tone: AppTone.warning,
            title: 'AI planner',
            message: _aiNote,
          ),
        const SizedBox(height: AppTheme.s4),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _generate,
                icon: _busy
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward),
                label: Text(_busy ? 'Planning...' : 'Plan this network'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _parse,
              icon: const Icon(Icons.list_alt_outlined),
              label: const Text('Preview intent'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            ),
          ],
        ),
      ],
    );
  }

  // --- step 2: review ------------------------------------------------------

  Widget _reviewStep() {
    final intent = _intent;
    if (intent == null) {
      return AppEmptyState(
        icon: Icons.rule_folder_outlined,
        title: 'Nothing planned yet',
        body: 'Go back and describe the network first.',
        actions: [
          FilledButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('Back to the brief'),
          ),
        ],
      );
    }
    final errors = _issues.where((i) => i.severity == 'error').toList();
    final warnings = _issues.where((i) => i.severity == 'warning').toList();
    final suggestions = PlannerSuggestionsService.forIntent(
      intent,
      target: _target,
    );
    final blocked = ValidatorService.hasErrors(_issues);
    return AppPage(
      maxWidth: 1080,
      children: [
        AppPageHeader(
          eyebrow: 'Step 2 - Review',
          title: 'Here is what I understood',
          description: 'Check the plan before anything is compiled or built. '
              'Say what to change in the chat and it is replanned - or go '
              'back and edit the brief.',
          actions: [
            OutlinedButton.icon(
              onPressed: () => setState(() => _step = 0),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Edit the brief'),
            ),
          ],
        ),
        AppMetricGrid(
          metrics: [
            AppMetric(
              label: 'Devices',
              value: '${intent.nodes.length}',
              icon: Icons.devices_other_outlined,
              tone: AppTone.accent,
            ),
            AppMetric(
              label: 'Links',
              value: '${intent.links.length}',
              icon: Icons.cable_outlined,
              tone: AppTone.info,
            ),
            AppMetric(
              label: 'Warnings',
              value: '${warnings.length}',
              icon: Icons.warning_amber_rounded,
              tone: warnings.isEmpty ? AppTone.success : AppTone.warning,
            ),
            AppMetric(
              label: 'Confidence',
              value: '${(intent.confidence * 100).round()}%',
              icon: Icons.insights_outlined,
              tone: AppTone.accent,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s14),
        AppBanner(
          tone: blocked ? AppTone.danger : AppTone.success,
          title: blocked ? 'The validator blocks this plan' : 'Validator: clean',
          message: blocked
              ? errors.map((e) => e.message).join('\n')
              : 'Nothing blocking. ${warnings.length} warning(s) worth a '
                    'look before you build.',
        ),
        AppPanel(
          icon: Icons.account_tree_outlined,
          title: 'Plan',
          subtitle: 'Planner: $_plannerSource',
          actions: [
            AppTag(
              label: intent.routing.isEmpty ? 'no routing' : intent.routing,
              tone: AppTone.accent,
            ),
            AppTag(label: _target, tone: AppTone.neutral),
          ],
          children: [
            _devicesList(intent),
            if (intent.addressing.isNotEmpty) ...[
              const AppDivider(label: 'Addressing'),
              for (final a in intent.addressing.take(12))
                AppKeyValue(
                  label: a.node,
                  value: '${a.iface}  ${a.ipCidr}',
                  mono: true,
                ),
              if (intent.addressing.length > 12)
                Text(
                  '+ ${intent.addressing.length - 12} more',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
            if (intent.vlans.isNotEmpty) ...[
              const AppDivider(label: 'VLANs'),
              Wrap(
                spacing: AppTheme.s6,
                runSpacing: AppTheme.s6,
                children: [
                  for (final vlan in intent.vlans)
                    AppTag(label: 'VLAN $vlan', tone: AppTone.info, mono: true),
                ],
              ),
            ],
            if (intent.links.isNotEmpty) ...[
              const AppDivider(label: 'Links'),
              for (final link in intent.links.take(10))
                AppKeyValue(
                  label: link.a,
                  value: '${link.aIf}  <->  ${link.b} ${link.bIf}',
                  mono: true,
                ),
              if (intent.links.length > 10)
                Text(
                  '+ ${intent.links.length - 10} more link(s)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
        if (intent.assumptions.isNotEmpty)
          AppPanel(
            icon: Icons.help_outline,
            title: 'Assumptions I made',
            subtitle: 'Correct any of these in the chat.',
            children: [
              for (final a in intent.assumptions)
                _Bullet(text: a),
            ],
          ),
        if (suggestions.isNotEmpty)
          AppPanel(
            icon: Icons.tips_and_updates_outlined,
            title: 'What you may want to fix',
            filled: true,
            tone: AppTone.warning,
            children: [
              for (final s in suggestions) _Bullet(text: s),
            ],
          ),
        if (intent.questions.isNotEmpty)
          AppPanel(
            icon: Icons.live_help_outlined,
            title: 'Open questions',
            children: [
              for (final q in intent.questions) _Bullet(text: q),
            ],
          ),
        if (intent.nodes.any((n) => n.services.isNotEmpty))
          AppPanel(
            icon: Icons.dns_outlined,
            title: 'Server services',
            children: [
              for (final n in intent.nodes.where(
                (n) => n.services.isNotEmpty,
              ))
                AppKeyValue(
                  label: n.name,
                  value: n.services.join(', '),
                ),
            ],
          ),
        if (intent.security.requested)
          AppPanel(
            icon: Icons.shield_outlined,
            title: 'Security',
            children: [
              AppKeyValue(
                label: 'Controls',
                value: _securitySummary(intent.security),
              ),
              AppKeyValue(
                label: 'Live checks',
                value: '${intent.security.tests.length}',
              ),
            ],
          ),
        const SizedBox(height: AppTheme.s8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: blocked ? null : () => setState(() => _step = 2),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Continue to build'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            OutlinedButton(
              onPressed: _busy ? null : _generate,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
              child: const Text('Replan'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _devicesList(NetworkIntent intent) {
    return Wrap(
      spacing: AppTheme.s6,
      runSpacing: AppTheme.s6,
      children: [
        for (final node in intent.nodes.take(24))
          AppTag(
            label: node.model == null || node.model!.isEmpty
                ? '${node.name} (${node.type})'
                : '${node.name} (${node.model})',
            tone: _deviceTone(node.type),
            icon: _deviceIcon(node.type),
          ),
        if (intent.nodes.length > 24)
          AppTag(
            label: '+${intent.nodes.length - 24} more',
            tone: AppTone.neutral,
          ),
      ],
    );
  }

  static AppTone _deviceTone(String type) {
    final t = type.toLowerCase();
    if (t.contains('router')) return AppTone.accent;
    if (t.contains('switch')) return AppTone.info;
    if (t.contains('server')) return AppTone.success;
    if (t.contains('pc') || t.contains('host')) return AppTone.neutral;
    if (t.contains('firewall') || t.contains('asa')) return AppTone.danger;
    return AppTone.neutral;
  }

  static IconData _deviceIcon(String type) {
    final t = type.toLowerCase();
    if (t.contains('router')) return Icons.router_outlined;
    if (t.contains('switch')) return Icons.hub_outlined;
    if (t.contains('server')) return Icons.dns_outlined;
    if (t.contains('firewall') || t.contains('asa')) {
      return Icons.shield_outlined;
    }
    if (t.contains('access') || t.contains('ap')) return Icons.wifi;
    return Icons.desktop_windows_outlined;
  }

  // --- step 3: build -------------------------------------------------------

  Widget _buildStep() {
    final intent = _intent;
    if (intent == null || _draft == null) {
      return AppEmptyState(
        icon: Icons.play_circle_outline,
        title: 'No plan is ready to build',
        body: 'Describe a network and review the plan first.',
        actions: [
          FilledButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('Start over'),
          ),
        ],
      );
    }
    return AppPage(
      maxWidth: 1080,
      children: [
        AppPageHeader(
          eyebrow: 'Step 3 - Build',
          title: 'Ready to build ${_draft!.projectName}',
          description:
              'The config below was compiled locally from the reviewed plan. '
              'Opening the workspace runs the plan against $_target and '
              'proves each step - nothing is typed into a device until you '
              'approve it there.',
          actions: [
            OutlinedButton.icon(
              onPressed: () => setState(() => _step = 1),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to the plan'),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.rocket_launch_outlined,
          title: 'Compiled config',
          subtitle: '${_configText.split('\n').length} lines for $_target',
          trailing: AppTag(
            label: _draft!.status,
            tone: AppTone.info,
          ),
        ),
        AppCodeBlock(
          text: _configText,
          title: '${_draft!.projectName}.cfg',
          maxHeight: 420,
          emptyText: 'The plan compiles no config for this target.',
        ),
        const SizedBox(height: AppTheme.s12),
        AppPanel(
          icon: Icons.notes_outlined,
          title: 'Planning log',
          subtitle: 'What the planner did, in order.',
        ),
        AppCodeBlock(
          text: _log,
          title: 'planner',
          maxHeight: 200,
          copyable: false,
        ),
        const SizedBox(height: AppTheme.s16),
        AppBanner(
          tone: AppTone.info,
          title: 'Nothing has been built yet',
          message: 'The workspace shows the same plan and proves every step '
              'on screen. You can stop a run at any point.',
        ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _openWorkspace,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Open the build workspace'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                ),
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            IconButton(
              tooltip: 'Copy the plan JSON',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent(
                      '  ',
                    ).convert(intent.toJson(includeSecrets: false)),
                  ),
                );
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Plan JSON copied')),
                );
              },
              icon: const Icon(Icons.data_object),
            ),
            IconButton(
              tooltip: 'Start over',
              onPressed: () => setState(() {
                _step = 0;
                _intent = null;
                _draft = null;
                _configText = '';
                _log = '';
              }),
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
      ],
    );
  }

  // --- shared --------------------------------------------------------------

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

/// The live reading of the brief: what the local parser sees *right now*.
/// It is the app showing its work while the sentence is still being written.
class _UnderstandingPanel extends StatelessWidget {
  final NetworkIntent intent;

  const _UnderstandingPanel({required this.intent});

  @override
  Widget build(BuildContext context) {
    final routers = intent.nodes
        .where((n) => n.type.toLowerCase().contains('router'))
        .length;
    final switches = intent.nodes
        .where((n) => n.type.toLowerCase().contains('switch'))
        .length;
    final pcs = intent.nodes.length - routers - switches;
    return AppPanel(
      icon: Icons.hearing_outlined,
      title: 'What I am reading so far',
      subtitle: 'Live, offline, and updated as you type.',
      children: [
        Wrap(
          spacing: AppTheme.s6,
          runSpacing: AppTheme.s6,
          children: [
            AppTag(
              label: '${intent.nodes.length} device(s)',
              tone: AppTone.accent,
              icon: Icons.devices_other_outlined,
            ),
            if (routers > 0)
              AppTag(
                label: '$routers router(s)',
                tone: AppTone.accent,
                icon: Icons.router_outlined,
              ),
            if (switches > 0)
              AppTag(
                label: '$switches switch(es)',
                tone: AppTone.info,
                icon: Icons.hub_outlined,
              ),
            if (pcs > 0)
              AppTag(
                label: '$pcs host(s)',
                tone: AppTone.neutral,
                icon: Icons.desktop_windows_outlined,
              ),
            if (intent.links.isNotEmpty)
              AppTag(
                label: '${intent.links.length} link(s)',
                tone: AppTone.info,
                icon: Icons.cable_outlined,
              ),
            if (intent.routing.trim().isNotEmpty)
              AppTag(
                label: intent.routing,
                tone: AppTone.success,
                icon: Icons.alt_route_outlined,
              ),
            for (final vlan in intent.vlans.take(4))
              AppTag(label: 'VLAN $vlan', tone: AppTone.info, mono: true),
            if (intent.security.requested)
              AppTag(
                label: 'security',
                tone: AppTone.warning,
                icon: Icons.shield_outlined,
              ),
          ],
        ),
      ],
    );
  }
}

/// One target, as a card-like chip: the name plus what it is for.
class _TargetChip extends StatelessWidget {
  final String target;
  final bool selected;
  final VoidCallback onTap;

  const _TargetChip({
    required this.target,
    required this.selected,
    required this.onTap,
  });

  static const _blurb = <String, (IconData, String)>{
    'gns3': (Icons.hub_outlined, 'Real IOS images, live lab'),
    'packet-tracer': (Icons.wifi_tethering, 'Offline .pkt files and autopilot'),
    'cisco': (Icons.terminal_outlined, 'A real device over SSH'),
    'aws': (Icons.cloud_outlined, 'Terraform for a VPC'),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, blurb) = _blurb[target] ?? (Icons.device_hub, 'Build target');
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : theme.brightness == Brightness.dark
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.3)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: onTap,
        child: Container(
          width: 210,
          padding: const EdgeInsets.all(AppTheme.s10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.5)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppTheme.s10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    Text(
                      blurb,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, size: 16, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;

  const _Bullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.s10),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
