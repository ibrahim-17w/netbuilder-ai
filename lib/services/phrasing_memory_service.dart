import '../models/network_intent.dart';

/// Phrasing memory: the app's way of learning an English phrasing WITHOUT a
/// model.
///
/// The rule: when a turn turned an underspecified earlier phrasing into a
/// resolved brief (the user clarified, or a change landed), the pair
/// `normalized phrasing -> resolved brief` is stored in SQLite. Next time the
/// same words appear, the parser reads the stored rewrite as if the user had
/// typed it - exactly the mechanism [SizingService.expandBrief] already uses,
/// but learned from the conversation instead of written by hand.
///
/// Everything here is deterministic and conservative:
///
/// * only phrasings the user personally caused are ever replayed;
/// * a message that already states device counts is parsed as written and is
///   never overridden by the index;
/// * near matching requires near-identical content tokens (>= 3 shared, >=
///   75% containment), so two different requests never collide;
/// * the index is capped and lives in the Memory screen, where it can be
///   reviewed and cleared.
/// What one row of the index says.
class _Entry {
  final String phrasing;
  final String rewrite;
  const _Entry(this.phrasing, this.rewrite);
}

/// One lesson worth remembering.
class PhrasingLearnRequest {
  final String key;
  final String rewrite;
  const PhrasingLearnRequest({required this.key, required this.rewrite});
}

/// One memory hit: what was remembered, and how well it matched the brief.
class PhrasingMatch {
  /// The learned phrasing this brief matched (its normalized key).
  final String key;

  /// The resolved brief the learned phrasing carries.
  final String rewrite;

  /// True when the brief IS the learned phrasing, not a near twin.
  final bool exact;

  /// 1.0 for an exact match; the conservative token score for a near one.
  final double score;

  const PhrasingMatch({
    required this.key,
    required this.rewrite,
    required this.exact,
    required this.score,
  });
}

class PhrasingMemoryService {
  const PhrasingMemoryService._();

  /// The live index consulted by `NetworkIntent.parseSimple`. Loaded from
  /// SQLite when memory opens and refreshed on every teach/delete/clear.
  static List<_Entry> _index = const [];

  /// The index as data, for tests and the Memory screen.
  static List<({String phrasing, String rewrite})> get indexView => [
        for (final e in _index) (phrasing: e.phrasing, rewrite: e.rewrite),
      ];

  /// Replace the live index (called by MemoryService after any change).
  static void setIndex(Iterable<({String phrasing, String rewrite})> rows) {
    _index = [for (final r in rows) _Entry(r.phrasing, r.rewrite)];
  }

  static void clearIndex() => _index = const [];

  static bool get isEmpty => _index.isEmpty;

  /// The stored key for a message: the brief is BRIDGED first (spelled
  /// numbers, Arabic digits, leading ask-verbs normalized), then lower-
  /// cased, punctuation stripped (digits, dots and slashes kept - they
  /// carry meaning in a brief), whitespace collapsed. Bridging inside the
  /// key is what lets teach and lookup agree: the chat stores the words the
  /// user said, the parser queries the bridged brief, and both land on one
  /// canonical key (bridgeBrief is idempotent, so the two paths meet).
  static String normalizeKey(String text) => NetworkIntent.bridgeBrief(text)
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9./\s-]+"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// A brief that already states device counts is parsed exactly as written -
  /// the index (and the sizing pack) must never second-guess it.
  static final RegExp _explicitCounts = RegExp(
    r'\b\d{1,3}\s*(routers?|switches|switch|pcs?|servers?|laptops?|printers?|'
    r'firewalls?|access points?|aps?|phones?|tablets?|clouds?|modems?|'
    r'cameras?)\b',
    caseSensitive: false,
  );

  static final Set<String> _stopwords = {
    'a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'with',
    'at', 'by', 'is', 'are', 'be', 'do', 'does', 'did', 'i', 'we', 'you',
    'my', 'our', 'your', 'it', 'this', 'that', 'these', 'those', 'please',
    'can', 'could', 'would', 'will', 'want', 'need', 'build', 'make',
    'me', 'us', 'so', 'up', 'out', 'if', 'then', 'from', 'into', 'just',
    'really', 'very', 'well', 'okay', 'ok', 'yeah', 'yes', 'no', 'not',
    'now', 'here', 'there', 'what', 'which', 'why', 'how', 'when', 'also',
    'pls', 'thanks', 'thank', 'hi', 'hello', 'let', 'lets', 'get', 'got',
    'like', 'about', 'over', 'all', 'any', 'some', 'one', 'thing', 'things',
  };

  /// Content tokens: meaningful words only, length >= 2.
  static Set<String> contentTokens(String normalizedKey) => {
        for (final w in normalizedKey.split(' '))
          if (w.length >= 2 && !_stopwords.contains(w)) w,
      };

  /// The stored rewrite for this brief, or null (see [lookupMatch]).
  static String? lookup(String bridged) => lookupMatch(bridged)?.rewrite;

  /// The stored lesson this brief matches, with its kind and score.
  ///
  /// Exact normalized match first. Then a deliberately conservative near
  /// match: >= 3 shared content tokens covering >= 75% of the smaller side.
  ///
  /// A NEAR TWIN is not the same request: the wording differs precisely
  /// where the user said something new, so the caller must merge the lesson
  /// into the new message instead of replacing it (see
  /// [NetworkIntent.parseSimple]). Returning the match separately - rather
  /// than a bare rewrite string - is what makes that decision possible.
  static PhrasingMatch? lookupMatch(String bridged) {
    if (_index.isEmpty) return null;
    if (_explicitCounts.hasMatch(bridged)) return null;
    final key = normalizeKey(bridged);
    if (key.isEmpty) return null;

    for (final e in _index) {
      if (e.phrasing == key) {
        return PhrasingMatch(
          key: e.phrasing,
          rewrite: e.rewrite,
          exact: true,
          score: 1.0,
        );
      }
    }

    final keyTokens = contentTokens(key);
    if (keyTokens.length < 3) return null;
    _Entry? best;
    var bestScore = 0.0;
    for (final e in _index) {
      final other = contentTokens(e.phrasing);
      if (other.length < 3) continue;
      final shared = keyTokens.intersection(other).length;
      if (shared < 3) continue;
      final smaller =
          keyTokens.length < other.length ? keyTokens.length : other.length;
      final score = shared / smaller;
      if (score > bestScore) {
        bestScore = score;
        best = e;
      }
    }
    if (best != null && bestScore >= 0.75) {
      return PhrasingMatch(
        key: best.phrasing,
        rewrite: best.rewrite,
        exact: false,
        score: bestScore,
      );
    }
    return null;
  }

  // --- teaching ----------------------------------------------------------

  /// Decide whether this turn taught something, pure and testable.
  ///
  /// [keyText] is the EARLIER phrasing (the one that was underspecified),
  /// [keyNodes] what it parsed to; [resolvedBrief]/[resolvedNodes] is what
  /// the conversation resolved it to. A lesson exists only when the earlier
  /// phrasing was genuinely weaker than the resolution:
  ///
  /// * the earlier phrasing is a real sentence (>= 4 words) that did not
  ///   itself state device counts;
  /// * the resolution is a real lab (>= 3 devices) strictly larger than what
  ///   the earlier phrasing parsed to, and it carries explicit numbers a
  ///   replay needs;
  /// * the resolution actually differs from the earlier phrasing.
  static PhrasingLearnRequest? learnRequest({
    required String keyText,
    required int keyNodes,
    required String resolvedBrief,
    required int resolvedNodes,
  }) {
    final key = normalizeKey(keyText);
    final rewrite = resolvedBrief.trim();
    if (key.isEmpty || rewrite.isEmpty) return null;
    if (normalizeKey(rewrite) == key) return null;
    if (keyText.trim().split(RegExp(r'\s+')).length < 4) return null;
    if (_explicitCounts.hasMatch(keyText)) return null;
    if (keyNodes <= 0) return null;
    if (resolvedNodes <= keyNodes) return null;
    if (resolvedNodes < 3) return null;
    if (!RegExp(r'\d').hasMatch(rewrite)) return null;
    return PhrasingLearnRequest(key: key, rewrite: rewrite);
  }

  /// The chat's teaching hook: decide, then persist through the caller's
  /// store (the store refreshes the live index, so the very next parse sees
  /// the lesson). Any failure is swallowed - learning must never break a
  /// conversation.
  static Future<bool> teachIfResolved(
    Future<void> Function(String key, String rewrite) teach, {
    required String keyText,
    required int keyNodes,
    required String resolvedBrief,
    required int resolvedNodes,
  }) async {
    final req = learnRequest(
      keyText: keyText,
      keyNodes: keyNodes,
      resolvedBrief: resolvedBrief,
      resolvedNodes: resolvedNodes,
    );
    if (req == null) return false;
    try {
      await teach(req.key, req.rewrite);
      return true;
    } catch (_) {
      return false;
    }
  }
}
