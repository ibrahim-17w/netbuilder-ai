import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/widgets/topology_canvas.dart';

NetworkIntent _intent() => NetworkIntent(
      projectName: 'office',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
        NetNode(name: 'SRV1', type: 'server', services: ['dhcp', 'dns']),
      ],
      links: [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'PC1', aIf: 'f0', b: 'SW1', bIf: 'f0/2'),
        NetLink(a: 'PC2', aIf: 'f0', b: 'SW1', bIf: 'f0/3'),
        NetLink(a: 'SRV1', aIf: 'f0', b: 'SW1', bIf: 'f0/4'),
      ],
      addressing: [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
        InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.1.10/24'),
        InterfaceAddr(node: 'PC2', iface: 'f0', ipCidr: '192.168.1.11/24'),
        InterfaceAddr(node: 'SRV1', iface: 'f0', ipCidr: '192.168.1.20/24'),
      ],
    );

void main() {
  test('layout puts distinct nodes at distinct positions and keeps layers',
      () {
    final intent = _intent();
    final positions = layoutPlan(intent, const Size(800, 600));
    expect(positions.keys, containsAll(['R1', 'SW1', 'PC1', 'SRV1']));
    // router above switch above pcs
    expect(positions['R1']!.dy, lessThan(positions['SW1']!.dy));
    expect(positions['SW1']!.dy, lessThan(positions['PC1']!.dy));
    // distinct x on the same layer
    expect(positions['PC1']!.dx, isNot(equals(positions['PC2']!.dx)));
    // deterministic
    final again = layoutPlan(intent, const Size(800, 600));
    expect(again['R1'], positions['R1']);
  });

  test('plan-supplied layout wins over auto layout', () {
    final intent = _intent().copyWith(layout: {
      'PC2': const Offset(777, 111),
    });
    final positions = layoutPlan(intent, const Size(800, 600));
    expect(positions['PC2'], const Offset(777, 111));
    // other nodes still laid out
    expect(positions.containsKey('R1'), isTrue);
  });

  test('layout roundtrips through toJson/fromJson', () {
    final intent = _intent().copyWith(layout: {
      'R1': const Offset(120, 80),
      'PC1': null,
    });
    final json = intent.toJson();
    final restored = NetworkIntent.fromJson(json);
    expect(restored.layout['R1'], const Offset(120, 80));
    expect(restored.layout.containsKey('PC1'), isTrue);
    expect(restored.layout['PC1'], isNull);
  });

  test('vlanAssignments numbers subnets deterministically', () {
    final vlans = vlanAssignments(_intent());
    expect(vlans['R1'], 1);
    expect(vlans['PC1'], 1);
    expect(vlans['SRV1'], 1);
  });

  testWidgets('canvas renders nodes and supports tap to inspect',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TopologyCanvas(intent: _intent()),
        ),
      ),
    ));
    // CustomPaint exists (at least ours)
    expect(find.byType(CustomPaint), findsWidgets);

    // tap where the canvas places R1 (layout is deterministic at this size)
    final positions = layoutPlan(_intent(), const Size(800, 600));
    await tester.tapAt(positions['R1']!);
    await tester.pumpAndSettle();
    // inspector bottom sheet shows the node name and its interface
    expect(find.text('R1'), findsOneWidget);
    expect(find.textContaining('g0/0'), findsOneWidget);
  });
}
