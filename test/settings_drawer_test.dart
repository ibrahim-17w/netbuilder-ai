import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/widgets/settings_drawer.dart';

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

}
