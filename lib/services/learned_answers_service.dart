import 'network_math.dart';

/// Learning from keyed-model answers, for offline replay.
///
/// When a model (Gemini / any OpenAI-compatible endpoint) answers a
/// question, the pair is captured so the OFFLINE assistant can return the
/// same answer next time the same question is asked with no key. The
/// capture is deliberately picky about what it stores:
///
/// * only question-shaped asks ("what is ip", "how does ospf work") - a
///   build brief or a change instruction is a request, not knowledge;
/// * only answers that pass a structural check (not a refusal, not an
///   error stub, sane length);
/// * only answers that do not contradict a fact the app can COMPUTE - if
///   the question names a CIDR and the answer claims a host count,
///   [NetworkMath] arbitrates before anything is stored.
///
/// The smart pick, when the same question was answered more than once:
/// an answer the model REPEATED (agreement across independent calls) is
/// confirmed and outranks a one-off; among equals, the most recently
/// seen wins. So contradictory one-off answers lose to the answer the
/// model consistently gives, without anyone hand-picking.
///
/// Pure and synchronous - the store ([MemoryService]) owns persistence;
/// this class owns the decisions.
class LearnedAnswer {
  final int id;
  final String qkey;
  final String question;
  final String answer;
  final String source;
  final int seenCount;
  final bool confirmed;
  final String createdAt;
  final String lastSeenAt;

  const LearnedAnswer({
    this.id = 0,
    required this.qkey,
    required this.question,
    required this.answer,
    this.source = '',
    this.seenCount = 1,
    this.confirmed = false,
    required this.createdAt,
    required this.lastSeenAt,
  });
}

/// What [LearnedAnswers.capture] decided to do with one model answer.
class LearnedCapture {
  /// Persist as a NEW candidate for this question.
  static const learned = 'learned';

  /// The answer AGREES with an existing candidate: bump its seen count
  /// (and confirm it - repetition across independent calls is the signal).
  static const agrees = 'agrees';

  /// Rejected: refusal, error stub, out of scope, or contradicting a
  /// computable fact. Nothing is stored.
  static const rejected = 'rejected';

  final String action;

  /// For [agrees]: the id of the existing candidate to bump.
  final int existingId;

  /// For [learned]: the candidate to insert.
  final LearnedAnswer? candidate;

  /// For [rejected]: the human-readable reason (for tests and logs).
  final String reason;

  const LearnedCapture.learn(LearnedAnswer this.candidate)
    : action = learned,
      existingId = 0,
      reason = '';

  const LearnedCapture.agree(this.existingId)
    : action = agrees,
      candidate = null,
      reason = '';

  const LearnedCapture.reject(this.reason)
    : action = rejected,
      existingId = 0,
      candidate = null;
}

class LearnedAnswers {
  const LearnedAnswers._();

  /// Stored answers are capped: the learned table is a working memory, not
  /// an archive. Oldest-seen entries are dropped beyond this.
  static const int maxAnswers = 500;

  /// Bounds on what is worth remembering verbatim.
  static const int minAnswerLength = 30;
  static const int maxAnswerLength = 8000;

  /// Two answers to the same question AGREE when the shorter one's content
  /// tokens are contained in the longer one's to this degree (directional
  /// containment, not Jaccard: the same knowledge said at length and said
  /// briefly must match, even though the long one adds words).
  static const double agreementThreshold = 0.62;

  // --- what is learnable ----------------------------------------------------

  /// True when [text] is a question whose answer is knowledge worth
  /// remembering: question-shaped, not a request the planner owns, not a
  /// slash command, and inside the app's networking scope.
  static bool isLearnableQuestion(String text) {
    final t = text.trim().toLowerCase();
    if (t.length < 8 || t.contains('\n')) return false;
    if (t.startsWith('/')) return false;
    // A device COUNT is a build brief ("2 routers and 4 PCs"), a change
    // or a repair is an instruction - the planner owns all of these and
    // the answer would be a plan dump, not knowledge.
    if (RegExp(
      r'\d+\s*(routers?|switches|switch|pcs?|servers?|laptops?|printers?'
      r'|firewalls?)',
    ).hasMatch(t)) {
      return false;
    }
    if (RegExp(r'^(add|remove|delete|fix|repair|change|set|use|build|make)\b')
        .hasMatch(t)) {
      return false;
    }
    final questionShaped = t.startsWith('how ') ||
        t.startsWith('what ') ||
        t.startsWith('why ') ||
        t.startsWith('when ') ||
        t.startsWith('which ') ||
        t.startsWith('where ') ||
        t.startsWith('who ') ||
        t.endsWith('?') ||
        t.contains('what is ') ||
        t.contains('what are ') ||
        t.contains('difference between') ||
        t.contains('how do ') ||
        t.contains('how does ');
    if (!questionShaped) return false;
    // The offline brain is networking-only; it should not learn (and later
    // answer from memory) anything it would decline as out of scope.
    if (_offTopic(t)) return false;
    return true;
  }

  /// The off-topic patterns that matter for a QUESTION (the full ScopeGate
  /// decline list, minus anything a networking question can carry).
  static bool _offTopic(String t) {
    return RegExp(
      r'\b(weather|horoscope|celebrit|gossip|stock (price|market)|exchange '
      r"rate|recipe|movie|song|joke|poem|essay|homework|resume|recipe)\b",
    ).hasMatch(t);
  }

  // --- capture --------------------------------------------------------------

  /// Decide what to do with one model answer to [question].
  static LearnedCapture capture({
    required String question,
    required String answer,
    required String source,
    required List<LearnedAnswer> existing,
    String? now,
  }) {
    final stamp = now ?? DateTime.now().toIso8601String();
    final text = answer.trim();
    if (text.isEmpty) {
      return const LearnedCapture.reject('empty answer');
    }
    if (text.length < minAnswerLength || text.length > maxAnswerLength) {
      return const LearnedCapture.reject('answer length out of bounds');
    }
    final refusal = _refusal.firstMatch(text.toLowerCase());
    if (refusal != null) {
      return LearnedCapture.reject('refusal-shaped answer: ${refusal.group(0)}');
    }
    final conflict = _factConflict(question, text);
    if (conflict != null) {
      return LearnedCapture.reject(conflict);
    }
    // Agreement: an answer the model has effectively given before is the
    // same knowledge said again - that repetition IS the confirmation.
    for (final candidate in existing) {
      if (answersAgree(candidate.answer, text)) {
        return LearnedCapture.agree(candidate.id);
      }
    }
    return LearnedCapture.learn(
      LearnedAnswer(
        qkey: keyFor(question),
        question: question.trim(),
        answer: text,
        source: source,
        // A CIDR question survived the fact check: the count (if any) in
        // this answer was computed against [NetworkMath] and agreed, so
        // the answer is confirmed knowledge from day one. Every other
        // answer starts unconfirmed and earns it by repetition.
        confirmed: RegExp(r'/\s*\d{1,2}').hasMatch(question),
        createdAt: stamp,
        lastSeenAt: stamp,
      ),
    );
  }

  /// Refusal / error shapes that must never enter memory as knowledge.
  static final RegExp _refusal = RegExp(
    r"i (?:cannot|can't|can not|am unable|'m unable)|"
    r"i(?:'m| am) sorry|i apologize|as an ai|"
    r'cannot help|unable to help|not able to help|'
    r'returned nothing usable|violat(?:e|ing) (?:my )?policy|'
    r'rate limit|quota|api key',
    caseSensitive: false,
  );

  /// A computable-fact conflict, or null. The only facts the app can
  /// arbitrate offline are the ones [NetworkMath] owns: when the question
  /// names a CIDR and the answer states a usable-host count, the math is
  /// the truth and a disagreeing answer must not be remembered.
  static String? _factConflict(String question, String answer) {
    final cidrs = RegExp(
      r'\b\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2}\b',
    ).allMatches(question);
    if (cidrs.isEmpty) return null;
    final counts = RegExp(
      r'(\d[\d,]{0,12})\s*(?:usable\s+)?(?:host|device|address)',
      caseSensitive: false,
    ).allMatches(answer);
    if (counts.isEmpty) return null;
    for (final m in cidrs) {
      final normalized = m.group(0)!.replaceAll(' ', '');
      final facts = NetworkMath.facts(normalized);
      if (facts['ok'] != true) continue;
      final expected = facts['usableHosts'];
      if (expected is! int) continue;
      for (final c in counts) {
        final claimed = int.tryParse(c.group(1)!.replaceAll(',', ''));
        if (claimed == null || claimed == expected) continue;
        return 'answer claims $claimed usable hosts for $normalized '
            'but the computed count is $expected';
      }
    }
    return null;
  }

  // --- the smart pick -------------------------------------------------------

  /// The answer to serve offline for this question: confirmed knowledge
  /// first (the model repeated it, or it survived the fact check), then
  /// agreement count, then recency. A question answered once with a
  /// contradictory one-off still serves - flagged unconfirmed - but loses
  /// to any repeated answer.
  static LearnedAnswer? pickBest(List<LearnedAnswer> candidates) {
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]..sort((a, b) {
        if (a.confirmed != b.confirmed) return a.confirmed ? -1 : 1;
        if (a.seenCount != b.seenCount) return b.seenCount - a.seenCount;
        final bySeen = b.lastSeenAt.compareTo(a.lastSeenAt);
        if (bySeen != 0) return bySeen;
        return b.createdAt.compareTo(a.createdAt);
      });
    return sorted.first;
  }

  /// Do two answers carry the same knowledge? Content tokens (stopwords
  /// and scaffolding removed, crude stemming), directional containment of
  /// the smaller token set in the larger against [agreementThreshold] -
  /// plus a shared-token floor, because containment degenerates on tiny
  /// sets (two shared words would otherwise confirm anything that names
  /// the same two terms).
  static bool answersAgree(String a, String b) {
    final ta = _contentTokens(a);
    final tb = _contentTokens(b);
    if (ta.isEmpty || tb.isEmpty) return false;
    final shared = ta.intersection(tb).length;
    if (shared < 3) return false;
    final smaller = ta.length < tb.length ? ta.length : tb.length;
    return shared / smaller >= agreementThreshold;
  }

  static const Set<String> _stopwords = {
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'to', 'of', 'and',
    'or', 'in', 'on', 'at', 'for', 'with', 'as', 'by', 'it', 'its', 'this',
    'that', 'you', 'your', 'can', 'will', 'do', 'does', 'not', 'if', 'when',
    'use', 'used', 'using', 'set', 'get', 'have', 'has', 'had', 'so', 'than',
    'then', 'there', 'here', 'which', 'what', 'how', 'why', 'from', 'into',
    'also', 'about', 'up', 'out', 'one', 'two', 'each', 'all', 'any', 'may',
    'should', 'would', 'could', 'must', 'need', 'want', 'make', 'made',
  };

  static Set<String> _contentTokens(String text) {
    final out = <String>{};
    for (final w in text.toLowerCase().split(RegExp(r'[^a-z0-9#/]+'))) {
      if (w.length < 3 || _stopwords.contains(w)) continue;
      out.add(_stem(w));
    }
    return out;
  }

  static String _stem(String w) {
    for (final suffix in const ['ing', 'ies', 'es', 's']) {
      if (w.length > suffix.length + 2 && w.endsWith(suffix)) {
        return w.substring(0, w.length - suffix.length);
      }
    }
    return w;
  }

  /// The storage key for a question: lowercase, punctuation and filler
  /// collapsed, so "What is IP?" and "what is ip" land on the same row.
  static String keyFor(String question) {
    var t = question.trim().toLowerCase();
    t = t.replaceAll(RegExp(r'[?!.,;:"'']'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }
}
