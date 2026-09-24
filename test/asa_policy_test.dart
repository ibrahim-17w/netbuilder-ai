import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';

NetworkIntent _asaIntent() {
  const intent = NetworkIntent(
    projectName: 'asa-lab',
    nodes: [
      NetNode(name: 'ASA1', type: 'firewall'),
      NetNode(name: 'R1', type: 'router'),
      NetNode(name: 'INET', type: 'cloud'),
    ],
    links: [
      NetLink(a: 'ASA1', aIf: 'g0/1', b: 'R1', bIf: 'g0/0'),
      NetLink(a: 'ASA1', aIf: 'g0/0', b: 'INET', bIf: 'e0'),
    ],
    addressing: [
      InterfaceAddr(node: 'ASA1', iface: 'g0/1', ipCidr: '192.168.1.254/24'),
      InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
      InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.0.10.1/24'),
      InterfaceAddr(node: 'ASA1', iface: 'g0/0', ipCidr: '172.16.2.1/30'),
    ],
    security: SecurityIntent(
      extendedAcl: true,
      protectedServerIp: '10.0.10.50',
      allowedWebServerIp: '10.0.10.80',
      managerIp: '172.16.9.9',
    ),
  );
  return intent;
}

void main() {
  test('ASA writes named inside policy from security intent', () {
    final cfg = CiscoAdapter.firewallConfigs(_asaIntent())['ASA1']!;
    expect(cfg, contains('access-list INSIDE_POLICY extended permit tcp any host 10.0.10.80 eq www'));
    expect(cfg, contains('access-list INSIDE_POLICY extended deny ip any host 10.0.10.50'));
    expect(cfg, contains('access-group INSIDE_POLICY in interface inside'));
  });

  test('ASA restricts management to the plan manager address', () {
    final cfg = CiscoAdapter.firewallConfigs(_asaIntent())['ASA1']!;
    expect(cfg, contains('access-list MGMT_ONLY extended permit ip host 172.16.9.9 any'));
    expect(cfg, contains('access-group MGMT_ONLY in interface outside'));
  });

  test('ASA NATs router LANs behind the outside interface', () {
    final cfg = CiscoAdapter.firewallConfigs(_asaIntent())['ASA1']!;
    expect(cfg, contains('object network INSIDE_LANS'));
    expect(cfg, contains(' subnet 10.0.10.0 255.255.255.0'));
    expect(cfg, contains(' nat (inside,outside) dynamic interface'));
  });

  test('no NAT when there is no outside link', () {
    final noCloud = NetworkIntent(
      projectName: 'no-edge',
      nodes: const [
        NetNode(name: 'ASA1', type: 'firewall'),
        NetNode(name: 'R1', type: 'router'),
      ],
      links: const [NetLink(a: 'ASA1', aIf: 'g0/1', b: 'R1', bIf: 'g0/0')],
      addressing: const [
        InterfaceAddr(node: 'ASA1', iface: 'g0/1', ipCidr: '192.168.1.254/24'),
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
      ],
      security: const SecurityIntent(extendedAcl: true, protectedServerIp: '192.168.1.9'),
    );
    final cfg = CiscoAdapter.firewallConfigs(noCloud)['ASA1']!;
    expect(cfg, isNot(contains('object network')));
  });

  test('edge router with cloud uplink gets PAT over its outside interface', () {
    final intent = NetworkIntent(
      projectName: 'edge-nat',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'CLOUD', type: 'cloud'),
      ],
      links: const [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'R1', aIf: 'g0/1', b: 'CLOUD', bIf: 'e0'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '10.0.0.1/24'),
        InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '203.0.113.2/30'),
      ],
    );
    final cfg = CiscoAdapter.render(intent)['R1']!;
    expect(cfg, contains('ip access-list standard NAT_LANS'));
    expect(cfg, contains(' permit 10.0.0.0 0.0.0.255'));
    expect(cfg, contains('ip nat inside source list NAT_LANS interface g0/1 overload'));
    expect(cfg, contains('interface g0/0'));
    expect(cfg, contains(' ip nat inside'));
    expect(cfg, contains('interface g0/1'));
    expect(cfg, contains(' ip nat outside'));
  });

  test('pure LAN router gets no NAT statements', () {
    final intent = NetworkIntent(
      projectName: 'no-edge-nat',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
      ],
      links: const [NetLink(a: 'R1', aIf: 's0/0/0', b: 'R2', bIf: 's0/0/0')],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 's0/0/0', ipCidr: '10.1.0.1/30'),
        InterfaceAddr(node: 'R2', iface: 's0/0/0', ipCidr: '10.1.0.2/30'),
      ],
    );
    final cfg = CiscoAdapter.render(intent)['R1']!;
    expect(cfg, isNot(contains('ip nat')));
  });
}
