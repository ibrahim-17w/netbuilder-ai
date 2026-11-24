/// Wording that reads like a person wrote it.
///
/// The chat used to render counts as `1 router(s)`, `3 switch(es)` and
/// `35 device(s) in total` - the shape of a log line, not a sentence. This
/// helper is the single place that turns a count into the plural the user
/// would say, so the assistant, action labels and UI summaries cannot drift
/// back into parenthesised plurals.
class HumanLanguage {
  const HumanLanguage._();

  /// The plural of [singular]. Pass [plural] for irregular words.
  static String pluralize(String singular, [String? plural]) {
    if (plural != null && plural.isNotEmpty) return plural;
    final word = singular.trim();
    if (word.isEmpty) return word;
    final lower = word.toLowerCase();
    if (lower.endsWith('s') ||
        lower.endsWith('x') ||
        lower.endsWith('z') ||
        lower.endsWith('ch') ||
        lower.endsWith('sh')) {
      return '${word}es';
    }
    if (lower.endsWith('y') &&
        lower.length > 1 &&
        !'aeiou'.contains(lower[lower.length - 2])) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    // Acronyms (PC, AP, VLAN) take a plain "s". Title-case words ending in
    // "y" ("Gateway") were already handled above; this only protects the
    // all-caps case.
    return '${word}s';
  }

  /// "1 router", "3 routers", "35 devices".
  static String count(int n, String singular, [String? plural]) {
    final word = n == 1 || n == -1 ? singular : pluralize(singular, plural);
    return '$n $word';
  }

  /// "2 errors and 1 warning" - the one phrasing of a findings count, so
  /// panels stop saying "2 error(s), 1 warning(s)". "no issues" when clean.
  ///
  /// [notes] are the info-level findings: without them a panel that lists one
  /// would claim "no issues" directly above it.
  static String findingsSummary(int errors, int warnings, [int notes = 0]) {
    final parts = <String>[
      if (errors > 0) count(errors, 'error'),
      if (warnings > 0) count(warnings, 'warning'),
      if (notes > 0) count(notes, 'note'),
    ];
    return parts.isEmpty ? 'no issues' : list(parts);
  }

  /// A signed count for a plan diff: "+1 router", "-2 PCs".
  static String signedCount(int n, String singular, [String? plural]) {
    if (n == 0) return count(0, singular, plural);
    final sign = n > 0 ? '+' : '';
    return '$sign${count(n, singular, plural)}';
  }

  /// The calendar day a stored turn belongs to, worded for a transcript
  /// separator: "Today", "Yesterday" or "12 November 2026".
  ///
  /// The day arithmetic is done on UTC midnights so a daylight-saving change
  /// cannot turn "yesterday" into "today".
  static String dayLabel(DateTime when, {DateTime? now}) {
    final local = when.toLocal();
    final today = (now ?? DateTime.now()).toLocal();
    final date = DateTime.utc(local.year, local.month, local.day);
    final base = DateTime.utc(today.year, today.month, today.day);
    final days = base.difference(date).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    return '${local.day} ${_monthNames[local.month - 1]} ${local.year}';
  }

  static const _monthNames = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// "2 routers, 1 switch and 4 PCs" - the way a person lists three things.
  static String list(List<String> items) {
    final visible = items.where((item) => item.trim().isNotEmpty).toList();
    if (visible.isEmpty) return '';
    if (visible.length == 1) return visible.first;
    if (visible.length == 2) return '${visible[0]} and ${visible[1]}';
    return '${visible.take(visible.length - 1).join(', ')}, and ${visible.last}';
  }

  /// "Error", "Warning", "Info" - never the machine tag `[error]`.
  static String severity(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return 'Issue';
    final lower = value.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  /// One finding as a readable bullet line: "Error: Duplicate address ...".
  static String finding(String severity, String message) =>
      '${HumanLanguage.severity(severity)}: $message';

  /// The same finding as a bullet in a message list. Kept apart from
  /// [finding] so the plain label stays stable for callers that want it.
  static String findingLine(String severity, String message) =>
      '- ${finding(severity, message)}';
}
