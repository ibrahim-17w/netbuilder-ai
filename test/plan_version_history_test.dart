import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/plan_version_diff.dart';
import 'package:net_builder/services/plan_version_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Plan version history: every version of a project shares one stable key,
/// each edit names the version it was made from, a timeline reads back the
/// way the work happened, compare is pure, and RESTORE IS AN EDIT - the
/// originals survive.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-version-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/memory.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  BuildRecord record(
    String project,
    String intentBrief, {
    String? projectKey,
    int? parentVersionId,
    String instruction = 'manual plan',
    String status = 'planned',
  }) {
    final intent = NetworkIntent.parseSimple('p', intentBrief);
    return BuildRecord(
      projectName: project,
      instruction: instruction,
      intentJson: jsonEncode(intent.toPlannerJson()),
      target: 'packet-tracer',
      success: false,
      status: status,
      createdAt: DateTime.now(),
      projectKey: projectKey ?? '',
      parentVersionId: parentVersionId,
    );
  }

  group('the pure diff', () {
    test('two identical plans compare empty', () {
      final a = NetworkIntent.parseSimple('p', '2 routers 1 switch 2 pcs');
      final b = NetworkIntent.parseSimple('p', '2 routers 1 switch 2 pcs');
      expect(PlanVersionDiff.compare(a, b).isEmpty, isTrue);
      expect(
        PlanVersionDiff.compare(a, b).toMarkdown(),
        contains('same network'),
      );
    });

    test(
      'devices, cables, addresses, routing and services are all compared',
      () {
        final a = NetworkIntent.parseSimple(
          'p',
          '1 router 1 switch 2 pcs with static routing',
        );
        final b = NetworkIntent.parseSimple(
          'p',
          '2 routers 1 switch 3 pcs in vlan 20 with ospf and a dns server',
        );
        final diff = PlanVersionDiff.compare(a, b);
        expect(diff.devicesAdded, containsAll(['R2', 'PC3', 'SRV1']));
        expect(diff.routingBefore, 'static');
        expect(diff.routingAfter, 'ospf');
        expect(diff.cablesAdded, isNotEmpty);
        expect(diff.addressChanges, isNotEmpty);
        expect(diff.toMarkdown(), contains('Devices added'));
        expect(diff.toMarkdown(), contains('Routing'));
      },
    );

    test('a credential never appears in the diff', () {
      final a = NetworkIntent.parseSimple('p', '1 router 1 aaa server');
      final b = NetworkIntent.parseSimple('p', '1 router 1 aaa server');
      final server = b.nodes.firstWhere((n) => n.type == 'server');
      b.nodes[b.nodes.indexOf(server)] = NetNode(
        name: server.name,
        type: server.type,
        model: server.model,
        services: server.services,
        serviceRules: {
          'aaa': {
            'users': [
              {'username': 'admin', 'password': 'hunter2-secret'},
            ],
          },
        },
      );
      final text = PlanVersionDiff.compare(a, b).toMarkdown();
      expect(text, isNot(contains('hunter2-secret')));
    });
  });

  group('the version chain', () {
    test('an edit carries the project key and its parent', () async {
      final mem = await fresh();
      final first = await mem.logBuild(
        record('office', '2 routers 4 switches', status: 'verified'),
      );
      final previous = (await mem.recentBuilds()).firstWhere(
        (r) => r.id == first,
      );
      final second = await PlanVersionService.saveEditedPlan(
        memory: mem,
        intent: NetworkIntent.parseSimple('office', '2 routers 5 switches'),
        previous: previous,
      );
      expect(second.projectKey, 'office');
      expect(second.parentVersionId, first);
    });

    test(
      'the timeline reads oldest first across legacy and keyed rows',
      () async {
        final mem = await fresh();
        // A legacy row: no key, no parent - identified by project name.
        await mem.logBuild(record('office', '1 router', status: 'verified'));
        final parent = (await mem.recentBuilds()).last;
        await PlanVersionService.saveEditedPlan(
          memory: mem,
          intent: NetworkIntent.parseSimple('office', '2 routers'),
          previous: parent,
        );
        // An unrelated project must not join the timeline.
        await mem.logBuild(record('other', '9 routers', status: 'verified'));

        final timeline = await PlanVersionService.timeline(
          mem,
          projectKey: 'office',
        );
        expect(timeline, hasLength(2));
        expect(timeline.first.instruction, 'manual plan');
        expect(timeline.last.parentVersionId, timeline.first.id);
      },
    );

    test('restoring an older version creates a NEW version', () async {
      final mem = await fresh();
      await mem.logBuild(record('office', '2 routers 4 switches'));
      final parent = (await mem.recentBuilds()).last;
      await PlanVersionService.saveEditedPlan(
        memory: mem,
        intent: NetworkIntent.parseSimple('office', '2 routers 8 switches'),
        previous: parent,
      );
      final beforeCount = (await mem.recentBuilds()).length;
      final timeline = await PlanVersionService.timeline(
        mem,
        projectKey: 'office',
      );
      final original = timeline.first;
      final latest = timeline.last;

      final restored = await PlanVersionService.restoreVersion(
        memory: mem,
        original: original,
        latest: latest,
      );

      final after = await mem.recentBuilds();
      expect(after.length, beforeCount + 1);
      expect(restored.parentVersionId, latest.id);
      // The restored plan IS the old plan.
      final restoredIntent = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(restored.intentJson) as Map),
      );
      final originalIntent = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(original.intentJson) as Map),
      );
      expect(
        restoredIntent.revision,
        originalIntent.revision,
        reason: 'the restore brings the old network back',
      );
      // And both originals survive untouched.
      expect(
        after.where((r) => r.id == original.id || r.id == latest.id).length,
        2,
      );
    });
  });

  test('a schema-11 store upgrades and keeps its history chainable', () async {
    final dir = await Directory.systemTemp.createTemp('nb-version-upg');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    // A pre-v12 builds table without the identity columns.
    await db.execute('''
CREATE TABLE builds(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 projectName TEXT NOT NULL,
 instruction TEXT NOT NULL,
 intentJson TEXT NOT NULL,
 target TEXT NOT NULL,
 success INTEGER NOT NULL DEFAULT 1,
 status TEXT NOT NULL DEFAULT 'verified',
 error TEXT,
 fix TEXT,
 createdAt TEXT NOT NULL
)''');
    await MemoryService.upgradeSchema(db, 11, 12);
    final mem = MemoryService(injected: db);
    final first = await mem.logBuild(
      record('legacy', '1 router', status: 'verified'),
    );
    final parent = (await mem.recentBuilds()).firstWhere((r) => r.id == first);
    final second = await PlanVersionService.saveEditedPlan(
      memory: mem,
      intent: NetworkIntent.parseSimple('legacy', '2 routers'),
      previous: parent,
    );
    expect(second.parentVersionId, first);
    expect(second.projectKey, 'legacy');
  });
}
