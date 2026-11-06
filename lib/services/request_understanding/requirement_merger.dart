import 'dart:convert';

import '../../models/design_brief.dart';
import '../../models/request_contract_utils.dart';
import '../../models/request_requirement.dart';

/// A conflict is retained with its source excerpts so the UI can ask about
/// the exact clause pair instead of choosing the last value it saw.
class RequirementConflict {
  final String propertyKey;
  final List<String> requirementIds;
  final String reason;
  final List<String> sourceExcerpts;

  RequirementConflict({
    required this.propertyKey,
    required List<String> requirementIds,
    required this.reason,
    List<String> sourceExcerpts = const [],
  }) : requirementIds = List.unmodifiable(requirementIds),
       sourceExcerpts = List.unmodifiable(sourceExcerpts);

  @override
  bool operator ==(Object other) =>
      other is RequirementConflict &&
      jsonValueEquals(
        {
          'key': propertyKey,
          'ids': requirementIds,
          'reason': reason,
          'excerpts': sourceExcerpts,
        },
        {
          'key': other.propertyKey,
          'ids': other.requirementIds,
          'reason': other.reason,
          'excerpts': other.sourceExcerpts,
        },
      );

  @override
  int get hashCode => jsonValueHash({
    'key': propertyKey,
    'ids': requirementIds,
    'reason': reason,
    'excerpts': sourceExcerpts,
  });
}

/// The scoped, typed constraints a later planner or brief adapter should use
/// to decide which learned defaults may fill empty fields.
class RequirementMemoryProtection {
  final Set<String> protectedFields;
  final Map<String, String> routerModels;
  final Map<String, String> switchModels;
  final Set<String> protectedSubnets;

  RequirementMemoryProtection({
    Set<String> protectedFields = const {},
    Map<String, String> routerModels = const {},
    Map<String, String> switchModels = const {},
    Set<String> protectedSubnets = const {},
  }) : protectedFields = Set.unmodifiable(protectedFields),
       routerModels = Map.unmodifiable(routerModels),
       switchModels = Map.unmodifiable(switchModels),
       protectedSubnets = Set.unmodifiable(protectedSubnets);

  bool get isEmpty =>
      protectedFields.isEmpty &&
      routerModels.isEmpty &&
      switchModels.isEmpty &&
      protectedSubnets.isEmpty;
}

class RequirementMergeResult {
  final List<Requirement> requirements;
  final List<RequirementConflict> conflicts;

  RequirementMergeResult({
    required List<Requirement> requirements,
    required List<RequirementConflict> conflicts,
  }) : requirements = List.unmodifiable(requirements),
       conflicts = List.unmodifiable(conflicts);

  List<Requirement> get active => requirements
      .where((requirement) => requirement.state == RequirementState.active)
      .toList(growable: false);

  List<Requirement> get unresolved => requirements
      .where((requirement) => requirement.state == RequirementState.unresolved)
      .toList(growable: false);

  bool get hasConflicts => conflicts.isNotEmpty;

  /// Apply active request requirements to the current brief adapter. Only
  /// project-wide, exact facts with an existing brief slot are representable;
  /// other requirements remain available to the coordinator and validators.
  DesignBrief applyToBrief(DesignBrief base) {
    var brief = base;
    for (final requirement in active) {
      final slot = _briefSlot(requirement);
      if (slot == null ||
          requirement.scope.kind != RequirementScopeKind.project ||
          requirement.comparator != RequirementComparator.equals) {
        continue;
      }
      final fact = _briefFact(requirement, slot);
      if (fact == null) continue;
      final existing = brief.fact(slot);
      if (existing != null &&
          BriefFact.rank(existing.origin) >= BriefFact.rank(fact.origin)) {
        continue;
      }
      brief = brief.withFact(slot, fact);
    }
    return brief;
  }

  static String? _briefSlot(Requirement requirement) {
    final property = requirement.property.toLowerCase();
    return switch (property) {
      'routing' || 'routing_protocol' => DesignBrief.routing,
      'scale' || 'device_count' => DesignBrief.scale,
      'segmentation' => DesignBrief.segmentation,
      'venue' => DesignBrief.venue,
      _ => null,
    };
  }

  static BriefFact? _briefFact(Requirement requirement, String slot) {
    final raw = requirement.value;
    if (raw == null) return null;
    final value = '$raw';
    final (source, origin) = switch (requirement.origin) {
      RequirementOrigin.currentExplicit => (
        'your current request',
        BriefSource.user,
      ),
      RequirementOrigin.establishedProject => (
        'established project decision',
        BriefSource.user,
      ),
      RequirementOrigin.scopedRememberedPreference => (
        'remembered preference',
        BriefSource.remembered,
      ),
      RequirementOrigin.environmentProfile => (
        'your environment profile',
        BriefSource.profile,
      ),
      RequirementOrigin.derivedDefault => (
        'planner assumption',
        BriefSource.plan,
      ),
      RequirementOrigin.unknown => ('unknown provenance', BriefSource.plan),
    };
    if (slot == DesignBrief.routing) {
      final routing = value.toLowerCase();
      if (!const {'static', 'ospf', 'eigrp', 'bgp', 'none'}.contains(routing)) {
        return null;
      }
      return BriefFact(
        value: routing,
        display: routing == 'static'
            ? 'Static routes'
            : routing == 'none'
            ? 'No dynamic routing'
            : routing.toUpperCase(),
        source: source,
        origin: origin,
      );
    }
    if (slot == DesignBrief.scale) {
      final count = int.tryParse(value);
      if (count == null || count <= 0) return null;
      final userLoad = requirement.quantityRole == QuantityRole.userLoad;
      final deviceInventory =
          requirement.quantityRole == QuantityRole.deviceInventory ||
          requirement.quantityRole == QuantityRole.total;
      if (!userLoad && !deviceInventory) return null;
      return BriefFact(
        value: '$count',
        display: userLoad ? '$count users' : '$count devices',
        source: source,
        origin: origin,
        quantityKind: userLoad
            ? QuantityKind.userLoad
            : QuantityKind.deviceInventory,
      );
    }
    if (slot == DesignBrief.segmentation) {
      final segmentation = value.toLowerCase();
      final display = switch (segmentation) {
        'none' || 'flat' => 'one flat network',
        'vlans' || 'vlan' => 'VLANs',
        _ => null,
      };
      if (display == null) return null;
      return BriefFact(
        value: display == 'VLANs' ? 'vlans' : 'none',
        display: display,
        source: source,
        origin: origin,
      );
    }
    return BriefFact(
      value: value,
      display: value,
      source: source,
      origin: origin,
    );
  }

  RequirementMemoryProtection get memoryProtection {
    final fields = <String>{};
    final routerModels = <String, String>{};
    final switchModels = <String, String>{};
    final subnets = <String>{};

    for (final requirement in active) {
      if (requirement.strength != RequirementStrength.explicit ||
          !const {
            RequirementOrigin.currentExplicit,
            RequirementOrigin.establishedProject,
          }.contains(requirement.origin)) {
        continue;
      }
      final property = requirement.property.toLowerCase();
      switch (property) {
        case 'routing':
        case 'routing_protocol':
          // The current plan model has one project-wide protocol field. A
          // more local requirement cannot be applied safely through memory.
          fields.add('routing');
        case 'router_model':
        case 'routermodel':
        case 'switch_model':
        case 'switchmodel':
        case 'device_model':
        case 'model':
          final model = requirement.value;
          if (model is! String || model.trim().isEmpty) continue;
          if (requirement.scope.kind == RequirementScopeKind.device &&
              requirement.scope.scopeId.isNotEmpty) {
            if (property.startsWith('switch') ||
                requirement.subject.toLowerCase().contains('switch')) {
              switchModels[requirement.scope.scopeId] = model;
            } else {
              routerModels[requirement.scope.scopeId] = model;
            }
          } else if (property.startsWith('switch') ||
              requirement.subject.toLowerCase().contains('switch')) {
            fields.add('switch_model');
          } else if (property.startsWith('router') ||
              requirement.subject.toLowerCase().contains('router')) {
            fields.add('router_model');
          } else {
            fields.add('router_model');
            fields.add('switch_model');
          }
        case 'subnet':
        case 'base_subnet':
        case 'basesubnet':
          final cidr = requirement.value;
          if (cidr is! String) continue;
          final network = _canonical24(cidr);
          if (network == null) continue;
          if (requirement.scope.kind == RequirementScopeKind.project ||
              requirement.scope.kind == RequirementScopeKind.site) {
            fields.add('base_subnet');
          } else {
            subnets.add(network);
          }
        case 'excluded_service':
        case 'service_exclusion':
        case 'dns_excluded':
          if ('${requirement.value}'.toLowerCase() == 'dns' ||
              property == 'dns_excluded') {
            fields.add('dns_excluded');
            fields.add('add_dns');
          }
        default:
          break;
      }
      if (requirement.comparator == RequirementComparator.forbidden &&
          '${requirement.value}'.toLowerCase() == 'dns') {
        fields.add('dns_excluded');
      }
    }

    return RequirementMemoryProtection(
      protectedFields: fields,
      routerModels: routerModels,
      switchModels: switchModels,
      protectedSubnets: subnets,
    );
  }

  static String? _canonical24(String value) {
    final match = RegExp(
      r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/24$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final octets = [for (var i = 1; i <= 4; i++) int.tryParse(match.group(i)!)];
    if (octets.any((part) => part == null || part < 0 || part > 255)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}.0/24';
  }
}

/// Deterministically resolves requirement precedence by scope and property.
/// It never applies a requirement to a plan; it only returns active, historic
/// and unresolved requirements for the later coordinator.
class RequirementMerger {
  const RequirementMerger._();

  static RequirementMergeResult merge(Iterable<Requirement> input) {
    final byId = <String, Requirement>{};
    for (final requirement in input) {
      final previous = byId[requirement.id];
      if (previous == null) {
        byId[requirement.id] = requirement;
      } else if (previous != requirement) {
        throw FormatException(
          'Requirement ID "${requirement.id}" has conflicting definitions.',
        );
      }
    }

    final original = byId.values.toList()..sort(_compareRequirements);
    final resultById = <String, Requirement>{
      for (final requirement in original) requirement.id: requirement,
    };
    final conflicts = <RequirementConflict>[];
    final replacementTargets = <String, List<Requirement>>{};
    final invalidReplacementIds = <String>{};
    final supersededIds = <String>{};

    for (final requirement in original) {
      final targetId = requirement.supersedesId;
      if (targetId == null) continue;
      final previous = byId[targetId];
      if (previous == null || _key(previous) != _key(requirement)) {
        invalidReplacementIds.add(requirement.id);
        final reason = previous == null
            ? 'Correction ${requirement.id} refers to missing requirement $targetId.'
            : 'Correction ${requirement.id} replaces a different scoped property than $targetId.';
        conflicts.add(_conflict(requirement.property, [requirement], reason));
        continue;
      }
      replacementTargets.putIfAbsent(targetId, () => []).add(requirement);
      supersededIds.add(targetId);
    }

    final cycleIds = <String>{};
    final visitedCycles = <String>{};
    for (final requirement in original) {
      if (invalidReplacementIds.contains(requirement.id)) continue;
      final path = <String>[];
      final pathPositions = <String, int>{};
      var cursor = requirement.id;
      while (true) {
        final cycleStart = pathPositions[cursor];
        if (cycleStart != null) {
          final cycle = path.skip(cycleStart).toList()..sort();
          final cycleKey = cycle.join('|');
          if (visitedCycles.add(cycleKey)) {
            cycleIds.addAll(cycle);
            final members = [for (final id in cycle) byId[id]!];
            conflicts.add(
              _conflict(
                _key(members.first),
                members,
                'Correction history contains a cycle among ${cycle.join(', ')}.',
              ),
            );
          }
          break;
        }
        pathPositions[cursor] = path.length;
        path.add(cursor);
        final current = byId[cursor];
        final targetId = current?.supersedesId;
        if (current == null || targetId == null) break;
        final target = byId[targetId];
        if (target == null ||
            _key(target) != _key(current) ||
            invalidReplacementIds.contains(current.id)) {
          break;
        }
        cursor = targetId;
      }
    }
    invalidReplacementIds.addAll(cycleIds);
    supersededIds.removeAll(cycleIds);

    for (final entry in replacementTargets.entries) {
      final replacements =
          entry.value
              .where((item) => !invalidReplacementIds.contains(item.id))
              .toSet()
              .toList()
            ..sort(_compareRequirements);
      if (replacements.length <= 1) continue;
      final signatures = replacements.map(_meaningKey).toSet();
      if (signatures.length <= 1) continue;
      invalidReplacementIds.addAll(replacements.map((item) => item.id));
      supersededIds.remove(entry.key);
      conflicts.add(
        _conflict(
          _key(byId[entry.key]!),
          [byId[entry.key]!, ...replacements],
          'More than one incompatible correction replaces requirement ${entry.key}.',
        ),
      );
    }

    final groups = <String, List<Requirement>>{};
    for (final requirement in original) {
      groups.putIfAbsent(_key(requirement), () => []).add(requirement);
    }

    for (final entry in groups.entries) {
      final group = entry.value;
      final candidatesWithDuplicates =
          group
              .where(
                (requirement) =>
                    requirement.state == RequirementState.active &&
                    !supersededIds.contains(requirement.id) &&
                    !invalidReplacementIds.contains(requirement.id),
              )
              .toList()
            ..sort(_compareRequirements);
      final meaningSeen = <String>{};
      final candidates = <Requirement>[];
      for (final requirement in candidatesWithDuplicates) {
        if (meaningSeen.add(_meaningKey(requirement))) {
          candidates.add(requirement);
        } else {
          resultById[requirement.id] = requirement.copyWith(
            state: RequirementState.superseded,
          );
        }
      }
      for (final id in supersededIds.where(
        (id) => group.any((requirement) => requirement.id == id),
      )) {
        final previous = resultById[id]!;
        resultById[id] = previous.copyWith(state: RequirementState.superseded);
      }
      for (final id in invalidReplacementIds.where(
        (id) => group.any((requirement) => requirement.id == id),
      )) {
        resultById[id] = resultById[id]!.copyWith(
          state: RequirementState.unresolved,
        );
      }
      if (candidates.isEmpty) continue;

      final topRank = _rank(candidates.first);
      final top = candidates.where((item) => _rank(item) == topRank).toList();
      final duplicateSignatures = <String, Requirement>{};
      final uniqueTop = <Requirement>[];
      for (final requirement in top) {
        final signature = _meaningKey(requirement);
        final prior = duplicateSignatures[signature];
        if (prior == null) {
          duplicateSignatures[signature] = requirement;
          uniqueTop.add(requirement);
        } else {
          resultById[requirement.id] = requirement.copyWith(
            state: RequirementState.superseded,
          );
        }
      }

      final conflictingPairs = <(Requirement, Requirement)>[];
      for (var i = 0; i < uniqueTop.length; i++) {
        for (var j = i + 1; j < uniqueTop.length; j++) {
          if (_incompatible(uniqueTop[i], uniqueTop[j])) {
            conflictingPairs.add((uniqueTop[i], uniqueTop[j]));
          }
        }
      }
      if (conflictingPairs.isNotEmpty) {
        final involved = <String>{
          for (final pair in conflictingPairs) pair.$1.id,
          for (final pair in conflictingPairs) pair.$2.id,
        };
        final conflictingRequirements = [
          for (final requirement in uniqueTop)
            if (involved.contains(requirement.id)) requirement,
        ];
        final reason = _conflictReason(entry.key, conflictingRequirements);
        conflicts.add(_conflict(entry.key, conflictingRequirements, reason));
        for (final requirement in conflictingRequirements) {
          resultById[requirement.id] = requirement.copyWith(
            state: RequirementState.unresolved,
          );
        }
        for (final requirement in candidates.where(
          (item) => _rank(item) < topRank,
        )) {
          if (conflictingRequirements.any(
            (winner) => _incompatible(winner, requirement),
          )) {
            resultById[requirement.id] = requirement.copyWith(
              state: RequirementState.superseded,
            );
          }
        }
        continue;
      }

      for (final requirement in candidates) {
        if (resultById[requirement.id]?.state == RequirementState.superseded) {
          continue;
        }
        final higher = candidates.where(
          (other) => _rank(other) > _rank(requirement),
        );
        if (higher.any((other) => _incompatible(other, requirement))) {
          resultById[requirement.id] = requirement.copyWith(
            state: RequirementState.superseded,
          );
        }
      }
    }

    final output = resultById.values.toList()..sort(_compareRequirements);
    conflicts.sort((a, b) {
      final key = a.propertyKey.compareTo(b.propertyKey);
      return key != 0
          ? key
          : a.requirementIds.join(',').compareTo(b.requirementIds.join(','));
    });
    return RequirementMergeResult(requirements: output, conflicts: conflicts);
  }

  static int _rank(Requirement requirement) {
    final strength = switch (requirement.strength) {
      RequirementStrength.explicit => 100,
      RequirementStrength.advisory => 0,
    };
    final origin = switch (requirement.origin) {
      RequirementOrigin.currentExplicit => 6,
      RequirementOrigin.establishedProject => 5,
      RequirementOrigin.scopedRememberedPreference => 4,
      RequirementOrigin.environmentProfile => 3,
      RequirementOrigin.derivedDefault => 2,
      RequirementOrigin.unknown => 1,
    };
    return strength + origin;
  }

  static String _key(Requirement requirement) =>
      '${requirement.subject.toLowerCase()}|${requirement.scope.kind.name}|'
      '${requirement.scope.scopeId.toLowerCase()}|${requirement.property.toLowerCase()}';

  static String _meaningKey(Requirement requirement) => jsonEncode({
    'comparator': requirement.comparator.name,
    'value': requirement.value,
    'quantityRole': requirement.quantityRole.name,
    'unit': requirement.unit,
  });

  static int _compareRequirements(Requirement a, Requirement b) {
    final key = _key(a).compareTo(_key(b));
    if (key != 0) return key;
    final rank = _rank(b).compareTo(_rank(a));
    if (rank != 0) return rank;
    return a.id.compareTo(b.id);
  }

  static bool _incompatible(Requirement a, Requirement b) {
    if (a.comparator == RequirementComparator.forbidden &&
        b.comparator == RequirementComparator.forbidden) {
      return false;
    }
    if (a.comparator == RequirementComparator.forbidden ||
        b.comparator == RequirementComparator.forbidden) {
      final forbidden = a.comparator == RequirementComparator.forbidden ? a : b;
      final chosen = identical(forbidden, a) ? b : a;
      return chosen.comparator == RequirementComparator.equals &&
          jsonValueEquals(forbidden.value, chosen.value);
    }
    if (a.comparator == RequirementComparator.preserve ||
        b.comparator == RequirementComparator.preserve) {
      return !jsonValueEquals(a.value, b.value);
    }

    final aExact = a.comparator == RequirementComparator.equals;
    final bExact = b.comparator == RequirementComparator.equals;
    final aNumber = _number(a.value);
    final bNumber = _number(b.value);
    if (aExact && bExact) return !jsonValueEquals(a.value, b.value);
    if (aExact && bNumber != null) return !_satisfies(aNumber, b);
    if (bExact && aNumber != null) return !_satisfies(bNumber, a);
    if (a.comparator == RequirementComparator.atLeast &&
        b.comparator == RequirementComparator.atMost &&
        aNumber != null &&
        bNumber != null) {
      return aNumber > bNumber;
    }
    if (b.comparator == RequirementComparator.atLeast &&
        a.comparator == RequirementComparator.atMost &&
        aNumber != null &&
        bNumber != null) {
      return bNumber > aNumber;
    }
    return false;
  }

  static bool _satisfies(num? exact, Requirement bound) {
    if (exact == null) return false;
    final value = _number(bound.value);
    if (value == null) return false;
    return switch (bound.comparator) {
      RequirementComparator.atLeast => exact >= value,
      RequirementComparator.atMost => exact <= value,
      _ => true,
    };
  }

  static num? _number(Object? value) => value is num ? value : null;

  static RequirementConflict _conflict(
    String key,
    List<Requirement> requirements,
    String reason,
  ) {
    final ordered = requirements.toList()..sort(_compareRequirements);
    final excerpts = <String>{
      for (final requirement in ordered)
        for (final span in requirement.sourceSpans)
          if (span.excerpt.trim().isNotEmpty) span.excerpt,
    }.toList()..sort();
    return RequirementConflict(
      propertyKey: key,
      requirementIds: ordered.map((item) => item.id).toSet().toList()..sort(),
      reason: reason,
      sourceExcerpts: excerpts,
    );
  }

  static String _conflictReason(String key, List<Requirement> requirements) {
    final values = requirements
        .map((item) => '${item.id}=${_safeValue(item)}')
        .join(', ');
    final excerpts = <String>{
      for (final item in requirements)
        for (final span in item.sourceSpans)
          if (span.excerpt.trim().isNotEmpty) '“${span.excerpt}”',
    }.toList()..sort();
    return 'Incompatible requirements for $key: $values.'
        '${excerpts.isEmpty ? '' : ' Sources: ${excerpts.join(' | ')}'}';
  }

  static String _safeValue(Requirement requirement) {
    if (RegExp(
      r'password|secret|psk|credential',
      caseSensitive: false,
    ).hasMatch(requirement.property)) {
      return '[redacted]';
    }
    return jsonEncode(requirement.value);
  }
}
