import '../../models/request_interpretation.dart';

/// Output instructions affect presentation only, never the plan or error state.
class ResponsePresentation {
  const ResponsePresentation._();

  static String instruction(ResponsePreferences preferences) {
    final parts = <String>[
      if (preferences.language.isNotEmpty)
        'Reply in ${preferences.language.startsWith('ar') ? 'Arabic' : preferences.language}. Preserve technical names and literals.',
      if (preferences.maxSentences != null)
        'Use at most ${preferences.maxSentences} sentences, except necessary errors or unresolved decisions.',
      if (preferences.brevity == ResponseBrevity.concise)
        'Keep the response concise.',
      if (preferences.brevity == ResponseBrevity.detailed)
        'Explain the relevant details.',
      if (preferences.isCasual)
        'Use a casual, conversational tone. Contractions are welcome; avoid corporate phrasing.',
      if (preferences.isFormal) 'Keep a professional, formal tone.',
      if (!preferences.explainChanges || preferences.configurationOnly)
        'Return only the requested output and necessary errors or unresolved decisions; do not add an unsolicited explanation.',
      if (preferences.format != ResponseFormat.defaultFormat)
        'Requested output format: ${preferences.format.name}.',
    ];
    return parts.join('\n');
  }

  /// Text where cutting for brevity would remove a command, a list step, a
  /// heading, a table or a warning. The sentence limit is a style request,
  /// never permission to break the answer.
  static final RegExp _structured = RegExp(
    r'^\s*(?:```|#{1,6}\s|[-*+]\s|\d+\.\s|\|)',
    multiLine: true,
  );
  static final RegExp _risk = RegExp(
    r"\b(?:error|warning|blocked|cannot|can't|failed|unsafe)\b",
    caseSensitive: false,
  );

  static String apply(
    String text,
    ResponsePreferences preferences, {
    bool hasIssue = false,
  }) {
    if (text.isEmpty ||
        hasIssue ||
        text.contains('```') ||
        preferences.configurationOnly) {
      return text;
    }
    if (preferences.format == ResponseFormat.json ||
        preferences.format == ResponseFormat.table) {
      return text;
    }
    var result = text;
    final limit = preferences.maxSentences;
    if (limit != null && limit > 0) {
      // A length request is not permission to drop the commands, the steps,
      // the warning or the question. Only trim plain prose; anything with a
      // structure or a risk marker stays whole, and the prompt already asked
      // for the shorter answer.
      if (!_structured.hasMatch(result) && !_risk.hasMatch(result)) {
        final sentences = RegExp(r'[^.!?؟]+(?:[.!?؟](?=\s|$)|$)')
            .allMatches(result)
            .map((match) => match.group(0)!.trim())
            .where((part) => part.isNotEmpty)
            .toList();
        if (sentences.length > limit) {
          result = sentences.take(limit).join(' ');
        }
      }
    }
    if (preferences.format == ResponseFormat.plainText) {
      result = result
          .replaceAllMapped(
            RegExp(r'\*\*([^*]+)\*\*'),
            (match) => match.group(1)!,
          )
          .replaceAllMapped(RegExp(r'`([^`]+)`'), (match) => match.group(1)!);
    }
    return result;
  }
}
