import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/context_budget.dart';

/// A runtime window so tight that one turn rivals the summary reserve.
///
/// The reserve is a third of the history room (900 tokens at best), but a
/// real turn can be larger than that. When it was, the walk kept NOTHING:
/// the plan carried a summary of every turn, including the one the user had
/// just sent, and the model answered without the question it was asked.
void main() {
  test('a starved window still sends the newest turn word-for-word', () {
    final plan = ContextBudget.plan(
      history: [
        // Distinct filler per turn, so "was it resent in full?" is
        // answerable per turn rather than by counting x's.
        for (var i = 0; i < 8; i++)
          ChatMessage(
            role: 'user',
            text: 'turn $i ${List.filled(3000, 'w$i').join()}',
          ),
      ],
      systemContext: 'you are a network engineer',
      networkContext: '## Live network\nR1 (router, 10.0.0.1)\nSW1',
      sessionState: '## Session state\nfocus device: R1',
      memories: '## Recalled memory\nThe user wants OSPF, not RIP.',
      storedSummary: 'Earlier: the user asked for 10 PCs and 2 routers.',
      pendingText: 'what is on the network right now?',
      budgetTokens: 3000,
    );

    expect(plan.windowTokens, 3000);
    expect(plan.recentTurns, isNotEmpty,
        reason: 'the newest turn outranks the summary reserve');
    expect(plan.recentTurns.last.text, contains('turn 7'));
    expect(plan.recentTurns.last.text, contains('w7w7w7w7'),
        reason: 'whole, not a quote: the turn is sent word-for-word');
    expect(plan.turnsSummarized, greaterThan(0),
        reason: 'the older turns are compacted, never silently lost');
    expect(plan.memoryBlock, contains('10 PCs and 2 routers'),
        reason: 'the saved summary still rides along with what fits');
    expect(plan.memoryBlock, contains('turn 0'),
        reason: 'the compacted turns are still represented');
    expect(plan.tokensUsed, lessThanOrEqualTo(plan.windowTokens),
        reason: 'the plan never hands the runtime more than its window');
    expect(plan.report, isNotNull);
    expect(plan.notes, isNotEmpty, reason: 'the compaction is said out loud');
  });
}
