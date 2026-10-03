import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';

/// The reported brief: it asks for a network for 40 users and then lists 15 PCs
/// at the HQ and 10 at the branch - 25 PCs. The app built the 25, said nothing
/// about the other 15, and its own audit reported "nothing to fix".
const brief =
    'Build a corporate network for 40 users across 2 physical sites. '
    'Site A is the headquarters with 2 routers, 2 switches, 3 Server-PT '
    'devices (1 DHCP server, 1 AAA/TACACS+ server, 1 DNS+HTTP server) and '
    '15 PCs. Site B is a branch with 1 router, 1 switch, 1 Server-PT device '
    '(the DHCP server) and 10 PCs. Use 192.168.10.0/24 at HQ and '
    '192.168.20.0/24 at the branch, OSPF area 0, and set up AAA with the '
    'client name admin and password 123.';

void main() {
  group('a stated headcount that disagrees with the device list', () {
    test('the plan itself follows the PCs it was given', () {
      final plan = NetworkIntent.parseSimple('t', brief);
      expect(plan.nodes.where((n) => n.type == 'pc'), hasLength(25));
      expect(plan.nodes.where((n) => n.type == 'server'), hasLength(4));
      expect(plan.nodes.where((n) => n.type == 'switch'), hasLength(3));
    });

    test('the headcount is read from the brief, and only from a real one', () {
      expect(NetworkIntent.statedUserCount(brief), 40);
      expect(NetworkIntent.statedUserCount('a branch office for 12 staff'), 12);
      // A subnet question, a credential and a server role are not headcounts.
      expect(
        NetworkIntent.statedUserCount('how many hosts does a /28 hold'),
        isNull,
      );
      expect(
        NetworkIntent.statedUserCount(
          'set up AAA with the client name admin and password 123',
        ),
        isNull,
      );
      expect(
        NetworkIntent.statedUserCount('2 routers, 2 switches and 15 PCs'),
        isNull,
      );
    });

    test('the popup names both numbers and offers a way to fix it', () {
      final plan = NetworkIntent.parseSimple('t', brief);
      expect(plan.prompts, hasLength(1));
      final prompt = plan.prompts.single;
      expect(prompt.title, contains('40'));
      expect(prompt.title, contains('25'));
      expect(prompt.message, contains('40 users'));
      expect(prompt.message, contains('25'));
      final grow = prompt.options.first;
      expect(grow.recommended, isTrue);
      expect(grow.reply, 'add 15 more PCs');
      expect(
        prompt.options.last.reply,
        isEmpty,
        reason: '"keep what I listed" must not change the plan',
      );
      // The plan says the same thing in its own words, so the answer the user
      // reads and the popup cannot disagree.
      expect(
        plan.assumptions.any((a) => a.contains('40 users')),
        isTrue,
      );
    });

    test('the popup button really produces 40 PCs', () {
      final plan = NetworkIntent.parseSimple('t', brief);
      final reply = plan.prompts.single.options.first.reply;
      final outcome = NetworkIntent.followUp(
        previous: plan,
        previousBrief: brief,
        brief: reply,
        parsed: NetworkIntent.parseSimple('t', reply),
        project: 't',
      );
      expect(outcome.plan.nodes.where((n) => n.type == 'pc'), hasLength(40));
      // Nothing else was lost or doubled on the way.
      expect(outcome.plan.nodes.where((n) => n.type == 'router'), hasLength(3));
      expect(outcome.plan.nodes.where((n) => n.type == 'switch'), hasLength(3));
    });

    test('a plan that agrees with its brief raises nothing', () {
      final plan = NetworkIntent.parseSimple(
        't',
        'an office for 10 users with 1 router, 1 switch and 10 PCs',
      );
      expect(plan.nodes.where((n) => n.type == 'pc'), hasLength(10));
      expect(plan.prompts, isEmpty);
    });

    test('a brief with no headcount at all raises nothing', () {
      final plan = NetworkIntent.parseSimple(
        't',
        'a lab with 2 routers, 2 switches and 10 PCs',
      );
      expect(plan.prompts, isEmpty);
    });

    test('a plan survives a round trip through JSON with its prompts', () {
      final plan = NetworkIntent.parseSimple('t', brief);
      final restored = NetworkIntent.fromJson(plan.toJson());
      expect(restored.prompts.single.id, plan.prompts.single.id);
      expect(restored.prompts.single.options.first.reply, 'add 15 more PCs');
      // Prompts are not part of the plan's identity: asking a question does not
      // make every build card in the conversation look stale.
      expect(restored.revision, plan.revision);
    });
  });
}
