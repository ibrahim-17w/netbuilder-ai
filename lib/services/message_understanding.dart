import '../models/network_intent.dart';
import 'file_edit_intent.dart';

/// One structured reading of a user message: the kind of turn it is, what
/// was recognized - with the exact words and their position in the message -
/// corrections, references to a file ("it", "that file"), open questions and
/// confidence.
///
/// Assembled from the services that already make these decisions (the
/// planner's public brief classifier, the routing resolver, the file
/// reader), so the card can explain what was understood and why WITHOUT a
/// second parser that could drift away from the real one.
class MessageUnderstanding {
  /// One of: empty, social, advice, howto, question, confirm, growth,
  /// addition, build, change, statement (see [NetworkIntent.classifyBrief]).
  final String kind;

  /// Recognized details, in message order. Each keeps the words it came
  /// from and where they are.
  final List<RecognizedDetail> details;

  /// "not OSPF", "actually 8", "instead of EIGRP", "more than 2 switches".
  final List<RecognizedDetail> corrections;

  /// The first pointer at a saved file, when the words referred to one.
  final RecognizedDetail? reference;

  /// Questions the plan still carries for this turn.
  final List<String> openQuestions;

  /// The parser's confidence, 0 when there is no plan.
  final double confidence;

  /// One short sentence: how this turn was read, and what it does to the
  /// plan.
  final String why;

  const MessageUnderstanding({
    required this.kind,
    required this.details,
    required this.corrections,
    required this.reference,
    required this.openQuestions,
    required this.confidence,
    required this.why,
  });

  static final RegExp _count = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|computers?|servers?|'
    r'laptops?|printers?|phones?|firewalls?|tablets?|access\s+points?|aps?)\b',
    caseSensitive: false,
  );
  static final RegExp _cidr =
      RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2}\b');
  static final RegExp _vlan = RegExp(r'\bvlan\s*\d{1,4}\b', caseSensitive: false);
  static final RegExp _correction = RegExp(
    r"\b(?:not\s+[a-z]+|don'?t\s+use\s+[a-z]+|instead\s+of\s+[a-z]+|"
    r"rather\s+than\s+[a-z]+|actually\s+\d{1,3}|no\s+wait|"
    r"more\s+than\s+\d{1,3}\s+[a-z]+|over\s+\d{1,3}\s+[a-z]+)\b",
    caseSensitive: false,
  );

  /// Read [text] through the same rules the planner uses. [parsed] is the
  /// turn's plan when one was produced (it may be null: a question or a
  /// greeting produces none).
  static MessageUnderstanding read({
    required String text,
    NetworkIntent? parsed,
  }) {
    final trimmed = text.trim();
    final kind = NetworkIntent.classifyBrief(trimmed);

    final details = <RecognizedDetail>[];
    void collect(RegExp re, String label) {
      for (final m in re.allMatches(trimmed)) {
        final excerpt = m.group(0)!.trim();
        if (excerpt.isEmpty) continue;
        details.add(RecognizedDetail(label, excerpt, m.start));
      }
    }

    collect(_count, 'count');
    collect(_cidr, 'subnet');
    collect(_vlan, 'vlan');
    final routing = NetworkIntent.resolveRouting(trimmed.toLowerCase());
    if (routing != null) {
      final m = RegExp('\\b$routing\\b', caseSensitive: false)
          .firstMatch(trimmed);
      if (m != null) {
        details.add(RecognizedDetail('routing', m.group(0)!, m.start));
      }
    }
    details.sort((a, b) => a.offset.compareTo(b.offset));

    final corrections = <RecognizedDetail>[];
    for (final m in _correction.allMatches(trimmed)) {
      corrections.add(RecognizedDetail('correction', m.group(0)!.trim(), m.start));
    }

    final ref = FileEditIntentReader.referenceIn(trimmed);

    return MessageUnderstanding(
      kind: kind,
      details: details,
      corrections: corrections,
      reference: ref == null
          ? null
          : RecognizedDetail('reference', ref.excerpt, ref.offset),
      openQuestions: parsed?.questions ?? const [],
      confidence: parsed?.confidence ?? 0,
      why: whyFor(kind),
    );
  }

  /// The human sentence for a [kind]: how the turn was read and what it does
  /// to the plan.
  static String whyFor(String kind) {
    switch (kind) {
      case 'social':
        return 'a greeting or acknowledgement - the plan is untouched.';
      case 'advice':
        return 'an advice question - answered with a recommendation, and the '
            'plan is untouched.';
      case 'howto':
        return 'a how-to question - answered, and the plan is untouched.';
      case 'question':
        return 'a question about the lab - the plan is untouched.';
      case 'confirm':
        return 'a confirmation - the plan on the table is what would build.';
      case 'growth':
        return 'a growth request - the lab only grows to meet it, never shrinks.';
      case 'addition':
        return 'an addition to the standing lab.';
      case 'change':
        return 'a change request for the standing lab.';
      case 'build':
        return 'a build request, read into the plan above.';
      case 'statement':
        return 'a description of the lab.';
      default:
        return '';
    }
  }
}

/// One recognized piece of a message: what it is, the words it came from,
/// and where those words sit in the message.
class RecognizedDetail {
  /// 'count', 'subnet', 'vlan', 'routing', 'correction', 'reference'.
  final String label;
  final String excerpt;
  final int offset;
  const RecognizedDetail(this.label, this.excerpt, this.offset);
}
