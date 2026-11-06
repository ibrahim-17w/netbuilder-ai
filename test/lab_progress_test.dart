import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/lab_catalog.dart';
import 'package:net_builder/services/lab_grading_service.dart';
import 'package:net_builder/services/lab_progress_service.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'both entry points share goals and progress survives reopening',
    () async {
      final dir = Directory.systemTemp.createTempSync('nb-labs-');
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/db');
      await MemoryService.createSchema(db);
      final memory = MemoryService(injected: db);
      addTearDown(() async {
        await db.close();
        dir.deleteSync(recursive: true);
      });
      final lab = LabCatalog.byId('office-vlans-dhcp')!;
      final plan = NetworkIntent.parseSimple(
        'practice',
        '1 router 1 switch 2 pcs',
      );
      final chatGrade = LabGrader.grade(lab, plan);
      final screenGrade = LabGradingService.grade('office-vlans-dhcp', plan);
      expect(
        screenGrade.map((r) => r.passed),
        chatGrade.results.map((r) => r.ok),
      );
      final service = LabProgressService(memory);
      await service.record(lab, plan, buildId: 42, hintUsed: true);
      final saved = (await LabProgressService(memory).load('vlan-dhcp'))!;
      expect(saved['buildId'], 42);
      expect(saved['hintsUsed'], 1);
      expect(saved['attempts'], hasLength(1));
      expect(
        NetworkIntent.fromJson(
          Map<String, dynamic>.from(saved['plan']),
        ).revision,
        plan.revision,
      );
      expect(await service.load('ospf-wan'), isNull);
    },
  );
}
