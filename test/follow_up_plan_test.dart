import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';

/// What the standing plan becomes after one more turn. This is the difference
/// between a conversation and a series of unrelated labs, and getting it wrong
/// is how "can we add AAA server to it as well?" replaced a 13-device lab with
/// a single server.
void main() {
  ({NetworkIntent plan, String brief}) start(String brief) =>
      NetworkIntent.followUp(
        previous: null,
        previousBrief: '',
        brief: brief,
        parsed: NetworkIntent.parseSimple('chat', brief),
        project: 'chat',
      );

  ({NetworkIntent plan, String brief}) next(
    ({NetworkIntent plan, String brief}) previous,
    String brief,
  ) => NetworkIntent.followUp(
    previous: previous.plan,
    previousBrief: previous.brief,
    brief: brief,
    parsed: NetworkIntent.parseSimple('offline-chat', brief),
    project: 'offline-chat',
  );

  final firstBrief =
      'I have 10 Pcs and want to build a network for them add switches and '
      'routers and servers and make security maximum';

  group('a follow-up that adds to the lab', () {
    test('keeps the lab it was said about, and adds what was asked', () {
      final lab = start(firstBrief);
      expect(lab.plan.nodes.length, 13);
      expect(lab.plan.security.aaa, isFalse);

      final after = next(lab, 'can we add AAA server to it as well ?');

      expect(after.plan.nodes.length, lab.plan.nodes.length + 1,
          reason: 'the 13 devices survive, and the AAA server is added');
      expect(after.plan.security.aaa, isTrue, reason: 'AAA is the addition');
      expect(
        after.plan.nodes.map((n) => n.name),
        containsAll(<String>['R1', 'SW1', 'PC10', 'SRV1']),
        reason: 'every device of the original lab is still there',
      );
      expect(after.plan.links.length, greaterThanOrEqualTo(12));
    });

    test('says what changed, so the user can tell it landed', () {
      final lab = start(firstBrief);
      final after = next(lab, 'can we add AAA server to it as well ?');
      final delta = NetworkIntent.planChangeSummary(lab.plan, after.plan);
      expect(delta, contains('AAA'));
      expect(delta, isNot(contains('Telnet')),
          reason: 'AAA is one decision, not two');
    });

    test('"add" means plus, for counted and uncounted kinds alike', () {
      final lab = start('1 router 2 switches 4 pcs');
      final after = next(lab, 'add 6 pcs and a server too');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 10,
          reason: 'four PCs plus the six the user asked for');
      expect(after.plan.nodes.where((n) => n.type == 'server').length, 1);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 1);
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2);
    });

    test('the addition stays part of the brief for the turn after it', () {
      final lab = start('2 routers 4 pcs');
      final withDns = next(lab, 'add a DNS server too');
      final withHttp = next(withDns, 'and an HTTP server as well');
      expect(withHttp.plan.nodes.where((n) => n.type == 'server').length, 2);
      expect(withHttp.plan.nodes.where((n) => n.type == 'router').length, 2);
    });
  });

  group('a follow-up that is not an addition', () {
    test('a nudge keeps the standing plan', () {
      final lab = start(firstBrief);
      final after = next(lab, 'ok build the .pkt');
      expect(identical(after.plan, lab.plan), isTrue);
      expect(after.brief, lab.brief);
    });

    test('a rebuild that names devices re-plans on purpose', () {
      final lab = start(firstBrief);
      final after = next(lab, 'make it 2 routers and 4 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 4);
      expect(after.plan.nodes.length, lessThan(lab.plan.nodes.length));
    });

    test('a protocol change is applied and the devices stay', () {
      final lab = start('2 routers 4 pcs');
      final after = next(lab, 'use ospf for routing');
      expect(after.plan.routing, 'ospf');
      expect(after.plan.nodes.length, lab.plan.nodes.length);
      // ...and it is remembered for a later addition.
      final withServer = next(after, 'add a web server too');
      expect(withServer.plan.routing, 'ospf');
      expect(withServer.plan.nodes.length, greaterThan(after.plan.nodes.length));
    });
  });

  group('"want" is not a WAN', () {
    test('a brief that asks for AAA is not read as a two-site security lab', () {
      final plan = NetworkIntent.parseSimple(
        'x',
        'I want 1 router 2 switches 10 pcs and a server with AAA',
      );
      expect(plan.security.aaa, isTrue);
      expect(plan.nodes.length, 14);
      expect(
        plan.nodes.any((n) => n.name.startsWith('HQ_') || n.name.startsWith('BR_')),
        isFalse,
        reason: 'the branch-profile devices are a different lab',
      );
    });

    test('the site wording itself still selects that profile', () {
      final plan = NetworkIntent.parseSimple(
        'x',
        'two branch offices connected over a WAN with AAA and a time-based ACL',
      );
      expect(plan.nodes.any((n) => n.name.startsWith('HQ_')), isTrue);
      expect(plan.security.aaa, isTrue);
    });

    test('a WAN without a security word is an ordinary lab', () {
      final plan = NetworkIntent.parseSimple(
        'x',
        '2 routers over a serial WAN, 4 pcs each side',
      );
      expect(plan.nodes.any((n) => n.name.startsWith('HQ_')), isFalse);
    });
  });
}
