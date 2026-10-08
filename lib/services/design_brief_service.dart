import '../models/design_brief.dart';
import '../models/environment_profile.dart';
import '../models/network_intent.dart';

/// The brief's state machine: fold one conversation turn into the running
/// [DesignBrief].
///
/// Precedence is the contract's (user > remembered > profile > plan) and is
/// enforced by [DesignBrief.withFact]; this service only decides WHAT each
/// source may claim:
///
/// * the user's words claim a slot only when the words say it - "use OSPF"
///   fills routing, but a plan whose routing is the planner's DEFAULT never
///   does (a default must not masquerade as a decision);
/// * the parsed plan claims a slot only when the text shows the user was
///   talking about that dimension, or when the plan's own content is itself
///   the user's decision (access points exist because they asked);
/// * the environment profile fills what nobody said this turn.
///
/// Tentative/exploration sentences never reach here: the chat's
/// tentative-language gate runs FIRST, so everything this service sees is a
/// definite statement.
class DesignBriefService {
  const DesignBriefService._();

  /// The outcome of one turn: the new brief, whether it changed, and short
  /// human lines for the facts that changed (with their provenance), which
  /// the chat can quote in its answer.
  static BriefTurn briefForTurn({
    DesignBrief? previous,
    required String normalizedText,
    NetworkIntent? parsedPlan,
    EnvironmentProfile? profile,
    List<String> standingRules = const [],
  }) {
    final t = normalizedText.trim().toLowerCase();
    final old = previous ?? const DesignBrief();
    var brief = old;

    // Standing rules the user taught the app ("always use ospf") are the
    // user's own words, just older: they fold in at user rank and are
    // announced when new ("Routing: OSPF - your standing rule"). Folding
    // them FIRST means this turn's fresh statement still wins a same-rank
    // tie, and the app never asks about something it has already been told.
    for (final rule in standingRules) {
      brief = _applyText(brief, rule.trim().toLowerCase(),
          source: 'your standing rule');
    }

    // Applied lowest precedence first: each later claim wins only when its
    // origin outranks (or later-matches) what is already there.
    if (profile != null) {
      if (profile.venue.isNotEmpty) {
        brief = brief.withFact(
          DesignBrief.venue,
          BriefFact(
            value: profile.venue,
            display: _venueDisplay(profile.venue),
            source: 'from your environment profile',
            origin: BriefSource.profile,
          ),
        );
      }
      if (profile.scale > 0) {
        brief = brief.withFact(
          DesignBrief.scale,
          BriefFact(
            value: '${profile.scale}',
            display: '${profile.scale} users',
            source: 'from your environment profile',
            origin: BriefSource.profile,
          ),
        );
      }
    }

    // The plan as the user described it. Every claim below is gated on the
    // text or on plan CONTENT being itself a user decision.
    final plan = parsedPlan;
    if (plan != null) {
      // Scale from the lab the user described, when the sentence was about
      // devices at all - a stated count of routers/switches/servers IS the
      // network's size, stated in device terms. PCs first (end devices are
      // the load), total node count when the lab has none.
      if (_deviceNouns.hasMatch(t) && !brief.has(DesignBrief.scale)) {
        final pcs = plan.nodes.where((n) => n.type == 'pc').length;
        final n = pcs > 0 ? pcs : plan.nodes.length;
        if (n > 0) {
          brief = brief.withFact(
            DesignBrief.scale,
            BriefFact(
              value: '$n',
              display: '$n devices',
              source: 'from the lab you described',
              origin: BriefSource.plan,
            ),
          );
        }
      }
      // Routing from the plan ONLY when the text was about routing: the
      // planner fills a default otherwise, and a default is not a decision.
      if (_routingWords.hasMatch(t) &&
          plan.routing.isNotEmpty &&
          plan.routing != 'none') {
        brief = brief.withFact(
          DesignBrief.routing,
          BriefFact(
            value: plan.routing,
            display: _routingDisplay(plan.routing),
            source: 'from the protocol you named',
            origin: BriefSource.plan,
          ),
        );
      }
      // Access points exist because the user asked for them: plan content
      // as decision.
      final hasWireless = plan.nodes.any(
        (n) => n.type == 'access point' || n.type == 'wireless-router',
      );
      if (hasWireless && !brief.has(DesignBrief.wireless)) {
        brief = brief.withFact(
          DesignBrief.wireless,
          BriefFact(
            value: 'yes',
            display: 'planned',
            source: 'the lab has access points',
            origin: BriefSource.plan,
          ),
        );
      }
      // VLANs from the plan only when the text was about segmentation.
      if (_vlanWords.hasMatch(t) && plan.vlans.isNotEmpty) {
        brief = brief.withFact(
          DesignBrief.segmentation,
          BriefFact(
            value: 'vlans',
            display: 'VLANs ${plan.vlans.join(', ')}',
            source: 'from the VLANs you named',
            origin: BriefSource.plan,
          ),
        );
      }
    }

    // The user's words, last and strongest: same-rank replaces, so "actually
    // 8" overwrites an earlier "50" from this same conversation.
    brief = _applyText(brief, t, source: 'from your words');

    final announced = <String>[];
    var changed = false;
    for (final id in DesignBrief.slotIds) {
      final was = old.facts[id];
      final now = brief.facts[id];
      if (was == null && now == null) continue;
      if (was != null && now != null && was.value == now.value) continue;
      changed = true;
      if (now != null) {
        announced.add('${_slotLabel(id)}: ${now.display} - ${now.source}');
      } else {
        announced.add('${_slotLabel(id)}: no longer set');
      }
    }
    return BriefTurn(
      brief: brief,
      changed: changed,
      announced: announced,
    );
  }

  // --- text claims ---------------------------------------------------------

  /// [source] names where the words came from - this turn's message or a
  /// standing rule - so the card and the announced lines can say so.
  static DesignBrief _applyText(DesignBrief brief, String t,
      {String source = 'from your words'}) {
    if (t.isEmpty) return brief;

    // Scale: a number attached to a count-of-people/devices noun.
    final count = _countNoun.firstMatch(t);
    if (count != null) {
      final n = int.tryParse(count.group(1)!);
      if (n != null && n > 0 && n <= 5000) {
        final noun = (count.group(2) ?? '').trim();
        final peopleish = RegExp(
          r'^(users?|employees?|people|staff|students?|patients?|clients?'
          r'|guests?|customers?|seats?|workstations?|endpoints?)$',
        ).hasMatch(noun);
        brief = brief.withFact(
          DesignBrief.scale,
          BriefFact(
            value: '$n',
            display: peopleish ? '$n users' : '$n devices',
            source: source,
            origin: BriefSource.user,
          ),
        );
      }
    }

    // Routing. A stated protocol is a decision; so is asking for none.
    final protocol = _protocol.firstMatch(t);
    if (protocol != null) {
      brief = brief.withFact(
        DesignBrief.routing,
        BriefFact(
          value: protocol.group(1)!,
          display: _routingDisplay(protocol.group(1)!),
          source: source,
          origin: BriefSource.user,
        ),
      );
    } else if (_staticRouting.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.routing,
        BriefFact(
          value: 'static',
          display: 'Static routes',
          source: source,
          origin: BriefSource.user,
        ),
      );
    } else if (_noRouting.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.routing,
        BriefFact(
          value: 'none',
          display: 'None',
          source: source,
          origin: BriefSource.user,
        ),
      );
    }

    // Segmentation. The bare "vlans" wording yields to a richer fact the
    // plan already supplied this turn ("VLANs 10, 20"), not the other way
    // round.
    if (_noVlans.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.segmentation,
        BriefFact(
          value: 'none',
          display: 'one flat network',
          source: source,
          origin: BriefSource.user,
        ),
      );
    } else if (_vlanWords.hasMatch(t) &&
        brief.value(DesignBrief.segmentation) != 'vlans') {
      brief = brief.withFact(
        DesignBrief.segmentation,
        BriefFact(
          value: 'vlans',
          display: 'VLANs',
          source: source,
          origin: BriefSource.user,
        ),
      );
    }

    // Wireless. Same yield rule: "access points" in a sentence whose plan
    // already carries APs adds nothing over "the lab has access points".
    if (_noWireless.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.wireless,
        BriefFact(
          value: 'no',
          display: 'wired only',
          source: source,
          origin: BriefSource.user,
        ),
      );
    } else if (_wirelessWords.hasMatch(t) &&
        brief.value(DesignBrief.wireless) != 'yes') {
      brief = brief.withFact(
        DesignBrief.wireless,
        BriefFact(
          value: 'yes',
          display: 'planned',
          source: source,
          origin: BriefSource.user,
        ),
      );
    }

    // Security posture.
    if (_maxSecurity.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.security,
        BriefFact(
          value: 'maximum',
          display: 'maximum',
          source: source,
          origin: BriefSource.user,
        ),
      );
    } else if (_basicSecurity.hasMatch(t)) {
      brief = brief.withFact(
        DesignBrief.security,
        BriefFact(
          value: 'basic',
          display: 'basic',
          source: source,
          origin: BriefSource.user,
        ),
      );
    }

    // Venue stated in passing ("it's for a school").
    final venue = _venueOf(t);
    if (venue != null) {
      brief = brief.withFact(
        DesignBrief.venue,
        BriefFact(
          value: venue,
          display: _venueDisplay(venue),
          source: source,
          origin: BriefSource.user,
        ),
      );
    }

    return brief;
  }

  // --- regexes -------------------------------------------------------------

  /// "40 users", "12 pcs", "3 devices" - the same shape the advisor and the
  /// environment reader count with, so all three agree on what a scale is.
  static final RegExp _countNoun = RegExp(
    r'\b(\d{1,4})\s*[- ]?\s*(users?|employees?|people|staff|students?'
    r'|patients?|clients?|guests?|customers?|pcs?|computers?|devices?'
    r'|hosts?|seats?|workstations?|endpoints?)\b',
  );

  /// Any network-device noun - the looser gate for taking a scale from the
  /// parsed plan. Routers/switches/servers/APs count too: "2 routers and 4
  /// switches" has stated the network's size, in device terms.
  static final RegExp _deviceNouns = RegExp(
    r'\b(pcs?|computers?|devices?|hosts?|workstations?|endpoints?'
    r'|routers?|switches|switch|servers?|firewalls?|access points?'
    r'|wireless routers?|laptops?|phones?)\b',
  );

  static final RegExp _protocol = RegExp(
    r'\b(ospf|eigrp|rip|bgp)\b',
  );

  /// The text was ABOUT routing - the gate for trusting the plan's routing
  /// value as a user decision rather than a planner default.
  static final RegExp _routingWords = RegExp(
    r'\brouting\b|\broute(?:s|d)?\b|\bprotocol\b|\bdynamic\b|\bstatic\b'
    r'|\bospf\b|\beigrp\b|\brip\b|\bbgp\b',
  );
  static final RegExp _staticRouting = RegExp(
    r'\bstatic (?:routing|routes)\b|\buse static\b|\bstatic instead\b',
  );
  static final RegExp _noRouting = RegExp(
    r'\bno routing\b|\bwithout routing\b|\bno routing protocol\b',
  );

  static final RegExp _noVlans = RegExp(
    r'\bno vlans?\b|\bone flat (?:network|lan)\b|\bflat network\b'
    r'|\bflat lan\b|\bno segmentation\b',
  );
  static final RegExp _vlanWords = RegExp(r'\bvlans?\b');

  static final RegExp _noWireless = RegExp(
    r'\bno wireless\b|\bwithout wireless\b|\bwired only\b',
  );
  static final RegExp _wirelessWords = RegExp(
    r'\bwireless\b|\bwi-?fi\b|\baccess points?\b|\bwaps?\b',
  );

  static final RegExp _maxSecurity = RegExp(
    r'\bmaximum security\b|\bmax security\b|\bhigh security\b'
    r'|\bsecurity maximum\b|\btop security\b',
  );
  static final RegExp _basicSecurity = RegExp(
    r'\bbasic security\b|\bstandard security\b|\bsimple security\b',
  );

  static final RegExp _schoolWords = RegExp(
    r'\bschool|university|college|campus\b',
  );
  static final RegExp _clinicWords = RegExp(r'\bclinic|hospital\b');
  static final RegExp _homeWords = RegExp(r'\bhome|house|apartment\b');
  static final RegExp _industrialWords = RegExp(r'\bwarehouse|factory\b');
  static final RegExp _officeWords = RegExp(r'\boffice|business\b');

  /// Venue stated in the text. Hospitality is checked before office because
  /// a cafe is a business, but its advice lives in the hospitality track.
  static String? _venueOf(String t) {
    if (_schoolWords.hasMatch(t)) return 'school';
    if (_clinicWords.hasMatch(t)) return 'clinic';
    if (RegExp(r'\bcafe|caf\u00e9|restaurant|hotel|shop|store\b').hasMatch(t)) {
      return 'hospitality';
    }
    if (_industrialWords.hasMatch(t)) return 'industrial';
    if (_officeWords.hasMatch(t)) return 'office';
    if (_homeWords.hasMatch(t)) return 'home';
    return null;
  }

  // --- presentation ---------------------------------------------------------

  static String _routingDisplay(String v) => switch (v) {
    'ospf' => 'OSPF',
    'eigrp' => 'EIGRP',
    'rip' => 'RIP',
    'bgp' => 'BGP',
    'static' => 'Static routes',
    'none' => 'None',
    _ => v,
  };

  static String _venueDisplay(String v) => switch (v) {
    'home' => 'home',
    'office' => 'office',
    'school' => 'school / campus',
    'clinic' => 'clinic / hospital',
    'hospitality' => 'cafe / hotel / shop',
    'industrial' => 'industrial / warehouse',
    _ => v,
  };

  static String _slotLabel(String id) => switch (id) {
    DesignBrief.scale => 'Scale',
    DesignBrief.routing => 'Routing',
    DesignBrief.wireless => 'Wireless',
    DesignBrief.segmentation => 'VLANs',
    DesignBrief.security => 'Security',
    DesignBrief.venue => 'Venue',
    _ => id,
  };

  /// The card's row labels, exposed so the widget and tests never re-spell
  /// them.
  static String labelFor(String slotId) => _slotLabel(slotId);
}

/// One turn's effect on the brief.
class BriefTurn {
  final DesignBrief brief;
  final bool changed;

  /// One line per fact that changed, with its provenance - "Routing: OSPF -
  /// from your words". Empty when nothing changed.
  final List<String> announced;

  const BriefTurn({
    required this.brief,
    required this.changed,
    required this.announced,
  });
}
