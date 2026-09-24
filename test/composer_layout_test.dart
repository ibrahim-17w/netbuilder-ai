import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// The composer must never be covered, and Enter must send.
///
/// This pins the reported bug: the floating PAUSE/STOP column sat on top of
/// the chat composer's Send button. The run controls now live in the chat
/// header, and the Chat tab shows no floating buttons at all.

class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
}

class _OfflineMemory extends MemoryService {
  @override
  bool get ready => false;
}

Widget _chatHarness() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: _OfflineMemory()),
  ],
  child: const MaterialApp(home: Scaffold(body: ChatScreen())),
);

/// The whole app at a phone width: the drawer only exists in the real shell,
/// and the drawer is where the run controls live now.
Widget _narrowApp() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: _OfflineMemory()),
  ],
  child: const NetBuilderApp(),
);

Finder _composer() => find.byType(TextField).last;

void main() {
  testWidgets('the chat is the only screen: no tabs, no floating controls',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The reported bug class - a floating control covering the composer -
    // cannot recur, because the shell no longer renders floats or tabs.
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget);

    // The run controls no longer sit over the composer at all - they are in
    // Settings - so there is nothing left to cover Send. The chat sheet keeps
    // only the capture actions.
    await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
    await tester.pumpAndSettle();
    expect(find.text('Build a .pkt from the current plan'), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline), findsNothing);
  });

  testWidgets('Enter sends the message and clears the composer',
      (tester) async {
    await tester.pumpWidget(_chatHarness());
    await tester.pumpAndSettle();

    await tester.enterText(_composer(), 'hello world');
    await tester.pump();
    expect(
      tester.widget<TextField>(_composer()).controller!.text,
      'hello world',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      tester.widget<TextField>(_composer()).controller!.text,
      isEmpty,
      reason: 'Enter must send the message and clear the composer',
    );
    expect(
      find.text('hello world'),
      findsOneWidget,
      reason: 'the sent text must appear as a message bubble',
    );
  });

  testWidgets('Shift+Enter does not send', (tester) async {
    await tester.pumpWidget(_chatHarness());
    await tester.pumpAndSettle();

    await tester.enterText(_composer(), 'first line');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      tester.widget<TextField>(_composer()).controller!.text,
      isNotEmpty,
      reason: 'Shift+Enter must add a line, not send',
    );
  });

  testWidgets('composer + run controls hold at a narrow phone width',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_narrowApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'nothing may overflow at 360x640');
    expect(find.byIcon(Icons.send), findsOneWidget);

    // The tools sheet must survive the narrowest phone.
    await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the tools sheet must not overflow at 360x640');
    expect(find.text('Build a .pkt from the current plan'), findsOneWidget);

    // The settings drawer no longer uses a fixed 380px width (which was wider
    // than this phone and overflowed): it takes 86% of a narrow screen. That
    // is asserted by the drawer tests at the default size, where the drawer
    // reliably opens; at this width the harness does not open it, so claiming
    // more here would be claiming something untested.
  });

  testWidgets('composer holds at a wide desktop width', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_chatHarness());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });
}
