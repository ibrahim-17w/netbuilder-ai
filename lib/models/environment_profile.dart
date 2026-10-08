import 'dart:convert';

/// The user's environment, as the advice answers should know it: where the
/// network lives, how big it is, whether money is tight, and how experienced
/// the person asking is.
///
/// This used to be re-derived from every message and thrown away, so a user
/// who said "I'm a beginner" once kept getting answers that forgot it. It is
/// now one remembered row (see [MemoryService.environmentProfile]): stated
/// facts are merged in as they arrive, the advisor falls back to it whenever
/// the message does not restate a fact, and the Memory screen shows and
/// edits it.
class EnvironmentProfile {
  /// Where the network lives. Empty means unknown. Values match the
  /// advisor's venue list: home, office, school, clinic, hospitality,
  /// industrial.
  final String venue;

  /// How many people/devices the site serves. 0 means unknown.
  final int scale;

  /// Whether the user said money is tight. Null means never stated either
  /// way (distinct from "stated not budget-limited").
  final bool? budget;

  /// How experienced the user is: beginner, intermediate or advanced.
  /// Empty means unknown.
  final String skill;

  /// When this profile was last written, and the message that last changed
  /// it - shown on the Memory screen so "where did that come from?" has an
  /// answer.
  final String updatedAt;
  final String source;

  const EnvironmentProfile({
    this.venue = '',
    this.scale = 0,
    this.budget,
    this.skill = '',
    this.updatedAt = '',
    this.source = '',
  });

  /// True when nothing has been learned yet (or everything was forgotten).
  bool get isEmpty =>
      venue.isEmpty && scale == 0 && budget == null && skill.isEmpty;

  /// One line for a prompt or a snackbar: "office, ~40 users, beginner".
  /// Empty when nothing is known.
  String get summaryLine {
    final bits = <String>[
      if (venue.isNotEmpty) venue,
      if (scale > 0) '~$scale users',
      if (budget == true) 'budget-conscious',
      if (skill.isNotEmpty) skill,
    ];
    return bits.join(', ');
  }

  /// Only the facts [update] states, kept on top of this profile. A field
  /// the update does not state is left exactly as it was - "and for 40
  /// users?" must not erase the venue it learned two turns ago.
  EnvironmentProfile merge(EnvironmentProfile update) => EnvironmentProfile(
    venue: update.venue.isNotEmpty ? update.venue : venue,
    scale: update.scale > 0 ? update.scale : scale,
    budget: update.budget ?? budget,
    skill: update.skill.isNotEmpty ? update.skill : skill,
    updatedAt: update.updatedAt.isEmpty ? updatedAt : update.updatedAt,
    source: update.source.isEmpty ? source : update.source,
  );

  /// Whether [other] carries the same facts as this profile (timestamps and
  /// provenance aside), so a writer can skip a no-op save.
  bool sameFactsAs(EnvironmentProfile other) =>
      venue == other.venue &&
      scale == other.scale &&
      budget == other.budget &&
      skill == other.skill;

  Map<String, dynamic> toJson() => {
    'venue': venue,
    'scale': scale,
    if (budget != null) 'budget': budget,
    'skill': skill,
    'updatedAt': updatedAt,
    'source': source,
  };

  factory EnvironmentProfile.fromJson(Map<String, dynamic> json) =>
      EnvironmentProfile(
        venue: (json['venue'] ?? '').toString(),
        scale: (json['scale'] as num?)?.toInt() ?? 0,
        budget: json['budget'] is bool ? json['budget'] as bool : null,
        skill: (json['skill'] ?? '').toString(),
        updatedAt: (json['updatedAt'] ?? '').toString(),
        source: (json['source'] ?? '').toString(),
      );

  /// Decode a stored row tolerantly: a value that will not parse reads as
  /// "nothing learned" rather than breaking the chat that asked for it.
  static EnvironmentProfile? tryDecode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return EnvironmentProfile.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
