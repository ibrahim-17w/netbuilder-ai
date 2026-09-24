import '../models/chat_message.dart';

/// The conversation's long-term memory.
///
/// The chat used to forget everything past the last handful of turns, so a
/// request made at the start of a session was gone by the end. This class
/// compacts the turns that no longer fit in the context budget into a small,
/// deterministic block that is re-injected into every request - so the
/// assistant can still say what you asked first.
///
/// Pure and offline: no model, no network, no randomness.
class ConversationMemory {
  const ConversationMemory._();

  /// How much of a single message the memory keeps. Long messages are
  /// shortened on a word boundary; the point is to preserve the *ask*.
  static const int askChars = 220;

  /// The user's requests, oldest first, shortened.
  static List<String> userAsks(List<ChatMessage> messages) {
    final out = <String>[];
    for (final m in messages) {
      if (!m.isUser) continue;
      final t = _tidy(m.text);
      if (t.isEmpty) continue;
      // "hi", "help", "ok" are not requests: keeping them as the
      // conversation's original ask would make every recall wrong.
      if (t.length < 12 && t.split(' ').length < 3) continue;
      out.add(_short(t, askChars));
    }
    return out;
  }

  /// Facts the user has stated in the conversation, pulled out of their own
  /// wording. Deterministic patterns only - nothing is inferred.
  static List<String> pinnedFacts(List<ChatMessage> messages) {
    final cidrs = <String>{};
    final models = <String>{};
    final vlans = <String>{};
    final devices = <String>{};
    for (final m in messages) {
      if (!m.isUser) continue;
      final text = m.text;
      for (final match in RegExp(
        r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b',
      ).allMatches(text)) {
        cidrs.add(match.group(1)!);
      }
      for (final match in RegExp(
        r'\b(4331|4321|2911|2901|1941|2960|2950|3560|829)\b',
      ).allMatches(text)) {
        models.add(match.group(1)!);
      }
      for (final match in RegExp(
        r'\bvlan\s*(\d{1,4})\b',
        caseSensitive: false,
      ).allMatches(text)) {
        vlans.add('VLAN ${match.group(1)!}');
      }
      for (final match in RegExp(
        r'\b(R\d{1,2}|SW\d{1,2}|PC\d{1,2}|SRV\d{1,2})\b',
      ).allMatches(text)) {
        devices.add(match.group(1)!);
      }
    }
    final facts = <String>[];
    if (cidrs.isNotEmpty) facts.add('networks mentioned: ${cidrs.take(6).join(', ')}');
    if (models.isNotEmpty) facts.add('models mentioned: ${models.join(', ')}');
    if (vlans.isNotEmpty) facts.add(vlans.take(6).join(', '));
    if (devices.isNotEmpty) facts.add('devices named: ${devices.take(8).join(', ')}');
    return facts;
  }

  /// A compact block describing the turns that were dropped, or '' when none
  /// were. Kept short on purpose: it competes with the live turns for budget.
  static String summarize(List<ChatMessage> dropped) {
    if (dropped.isEmpty) return '';
    final asks = userAsks(dropped);
    if (asks.isEmpty) return '';
    final facts = pinnedFacts(dropped);
    final proposals = <String>{
      for (final m in dropped)
        for (final a in m.actions) a.kind,
    };

    final b = StringBuffer()
      ..writeln(
        '## Conversation memory (earlier turns compacted to stay inside the '
        'context budget)',
      )
      ..writeln(
        'These turns are no longer sent word-for-word, but they still '
        'matter. Treat them as things the user already said:',
      )
      ..writeln('- The user\'s ORIGINAL request: "${asks.first}"');
    if (asks.length > 1) {
      b.writeln(
        '- Requests after that, oldest first: '
        '${asks.skip(1).map((a) => '"$a"').join('; ')}',
      );
    }
    if (facts.isNotEmpty) {
      b.writeln('- Facts the user stated: ${facts.join(' | ')}');
    }
    if (proposals.isNotEmpty) {
      b.writeln(
        '- Proposals already shown to the user: ${proposals.join(', ')}',
      );
    }
    b.writeln(
      '- When the user says "it", "that", "the first thing" or "as I asked", '
      'they mean the ORIGINAL request above. Never ask them to repeat it.',
    );
    return b.toString().trimRight();
  }

  static String _tidy(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _short(String s, int max) {
    if (s.length <= max) return s;
    final cut = s.substring(0, max);
    final space = cut.lastIndexOf(' ');
    return '${space > max ~/ 2 ? cut.substring(0, space) : cut}...';
  }
}
