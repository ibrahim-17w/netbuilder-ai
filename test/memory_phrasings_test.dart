import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/phrasing_memory_service.dart';

/// The data contract behind the Memory screen's "Learned phrasings"
/// section: teach writes a row AND refreshes the live replay index, the
/// store lists rows newest first, and forgetting removes the row AND
/// clears the lesson from the live index (so it stops replaying at once,
/// not after a restart).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(PhrasingMemoryService.clearIndex);

  test('phrasings are stored, listed and forgotten, index kept in sync',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await MemoryService.createSchema(db);
    final mem = MemoryService(injected: db);

    final key = PhrasingMemoryService.normalizeKey(
      'make me a lab for the class',
    );
    await mem.teachPhrasing(key, '2 routers 2 switches 6 pcs');

    final rows = await mem.allPhrasings();
    expect(rows, hasLength(1));
    expect(rows.first['phrasing'], key);
    expect(rows.first['rewrite'], '2 routers 2 switches 6 pcs');
    // Teaching refreshes the live index, so the very next parse replays.
    expect(PhrasingMemoryService.indexView, hasLength(1));
    expect(
      PhrasingMemoryService.lookup('make me a lab for the class'),
      '2 routers 2 switches 6 pcs',
    );

    await mem.forgetPhrasing(key);
    expect(await mem.allPhrasings(), isEmpty);
    expect(PhrasingMemoryService.isEmpty, isTrue,
        reason: 'forgetting clears the live index too');

    await db.close();
  });

  test('an empty store lists nothing rather than inventing a lesson',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await MemoryService.createSchema(db);
    final mem = MemoryService(injected: db);
    expect(await mem.allPhrasings(), isEmpty);
    await db.close();
  });
}
