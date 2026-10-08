import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/validator_service.dart';

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

  group('a count correction of the standing lab', () {
    // The confirmed failure this group pins: "actually 8 pcs" re-planned
    // from the fragment alone and replaced the lab with eight orphan PCs,
    // while a bare "actually 8" did nothing at all - both while the
    // understood card reported the correction.
    final base = start('2 routers, 2 switches and 50 PCs with OSPF');

    test('"actually 8 pcs" corrects the PC count and keeps the rest', () {
      final after = next(base, 'actually 8 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8,
          reason: 'the correction replaces the 50');
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2,
          reason: 'the routers were not part of the correction');
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2);
      expect(after.plan.routing, 'ospf',
          reason: 'the routing the original brief asked for stays');
      expect(after.plan.nodes.length, 12);
    });

    test('a bare "actually 8" corrects the kind the lab was last about', () {
      final after = next(base, 'actually 8');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2);
    });

    test('"no wait, 8 pcs" reads as the same correction', () {
      final after = next(base, 'no wait, 8 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
    });

    test('corrections chain: the newest number wins', () {
      final first = next(base, 'actually 8 pcs');
      expect(first.plan.nodes.where((n) => n.type == 'pc').length, 8);
      final second = next(first, 'actually 60 pcs');
      expect(second.plan.nodes.where((n) => n.type == 'pc').length, 60);
      expect(second.plan.nodes.where((n) => n.type == 'router').length, 2,
          reason: 'the earlier correction did not loosen the lab');
    });

    test('several kinds can be corrected in one breath', () {
      final after = next(base, 'actually 2 routers and 4 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 4);
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2,
          reason: 'the switches were not part of the correction');
    });

    test('correcting a kind the lab does not have yet adds it', () {
      final infra = start('2 routers and 2 switches');
      final after = next(infra, 'actually 8 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2);
    });

    test('a correction may carry a service of its own', () {
      final after = next(base, 'actually 8 pcs with a web server');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8);
      expect(after.plan.nodes.where((n) => n.type == 'server').length, 1,
          reason: 'the server the correction names is part of the lab');
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 2);
    });

    test('the corrected plan is still buildable', () {
      final after = next(base, 'actually 8 pcs');
      final blocking = ValidatorService.validate(
        after.plan,
        target: 'packet-tracer',
      ).where((issue) => issue.blocks);
      expect(blocking, isEmpty,
          reason: 'a correction must never leave the plan unbuildable');
    });

    test('the corrected count survives the normalize step the chat runs',
        () {
      final normalized = CasualEnglish.normalize('Actually, 8 pcs');
      final after = NetworkIntent.followUp(
        previous: base.plan,
        previousBrief: base.brief,
        brief: normalized,
        parsed: NetworkIntent.parseSimple('chat', normalized),
        project: 'chat',
      );
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 8);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
    });

    test('an addition is still an addition, not a correction', () {
      final after = next(base, 'add 2 more pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 52,
          reason: '"add" means plus on the standing lab');
    });

    test('a rebuild that names devices still re-plans on purpose', () {
      final after = next(base, 'make it 2 routers and 4 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 4);
      expect(after.plan.nodes.where((n) => n.type == 'router').length, 2);
      expect(after.plan.nodes.where((n) => n.type == 'switch').length, 0,
          reason: 'the documented re-plan reading is unchanged');
    });

    test('a corrected floor restates the bound instead of growing to it', () {
      final floored = start('more than 100 pcs');
      final after = next(floored, 'no wait, actually more than 8 pcs');
      expect(after.plan.nodes.where((n) => n.type == 'pc').length, 9,
          reason: 'the new bound replaces the old one');
    });
  });
}
