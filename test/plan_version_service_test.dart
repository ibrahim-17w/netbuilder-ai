import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/plan_version_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'saves a complete edited topology before returning its history row',
    () async {
      final dir = await Directory.systemTemp.createTemp('nb-plan-version');
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/memory.db');
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await MemoryService.createSchema(db);
      final memory = MemoryService(injected: db);
      final previous = BuildRecord(
        id: 4,
        projectName: 'office',
        instruction: 'Two routed LANs',
        intentJson: '{}',
        target: 'packet-tracer',
        status: 'planned',
        success: false,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final intent = NetworkIntent(
        projectName: 'office',
        nodes: const [NetNode(name: 'R1', type: 'router')],
        addressing: const [
          InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
        ],
      );

      final saved = await PlanVersionService.saveEditedPlan(
        memory: memory,
        intent: intent,
        previous: previous,
        now: DateTime.utc(2026, 2, 1),
      );

      expect(saved.id, isNotNull);
      expect(saved.status, 'planned');
      expect(saved.success, isFalse);
      expect(saved.instruction, contains('Two routed LANs'));
      expect(saved.createdAt, DateTime.utc(2026, 2, 1));
      final stored = await db.query(
        'builds',
        where: 'id=?',
        whereArgs: [saved.id],
      );
      expect(stored, hasLength(1));
      final restored = NetworkIntent.fromJson(
        jsonDecode(stored.single['intentJson']! as String)
            as Map<String, dynamic>,
      );
      expect(restored.addressing.single.ipCidr, '192.168.1.1/24');
    },
  );

  test(
    'reports unavailable history without pretending the edit was saved',
    () async {
      await expectLater(
        PlanVersionService.saveEditedPlan(
          memory: MemoryService(),
          intent: const NetworkIntent(projectName: 'office'),
          previous: null,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}
