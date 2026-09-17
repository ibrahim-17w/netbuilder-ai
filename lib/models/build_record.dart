// Build history record + learned rule models (pure Dart, testable).
class BuildRecord {
  final int? id;
  final String projectName;
  final String instruction;
  final String intentJson;
  final String target; // gns3, cisco-ssh, packet-tracer, aws
  final bool success;

  /// Lifecycle status is more precise than the legacy success flag.
  /// planned means generated but not executed; verified means evidence exists.
  final String status;
  final String? error;
  final String? fix;
  final DateTime createdAt;

  const BuildRecord({
    this.id,
    required this.projectName,
    required this.instruction,
    required this.intentJson,
    required this.target,
    this.success = true,
    this.status = 'verified',
    this.error,
    this.fix,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'projectName': projectName,
    'instruction': instruction,
    'intentJson': intentJson,
    'target': target,
    'success': success ? 1 : 0,
    'status': status,
    'error': error,
    'fix': fix,
    'createdAt': createdAt.toIso8601String(),
  };

  factory BuildRecord.fromMap(Map<String, dynamic> m) => BuildRecord(
    id: m['id'] as int?,
    projectName: m['projectName'] as String? ?? '',
    instruction: m['instruction'] as String? ?? '',
    intentJson: m['intentJson'] as String? ?? '{}',
    target: m['target'] as String? ?? 'gns3',
    success: (m['success'] as int? ?? 1) == 1,
    status:
        m['status'] as String? ??
        ((m['success'] as int? ?? 1) == 1 ? 'verified' : 'failed'),
    error: m['error'] as String?,
    fix: m['fix'] as String?,
    createdAt:
        DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class LearnedRule {
  final int? id;
  final String ruleText;
  final String targets; // csv: gns3,cisco
  final int hits;
  final int misses;

  const LearnedRule({
    this.id,
    required this.ruleText,
    this.targets = 'all',
    this.hits = 0,
    this.misses = 0,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'ruleText': ruleText,
    'targets': targets,
    'hits': hits,
    'misses': misses,
  };

  factory LearnedRule.fromMap(Map<String, dynamic> m) => LearnedRule(
    id: m['id'] as int?,
    ruleText: m['ruleText'] as String? ?? '',
    targets: m['targets'] as String? ?? 'all',
    hits: m['hits'] as int? ?? 0,
    misses: m['misses'] as int? ?? 0,
  );
}
