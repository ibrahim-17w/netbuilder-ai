import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// A keyless chat has to read like a conversation, not like a form: one
/// account of why there is no model, acknowledgements that are answered,
/// follow-ups that pick up where the last turn left off, and suggestions that
/// are things the app can actually do.
void main() {
  AssistantReply ask(
    String raw, {
    String normalized = '',
    NetworkIntent? plan,
    NetworkIntent? previousPlan,
    List<ChatMessage> history = const [],
  }) => OfflineAssistantService.reply(
    rawText: raw,
    normalized: normalized.isEmpty ? raw.toLowerCase() : normalized,
    target: 'pt',
    plan: plan,
    previousPlan: previousPlan,
    suggestions: const [],
    history: history,
  );

  final lab = NetworkIntent.parseSimple(
    'p',
    '2 routers 1 switch 4 pcs with ospf',
  );

  ChatMessage turn(String role, String text) =>
      ChatMessage(role: role, text: text);

  group('the offline notice is said once, not every turn', () {
    test('the first answer explains the situation', () {
      final first = ask('build a small office lab');
      // The offline STATE moved out of the text: it is the header sign's
      // job now, and the turn's source line. The answer itself starts with
      // its content.
      expect(first.text.toLowerCase(), isNot(contains('offline')));
    });

    test('the next answers just answer', () {
      final second = ask(
        'add a DNS server',
        plan: lab,
        history: [
          turn('user', 'build a small office lab'),
          turn('model', 'Answering offline - no API key needed.'),
        ],
      );
      expect(second.text.toLowerCase(), isNot(contains('offline')));
      expect(second.text, isNot(contains('no API key')));
    });

    test('a model failure is reported once, then conversation resumes', () {
      final failed = OfflineAssistantService.reply(
        rawText: 'hi',
        normalized: 'hi',
        target: 'pt',
        modelError: 'HTTP 429: rate limited',
      );
      // The failure itself is not pasted into the answer any more. The
      // caller reports it where it can be checked: the header sign (via
      // AiStatus.describe's lastError) and the turn's source line.
      expect(failed.text, isNot(contains('429')));
      expect(
        failed.text,
        isNot(contains('unavailable')),
        reason: 'the provider failure is not the answer\'s opening line',
      );

      final later = OfflineAssistantService.reply(
        rawText: 'hi',
        normalized: 'hi',
        target: 'pt',
        modelError: 'HTTP 429: rate limited',
        history: [
          turn('user', 'hello'),
          turn('model', failed.text),
        ],
      );
      expect(later.text, isNot(contains('429')));
      expect(later.text, failed.text);
    });

    test('private mode answers with content, never a mode label', () {
      // The mode is the top bar's AI pill now: the transcript stays free of
      // "Private mode is on" lines, on the first turn and every turn after.
      final reply = OfflineAssistantService.reply(
        rawText: 'hi',
        normalized: 'hi',
        target: 'pt',
        privateMode: true,
      );
      expect(reply.text, isNot(contains('Private mode')));
      final later = OfflineAssistantService.reply(
        rawText: 'hi',
        normalized: 'hi',
        target: 'pt',
        privateMode: true,
        history: [
          turn('user', 'hello'),
          turn('model', reply.text),
        ],
      );
      expect(later.text, isNot(contains('Private mode')));
    });
  });

  group('the conversation moves like a conversation', () {
    test('a thank-you keeps the plan in view instead of re-planning', () {
      final reply = ask('thanks', plan: lab);
      expect(reply.intent, 'ack');
      expect(reply.text, contains('2 routers'));
      expect(reply.text, isNot(contains('Next steps')));
      expect(reply.quickReplies, contains('Build the .pkt'));
    });

    test('a bare yes confirms the lab that is on the table', () {
      final reply = ask('yes', plan: lab);
      expect(reply.intent, 'confirm');
      expect(reply.text, contains('2 routers'));
      expect(reply.text, contains('Build the .pkt'));
      expect(reply.quickReplies, contains('Build the .pkt'));
    });

    test('a bare no asks what to change', () {
      final reply = ask('no', plan: lab);
      expect(reply.intent, 'deny');
      expect(reply.text.toLowerCase(), contains('change'));
      expect(reply.quickReplies, isEmpty);
    });

    test('a short follow-up is answered in the context of the plan', () {
      final reply = ask(
        'and vlans?',
        plan: lab,
        history: [turn('user', '2 routers 1 switch 4 pcs with ospf')],
      );
      expect(reply.intent, 'howto');
      expect(reply.text, contains('For the lab you have planned'));
      expect(reply.text, contains('2 routers'));
    });

    test('a standalone question is not dressed up as a follow-up', () {
      final reply = ask('what is better ospf or static');
      expect(reply.intent, 'howto');
      expect(reply.text, isNot(contains('For the lab you have planned')));
    });

    test('a greeting and a thank-you are different turns', () {
      expect(ask('hi').intent, 'greeting');
      expect(ask('thanks').intent, 'ack');
      expect(ask('ok').intent, 'ack');
    });
  });

  group('the plan actually changes when asked', () {
    test('"use ospf" switches the standing plan', () {
      final statics = NetworkIntent.parseSimple('p', '2 routers 4 pcs');
      expect(statics.routing, 'static');
      final changed = NetworkIntent.applyFollowUpChange(
        previous: statics,
        brief: 'use ospf for routing',
      );
      expect(changed, isNotNull);
      expect(changed!.routing, 'ospf');
      expect(changed.nodes.length, statics.nodes.length,
          reason: 'a routing change must not re-plan the topology');
    });

    test('the offline advice and the offline action agree', () {
      // The build answer tells the user to say "use ospf" to switch. That
      // sentence is a promise, so the same words have to switch it.
      final statics = NetworkIntent.parseSimple('p', '2 routers 4 pcs');
      final advice = ask(
        'now build it',
        plan: statics,
        history: [turn('user', '2 routers 4 pcs')],
      ).text;
      expect(advice.toLowerCase(), contains('ospf'));
      expect(
        NetworkIntent.applyFollowUpChange(
          previous: statics,
          brief: 'use ospf',
        )?.routing,
        'ospf',
      );
    });

    test('a switch back to static works too', () {
      final ospf = NetworkIntent.parseSimple('p', '2 routers with ospf');
      final back = NetworkIntent.applyFollowUpChange(
        previous: ospf,
        brief: 'use static routing instead',
      );
      expect(back?.routing, 'static');
    });

    test('naming devices is a re-plan, not a tweak', () {
      final statics = NetworkIntent.parseSimple('p', '2 routers 4 pcs');
      expect(
        NetworkIntent.applyFollowUpChange(
          previous: statics,
          brief: 'use ospf on 3 routers',
        ),
        isNull,
      );
    });

    test('asking for the protocol it already uses changes nothing', () {
      final ospf = NetworkIntent.parseSimple('p', '2 routers with ospf');
      expect(
        NetworkIntent.applyFollowUpChange(previous: ospf, brief: 'use ospf'),
        isNull,
      );
      expect(
        NetworkIntent.applyFollowUpChange(
          previous: ospf,
          brief: 'build the pkt',
        ),
        isNull,
      );
    });

    test('a change is reported to the user, not just applied', () {
      final statics = NetworkIntent.parseSimple('p', '2 routers 4 pcs');
      final ospf = NetworkIntent.parseSimple('p', '2 routers 4 pcs with ospf');
      final reply = ask(
        'use ospf',
        plan: ospf,
        previousPlan: statics,
        history: [turn('user', '2 routers 4 pcs')],
      );
      expect(reply.text, contains('routing is now ospf'));
    });
  });

  group('the suggestions are things the app can do', () {
    test('a plan offers the build and a routing switch', () {
      final replies = [
        ask('thanks', plan: lab),
        ask('yes', plan: lab),
        ask('2 routers 1 switch 4 pcs with ospf', plan: lab),
      ];
      for (final reply in replies) {
        expect(reply.quickReplies, isNotEmpty, reason: reply.intent);
        for (final quick in reply.quickReplies) {
          expect(quick.trim(), isNotEmpty);
          expect(quick.length, lessThan(40));
        }
      }
    });

    test('with no plan the suggestions are example briefs', () {
      final reply = ask('hmm');
      expect(reply.intent, 'vague');
      expect(reply.questions, isNotEmpty);
      expect(reply.quickReplies, isNotEmpty);
      expect(reply.quickReplies.first, contains('router'));
    });
  });
}
