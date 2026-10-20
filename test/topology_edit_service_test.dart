import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/topology_edit_service.dart';

void main() {
  NetworkIntent plan() => NetworkIntent(
    projectName: 'multi-interface',
    nodes: const [
      NetNode(name: 'R1', type: 'router', model: '2911'),
      NetNode(name: 'SW1', type: 'switch'),
    ],
    links: const [
      NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1', dce: 'R1'),
    ],
    addressing: const [
      InterfaceAddr(
        node: 'R1',
        iface: 'g0/0',
        ipCidr: '192.168.1.1/24',
        ip6Cidr: '2001:db8:1::1/64',
      ),
      InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.0.0.1/30'),
      InterfaceAddr(node: 'SW1', iface: 'vlan1', ipCidr: '192.168.1.2/24'),
    ],
    security: const SecurityIntent(
      aaa: true,
      aaaServer: 'R1',
      aaaRouter: 'R1',
      vpnPeerA: 'R1',
    ),
    layout: const {'R1': Offset(20, 30), 'SW1': Offset(200, 30)},
  );

  test('rename and primary address edit retain every other interface', () {
    final edited = TopologyEditService.editDevice(
      intent: plan(),
      oldName: 'R1',
      newName: 'Core',
      primaryIpv4: '192.168.1.254/24',
      fallbackInterface: 'g0/0',
    );

    expect(edited.addressing.map((a) => a.toJson()).toList(), [
      {
        'node': 'Core',
        'iface': 'g0/0',
        'ipCidr': '192.168.1.254/24',
        'ip6Cidr': '2001:db8:1::1/64',
      },
      {'node': 'Core', 'iface': 'g0/1', 'ipCidr': '10.0.0.1/30'},
      {'node': 'SW1', 'iface': 'vlan1', 'ipCidr': '192.168.1.2/24'},
    ]);
    expect(edited.links.single.a, 'Core');
    expect(edited.links.single.dce, 'Core');
    expect(edited.layout['Core'], const Offset(20, 30));
    expect(edited.layout.containsKey('R1'), isFalse);
    expect(edited.security.aaaServer, 'Core');
    expect(edited.security.aaaRouter, 'Core');
    expect(edited.security.vpnPeerA, 'Core');
  });

  test('clearing primary IPv4 keeps secondary IPv4 and IPv6 data', () {
    final edited = TopologyEditService.editDevice(
      intent: plan(),
      oldName: 'R1',
      newName: 'R1',
      primaryIpv4: '',
      fallbackInterface: 'g0/0',
    );

    expect(edited.addressing.map((a) => a.toJson()).toList(), [
      {'node': 'R1', 'iface': 'g0/1', 'ipCidr': '10.0.0.1/30'},
      {'node': 'SW1', 'iface': 'vlan1', 'ipCidr': '192.168.1.2/24'},
    ]);
  });

  test('adds a primary address when the device had none', () {
    final edited = TopologyEditService.editDevice(
      intent: plan().copyWith(addressing: const []),
      oldName: 'R1',
      newName: 'R1',
      primaryIpv4: '192.168.1.1/24',
      fallbackInterface: 'g0/0',
    );
    expect(edited.addressing.single.iface, 'g0/0');
    expect(edited.addressing.single.ipCidr, '192.168.1.1/24');
  });
}
