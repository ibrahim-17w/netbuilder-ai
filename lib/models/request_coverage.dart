import 'request_contract_utils.dart';
import 'request_requirement.dart';

enum PlanningStatus { satisfied, violated, unresolved, unsupported, superseded }

enum DeliveryStatus { notRequested, pending, verified, mismatch, unverified }

/// One independent observation supporting a requirement's delivery state.
class RequirementEvidence {
  final String requirementId;
  final String planRevision;
  final String target;
  final RequirementPhase phase;
  final String artifactHash;
  final Object? measuredValue;
  final String checker;
  final String checkedAt;
  final String explanation;

  RequirementEvidence({
    required this.requirementId,
    required this.planRevision,
    required this.target,
    required this.phase,
    this.artifactHash = '',
    Object? measuredValue,
    required this.checker,
    required this.checkedAt,
    this.explanation = '',
  }) : measuredValue = freezeJsonValue(
         measuredValue,
         label: 'RequirementEvidence measuredValue',
       ) {
    if (requirementId.trim().isEmpty || checker.trim().isEmpty) {
      throw const FormatException(
        'Evidence requirementId and checker must not be empty.',
      );
    }
  }

  factory RequirementEvidence.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequirementEvidence');
    rejectUnknownFields(json, {
      'requirementId',
      'planRevision',
      'target',
      'phase',
      'artifactHash',
      'measuredValue',
      'checker',
      'checkedAt',
      'explanation',
    }, 'RequirementEvidence');
    return RequirementEvidence(
      requirementId: readString(json, 'requirementId', allowEmpty: false),
      planRevision: readString(json, 'planRevision', defaultValue: ''),
      target: readString(json, 'target', defaultValue: ''),
      phase: readEnum(
        json['phase'],
        RequirementPhase.values,
        'evidence phase',
        defaultValue: RequirementPhase.planning,
      ),
      artifactHash: readString(json, 'artifactHash', defaultValue: ''),
      measuredValue: json['measuredValue'],
      checker: readString(json, 'checker', allowEmpty: false),
      checkedAt: readString(json, 'checkedAt', defaultValue: ''),
      explanation: readString(json, 'explanation', defaultValue: ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'requirementId': requirementId,
    'planRevision': planRevision,
    'target': target,
    'phase': phase.name,
    'artifactHash': artifactHash,
    'measuredValue': mutableJsonCopy(measuredValue),
    'checker': checker,
    'checkedAt': checkedAt,
    'explanation': explanation,
  };

  @override
  bool operator ==(Object other) =>
      other is RequirementEvidence && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// Planning and delivery status are separate: a correct plan is not proof
/// that an artifact or a live network has been verified.
class RequirementCoverage {
  final String requirementId;
  final PlanningStatus planning;
  final DeliveryStatus delivery;
  final List<RequirementEvidence> evidence;
  final String explanation;

  RequirementCoverage({
    required this.requirementId,
    this.planning = PlanningStatus.unresolved,
    this.delivery = DeliveryStatus.notRequested,
    List<RequirementEvidence> evidence = const [],
    this.explanation = '',
  }) : evidence = List.unmodifiable(evidence) {
    if (requirementId.trim().isEmpty) {
      throw const FormatException('Coverage requirementId must not be empty.');
    }
    if (this.evidence.any((item) => item.requirementId != requirementId)) {
      throw const FormatException(
        'Coverage evidence must reference the same requirementId.',
      );
    }
  }

  factory RequirementCoverage.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequirementCoverage');
    rejectUnknownFields(json, {
      'requirementId',
      'planning',
      'delivery',
      'evidence',
      'explanation',
    }, 'RequirementCoverage');
    final rawEvidence = json['evidence'] ?? const [];
    if (rawEvidence is! List) {
      throw const FormatException('Coverage evidence must be a list.');
    }
    return RequirementCoverage(
      requirementId: readString(json, 'requirementId', allowEmpty: false),
      planning: readEnum(
        json['planning'],
        PlanningStatus.values,
        'planning status',
        defaultValue: PlanningStatus.unresolved,
      ),
      delivery: readEnum(
        json['delivery'],
        DeliveryStatus.values,
        'delivery status',
        defaultValue: DeliveryStatus.notRequested,
      ),
      evidence: [
        for (final item in rawEvidence) RequirementEvidence.fromJson(item),
      ],
      explanation: readString(json, 'explanation', defaultValue: ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'requirementId': requirementId,
    'planning': planning.name,
    'delivery': delivery.name,
    'evidence': evidence.map((item) => item.toJson()).toList(),
    'explanation': explanation,
  };

  @override
  bool operator ==(Object other) =>
      other is RequirementCoverage && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// Coverage entries for the active request, kept in requirement order.
class CoverageReport {
  static const currentSchemaVersion = 1;

  final List<RequirementCoverage> requirements;
  final int schemaVersion;

  CoverageReport({
    List<RequirementCoverage> requirements = const [],
    this.schemaVersion = currentSchemaVersion,
  }) : requirements = List.unmodifiable(requirements) {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported CoverageReport schemaVersion $schemaVersion.',
      );
    }
    final ids = this.requirements.map((entry) => entry.requirementId).toList();
    if (ids.toSet().length != ids.length) {
      throw const FormatException(
        'CoverageReport cannot contain duplicate requirement IDs.',
      );
    }
  }

  RequirementCoverage? forRequirement(String id) {
    for (final entry in requirements) {
      if (entry.requirementId == id) return entry;
    }
    return null;
  }

  factory CoverageReport.fromJson(Object? value) {
    final json = strictJsonObject(value, 'CoverageReport');
    rejectUnknownFields(json, {
      'schemaVersion',
      'requirements',
    }, 'CoverageReport');
    final rawRequirements = json['requirements'] ?? const [];
    if (rawRequirements is! List) {
      throw const FormatException(
        'CoverageReport requirements must be a list.',
      );
    }
    return CoverageReport(
      requirements: [
        for (final item in rawRequirements) RequirementCoverage.fromJson(item),
      ],
      schemaVersion: readSchemaVersion(json, label: 'CoverageReport'),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'requirements': requirements.map((entry) => entry.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is CoverageReport && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}
