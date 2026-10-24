import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// Networking questions must be answered as help, not answered with a plan
/// dump or a build offer - the request the user actually made.
void main() {
  NetworkIntent plan = NetworkIntent.parseSimple('p', '2 routers 4 switches');

  test('a bare topic question is answered as howto, not a plan dump', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'what is ospf?',
      normalized: 'what is ospf?',
      target: 'packet-tracer',
      plan: plan,
    );
    expect(reply.intent, 'howto');
    expect(reply.text, isNot(contains('Build the .pkt')));
  });

  test('a help ask carries no build actions for the user to mistake', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'explain vlans',
      normalized: 'explain vlans',
      target: 'packet-tracer',
      plan: plan,
    );
    expect(reply.intent, 'howto');
    expect(reply.quickReplies, isNot(contains('Build the .pkt')));
  });

  test('a follow-up is answered from the previous topic, not the lab', () {
    final history = [
      const ChatMessage(role: 'user', text: 'how do I configure ospf?'),
      const ChatMessage(role: 'model', text: 'network 10.0.0.0 ...'),
    ];
    final reply = OfflineAssistantService.reply(
      rawText: 'give me an example',
      normalized: 'give me an example',
      target: 'packet-tracer',
      plan: plan,
      history: history,
    );
    expect(reply.intent, 'howto');
    expect(reply.text, contains('ospf'));
  });

  test('a follow-up after a build answer gets the guided near-miss', () {
    final history = [
      const ChatMessage(role: 'user', text: '2 routers and 4 switches'),
      const ChatMessage(role: 'model', text: 'Here is the lab.'),
    ];
    final reply = OfflineAssistantService.reply(
      rawText: 'give me an example',
      normalized: 'give me an example',
      target: 'packet-tracer',
      plan: plan,
      history: history,
    );
    // No networking topic is standing, so the answer is the honest gap - and
    // the lab on the table is named as ground the user can point at.
    expect(reply.text, contains('not in my offline material'));
    expect(reply.text, contains('Name one of its devices'));
    expect(reply.quickReplies, isNot(contains('Build the .pkt')));
  });

  test('a symptom question with no plan gets a help answer', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'my pc cannot ping the gateway',
      normalized: 'my pc cannot ping the gateway',
      target: 'packet-tracer',
    );
    expect(['troubleshoot', 'howto'].contains(reply.intent), isTrue);
    expect(reply.text, isNot(contains('Build the .pkt')));
  });
}
