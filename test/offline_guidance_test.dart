import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// The keyless assistant has no model, so its memory of the conversation is
/// what makes it useful. These pin that it actually uses the earlier turns.
void main() {
  test('a vague follow-up recalls the original request', () {
    final history = [
      const ChatMessage(
        role: 'user',
        text: 'build a two-site OSPF lab with a serial WAN',
      ),
    ];
    final reply = OfflineAssistantService.reply(
      rawText: 'make it normal',
      normalized: '',
      target: 'pt',
      history: history,
    );
    expect(reply.intent, 'vague');
    expect(reply.text, contains('two-site OSPF lab'));
    expect(reply.questions, isNotEmpty);
  });

  test('a build answer names the earlier request it follows', () {
    final history = [
      const ChatMessage(role: 'user', text: 'a small office with guest wifi'),
    ];
    final reply = OfflineAssistantService.reply(
      rawText: 'now add 2 routers and a switch',
      normalized: 'now add 2 routers and a switch',
      target: 'pt',
      plan: NetworkIntent.parseSimple('p', '2 routers 1 switch 4 pcs'),
      history: history,
    );
    expect(reply.intent, 'build');
    expect(reply.text, contains('guest wifi'));
    expect(reply.text, contains('Next steps'));
  });

  test('a recall question is answered from memory, not re-planned', () {
    final history = [
      const ChatMessage(
        role: 'user',
        text: 'build a two-site OSPF lab with a serial WAN',
      ),
      const ChatMessage(role: 'model', text: 'ok'),
      const ChatMessage(role: 'user', text: 'now add a DNS server'),
    ];
    final reply = OfflineAssistantService.reply(
      rawText: 'what did I ask you to build at the start?',
      normalized: 'what did i ask you to build at the start?',
      target: 'pt',
      history: history,
    );
    expect(reply.intent, 'recall');
    expect(reply.text, contains('two-site OSPF lab'));
    expect(reply.text, contains('now add a DNS server'));
    expect(reply.text, contains('ORIGINAL request'));
  });

  test('a recall question with no history says so', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'what did I ask you?',
      normalized: 'what did i ask you?',
      target: 'pt',
    );
    expect(reply.intent, 'recall');
    expect(reply.text, contains('start of our conversation'));
  });

  test('with no history it does not invent one', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'make it normal',
      normalized: '',
      target: 'pt',
    );
    expect(reply.text, isNot(contains('Earlier in this conversation')));
  });
}
