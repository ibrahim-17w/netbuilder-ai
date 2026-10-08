import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// main() is what installs the providers and a widget test does not call it.
Widget _app() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>(create: (_) => SettingsService()),
    ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
  ],
  child: const NetBuilderApp(),
);

void main() {
  testWidgets('the app opens straight into the chat: no tabs, no floats',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The redesigned chrome: the top bar names the screen you are on
    // ("Chat" here) instead of repeating the app's name. The brand itself
    // lives once, on the desktop rail (asserted by the shell test).
    expect(find.text('Chat'), findsWidgets);
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);

    expect(find.textContaining('Enter sends'), findsOneWidget);

    // No token counter, no status tag, no message count: the chat shows the
    // conversation and the box, and the diagnostics are one tap away in the
    // tools sheet rather than permanently painted under the transcript.
    expect(find.textContaining('Context '), findsNothing);
    expect(find.textContaining('message(s)'), findsNothing);

    // The chat screen is chat plus a media picker and one tools control.
    expect(find.byTooltip('Attach'), findsOneWidget);
    expect(find.byTooltip('Tools: run, capture, and integrations'),
        findsOneWidget);
  });

  testWidgets('the on-device .pkt builder is reachable from the chat',
      (tester) async {
    // A builder nobody can reach is not a feature. On Android the sidecar is
    // not there at all, so these two actions are the ONLY route to a .pkt -
    // they have to be findable from the tools sheet.
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
    await tester.pumpAndSettle();

    expect(find.text('Import a seed .pkt'), findsOneWidget);
    expect(find.text('Build a .pkt on this device'), findsOneWidget);
  });

  testWidgets('the token report is one tap away, not always on screen',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
    await tester.pumpAndSettle();
    // The sheet grew a Share tile for built files, so the report may sit
    // below the fold on a test window: scroll to it, then press it.
    await tester.ensureVisible(find.text('Context report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Context report'));
    await tester.pumpAndSettle();

    expect(find.text('Context report'), findsWidgets);
    expect(find.textContaining('tokens used'), findsOneWidget);
  });

  testWidgets('the old strip above the chat is gone', (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    expect(find.text('Project context'), findsNothing);
    expect(find.text('Live context'), findsNothing);
    expect(find.text('Run:'), findsNothing);
  });

  testWidgets('the chat sheet keeps only what is used while chatting',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byTooltip('Tools: run, capture, and integrations'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build a .pkt from the current plan'), findsOneWidget);
    expect(find.text('Analyze a .pkt'), findsOneWidget);
    expect(find.text('Clear this conversation'), findsOneWidget);

    // The technical controls moved out, so they are not here any more.
    expect(find.text('Live context'), findsNothing);
    expect(find.text('Project context'), findsNothing);
    expect(find.text('Push the plan to GNS3'), findsNothing);
  });

  testWidgets('nothing was lost: the run, the ledger and the rest are in '
      'Settings', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu).first);
    await tester.pumpAndSettle();

    // Moved out of the chat, present here.
    expect(find.text('Packet Tracer run'), findsOneWidget);
    expect(find.text('Pause / resume'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Ledger'), findsOneWidget);
    expect(find.text('Live context'), findsOneWidget);
    expect(find.text('Project context'), findsOneWidget);

    // The settings that were always here are further down the same list; they
    // are asserted in settings_drawer_test.dart, which scrolls to them.
  });

  testWidgets('the composer is focused on open', (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(find.byType(TextField), findsWidgets);
  });
}
