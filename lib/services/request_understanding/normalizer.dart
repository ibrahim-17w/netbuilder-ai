import '../../models/network_intent.dart';
import '../../models/normalized_message.dart';
import '../../models/plan_operation.dart';
import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import '../nlu/lexicon.dart';
import '../nlu/slots.dart';
import '../packet_tracer/brief_reader.dart';
import 'requested_action_reader.dart';

/// Source-mapped access to the bridge already used by the offline parser.
class RequestNormalizer {
  const RequestNormalizer._();

  static NormalizedMessage normalize(String originalText) =>
      NetworkIntent.bridgeBriefWithMapping(originalText);
}

/// Adapts deterministic reader output into the versioned request contract.
/// Specialized parsers remain responsible for network and Packet Tracer
/// semantics; this class only attaches typed evidence to what they read.
class RequestInterpretationAdapter {
  const RequestInterpretationAdapter._();

  static RequestInterpretation adapt({
    required String originalText,
    String projectName = '',
    String turnId = '',
    String conversationId = '',
    String projectId = '',
    String basePlanRevision = '',
    String messageId = 'current-message',
  }) {
    final normalized = RequestNormalizer.normalize(originalText);
    final requirements = <Requirement>[];
    final operations = <PlanOperation>[];
    final seen = <String>{};
    final corrections = <String, String>{};

    void addRequirement(Requirement requirement) {
      if (seen.add(requirement.id)) requirements.add(requirement);
    }

    String id(String family, int start, String subject) =>
        'req-${turnId.isEmpty ? 'turn' : turnId}-$family-$subject-$start';

    SourceSpan? span(int start, int end) =>
        normalized.sourceSpan(messageId: messageId, start: start, end: end);

    final normalizedText = normalized.normalizedText;
    final lower = normalizedText.toLowerCase();
    final classification = NetworkIntent.classifyBrief(originalText);
    final commandVerb = RegExp(
      r'\b(?:use|run|configure|set|switch\s+to|enable|select|choose|add|remove|delete|rename|change|update|create|build|make|connect|assign|put|keep|preserve)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    final routeStatement = RegExp(
      r'\b(?:routing(?:\s+protocol)?|protocol)\s+(?:(?:should|must)\s+)?(?:be|is|=)\s*',
      caseSensitive: false,
    ).hasMatch(lower);
    final mutationRequest =
        const {
          'build',
          'change',
          'addition',
          'growth',
        }.contains(classification) ||
        (classification == 'statement' && (commandVerb || routeStatement));
    for (final quantity in BriefSlotPipeline.extractNormalizedQuantities(
      normalizedText,
    )) {
      if (normalized.overlapsOpaqueSource(
        start: quantity.start,
        end: quantity.end,
      )) {
        continue;
      }
      final evidence = span(quantity.start, quantity.end);
      if (evidence == null) continue;
      final excerpt = lower.substring(quantity.start, quantity.end);
      final isMinimum = quantity.minimum;
      final isMaximum = quantity.maximum;
      final isUserLoad = RegExp(
        r'\b(?:users?|people|employees?|staff|headcount|students?)\b',
      ).hasMatch(excerpt);
      final scope = quantity.site == null
          ? RequirementScope.project(projectId)
          : RequirementScope(
              kind: RequirementScopeKind.site,
              scopeId: quantity.site!,
            );
      final role = isUserLoad
          ? QuantityRole.userLoad
          : isMinimum
          ? QuantityRole.minimum
          : isMaximum
          ? QuantityRole.maximum
          : quantity.increment
          ? QuantityRole.increment
          : quantity.correction
          ? QuantityRole.total
          : QuantityRole.deviceInventory;
      final property = isUserLoad ? 'user_load' : 'device_count';
      final comparator = isMinimum
          ? RequirementComparator.atLeast
          : isMaximum
          ? RequirementComparator.atMost
          : RequirementComparator.equals;
      final requirementId = id(
        'quantity',
        quantity.start,
        '${quantity.kind}-${quantity.site ?? 'project'}',
      );
      final key = '${quantity.site ?? ''}|${quantity.kind}|$property';
      final supersedesId = quantity.correction ? corrections[key] : null;
      addRequirement(
        Requirement(
          id: requirementId,
          subject: quantity.kind,
          property: property,
          value: quantity.value,
          comparator: comparator,
          scope: scope,
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          supersedesId: supersedesId,
          strength: RequirementStrength.explicit,
          quantityRole: role,
          unit: isUserLoad ? 'people' : 'devices',
        ),
      );
      corrections[key] = requirementId;

      if (!isUserLoad &&
          !isMinimum &&
          !isMaximum &&
          mutationRequest &&
          projectId.isNotEmpty &&
          basePlanRevision.isNotEmpty &&
          (!quantity.increment || quantity.value > 0)) {
        final kind = quantity.increment
            ? PlanOperationKind.addDevices
            : PlanOperationKind.setDeviceCount;
        final operationSpan = _quantityOperationSpan(
          normalized: normalized,
          messageId: messageId,
          start: quantity.start,
          end: quantity.end,
        );
        operations.add(
          PlanOperation(
            operationId: 'op-$requirementId',
            kind: kind,
            requirementIds: [requirementId],
            sourceSpans: [operationSpan ?? evidence],
            projectId: projectId,
            baseRevision: basePlanRevision,
            scope: scope,
            payload: quantity.increment
                ? {'kind': quantity.kind, 'count': quantity.value}
                : {'kind': quantity.kind, 'total': quantity.value},
          ),
        );
      }
    }

    _addSingularAdditionEvidence(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      allowOperation: mutationRequest,
      requirements: requirements,
      operations: operations,
      seen: seen,
    );

    _addRoutingEvidence(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      allowRequirement: mutationRequest,
      allowOperation: mutationRequest,
      requirements: requirements,
      operations: operations,
      seen: seen,
    );
    _addExclusions(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      requirements: requirements,
      seen: seen,
    );
    _addNamedDeviceEvidence(
      originalText: originalText,
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectName: projectName,
      projectId: projectId,
      requirements: requirements,
      seen: seen,
    );
    _addNamedEditEvidence(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      allowOperation: mutationRequest,
      requirements: requirements,
      operations: operations,
      seen: seen,
    );
    _addPreservationEvidence(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      allowOperation: mutationRequest,
      requirements: requirements,
      operations: operations,
      seen: seen,
    );

    final hasEditVerb = RegExp(
      r'\b(?:change|update|replace|remove|delete|rename|add|keep|preserve|switch\s+to|set\s+(?:the\s+)?(?:routing|model|count|total|number|address|subnet|vlan))\b|\b(?:routing(?:\s+protocol)?|protocol)\s+(?:(?:should|must)\s+)?(?:be|is|=)',
      caseSensitive: false,
    ).hasMatch(lower);
    final requestedActions = RequestedActionReader.read(
      text: originalText,
      turnId: turnId,
    );
    return RequestInterpretation(
      turnId: turnId,
      conversationId: conversationId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      mode: switch (classification) {
        'social' => RequestMode.social,
        'advice' => RequestMode.advise,
        'howto' || 'question' => RequestMode.explain,
        'confirm' => RequestMode.build,
        'build' => RequestMode.create,
        'change' || 'addition' || 'growth' => RequestMode.edit,
        _ =>
          hasEditVerb
              ? RequestMode.edit
              : requestedActions.isNotEmpty
              ? RequestMode.export
              : RequestMode.unknown,
      },
      requirements: requirements,
      operations: operations,
      requestedActions: requestedActions,
      mutationPolicy: operations.isEmpty
          ? MutationPolicy.none
          : MutationPolicy.candidateOnly,
      reliability: requirements.isEmpty
          ? const {ReliabilityLabel.unresolved}
          : const {ReliabilityLabel.exactExtraction},
    );
  }

  static String _clausePrefix(String text, int at) {
    int previous(String value) =>
        at == 0 ? -1 : text.lastIndexOf(value, at - 1);
    final start =
        [
          previous(','),
          previous(';'),
          previous('.'),
          previous('\n'),
        ].reduce((a, b) => a > b ? a : b) +
        1;
    return text.substring(start, at).toLowerCase();
  }

  static SourceSpan? _quantityOperationSpan({
    required NormalizedMessage normalized,
    required String messageId,
    required int start,
    required int end,
  }) {
    final text = normalized.normalizedText;
    final boundaries = [
      text.lastIndexOf(',', start == 0 ? 0 : start - 1),
      text.lastIndexOf(';', start == 0 ? 0 : start - 1),
      text.lastIndexOf('.', start == 0 ? 0 : start - 1),
      text.lastIndexOf('\n', start == 0 ? 0 : start - 1),
    ];
    final clauseStart =
        boundaries.reduce((left, right) => left > right ? left : right) + 1;
    final prefix = text.substring(clauseStart, start);
    final action = RegExp(
      r'\b(?:add|make|set|change|reduce|decrease|increase|remove|delete)\b',
      caseSensitive: false,
    ).allMatches(prefix).lastOrNull;
    final operationStart = action == null ? start : clauseStart + action.start;
    return normalized.sourceSpan(
      messageId: messageId,
      start: operationStart,
      end: end,
    );
  }

  static void _addPreservationEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required String basePlanRevision,
    required bool allowOperation,
    required List<Requirement> requirements,
    required List<PlanOperation> operations,
    required Set<String> seen,
  }) {
    final text = normalized.normalizedText;
    final pattern = RegExp(
      r'\b(?:keep|preserve|leave|retain)\s+(?:the\s+)?'
      r'((?:hq|headquarters)|(?:(?:first|1st|second|2nd|third|3rd|fourth|4th|'
      r'fifth|5th|\d+(?:st|nd|rd|th)?)\s+)?'
      r'(?:branch|site|office|building)(?:\s+[a-z0-9_-]+)?|'
      r'[a-z]{1,8}\d{1,3})\s+'
      r'(?:as\s+it\s+is|as[- ]?is|unchanged|the\s+same)\b',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      if (normalized.overlapsOpaqueSource(start: match.start, end: match.end)) {
        continue;
      }
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      if (evidence == null) continue;
      final rawScope = match.group(1)!.trim();
      final isSite = RegExp(
        r'^(?:hq|headquarters|(?:(?:first|1st|second|2nd|third|3rd|fourth|4th|'
        r'fifth|5th|\d+(?:st|nd|rd|th)?)\s+)?'
        r'(?:branch|site|office|building)(?:\s+[a-z0-9_-]+)?)$',
        caseSensitive: false,
      ).hasMatch(rawScope);
      final scope = isSite
          ? RequirementScope(
              kind: RequirementScopeKind.site,
              scopeId: rawScope.toLowerCase(),
            )
          : RequirementScope(
              kind: RequirementScopeKind.device,
              scopeId: rawScope,
            );
      final requirementId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-preserve-${match.start}';
      if (!seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: rawScope,
          property: 'semantic_state',
          value: true,
          comparator: RequirementComparator.preserve,
          scope: scope,
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
      if (!allowOperation ||
          projectId.trim().isEmpty ||
          basePlanRevision.trim().isEmpty) {
        continue;
      }
      operations.add(
        PlanOperation(
          operationId: 'op-$requirementId',
          kind: PlanOperationKind.preserve,
          requirementIds: [requirementId],
          sourceSpans: [evidence],
          projectId: projectId,
          baseRevision: basePlanRevision,
          scope: scope,
          payload: {
            'properties': [
              'devices',
              'links',
              'addressing',
              'services',
              'models',
              'layout',
            ],
          },
        ),
      );
    }
  }

  static void _addSingularAdditionEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required String basePlanRevision,
    required bool allowOperation,
    required List<Requirement> requirements,
    required List<PlanOperation> operations,
    required Set<String> seen,
  }) {
    final text = normalized.normalizedText;
    final kinds = [...deviceKinds]
      ..sort((left, right) {
        final leftLength = left.keywords.fold<int>(
          0,
          (length, word) => word.length > length ? word.length : length,
        );
        final rightLength = right.keywords.fold<int>(
          0,
          (length, word) => word.length > length ? word.length : length,
        );
        return rightLength.compareTo(leftLength);
      });
    for (final kind in kinds) {
      for (final keyword in kind.keywords) {
        final pattern = RegExp(
          '\\b(?:add|create|include)\\s+(?:a|an|one)\\s+(?:new\\s+)?${RegExp.escape(keyword)}\\b',
          caseSensitive: false,
        );
        for (final match in pattern.allMatches(text)) {
          if (normalized.overlapsOpaqueSource(
            start: match.start,
            end: match.end,
          )) {
            continue;
          }
          final evidence = normalized.sourceSpan(
            messageId: messageId,
            start: match.start,
            end: match.end,
          );
          if (evidence == null) continue;
          final requirementId =
              'req-${turnId.isEmpty ? 'turn' : turnId}-quantity-${kind.type}-project-${match.start}';
          if (!seen.add(requirementId)) continue;
          requirements.add(
            Requirement(
              id: requirementId,
              subject: kind.type,
              property: 'device_count',
              value: 1,
              comparator: RequirementComparator.equals,
              scope: RequirementScope.project(projectId),
              origin: RequirementOrigin.currentExplicit,
              sourceTurnId: turnId,
              sourceSpans: [evidence],
              strength: RequirementStrength.explicit,
              quantityRole: QuantityRole.increment,
              unit: 'devices',
            ),
          );
          if (!allowOperation ||
              projectId.trim().isEmpty ||
              basePlanRevision.trim().isEmpty) {
            continue;
          }
          operations.add(
            PlanOperation(
              operationId: 'op-$requirementId',
              kind: PlanOperationKind.addDevices,
              requirementIds: [requirementId],
              sourceSpans: [evidence],
              projectId: projectId,
              baseRevision: basePlanRevision,
              scope: RequirementScope.project(projectId),
              payload: {'kind': kind.type, 'count': 1},
            ),
          );
        }
      }
    }
  }

  static void _addRoutingEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required String basePlanRevision,
    required bool allowRequirement,
    required bool allowOperation,
    required List<Requirement> requirements,
    required List<PlanOperation> operations,
    required Set<String> seen,
  }) {
    if (!allowRequirement) return;
    final text = normalized.normalizedText;
    final pattern = RegExp(
      r'\b(?:ospf|eigrp|bgp|static\s+(?:routing|routes?))\b',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      if (normalized.overlapsOpaqueSource(start: match.start, end: match.end)) {
        continue;
      }
      final rawProtocol = match.group(0)!.toLowerCase();
      final protocol = rawProtocol.startsWith('static')
          ? 'static'
          : rawProtocol;
      final prefix = _clausePrefix(text.toLowerCase(), match.start);
      final forbidden = RegExp(
        r'(?:do\s+not|don.t|never|avoid|without|no|not)\s+(?:use\s+|run\s+|configure\s+)?$',
      ).hasMatch(prefix);
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      if (evidence == null) continue;
      final suffix = text.substring(
        match.end,
        match.end + 55 > text.length ? text.length : match.end + 55,
      );
      final siteMatch = RegExp(
        r'^\s*(?:at|for|in|within)\s+(?:the\s+)?((?:site|branch|office)\s+[A-Za-z0-9_-]+|headquarters|hq|east|west|north|south|branch|office)\b',
        caseSensitive: false,
      ).firstMatch(suffix);
      final siteId = siteMatch?.group(1)?.toLowerCase();
      final scope = siteId == null
          ? RequirementScope.project(projectId)
          : RequirementScope(kind: RequirementScopeKind.site, scopeId: siteId);
      final requirementId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-routing-${match.start}';
      if (!seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: 'network',
          property: 'routing_protocol',
          value: protocol,
          comparator: forbidden
              ? RequirementComparator.forbidden
              : RequirementComparator.equals,
          scope: scope,
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
      if (!forbidden &&
          allowOperation &&
          scope.kind == RequirementScopeKind.project &&
          projectId.isNotEmpty &&
          basePlanRevision.isNotEmpty) {
        operations.add(
          PlanOperation(
            operationId: 'op-$requirementId',
            kind: PlanOperationKind.setRouting,
            requirementIds: [requirementId],
            sourceSpans: [evidence],
            projectId: projectId,
            baseRevision: basePlanRevision,
            scope: RequirementScope.project(projectId),
            payload: {'protocol': protocol},
          ),
        );
      }
    }
  }

  static void _addExclusions({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required List<Requirement> requirements,
    required Set<String> seen,
  }) {
    final text = normalized.normalizedText;
    final exclusionStart = RegExp(
      r'\b(?:do\s+not|don.t|never|must\s+not|should\s+not|exclude|without|no\s+(?!more\s+than))\s+(?:(?:add|include|create|introduce|insert|use|enable)\s+)?',
      caseSensitive: false,
    );
    final boundaries = RegExp(
      r'[.;\n]|\b(?:but|however)\b',
      caseSensitive: false,
    );
    final kinds = [...deviceKinds]
      ..sort(
        (a, b) => b.keywords
            .fold<int>(0, (m, w) => w.length > m ? w.length : m)
            .compareTo(
              a.keywords.fold<int>(0, (m, w) => w.length > m ? w.length : m),
            ),
      );
    for (final cue in exclusionStart.allMatches(text)) {
      final nextBoundary = boundaries.firstMatch(text.substring(cue.end));
      final end = nextBoundary == null
          ? text.length
          : cue.end + nextBoundary.start;
      final clause = text.substring(cue.end, end);
      for (final kind in kinds) {
        for (final keyword in kind.keywords) {
          final match = RegExp(
            '\\b${RegExp.escape(keyword)}(?:es|s)?\\b',
            caseSensitive: false,
          ).firstMatch(clause);
          if (match == null) continue;
          final matchStart = cue.end + match.start;
          final matchEnd = cue.end + match.end;
          if (normalized.overlapsOpaqueSource(
            start: matchStart,
            end: matchEnd,
          )) {
            continue;
          }
          final start = cue.start;
          final finish = matchEnd;
          final evidence = normalized.sourceSpan(
            messageId: messageId,
            start: start,
            end: finish,
          );
          if (evidence == null) continue;
          final requirementId =
              'req-${turnId.isEmpty ? 'turn' : turnId}-exclude-${kind.type}-$start';
          if (!seen.add(requirementId)) continue;
          requirements.add(
            Requirement(
              id: requirementId,
              subject: kind.type,
              property: 'device_type',
              value: kind.type,
              comparator: RequirementComparator.forbidden,
              scope: RequirementScope.project(projectId),
              origin: RequirementOrigin.currentExplicit,
              sourceTurnId: turnId,
              sourceSpans: [evidence],
              strength: RequirementStrength.explicit,
            ),
          );
          break;
        }
      }
      const services = <String, String>{
        'dhcp': 'dhcp',
        'dns': 'dns',
        'http': 'http',
        'https': 'http',
        'web': 'http',
        'ftp': 'ftp',
        'tftp': 'tftp',
        'ntp': 'ntp',
        'snmp': 'snmp',
        'syslog': 'syslog',
        'aaa': 'aaa',
        'tacacs': 'aaa',
        'radius': 'aaa',
      };
      for (final entry in services.entries) {
        final match = RegExp(
          '\\b${RegExp.escape(entry.key)}\\b',
          caseSensitive: false,
        ).firstMatch(clause);
        if (match == null) continue;
        final matchStart = cue.end + match.start;
        final matchEnd = cue.end + match.end;
        if (normalized.overlapsOpaqueSource(start: matchStart, end: matchEnd)) {
          continue;
        }
        final evidence = normalized.sourceSpan(
          messageId: messageId,
          start: cue.start,
          end: matchEnd,
        );
        if (evidence == null) continue;
        final requirementId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-exclude-service-${entry.value}-${cue.start}';
        if (!seen.add(requirementId)) continue;
        requirements.add(
          Requirement(
            id: requirementId,
            subject: 'network',
            property: 'excluded_service',
            value: entry.value,
            comparator: RequirementComparator.forbidden,
            scope: RequirementScope.project(projectId),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
      }
    }
  }

  static void _addNamedDeviceEvidence({
    required String originalText,
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectName,
    required String projectId,
    required List<Requirement> requirements,
    required Set<String> seen,
  }) {
    final request = PtBriefRequest.read(normalized.normalizedText);
    final parsed = request.apply(
      NetworkIntent.parseBridged(
        projectName.isEmpty ? 'request' : projectName,
        normalized.normalizedText,
        originalText,
        request.routerModelHint,
      ),
    );
    final lower = normalized.normalizedText.toLowerCase();
    for (final node in parsed.nodes) {
      final needle = node.name.toLowerCase();
      final at = lower.indexOf(needle);
      final nameEvidence =
          needle.isEmpty ||
              at < 0 ||
              normalized.overlapsOpaqueSource(
                start: at,
                end: at + needle.length,
              )
          ? null
          : normalized.sourceSpan(
              messageId: messageId,
              start: at,
              end: at + needle.length,
            );
      final isRenameSource = RegExp(
        '\\b(?:rename|change\\s+(?:the\\s+)?name\\s+of)\\s+${RegExp.escape(node.name)}\\s+to\\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (nameEvidence != null && !isRenameSource) {
        final nameId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-device-name-${node.name}-$at';
        if (seen.add(nameId)) {
          requirements.add(
            Requirement(
              id: nameId,
              subject: node.type,
              property: 'device_name',
              value: node.name,
              scope: RequirementScope(
                kind: RequirementScopeKind.device,
                scopeId: node.name,
              ),
              origin: RequirementOrigin.currentExplicit,
              sourceTurnId: turnId,
              sourceSpans: [nameEvidence],
              strength: RequirementStrength.explicit,
            ),
          );
        }
      }

      if (!node.exactModel || node.model == null || node.model!.isEmpty) {
        continue;
      }
      final modelPattern = RegExp(
        '(?<![A-Za-z0-9])${RegExp.escape(node.model!)}(?![A-Za-z0-9])',
        caseSensitive: false,
      );
      for (final modelMatch in modelPattern.allMatches(lower)) {
        if (normalized.overlapsOpaqueSource(
          start: modelMatch.start,
          end: modelMatch.end,
        )) {
          continue;
        }
        final modelEvidence = normalized.sourceSpan(
          messageId: messageId,
          start: modelMatch.start,
          end: modelMatch.end,
        );
        if (modelEvidence == null) continue;
        final modelId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-model-${node.type}-${modelMatch.start}';
        if (!seen.add(modelId)) continue;
        requirements.add(
          Requirement(
            id: modelId,
            subject: node.type,
            property: node.type.toLowerCase().contains('switch')
                ? 'switch_model'
                : node.type.toLowerCase().contains('router')
                ? 'router_model'
                : 'device_model',
            value: node.model,
            scope: nameEvidence == null
                ? RequirementScope.project(projectId)
                : RequirementScope(
                    kind: RequirementScopeKind.device,
                    scopeId: node.name,
                  ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [modelEvidence],
            strength: RequirementStrength.explicit,
          ),
        );
      }
    }
  }

  static void _addNamedEditEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required String basePlanRevision,
    required bool allowOperation,
    required List<Requirement> requirements,
    required List<PlanOperation> operations,
    required Set<String> seen,
  }) {
    final text = normalized.normalizedText;
    final lower = text.toLowerCase();
    SourceSpan? span(int start, int end) =>
        normalized.sourceSpan(messageId: messageId, start: start, end: end);
    String id(String family, int start, String subject) =>
        'req-${turnId.isEmpty ? 'turn' : turnId}-$family-$subject-$start';
    bool canWrite() =>
        allowOperation &&
        projectId.trim().isNotEmpty &&
        basePlanRevision.trim().isNotEmpty;

    final devicePattern = RegExp(r'[A-Za-z][A-Za-z0-9_-]*\d+');
    final removalPattern = RegExp(
      r'\b(?:remove|delete|take\s+out)\s+(?:only\s+)?(?<devices>[A-Za-z][A-Za-z0-9_-]*\d+(?:\s*(?:,|and)\s*[A-Za-z][A-Za-z0-9_-]*\d+)*)',
      caseSensitive: false,
    );
    for (final match in removalPattern.allMatches(text)) {
      final list = match.namedGroup('devices')!;
      final deviceMatches = devicePattern.allMatches(list).toList();
      final names = <String>[];
      final sourceSpans = <SourceSpan>[];
      final requirementIds = <String>[];
      for (final deviceMatch in deviceMatches) {
        final start =
            match.start +
            match.namedGroup('devices')!.indexOf(deviceMatch.group(0)!);
        final end = start + deviceMatch.group(0)!.length;
        if (normalized.overlapsOpaqueSource(start: start, end: end)) continue;
        final name = deviceMatch.group(0)!;
        final evidence = span(start, end);
        if (evidence == null) continue;
        final requirementId = id('remove-device', start, name);
        if (!seen.add(requirementId)) continue;
        names.add(name);
        requirementIds.add(requirementId);
        sourceSpans.add(evidence);
        requirements.add(
          Requirement(
            id: requirementId,
            subject: 'device',
            property: 'device_presence',
            value: name,
            comparator: RequirementComparator.forbidden,
            scope: RequirementScope(
              kind: RequirementScopeKind.device,
              scopeId: name,
            ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
      }
      if (names.isNotEmpty &&
          allowOperation &&
          projectId.trim().isNotEmpty &&
          basePlanRevision.trim().isNotEmpty) {
        final operationSpan = span(match.start, match.end);
        operations.add(
          PlanOperation(
            operationId:
                'op-remove-${turnId.isEmpty ? 'turn' : turnId}-${match.start}',
            kind: PlanOperationKind.removeDevices,
            requirementIds: requirementIds,
            sourceSpans: [?operationSpan, ...sourceSpans],
            projectId: projectId,
            baseRevision: basePlanRevision,
            scope: RequirementScope.project(projectId),
            payload: {'deviceIds': names},
          ),
        );
      }
    }

    final renamePattern = RegExp(
      r'\b(?:rename|change\s+(?:the\s+)?name\s+of)\s+(?<old>[A-Za-z][A-Za-z0-9_-]*\d+)\s+to\s+(?<new>[A-Za-z][A-Za-z0-9_-]*)\b',
      caseSensitive: false,
    );
    for (final match in renamePattern.allMatches(text)) {
      final oldName = match.namedGroup('old')!;
      final newName = match.namedGroup('new')!;
      if (normalized.overlapsOpaqueSource(start: match.start, end: match.end)) {
        continue;
      }
      final evidence = span(match.start, match.end);
      if (evidence == null) continue;
      final requirementId = id('rename-device', match.start, oldName);
      if (!seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: 'device',
          property: 'device_name',
          value: newName,
          scope: RequirementScope(
            kind: RequirementScopeKind.device,
            scopeId: oldName,
          ),
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
      if (allowOperation &&
          projectId.trim().isNotEmpty &&
          basePlanRevision.trim().isNotEmpty) {
        operations.add(
          PlanOperation(
            operationId: 'op-$requirementId',
            kind: PlanOperationKind.renameDevice,
            requirementIds: [requirementId],
            sourceSpans: [evidence],
            projectId: projectId,
            baseRevision: basePlanRevision,
            scope: RequirementScope.project(projectId),
            payload: {'deviceId': oldName, 'newName': newName},
          ),
        );
      }
    }

    const serviceWords = <String, String>{
      'dhcp': 'dhcp',
      'dns': 'dns',
      'http': 'http',
      'https': 'http',
      'web': 'http',
      'ftp': 'ftp',
      'tftp': 'tftp',
      'ntp': 'ntp',
      'snmp': 'snmp',
      'syslog': 'syslog',
      'aaa': 'aaa',
      'tacacs': 'aaa',
      'radius': 'aaa',
    };
    final servicePattern = RegExp(
      '\\b(?:${serviceWords.keys.map(RegExp.escape).join('|')})\\b',
      caseSensitive: false,
    );
    for (final match in servicePattern.allMatches(text)) {
      final start = match.start;
      final end = match.end;
      if (normalized.overlapsOpaqueSource(start: start, end: end)) continue;
      final service = serviceWords[match.group(0)!.toLowerCase()];
      if (service == null) continue;
      final prefix = _clausePrefix(lower, start);
      if (RegExp(
        r'(?:do\s+not|don.t|never|must\s+not|should\s+not|exclude|without|no)\s+(?:(?:add|include|create|enable|use|assign|put|configure)\s+)?(?:the\s+)?$',
      ).hasMatch(prefix)) {
        continue;
      }
      final beforeStart = start > 100 ? start - 100 : 0;
      final before = text.substring(beforeStart, start);
      final after = text.substring(
        end,
        end + 60 > text.length ? text.length : end + 60,
      );
      String? deviceId;
      var deviceStart = -1;
      var deviceEnd = -1;
      final preceding = RegExp(
        r'(?:(?:only|just)\s+)?(?:(?<named>[A-Za-z][A-Za-z0-9_-]*\d+)\s+(?:(?:only|as)\s+)?|(?<other>another|other)\s+server\s+)(?:(?:to|as)\s+)?$',
        caseSensitive: false,
      ).firstMatch(before);
      if (preceding != null) {
        deviceId = preceding.namedGroup('named') ?? 'another server';
        deviceStart =
            beforeStart +
            before.toLowerCase().lastIndexOf(deviceId.toLowerCase());
        deviceEnd = deviceStart + deviceId.length;
      }
      if (deviceId == null) {
        final following = RegExp(
          r'^\s*(?:service\s+)?(?:on|to|for)\s+(?<device>[A-Za-z][A-Za-z0-9_-]*\d+)\b',
          caseSensitive: false,
        ).firstMatch(after);
        deviceId = following?.namedGroup('device');
        if (following != null) {
          final deviceOffset = following.group(0)!.lastIndexOf(deviceId!);
          deviceStart = end + following.start + deviceOffset;
          deviceEnd = deviceStart + deviceId.length;
        }
      }
      if (deviceId == null) continue;
      final actionPrefix = prefix.toLowerCase();
      final hasAction = RegExp(
        r'\b(?:configure|set|change|make|put|assign|enable|run|use)\b',
      ).hasMatch(actionPrefix);
      final hasDevicePreposition = RegExp(
        r'^\s*(?:on|to|for)\s+',
        caseSensitive: false,
      ).hasMatch(after);
      if (!hasAction && !hasDevicePreposition) continue;

      final actionMatch = RegExp(
        r'\b(?:configure|set|change|make|put|assign|enable|run|use)\b',
      ).allMatches(actionPrefix).lastOrNull;
      final assignmentSpan = span(
        actionMatch != null
            ? beforeStart + actionMatch.start
            : deviceStart >= 0 && deviceStart < start
            ? deviceStart
            : start,
        deviceEnd > end ? deviceEnd : end,
      );
      final requirementId = id('service', start, '$service-$deviceId');
      if (assignmentSpan == null || !seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: service,
          property: 'service_role',
          value: true,
          scope: RequirementScope(
            kind: RequirementScopeKind.device,
            scopeId: deviceId,
          ),
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [assignmentSpan],
          strength: RequirementStrength.explicit,
        ),
      );
      if (canWrite()) {
        operations.add(
          PlanOperation(
            operationId: 'op-$requirementId',
            kind: PlanOperationKind.assignService,
            requirementIds: [requirementId],
            sourceSpans: [assignmentSpan],
            projectId: projectId,
            baseRevision: basePlanRevision,
            scope: RequirementScope(
              kind: RequirementScopeKind.device,
              scopeId: deviceId,
            ),
            payload: {'deviceId': deviceId, 'service': service},
          ),
        );
      }
    }
  }
}
