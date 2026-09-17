import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

class _FakeMemoryService extends MemoryService {
  final List<BuildRecord> records;

  _FakeMemoryService(this.records);

  @override
  bool get ready => true;

  @override
  Future<List<BuildRecord>> recentBuilds({int limit = 20}) async {
    return records.take(limit).toList();
  }
}

void main() {
  testWidgets('App boots to NetBuilder shell', (WidgetTester tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('NetBuilder'), findsWidgets);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('Analyze'), findsOneWidget);
  });

  testWidgets('PKT Files tab explains the safe file lifecycle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('PKT Files'));
    await tester.pumpAndSettle();
    expect(find.text('Choose .pkt file'), findsOneWidget);
    expect(find.text('Inspect .pkt'), findsOneWidget);
    expect(find.text('Open + backup'), findsOneWidget);
    expect(find.text('Open + analyze'), findsOneWidget);
    expect(find.text('Save current topology as new .pkt'), findsOneWidget);
    expect(find.textContaining('Read checks the file'), findsOneWidget);
  });

  testWidgets('Projects opens the selected saved build in Detail', (
    WidgetTester tester,
  ) async {
    final intent = NetworkIntent.parseSimple(
      'saved-lab',
      '1 router 1 switch with OSPF on 192.168.10.0/24',
    );
    final record = BuildRecord(
      projectName: 'saved-lab',
      instruction: '1 router 1 switch with OSPF on 192.168.10.0/24',
      intentJson: jsonEncode(intent.toJson()),
      target: 'packet-tracer',
      status: 'planned',
      success: false,
      createdAt: DateTime(2026, 9, 12),
    );
    final memory = _FakeMemoryService([record]);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SettingsService()),
          ChangeNotifierProvider<MemoryService>.value(value: memory),
        ],
        child: const NetBuilderApp(monitorDetailSidecar: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('saved-lab [packet-tracer]'), findsOneWidget);

    await tester.tap(find.text('saved-lab [packet-tracer]'));
    // Detail keeps a live status timer, so settle only the transition frame
    // instead of advancing fake time until a periodic timer can never end.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Plan status: PLANNED'), findsOneWidget);
    expect(
      find.text('Deterministic config / export from this plan:'),
      findsOneWidget,
    );
    expect(find.textContaining('=== R1 ==='), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
