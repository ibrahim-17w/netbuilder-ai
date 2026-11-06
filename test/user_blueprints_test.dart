import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/user_blueprints.dart';
import 'package:net_builder/screens/blueprints_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late MemoryService memory;
  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('nb-blueprint-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/db');
    await MemoryService.createSchema(db);
    memory = MemoryService(injected: db);
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
  test(
    'template survives reload; instances are independent and unverified',
    () async {
      final plan = NetworkIntent.parseSimple(
        'source',
        '1 router 1 switch 2 pcs with ospf',
      );
      final before = plan.revision;
      await UserBlueprints(
        memory,
      ).save(plan, name: 'Office', description: 'Small office', tags: 'ospf');
      final stored = (await UserBlueprints(memory).all()).single;
      final a = await UserBlueprints(memory).instantiate(stored, 'Branch');
      final b = await UserBlueprints(memory).instantiate(stored, 'Branch');
      expect(a.projectKey, isNot(b.projectKey));
      expect(a.projectName, isNot(b.projectName));
      expect(a.parentVersionId, isNull);
      expect(a.success, isFalse);
      expect(a.status, 'planned');
      final restored = NetworkIntent.fromJson(jsonDecode(a.intentJson));
      expect(restored.nodes.length, plan.nodes.length);
      expect(restored.links.length, plan.links.length);
      expect(plan.revision, before);
      await UserBlueprints(
        memory,
      ).save(plan, name: 'Renamed', id: stored['id']);
      expect((await UserBlueprints(memory).all()).single['name'], 'Renamed');
      await UserBlueprints(memory).remove(stored['id']);
      expect(await UserBlueprints(memory).all(), isEmpty);
    },
  );
  testWidgets('library searches saved names and tags', (tester) async {
    await tester.runAsync(
      () => UserBlueprints(memory).save(
        NetworkIntent(projectName: 'source'),
        name: 'Office',
        tags: 'branch',
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: memory,
        child: MaterialApp(home: BlueprintsScreen(onOpen: (_) {})),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Office'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('Office'), findsNothing);
    await tester.enterText(find.byType(TextField), 'branch');
    await tester.pump();
    expect(find.text('Office'), findsOneWidget);
  });

  test('blueprints never persist source credentials', () async {
    final plan = NetworkIntent.fromJson({
      'projectName': 'original',
      'nodes': [
        {'name': 'R1', 'type': 'router'},
      ],
      'security': {
        'aaa': true,
        'aaaPassword': 'SourceOnly123',
        'vpnPreSharedKey': 'SourceOnly456',
      },
    });
    await UserBlueprints(memory).save(plan, name: 'Safe design');
    final raw = (await memory.readPref(UserBlueprints.storageKey))!;
    expect(raw, isNot(contains('SourceOnly123')));
    expect(raw, isNot(contains('SourceOnly456')));
    final row = (await UserBlueprints(memory).all()).single;
    final copy = await UserBlueprints(memory).instantiate(row, 'Independent');
    expect(copy.intentJson, isNot(contains('SourceOnly')));
    expect(copy.projectName, isNot(plan.projectName));
  });
}
