import '../models/chat_message.dart';

/// The conversation's long-term memory.
///
/// The chat used to forget everything past the last handful of turns, so a
/// request made at the start of a session was gone by the end. This class
/// compacts the turns that no longer fit in the context budget into a small,
/// deterministic block that is re-injected into every request - so the
/// assistant can still say what you asked first.
///
/// Two rules shape it:
///
///  * **Bounded.** The block is paid for out of the same window as everything
///    else, so it keeps the ORIGINAL request, the newest few asks and the
///    structured facts - never a growing pile of prose. A summary that grows
///    with the conversation eventually crowds out the conversation itself,
///    which is the failure mode this whole design exists to avoid.
///  * **Technical values survive exactly.** Addresses, prefixes, VLAN ids,
///    interface names, model numbers and device names are lifted verbatim
///    from both sides of the conversation, not paraphrased. "The gateway is
///    192.168.1.1" has to survive as 192.168.1.1.
///
/// Pure and offline: no model, no network, no randomness.
class ConversationMemory {
  const ConversationMemory._();

  /// How much of a single message the memory keeps. Long messages are
  /// shortened on a word boundary; the point is to preserve the *ask*.
  static const int askChars = 220;

  /// How many asks (after the original) are carried. The original request is
  /// what "as I asked" points at, and the newest few are what "keep going"
  /// points at; the middle of a very long session lives in the database, not
  /// in the prompt.
  static const int maxAsks = 12;

  /// The user's requests, oldest first, shortened.
  ///
  /// The first entry is always the ORIGINAL request (kept even when it is
  /// short), then the newest asks, in order, with an explicit note when asks
  /// were left out - so the model knows the list is not the whole story
  /// instead of assuming it is.
  static List<String> userAsks(List<ChatMessage> messages, {int? limit}) {
    final all = <String>[];
    String? firstShort;
    for (final m in messages) {
      if (!m.isUser) continue;
      final t = _tidy(m.text);
      if (t.isEmpty) continue;
      // "hi", "help", "ok" are not requests: keeping them as the
      // conversation's original ask would make every recall wrong. The first
      // one is kept aside, though, so an all-chatter conversation still
      // summarizes to something rather than to nothing.
      if (t.length < 12 && t.split(' ').length < 3) {
        firstShort ??= _short(t, askChars);
        continue;
      }
      all.add(_short(t, askChars));
    }
    if (all.isEmpty) {
      return firstShort == null ? const [] : [firstShort];
    }
    final cap = limit ?? maxAsks;
    if (all.length <= cap + 1) return all;
    final head = all.first;
    final tail = all.sublist(all.length - cap);
    return [
      head,
      '... ${all.length - cap - 1} earlier request(s) omitted ...',
      ...tail,
    ];
  }

  /// Facts the user has stated in the conversation, pulled out of their own
  /// wording, plus the technical values the assistant itself established.
  ///
  /// Deterministic patterns only - nothing is inferred. Assistant turns are
  /// read for values (an interface name or an address it named is part of the
  /// shared context) but never for claims, so a hallucinated sentence in an
  /// old answer cannot become a "fact" here.
  static List<String> pinnedFacts(List<ChatMessage> messages) {
    final cidrs = <String>{};
    final models = <String>{};
    final vlans = <String>{};
    final devices = <String>{};
    final interfaces = <String>{};
    for (final m in messages) {
      if (m.isError) continue;
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
      for (final match in RegExp(
        r'\b((?:g|gi|fa|f|s|se|serial|eth|e)\d+(?:/\d+){1,3}(?:\.\d{1,4})?)\b',
        caseSensitive: false,
      ).allMatches(text)) {
        interfaces.add(match.group(1)!);
      }
    }
    final facts = <String>[];
    if (cidrs.isNotEmpty) {
      facts.add('addresses seen: ${cidrs.take(10).join(', ')}');
    }
    if (models.isNotEmpty) facts.add('models seen: ${models.join(', ')}');
    if (vlans.isNotEmpty) facts.add(vlans.take(8).join(', '));
    if (devices.isNotEmpty) {
      facts.add('devices named: ${devices.take(12).join(', ')}');
    }
    if (interfaces.isNotEmpty) {
      facts.add('interfaces named: ${interfaces.take(10).join(', ')}');
    }
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
      // Compacted asks are quoted short on purpose: a real request is one
      // sentence, and this block competes with the live turns for budget.
      ..writeln('- The user\'s ORIGINAL request: "${_short(asks.first, 140)}"');
    if (asks.length > 1) {
      b.writeln(
        '- Requests after that, oldest first: '
        '${asks.skip(1).map((a) => '"${_short(a, 140)}"').join('; ')}',
      );
    }
    if (facts.isNotEmpty) {
      b.writeln('- Technical values from these turns: ${facts.join(' | ')}');
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

  /// Fold newly compacted turns into the summary the last turn saved.
  ///
  /// The saved summary used to REPLACE the fresh one, so after the first
  /// overflow every turn compacted since then was dropped on the floor: the app
  /// kept replaying a summary of the first few turns while the turns the user
  /// had just spoken went missing. The saved part is treated as older compacted
  /// turns and merged, with the union of the requests so a repeated one is not
  /// listed twice.
  static String mergeSummary(
    String previousSummary,
    List<ChatMessage> dropped,
  ) {
    final fresh = summarize(dropped);
    final previous = previousSummary.trim();
    if (fresh.isEmpty) return previous;
    if (previous.isEmpty) return fresh;
    // A summary written by an older build (or by hand) has none of the markers
    // below, so it cannot be merged field by field - and dropping it would lose
    // exactly what the merge exists to keep. It is carried through verbatim.
    if (!previous.contains('## Conversation memory')) {
      return '$fresh\n'
          '- Also already known from earlier turns: '
          '${_short(previous, 600)}';
    }
    // Pull the saved asks/facts out of the previous block and re-summarize with
    // the new ones, so the result is one block rather than two stacked blocks.
    final previousAsks = _quoted(previous, 'The user\'s ORIGINAL request: ');
    final more = _quotedList(previous, 'Requests after that, oldest first: ');
    final previousFacts = _after(
      previous,
      '- Technical values from these turns: ',
    );

    final asks = <String>{
      ...?previousAsks,
      ...more,
      ...userAsks(dropped),
    }.toList();
    final facts = <String>{
      ..._splitList(previousFacts),
      ...pinnedFacts(dropped),
    };
    final proposals = <String>{
      ..._proposalWords(previous),
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
      ..writeln('- The user\'s ORIGINAL request: "${_short(asks.first, 140)}"');
    if (asks.length > 1) {
      b.writeln(
        '- Requests after that, oldest first: '
        '${asks.skip(1).map((a) => '"${_short(a, 140)}"').join('; ')}',
      );
    }
    if (facts.isNotEmpty) {
      b.writeln('- Technical values from these turns: ${facts.join(' | ')}');
    }
    if (proposals.isNotEmpty) {
      b.writeln('- Proposals already shown to the user: ${proposals.join(', ')}');
    }
    b.writeln(
      '- When the user says "it", "that", "the first thing" or "as I asked", '
      'they mean the ORIGINAL request above. Never ask them to repeat it.',
    );
    return b.toString().trimRight();
  }

  /// Quoted asks on the same line as [marker], if the marker is there.
  static List<String>? _quoted(String text, String marker) {
    final i = text.indexOf(marker);
    if (i < 0) return null;
    final tail = text.substring(i + marker.length);
    final end = tail.indexOf('\n');
    final line = (end < 0 ? tail : tail.substring(0, end)).trim();
    return [line.replaceAll('"', '').trim()];
  }

  static List<String> _quotedList(String text, String marker) {
    final i = text.indexOf(marker);
    if (i < 0) return const [];
    final tail = text.substring(i + marker.length);
    final end = tail.indexOf('\n');
    final line = (end < 0 ? tail : tail.substring(0, end)).trim();
    return RegExp(r'"([^"]*)"')
        .allMatches(line)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String _after(String text, String marker) {
    final i = text.indexOf(marker);
    if (i < 0) return '';
    final tail = text.substring(i + marker.length);
    final end = tail.indexOf('\n');
    return (end < 0 ? tail : tail.substring(0, end)).trim();
  }

  static List<String> _splitList(String line) => line
      .split(RegExp(r'\s*\|\s*'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static Set<String> _proposalWords(String text) => RegExp(
        r'^- Proposals already shown to the user: (.+)$',
        multiLine: true,
      ).allMatches(text).expand((m) => m.group(1)!.split(',')).map((s) => s.trim()).toSet();

  static String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _short(String s, int max) {
    if (s.length <= max) return s;
    final cut = s.substring(0, max);
    final space = cut.lastIndexOf(' ');
    return '${space > max ~/ 2 ? cut.substring(0, space) : cut}...';
  }
}
