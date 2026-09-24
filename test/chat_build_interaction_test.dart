import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';

/// Drives the real chat screen rather than calling the logic directly: press
/// the control a user presses, and read what the user would read.
///
/// `pumpAndSettle` is deliberately avoided after a control that starts work -
/// a busy turn can carry an animation that never settles, which would time the
/// test out rather than let it assert.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

final _toolsButton =
    find.byTooltip('Tools: run, capture, and integrations');
final _buildTile = find.text('Build a .pkt from the current plan');

/// Open the tools sheet, where the capture actions now live.
Future<void> _openTools(WidgetTester tester) async {
  await tester.ensureVisible(_toolsButton);
  await tester.tap(_toolsButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the build action is reachable from the chat screen',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The reported problem was that the generator had no control at all from
    // this screen. It has one now, named, one tap away.
    expect(_toolsButton, findsOneWidget);
    await _openTools(tester);
    expect(_buildTile, findsOneWidget);
  });

  testWidgets('pressing it with no plan explains how to make one',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await _openTools(tester);
    await tester.tap(_buildTile);
    await _settle(tester);

    // The empty path, through the UI: no exception, no blank bubble.
    expect(find.textContaining('There is no plan to compile yet'),
        findsOneWidget);
    expect(find.textContaining('No API key is needed'), findsOneWidget);
  });

  testWidgets('a described network makes a plan, and the failure is readable',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The settings sidebar has text fields too, so the composer is addressed
    // by its label rather than by position.
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    expect(composer, findsOneWidget);

    // Describe a network the offline planner can parse - this is the no-key
    // path, so nothing here depends on a model or a network.
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);
    expect(find.textContaining('2 routers and 4 switches'), findsWidgets);

    // Now the action has something to compile. The sidecar is not running in
    // a test, so the honest outcome is the start-up hint - not a crash and
    // not a silent no-op.
    await _openTools(tester);
    await tester.tap(_buildTile);
    await _settle(tester);

    expect(find.textContaining('Sidecar not running'), findsOneWidget);
  });

  testWidgets('an unreachable engine is stated up front, with a way to fix it',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    // No engine is listening in a test, so the banner is expected once the
    // reachability check has run.
    await _settle(tester);

    expect(find.textContaining('No .pkt engine at'), findsOneWidget);
    expect(find.text('Set address'), findsOneWidget);
  });
}
