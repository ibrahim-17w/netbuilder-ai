import 'dart:convert';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'memory_service.dart';

/// Persists topology edits as a new history row before the app switches to it.
class PlanVersionService {
  const PlanVersionService._();

  static Future<BuildRecord> saveEditedPlan({
    required MemoryService memory,
    required NetworkIntent intent,
    required BuildRecord? previous,
    DateTime? now,
  }) async {
    if (!memory.ready) {
      throw StateError(
        'Local history is unavailable. Try again after it opens.',
      );
    }
    final createdAt = now ?? DateTime.now();
    final json = intent.toPlannerJson();
    final row = BuildRecord(
      projectName: intent.projectName,
      instruction:
          'Edited topology · ${previous?.instruction ?? 'manual plan'}',
      intentJson: jsonEncode(json),
      target: previous?.target ?? 'packet-tracer',
      success: false,
      status: 'planned',
      createdAt: createdAt,
    );
    final id = await memory.logBuild(row);
    return BuildRecord(
      id: id,
      projectName: row.projectName,
      instruction: row.instruction,
      intentJson: row.intentJson,
      target: row.target,
      success: row.success,
      status: row.status,
      createdAt: row.createdAt,
    );
  }
}
