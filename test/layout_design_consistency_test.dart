import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_attempt.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/layout_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the selected preview matches the positions sent to the builder', () {
    final base = NetworkIntent.parseSimple(
      'office',
      '2 routers, 2 switches, 4 PCs and 1 server',
    );
    final intent = base.copyWith(
      notes: [
        LayoutRequest.noteFor(
          'grouped',
          zones: [
            LayoutZoneRequest(kinds: ['server'], edge: 'right'),
            LayoutZoneRequest(kinds: ['router'], edge: 'left'),
          ],
        ),
      ],
    );

    final preview = LayoutRequest.previewFromNotes(intent)!;
    final builderLayout = PacketTracerAdapter.resolveLayoutForEngine(
      intent,
      PacketTracerAdapter.intentLayoutFromNotes(intent),
    );

    expect({
      for (final spot in preview.spots)
        spot.name: [spot.x.toInt(), spot.y.toInt()],
    }, builderLayout['positions']);
  });

  test(
    'a design choice updates the pending plan and its pending attempt',
    () async {
      final dir = await Directory.systemTemp.createTemp('nb-layout-choice-');
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/memory.db');
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await MemoryService.createSchema(db);
      final memory = MemoryService(injected: db);
      final now = DateTime.utc(2026, 10, 15);
      final initial = NetworkIntent.parseSimple(
        'office',
        '1 router and 1 switch',
      );
      final recordId = await memory.logBuild(
        BuildRecord(
          projectName: initial.projectName,
          instruction: '1 router and 1 switch',
          intentJson: jsonEncode(initial.toJson(includeSecrets: false)),
          target: 'packet-tracer',
          success: false,
          status: 'planned',
          createdAt: now,
        ),
      );
      await memory.logAttempt(
        BuildAttempt(
          buildId: recordId,
          projectName: initial.projectName,
          instruction: '1 router and 1 switch',
          intentJson: jsonEncode(initial.toJson(includeSecrets: false)),
          target: 'packet-tracer',
          status: 'planned',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final chosen = initial.copyWith(
        notes: [LayoutRequest.noteFor('backbone')],
      );

      expect(
        await memory.updatePlannedBuildIntent(id: recordId, intent: chosen),
        isTrue,
      );
      final buildRow = (await db.query(
        'builds',
        where: 'id=?',
        whereArgs: [recordId],
      )).single;
      final attemptRow = (await db.query(
        'attempts',
        where: 'buildId=?',
        whereArgs: [recordId],
      )).single;
      expect(
        LayoutRequest.styleFromNote(
          NetworkIntent.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(buildRow['intentJson']! as String) as Map,
            ),
          ).notes.single,
        ),
        'backbone',
      );
      expect(
        LayoutRequest.styleFromNote(
          NetworkIntent.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(attemptRow['intentJson']! as String) as Map,
            ),
          ).notes.single,
        ),
        'backbone',
      );
    },
  );
}
