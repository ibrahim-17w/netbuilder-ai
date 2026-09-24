import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/destinations.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../screens/engine_screen.dart';
import '../screens/network_toolkit_screen.dart';
import '../screens/topology_preview_screen.dart';
import '../widgets/app_dialogs.dart';
import 'adapters/cisco_adapter.dart';
import 'adapters/gns3_adapter.dart';
import 'adapters/packet_tracer_adapter.dart';
import 'adapters/terraform_adapter.dart';
import 'autopilot_service.dart';
import 'engine_status.dart';
import 'memory_service.dart';
import 'network_math.dart';
import 'network_tools.dart';
import 'planner_suggestions_service.dart';
import 'privacy_search_service.dart';
import 'settings_service.dart';
import 'validator_service.dart';

/// What an action is allowed to do: navigate the shell, open a screen, ask
/// the chat a question, and read the plan that is currently open.
///
/// The registry passes this in rather than letting an action reach for a
/// global, so an action is a plain function of what the user has open, and
/// the hub that calls it can be used from a test with a fake host.
class ActionContext {
  final BuildContext context;
  final AppDestination current;

  /// The plan currently open, if any. Actions that need one declare it with
  /// [AppAction.needsPlan] and the hub keeps them disabled instead of letting
  /// them fail.
  final NetworkIntent? intent;
  final BuildRecord? record;

  /// The project/chat name the app is on.
  final String project;

  final void Function(AppDestination destination) go;
  final void Function(Widget screen) push;
  final void Function({required String project, String prefill}) openChat;
  final VoidCallback openDrawer;

  const ActionContext({
    required this.context,
    required this.current,
    required this.go,
    required this.push,
    required this.openChat,
    required this.openDrawer,
    this.intent,
    this.record,
    this.project = 'default',
  });

  bool get hasPlan => intent != null;

  MemoryService? get memory {
    try {
      return context.read<MemoryService>();
    } catch (_) {
      return null;
    }
  }

  SettingsService? get settings {
    try {
      return context.read<SettingsService>();
    } catch (_) {
      return null;
    }
  }

  void toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

/// One capability, as a button.
class AppAction {
  final String id;
  final String label;
  final String description;
  final IconData icon;
  final String group;

  /// Extra words a search should match, beyond the label and description.
  final List<String> keywords;

  /// Disabled (with a reason) until a plan is open.
  final bool needsPlan;

  /// Changes something outside the app - typed into Packet Tracer, run on
  /// real devices, saved to disk. Marked in the UI, never run silently.
  final bool touchesDevices;

  final Future<void> Function(ActionContext context) run;

  const AppAction({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    required this.group,
    required this.run,
    this.keywords = const [],
    this.needsPlan = false,
    this.touchesDevices = false,
  });

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = '$label $description ${keywords.join(' ')} $group'
        .toLowerCase();
    // Every word in the query has to appear somewhere, so "pkt fix" doesn't
    // match something that only says "fix".
    return q.split(RegExp(r'\s+')).every(haystack.contains);
  }
}

/// Every feature in the app, declared once, with the button that reaches it.
///
/// This exists because the app had features with no way in: the memory
/// screen, the .pkt file screen, the saved-network history, the Terraform
/// adapter and the whole subnet/gateway library were implemented, tested and
/// then never shown to anyone. A feature without a button is not a feature.
///
/// Keeping the list declarative also means it can be *checked*: a test walks
/// every entry and asserts it has a unique id, a group and a runner, and the
/// hub renders all of them as buttons. Adding a capability to the app is now
/// one entry here plus the code behind it, and forgetting the entry is a test
/// failure instead of a silent dead end.
class CapabilityRegistry {
  const CapabilityRegistry._();

  static const String planGroup = 'Plan a network';
  static const String toolsGroup = 'Network tools';
  static const String analyzeGroup = 'Analyze and repair';
  static const String pktGroup = 'Packet Tracer';
  static const String exportGroup = 'Exports';
  static const String chatGroup = 'Chat';
  static const String memoryGroup = 'Memory and learning';
  static const String systemGroup = 'Settings and system';

  static const List<String> groupOrder = [
    planGroup,
    toolsGroup,
    analyzeGroup,
    pktGroup,
    exportGroup,
    chatGroup,
    memoryGroup,
    systemGroup,
  ];

  static List<AppAction> get all => _all;

  static List<AppAction> inGroup(String group) =>
      [for (final action in _all) if (action.group == group) action];

  static List<AppAction> search(String query) =>
      [for (final action in _all) if (action.matches(query)) action];

  /// True when [destination] has at least one button that reaches it. The
  /// shell asserts this while it builds the hub, which is how "every screen
  /// is reachable" stops being a promise and becomes a property.
  static bool reaches(AppDestination destination) => _all.any(
    (action) => action.keywords.contains('destination:${destination.name}'),
  );

  // --- helpers the entries share ------------------------------------------

  static String _pretty(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  /// A read-only call to the sidecar (or a local service) rendered as a
  /// result dialog. The failure text is shown verbatim.
  static AppAction _probe({
    required String id,
    required String label,
    required String description,
    required IconData icon,
    required String group,
    required Future<({String title, String text})> Function() probe,
    List<String> keywords = const [],
    bool needsPlan = false,
    bool touchesDevices = false,
  }) => AppAction(
    id: id,
    label: label,
    description: description,
    icon: icon,
    group: group,
    keywords: keywords,
    needsPlan: needsPlan,
    touchesDevices: touchesDevices,
    run: (context) async {
      final result = await runWithFeedback<({String title, String text})>(
        context.context,
        busyLabel: '$label...',
        action: probe,
      );
      if (result == null || !context.context.mounted) return;
      await showArtifactDialog(
        context.context,
        title: result.title,
        subtitle: description,
        text: result.text,
      );
    },
  );

  /// Open the toolkit on a named section.
  static AppAction _toolkitSection({
    required String id,
    required String label,
    required ToolkitSection section,
    List<String> keywords = const [],
  }) => AppAction(
    id: id,
    label: label,
    description: section.blurb,
    icon: section.icon,
    group: toolsGroup,
    keywords: keywords,
    run: (context) => Future.sync(
      () => context.push(
        NetworkToolkitScreen(initialSection: section, intent: context.intent),
      ),
    ),
  );

  static List<String> _destinations(AppDestination destination) => [
    'destination:${destination.name}',
  ];

  static AppAction _go({
    required String id,
    required String label,
    required AppDestination destination,
    IconData? icon,
    String description = '',
    bool needsPlan = false,
    List<String> keywords = const [],
  }) => AppAction(
    id: id,
    label: label,
    description: description.isEmpty ? destination.description : description,
    icon: icon ?? destination.icon,
    group: planGroup,
    needsPlan: needsPlan,
    keywords: [..._destinations(destination), ...keywords],
    run: (context) => Future.sync(() => context.go(destination)),
  );

  /// Pick one file, remembering the last folder the user was in.
  static Future<String?> _pickPkt() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a .pkt file',
      type: FileType.any,
    );
    final path = picked?.files.single.path;
    return path == null || path.trim().isEmpty ? null : path;
  }

  static String _filesLocked(NetworkIntent? intent) =>
      intent == null
      ? 'no plan is open'
      : '${intent.nodes.length} devices, ${intent.links.length} links';

  // --- the capabilities ---------------------------------------------------

  static final List<AppAction> _all = [
    // ---- Plan a network ----
    _go(
      id: 'plan.new',
      label: 'Plan a network from a sentence',
      destination: AppDestination.newBuild,
      description:
          'Describe it in plain words ("3 routers, 2 switches, OSPF on '
          '10.0.0.0/24") and the planner builds the full design.',
      keywords: ['create', 'design', 'build', 'start', 'wizard'],
    ),
    _go(
      id: 'plan.review',
      label: 'Review the current plan',
      destination: AppDestination.analyze,
      description:
          'What was understood, what was assumed, what the checks say, and '
          'what is worth fixing before anything is touched.',
      keywords: ['audit', 'review', 'inspect', 'live'],
    ),
    _go(
      id: 'plan.execute',
      label: 'Open the build workspace',
      destination: AppDestination.execution,
      needsPlan: true,
      description:
          'Run the plan, approve each typed command, and prove the result on '
          'screen.',
      keywords: ['run', 'execute', 'autopilot', 'workspace'],
    ),
    AppAction(
      id: 'plan.topology',
      label: 'Preview the topology',
      description:
          'See the plan as a diagram before building it: layered devices, '
          'VLAN colors, drag to rearrange - the arrangement is saved with '
          'the plan.',
      icon: Icons.hub_outlined,
      group: planGroup,
      needsPlan: true,
      keywords: ['topology', 'diagram', 'preview', 'map', 'graph', 'draw'],
      run: (context) => Future.sync(() => context.push(
            TopologyPreviewScreen(intent: context.intent!),
          )),
    ),
    _go(
      id: 'plan.history',
      label: 'Saved networks',
      destination: AppDestination.history,
      description: 'Every network this app has built, with its outcome.',
      keywords: ['history', 'projects', 'recent', 'open'],
    ),
    _go(
      id: 'plan.files',
      label: 'Packet Tracer files',
      destination: AppDestination.files,
      description: 'Open, verify, back up and report on .pkt saves.',
      keywords: ['pkt', 'save', 'open', 'backup', 'file'],
    ),
    AppAction(
      id: 'plan.validate',
      label: 'Check the plan for errors',
      description:
          'Runs the same validator a build runs: addressing, sizes, cabling '
          'and target limits.',
      icon: Icons.fact_check_outlined,
      group: planGroup,
      needsPlan: true,
      keywords: ['validate', 'check', 'errors', 'lint'],
      run: (context) async {
        final intent = context.intent!;
        final issues = ValidatorService.validate(
          intent,
          target: context.settings?.defaultTarget ?? 'packet-tracer',
        );
        if (!context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: issues.isEmpty
              ? 'The plan is clean'
              : '${issues.length} finding(s)',
          subtitle:
              '${intent.projectName} - ${_filesLocked(intent)}',
          icon: Icons.fact_check_outlined,
          warn: issues.any((i) => i.severity == 'error'),
          lines: [
            for (final issue in issues) '[${issue.severity}] ${issue.message}',
          ],
        );
      },
    ),
    AppAction(
      id: 'plan.suggestions',
      label: 'What to improve in the plan',
      description:
          'The planner\'s own advice: redundancy, naming, services that are '
          'missing for what was asked.',
      icon: Icons.tips_and_updates_outlined,
      group: planGroup,
      needsPlan: true,
      keywords: ['suggestions', 'improve', 'advice', 'best practice'],
      run: (context) async {
        final intent = context.intent!;
        final suggestions = PlannerSuggestionsService.forIntent(
          intent,
          target: context.settings?.defaultTarget ?? 'packet-tracer',
        );
        if (!context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: suggestions.isEmpty
              ? 'Nothing to add'
              : '${suggestions.length} suggestion(s)',
          subtitle: intent.projectName,
          icon: Icons.tips_and_updates_outlined,
          lines: suggestions,
        );
      },
    ),

    // ---- Network tools ----
    AppAction(
      id: 'tools.open',
      label: 'Open the network toolkit',
      description:
          'The engineering console: subnet maths, VLSM, summarization, ACL '
          'masks, diagnostics, exports.',
      icon: Icons.calculate_outlined,
      group: toolsGroup,
      keywords: ['toolkit', 'console', 'tools'],
      run: (context) => Future.sync(
        () => context.push(NetworkToolkitScreen(intent: context.intent)),
      ),
    ),
    _toolkitSection(
      id: 'tools.subnet',
      label: 'Subnet calculator',
      section: ToolkitSection.subnet,
      keywords: ['subnet', 'mask', 'broadcast', 'wildcard', 'cidr', 'hosts'],
    ),
    _toolkitSection(
      id: 'tools.vlsm',
      label: 'VLSM and subnet splitting',
      section: ToolkitSection.vlsm,
      keywords: ['vlsm', 'allocate', 'split', 'subnets', 'sizing'],
    ),
    _toolkitSection(
      id: 'tools.summarize',
      label: 'Summarization and ranges',
      section: ToolkitSection.summarize,
      keywords: ['summarize', 'aggregate', 'supernet', 'summary route', 'range'],
    ),
    _toolkitSection(
      id: 'tools.addressing',
      label: 'Address plan checks',
      section: ToolkitSection.addressing,
      keywords: ['duplicate', 'overlap', 'addressing', 'ip conflict'],
    ),
    _toolkitSection(
      id: 'tools.acl',
      label: 'ACL and mask helper',
      section: ToolkitSection.acl,
      keywords: ['acl', 'wildcard', 'inverse mask', 'access list', 'reverse dns'],
    ),
    _toolkitSection(
      id: 'tools.diagnostics',
      label: 'Live diagnostics: DNS, ports, HTTP, ping',
      section: ToolkitSection.diagnostics,
      keywords: ['ping', 'dns', 'port', 'scan', 'http', 'traceroute', 'probe'],
    ),
    _toolkitSection(
      id: 'tools.local',
      label: 'This machine: interfaces, ARP, routes',
      section: ToolkitSection.local,
      keywords: ['interfaces', 'arp', 'route table', 'netstat', 'mac'],
    ),
    AppAction(
      id: 'tools.duplicates',
      label: 'Find duplicate addresses in the plan',
      description:
          'Any address used twice on the same segment is a real fault, and '
          'this names both devices that claim it.',
      icon: Icons.rule_folder_outlined,
      group: toolsGroup,
      needsPlan: true,
      keywords: ['duplicate', 'conflict', 'clone', 'same ip'],
      run: (context) async {
        final intent = context.intent!;
        final duplicates = NetworkTools.duplicateAddresses([
          for (final a in intent.addressing)
            {'node': a.node, 'iface': a.iface, 'ipCidr': a.ipCidr},
        ]);
        if (!context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: duplicates.isEmpty
              ? 'No duplicate addresses'
              : '${duplicates.length} duplicate address(es)',
          subtitle: intent.projectName,
          icon: Icons.rule_folder_outlined,
          warn: duplicates.isNotEmpty,
          lines: [
            for (final d in duplicates)
              '${d['address']} is claimed by ${(d['usedBy'] as List).join(' and ')}',
          ],
        );
      },
    ),
    AppAction(
      id: 'tools.overlaps',
      label: 'Check the subnets for overlaps',
      description:
          'Overlapping subnets on different links are a routing fault waiting '
          'to happen.',
      icon: Icons.layers_outlined,
      group: toolsGroup,
      needsPlan: true,
      keywords: ['overlap', 'conflict', 'subnet', 'collision'],
      run: (context) async {
        final intent = context.intent!;
        // A set literal, so two interfaces in the same subnet are compared
        // against each other only once.
        final cidrs = <String>{
          for (final a in intent.addressing)
            if (a.ipCidr.contains('/')) a.ipCidr,
        }.toList();
        final pairs = NetworkMath.overlappingPairs(cidrs);
        if (!context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: pairs.isEmpty
              ? 'No overlapping subnets'
              : '${pairs.length} overlapping pair(s)',
          subtitle: 'Checked ${cidrs.length} distinct subnets in '
              '${intent.projectName}',
          icon: Icons.layers_outlined,
          warn: pairs.isNotEmpty,
          lines: [
            for (final pair in pairs)
              '${pair.$1} and ${pair.$2} share addresses '
                  '(${NetworkMath.coveringPrefix(pair.$1, pair.$2) ?? '?'})',
          ],
        );
      },
    ),

    // ---- Analyze and repair ----
    _go(
      id: 'analyze.live',
      label: 'Audit a live lab',
      destination: AppDestination.analyze,
      description:
          'Read the devices that are on the screen now, list the faults and '
          'apply the fixes you approve.',
      keywords: ['audit', 'scan', 'fault', 'repair', 'diagnose'],
    ),
    AppAction(
      id: 'analyze.pkt',
      label: 'Audit a saved .pkt offline',
      description:
          'The sidecar reads the file directly - no Packet Tracer, no window, '
          'no clicks - and reports what is wrong inside it.',
      icon: Icons.plagiarism_outlined,
      group: analyzeGroup,
      keywords: ['audit', 'pkt', 'offline', 'fault', 'check file'],
      run: (context) async {
        final path = await _pickPkt();
        if (path == null || !context.context.mounted) return;
        final report = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Auditing $path...',
          action: () => AutopilotService().pktAudit(
            path,
            project: context.project,
          ),
        );
        if (report == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Offline audit',
          subtitle: path,
          text: _pretty(report),
        );
      },
    ),
    AppAction(
      id: 'analyze.verify',
      label: 'Verify a build (ping tests)',
      description:
          'Runs the plan test list against the live Packet Tracer window: '
          'every PC pings its gateway and each service server, with '
          'pass/fail evidence per test.',
      icon: Icons.fact_check_outlined,
      group: analyzeGroup,
      needsPlan: true,
      keywords: [
        'verify',
        'test',
        'ping',
        'evidence',
        'proof',
        'works',
      ],
      run: (context) async {
        final intent = context.intent;
        final baseCtx = context.context;
        if (intent == null || !baseCtx.mounted) return;
        final svc = AutopilotService();
        if (!await svc.healthy) {
          if (!baseCtx.mounted) return;
          await showArtifactDialog(
            baseCtx,
            title: 'Sidecar not running',
            text: AutopilotService.startHint,
          );
          return;
        }
        if (!baseCtx.mounted) return;
        final plan = PacketTracerAdapter.autopilotPlan(intent);
        final report =
            // ignore: use_build_context_synchronously - baseCtx is captured
            // before the await and re-checked with .mounted after it.
            await runWithFeedback<Map<String, dynamic>?>(
          baseCtx,
          busyLabel: 'Pinging every endpoint in Packet Tracer...',
          action: () async {
            await svc.verifyRun(plan);
            Map<String, dynamic>? rep;
            for (var i = 0; i < 150; i++) {
              await Future<void>.delayed(const Duration(seconds: 4));
              rep = await svc.verifyReport();
              if (rep != null &&
                  ((rep['total'] ?? 0) > 0 || rep['error'] != null)) {
                break;
              }
            }
            return rep;
          },
        );
        if (report == null || !baseCtx.mounted) return;
        await showArtifactDialog(
          baseCtx,
          title: 'Verification',
          subtitle: report['summary']?.toString() ?? '',
          text: (report['tests'] as List? ?? const [])
              .whereType<Map>()
              .map((t) =>
                  '${(t['status'] ?? '').toString().toUpperCase()}'
                  '  ${t['src']} -> ${t['dst']}'
                  '  ${t['detail'] ?? ''}')
              .join('\n'),
        );
      },
    ),
    AppAction(
      id: 'analyze.dryrun',
      label: 'Dry-run the plan (no PT)',
      description:
          'Walks the current plan against Packet Tracer constraints offline: '
          'what gets placed, cabled, typed and IP-configured, plus warnings '
          'for dead transits and incomplete configs - before anything runs.',
      icon: Icons.slow_motion_video_outlined,
      group: analyzeGroup,
      needsPlan: true,
      keywords: [
        'dry run',
        'dry-run',
        'preview',
        'simulate',
        'rehearse',
        'what if',
      ],
      run: (context) async {
        final intent = context.intent;
        final baseCtx = context.context;
        if (intent == null || !baseCtx.mounted) return;
        final svc = AutopilotService();
        if (!await svc.healthy) {
          if (!baseCtx.mounted) return;
          await showArtifactDialog(
            baseCtx,
            title: 'Sidecar not running',
            text: AutopilotService.startHint,
          );
          return;
        }
        if (!baseCtx.mounted) return;
        final plan = PacketTracerAdapter.autopilotPlan(intent);
        final report = await runWithFeedback<Map<String, dynamic>?>(
          baseCtx,
          busyLabel: 'Walking the plan...',
          action: () => svc.dryRun(plan),
        );
        if (report == null || !baseCtx.mounted) return;
        final summary = report['summary'] as Map? ?? const {};
        final warnings = (report['warnings'] as List? ?? const [])
            .whereType<String>()
            .toList();
        await showArtifactDialog(
          baseCtx,
          title: 'Dry run',
          subtitle:
              '${summary['devices'] ?? 0} devices, '
              '${summary['links'] ?? 0} links, '
              '${summary['cliDevices'] ?? 0} CLI, '
              '${summary['ipConfigured'] ?? 0} IP-configured, '
              '${warnings.length} warning(s)',
          text: [
            if (warnings.isNotEmpty) ...[
              'WARNINGS:',
              ...warnings.map((w) => ' ! $w'),
              '',
            ],
            'ACTIONS:',
            ...(report['actions'] as List? ?? const [])
                .whereType<Map>()
                .map((a) =>
                    ' ${(a['device'] ?? '')}: ${(a['action'] ?? '')}'
                    '${a['detail'] != null ? ' - ${a['detail']}' : ''}'),
          ].join('\n'),
        );
      },
    ),
    AppAction(
      id: 'analyze.blockers',
      label: 'What is blocking builds',
      description:
          'Failures the engine has seen often enough to treat as known '
          'blockers for this project.',
      icon: Icons.block_outlined,
      group: analyzeGroup,
      keywords: ['blocker', 'stuck', 'failure', 'known issue'],
      run: (context) async {
        final lines = await runWithFeedback<List<String>>(
          context.context,
          busyLabel: 'Reading the failure journal...',
          action: () =>
              AutopilotService().blockerLines(project: context.project),
        );
        if (lines == null || !context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: lines.isEmpty
              ? 'Nothing is blocking this project'
              : '${lines.length} known blocker(s)',
          subtitle: 'Project ${context.project}',
          icon: Icons.block_outlined,
          warn: lines.isNotEmpty,
          lines: lines,
        );
      },
    ),
    AppAction(
      id: 'analyze.unsupported',
      label: 'What the engine cannot do',
      description:
          'Operations the engine has proven unsupported, so the planner stops '
          'promising them.',
      icon: Icons.not_interested,
      group: analyzeGroup,
      keywords: ['unsupported', 'limits', 'cannot', 'capability'],
      run: (context) async {
        final lines = await runWithFeedback<List<String>>(
          context.context,
          busyLabel: 'Reading proven limits...',
          action: () => AutopilotService().provenUnsupported(),
        );
        if (lines == null || !context.context.mounted) return;
        await showLinesDialog(
          context.context,
          title: lines.isEmpty
              ? 'No proven limits recorded'
              : '${lines.length} proven limitation(s)',
          icon: Icons.not_interested,
          lines: lines,
        );
      },
    ),
    _go(
      id: 'analyze.corrections',
      label: 'Corrections and learned rules',
      destination: AppDestination.memory,
      description:
          'Every correction the app has been taught, the rules it distilled, '
          'and the failure journal behind them.',
      keywords: ['corrections', 'rules', 'teach', 'revert', 'learn'],
    ),
    _go(
      id: 'import.inspect',
      label: 'Open & inspect .pkt files',
      destination: AppDestination.importPkts,
      description:
          'Audit any saved .pkt for faults, diff two saves to see what '
          'changed, or grade one against the open plan.',
      keywords: [
        'import',
        'audit',
        'diff',
        'grade',
        'inspect',
        'open',
        'reverse',
      ],
    ),

    // ---- Packet Tracer ----
    AppAction(
      id: 'pt.generate',
      label: 'Build a .pkt from the plan',
      description:
          'Compiles the open plan into a Packet Tracer save file with no '
          'Packet Tracer and no GUI run.',
      icon: Icons.build_circle_outlined,
      group: pktGroup,
      needsPlan: true,
      touchesDevices: true,
      keywords: ['pkt', 'generate', 'build file', 'offline', 'create save'],
      run: (context) async {
        final intent = context.intent!;
        final plan = PacketTracerAdapter.autopilotPlan(intent);
        final report = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Compiling ${intent.projectName}.pkt...',
          action: () => AutopilotService().pktGenerate(
            plan,
            project: intent.projectName,
            replace: true,
          ),
        );
        if (report == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Generated .pkt',
          subtitle: 'Project ${intent.projectName}',
          text: _pretty(report),
        );
      },
    ),
    AppAction(
      id: 'pt.saveVerified',
      label: 'Save the live topology as a verified .pkt',
      description:
          'Saves what is on the Packet Tracer screen now, with a companion '
          'manifest and a reopened proof that it loads.',
      icon: Icons.save_outlined,
      group: pktGroup,
      touchesDevices: true,
      keywords: ['save', 'pkt', 'verified', 'manifest', 'backup'],
      run: (context) async {
        final confirmed = await confirmAction(
          context.context,
          title: 'Save the live topology?',
          body: 'The engine will save the topology Packet Tracer is showing '
              'into a .pkt in your output folder, alongside a companion '
              'manifest, and reopen it to prove it loads.',
          icon: Icons.save_outlined,
          confirmLabel: 'Save it',
        );
        if (!confirmed || !context.context.mounted) return;
        final result = await runWithFeedback<String>(
          context.context,
          busyLabel: 'Saving the live topology...',
          action: () => AutopilotService().pktSaveVerified(
            project: context.project,
            outDir: context.settings?.outputDir ?? '',
            force: true,
            reopen: true,
          ),
        );
        if (result == null || !context.context.mounted) return;
        context.toast(result);
      },
    ),
    AppAction(
      id: 'pt.open',
      label: 'Open a .pkt (with a backup first)',
      description:
          'The engine copies the file out of the way, then opens it in '
          'Packet Tracer.',
      icon: Icons.open_in_new,
      group: pktGroup,
      touchesDevices: true,
      keywords: ['open', 'pkt', 'load', 'restore'],
      run: (context) async {
        final path = await _pickPkt();
        if (path == null || !context.context.mounted) return;
        final result = await runWithFeedback<String>(
          context.context,
          busyLabel: 'Opening $path...',
          action: () => AutopilotService().pktOpen(path),
          successLabel: 'Opened',
        );
        if (result == null || !context.context.mounted) return;
        context.toast(result);
      },
    ),
    AppAction(
      id: 'pt.verify',
      label: 'Verify a .pkt opens',
      description:
          'Reopens a saved file and reports whether Packet Tracer accepts it.',
      icon: Icons.verified_outlined,
      group: pktGroup,
      keywords: ['verify', 'pkt', 'check', 'load test'],
      run: (context) async {
        final path = await _pickPkt();
        if (path == null || !context.context.mounted) return;
        final result = await runWithFeedback<String>(
          context.context,
          busyLabel: 'Verifying $path...',
          action: () => AutopilotService().pktVerify(path),
          successLabel: 'Verified',
        );
        if (result == null || !context.context.mounted) return;
        context.toast(result);
      },
    ),
    _probe(
      id: 'pt.report',
      label: 'Last .pkt save report',
      description: 'Where the last save went, and planned-vs-recorded.',
      icon: Icons.description_outlined,
      group: pktGroup,
      keywords: ['report', 'last save', 'comparison', 'artifact'],
      probe: () async {
        final report = await AutopilotService().pktReport();
        return (
          title: 'Last saved .pkt',
          text: report == null
              ? 'Nothing has been saved yet on this machine.'
              : _pretty(report),
        );
      },
    ),
    _probe(
      id: 'pt.ledger',
      label: 'Fix ledger',
      description:
          'Every fix applied to a .pkt, with its undo entry - the audit trail '
          'behind a changed file.',
      icon: Icons.history_edu_outlined,
      group: pktGroup,
      keywords: ['ledger', 'undo', 'audit trail', 'history'],
      probe: () async {
        final ledger = await AutopilotService().pktLedger();
        return (title: 'Fix ledger', text: _pretty(ledger));
      },
    ),
    _probe(
      id: 'pt.templates',
      label: 'What the .pkt generator can build',
      description:
          'Device models and cables the machine-local template library '
          'covers today.',
      icon: Icons.category_outlined,
      group: pktGroup,
      keywords: ['templates', 'models', 'library', 'harvest', 'pkt builder'],
      probe: () async {
        final status = await AutopilotService().pktTemplatesStatus();
        return (title: 'Template library', text: _pretty(status));
      },
    ),
    AppAction(
      id: 'pt.harvest',
      label: 'Learn device models from local .pkt files',
      description:
          'Extends the template library from Packet Tracer\'s own sample '
          'saves, so a plan asking for a 2911 gets a real 2911.',
      icon: Icons.auto_awesome_motion,
      group: pktGroup,
      keywords: ['harvest', 'templates', 'models', 'samples'],
      run: (context) async {
        final report = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Harvesting models (this can take a minute)...',
          action: () => AutopilotService().pktTemplatesHarvest(),
        );
        if (report == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Template harvest',
          text: _pretty(report),
        );
      },
    ),
    AppAction(
      id: 'pt.templatesBuild',
      label: 'Build the template library from my own .pkt files',
      description:
          'Point it at the saves you already have and the generator learns '
          'the exact device models inside them.',
      icon: Icons.library_add_outlined,
      group: pktGroup,
      keywords: ['templates', 'library', 'build', 'models', 'import pkt'],
      run: (context) async {
        final picked = await FilePicker.platform.pickFiles(
          dialogTitle: 'Choose the .pkt files to learn from',
          allowMultiple: true,
          type: FileType.any,
        );
        final paths = <String>[
          for (final file in picked?.files ?? const <PlatformFile>[])
            if ((file.path ?? '').trim().isNotEmpty) file.path!,
        ];
        if (paths.isEmpty || !context.context.mounted) return;
        final report = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Reading ${paths.length} file(s)...',
          action: () => AutopilotService().pktTemplatesBuild(
            paths,
            outDir: context.settings?.outputDir ?? '',
          ),
        );
        if (report == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Template library built',
          subtitle: 'From ${paths.length} file(s)',
          text: _pretty(report),
        );
      },
    ),
    _probe(
      id: 'pt.engine',
      label: 'Engine health',
      description:
          'Whether the .pkt engine answers, and what it says about itself.',
      icon: Icons.monitor_heart_outlined,
      group: pktGroup,
      keywords: ['engine', 'sidecar', 'health', 'status', 'connection'],
      probe: () async {
        final health = await AutopilotService().healthDetails();
        return (title: 'Engine health', text: _pretty(health));
      },
    ),
    _probe(
      id: 'pt.inventory',
      label: 'Live inventory',
      description:
          'The devices, modules and ports the engine last captured from the '
          'Packet Tracer window.',
      icon: Icons.inventory_2_outlined,
      group: pktGroup,
      keywords: ['inventory', 'devices', 'ports', 'capture'],
      probe: () async {
        final inventory = await AutopilotService().inventory();
        return (title: 'Live inventory', text: _pretty(inventory));
      },
    ),
    _probe(
      id: 'pt.events',
      label: 'Engine events',
      description: 'The journal tail: what the engine did, newest last.',
      icon: Icons.receipt_long_outlined,
      group: pktGroup,
      keywords: ['events', 'log', 'journal', 'trace'],
      probe: () async {
        final events = await AutopilotService().events(limit: 120);
        return (
          title: 'Engine events',
          text: events.isEmpty
              ? 'No events recorded yet.'
              : [
                  for (final event in events)
                    '${event['ts'] ?? ''}  ${event['kind'] ?? ''}  '
                        '${event['message'] ?? event['text'] ?? ''}',
                ].join('\n'),
        );
      },
    ),
    _probe(
      id: 'pt.shots',
      label: 'Screenshots from the run',
      description:
          'The evidence the engine saved while it worked, with their paths.',
      icon: Icons.photo_library_outlined,
      group: pktGroup,
      keywords: ['screenshots', 'evidence', 'shots', 'images'],
      probe: () async {
        final shots = await AutopilotService().shots();
        return (
          title: 'Run screenshots',
          text: shots.isEmpty
              ? 'No screenshots have been captured yet.'
              : [
                  for (final shot in shots)
                    '${shot['name'] ?? shot['path'] ?? '?'}'
                        '${shot['when'] == null ? '' : '  ${shot['when']}'}',
                ].join('\n'),
        );
      },
    ),
    _probe(
      id: 'pt.suggest',
      label: 'Ask the engine for a suggestion',
      description:
          'Rule suggestions distilled from recurring failure patterns.',
      icon: Icons.lightbulb_outline,
      group: pktGroup,
      keywords: ['suggest', 'advice', 'rules', 'patterns'],
      probe: () async {
        final suggestion = await AutopilotService().aiSuggest(
          project: 'default',
        );
        return (title: 'Engine suggestion', text: _pretty(suggestion));
      },
    ),
    _probe(
      id: 'pt.prove',
      label: 'Prove the click grid',
      description:
          'Test mode: checks that the engine can still find and move on the '
          'Packet Tracer canvas.',
      icon: Icons.my_location,
      group: pktGroup,
      touchesDevices: true,
      keywords: ['prove', 'calibrate', 'click', 'grid', 'test'],
      probe: () async {
        final result = await AutopilotService().prove();
        return (title: 'Click grid proof', text: result);
      },
    ),
    _probe(
      id: 'pt.inspect',
      label: 'Inspect the Packet Tracer window',
      description: 'What the engine sees right now: window, canvas, state.',
      icon: Icons.visibility_outlined,
      group: pktGroup,
      keywords: ['inspect', 'window', 'state', 'screenshot'],
      probe: () async {
        final result = await AutopilotService().inspect();
        return (title: 'Window inspection', text: result);
      },
    ),
    AppAction(
      id: 'pt.run.stop',
      label: 'Emergency stop',
      description:
          'Cancels the running job immediately. The same thing the Esc key '
          'does.',
      icon: Icons.stop_circle_outlined,
      group: pktGroup,
      touchesDevices: true,
      keywords: ['stop', 'cancel', 'abort', 'emergency'],
      run: (context) async {
        try {
          await AutopilotService().stop();
          context.toast('Emergency stop requested');
        } catch (e) {
          context.toast('Stop could not reach the engine: $e');
        }
      },
    ),
    AppAction(
      id: 'pt.run.pause',
      label: 'Pause or resume the run',
      description:
          'Holds the job at a safe boundary with its progress kept, or '
          'releases it. Same as F9.',
      icon: Icons.pause_circle_outline,
      group: pktGroup,
      touchesDevices: true,
      keywords: ['pause', 'resume', 'hold', 'f9'],
      run: (context) async {
        final result = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Toggling pause...',
          action: () => AutopilotService().pauseToggle(),
        );
        if (result == null) return;
        context.toast(
          (result['state'] ?? '').toString() == 'paused'
              ? 'Autopilot paused'
              : 'Autopilot resumed',
        );
      },
    ),
    AppAction(
      id: 'pt.gns3',
      label: 'Push the plan to GNS3',
      description:
          'Creates the project and its nodes on the GNS3 server configured in '
          'Settings, and wires the links.',
      icon: Icons.hub_outlined,
      group: pktGroup,
      needsPlan: true,
      touchesDevices: true,
      keywords: ['gns3', 'push', 'server', 'import', 'remote'],
      run: (context) async {
        final settings = context.settings;
        if (settings == null) return;
        final confirmed = await confirmAction(
          context.context,
          title: 'Push this plan to GNS3?',
          body: 'A new project will be created on ${settings.gns3Endpoint} '
              'with ${context.intent!.nodes.length} nodes and '
              '${context.intent!.links.length} links.',
          icon: Icons.hub_outlined,
          confirmLabel: 'Push it',
        );
        if (!confirmed || !context.context.mounted) return;
        final report = await runWithFeedback<String>(
          context.context,
          busyLabel: 'Pushing to GNS3...',
          action: () => Gns3Adapter.push(
            context.intent!,
            endpoint: settings.gns3Endpoint,
            user: settings.gns3User,
            pass: settings.gns3Pass,
          ),
        );
        if (report == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'GNS3 push',
          text: report,
        );
      },
    ),

    // ---- Exports ----
    AppAction(
      id: 'export.artifacts',
      label: 'Export the plan: IOS, PT, GNS3, Terraform',
      description:
          'Every compiled artifact for the open plan, ready to copy into a '
          'device, a simulator or a cloud account.',
      icon: Icons.ios_share,
      group: exportGroup,
      needsPlan: true,
      keywords: ['export', 'config', 'terraform', 'gns3', 'cisco', 'artifacts'],
      run: (context) => Future.sync(
        () => context.push(
          NetworkToolkitScreen(
            initialSection: ToolkitSection.exporters,
            intent: context.intent,
          ),
        ),
      ),
    ),
    AppAction(
      id: 'export.cisco',
      label: 'Cisco IOS configuration',
      description: 'The whole plan as IOS CLI, device by device.',
      icon: Icons.terminal,
      group: exportGroup,
      needsPlan: true,
      keywords: ['cisco', 'ios', 'ssh', 'cli', 'config'],
      run: (context) async {
        final rendered = CiscoAdapter.render(context.intent!);
        await showArtifactDialog(
          context.context,
          title: 'Cisco IOS configuration',
          subtitle: _filesLocked(context.intent),
          text: rendered.entries
              .map((entry) => '! ===== ${entry.key} =====\n${entry.value}')
              .join('\n\n'),
        );
      },
    ),
    AppAction(
      id: 'export.packetTracer',
      label: 'Packet Tracer CLI configuration',
      description: 'The same plan shaped for Packet Tracer devices.',
      icon: Icons.router_outlined,
      group: exportGroup,
      needsPlan: true,
      keywords: ['packet tracer', 'cli', 'config', 'pt'],
      run: (context) async {
        final rendered = PacketTracerAdapter.deviceConfigs(context.intent!);
        await showArtifactDialog(
          context.context,
          title: 'Packet Tracer CLI configuration',
          subtitle: _filesLocked(context.intent),
          text: rendered.entries
              .map((entry) => '! ===== ${entry.key} =====\n${entry.value}')
              .join('\n\n'),
        );
      },
    ),
    AppAction(
      id: 'export.gns3',
      label: 'GNS3 project JSON',
      description: 'Nodes, templates and links, ready to import by hand.',
      icon: Icons.hub_outlined,
      group: exportGroup,
      needsPlan: true,
      keywords: ['gns3', 'json', 'project', 'import'],
      run: (context) async {
        await showArtifactDialog(
          context.context,
          title: 'GNS3 project JSON',
          subtitle: _filesLocked(context.intent),
          text: Gns3Adapter.exportJson(context.intent!),
        );
      },
    ),
    AppAction(
      id: 'export.terraform',
      label: 'Terraform (AWS VPC)',
      description:
          'The cloud equivalent of the same topology, as Terraform.',
      icon: Icons.cloud_outlined,
      group: exportGroup,
      needsPlan: true,
      keywords: ['terraform', 'aws', 'vpc', 'iac', 'cloud'],
      run: (context) async {
        await showArtifactDialog(
          context.context,
          title: 'Terraform - AWS VPC',
          subtitle: _filesLocked(context.intent),
          text: TerraformAdapter.renderAwsVpc(context.intent!),
        );
      },
    ),
    AppAction(
      id: 'export.diagnostics',
      label: 'Export a diagnostics archive',
      description:
          'A redacted archive of how the app behaved, for a bug report. '
          'Screenshots are excluded.',
      icon: Icons.archive_outlined,
      group: exportGroup,
      keywords: ['diagnostics', 'export', 'support', 'bug report', 'logs'],
      run: (context) async {
        final archive = await runWithFeedback<Map<String, dynamic>>(
          context.context,
          busyLabel: 'Building the archive...',
          action: () => AutopilotService().exportDiagnostics(),
        );
        if (archive == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Diagnostics archive',
          text: _pretty(archive),
        );
      },
    ),

    // ---- Chat ----
    AppAction(
      id: 'chat.open',
      label: 'Open the chat',
      description: 'Talk to the assistant about the lab, a config or a fault.',
      icon: AppDestination.chat.icon,
      group: chatGroup,
      keywords: [..._destinations(AppDestination.chat), 'chat', 'ask', 'talk'],
      run: (context) => Future.sync(() => context.go(AppDestination.chat)),
    ),
    AppAction(
      id: 'chat.new',
      label: 'Start a new conversation',
      description:
          'A fresh transcript for a new topic, kept alongside the others.',
      icon: Icons.add_comment_outlined,
      group: chatGroup,
      keywords: ['new chat', 'conversation', 'topic', 'thread'],
      run: (context) async {
        final name = await promptText(
          context.context,
          title: 'Name this conversation',
          label: 'Conversation',
          initial: 'chat ${DateTime.now().toIso8601String().substring(11, 16)}',
          helper: 'The name is the conversation - it shows in the sidebar and '
              'keeps its own transcript.',
        );
        if (name == null || name.trim().isEmpty) return;
        context.openChat(project: name.trim());
      },
    ),
    AppAction(
      id: 'chat.explainPlan',
      label: 'Ask the assistant to explain the plan',
      description:
          'Opens the chat with the question already written, so you press '
          'send and nothing else.',
      icon: Icons.question_answer_outlined,
      group: chatGroup,
      keywords: ['explain', 'plain english', 'ask', 'plan review'],
      run: (context) => Future.sync(
        () => context.openChat(
          project: context.project,
          prefill:
              'Explain the current plan (${_filesLocked(context.intent)}) in '
              'plain English: what each device does, how the subnets are laid '
              'out, and what I should check first.',
        ),
      ),
    ),
    AppAction(
      id: 'chat.troubleshoot',
      label: 'Ask the assistant what is wrong',
      description:
          'Opens the chat with a troubleshooting question already written.',
      icon: Icons.health_and_safety_outlined,
      group: chatGroup,
      keywords: ['troubleshoot', 'broken', 'wrong', 'why', 'diagnose'],
      run: (context) => Future.sync(
        () => context.openChat(
          project: context.project,
          prefill:
              'Something is not working in this lab. Ask me for the evidence '
              'you need (configs, show output, a screenshot) and then tell me '
              'the most likely cause and the exact commands to confirm it.',
        ),
      ),
    ),

    // ---- Memory and learning ----
    _go(
      id: 'memory.open',
      label: 'Memory, rules and corrections',
      destination: AppDestination.memory,
      description:
          'What the app remembers: corrections you taught, rules it distilled '
          'and the failure journal behind them.',
      keywords: ['memory', 'rules', 'corrections', 'learning'],
    ),
    AppAction(
      id: 'memory.export',
      label: 'Export everything the app remembers',
      description:
          'Builds, attempts, rules, preferences and chat, as JSON - yours to '
          'keep or move.',
      icon: Icons.download_outlined,
      group: memoryGroup,
      keywords: ['export', 'backup', 'json', 'memory', 'move'],
      run: (context) async {
        final mem = context.memory;
        if (mem == null || !mem.ready) {
          context.toast('Memory is not available in this session.');
          return;
        }
        final json = await runWithFeedback<String>(
          context.context,
          busyLabel: 'Collecting memory...',
          action: () => mem.exportJson(),
        );
        if (json == null || !context.context.mounted) return;
        await showArtifactDialog(
          context.context,
          title: 'Memory export',
          subtitle: 'Builds, attempts, rules, preferences and chat',
          text: json,
        );
      },
    ),
    _probe(
      id: 'memory.learning',
      label: 'What the engine learned',
      description:
          'Failed actions plus the successful recoveries it can reuse.',
      icon: Icons.school_outlined,
      group: memoryGroup,
      keywords: ['learning', 'experiences', 'reuse', 'strategies'],
      probe: () async {
        final experiences = await AutopilotService().learningExperiences();
        return (
          title: 'Learned experiences',
          text: experiences.isEmpty
              ? 'Nothing has been learned yet on this machine.'
              : _pretty(experiences),
        );
      },
    ),
    _probe(
      id: 'memory.stats',
      label: 'Failure journal statistics',
      description: 'Which kinds of failure recur, and how often.',
      icon: Icons.insights_outlined,
      group: memoryGroup,
      keywords: ['stats', 'statistics', 'journal', 'failures'],
      probe: () async {
        final stats = await AutopilotService().stats();
        return (title: 'Failure journal', text: _pretty(stats));
      },
    ),

    // ---- Settings and system ----
    _go(
      id: 'settings.open',
      label: 'Settings',
      destination: AppDestination.settings,
      description:
          'Keys, provider, engine address, output folder, context budget.',
      keywords: ['settings', 'keys', 'api', 'provider', 'folder', 'config'],
    ),
    AppAction(
      id: 'settings.drawer',
      label: 'Open the settings sidebar',
      description:
          'The sidebar: chats, run controls, the ledger, live context and '
          'every technical setting.',
      icon: Icons.menu_open,
      group: systemGroup,
      keywords: ['sidebar', 'drawer', 'chats', 'run controls', 'ledger'],
      run: (context) => Future.sync(context.openDrawer),
    ),
    AppAction(
      id: 'settings.theme.system',
      label: 'Theme: follow the system',
      description: 'Light or dark, decided by the operating system.',
      icon: Icons.brightness_auto_outlined,
      group: systemGroup,
      keywords: ['theme', 'appearance', 'dark', 'light', 'system'],
      run: (context) async {
        await context.settings?.setThemeMode('system');
        context.toast('Theme follows the system');
      },
    ),
    AppAction(
      id: 'settings.theme.light',
      label: 'Theme: light',
      description: 'Always light - the readable choice in a bright room.',
      icon: Icons.light_mode_outlined,
      group: systemGroup,
      keywords: ['theme', 'appearance', 'light', 'day'],
      run: (context) async {
        await context.settings?.setThemeMode('light');
        context.toast('Light theme');
      },
    ),
    AppAction(
      id: 'settings.theme.dark',
      label: 'Theme: dark',
      description: 'Always dark - easier on the eyes at night.',
      icon: Icons.dark_mode_outlined,
      group: systemGroup,
      keywords: ['theme', 'appearance', 'dark', 'night'],
      run: (context) async {
        await context.settings?.setThemeMode('dark');
        context.toast('Dark theme');
      },
    ),
    AppAction(
      id: 'settings.privacy',
      label: 'Check what a web lookup would send',
      description:
          'Redacts an error into a generic search query and shows you exactly '
          'what would leave this machine - which is why addresses and names '
          'never do.',
      icon: Icons.privacy_tip_outlined,
      group: systemGroup,
      keywords: ['privacy', 'redact', 'search', 'leak', 'query'],
      run: (context) async {
        final errorText = await promptText(
          context.context,
          title: 'What went wrong?',
          label: 'Error text',
          hint: 'OSPF authentication mismatch on Gi0/1',
          helper: 'The preview shows the redacted query, not your text.',
        );
        if (errorText == null || errorText.trim().isEmpty) return;
        if (!context.context.mounted) return;
        final query = PrivacySearchService.buildQuery(
          errorText: errorText.trim(),
          target: context.settings?.defaultTarget ?? 'packet-tracer',
        );
        await showArtifactDialog(
          context.context,
          title: 'Redacted search query',
          subtitle:
              'This is everything the app would send. Addresses, hostnames '
              'and device names are removed before this point.',
          text: '${PrivacySearchService.previewPayload(query)}\n\n'
              '--- query ---\n$query',
        );
      },
    ),
    AppAction(
      id: 'system.engine',
      label: 'Local engine status',
      description:
          'Start, restart or stop the local .pkt engine, see what it can do '
          '(Packet Tracer control, OCR) and read its log when a start fails.',
      icon: Icons.dns_outlined,
      group: systemGroup,
      keywords: [
        'sidecar', 'engine', 'start', 'stop', 'restart', 'python', 'service',
        'log', 'diagnose',
      ],
      run: (context) => Future.sync(
        () => context.push(EngineScreen(settings: context.settings)),
      ),
    ),
    AppAction(
      id: 'system.sidecar',
      label: 'Start the local engine now',
      description:
          'Brings the local .pkt engine up and reports exactly what happened, '
          'so a failure comes with a reason instead of a dead end.',
      icon: Icons.power_settings_new,
      group: systemGroup,
      keywords: ['sidecar', 'engine', 'start', 'python', 'service'],
      run: (context) async {
        final started = await runWithFeedback<bool>(
          context.context,
          busyLabel: 'Starting the local engine...',
          action: () => EngineStatus.instance.ensure(force: true),
        );
        if (started == null) return;
        context.toast(
          started
              ? 'The local engine is running.'
              : EngineStatus.instance.summary,
        );
      },
    ),
    _probe(
      id: 'system.runSummary',
      label: 'Run summary',
      description:
          'What the last run did: answered, skipped, failed, and where it is '
          'now.',
      icon: Icons.summarize_outlined,
      group: systemGroup,
      keywords: ['summary', 'run', 'progress', 'report'],
      probe: () async {
        final summary = await AutopilotService().runSummary();
        return (title: 'Run summary', text: _pretty(summary));
      },
    ),
    _probe(
      id: 'system.llm',
      label: 'Model connection status',
      description:
          'Whether the configured provider answers, and which model is live.',
      icon: Icons.smart_toy_outlined,
      group: systemGroup,
      keywords: ['llm', 'model', 'api', 'status', 'provider'],
      probe: () async {
        final status = await AutopilotService().llmStatus();
        return (title: 'Model status', text: _pretty(status));
      },
    ),
  ];
}
