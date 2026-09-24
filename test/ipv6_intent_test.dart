import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';

void main() {
  test('briefs mentioning ipv6 get dual-stack router addressing', () {
    final intent = NetworkIntent.parseSimple(
      'ipv6-lab',
      '2 routers R1 R2 connected by serial, one switch and 2 pcs on R1, ipv6',
    );
    final routerAddrs = intent.addressing.where(
      (a) => a.node.startsWith('R') || a.node.startsWith('BR'),
    );
    final routerNodes = intent.nodes
        .where((n) => n.type == 'router')
        .map((n) => n.name)
        .toSet();
    final onRouters = intent.addressing.where((a) => routerNodes.contains(a.node));
    expect(onRouters, isNotEmpty);
    expect(onRouters.every((a) => a.ip6Cidr != null), isTrue);
    expect(
      onRouters.every((a) => a.ip6Cidr!.startsWith('2001:db8:')),
      isTrue,
    );
    // Endpoints stay SLAAC-only: no spelled-out v6 address.
    final endpoints = intent.addressing.where(
      (a) => !routerNodes.contains(a.node) &&
          !intent.nodes.any((n) => n.name == a.node && n.type == 'firewall'),
    );
    expect(endpoints.every((a) => a.ip6Cidr == null), isTrue);
    expect(routerAddrs, isNotNull);
  });

  test('router config carries ipv6 unicast-routing and interface addresses',
      () {
    const intent = NetworkIntent(
      projectName: 'v6',
      nodes: [NetNode(name: 'R1', type: 'router')],
      addressing: [
        InterfaceAddr(
          node: 'R1',
          iface: 'g0/0',
          ipCidr: '10.0.0.1/24',
          ip6Cidr: '2001:db8:1::1/64',
        ),
      ],
    );
    final cfg = CiscoAdapter.render(intent)['R1']!;
    expect(cfg, contains('ipv6 unicast-routing'));
    expect(cfg, contains('ipv6 address 2001:db8:1::1/64'));
    expect(cfg, contains('ipv6 enable'));
  });

  test('no ipv6 lines when the plan has no v6 addresses', () {
    const intent = NetworkIntent(
      projectName: 'v4-only',
      nodes: [NetNode(name: 'R1', type: 'router')],
      addressing: [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '10.0.0.1/24'),
      ],
    );
    final cfg = CiscoAdapter.render(intent)['R1']!;
    expect(cfg, isNot(contains('ipv6 unicast-routing')));
  });

  test('ipv6 json roundtrip keeps ip6Cidr', () {
    const a = InterfaceAddr(
      node: 'R1',
      iface: 'g0/0',
      ipCidr: '10.0.0.1/24',
      ip6Cidr: '2001:db8:1::1/64',
    );
    final back = InterfaceAddr.fromJson(a.toJson());
    expect(back.ip6Cidr, '2001:db8:1::1/64');
    expect(InterfaceAddr.fromJson(
      {'node': 'R1', 'iface': 'g0/0', 'ipCidr': '10.0.0.1/24'},
    ).ip6Cidr, isNull);
  });
}
