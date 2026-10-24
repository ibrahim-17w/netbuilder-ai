import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/plan_device_explainer.dart';

/// "What does SW1 do?" is a question whose answer is standing right there
/// in the plan - answered from it, deterministically, without touching it.
void main() {
  final plan = NetworkIntent.parseSimple('p', '2 routers 1 switch 4 pcs');

  test(
    'a device named in the question is found, not one merely sounded like',
    () {
      expect(PlanDeviceExplainer.namedDevice('what does SW1 do?', plan), 'SW1');
      expect(PlanDeviceExplainer.namedDevice('explain r1 please', plan), 'R1');
      // A word that merely CONTAINS the name is not the name.
      expect(
        PlanDeviceExplainer.namedDevice('what is a switch?', plan),
        isNull,
      );
    },
  );

  test('the explanation covers role, addresses, cables and commands', () {
    final text = PlanDeviceExplainer.explain(plan, 'SW1');
    expect(text, startsWith('**SW1**'));
    expect(text, contains('switch'));
    // Every cable names both ends and both ports.
    expect(text, contains('` <-> R1 `'));
    expect(text, contains('show vlan brief'));
    expect(text, contains('show cdp neighbors'));
  });

  test('a router gets routing commands, a server gets its roles', () {
    final router = PlanDeviceExplainer.explain(plan, 'R1');
    expect(router, contains('show ip route'));
    final withRoles = NetworkIntent.parseSimple(
      'p',
      '1 router 1 switch 1 dns and dhcp server',
    );
    final server = withRoles.nodes.firstWhere((n) => n.type == 'server');
    final text = PlanDeviceExplainer.explain(withRoles, server.name);
    expect(text, contains('service role'));
    expect(text, contains('Services tab'));
  });

  test('the offline assistant answers a device question from the plan', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'what does SW1 do?',
      normalized: 'what does sw1 do?',
      target: 'packet-tracer',
      plan: plan,
    );
    expect(reply.intent, 'howto');
    expect(reply.text, contains('**SW1**'));
    expect(reply.quickReplies, isNot(contains('Build the .pkt')));
  });

  test('a follow-up finds its topic past an acknowledgement', () {
    final history = [
      const ChatMessage(role: 'user', text: 'how do I configure ospf?'),
      const ChatMessage(role: 'model', text: 'network 10.0.0.0 ...'),
      const ChatMessage(role: 'user', text: 'thanks'),
      const ChatMessage(role: 'model', text: 'any time'),
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

  test('an uncovered ask with a plan points at the plan by name', () {
    final reply = OfflineAssistantService.reply(
      rawText: 'what about the routers and switches?',
      normalized: 'what about the routers and switches?',
      target: 'packet-tracer',
      plan: plan,
    );
    // The honest near-miss, grounded: the plan's own devices are named as
    // ground the user can point at.
    expect(reply.intent, 'missing');
    expect(reply.text, contains('Name one of its devices'));
    expect(reply.text, contains(plan.nodes.first.name));
  });
}
