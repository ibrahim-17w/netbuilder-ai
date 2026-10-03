import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// The redesigned chat makes the parser's understanding visible: an
/// "Understood" card under the latest user turn, chips for what it plans,
/// and the planner's open questions as tappable chips. These tests pin
/// that contract - the card appears when a turn parses, never wears an
/// older turn's plan, and a question chip fills the composer instead of
/// sending on the user's behalf.
Widget _app() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>(create: (_) => SettingsService()),
    ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
  ],
  child: const NetBuilderApp(),
);

/// A busy turn can carry an animation that never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Finder _composer() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Message',
);

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_composer(), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await _settle(tester);
}

void main() {
  testWidgets('a parsed turn shows what was understood, as chips',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _send(tester, '2 routers and 4 switches');

    expect(find.text('Understood'), findsOneWidget);
    expect(find.text('2 routers'), findsOneWidget);
    expect(find.text('4 switches'), findsOneWidget);
    // The parser says how sure it is, in numbers.
    expect(find.textContaining('%'), findsWidgets);
  });

  testWidgets('a sized brief shows its VLANs and its open questions',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _send(tester, '10 employees and two floors, build the network');

    expect(find.text('Understood'), findsOneWidget);
    expect(find.text('10 PCs'), findsOneWidget);
    expect(find.text('VLAN 10'), findsOneWidget);
    expect(find.text('VLAN 20'), findsOneWidget);
    expect(find.text('Worth confirming:'), findsOneWidget);
  });

  testWidgets('a question chip fills the composer and does not send',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _send(tester, '10 employees and two floors, build the network');

    const question = 'Should guests be blocked from the staff VLAN by an ACL?';
    expect(find.text(question), findsOneWidget);
    await tester.tap(find.text(question));
    // Bounded pumps, not pumpAndSettle: the turn is still "Thinking..."
    // and its indeterminate progress bar never stops animating.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final composer = tester.widget<TextField>(_composer());
    expect(composer.controller!.text, question);
  });

  testWidgets('a declined turn never wears an older turn\'s plan',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _send(tester, '2 routers and 4 switches');
    expect(find.text('Understood'), findsOneWidget);

    // End the in-flight turn the way a user would - the send button is a
    // Stop button while busy - because the test env has no provider to
    // answer it and the composer stays locked until the turn ends.
    await tester.tap(find.byIcon(Icons.stop).first);
    await tester.pumpAndSettle();

    await _send(tester, 'write me a python script to sort a list');
    // The coding request is declined and never parsed, so the card from
    // the previous turn must not appear under it.
    expect(find.text('Understood'), findsNothing);
  });
}
