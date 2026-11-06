import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/project_checks.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/screens/project_checks_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:convert';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final plan = NetworkIntent.parseSimple('checks', '1 router 1 switch 2 PCs');
  late MemoryService memory;
  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('nb-checks-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/db');
    await MemoryService.createSchema(db);
    memory = MemoryService(injected: db);
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
  test(
    'checks persist across service instances and stay project scoped',
    () async {
      final check = ProjectChecks.create(
        plan,
        plan.nodes.first.name,
        plan.nodes.last.name,
      );
      await ProjectChecks(memory, 'one').save([check]);
      final restored = (await ProjectChecks(memory, 'one').load()).single;
      expect(restored.toJson(), check.toJson());
      expect(await ProjectChecks(memory, 'two').load(), isEmpty);
      expect(
        ProjectChecks.preview(check, plan),
        contains('live result remains unverified'),
      );
    },
  );
  test('only matching live evidence can pass; changed plans become stale', () {
    final check = ProjectChecks.create(
      plan,
      plan.nodes.first.name,
      plan.nodes.last.name,
    );
    final result = ProjectChecks.applyReport(check, plan, {
      'tests': [
        {
          'checkId': check.id,
          'status': 'passed',
          'evidence': 'Replies received',
        },
      ],
    });
    expect(result.statusFor(plan), 'passed');
    expect(result.statusFor(plan.copyWith(routing: 'ospf')), 'stale');
    expect(
      ProjectChecks.applyReport(check, plan, {
        'tests': [
          {'checkId': check.id, 'status': 'passed'},
        ],
      }).status,
      'unverified',
    );
    expect(
      ProjectChecks.applyReport(check, plan, {'tests': []}).status,
      isNot('passed'),
    );
    final deny = ProjectChecks.create(
      plan,
      plan.nodes.first.name,
      plan.nodes.last.name,
      allow: false,
    );
    expect(
      ProjectChecks.applyReport(deny, plan, {
        'tests': [
          {'checkId': deny.id, 'status': 'passed'},
        ],
      }).status,
      'manual',
    );
  });
  testWidgets('project screen displays saved checks and their evidence state', (
    tester,
  ) async {
    final previousOverride = SettingsService.mobileOverrideForTests;
    SettingsService.mobileOverrideForTests = true;
    addTearDown(
      () => SettingsService.mobileOverrideForTests = previousOverride,
    );
    final check = ProjectChecks.create(
      plan,
      plan.nodes.first.name,
      plan.nodes.last.name,
    );
    await tester.runAsync(() => ProjectChecks(memory, 'checks').save([check]));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: memory,
        child: MaterialApp(
          home: ProjectChecksScreen(
            record: BuildRecord(
              projectName: 'checks',
              instruction: '',
              intentJson: jsonEncode(plan.toPlannerJson()),
              target: 'packet-tracer',
              createdAt: DateTime.now(),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(find.text(check.label), findsOneWidget);
    expect(find.text('unverified'), findsOneWidget);
    expect(find.text('Add check'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Run in Packet Tracer'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Live checks require'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
