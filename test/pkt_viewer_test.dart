import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/pkt_viewer_screen.dart';
import 'package:net_builder/widgets/topology_canvas.dart';

/// The built-in viewer: what a tap on a `.pkt` path shows when Packet Tracer
/// is not installed.
void main() {
  testWidgets('draws the plan at the given positions', (tester) async {
    const intent = NetworkIntent(
      projectName: 'office-lab',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
      ],
      links: [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PktViewerScreen(
          filePath: r'C:\pkt_output\office-lab.pkt',
          intent: intent,
          positions: const {
            'R1': Offset(400, 80),
            'SW1': Offset(400, 200),
            'PC1': Offset(400, 320),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('office-lab.pkt'), findsOneWidget);
    expect(find.text('3 devices'), findsOneWidget);
    expect(find.text('2 cables'), findsOneWidget);
    // The canvas draws the PT-style view (labels are painted, not Text
    // widgets), with the positions the build echoed.
    expect(find.byType(TopologyCanvas), findsOneWidget);
    expect(find.textContaining('Packet Tracer was not found'), findsOneWidget);
  });

  testWidgets('fits off-screen desktop coordinates into a phone preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const intent = NetworkIntent(
      projectName: 'phone-lab',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
        NetNode(name: 'PC3', type: 'pc'),
        NetNode(name: 'PC4', type: 'pc'),
      ],
      links: [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PktViewerScreen(
          filePath: '/tmp/phone-lab.pkt',
          intent: intent,
          positions: const {
            'R1': Offset(1800, 1200),
            'SW1': Offset(2200, 1500),
            'PC1': Offset(1800, 2200),
            'PC2': Offset(1950, 2200),
            'PC3': Offset(2100, 2200),
            'PC4': Offset(2250, 2200),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();

    for (final name in ['R1', 'SW1', 'PC1', 'PC2', 'PC3', 'PC4']) {
      final node = find.bySemanticsLabel(RegExp('^[^ ]+ $name\\.'));
      expect(
        node,
        findsOneWidget,
        reason: '$name should be in the fitted view',
      );
      final rect = tester.getRect(node);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.bottom, lessThanOrEqualTo(740));
    }
    semantics.dispose();
  });

  testWidgets('no plan in the conversation says so instead of guessing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PktViewerScreen(filePath: '/tmp/lab.pkt', intent: null),
      ),
    );
    expect(find.text('Nothing to draw yet'), findsOneWidget);
    expect(find.textContaining('lab.pkt'), findsWidgets);
  });
}
