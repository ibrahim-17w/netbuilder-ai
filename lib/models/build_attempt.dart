import 'dart:convert';

/// A durable record of one plan/execution/verification cycle.
/// Unlike a loose learned rule, this keeps the evidence that justifies it.
class BuildAttempt {
  final int? id;
  final int? buildId;
  final String projectName;
  final String instruction;
  final String intentJson;
  final String target;
  final String
  status; // planned, executing, verified, failed, unknown, corrected
  final String? failureKind;
  final String? failureDetail;
  final String? evidenceJson;
  final String? correction;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BuildAttempt({
    this.id,
    this.buildId,
    required this.projectName,
    required this.instruction,
    required this.intentJson,
    required this.target,
    this.status = 'planned',
    this.failureKind,
    this.failureDetail,
    this.evidenceJson,
    this.correction,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'buildId': buildId,
    'projectName': projectName,
    'instruction': instruction,
    'intentJson': intentJson,
    'target': target,
    'status': status,
    'failureKind': failureKind,
    'failureDetail': failureDetail,
    'evidenceJson': evidenceJson,
    'correction': correction,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory BuildAttempt.fromMap(Map<String, dynamic> m) => BuildAttempt(
    id: m['id'] as int?,
    buildId: m['buildId'] as int?,
    projectName: m['projectName'] as String? ?? '',
    instruction: m['instruction'] as String? ?? '',
    intentJson: m['intentJson'] as String? ?? '{}',
    target: m['target'] as String? ?? 'gns3',
    status: m['status'] as String? ?? 'planned',
    failureKind: m['failureKind'] as String?,
    failureDetail: m['failureDetail'] as String?,
    evidenceJson: m['evidenceJson'] as String?,
    correction: m['correction'] as String?,
    createdAt:
        DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );

  static String evidence(Object value) => jsonEncode(value);
}
