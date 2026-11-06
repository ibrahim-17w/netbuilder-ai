import 'dart:convert';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'memory_service.dart';

/// Persists topology edits as a new history row before the app switches to
/// it, and reads a project's versions back as a chain.
///
/// Identity: every version of one project carries the same [BuildRecord
/// .projectKey] (the first version's project name), and each edit names the
/// build id it was made FROM in [BuildRecord.parentVersionId]. Legacy rows -
/// saved before those columns existed - have neither, so the timeline falls
/// back to the project name and treats parentless rows as roots instead of
/// inventing history that was never recorded.
class PlanVersionService {
  const PlanVersionService._();

  /// Chat builds join saved-project history before compilation. A repeat build
  /// reuses the unchanged version; a changed design appends a new version.
  static Future<int?> captureBuildPlan({
    required MemoryService? memory,
    required NetworkIntent intent,
    required String target,
    required String instruction,
  }) async {
    if (memory == null || !memory.ready) return null;
    final previous = await memory.latestBuildNamed(intent.projectName);
    if (previous != null &&
        previous.target == target &&
        NetworkIntent.fromJson(
              Map<String, dynamic>.from(jsonDecode(previous.intentJson)),
            ).revision ==
            intent.revision) {
      return previous.id;
    }
    return memory.logBuild(
      BuildRecord(
        projectName: intent.projectName,
        instruction: instruction,
        // MemoryService moves secrets to the vault and redacts the stored row.
        intentJson: jsonEncode(intent.toJson()),
        target: target,
        success: false,
        status: 'planned',
        createdAt: DateTime.now(),
        projectKey: projectKeyOf(previous, intent.projectName),
        parentVersionId: previous?.id,
      ),
    );
  }

  /// The key a project's versions share: the parent's key when it has one,
  /// else the parent's project name (a legacy row's implicit identity).
  static String projectKeyOf(BuildRecord? previous, [String fallback = '']) {
    if (previous == null) return fallback;
    final key = previous.projectKey.trim();
    if (key.isNotEmpty) return key;
    return previous.projectName.trim();
  }

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
      projectKey: projectKeyOf(previous, intent.projectName),
      parentVersionId: previous?.id,
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
      projectKey: row.projectKey,
      parentVersionId: row.parentVersionId,
    );
  }

  /// Every version of one project, OLDEST FIRST, so a timeline reads top to
  /// bottom the way the work happened. Legacy rows are matched by project
  /// name; keyed rows by their stable key - which is why a project renamed
  /// after its first version still keeps its history together.
  static Future<List<BuildRecord>> timeline(
    MemoryService memory, {
    required String projectKey,
  }) async {
    final key = projectKey.trim();
    if (key.isEmpty) return const [];
    final all = await memory.projectVersions(key);
    final rows =
        all
            .where(
              (r) =>
                  r.projectKey.trim() == key ||
                  (r.projectKey.trim().isEmpty && r.projectName.trim() == key),
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return rows;
  }

  /// RESTORE IS AN EDIT. The chosen version's plan becomes the plan of a
  /// NEW version parented to the project's newest row - nothing in history
  /// is rewritten, and both originals survive untouched.
  ///
  /// [latest] is the project's newest row (the restore is an edit of THAT,
  /// not of the old version), and [original] supplies the plan being
  /// brought back.
  static Future<BuildRecord> restoreVersion({
    required MemoryService memory,
    required BuildRecord original,
    required BuildRecord? latest,
    DateTime? now,
  }) async {
    final intent = NetworkIntent.fromJson(
      Map<String, dynamic>.from(jsonDecode(original.intentJson) as Map),
    );
    final createdAt = now ?? DateTime.now();
    final row = BuildRecord(
      projectName: intent.projectName,
      instruction:
          'Restored version #${original.id ?? '?'} · '
          '${latest?.instruction ?? 'manual plan'}',
      intentJson: jsonEncode(intent.toPlannerJson()),
      target: latest?.target ?? original.target,
      success: false,
      status: 'planned',
      createdAt: createdAt,
      projectKey: projectKeyOf(latest, intent.projectName),
      parentVersionId: latest?.id,
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
      projectKey: row.projectKey,
      parentVersionId: row.parentVersionId,
    );
  }
}
