// ignore_for_file: avoid_print
// Guidance rubric demo - run it with:
//
//   cd C:\ai\app
//   dart run tool/guidance_demo.dart
//
// It walks ten representative prompts (vague, multi-part, follow-up, how-to,
// factual, change) through the KEYLESS assistant, keeping the conversation so
// the memory layer is exercised, and prints a transcript per prompt. The
// prompts and the rubric are documented in
// DELIVERY/netbuilder-chat-upgrade-2026-09-21.html.
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/conversation_memory.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';

const prompts = <String>[
  'help',                                                  // vague
  'make it normal',                                        // vague
  'build a small office with 2 routers 2 switches 1 server and 4 pcs',
  'i wanna 2 swtich and 3 routrs pls',                     // casual + typos
  'what is better ospf or static',                         // how-to
  'how do i connect two routers',                          // how-to
  'change the router to 4331',                             // change
  'add vlan 10 and 20 for the office',                     // change
  'now add guest wifi and port security to that',          // follow-up
  'what did I ask you to build at the start?',             // recall probe
];

void main() {
  final history = <ChatMessage>[];

  for (final raw in prompts) {
    final normalized = CasualEnglish.normalize(raw);
    NetworkIntent? plan;
    try {
      plan = PlannerMemoryService.apply(
        NetworkIntent.parseSimple(
          'demo',
          normalized.isEmpty ? raw : normalized,
        ),
      );
    } catch (_) {
      plan = null;
    }
    final suggestions = plan == null
        ? <String>[]
        : PlannerSuggestionsService.forIntent(plan, target: 'pt');
    final reply = OfflineAssistantService.reply(
      rawText: raw,
      normalized: normalized,
      target: 'pt',
      plan: plan,
      suggestions: suggestions,
      modelError: '',
      history: history,
    );

    print('=' * 78);
    print('PROMPT   : $raw');
    print('NORMALIZE: "$normalized"');
    print('INTENT   : ${reply.intent}');
    print('MEMORY   : ${ConversationMemory.userAsks(history).length} earlier ask(s)');
    print('-' * 78);
    print(reply.text);
    if (reply.questions.isNotEmpty) {
      print('QUESTIONS: ${reply.questions.join(' | ')}');
    }
    print('');

    history.add(ChatMessage(role: 'user', text: raw));
    history.add(ChatMessage(role: 'model', text: reply.text));
  }
}
