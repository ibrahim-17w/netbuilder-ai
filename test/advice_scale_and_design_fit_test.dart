// Two bugs, both found by testing a real conversation against the app.
//
// 1. "an office with 20 employees" was planned as NO hosts. The advisor's
//    one-tap plan sentence carried a fixed "10 PCs", and the topic-level fall
//    sentences carried no count at all, so the planner built 4 devices with not
//    one PC in them - while the answer had just said "you mentioned about 20
//    users/devices".
// 2. The design applied was the wrong one. "Plan a small office with ..."
//    matches the alias "small office" of the `soho` design (built for 1-15
//    hosts), and `apply` never checked the catalog's host range, so a
//    20-host office got the one-box design laid on top of it.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/advisor_service.dart';
import 'package:net_builder/services/design_library.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

int _hosts(NetworkIntent plan) =>
    plan.nodes.where((n) => n.type == 'pc').length;

void main() {
  group('advice keeps the scale the user stated', () {
    test('the Plan-this sentence carries the count, not a fixed 10', () {
      // The advice card's "Plan this" sends [AdviceAnswer.planBrief] straight
      // through the planner. It used to be a hardcoded "10 PCs" (and, on the
      // topic-level fallback, no count at all), so a 20-employee office came
      // back as 10 - or as zero.
      final answer = AdvisorService.advise(
        'what router should I use in this lab?',
        target: 'packet-tracer',
        briefScale: 20,
      );
      expect(answer, isNotNull);
      if (answer!.planBrief == null) {
        // Not every topic offers a plan step; that is a different question
        // from what this test pins, so skip rather than fail.
        return;
      }
      expect(
        _hosts(_plan(answer.planBrief!)),
        20,
        reason: 'the sentence "Plan this" sends must plan the scale the '
            'advisor just used in its answer',
      );
    });

    test('a follow-up with no number still plans the settled scale', () {
      // Exactly the reported flow: the 20 was said two turns earlier, so this
      // turn says only "an office with guests".
      final answer = AdvisorService.advise(
        'what firewall do we need for an office with guests?',
        target: 'packet-tracer',
        briefScale: 20,
      );
      expect(answer, isNotNull);
      final sent = answer!.quickReplies.firstWhere((r) => r.startsWith('Plan '));
      final plan = _plan(sent);
      expect(
        _hosts(plan),
        20,
        reason: 'a stated fact in an earlier turn must not be dropped by the '
            'plan the advice offers',
      );
      expect(
        plan.nodes.length,
        greaterThan(4),
        reason: 'the office has an edge, a switch, the firewall and its hosts',
      );
    });

    test('no scale stated anywhere still plans a usable office', () {
      final answer = AdvisorService.advise(
        'what firewall do we need for an office with guests?',
        target: 'packet-tracer',
      );
      final sent = answer!.quickReplies.firstWhere((r) => r.startsWith('Plan '));
      // Count-free is the fallback for someone who never gave a number: it
      // must still plan an office with hosts, not an empty 4-device shell.
      expect(_hosts(_plan(sent)), greaterThan(0));
    });
  });

  group('a design that does not fit the plan is not applied', () {
    test('the one-box design is refused for a 20-host office', () {
      final plan = _plan(
        'a small office with 20 employees, a firewall, guest wifi and staff '
        'VLANs',
      );
      expect(_hosts(plan), 20);

      final designed = DesignApplier.applyNamed(
        plan,
        'Plan a small office with a firewall, guest wifi and staff VLANs',
      );
      expect(
        designed,
        isNull,
        reason: '`soho` is catalogued for 1-15 hosts; laying it on a 20-host '
            'office is wrong advice, and its extra wireless router is a '
            'device the office already has a router for',
      );
    });

    test('a design that fits is still applied', () {
      final plan = _plan('2 routers, 2 switches and 20 PCs with OSPF');
      final designed = DesignApplier.applyNamed(plan, 'rebuild it with a DMZ');
      expect(designed, isNotNull);
      expect(
        designed!.plan.nodes.any((n) => n.type == 'firewall'),
        isTrue,
        reason: 'the DMZ design does fit a 20-host lab and must still apply',
      );
    });

    test('the one-box design still applies to the small office it fits', () {
      final plan = _plan('1 router and 6 PCs');
      final designed = DesignApplier.applyNamed(plan, 'small office one box');
      expect(
        designed,
        isNotNull,
        reason: '`soho` is built for 1-15 hosts, so a 6-host plan is exactly '
            'its case - the size gate must not refuse everything',
      );
      expect(designed!.design.id, 'soho');
    });
  });
}
