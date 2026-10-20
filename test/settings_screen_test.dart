import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/screens/settings_screen.dart';
import 'package:provider/provider.dart';

Widget _settingsApp(SettingsService settings) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: settings),
    ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
  ],
  child: const MaterialApp(home: SettingsScreen()),
);

void main() {
  testWidgets(
    'one settings page groups provider, build, and privacy controls',
    (tester) async {
      final settings = SettingsService();
      await tester.pumpWidget(_settingsApp(settings));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    expect(find.text('MODEL ACCESS (BYOK)'), findsOneWidget);
    expect(find.text('WHERE BUILDS GO'), findsOneWidget);
    expect(find.text('PRIVACY AND AUTOMATION'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Save + test provider'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the shell has one settings button and no settings drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>(
            create: (_) => SettingsService(),
          ),
          ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
        ],
        child: const NetBuilderApp(),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.drawer, isNull);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
