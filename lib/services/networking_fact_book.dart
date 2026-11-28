import 'networking_facts.dart';
import 'phrase_match.dart';

/// Matches numeric and reference questions to [networkingFacts].
///
/// Each fact declares ANDed groups of ORed phrases, so a fact only answers
/// when every part of the question is present. That is what keeps "bgp timer"
/// from being answered by the OSPF fact, and "what is bgp" from being answered
/// by a fact about BGP timers.
class NetworkingFactBook {
  const NetworkingFactBook._();

  /// The answer, or null when no fact matches.
  static String? answer(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    NetworkingFact? best;
    var bestScore = 0.0;
    for (final fact in networkingFacts) {
      final score = _score(fact, t);
      if (score <= bestScore) continue;
      best = fact;
      bestScore = score;
    }
    return best?.answer;
  }

  /// Best fact for a question, for tests and for debugging.
  static NetworkingFact? bestMatch(String text) {
    final t = text.trim().toLowerCase();
    NetworkingFact? best;
    var bestScore = 0.0;
    for (final fact in networkingFacts) {
      final score = _score(fact, t);
      if (score <= bestScore) continue;
      best = fact;
      bestScore = score;
    }
    return best;
  }

  static double _score(NetworkingFact fact, String t) {
    for (final phrase in fact.excludes) {
      if (PhraseMatch.has(t, phrase)) return 0;
    }
    var total = 0.0;
    for (final group in fact.requires) {
      var longest = 0;
      for (final phrase in group) {
        if (phrase.length > longest && PhraseMatch.has(t, phrase)) {
          longest = phrase.length;
        }
      }
      if (longest == 0) return 0;
      total += longest;
    }
    // Groups are the specificity signal: a two-group fact beats a one-group
    // fact that matched the same words.
    return total + fact.requires.length * 2 + fact.priority;
  }

  static List<String> get ids => [for (final f in networkingFacts) f.id];
}
