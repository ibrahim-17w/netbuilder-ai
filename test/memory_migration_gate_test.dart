import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';

/// The stored-privacy migration walked every table on EVERY launch. On a
/// real history that walk cost more than the whole 8s startup deadline, and
/// the app then ran on safe defaults - degraded - on exactly the machine
/// whose history needed protecting. A completed run records itself in
/// user_version; the next launch skips the walk.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // The migration walks legacy credentials through the OS keystore; the
    // test keeps that in memory - protectText verifies every write by
    // reading it back, so the mock must actually store.
    final keystore = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments as Map?;
            final key = args?['key'] as String?;
            switch (call.method) {
              case 'read':
                return keystore[key];
              case 'write':
                keystore[key!] = args!['value'] as String;
                return null;
              case 'delete':
                keystore.remove(key);
                return null;
              case 'readAll':
                return Map<String, String>.of(keystore);
            }
            return null;
          },
        );
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-migration-gate');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/m.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  test('a completed migration records itself and skips the second run', () async {
    final dir = await Directory.systemTemp.createTemp('nb-migration-gate2');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/m2.db');
    await MemoryService.createSchema(db);
    final mem = MemoryService(injected: db);
    await db.insert('builds', {
      'projectName': 'lab',
      'instruction': '2 routers and 4 PCs',
      'intentJson': '{}',
      'target': 'packet-tracer',
      'success': 1,
      'status': 'planned',
      'createdAt': DateTime.now().toIso8601String(),
    });

    await mem.migrateStoredPrivacy();
    final version = (await db.rawQuery('PRAGMA user_version'))
        .single
        .values
        .single as int;
    expect(version, 1, reason: 'the completed run stamps user_version = 1');

    // A second launch runs the gate, not the walk: same version, still 1.
    await mem.migrateStoredPrivacy();
    expect(
      ((await db.rawQuery('PRAGMA user_version')).single.values.single
          as int),
      1,
    );
  });

  test('the first run still redacts legacy plaintext rows', () async {
    final mem = await fresh();
    final db = mem.databaseForTest!;
    // A legacy chat row with a plaintext credential (the shape the
    // migration exists to redact).
    await db.insert('chat', {
      'role': 'user',
      'text': 'AAA password SuperSecret123 for the lab',
      'imagesJson': '',
      'actionsJson': '',
      'executedJson': '',
      'createdAt': DateTime.now().toIso8601String(),
      'conversation': 'legacy',
      'source': '',
    });

    await mem.migrateStoredPrivacy();

    final rows = await db.query(
      'chat',
      where: "conversation = 'legacy'",
    );
    expect(rows.toString(), isNot(contains('SuperSecret123')));
    expect(
      ((await db.rawQuery('PRAGMA user_version')).single.values.single
          as int),
      1,
    );
  });
}
