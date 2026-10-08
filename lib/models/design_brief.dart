/// What a conversation has established about the network to be, slot by
/// slot - the "brief" the chat accumulates BEFORE any build is offered.
///
/// This is the contract file for the brief/readiness work: the chat screen,
/// the brief service, the clarification service and their tests all code
/// against this model, so its shape is fixed here on purpose.
///
/// The point of the brief is that describing a lab is a CONVERSATION, not a
/// parse: "2 routers and 50 PCs" fills two slots and leaves the rest open,
/// and the app talks about what is open instead of reflexively compiling a
/// .pkt. A build is offered only when [ready] - every critical slot has a
/// value from some source the user can see (their words, a remembered
/// answer, or the environment profile they can edit on the Memory screen).
library;

/// Where a slot's value came from, shown on the brief card so "where did
/// OSPF come from?" always has an answer.
enum BriefSource {
  /// The user's own words this conversation.
  user,

  /// A remembered answer to the same clarification (see
  /// ClarificationService): applied, announced, and changeable in one tap.
  remembered,

  /// The environment profile (Memory screen > Environment).
  profile,

  /// Derived from the parsed plan the user described.
  plan,
}

/// One filled slot.
class BriefFact {
  /// Canonical value: 'ospf', '40', 'none', 'yes', 'no', 'home', ...
  final String value;

  /// Human words for the card: 'OSPF', '40 users', 'none', 'wireless'.
  final String display;

  /// The user words that set it (or 'remembered from an earlier answer' /
  /// 'from your environment profile'). Empty when derived from the plan.
  final String source;

  final BriefSource origin;
  final String setAt;

  const BriefFact({
    required this.value,
    required this.display,
    this.source = '',
    this.origin = BriefSource.user,
    this.setAt = '',
  });

  Map<String, dynamic> toJson() => {
    'value': value,
    'display': display,
    'source': source,
    'origin': origin.name,
    'setAt': setAt,
  };

  factory BriefFact.fromJson(Map<String, dynamic> json) => BriefFact(
    value: (json['value'] ?? '').toString(),
    display: (json['display'] ?? '').toString(),
    source: (json['source'] ?? '').toString(),
    origin: BriefSource.values.firstWhere(
      (s) => s.name == (json['origin'] ?? 'user'),
      orElse: () => BriefSource.user,
    ),
    setAt: (json['setAt'] ?? '').toString(),
  );

  /// Precedence when two sources offer a value: the user's own words beat a
  /// remembered answer, which beats the profile, which beats a plan-derived
  /// fact. "Could we do 40 instead?" must never lose to a remembered 50.
  static int rank(BriefSource s) => switch (s) {
    BriefSource.user => 3,
    BriefSource.remembered => 2,
    BriefSource.profile => 1,
    BriefSource.plan => 0,
  };
}

/// The brief itself: a map of slot id -> fact, plus the slot vocabulary.
class DesignBrief {
  /// Slot ids the app knows. Keeping the vocabulary closed is what lets the
  /// card, the clarification policy and the tests agree on "what's open".
  static const scale = 'scale';
  static const routing = 'routing';
  static const wireless = 'wireless';
  static const segmentation = 'segmentation';
  static const security = 'security';
  static const venue = 'venue';

  static const slotIds = [
    scale,
    routing,
    wireless,
    segmentation,
    security,
    venue,
  ];

  /// A build is not offered while one of these has no value. Deliberately
  /// short: a brief that interrogates the user is as bad as one that
  /// guesses. Wireless/segmentation/security stay optional - the planner
  /// has safe defaults, and the clarification policy may still ASK about
  /// them when the situation warrants (it just cannot block on them).
  static const criticalSlots = [scale, routing];

  final Map<String, BriefFact> facts;

  const DesignBrief({this.facts = const {}});

  bool get isEmpty => facts.isEmpty;

  bool get isNotEmpty => facts.isNotEmpty;

  BriefFact? fact(String slotId) => facts[slotId];

  bool has(String slotId) => facts[slotId] != null;

  /// Canonical value of a slot, or '' when unfilled.
  String value(String slotId) => facts[slotId]?.value ?? '';

  /// Slots with no value yet, in card order.
  List<String> get missing =>
      slotIds.where((id) => !has(id)).toList();

  /// Critical slots with no value: the readiness gate.
  List<String> get missingCritical =>
      criticalSlots.where((id) => !has(id)).toList();

  /// True when every critical slot is filled. The chat offers a build when
  /// this holds (and the plan itself is sound); until then it talks.
  bool get ready => missingCritical.isEmpty;

  /// One line for snackbars and prompts: "scale: 40 users · routing: OSPF ·
  /// open: wireless, VLANs". Empty when nothing is known.
  String get summaryLine {
    final bits = <String>[];
    for (final id in slotIds) {
      final f = facts[id];
      if (f != null) bits.add('$id: ${f.display}');
    }
    return bits.join(' · ');
  }

  /// Whether [other] carries the same facts (provenance aside), so a writer
  /// can skip a no-op persist.
  bool sameFactsAs(DesignBrief other) {
    if (facts.length != other.facts.length) return false;
    for (final entry in facts.entries) {
      final o = other.facts[entry.key];
      if (o == null || o.value != entry.value.value) return false;
    }
    return true;
  }

  /// [fact] wins over the current one only when its origin outranks it
  /// (see [BriefFact.rank]). Same-rank updates still replace: a NEW user
  /// statement ("actually 8") outranks the old user statement of the same
  /// kind because it is later - callers pass the new fact with origin
  /// [BriefSource.user] and the later timestamp, and the tie goes to it.
  DesignBrief withFact(String slotId, BriefFact fact) {
    final current = facts[slotId];
    if (current != null &&
        BriefFact.rank(fact.origin) < BriefFact.rank(current.origin)) {
      return this;
    }
    final next = Map<String, BriefFact>.from(facts);
    next[slotId] = fact;
    return DesignBrief(facts: next);
  }

  Map<String, dynamic> toJson() => {
    for (final e in facts.entries) e.key: e.value.toJson(),
  };

  factory DesignBrief.fromJson(Map<String, dynamic> json) => DesignBrief(
    facts: {
      for (final e in json.entries)
        if (e.value is Map)
          e.key.toString(): BriefFact.fromJson(Map<String, dynamic>.from(e.value as Map)),
    },
  );
}
