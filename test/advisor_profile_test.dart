import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/environment_profile.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// The remembered environment must change the advice the way the message
/// would have - and must never overwrite a fact the message states itself.
///
/// The golden battery (advisor_golden_test.dart) pins the advice SHAPE;
/// this file pins the profile MERGE: what a stored venue/scale/budget does
/// to an answer whose message leaves that fact unsaid.
void main() {
  AssistantReply ask(
    String q, {
    EnvironmentProfile? profile,
  }) =>
      OfflineAssistantService.reply(
        rawText: q,
        normalized: q.toLowerCase(),
        target: 'packet-tracer',
        environmentProfile: profile,
      );

  test('a remembered scale sizes the answer when the message states none',
      () {
    final r = ask(
      'how many access points do i need?',
      profile: const EnvironmentProfile(scale: 40),
    );
    expect(r.intent, 'advice');
    expect(r.advice, isNotNull);
    expect(r.text, contains('About 40 active devices'));
    expect(r.text, contains('2 AP(s)'));
  });

  test('without a profile the same question asks for the count', () {
    final r = ask('how many access points do i need?');
    expect(r.intent, 'advice');
    expect(r.text, isNot(contains('About')));
    expect(r.questions, isNotEmpty);
  });

  test('the message beats the profile: a stated count wins', () {
    final r = ask(
      'how many access points for 60 users?',
      profile: const EnvironmentProfile(scale: 40),
    );
    expect(r.text, contains('About 60 active devices'));
    expect(r.text, isNot(contains('About 40 active devices')));
  });

  test('a remembered venue shapes the plan-able sentence', () {
    // The question names the lab, so the advisor is allowed to offer a
    // plan-able sentence; the remembered venue decides WHAT it offers.
    final home = ask(
      'how many access points do i need for my packet tracer lab?',
      profile: const EnvironmentProfile(venue: 'home'),
    );
    expect(
      home.advice!.planBrief,
      'Build a home network with 1 wireless router and 4 PCs',
    );

    final office = ask(
      'how many access points do i need for my packet tracer lab?',
      profile: const EnvironmentProfile(venue: 'office'),
    );
    expect(
      office.advice!.planBrief,
      'Build a small office with 1 router, 1 switch, 2 access points '
      'and 10 PCs',
    );
  });

  test('a remembered budget changes the design review', () {
    final r = ask(
      'review my design',
      profile: const EnvironmentProfile(budget: true),
    );
    expect(r.intent, 'advice');
    expect(r.text, contains('On a tight budget'));
  });

  test('the structured advice rides the reply, not just the markdown', () {
    final r = ask(
      'which router should i get for my lab at home?',
      profile: const EnvironmentProfile(venue: 'home', skill: 'beginner'),
    );
    expect(r.advice, isNotNull);
    expect(r.advice!.recommendation, isNotEmpty);
    expect(r.advice!.options.length, greaterThanOrEqualTo(2));
    for (final o in r.advice!.options) {
      expect(o.chooseWhen, isNotEmpty);
      expect(o.tradeOff, isNotEmpty);
    }
    expect(r.advice!.basis, isNotEmpty);
    expect(r.advice!.planBrief, isNotNull);
  });
}
