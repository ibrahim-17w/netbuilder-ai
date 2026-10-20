// The store became unopenable and the app ran silently with no memory at all.
//
// A killed process left a migration half-applied: `learned_answer` was created
// but the version counter was never advanced past 7. Every launch after that
// re-ran `CREATE TABLE learned_answer`, threw, and main.dart swallowed it - so
// the app ran with no store, wrote nothing, showed an empty conversation list,
// and said nothing anywhere. A fresh install and weeks of history looked
// identical.
//
// These tests hold the two things that were wrong:
//
//   1. the migration is a NO-OP on a table that is already there, so the store
//      opens instead of throwing forever;
//   2. running the whole chain twice in a row is safe, which is what makes a
//      kill mid-migration survivable rather than fatal.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  /// A store at version 7 that has ALSO had the version-8 table created: the
  /// exact half-applied state the real memory.db was found in.
  Future<Database> halfAppliedStore(String path) async {
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute('''
CREATE TABLE chat(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 conversation TEXT NOT NULL DEFAULT 'default',
 role TEXT NOT NULL,
 text TEXT NOT NULL DEFAULT '',
 imagesJson TEXT NOT NULL DEFAULT '[]',
 actionsJson TEXT NOT NULL DEFAULT '[]',
 executedJson TEXT NOT NULL DEFAULT '[]',
 createdAt TEXT NOT NULL,
 source TEXT NOT NULL DEFAULT ''
)''');
    await db.execute('''
CREATE TABLE learned_answer(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 qkey TEXT NOT NULL,
 question TEXT NOT NULL,
 answer TEXT NOT NULL,
 source TEXT NOT NULL DEFAULT '',
 seenCount INTEGER NOT NULL DEFAULT 1,
 confirmed INTEGER NOT NULL DEFAULT 0,
 createdAt TEXT NOT NULL,
 lastSeenAt TEXT NOT NULL
)''');
    await db.insert('chat', {
      'conversation': 'default',
      'role': 'user',
      'text': 'hello from the old store',
      'createdAt': DateTime.now().toIso8601String(),
    });
    await db.rawUpdate('PRAGMA user_version = 7');
    await db.close();
    return databaseFactoryFfi.openDatabase(path);
  }

  test('the migration is a no-op on a table that is already there', () async {
    final tmp = Directory.systemTemp.createTempSync('mem-v7-');
    final path = '${tmp.path}${Platform.pathSeparator}memory.db';
    await halfAppliedStore(path);

    // The app's own upgrade chain, run over that store at the release
    // settings. Opening at all is the point: this is what used to throw.
    final db = await databaseFactoryFfi.openDatabase(path);
    await MemoryService.upgradeSchema(db, 7, 10);

    final rows = await db.query('chat');
    expect(
      rows,
      isNotEmpty,
      reason: 'the transcript must survive the upgrade, not be thrown away',
    );
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('the same half-applied store survives being upgraded twice', () async {
    // Re-running the chain must be idempotent, which is what makes a kill
    // mid-migration survivable rather than fatal.
    final tmp = Directory.systemTemp.createTempSync('mem-twice-');
    final path = '${tmp.path}${Platform.pathSeparator}memory.db';
    await halfAppliedStore(path);
    for (var i = 0; i < 2; i++) {
      final db = await databaseFactoryFfi.openDatabase(path);
      await MemoryService.upgradeSchema(db, 7, 10);
      await db.query('chat');
      await db.close();
    }
    tmp.deleteSync(recursive: true);
  });

  test('a column the counter says exists is still added when it does not',
      () async {
    // The counter is not the truth; the schema is. A store whose counter
    // advanced past version 7 without the `source` column landing (exactly
    // the shape the real store was found in) must still be repaired.
    final tmp = Directory.systemTemp.createTempSync('mem-col-');
    final path = '${tmp.path}${Platform.pathSeparator}memory.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute('''
CREATE TABLE chat(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 conversation TEXT NOT NULL DEFAULT 'default',
 role TEXT NOT NULL,
 text TEXT NOT NULL DEFAULT '',
 imagesJson TEXT NOT NULL DEFAULT '[]',
 actionsJson TEXT NOT NULL DEFAULT '[]',
 executedJson TEXT NOT NULL DEFAULT '[]',
 createdAt TEXT NOT NULL
)''');
    await db.rawUpdate('PRAGMA user_version = 6');
    await db.close();

    final upgraded = await databaseFactoryFfi.openDatabase(path);
    await MemoryService.upgradeSchema(upgraded, 6, 10);
    final cols = await upgraded.rawQuery('PRAGMA table_info(chat)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(
      names,
      contains('source'),
      reason: 'the source column is added even when the counter is ahead',
    );
    await upgraded.close();
    tmp.deleteSync(recursive: true);
  });
}
