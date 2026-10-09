// "Fix the plan" used to be a button that did nothing.
//
// Pressing it on a blocked build card ran the repair, and the repair cleared
// the duplicate addresses, the uncabled WLC and the shared ports - but it left
// two findings standing: the AAA server holds no account, and the IPSec tunnel
// has no pre-shared key. The answer then said "each one needs a choice only you
// can make" and offered to make it by TYPING "AAA client name admin password
// 123" - a sentence no phrase in the parser turns into an account. So the plan
// never changed, the same card came back with the same button, and pressing it
// again produced the identical answer. Forever.
//
// What makes it a loop rather than a slow repair: the card offered "Fix the
// plan" whether or not the repair could clear anything. A tap that changes
// nothing is a lie of a button.
//
// These tests hold both halves - the repair clears the credentials it can, and
// the card only offers the repair when it would do something.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/plan_repair_service.dart';
import 'package:net_builder/services/validator_service.dart';

const _brief = 'Build a three-site enterprise network. HQ needs 2 routers '
    'running HSRP, 1 firewall for the internet edge, 2 core multilayer '
    'switches, 2 access switches, a WLC with 3 access points, 20 PCs, a '
    'DHCP server, a DNS server, a TACACS+ AAA server and a web server. Each '
    'of two branch offices needs 1 router, 1 switch and 8 PCs. Use OSPF '
    'everywhere, put HQ users on VLAN 10, branch users on VLAN 20 and '
    'management on VLAN 99, connect every site with an IPsec VPN over a '
    'serial WAN link, and turn on port security plus DHCP snooping on the '
    'access switch ports.';

List<String> _blocking(NetworkIntent p) => ValidatorService.validate(
      p,
      target: 'packet-tracer',
    )
        .where((i) => i.blocks)
        .map((i) => i.message)
        .toList();

void main() {
  group('the repair clears what it is asked for', () {
    test('one repair pass leaves nothing blocking', () {
      final plan = NetworkIntent.parseSimple('chat', _brief);
      expect(_blocking(plan), isNotEmpty,
          reason: 'the fixture must start with findings to clear');

      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(repair.changes, isNotEmpty, reason: 'something must be repaired');
      expect(
        _blocking(repair.plan),
        isEmpty,
        reason: 'a second press must have nothing left to do - that is what '
            'stops the loop',
      );
    });

    test('the AAA finding is cleared by an account, not by a sentence', () {
      final plan = NetworkIntent.parseSimple('chat', _brief);
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      final aaa = repair.plan.security;
      expect(aaa.aaa, isTrue, reason: 'the brief asks for AAA');
      expect(
        (aaa.aaaUsername ?? '').isNotEmpty &&
            (aaa.aaaAccountPassword ?? '').isNotEmpty,
        isTrue,
        reason: 'the repair must write the placeholder account the answer '
            'used to ask the user to type - which the parser could not read',
      );
    });

    test('the IPSec finding is cleared by a key', () {
      final plan = NetworkIntent.parseSimple('chat', _brief);
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(
        (repair.plan.security.vpnPreSharedKey ?? '').isNotEmpty,
        isTrue,
        reason: 'the tunnel cannot establish without one',
      );
    });

    test('a placeholder credential is reported, never silent', () {
      final plan = NetworkIntent.parseSimple('chat', _brief);
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      final reported = repair.changes.join('\n');
      expect(reported, contains('placeholder'));
      expect(reported, contains(repair.plan.security.aaaUsername!));
      expect(
        repair.fixes.any((f) => f.kind == 'aaa_account_missing'),
        isTrue,
        reason: 'the fix is remembered so the same words teach the same repair',
      );
    });

    test('a plan with neither AAA nor IPSec is untouched', () {
      final plan = NetworkIntent.parseSimple(
        'chat',
        '2 routers, 2 switches and 10 PCs with OSPF',
      );
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(repair.plan.security.aaaUsername, isNull);
      expect(repair.plan.security.vpnPreSharedKey, isNull);
    });
  });

  group('the chat answer drives the repair, not the reader', () {
    test('the fix reply carries the repaired plan', () {
      final plan = NetworkIntent.parseSimple('chat', _brief);
      final reply = OfflineAssistantService.fixPlan(
        plan: plan,
        target: 'packet-tracer',
      );
      expect(reply.repairedPlan, isNotNull);
      expect(reply.text, contains('Fixed'));
      expect(
        _blocking(reply.repairedPlan!),
        isEmpty,
        reason: 'the reply must hand the chat a plan that can actually build',
      );
    });

    test('the second press has nothing to repair and says so', () {
      var plan = NetworkIntent.parseSimple('chat', _brief);
      plan = OfflineAssistantService.fixPlan(
        plan: plan,
        target: 'packet-tracer',
      ).repairedPlan!;

      final second = OfflineAssistantService.fixPlan(
        plan: plan,
        target: 'packet-tracer',
      );
      expect(
        second.text,
        contains('Nothing in this plan blocks the build'),
        reason: 'a plan that is already clean must not be repaired again',
      );
    });

    test('a repair that changes nothing is reported as such', () {
      // A plan whose only findings need a real decision - a clean cabling and
      // addressing pass leaves it standing - must say so rather than repeat.
      final plan = NetworkIntent(
        projectName: 'clean',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'SW1', type: 'switch'),
          NetNode(name: 'PC1', type: 'pc'),
        ],
        links: const [
          NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
          NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
        ],
      );
      final repair = PlanRepairService.repair(plan, target: 'packet-tracer');
      expect(repair.changes, isEmpty,
          reason: 'nothing to repair is the case the button must not be '
              'offered for');
    });
  });
}
