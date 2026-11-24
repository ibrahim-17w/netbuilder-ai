import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/network_intent.dart';
import '../../models/request_contract_utils.dart';
import '../../models/request_requirement.dart';

/// Immutable inputs to an artifact action. A path alone is never an identity.
/// The generated content hash is bound separately, after saved-byte read-back.
class BuildActionIdentity {
  final String projectId;
  final String planRevision;
  final String buildRevision;
  final String requirementsDigest;
  final String target;
  final String scope;
  final String layoutIdentity;
  final String outputIdentity;

  const BuildActionIdentity({
    required this.projectId,
    required this.planRevision,
    required this.buildRevision,
    required this.requirementsDigest,
    required this.target,
    required this.scope,
    required this.layoutIdentity,
    required this.outputIdentity,
  });

  factory BuildActionIdentity.forPlan({
    required NetworkIntent plan,
    required Iterable<Requirement> requirements,
    required String target,
    String? projectId,
    String scope = 'project',
    String output = 'pkt',
    Map<String, dynamic> outputOptions = const {},
  }) => BuildActionIdentity(
    projectId: (projectId ?? plan.projectName).trim(),
    planRevision: plan.revision,
    buildRevision: plan.buildRevision,
    requirementsDigest: digestRequirements(requirements),
    target: target.trim().toLowerCase(),
    scope: digestJson({
      'scope': scope.trim(),
      'sites': {for (final node in plan.nodes) node.name: node.siteId},
    }),
    layoutIdentity: digestJson({
      'notes': plan.notes
          .where((note) => note.trim().toLowerCase().startsWith('layout:'))
          .map((note) => note.trim())
          .toList(),
      'positions': {
        for (final entry in plan.layout.entries)
          entry.key: entry.value == null
              ? null
              : {'x': entry.value!.dx, 'y': entry.value!.dy},
      },
    }),
    outputIdentity: digestJson({'format': output, 'options': outputOptions}),
  );

  /// Stable regardless of map insertion order or requirement list order.
  /// Include unresolved/superseded facts too: accepting a replacement changes
  /// the requirement-set version even when the candidate plan did not change.
  static String digestRequirements(Iterable<Requirement> requirements) {
    final rows = requirements.map((item) => item.toJson()).toList()
      ..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
    return digestJson(rows);
  }

  static String digestJson(Object? value) =>
      sha256.convert(utf8.encode(_canonical(value))).toString();

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
    }
    if (value is Iterable) return '[${value.map(_canonical).join(',')}]';
    return jsonEncode(value);
  }

  bool get isComplete => [
    projectId,
    planRevision,
    buildRevision,
    requirementsDigest,
    target,
    scope,
    layoutIdentity,
    outputIdentity,
  ].every((value) => value.trim().isNotEmpty);

  String get key => digestJson(toJson());

  /// Semantic and drawing checks must remain separate for layout-only edits.
  static bool preservesSemantics(NetworkIntent before, NetworkIntent after) =>
      before.revision == after.revision &&
      digestJson({for (final node in before.nodes) node.name: node.siteId}) ==
          digestJson({for (final node in after.nodes) node.name: node.siteId});

  factory BuildActionIdentity.fromJson(Object? value) {
    final json = strictJsonObject(value, 'BuildActionIdentity');
    rejectUnknownFields(json, {
      'projectId',
      'planRevision',
      'buildRevision',
      'requirementsDigest',
      'target',
      'scope',
      'layoutIdentity',
      'outputIdentity',
    }, 'BuildActionIdentity');
    return BuildActionIdentity(
      projectId: readString(json, 'projectId', defaultValue: ''),
      planRevision: readString(json, 'planRevision', defaultValue: ''),
      buildRevision: readString(json, 'buildRevision', defaultValue: ''),
      requirementsDigest: readString(
        json,
        'requirementsDigest',
        defaultValue: '',
      ),
      target: readString(json, 'target', defaultValue: ''),
      scope: readString(json, 'scope', defaultValue: ''),
      layoutIdentity: readString(json, 'layoutIdentity', defaultValue: ''),
      outputIdentity: readString(json, 'outputIdentity', defaultValue: ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'planRevision': planRevision,
    'buildRevision': buildRevision,
    'requirementsDigest': requirementsDigest,
    'target': target,
    'scope': scope,
    'layoutIdentity': layoutIdentity,
    'outputIdentity': outputIdentity,
  };

  @override
  bool operator ==(Object other) =>
      other is BuildActionIdentity && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}
