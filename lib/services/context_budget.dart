import '../models/chat_message.dart';
import 'context_report.dart';
import 'conversation_memory.dart';

/// What one request will actually carry, and what had to be compacted.
class ContextPlan {
  /// The ceiling this plan was built against (the user's setting).
  final int budgetTokens;

  /// The window the runtime really allocates. [budgetTokens] and this can
  /// differ by orders of magnitude, and when they do, this is the one that
  /// decides what the model actually sees.
  final int windowTokens;

  /// Where [windowTokens] came from (`Ollama /api/ps`, `assumed`, ...).
  final String windowSource;

  /// Estimated tokens the request will use.
  final int tokensUsed;

  /// Turns of history that fit and are sent word-for-word.
  final List<ChatMessage> recentTurns;

  /// How many turns were compacted into [memoryBlock].
  final int turnsSummarized;

  /// The compacted memory of the dropped turns ('' when nothing was dropped).
  final String memoryBlock;

  /// Relevant long-term memories retrieved from the local database ('' when
  /// none were found or none fitted).
  final String memoriesBlock;

  /// The live network/session picture, as its own block.
  final String networkBlock;

  /// The structured session state (focus devices, the current problem, the
  /// last change), as its own block ('' when it did not fit).
  ///
  /// This was computed by the planner and then dropped on the floor, so every
  /// turn paid to build the "what does 'its' mean" block and then never sent
  /// it - the follow-up questions it exists for were unanswerable.
  final String sessionStateBlock;

  /// Why something was left out, in the words of the report.
  final List<String> notes;

  /// The full breakdown of this request (sections, window, reasons).
  final RequestReport? report;

  const ContextPlan({
    required this.budgetTokens,
    required this.tokensUsed,
    required this.recentTurns,
    required this.turnsSummarized,
    required this.memoryBlock,
    this.windowTokens = 0,
    this.windowSource = 'configured',
    this.memoriesBlock = '',
    this.networkBlock = '',
    this.sessionStateBlock = '',
    this.notes = const [],
    this.report,
  });

  double get usedFraction =>
      windowTokens <= 0 ? 0 : (tokensUsed / windowTokens).clamp(0.0, 1.0);

  int get remainingTokens =>
      (windowTokens - tokensUsed) < 0 ? 0 : windowTokens - tokensUsed;

  bool get summarized => turnsSummarized > 0;

  /// True when the runtime's window is what limited the request - the state
  /// that used to be invisible.
  bool get limitedByWindow =>
      windowTokens > 0 && windowTokens < budgetTokens;
}

/// The context window, in one place.
///
/// Two numbers matter and they are not the same:
///
///  * [budgetTokens] - the user's ceiling (Settings, up to 1,024k). This is
///    what the app is *willing* to send.
///  * the runtime window - what the process on the other end will actually
///    hold. Ollama's default `num_ctx` is 4096 and its OpenAI-compatible
///    endpoint ignores per-request `num_ctx`, so a request planned against
///    1,024k arrived at a 4k window and the runtime silently dropped the front
///    of it: the newest one or two turns survived and everything earlier was
///    gone. That is the reported memory bug, and it was invisible from inside
///    the app because the plan was measured against the setting.
///
/// So the plan is now built against `min(budget, real window)`, with the
/// output reserve and the fixed blocks allocated FIRST and the history fitted
/// into what is left. Nothing is ever handed to the runtime that will not fit,
/// which means the runtime never gets to decide what to forget - and what does
/// not fit is compacted into the conversation summary instead.
///
/// Token counts are ESTIMATED (there is no tokenizer offline): ~4 ASCII
/// characters per token and 1 token per non-ASCII character, plus a small
/// per-turn overhead. The estimate is deliberately conservative, which is the
/// safe direction - the real request is smaller than the number shown.
class ContextBudget {
  const ContextBudget._();

  /// THE KNOB. Default context ceiling, in tokens (~256k, like a long-context
  /// chat model). Change this, or the `contextBudget` preference in Settings,
  /// to move the ceiling. Nothing else in the app hardcodes a context size.
  static const int defaultContextTokens = 262144;

  /// Room kept for the model's own answer so a reply is never truncated. It
  /// scales with the window (a fifth of it) so a 4k runtime still gets to
  /// answer while a 256k one is not limited to a short reply.
  static const int defaultMaxOutputTokens = 8192;
  static const int minOutputTokens = 256;

  /// Framing overhead the transport adds around the system prompt.
  static const int systemOverheadTokens = 256;

  /// Allowance for inline images on the current turn.
  static const int attachmentOverheadTokens = 2048;

  /// Per-turn framing overhead chat APIs add around one message.
  static const int perTurnOverheadTokens = 6;

  /// How much of the ceiling the request may actually use. It is a ceiling,
  /// not a target: a conversation that fits in less sends less.
  static const double workingFraction = 0.9;

  /// The most of the optional room that live network data + structured state
  /// may take. The rest is reserved for the conversation, because a follow-up
  /// ("what about its gateway?") needs the turns more than it needs a second
  /// copy of the topology.
  static const double sectionFraction = 0.4;

  /// Room held back for the conversation summary, which is bounded by
  /// [ConversationMemory] (the original request, the newest few asks and the
  /// structured facts), so this really is its ceiling. Without the reserve the
  /// history walk would eat every last token and the summary would never fit -
  /// which is how the oldest turns got dropped instead of compacted.
  static const int summaryReserveTokens = 900;

  /// Estimate tokens for [text]. Deterministic; see the class doc.
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    var ascii = 0;
    var wide = 0;
    for (final rune in text.runes) {
      if (rune < 128) {
        ascii++;
      } else {
        wide++;
      }
    }
    return (ascii + 3) ~/ 4 + wide;
  }

  static int estimateTurn(ChatMessage message) =>
      estimateTokens(message.text) + perTurnOverheadTokens;

  static int estimateMessages(List<ChatMessage> messages) {
    var total = 0;
    for (final m in messages) {
      total += estimateTurn(m);
    }
    return total;
  }

  /// Room to leave for the model's reply.
  static int outputReserveFor(int window) =>
      (window * 0.2).round().clamp(minOutputTokens, defaultMaxOutputTokens);

  /// Decide what fits.
  ///
  /// Walks the history newest-first while it fits under the working budget,
  /// then compacts everything older into one memory block. [pendingText] is
  /// the turn being sent right now.
  static ContextPlan plan({
    required List<ChatMessage> history,
    required String systemContext,
    required String pendingText,
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    int attachmentCount = 0,
    int? budgetTokens,
    int? runtimeWindowTokens,
    String runtimeWindowSource = 'configured',
    bool runtimeWindowAssumed = false,
    String model = '',
    String provider = '',
    double workingFractionOverride = workingFraction,
  }) {
    final configured = (budgetTokens == null || budgetTokens <= 0)
        ? defaultContextTokens
        : budgetTokens;

    // THE REAL CEILING. The user's setting is a maximum, never a target: a
    // runtime that allocates 4k gets a 4k-sized request, planned here, instead
    // of being handed 40k tokens and silently keeping the tail.
    final window = (runtimeWindowTokens != null && runtimeWindowTokens > 0)
        ? (runtimeWindowTokens < configured ? runtimeWindowTokens : configured)
        : configured;
    final windowSource = (runtimeWindowTokens != null &&
            runtimeWindowTokens > 0 &&
            runtimeWindowTokens < configured)
        ? runtimeWindowSource
        : 'configured budget';

    final working = (window * workingFractionOverride)
        .round()
        .clamp(window < 2048 ? 1 : 2048, window);
    final reserve = outputReserveFor(window);
    final notes = <String>[];

    // --- the blocks that must be there ------------------------------------
    var systemBlock = systemContext;
    final systemTokens = estimateTokens(systemBlock) + systemOverheadTokens;
    final currentTokens =
        estimateTokens(pendingText) +
        (attachmentCount > 0 ? attachmentOverheadTokens : 0);

    // If the system prompt alone does not fit, it is trimmed - and said so.
    // Silently sending a prompt the runtime will cut is how a chat ends up
    // answering the wrong question.
    var fixedTokens = systemTokens + currentTokens + reserve;
    if (fixedTokens > working) {
      final allowed = working - currentTokens - reserve;
      if (allowed <= 0) {
        systemBlock = '';
        notes.add(
          'the request did not fit the $window-token runtime window even '
          'without the system prompt: raise the runtime context window',
        );
      } else {
        systemBlock = _trimToTokens(systemBlock, allowed);
        notes.add(
          'the system prompt was trimmed from $systemTokens to '
          '${estimateTokens(systemBlock) + systemOverheadTokens} tokens to fit '
          'the $window-token runtime window',
        );
      }
      fixedTokens = estimateTokens(systemBlock) +
          systemOverheadTokens +
          currentTokens +
          reserve;
    }

    // --- the optional blocks, most valuable first --------------------------
    // Live network data beats structured state beats long-term memory: the
    // user is asking about the network in front of them.
    final optionalRoom = working - fixedTokens;
    final sectionCap = optionalRoom <= 0
        ? 0
        : (optionalRoom * sectionFraction).round();
    var sectionUsed = 0;
    var networkBlock = '';
    var stateBlock = '';
    var memoriesBlock = '';

    void take(String label, String text, void Function(String) assign) {
      if (text.trim().isEmpty) return;
      final cost = estimateTokens(text) + perTurnOverheadTokens;
      if (sectionUsed + cost > sectionCap) {
        if (optionalRoom > 0 && cost > 0) {
          notes.add(
            '$label did not fit: it needs ~$cost tokens and only '
            '${sectionCap - sectionUsed} were left after the system prompt',
          );
        }
        return;
      }
      sectionUsed += cost;
      assign(text);
    }

    if (optionalRoom > 0) {
      take('the network context', networkContext, (v) => networkBlock = v);
      take('the session state', sessionState, (v) => stateBlock = v);
      // Retrieved memory used to be passed in and silently never budgeted, so
      // it was never sent: the app recalled a fact, then dropped it on the
      // floor before the request went out. It is budgeted like any other
      // optional block now, and reported whether or not it fitted.
      take('the retrieved memory', memories, (v) => memoriesBlock = v);
    }

    // --- the conversation --------------------------------------------------
    // What the model can read, after everything that must be there. The
    // summary is paid for BEFORE the history walk, because the walk fills
    // every token it is given: without the reserve the oldest turns would be
    // dropped and the summary that was supposed to replace them would have no
    // room to arrive in.
    final availableForHistory = working - fixedTokens - sectionUsed;
    final kept = <ChatMessage>[];
    var summary = '';
    var droppedCount = 0;

    /// Newest-first until the room runs out, then reversed into reading order.
    (int, List<ChatMessage>) walk(int room) {
      final keptLocal = <ChatMessage>[];
      var used = 0;
      if (room > 0) {
        for (var i = history.length - 1; i >= 0; i--) {
          final cost = estimateTurn(history[i]);
          if (used + cost > room) break;
          used += cost;
          keptLocal.insert(0, history[i]);
        }
      }
      return (used, keptLocal);
    }

    var summaryReserve = availableForHistory > summaryReserveTokens * 3
        ? summaryReserveTokens
        : (history.length > 2 ? availableForHistory ~/ 3 : 0);
    // The reserve may never cost the conversation its NEWEST turn. On a tight
    // runtime window a third of the room can be smaller than one large turn:
    // the walk then keeps nothing and the model is handed a summary instead
    // of the message the user just sent. The reserve is capped at what is
    // left after the newest turn, and the summary is fitted to the real
    // leftover below - so the plan still never exceeds the window.
    if (history.isNotEmpty && summaryReserve > 0) {
      final roomForNewest = availableForHistory - estimateTurn(history.last);
      if (roomForNewest < summaryReserve) {
        summaryReserve = roomForNewest < 0 ? 0 : roomForNewest;
      }
    }
    var (historyUsed, walked) = walk(availableForHistory - summaryReserve);

    // Nothing had to be dropped after all, so the summary reserve goes back to
    // the conversation and the walk runs once more with the full room.
    if (walked.length == history.length && summaryReserve > 0) {
      final (used, full) = walk(availableForHistory);
      if (full.length >= walked.length) {
        historyUsed = used;
        walked = full;
      }
    }

    kept.addAll(walked);
    final dropped = history.sublist(0, history.length - kept.length);
    droppedCount = dropped.length;
    if (dropped.isNotEmpty) {
      // The saved summary is MERGED, not reused: reusing it silently threw away
      // every turn compacted since, which is how the app "forgot" something the
      // user had said two or three messages earlier.
      final hadSaved = storedSummary.trim().isNotEmpty;
      summary = hadSaved
          ? ConversationMemory.mergeSummary(storedSummary, dropped)
          : ConversationMemory.summarize(dropped);
      final source = hadSaved
          ? 'the saved conversation summary plus the turns compacted now'
          : 'a summary built from those turns';
      notes.add(
        'summarized $droppedCount earlier turn(s) into $source to stay inside '
        'the ${_thousands(window)}-token runtime window',
      );
      // The summary is fitted to the room the kept turns actually left
      // behind - not to the nominal reserve, which the walk may have spent
      // on turns. The invariant is that the plan never exceeds the working
      // budget, and when something has to give, it is the summary: a live
      // turn the user just typed is always worth more than the tail of a
      // summary of older ones.
      final summaryRoom = availableForHistory - historyUsed;
      if (summaryRoom <= 0) {
        summary = '';
        notes.add(
          'left the conversation summary out: the kept turns used all of '
          'its room in the ${_thousands(window)}-token window',
        );
      } else if (estimateTokens(summary) > summaryRoom) {
        final fitted = _fitSummary(summary, summaryRoom);
        if (fitted.length < summary.length) {
          notes.add(
            'trimmed the conversation summary to the '
            '${_thousands(summaryRoom)}-token room left after the kept turns',
          );
        }
        summary = fitted;
      }
    }

    // --- count it honestly -------------------------------------------------
    var tokens = fixedTokens +
        sectionUsed +
        historyUsed +
        estimateTokens(summary);
    // The clamp is the invariant: a plan never exceeds the window, whatever
    // the estimate above said. Oldest turns go first; they are in the summary.
    while (tokens > working && kept.isNotEmpty) {
      final removed = kept.removeAt(0);
      tokens -= estimateTurn(removed);
      notes.add(
        'dropped the oldest kept turn ("${_firstWords(removed.text)}") to fit '
        'the ${_thousands(window)}-token window',
      );
    }
    if (tokens > working) {
      // Even the fixed blocks are over (a huge single message). The request is
      // still sent - the runtime will cut it - but the report says so.
      notes.add(
        'the current message plus the system prompt exceed the '
        '${_thousands(window)}-token window',
      );
    }

    final summarizedCount = history.length - kept.length;
    final memoryBlock = summarizedCount > 0 ? summary : '';

    return ContextPlan(
      budgetTokens: configured,
      windowTokens: window,
      windowSource: windowSource,
      tokensUsed: tokens,
      recentTurns: kept,
      turnsSummarized: summarizedCount,
      memoryBlock: memoryBlock,
      memoriesBlock: memoriesBlock,
      networkBlock: networkBlock,
      sessionStateBlock: stateBlock,
      notes: notes,
      report: RequestReport(
        sequence: 0,
        model: model,
        provider: provider,
        runtimeWindow: window,
        runtimeWindowSource: windowSource,
        runtimeWindowAssumed: runtimeWindowAssumed,
        configuredBudget: configured,
        effectiveBudget: window,
        outputReserve: reserve,
        sections: [
          ReportSection(
            'system prompt',
            estimateTokens(systemBlock) + systemOverheadTokens,
          ),
          if (networkBlock.isNotEmpty)
            ReportSection('network context', estimateTokens(networkBlock)),
          if (stateBlock.isNotEmpty)
            ReportSection('session state', estimateTokens(stateBlock)),
          if (memoryBlock.isNotEmpty)
            ReportSection('conversation summary', estimateTokens(memoryBlock),
                '$summarizedCount earlier turn(s)'),
          if (memoriesBlock.isNotEmpty)
            ReportSection('retrieved memory', estimateTokens(memoriesBlock)),
          ReportSection(
            'recent conversation',
            estimateMessages(kept),
            '${kept.length} turn(s)',
          ),
          ReportSection(
            'current message',
            currentTokens,
            attachmentCount > 0 ? '$attachmentCount attachment(s)' : '',
          ),
        ]
          // A section with no cost was not sent at all; the report lists what
          // the model actually received.
          .where((s) => s.tokens > 0)
          .toList(),
        turnsSent: kept.length,
        turnsSummarized: summarizedCount,
        notes: notes,
        at: DateTime.now(),
      ),
    );
  }

  /// Cut a conversation-memory block down to [maxTokens].
  ///
  /// The line that matters is the original request, so it is kept and the list
  /// of later asks is what shrinks. The list is trimmed from the front, because
  /// the newest asks are the ones a follow-up refers back to.
  static String _fitSummary(String summary, int maxTokens) {
    if (estimateTokens(summary) <= maxTokens) return summary;
    final lines = summary.split('\n');
    final asksIndex = lines.indexWhere(
      (l) => l.startsWith('- Requests after that'),
    );
    if (asksIndex < 0) {
      var out = lines;
      while (out.length > 3 && estimateTokens(out.join('\n')) > maxTokens) {
        out = out.sublist(0, out.length - 1);
      }
      return out.join('\n');
    }
    final asks = RegExp(r'"[^"]*"')
        .allMatches(lines[asksIndex])
        .map((m) => m.group(0)!)
        .toList();
    while (asks.length > 1 && estimateTokens(summary) > maxTokens) {
      asks.removeAt(0);
      lines[asksIndex] =
          '- Requests after that, most recent first: ${asks.join('; ')}';
    }
    var out = lines.join('\n');
    if (estimateTokens(out) <= maxTokens) return out;
    // Still over: shorten each remaining quote to a clause.
    for (var i = asksIndex; i < lines.length; i++) {
      lines[i] = lines[i].replaceAllMapped(
        RegExp(r'"([^"]{40,})"'),
        (m) => '"${m.group(1)!.substring(0, 60)}..."',
      );
      out = lines.join('\n');
      if (estimateTokens(out) <= maxTokens) return out;
    }
    // Last resort: keep the heading and the original request, drop the rest.
    // A live turn the user just typed is always worth more than the tail of a
    // summary, so the summary is what gives way.
    final original = lines.firstWhere(
      (l) => l.startsWith('- The user\'s ORIGINAL request:'),
      orElse: () => '',
    );
    final ask = original.length <= 320
        ? original
        : '${original.substring(0, 300)}..."';
    return [
      lines.first,
      'Earlier turns were compacted. What the user originally asked for:',
      ask,
      '- "it" and "that" mean that original request. Never ask again.',
    ].join('\n');
  }

  static String _firstWords(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= 40) return one;
    return '${one.substring(0, 40)}...';
  }

  /// Cut [text] down to at most [tokens] estimated tokens, on a line boundary
  /// where possible so a trimmed system prompt still reads as instructions.
  static String _trimToTokens(String text, int tokens) {
    if (tokens <= 0) return '';
    if (estimateTokens(text) <= tokens) return text;
    final maxChars = tokens * 4;
    if (text.length <= maxChars) return text;
    final cut = text.substring(0, maxChars);
    final line = cut.lastIndexOf('\n');
    return '${line > maxChars ~/ 2 ? cut.substring(0, line) : cut}\n'
        '[... trimmed to fit the runtime context window ...]';
  }

  static String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}
