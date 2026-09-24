import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/context_budget.dart';
import 'package:net_builder/services/conversation_memory.dart';

/// A synthetic conversation: each turn is big enough that a few dozen turns
/// blow any small budget.
List<ChatMessage> convo({int turns = 20, int fillerChars = 4000}) {
  final out = <ChatMessage>[];
  for (var i = 0; i < turns; i++) {
    out.add(ChatMessage(role: 'user', text: 'ask $i ${'x' * fillerChars}'));
    out.add(ChatMessage(role: 'model', text: 'reply $i ${'y' * fillerChars}'));
  }
  return out;
}

void main() {
  group('the context ceiling is a real, documented value', () {
    test('the default is 256k', () {
      expect(ContextBudget.defaultContextTokens, 262144);
    });

    test('a small conversation is sent whole, with no memory block', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 2, fillerChars: 20),
        systemContext: 'sys',
        pendingText: 'hi',
      );
      expect(plan.turnsSummarized, 0);
      expect(plan.memoryBlock, isEmpty);
      expect(plan.recentTurns.length, 4);
      expect(plan.budgetTokens, 262144);
    });

    test('a bigger ceiling keeps strictly more turns', () {
      final history = convo(turns: 40, fillerChars: 4000);
      int kept(int budget) => ContextBudget.plan(
        history: history,
        systemContext: 'sys',
        pendingText: 'q',
        budgetTokens: budget,
      ).recentTurns.length;
      expect(kept(120000), greaterThan(kept(40000)));
    });
  });

  group('overflow is compacted into memory, never silently dropped', () {
    test('the request is never larger than the budget', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 40, fillerChars: 4000),
        systemContext: 'sys',
        pendingText: 'what did I ask at the very start?',
        budgetTokens: 30000,
      );
      expect(plan.tokensUsed, lessThanOrEqualTo(plan.budgetTokens));
      expect(plan.turnsSummarized, greaterThan(0));
      expect(plan.summarized, isTrue);
    });

    test('the ORIGINAL request survives in the memory block', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 40, fillerChars: 4000),
        systemContext: 'sys',
        pendingText: 'remind me',
        budgetTokens: 30000,
      );
      expect(plan.memoryBlock, contains('ORIGINAL request'));
      expect(plan.memoryBlock, contains('ask 0'));
      expect(plan.memoryBlock, contains('Never ask them to repeat it'));
    });

    test('the newest turn always survives', () {
      final history = convo(turns: 40, fillerChars: 4000);
      final plan = ContextBudget.plan(
        history: history,
        systemContext: 'sys',
        pendingText: 'q',
        budgetTokens: 30000,
      );
      expect(plan.recentTurns.last.text, contains('reply 39'));
    });

    test('the configured ceiling decides how much history is kept', () {
      // Same conversation, two different context lengths: the bigger budget
      // must retain strictly more of the conversation. This is the promise
      // the Settings knob makes - "context length = how much the chat
      // remembers" - and halving it must not be a no-op.
      final history = convo(turns: 60, fillerChars: 4000);
      int kept(int budget) => ContextBudget.plan(
        history: history,
        systemContext: 'sys',
        pendingText: 'q',
        budgetTokens: budget,
      ).recentTurns.length;
      expect(kept(240000), greaterThan(kept(60000)));
      // And a modest budget keeps most of the window for history, not half.
      expect(kept(60000), greaterThan(kept(30000)));
    });
  });

  group('conversation memory', () {
    test('pins the facts the user stated', () {
      final facts = ConversationMemory.pinnedFacts([
        const ChatMessage(
          role: 'user',
          text: 'use a 4331 router, LAN 192.168.1.0/24, VLAN 10, R1 and SW1',
        ),
      ]);
      final joined = facts.join(' | ');
      expect(joined, contains('192.168.1.0/24'));
      expect(joined, contains('4331'));
      expect(joined, contains('VLAN 10'));
      expect(joined, contains('R1'));
    });

    test('is deterministic', () {
      final msgs = convo(turns: 3, fillerChars: 10);
      expect(
        ConversationMemory.summarize(msgs),
        ConversationMemory.summarize(msgs),
      );
    });
  });
}