import '../models/network_intent.dart';
import 'adapters/gns3_adapter.dart';
import 'network_math.dart';
import 'network_tools.dart';
import 'planner_suggestions_service.dart';
import 'validator_service.dart';

/// The read-only app capabilities the chat can run from plain language.
///
/// The Action Hub already gives every feature a button (see
/// `CapabilityRegistry`); this class is how the KEYLESS chat reaches the
/// same capabilities. Each one:
///
/// * runs the SAME service behind the Action Hub button, so the chat and
///   the button can never disagree about what a check found;
/// * needs a plan on the table first, and says so when there is none;
/// * is read-only - it inspects the plan and reports. Anything that
///   changes a device or a file (builds, fixes, run controls) keeps its
///   existing approval-gated path and is never executed here.
enum ChatCapability {
  /// Action Hub button: "Check the plan for errors" (`plan.validate`).
  validatePlan,

  /// Action Hub button: "Find duplicate addresses in the plan"
  /// (`tools.duplicates`).
  duplicateAddresses,

  /// Action Hub button: "Check the subnets for overlaps" (`tools.overlaps`).
  subnetOverlaps,

  /// Action Hub button: "What to improve in the plan" (`plan.suggestions`).
  improvePlan,

  /// Read-only: the files this conversation produced plus where every save
  /// lives (the Files view).
  savedNetworks,

  /// Read-only preview of the GNS3 export, plus the pointer at the
  /// approval-gated actions that create or push it.
  exportGns3,

  /// "Export the plan" with no format named: offer the formats and ask
  /// which one, rather than picking for the user.
  exportHelp,
}

class ChatCapabilities {
  const ChatCapabilities._();

  /// The Action Hub button each capability mirrors, so an answer can point
  /// at the button for the full output.
  static const Map<ChatCapability, String> hubButton = {
    ChatCapability.validatePlan: 'Check the plan for errors',
    ChatCapability.duplicateAddresses: 'Find duplicate addresses in the plan',
    ChatCapability.subnetOverlaps: 'Check the subnets for overlaps',
    ChatCapability.improvePlan: 'What to improve in the plan',
    ChatCapability.savedNetworks: 'Files',
    ChatCapability.exportGns3: 'Export the plan: IOS, PT, GNS3, Terraform',
    ChatCapability.exportHelp: 'Export the plan: IOS, PT, GNS3, Terraform',
  };

  /// Prerequisites and behaviour for each capability: what it needs on the
  /// table, and whether it only reads data or can change something.
  ///
  /// Every capability in this enum is read-only by design. The
  /// approval-gated capabilities (builds, fixes, GNS3 pushes) are NOT in
  /// this enum at all - they live in the Action Hub where they are
  /// approved; the chat only ever previews or points at them.
  static const Map<ChatCapability, ({bool readOnly, bool needsPlan})> meta = {
    ChatCapability.validatePlan: (readOnly: true, needsPlan: true),
    ChatCapability.duplicateAddresses: (readOnly: true, needsPlan: true),
    ChatCapability.subnetOverlaps: (readOnly: true, needsPlan: true),
    ChatCapability.improvePlan: (readOnly: true, needsPlan: true),
    ChatCapability.savedNetworks: (readOnly: true, needsPlan: false),
    ChatCapability.exportGns3: (readOnly: true, needsPlan: true),
    ChatCapability.exportHelp: (readOnly: true, needsPlan: true),
  };

  /// The aliases each capability answers to, kept readable next to the
  /// matcher and walked by the tests: every phrase here provably routes.
  /// Order matters when two aliases could overlap - the narrow checks
  /// (duplicates, overlaps) run before the general ones.
  static const Map<ChatCapability, List<String>> aliases = {
    ChatCapability.duplicateAddresses: [
      'duplicate address', 'duplicate ip', 'any duplicate', 'duplicates',
      'same ip twice', 'ip conflict', 'address conflict',
    ],
    ChatCapability.subnetOverlaps: [
      'do the subnets overlap', 'overlapping subnet', 'subnet overlap',
      'network overlap', 'any overlap', 'check for overlap',
    ],
    ChatCapability.validatePlan: [
      'validate', 'lint', 'sanity check', 'check for errors',
      'check for mistakes', 'find errors', 'find the errors',
      'check the plan', 'check my plan', 'check the network',
      'is the plan ok', 'is the plan okay', "what's wrong with the plan",
      'what is wrong with the plan',
    ],
    ChatCapability.improvePlan: [
      'improve the plan', 'improve my plan', 'improve this plan',
      'improve the network', 'what to improve', 'what should i fix',
      'what to fix', 'any suggestions', 'best practices',
      'review the plan', 'make it better',
    ],
    ChatCapability.savedNetworks: [
      'saved networks', 'saved files', 'saved labs', 'saved projects',
      'show my files', 'list the files', 'list files', 'list saved',
      'show saved', 'what files do i have', 'which files do i have',
    ],
    ChatCapability.exportGns3: [
      'export for gns3', 'export to gns3', 'gns3 export',
      'export the gns3', 'gns3 project', 'gns3 file', 'for gns3',
    ],
    ChatCapability.exportHelp: [
      'export this', 'export the plan', 'export the network', 'export it',
      'export options', 'export formats', 'how do i export',
    ],
  };

  /// The capability a message is asking for, or null.
  ///
  /// Deliberately strict: either the message contains a documented alias,
  /// or it combines a check verb with the object it checks ("check the
  /// design for problems") - so "check my cable" and "can I duplicate a
  /// config" never route here. A "how"/"why" question is left to the
  /// howto path: it asks how a check works, not for this plan to be
  /// checked.
  static ChatCapability? match(String lower) {
    final t = lower.trim().toLowerCase();
    if (t.isEmpty) return null;
    // An export ask routes even when phrased "how do I export...": the
    // export questions are answered by the capability, not the how-to path.
    if (t.contains('export')) {
      return t.contains('gns3')
          ? ChatCapability.exportGns3
          : ChatCapability.exportHelp;
    }
    if (t.startsWith('how ') || t.startsWith('why ')) return null;
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        if (t.contains(alias)) return entry.key;
      }
    }
    final aboutPlan = t.contains('plan') ||
        t.contains('network') ||
        t.contains('lab') ||
        t.contains('design') ||
        t.contains('topology') ||
        t.contains('subnet');
    if (t.contains('overlap') && (aboutPlan || t.contains('check'))) {
      return ChatCapability.subnetOverlaps;
    }
    if (t.contains('duplicate') &&
        (t.contains('address') ||
            RegExp(r'\bips?\b').hasMatch(t) ||
            t.contains('conflict') ||
            t.contains('any'))) {
      return ChatCapability.duplicateAddresses;
    }
    if (aboutPlan &&
        (t.contains('check') ||
            t.contains('errors') ||
            t.contains('mistake') ||
            t.contains('problem') ||
            t.contains('issue') ||
            t.contains('ok to build') ||
            t.contains('ready to build'))) {
      return ChatCapability.validatePlan;
    }
    if ((aboutPlan || t.contains('suggestion')) &&
        (t.contains('improve') ||
            t.contains('suggestion') ||
            t.contains('review') ||
            t.contains('best practice') ||
            t.contains('what to fix') ||
            t.contains('what should i fix'))) {
      return ChatCapability.improvePlan;
    }
    if (t.contains('export') && t.contains('gns3')) {
      return ChatCapability.exportGns3;
    }
    if (t.contains('export')) return ChatCapability.exportHelp;
    if (t.contains('saved') &&
        (t.contains('file') || t.contains('network') || t.contains('lab'))) {
      return ChatCapability.savedNetworks;
    }
    return null;
  }

  /// The answer for a routed capability, computed from the plan with the
  /// same services the Action Hub buttons use. Every answer states that the
  /// check was read-only, and a result is only reported because the service
  /// really ran on this plan.
  static String answer(
    ChatCapability capability, {
    required NetworkIntent? plan,
    required String target,
    List<({String name, String note})> knownArtifacts = const [],
  }) {
    switch (capability) {
      case ChatCapability.validatePlan:
        return _validate(plan, target);
      case ChatCapability.duplicateAddresses:
        return _duplicates(plan);
      case ChatCapability.subnetOverlaps:
        return _overlaps(plan);
      case ChatCapability.improvePlan:
        return _improve(plan, target);
      case ChatCapability.savedNetworks:
        return _savedNetworks(plan, knownArtifacts);
      case ChatCapability.exportGns3:
        return _exportGns3(plan);
      case ChatCapability.exportHelp:
        return _exportHelp(plan);
    }
  }

  /// True when the only "plan" there is came from the parser's tiny-office
  /// fallback: a guess, not a request. Marked by the assumption the parser
  /// attaches when it defaults.
  static bool _looksLikeFallback(NetworkIntent plan) =>
      plan.nodes.length <= 2 &&
      plan.assumptions.any((a) => a.contains('small-office pair was assumed'));

  static String _noPlan(String what) =>
      'I do not have a plan yet, so there is nothing to $what. Describe the '
      'lab first (for example "2 routers, 1 switch and 4 PCs with OSPF") and '
      'I will hold it for checks like this. The same check is also an Action '
      'Hub button once a plan is open.';

  static String _validate(NetworkIntent? plan, String target) {
    if (plan == null || plan.nodes.isEmpty || _looksLikeFallback(plan)) {
      return _noPlan('check for errors');
    }
    final issues = ValidatorService.validate(plan, target: target);
    final head = 'Checked "${plan.projectName}" '
        '(${plan.nodes.length} device(s), ${plan.links.length} link(s)) with '
        'the same validator a build runs - read-only, nothing was changed.';
    if (issues.isEmpty) {
      return '$head\n\nThe plan is clean - no issues found.';
    }
    final errors = issues.where((i) => i.severity == 'error').toList();
    final b = StringBuffer()
      ..writeln(head)
      ..writeln()
      ..writeln('${issues.length} finding(s): ${errors.length} error(s), '
          '${issues.length - errors.length} warning(s).');
    for (final issue in issues.take(10)) {
      b.writeln('- [${issue.severity}] ${issue.message}');
    }
    if (issues.length > 10) {
      b.writeln('... and ${issues.length - 10} more - "${hubButton[ChatCapability.validatePlan]}" '
          'in the Action Hub shows the full list.');
    }
    if (errors.isNotEmpty) {
      b.write('Fix the errors before building. Changes to the lab still go '
          'through the usual approval - I never change a device on my own.');
    }
    return b.toString().trimRight();
  }

  static String _duplicates(NetworkIntent? plan) {
    if (plan == null || plan.nodes.isEmpty || _looksLikeFallback(plan)) {
      return _noPlan('check for duplicate addresses');
    }
    final rows = NetworkTools.duplicateAddresses([
      for (final a in plan.addressing)
        {'node': a.node, 'iface': a.iface, 'ipCidr': a.ipCidr},
    ]);
    if (rows.isEmpty) {
      return 'No duplicate addresses in "${plan.projectName}": every address '
          'is claimed once (read-only check, nothing changed).';
    }
    final b = StringBuffer()
      ..writeln('${rows.length} duplicate address(es) in '
          '"${plan.projectName}" (read-only check, nothing changed):');
    for (final d in rows.take(10)) {
      b.writeln('- ${d['address']} is claimed by '
          '${(d['usedBy'] as List?)?.join(' and ') ?? '?'}');
    }
    b.write('Give the second device the next free host on its LAN to clear '
        'it.');
    return b.toString();
  }

  static String _overlaps(NetworkIntent? plan) {
    if (plan == null || plan.nodes.isEmpty || _looksLikeFallback(plan)) {
      return _noPlan('check the subnets for overlaps');
    }
    // A set, so two interfaces in the same subnet are compared once.
    final cidrs = <String>{
      for (final a in plan.addressing)
        if (a.ipCidr.contains('/')) a.ipCidr,
    }.toList();
    final pairs = NetworkMath.overlappingPairs(cidrs);
    if (pairs.isEmpty) {
      return 'No overlapping subnets among the ${cidrs.length} distinct '
          'subnet(s) in "${plan.projectName}" (read-only check, nothing '
          'changed).';
    }
    final b = StringBuffer()
      ..writeln('${pairs.length} overlapping subnet pair(s) in '
          '"${plan.projectName}" (read-only check, nothing changed):');
    for (final pair in pairs.take(10)) {
      b.writeln('- ${pair.$1} and ${pair.$2} share addresses '
          '(${NetworkMath.coveringPrefix(pair.$1, pair.$2) ?? '?'})');
    }
    b.write('Overlaps like this are a routing fault waiting to happen - '
        'the fix normally moves one subnet to a free range.');
    return b.toString();
  }

  static String _improve(NetworkIntent? plan, String target) {
    if (plan == null || plan.nodes.isEmpty || _looksLikeFallback(plan)) {
      return _noPlan('review');
    }
    final suggestions =
        PlannerSuggestionsService.forIntent(plan, target: target);
    if (suggestions.isEmpty) {
      return '"${plan.projectName}" reads complete - nothing to add. This is '
          'the same review as the Action Hub button '
          '"${hubButton[ChatCapability.improvePlan]}".';
    }
    final b = StringBuffer()
      ..writeln('${suggestions.length} suggestion(s) for '
          '"${plan.projectName}" (read-only review, nothing changed):');
    for (final s in suggestions.take(8)) {
      b.writeln('- $s');
    }
    if (suggestions.length > 8) {
      b.writeln('... and ${suggestions.length - 8} more in the Action Hub '
          'button "${hubButton[ChatCapability.improvePlan]}".');
    }
    return b.toString().trimRight();
  }

  /// What files exist, without guessing: the conversation's own builds with
  /// what is known about each, and where every save can be inspected.
  static String _savedNetworks(
    NetworkIntent? plan,
    List<({String name, String note})> knownArtifacts,
  ) {
    if (knownArtifacts.isEmpty) {
      final planBit = plan == null || plan.nodes.isEmpty
          ? ''
          : ' The current plan ("${plan.projectName}", '
                '${plan.nodes.length} device(s)) is ready to build.';
      return 'This conversation has not produced a file yet.$planBit\n\n'
          'Every save is listed in the Files view (Action Hub ▸ Files) with '
          'its audits and repairs; the Import screen can open any .pkt for a '
          'read-only audit.';
    }
    final b = StringBuffer('Files this conversation produced (newest first):');
    for (final f in knownArtifacts.take(5)) {
      b.write('\n- ${f.name}${f.note.isEmpty ? '' : ' (${f.note})'}');
    }
    b.write(
      '\n\nThe Files view lists every save with its audit and repair trail. '
      'Say "edit <file name>" to change one in place (a timestamped backup '
      'is kept first).',
    );
    return b.toString();
  }

  /// The GNS3 export, previewed read-only. Creating the file and pushing it
  /// to a server stay the approval-gated Action Hub actions.
  static String _exportGns3(NetworkIntent? plan) {
    if (plan == null || plan.nodes.isEmpty) {
      return _noPlan('export to GNS3');
    }
    final json = Gns3Adapter.exportJson(plan);
    final lines = json.split('\n');
    final preview = lines.take(14).join('\n');
    return 'The GNS3 export for "${plan.projectName}" is ready to generate '
        '(${plan.nodes.length} device(s), ${plan.links.length} link(s)) - '
        'produced by the same adapter the Action Hub uses. Read-only preview '
        'of its first lines:\n\n```\n$preview\n'
        '${lines.length > 14 ? '... (${lines.length - 14} more lines)\n' : ''}```\n\n'
        'Create the actual file with the Action Hub button '
        '"${hubButton[ChatCapability.exportGns3]}". Pushing it to a live GNS3 '
        'server is the separate "Push the plan to GNS3" action - it asks for '
        'approval and uses the server configured in Settings.';
  }

  /// "Export the plan" with no format named: offer the formats and ask
  /// which one, like the prompt asks, rather than picking silently.
  static String _exportHelp(NetworkIntent? plan) {
    final b = StringBuffer(
      'Exports are produced from the plan by the same adapters the Action '
      'Hub uses:\n- Cisco IOS configuration\n- Packet Tracer config\n'
      '- GNS3 project (JSON)\n- Terraform',
    );
    if (plan == null || plan.nodes.isEmpty) {
      b.write(
        '\n\nNo plan is on the table yet - describe the lab first, then say '
        '"export for GNS3", or open "${hubButton[ChatCapability.exportHelp]}" '
        'in the Action Hub.',
      );
    } else {
      b.write(
        '\n\nWhich one? Say "export for GNS3" for a read-only preview, or '
        'open "${hubButton[ChatCapability.exportHelp]}" in the Action Hub '
        'for all four.',
      );
    }
    return b.toString();
  }
}
