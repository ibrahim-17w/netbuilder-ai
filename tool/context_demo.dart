// ignore_for_file: avoid_print
// Long-conversation recall demo - run it with:
//
//   cd C:\ai\app
//   dart run tool/context_demo.dart
//
// It builds a conversation well past 100k tokens and shows what the context
// layer does with it: how many turns still fit, how many were compacted into
// memory, the token count against the budget, and proof that the request made
// at the very START is still carried to the model.
//
// The end-to-end proof that this reaches the model intact (via the real
// ChatService request path, capturing the outgoing payload) is
// test/chat_memory_test.dart, which runs under `flutter test`.
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/context_budget.dart';
import 'package:net_builder/services/conversation_memory.dart';

void main() {
  const opening = 'OPENING-ASK: build a two-site OSPF lab, serial WAN '
      '10.1.1.0/30, LANs 192.168.1.0/24 and 192.168.2.0/24, one server '
      'per site';
  final history = <ChatMessage>[
    const ChatMessage(role: 'user', text: opening),
    const ChatMessage(role: 'model', text: 'Noted: two sites, OSPF, serial WAN.'),
  ];

  var i = 0;
  while (ContextBudget.estimateMessages(history) < 120000) {
    i++;
    history.add(
      ChatMessage(role: 'user', text: 'filler question $i ${'x' * 600}'),
    );
    history.add(
      ChatMessage(role: 'model', text: 'filler answer $i ${'y' * 600}'),
    );
  }

  const pending = 'what did I ask you to build at the very beginning?';
  final total = ContextBudget.estimateMessages(history);

  print('conversation  : ${history.length} turns, ~$total tokens (uncapped)');
  print('ceiling       : ${ContextBudget.defaultContextTokens} tokens '
      '(ContextBudget.defaultContextTokens)');
  print('sending       : "$pending"');
  print('');

  final plan = ContextBudget.plan(
    history: history,
    systemContext: 'SYS (app knowledge + rule packs)',
    pendingText: pending,
    budgetTokens: ContextBudget.defaultContextTokens,
  );

  print('--- result ---');
  print('turns sent word-for-word   : ${plan.recentTurns.length} of '
      '${history.length}');
  print('turns summarized into memory: ${plan.turnsSummarized}');
  print('tokens used / budget        : ${plan.tokensUsed} / '
      '${plan.budgetTokens} (${(plan.usedFraction * 100).toStringAsFixed(2)}%)');
  print('request <= budget           : '
      '${plan.tokensUsed <= plan.budgetTokens}');
  print('original ask kept           : ${plan.memoryBlock.contains('OPENING-ASK')}');
  print('');
  print('--- the memory block the model receives (first 12 lines) ---');
  print(plan.memoryBlock.split('\n').take(12).join('\n'));
  print('');
  print('--- what a SHORT conversation does (no memory block) ---');
  final short = ContextBudget.plan(
    history: const [
      ChatMessage(role: 'user', text: 'hi'),
      ChatMessage(role: 'model', text: 'hello'),
    ],
    systemContext: 'SYS',
    pendingText: 'continue',
  );
  print('turns sent: ${short.recentTurns.length}, summarized: '
      '${short.turnsSummarized}, memory block empty: '
      '${short.memoryBlock.isEmpty}');
  print('facts pinned from user turns: '
      '${ConversationMemory.pinnedFacts(history).join(' | ')}');
}
