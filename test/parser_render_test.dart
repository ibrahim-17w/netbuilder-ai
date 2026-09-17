import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/rule_packs_service.dart';

void main() {
  test('parses the lab prompt into explicit links + correct addressing', () {
    const instr = '''
Build a small lab network with 2 routers (2911), 2 switches (2960) and 2 PCs.
R1 and R2 connect to each other using GigabitEthernet0/1 on both sides.
R1 GigabitEthernet0/0 connects to SW1 FastEthernet0/1.
R2 GigabitEthernet0/0 connects to SW2 FastEthernet0/1.
PC1 connects to SW1 FastEthernet0/2, PC2 connects to SW2 FastEthernet0/2.
Use 192.168.1.0/30 on the R1-R2 link, 192.168.10.0/24 on the SW1 side and
192.168.20.0/24 on the SW2 side. Run OSPF area 0 on both routers for all
networks. Set hostnames R1, R2, SW1, SW2, disable domain lookup, encrypt
passwords, and save with write memory.''';

    final intent = NetworkIntent.parseSimple('lab', instr);

    expect(
      intent.links.map((l) => '${l.a}:${l.aIf}<->${l.b}:${l.bIf}'),
      containsAll([
        'R1:g0/1<->R2:g0/1',
        'R1:g0/0<->SW1:f0/1',
        'R2:g0/0<->SW2:f0/1',
        'SW1:f0/2<->PC1:f0',
        'SW2:f0/2<->PC2:f0',
      ]),
    );

    final addrs = intent.addressing
        .map((a) => '${a.node}:${a.iface}=${a.ipCidr}')
        .toList();
    expect(addrs, contains('R1:g0/1=192.168.1.1/30'));
    expect(addrs, contains('R2:g0/1=192.168.1.2/30'));
    expect(addrs, contains('R1:g0/0=192.168.10.1/24'));
    expect(addrs, contains('R2:g0/0=192.168.20.1/24'));
    // PCs get .10 of their switch's LAN subnet
    expect(addrs, contains('PC1:f0=192.168.10.10/24'));
    expect(addrs, contains('PC2:f0=192.168.20.10/24'));

    // the plan carries a config_pcs step with ip/mask/gateway per PC
    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final pcsStep =
        plan['steps']!.firstWhere((s) => (s as Map)['action'] == 'config_pcs')
            as Map;
    expect((pcsStep['pcs'] as Map)['PC1'], {
      'ip': '192.168.10.10',
      'mask': '255.255.255.0',
      'gw': '192.168.10.1',
    });
    expect((pcsStep['pcs'] as Map)['PC2'], {
      'ip': '192.168.20.10',
      'mask': '255.255.255.0',
      'gw': '192.168.20.1',
    });

    final r1 = CiscoAdapter.render(intent)['R1']!;
    expect(r1, contains('interface g0/1'));
    expect(r1, contains('ip address 192.168.1.1 255.255.255.252'));
    expect(r1, contains('network 192.168.1.0 0.0.0.3 area 0'));
    expect(r1, contains('network 192.168.10.0 0.0.0.255 area 0'));
    expect(r1, contains('no shutdown'));

    // PCs are excluded from CLI configs entirely
    expect(CiscoAdapter.render(intent).containsKey('PC1'), isFalse);
  });

  test('servers get links, LAN addressing and Desktop IP config, no CLI', () {
    const instr = '''
Build a network with 1 router, 1 switch, 1 PC and 1 server on
192.168.10.0/24.
R1 GigabitEthernet0/1 connects to SW1 FastEthernet0/1.
PC1 connects to SW1 FastEthernet0/2. SRV1 connects to SW1 FastEthernet0/4.''';

    final intent = NetworkIntent.parseSimple('srvlab', instr);

    expect(
      intent.nodes.map((n) => '${n.name}:${n.type}:${n.model}'),
      contains('SRV1:server:Server-PT'),
    );

    expect(
      intent.links.map((l) => '${l.a}:${l.aIf}<->${l.b}:${l.bIf}'),
      contains('SW1:f0/4<->SRV1:f0'),
    );

    final addrs = intent.addressing
        .map((a) => '${a.node}:${a.iface}=${a.ipCidr}')
        .toList();
    // server shares the LAN pool with the PC, next free host
    expect(addrs, contains('PC1:f0=192.168.10.10/24'));
    expect(addrs, contains('SRV1:f0=192.168.10.11/24'));

    // the plan carries the server in config_pcs with ip/mask/gateway
    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final pcsStep =
        plan['steps']!.firstWhere((s) => (s as Map)['action'] == 'config_pcs')
            as Map;
    expect((pcsStep['pcs'] as Map)['SRV1'], {
      'ip': '192.168.10.11',
      'mask': '255.255.255.0',
      'gw': '192.168.10.1',
    });

    // servers are excluded from CLI configs like PCs (Desktop IP only)
    expect(CiscoAdapter.render(intent).containsKey('SRV1'), isFalse);
  });

  test('server roles parse into services with derived params + plan step', () {
    const instr = '''
Build a network with 1 router, 1 switch and 1 server on 192.168.10.0/24.
R1 GigabitEthernet0/1 connects to SW1 FastEthernet0/1.
SRV1 connects to SW1 FastEthernet0/2. SRV1 is the DHCP and DNS server.''';

    final intent = NetworkIntent.parseSimple('svcs', instr);
    final srv = intent.nodes.firstWhere((n) => n.name == 'SRV1');
    expect(srv.services, containsAll(['dhcp', 'dns']));

    final svc = PacketTracerAdapter.serverServices(intent, 'SRV1');
    expect(svc['dhcp'], {
      'gateway': '192.168.10.1',
      'dnsServer': '192.168.10.10', // serves its own DNS
      'startIp': '192.168.10.100',
      'mask': '255.255.255.0',
      'maxUsers': '100',
    });
    expect(
      (svc['dns']!['records'] as List).any(
        (row) => row['name'] == 'srv1' && row['address'] == '192.168.10.10',
      ),
      isTrue,
    );

    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final srvStep =
        plan['steps']!.firstWhere(
              (s) => (s as Map)['action'] == 'config_servers',
            )
            as Map;
    expect(
      ((srvStep['servers'] as Map)['SRV1'] as Map)['services'],
      contains('dhcp'),
    );
  });

  test('server service rules parse into deterministic build parameters', () {
    const instr = '''
Build a network with 1 router, 1 switch and 1 server on 192.168.10.0/24.
R1 GigabitEthernet0/1 connects to SW1 FastEthernet0/1.
SRV1 connects to SW1 FastEthernet0/2. SRV1 provides DNS and FTP.
DNS records: r1.lab -> 192.168.10.1, srv1.lab -> 192.168.10.10.
FTP user alice password test123.''';

    final intent = NetworkIntent.parseSimple('service-rules', instr);
    final srv = intent.nodes.firstWhere((n) => n.name == 'SRV1');
    expect(srv.services, containsAll(['dns', 'ftp']));
    final records = (srv.serviceRules['dns'] as Map)['records'] as List;
    expect(
      records.any(
        (row) => row['name'] == 'r1.lab' && row['address'] == '192.168.10.1',
      ),
      isTrue,
    );
    expect(((srv.serviceRules['ftp'] as Map)['users'] as List).single, {
      'username': 'alice',
      'password': 'test123',
    });

    final services = PacketTracerAdapter.serverServices(intent, 'SRV1');
    expect((services['dns']!['records'] as List).length, 2);
    expect((services['ftp']!['users'] as List).single['username'], 'alice');
    expect(services['ftp']!['verification'], 'rules');
  });

  test(
    'planner export removes service passwords but execution export keeps them',
    () {
      const node = NetNode(
        name: 'SRV1',
        type: 'server',
        services: ['ftp'],
        serviceRules: {
          'ftp': {
            'users': [
              {'username': 'alice', 'password': 'secret'},
            ],
          },
        },
      );
      final intent = NetworkIntent(projectName: 'safe', nodes: const [node]);
      expect(
        intent
            .toJson()['nodes'][0]['serviceRules']['ftp']['users'][0]['password'],
        'secret',
      );
      expect(
        intent
            .toPlannerJson()['nodes'][0]['serviceRules']['ftp']['users'][0]
            .containsKey('password'),
        isFalse,
      );
    },
  );

  test('security branch brief becomes executable controls and live checks', () {
    const instr = '''
Build a headquarters and branch network connected over a public WAN.
Use HQ_Router and BR_Router, HQ_Switch and BR_Switch. Add an AAA Server,
DHCP Server and web server. Enable port security on all user ports with one
MAC and shutdown violations. Enable DHCP snooping with the router-facing
port trusted. Use TACACS+ and Telnet on the HQ router. Only manager device
192.168.1.50 may access VTY during office hours. Use an extended ACL so
branch devices cannot reach the AAA server but may reach the HQ HTTP server.
Build an IPSec site-to-site VPN between 192.168.1.0/24 and 192.168.2.0/24
using AES and SHA. Test the controls after building.''';

    final intent = NetworkIntent.parseSimple('security-lab', instr);
    expect(
      intent.nodes.map((n) => n.name),
      containsAll([
        'HQ_Router',
        'BR_Router',
        'HQ_Switch',
        'BR_Switch',
        'AAA1',
        'DHCP1',
        'WEB1',
        'MGR1',
        'HQ_PC1',
        'BR_PC1',
      ]),
    );
    expect(intent.security.portSecurity, isTrue);
    expect(intent.security.dhcpSnooping, isTrue);
    expect(intent.security.aaa, isTrue);
    expect(intent.security.extendedAcl, isTrue);
    expect(intent.security.ipsecVpn, isTrue);
    expect(intent.security.vpnEncryption, 'aes');
    expect(intent.security.vpnHash, 'sha');
    expect(intent.security.tests.length, greaterThan(3));
    expect(
      intent.questions,
      isNotEmpty,
    ); // secrets and serial module are absent

    final hq = CiscoAdapter.render(intent)['HQ_Router']!;
    final branch = CiscoAdapter.render(intent)['BR_Router']!;
    final sw = CiscoAdapter.render(intent)['HQ_Switch']!;
    expect(hq, contains('aaa new-model'));
    expect(hq, contains('VTY_MANAGER_ONLY'));
    expect(hq, contains('crypto isakmp policy 10'));
    expect(branch, contains('BRANCH_TO_HQ'));
    expect(sw, contains('switchport port-security maximum 1'));
    expect(sw, contains('ip dhcp snooping trust'));

    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final securityStep =
        (plan['steps'] as List).firstWhere(
              (s) => (s as Map)['action'] == 'verify_security',
            )
            as Map;
    expect((securityStep['checks'] as List).length, greaterThan(5));
    final dhcp = PacketTracerAdapter.serverServices(intent, 'DHCP1')['dhcp']!;
    expect(dhcp['pools'], hasLength(2));
    final aaa = PacketTracerAdapter.serverServices(intent, 'AAA1')['aaa']!;
    expect(aaa['users'], isEmpty); // no credentials are invented
  });

  test('complete all-features brief keeps SRV1, OSPF, and service rules', () {
    const instr = '''
Build a network named all-features-lab. Use HQ_Router and BR_Router, Cisco
2911; HQ_Switch and BR_Switch, Cisco 2960; AAA1 providing TACACS+; DHCP1
providing DHCP; WEB1 providing HTTP and HTTPS; and SRV1 providing DNS, FTP,
email, NTP, and TFTP. Connect HQ_Switch FastEthernet0/7 to SRV1 and use
192.168.1.103 for SRV1. Use OSPF area 0 on both routers. DNS records:
hq-router.lab -> 192.168.1.1, br-router.lab -> 192.168.2.1,
web.lab -> 192.168.1.102, srv.lab -> 192.168.1.103. TACACS+ username
labadmin with password LabAdmin2026. FTP user testuser with password
FtpTest2026. Email domain all-features.lab. Office hours weekdays
08:00-17:00. Use IPSec with pre-shared key NetBuilderLab2026, AES, and SHA.
''';

    final intent = NetworkIntent.parseSimple('all-features-lab', instr);
    expect(intent.nodes, hasLength(11));
    expect(intent.routing, 'ospf');
    final srv = intent.nodes.firstWhere((n) => n.name == 'SRV1');
    expect(srv.services, containsAll(['dns', 'ftp', 'email', 'ntp', 'tftp']));
    expect(
      intent.links.any(
        (link) =>
            link.a == 'HQ_Switch' &&
            link.aIf == 'f0/7' &&
            link.b == 'SRV1' &&
            link.bIf == 'f0',
      ),
      isTrue,
    );
    expect(
      intent.addressing.any(
        (addr) =>
            addr.node == 'SRV1' &&
            addr.iface == 'f0' &&
            addr.ipCidr == '192.168.1.103/24',
      ),
      isTrue,
    );
    expect(CiscoAdapter.render(intent)['HQ_Router'], contains('router ospf 1'));
    expect(intent.questions, isEmpty);

    final dhcp = PacketTracerAdapter.serverServices(intent, 'DHCP1')['dhcp']!;
    expect(
      (dhcp['pools'] as List).every(
        (pool) => (pool as Map)['dnsServer'] == '192.168.1.103',
      ),
      isTrue,
    );
    expect(
      PacketTracerAdapter.serverServices(intent, 'WEB1')['http']!['https'],
      isTrue,
    );
    final dns = PacketTracerAdapter.serverServices(intent, 'SRV1')['dns']!;
    expect((dns['records'] as List), hasLength(4));
    final ftp = PacketTracerAdapter.serverServices(intent, 'SRV1')['ftp']!;
    expect((ftp['users'] as List).single['username'], 'testuser');
    expect(
      PacketTracerAdapter.serverServices(intent, 'SRV1')['email']!['domain'],
      'all-features.lab',
    );
  });

  test('a serial WAN plan carries the cable, the DCE end and the clock rate',
      () {
    const instr = '''
Build a network with 2 routers, 2 switches and 2 PCs. The routers are joined
by a back-to-back serial WAN. Use 10.1.1.0/30 on the WAN, 192.168.1.0/24
for R1 and 192.168.2.0/24 for R2.''';

    final intent = NetworkIntent.parseSimple('wan', instr);
    final wan = intent.links.firstWhere((l) => l.isSerial);
    expect(wan.aIf, 's0/0/0');
    expect(wan.bIf, 's0/0/0');
    expect(wan.cable, 'serial');
    expect(wan.dceEnd, 'a');
    expect(
      intent.addressing
          .map((a) => '${a.node}:${a.iface}=${a.ipCidr}')
          .toList(),
      containsAll([
        'R1:s0/0/0=10.1.1.1/30',
        'R2:s0/0/0=10.1.1.2/30',
      ]),
    );

    // the plan tells the executor which cable and which clocking end
    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final linksStep = (plan['steps'] as List)
        .firstWhere((s) => (s as Map)['action'] == 'create_links') as Map;
    final wanJson = (linksStep['links'] as List)
        .cast<Map>()
        .firstWhere((l) => l['aIf'] == 's0/0/0');
    expect(wanJson['cable'], 'serial');
    expect(wanJson['dce'], 'a');

    // ONE clock rate, on the DCE side only: PT rejects it on the DTE end
    final r1 = CiscoAdapter.render(intent)['R1']!;
    final r2 = CiscoAdapter.render(intent)['R2']!;
    expect(r1, contains('interface s0/0/0'));
    expect(r1, contains('clock rate 64000'));
    expect(r2, contains('interface s0/0/0'));
    expect(r2, isNot(contains('clock rate')),
        reason: 'the DTE end must not carry a clock rate');
    expect(
      intent.assumptions.any((a) => a.contains('clocking (DCE) end')),
      isTrue,
      reason: 'the serial WAN assumption must be stated',
    );
  });

  test('the device catalog adds edge, wireless and telephony devices', () {
    const instr = '''
Build a small office network: 1 router, 1 switch, 1 firewall, 1 cloud, 1
wireless access point, 2 IP phones, 1 laptop and 1 printer. 2 tablets and
1 smartphone join over wireless.''';

    final intent = NetworkIntent.parseSimple('office', instr);
    final types = intent.nodes.map((n) => n.type).toSet();
    expect(types.containsAll([
      'router',
      'switch',
      'firewall',
      'cloud',
      'wireless',
      'phone',
      'laptop',
      'printer',
      'tablet',
      'smartphone',
    ]), isTrue, reason: types.toString());
    expect(
      intent.nodes.firstWhere((n) => n.type == 'firewall').model,
      '5506',
    );
    expect(
      intent.nodes.firstWhere((n) => n.type == 'wireless').model,
      'AccessPoint-PT',
    );

    // the firewall sits between the router and the internet edge
    expect(
      intent.links.any((l) => l.a == 'R1' && l.b == 'FW1'),
      isTrue,
      reason: intent.links.map((l) => '${l.a}<->${l.b}').toString(),
    );
    expect(
      intent.links.any((l) => l.a == 'FW1' && l.b == 'CLOUD1'),
      isTrue,
    );
    // phones and access points cable on their own port names, not 'f0'
    expect(
      intent.links.any(
        (l) =>
            (l.b == 'AP1' && l.bIf == 'port1') ||
            (l.a == 'AP1' && l.aIf == 'port1'),
      ),
      isTrue,
    );
    expect(intent.links.any((l) => l.a == 'PH1' || l.b == 'PH1'), isTrue);
    // wireless-only clients are never cabled
    for (final name in const ['TAB1', 'TAB2', 'SP1']) {
      expect(
        intent.links.any((l) => l.a == name || l.b == name),
        isFalse,
        reason: '$name must associate wirelessly, not by cable',
      );
    }

    // only router/switch kinds get CLI configuration
    final cfg = CiscoAdapter.render(intent);
    expect(cfg.containsKey('R1'), isTrue);
    for (final name in const ['FW1', 'CLOUD1', 'AP1', 'PH1', 'LT1', 'PRN1']) {
      expect(cfg.containsKey(name), isFalse, reason: '$name has no IOS CLI');
    }

    // ...while the IP-configured kinds reach Desktop > IP Configuration
    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final pcsStep = (plan['steps'] as List)
        .firstWhere((s) => (s as Map)['action'] == 'config_pcs') as Map;
    expect(
      (pcsStep['pcs'] as Map).keys,
      containsAll(['LT1', 'PRN1']),
    );
    expect((pcsStep['pcs'] as Map).containsKey('PH1'), isFalse);
    expect((pcsStep['pcs'] as Map).containsKey('AP1'), isFalse);
    expect(
      intent.assumptions.any((a) => a.contains('ASA')),
      isTrue,
      reason: 'the firewall\'s manual config must be disclosed',
    );
  });

  test('device keywords are word-bounded: a laptop is not an access point',
      () {
    const instr =
        'Build 1 router, 1 switch and 1 laptop on 192.168.5.0/24.';
    final intent = NetworkIntent.parseSimple('kw', instr);
    final types = intent.nodes.map((n) => n.type).toList();
    expect(types, contains('laptop'));
    expect(types, isNot(contains('wireless')));
    expect(types, isNot(contains('wireless-router')));

    expect(deviceKindFor('access point')!.type, 'wireless');
    expect(deviceKindFor('wireless controller')!.type, 'wlc');
    expect(deviceKindFor('nonsense'), isNull);
    expect(devicePrefix('firewall'), 'FW');
    expect(devicePrefix('cloud'), 'CLOUD');
  });

  test('the rule packs carry the serial WAN and device-surface rules', () {
    final ids = RulePacksService.packs.map((p) => p.id).toList();
    expect(ids, containsAll(['pt-02', 'pt-03', 'pt-04', 'pt-05']));
    expect(ids, containsAll(['core-04', 'core-05']));
    final serial = RulePacksService.packs.firstWhere((p) => p.id == 'pt-02');
    expect(serial.targets, contains('packet-tracer'));
    expect(serial.rule, contains('Serial0/0/0'));
    expect(serial.rule, contains('DCE'));
  });

  test('rule pack ids are unique and non-empty', () {
    final ids = RulePacksService.packs.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate pack id');
    for (final p in RulePacksService.packs) {
      expect(p.id, isNotEmpty);
      expect(p.targets, isNotEmpty, reason: '${p.id} has no targets');
      expect(p.rule.trim(), isNotEmpty, reason: '${p.id} has an empty rule');
      expect(
        p.rule.trim().length,
        greaterThan(20),
        reason: '${p.id} is too vague to steer the planner',
      );
    }
  });

  test('severities and targets stay inside what the app understands', () {
    const knownTargets = {
      'all',
      'gns3',
      'cisco-ssh',
      'packet-tracer',
      'aws-vpc',
    };
    for (final p in RulePacksService.packs) {
      expect(
        p.targets.every(knownTargets.contains),
        isTrue,
        reason: '${p.id} targets ${p.targets} - unknown target',
      );
    }
  });

  test('expanded packs cover the key planner concerns per family', () {
    final byId = {for (final p in RulePacksService.packs) p.id: p};
    // Addressing family: gateway/host placement, loopbacks, VLAN numbering.
    for (final id in ['core-06', 'core-07', 'core-08', 'core-10', 'core-11']) {
      expect(byId, contains(id), reason: 'missing core addressing rule $id');
    }
    // IOS family: hardening, VTY, ports/trunking, ACL, NAT, DHCP, inter-VLAN.
    for (final id in [
      'cisco-04', 'cisco-05', 'cisco-06', 'cisco-09',
      'cisco-10', 'cisco-11', 'cisco-12',
    ]) {
      expect(byId, contains(id), reason: 'missing IOS rule $id');
    }
    // PT executor reality: cabling kinds, port roles, security placement,
    // ASA security levels, IPSec symmetry, AP/VLAN, evidence rule.
    for (final id in [
      'pt-06', 'pt-07', 'pt-08', 'pt-09', 'pt-10', 'pt-11', 'pt-12', 'pt-13',
    ]) {
      expect(
        byId[id]!.targets,
        contains('packet-tracer'),
        reason: '$id must target packet-tracer',
      );
    }
    // Security obligations and AWS routing split.
    expect(byId['sec-02']!.rule, contains('never'));
    expect(byId['aws-02']!.rule, contains('NAT'));
    expect(byId['val-01']!.severity, 'block');
    expect(byId['val-02']!.severity, 'warn');
  });

  test('every embedded pack is mirrored into an asset yaml', () {
    // The asset files are the user-editable mirror of the embedded packs.
    // Read them straight off disk (no rootBundle) so this gate runs in the
    // plain dart test VM.
    final assetDir = Directory('assets/rule_packs');
    expect(assetDir.existsSync(), isTrue);
    final yamlText = assetDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    final assetIds = RegExp(r'- id:\s*(\S+)')
        .allMatches(yamlText)
        .map((m) => m.group(1)!)
        .toSet();
    final dartIds = RulePacksService.packs.map((p) => p.id).toSet();
    expect(
      assetIds.containsAll(dartIds),
      isTrue,
      reason:
          'packs missing from assets/rule_packs: '
          '${dartIds.difference(assetIds).toList()} - add them to the yaml',
    );
    expect(
      dartIds.containsAll(assetIds),
      isTrue,
      reason:
          'asset rules missing from RulePacksService.packs: '
          '${assetIds.difference(dartIds).toList()} - embed them in Dart',
    );
    // Spot-check the rule TEXT traveled too, not just the id.
    final core06 = RulePacksService.packs.firstWhere((p) => p.id == 'core-06');
    expect(yamlText, contains('core-06'));
    final sec01 = RulePacksService.packs.firstWhere((p) => p.id == 'sec-01');
    expect(yamlText, contains(sec01.rule.substring(0, 40)));
    expect(yamlText, contains(core06.rule.substring(0, 40)));
  });
}
