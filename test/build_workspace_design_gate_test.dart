import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/build_workspace_screen.dart';
import 'package:net_builder/services/settings_service.dart';

void main() {
  tearDown(() => SettingsService.mobileOverrideForTests = null);

  testWidgets('Windows saved plans choose a design before build controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SettingsService.mobileOverrideForTests = false;
    final intent = NetworkIntent.parseSimple(
      'office',
      '2 routers, 2 switches and 6 PCs with OSPF',
    );
    final record = BuildRecord(
      projectName: intent.projectName,
      instruction: '2 routers, 2 switches and 6 PCs with OSPF',
      intentJson: jsonEncode(intent.toJson(includeSecrets: false)),
      target: 'packet-tracer',
      status: 'planned',
      success: false,
      createdAt: DateTime.utc(2026, 10, 15),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BuildWorkspaceScreen(
            record: record,
            intent: intent,
            configText: '',
            monitorSidecar: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Design'));
    await tester.pumpAndSettle();

    expect(find.text('Choose network design'), findsWidgets);
    expect(find.text('Choose network design').last, findsOneWidget);
    expect(find.text('PT Autopilot Start'), findsNothing);
    expect(find.text('Generate .pkt (no PT)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
