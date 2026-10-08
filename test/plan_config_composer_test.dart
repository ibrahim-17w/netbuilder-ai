import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/plan_config_composer.dart';

/// Direct unit tests for the plan-aware config composer: a section composed
/// from an open plan must carry the plan's REAL device names, interfaces and
/// subnets (never generic placeholders), the wildcard/mask arithmetic must
/// agree with the plan's CIDRs, and a plan that lacks the facts a topic needs
/// must return either null or the pinned explicit-gap line - never an
/// invented address.
///
/// Plans are built the way the rest of the corpus builds them:
/// [NetworkIntent.parseSimple] for brief-driven labs (the same phrasings
/// `test/offline_planner_test.dart` pins) and direct construction for the
/// hand-shaped plans (the pattern `test/asa_policy_test.dart` uses).
void main() {
  /// The reference two-site lab: transit 10.0.0.0/30, R1's LAN
  /// 192.168.1.0/24 (gateway .1), R2's LAN 192.168.2.0/24 (gateway .1).
  NetworkIntent twoRouterLab() => NetworkIntent.parseSimple(
    'offline-chat',
    '2 routers, 2 switches and 4 PCs with OSPF',
  );

  group('topics set', () {
    test('declares the concept-key strings it can ground', () {
      expect(
        PlanConfigComposer.topics,
        containsAll(<String>[
          'ospf',
          'eigrp',
          'static',
          'default_route',
          'ssh',
          'dhcp',
          'vlan',
          'acl',
          'internet',
        ]),
      );
    });

    test('an unknown topic composes nothing', () {
      final plan = twoRouterLab();
      expect(
        PlanConfigComposer.compose(
          plan: plan,
          topic: 'two_routers',
          target: 'pt',
        ),
        isNull,
      );
    });

    test('an empty plan composes nothing for any topic', () {
      const plan = NetworkIntent(projectName: 'empty');
      expect(
        PlanConfigComposer.compose(plan: plan, topic: 'ospf', target: 'pt'),
        isNull,
      );
    });

    test('composition is deterministic', () {
      final plan = twoRouterLab();
      final a = PlanConfigComposer.compose(
        plan: plan,
        topic: 'ospf',
        target: 'pt',
      );
      final b = PlanConfigComposer.compose(
        plan: plan,
        topic: 'ospf',
        target: 'pt',
      );
      // Two separately built strings: equal by value, not by identity.
      expect(a, equals(b));
    });
  });

  group('ospf', () {
    late NetworkIntent plan;
    late String? section;
    setUpAll(() {
      plan = twoRouterLab();
      section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'ospf',
        target: 'pt',
      );
    });

    test('composes a grounded section for the addressed plan', () {
      expect(section, isNotNull);
      expect(plan.routing, 'ospf');
      // Every section opens on the lab, never with a greeting.
      expect(section!.startsWith('Your lab:'), isTrue);
    });

    test('names the plan routers and their real subnets', () {
      expect(section, contains('R1'));
      expect(section, contains('R2'));
      expect(section, contains('10.0.0.0/30'));
      expect(section, contains('192.168.1.0/24'));
      expect(section, contains('192.168.2.0/24'));
    });

    test('wildcard masks are correct for the plan subnets', () {
      // /30 transit -> 0.0.0.3, /24 LANs -> 0.0.0.255, and the network
      // address is the SUBNET base, not the router's host address.
      expect(section, contains('router ospf 1'));
      expect(section, contains('network 10.0.0.0 0.0.0.3 area 0'));
      expect(section, contains('network 192.168.1.0 0.0.0.255 area 0'));
      expect(section, contains('network 192.168.2.0 0.0.0.255 area 0'));
      expect(section, isNot(contains('192.168.1.1 0.0.0.255')));
    });

    test('no generic placeholders survive', () {
      expect(section, isNot(contains('<subnet>')));
      expect(section, isNot(contains('<network>')));
      expect(section, isNot(contains('<interface>')));
      expect(section, isNot(contains('<ip>')));
    });

    test('verification command comes last and the section stays compact', () {
      expect(section, contains('show ip ospf neighbor'));
      expect(
        section!.trimRight().split('\n').last,
        contains('show ip ospf neighbor'),
      );
      expect(section!.split('\n').length, lessThan(31));
    });

    test('a plan without any addresses gets the explicit-gap section', () {
      // Pinned: an explicit gap that names the fix phrasing, not null and
      // not an invented network statement.
      const bare = NetworkIntent(
        projectName: 'bare',
        nodes: [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'R2', type: 'router'),
        ],
        links: [NetLink(a: 'R1', aIf: 'g0/0', b: 'R2', bIf: 'g0/0')],
        routing: 'ospf',
      );
      final gap = PlanConfigComposer.compose(
        plan: bare,
        topic: 'ospf',
        target: 'pt',
      );
      expect(gap, isNotNull);
      expect(gap!.startsWith('Your lab:'), isTrue);
      expect(gap, contains('no addresses yet'));
      expect(gap, contains("use 10.0.0.0/24"));
      expect(gap, contains('R1'));
      expect(gap, isNot(contains('network ')));
    });
  });

  group('eigrp', () {
    test('one AS, wildcard network statements, EIGRP verification', () {
      final section = PlanConfigComposer.compose(
        plan: twoRouterLab(),
        topic: 'eigrp',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('router eigrp 10'));
      expect(section, contains('no auto-summary'));
      expect(section, contains('network 10.0.0.0 0.0.0.3'));
      expect(section, contains('network 192.168.1.0 0.0.0.255'));
      expect(section, contains('network 192.168.2.0 0.0.0.255'));
      expect(section, contains('show ip eigrp neighbors'));
      expect(
        section.trimRight().split('\n').last,
        contains('show ip eigrp neighbors'),
      );
      expect(section.split('\n').length, lessThan(31));
    });
  });

  group('static routes', () {
    test('one route per remote LAN via the far end real address', () {
      final section = PlanConfigComposer.compose(
        plan: twoRouterLab(),
        topic: 'static',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      // R1 routes to R2's LAN via R2's transit address 10.0.0.2, and the
      // mirror route on R2 via 10.0.0.1.
      expect(section, contains('ip route 192.168.2.0 255.255.255.0 10.0.0.2'));
      expect(section, contains('ip route 192.168.1.0 255.255.255.0 10.0.0.1'));
      // The transit subnet itself is a next hop, never a destination.
      expect(section, isNot(contains('ip route 10.0.0.0 ')));
      expect(
        section.trimRight().split('\n').last,
        contains('show ip route'),
      );
      expect(section.split('\n').length, lessThan(31));
    });

    test('a plan with only unaddressed routers gets the gap line', () {
      const bare = NetworkIntent(
        projectName: 'bare',
        nodes: [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'R2', type: 'router'),
        ],
        links: [NetLink(a: 'R1', aIf: 'g0/0', b: 'R2', bIf: 'g0/0')],
      );
      final gap = PlanConfigComposer.compose(
        plan: bare,
        topic: 'static',
        target: 'pt',
      );
      expect(gap, isNotNull);
      expect(gap, contains('has no addresses yet'));
      expect(gap, contains('10.0.0.0/30'));
      expect(gap, isNot(contains('ip route ')));
    });
  });

  group('ssh', () {
    test('per-router block on the plan hostnames, placeholders for secrets',
        () {
      final section = PlanConfigComposer.compose(
        plan: twoRouterLab(),
        topic: 'ssh',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('hostname R1'));
      expect(section, contains('hostname R2'));
      // The hostname-derived domain the adapters write.
      expect(section, contains('ip domain-name r1.lab.local'));
      expect(section, contains('crypto key generate rsa'));
      expect(section, contains('1024'));
      // A secret the plan does not carry stays a placeholder.
      expect(section, contains('username admin secret 0 <password>'));
      expect(section, contains('transport input ssh'));
      expect(section, contains('login local'));
      expect(
        section.trimRight().split('\n').last,
        contains('show ip ssh'),
      );
      // The login target is the router's real LAN address.
      expect(section, contains('ssh -l admin 192.168.1.1'));
    });

    test('the plan AAA account is used when the brief stated one', () {
      final plan = twoRouterLab().copyWith(
        security: const SecurityIntent(
          aaaUsername: 'netadmin',
          aaaAccountPassword: 'Lab2026',
        ),
      );
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'ssh',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section, contains('username netadmin secret 0 Lab2026'));
      expect(section, isNot(contains('<password>')));
    });
  });

  group('dhcp', () {
    test('one pool per LAN subnet with the plan gateway and exclusions', () {
      final section = PlanConfigComposer.compose(
        plan: twoRouterLab(),
        topic: 'dhcp',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('ip dhcp pool LAN_192_168_1_0'));
      expect(section, contains('ip dhcp pool LAN_192_168_2_0'));
      expect(section, contains('network 192.168.1.0 255.255.255.0'));
      expect(section, contains('network 192.168.2.0 255.255.255.0'));
      // default-router is the router's REAL interface address per LAN.
      expect(section, contains('default-router 192.168.1.1'));
      expect(section, contains('default-router 192.168.2.1'));
      // The statically assigned plan addresses stay out of the pool.
      expect(section, contains('ip dhcp excluded-address 192.168.1.1'));
      // No DNS server exists in this plan, so no invented dns-server line.
      expect(section, isNot(contains('dns-server')));
      expect(
        section.trimRight().split('\n').last,
        contains('show ip dhcp binding'),
      );
    });

    test('a plan DNS server is named in the pool', () {
      final plan = NetworkIntent.parseSimple(
        'dhcp-dns',
        '2 routers, 2 switches, 1 DNS server and 4 PCs',
      );
      final dnsServer = plan.nodes.firstWhere(
        (n) => n.type == 'server' &&
            n.services.any((s) => s.toLowerCase() == 'dns'),
      );
      final dnsIp = plan.addressing
          .firstWhere((a) => a.node == dnsServer.name)
          .ipCidr
          .split('/')
          .first;
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'dhcp',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section, contains('dns-server $dnsIp'));
    });

    test('routers without LAN addresses get the gap line', () {
      const bare = NetworkIntent(
        projectName: 'bare',
        nodes: [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'R2', type: 'router'),
        ],
        links: [NetLink(a: 'R1', aIf: 'g0/0', b: 'R2', bIf: 'g0/0')],
      );
      final gap = PlanConfigComposer.compose(
        plan: bare,
        topic: 'dhcp',
        target: 'pt',
      );
      expect(gap, isNotNull);
      expect(gap, contains('no LAN address yet'));
      expect(gap, contains('use 192.168.1.0/24'));
      expect(gap, isNot(contains('ip dhcp pool')));
    });
  });

  group('vlan', () {
    late NetworkIntent plan;
    late String? section;
    setUpAll(() {
      plan = NetworkIntent.parseSimple(
        'vlans-chat',
        '1 router 1 switch 4 pcs with vlan 10 and vlan 20, inter-vlan routing',
      );
      section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'vlan',
        target: 'pt',
      );
    });

    test('composes the plan VLANs on the plan switch', () {
      expect(section, isNotNull);
      expect(plan.vlans, containsAll(<int>[10, 20]));
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('SW1'));
      expect(section, contains('vlan 10'));
      expect(section, contains('vlan 20'));
    });

    test('the real uplink is the trunk and device ports are access', () {
      expect(section, contains('interface f0/1'));
      expect(section, contains(' switchport mode trunk'));
      expect(section, contains(' switchport trunk allowed vlan 10,20'));
      expect(section, contains(' switchport mode access'));
      expect(section, contains(' switchport access vlan 10'));
      expect(section, contains(' switchport access vlan 20'));
    });

    test('per-port VLANs and gateways come from the plan addressing', () {
      // The parser spread the PCs round-robin and addressed VLAN N in its
      // own subnet - the section must repeat the plan, not re-decide it.
      final pc10 = plan.addressing.any(
        (a) =>
            a.node.startsWith('PC') && a.ipCidr.startsWith('192.168.10.10'),
      );
      final pc20 = plan.addressing.any(
        (a) =>
            a.node.startsWith('PC') && a.ipCidr.startsWith('192.168.20.10'),
      );
      expect(pc10, isTrue, reason: 'a PC sits in VLAN 10');
      expect(pc20, isTrue, reason: 'a PC sits in VLAN 20');
      expect(section, contains('VLAN 10 - 192.168.10.1'));
      expect(section, contains('VLAN 20 - 192.168.20.1'));
      expect(
        section!.trimRight().split('\n').last,
        contains('show vlan brief'),
      );
    });

    test('the trunk key grounds the same section', () {
      final viaTrunk = PlanConfigComposer.compose(
        plan: plan,
        topic: 'trunk',
        target: 'pt',
      );
      // Equal by value: the same composer path built each string.
      expect(viaTrunk, equals(section));
    });

    test('a plan with switches but no VLAN numbers gets the gap line', () {
      final flat = NetworkIntent.parseSimple(
        'vlans-gap',
        '1 router 1 switch and 4 PCs',
      );
      final gap = PlanConfigComposer.compose(
        plan: flat,
        topic: 'vlan',
        target: 'pt',
      );
      expect(gap, isNotNull);
      expect(gap!.startsWith('Your lab:'), isTrue);
      expect(gap, contains('no VLAN numbers yet'));
      expect(gap, contains('add vlan 10 and vlan 20'));
      expect(gap, isNot(contains('switchport')));
    });

    test('a plan with no switch at all composes nothing', () {
      const plan = NetworkIntent(
        projectName: 'norouter',
        nodes: [NetNode(name: 'PC1', type: 'pc')],
      );
      expect(
        PlanConfigComposer.compose(plan: plan, topic: 'vlan', target: 'pt'),
        isNull,
      );
    });
  });

  group('acl', () {
    test('the protected-server policy uses the plan names and subnets', () {
      // The deterministic security profile: HQ_Router + BR_Router over
      // 10.1.1.0/30, AAA1 at 192.168.1.100 protected, WEB1 at .102 allowed,
      // branch LAN 192.168.2.0/24.
      final plan = NetworkIntent.parseSimple(
        'sec-chat',
        'Harden the user ports on the HQ switch and stop rogue DHCP servers '
        'from the branch site. Centralized authentication with TACACS+ for '
        'router logins during business hours 09:00 to 17:00.',
      );
      expect(plan.security.protectedServerIp, '192.168.1.100');
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'acl',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('ip access-list extended PROTECTED_SERVER'));
      // Real source subnet, real protected and allowed hosts.
      expect(
        section,
        contains('permit tcp 192.168.2.0 0.0.0.255 host 192.168.1.102 eq 80'),
      );
      expect(
        section,
        contains('deny ip 192.168.2.0 0.0.0.255 host 192.168.1.100'),
      );
      expect(section, contains('permit ip any any'));
      // Applied on the real router's real WAN interface.
      expect(section, contains('BR_Router'));
      expect(section, contains('interface s0/0/0'));
      expect(section, contains('ip access-group PROTECTED_SERVER out'));
      expect(
        section.trimRight().split('\n').last,
        contains('show access-lists'),
      );
    });

    test('a manager-only plan gets the VTY access-class section', () {
      final plan = twoRouterLab().copyWith(
        security: const SecurityIntent(managerIp: '192.168.1.50'),
      );
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'acl',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section, contains('ip access-list standard VTY_MANAGER_ONLY'));
      expect(section, contains('permit host 192.168.1.50'));
      expect(section, contains('deny any'));
      expect(section, contains('access-class VTY_MANAGER_ONLY in'));
    });

    test('a plan with no ACL policy gets the gap line', () {
      final gap = PlanConfigComposer.compose(
        plan: twoRouterLab(),
        topic: 'acl',
        target: 'pt',
      );
      expect(gap, isNotNull);
      expect(gap!.startsWith('Your lab:'), isTrue);
      expect(gap, contains('no ACL policy yet'));
      expect(gap, isNot(contains('access-list ')));
    });
  });

  group('nat (internet)', () {
    late NetworkIntent plan;
    setUpAll(() {
      plan = NetworkIntent.parseSimple(
        'nat-chat',
        '1 router 1 switch 2 pcs and one cloud',
      );
    });

    test('the cloud link is the outside, the LAN the inside', () {
      // Sanity: the parser really cabled R1 to the cloud.
      expect(
        plan.nodes.any((n) => n.type == 'cloud'),
        isTrue,
        reason: 'the brief produced an edge device',
      );
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'internet',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      expect(section, contains('CLOUD1'));
      expect(section, contains('interface g0/1'));
      expect(section, contains(' ip nat inside'));
      expect(section, contains('interface g0/2'));
      expect(section, contains(' ip nat outside'));
      expect(
        section,
        contains('access-list 100 permit ip 192.168.1.0 0.0.0.255 any'),
      );
      expect(
        section,
        contains('ip nat inside source list 100 interface g0/2 overload'),
      );
      expect(
        section.trimRight().split('\n').last,
        contains('show ip nat translations'),
      );
    });

    test('the same plan grounds the default route out of the edge', () {
      final section = PlanConfigComposer.compose(
        plan: plan,
        topic: 'default_route',
        target: 'pt',
      );
      expect(section, isNotNull);
      expect(section!.startsWith('Your lab:'), isTrue);
      // The edge link carries no address, so the route rides the exit
      // interface - the plan's real edge interface.
      expect(section, contains('ip route 0.0.0.0 0.0.0.0 g0/2'));
      expect(
        section.trimRight().split('\n').last,
        contains('show ip route'),
      );
    });

    test('a plan with no edge gets the gap line for both topics', () {
      for (final topic in const ['internet', 'default_route']) {
        final gap = PlanConfigComposer.compose(
          plan: twoRouterLab(),
          topic: topic,
          target: 'pt',
        );
        expect(gap, isNotNull, reason: topic);
        expect(gap!.startsWith('Your lab:'), isTrue, reason: topic);
        expect(gap, contains('no internet edge yet'), reason: topic);
        expect(gap, contains('add internet access'), reason: topic);
        expect(gap, isNot(contains('ip nat ')), reason: topic);
      }
    });
  });
}
