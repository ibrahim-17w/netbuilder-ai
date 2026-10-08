import '../models/design_brief.dart';
import '../models/environment_profile.dart';
import '../models/network_intent.dart';
import 'memory_service.dart';

/// One clarifying question the chat may ask before committing a plan.
class ClarificationQuestion {
  /// Stable id - the key answers are remembered under.
  final String id;

  /// The question, phrased so "just build it" is never the only way out.
  final String question;

  /// The tappable replies, worded as a person would answer.
  final List<String> quickReplies;

  /// The canonical value each quick reply resolves to (same length/order as
  /// [quickReplies]).
  final List<String> quickReplyValues;

  const ClarificationQuestion({
    required this.id,
    required this.question,
    required this.quickReplies,
    required this.quickReplyValues,
  });
}

/// Ask before you plan - with a memory.
///
/// When a build-shaped request leaves a CRITICAL brief slot open, the chat
/// asks at most two short questions instead of committing a plan. Answers
/// are remembered (see [MemoryService.rememberClarification]) keyed against
/// the environment's venue, so the same person is never asked the same
/// thing twice - a home-lab "static" answer must not silently become the
/// office answer, but an answer given with no site in play applies
/// everywhere.
///
/// Only scale/routing/segmentation are ever asked. Wireless, security and
/// venue have safe planner defaults or are optional; a brief that
/// interrogates the user is as bad as one that guesses.
class ClarificationService {
  const ClarificationService._();

  /// The scale question, reused by the lookup map.
  static const scaleQuestion = ClarificationQuestion(
    id: 'scale',
    question: 'How many people or devices should the network serve?',
    quickReplies: ['10', '25', '50'],
    quickReplyValues: ['10', '25', '50'],
  );

  static const routingQuestion = ClarificationQuestion(
    id: 'routing',
    question:
        'How should the routers route - static routes or a dynamic '
        'protocol like OSPF?',
    quickReplies: ['Static routes', 'OSPF'],
    quickReplyValues: ['static', 'ospf'],
  );

  static const segmentationQuestion = ClarificationQuestion(
    id: 'segmentation',
    question: 'Should the network be one flat LAN, or split into VLANs?',
    quickReplies: ['One flat network', 'Split into VLANs'],
    quickReplyValues: ['none', 'vlans'],
  );

  static ClarificationQuestion? questionById(String id) => switch (id) {
    'scale' => scaleQuestion,
    'routing' => routingQuestion,
    'segmentation' => segmentationQuestion,
    _ => null,
  };

  /// Which questions this turn needs, most critical first, at most two.
  ///
  /// [rememberedQuestionIds] are ids the environment profile already
  /// answered - they are never asked again.
  static List<ClarificationQuestion> neededFor({
    required DesignBrief brief,
    NetworkIntent? plan,
    EnvironmentProfile? profile,
    required Set<String> rememberedQuestionIds,
  }) {
    final out = <ClarificationQuestion>[];

    /// [provisional] marks a slot whose value was DERIVED from the parsed
    /// plan rather than stated by anyone: it is still asked, because a
    /// device count is not an answer to "how many should this serve". The
    /// user's answer outranks it (see [BriefFact.rank]), so confirming it
    /// settles what the derivation only guessed and costs one tap.
    void consider(String id, bool needed, {bool provisional = false}) {
      if (!needed) return;
      if (rememberedQuestionIds.contains(id)) return;
      final fact = brief.fact(id);
      if (fact != null && (fact.origin != BriefSource.plan || !provisional)) {
        return;
      }
      final q = questionById(id);
      if (q != null) out.add(q);
    }

    // Scale: the one fact almost every downstream decision sizes from. A
    // scale the plan counted out of routers and switches is provisional -
    // the lab's shape, not its load - so it is confirmed like an open slot.
    consider('scale', true, provisional: true);
    // Routing only matters once there is more than one router to keep in
    // step - a single-router lab with a default route has nothing to ask.
    final routerCount =
        plan?.nodes.where((n) => n.type == 'router').length ?? 0;
    consider('routing', routerCount >= 2);
    // Segmentation earns a question only when something actually separates:
    // a server to protect, or a venue where separation is the norm.
    final hasServer = plan?.nodes.any((n) => n.type == 'server') ?? false;
    final venue = profile?.venue ?? brief.value(DesignBrief.venue);
    consider(
      'segmentation',
      hasServer || venue == 'office' || venue == 'school',
    );
    return out.take(2).toList();
  }

  /// Turn a reply into a canonical fact, or null when the reply is not
  /// resolvable (fail-closed: the chat asks again rather than guesses).
  ///
  /// The returned fact carries NO origin or source - the caller wraps it
  /// (a tapped quick reply is a user decision; a remembered replay is
  /// [BriefSource.remembered] with its own provenance line).
  static BriefFact? resolveAnswer(ClarificationQuestion q, String answerText) {
    final t = answerText.trim().toLowerCase();
    if (t.isEmpty) return null;
    // Quick replies map exactly (case-insensitive).
    for (var i = 0; i < q.quickReplies.length; i++) {
      if (q.quickReplies[i].trim().toLowerCase() == t) {
        final value = q.quickReplyValues[i];
        return BriefFact(
          value: value,
          // Canonical display, not the button's wording: '25' becomes
          // '25 users', 'One flat network' becomes the lowercase form the
          // free-text path produces too - so the ack and the brief card are
          // consistent however the answer arrived.
          display: switch (q.id) {
            'scale' => '$value users',
            'segmentation' =>
              value == 'none' ? 'one flat network' : 'VLANs',
            _ => _display(q, value),
          },
        );
      }
    }
    return switch (q.id) {
      'scale' => _resolveScale(t),
      'routing' => _resolveRouting(t),
      'segmentation' => _resolveSegmentation(t),
      _ => null,
    };
  }

  static BriefFact? _resolveScale(String t) {
    final m = RegExp(r'\b(\d{1,4})\b').firstMatch(t);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!);
    if (n == null || n <= 0 || n > 5000) return null;
    return BriefFact(value: '$n', display: '$n users');
  }

  static BriefFact? _resolveRouting(String t) {
    // Negation binds: "not static" states a rejection, not a choice.
    if (RegExp(r'\bnot\s+(?:static|ospf|eigrp|rip)\b').hasMatch(t)) {
      return null;
    }
    if (RegExp(r'\bospf\b').hasMatch(t)) {
      return const BriefFact(value: 'ospf', display: 'OSPF');
    }
    if (RegExp(r'\beigrp\b').hasMatch(t)) {
      return const BriefFact(value: 'eigrp', display: 'EIGRP');
    }
    if (RegExp(r'\brip\b').hasMatch(t)) {
      return const BriefFact(value: 'rip', display: 'RIP');
    }
    if (RegExp(r'\bstatic\b|\bstatic routes?\b|\bstatic routing\b')
        .hasMatch(t)) {
      return const BriefFact(value: 'static', display: 'Static routes');
    }
    return null;
  }

  static BriefFact? _resolveSegmentation(String t) {
    if (RegExp(r'\bflat\b|\bno vlans?\b|\bone (?:lan|network)\b')
        .hasMatch(t)) {
      return const BriefFact(value: 'none', display: 'one flat network');
    }
    if (RegExp(r'\bvlans?\b|\bsplit\b|\bsegment').hasMatch(t)) {
      return const BriefFact(value: 'vlans', display: 'VLANs');
    }
    return null;
  }

  static String _display(ClarificationQuestion q, String canonicalValue) {
    for (var i = 0; i < q.quickReplyValues.length; i++) {
      if (q.quickReplyValues[i] == canonicalValue) return q.quickReplies[i];
    }
    return canonicalValue;
  }

  /// The remembered answer for a question, as a fact ready for the brief -
  /// or null. This is the "never ask twice" path: the value arrives with
  /// its provenance attached, so the chat can say "from your earlier
  /// answer" and the brief card can show it honestly.
  static Future<BriefFact?> rememberedAnswer({
    required String questionId,
    required EnvironmentProfile? profile,
    required MemoryService mem,
  }) async {
    final q = questionById(questionId);
    if (q == null) return null;
    final answer = await mem.answerForClarification(questionId, profile);
    if (answer == null) return null;
    final resolved = resolveAnswer(q, answer);
    if (resolved == null) return null;
    return BriefFact(
      value: resolved.value,
      display: resolved.display,
      source: 'remembered from an earlier answer',
      origin: BriefSource.remembered,
    );
  }
}
