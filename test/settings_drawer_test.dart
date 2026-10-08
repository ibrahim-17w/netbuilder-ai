import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/widgets/settings_drawer.dart';
import 'package:provider/provider.dart';

/// Every setting lives on the sidebar - there is no other screen.
void main() {
  testWidgets('the shell is wired to the settings sidebar', (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.drawer, isNotNull, reason: 'the shell must have a drawer');
    expect(scaffold.drawer, isA<SettingsDrawer>());
    expect(scaffold.bottomNavigationBar, isNull);
    expect(scaffold.floatingActionButton, isNull);
  });

  testWidgets('the context controls are here, ceiling and runtime window alike',
      (tester) async {
    final settings = SettingsService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          // The drawer lists the saved chats, so it needs the store.
          ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
        ],
        // The test font is much wider than the shipped one, so the drawer is
        // laid out at a smaller text scale: this test is about the controls,
        // not about typography.
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(0.5)),
            child: child!,
          ),
          home: const Scaffold(drawer: SettingsDrawer(), body: SizedBox()),
        ),
      ),
    );
    // Tall enough that the chat-context section is laid out without a scroll:
    // the assertion is about the controls, not about scrolling.
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('Context budget'), findsOneWidget,
        reason: 'the ceiling and the real window are set side by side');
    expect(find.text('Runtime window'), findsOneWidget);
    expect(find.text('Log every request context'), findsOneWidget);

    // Setting the window by hand must reach the service: this is the only
    // lever a user has when the runtime allocates less than it accepts.
    await tester.tap(find.text('Detect automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4k tokens').last);
    await tester.pumpAndSettle();
    expect(settings.runtimeWindow, 4096);

    // ...and the debug toggle has to be switchable too.
    await tester.tap(find.text('Log every request context'));
    await tester.pumpAndSettle();
    expect(settings.contextDebug, isTrue);
  });

  testWidgets('the local-model presets are one tap to a working address',
      (tester) async {
    final settings = SettingsService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(0.5)),
            child: child!,
          ),
          home: const Scaffold(drawer: SettingsDrawer(), body: SizedBox()),
        ),
      ),
    );
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('Local model (fully offline)'), findsOneWidget);

    // The presets exist because local runtimes were supported but buried:
    // one tap has to land on a usable address, not open a form.
    await tester.tap(find.text('Ollama'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(settings.providerName, 'openai',
        reason: 'the chip switches the provider itself');
    expect(settings.openAiBaseUrl, 'http://127.0.0.1:11434/v1');
  });
}
