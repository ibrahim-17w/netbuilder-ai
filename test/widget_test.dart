import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/main.dart';
import 'package:net_builder/models/chat_message.dart';

/// The shell is one screen. These replace the old tab-based tests: there are
/// no tabs, no floating controls and no separate settings page any more.
void main() {
  testWidgets('App boots to the single chat screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.textContaining('Network Engineer'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('the composer offers one media picker, with every option',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // One picker instead of a row of icons: this is the ChatGPT-shaped
    // composer the redesign asked for.
    expect(find.byTooltip('Attach'), findsOneWidget);
    expect(find.byTooltip('Tools: run, capture, and integrations'),
        findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);

    // Every way of attaching something is still reachable, by name.
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    expect(find.text('Photo or image file'), findsOneWidget);
    expect(find.text('Screenshot from the run'), findsOneWidget);
    expect(find.text('Packet Tracer save (.pkt)'), findsOneWidget);
    expect(find.text('Paste clipboard text'), findsOneWidget);
  });

  test('the offline capture actions are part of the action whitelist', () {
    // An unknown kind is dropped rather than given an executor; these four
    // are the ones the chat is allowed to run offline.
    for (final kind in ['pkt_scan', 'pkt_fix', 'pkt_undo', 'ledger']) {
      expect(ChatAction.supported.contains(kind), isTrue, reason: kind);
    }
    final parsed = ChatAction.parseList([
      {'kind': 'pkt_fix', 'device': 'R1', 'id': 'x'},
      {'kind': 'not_a_real_kind'},
    ]);
    expect(parsed.length, 1);
    expect(parsed.single.kind, 'pkt_fix');
    expect(parsed.single.payload['device'], 'R1');
  });
}
