import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The conversation that went wrong, replayed step by step.
///
/// The user discussed a two-site company network (50 PCs, phones, servers,
/// VLANs) and said "ok build this network then" - and the app confirmed,
/// and built, "1 router, 1 switch, 1 server" (a 3-device file). These tests
/// pin the fixed behaviour of the whole exchange: greetings and questions
/// no longer seed or overwrite the plan, described sites become a
/// multi-site network, "more than 1 router" is a floor rather than a count
/// of one, an unknown phone count becomes a question instead of a PH1, and
/// the build confirmation names the discussed scale.
void main() {
  final turnNames = <String>[];

  String brief = '';
  NetworkIntent? plan;

  NetworkIntent? turn(String message) {
    final parsed = NetworkIntent.parseSimple('chat', message);
    final outcome = NetworkIntent.followUp(
      previous: plan,
      previousBrief: brief,
      brief: message,
      parsed: parsed,
      project: 'chat',
    );
    plan = outcome.plan;
    brief = outcome.brief;
    turnNames.add(message);
    return plan;
  }

  int count(NetworkIntent p, String type) =>
      p.nodes.where((n) => n.type == type).length;

  tearDown(() {
    plan = null;
    brief = '';
    turnNames.clear();
  });

  group('the discussed network survives the conversation', () {
    test('hello does not seed a default lab', () {
      final p = turn('hello');
      expect(
        p == null || p.nodes.isEmpty,
        isTrue,
        reason: 'a greeting is not a specification',
      );
    });

    test('a recommendations question does not create a plan', () {
      turn('hello');
      final p = turn(
        'I need to build a network for a large company what is your '
        'recommendations ?',
      );
      expect(p == null || p.nodes.isEmpty, isTrue);
    });

    test('two physical sites and 50 PCs become a multi-site network', () {
      turn('hello');
      turn(
        'I need to build a network for a large company what is your '
        'recommendations ?',
      );
      final p = turn(
        "two physical sites and like 50 PCs and i don't know how many phones",
      )!;
      expect(count(p, 'pc'), 50);
      expect(
        count(p, 'phone'),
        0,
        reason: '"i don\'t know how many phones" must not invent a PH1',
      );
      expect(count(p, 'router'), 2, reason: 'one router per described site');
      expect(count(p, 'switch'), greaterThanOrEqualTo(2));
      expect(p.links, isNotEmpty, reason: 'a described network is wired, not a PC farm');
      expect(
        p.questions.where((q) => q.toLowerCase().contains('how many phones')),
        isNotEmpty,
        reason: 'the unknown phone count is asked about',
      );
      expect(
        p.assumptions.any((a) => a.contains('sites')),
        isTrue,
        reason: 'the completion is stated as an assumption',
      );
    });

    test('a question about the devices does not re-plan over the lab', () {
      turn('hello');
      turn(
        'I need to build a network for a large company what is your '
        'recommendations ?',
      );
      turn(
        "two physical sites and like 50 PCs and i don't know how many phones",
      );
      final p = turn('what about the routers and switches and servers?')!;
      expect(count(p, 'pc'), 50);
      expect(count(p, 'router'), 2);
    });

    test('"more than ..." grows the lab and never shrinks it', () {
      turn('hello');
      turn(
        'I need to build a network for a large company what is your '
        'recommendations ?',
      );
      turn(
        "two physical sites and like 50 PCs and i don't know how many phones",
      );
      turn('what about the routers and switches and servers?');
      final p = turn(
        'I think we will need more than 1 router and 1 switch and 1 server '
        'and it should be secure',
      )!;
      expect(
        count(p, 'pc'),
        50,
        reason: 'the discussed network must not collapse back to a few devices',
      );
      expect(count(p, 'router'), greaterThanOrEqualTo(2));
      expect(count(p, 'server'), greaterThanOrEqualTo(1));
      expect(
        p.questions.where((q) => q.toLowerCase().contains('secure')),
        isNotEmpty,
        reason: '"it should be secure" is a requirement without a control',
      );
      expect(
        p.assumptions.any((a) => a.contains('more than 1 router')),
        isTrue,
        reason: 'the floor reading is stated',
      );
    });

    test('"ok then build this network" confirms the discussed scale', () {
      turn('hello');
      turn(
        'I need to build a network for a large company what is your '
        'recommendations ?',
      );
      turn(
        "two physical sites and like 50 PCs and i don't know how many phones",
      );
      turn('what about the routers and switches and servers?');
      turn(
        'I think we will need more than 1 router and 1 switch and 1 server '
        'and it should be secure',
      );
      final reply = OfflineAssistantService.reply(
        rawText: 'ok then build this network',
        normalized: 'ok then build this network',
        target: 'packet-tracer',
        plan: plan,
      );
      expect(reply.intent, 'confirm');
      expect(reply.text, contains('50 PC'));
      expect(
        reply.text,
        isNot(contains('1 router, 1 switch')),
        reason: 'the old failure said exactly this',
      );
      // The build is NOT offered for a plan the validator holds back, and the
      // reply says which finding is in the way. Offering "Build the .pkt"
      // here led straight back to "I did not build: N findings", which is the
      // dead end that was reported.
      expect(
        reply.quickReplies,
        isNot(contains('Build the .pkt')),
        reason: 'a 50-PC plan is refused by the validator, so its build must '
            'not be advertised as ready',
      );
      expect(reply.text, contains('cannot build this one yet'));
      expect(
        reply.text,
        contains('more than 50 devices'),
        reason: 'the blocker is named, not just counted',
      );
    });
  });

  group('the smaller twin is buildable end to end', () {
    test('two sites and 20 PCs cable every device and pass the validator',
        () {
      final p = NetworkIntent.parseSimple('chat', 'two physical sites and 20 PCs');
      expect(count(p, 'pc'), 20);
      expect(count(p, 'router'), 2);
      expect(count(p, 'switch'), 2);
      for (final node in p.nodes.where((n) => n.type == 'pc')) {
        expect(
          p.links.any((l) => l.a == node.name || l.b == node.name),
          isTrue,
          reason: '${node.name} must be cabled',
        );
      }
      final issues = ValidatorService.validate(p, target: 'packet-tracer');
      expect(
        ValidatorService.hasErrors(issues),
        isFalse,
        reason: issues.map((i) => '${i.severity}: ${i.message}').join('\n'),
      );
    });

    test('the full 50-PC version is flagged, not silently built', () {
      final p = NetworkIntent.parseSimple(
        'chat',
        "two physical sites and like 50 PCs and i don't know how many phones",
      );
      final issues = ValidatorService.validate(p, target: 'packet-tracer');
      expect(
        issues.any((i) => i.message.contains('more than 50 devices')),
        isTrue,
        reason: 'a 50-PC lab exceeds the autopilot device limit; the app '
            'must say so rather than stay silent',
      );
    });
  });

  group('the new reading rules, in isolation', () {
    test('"more than 1 router and 1 switch and 1 server" plans the minimums',
        () {
      final p = NetworkIntent.parseSimple(
        'p',
        'we will need more than 1 router and 1 switch and 1 server',
      );
      expect(count(p, 'router'), 2);
      expect(count(p, 'switch'), 1);
      expect(count(p, 'server'), 1);
      expect(
        p.assumptions
            .any((a) => a.contains('more than 1 router') && a.contains('2')),
        isTrue,
      );
    });

    test('"at least 2 switches" keeps reading as written', () {
      final p = NetworkIntent.parseSimple('p', 'at least 2 switches');
      expect(count(p, 'switch'), 2);
    });

    test('an unknown phone count is a question, never a device', () {
      final p = NetworkIntent.parseSimple(
        'p',
        "i don't know how many phones, maybe a few",
      );
      expect(count(p, 'phone'), 0);
      expect(
        p.questions.where((q) => q.toLowerCase().contains('how many phones')),
        isNotEmpty,
      );
    });

    test('a stated phone count still plans', () {
      final p = NetworkIntent.parseSimple('p', '2 routers and 10 phones');
      expect(count(p, 'phone'), 10);
    });
  });
}
