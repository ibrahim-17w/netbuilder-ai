import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/chat_capabilities.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// The keyless chat's capability routing: "check the plan" runs the app's
/// own read-only checks and answers with the real findings - never with a
/// description of what a check would say, and never by changing anything.
///
/// The same capabilities back the Action Hub buttons, so a routed answer
/// and a clicked button read the same plan the same way.
void main() {
  final lab = NetworkIntent.parseSimple(
    'p',
    '2 routers 1 switch 4 pcs with ospf',
  );

  AssistantReply ask(String raw, {NetworkIntent? plan}) =>
      OfflineAssistantService.reply(
        rawText: raw,
        normalized: raw.toLowerCase(),
        target: 'pt',
        plan: plan,
      );

  group('the matcher routes natural language to capabilities', () {
    test('every documented alias routes to its capability', () {
      ChatCapabilities.aliases.forEach((capability, phrases) {
        for (final phrase in phrases) {
          expect(
            ChatCapabilities.match(phrase),
            capability,
            reason: '"$phrase" must route to $capability',
          );
        }
      });
    });

    test('full sentences route by their capability words', () {
      expect(
        ChatCapabilities.match('please validate the plan before I build'),
        ChatCapability.validatePlan,
      );
      expect(
        ChatCapabilities.match('check the subnets for overlaps'),
        ChatCapability.subnetOverlaps,
      );
      expect(
        ChatCapabilities.match('are there any duplicate addresses?'),
        ChatCapability.duplicateAddresses,
      );
      expect(
        ChatCapabilities.match('what should I improve in the design?'),
        ChatCapability.improvePlan,
      );
    });

    test('ordinary chat and how-to questions are not captured', () {
      for (final msg in const [
        'add a dns server',
        'make it 3 routers',
        'what is better ospf or static routing',
        'how do I check for errors in packet tracer',
        'can I duplicate a config on another router',
        'check my cable crimping',
        'build the pkt',
      ]) {
        expect(
          ChatCapabilities.match(msg.toLowerCase()),
          isNull,
          reason: '"$msg" is not a capability ask',
        );
      }
    });
  });

  group('the answers come from the real services', () {
    test('validate reports the validator output, not a promise', () {
      final reply = ask('validate the plan', plan: lab);
      expect(reply.intent, 'capability');
      expect(reply.text.toLowerCase(), contains('read-only'));
      expect(reply.text.toLowerCase(), contains('checked'));
    });

    test('validate surfaces real errors with their severity', () {
      final broken = NetworkIntent.parseSimple('p', '2 pcs');
      final withDupes = broken.copyWith(
        addressing: [...broken.addressing, ...broken.addressing],
      );
      final reply = ask('validate the network', plan: withDupes);
      expect(reply.intent, 'capability');
      expect(reply.text, contains('[error]'));
      expect(reply.text.toLowerCase(), contains('duplicate'));
    });

    test('duplicate addresses are found when they exist', () {
      final broken = NetworkIntent.parseSimple('p', '2 pcs');
      final withDupes = broken.copyWith(
        addressing: [...broken.addressing, ...broken.addressing],
      );
      final reply = ask('any duplicate ips?', plan: withDupes);
      expect(reply.intent, 'capability');
      expect(reply.text.toLowerCase(), contains('duplicate'));
      expect(reply.text.toLowerCase(), contains('claimed by'));
    });

    test('a clean plan says so', () {
      final reply = ask('check the plan for errors', plan: lab);
      expect(reply.intent, 'capability');
      expect(
        reply.text.toLowerCase(),
        anyOf(contains('clean'), contains('finding')),
      );
    });

    test('no plan yet says so instead of inventing one', () {
      final reply = ask('check the plan for errors');
      expect(reply.intent, 'capability');
      expect(reply.text.toLowerCase(), contains('do not have a plan'));
    });

    test('a fallback plan (no devices named) is not checked as if real', () {
      // "build something" parses to the tiny-office fallback, which now
      // marks itself as an assumption - the check must not treat that guess
      // as a user plan.
      final fallback = NetworkIntent.parseSimple('p', 'build something');
      final reply = ask('validate the plan', plan: fallback);
      expect(reply.intent, 'capability');
      expect(reply.text.toLowerCase(), contains('do not have a plan'));
    });
  });

  group('the check action is a supported, read-only card', () {
    test('check_plan parses and does not warn as touching PT', () {
      expect(ChatAction.supported, contains('check_plan'));
      final parsed = ChatAction.parseList([
        {'kind': 'check_plan', 'summary': 'Check the plan (read-only)'},
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.kind, 'check_plan');
      expect(parsed.single.touchesPacketTracer, isFalse);
    });

    test('its label reads as a read-only check', () {
      const action = ChatAction(kind: 'check_plan', payload: {});
      expect(action.label.toLowerCase(), contains('read-only'));
    });
  });
}
