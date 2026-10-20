import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'merge remaps IDs, keeps conversations separate, and is repeatable',
    () async {
      final dir = await Directory.systemTemp.createTemp('nb-memory-merge');
      final localDb = await databaseFactoryFfi.openDatabase(
        '${dir.path}/local.db',
      );
      final sourceDb = await databaseFactoryFfi.openDatabase(
        '${dir.path}/source.db',
      );
      addTearDown(() async {
        await localDb.close();
        await sourceDb.close();
        await dir.delete(recursive: true);
      });
      await MemoryService.createSchema(localDb);
      await MemoryService.createSchema(sourceDb);
      final local = MemoryService(injected: localDb);
      final source = MemoryService(injected: sourceDb);
      const createdAt = '2026-01-01T00:00:00.000Z';

      Future<void> addBuild(
        DatabaseExecutor db,
        String project,
        String instruction,
      ) async {
        await db.insert('builds', {
          'projectName': project,
          'instruction': instruction,
          'intentJson': '{"projectName":"$project"}',
          'target': 'packet-tracer',
          'success': 0,
          'status': 'planned',
          'createdAt': createdAt,
        });
      }

      await addBuild(localDb, 'local', 'Local plan');
      await addBuild(sourceDb, 'imported', 'Imported plan');
      await sourceDb.insert('attempts', {
        'buildId': 1,
        'projectName': 'imported',
        'instruction': 'Imported plan',
        'intentJson': '{"projectName":"imported"}',
        'target': 'packet-tracer',
        'status': 'planned',
        'createdAt': createdAt,
        'updatedAt': createdAt,
      });
      await localDb.insert('conversations', {
        'id': 'shared',
        'title': 'Local chat',
        'project': 'local',
        'createdAt': createdAt,
        'updatedAt': createdAt,
        'summary': '',
        'summaryUpToId': 0,
        'stateJson': '{}',
      });
      await sourceDb.insert('conversations', {
        'id': 'shared',
        'title': 'Backup chat',
        'project': 'backup',
        'createdAt': createdAt,
        'updatedAt': createdAt,
        'summary': '',
        'summaryUpToId': 0,
        'stateJson': '{}',
      });
      await sourceDb.insert('chat', {
        'conversation': 'shared',
        'role': 'user',
        'text': 'Keep this imported chat separate.',
        'createdAt': createdAt,
        'source': 'test',
      });
      await localDb.insert('prefs', {'k': 'theme', 'v': 'dark'});
      await sourceDb.insert('prefs', {'k': 'theme', 'v': 'light'});
      await sourceDb.insert('prefs', {'k': 'density', 'v': 'compact'});

      final backup = await source.exportJson();
      final added = await local.mergeJson(backup);
      expect(added['builds'], 1);
      expect(added['attempts'], 1);
      expect(added['conversations'], 1);
      expect(added['chat'], 1);
      expect(added['prefs'], 1);

      final builds = await localDb.query('builds', orderBy: 'id');
      expect(builds.map((r) => r['projectName']), ['local', 'imported']);
      final attempts = await localDb.query('attempts');
      expect(attempts.single['buildId'], builds.last['id']);
      final conversations = await localDb.query('conversations', orderBy: 'id');
      expect(conversations, hasLength(2));
      final importedConversation = conversations.singleWhere(
        (row) => row['title'] == 'Backup chat',
      );
      expect(importedConversation['id'], isNot('shared'));
      final chat = await localDb.query('chat');
      expect(chat.single['conversation'], importedConversation['id']);
      expect(
        (await localDb.query(
          'prefs',
          where: 'k=?',
          whereArgs: ['theme'],
        )).single['v'],
        'dark',
      );
      expect(
        (await localDb.query(
          'prefs',
          where: 'k=?',
          whereArgs: ['density'],
        )).single['v'],
        'compact',
      );

      final repeated = await local.mergeJson(backup);
      expect(repeated['builds'] ?? 0, 0);
      expect(repeated['attempts'] ?? 0, 0);
      expect(repeated['conversations'] ?? 0, 0);
      expect(repeated['chat'] ?? 0, 0);
      expect(await localDb.query('builds'), hasLength(2));
      expect(await localDb.query('attempts'), hasLength(1));
      expect(await localDb.query('conversations'), hasLength(2));
      expect(await localDb.query('chat'), hasLength(1));

      await local.mergeJson(backup, preferBackupSettings: true);
      expect(
        (await localDb.query(
          'prefs',
          where: 'k=?',
          whereArgs: ['theme'],
        )).single['v'],
        'light',
      );
    },
  );

  test('invalid backup merge leaves local memory unchanged', () async {
    final dir = await Directory.systemTemp.createTemp(
      'nb-memory-merge-invalid',
    );
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/local.db');
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await MemoryService.createSchema(db);
    final memory = MemoryService(injected: db);
    await db.insert('prefs', {'k': 'theme', 'v': 'dark'});

    await expectLater(
      memory.mergeJson(jsonEncode({'schemaVersion': 5, 'prefs': {}})),
      throwsA(isA<FormatException>()),
    );
    expect((await db.query('prefs')).single['v'], 'dark');
  });
}
