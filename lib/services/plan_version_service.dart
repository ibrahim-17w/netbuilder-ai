import 'dart:convert';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../models/request_interpretation.dart';
import 'memory_service.dart';
import 'request_understanding/build_action_identity.dart';

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
    RequestOutcome? requestOutcome,
    BuildActionIdentity? actionIdentity,
  }) async {
    if (memory == null || !memory.ready) return null;
    final identity =
        actionIdentity ??
        (requestOutcome == null
            ? null
            : BuildActionIdentity.forPlan(
                plan: intent,
                requirements: requestOutcome.interpretation.requirements,
                target: target,
                projectId: requestOutcome.interpretation.projectId.isEmpty
                    ? null
                    : requestOutcome.interpretation.projectId,
              ));
    final previous = await memory.latestBuildNamed(intent.projectName);
    if (previous != null &&
        matchesBuildPlan(
          previous,
          intent: intent,
          target: target,
          actionIdentity: identity,
        )) {
      return previous.id;
    }
    return memory.logBuild(
      BuildRecord(
        projectName: intent.projectName,
        instruction: instruction,
        // Reserved envelopes are ignored by NetworkIntent.fromJson. History
        // can restore requirements without fabricating provenance from prose.
        intentJson: jsonEncode({
          ...intent.toJson(),
          if (requestOutcome != null) 'requestOutcome': requestOutcome.toJson(),
          if (identity != null) 'buildActionIdentity': identity.toJson(),
        }),
        target: target,
        success: false,
        status: 'planned',
        createdAt: DateTime.now(),
        projectKey: projectKeyOf(previous, intent.projectName),
        parentVersionId: previous?.id,
      ),
    );
  }

  static Map<String, dynamic>? _envelope(BuildRecord record) {
    try {
      final value = jsonDecode(record.intentJson);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  static RequestOutcome? requestOutcomeOf(BuildRecord record) {
    final value = _envelope(record)?['requestOutcome'];
    if (value == null) return null;
    try {
      return RequestOutcome.fromJson(value);
    } catch (_) {
      return null;
    }
  }

  static BuildActionIdentity? actionIdentityOf(BuildRecord record) {
    final value = _envelope(record)?['buildActionIdentity'];
    if (value == null) return null;
    try {
      return BuildActionIdentity.fromJson(value);
    } catch (_) {
      return null;
    }
  }

  /// Reuse is safe only for the same semantic AND build/layout revision.
  /// When requirements were supplied, legacy rows without that binding cannot
  /// satisfy them. Malformed older rows append a new version rather than crash.
  static bool matchesBuildPlan(
    BuildRecord record, {
    required NetworkIntent intent,
    required String target,
    BuildActionIdentity? actionIdentity,
  }) {
    if (record.target != target) return false;
    final json = _envelope(record);
    if (json == null) return false;
    try {
      final old = NetworkIntent.fromJson(json);
      if (old.revision != intent.revision ||
          old.buildRevision != intent.buildRevision ||
          BuildActionIdentity.digestJson({
                for (final node in old.nodes) node.name: node.siteId,
              }) !=
              BuildActionIdentity.digestJson({
                for (final node in intent.nodes) node.name: node.siteId,
              })) {
        return false;
      }
      final storedIdentity = actionIdentityOf(record);
      return actionIdentity == null
          ? storedIdentity == null
          : actionIdentity.isComplete && storedIdentity == actionIdentity;
    } catch (_) {
      return false;
    }
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
    final priorOutcome = previous == null ? null : requestOutcomeOf(previous);
    // Keep the old interpretation/evidence for forensics. Its action identity
    // is deliberately not copied onto a changed plan as current proof.
    if (priorOutcome != null) json['requestOutcome'] = priorOutcome.toJson();
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
      intentJson: jsonEncode({
        ...intent.toPlannerJson(),
        if (requestOutcomeOf(original) != null)
          'requestOutcome': requestOutcomeOf(original)!.toJson(),
      }),
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
