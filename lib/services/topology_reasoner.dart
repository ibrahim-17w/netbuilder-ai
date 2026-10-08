// Topology reachability reasoner: "why can't PC1 ping PC2?" answered by
// WALKING THE PLAN'S OWN GRAPH - addressing, gateways, links, subnets,
// routing - as a deterministic check ladder, never a text match.
//
// The offline assistant must be smart WITHOUT any model (locked product
// direction), so every finding here is computed from plan data. A check the
// plan cannot support says exactly what is missing ("cannot tell from the
// plan: ...") instead of guessing: a guessed verdict in either direction is
// worse than an honest gap, because the user acts on it.
//
// The gateway of an end device deserves one note up front: the plan does not
// store per-endpoint gateways. What the plan DOES store is the router
// interface address on the link the device hangs off - which is exactly what
// PacketTracerAdapter.endpointIpConfig types into Desktop > IP
// Configuration. So "the gateway the plan gives this device" is derived here
// from the same rows the adapter reads, by the same walk (device -> switch ->
// router interface). When this reasoner says "the gateway would be X", X is
// what the built file would actually carry.
//
// Pure Dart: no I/O, no Flutter, no async, no emoji - every step is testable.

import '../models/network_intent.dart';
import 'fuzzy_match.dart';
import 'network_tools.dart';

/// One rung of the deterministic check ladder: what was checked and what the
/// plan's own data showed.
class ReasonStep {
  /// Short label of the check ('Link', 'Addressing', 'Subnet', 'Gateway',
  /// 'Duplicates', 'Routing', 'Cables', ...).
  final String check;

  /// One line, computed from the plan - addresses, names, reasons included.
  final String detail;

  /// True when this step is the finding that stops the ladder.
  final bool blocked;

  /// True when the plan cannot support this check at all (a fail-closed gap,
  /// not a fault).
  final bool cannotTell;

  /// A verification command for the device console, when one applies
  /// (`ping ...`, `show ip route`).
  final String? command;

  /// Fix-oriented next actions the user can send straight back.
  final List<String> fixes;

  const ReasonStep({
    required this.check,
    required this.detail,
    this.blocked = false,
    this.cannotTell = false,
    this.command,
    this.fixes = const [],
  });

  bool get ok => !blocked && !cannotTell;
}

/// A parsed reachability question: the two plan devices it is about, with
/// canonical (plan-spelled) names.
class ReachabilityQuestion {
  final String from;
  final String to;

  const ReachabilityQuestion({required this.from, required this.to});

  /// Null unless [text] asks a reachability question about two devices of
  /// [plan]. Use [parseQuestion] when the caller needs to know WHY the text
  /// did not parse (unknown or ambiguous device names) so it can ask a
  /// precise clarifying question instead of a generic retry.
  static ReachabilityQuestion? parse(String text, NetworkIntent plan) =>
      parseQuestion(text, plan).question;

  /// The same reader as [parse], plus the failure reason. [failure] is null
  /// when the text simply was not a reachability question; it is non-null
  /// when the text WAS one but named a device the plan does not have (or an
  /// ambiguous shorthand), which is the case worth clarifying.
  static ({ReachabilityQuestion? question, String? failure}) parseQuestion(
    String text,
    NetworkIntent plan,
  ) {
    final raw = text.trim();
    if (raw.isEmpty) return (question: null, failure: null);
    if (plan.nodes.length < 2) {
      // A one-device plan has nothing to reason between. Only own up to that
      // when the text actually asked the question - otherwise stay silent so
      // an unrelated message keeps its normal path.
      final asked = _patterns.any((p) => p.hasMatch(raw));
      return (
        question: null,
        failure: asked
            ? 'This plan has fewer than two devices, so there is nothing to '
                'reason between yet.'
            : null,
      );
    }
    for (final p in _patterns) {
      for (final m in p.allMatches(raw)) {
        final first = _resolveDevice(m.group(1)!, plan);
        if (first.failure != null) {
          return (question: null, failure: first.failure);
        }
        // A null name with no failure means the slot was a noise word - this
        // match is not a question about two devices of the plan, so keep
        // looking rather than erroring.
        if (first.name == null) continue;
        final second = _resolveDevice(m.group(2)!, plan);
        if (second.failure != null) {
          return (question: null, failure: second.failure);
        }
        if (second.name == null) continue;
        return (
          question: ReachabilityQuestion(from: first.name!, to: second.name!),
          failure: null,
        );
      }
    }
    return (question: null, failure: null);
  }

  /// The question shapes this reader accepts. Device slots are single
  /// plan-name-like tokens; noise around them ('the', pronouns) is filtered
  /// by the resolver, so a slot that resolves to nothing meaningful turns
  /// the pattern match into "not this shape" rather than an error.
  static const String _dev = r'([A-Za-z][A-Za-z0-9_.-]*)';
  static const String _verb =
      r'(?:ping|reach|communicate\s+with|talk\s+to|connect\s+to)';

  static final List<RegExp> _patterns = [
    // "why can't PC1 ping PC2", "why cannot R1 reach R2".
    // NOT raw strings: the device/verb slots interpolate, so the escapes
    // are doubled and the prefix is absent.
    RegExp(
      "why\\s+can(?:not|'?t)\\s+$_dev\\s+$_verb\\s+(?:the\\s+)?$_dev\\b",
      caseSensitive: false,
    ),
    // "PC1 and PC2 cannot ping each other", "... cannot talk to each other".
    // Ordered BEFORE the plain "X cannot ping Y" shape on purpose: that one
    // would otherwise swallow this sentence with Y = 'each' and report the
    // noise word as an unknown device.
    RegExp(
      "\\b$_dev\\s+and\\s+$_dev\\s+(?:cannot|can'?t|cant)\\s+"
      '$_verb\\s+each\\s+other\\b',
      caseSensitive: false,
    ),
    // "PC1 and PC2 cannot communicate".
    RegExp(
      "\\b$_dev\\s+and\\s+$_dev\\s+(?:cannot|can'?t|cant)\\s+communicate\\b",
      caseSensitive: false,
    ),
    // "PC1 cannot reach PC2", "PC2 doesn't ping PC1", "PC1 is not able to
    // reach PC2".
    RegExp(
      "\\b$_dev\\s+(?:cannot|can'?t|cant|does\\s+not|doesn'?t|"
      'is\\s+not\\s+able\\s+to)\\s+$_verb\\s+(?:the\\s+)?$_dev\\b',
      caseSensitive: false,
    ),
    // "troubleshoot connectivity between PC1 and PC2".
    RegExp(
      '\\b(?:troubleshoot|test|check|verify|debug)\\s+(?:the\\s+)?'
      '(?:connectivity|reachability|link|path)\\s+between\\s+'
      '$_dev\\s+and\\s+$_dev\\b',
      caseSensitive: false,
    ),
    // "check reachability from R1 to R2".
    RegExp(
      '\\b(?:troubleshoot|test|check|verify|debug)\\s+(?:the\\s+)?'
      '(?:connectivity|reachability|link|path)\\s+from\\s+'
      '$_dev\\s+to\\s+$_dev\\b',
      caseSensitive: false,
    ),
    // "can PC1 ping PC2", "can R1 reach R2".
    RegExp(
      "\\bcan\\s+(?:the\\s+)?$_dev\\s+$_verb\\s+(?:the\\s+)?$_dev\\b",
      caseSensitive: false,
    ),
    // "PC1 to PC2 not working".
    RegExp(
      "\\b$_dev\\s+to\\s+$_dev\\s+(?:is\\s+)?not\\s+working\\b",
      caseSensitive: false,
    ),
  ];

  /// Words that are grammatical furniture, not device names. Checked AFTER
  /// the exact match, so a device the user really named 'PC' or 'Server'
  /// still wins - the noise set only stops pronouns and generic nouns from
  /// being reported as "unknown device".
  static const Set<String> _noise = {
    'i', 'me', 'my', 'we', 'us', 'you', 'your', 'he', 'she', 'it', 'they',
    'them', 'this', 'that', 'these', 'those', 'the', 'a', 'an', 'one',
    'pc', 'pcs', 'router', 'routers', 'switch', 'switches', 'server',
    'servers', 'device', 'devices', 'host', 'hosts', 'gateway', 'gateways',
    'subnet', 'subnets', 'vlan', 'vlans', 'network', 'networks', 'ping',
    'pings', 'traffic', 'packet', 'packets', 'data', 'connection',
    'connectivity', 'reachability',
    // The quantifying and pairing words a question drags with it - they are
    // grammar here, never device names ('each', from "cannot ping each
    // other", must not read as an unknown host).
    'each', 'other', 'others', 'another', 'all', 'both', 'either',
    'neither', 'able', 'itself', 'themselves',
  };

  /// A device name with separators removed: case-insensitive, and 'p_c-1'
  /// normalizes to the same key as 'PC1'. That is the whole normalization on
  /// purpose: two plan names that collide after it surface as ambiguous
  /// instead of silently picking one.
  static String _normName(String raw) =>
      raw.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Resolve one question slot against the plan's device names, in tiers:
  /// exact (normalized) -> unique prefix -> near typo. Every tier is
  /// deterministic and refuses to guess when two devices match equally:
  /// a tie is reported, never broken, so the assistant can ask precisely.
  static ({String? name, String? failure}) _resolveDevice(
    String raw,
    NetworkIntent plan,
  ) {
    final norm = _normName(raw);
    if (norm.isEmpty) return (name: null, failure: null);
    final names = plan.nodes.map((n) => n.name).join(', ');

    // Tier 1: exact after normalization ('pc1' -> 'PC1', 'hq_pc1' ->
    // 'HQ_PC1').
    final exact = plan.nodes
        .where((n) => _normName(n.name) == norm)
        .map((n) => n.name)
        .toList();
    if (exact.length == 1) return (name: exact.first, failure: null);
    if (exact.length > 1) {
      return (
        name: null,
        failure: "'${raw.trim()}' matches more than one device in this plan "
            '- ${exact.join(', ')}. Name one of them.',
      );
    }
    if (_noise.contains(norm)) return (name: null, failure: null);

    // Tier 2: unique prefix ('sw' -> 'SW1' when SW1 is the only switch).
    // An ambiguous prefix is the user's shorthand, not a fact - report the
    // candidates instead of choosing.
    final prefixed = plan.nodes
        .where((n) => _normName(n.name).startsWith(norm))
        .map((n) => n.name)
        .toList();
    if (prefixed.length == 1) return (name: prefixed.first, failure: null);
    if (prefixed.length > 1) {
      return (
        name: null,
        failure: "'${raw.trim()}' matches more than one device in this plan "
            '- ${prefixed.join(', ')}. Name one of them.',
      );
    }

    // Tier 3: one typo away, reusing FuzzyMatch's distance and its
    // length-scaled budget. The first letter must match and the nearest
    // candidate must be strictly nearer than the runner-up - the same
    // no-coin-flip rule the planner's typo correction lives by.
    final near = <(String, int)>[];
    for (final n in plan.nodes) {
      final key = _normName(n.name);
      if (key.isEmpty || key[0] != norm[0]) continue;
      final budget = FuzzyMatch.budgetFor(
        norm.length > key.length ? norm.length : key.length,
      );
      final d = FuzzyMatch.distance(norm, key);
      if (d >= 1 && d <= budget) near.add((n.name, d));
    }
    if (near.isNotEmpty) {
      near.sort((a, b) => a.$2.compareTo(b.$2));
      final best = near.where((e) => e.$2 == near.first.$2).toList();
      if (best.length == 1) return (name: best.first.$1, failure: null);
      return (
        name: null,
        failure: "'${raw.trim()}' is one letter from several devices in this "
            'plan - ${best.map((e) => e.$1).join(', ')}. Which one did you '
            'mean?',
      );
    }
    return (
      name: null,
      failure: "I don't see a device named '${raw.trim()}' in this plan - "
          'the plan has $names.',
    );
  }
}

/// The verdict of walking a plan for one reachability question.
class ReachabilityVerdict {
  /// true = every check the plan supports passed; false = a blocking finding
  /// stopped the ladder; null = the plan cannot support the question
  /// (fail-closed: what is missing is named in the ladder).
  final bool? reachable;

  /// The checks run so far, in order. The LAST step is the blocking or
  /// cannot-tell finding when [reachable] is not true.
  final List<ReasonStep> ladder;

  final String from;
  final String to;

  /// The question as the user asked it - echoed at the top of [toText], never
  /// re-parsed.
  final String target;

  /// A device-console command that confirms the verdict, when one applies.
  final String? verifyCommand;

  const ReachabilityVerdict({
    required this.reachable,
    required this.ladder,
    required this.from,
    required this.to,
    required this.target,
    this.verifyCommand,
  });

  /// Fix-oriented next actions. For a blocking verdict these are the fixes
  /// of the step that stopped the ladder; for a reachable verdict, the one
  /// test that confirms it on the device.
  List<String> get quickReplies {
    if (reachable == true) {
      return verifyCommand == null
          ? const []
          : ['Ping $to from $from to confirm'];
    }
    for (final s in ladder.reversed) {
      if (s.fixes.isNotEmpty) return List<String>.of(s.fixes);
    }
    return const [];
  }

  /// The ladder, in the corpus answer style: numbered one-line checks, then
  /// the blocking reason with its fix next to it, then a verification
  /// command where the plan supports one.
  String toText() {
    final sb = StringBuffer();
    final ask = target.trim();
    if (ask.isNotEmpty) sb.writeln('Q: $ask');
    if (reachable == true) {
      sb.write('$from -> $to looks reachable in this plan, checked step by '
          'step:');
    } else if (reachable == false) {
      sb.write('Why $from cannot reach $to - walked against the plan:');
    } else {
      sb.write('Cannot tell from the plan whether $from reaches $to:');
    }
    for (var i = 0; i < ladder.length; i++) {
      final s = ladder[i];
      final flag = s.blocked
          ? 'BLOCKED - '
          : (s.cannotTell ? 'CANNOT TELL - ' : '');
      sb.write('\n${i + 1}. ${s.check}: $flag${s.detail}');
      if (s.blocked) {
        if (s.fixes.isNotEmpty) sb.write('\n   Fix: ${s.fixes.join('; ')}.');
        if (s.command != null) {
          sb.write('\n   Verify on the device: `${s.command}`.');
        }
      }
    }
    if (reachable == true && verifyCommand != null) {
      sb.write('\nConfirm on the device: `$verifyCommand` - the first reply '
          'may wait on ARP, run it twice.');
    } else if (reachable != true) {
      final replies = quickReplies;
      if (replies.isNotEmpty) {
        sb.write('\nSay one of these and I will walk the plan again: '
            '${replies.join(' | ')}.');
      }
    }
    return sb.toString();
  }
}

/// The reasoner proper: one entry point that walks the plan.
class TopologyReasoner {
  const TopologyReasoner._();

  /// Device kinds that can route between subnets in a plan of this app. A
  /// firewall (ASA) carries addresses in two subnets and forwards between
  /// them just as a router does, so it counts as a routing hop - the plan
  /// proves it by holding its addresses.
  static const Set<String> _routingCapable = {'router', 'firewall'};

  /// Kinds whose ports only bridge frames (the same set NetLink treats as
  /// switch-shaped, which is private there): they forward at layer 2 and
  /// route at none.
  static const Set<String> _layer2 = {
    'switch', 'hub', 'bridge', 'cloud', 'modem', 'wlc',
  };

  /// Kinds with serial interfaces a serial cable can terminate on. A PC or a
  /// 2960 switch has none, so a serial link to one cannot come up.
  static const Set<String> _serialCapable = {'router', 'firewall'};

  /// Routing the plan can declare. 'static' IS routing intent: it is what
  /// the plan's routing field says, and the adapters materialize it as one
  /// `ip route` per remote LAN (CiscoAdapter._renderStaticRoutes). What does
  /// NOT count is 'none'/empty - the plan then declares no routing at all,
  /// the same reading DesignReview gives it.
  static const Set<String> _routingKinds = {
    'static', 'ospf', 'eigrp', 'bgp', 'rip',
  };

  /// Walk the plan's own graph for one reachability question and return the
  /// check ladder, stopping at the first blocking finding (the steps run so
  /// far stay in the ladder as proof of what already held).
  ///
  /// [from]/[to] are device names; exact (case-insensitive) matches are used
  /// as-is and anything else goes through the same resolver the question
  /// parser uses. [target] is the user's question text, echoed in the answer.
  static ReachabilityVerdict explain({
    required NetworkIntent plan,
    required String from,
    required String to,
    required String target,
  }) {
    final resolvedFrom = ReachabilityQuestion._resolveDevice(from, plan);
    final resolvedTo = ReachabilityQuestion._resolveDevice(to, plan);

    // 1. Same device named twice. The question collapses to one device, and
    //    no network path is exercised - the plan cannot support an answer
    //    about "reachability" between a thing and itself.
    if (resolvedFrom.name != null && resolvedFrom.name == resolvedTo.name) {
      return ReachabilityVerdict(
        reachable: false,
        ladder: [
          ReasonStep(
            check: 'Same device',
            blocked: true,
            detail: '${resolvedFrom.name} and ${resolvedTo.name} are the '
                'same device - a ping to itself never crosses the network, '
                'so there is no path to reason about.',
            fixes: ['Name two different devices from the plan'],
          ),
        ],
        from: resolvedFrom.name!,
        to: resolvedTo.name!,
        target: target,
      );
    }

    // 2. Both devices exist. The question parser guarantees this; kept as a
    //    ladder step so a direct explain() call fails closed and visibly.
    if (resolvedFrom.name == null || resolvedTo.name == null) {
      final missing = resolvedFrom.name == null ? from : to;
      final failure = resolvedFrom.name == null
          ? resolvedFrom.failure
          : resolvedTo.failure;
      return ReachabilityVerdict(
        reachable: null,
        ladder: [
          ReasonStep(
            check: 'Devices',
            cannotTell: true,
            detail: 'Cannot tell from the plan: '
                "${failure ?? "no device named '$missing' in this plan"}.",
            fixes: ['Check the device names against the plan'],
          ),
        ],
        from: from,
        to: to,
        target: target,
      );
    }

    final nodeA = _nodeOf(plan, resolvedFrom.name!)!;
    final nodeB = _nodeOf(plan, resolvedTo.name!)!;
    final steps = <ReasonStep>[];

    // 3. Connectivity path: breadth-first over the plan's links. Switches,
    //    hubs and routers are all walkable hops - the BFS asks "is there a
    //    cable path at all", not "would every hop forward this packet"; the
    //    later steps answer that.
    final path = _walk(plan, nodeA.name, nodeB.name);
    if (path == null) {
      steps.add(ReasonStep(
        check: 'Link',
        blocked: true,
        detail: '${nodeA.name} and ${nodeB.name} are not cabled together in '
            'this plan - nothing connects them, so there is no path to walk.',
        fixes: [
          'Cable ${nodeA.name} and ${nodeB.name} together directly or '
              'through a switch',
        ],
      ));
      return _verdict(false, steps, nodeA, nodeB, target, null);
    }
    steps.add(ReasonStep(
      check: 'Link',
      detail: '${_renderPath(path)} - a cabled path exists.',
    ));

    // 4. End-device addressing: IP + mask on both ends, read from the plan's
    //    own addressing rows (the same rows Desktop > IP Configuration is
    //    filled from).
    final addrA = _endpointAddress(plan, nodeA);
    if (addrA.cidr == null) {
      return _addressingStop(steps, nodeA, addrA, nodeA, nodeB, target);
    }
    steps.add(ReasonStep(
      check: 'Addressing',
      detail: '${nodeA.name} is ${addrA.cidr}'
          '${addrA.iface == null ? '' : ' on ${addrA.iface}'}.',
    ));
    final addrB = _endpointAddress(plan, nodeB);
    if (addrB.cidr == null) {
      return _addressingStop(steps, nodeB, addrB, nodeA, nodeB, target);
    }
    steps.add(ReasonStep(
      check: 'Addressing',
      detail: '${nodeB.name} is ${addrB.cidr}'
          '${addrB.iface == null ? '' : ' on ${addrB.iface}'}.',
    ));

    // 5. Same subnet, via each end's OWN mask (masks can disagree; a
    //    mismatched mask is itself the fault this comparison exposes).
    final sameSubnet = NetworkTools.sameSubnet(addrA.cidr!, addrB.cidr!);
    final infoA = NetworkTools.subnet(addrA.cidr!);
    final infoB = NetworkTools.subnet(addrB.cidr!);
    final netA =
        infoA == null ? addrA.cidr! : '${infoA.network}/${infoA.prefix}';
    final netB =
        infoB == null ? addrB.cidr! : '${infoB.network}/${infoB.prefix}';
    final routersOnPath = path.nodes
        .map((n) => _nodeOf(plan, n))
        .whereType<NetNode>()
        .where((n) => _routingCapable.contains(n.type))
        .map((n) => n.name)
        .toList();
    if (sameSubnet) {
      steps.add(ReasonStep(
        check: 'Subnet',
        detail: '${nodeA.name} ($netA) and ${nodeB.name} ($netB) are in the '
            'same subnet - no routing is needed.',
      ));
    } else if (routersOnPath.isEmpty) {
      // Different subnets with only switches between them: a layer-2 device
      // cannot route, and no amount of addressing fixes a missing router.
      steps.add(ReasonStep(
        check: 'Subnet',
        blocked: true,
        detail: '${nodeA.name} is in $netA and ${nodeB.name} is in $netB - '
            'different subnets, but the path between them never crosses a '
            'router: a layer-2 switch cannot route between $netA and $netB.',
        fixes: [
          'Add a router between the two subnets',
          'Put ${nodeA.name} and ${nodeB.name} in the same subnet',
        ],
      ));
      return _verdict(false, steps, nodeA, nodeB, target, null);
    } else {
      steps.add(ReasonStep(
        check: 'Subnet',
        detail: '${nodeA.name} is in $netA and ${nodeB.name} is in $netB - '
            'different subnets, and ${routersOnPath.join(' and ')} '
            '${routersOnPath.length == 1 ? 'is' : 'are'} on the path to '
            'route between them.',
      ));
    }

    // The one test that confirms the whole ladder on the device, whichever
    // way the remaining checks go.
    final confirmCommand = 'ping ${_ipOf(addrB.cidr!)} from ${nodeA.name}';

    // 6. Gateways - only when traffic must leave the subnet (same-subnet
    //    traffic ARPs directly and never asks a gateway). Router and
    //    firewall ends are skipped: they route from their own interfaces and
    //    carry no default gateway.
    if (!sameSubnet) {
      final checkA = _gatewayCheck(
        plan: plan,
        path: path,
        end: nodeA,
        cidr: addrA.cidr!,
        net: netA,
        fromEnd: true,
      );
      steps.add(checkA);
      if (!checkA.ok) {
        return _verdict(
          checkA.blocked ? false : null,
          steps,
          nodeA,
          nodeB,
          target,
          null,
        );
      }
      final checkB = _gatewayCheck(
        plan: plan,
        path: path,
        end: nodeB,
        cidr: addrB.cidr!,
        net: netB,
        fromEnd: false,
      );
      steps.add(checkB);
      if (!checkB.ok) {
        return _verdict(
          checkB.blocked ? false : null,
          steps,
          nodeA,
          nodeB,
          target,
          null,
        );
      }
    }

    // 7. Duplicate addresses anywhere on the path - the fault that makes a
    //    host answer ARP that belongs to another, intermittently and only
    //    for the duplicated pair.
    final pathKeys = path.nodes.map((n) => n.toLowerCase()).toSet();
    final pathInterfaces = [
      for (final row in plan.addressing)
        if (pathKeys.contains(row.node.toLowerCase()))
          {'node': row.node, 'iface': row.iface, 'ipCidr': row.ipCidr},
    ];
    final dups = NetworkTools.duplicateAddresses(pathInterfaces);
    if (dups.isNotEmpty) {
      final first = dups.first;
      final users = (first['usedBy'] as List).join(' and ');
      steps.add(ReasonStep(
        check: 'Duplicates',
        blocked: true,
        detail: 'Address ${first['address']} is used more than once on the '
            'path - $users - so the second one answers ARP that belongs to '
            'the first.',
        fixes: ['Give one of the duplicated devices a different address'],
      ));
      return _verdict(false, steps, nodeA, nodeB, target, null);
    }
    steps.add(const ReasonStep(
      check: 'Duplicates',
      detail: 'No address on the path is used twice.',
    ));

    // 8. Routing - only when the pings must cross subnets, which is exactly
    //    when a router on the path needs to know where the far side lives.
    if (!sameSubnet) {
      final routing = plan.routing.trim().toLowerCase();
      if (_routingKinds.contains(routing)) {
        final note = routing == 'static'
            ? 'the plan uses static routing - one `ip route` per remote LAN '
                'is part of the build'
            : 'the plan runs ${routing.toUpperCase()} between the routers';
        steps.add(ReasonStep(
          check: 'Routing',
          detail: '$note (`show ip route` on ${routersOnPath.first} should '
              'list the far subnet).',
          command: 'show ip route',
        ));
      } else if (plan.security.interVlanRouting) {
        // Router-on-a-stick: the plan routes between the VLANs through one
        // dot1Q sub-interface set - that IS the routing intent, spelled in
        // the security block, even when the routing field says none.
        steps.add(ReasonStep(
          check: 'Routing',
          detail: 'the plan routes between the VLANs on '
              '${routersOnPath.first} (router-on-a-stick), so no separate '
              'routing protocol is needed.',
        ));
      } else {
        final label = routing.isEmpty
            ? 'no routing at all'
            : 'no routing the plan declares (routing: ${plan.routing})';
        steps.add(ReasonStep(
          check: 'Routing',
          blocked: true,
          detail: 'The path crosses ${routersOnPath.join(' and ')} but the '
              'plan carries $label - the last router would answer '
              '"destination host unreachable".',
          command: 'show ip route',
          fixes: _routingFixes(routersOnPath),
        ));
        return _verdict(false, steps, nodeA, nodeB, target, null);
      }
    }

    // 9. Cable sanity, only for the kinds the plan states. A serial cable
    //    needs serial-capable ends: the transit link a brief called serial,
    //    or a router interface named s0/x, must not land on a PC or a switch
    //    - those have no serial port to terminate the cable.
    final serialLinks = path.links
        .where((l) =>
            l.isSerial || (l.cable ?? '').toLowerCase().contains('serial'))
        .toList();
    if (serialLinks.isEmpty) {
      steps.add(const ReasonStep(
        check: 'Cables',
        detail: 'No serial or special cable kinds on the path - copper '
            'Ethernet throughout.',
      ));
    } else {
      for (final l in serialLinks) {
        final offender = _serialOffender(plan, l);
        if (offender != null) {
          steps.add(ReasonStep(
            check: 'Cables',
            blocked: true,
            detail: 'The link ${l.a} ${l.aIf} -<-> ${l.b} ${l.bIf} is wired '
                'as serial, but $offender has no serial port - serial needs '
                'serial-capable ends (routers, firewalls).',
            fixes: ['Use an Ethernet cable between ${l.a} and ${l.b}'],
          ));
          return _verdict(false, steps, nodeA, nodeB, target, null);
        }
      }
      steps.add(ReasonStep(
        check: 'Cables',
        detail: 'Serial link(s) on the path terminate on serial-capable '
            'ends: ${serialLinks.map((l) => '${l.a}-${l.b}').join(', ')}.',
      ));
    }

    // Every check the plan supports has passed - the ladder IS the proof.
    return _verdict(true, steps, nodeA, nodeB, target, confirmCommand);
  }

  // --- internals -----------------------------------------------------------

  /// The verdict shape every stop returns, so the caller sees one form.
  static ReachabilityVerdict _verdict(
    bool? reachable,
    List<ReasonStep> steps,
    NetNode from,
    NetNode to,
    String target,
    String? verifyCommand,
  ) =>
      ReachabilityVerdict(
        reachable: reachable,
        ladder: steps,
        from: from.name,
        to: to.name,
        target: target,
        verifyCommand: verifyCommand,
      );

  /// The step-4 stop: a missing address on an end device is a deterministic
  /// fault (the file would ship unconfigured); a switch with no IP config is
  /// a fail-closed gap the plan genuinely cannot answer.
  static ReachabilityVerdict _addressingStop(
    List<ReasonStep> steps,
    NetNode failing,
    ({String? cidr, String? iface, String? problem, bool cannotTell}) addr,
    NetNode from,
    NetNode to,
    String target,
  ) {
    steps.add(ReasonStep(
      check: 'Addressing',
      blocked: !addr.cannotTell,
      cannotTell: addr.cannotTell,
      detail: addr.problem!,
      // A missing IP has a concrete fix; a layer-2 device with no IP config
      // is not fixable in the plan, so no fix is offered.
      fixes: addr.cannotTell
          ? const []
          : ['Add an IP address for ${failing.name} in the plan'],
    ));
    return _verdict(
      addr.cannotTell ? null : false,
      steps,
      from,
      to,
      target,
      null,
    );
  }

  /// The plan's address for one end of the question, or the reason the plan
  /// cannot supply one. Rows are matched case-insensitively; a row whose
  /// address is 0.0.0.0 or unparsable counts as no address (0.0.0.0 is the
  /// placeholder the adapters leave for an unconfigured device), and an
  /// address without a mask is a fail-closed gap - the subnet cannot be
  /// computed from it.
  static ({String? cidr, String? iface, String? problem, bool cannotTell})
      _endpointAddress(NetworkIntent plan, NetNode node) {
    final rows = plan.addressing
        .where((r) => r.node.toLowerCase() == node.name.toLowerCase())
        .toList();
    for (final row in rows) {
      final ip = row.ipCidr.split('/').first.trim();
      if (ip.isEmpty || ip == '0.0.0.0') continue;
      if (NetworkTools.parseCidr(row.ipCidr) == null) {
        return (
          cidr: null,
          iface: null,
          problem: '${node.name} has ${row.ipCidr} in the plan, which is not '
              'a valid address/mask pair - cannot tell its subnet.',
          cannotTell: true,
        );
      }
      return (
        cidr: row.ipCidr,
        iface: row.iface,
        problem: null,
        cannotTell: false,
      );
    }
    if (_layer2.contains(node.type)) {
      return (
        cidr: null,
        iface: null,
        problem: '${node.name} is a ${node.type} and the plan carries no IP '
            'config for it - a ping from it cannot be judged from the plan.',
        cannotTell: true,
      );
    }
    if (deviceKindOf(node.type)?.ipConfig ?? false) {
      return (
        cidr: null,
        iface: null,
        problem: '${node.name} has no IP address in the plan - the file '
            'would ship unconfigured.',
        cannotTell: false,
      );
    }
    return (
      cidr: null,
      iface: null,
      problem: '${node.name} has no interface address in the plan - it could '
          'not send or forward anything as it stands.',
      cannotTell: false,
    );
  }

  /// The gateway check for one end. Returns the ok step, or the blocking /
  /// cannot-tell step that stops the ladder. The gateway is not stored per
  /// endpoint - it is derived from the plan the same way the adapter derives
  /// it when it fills Desktop > IP Configuration.
  static ReasonStep _gatewayCheck({
    required NetworkIntent plan,
    required _Path path,
    required NetNode end,
    required String cidr,
    required String net,
    required bool fromEnd,
  }) {
    if (_routingCapable.contains(end.type)) {
      return ReasonStep(
        check: 'Gateway',
        detail: '${end.name} is a ${end.type} - it routes from its own '
            'interfaces, so it needs no gateway.',
      );
    }
    final gw = _deriveGateway(plan, path, end.name, cidr, fromEnd: fromEnd);
    if (gw.problem != null) {
      return ReasonStep(
        check: 'Gateway',
        blocked: true,
        detail: gw.problem!,
        fixes: gw.fixes,
      );
    }
    final verdict = NetworkTools.checkGateway(hostCidr: cidr, gateway: gw.ip!);
    if (verdict['ok'] != true) {
      final gwCidr = gw.gwCidr;
      final gwInfo = gwCidr == null ? null : NetworkTools.subnet(gwCidr);
      return ReasonStep(
        check: 'Gateway',
        blocked: true,
        detail: "${end.name}'s gateway would be ${gw.ip} (${gw.owner} "
            '${gw.iface}), but ${verdict['reason']} - a gateway must live '
            "in the host's own subnet.",
        command: 'ping ${gw.ip}',
        fixes: [
          "Put ${gw.owner}'s address on ${gw.iface} inside $net",
          if (gwInfo != null)
            'Move ${end.name} into ${gwInfo.network}/${gwInfo.prefix}',
        ],
      );
    }
    return ReasonStep(
      check: 'Gateway',
      detail: "${end.name}'s gateway is ${gw.ip} (${gw.owner} "
          '${gw.iface}) - inside its own subnet $net.',
    );
  }

  /// The gateway the plan itself offers one end: walk device -> first hop ->
  /// router, and read the router interface address on that link. Falls back
  /// to a dot1Q sub-interface in the device's subnet (router-on-a-stick),
  /// where the physical trunk interface has no address of its own.
  static ({
    String? ip,
    String? owner,
    String? iface,
    String? gwCidr,
    String? problem,
    List<String> fixes,
  }) _deriveGateway(
    NetworkIntent plan,
    _Path path,
    String device,
    String deviceCidr, {
    required bool fromEnd,
  }) {
    final deviceIdx = fromEnd ? 0 : path.nodes.length - 1;
    final firstLink = fromEnd ? path.links.first : path.links.last;
    final deviceKey = path.nodes[deviceIdx].toLowerCase();
    final neighborName = firstLink.a.toLowerCase() == deviceKey
        ? firstLink.b
        : firstLink.a;
    final neighbor = _nodeOf(plan, neighborName);
    final deviceIp = deviceCidr.split('/').first;

    if (neighbor == null) {
      return _noGateway(
        '$device must leave its subnet but its first hop $neighborName is '
        'not a device of this plan - there is no gateway to point at.',
        ['Check the plan\'s links around $device'],
      );
    }
    if (!_routingCapable.contains(neighbor.type) &&
        !_layer2.contains(neighbor.type)) {
      return _noGateway(
        '$device must leave its subnet but its first hop is '
        '${neighbor.name}, which is neither a switch nor a router in this '
        'plan - there is no gateway to point at.',
        ['Put a switch or a router between the two subnets'],
      );
    }

    // The router whose interface address becomes the gateway, and the
    // interface of its that faces the device (directly, or through the
    // switch in between).
    final router = _routingCapable.contains(neighbor.type)
        ? (
            name: neighbor.name,
            iface: firstLink.a.toLowerCase() == neighborName.toLowerCase()
                ? firstLink.aIf
                : firstLink.bIf,
          )
        : _routerBehindSwitch(plan, path, neighborName, fromEnd);
    if (router == null) {
      return _noGateway(
        '$device must leave its subnet but the first hop is '
        '${neighbor.name} and no router sits behind it in the plan - there '
        'is no gateway to point at.',
        ['Add a router behind ${neighbor.name}'],
      );
    }

    // The exact interface row is what the adapter would type as the gateway.
    // When the physical interface carries no row - a router-on-a-stick
    // trunk - the dot1Q sub-interface whose subnet holds the device's
    // address is the gateway instead.
    final exact = plan.addressing
        .where((r) =>
            r.node.toLowerCase() == router.name.toLowerCase() &&
            r.iface.toLowerCase() == router.iface.toLowerCase())
        .toList();
    if (exact.isNotEmpty) {
      final ip = exact.first.ipCidr.split('/').first.trim();
      if (ip != '0.0.0.0' &&
          NetworkTools.parseCidr(exact.first.ipCidr) != null) {
        return (
          ip: ip,
          owner: router.name,
          iface: router.iface,
          gwCidr: exact.first.ipCidr,
          problem: null,
          fixes: const [],
        );
      }
    }
    final subs = plan.addressing
        .where((r) =>
            r.node.toLowerCase() == router.name.toLowerCase() &&
            r.iface
                .toLowerCase()
                .startsWith('${router.iface.toLowerCase()}.') &&
            NetworkTools.contains(r.ipCidr, deviceIp))
        .toList();
    if (subs.isNotEmpty) {
      return (
        ip: subs.first.ipCidr.split('/').first,
        owner: router.name,
        iface: subs.first.iface,
        gwCidr: subs.first.ipCidr,
        problem: null,
        fixes: const [],
      );
    }
    return _noGateway(
      '$device must leave its subnet but ${router.name} has no address on '
      '${router.iface} in the plan - there is no gateway for it to point at.',
      ['Give ${router.name} an address on ${router.iface}'],
    );
  }

  static ({
    String? ip,
    String? owner,
    String? iface,
    String? gwCidr,
    String? problem,
    List<String> fixes,
  }) _noGateway(String problem, List<String> fixes) => (
        ip: null,
        owner: null,
        iface: null,
        gwCidr: null,
        problem: problem,
        fixes: fixes,
      );

  /// The router one hop behind a layer-2 first hop. The path's own next node
  /// is tried first (that is the walk the packets take); anything else falls
  /// back to the first router cabled to that switch, in plan order - the
  /// deterministic choice the adapter's gateway walk also lands on.
  static ({String name, String iface})? _routerBehindSwitch(
    NetworkIntent plan,
    _Path path,
    String switchName,
    bool fromEnd,
  ) {
    final switchKey = switchName.toLowerCase();
    if (path.nodes.length >= 3) {
      // links[i] joins nodes[i] and nodes[i+1], so the link between the node
      // one hop beyond the switch and the switch itself sits at the SMALLER
      // of the two indices - nodes.length - 3 for the far end, never
      // links.length - 3 (that is one link too early).
      final nextIdx = fromEnd ? 2 : path.nodes.length - 3;
      final linkIdx = fromEnd ? 1 : path.nodes.length - 3;
      final next = _nodeOf(plan, path.nodes[nextIdx]);
      if (next != null && _routingCapable.contains(next.type)) {
        final link = path.links[linkIdx];
        return (
          name: next.name,
          iface: link.a.toLowerCase() == next.name.toLowerCase()
              ? link.aIf
              : link.bIf,
        );
      }
    }
    for (final l in plan.links) {
      final other = l.a.toLowerCase() == switchKey
          ? l.b
          : (l.b.toLowerCase() == switchKey ? l.a : null);
      if (other == null) continue;
      final node = _nodeOf(plan, other);
      if (node == null || !_routingCapable.contains(node.type)) continue;
      return (
        name: node.name,
        iface: l.a.toLowerCase() == node.name.toLowerCase()
            ? l.aIf
            : l.bIf,
      );
    }
    return null;
  }

  /// The routing fixes name the routers actually on the path, so "add OSPF
  /// between R1 and R2" is a sentence the planner can act on, not a generic
  /// nudge.
  static List<String> _routingFixes(List<String> routersOnPath) {
    if (routersOnPath.length >= 2) {
      return [
        'Add OSPF between ${routersOnPath[0]} and ${routersOnPath[1]}',
        'Add a static route',
      ];
    }
    return [
      'Add OSPF for ${routersOnPath.first}',
      'Add a static route',
    ];
  }

  /// The end of a serial link that cannot terminate one, or null when both
  /// ends are serial-capable.
  static String? _serialOffender(NetworkIntent plan, NetLink l) {
    for (final end in [l.a, l.b]) {
      final node = _nodeOf(plan, end);
      if (node != null && !_serialCapable.contains(node.type)) {
        return '${node.name} (${node.type})';
      }
    }
    return null;
  }

  /// Breadth-first path over the plan's links, deterministic by link order.
  /// Every node type is a walkable hop: this asks "cabled at all", and the
  /// ladder's later steps decide whether the hops can actually forward.
  static _Path? _walk(NetworkIntent plan, String from, String to) {
    final adj = <String, List<NetLink>>{};
    for (final l in plan.links) {
      adj.putIfAbsent(l.a.toLowerCase(), () => []).add(l);
      adj.putIfAbsent(l.b.toLowerCase(), () => []).add(l);
    }
    final start = from.toLowerCase();
    final goal = to.toLowerCase();
    final prev = <String, (String, NetLink)>{};
    final seen = <String>{start};
    final queue = <String>[start];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      if (cur == goal) break;
      for (final l in adj[cur] ?? const <NetLink>[]) {
        final other = l.a.toLowerCase() == cur
            ? l.b.toLowerCase()
            : l.a.toLowerCase();
        if (seen.add(other)) {
          prev[other] = (cur, l);
          queue.add(other);
        }
      }
    }
    if (!seen.contains(goal)) return null;
    final nodes = <String>[];
    final links = <NetLink>[];
    var cur = goal;
    while (cur != start) {
      final (parent, link) = prev[cur]!;
      nodes.insert(0, _canonical(plan, cur));
      links.insert(0, link);
      cur = parent;
    }
    nodes.insert(0, _canonical(plan, start));
    return _Path(nodes: nodes, links: links);
  }

  static String _canonical(NetworkIntent plan, String key) {
    for (final n in plan.nodes) {
      if (n.name.toLowerCase() == key) return n.name;
    }
    return key;
  }

  static NetNode? _nodeOf(NetworkIntent plan, String name) {
    for (final n in plan.nodes) {
      if (n.name.toLowerCase() == name.toLowerCase()) return n;
    }
    return null;
  }

  /// "PC1 f0 -<-> SW1 -<-> PC2": the origin names the interface it leaves
  /// on, the hops are plain device names - the shape the corpus answers use.
  static String _renderPath(_Path path) {
    final origin = path.nodes.first;
    final firstLink = path.links.first;
    final iface = firstLink.a.toLowerCase() == origin.toLowerCase()
        ? firstLink.aIf
        : firstLink.bIf;
    final head = iface.isEmpty ? origin : '$origin $iface';
    return '$head -<-> ${path.nodes.skip(1).join(' -<-> ')}';
  }

  static String _ipOf(String cidr) => cidr.split('/').first.trim();
}

/// One walked path: device names end to end, with the link that joins each
/// pair (links[i] joins nodes[i] and nodes[i+1]).
class _Path {
  final List<String> nodes;
  final List<NetLink> links;
  const _Path({required this.nodes, required this.links});
}
