import '../models/chat_message.dart';
import 'conversation_memory.dart';

/// What one request will actually carry, and what had to be compacted.
class ContextPlan {
  /// The ceiling this plan was built against.
  final int budgetTokens;

  /// Estimated tokens the request will use (system + history + reply reserve).
  final int tokensUsed;

  /// Turns of history that fit and are sent word-for-word.
  final List<ChatMessage> recentTurns;

  /// How many turns were compacted into [memoryBlock].
  final int turnsSummarized;

  /// The compacted memory of the dropped turns ('' when nothing was dropped).
  final String memoryBlock;

  const ContextPlan({
    required this.budgetTokens,
    required this.tokensUsed,
    required this.recentTurns,
    required this.turnsSummarized,
    required this.memoryBlock,
  });

  double get usedFraction =>
      budgetTokens <= 0 ? 0 : (tokensUsed / budgetTokens).clamp(0.0, 1.0);

  int get remainingTokens =>
      (budgetTokens - tokensUsed) < 0 ? 0 : budgetTokens - tokensUsed;

  bool get summarized => turnsSummarized > 0;
}

/// The context window, in one place.
///
/// 256k is the ceiling this app targets - the same order as a long-context
/// chat model - and it is a real number the request path obeys: turns that do
/// not fit are compacted by [ConversationMemory] instead of being dropped, so
/// the assistant keeps what you asked first.
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

  /// Room kept for the model's own answer so a reply is never truncated.
  static const int defaultMaxOutputTokens = 8192;

  /// Rough allowance for the rule packs + app knowledge already in the system
  /// prompt (measured ~3-5k on a real build).
  static const int systemOverheadTokens = 4096;

  /// Allowance for inline images on the current turn.
  static const int attachmentOverheadTokens = 2048;

  /// Per-turn framing overhead chat APIs add around one message.
  static const int perTurnOverheadTokens = 6;

  /// How much of the ceiling the request may actually use. It is a ceiling,
  /// not a target: a conversation that fits in less sends less. The old value
  /// (0.5) threw half the window away, which is why the configured context
  /// length did not change how much the chat remembered.
  static const double workingFraction = 0.9;

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

  /// Decide what fits.
  ///
  /// Walks the history newest-first while it fits under the working budget,
  /// then compacts everything older into one memory block. [pendingText] is
  /// the turn being sent right now.
  static ContextPlan plan({
    required List<ChatMessage> history,
    required String systemContext,
    required String pendingText,
    int? budgetTokens,
    double workingFractionOverride = workingFraction,
  }) {
    final budget = (budgetTokens == null || budgetTokens <= 0)
        ? defaultContextTokens
        : budgetTokens;

    // A huge ceiling does not mean "send everything": work to a fraction of it
    // so latency and cost stay flat, and compact the rest into memory.
    final working = (budget * workingFractionOverride).round().clamp(
      2048,
      budget,
    );

    var used =
        estimateTokens(systemContext) +
        systemOverheadTokens +
        estimateTokens(pendingText) +
        attachmentOverheadTokens +
        defaultMaxOutputTokens;

    final kept = <ChatMessage>[];
    for (var i = history.length - 1; i >= 0; i--) {
      final turnTokens = estimateTurn(history[i]);
      if (used + turnTokens > working && kept.isNotEmpty) break;
      if (used + turnTokens > budget) break;
      used += turnTokens;
      kept.insert(0, history[i]);
    }

    final dropped = history.sublist(0, history.length - kept.length);
    final memoryBlock = ConversationMemory.summarize(dropped);

    // The memory block is part of the request too, so it counts.
    if (memoryBlock.isNotEmpty) {
      used += estimateTokens(memoryBlock);
      while (used > budget && kept.isNotEmpty) {
        final removed = kept.removeAt(0);
        used -= estimateTurn(removed);
      }
    }

    // Count what is really missing from the sent turns. The memory block was
    // built from a superset of these, which is the safe direction.
    final summarizedCount = history.length - kept.length;
    return ContextPlan(
      budgetTokens: budget,
      tokensUsed: used,
      recentTurns: kept,
      turnsSummarized: summarizedCount,
      memoryBlock: summarizedCount > 0 ? memoryBlock : '',
    );
  }
}
