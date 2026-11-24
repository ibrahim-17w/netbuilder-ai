/// Routing mentions with clause-local polarity. A prohibition on replacing a
/// protocol preserves the source protocol; it does not prohibit using it.
class RoutingConstraint {
  final String protocol;
  final int start;
  final int end;
  final int evidenceStart;
  final int evidenceEnd;
  final bool forbidden;
  final bool instructed;

  const RoutingConstraint({
    required this.protocol,
    required this.start,
    required this.end,
    required this.evidenceStart,
    required this.evidenceEnd,
    required this.forbidden,
    required this.instructed,
  });
}

class RoutingConstraintReader {
  const RoutingConstraintReader._();

  static final _protocol = RegExp(
    r'\b(?:ospf|eigrp|bgp|static(?:\s+(?:routing|routes?))?)\b',
    caseSensitive: false,
  );
  static final _replacement = RegExp(
    r'\b(?:replace|substitute|swap)\s+(ospf|eigrp|bgp|static)'
    r'(?:\s+(?:routing|routes?))?\s+(?:with|by|for)\s+'
    r'(ospf|eigrp|bgp|static)(?:\s+(?:routing|routes?))?\b',
    caseSensitive: false,
  );
  static final _negative = RegExp(
    r"\b(?:do\s+not|don['’]?t|never|must\s+not|should\s+not|"
    r'not|no|without|avoid|drop|remove|instead\s+of|rather\s+than)\b',
    caseSensitive: false,
  );
  static final _action = RegExp(
    r'\b(?:use|using|run|running|configure|implement|adopt|choose|pick|'
    r'enable|prefer|keep|preserve|switch\s+to|change\s+(?:it\s+)?to|'
    r'go\s+with|set\s+(?:routing\s+)?to|make\s+it|go\s+for)\b',
    caseSensitive: false,
  );

  static String clausePrefix(String text, int at) {
    final head = text.substring(0, at);
    final boundary = RegExp(r'[,;.\n!?]').allMatches(head).lastOrNull;
    return head.substring(boundary?.end ?? 0);
  }

  static bool negatedAt(String text, int at) {
    final prefix = clausePrefix(text, at);
    final negative = _negative.allMatches(prefix).lastOrNull;
    if (negative == null) return false;
    final tail = prefix.substring(negative.end);
    return !RegExp(
      r'\b(?:but|however)\b|\band\s+(?:add|use|run|configure|enable|'
      r'put|set|change|keep|preserve)\b',
      caseSensitive: false,
    ).hasMatch(tail);
  }

  static List<RoutingConstraint> read(String text) {
    final replacements = _replacement.allMatches(text).toList();
    final result = <RoutingConstraint>[];
    for (final match in _protocol.allMatches(text)) {
      final raw = match.group(0)!.toLowerCase();
      if (raw == 'static' &&
          RegExp(
            r'^\s+(?:ip(?:s|v4|v6)?|addresses|addressing|pcs?|servers?|hosts?)\b',
            caseSensitive: false,
          ).hasMatch(text.substring(match.end))) {
        continue;
      }
      final protocol = raw.startsWith('static') ? 'static' : raw;
      final replacement = replacements
          .where((r) => r.start <= match.start && r.end >= match.end)
          .firstOrNull;
      final prefix = clausePrefix(text, match.start);
      final cue = RegExp(
        r"\b(?:use|using|run|configure|keep|preserve|set|change|switch\s+to|"
        r"do\s+not|don['’]?t|never|without|no|not|actually)\b",
        caseSensitive: false,
      ).allMatches(prefix).lastOrNull;
      var forbidden = negatedAt(text, match.start);
      var instructed =
          _action.hasMatch(prefix) ||
          RegExp(
            r'^\s*(?:instead|as\s+the\s+protocol)\b',
            caseSensitive: false,
          ).hasMatch(text.substring(match.end));
      if (replacement != null) {
        final negativeReplacement = negatedAt(text, replacement.start);
        final source =
            protocol == replacement.group(1)!.toLowerCase() &&
            match.start <
                replacement.start +
                    replacement.group(0)!.lastIndexOf(replacement.group(2)!);
        forbidden = negativeReplacement ? !source : source;
        instructed = !forbidden;
      }
      result.add(
        RoutingConstraint(
          protocol: protocol,
          start: match.start,
          end: match.end,
          evidenceStart: replacement == null
              ? (cue == null
                    ? match.start
                    : match.start - prefix.length + cue.start)
              : negatedAt(text, replacement.start)
              ? replacement.start -
                    clausePrefix(text, replacement.start).length +
                    (_negative
                            .allMatches(clausePrefix(text, replacement.start))
                            .lastOrNull
                            ?.start ??
                        0)
              : replacement.start,
          evidenceEnd: replacement?.end ?? match.end,
          forbidden: forbidden,
          instructed: instructed,
        ),
      );
    }
    return result;
  }
}
