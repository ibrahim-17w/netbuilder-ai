import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/advisor_service.dart';
import 'package:net_builder/services/chat_service.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// The golden advice set: sixty design/purchase/sizing questions, grouped by
/// the venue they are asked in, answered with NO model and NO API key.
///
/// Three guarantees are measured for every line:
///
/// * the answer is ADVICE: a recommendation, 2+ options that each carry a
///   "choose this when" and a trade-off, at most two questions, a concrete
///   next step and a provenance line;
/// * the standing plan is untouched - the question about the lab never
///   re-plans the lab;
/// * every quick reply is a real next step: tapping it never lands on the
///   vague reply, the missing-coverage reply or the scope decline.
///
/// The model path is pinned too: `ChatService.systemContext` must carry the
/// same advisory contract, so advise-with-a-key and advise-without-a-key
/// answer the same shape.
void main() {
  AssistantReply ask(String q, {NetworkIntent? plan}) =>
      OfflineAssistantService.reply(
        rawText: q,
        normalized: q.toLowerCase(),
        target: 'packet-tracer',
        plan: plan,
      );

  const home = <String>[
    'which router should i get for a home?',
    'mesh or access points for a long house?',
    'is wifi 6 worth it for a home?',
    'do i need a managed switch at home?',
    'what is the best way to cover a three-floor house with wifi?',
    'how many access points do i need for a home with 30 devices?',
    'should we set up a guest network for visitors at home?',
    'do i need a ups for the home router and modem?',
  ];
  const office = <String>[
    'which router should i get for an office with 20 employees?',
    'do we need a firewall for a small office?',
    'is a managed switch worth it for an office?',
    'how many access points do i need for 40 users?',
    'how much bandwidth do i need for 50 users?',
    'do i need a poe switch for 6 cameras?',
    'how should i set up guest wifi for clients?',
    'what should i use for remote access to the office?',
    'fiber or copper between two offices a block apart?',
    'is a second internet line worth it for the office?',
  ];
  const school = <String>[
    'how many access points do i need for 300 students?',
    'which wifi standard should i get for a school?',
    'how much bandwidth do we need for a school with 300 students?',
    'should we separate staff, students and guest networks?',
    'do we need a firewall that filters content for a school?',
    'what switch do i need for a classroom block with 30 pcs?',
  ];
  const clinic = <String>[
    'what firewall do we need for a clinic with patients?',
    'should patients get guest wifi?',
    'where should we put the dns and dhcp server in a clinic?',
    'do we need a ups and a rack for a clinic?',
    'do we need ip cameras in a clinic?',
    'how many access points for a clinic with 15 staff?',
  ];
  const cafe = <String>[
    'which router should i get for a cafe?',
    'should guests get their own ssid and vlan at the cafe?',
    'how much bandwidth does a cafe with 50 customers need?',
    'do we need a captive portal for cafe wifi?',
    'should the point of sale be on its own vlan?',
    'do we need cameras in the cafe?',
  ];
  const industrial = <String>[
    'how many access points do i need in a warehouse?',
    'mesh or access points in a warehouse?',
    'fiber or copper between the warehouse and the office?',
    'do we need a poe switch for cameras in the warehouse?',
    'is a backup internet line worth it for the warehouse?',
    'do we need a rack and ups for the warehouse cabinet?',
  ];
  const lab = <String>[
    'which router should i use for this lab?',
    'which switch should i get for a packet tracer lab?',
    'what is the difference between a router and a switch?',
    'should i use a 2960 or a 3560 for inter-vlan routing in the lab?',
    'which model should i use for an ospf lab in packet tracer?',
    'which is better, a 2911 or a 4331 for the lab?',
    '2960 or 3560',
    'is the 1841 enough for an ospf lab?',
    'do i need a firewall in a packet tracer lab?',
    'how many access points should i use in a wireless lab?',
    'review my lab design for a packet tracer network',
  ];
  const comparisons = <String>[
    'which is better, fiber or copper for a 150 m run?',
    'is wifi 7 worth it over wifi 6?',
    'what vpn should i use for two offices?',
    'which is better, port forwarding or a vpn for remote access?',
    'should i use a layer 3 switch or router-on-a-stick?',
    'should i use a server or cloud services for file sharing?',
    'which switch should i get for 30 devices?',
    'how much bandwidth do i need for 80 users?',
  ];
  const design = <String>[
    'what do you recommend for a small office network?',
    'review my design for a small office',
    'is a poe switch worth it?',
    'what firewall should we use with a guest network?',
  ];
  final all = <String>[
    ...home,
    ...office,
    ...school,
    ...clinic,
    ...cafe,
    ...industrial,
    ...lab,
    ...comparisons,
    ...design,
  ];

  group('golden advice battery: every question gets a recommendation', () {
    test('the battery is the promised breadth', () {
      expect(all.length, greaterThanOrEqualTo(60));
    });
    for (final q in all) {
      test('"$q"', () {
        final a = AdvisorService.advise(q);
        expect(a, isNotNull, reason: 'this is an advisory question');
        final answer = a!;
        expect(answer.recommendation.trim(), isNotEmpty);
        expect(
          answer.options.length,
          greaterThanOrEqualTo(2),
          reason: 'advice offers real choices, not one canned paragraph',
        );
        for (final o in answer.options) {
          expect(o.chooseWhen.trim(), isNotEmpty, reason: o.label);
          expect(o.tradeOff.trim(), isNotEmpty, reason: o.label);
        }
        expect(answer.questions.length, lessThanOrEqualTo(2));
        expect(answer.nextStep.trim(), isNotEmpty);
        expect(answer.basis.trim(), isNotEmpty, reason: 'provenance');
        final r = ask(q);
        expect(r.intent, 'advice');
        expect(r.text, contains('What I would do'));
        expect(r.text, contains('Based on:'));
        expect(
          r.text.toLowerCase(),
          isNot(contains('i need a bit more to go on')),
          reason: 'an advice question is answered, not deflected',
        );
        expect(
          r.text.toLowerCase(),
          isNot(contains('not in my offline material')),
          reason: 'the advisory corpus must cover all sixty',
        );
        expect(r.quickReplies, isNotEmpty);
        expect(r.quickReplies.length, lessThanOrEqualTo(3));
      });
    }
  });

  group('advice never touches the plan', () {
    const standingBrief = '2 routers, 2 switches and 10 pcs with ospf';
    for (final q in all) {
      test('"$q"', () {
        final standing = NetworkIntent.parseSimple('p', standingBrief);
        final outcome = NetworkIntent.followUp(
          previous: standing,
          previousBrief: standingBrief,
          brief: q,
          parsed: NetworkIntent.parseSimple('p', q),
          project: 'p',
        );
        expect(
          outcome.plan.nodes.length,
          standing.nodes.length,
          reason: 'the question must not replace the lab it asks about',
        );
        expect(outcome.brief, standingBrief);
        final r = ask(q, plan: standing);
        expect(r.intent, 'advice');
        expect(r.repairedPlan, isNull);
      });
    }
  });

  group('every quick reply is a real next step, not a dead end', () {
    for (final q in all) {
      test('chips from "$q"', () {
        final answer = AdvisorService.advise(q)!;
        for (final chip in answer.quickReplies) {
          // The chat parses the message into a plan BEFORE it asks the
          // assistant, so the chip is checked the same way: with its parsed
          // plan on the table, not in a vacuum.
          final r = ask(chip, plan: NetworkIntent.parseSimple('p', chip));
          expect(
            const ['vague', 'missing', 'offtopic'],
            isNot(contains(r.intent)),
            reason: 'tapping "$chip" dead-ends at ${r.intent}',
          );
          expect(r.text.trim(), isNotEmpty);
        }
      });
    }
  });

  group('provenance', () {
    test('with a plan, the answer says it is based on the lab', () {
      final plan = NetworkIntent.parseSimple('p', '2 routers and 4 pcs');
      final a = AdvisorService.advise(
        'which switch should i use for this lab?',
        plan: plan,
      )!;
      expect(a.basis, contains('lab on the table'));
      expect(a.basis, contains('2 routers'));
      final r = ask('which switch should i use for this lab?', plan: plan);
      expect(r.text, contains('Based on: the lab on the table'));
    });

    test('real-world answers say the gear is examples and prices are not', () {
      final a = AdvisorService.advise('which router should i get for a home?')!;
      expect(a.basis.toLowerCase(), contains('check current prices'));
      expect(a.basis.toLowerCase(), contains('examples'));
    });
  });

  group('the model path is told the same advice contract', () {
    test('systemContext pins the advisor rules', () {
      final prompt = ChatService.systemContext(
        target: 'packet-tracer',
        rulePacks: '',
        learnedRules: const [],
        preferences: const {},
        knownBlockers: const [],
        unsupportedCapabilities: const [],
        liveState: '',
      );
      expect(prompt, contains('ADVICE GETS A RECOMMENDATION'));
      expect(prompt, contains('ADVICE NEVER CHANGES THE PLAN'));
      expect(prompt, contains('NO INVENTED PRICES OR STOCK'));
      expect(prompt, contains('choose this when'));
    });
  });
}
