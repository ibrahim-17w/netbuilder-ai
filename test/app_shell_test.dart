import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/screens/home_screen.dart';
import 'package:net_builder/screens/new_build_screen.dart';
import 'package:net_builder/screens/settings_screen.dart';
import 'package:net_builder/widgets/action_hub.dart';

/// The hub's own search field. Addressed by its label because the chat
/// composer sits behind the dialog and is also a TextField.
Finder _hubSearch() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Find a feature',
);

/// A busy turn can carry an animation that never settles, so tests that start
/// work pump a fixed number of frames instead of waiting for stillness.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// main() installs the providers and a widget test does not call it, so the
/// shell is mounted the same way it is in the app.
Widget _app() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>(create: (_) => SettingsService()),
    ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
  ],
  child: const NetBuilderApp(),
);

Future<void> _desktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the desktop rail offers every screen by name', (tester) async {
    await _desktop(tester);

    // Each of these was a screen with no way in before the rail existed.
    for (final label in const [
      'Chat',
      'New build',
      'Analyze and fix',
      'Packet Tracer files',
      'Saved networks',
      'Memory and learning',
      'Settings',
    ]) {
      expect(
        find.text(label),
        findsWidgets,
        reason: '"$label" must be reachable by name',
      );
    }
    expect(find.text('All features'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail actually moves between screens', (tester) async {
    await _desktop(tester);

    await tester.tap(find.text('New build'));
    await tester.pumpAndSettle();
    expect(find.byType(NewBuildScreen), findsOneWidget);

    await tester.tap(find.text('Saved networks'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('the hub opens from the app bar', (tester) async {
    await _desktop(tester);

    await tester.tap(find.byTooltip('All features (Ctrl+K)'));
    await tester.pumpAndSettle();

    expect(find.byType(ActionHubPanel), findsOneWidget);
    expect(find.text('Find a feature'), findsOneWidget);
    expect(find.text('PLAN A NETWORK'), findsOneWidget);
    expect(find.text('Plan a network from a sentence'), findsOneWidget);

    // The network operations that had no interface at all before are in here
    // too - reached by the hub's own search, which is how it is meant to be
    // used on a laptop-sized window.
    await tester.enterText(_hubSearch(), 'toolkit');
    await tester.pumpAndSettle();
    expect(find.text('Open the network toolkit'), findsOneWidget);

    await tester.enterText(_hubSearch(), 'port');
    await tester.pumpAndSettle();
    expect(
      find.text('Live diagnostics: DNS, ports, HTTP, ping'),
      findsOneWidget,
    );
  });

  testWidgets('Ctrl+K opens the hub from anywhere', (tester) async {
    await _desktop(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(ActionHubPanel), findsOneWidget);
    expect(find.text('Find a feature'), findsOneWidget);
  });

  testWidgets('the toolkit opens from the app bar, on the calculator',
      (tester) async {
    await _desktop(tester);

    // The rail carries the same control, so the app bar's is the first.
    await tester.tap(find.byTooltip('Network toolkit').first);
    await tester.pumpAndSettle();

    expect(find.text('Subnet calculator'), findsWidgets);
    expect(find.text('Subnet mask'), findsOneWidget);
    expect(find.text('255.255.255.0'), findsOneWidget);
  });

  testWidgets('the chat offers openers, and one fills the composer',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Start with one of these'), findsOneWidget);
    expect(find.text('Design a small office network'), findsOneWidget);

    // The openers are the last thing in a scrollable empty state, so a short
    // window needs a scroll to reach them - as a person would.
    await tester.ensureVisible(find.text('Plan a VLAN lab'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan a VLAN lab'));
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Message',
      ),
    );
    expect(composer.controller!.text, contains('VLAN lab'));
  });

  testWidgets('the chat names the conversation and can start another one',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('message(s)'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.byTooltip('Clear this conversation'), findsOneWidget);

    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();

    // A fresh conversation is a fresh transcript under its own name, and the
    // empty state comes back with the openers.
    expect(find.textContaining('chat '), findsWidgets);
    expect(find.text('Start with one of these'), findsOneWidget);
  });

  testWidgets('a sent message gets its own name, time and actions',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);

    // The message is presented as a turn in a conversation: who said it, the
    // text, and the things you can do with it afterwards.
    expect(find.text('You'), findsWidgets);
    expect(find.text('Copy'), findsWidgets);
    expect(find.text('Edit and resend'), findsWidgets);
  });
}
