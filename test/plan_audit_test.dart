import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/layout_intent.dart';
import 'package:net_builder/services/validator_service.dart';

/// The plans ordinary briefs produce, kept honest.
///
/// Every case here is a brief a person would actually type, run through the
/// same chain the chat runs: parse -> validate -> build gate. The files these
/// plans describe are built from the chat, so a plan that cannot be built is
/// the whole failure mode - and each entry in this file is a bug that got that
/// far: "1 router and 3 pcs" shipped with every PC at 0.0.0.0 and a blocking
/// finding each (all three cables on one router port, and no addressing pass
/// for an endpoint cabled straight to a router); a brief of pure security
/// controls produced a one-device plan; "VLANs 10, 20, 30 and 40" lost all four
/// VLANs because the normalizer trims the commas that separated them.
List<ValidationIssue> blocking(NetworkIntent plan) =>
    ValidatorService.validate(plan, target: 'packet-tracer')
        .where((i) => i.blocks)
        .toList();

NetworkIntent plan(String brief) =>
    NetworkIntent.parseSimple('audit', CasualEnglish.normalize(brief));

int count(NetworkIntent p, String type) =>
    p.nodes.where((n) => n.type == type).length;

/// The exact write/read pair the chat's session state uses.
NetworkIntent restored(NetworkIntent p) => NetworkIntent.fromJson(
  Map<String, dynamic>.from(
    jsonDecode(jsonEncode(p.toJson(includeSecrets: false))) as Map,
  ),
);

void main() {
  group('an ordinary brief is buildable', () {
    const briefs = <String, String>{
      'home': '1 router and 3 pcs',
      'flat office': '2 routers, 2 switches and 20 pcs with ospf',
      'switchless vlan lab':
          '1 router and 1 switch, VLANs 10, 20, 30 and 40 with 2 pcs each, '
          'router on a stick and ospf',
      'wireless home':
          'a wireless router with SSID HOME and WPA2, 3 laptops and a printer',
      'server lab':
          '1 router, 1 switch and 1 server with DHCP, DNS records web.lab '
          '192.168.1.10, HTTP and FTP user alice password test123',
      'serial WAN':
          '2 routers connected by a serial link with R1 the DCE end, OSPF, '
          '2 switches and 6 pcs',
      'triangle': '3 routers in a triangle with ospf, 4 switches and 12 pcs',
      'NAT to the internet':
          '1 router NAT to the internet through a cloud, 1 switch, 5 pcs',
      'ipv6': '2 routers and 4 pcs with ipv6 2001:db8:1::/64 on the LAN',
      'firewall':
          'a firewall between the internet and the LAN, 2 switches, 10 pcs',
      'hsrp': '2 routers with HSRP virtual ip 192.168.1.254, 1 switch, 10 pcs',
      'etherchannel': '2 switches with an etherchannel trunk and 2 pcs',
      'voice': '1 router, 1 switch, 5 ip phones and 5 pcs with a voice vlan 110',
      'typos': 'i wanna a netwrok with 3 routrs and 2 swtichs and like 10 pcs '
          'and ospf pls',
      'ten pcs and no switch': '1 router and 10 pcs',
    };

    briefs.forEach((label, brief) {
      test(label, () {
        final built = plan(brief);
        expect(
          blocking(built).map((i) => '[${i.severity}] ${i.message}').toList(),
          isEmpty,
          reason: 'the plan for "$brief" must be buildable',
        );
      });
    });
  });

  group('a switch-less brief gets a real LAN', () {
    test('every endpoint has its own router interface and an address', () {
      final built = plan('1 router and 3 pcs');
      final pcIfaces = <String>{};
      for (final l in built.links) {
        final routerSide = l.a == 'R1' ? l.aIf : l.bIf;
        pcIfaces.add(routerSide);
      }
      expect(
        pcIfaces.length,
        built.links.length,
        reason: 'one cable per router interface, never two on one port',
      );
      for (final pc in built.nodes.where((n) => n.type == 'pc')) {
        expect(
          built.addressing.any((a) => a.node == pc.name),
          isTrue,
          reason: '${pc.name} needs an address, not 0.0.0.0',
        );
      }
      // The gateway of each PC is the router interface facing it.
      for (final a in built.addressing.where((a) => a.node == 'R1')) {
        expect(a.iface.toLowerCase().startsWith('g'), isTrue);
      }
    });

    test('more endpoints than router interfaces earns a switch', () {
      final built = plan('1 router and 10 pcs');
      expect(count(built, 'pc'), 10);
      expect(count(built, 'switch'), 1, reason: 'a router has four LAN ports');
      expect(blocking(built), isEmpty);
    });

    test('a router is never handed two cables on one interface', () {
      for (final brief in const [
        '1 router and 3 pcs',
        '2 routers and 4 pcs',
        '3 routers and 12 pcs',
      ]) {
        final built = plan(brief);
        final used = <String>{};
        for (final l in built.links) {
          for (final end in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)]) {
            expect(
              used.add('${end.key}|${end.value}'.toLowerCase()),
              isTrue,
              reason: '$brief: ${end.key} ${end.value} carries two cables',
            );
          }
        }
      }
    });
  });

  group('a brief of controls and no device', () {
    test('is planned as the security lab, not as one lonely server', () {
      final built = plan(
        'harden the network: port security on the user ports, dhcp snooping, '
        'ssh instead of telnet and aaa on the vty lines',
      );
      expect(count(built, 'router'), greaterThanOrEqualTo(2));
      expect(count(built, 'switch'), greaterThanOrEqualTo(2));
      expect(built.nodes.any((n) => n.services.contains('aaa')), isTrue);
      expect(built.security.portSecurity, isTrue);
      expect(built.security.dhcpSnooping, isTrue);
      expect(built.security.ssh, isTrue);
    });

    test('still leaves a brief that names its own devices alone', () {
      // Counts are a specification: the profile must not replace them.
      final built = plan('2 routers 2 switches 20 pcs and aaa with port '
          'security');
      expect(count(built, 'router'), 2);
      expect(count(built, 'switch'), 2);
      expect(count(built, 'pc'), 20);
      // At most the one server AAA needs - the profile's ten-device lab (with
      // its own PCs, manager and WAN) must not have appeared over the counts.
      expect(count(built, 'server'), lessThanOrEqualTo(1));
    });
  });

  group('a VLAN list survives the normalizer', () {
    test('commas are not needed for the list to be read', () {
      for (final written in const [
        '1 router 1 switch 4 pcs VLANs 10, 20, 30 and 40',
        '1 router 1 switch 4 pcs vlans 10 20 30 40',
        '1 router 1 switch 4 pcs vlan 10 and vlan 20',
      ]) {
        final built = plan(written);
        expect(built.vlans, containsAll(const [10, 20]), reason: written);
      }
    });

    test('a router-on-a-stick lab is addressed per VLAN', () {
      final built = plan(
        '1 router and 1 switch, VLANs 10, 20, 30 and 40 with 2 pcs each, '
        'router on a stick and ospf',
      );
      expect(built.vlans, const [10, 20, 30, 40]);
      expect(built.security.interVlanRouting, isTrue);
      for (final v in built.vlans) {
        expect(
          built.addressing.any((a) => a.iface.endsWith('.$v')),
          isTrue,
          reason: 'VLAN $v needs a dot1Q sub-interface',
        );
      }
      expect(blocking(built), isEmpty);
    });
  });

  group('the build gate tells advice from a decision', () {
    test('a note the build acts on itself does not withhold the build', () {
      final built = plan('2 routers with a serial link, 2 switches and 6 pcs');
      final messages = ValidatorService.validate(
        built,
        target: 'packet-tracer',
      ).map((i) => i.message).join(' | ');
      expect(messages, contains('serial module'), reason: 'still reported');
      expect(blocking(built), isEmpty);
    });

    test('a gap only the user can fill still withholds it', () {
      final built = plan('2 routers 1 switch 8 pcs with aaa on the vty lines');
      expect(
        blocking(built).map((i) => i.message).join(' | '),
        contains('holds no account'),
      );
    });
  });

  group('a redacted plan is repaired by the conversation', () {
    test('the profile lab survives the round trip', () {
      const brief =
          'harden the network: port security on the user ports, dhcp snooping, '
          'ssh instead of telnet and aaa on the vty lines with username admin '
          'password 123';
      final back = restored(plan(brief));
      expect(blocking(back), isNotEmpty, reason: 'the redaction drops it');
      expect(
        blocking(NetworkIntent.recoverRedactedSecrets(back, brief)),
        isEmpty,
        reason: 'the transcript still has what the user typed',
      );
    });
  });

  group('a typo in the plural is still that word', () {
    test('two switches asked for are two switches planned', () {
      final built = plan('3 routers, 2 swtichs and 10 pcs with ospf');
      expect(count(built, 'router'), 3);
      expect(count(built, 'switch'), 2, reason: 'swtichs = switches');
      expect(blocking(built), isEmpty);
    });

    test('the repair never rewrites a real word', () {
      // "wireless" ends in an s and maps from the typo "wireles": putting an
      // s back on it produced "wirelesses", which matched nothing, so a brief
      // asking for a wireless router got a plain wired 2911 instead.
      expect(CasualEnglish.normalize('a wireless router'), 'a wireless router');
      expect(CasualEnglish.normalize('2 swtichs'), '2 switches');
      expect(CasualEnglish.normalize('3 routrs'), '3 routers');
      expect(CasualEnglish.normalize('1 wirless swtich'), '1 wireless switch');
    });
  });

  group('a brief that names its wireless router keeps it', () {
    test('the wireless router is planned as one', () {
      for (final brief in const [
        'a wireless router with SSID HOME and WPA2, 3 laptops and a printer',
        'a wireless router and 4 laptops',
        'a wireless router and 4 smart bulbs with ssid HOME',
      ]) {
        final built = plan(brief);
        expect(count(built, 'wireless-router'), 1, reason: brief);
        expect(blocking(built), isEmpty, reason: brief);
      }
    });

    test('the things a home lab names are counted as the devices they are', () {
      final built = plan('a wireless router and 4 smart bulbs with ssid HOME');
      expect(count(built, 'iot'), 4);
      expect(count(built, 'wireless'), 1, reason: 'the bulbs join an AP');
    });
  });

  group('a tunnel asked for is a tunnel planned', () {
    const twoSites =
        'two sites with 2 routers, 2 switches and 8 pcs each, site-to-site '
        'ipsec vpn with pre-shared key LabKey1 and ospf';

    test('the peers and protected networks come off the plan', () {
      final built = plan(twoSites);
      final s = built.security;
      expect(s.ipsecVpn, isTrue);
      expect(s.vpnPreSharedKey, 'LabKey1');
      // The WAN addresses and the two LANs, not one profile's fixed numbers.
      expect(s.vpnPeerA, '10.0.0.1');
      expect(s.vpnPeerB, '10.0.0.2');
      expect(s.vpnLocalNetwork, '192.168.1.0/24');
      expect(s.vpnRemoteNetwork, '192.168.2.0/24');
      // The licensing note is advice: the tunnel is still generated.
      expect(blocking(built), isEmpty);
    });

    test('each end protects its own LAN and points at the other peer', () {
      final built = plan(twoSites);
      final s = built.security;
      final cfgs = CiscoAdapter.render(built);
      final r1 = cfgs['R1'] ?? '';
      final r2 = cfgs['R2'] ?? '';
      expect(r1, contains('crypto isakmp key LabKey1 address ${s.vpnPeerB}'));
      expect(r2, contains('crypto isakmp key LabKey1 address ${s.vpnPeerA}'));
      expect(r1, contains('set peer ${s.vpnPeerB}'));
      expect(r2, contains('set peer ${s.vpnPeerA}'));
      expect(
        r1,
        contains('permit ip 192.168.1.0 0.0.0.255 192.168.2.0 0.0.0.255'),
      );
      expect(
        r2,
        contains('permit ip 192.168.2.0 0.0.0.255 192.168.1.0 0.0.0.255'),
      );
      // The map rides the WAN port THIS plan built (g0/0), not a hard-coded
      // s0/0/0 the device does not have.
      final mapped = RegExp(
        r'interface (\S+)\s*\n crypto map SITE_VPN',
      ).firstMatch(r1)?.group(1);
      expect(mapped, 'g0/0');
    });

    test('the tunnel probes are advice and ping a host that exists', () {
      final built = plan(twoSites);
      final checks = PacketTracerAdapter.securityChecks(built);
      final probes = checks
          .where((c) => c['kind'] == 'ike' || c['kind'] == 'ipsec')
          .toList();
      expect(probes, isNotEmpty);
      expect(
        probes.every((c) => c['advisory'] == true),
        isTrue,
        reason: 'Packet Tracer cannot type the crypto block, so a probe that '
            'can never pass must not fail the run',
      );
      for (final probe in probes) {
        final target = probe['trafficTarget'] as String?;
        expect(target, isNotNull);
        expect(
          built.addressing.any((a) => a.ipCidr.startsWith('$target/')),
          isTrue,
          reason: '$target must be an address this plan actually gives out',
        );
      }
    });

    test('a tunnel brief loses no other feature', () {
      // The security return path used to skip the IPv6 pass entirely.
      final built = plan('2 routers and 4 pcs with ipv6 and ipsec vpn '
          'pre-shared key Key9');
      expect(built.security.ipsecVpn, isTrue);
      expect(
        built.addressing.any((a) => a.ip6Cidr != null),
        isTrue,
        reason: 'asking for a tunnel must not drop the IPv6 addressing',
      );
      expect(built.security.vpnRemoteNetwork, isNotNull);
    });
  });

  group('a device the plan cannot cable is a note, not a refusal', () {
    test('a planned controller does not withhold the build', () {
      final built = plan(
        'a wireless lan controller with 2 access points and 8 laptops '
        'with WPA2 and SSID OFFICE',
      );
      expect(count(built, 'wlc'), 1);
      expect(blocking(built), isEmpty);
      expect(
        ValidatorService.validate(built, target: 'packet-tracer')
            .map((i) => i.message)
            .join(' | '),
        contains('placed but not cabled'),
        reason: 'uncabled by design is still said out loud',
      );
    });
  });

  group('the drawing a request asks for', () {
    test('a count per row means the rows drawing', () {
      final request = LayoutRequest.read('put 4 devices per row');
      expect(request?.style, 'rows');
      expect(request?.columns, 4);
      final words = LayoutRequest.read('four devices per row');
      expect(words?.style, 'rows');
      expect(words?.columns, 4);
    });

    test('a vague request is never the drawing already on the table', () {
      var style = 'tree';
      for (var i = 0; i < LayoutRequest.styles.length; i++) {
        final request = LayoutRequest.read('make it look better', currentStyle: style);
        expect(request, isNotNull);
        expect(request!.style, isNot(style));
        style = request.style;
      }
      expect(style, 'tree', reason: 'it cycles, so it never repeats a drawing');
    });

    test('a change to the network is not a redraw', () {
      expect(LayoutRequest.read('add another switch'), isNull);
      expect(LayoutRequest.read('build it'), isNull);
      expect(LayoutRequest.read('the layout is fine'), isNull);
    });
  });
}
