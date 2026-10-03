import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/validator_service.dart';

/// The brief a lab test is written from, kept whole: the regression it exists
/// for is the WHOLE prompt, not any sentence in it.
const String serialLabBrief =
    'Build a Packet Tracer project named `serial-10pc-service-lab`. '
    'Use exactly two Cisco 2911 routers (R1 and R2), two Cisco 2960 switches '
    '(SW1 and SW2), ten PCs (PC1-PC10), and six Server-PT devices: '
    'DHCP1, DNS1, WEB1, AAA1, FTP1 and MAIL1. '
    'Connect R1 Serial0/0/0 to R2 Serial0/0/0 with a serial cable. '
    'R1 is the only DCE end, with clock rate 64000. Install an HWIC-2T if '
    'needed. Keep the exact Serial0/0/0 interfaces; a remap to another port '
    'fails this test. '
    'Connect R1 GigabitEthernet0/0 to SW1 FastEthernet0/1 and R2 '
    'GigabitEthernet0/0 to SW2 FastEthernet0/1. '
    'Connect PC1-PC5 to SW1 FastEthernet0/2-0/6 and PC6-PC10 to SW2 '
    'FastEthernet0/2-0/6. '
    'Connect DHCP1, DNS1, WEB1, AAA1, FTP1 and MAIL1 to SW1 '
    'FastEthernet0/7-0/12. '
    'Use 10.255.0.0/30 on the serial link: R1 is 10.255.0.1 and R2 is '
    '10.255.0.2. Use 192.168.10.0/24 on the R1 LAN and 192.168.20.0/24 on the '
    'R2 LAN, with .1 as each gateway. '
    'Assign PC1-PC5 addresses .11-.15 on the R1 LAN and PC6-PC10 addresses '
    '.11-.15 on the R2 LAN. '
    'Assign DHCP1-MAIL1 addresses 192.168.10.101-192.168.10.106 in the order '
    'listed. Set the correct masks, gateways and DNS address on every '
    'endpoint. '
    'Configure OSPF area 0 across the serial link and both LANs. '
    'Configure DHCP1 with named pools for both LANs, using each LAN\'s .1 '
    'gateway and DNS server 192.168.10.102. Start the R1 LAN pool at '
    '192.168.10.150 and the R2 LAN pool at 192.168.20.100, with 40 leases '
    'each. Add DHCP relay on R2\'s LAN interface, pointing to DHCP1 at '
    '192.168.10.101. Keep the static PC and server addresses outside both '
    'pools. '
    'DNS1: web.lab.test -> 192.168.10.103, ftp.lab.test -> 192.168.10.105, '
    'mail.lab.test -> 192.168.10.106, and r2.lab.test -> 192.168.20.1. '
    'WEB1: Enable HTTP and HTTPS. '
    'AAA1: Enable AAA/TACACS+, add user netadmin with password LabTest2026, '
    'and add R1 at 192.168.10.1 as a client using the same shared key on the '
    'server and router. '
    'FTP1: Enable FTP and add user ftpuser with password FtpTest2026. '
    'MAIL1: Enable email, set domain lab.test, and add user mailuser with '
    'password MailTest2026. '
    'Show the assumptions and validation findings before execution. Build the '
    'topology, verify the exact serial interfaces, OSPF adjacency, DHCP '
    'pools, DNS records, service settings and account entries. Run gateway '
    'and cross-LAN ping checks from the PCs. Run the read-only audit and show '
    'proposed repairs for my review. Save the completed project as '
    '`serial-10pc-service-lab.pkt` and verify it can be reopened.';

NetworkIntent _parse([String? text]) => NetworkIntent.parseSimple(
  'serial-10pc-service-lab',
  text ?? CasualEnglish.normalize(serialLabBrief),
);

String? _ipOf(NetworkIntent intent, String node) {
  for (final row in intent.addressing) {
    if (row.node == node) return row.ipCidr;
  }
  return null;
}

Map<String, dynamic> _rule(NetworkIntent intent, String node, String service) {
  for (final n in intent.nodes) {
    if (n.name != node) continue;
    final rules = n.serviceRules[service];
    if (rules is Map) {
      return rules.map((k, v) => MapEntry(k.toString(), v));
    }
  }
  return const {};
}

void main() {
  group('the serial/service lab brief', () {
    late NetworkIntent intent;

    setUp(() => intent = _parse());

    test('builds exactly the twenty devices that were asked for', () {
      expect(
        intent.nodes.map((n) => n.name).toList(),
        [
          'R1',
          'R2',
          'SW1',
          'SW2',
          'PC1',
          'PC2',
          'PC3',
          'PC4',
          'PC5',
          'PC6',
          'PC7',
          'PC8',
          'PC9',
          'PC10',
          'DHCP1',
          'DNS1',
          'WEB1',
          'AAA1',
          'FTP1',
          'MAIL1',
        ],
      );
      expect(
        intent.nodes.where((n) => n.type == 'router').map((n) => n.model),
        ['2911', '2911'],
      );
      expect(
        intent.nodes.where((n) => n.type == 'switch').map((n) => n.model),
        ['2960', '2960'],
      );
      expect(intent.nodes.where((n) => n.type == 'server').length, 6);
    });

    test('cables the serial link between the exact interfaces asked for', () {
      final serial = intent.links.where((l) => l.isSerial).toList();
      expect(serial, hasLength(1));
      final link = serial.single;
      expect(link.a, 'R1');
      expect(link.b, 'R2');
      expect(link.aIf, 's0/0/0');
      expect(link.bIf, 's0/0/0');
      expect(link.cable, 'serial');
      // "R1 is the only DCE end", so the clocking side is R1.
      expect(link.dceEnd, 'a');
    });

    test('cables every uplink, PC and server, and nothing else', () {
      expect(intent.links, hasLength(19));

      bool linked(String node, String iface) => intent.links.any(
        (l) =>
            (l.a == node && l.aIf == iface) || (l.b == node && l.bIf == iface),
      );

      expect(linked('R1', 'g0/0'), isTrue);
      expect(linked('R2', 'g0/0'), isTrue);
      for (var n = 1; n <= 5; n++) {
        expect(linked('SW1', 'f0/${n + 1}'), isTrue, reason: 'PC$n uplink');
        expect(linked('PC$n', 'f0'), isTrue, reason: 'PC$n cable');
      }
      for (var n = 6; n <= 10; n++) {
        expect(linked('SW2', 'f0/${n - 4}'), isTrue, reason: 'PC$n uplink');
        expect(linked('PC$n', 'f0'), isTrue, reason: 'PC$n cable');
      }
      const servers = ['DHCP1', 'DNS1', 'WEB1', 'AAA1', 'FTP1', 'MAIL1'];
      for (var i = 0; i < servers.length; i++) {
        expect(
          linked('SW1', 'f0/${i + 7}'),
          isTrue,
          reason: '${servers[i]} on f0/${i + 7}',
        );
        expect(linked(servers[i], 'f0'), isTrue, reason: '${servers[i]} cable');
      }
    });

    test('addresses the serial link, both LANs, the PCs and the servers', () {
      expect(_ipOf(intent, 'R1'), '10.255.0.1/30');
      expect(_ipOf(intent, 'R2'), isNot('10.255.0.1/30'));
      expect(_ipOf(intent, 'R1'), '10.255.0.1/30');
      // The LAN interface, not the serial one, carries the LAN gateway.
      final r1 = intent.addressing.firstWhere((a) => a.node == 'R1');
      expect(r1.ipCidr, anyOf('10.255.0.1/30', '192.168.10.1/24'));
      expect(
        intent.addressing.where((a) => a.node == 'R1').map((a) => a.ipCidr),
        containsAll(['10.255.0.1/30', '192.168.10.1/24']),
      );
      expect(
        intent.addressing.where((a) => a.node == 'R2').map((a) => a.ipCidr),
        containsAll(['10.255.0.2/30', '192.168.20.1/24']),
      );

      for (var n = 1; n <= 5; n++) {
        expect(_ipOf(intent, 'PC$n'), '192.168.10.1$n/24', reason: 'PC$n');
      }
      for (var n = 6; n <= 10; n++) {
        final host = n - 5;
        expect(_ipOf(intent, 'PC$n'), '192.168.20.1$host/24', reason: 'PC$n');
      }
      const servers = ['DHCP1', 'DNS1', 'WEB1', 'AAA1', 'FTP1', 'MAIL1'];
      for (var i = 0; i < servers.length; i++) {
        expect(
          _ipOf(intent, servers[i]),
          '192.168.10.${101 + i}/24',
          reason: servers[i],
        );
      }
    });

    test('gives every endpoint a mask, gateway and DNS server', () {
      for (final node in ['PC1', 'PC5', 'PC6', 'PC10', 'DHCP1', 'MAIL1']) {
        final config = PacketTracerAdapter.endpointIpConfig(intent, node);
        expect(config['ip'], isNotEmpty, reason: '$node ip');
        expect(config['ip'], isNot('0.0.0.0'), reason: '$node placeholder');
        expect(config['mask'], '255.255.255.0', reason: '$node mask');
        expect(config['gw'], isNotEmpty, reason: '$node gateway');
        expect(config['dns'], '192.168.10.102', reason: '$node dns');
      }
      expect(
        PacketTracerAdapter.endpointIpConfig(intent, 'PC1')['gw'],
        '192.168.10.1',
      );
      expect(
        PacketTracerAdapter.endpointIpConfig(intent, 'PC6')['gw'],
        '192.168.20.1',
      );
    });

    test('routes OSPF across the serial link and both LANs', () {
      expect(intent.routing, 'ospf');
    });

    test('puts the named services on the named servers', () {
      final byName = {for (final n in intent.nodes) n.name: n};
      expect(byName['DHCP1']!.services, contains('dhcp'));
      expect(byName['DNS1']!.services, contains('dns'));
      expect(byName['WEB1']!.services, contains('http'));
      expect(byName['AAA1']!.services, contains('aaa'));
      expect(byName['FTP1']!.services, contains('ftp'));
      expect(byName['MAIL1']!.services, contains('email'));
      // No generic SRV* stand-ins left behind.
      expect(intent.nodes.where((n) => n.name.startsWith('SRV')), isEmpty);
    });

    test('reads both named DHCP pools and keeps statics outside them', () {
      final pools = (_rule(intent, 'DHCP1', 'dhcp')['pools'] as List?) ?? [];
      expect(pools, hasLength(2));
      String field(Map<String, dynamic> p, String key) =>
          (p[key] ?? '').toString();
      final r1 = pools.firstWhere(
        (p) => field(p as Map<String, dynamic>, 'startIp') ==
            '192.168.10.150',
      ) as Map<String, dynamic>;
      final r2 = pools.firstWhere(
        (p) => field(p as Map<String, dynamic>, 'startIp') ==
            '192.168.20.100',
      ) as Map<String, dynamic>;
      expect(field(r1, 'gateway'), '192.168.10.1');
      expect(field(r1, 'dnsServer'), '192.168.10.102');
      expect(field(r1, 'maxUsers'), '40');
      expect(field(r2, 'gateway'), '192.168.20.1');
      expect(field(r2, 'dnsServer'), '192.168.10.102');
      expect(field(r2, 'maxUsers'), '40');
    });

    test('reads the four DNS records with the right addresses', () {
      final records =
          (_rule(intent, 'DNS1', 'dns')['records'] as List?) ?? const [];
      final byName = <String, String>{
        for (final r in records)
          (r as Map)['name'].toString(): r['address'].toString(),
      };
      expect(byName['web.lab.test'], '192.168.10.103');
      expect(byName['ftp.lab.test'], '192.168.10.105');
      expect(byName['mail.lab.test'], '192.168.10.106');
      expect(byName['r2.lab.test'], '192.168.20.1');
    });

    test('reads the service accounts, and never invents a shared key', () {
      expect(
        _rule(intent, 'AAA1', 'aaa')['users'],
        contains(
          containsPair('username', 'netadmin'),
        ),
      );
      expect(
        _rule(intent, 'FTP1', 'ftp')['users'],
        contains(containsPair('username', 'ftpuser')),
      );
      final mail = _rule(intent, 'MAIL1', 'email');
      expect(mail['domain'], 'lab.test');
      expect(mail['users'], contains(containsPair('username', 'mailuser')));
      expect((_rule(intent, 'WEB1', 'http')['https']), isTrue);

      // "using the same shared key on the server and router" never says what
      // the key is, and the word "on" is not a key.
      expect(intent.security.aaa, isTrue);
      expect(intent.security.aaaServer, 'AAA1');
      expect(intent.security.aaaRouter, 'R1');
      expect(NetworkIntent.readSharedKey(serialLabBrief), isNull);
      final routerKey = (intent.security.aaaPassword ?? '').toLowerCase();
      expect(routerKey, isNot('on'));
      expect(routerKey.trim(), isEmpty);
    });

    test('has no validator errors', () {
      final issues = ValidatorService.validate(intent, target: 'packet-tracer');
      final errors = issues.where((i) => i.severity == 'error').toList();
      expect(errors, isEmpty, reason: errors.map((e) => e.message).join('\n'));
    });
  });

  group('the same brief asked twice', () {
    test('re-plans the same twenty devices instead of doubling them', () {
      final first = NetworkIntent.followUp(
        previous: null,
        previousBrief: '',
        brief: serialLabBrief,
        parsed: _parse(),
        project: 'serial-10pc-service-lab',
      );
      expect(first.plan.nodes, hasLength(20));

      // The word "add" appears in this brief four times ("add user netadmin",
      // "add R1 ... as a client", "add user ftpuser", "add user mailuser") and
      // "Add DHCP relay" as well. That is a specification, not a delta: reading
      // it as an addition merged the lab onto itself and produced 40 devices.
      final again = NetworkIntent.followUp(
        previous: first.plan,
        previousBrief: first.brief,
        brief: serialLabBrief,
        parsed: _parse(),
        project: 'serial-10pc-service-lab',
      );
      expect(again.plan.nodes, hasLength(20));
      expect(
        again.plan.nodes.map((n) => n.name).toSet(),
        first.plan.nodes.map((n) => n.name).toSet(),
      );
      expect(again.plan.links, hasLength(19));
      expect(NetworkIntent.planChangeSummary(first.plan, again.plan), isEmpty);
    });

    test('a genuine addition still adds', () {
      final base = _parse();
      final added = NetworkIntent.followUp(
        previous: base,
        previousBrief: serialLabBrief,
        brief: 'add 2 more PCs',
        parsed: NetworkIntent.parseSimple(
          'serial-10pc-service-lab',
          'add 2 more PCs',
        ),
        project: 'serial-10pc-service-lab',
      );
      expect(added.plan.nodes.length, greaterThan(base.nodes.length));
    });
  });
}
