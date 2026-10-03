import '../models/network_intent.dart';
import 'design_library.dart';
import 'design_review.dart';
import 'domain_vocabulary.dart';

/// What one built network taught the app.
class DesignMemoryEntry {
  /// The shape of the design, not its names: two labs with different site
  /// names but the same structure are the same lesson.
  final String signature;

  /// A short human label for the shape - "2 routers, 2 switches, 20 hosts,
  /// OSPF, flat".
  final String shape;

  /// What the design was called, when a design was applied.
  final String designId;

  final int score;

  /// The areas the review was happy about, and the ones it was not.
  final List<String> strengths;
  final List<String> weaknesses;

  /// How many times this shape has been built.
  final int builds;

  /// The highest score this shape has ever reached.
  final int bestScore;

  const DesignMemoryEntry({
    required this.signature,
    required this.shape,
    required this.designId,
    required this.score,
    required this.strengths,
    required this.weaknesses,
    required this.builds,
    required this.bestScore,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'signature': signature,
        'shape': shape,
        'designId': designId,
        'score': score,
        'strengths': strengths,
        'weaknesses': weaknesses,
        'builds': builds,
        'bestScore': bestScore,
      };

  static DesignMemoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final signature = raw['signature'];
    if (signature is! String || signature.isEmpty) return null;
    // Stored scores are numbers or they are nothing: a row whose score is a
    // string is a corrupted row, and defaulting it to 0 would quietly demote
    // a design the user actually built well.
    final score = raw['score'];
    if (score is! num) return null;
    final builds = raw['builds'];
    final best = raw['bestScore'];
    return DesignMemoryEntry(
      signature: signature,
      shape: raw['shape'] is String ? raw['shape'] as String : '',
      designId: raw['designId'] is String ? raw['designId'] as String : '',
      score: score.toInt(),
      strengths: _strings(raw['strengths']),
      weaknesses: _strings(raw['weaknesses']),
      builds: builds is num && builds.toInt() > 0 ? builds.toInt() : 1,
      bestScore: best is num ? best.toInt() : score.toInt(),
    );
  }

  DesignMemoryEntry mergedWith(DesignMemoryEntry next) => DesignMemoryEntry(
        signature: signature,
        shape: next.shape.isEmpty ? shape : next.shape,
        designId: next.designId.isEmpty ? designId : next.designId,
        score: next.score,
        strengths: next.strengths,
        weaknesses: next.weaknesses,
        builds: builds + next.builds,
        bestScore: next.score > bestScore ? next.score : bestScore,
      );

  static List<String> _strings(Object? raw) => raw is List
      ? [for (final e in raw) '$e']
      : const <String>[];
}

/// What the app learned from every network it has built.
///
/// Two things are learned, and they are learned from different evidence:
///
/// * **WORDS** - when a user corrects the app, the word they corrected goes
///   into [DomainVocabulary] so the same phrasing parses correctly next time.
///   This is the part that compounds fastest, because a person only has to
///   say it once.
/// * **DESIGNS** - every built network is reviewed, and the ones that scored
///   well are remembered by SHAPE. Next time a brief resembles a design that
///   worked, the app can point at it: not "here is a template", but "you
///   built this shape before and it held together".
///
/// Nothing here is a black box and nothing is trusted blindly: only reviews
/// above [kLearnThreshold] are remembered, a shape has to be seen twice
/// before it is offered back as a known-good, and the whole memory can be
/// listed, inspected and cleared.
class DesignMemory {
  const DesignMemory._();

  /// A design has to score at least this well to be worth remembering.
  static const int kLearnThreshold = 70;

  /// How many builds of the same shape before it counts as "known good".
  static const int kTrustedAfter = 2;

  /// How many shapes are remembered. Older, worse ones are dropped first.
  static const int kMaxEntries = 200;

  static final Map<String, DesignMemoryEntry> _entries =
      <String, DesignMemoryEntry>{};

  /// The remembered shapes, most trusted first.
  static List<DesignMemoryEntry> get entries {
    final all = _entries.values.toList()
      ..sort((a, b) {
        final byBest = b.bestScore.compareTo(a.bestScore);
        if (byBest != 0) return byBest;
        return b.builds.compareTo(a.builds);
      });
    return all;
  }

  static void reset() => _entries.clear();

  /// A stable fingerprint of what a plan IS, ignoring what it is called.
  ///
  /// Device counts by kind, the routing protocol, whether the design was
  /// segmented, and whether it reaches the internet - the things a review
  /// actually judges. Names, addresses and site labels are left out on
  /// purpose: "Branch Office HQ build 3" and "Warehouse pilot" are the same
  /// lesson if they have the same shape.
  static String signatureOf(NetworkIntent plan) {
    final byType = <String, int>{};
    for (final n in plan.nodes) {
      final type = n.type.trim().toLowerCase();
      byType[type] = (byType[type] ?? 0) + 1;
    }
    final parts = byType.keys.toList()..sort();
    final shape = [
      for (final type in parts) '$type:${byType[type]}',
    ].join(',');
    final services = <String>{
      for (final n in plan.nodes) ...n.services.map((s) => s.trim().toLowerCase()),
    }.toList()
      ..sort();
    return <String>[
      shape,
      'routing=${plan.routing.trim().toLowerCase()}',
      'vlans=${plan.vlans.length}',
      'cloud=${plan.nodes.any((n) => n.type == 'cloud')}',
      'firewall=${plan.nodes.any((n) => n.type == 'firewall')}',
      'services=${services.join('+')}',
    ].join('|');
  }

  /// The human label for a shape, for the screen that lists what was learned.
  static String shapeOf(NetworkIntent plan) {
    final byType = <String, int>{};
    for (final n in plan.nodes) {
      final type = n.type.trim().toLowerCase();
      byType[type] = (byType[type] ?? 0) + 1;
    }
    final parts = byType.keys.toList()..sort();
    return <String>[
      for (final type in parts) '${byType[type]} $type'
          '${byType[type] == 1 ? '' : 's'}',
      plan.routing.trim().isEmpty ? '' : plan.routing.trim(),
      if (plan.vlans.isNotEmpty) '${plan.vlans.length} VLANs',
    ].where((s) => s.isNotEmpty).join(', ');
  }

  /// The design id a plan is carrying, when one was applied.
  ///
  /// Read from the plan's own notes so the memory does not need a second
  /// source of truth about what was built.
  static String designIdOf(NetworkIntent plan) {
    for (final note in plan.notes) {
      final lower = note.toLowerCase();
      final hit = lower.indexOf('design:');
      if (hit < 0) continue;
      final id = note.substring(hit + 7).trim().split(RegExp(r'\s')).first;
      if (DesignLibrary.byId(id) != null) return id;
    }
    return '';
  }

  /// What a build taught. Returns the entry it stored, or null when the
  /// design was not good enough to be worth remembering.
  ///
  /// A design that scored badly is remembered as a negative lesson only if it
  /// has been seen more than once - one bad build is usually a typo, not a
  /// pattern.
  static DesignMemoryEntry? recordBuild({
    required NetworkIntent plan,
    required DesignReview review,
  }) {
    final signature = signatureOf(plan);
    final next = DesignMemoryEntry(
      signature: signature,
      shape: shapeOf(plan),
      designId: designIdOf(plan),
      score: review.score,
      strengths: review.strengths,
      weaknesses: [for (final f in review.findings) f.area],
      builds: 1,
      bestScore: review.score,
    );

    final existing = _entries[signature];
    if (existing == null) {
      if (review.score < kLearnThreshold) {
        // Not worth keeping, and keeping it would only ever be used to warn
        // about a shape the user built once on purpose.
        return null;
      }
      _store(next);
      return next;
    }

    final merged = existing.mergedWith(next);
    _store(merged);
    return merged;
  }

  /// The best remembered design for [plan]'s shape, when it is worth
  /// offering back. Null when the shape has never scored well or has only
  /// been built once - one success is not evidence.
  static DesignMemoryEntry? recallFor(NetworkIntent plan) {
    final entry = _entries[signatureOf(plan)];
    if (entry == null) return null;
    if (entry.bestScore < kLearnThreshold) return null;
    if (entry.builds < kTrustedAfter) return null;
    return entry;
  }

  /// Every remembered shape that scored well, best first - the "other designs
  /// this has learned" list.
  static List<DesignMemoryEntry> get knownGood => <DesignMemoryEntry>[
        for (final e in entries)
          if (e.bestScore >= kLearnThreshold) e,
      ];

  /// The repeated weaknesses across remembered designs, most common first.
  ///
  /// This is the app noticing a habit rather than a single mistake: if four
  /// remembered labs all lacked segmentation, that is a pattern worth saying
  /// out loud once.
  static List<({String area, int count})> repeatedWeaknesses() {
    final counts = <String, int>{};
    for (final e in knownGood) {
      for (final area in e.weaknesses) {
        counts[area] = (counts[area] ?? 0) + 1;
      }
    }
    final out = counts.entries
        .where((e) => e.value >= kTrustedAfter)
        .map((e) => (area: e.key, count: e.value))
        .toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.area.compareTo(b.area);
      });
    return out;
  }

  /// One line about what the app has learned, for the chat to say out loud.
  /// Empty when there is nothing worth saying.
  static String recap() {
    final good = knownGood;
    if (good.isEmpty) return '';
    final best = good.first;
    final habits = repeatedWeaknesses();
    final designs = good
        .map((e) => e.designId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .map((id) => DesignLibrary.byId(id)?.name ?? id)
        .toList();
    final parts = <String>[
      'I have reviewed ${good.fold<int>(0, (n, e) => n + e.builds)} builds '
          'across ${good.length} shape${good.length == 1 ? '' : 's'}',
      if (designs.isNotEmpty)
        'the one that worked best was ${best.shape} '
            '(${designs.join(', ')})',
      if (habits.isNotEmpty)
        'the thing that keeps coming up is ${habits.first.area}',
    ];
    return '${parts.join('; ')}.';
  }

  static void _store(DesignMemoryEntry entry) {
    _entries[entry.signature] = entry;
    if (_entries.length <= kMaxEntries) return;
    // Drop the least trusted first: worst best-score, then least built.
    final order = _entries.values.toList()
      ..sort((a, b) {
        final byBest = a.bestScore.compareTo(b.bestScore);
        return byBest != 0 ? byBest : a.builds.compareTo(b.builds);
      });
    for (final drop in order.take(_entries.length - kMaxEntries)) {
      _entries.remove(drop.signature);
    }
  }

  /// Everything remembered, for storage.
  static Map<String, dynamic> snapshot() => <String, dynamic>{
        'entries': [
          for (final e in _entries.values) e.toJson(),
        ],
        'words': DomainVocabulary.snapshot(),
      };

  /// Put back what [snapshot] took out, skipping anything unusable.
  static void restore(Map<dynamic, dynamic>? raw) {
    _entries.clear();
    DomainVocabulary.reset();
    if (raw == null) return;
    final list = raw['entries'];
    if (list is List) {
      for (final item in list) {
        final entry = DesignMemoryEntry.fromJson(item);
        if (entry == null) continue;
        _store(entry);
      }
    }
    // Storage hands back whatever it has. Every nested value is checked before
    // it is used, because a row written by an older build (or corrupted) must
    // be skipped rather than thrown on - losing a memory is recoverable,
    // failing to start is not.
    final words = raw['words'];
    DomainVocabulary.restore(words is Map ? words : null);
  }
}