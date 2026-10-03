import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/advisor_service.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// The advisory battery: design, purchase and sizing questions answered with
/// NO model and NO API key. Nothing in this file ever sets a key, so a pass
/// is proof the answer came from [AdvisorService] and the offline paths.
///
/// The plan rule is measured here too: advice is answered, and the lab on
/// the table is exactly as it was afterwards.
void main() {
  AssistantReply ask(String q, {NetworkIntent? plan}) =>
      OfflineAssistantService.reply(
        rawText: q,
        normalized: q.toLowerCase(),
        target: 'packet-tracer',
        plan: plan,
      );

  group('advice questions are answered as advice, keyless', () {
    final cases = <String, String>{
      'what router should i use in this case?': 'all-in-one',
      'which router should i get for a home with 4 people?': 'all-in-one',
      'which router should i get for an office with 20 employees?':
          'business router',
      'how many access points do i need for 50 users?': 'access point',
      'which is better, fiber or copper for a run between two buildings?':
          'fiber',
      'is a managed switch worth it?': 'managed',
      'do i need a poe switch for 6 cameras?': 'nvr',
      'my wifi is slow in the back office, what should i do?': 'wired',
      'review my design for a small office': 'what i would do',
      'how much bandwidth do i need for 50 users?': 'mbit/s',
      'what firewall do we need for a clinic with guests?': 'firewall',
      'should i use pppoe or dhcp on the wan?': 'wan',
    };
    cases.forEach((q, expected) {
      test('offline advice: "$q"', () {
        final r = ask(q);
        expect(r.intent, 'advice', reason: 'not a plan dump, not a refusal');
        expect(r.text.toLowerCase(), contains(expected));
        expect(r.text, contains('What I would do'));
        expect(
          r.text.toLowerCase(),
          isNot(contains('i need a bit more to go on')),
          reason: 'an advice question is answered, not deflected',
        );
        expect(
          r.quickReplies,
          isNotEmpty,
          reason: 'advice always offers a next tap',
        );
      });
    });
  });

  group('advice is structured, not one canned paragraph', () {
    test('options carry a choose-when and a trade-off', () {
      final a = AdvisorService.advise('which router should I use?')!;
      expect(a.recommendation, isNotEmpty);
      expect(a.options.length, greaterThanOrEqualTo(2));
      for (final o in a.options) {
        expect(o.chooseWhen, isNotEmpty);
        expect(o.tradeOff, isNotEmpty);
      }
      expect(a.questions.length, lessThanOrEqualTo(2),
          reason: 'at most two questions may change the recommendation');
      expect(a.nextStep, isNotEmpty);
      expect(a.toText(), contains('| Option | Choose it when | Trade-off |'));
    });

    test('sizing really computes from the stated number', () {
      final a = AdvisorService.advise(
        'how much bandwidth do I need for 80 users?',
      )!;
      expect(a.topic, 'sizing');
      expect(a.reasons.join(' '), contains('600 Mbit/s'));
      expect(a.reasons.join(' '), contains('2000 Mbit/s'));
    });

    test('the venue changes the recommendation', () {
      final home = AdvisorService.advise(
        'which router should I get for a home?',
      )!;
      final office = AdvisorService.advise(
        'which router should I get for an office?',
      )!;
      expect(home.topic, 'router_selection');
      expect(office.topic, 'router_selection');
      expect(home.recommendation.toLowerCase(), contains('all-in-one'));
      expect(office.recommendation.toLowerCase(), contains('office'));
      expect(home.recommendation, isNot(office.recommendation));
    });
  });

  group('advice never touches the plan', () {
    final plan = NetworkIntent.parseSimple(
      'p',
      '2 routers, 1 switch and 4 pcs with ospf',
    );

    test('the answer names the lab and repairs nothing', () {
      final r = ask('which switch should i use for this lab?', plan: plan);
      expect(r.intent, 'advice');
      expect(r.repairedPlan, isNull, reason: 'advice is read-only');
      expect(r.text, contains('2 routers'));
    });

    test('a router question does not re-plan over the standing lab', () {
      final r = ask('what router should i use in this case?', plan: plan);
      expect(r.intent, 'advice');
      final outcome = NetworkIntent.followUp(
        previous: plan,
        previousBrief: '2 routers, 1 switch and 4 pcs with ospf',
        brief: 'what router should i use in this case?',
        parsed: NetworkIntent.parseSimple(
          'p',
          'what router should i use in this case?',
        ),
        project: 'p',
      );
      expect(outcome.plan.nodes.length, plan.nodes.length);
      expect(
        outcome.plan.nodes.where((n) => n.type == 'router').length,
        2,
        reason: 'the advice question must not replace the lab it asks about',
      );
      expect(
        outcome.brief,
        '2 routers, 1 switch and 4 pcs with ospf',
        reason: 'the standing brief is untouched',
      );
    });
  });

  group('the intent taxonomy reads advice as its own kind', () {
    test('while the existing kinds stay exactly as they were', () {
      expect(
        NetworkIntent.classifyBrief('what router should i use in this case?'),
        'advice',
      );
      expect(
        NetworkIntent.classifyBrief(
          'how many access points do i need for 50 users?',
        ),
        'advice',
      );
      expect(NetworkIntent.classifyBrief('review my design'), 'advice');
      expect(
        NetworkIntent.classifyBrief('how do I configure a trunk port?'),
        'howto',
      );
      expect(NetworkIntent.classifyBrief('what is better ospf or static'),
          'howto');
      expect(
        NetworkIntent.classifyBrief('recommend 2 routers and 4 pcs'),
        'build',
        reason: 'a stated count is a build request, however it is phrased',
      );
      expect(NetworkIntent.classifyBrief('build 3 routers with ospf'), 'build');
    });
  });

  group('the boundary still holds', () {
    test('configuration questions are not advice', () {
      for (final q in const [
        'how do I configure a trunk port on a 2960 switch',
        'how does dhcp snooping work',
        'what cable do I use between two switches',
        'which cable to connect pc to switch',
        'what is better ospf or static routing',
      ]) {
        final r = ask(q);
        expect(r.intent, isNot('advice'), reason: q);
        expect(r.intent, isNot('offtopic'), reason: q);
      }
    });

    test('a build request with counts still plans', () {
      // The chat parses the plan before it asks the assistant, so the same
      // turn is given its parsed plan here - otherwise the reply is looking
      // at no plan at all.
      final plan = NetworkIntent.parseSimple(
        'p',
        'recommend 2 routers and 4 pcs',
      );
      final r = ask('recommend 2 routers and 4 pcs', plan: plan);
      expect(r.intent, 'build');
      expect(r.text, contains('router'));
    });
  });
}
