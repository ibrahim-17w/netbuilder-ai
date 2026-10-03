import '../models/network_intent.dart';
import 'network_tools.dart';

/// One thing the review noticed about a design, and how much it matters.
///
/// [severity] is what decides whether a finding is advice or a real gap:
/// [note] is worth reading, [gap] is something the design is missing, and
/// [fault] is something that is actively wrong.
enum DesignSeverity { note, gap, fault }

/// What a review is looking at. Kept separate from the finding so a design can
/// be reviewed the same way whether it is about to be built or has just been.
class DesignFinding {
  final DesignSeverity severity;

  /// The rubric line this came from - 'addressing', 'redundancy',
  /// 'segmentation', 'routing', 'security', 'services', 'structure'.
  final String area;

  /// One sentence a person can act on. Never "consider possibly".
  final String message;

  /// What to do about it, when there is something to do.
  final String fix;

  const DesignFinding(
    this.severity,
    this.area,
    this.message, {
    this.fix = '',
  });
}

/// The verdict on one design.
class DesignReview {
  /// 0-100. Only a design with nothing wrong can reach 100.
  final int score;

  /// 'solid', 'workable', 'thin', or 'unusable' - the headline a person reads
  /// before anything else.
  final String verdict;

  /// The one sentence that says what is most worth fixing.
  final String headline;

  /// Everything the review noticed, worst first.
  final List<DesignFinding> findings;

  /// The rubric lines that scored full marks. The absence of these in the
  /// findings is the whole story of why a design scored what it did, so they
  /// are worth showing rather than hiding.
  final List<String> strengths;

  const DesignReview({
    required this.score,
    required this.verdict,
    required this.headline,
    required this.findings,
    required this.strengths,
  });

  bool get isClean => findings.isEmpty;

  int faultsIn(String area) =>
      findings.where((f) => f.severity == DesignSeverity.fault && f.area == area).length;
}

/// Scans a design the way an experienced engineer would read it: does the
/// addressing actually work, is there enough of the right hardware, is the
/// traffic separated, is the routing proportionate, and is the edge protected.
///
/// Pure Dart and deterministic - the same plan always reviews the same way -
/// so a review can be stored, compared and learned from. It deliberately does
/// NOT block anything: the validator already decides what may be built, and a
/// review that second-guessed a finished build would be a second, worse
/// validator. This one only says what is good and what is missing.
class DesignReviewer {
  const DesignReviewer._();

  /// How many hosts a subnet should carry before a second one is the safer
  /// default. A /24 holds 254, so this only fires on genuinely large labs.
  static const int kLargeLabHosts = 200;

  /// How many routers make a design "has a core" rather than "has a box".
  static const int kRedundantRouters = 2;

  static DesignReview review(NetworkIntent plan) {
    if (plan.nodes.isEmpty) {
      return const DesignReview(
        score: 0,
        verdict: 'unusable',
        headline: 'There is no network here yet.',
        findings: <DesignFinding>[],
        strengths: <String>[],
      );
    }

    final findings = <DesignFinding>[];
    final strengths = <String>[];

    _reviewStructure(plan, findings, strengths);
    _reviewAddressing(plan, findings, strengths);
    _reviewRedundancy(plan, findings, strengths);
    _reviewSegmentation(plan, findings, strengths);
    _reviewRouting(plan, findings, strengths);
    _reviewSecurity(plan, findings, strengths);
    _reviewServices(plan, findings, strengths);

    // Worst first, so the list reads as a to-do list.
    const order = <DesignSeverity, int>{
      DesignSeverity.fault: 0,
      DesignSeverity.gap: 1,
      DesignSeverity.note: 2,
    };
    findings.sort((a, b) {
      final bySeverity = order[a.severity]!.compareTo(order[b.severity]!);
      return bySeverity != 0 ? bySeverity : a.area.compareTo(b.area);
    });

    var score = 100;
    for (final f in findings) {
      switch (f.severity) {
        case DesignSeverity.fault:
          score -= 22;
        case DesignSeverity.gap:
          score -= 9;
        case DesignSeverity.note:
          score -= 2;
      }
    }
    score = score.clamp(0, 100);

    final verdict = score >= 90
        ? 'solid'
        : score >= 70
            ? 'workable'
            : score >= 45
                ? 'thin'
                : 'unusable';
    final faultCount =
        findings.where((f) => f.severity == DesignSeverity.fault).length;
    final headline = faultCount > 0
        ? findings.first.message
        : findings.isEmpty
            ? 'Nothing to fix - this design holds together.'
            : findings.first.message;

    return DesignReview(
      score: score,
      verdict: verdict,
      headline: headline,
      findings: findings,
      strengths: strengths,
    );
  }

  // --- the rubric lines ----------------------------------------------------

  static void _reviewStructure(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final types = plan.nodes.map((n) => n.type.trim().toLowerCase()).toList();
    final hosts = plan.nodes.where(_isHost).length;
    if (hosts > 0 && !types.contains('switch') && !types.contains('router')) {
      findings.add(const DesignFinding(
        DesignSeverity.fault,
        'structure',
        'There are hosts but nothing for them to plug into.',
        fix: 'Add at least one switch.',
      ));
    } else {
      strengths.add('Every host has something to connect through.');
    }

    if (types.contains('cloud') && !types.contains('router')) {
      findings.add(const DesignFinding(
        DesignSeverity.fault,
        'structure',
        'There is an internet connection with no router to route it.',
        fix: 'Add a router between the cloud and the lab.',
      ));
    }

    // A device that nothing is cabled to is drawn on the canvas and does
    // nothing - the single most common way a plan looks finished and is not.
    final connected = <String>{
      for (final l in plan.links) ...[l.a, l.b],
    };
    final orphans = [
      for (final n in plan.nodes)
        if (!connected.contains(n.name)) n.name,
    ];
    if (orphans.isNotEmpty && plan.nodes.length > 1) {
      final shown = orphans.take(4).join(', ');
      final more = orphans.length > 4 ? ' and ${orphans.length - 4} more' : '';
      findings.add(DesignFinding(
        orphans.length > 2 ? DesignSeverity.gap : DesignSeverity.note,
        'structure',
        '$shown$more ${orphans.length == 1 ? 'is' : 'are'} not cabled to '
            'anything.',
        fix: 'Connect them, or take them out of the plan.',
      ));
    }
  }

  static void _reviewAddressing(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    if (plan.addressing.isEmpty) {
      findings.add(const DesignFinding(
        DesignSeverity.fault,
        'addressing',
        'No device has an address.',
        fix: 'Give every interface an address before building.',
      ));
      return;
    }

    final duplicates = NetworkTools.duplicateAddresses(
      <Map<String, dynamic>>[
        for (final a in plan.addressing)
          <String, dynamic>{
            'node': a.node,
            'iface': a.iface,
            'ipCidr': a.ipCidr,
          },
      ],
    );
    final clashes = duplicates.length;
    if (clashes > 0) {
      findings.add(DesignFinding(
        DesignSeverity.fault,
        'addressing',
        '$clashes ${clashes == 1 ? 'address is' : 'addresses are'} used by more '
            'than one device.',
        fix: 'Two devices on one address cannot both be on the network.',
      ));
    } else {
      strengths.add('No two interfaces share an address.');
    }

    // A subnet too small for the devices on it is a design fault that only
    // shows up later as a lab that half-works.
    final perSubnet = <String, ({int prefix, int count})>{};
    for (final a in plan.addressing) {
      final info = NetworkTools.subnet(a.ipCidr);
      if (info == null) continue;
      final existing = perSubnet[info.network];
      perSubnet[info.network] = (
        prefix: info.prefix,
        count: (existing?.count ?? 0) + 1,
      );
    }
    for (final entry in perSubnet.entries) {
      final info = NetworkTools.subnet(
        '${entry.key}/${entry.value.prefix}',
      );
      final capacity = info?.usableHosts ?? 0;
      if (capacity > 0 && entry.value.count > capacity) {
        findings.add(DesignFinding(
          DesignSeverity.fault,
          'addressing',
          '${entry.key} holds ${entry.value.count} devices but only has room '
              'for $capacity.',
          fix: 'Use a larger subnet or split it in two.',
        ));
      }
    }

    final hosts = plan.nodes.where((n) => _isHost(n)).length;
    if (hosts > kLargeLabHosts) {
      final nets = perSubnet.length;
      if (nets < 2) {
        findings.add(DesignFinding(
          DesignSeverity.gap,
          'addressing',
          '$hosts hosts all sit on one subnet.',
          fix: 'Split them across subnets so each site or floor has its own.',
        ));
      } else {
        strengths.add('The lab is split across ${_number(nets)} subnets.');
      }
    }
  }

  static void _reviewRedundancy(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final routers = plan.nodes.where((n) => n.type == 'router').length;
    final hosts = plan.nodes.where((n) => _isHost(n)).length;

    if (routers >= kRedundantRouters) {
      strengths.add('${_number(routers)} routers, so nothing is a single '
          'point of failure.');
      return;
    }
    // One router is the right answer for a small lab. It only becomes a gap
    // once the lab is big enough that losing it hurts.
    if (hosts > 50) {
      findings.add(DesignFinding(
        DesignSeverity.gap,
        'redundancy',
        'One router carries $hosts hosts, so it is a single point of failure.',
        fix: 'A second router on a different path removes that risk.',
      ));
    } else {
      strengths.add('One router is the right weight for this size of lab.');
    }

    // A core with two routers but only ever one link between them is a
    // failover that cannot actually fail over.
    for (final name in plan.nodes
        .where((n) => n.type == 'router')
        .map((n) => n.name)) {
      final paths = <String>{};
      for (final l in plan.links) {
        if (l.a == name) paths.add(l.b);
        if (l.b == name) paths.add(l.a);
      }
      if (routers >= kRedundantRouters && paths.length < 2) {
        findings.add(DesignFinding(
          DesignSeverity.note,
          'redundancy',
          '$name only has one way out, so the second router cannot take over.',
          fix: 'Link the two routers together, or through a shared switch.',
        ));
      }
    }
  }

  static void _reviewSegmentation(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final types = plan.nodes.map((n) => n.type.trim().toLowerCase()).toSet();
    final switches = plan.nodes.where((n) => n.type == 'switch').length;

    if (plan.vlans.isNotEmpty) {
      strengths.add('Traffic is split into ${_number(plan.vlans.length)} VLANs.');
      // VLANs only pay off if something routes between them.
      final hasRouter = types.contains('router');
      if (plan.vlans.length > 1 && !hasRouter) {
        findings.add(const DesignFinding(
          DesignSeverity.fault,
          'segmentation',
          'There are several VLANs but nothing routing between them.',
          fix: 'Add a router or a layer 3 switch to move traffic between '
              'them.',
        ));
      }
      return;
    }

    // A lab with both servers and phones, or guests and staff, is the classic
    // case where one flat subnet stops being the right answer.
    final mixed =
        (types.contains('server') && types.contains('phone')) ||
            (types.contains('phone') && types.contains('wireless')) ||
            (switches >= 2 && plan.nodes.where(_isHost).length > 20);
    if (mixed) {
      findings.add(const DesignFinding(
        DesignSeverity.gap,
        'segmentation',
        'Servers, phones and hosts all share one subnet.',
        fix: 'VLANs keep voice, servers and user traffic apart, which is what '
            'makes a busy network behave.',
      ));
    } else {
      strengths.add('One flat subnet is right for a lab this simple.');
    }
  }

  static void _reviewRouting(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final routers = plan.nodes.where((n) => n.type == 'router').length;
    final routing = plan.routing.trim().toLowerCase();
    final thirdOctetSeen = plan.addressing
        .map((a) => NetworkTools.subnet(a.ipCidr)?.network ?? '')
        .where((n) => n.isNotEmpty)
        .toSet()
        .length;

    if (routers < 2) {
      strengths.add('One router means routing stays simple.');
      if (thirdOctetSeen > 1 && routing != 'static') {
        findings.add(const DesignFinding(
          DesignSeverity.note,
          'routing',
          'There is more than one subnet but no second router.',
          fix: 'Static routes on one router are fine here - just make sure '
              'each subnet has a way back.',
        ));
      }
      return;
    }

    if (routing == 'ospf' || routing == 'eigrp') {
      strengths.add('Two or more routers using $routing, which is the right '
          'tool for more than one path.');
    } else if (routing == 'static') {
      findings.add(DesignFinding(
        DesignSeverity.note,
        'routing',
        '$routers routers are connected by static routes.',
        fix: '$routing is fine for two routers. Above that, a dynamic protocol '
            'is what keeps the routes correct.',
      ));
    } else if (routing == 'bgp') {
      strengths.add('BGP is running, which fits an internet-scale design.');
    } else {
      findings.add(DesignFinding(
        DesignSeverity.fault,
        'routing',
        '$routers routers are connected but no routing protocol was asked for.',
        fix: 'Say how they should learn each other - OSPF or static routes.',
      ));
    }
  }

  static void _reviewSecurity(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final hasCloud = plan.nodes.any((n) => n.type == 'cloud');
    final hasFirewall = plan.nodes.any((n) => n.type == 'firewall');
    final hosts = plan.nodes.where((n) => _isHost(n)).length;

    if (hasCloud && !hasFirewall && hosts > 10) {
      findings.add(const DesignFinding(
        DesignSeverity.gap,
        'security',
        'The lab reaches the internet with no firewall in the path.',
        fix: 'A firewall between the cloud and the first router is the '
            'difference between a lab and an open door.',
      ));
    } else if (hasCloud && hasFirewall) {
      strengths.add('A firewall sits between the lab and the internet.');
    }

    if (plan.security.aaa) {
      strengths.add('Authentication is centralized rather than local.');
    } else if (plan.nodes.any((n) => n.type == 'router') && hosts > 25) {
      findings.add(const DesignFinding(
        DesignSeverity.gap,
        'security',
        'There is no central authentication on a lab this size.',
        fix: 'AAA with a TACACS+ or RADIUS server means one place to add or '
            'remove a user.',
      ));
    }

    if (plan.security.portSecurity) {
      strengths.add('Switch ports are locked down with port security.');
    }
  }

  static void _reviewServices(
    NetworkIntent plan,
    List<DesignFinding> findings,
    List<String> strengths,
  ) {
    final roles = <String>{
      for (final n in plan.nodes) ...n.services.map((s) => s.trim().toLowerCase()),
    };
    final hosts = plan.nodes.where((n) => _isHost(n)).length;

    if (hosts > 0 && !roles.contains('dhcp')) {
      findings.add(DesignFinding(
        hosts > 20 ? DesignSeverity.gap : DesignSeverity.note,
        'services',
        '$hosts hosts have no way to get an address automatically.',
        fix: 'A DHCP server saves addressing every device by hand.',
      ));
    } else if (roles.contains('dhcp')) {
      strengths.add('Addresses are handed out by DHCP, not typed by hand.');
    }

    if (hosts > 5 && !roles.contains('dns')) {
      findings.add(const DesignFinding(
        DesignSeverity.gap,
        'services',
        'There is no DNS server, so nothing resolves by name.',
        fix: 'Even a small lab wants one - it is what makes hosts addressable '
            'in a way a person can read.',
      ));
    } else if (roles.contains('dns')) {
      strengths.add('Names resolve through a server in the lab.');
    }
  }

  // --- helpers -------------------------------------------------------------

  static bool _isHost(NetNode node) {
    const hosts = {
      'pc', 'laptop', 'tablet', 'phone', 'printer', 'camera', 'iot', 'tv',
      'smartphone', 'wireless',
    };
    return hosts.contains(node.type.trim().toLowerCase());
  }

  static String _number(int value) =>
      value.toString().replaceAllMapped(
            RegExp(r'^1$'),
            (_) => 'one',
          );
}