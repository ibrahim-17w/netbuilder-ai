import '../../models/network_intent.dart';
import '../../models/normalized_message.dart';
import '../../models/plan_operation.dart';
import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import '../network_tools.dart';
import '../nlu/lexicon.dart';
import '../nlu/parser.dart' as brief_parser;
import '../nlu/slots.dart';
import '../nlu/requirement_scope_reader.dart';
import '../nlu/routing_constraints.dart';
import '../packet_tracer/brief_reader.dart';
import '../tentative_language.dart';
import 'requested_action_reader.dart';

/// Capabilities this app's offline service model and Packet Tracer generator
/// do not implement. One list, so the request ledger and the keyless answer
/// cannot disagree about what was asked for.
class UnsupportedServiceCapabilities {
  const UnsupportedServiceCapabilities._();

  static final Map<String, RegExp> patterns = {
    'DHCP failover': RegExp(r'\bdhcp\s+failover\b', caseSensitive: false),
    'Active Directory domain controller': RegExp(
      r'\b(?:active\s+directory|domain\s+controller)\b',
      caseSensitive: false,
    ),
    'server clustering': RegExp(
      r'\b(?:server\s+cluster(?:ing)?|clustered\s+servers?)\b',
      caseSensitive: false,
    ),
    'advanced server configuration': RegExp(
      r'\badvanced\s+server\s+configurations?\b',
      caseSensitive: false,
    ),
    'BIND DNSSEC signing': RegExp(
      r'\b(?:dnssec|bind\s+dns)\b',
      caseSensitive: false,
    ),
  };

  /// The capabilities the text asks for, in its own order of mention.
  static List<String> namedIn(String text) {
    final hits = <(int, String)>[];
    patterns.forEach((label, pattern) {
      for (final match in pattern.allMatches(text)) {
        hits.add((match.start, label));
      }
    });
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <String>[];
    for (final hit in hits) {
      // "Active Directory domain controller" matches both patterns that
      // describe it; the answer names the capability once.
      if (!out.contains(hit.$2)) out.add(hit.$2);
    }
    return out;
  }

  static String reasonFor(String capability) =>
      '$capability is not implemented by the offline service model or the '
      'Packet Tracer server generator. Basic service enablement is not proof '
      'of this capability.';
}

/// Source-mapped access to the bridge already used by the offline parser.
class RequestNormalizer {
  const RequestNormalizer._();

  static NormalizedMessage normalize(String originalText) =>
      NetworkIntent.bridgeBriefWithMapping(originalText);
}

/// Output instructions are response preferences, never network requirements.
/// Only explicit, bounded wording is read; quoted values remain data.
class ResponsePreferenceReader {
  const ResponsePreferenceReader._();

  static ResponsePreferences read(String text) {
    final normalized = RequestNormalizer.normalize(text);
    final prose = RequestInterpretationAdapter._readableText(normalized);
    final lower = prose.toLowerCase();
    var language =
        normalized.segments.any(
          (segment) =>
              !normalized.opaqueSourceRanges.any(
                (range) =>
                    range.$1 < segment.originalEnd &&
                    range.$2 > segment.originalStart,
              ) &&
              RegExp(r'[\u0621-\u064a]').hasMatch(
                text.substring(segment.originalStart, segment.originalEnd),
              ),
        )
        ? 'ar'
        : 'en';
    for (final match in RegExp(
      r'\b(?:in|reply\s+in|answer\s+in|respond\s+in)\s+(arabic|english)\b',
    ).allMatches(lower)) {
      language = match.group(1) == 'arabic' ? 'ar' : 'en';
    }
    final sentenceMatch = RegExp(
      r'\b(?:in\s+|within\s+|at\s+most\s+|no\s+more\s+than\s+)?(\d{1,2})\s+sentences?\b',
    ).firstMatch(lower);
    final sentenceCount = int.tryParse(sentenceMatch?.group(1) ?? '');
    final maxSentences = sentenceCount != null && sentenceCount > 0
        ? sentenceCount
        : null;
    final configurationOnly = RegExp(
      r'\b(?:only\s+(?:the\s+)?(?:configs?|configurations?)|'
      r'(?:configs?|configurations?)(?:\s+files?)?\s+only)\b',
    ).hasMatch(lower);
    final noExplanation = RegExp(
      r'\b(?:no|without)\s+(?:an?\s+)?(?:explanations?|commentary|prose)\b|'
      r'\b(?:do\s+not|don.t)\s+explain\b',
    ).hasMatch(lower);
    final concise =
        configurationOnly ||
        noExplanation ||
        maxSentences != null ||
        RegExp(r'\b(?:briefly|concise|brief|short\s+answer)\b').hasMatch(lower);
    // Tone is one-way in each phrase: "less formal" is casual, not formal.
    // The literal "formal" inside it must not win.
    final casualTone = RegExp(
      r'\b(?:less\s+formal|casual|conversational|relaxed|friendly)\b',
    ).hasMatch(lower);
    final formalTone =
        !casualTone &&
        RegExp(
          r'\b(?:more\s+formal|formal|professional\s+tone)\b',
        ).hasMatch(lower);
    final tone = casualTone
        ? 'casual'
        : formalTone
        ? 'formal'
        : '';
    final format = RegExp(r'\b(?:as|in)\s+json\b').hasMatch(lower)
        ? ResponseFormat.json
        : RegExp(r'\b(?:as|in)\s+(?:a\s+)?table\b').hasMatch(lower)
        ? ResponseFormat.table
        : RegExp(r'\b(?:as|in)\s+plain\s+text\b').hasMatch(lower)
        ? ResponseFormat.plainText
        : RegExp(r'\b(?:as|in)\s+markdown\b').hasMatch(lower)
        ? ResponseFormat.markdown
        : ResponseFormat.defaultFormat;
    return ResponsePreferences(
      language: language,
      brevity: concise ? ResponseBrevity.concise : ResponseBrevity.defaultStyle,
      format: format,
      explainChanges: !noExplanation && !configurationOnly,
      configurationOnly: configurationOnly,
      maxSentences: maxSentences,
      tone: tone,
    );
  }
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
    final unresolved = <UnresolvedFragment>[];
    final issues = <RequestIssue>[];
    final seen = <String>{};
    final corrections = <String, String>{};

    void addRequirement(Requirement requirement) {
      if (seen.add(requirement.id)) requirements.add(requirement);
    }

    String id(String family, int start, String subject) =>
        'req-${turnId.isEmpty ? 'turn' : turnId}-$family-$subject-$start';

    SourceSpan? span(int start, int end) =>
        normalized.sourceSpan(messageId: messageId, start: start, end: end);

    final lower = _readableText(normalized).toLowerCase();
    final scopes = RequirementScopeReader(lower);
    final classification = NetworkIntent.classifyBrief(lower);
    final tentative = TentativeLanguageService.analyze(lower).tentative;
    final answerOnly =
        tentative ||
        RegExp(
          r'\b(?:explain|compare|describe|why|what\s+is|what\s+are|what\s+if|'
          r'how\s+(?:do|does|to|can)|would\s+you\s+recommend)\b|'
          r'\b(?:do\s+not|don.t|never)\s+(?:edit|modify|change)\s+(?:my\s+|the\s+)?(?:network|project|design)\b|'
          r'\bwithout\s+(?:changing|changes|modifying)\b',
          caseSensitive: false,
        ).hasMatch(lower);
    final commandVerb = RegExp(
      r'\b(?:use|run|configure|set|switch\s+to|enable|select|choose|add|remove|delete|rename|replace|change|update|create|build|make|connect|assign|put|keep|preserve)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    final routeStatement = RegExp(
      r'\b(?:routing(?:\s+protocol)?|protocol)\s+(?:(?:should|must)\s+)?(?:be|is|=)\s*',
      caseSensitive: false,
    ).hasMatch(lower);
    final mutationRequest =
        !answerOnly &&
        (const {
              'build',
              'change',
              'addition',
              'growth',
            }.contains(classification) ||
            (classification == 'statement' && (commandVerb || routeStatement)));
    for (final quantity in BriefSlotPipeline.extractNormalizedQuantities(
      lower,
    )) {
      if (answerOnly ||
          _isNegatedAt(lower, quantity.start) ||
          quantity.distribution) {
        continue;
      }
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
      final quantityScope = quantity.scope;
      final scope = quantityScope == null
          ? scopes.scopeAt(
              quantity.start,
              end: quantity.end,
              projectId: projectId,
              includeService: false,
            )
          : quantityScope.kind == RequirementScopeKind.project
          ? RequirementScope.project(projectId)
          : quantityScope;
      final hasQuantitySuffix = RegExp(
        r'\b(?:more|extra|additional|further)\b',
      ).hasMatch(excerpt);
      final increment =
          quantity.increment &&
          (hasQuantitySuffix ||
              !RegExp(
                r'\b(?:create|build|make)\s*$',
              ).hasMatch(_clausePrefix(lower, quantity.start)));
      final role = isUserLoad
          ? QuantityRole.userLoad
          : isMinimum
          ? QuantityRole.minimum
          : isMaximum
          ? QuantityRole.maximum
          : increment
          ? QuantityRole.increment
          : quantity.total || quantity.correction
          ? QuantityRole.total
          : quantity.allocation || scope.kind != RequirementScopeKind.project
          ? QuantityRole.allocation
          : QuantityRole.deviceInventory;
      final serviceRole = quantity.kind == 'server'
          ? RegExp(
              r'\b(?:dhcp|dns|https?|web|aaa|radius|tacacs|ftp|mail|email|ntp|syslog)\b',
            ).firstMatch(quantity.role ?? '')?.group(0)
          : null;
      final property = isUserLoad
          ? 'user_load'
          : serviceRole != null
          ? 'role_device_count'
          : 'device_count';
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
      final hierarchy = scopes.scopeAt(
        quantity.start,
        end: quantity.end,
        projectId: projectId,
        includeService: false,
      );
      final scopedQuantity =
          scope.kind == RequirementScopeKind.project ||
              hierarchy.kind == RequirementScopeKind.vlan ||
              hierarchy.kind == RequirementScopeKind.device ||
              hierarchy.kind == RequirementScopeKind.linkInterface
          ? hierarchy
          : scope;
      final requirementScope = serviceRole == null
          ? scopedQuantity
          : RequirementScope(
              kind: RequirementScopeKind.service,
              scopeId: _canonicalService(serviceRole),
              siteId: scopedQuantity.kind == RequirementScopeKind.site
                  ? scopedQuantity.scopeId
                  : scopedQuantity.siteId,
              parent: scopedQuantity,
            );
      addRequirement(
        Requirement(
          id: requirementId,
          subject: quantity.kind,
          property: property,
          value: quantity.value,
          comparator: comparator,
          scope: requirementScope,
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
          serviceRole == null &&
          !isMinimum &&
          !isMaximum &&
          mutationRequest &&
          projectId.isNotEmpty &&
          basePlanRevision.isNotEmpty &&
          (!increment || quantity.value > 0)) {
        final kind = increment
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
            payload: increment
                ? {'kind': quantity.kind, 'count': quantity.value}
                : {'kind': quantity.kind, 'total': quantity.value},
          ),
        );
      }
    }

    if (!answerOnly) {
      if (scopes.inventorySites.isNotEmpty) {
        addRequirement(
          Requirement(
            id: id('allocation-sites', 0, 'network'),
            subject: 'network',
            property: 'allocation_sites',
            value: {
              'sites': scopes.inventorySites,
              'complete': scopes.completeInventorySites,
            },
            scope: RequirementScope.project(projectId),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [?span(0, lower.length)],
            strength: RequirementStrength.explicit,
          ),
        );
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
        allowRequirement: !answerOnly,
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

      _addSubnetAndPolicyEvidence(
        normalized: normalized,
        messageId: messageId,
        turnId: turnId,
        projectId: projectId,
        requirements: requirements,
        unresolved: unresolved,
        issues: issues,
        seen: seen,
      );
    }

    final hasEditVerb = RegExp(
      r'\b(?:change|update|replace|remove|delete|rename|add|keep|preserve|switch\s+to|set\s+(?:the\s+)?(?:routing|model|count|total|number|address|subnet|vlan))\b|\b(?:routing(?:\s+protocol)?|protocol)\s+(?:(?:should|must)\s+)?(?:be|is|=)',
      caseSensitive: false,
    ).hasMatch(lower);
    final requestedActions = answerOnly
        ? <RequestedAction>[]
        : RequestedActionReader.read(text: lower, turnId: turnId);
    return RequestInterpretation(
      turnId: turnId,
      conversationId: conversationId,
      projectId: projectId,
      basePlanRevision: basePlanRevision,
      mode: tentative
          ? RequestMode.explore
          : answerOnly
          ? RequestMode.explain
          : switch (classification) {
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
      unresolvedFragments: unresolved,
      issues: issues,
      requestedActions: requestedActions,
      responsePreferences: ResponsePreferenceReader.read(originalText),
      mutationPolicy: operations.isEmpty
          ? MutationPolicy.none
          : MutationPolicy.candidateOnly,
      reliability: {
        if (requirements.isNotEmpty) ReliabilityLabel.exactExtraction,
        if (requirements.isEmpty || unresolved.isNotEmpty)
          ReliabilityLabel.unresolved,
      },
    );
  }

  static String _readableText(NormalizedMessage normalized) {
    final text = normalized.normalizedText;
    // Indexes still address normalized UTF16 text. Mask whole mapped ranges,
    // not a quadratic per-character walk on long pasted briefs.
    final units = text.codeUnits.toList();
    for (final range in normalized.opaqueSourceRanges) {
      for (final segment in normalized.segments) {
        if (segment.originalStart >= range.$2 ||
            segment.originalEnd <= range.$1) {
          continue;
        }
        final copied =
            segment.normalizedEnd - segment.normalizedStart ==
            segment.originalEnd - segment.originalStart;
        final start = copied && range.$1 > segment.originalStart
            ? segment.normalizedStart + range.$1 - segment.originalStart
            : segment.normalizedStart;
        final end = copied && range.$2 < segment.originalEnd
            ? segment.normalizedStart + range.$2 - segment.originalStart
            : segment.normalizedEnd;
        for (var i = start; i < end; i++) {
          units[i] = 32;
        }
      }
    }
    return String.fromCharCodes(units);
  }

  static bool _isNegatedAt(String text, int at) {
    final prefix = _clausePrefix(text, at);
    if (RegExp(
      r'\b(?:no\s+(?:more|fewer)|not\s+(?:less|more))\s+than\s*$',
      caseSensitive: false,
    ).hasMatch(prefix)) {
      return false;
    }
    final negative = RegExp(
      r'\b(?:do\s+not|don.t|never|must\s+not|should\s+not|without|no|not|exclude|avoid)\b',
      caseSensitive: false,
    ).allMatches(prefix).lastOrNull;
    if (negative == null) return false;
    final suffix = prefix.substring(negative.end);
    // Negation carries through a noun list, but stops when another explicit
    // action starts: "no DNS and add DHCP" is not "no DHCP".
    return !RegExp(
      r'\b(?:but|however)\b|\band\s+(?:add|use|enable|put|set|change|keep|preserve)\b',
      caseSensitive: false,
    ).hasMatch(suffix);
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

  static String _canonicalService(String value) =>
      switch (value.toLowerCase()) {
        'web' || 'https' => 'http',
        'tacacs' || 'radius' => 'aaa',
        'mail' => 'email',
        final service => service,
      };

  static void _addSubnetAndPolicyEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required List<Requirement> requirements,
    required List<UnresolvedFragment> unresolved,
    required List<RequestIssue> issues,
    required Set<String> seen,
  }) {
    final text = _readableText(normalized);
    final scopes = RequirementScopeReader(text);
    final subnetMatches = RegExp(
      r'(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,3}(?![\d/])',
    ).allMatches(text).toList();
    for (final match in subnetMatches) {
      final cidr = match.group(0)!.replaceAll(RegExp(r'\s+'), '');
      final subnet = NetworkTools.subnet(cidr);
      final before = text.substring(0, match.start);
      final explicitSubnet = RegExp(
        r'\b(?:subnet|network|lan|base(?:\s+subnet)?)\s*[:=]?\s*$',
        caseSensitive: false,
      ).hasMatch(before);
      // The existing validated address reader distinguishes network blocks
      // from host/interface addresses. Do not turn an arbitrary host CIDR
      // (or an address in a policy) into a project base-subnet requirement.
      if (subnet != null &&
          !explicitSubnet &&
          subnet.network != cidr.split('/').first) {
        continue;
      }
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      if (evidence == null) continue;
      final scope = scopes.scopeAt(
        match.start,
        end: match.end,
        projectId: projectId,
        includeService: false,
      );
      final allocationBlock = RegExp(
        r'\b(?:base(?:\s+subnet)?|allocation\s+block|address\s+block)\s*[:=]?\s*$',
        caseSensitive: false,
      ).hasMatch(before);
      final requirementId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-subnet-${match.start}';
      if (!seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: 'network',
          property:
              allocationBlock ||
                  (subnetMatches.length == 1 &&
                      scope.kind == RequirementScopeKind.project &&
                      scope.networkRole.isEmpty)
              ? 'base_subnet'
              : 'subnet',
          value: cidr,
          comparator: _isNegatedAt(text, match.start)
              ? RequirementComparator.forbidden
              : RequirementComparator.equals,
          scope: scope,
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
      if (subnet == null) {
        unresolved.add(
          UnresolvedFragment(
            id: 'unresolved-$requirementId',
            text: evidence.excerpt,
            sourceSpans: [evidence],
          ),
        );
        issues.add(
          RequestIssue(
            id: 'issue-$requirementId',
            kind: RequestIssueKind.invalid,
            code: 'invalid_requested_subnet',
            message: 'The requested subnet is not a valid IPv4 CIDR.',
            requirementIds: [requirementId],
            sourceSpans: [evidence],
          ),
        );
      }
    }

    for (final match in RegExp(
      r'\b(?:default\s+)?gateway\s*(?:is\s+|[:=]\s*)?(\d{1,3}(?:\.\d{1,3}){3})\b',
      caseSensitive: false,
    ).allMatches(text)) {
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      if (evidence == null) continue;
      final scope = scopes.scopeAt(
        match.start,
        end: match.end,
        projectId: projectId,
        includeService: false,
      );
      requirements.add(
        Requirement(
          id: 'req-${turnId.isEmpty ? 'turn' : turnId}-gateway-${match.start}',
          subject: 'network',
          property: 'gateway',
          value: match.group(1),
          scope: scope,
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
    }

    final connectivity = RegExp(
      r'\b(?:all\s+)?(?:pcs?|computers?|hosts?|devices?)\s+'
      r'(?:(?:must|should|shall|can)\s+)?(?:be\s+able\s+to\s+)?'
      r'(?:communicate(?:\s+with\s+(?:each\s+other|one\s+another))?|'
      r'reach\s+(?:each\s+other|one\s+another))\b',
      caseSensitive: false,
    );
    for (final match in connectivity.allMatches(text)) {
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      if (evidence == null) continue;
      requirements.add(
        Requirement(
          id: 'req-${turnId.isEmpty ? 'turn' : turnId}-connectivity-${match.start}',
          subject: 'pc',
          property: 'connectivity',
          value: true,
          scope: scopes.scopeAt(
            match.start,
            end: match.end,
            projectId: projectId,
            includeService: false,
          ),
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [evidence],
          strength: RequirementStrength.explicit,
        ),
      );
    }

    _addUnsupportedServiceEvidence(
      normalized: normalized,
      messageId: messageId,
      turnId: turnId,
      projectId: projectId,
      requirements: requirements,
      issues: issues,
      unresolved: unresolved,
    );
    final isolation = RegExp(
      r'\b(?:must\s+not|cannot|can.t|may\s+not|should\s+not)\s+(?:reach|access|communicate\s+with)\b|'
      r'\b(?:isolate|isolation)\b|\b(?:deny|block)\s+(?:all\s+)?'
      r'(?:traffic|access|connections?|guests?|staff|dns|dhcp|http|https|ftp)\b',
      caseSensitive: false,
    );
    final hardCue = RegExp(
      r'\b(?:must|required|mandatory|never|shall|ensure|require|guarantee)\b|'
      r'\b(?:only|no)\s+(?:allow|permit|traffic|access|connections?)\b|'
      r'\b(?:do\s+not|don.t)\s+(?:allow|permit)\b',
      caseSensitive: false,
    );
    // Retain unsupported clauses verbatim. We do not guess an ACL from these
    // words or mark a nonempty parsed topology as evidence of the policy.
    for (final match in RegExp(r'(?:(?!\.(?=\s|$))[^;\n])+').allMatches(text)) {
      final clause = match.group(0)!;
      for (final piece in RegExp(r'[^,]+').allMatches(clause)) {
        final raw = piece.group(0)!;
        final trimmed = raw.trim();
        if (trimmed.isEmpty ||
            (!isolation.hasMatch(trimmed) && !hardCue.hasMatch(trimmed))) {
          continue;
        }
        final start = match.start + piece.start + raw.indexOf(trimmed);
        final end = start + trimmed.length;
        final evidence = normalized.sourceSpan(
          messageId: messageId,
          start: start,
          end: end,
        );
        if (evidence == null) continue;
        final isPolicy = isolation.hasMatch(trimmed);
        // Known quantities/routing/exclusions cover only their own words;
        // trailing hard language such as "must enforce office hours" remains
        // unresolved even when a preceding count was understood.
        final covered =
            !isPolicy &&
            requirements.any(
              (requirement) =>
                  requirement.property != 'allocation_sites' &&
                  requirement.sourceSpans.any(
                    (source) =>
                        source.start <= evidence.start &&
                        source.end >= evidence.end,
                  ),
            );
        final connectivityMatch = connectivity.firstMatch(trimmed);
        final onlyConnectivity =
            connectivityMatch != null &&
            trimmed.substring(0, connectivityMatch.start).trim().isEmpty &&
            RegExp(
              r'^[.!\s]*$',
            ).hasMatch(trimmed.substring(connectivityMatch.end));
        if (covered || onlyConnectivity) continue;
        final knownRouting = RegExp(
          r'^\s*(?:(?:we|the\s+network)\s+)?(?:(?:must|shall|never|do\s+not)\s+)?'
          r'(?:(?:use|run|configure|keep|preserve)\s+)?(?:not\s+)?'
          r'(?:ospf(?:\s+area\s+\d+)?|eigrp|bgp|static(?:\s+routing|\s+routes?)?)'
          r'\s*[.!]?\s*$',
          caseSensitive: false,
        ).hasMatch(trimmed);
        if (!isPolicy && knownRouting) continue;
        final hasOnlyKnownConstraint =
            !isPolicy &&
            RegExp(
              r'^\s*(?:(?:we|the\s+network)\s+)?(?:must|shall|never|do\s+not)\s+'
              r'(?:(?:use|run|add|include|enable)\s+)?(?:not\s+)?'
              r'(?:ospf|eigrp|bgp|static(?:\s+routes?)?|dns|dhcp|https?|servers?|routers?|switches|'
              r'\d+\s+(?:pcs?|routers?|switches))\s*[.!]?\s*$',
              caseSensitive: false,
            ).hasMatch(trimmed) &&
            requirements.any(
              (requirement) => requirement.sourceSpans.any(
                (source) =>
                    source.start >= evidence.start &&
                    source.end <= evidence.end,
              ),
            );
        if (hasOnlyKnownConstraint) continue;
        final requirementId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-policy-$start';
        if (!seen.add(requirementId)) continue;
        requirements.add(
          Requirement(
            id: requirementId,
            subject: 'network',
            property: isPolicy ? 'isolation_policy' : 'unsupported_policy',
            value: evidence.excerpt,
            scope: scopes.scopeAt(
              start,
              end: end,
              projectId: projectId,
              includeService: false,
            ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
        unresolved.add(
          UnresolvedFragment(
            id: 'unresolved-$requirementId',
            text: evidence.excerpt,
            sourceSpans: [evidence],
          ),
        );
        final unsupportedKnown =
            isPolicy ||
            RegExp(
              r'\b(?:office\s+hours|business[- ]hours?|time[- ]based|failover|active\s+directory|cluster(?:ing)?)\b',
              caseSensitive: false,
            ).hasMatch(trimmed);
        issues.add(
          RequestIssue(
            id: 'issue-$requirementId',
            kind: unsupportedKnown
                ? RequestIssueKind.unsupported
                : RequestIssueKind.ambiguity,
            code: isPolicy
                ? 'unsupported_isolation_policy'
                : 'unresolved_hard_clause',
            message:
                ResponsePreferenceReader.read(normalized.originalText).isArabic
                ? 'هذا الشرط يحتاج دعماً أو توضيحاً قبل البناء؛ لن أعتبره مطبقاً.'
                : 'This hard policy needs support or clarification before building; it is not treated as satisfied.',
            requirementIds: [requirementId],
            sourceSpans: [evidence],
          ),
        );
      }
    }
  }

  static void _addUnsupportedServiceEvidence({
    required NormalizedMessage normalized,
    required String messageId,
    required String turnId,
    required String projectId,
    required List<Requirement> requirements,
    required List<RequestIssue> issues,
    required List<UnresolvedFragment> unresolved,
  }) {
    final text = _readableText(normalized);
    final scopes = RequirementScopeReader(text);
    for (final entry in UnsupportedServiceCapabilities.patterns.entries) {
      for (final match in entry.value.allMatches(text)) {
        if (_isNegatedAt(text, match.start)) continue;
        final evidence = normalized.sourceSpan(
          messageId: messageId,
          start: match.start,
          end: match.end,
        );
        if (evidence == null) continue;
        final id =
            'req-${turnId.isEmpty ? 'turn' : turnId}-unsupported-service-${match.start}';
        final reason = UnsupportedServiceCapabilities.reasonFor(entry.key);
        requirements.add(
          Requirement(
            id: id,
            subject: 'server',
            property: 'unsupported_service_configuration',
            value: {'capability': entry.key, 'reason': reason},
            scope: scopes.scopeAt(
              match.start,
              end: match.end,
              projectId: projectId,
            ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
        issues.add(
          RequestIssue(
            id: 'issue-$id',
            kind: RequestIssueKind.unsupported,
            code: 'unsupported_service_configuration',
            message: reason,
            requirementIds: [id],
            sourceSpans: [evidence],
          ),
        );
        unresolved.add(
          UnresolvedFragment(
            id: 'unresolved-$id',
            text: evidence.excerpt,
            sourceSpans: [evidence],
          ),
        );
      }
    }
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
    final propertyPatterns = <String, RegExp>{
      'device_count': RegExp(
        r'\b(?:keep|preserve|retain)\s+(?:(?:the|all)\s+)?(?:device\s+counts?|inventory|number\s+of\s+devices)'
        r'(?:\s+(?:the\s+same|unchanged))?\b|'
        r'\bkeep\s+(?:the\s+)?(?:device\s+counts?|number\s+of\s+devices)\s+the\s+same\b',
        caseSensitive: false,
      ),
      'addressing': RegExp(
        r'\b(?:preserve|keep|retain)\s+(?:(?:the|all|remaining|other|rest\s+of\s+the)\s+)*'
        r'(?:addresses|addressing|ips)(?:\s+(?:of\s+the\s+remaining\s+devices|the\s+same|unchanged))?\b|'
        r'\b(?:do\s+not|don.t)\s+change\s+(?:(?:the|all|remaining|other)\s+)*(?:addresses|addressing|ips)\b',
        caseSensitive: false,
      ),
    };
    for (final entry in propertyPatterns.entries) {
      for (final match in entry.value.allMatches(text)) {
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
            'req-${turnId.isEmpty ? 'turn' : turnId}-preserve-${entry.key}-${match.start}';
        if (!seen.add(requirementId)) continue;
        requirements.add(
          Requirement(
            id: requirementId,
            subject: 'network',
            property: entry.key,
            value: true,
            comparator: RequirementComparator.preserve,
            scope: RequirementScope.project(projectId),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
        if (allowOperation &&
            projectId.isNotEmpty &&
            basePlanRevision.isNotEmpty) {
          operations.add(
            PlanOperation(
              operationId: 'op-$requirementId',
              kind: PlanOperationKind.preserve,
              requirementIds: [requirementId],
              sourceSpans: [evidence],
              projectId: projectId,
              baseRevision: basePlanRevision,
              scope: RequirementScope.project(projectId),
              payload: {
                'properties': [
                  entry.key == 'device_count' ? 'device_counts' : 'addressing',
                ],
              },
            ),
          );
        }
      }
    }
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
          if (_isNegatedAt(text, match.start)) continue;
          if (requirements.any(
            (item) =>
                item.property == 'device_count' &&
                item.subject == kind.type &&
                item.sourceSpans.any((source) {
                  final matchSource = normalized.sourceSpan(
                    messageId: messageId,
                    start: match.start,
                    end: match.end,
                  );
                  return matchSource != null &&
                      source.start >= matchSource.start &&
                      source.end <= matchSource.end;
                }),
          )) {
            continue;
          }
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
    final scopes = RequirementScopeReader(_readableText(normalized));
    final priorPositive = <String, String>{};
    for (final mention in RoutingConstraintReader.read(text)) {
      if (normalized.overlapsOpaqueSource(
        start: mention.start,
        end: mention.end,
      )) {
        continue;
      }
      final protocol = mention.protocol;
      final prefix = _clausePrefix(text.toLowerCase(), mention.start);
      final forbidden = mention.forbidden;
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: mention.evidenceStart,
        end: mention.evidenceEnd,
      );
      if (evidence == null) continue;
      final scope = scopes.scopeAt(
        mention.start,
        end: mention.end,
        projectId: projectId,
        includeService: false,
      );
      final siteId = scope.kind == RequirementScopeKind.site
          ? scope.scopeId
          : scope.siteId.isEmpty
          ? null
          : scope.siteId;
      final requirementId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-routing-${mention.start}';
      final supersedes = !forbidden && RegExp(r'\bactually\b').hasMatch(prefix)
          ? priorPositive[siteId ?? '']
          : null;
      if (!seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: 'network',
          property: 'routing_protocol',
          value: protocol,
          supersedesId: supersedes,
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
      if (!forbidden) priorPositive[siteId ?? ''] = requirementId;
      if (protocol == 'ospf' && !forbidden) {
        final area = RegExp(
          r'^\s+(?:in\s+)?area\s+(\d+)\b',
          caseSensitive: false,
        ).firstMatch(text.substring(mention.end));
        if (area != null) {
          final areaSpan = normalized.sourceSpan(
            messageId: messageId,
            start: mention.start,
            end: mention.end + area.end,
          );
          requirements.add(
            Requirement(
              id: '$requirementId-area',
              subject: 'network',
              property: 'ospf_area',
              value: int.parse(area.group(1)!),
              scope: scope,
              origin: RequirementOrigin.currentExplicit,
              sourceTurnId: turnId,
              sourceSpans: [?areaSpan],
              strength: RequirementStrength.explicit,
            ),
          );
        }
      }
      if (supersedes != null) {
        operations.removeWhere(
          (operation) => operation.requirementIds.contains(supersedes),
        );
      }
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
    final scopes = RequirementScopeReader(_readableText(normalized));
    final exclusionStart = RegExp(
      r'\b(?:do\s+not|don.t|never|must\s+not|should\s+not|exclude|without|no(?!\s+(?:more|fewer)\s+than))\s+(?:(?:add|include|create|introduce|insert|use|enable)\s+)?',
      caseSensitive: false,
    );
    final boundaries = RegExp(
      r'[.;\n]|\b(?:but|however)\b|\band\s+(?:add|use|enable|put|set|change|keep|preserve)\b',
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
      final vlan = RegExp(
        r'\bvlans?\b',
        caseSensitive: false,
      ).firstMatch(clause);
      if (vlan != null &&
          !normalized.overlapsOpaqueSource(
            start: cue.start,
            end: cue.end + vlan.end,
          )) {
        final evidence = normalized.sourceSpan(
          messageId: messageId,
          start: cue.start,
          end: cue.end + vlan.end,
        );
        final requirementId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-no-vlan-${cue.start}';
        if (evidence != null && seen.add(requirementId)) {
          requirements.add(
            Requirement(
              id: requirementId,
              subject: 'network',
              property: 'segmentation',
              value: 'none',
              scope: scopes.scopeAt(
                cue.start,
                end: end,
                projectId: projectId,
                includeService: false,
              ),
              origin: RequirementOrigin.currentExplicit,
              sourceTurnId: turnId,
              sourceSpans: [evidence],
              strength: RequirementStrength.explicit,
            ),
          );
        }
      }
      for (final kind in kinds) {
        for (final keyword in kind.keywords) {
          final match = RegExp(
            '\\b${RegExp.escape(keyword)}(?:es|s)?\\b',
            caseSensitive: false,
          ).firstMatch(clause);
          if (match == null) continue;
          // "no DNS server" forbids the DNS role, not all server hardware.
          if (kind.type == 'server' &&
              RegExp(
                r'\b(?:dns|dhcp|https?|web|ftp|tftp|ntp|snmp|syslog|aaa|tacacs|radius)\s+$',
                caseSensitive: false,
              ).hasMatch(clause.substring(0, match.start))) {
            continue;
          }
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
              scope: scopes.scopeAt(
                cue.start,
                end: end,
                projectId: projectId,
                includeService: false,
              ),
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
            scope: scopes.scopeAt(
              cue.start,
              end: end,
              projectId: projectId,
              includeService: false,
            ),
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
    final explicitName = brief_parser.explicitProjectName(originalText);
    final nameMention = brief_parser.projectNameMention(originalText);
    if (explicitName != null && nameMention != null) {
      final nameId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-project-name-${nameMention.start}';
      if (seen.add(nameId)) {
        requirements.add(
          Requirement(
            id: nameId,
            subject: 'project',
            property: 'project_name',
            value: explicitName,
            scope: RequirementScope.project(projectId),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [
              SourceSpan(
                messageId: messageId,
                start: nameMention.start,
                end: nameMention.end,
                excerpt: originalText.substring(
                  nameMention.start,
                  nameMention.end,
                ),
              ),
            ],
            strength: RequirementStrength.explicit,
            phase: RequirementPhase.planning,
          ),
        );
      }
    }
    final request = PtBriefRequest.read(normalized.normalizedText);
    final parsed = NetworkIntent.parseSimple(
      projectName.isEmpty ? 'request' : projectName,
      originalText,
    );
    final lower = normalized.normalizedText.toLowerCase();
    final routerDhcp = BriefSlotPipeline.routerDhcpRequested(lower);
    if (routerDhcp) {
      final match = RegExp(
        r'\bdhcp\b',
        caseSensitive: false,
      ).firstMatch(lower)!;
      final evidence = normalized.sourceSpan(
        messageId: messageId,
        start: match.start,
        end: match.end,
      );
      final owners = parsed.nodes.where(
        (n) => n.type == 'router' && n.services.contains('dhcp'),
      );
      for (final owner in owners) {
        final serviceId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-router-dhcp-${owner.name}-${match.start}';
        if (evidence == null || !seen.add(serviceId)) continue;
        requirements.add(
          Requirement(
            id: serviceId,
            subject: 'dhcp',
            property: 'service_role',
            value: true,
            scope: RequirementScope(
              kind: RequirementScopeKind.device,
              scopeId: owner.name,
            ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
      }
      for (final client in parsed.nodes.where(
        (n) => (n.serviceRules['addressing'] as Map?)?['mode'] == 'dhcp',
      )) {
        final clientId =
            'req-${turnId.isEmpty ? 'turn' : turnId}-dhcp-client-${client.name}-${match.start}';
        if (evidence == null || !seen.add(clientId)) continue;
        requirements.add(
          Requirement(
            id: clientId,
            subject: client.type,
            property: 'addressing_mode',
            value: 'dhcp',
            scope: RequirementScope(
              kind: RequirementScopeKind.device,
              scopeId: client.name,
            ),
            origin: RequirementOrigin.currentExplicit,
            sourceTurnId: turnId,
            sourceSpans: [evidence],
            strength: RequirementStrength.explicit,
          ),
        );
      }
    }
    for (final connection in request.connections) {
      final linkId =
          'req-${turnId.isEmpty ? 'turn' : turnId}-link-${connection.a}-${connection.aIf}-${connection.b}-${connection.bIf}';
      if (!seen.add(linkId)) continue;
      // The specialized reader has already resolved the original endpoint
      // labels and port aliases; retain the source clause, not inferred layout.
      final source = SourceSpan(
        messageId: messageId,
        start: 0,
        end: originalText.length,
        excerpt: originalText,
      );
      requirements.add(
        Requirement(
          id: linkId,
          subject: 'network',
          property: 'link',
          value: connection.toJson(),
          scope: RequirementScope.project(projectId),
          origin: RequirementOrigin.currentExplicit,
          sourceTurnId: turnId,
          sourceSpans: [source],
          strength: RequirementStrength.explicit,
        ),
      );
    }
    for (final node in parsed.nodes) {
      final needle = node.name.toLowerCase();
      final nameMatch = RegExp(
        '(?<![A-Za-z0-9_.-])${RegExp.escape(needle)}(?![A-Za-z0-9_.-])',
      ).firstMatch(lower);
      final at = nameMatch?.start ?? -1;
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
      final isRemoved = RegExp(
        '\\b(?:remove|delete|take\\s+out)\\s+(?:only\\s+)?${RegExp.escape(node.name)}\\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (nameEvidence != null &&
          !isRenameSource &&
          !isRemoved &&
          !_isNegatedAt(lower, at)) {
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
      if (_isNegatedAt(text, match.start)) continue;
      final list = match.namedGroup('devices')!;
      final deviceMatches = devicePattern.allMatches(list).toList();
      final names = <String>[];
      final sourceSpans = <SourceSpan>[];
      final requirementIds = <String>[];
      for (final deviceMatch in deviceMatches) {
        final start =
            match.start + match.group(0)!.indexOf(list) + deviceMatch.start;
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
      if (_isNegatedAt(text, match.start)) continue;
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
      if (_isNegatedAt(lower, start)) continue;
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
      if (deviceId == null) {
        final siteScope = RequirementScopeReader(
          _readableText(normalized),
        ).scopeAt(start, end: end, projectId: projectId, includeService: false);
        if (siteScope.kind == RequirementScopeKind.site ||
            siteScope.kind == RequirementScopeKind.vlan) {
          final evidence = span(start, end);
          final requirementId = id('service-site', start, service);
          if (evidence != null && seen.add(requirementId)) {
            requirements.add(
              Requirement(
                id: requirementId,
                subject: service,
                property: 'service_role',
                value: true,
                scope: siteScope,
                origin: RequirementOrigin.currentExplicit,
                sourceTurnId: turnId,
                sourceSpans: [evidence],
                strength: RequirementStrength.explicit,
              ),
            );
          }
        }
        continue;
      }
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
      final assignmentEnd = deviceEnd > end ? deviceEnd : end;
      final trailingOnly = RegExp(
        r'^\s+only\b',
        caseSensitive: false,
      ).firstMatch(text.substring(assignmentEnd));
      final exclusive =
          trailingOnly != null ||
          RegExp(
            r'\bonly\s+(?:on\s+)?$',
            caseSensitive: false,
          ).hasMatch(deviceStart < 0 ? '' : text.substring(0, deviceStart));
      final assignmentSpan = span(
        actionMatch != null
            ? start - prefix.length + actionMatch.start
            : deviceStart >= 0 && deviceStart < start
            ? deviceStart
            : start,
        assignmentEnd + (trailingOnly?.end ?? 0),
      );
      final requirementId = id('service', start, '$service-$deviceId');
      if (assignmentSpan == null || !seen.add(requirementId)) continue;
      requirements.add(
        Requirement(
          id: requirementId,
          subject: service,
          property: 'service_role',
          value: exclusive ? const {'enabled': true, 'exclusive': true} : true,
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
