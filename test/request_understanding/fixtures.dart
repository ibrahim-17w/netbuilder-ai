import 'dart:ui' show Offset;

import 'package:net_builder/models/network_intent.dart';

/// A fully named, fixed two-LAN baseline used by acceptance scenarios.
NetworkIntent basePlan({String project = 'P1'}) {
  final nodes = <NetNode>[
    const NetNode(name: 'R1', type: 'router', model: '2911', exactModel: true),
    const NetNode(name: 'R2', type: 'router', model: '2911', exactModel: true),
    const NetNode(name: 'SW1', type: 'switch', model: '2960', exactModel: true),
    const NetNode(name: 'SW2', type: 'switch', model: '2960', exactModel: true),
    for (var i = 1; i <= 10; i++) NetNode(name: 'PC$i', type: 'pc'),
    const NetNode(name: 'SRV1', type: 'server', services: ['dhcp']),
    const NetNode(name: 'SRV2', type: 'server', services: ['dns']),
  ];
  final links = <NetLink>[
    const NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'g0/1'),
    const NetLink(a: 'R2', aIf: 'g0/0', b: 'SW2', bIf: 'g0/1'),
    const NetLink(
      a: 'R1',
      aIf: 's0/0/0',
      b: 'R2',
      bIf: 's0/0/0',
      cable: 'serial-dce',
      dce: 'R1',
    ),
    for (var i = 1; i <= 5; i++)
      NetLink(a: 'PC$i', aIf: 'e0', b: 'SW1', bIf: 'f0/${i + 1}'),
    for (var i = 6; i <= 10; i++)
      NetLink(a: 'PC$i', aIf: 'e0', b: 'SW2', bIf: 'f0/${i - 4}'),
    const NetLink(a: 'SRV1', aIf: 'f0', b: 'SW1', bIf: 'f0/7'),
    const NetLink(a: 'SRV2', aIf: 'f0', b: 'SW2', bIf: 'f0/7'),
  ];
  final addresses = <InterfaceAddr>[
    const InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.10.1/24'),
    const InterfaceAddr(node: 'R2', iface: 'g0/0', ipCidr: '192.168.20.1/24'),
    const InterfaceAddr(node: 'R1', iface: 's0/0/0', ipCidr: '172.16.0.1/30'),
    const InterfaceAddr(node: 'R2', iface: 's0/0/0', ipCidr: '172.16.0.2/30'),
    for (var i = 1; i <= 5; i++)
      InterfaceAddr(
        node: 'PC$i',
        iface: 'e0',
        ipCidr: '192.168.10.${10 + i}/24',
      ),
    for (var i = 6; i <= 10; i++)
      InterfaceAddr(
        node: 'PC$i',
        iface: 'e0',
        ipCidr: '192.168.20.${5 + i}/24',
      ),
    const InterfaceAddr(node: 'SRV1', iface: 'f0', ipCidr: '192.168.10.20/24'),
    const InterfaceAddr(node: 'SRV2', iface: 'f0', ipCidr: '192.168.20.20/24'),
  ];
  return NetworkIntent(
    projectName: project,
    nodes: nodes,
    links: links,
    addressing: addresses,
    routing: 'static',
    notes: const ['Acceptance fixture: fixed inventory and addressing'],
    confidence: 1,
    layout: const {
      'R1': Offset(0, 0),
      'SW1': Offset(1, 0),
      'R2': Offset(0, 1),
      'SW2': Offset(1, 1),
    },
  );
}

/// Complete redacted plan payload so a no-mutation turn cannot quietly alter
/// an address, service, port, identity, layout or other plan field.
Map<String, dynamic> semanticSnapshot(NetworkIntent plan) =>
    Map<String, dynamic>.from(plan.toPlannerJson());
