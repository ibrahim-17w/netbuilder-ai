import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/build_artifact_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The offline planner is the path that has to work with no API key, so these
/// tests pin the wording it accepts: Arabic briefs, Arabic-Indic digits,
/// dotted masks, spelled-out numbers, and the synonyms a course brief mixes
/// English and Arabic into.  Nothing here touches Gemini, Packet Tracer or the
/// network - the whole point is that this path needs none of them.
void main() {
  String fixture(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  group('brief bridge', () {
    test('Arabic-Indic digits become ASCII', () {
      final bridged = NetworkIntent.bridgeBrief('٢ routers ١ switch');
      expect(bridged, contains('2 routers'));
      expect(bridged, contains('1 switch'));
    });

    test('right-to-left marks and tashkeel do not break matching', () {
      final bridged = NetworkIntent.bridgeBrief('\u200fموجه\u064c\nمبدلة');
      expect(bridged, contains('router'));
      expect(bridged, contains('switch'));
    });

    test('a dotted mask becomes a prefix length', () {
      expect(
        NetworkIntent.bridgeBrief('LAN 192.168.1.0 255.255.255.0'),
        contains('192.168.1.0/24'),
      );
      expect(
        NetworkIntent.bridgeBrief('WAN 10.1.1.0 subnet mask 255.255.255.252'),
        contains('10.1.1.0/30'),
      );
      // A plain address pair is not a mask and must survive untouched.
      expect(
        NetworkIntent.bridgeBrief('peer 192.168.1.1 192.168.2.1'),
        contains('192.168.1.1 192.168.2.1'),
      );
    });

    test('numbers spelled out - English and Arabic - become digits', () {
      expect(NetworkIntent.bridgeBrief('two routers'), contains('2 routers'));
      expect(NetworkIntent.bridgeBrief('اثنين موجه'), contains('2 router'));
      expect(NetworkIntent.bridgeBrief('three switches'), contains('3'));
    });

    test('Arabic device words map onto the parser vocabulary', () {
      final bridged = NetworkIntent.bridgeBrief(
        'الفرع الرئيسي يضم الموجه والمبدلة والخادم وجهاز الموظفين',
      );
      expect(bridged, contains('headquarters'));
      expect(bridged, contains('router'));
      expect(bridged, contains('switch'));
      expect(bridged, contains('server'));
      expect(bridged, contains('pc'));
      // 'جهاز التوجيه' is a router, not a PC: the longer phrase wins.
      expect(
        NetworkIntent.bridgeBrief('جهاز التوجيه'),
        isNot(contains('pc')),
      );
    });
  });

  group('Arabic-only security brief', () {
    const brief = '''
مشروع أمن الشبكات
الفرع الرئيسي يضم الموجه والمبدلة وخادم AAA وخادم الويب.
الفرع الفرعي يضم الموجه والمبدلة.
وصلة تسلسلية تربط بين الموجهين.
قم بتفعيل أمن المنافذ على منافذ المستخدمين وتنصت DHCP ومنع الخوادم الوهمية.
استخدم المصادقة المركزية TACACS+ للدخول الى الموجه.
أوقات الدوام الرسمي من 8:00 الى 16:00.
''';

    test('is recognised and planned without any Latin keyword', () {
      final intent = NetworkIntent.parseSimple('amn', brief);
      expect(intent.planningSource, 'local');
      expect(intent.nodes.map((n) => n.name), contains('HQ_Router'));
      expect(intent.nodes.map((n) => n.name), contains('AAA1'));
      final s = intent.security;
      expect(s.portSecurity, isTrue);
      expect(s.dhcpSnooping, isTrue);
      expect(s.aaa, isTrue);
      expect(s.officeHours, contains('8:00-16:00'));
      expect(intent.links.any((l) => l.isSerial), isTrue);
      expect(ValidatorService.hasErrors(ValidatorService.validate(intent)), isFalse);
    });

    test('English synonyms trigger the same controls', () {
      final intent = NetworkIntent.parseSimple(
        'secure-hq',
        'Harden the user ports on the HQ switch and stop rogue DHCP servers '
            'from the branch site. Centralized authentication with TACACS+ for '
            'router logins during business hours 09:00 to 17:00.',
      );
      final s = intent.security;
      expect(s.portSecurity, isTrue);
      expect(s.dhcpSnooping, isTrue);
      expect(s.aaa, isTrue);
      expect(s.officeHours, contains('09:00-17:00'));
    });
  });

  group('the course brief (Arabic .docx) offline', () {
    late NetworkIntent intent;

    setUpAll(() {
      intent = NetworkIntent.parseSimple(
        'security-project',
        fixture('security_brief_ar.txt'),
      );
    });

    test('plans the two-site topology with no key and no model', () {
      expect(intent.planningSource, 'local');
      expect(
        intent.nodes.map((n) => '${n.name}:${n.type}'),
        containsAll(<String>[
          'HQ_Router:router',
          'BR_Router:router',
          'HQ_Switch:switch',
          'BR_Switch:switch',
          'AAA1:server',
          'DHCP1:server',
          'WEB1:server',
          'MGR1:pc',
          'HQ_PC1:pc',
          'BR_PC1:pc',
        ]),
      );
      // Every device is cabled: nothing is left floating for the user.
      for (final n in intent.nodes) {
        expect(
          intent.links.any((l) => l.a == n.name || l.b == n.name),
          isTrue,
          reason: '${n.name} has no link',
        );
      }
    });

    test('honours the brief address table', () {
      String addr(String node, String iface) => intent.addressing
          .firstWhere((a) => a.node == node && a.iface == iface)
          .ipCidr;
      expect(addr('HQ_Router', 's0/0/0'), '10.1.1.1/30');
      expect(addr('BR_Router', 's0/0/0'), '10.1.1.2/30');
      expect(addr('HQ_Router', 'g0/0'), '192.168.1.1/24');
      expect(addr('BR_Router', 'g0/0'), '192.168.2.1/24');
      expect(addr('AAA1', 'f0'), '192.168.1.100/24');
      expect(addr('MGR1', 'f0'), '192.168.1.50/24');
    });

    test('carries every security control the project asks for', () {
      final s = intent.security;
      expect(s.portSecurity, isTrue, reason: 'layer-2 port security');
      expect(s.dhcpSnooping, isTrue, reason: 'DHCP snooping task');
      expect(s.aaa, isTrue, reason: 'TACACS+ task');
      expect(s.managerIp, '192.168.1.50', reason: 'manager-only VTY task');
      expect(s.extendedAcl, isTrue, reason: 'branch ACL task');
      expect(s.ipsecVpn, isTrue, reason: 'site-to-site VPN task');
      expect(s.vpnEncryption, 'aes');
      expect(s.vpnHash, 'sha');
      // The brief states no secrets, and the planner never invents one: it
      // asks, so the lab is built with the credentials the project expects.
      expect(s.aaaUsername, isNull);
      expect(s.aaaPassword, isNull);
      expect(s.vpnPreSharedKey, isNull);
      expect(
        intent.questions.where((q) => q.toLowerCase().contains('credential')),
        isNotEmpty,
      );
    });

    test('uses the credentials and pre-shared key when the brief states them', () {
      final stated = NetworkIntent.parseSimple('security-project', '''
Security project for the branch and headquarters. TACACS+ username labadmin
with password LabAdmin2026, office hours 08:00 to 17:00, port security and
DHCP snooping on the user ports, IPSec with pre-shared key NetBuilderLab2026,
AES and SHA.
''');
      expect(stated.security.aaaUsername, 'labadmin');
      expect(stated.security.aaaPassword, 'LabAdmin2026');
      expect(stated.security.vpnPreSharedKey, 'NetBuilderLab2026');
    });

    test('reads credentials written in Arabic', () {
      final stated = NetworkIntent.parseSimple('amn', '''
الفرع الرئيسي والفرع الفرعي. اسم المستخدم labadmin
كلمة المرور LabAdmin2026. استخدم TACACS+ و امن المنافذ.
''');
      expect(stated.security.aaaUsername, 'labadmin');
      expect(stated.security.aaaPassword, 'LabAdmin2026');
    });

    test('validates without a blocking error', () {
      final issues = ValidatorService.validate(intent, target: 'pt');
      expect(
        issues.where((i) => i.severity == 'error').map((i) => i.message),
        isEmpty,
      );
    });

    test('renders a config that contains the security blocks', () {
      final cfg = BuildArtifactService.renderLocal(intent, 'pt');
      expect(cfg, contains('switchport port-security'));
      expect(cfg, contains('ip dhcp snooping'));
      expect(cfg, contains('aaa authentication login default group tacacs+'));
      expect(cfg, contains('tacacs-server host 192.168.1.100'));
      expect(cfg, contains('ip access-list extended BRANCH_TO_HQ'));
      expect(cfg, contains('crypto isakmp policy 10'));
      expect(cfg, contains('crypto ipsec transform-set SITE_VPN_SET'));
      // No key in the brief, so the crypto map is deliberately left out and
      // the config says why instead of shipping a tunnel that cannot come up.
      expect(cfg, isNot(contains('crypto map SITE_VPN 10 ipsec-isakmp')));
      expect(cfg, contains('pre-shared key not supplied'));

      final keyed = NetworkIntent.parseSimple('security-project', '''
Branch and headquarters security lab with IPSec using pre-shared key
NetBuilderLab2026, AES and SHA, and TACACS+ username labadmin password
LabAdmin2026.
''');
      final keyedCfg = BuildArtifactService.renderLocal(keyed, 'pt');
      expect(keyedCfg, contains('crypto map SITE_VPN 10 ipsec-isakmp'));
      expect(keyedCfg, contains('set peer'));
    });
  });

  group('simple prompts produce a complete network', () {
    /// Every device cabled, every configurable device addressed, and the
    /// switches actually carrying devices: what "2 routers 2 switches 1
    /// server and 4 pcs" has to mean when the brief gives no cables.
    void expectCompleteTopology(NetworkIntent intent) {
      for (final n in intent.nodes) {
        expect(
          intent.links.any((l) => l.a == n.name || l.b == n.name),
          isTrue,
          reason: '${n.name} was left floating',
        );
        if (deviceKindOf(n.type)?.ipConfig ?? false) {
          expect(
            intent.addressing.any((a) => a.node == n.name),
            isTrue,
            reason: '${n.name} has no address',
          );
        }
      }
      for (final sw in intent.nodes.where((n) => n.type == 'switch')) {
        expect(
          intent.links.any(
            (l) =>
                (l.a == sw.name || l.b == sw.name) &&
                (l.a != sw.name || l.b != sw.name),
          ),
          isTrue,
          reason: '${sw.name} has no link',
        );
      }
    }

    test('"2 routers 2 switches 1 server and 4 pcs" is a two-LAN network', () {
      final intent = NetworkIntent.parseSimple(
        'office',
        'small office network with 2 routers 2 switches 1 server and 4 pcs',
      );
      expectCompleteTopology(intent);
      expect(intent.nodes.length, 9);
      // One LAN per router, so the two switches are not stacked on one side.
      final uplinks = intent.links.where((l) {
        bool kind(String name, String type) => intent.nodes.any(
          (n) => n.name == name && n.type == type,
        );
        return (kind(l.a, 'router') && kind(l.b, 'switch')) ||
            (kind(l.b, 'router') && kind(l.a, 'switch'));
      }).toList();
      expect(uplinks.length, 2);
      final lanSubnets = intent.links
          .where((l) => l.a == 'R1' || l.b == 'R1')
          .where((l) => l.a == 'SW1' || l.b == 'SW1')
          .expand(
            (l) => intent.addressing.where(
              (a) =>
                  a.node == 'R1' &&
                  a.iface == (l.a == 'R1' ? l.aIf : l.bIf),
            ),
          )
          .map((a) => a.ipCidr)
          .toList();
      expect(lanSubnets, ['192.168.1.1/24']);
      // ...and their PCs are on different subnets, each with its own gateway.
      final pc1 = PacketTracerAdapter.endpointIpConfig(intent, 'PC1');
      final pc3 = PacketTracerAdapter.endpointIpConfig(intent, 'PC3');
      expect(pc1['ip']!.split('.').sublist(0, 3), ['192', '168', '1']);
      expect(pc3['ip']!.split('.').sublist(0, 3), ['192', '168', '2']);
      expect(pc1['gw'], '192.168.1.1');
      expect(pc3['gw'], '192.168.2.1');
      // The server sits on the first LAN (the one switch the brief put it on).
      final srv = PacketTracerAdapter.endpointIpConfig(intent, 'SRV1');
      expect(srv['gw'], '192.168.1.1');
    });

    test('one router with three switches gives each LAN its own subnet', () {
      final intent = NetworkIntent.parseSimple(
        'office',
        'office with 1 router 3 switches 2 servers 8 pcs',
      );
      expectCompleteTopology(intent);
      final subnets = intent.nodes
          .where((n) => n.type == 'pc')
          .map(
            (n) =>
                PacketTracerAdapter.endpointIpConfig(intent, n.name)['ip']!
                    .split('.')
                    .sublist(0, 3)
                    .join('.'),
          )
          .toSet();
      expect(subnets.length, 3, reason: 'three switches, three LANs');
    });

    test('a multi-router plan routes its LANs without a routing protocol', () {
      final intent = NetworkIntent.parseSimple(
        'chain',
        '3 routers 3 switches 6 pcs',
      );
      expectCompleteTopology(intent);
      final cfgs = CiscoAdapter.render(intent);
      // The middle router needs both far LANs, the ends need one each, and
      // nothing may route through a transit subnet that is not a LAN.
      expect(cfgs['R1']!, contains('ip route 192.168.2.0 255.255.255.0'));
      expect(cfgs['R1']!, contains('ip route 192.168.3.0 255.255.255.0'));
      expect(cfgs['R1']!, isNot(contains('ip route 10.0.0.')));
      expect(cfgs['R2']!, contains('ip route 192.168.1.0 255.255.255.0'));
      expect(cfgs['R2']!, contains('ip route 192.168.3.0 255.255.255.0'));
      expect(cfgs['R3']!, contains('ip route 192.168.1.0 255.255.255.0'));
      expect(cfgs['R3']!, isNot(contains('ip route 192.168.3.0')));
    });

    test('no static routes are added when OSPF was asked for', () {
      final intent = NetworkIntent.parseSimple(
        'ospf',
        '2 routers 2 switches 4 pcs, use ospf',
      );
      final cfg = CiscoAdapter.render(intent)['R1']!;
      expect(cfg, contains('router ospf 1'));
      expect(cfg, isNot(contains('ip route ')));
      for (final sw in intent.nodes.where((n) => n.type == 'switch')) {
        expect(
          intent.links.any((l) => l.a == sw.name || l.b == sw.name),
          isTrue,
        );
      }
    });

    test('"each with ..." describes every site, not just the first', () {
      final intent = NetworkIntent.parseSimple(
        'sites',
        'two branch offices connected by a serial WAN, each with a router, a '
            'switch and 3 pcs, plus one server at headquarters',
      );
      expect(intent.nodes.where((n) => n.type == 'router').length, 2);
      expect(intent.nodes.where((n) => n.type == 'switch').length, 2);
      expect(intent.nodes.where((n) => n.type == 'pc').length, 6);
      // 'one server at headquarters' is an aside, not a per-site device.
      expect(intent.nodes.where((n) => n.type == 'server').length, 1);
      expectCompleteTopology(intent);
      expect(intent.links.any((l) => l.isSerial), isTrue);
      final cfg = CiscoAdapter.render(intent);
      expect(cfg['R1']!, contains('ip route 192.168.2.0 255.255.255.0'));
      expect(cfg['R2']!, contains('ip route 192.168.1.0 255.255.255.0'));
    });

    test('a brief that says it once keeps one site', () {
      final intent = NetworkIntent.parseSimple(
        'single',
        'one office network with 2 routers 2 switches 1 server 4 pcs',
      );
      expect(intent.nodes.where((n) => n.type == 'router').length, 2);
      expect(intent.nodes.where((n) => n.type == 'switch').length, 2);
      expect(intent.nodes.where((n) => n.type == 'pc').length, 4);
    });

    test('wired extras are spread over the switches, not stacked', () {
      final intent = NetworkIntent.parseSimple(
        'home',
        'a home office with 2 switches, one printer, two laptops and two pcs',
      );
      expectCompleteTopology(intent);
      for (final n in intent.nodes.where(
        (n) => deviceKindOf(n.type)?.ipConfig ?? false,
      )) {
        expect(
          PacketTracerAdapter.endpointIpConfig(intent, n.name)['ip'],
          isNot('0.0.0.0'),
        );
      }
    });
  });

  group('plain wording the offline planner must still accept', () {
    test('spelled-out quantities and a dotted mask plan a real topology', () {
      final intent = NetworkIntent.parseSimple(
        'office',
        'two routers, one switch and two PCs. Serial WAN 10.0.0.0 '
            '255.255.255.252, LAN 192.168.1.0 255.255.255.0. Run OSPF.',
      );
      expect(intent.nodes.where((n) => n.type == 'router').length, 2);
      expect(intent.nodes.where((n) => n.type == 'switch').length, 1);
      expect(intent.nodes.where((n) => n.type == 'pc').length, 2);
      expect(intent.routing, 'ospf');
      final cidrs = intent.addressing.map((a) => a.ipCidr).toList();
      expect(cidrs, contains('10.0.0.1/30'));
      expect(cidrs, contains('192.168.1.1/24'));
      expect(intent.links.any((l) => l.cable == 'serial'), isTrue);
    });
  });
}
