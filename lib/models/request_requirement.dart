import 'package:net_builder/models/network_intent.dart';

import 'chat_message.dart' show AttachmentSource;
import 'request_contract_utils.dart';

export 'chat_message.dart' show AttachmentSource;

enum RequirementComparator { equals, atLeast, atMost, forbidden, preserve }

enum RequirementScopeKind {
  project,
  site,
  device,
  linkInterface,
  vlan,
  service,
  output,
}

enum RequirementOrigin {
  currentExplicit,
  establishedProject,
  imported,
  scopedRememberedPreference,
  environmentProfile,
  derivedDefault,
  unknown,
}

enum RequirementState { active, superseded, unresolved }

enum RequirementStrength { explicit, advisory }

enum RequirementPhase { planning, artifact, liveVerification }

enum QuantityRole {
  unspecified,
  increment,
  total,
  minimum,
  maximum,
  userLoad,
  deviceInventory,
  allocation,
}

/// A redacted excerpt from a message, using UTF-16 code-unit offsets.
class SourceSpan {
  final String messageId;
  final int start;
  final int end;
  final String excerpt;

  /// Null for legacy/user-message spans. Attachment offsets refer to the
  /// original reader output, not the shortened display quote.
  final AttachmentSource? attachment;

  SourceSpan({
    required this.messageId,
    required this.start,
    required this.end,
    required String excerpt,
    this.attachment,
  }) : excerpt = NetworkIntent.redactSecrets(excerpt) {
    if (messageId.trim().isEmpty) {
      throw const FormatException('SourceSpan messageId must not be empty.');
    }
    if (start < 0 || end < start) {
      throw const FormatException('SourceSpan has an invalid range.');
    }
  }

  factory SourceSpan.fromText({
    required String messageId,
    required String originalText,
    required int start,
    required int end,
    AttachmentSource? attachment,
  }) {
    if (start < 0 || end < start || end > originalText.length) {
      throw const FormatException(
        'SourceSpan range is outside the original message.',
      );
    }
    return SourceSpan(
      messageId: messageId,
      start: start,
      end: end,
      excerpt: originalText.substring(start, end),
      attachment: attachment,
    );
  }

  factory SourceSpan.fromJson(Object? value) {
    final json = strictJsonObject(value, 'SourceSpan');
    rejectUnknownFields(json, {
      'messageId',
      'start',
      'end',
      'excerpt',
      'attachment',
    }, 'SourceSpan');
    return SourceSpan(
      messageId: readString(json, 'messageId', allowEmpty: false),
      start: readInt(json, 'start', minimum: 0),
      end: readInt(json, 'end', minimum: 0),
      excerpt: readString(json, 'excerpt'),
      attachment: json['attachment'] == null
          ? null
          : AttachmentSource.fromMap(
              strictJsonObject(json['attachment'], 'SourceSpan attachment'),
            ),
    );
  }

  /// Validate this span against the original message before using it to map
  /// a normalized range back to user text.
  void validateAgainst(String originalText) {
    if (start < 0 || end < start || end > originalText.length) {
      throw const FormatException(
        'SourceSpan range is outside the original message.',
      );
    }
    if (excerpt !=
        NetworkIntent.redactSecrets(originalText.substring(start, end))) {
      throw const FormatException(
        'SourceSpan excerpt does not match its source.',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'start': start,
    'end': end,
    'excerpt': NetworkIntent.redactSecrets(excerpt),
    if (attachment != null) 'attachment': attachment!.toMap(),
  };

  @override
  bool operator ==(Object other) =>
      other is SourceSpan && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// The scope in which a requirement is valid. [scopeId] is a stable name
/// within the project and base revision, not a claim that devices already
/// have permanent IDs.
class RequirementScope {
  final RequirementScopeKind kind;
  final String scopeId;

  /// Optional ancestry/context. Local names remain compatible with old saved
  /// requests; VLAN 10 at HQ is distinct from VLAN 10 at a branch.
  final RequirementScope? parent;
  final String siteId;
  final String deviceId;
  final String networkRole;

  const RequirementScope({
    required this.kind,
    this.scopeId = '',
    this.parent,
    this.siteId = '',
    this.deviceId = '',
    this.networkRole = '',
  });

  String get owningSiteId => siteId.isNotEmpty
      ? siteId
      : kind == RequirementScopeKind.site
      ? scopeId
      : parent?.owningSiteId ?? '';

  String get owningDeviceId => deviceId.isNotEmpty
      ? deviceId
      : kind == RequirementScopeKind.device
      ? scopeId
      : parent?.owningDeviceId ?? '';

  Iterable<RequirementScope> get ancestry sync* {
    if (parent != null) {
      yield* parent!.ancestry;
      yield parent!;
    }
  }

  factory RequirementScope.project(String projectId) =>
      RequirementScope(kind: RequirementScopeKind.project, scopeId: projectId);

  factory RequirementScope.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequirementScope');
    rejectUnknownFields(json, {
      'kind',
      'scopeId',
      'parent',
      'siteId',
      'deviceId',
      'networkRole',
    }, 'RequirementScope');
    return RequirementScope(
      kind: readEnum(
        json['kind'],
        RequirementScopeKind.values,
        'requirement scope kind',
        defaultValue: RequirementScopeKind.project,
      ),
      scopeId: readString(json, 'scopeId', defaultValue: ''),
      parent: json['parent'] == null
          ? null
          : RequirementScope.fromJson(json['parent']),
      siteId: readString(json, 'siteId', defaultValue: ''),
      deviceId: readString(json, 'deviceId', defaultValue: ''),
      networkRole: readString(json, 'networkRole', defaultValue: ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'scopeId': scopeId,
    if (parent != null) 'parent': parent!.toJson(),
    if (siteId.isNotEmpty) 'siteId': siteId,
    if (deviceId.isNotEmpty) 'deviceId': deviceId,
    if (networkRole.isNotEmpty) 'networkRole': networkRole,
  };

  @override
  bool operator ==(Object other) =>
      other is RequirementScope && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// One typed, scoped fact that the plan or delivered artifact must respect.
class Requirement {
  static const currentSchemaVersion = 1;

  final String id;
  final String subject;
  final String property;
  final Object? value;
  final RequirementComparator comparator;
  final RequirementScope scope;
  final RequirementOrigin origin;
  final String sourceTurnId;
  final List<SourceSpan> sourceSpans;
  final RequirementState state;
  final String? supersedesId;
  final RequirementStrength strength;
  final RequirementPhase phase;
  final QuantityRole quantityRole;
  final String unit;
  final int schemaVersion;

  Requirement({
    required this.id,
    required this.subject,
    required this.property,
    Object? value,
    this.comparator = RequirementComparator.equals,
    required this.scope,
    this.origin = RequirementOrigin.unknown,
    this.sourceTurnId = '',
    List<SourceSpan> sourceSpans = const [],
    this.state = RequirementState.active,
    this.supersedesId,
    this.strength = RequirementStrength.advisory,
    this.phase = RequirementPhase.planning,
    this.quantityRole = QuantityRole.unspecified,
    this.unit = '',
    this.schemaVersion = currentSchemaVersion,
  }) : sourceSpans = List.unmodifiable(sourceSpans),
       value = freezeJsonValue(value, label: 'Requirement value') {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported Requirement schemaVersion $schemaVersion.',
      );
    }
    if (id.trim().isEmpty ||
        subject.trim().isEmpty ||
        property.trim().isEmpty) {
      throw const FormatException(
        'Requirement id, subject and property must not be empty.',
      );
    }
    if (supersedesId != null && supersedesId!.trim().isEmpty) {
      throw const FormatException('supersedesId must not be empty.');
    }
  }

  factory Requirement.fromJson(Object? value) {
    final json = strictJsonObject(value, 'Requirement');
    rejectUnknownFields(json, {
      'schemaVersion',
      'id',
      'subject',
      'property',
      'value',
      'comparator',
      'scope',
      'origin',
      'sourceTurnId',
      'sourceSpans',
      'state',
      'supersedesId',
      'strength',
      'phase',
      'quantityRole',
      'unit',
    }, 'Requirement');
    final version = readSchemaVersion(json, label: 'Requirement');
    final rawSpans = json['sourceSpans'] ?? const [];
    if (rawSpans is! List) {
      throw const FormatException('Requirement sourceSpans must be a list.');
    }
    return Requirement(
      id: readString(json, 'id', allowEmpty: false),
      subject: readString(json, 'subject', allowEmpty: false),
      property: readString(json, 'property', allowEmpty: false),
      value: json['value'],
      comparator: readEnum(
        json['comparator'],
        RequirementComparator.values,
        'requirement comparator',
        defaultValue: RequirementComparator.equals,
      ),
      scope: json['scope'] == null
          ? RequirementScope.project('')
          : RequirementScope.fromJson(json['scope']),
      origin: readEnum(
        json['origin'],
        RequirementOrigin.values,
        'requirement origin',
        defaultValue: RequirementOrigin.unknown,
      ),
      sourceTurnId: readString(json, 'sourceTurnId', defaultValue: ''),
      sourceSpans: [for (final span in rawSpans) SourceSpan.fromJson(span)],
      state: readEnum(
        json['state'],
        RequirementState.values,
        'requirement state',
        defaultValue: RequirementState.active,
      ),
      supersedesId: json['supersedesId'] == null
          ? null
          : readString(json, 'supersedesId', allowEmpty: false),
      strength: readEnum(
        json['strength'],
        RequirementStrength.values,
        'requirement strength',
        defaultValue: RequirementStrength.advisory,
      ),
      phase: readEnum(
        json['phase'],
        RequirementPhase.values,
        'requirement phase',
        defaultValue: RequirementPhase.planning,
      ),
      quantityRole: readEnum(
        json['quantityRole'],
        QuantityRole.values,
        'quantity role',
        defaultValue: QuantityRole.unspecified,
      ),
      unit: readString(json, 'unit', defaultValue: ''),
      schemaVersion: version,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'subject': subject,
    'property': property,
    'value': mutableJsonCopy(value),
    'comparator': comparator.name,
    'scope': scope.toJson(),
    'origin': origin.name,
    'sourceTurnId': sourceTurnId,
    'sourceSpans': sourceSpans.map((span) => span.toJson()).toList(),
    'state': state.name,
    if (supersedesId != null) 'supersedesId': supersedesId,
    'strength': strength.name,
    'phase': phase.name,
    'quantityRole': quantityRole.name,
    'unit': unit,
  };

  Requirement copyWith({
    String? id,
    String? subject,
    String? property,
    Object? value,
    bool clearValue = false,
    RequirementComparator? comparator,
    RequirementScope? scope,
    RequirementOrigin? origin,
    String? sourceTurnId,
    List<SourceSpan>? sourceSpans,
    RequirementState? state,
    String? supersedesId,
    bool clearSupersedesId = false,
    RequirementStrength? strength,
    RequirementPhase? phase,
    QuantityRole? quantityRole,
    String? unit,
  }) => Requirement(
    id: id ?? this.id,
    subject: subject ?? this.subject,
    property: property ?? this.property,
    value: clearValue ? null : value ?? this.value,
    comparator: comparator ?? this.comparator,
    scope: scope ?? this.scope,
    origin: origin ?? this.origin,
    sourceTurnId: sourceTurnId ?? this.sourceTurnId,
    sourceSpans: sourceSpans ?? this.sourceSpans,
    state: state ?? this.state,
    supersedesId: clearSupersedesId ? null : supersedesId ?? this.supersedesId,
    strength: strength ?? this.strength,
    phase: phase ?? this.phase,
    quantityRole: quantityRole ?? this.quantityRole,
    unit: unit ?? this.unit,
  );

  @override
  bool operator ==(Object other) =>
      other is Requirement && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}
