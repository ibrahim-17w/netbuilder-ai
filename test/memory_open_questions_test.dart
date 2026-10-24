import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The unanswered-questions loop: a keyless miss lands in a local backlog,
/// deduped by the question's wording, capped, and shown newest-first. The
/// corpus grows from real misses instead of guesses - nothing leaves the
/// device.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-openq-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // A leftover temp directory is not worth failing a test over.
      }
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/memory.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  late MemoryService mem;
  setUp(() async => mem = await fresh());

  test('a miss is recorded once and counted on repeat', () async {
    await mem.recordOpenQuestion('What is VTP pruning?');
    await mem.recordOpenQuestion('what is vtp pruning');
    await mem.recordOpenQuestion('What is VTP pruning?');
    final list = await mem.openQuestions();
    expect(list, hasLength(1), reason: 'the wording is deduped');
    expect(list.single.question, 'what is vtp pruning');
    expect(list.single.hits, 3);
  });

  test('newest miss first, whatever the ask order', () async {
    await mem.recordOpenQuestion('first miss');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await mem.recordOpenQuestion('second miss');
    final list = await mem.openQuestions();
    expect(list.first.question, 'second miss');
    expect(list.last.question, 'first miss');
  });

  test('an empty ask is never recorded', () async {
    await mem.recordOpenQuestion('   ');
    expect(await mem.openQuestions(), isEmpty);
  });

  test('the backlog is capped at the newest misses', () async {
    for (var i = 0; i < MemoryService.openQuestionCap + 10; i++) {
      await mem.recordOpenQuestion('miss number $i');
      // Distinct instants so the ordering is unambiguous.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final list = await mem.openQuestions(limit: 1000);
    expect(list.length, MemoryService.openQuestionCap);
    // The OLDEST asks fell off; the newest are all here.
    expect(
      list.any((q) => q.question == 'miss number 0'),
      isFalse,
      reason: 'the oldest miss was evicted by the cap',
    );
    expect(
      list.any(
        (q) => q.question == 'miss number ${MemoryService.openQuestionCap + 9}',
      ),
      isTrue,
    );
  });

  test('clearing the list empties it', () async {
    await mem.recordOpenQuestion('some miss');
    await mem.clearOpenQuestions();
    expect(await mem.openQuestions(), isEmpty);
  });

  test('an upgrade from schema 10 creates the backlog table', () async {
    final dir = await Directory.systemTemp.createTemp('nb-openq-upg');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    await db.execute('CREATE TABLE builds(id INTEGER PRIMARY KEY)');
    // A store at version 10, before the backlog existed.
    await MemoryService.upgradeSchema(db, 10, 11);
    final mem = MemoryService(injected: db);
    await mem.recordOpenQuestion('asked after the upgrade');
    final list = await mem.openQuestions();
    expect(list, hasLength(1));
  });
}
