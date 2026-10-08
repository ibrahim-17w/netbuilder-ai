import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';

/// The chat screen's rule for what the standing plan becomes after a turn.
/// Mirrored here because the bug it prevents - a short follow-up replacing a
/// real plan with the parser's default lab - only shows at this level.
NetworkIntent standing(NetworkIntent? previous, String raw) {
  final normalized = CasualEnglish.normalize(raw);
  return NetworkIntent.planAfterFollowUp(
    previous: previous,
    parsed: NetworkIntent.parseSimple(
      'offline-chat',
      normalized.isEmpty ? raw : normalized,
    ),
    brief: normalized.isEmpty ? raw : normalized,
  );
}

/// Mirror what the chat screen does for an offline turn, so these tests pin
/// the keyless conversation end to end.
AssistantReply ask(String raw) {
  final normalized = CasualEnglish.normalize(raw);
  NetworkIntent? plan;
  try {
    plan = NetworkIntent.parseSimple(
      'offline-chat',
      normalized.isEmpty ? raw : normalized,
    );
  } catch (_) {
    plan = null;
  }
  final suggestions =
      plan == null ? <String>[] : PlannerSuggestionsService.forIntent(plan);
  return OfflineAssistantService.reply(
    rawText: raw,
    normalized: normalized,
    target: 'pt',
    plan: plan,
    suggestions: suggestions,
    modelError: 'HTTP 429: rate limited',
  );
}

void main() {
  test('a greeting is answered like a person, offline', () {
    final r = ask('hi');
    expect(r.intent, 'greeting');
    expect(r.text.toLowerCase(), contains('offline'));
    expect(r.text, isNot(contains('Could not reach')));
  });

  test('a vague message asks questions instead of erroring', () {
    final r = ask('make it normal');
    expect(r.intent, 'vague');
    expect(r.questions, isNotEmpty);
    expect(r.text, isNot(contains('Could not reach')));
  });

  test('a how-to question gets a real answer with advice', () {
    final r = ask('what is better ospf or static');
    expect(r.intent, 'howto');
    expect(r.text.toLowerCase(), contains('ospf'));
    expect(r.text.toLowerCase(), contains('static'));
  });

  test('a casual, typo-ridden build request still plans and advises', () {
    final r = ask('i wanna 2 swtich and 3 routrs pls');
    expect(r.intent, 'build');
    expect(r.text.toLowerCase(), contains('router'));
    expect(r.text.toLowerCase(), contains('switch'));
    expect(r.text, isNot(contains('Could not reach')));
  });

  test('a change request explains itself and how to persist it', () {
    final r = ask('change the router to 4331');
    expect(r.intent, 'change');
    expect(r.text, contains('4331'));
    expect(r.text.toLowerCase(), contains('rule'));
  });

  test('a mode question is answered, not planned', () {
    final r = ask('how do i connect two routers');
    expect(r.intent, 'howto');
    expect(r.text.toLowerCase(), contains('serial'));
  });

  group('a follow-up keeps the plan the user actually asked for', () {
    final real = NetworkIntent.parseSimple(
      'chat',
      '10 pcs, 1 server, 1 switch and a router with ospf',
    );

    test('building the file does not re-plan a default lab over the real one',
        () {
      final next = standing(real, 'ok build the packet tracer file');
      expect(next.nodes.length, real.nodes.length);
      expect(
        next.nodes.where((n) => n.type == 'pc').length,
        10,
        reason: 'the 10 PCs from the original ask must survive',
      );
    });

    test('neither does a vague nudge or a short approval', () {
      expect(standing(real, 'ok').nodes.length, real.nodes.length);
      expect(standing(real, 'go on').nodes.length, real.nodes.length);
      expect(standing(real, 'yes please').nodes.length, real.nodes.length);
    });

    test('a message that names devices re-plans on purpose', () {
      final grown = standing(real, 'actually make it 2 routers and 20 pcs');
      expect(grown.nodes.where((n) => n.type == 'pc').length, 20);
      expect(grown.nodes.where((n) => n.type == 'router').length, 2);
    });

    test('a brand-new chat with no devices still gets the default lab', () {
      final fresh = standing(null, 'ok build the packet tracer file');
      expect(fresh.nodes, isNotEmpty);
      // The parser's fallback (router + switch) is correct here: there is
      // nothing to protect yet.
      expect(fresh.nodes.where((n) => n.type == 'router'), isNotEmpty);
    });

    test('a bigger plan from the same words is never discarded', () {
      final bigger = standing(real, 'ok build the packet tracer file');
      expect(bigger.nodes.length, greaterThanOrEqualTo(2));
    });
  });

  group('the assistant can talk about itself', () {
    test('"who are you" introduces the offline assistant, not a plan', () {
      final r = ask('who are you');
      expect(r.intent, 'identity');
      expect(r.text, contains('NetBuilder assistant'));
      expect(r.text.toLowerCase(), contains('offline'));
      expect(r.text.toLowerCase(), contains('leaves this device'));
      expect(r.repairedPlan, isNull);
      expect(r.text, isNot(contains('lab I understand')));
    });

    test('"what can you do" lists real abilities with examples', () {
      final r = ask('what can you do');
      expect(r.intent, 'identity');
      expect(r.text, contains('Plan a lab'));
      expect(r.text, contains('.pkt'));
      expect(r.quickReplies, isNotEmpty);
      expect(r.quickReplies.length, lessThanOrEqualTo(4));
    });

    test('"how are you" is answered warmly and locally', () {
      final r = ask('how are you');
      expect(r.intent, 'identity');
      expect(r.text.toLowerCase(), contains('local'));
    });

    test('"are you an AI" is answered honestly: rules, no model', () {
      final r = ask('are you an AI');
      expect(r.intent, 'identity');
      expect(r.text.toLowerCase(), contains('no model'));
      expect(r.text.toLowerCase(), contains('rule-based'));
    });

    test('"who made you" names no invented maker', () {
      final r = ask('who made you');
      expect(r.intent, 'identity');
      expect(r.text, contains('NetBuilder AI'));
      expect(r.text, isNot(contains('OpenAI')));
    });

    test('"do you need internet" confirms the fully local operation', () {
      final r = ask('do you need internet');
      expect(r.intent, 'identity');
      expect(r.text.toLowerCase(), contains('offline'));
      expect(r.text.toLowerCase(), contains('no api key'));
    });

    test('an identity opener over a network question keeps its route', () {
      final r = ask('what can you do about the OSPF adjacency');
      expect(r.intent, isNot('identity'));
      expect(r.text.toLowerCase(), contains('ospf'));
    });
  });

  group('a farewell is answered like a farewell', () {
    test('"bye" says goodbye and that nothing leaves the device', () {
      final r = ask('bye');
      expect(r.intent, 'bye');
      expect(r.text.toLowerCase(), contains('device'));
      expect(r.text, isNot(contains('lab I understand')));
    });

    test('the other farewells farewell too', () {
      expect(ask('goodbye').intent, 'bye');
      expect(ask('good night').intent, 'bye');
      expect(ask('see you').intent, 'bye');
      expect(ask('later').intent, 'bye', reason: 'later is a goodbye, not a no');
    });
  });

  group('the greeting set covers how people actually open', () {
    for (final g in const ['hiya', 'heyo', 'howdy', 'greetings', 'good day']) {
      test('"$g" is a greeting', () {
        final r = ask(g);
        expect(r.intent, 'greeting', reason: g);
        expect(r.text.toLowerCase(), contains('offline'));
      });
    }

    test('cheers is not swallowed by the greeting set', () {
      // "cheers" is acknowledgement/small-talk territory elsewhere (the
      // scope gate); the greeting branch must not take it over.
      expect(ask('cheers').intent, isNot('greeting'));
    });
  });
}
