import 'package:net_builder/models/network_intent.dart';

import 'plan_operation.dart';
import 'request_contract_utils.dart';
import 'request_coverage.dart';
import 'request_requirement.dart';

enum RequestMode {
  social,
  explain,
  advise,
  compare,
  explore,
  create,
  edit,
  build,
  verify,
  export,
  undo,
  clarify,
  unknown,
}

enum MutationPolicy { none, candidateOnly, commitIfValid }

enum ReliabilityLabel {
  exactExtraction,
  ruleInference,
  modelProposal,
  unresolved,
}

enum RequestIssueKind {
  conflict,
  ambiguity,
  unsupported,
  invalid,
  missingInput,
}

enum PendingQuestionTargetKind { requirement, operation, issue }

enum RequestedActionKind {
  build,
  exportConfiguration,
  exportPacketTracer,
  verify,
  compare,
  undo,
  other,
}

enum ResponseBrevity { defaultStyle, concise, detailed }

enum ResponseFormat { defaultFormat, plainText, markdown, json, table }

enum RequestDisposition { answerOnly, ask, commit, blocked }

class ResolvedReference {
  final String projectId;
  final String baseRevision;
  final String kind;
  final String canonicalId;
  final String displayName;

  const ResolvedReference({
    required this.projectId,
    required this.baseRevision,
    required this.kind,
    required this.canonicalId,
    this.displayName = '',
  });

  factory ResolvedReference.fromJson(Object? value) {
    final json = strictJsonObject(value, 'ResolvedReference');
    rejectUnknownFields(json, {
      'projectId',
      'baseRevision',
      'kind',
      'canonicalId',
      'displayName',
    }, 'ResolvedReference');
    return ResolvedReference(
      projectId: readString(json, 'projectId', allowEmpty: false),
      baseRevision: readString(json, 'baseRevision', allowEmpty: false),
      kind: readString(json, 'kind', allowEmpty: false),
      canonicalId: readString(json, 'canonicalId', allowEmpty: false),
      displayName: readString(json, 'displayName', defaultValue: ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'baseRevision': baseRevision,
    'kind': kind,
    'canonicalId': canonicalId,
    'displayName': displayName,
  };

  @override
  bool operator ==(Object other) =>
      other is ResolvedReference && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

class UnresolvedFragment {
  final String id;
  final String text;
  final List<SourceSpan> sourceSpans;

  UnresolvedFragment({
    required this.id,
    required String text,
    List<SourceSpan> sourceSpans = const [],
  }) : text = NetworkIntent.redactSecrets(text),
       sourceSpans = List.unmodifiable(sourceSpans) {
    if (id.trim().isEmpty || this.text.trim().isEmpty) {
      throw const FormatException(
        'UnresolvedFragment id and text must not be empty.',
      );
    }
  }

  factory UnresolvedFragment.fromJson(Object? value) {
    final json = strictJsonObject(value, 'UnresolvedFragment');
    rejectUnknownFields(json, {
      'id',
      'text',
      'sourceSpans',
    }, 'UnresolvedFragment');
    final rawSpans = json['sourceSpans'] ?? const [];
    if (rawSpans is! List) {
      throw const FormatException(
        'UnresolvedFragment sourceSpans must be a list.',
      );
    }
    return UnresolvedFragment(
      id: readString(json, 'id', allowEmpty: false),
      text: readString(json, 'text', allowEmpty: false),
      sourceSpans: [for (final span in rawSpans) SourceSpan.fromJson(span)],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': NetworkIntent.redactSecrets(text),
    'sourceSpans': sourceSpans.map((span) => span.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is UnresolvedFragment && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

class PendingRequestQuestion {
  final String id;
  final PendingQuestionTargetKind targetKind;
  final String targetId;
  final String prompt;

  PendingRequestQuestion({
    required this.id,
    required this.targetKind,
    required this.targetId,
    required String prompt,
  }) : prompt = NetworkIntent.redactSecrets(prompt) {
    if (id.trim().isEmpty ||
        targetId.trim().isEmpty ||
        this.prompt.trim().isEmpty) {
      throw const FormatException(
        'Pending questions require an id, target and prompt.',
      );
    }
  }

  factory PendingRequestQuestion.fromJson(Object? value) {
    final json = strictJsonObject(value, 'PendingRequestQuestion');
    rejectUnknownFields(json, {
      'id',
      'targetKind',
      'targetId',
      'prompt',
    }, 'PendingRequestQuestion');
    return PendingRequestQuestion(
      id: readString(json, 'id', allowEmpty: false),
      targetKind: readEnum(
        json['targetKind'],
        PendingQuestionTargetKind.values,
        'pending question target kind',
      ),
      targetId: readString(json, 'targetId', allowEmpty: false),
      prompt: readString(json, 'prompt', allowEmpty: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetKind': targetKind.name,
    'targetId': targetId,
    'prompt': NetworkIntent.redactSecrets(prompt),
  };

  @override
  bool operator ==(Object other) =>
      other is PendingRequestQuestion &&
      jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

class RequestIssue {
  final String id;
  final RequestIssueKind kind;
  final String code;
  final String message;
  final List<String> requirementIds;
  final List<SourceSpan> sourceSpans;

  RequestIssue({
    required this.id,
    required this.kind,
    this.code = '',
    required String message,
    List<String> requirementIds = const [],
    List<SourceSpan> sourceSpans = const [],
  }) : message = NetworkIntent.redactSecrets(message),
       requirementIds = List.unmodifiable(requirementIds),
       sourceSpans = List.unmodifiable(sourceSpans) {
    if (id.trim().isEmpty || this.message.trim().isEmpty) {
      throw const FormatException('RequestIssue id and message are required.');
    }
  }

  factory RequestIssue.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequestIssue');
    rejectUnknownFields(json, {
      'id',
      'kind',
      'code',
      'message',
      'requirementIds',
      'sourceSpans',
    }, 'RequestIssue');
    final rawSpans = json['sourceSpans'] ?? const [];
    if (rawSpans is! List) {
      throw const FormatException('RequestIssue sourceSpans must be a list.');
    }
    return RequestIssue(
      id: readString(json, 'id', allowEmpty: false),
      kind: readEnum(
        json['kind'],
        RequestIssueKind.values,
        'request issue kind',
      ),
      code: readString(json, 'code', defaultValue: ''),
      message: readString(json, 'message', allowEmpty: false),
      requirementIds: json['requirementIds'] == null
          ? const []
          : readStringList(json['requirementIds'], 'requirementIds'),
      sourceSpans: [for (final span in rawSpans) SourceSpan.fromJson(span)],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'code': code,
    'message': NetworkIntent.redactSecrets(message),
    'requirementIds': requirementIds.toList(),
    'sourceSpans': sourceSpans.map((span) => span.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is RequestIssue && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

class RequestedAction {
  final String id;
  final RequestedActionKind kind;
  final String target;
  final List<String> dependsOn;
  final Map<String, Object?> outputOptions;

  RequestedAction({
    required this.id,
    required this.kind,
    this.target = '',
    List<String> dependsOn = const [],
    Map<String, Object?> outputOptions = const {},
  }) : dependsOn = List.unmodifiable(dependsOn),
       outputOptions = freezeJsonMap(outputOptions, label: 'outputOptions') {
    if (id.trim().isEmpty ||
        this.dependsOn.any((item) => item.trim().isEmpty)) {
      throw const FormatException(
        'RequestedAction id and dependency IDs must not be empty.',
      );
    }
  }

  factory RequestedAction.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequestedAction');
    rejectUnknownFields(json, {
      'id',
      'kind',
      'target',
      'dependsOn',
      'outputOptions',
    }, 'RequestedAction');
    final options = json['outputOptions'] == null
        ? <String, dynamic>{}
        : strictJsonObject(
            json['outputOptions'],
            'RequestedAction outputOptions',
          );
    return RequestedAction(
      id: readString(json, 'id', allowEmpty: false),
      kind: readEnum(
        json['kind'],
        RequestedActionKind.values,
        'requested action kind',
      ),
      target: readString(json, 'target', defaultValue: ''),
      dependsOn: json['dependsOn'] == null
          ? const []
          : readStringList(json['dependsOn'], 'dependsOn'),
      outputOptions: options,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'target': target,
    'dependsOn': dependsOn.toList(),
    'outputOptions': mutableJsonCopy(outputOptions),
  };

  @override
  bool operator ==(Object other) =>
      other is RequestedAction && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

class ResponsePreferences {
  final String language;
  final ResponseBrevity brevity;
  final ResponseFormat format;
  final bool explainChanges;

  const ResponsePreferences({
    this.language = '',
    this.brevity = ResponseBrevity.defaultStyle,
    this.format = ResponseFormat.defaultFormat,
    this.explainChanges = true,
  });

  factory ResponsePreferences.fromJson(Object? value) {
    final json = strictJsonObject(value, 'ResponsePreferences');
    rejectUnknownFields(json, {
      'language',
      'brevity',
      'format',
      'explainChanges',
    }, 'ResponsePreferences');
    return ResponsePreferences(
      language: readString(json, 'language', defaultValue: ''),
      brevity: readEnum(
        json['brevity'],
        ResponseBrevity.values,
        'response brevity',
        defaultValue: ResponseBrevity.defaultStyle,
      ),
      format: readEnum(
        json['format'],
        ResponseFormat.values,
        'response format',
        defaultValue: ResponseFormat.defaultFormat,
      ),
      explainChanges: readBool(json, 'explainChanges', defaultValue: true),
    );
  }

  Map<String, dynamic> toJson() => {
    'language': language,
    'brevity': brevity.name,
    'format': format.name,
    'explainChanges': explainChanges,
  };

  ResponsePreferences copyWith({
    String? language,
    ResponseBrevity? brevity,
    ResponseFormat? format,
    bool? explainChanges,
  }) => ResponsePreferences(
    language: language ?? this.language,
    brevity: brevity ?? this.brevity,
    format: format ?? this.format,
    explainChanges: explainChanges ?? this.explainChanges,
  );

  @override
  bool operator ==(Object other) =>
      other is ResponsePreferences && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// The typed record for one turn. It contains request state only; the current
/// mutable design remains [NetworkIntent] until a later task applies edits.
class RequestInterpretation {
  static const currentSchemaVersion = 1;

  final String turnId;
  final String conversationId;
  final String projectId;
  final String basePlanRevision;
  final RequestMode mode;
  final List<Requirement> requirements;
  final List<PlanOperation> operations;
  final ResolvedReference? resolvedReference;
  final List<UnresolvedFragment> unresolvedFragments;
  final List<PendingRequestQuestion> pendingQuestions;
  final List<RequestIssue> issues;
  final MutationPolicy mutationPolicy;
  final List<RequestedAction> requestedActions;
  final ResponsePreferences responsePreferences;
  final Set<ReliabilityLabel> reliability;
  final int schemaVersion;

  RequestInterpretation({
    this.turnId = '',
    this.conversationId = '',
    this.projectId = '',
    this.basePlanRevision = '',
    this.mode = RequestMode.unknown,
    List<Requirement> requirements = const [],
    List<PlanOperation> operations = const [],
    this.resolvedReference,
    List<UnresolvedFragment> unresolvedFragments = const [],
    List<PendingRequestQuestion> pendingQuestions = const [],
    List<RequestIssue> issues = const [],
    this.mutationPolicy = MutationPolicy.none,
    List<RequestedAction> requestedActions = const [],
    this.responsePreferences = const ResponsePreferences(),
    Set<ReliabilityLabel> reliability = const {ReliabilityLabel.unresolved},
    this.schemaVersion = currentSchemaVersion,
  }) : requirements = List.unmodifiable(requirements),
       operations = List.unmodifiable(operations),
       unresolvedFragments = List.unmodifiable(unresolvedFragments),
       pendingQuestions = List.unmodifiable(pendingQuestions),
       issues = List.unmodifiable(issues),
       requestedActions = List.unmodifiable(requestedActions),
       reliability = Set.unmodifiable(reliability) {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported RequestInterpretation schemaVersion $schemaVersion.',
      );
    }
    if (this.operations.any((operation) => operation.projectId != projectId)) {
      throw const FormatException(
        'Every operation must target the interpretation projectId.',
      );
    }
    if (this.requirements.map((item) => item.id).toSet().length !=
        this.requirements.length) {
      throw const FormatException(
        'RequestInterpretation cannot contain duplicate requirement IDs.',
      );
    }
  }

  factory RequestInterpretation.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequestInterpretation');
    rejectUnknownFields(json, {
      'schemaVersion',
      'turnId',
      'conversationId',
      'projectId',
      'basePlanRevision',
      'mode',
      'requirements',
      'operations',
      'resolvedReference',
      'unresolvedFragments',
      'pendingQuestions',
      'issues',
      'mutationPolicy',
      'requestedActions',
      'responsePreferences',
      'reliability',
    }, 'RequestInterpretation');
    final version = readSchemaVersion(json, label: 'RequestInterpretation');
    return RequestInterpretation(
      turnId: readString(json, 'turnId', defaultValue: ''),
      conversationId: readString(json, 'conversationId', defaultValue: ''),
      projectId: readString(json, 'projectId', defaultValue: ''),
      basePlanRevision: readString(json, 'basePlanRevision', defaultValue: ''),
      mode: readEnum(
        json['mode'],
        RequestMode.values,
        'request mode',
        defaultValue: RequestMode.unknown,
      ),
      requirements: _readObjectList(
        json['requirements'],
        'requirements',
        Requirement.fromJson,
      ),
      operations: _readObjectList(
        json['operations'],
        'operations',
        PlanOperation.fromJson,
      ),
      resolvedReference: json['resolvedReference'] == null
          ? null
          : ResolvedReference.fromJson(json['resolvedReference']),
      unresolvedFragments: _readObjectList(
        json['unresolvedFragments'],
        'unresolvedFragments',
        UnresolvedFragment.fromJson,
      ),
      pendingQuestions: _readObjectList(
        json['pendingQuestions'],
        'pendingQuestions',
        PendingRequestQuestion.fromJson,
      ),
      issues: _readObjectList(json['issues'], 'issues', RequestIssue.fromJson),
      mutationPolicy: readEnum(
        json['mutationPolicy'],
        MutationPolicy.values,
        'mutation policy',
        defaultValue: MutationPolicy.none,
      ),
      requestedActions: _readObjectList(
        json['requestedActions'],
        'requestedActions',
        RequestedAction.fromJson,
      ),
      responsePreferences: json['responsePreferences'] == null
          ? const ResponsePreferences()
          : ResponsePreferences.fromJson(json['responsePreferences']),
      reliability: _readEnumSet(
        json['reliability'],
        ReliabilityLabel.values,
        'reliability label',
        defaultValue: const {ReliabilityLabel.unresolved},
      ),
      schemaVersion: version,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'turnId': turnId,
    'conversationId': conversationId,
    'projectId': projectId,
    'basePlanRevision': basePlanRevision,
    'mode': mode.name,
    'requirements': requirements.map((item) => item.toJson()).toList(),
    'operations': operations.map((item) => item.toJson()).toList(),
    if (resolvedReference != null)
      'resolvedReference': resolvedReference!.toJson(),
    'unresolvedFragments': unresolvedFragments
        .map((item) => item.toJson())
        .toList(),
    'pendingQuestions': pendingQuestions.map((item) => item.toJson()).toList(),
    'issues': issues.map((item) => item.toJson()).toList(),
    'mutationPolicy': mutationPolicy.name,
    'requestedActions': requestedActions.map((item) => item.toJson()).toList(),
    'responsePreferences': responsePreferences.toJson(),
    'reliability': reliability.map((item) => item.name).toList()..sort(),
  };

  RequestInterpretation copyWith({
    String? turnId,
    String? conversationId,
    String? projectId,
    String? basePlanRevision,
    RequestMode? mode,
    List<Requirement>? requirements,
    List<PlanOperation>? operations,
    ResolvedReference? resolvedReference,
    bool clearResolvedReference = false,
    List<UnresolvedFragment>? unresolvedFragments,
    List<PendingRequestQuestion>? pendingQuestions,
    List<RequestIssue>? issues,
    MutationPolicy? mutationPolicy,
    List<RequestedAction>? requestedActions,
    ResponsePreferences? responsePreferences,
    Set<ReliabilityLabel>? reliability,
  }) => RequestInterpretation(
    turnId: turnId ?? this.turnId,
    conversationId: conversationId ?? this.conversationId,
    projectId: projectId ?? this.projectId,
    basePlanRevision: basePlanRevision ?? this.basePlanRevision,
    mode: mode ?? this.mode,
    requirements: requirements ?? this.requirements,
    operations: operations ?? this.operations,
    resolvedReference: clearResolvedReference
        ? null
        : resolvedReference ?? this.resolvedReference,
    unresolvedFragments: unresolvedFragments ?? this.unresolvedFragments,
    pendingQuestions: pendingQuestions ?? this.pendingQuestions,
    issues: issues ?? this.issues,
    mutationPolicy: mutationPolicy ?? this.mutationPolicy,
    requestedActions: requestedActions ?? this.requestedActions,
    responsePreferences: responsePreferences ?? this.responsePreferences,
    reliability: reliability ?? this.reliability,
  );

  static List<T> _readObjectList<T>(
    Object? raw,
    String label,
    T Function(Object?) decode,
  ) {
    if (raw == null) return const [];
    if (raw is! List) throw FormatException('$label must be a list.');
    return List.unmodifiable([for (final value in raw) decode(value)]);
  }

  static Set<T> _readEnumSet<T extends Enum>(
    Object? raw,
    Iterable<T> values,
    String label, {
    required Set<T> defaultValue,
  }) {
    if (raw == null) return Set.unmodifiable(defaultValue);
    if (raw is! List) throw FormatException('$label values must be a list.');
    return Set.unmodifiable([
      for (final value in raw) readEnum(value, values, label),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is RequestInterpretation &&
      jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}

/// The one result a coordinator can hand to the chat UI for a turn.
class RequestOutcome {
  static const currentSchemaVersion = 1;

  final RequestInterpretation interpretation;
  final NetworkIntent? candidatePlan;
  final PlanChangeSet? changeSet;
  final CoverageReport? coverage;
  final List<RequestIssue> clarifications;
  final List<RequestedAction> requestedActions;
  final RequestDisposition disposition;
  final int schemaVersion;

  RequestOutcome({
    required this.interpretation,
    this.candidatePlan,
    this.changeSet,
    this.coverage,
    List<RequestIssue> clarifications = const [],
    List<RequestedAction>? requestedActions,
    required this.disposition,
    this.schemaVersion = currentSchemaVersion,
  }) : clarifications = List.unmodifiable(clarifications),
       requestedActions = List.unmodifiable(
         requestedActions ?? interpretation.requestedActions,
       ) {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported RequestOutcome schemaVersion $schemaVersion.',
      );
    }
    if (candidatePlan != null &&
        changeSet != null &&
        changeSet!.projectId != interpretation.projectId) {
      throw const FormatException(
        'RequestOutcome changeSet must target the interpretation project.',
      );
    }
  }

  factory RequestOutcome.fromJson(Object? value) {
    final json = strictJsonObject(value, 'RequestOutcome');
    rejectUnknownFields(json, {
      'schemaVersion',
      'interpretation',
      'candidatePlan',
      'changeSet',
      'coverage',
      'clarifications',
      'requestedActions',
      'disposition',
    }, 'RequestOutcome');
    return RequestOutcome(
      interpretation: RequestInterpretation.fromJson(json['interpretation']),
      candidatePlan: json['candidatePlan'] == null
          ? null
          : NetworkIntent.fromJson(
              strictJsonObject(json['candidatePlan'], 'candidatePlan'),
            ),
      changeSet: json['changeSet'] == null
          ? null
          : PlanChangeSet.fromJson(json['changeSet']),
      coverage: json['coverage'] == null
          ? null
          : CoverageReport.fromJson(json['coverage']),
      clarifications: RequestInterpretation._readObjectList(
        json['clarifications'],
        'clarifications',
        RequestIssue.fromJson,
      ),
      requestedActions: RequestInterpretation._readObjectList(
        json['requestedActions'],
        'requestedActions',
        RequestedAction.fromJson,
      ),
      disposition: readEnum(
        json['disposition'],
        RequestDisposition.values,
        'request disposition',
      ),
      schemaVersion: readSchemaVersion(json, label: 'RequestOutcome'),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'interpretation': interpretation.toJson(),
    if (candidatePlan != null)
      'candidatePlan': candidatePlan!.toJson(includeSecrets: false),
    if (changeSet != null) 'changeSet': changeSet!.toJson(),
    if (coverage != null) 'coverage': coverage!.toJson(),
    'clarifications': clarifications.map((item) => item.toJson()).toList(),
    'requestedActions': requestedActions.map((item) => item.toJson()).toList(),
    'disposition': disposition.name,
  };

  @override
  bool operator ==(Object other) =>
      other is RequestOutcome && jsonValueEquals(toJson(), other.toJson());

  @override
  int get hashCode => jsonValueHash(toJson());
}
