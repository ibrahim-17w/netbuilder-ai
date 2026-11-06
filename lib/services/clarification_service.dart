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
/// asks at most two short questions instead of committing a plan. A one-off
/// answer stays with its conversation; only an explicit request to remember
/// it may be written to [MemoryService] and reused for another project.
///
/// Only scale/routing/segmentation are ever asked. Wireless, security and
/// venue have safe planner defaults or are optional; a brief that
/// interrogates the user is as bad as one that guesses.
class ClarificationService {
  const ClarificationService._();

  /// The scale question, reused by the lookup map.
  static const scaleQuestion = ClarificationQuestion(
    id: 'scale',
    question:
        'How many PCs or end-user devices should this design include? If you '
        'mean people served, tell me that and I will check capacity separately.',
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

  /// Read an explicit request to reuse a routing choice for later labs.
  ///
  /// Keeping this separate from ordinary routing answers prevents a memory
  /// request such as "remember OSPF for future office labs" from changing the
  /// currently open plan. The venue is stored with the answer so it only
  /// applies when a later environment profile matches it.
  static ({String protocol, String venue})? rememberedRoutingRequest(
    String text,
  ) {
    if (text.trim().endsWith('?')) return null;
    final match = RegExp(
      r'^\s*(?:please\s+)?remember\s+(?:to\s+(?:use|prefer)\s+)?'
      r'(ospf|eigrp|bgp|static)\s+for\s+future\s+'
      r'(?:(home|office|school|clinic|hospitality|industrial)\s+)?'
      r'labs?\s*[.!]?\s*$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return (
      protocol: match.group(1)!.toLowerCase(),
      venue: (match.group(2) ?? '').toLowerCase(),
    );
  }

  /// Which questions this turn needs, most critical first, at most two.
  ///
  /// [rememberedQuestionIds] are ids the environment profile already
  /// answered - they are never asked again.
  static List<ClarificationQuestion> neededFor({
    required DesignBrief brief,
    NetworkIntent? plan,
    EnvironmentProfile? profile,
    required Set<String> rememberedQuestionIds,
    String instruction = '',
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
      if (fact != null &&
          !(id == DesignBrief.scale &&
              fact.quantityKind == QuantityKind.userLoad) &&
          (fact.origin != BriefSource.plan || !provisional)) {
        return;
      }
      final q = questionById(id);
      if (q != null) out.add(q);
    }

    // Ask for capacity only when the request has not already specified the
    // network inventory. A complete device list is not an invitation to ask
    // the user how many devices they wanted.
    final text = instruction.toLowerCase();
    // Router/switch counts describe the infrastructure, not how many client
    // devices it must support. Skip the generic sizing question only when
    // the user has specified end-device inventory (including named PCs).
    final specifiedInventory =
        RegExp(
          r'\b(?:pcs?|computers?|hosts?|workstations?|endpoints?|'
          r'laptops?|phones?|tablets?|clients?|end devices?)\b',
        ).hasMatch(text) ||
        RegExp(r'\bpc\d{1,2}\b').hasMatch(text);
    consider(
      'scale',
      !specifiedInventory ||
          brief.fact(DesignBrief.scale)?.quantityKind == QuantityKind.userLoad,
      provisional: true,
    );
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
          // '25 devices', 'One flat network' becomes the lowercase form the
          // free-text path produces too - so the ack and the brief card are
          // consistent however the answer arrived.
          display: switch (q.id) {
            'scale' => '$value devices',
            'segmentation' => value == 'none' ? 'one flat network' : 'VLANs',
            _ => _display(q, value),
          },
          quantityKind: q.id == DesignBrief.scale
              ? QuantityKind.deviceInventory
              : QuantityKind.unspecified,
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

  /// Resolve every pending question answered clearly by one message. The map
  /// is keyed by question ID so question order cannot make one answer consume
  /// another. Numeric answers require an unambiguous scale quantity.
  static Map<String, BriefFact> resolveAnswers({
    required List<ClarificationQuestion> questions,
    required String answerText,
  }) {
    final answers = <String, BriefFact>{};
    for (final question in questions) {
      final fact = resolveAnswer(question, answerText);
      if (fact != null) answers[question.id] = fact;
    }
    return answers;
  }

  /// Reconcile a supported answer into a candidate plan. Returning null
  /// means the answer cannot be represented without guessing; callers must
  /// keep it unresolved instead of acknowledging a change that did not land.
  static NetworkIntent? reconcilePlanWithFact({
    required NetworkIntent? plan,
    required String questionId,
    required BriefFact fact,
    String previousBrief = '',
  }) {
    if (plan == null || plan.nodes.isEmpty) return null;
    try {
      if (questionId == DesignBrief.routing) {
        if (!const [
          'static',
          'ospf',
          'eigrp',
          'bgp',
          'rip',
          'none',
        ].contains(fact.value)) {
          return null;
        }
        return plan.routing.toLowerCase() == fact.value
            ? plan
            : plan.copyWith(routing: fact.value);
      }
      if (questionId == DesignBrief.scale) {
        if (fact.quantityKind == QuantityKind.userLoad) return plan;
        final wanted = int.tryParse(fact.value) ?? 0;
        if (wanted <= 0 || wanted > 5000) return null;
        final pcs = plan.nodes.where((node) => node.type == 'pc').length;
        if (wanted == pcs) return plan;

        // This question confirms a total, so use count-correction semantics.
        // "add 40" would turn an existing ten-PC plan into fifty PCs.
        const correctionPrefix = 'actually';
        final briefText = '$correctionPrefix $wanted pcs';
        final outcome = NetworkIntent.followUp(
          previous: plan,
          previousBrief: previousBrief,
          brief: briefText,
          parsed: NetworkIntent.parseSimple('clarification', briefText),
          project: plan.projectName,
        );
        if (outcome.plan.nodes.where((node) => node.type == 'pc').length !=
            wanted) {
          return null;
        }
        // A scale answer changes the inventory total only. The re-read above
        // can reconstruct the topology from an older prose brief that does
        // not include a routing choice made by a later clarification, so
        // carry the standing protocol through the count correction.
        return outcome.plan.copyWith(routing: plan.routing);
      }
      if (questionId == DesignBrief.segmentation) {
        if (fact.value == 'none' && plan.vlans.isEmpty) return plan;
        if (fact.value == 'vlans' && plan.vlans.isNotEmpty) return plan;
        // The plan currently has VLAN IDs but not enough membership/policy
        // data to safely switch segmentation modes here.
        return null;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static BriefFact? _resolveScale(String t) {
    final normalized = t.replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (match) {
      final digit = match.group(0)!.codeUnitAt(0);
      return '${digit >= 0x06f0 ? digit - 0x06f0 : digit - 0x0660}';
    });
    final numberMatches = RegExp(r'\d+').allMatches(normalized).toList();
    if (numberMatches.length != 1) return null;
    final m = numberMatches.single;
    final number = m.group(0)!;
    final exactNumber = RegExp(r'^\s*\d{1,4}\s*$').hasMatch(normalized);
    final afterNumber = normalized.substring(m.end).trimLeft();
    final userLoad = RegExp(
      r'^(?:users?|people|staff|employees?|students?|clients?|customers?|'
      r'seats?)\b|^(?:مستخدمون|مستخدمين|موظفون|موظفين)(?:\s|$)',
    ).hasMatch(afterNumber);
    final deviceInventory = RegExp(
      r'^(?:devices?|hosts?|pcs?|computers?|workstations?|endpoints?)\b'
      r'|^(?:جهاز|اجهزه)(?:\s|$)',
    ).hasMatch(afterNumber);
    final quantity = userLoad || deviceInventory;
    if (!exactNumber && !quantity) return null;

    final n = int.tryParse(number);
    if (n == null || n <= 0 || n > 5000) return null;
    if (exactNumber &&
        (NetworkIntent.ptRouters.contains(number) ||
            NetworkIntent.ptSwitches.contains(number))) {
      return null;
    }
    return BriefFact(
      value: '$n',
      display: userLoad ? '$n users' : '$n devices',
      quantityKind: userLoad
          ? QuantityKind.userLoad
          : QuantityKind.deviceInventory,
    );
  }

  static BriefFact? _resolveRouting(String t) {
    // Negation binds: "not static" states a rejection, not a choice.
    final matches = RegExp(r'\b(ospf|eigrp|bgp|rip|static)\b')
        .allMatches(t)
        .where((match) {
          final start = match.start == 0
              ? -1
              : t.lastIndexOf(RegExp(r'[.;,!?\n]'), match.start - 1);
          final before = t.substring(start < 0 ? 0 : start + 1, match.start);
          return !RegExp(
            r"\b(?:not|no|never|avoid|without|don['’]?t|do\s+not|instead\s+of)\b"
            r'(?:\s+\w+){0,2}\s*$',
          ).hasMatch(before.trimRight());
        })
        .map((match) => match.group(1)!)
        .toSet();
    if (matches.length != 1) return null;
    final protocol = matches.single;
    return BriefFact(
      value: protocol,
      display: protocol == 'static' ? 'Static routes' : protocol.toUpperCase(),
    );
  }

  static BriefFact? _resolveSegmentation(String t) {
    if (RegExp(r'\bflat\b|\bno vlans?\b|\bone (?:lan|network)\b').hasMatch(t)) {
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
