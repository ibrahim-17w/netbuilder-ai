import '../models/network_intent.dart';
import 'phrasing_memory_service.dart';

/// One correction the user made to a parse, counted.
///
/// The triple is the whole point: THE WORDS, WHAT THE APP MADE OF THEM, WHAT
/// THEY MEANT. Unlike a lesson inferred from free text, every row here is
/// labeled by the user themselves - either by tapping a slot on the
/// "Understood" card and typing the right value, or by typing a correction
/// the app recognized ("actually 40", "no, OSPF"). That is the training pair
/// [PhrasingMemoryService] needs, captured with zero ambiguity.
class MisparseEntry {
  /// [PhrasingMemoryService.normalizeKey] of [original]: what repeats.
  final String key;

  /// The words that misparsed, exactly as the user wrote them.
  final String original;

  /// What the app made of them - the brief in force when they were read.
  final String understood;

  /// The brief that replays what they actually meant. This is what gets
  /// taught as a phrasing, so it must parse back to the corrected plan.
  final String corrected;

  /// Which slot was corrected: `count:pc`, `routing`, `vlan:10`, or `free`
  /// for a correction that arrived as words rather than a tap.
  final String slot;

  /// `tap` (a slot fix - no ambiguity at all) or `typed` (words).
  final String source;

  /// `ledger` (counting) -> `proposed` (seen [MisparseLedger.promoteAfter]
  /// times, waiting for review) -> `taught` | `dismissed`.
  final String status;

  /// How many times this exact wording needed this exact correction.
  final int count;

  final String createdAt;
  final String updatedAt;

  const MisparseEntry({
    required this.key,
    required this.original,
    required this.understood,
    required this.corrected,
    required this.slot,
    required this.source,
    required this.status,
    required this.count,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isReviewable => status == 'proposed';

  Map<String, dynamic> toMap() => {
        'key': key,
        'original': original,
        'understood': understood,
        'corrected': corrected,
        'slot': slot,
        'source': source,
        'status': status,
        'count': count,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory MisparseEntry.fromMap(Map<String, dynamic> m) => MisparseEntry(
        key: (m['key'] ?? '').toString(),
        original: (m['original'] ?? '').toString(),
        understood: (m['understood'] ?? '').toString(),
        corrected: (m['corrected'] ?? '').toString(),
        slot: (m['slot'] ?? 'free').toString(),
        source: (m['source'] ?? 'typed').toString(),
        status: (m['status'] ?? 'ledger').toString(),
        count: (m['count'] as num?)?.toInt() ?? 1,
        createdAt: (m['createdAt'] ?? '').toString(),
        updatedAt: (m['updatedAt'] ?? '').toString(),
      );
}

/// The misparse ledger: a conversation-side twin of the build side's
/// failures journal.
///
/// Nothing here teaches anything by itself. A correction is logged; the same
/// wording needing the same correction [promoteAfter] times moves the row to
/// `proposed`, where the Memory screen can review it; only a review promotes
/// it into the live phrasing index. Fail-closed, exactly like the autopilot
/// learning loop - an unreviewed guess must never rewrite the user's parses.
class MisparseLedger {
  const MisparseLedger._();

  /// Sightings of one wording needing one correction before it is proposed.
  static const int promoteAfter = 3;

  /// A ledger is a working set, not an archive. Oldest rows are dropped.
  static const int maxEntries = 100;

  /// Fold one correction into [entries].
  ///
  /// Same wording + same correction bumps the count (and proposes it at the
  /// threshold); the same wording needing a DIFFERENT correction is a
  /// different row, because two rows cannot both be right.
  static ({
    List<MisparseEntry> entries,
    MisparseEntry? entry,
    MisparseEntry? proposed,
  }) record({
    required List<MisparseEntry> entries,
    required String original,
    required String understood,
    required String corrected,
    required String slot,
    required String source,
  }) {
    final now = DateTime.now().toIso8601String();
    final key = PhrasingMemoryService.normalizeKey(original);
    if (key.isEmpty || corrected.trim().isEmpty) {
      return (entries: entries, entry: null, proposed: null);
    }
    final next = [...entries];
    final at = next.indexWhere((e) => e.key == key && e.corrected == corrected);
    if (at >= 0) {
      final was = next[at];
      final count = was.count + 1;
      final status = was.status == 'dismissed' || was.status == 'taught'
          ? was.status
          : count >= promoteAfter
              ? 'proposed'
              : was.status;
      next[at] = MisparseEntry(
        key: was.key,
        original: was.original,
        understood: was.understood,
        corrected: was.corrected,
        slot: was.slot,
        source: was.source,
        status: status,
        count: count,
        createdAt: was.createdAt,
        updatedAt: now,
      );
      return (
        entries: next,
        entry: next[at],
        proposed: (status == 'proposed' && was.status != 'proposed')
            ? next[at]
            : null,
      );
    }
    final entry = MisparseEntry(
      key: key,
      original: original.trim(),
      understood: understood.trim(),
      corrected: corrected.trim(),
      slot: slot,
      source: source,
      status: promoteAfter <= 1 ? 'proposed' : 'ledger',
      count: 1,
      createdAt: now,
      updatedAt: now,
    );
    next.insert(0, entry);
    return (
      entries: _trim(next),
      entry: entry,
      proposed: entry.status == 'proposed' ? entry : null,
    );
  }

  static List<MisparseEntry> _trim(List<MisparseEntry> entries) =>
      entries.length <= maxEntries ? entries : entries.sublist(0, maxEntries);

  /// The brief a corrected plan replays as, so a taught phrasing parses back
  /// to exactly the plan the user fixed.
  ///
  /// Device counts, routing and VLANs - the slots the card lets the user
  /// correct. Anything richer (roles, addressing) rides along only when the
  /// correction was a textual edit of the user's own words, which is the
  /// common case and the one that carries everything.
  static String briefFromPlan(NetworkIntent plan) {
    final counts = <String, int>{};
    for (final n in plan.nodes) {
      counts[n.type] = (counts[n.type] ?? 0) + 1;
    }
    final order = <String>[
      'router', 'switch', 'pc', 'server', 'firewall', 'wireless', 'laptop',
      'printer', 'phone', 'cloud', 'modem', 'wireless-router',
    ];
    final parts = <String>[
      for (final t in order)
        if (counts[t] != null && counts[t]! > 0)
          '${counts[t]} ${unit(t, counts[t]!)}',
      for (final e in counts.entries)
        if (!order.contains(e.key) && e.value > 0)
          '${e.value} ${unit(e.key, e.value)}',
    ];
    if (parts.isEmpty) return '';
    if (plan.routing.isNotEmpty) parts.add('routing ${plan.routing}');
    for (final v in plan.vlans) {
      parts.add('vlan $v');
    }
    return parts.join(', ');
  }

  /// How a type is written in a brief, so the count it carries parses back.
  static String unit(String type, int n) {
    if (type == 'pc') return n == 1 ? 'PC' : 'PCs';
    if (type == 'wireless') return n == 1 ? 'AP' : 'APs';
    if (type == 'switch') return n == 1 ? 'switch' : 'switches';
    if (type == 'wireless-router') {
      return n == 1 ? 'wireless router' : 'wireless routers';
    }
    return n == 1 ? type : '${type}s';
  }

  /// Rewrite [original] so the corrected slot carries [value].
  ///
  /// The user's own words are edited in place whenever the slot appears in
  /// them - that keeps every other thing the sentence said (a role, an
  /// address, "for the office") inside the lesson. When it does not appear
  /// (the value came from a default or a profile), the canonical description
  /// of the plan being fixed is edited instead, so a correction is never
  /// silently dropped.
  ///
  /// Returns null when neither can be rewritten: recording a correction that
  /// would not replay the correction is worse than recording none.
  static String? correctedBrief({
    required String original,
    required String slot,
    required String value,
    required NetworkIntent current,
  }) {
    final v = value.trim();

    if (v.isEmpty) return null;
    if (slot.startsWith('count:')) {
      final type = slot.substring('count:'.length);
      return _replaceCount(original, type, v) ??
          _replaceCount(briefFromPlan(current), type, v);
    }
    if (slot == 'routing') {
      final proto = v.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (!const ['static', 'ospf', 'eigrp', 'bgp'].contains(proto)) return null;
      final hit = RegExp(
        r'\b(?:ospf|eigrp|bgp|static)\b',
        caseSensitive: false,
      ).firstMatch(original);
      if (hit != null) {
        final before = original.substring(0, hit.start);
        final after = original.substring(hit.end);
        final lead = RegExp(r'\s*(?:to|with|as|and|,|\s)+\s*$');
        if (lead.hasMatch(before)) {
          return '${before.replaceFirst(lead, ' ')}$proto$after';
        }
        return '$before $proto$after';
      }
      final base = briefFromPlan(current);
      final replaced = RegExp(r'\brouting\s+\w+\b').firstMatch(base);
      if (replaced != null) {
        return '${base.substring(0, replaced.start)}routing $proto'
            '${base.substring(replaced.end)}';
      }
      return '$base, routing $proto';
    }
    if (slot.startsWith('vlan:')) {
      final from = slot.substring('vlan:'.length);
      final hit = RegExp(
        '\\bvlan\\s+$from\\b',
        caseSensitive: false,
      ).firstMatch(original);
      if (hit != null) {
        return '${original.substring(0, hit.start)}vlan $v'
            '${original.substring(hit.end)}';
      }
      final base = briefFromPlan(current);
      final again = RegExp(
        '\\bvlan\\s+$from\\b',
        caseSensitive: false,
      ).firstMatch(base);
      if (again != null) {
        return '${base.substring(0, again.start)}vlan $v'
            '${base.substring(again.end)}';
      }
      return null;
    }
    return null;
  }

  /// The typed count for [type] in [text], replaced by [value]. The unit is
  /// kept as written, so "50 pcs" becomes "40 pcs" and not "40 PCs and".
  static String? _replaceCount(String text, String type, String value) {
    final singular = RegExp(
      '\\b(\\d{1,4})\\s+(${_unitPattern(type)})\\b',
      caseSensitive: false,
    );
    final m = singular.firstMatch(text);
    if (m == null) return null;
    return '${text.substring(0, m.start)}$value ${m.group(2)}'
        '${text.substring(m.end)}';
  }

  static String _unitPattern(String type) {
    switch (type) {
      case 'pc':
        return 'pcs?|computers?';
      case 'switch':
        return 'switches|switch';
      case 'wireless':
        return 'aps?|access\\s+points?';
      case 'wireless-router':
        return 'wireless\\s+routers?';
      case 'server':
        return 'servers?';
      case 'router':
        return 'routers?';
      case 'firewall':
        return 'firewalls?';
      case 'laptop':
        return 'laptops?';
      case 'printer':
        return 'printers?';
      case 'phone':
        return 'phones?';
      case 'cloud':
        return 'clouds?';
      case 'modem':
        return 'modems?';
      default:
        return '${type}s?';
    }
  }
}
