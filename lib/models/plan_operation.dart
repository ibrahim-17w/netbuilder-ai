import 'request_contract_utils.dart';
import 'request_requirement.dart';

enum PlanOperationKind {
  addDevices,
  setDeviceCount,
  removeDevices,
  renameDevice,
  setRouting,
  setDeviceModel,
  assignService,
  removeService,
  setAddress,
  setVlanMembership,
  setLink,
  setLayout,
  preserve,
}

/// A closed, validated request to change a plan. Payload keys are limited to
/// the operation's declared shape; model output cannot name arbitrary paths.
class PlanOperation {
  static const currentSchemaVersion = 1;

  final String operationId;
  final PlanOperationKind kind;
  final List<String> requirementIds;
  final List<SourceSpan> sourceSpans;
  final String projectId;
  final String baseRevision;
  final RequirementScope scope;
  final Map<String, Object?> payload;
  final int schemaVersion;

  PlanOperation({
    required this.operationId,
    required this.kind,
    required List<String> requirementIds,
    List<SourceSpan> sourceSpans = const [],
    required this.projectId,
    required this.baseRevision,
    required this.scope,
    required Map<String, Object?> payload,
    this.schemaVersion = currentSchemaVersion,
  }) : requirementIds = List.unmodifiable(requirementIds),
       sourceSpans = List.unmodifiable(sourceSpans),
       payload = freezeJsonMap(payload, label: 'PlanOperation payload') {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported PlanOperation schemaVersion $schemaVersion.',
      );
    }
    if (operationId.trim().isEmpty ||
        projectId.trim().isEmpty ||
        baseRevision.trim().isEmpty) {
      throw const FormatException(
        'PlanOperation identity and baseRevision must not be empty.',
      );
    }
    if (this.requirementIds.isEmpty ||
        this.requirementIds.any((id) => id.trim().isEmpty)) {
      throw const FormatException(
        'PlanOperation must reference at least one requirement.',
      );
    }
    _validatePayload();
  }

  factory PlanOperation.fromJson(Object? value) {
    final json = strictJsonObject(value, 'PlanOperation');
    rejectUnknownFields(json, {
      'schemaVersion',
      'operationId',
      'kind',
      'requirementIds',
      'sourceSpans',
      'projectId',
      'baseRevision',
      'scope',
      'payload',
    }, 'PlanOperation');
    final rawSpans = json['sourceSpans'] ?? const [];
    if (rawSpans is! List) {
      throw const FormatException('PlanOperation sourceSpans must be a list.');
    }
    final rawPayload = strictJsonObject(
      json['payload'],
      'PlanOperation payload',
    );
    return PlanOperation(
      operationId: readString(json, 'operationId', allowEmpty: false),
      kind: readEnum(
        json['kind'],
        PlanOperationKind.values,
        'plan operation kind',
      ),
      requirementIds: readStringList(json['requirementIds'], 'requirementIds'),
      sourceSpans: [for (final span in rawSpans) SourceSpan.fromJson(span)],
      projectId: readString(json, 'projectId', allowEmpty: false),
      baseRevision: readString(json, 'baseRevision', allowEmpty: false),
      scope: RequirementScope.fromJson(json['scope']),
      payload: rawPayload,
      schemaVersion: readSchemaVersion(json, label: 'PlanOperation'),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'operationId': operationId,
    'kind': kind.name,
    'requirementIds': requirementIds.toList(),
    'sourceSpans': sourceSpans.map((span) => span.toJson()).toList(),
    'projectId': projectId,
    'baseRevision': baseRevision,
    'scope': scope.toJson(),
    'payload': mutableJsonCopy(payload),
  };

  PlanOperation copyWith({
    String? operationId,
    PlanOperationKind? kind,
    List<String>? requirementIds,
    List<SourceSpan>? sourceSpans,
    String? projectId,
    String? baseRevision,
    RequirementScope? scope,
    Map<String, Object?>? payload,
  }) => PlanOperation(
    operationId: operationId ?? this.operationId,
    kind: kind ?? this.kind,
    requirementIds: requirementIds ?? this.requirementIds,
    sourceSpans: sourceSpans ?? this.sourceSpans,
    projectId: projectId ?? this.projectId,
    baseRevision: baseRevision ?? this.baseRevision,
    scope: scope ?? this.scope,
    payload: payload ?? this.payload,
  );

  void _validatePayload() {
    final (requiredFields, optionalFields) = _payloadFields(kind);
    final keys = payload.keys.toSet();
    final missing = requiredFields.difference(keys);
    if (missing.isNotEmpty) {
      throw FormatException(
        '${kind.name} is missing payload field(s): ${missing.toList()..sort()}.',
      );
    }
    rejectUnknownFields(payload, {
      ...requiredFields,
      ...optionalFields,
    }, '${kind.name} payload');
    _rejectRawSecretFields(payload);
    switch (kind) {
      case PlanOperationKind.addDevices:
        _readPayloadString('kind');
        _readPayloadInt('count', minimum: 1);
        _readPayloadStringList('names', optional: true);
        if (scope.kind != RequirementScopeKind.project &&
            scope.kind != RequirementScopeKind.site) {
          throw const FormatException(
            'addDevices requires project-wide or site scope.',
          );
        }
      case PlanOperationKind.setDeviceCount:
        _readPayloadString('kind');
        _readPayloadInt('total', minimum: 0);
        if (scope.kind != RequirementScopeKind.project &&
            scope.kind != RequirementScopeKind.site) {
          throw const FormatException(
            'setDeviceCount requires project-wide or site scope.',
          );
        }
      case PlanOperationKind.removeDevices:
        _readPayloadStringList('deviceIds');
      case PlanOperationKind.renameDevice:
        _readPayloadString('deviceId');
        _readPayloadString('newName');
      case PlanOperationKind.setRouting:
        final protocol = _readPayloadString('protocol').toLowerCase();
        if (!const {
          'static',
          'ospf',
          'eigrp',
          'bgp',
          'none',
        }.contains(protocol)) {
          throw FormatException('Unsupported routing protocol "$protocol".');
        }
      case PlanOperationKind.setDeviceModel:
        _readPayloadStringList('deviceIds');
        _readPayloadString('model');
      case PlanOperationKind.assignService:
      case PlanOperationKind.removeService:
        _readPayloadString('deviceId');
        _readPayloadString('service');
        if (payload['settings'] != null && payload['settings'] is! Map) {
          throw const FormatException('service settings must be an object.');
        }
      case PlanOperationKind.setAddress:
        _readPayloadString('deviceId');
        _readPayloadString('interfaceId');
        final family = _readPayloadString('family').toLowerCase();
        if (family != 'ipv4' && family != 'ipv6') {
          throw const FormatException('Address family must be ipv4 or ipv6.');
        }
        _readPayloadString('value');
      case PlanOperationKind.setVlanMembership:
        _readPayloadStringList('deviceIds');
        _readPayloadInt('vlanId', minimum: 1, maximum: 4094);
        final mode = _readPayloadString('mode').toLowerCase();
        if (mode != 'access' && mode != 'trunk') {
          throw const FormatException('VLAN mode must be access or trunk.');
        }
      case PlanOperationKind.setLink:
        final action = _readPayloadString('action').toLowerCase();
        if (!const {'add', 'remove', 'replace'}.contains(action)) {
          throw const FormatException(
            'Link action must be add, remove or replace.',
          );
        }
        for (final key in const [
          'aDeviceId',
          'aInterfaceId',
          'bDeviceId',
          'bInterfaceId',
          'cableType',
        ]) {
          _readPayloadString(key);
        }
      case PlanOperationKind.setLayout:
        _readPayloadString('style');
        if (payload['zones'] != null && payload['zones'] is! Map) {
          throw const FormatException('layout zones must be an object.');
        }
      case PlanOperationKind.preserve:
        final wholeDesign = payload['entireSemantic'] == true;
        final properties = payload['properties'];
        if (!wholeDesign &&
            (properties is! List ||
                properties.isEmpty ||
                properties.any((v) => v is! String))) {
          throw const FormatException(
            'preserve requires properties or entireSemantic=true.',
          );
        }
    }
  }

  String _readPayloadString(String key) =>
      readString(payload.cast<String, dynamic>(), key, allowEmpty: false);

  int _readPayloadInt(String key, {int? minimum, int? maximum}) => readInt(
    payload.cast<String, dynamic>(),
    key,
    minimum: minimum,
    maximum: maximum,
  );

  List<String> _readPayloadStringList(String key, {bool optional = false}) {
    final raw = payload[key];
    if (optional && raw == null) return const [];
    return readStringList(raw, key);
  }

  static (Set<String>, Set<String>) _payloadFields(PlanOperationKind kind) =>
      switch (kind) {
        PlanOperationKind.addDevices => ({'kind', 'count'}, {'names'}),
        PlanOperationKind.setDeviceCount => (
          {'kind', 'total'},
          const <String>{},
        ),
        PlanOperationKind.removeDevices => ({'deviceIds'}, const <String>{}),
        PlanOperationKind.renameDevice => (
          {'deviceId', 'newName'},
          const <String>{},
        ),
        PlanOperationKind.setRouting => ({'protocol'}, const <String>{}),
        PlanOperationKind.setDeviceModel => (
          {'deviceIds', 'model'},
          const <String>{},
        ),
        PlanOperationKind.assignService || PlanOperationKind.removeService => (
          {'deviceId', 'service'},
          {'settings'},
        ),
        PlanOperationKind.setAddress => (
          {'deviceId', 'interfaceId', 'family', 'value'},
          const <String>{},
        ),
        PlanOperationKind.setVlanMembership => (
          {'deviceIds', 'vlanId', 'mode'},
          const <String>{},
        ),
        PlanOperationKind.setLink => (
          {
            'action',
            'aDeviceId',
            'aInterfaceId',
            'bDeviceId',
            'bInterfaceId',
            'cableType',
          },
          const <String>{},
        ),
        PlanOperationKind.setLayout => ({'style'}, {'zones'}),
        PlanOperationKind.preserve => (
          const <String>{},
          {'properties', 'entireSemantic'},
        ),
      };

  static void _rejectRawSecretFields(Object? value) {
    if (value is List) {
      for (final item in value) {
        _rejectRawSecretFields(item);
      }
      return;
    }
    if (value is! Map) return;
    for (final entry in value.entries) {
      final key = '${entry.key}'.toLowerCase();
      final isSecretReference = const {
        'secretref',
        'passwordref',
        'pskref',
        'vaultref',
      }.contains(key);
      if ((key.contains('password') ||
              key.contains('secret') ||
              key == 'psk') &&
          !isSecretReference) {
        throw FormatException(
          'Raw secret field "${entry.key}" is not allowed; use a vault reference.',
        );
      }
      if (isSecretReference &&
          (entry.value is! String ||
              !(entry.value as String).startsWith('vault:'))) {
        throw FormatException('"${entry.key}" must contain a vault reference.');
      }
      _rejectRawSecretFields(entry.value);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PlanOperation && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// Ordered candidate edits and the difference they propose from one exact
/// base revision. Applying this value is a later task; this model is data only.
class PlanChangeSet {
  static const currentSchemaVersion = 1;

  final String projectId;
  final String baseRevision;
  final String candidateRevision;
  final List<PlanOperation> operations;
  final Map<String, Object?> oldValues;
  final Map<String, Object?> newValues;
  final List<String> incidentalChanges;
  final List<String> reasons;
  final int schemaVersion;

  PlanChangeSet({
    required this.projectId,
    required this.baseRevision,
    required this.candidateRevision,
    List<PlanOperation> operations = const [],
    Map<String, Object?> oldValues = const {},
    Map<String, Object?> newValues = const {},
    List<String> incidentalChanges = const [],
    List<String> reasons = const [],
    this.schemaVersion = currentSchemaVersion,
  }) : operations = List.unmodifiable(operations),
       oldValues = freezeJsonMap(oldValues, label: 'oldValues'),
       newValues = freezeJsonMap(newValues, label: 'newValues'),
       incidentalChanges = List.unmodifiable(incidentalChanges),
       reasons = List.unmodifiable(reasons) {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported PlanChangeSet schemaVersion $schemaVersion.',
      );
    }
    if (projectId.trim().isEmpty ||
        baseRevision.trim().isEmpty ||
        candidateRevision.trim().isEmpty) {
      throw const FormatException(
        'PlanChangeSet project and revision identities must not be empty.',
      );
    }
  }

  factory PlanChangeSet.fromJson(Object? value) {
    final json = strictJsonObject(value, 'PlanChangeSet');
    rejectUnknownFields(json, {
      'schemaVersion',
      'projectId',
      'baseRevision',
      'candidateRevision',
      'operations',
      'oldValues',
      'newValues',
      'incidentalChanges',
      'reasons',
    }, 'PlanChangeSet');
    final rawOperations = json['operations'] ?? const [];
    if (rawOperations is! List) {
      throw const FormatException('PlanChangeSet operations must be a list.');
    }
    final oldValues = json['oldValues'] == null
        ? <String, dynamic>{}
        : strictJsonObject(json['oldValues'], 'PlanChangeSet oldValues');
    final newValues = json['newValues'] == null
        ? <String, dynamic>{}
        : strictJsonObject(json['newValues'], 'PlanChangeSet newValues');
    return PlanChangeSet(
      projectId: readString(json, 'projectId', allowEmpty: false),
      baseRevision: readString(json, 'baseRevision', allowEmpty: false),
      candidateRevision: readString(
        json,
        'candidateRevision',
        allowEmpty: false,
      ),
      operations: [
        for (final operation in rawOperations)
          PlanOperation.fromJson(operation),
      ],
      oldValues: oldValues,
      newValues: newValues,
      incidentalChanges: json['incidentalChanges'] == null
          ? const []
          : readStringList(json['incidentalChanges'], 'incidentalChanges'),
      reasons: json['reasons'] == null
          ? const []
          : readStringList(json['reasons'], 'reasons'),
      schemaVersion: readSchemaVersion(json, label: 'PlanChangeSet'),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'projectId': projectId,
    'baseRevision': baseRevision,
    'candidateRevision': candidateRevision,
    'operations': operations.map((operation) => operation.toJson()).toList(),
    'oldValues': mutableJsonCopy(oldValues),
    'newValues': mutableJsonCopy(newValues),
    'incidentalChanges': incidentalChanges.toList(),
    'reasons': reasons.toList(),
  };

  PlanChangeSet copyWith({
    String? projectId,
    String? baseRevision,
    String? candidateRevision,
    List<PlanOperation>? operations,
    Map<String, Object?>? oldValues,
    Map<String, Object?>? newValues,
    List<String>? incidentalChanges,
    List<String>? reasons,
  }) => PlanChangeSet(
    projectId: projectId ?? this.projectId,
    baseRevision: baseRevision ?? this.baseRevision,
    candidateRevision: candidateRevision ?? this.candidateRevision,
    operations: operations ?? this.operations,
    oldValues: oldValues ?? this.oldValues,
    newValues: newValues ?? this.newValues,
    incidentalChanges: incidentalChanges ?? this.incidentalChanges,
    reasons: reasons ?? this.reasons,
  );

  @override
  bool operator ==(Object other) =>
      other is PlanChangeSet && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}
