import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';

void main() {
  group('generic briefs carry security intent', () {
    test('AAA in a plain brief configures BOTH ends, not just the server', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '2 routers 2 switches 4 pcs and an AAA server for centralized '
            'authentication, use tacacs+',
      );
      expect(intent.security.aaa, isTrue);
      expect(intent.security.aaaProtocol, 'tacacs+');
      expect(intent.security.aaaServer, isNotNull);
      expect(intent.security.aaaRouter, 'R1');

      // Router side: the AAA block exists and points at the server.
      final r1 = CiscoAdapter.render(intent)['R1']!;
      expect(r1, contains('aaa new-model'));
      expect(r1, contains('tacacs-server host'));
      expect(r1, contains('aaa authentication login default group tacacs+'));

      // Server side: the AAA tab carries the client entry matching the
      // router IP and the shared key the router sends.
      final aaa = PacketTracerAdapter.serverServices(intent, 'SRV1')['aaa']!;
      final clients = aaa['clients'] as List;
      expect(clients, isNotEmpty);
      expect((clients.first as Map)['serverType'], 'TACACS');
      // No key supplied: both ends agree on the documented default.
      expect((clients.first as Map)['key'], 'cisco');
    });

    test('radius is requested by name and drives both ends', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs with a radius AAA server',
      );
      expect(intent.security.aaa, isTrue);
      expect(intent.security.aaaProtocol, 'radius');
      final r1 = CiscoAdapter.render(intent)['R1']!;
      expect(r1, contains('radius-server host'));
      expect(r1, contains('group radius local'));
      final aaa = PacketTracerAdapter.serverServices(intent, 'SRV1')['aaa']!;
      expect(
        ((aaa['clients'] as List).first as Map)['serverType'],
        'RADIUS',
      );
    });

    test('an explicit shared key lands on both ends identically', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs, AAA with tacacs+ using key S3cret',
      );
      expect(intent.security.aaaPassword, 's3cret'); // lowercased with the brief
      final r1 = CiscoAdapter.render(intent)['R1']!;
      expect(r1, contains('tacacs-server key s3cret'));
      final aaa = PacketTracerAdapter.serverServices(intent, 'SRV1')['aaa']!;
      final client = (aaa['clients'] as List).first as Map;
      expect(client['key'], 's3cret');
    });
  });

  group('firewall nodes get a real ASA config', () {
    test('inside/outside, inspection and the router default route', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs with a firewall and internet access',
      );
      expect(intent.nodes.any((n) => n.type == 'firewall'), isTrue);

      final fw = CiscoAdapter.firewallConfigs(intent);
      final name = fw.keys.first;
      final cfg = fw[name]!;
      expect(cfg, contains('nameif inside'));
      expect(cfg, contains('security-level 100'));
      expect(cfg, contains('nameif outside'));
      expect(cfg, contains('security-level 0'));
      expect(cfg, contains('inspect icmp'));
      expect(cfg, contains('inspect dns preset_dns_map'));
      expect(cfg, contains('write memory'));

      // The LAN router gets a default route through the firewall.
      final r1 = CiscoAdapter.render(intent)['R1']!;
      expect(r1, contains('ip route 0.0.0.0 0.0.0.0'));
    });

    test('firewall configs ride in the autopilot plan but outside live CLI', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs with a firewall',
      );
      final plan = PacketTracerAdapter.autopilotPlan(intent);
      final cli = plan['steps'].firstWhere(
        (s) => (s as Map)['action'] == 'paste_cli',
      ) as Map;
      // Present in the saved file...
      expect((cli['configs'] as Map).keys.any((k) => k.startsWith('FW')), isTrue);
      // ...but the live executor must never type ASA at a firewall: its
      // skip list comes from the node types, and the FW node stays outside
      // cliTypes, so paste_to_device sees no FW key from deviceConfigs.
      final iosOnly = CiscoAdapter.render(intent).keys.toList();
      expect(iosOnly.any((k) => k.startsWith('FW')), isFalse);
    });
  });

  group('new server service params', () {
    test('dhcpv6 plans a stateful pool on the server LAN', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs and SRV1 with dhcpv6',
      );
      final v6 = PacketTracerAdapter.serverServices(
        intent,
        'SRV1',
      )['dhcpv6']!;
      expect(v6['pools'], isNotEmpty);
      expect(((v6['pools'] as List).first as Map)['prefixLength'], '64');
    });

    test('snmp gets communities and the server IP as agent', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs and SRV1 with snmp',
      );
      final snmp = PacketTracerAdapter.serverServices(intent, 'SRV1')['snmp']!;
      expect(snmp['readCommunity'], 'public');
      expect(snmp['writeCommunity'], 'private');
      expect(snmp['agentIp'], isNot('0.0.0.0'));
    });

    test('iot enables the registration server with an account', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs and SRV1 as the iot registration server',
      );
      final iot = PacketTracerAdapter.serverServices(intent, 'SRV1')['iot']!;
      expect(iot['registration'], isTrue);
      expect((iot['users'] as List), isNotEmpty);
    });
  });
}
