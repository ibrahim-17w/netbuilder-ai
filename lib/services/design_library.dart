import '../models/network_intent.dart';
import 'design_review.dart';
import 'domain_vocabulary.dart';

/// One change a design wants to make to a plan.
class DesignChange {
  /// 'device', 'vlan', 'routing', 'security' or 'note'.
  final String kind;

  /// The device type to add, the VLAN id, the routing protocol, or empty.
  final String value;

  /// What the change is for, in one line.
  final String why;

  const DesignChange(this.kind, this.value, this.why);
}

/// One named architecture the app knows how to build.
///
/// A design is NOT applied silently. It is matched against the brief, offered
/// with the reasons it matched, and only applied when the user asks - the same
/// rule the rest of the planner follows. What a design carries is the part a
/// parser cannot infer from a sentence: the extra device a redundant core
/// needs, the VLAN a DMZ assumes, the routing protocol a two-site lab should
/// be running.
class NetworkDesign {
  final String id;
  final String name;

  /// One sentence: what this design IS.
  final String blurb;

  /// What it assumes about the brief, as words a person would use. Matched
  /// through [DomainVocabulary], so "HQ" and "headquarters" both reach here.
  final List<String> wantsSiteKinds;

  /// The lab sizes this design makes sense at. A RANGE, not a list of exact
  /// counts - a design that fits "up to fifteen devices" has to fit twelve
  /// too, and reading the bound as an exact count quietly offered nothing to
  /// almost every lab.
  final int minHosts;
  final int maxHosts;

  /// Host counts this design is wrong for, even if something else matches.
  final List<int> rejectsHostCounts;

  /// The changes applying it makes.
  final List<DesignChange> changes;

  /// What a design of this shape usually scores, used to put the best-fitting
  /// design first without building every one of them to find out.
  final int expectedScore;

  const NetworkDesign({
    required this.id,
    required this.name,
    required this.blurb,
    this.wantsSiteKinds = const <String>[],
    this.minHosts = 0,
    this.maxHosts = 1000000,
    this.rejectsHostCounts = const <int>[],
    this.changes = const <DesignChange>[],
    this.expectedScore = 70,
  });

  bool get isEmpty => changes.isEmpty;

  /// The host count this design is built for, in words a person reads.
  String get sizeLabel {
    if (minHosts == 0 && maxHosts >= 1000000) return 'any size of lab';
    if (maxHosts >= 1000000) return '$minHosts+ devices';
    if (minHosts <= 1) return 'up to $maxHosts devices';
    return '$minHosts-$maxHosts devices';
  }
}

/// A design matched to a brief, with why it matched.
class DesignSuggestion {
  final NetworkDesign design;

  /// Higher is a better fit. Zero means it does not apply at all.
  final int fit;

  /// The reasons, in plain words - so the offer can explain itself.
  final List<String> reasons;

  const DesignSuggestion(this.design, this.fit, this.reasons);
}

/// The catalog of designs, and the rule that chooses between them.
///
/// Fitting is deliberately explainable and deterministic: a design earns fit
/// from what the brief actually said (site kind, size, whether it has an
/// internet edge, how many routers) and never from a model. A wrong design
/// offered confidently is worse than no design offered at all.
class DesignLibrary {
  const DesignLibrary._();

  /// Every design the app can build.
  static const List<NetworkDesign> all = <NetworkDesign>[
    NetworkDesign(
      id: 'soho',
      name: 'Small office, one box',
      blurb: 'A wireless router does routing, DHCP and wireless by itself. '
          'Right until it stops being enough.',
      wantsSiteKinds: <String>['soho'],
      minHosts: 1, maxHosts: 15,
      changes: <DesignChange>[
        DesignChange('device', 'wireless-router',
            'Routes, hands out addresses and broadcasts a wireless network'),
      ],
      expectedScore: 70,
    ),
    NetworkDesign(
      id: 'flat-lab',
      name: 'Flat lab',
      blurb: 'One router, one switch, one subnet. The simplest thing that '
          'works, and the right starting point.',
      minHosts: 1, maxHosts: 30,
      changes: <DesignChange>[
        DesignChange('device', 'switch', 'Gives the hosts a place to plug in'),
        DesignChange('device', 'server', 'Carries DHCP and DNS for the lab'),
      ],
      expectedScore: 78,
    ),
    NetworkDesign(
      id: 'router-on-a-stick',
      name: 'Router on a stick',
      blurb: 'One router with a sub-interface per VLAN, so voice, servers and '
          'users share a cable but not a subnet.',
      wantsSiteKinds: <String>['classroom', 'lab', 'retail', 'healthcare'],
      minHosts: 5, maxHosts: 60,
      changes: <DesignChange>[
        DesignChange('vlan', '10', 'User data'),
        DesignChange('vlan', '20', 'Voice, so calls keep their own subnet'),
        DesignChange('vlan', '30', 'Servers, kept off the user network'),
        DesignChange('note', 'sub-interface',
            'The router needs one sub-interface per VLAN on the trunk link'),
      ],
      expectedScore: 86,
    ),
    NetworkDesign(
      id: 'services-segmentation',
      name: 'Servers on their own subnet',
      blurb: 'User traffic and server traffic on separate subnets, so a busy '
          'file server never starves the office.',
      wantsSiteKinds: <String>['datacenter', 'headquarters', 'warehouse'],
      minHosts: 5, maxHosts: 500,
      changes: <DesignChange>[
        DesignChange('vlan', '10', 'Users'),
        DesignChange('vlan', '30', 'Servers'),
        DesignChange('note', 'static-or-dynamic',
            'Something has to route between the two subnets'),
      ],
      expectedScore: 84,
    ),
    NetworkDesign(
      id: 'redundant-core',
      name: 'Redundant core',
      blurb: 'Two routers and a core switch, so losing one box takes the site '
          'down for a minute instead of a morning.',
      wantsSiteKinds: <String>['headquarters', 'campus', 'datacenter'],
      minHosts: 40, maxHosts: 5000,
      changes: <DesignChange>[
        DesignChange('device', 'router', 'The second core router'),
        DesignChange('device', 'multilayer switch', 'The core both routers '
            'plug into'),
        DesignChange('routing', 'ospf',
            'Two routers with more than one path need to agree on it'),
        DesignChange('note', 'dual-homing',
            'Every access switch should reach both routers, not just one'),
      ],
      expectedScore: 92,
    ),
    NetworkDesign(
      id: 'dmz',
      name: 'DMZ',
      blurb: 'Public services in their own segment, so the server the internet '
          'can reach is not the server holding the office data.',
      wantsSiteKinds: <String>['headquarters', 'warehouse', 'industrial'],
      minHosts: 10, maxHosts: 5000,
      changes: <DesignChange>[
        DesignChange('device', 'firewall', 'The edge, with three interfaces'),
        DesignChange('vlan', '50', 'The DMZ - public services only'),
        DesignChange('note', 'nat', 'Only the DMZ is published to the '
            'internet; inside stays private'),
      ],
      expectedScore: 90,
    ),
    NetworkDesign(
      id: 'branch-vpn',
      name: 'Branch over a tunnel',
      blurb: 'A branch site reaching head office across a WAN, with a tunnel '
          'so the two sites share one routing table.',
      wantsSiteKinds: <String>['branch', 'retail', 'warehouse'],
      minHosts: 2, maxHosts: 100,
      changes: <DesignChange>[
        DesignChange('device', 'router', 'The branch router'),
        DesignChange('note', 'tunnel', 'The branch reaches head office over a '
            'tunnel rather than exposing its own LAN'),
        DesignChange('routing', 'ospf', 'So the tunnel learns routes by itself'),
      ],
      expectedScore: 85,
    ),
    NetworkDesign(
      id: 'guest-wireless',
      name: 'Guest wireless, walled off',
      blurb: 'Guests get wireless on their own VLAN with no route to anything '
          'inside the office.',
      wantsSiteKinds: <String>['classroom', 'retail', 'campus', 'soho'],
      minHosts: 3, maxHosts: 200,
      changes: <DesignChange>[
        DesignChange('device', 'wireless', 'The access point guests join'),
        DesignChange('vlan', '60', 'Guests, isolated from everything else'),
        DesignChange('note', 'acl',
            'Guest traffic is denied everywhere except the internet'),
      ],
      expectedScore: 88,
    ),
    NetworkDesign(
      id: 'two-tier',
      name: 'Two-tier campus',
      blurb: 'A distribution layer over access switches, which is what makes a '
          'building-sized network readable and maintainable.',
      wantsSiteKinds: <String>['campus', 'headquarters', 'datacenter'],
      minHosts: 60, maxHosts: 5000,
      changes: <DesignChange>[
        DesignChange('device', 'multilayer switch',
            'The distribution layer the access switches hang from'),
        DesignChange('routing', 'ospf',
            'The routers and the distribution layer agree on the paths'),
      ],
      expectedScore: 93,
    ),
  ];

  /// Every design whose [id] is [id], or null.
  static NetworkDesign? byId(String id) {
    for (final design in all) {
      if (design.id == id) return design;
    }
    return null;
  }

  /// The designs that fit [plan], best first.
  ///
  /// A design that explicitly rejects the lab's size is never offered even
  /// when everything else matches - a DMZ for four people is not a generous
  /// suggestion, it is a wrong one.
  static List<DesignSuggestion> suggest(NetworkIntent plan) {
    final hosts = plan.nodes
        .where((n) => const {'pc', 'laptop', 'tablet', 'phone'}.contains(n.type))
        .length;
    final routers =
        plan.nodes.where((n) => n.type == 'router').length;
    final hasCloud = plan.nodes.any((n) => n.type == 'cloud');
    final hasFirewall = plan.nodes.any((n) => n.type == 'firewall');
    final siteKinds = DomainVocabulary.siteKindsIn(
      '${plan.projectName} ${plan.notes.join(' ')}',
    ).map((e) => e.kind).toSet();

    final out = <DesignSuggestion>[];
    for (final design in all) {
      if (design.rejectsHostCounts.contains(hosts)) continue;

      var fit = 0;
      final reasons = <String>[];

      if (design.wantsSiteKinds.any(siteKinds.contains)) {
        fit += 40;
        reasons.add('the brief describes a '
            '${siteKinds.firstWhere((k) => design.wantsSiteKinds.contains(k))}');
      }
      if (hosts >= design.minHosts && hosts <= design.maxHosts) {
        fit += 20;
        reasons.add('$hosts devices is the size this design is built for');
      } else if (design.minHosts == 0 && design.maxHosts >= 1000000) {
        fit += 10;
        reasons.add('this design suits any size of lab');
      }

      // What the plan already has is evidence FOR a design, not against it.
      if (design.id == 'dmz' && hasFirewall) {
        fit += 25;
        reasons.add('there is already a firewall to build the zones on');
      }
      if (design.id == 'redundant-core' && routers >= 2) {
        fit += 25;
        reasons.add('there are already ${routers > 2 ? routers : 'two'} routers');
      }
      if (design.id == 'branch-vpn' && routers >= 2) {
        fit += 20;
        reasons.add('more than one site already has a router');
      }
      if (design.id == 'soho' && routers > 1) {
        continue; // a multi-router lab is not a single-box office
      }
      if (design.id == 'flat-lab' && (routers >= 2 || hasCloud)) {
        // The flat design is the starting point, not an upgrade.
        continue;
      }

      // A design the brief already satisfies is not worth offering.
      if (design.id == 'dmz' && !hasCloud) {
        fit -= 30;
        reasons.clear();
        reasons.add('nothing in the brief reaches the internet yet');
      }

      if (fit <= 0) continue;
      out.add(DesignSuggestion(design, fit, reasons));
    }

    out.sort((a, b) {
      final byFit = b.fit.compareTo(a.fit);
      if (byFit != 0) return byFit;
      return b.design.expectedScore.compareTo(a.design.expectedScore);
    });
    return out;
  }

  /// The designs that would most improve [review]'s findings.
  ///
  /// This is the "learn other designs" path: after a build is reviewed, the
  /// designs that address what the review complained about are the ones worth
  /// showing next time. Matching on the review's areas rather than on the
  /// plan means a design earns its place by fixing something real.
  static List<DesignSuggestion> suggestionsForReview(
    NetworkIntent plan,
    DesignReview review,
  ) {
    final areas = review.findings.map((f) => f.area).toSet();
    final all_ = suggest(plan);
    final addressed = all_.where((s) {
      return s.design.changes.any((c) {
        switch (c.kind) {
          case 'device':
            return areas.contains('structure') ||
                areas.contains('redundancy') ||
                areas.contains('security');
          case 'vlan':
            return areas.contains('segmentation') ||
                areas.contains('security') ||
                areas.contains('services');
          case 'routing':
            return areas.contains('routing');
          default:
            return areas.contains('segmentation') ||
                areas.contains('security');
        }
      });
    }).toList();

    // A design is only offered if APPLYING it leaves the plan at least as
    // good. Matching areas says the design is relevant; applying it and
    // re-reviewing says it is an improvement, and only the second is
    // something worth spending the user's time on. Without this check the
    // app offers designs that make the network worse - a segmentation
    // complaint pulls in guest wireless, which adds an AP the plan never
    // needed and scores two points below where it started.
    final helpful = <DesignSuggestion>[];
    for (final s in addressed) {
      final applied = DesignApplier.apply(plan, s.design.id);
      if (applied.added.isEmpty) continue;
      final after = DesignReviewer.review(applied.plan);
      if (after.score > review.score) helpful.add(s);
    }
    return helpful;
  }
}

/// Applies a named design to a plan.
///
/// The design is expressed as ORDERS - add this device, add this VLAN, run
/// this routing protocol - and applying one returns a NEW plan. Nothing is
/// ever changed in place, and the design is stamped onto the plan's own notes
/// (`design: <id>`) so [DesignMemory.designIdOf] can read back what was built
/// without the memory keeping its own list.
///
/// Orders the plan cannot honour are dropped and reported rather than
/// guessed at: a design that says "add a firewall" on a plan that already has
/// one adds nothing, and the caller is told so instead of being handed a plan
/// that quietly doubled up.
class DesignApplier {
  const DesignApplier._();

  /// What applying [designId] would do to [plan], or null when the design
  /// does not fit the plan.
  ///
  /// WHY THE SIZE GATE IS HERE: the catalog states each design's [minHosts]
  /// and [maxHosts] and [suggest] honours them, but [apply] did not - so a
  /// design matched only by NAME was applied at any size. "Plan a small
  /// office with 20 employees, a firewall and staff VLANs" arrives with 20
  /// PCs in it, matches the word "small office" (an alias of `soho`, which
  /// is built for 1-15 hosts), and the one-box design was applied on top of
  /// an office it explicitly does not fit - adding a wireless router to a
  /// lab that already had a router, and reporting "Applied the Small office,
  /// one box design" as if that were an improvement. Returning null leaves
  /// the plan exactly as the user described it, which is the honest outcome.
  ///
  /// The host count is the same one [suggest] uses: the endpoints, not the
  /// infrastructure - 20 PCs is 20 hosts whether they hang off one switch or
  /// four.
  static ({NetworkIntent plan, List<String> added, List<String> skipped})?
  tryApply(
    NetworkIntent plan,
    String designId,
  ) {
    final design = DesignLibrary.byId(designId);
    if (design == null) return null;
    final hosts = plan.nodes
        .where((n) => const {'pc', 'laptop', 'tablet', 'phone'}.contains(n.type))
        .length;
    if (hosts < design.minHosts || hosts > design.maxHosts) return null;
    return apply(plan, designId);
  }

  /// What applying [design] would do to [plan].
  static ({NetworkIntent plan, List<String> added, List<String> skipped}) apply(
    NetworkIntent plan,
    String designId,
  ) {
    final design = DesignLibrary.byId(designId);
    if (design == null) {
      return (plan: plan, added: const <String>[], skipped: const <String>[]);
    }

    final nodes = [...plan.nodes];
    final vlans = [...plan.vlans];
    var routing = plan.routing;
    final notes = [...plan.notes];
    final added = <String>[];
    final skipped = <String>[];

    for (final change in design.changes) {
      switch (change.kind) {
        case 'device':
          final type = change.value;
          if (nodes.any((n) => n.type.trim().toLowerCase() == type)) {
            skipped.add('already has a $type');
            continue;
          }
          nodes.add(_deviceFor(type, nodes));
          added.add('a $type');
        case 'vlan':
          final id = int.tryParse(change.value) ?? 0;
          if (id <= 0) {
            skipped.add('${change.value} is not a VLAN id');
            continue;
          }
          if (vlans.contains(id)) {
            skipped.add('VLAN $id is already there');
            continue;
          }
          vlans.add(id);
          added.add('VLAN $id');
        case 'routing':
          if (routing == change.value) {
            skipped.add('already routing with $routing');
            continue;
          }
          routing = change.value;
          added.add('$routing routing');
        default:
          // A note carries the intent ("one sub-interface per VLAN") to the
          // planner and to the person reading the plan back. It is only
          // reported as added when it is genuinely new - re-applying a design
          // that is already there must not claim to have changed anything.
          if (notes.contains(change.why)) {
            skipped.add(change.why);
            continue;
          }
          notes.add(change.why);
          added.add(change.why);
      }
    }

    // The stamp goes last so it survives a re-apply of the same design
    // instead of accumulating.
    final stamp = 'design: ${design.id}';
    final stamped = [...notes.where((n) => !n.startsWith('design:')), stamp];

    return (
      plan: plan.copyWith(
        nodes: nodes,
        vlans: vlans,
        routing: routing,
        notes: stamped,
      ),
      added: added,
      skipped: skipped,
    );
  }

  /// Reads a plain-language request for one of the catalog designs and applies
  /// it, or returns null when the text does not name a design.
  ///
  /// This is what makes the review's closing line - "ask me to rebuild with
  /// one of those" - an actual promise rather than a nicety. It matches the
  /// way people actually ask ("rebuild it with the DMZ design", "use router
  /// on a stick", "flat lab please") and matches only a design the catalog
  /// really has, so an offer the app printed can never come back as "no such
  /// design".
  static ({
    NetworkIntent plan,
    NetworkDesign design,
    List<String> added,
    List<String> skipped,
  })? applyNamed(NetworkIntent plan, String text) {
    final match = namedInDetailed(text);
    if (match == null) return null;
    // A shorthand match is size-checked; an explicit one is honoured.
    //
    // WHY THE SPLIT: "rebuild it with the DMZ design" is the user naming a
    // design from the catalog and getting it, which is the promise the
    // review makes and what the applier tests pin. But the same adjective
    // that is an alias - "small office" for `soho` - also appears inside an
    // ordinary sentence the advisor writes for itself: "Plan a small office
    // with 20 employees, a firewall, guest wifi and staff VLANs". Applied by
    // alias alone, that laid a one-box design built for 1-15 hosts on top of
    // a 20-PC office and reported it as an improvement.
    //
    // So a design named by its own name or id is applied as asked, and one
    // reached only through shorthand has to fit the lab first.
    final applied = match.shorthand
        ? tryApply(plan, match.design.id)
        : apply(plan, match.design.id);
    if (applied == null) return null;
    return (
      plan: applied.plan,
      design: match.design,
      added: applied.added,
      skipped: applied.skipped,
    );
  }

  /// The design [text] asks for, or null if it does not ask for one.
  ///
  /// Deliberately narrow: a design has to be NAMED. "make it better" is the
  /// reviewer's job and must not quietly resolve to whichever design happens
  /// to be first in the catalog.
  static NetworkDesign? namedIn(String text) => namedInDetailed(text)?.design;

  /// How [text] names a design: the design itself, and whether it was reached
  /// through its own name or id (explicit) or only through one of the
  /// shorthand phrases.
  static ({NetworkDesign design, bool shorthand})? namedInDetailed(
    String text,
  ) {
    final lower = text.toLowerCase();
    // Longest name first, so "servers on their own subnet" is never read as
    // a shorter design that happens to be a prefix of it.
    final ranked = [...DesignLibrary.all]
      ..sort(
        (a, b) => b.name.length.compareTo(a.name.length),
      );
    NetworkDesign? best;
    var bestSpan = 0;
    var bestShorthand = false;
    for (final d in ranked) {
      final shorthand = _aliasWords[d.id] ?? const <String>[];
      final explicit = <String>[
        d.name.toLowerCase(),
        d.id.toLowerCase(),
        d.id.toLowerCase().replaceAll('-', ' '),
      ];
      for (final alias in [...explicit, ...shorthand]) {
        if (alias.isEmpty) continue;
        if (!lower.contains(alias)) continue;
        if (alias.length <= bestSpan) continue;
        best = d;
        bestSpan = alias.length;
        bestShorthand = !explicit.contains(alias);
      }
    }
    if (best == null) return null;
    return (design: best, shorthand: bestShorthand);
  }

  /// Shorthand people actually type, so "dmz" and "redundant core" resolve
  /// without quoting the catalog's full name.
  static const Map<String, List<String>> _aliasWords = {
    'soho': <String>['soho', 'small office', 'one box'],
    'flat-lab': <String>['flat lab', 'flat network', 'one subnet'],
    'router-on-a-stick': <String>[
      'on a stick',
      'router on a stick',
      'one arm',
    ],
    'services-segmentation': <String>[
      'servers on their own subnet',
      'server subnet',
      'segmented',
    ],
    'redundant-core': <String>[
      'redundant core',
      'redundant',
      'high availability',
      'failover',
    ],
    'dmz': <String>['dmz', 'perimeter network'],
    'branch-vpn': <String>[
      'branch over a tunnel',
      'branch vpn',
      'site to site',
      'vpn',
    ],
    'guest-wireless': <String>[
      'guest wireless',
      'guest wifi',
      'guest network',
    ],
    'two-tier': <String>['two tier', '2 tier', 'two-tier', 'campus'],
  };

  /// A new device of [type], named so it does not collide with the plan.
  static NetNode _deviceFor(String type, List<NetNode> existing) {
    final taken = {for (final n in existing) n.name.toUpperCase()};
    const prefixes = <String, List<String>>{
      'router': <String>['R', 'BR'],
      'switch': <String>['SW', 'BSW'],
      'firewall': <String>['FW', 'BFW'],
      'server': <String>['SRV', 'BSRV'],
      'multilayer switch': <String>['ML', 'BML'],
      'wireless': <String>['AP', 'BAP'],
      'wireless-router': <String>['WR', 'BWR'],
    };
    final candidates =
        prefixes[type] ?? <String>[type.replaceAll(' ', '').toUpperCase()];
    for (final prefix in candidates) {
      for (var i = 1; i < 100; i++) {
        final name = '$prefix$i';
        if (taken.contains(name)) continue;
        return NetNode(name: name, type: type);
      }
    }
    return NetNode(
      name: '${type.replaceAll(' ', '').toUpperCase()}${taken.length + 1}',
      type: type,
    );
  }
}