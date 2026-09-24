import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/main.dart';

/// The capture flow lives IN the chat: there is no other screen to open.
void main() {
  testWidgets('the capture flow is part of the single chat screen',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    // Attach a .pkt, ask about it, and act on the answer - all in one place.
    // Attaching lives behind the single media picker, and the capture actions
    // live behind the tools control; neither needs another screen.
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.textContaining('Context '), findsOneWidget);

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    expect(find.text('Packet Tracer save (.pkt)'), findsOneWidget);
    expect(find.byIcon(Icons.router_outlined), findsWidgets);
  });

  testWidgets('the tools sheet reaches the capture actions', (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
    await tester.pumpAndSettle();
    expect(find.text('Analyze a .pkt'), findsOneWidget);
    expect(find.text('Build a .pkt from the current plan'), findsOneWidget);
  });
}
