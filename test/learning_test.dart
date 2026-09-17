import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:net_builder/models/build_attempt.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('learning memory keeps evidence and correction for a run', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await MemoryService.createSchema(db);
    final memory = MemoryService(injected: db);
    final intent = NetworkIntent.parseSimple('lab', '1 router 1 switch');
    final now = DateTime.now();
    final buildId = await memory.logBuild(
      BuildRecord(
        projectName: 'lab',
        instruction: '1 router 1 switch',
        intentJson: intent.toJson().toString(),
        target: 'packet-tracer',
        success: false,
        status: 'planned',
        createdAt: now,
      ),
    );
    final attemptId = await memory.logAttempt(
      BuildAttempt(
        buildId: buildId,
        projectName: 'lab',
        instruction: '1 router 1 switch',
        intentJson: intent.toJson().toString(),
        target: 'packet-tracer',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await memory.updateAttempt(
      id: attemptId,
      status: 'corrected',
      failureKind: 'placement_failed',
      failureDetail: 'Model thumbnail missed; device was not armed.',
      evidenceJson: BuildAttempt.evidence({'recovered': true}),
      correction: 'Teach the model thumbnail before retrying.',
    );

    final saved = await memory.latestAttemptForBuild(buildId);
    expect(saved?.status, 'corrected');
    expect(saved?.failureKind, 'placement_failed');
    expect(saved?.correction, contains('Teach'));
    expect(saved?.evidenceJson, contains('recovered'));
    await db.close();
  });
}
