import 'dart:ui' show Offset;

import '../../models/network_intent.dart';
import '../../models/plan_operation.dart';
import '../../models/request_contract_utils.dart';
import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import '../layout_intent.dart';
import '../nlu/lexicon.dart';
import '../packet_tracer/catalog.dart';
import '../topology_edit_service.dart';
import '../validator_service.dart';

/// A candidate is exposed for review even when it is held. Only [candidate]
/// and [changeSet] are committable; [heldCandidate] is diagnostic state.
class OperationApplicationResult {
  final NetworkIntent? candidate;
  final NetworkIntent heldCandidate;
  final PlanChangeSet? changeSet;
  final List<RequestIssue> issues;

  OperationApplicationResult({
    required this.candidate,
    required this.heldCandidate,
    required this.changeSet,
    required List<RequestIssue> issues,
  }) : issues = List.unmodifiable(issues);

  bool get canCommit =>
      candidate != null && changeSet != null && issues.isEmpty;
  bool get held => !canCommit;
}

class _OperationProblem implements Exception {
  final RequestIssueKind kind;
  final String code;
  final String message;

  const _OperationProblem(this.kind, this.code, this.message);
}

/// Deterministically applies typed edits to a deep candidate copy. It never
/// mutates the committed [NetworkIntent]. A candidate with any unresolved or
/// invalid operation is returned as held and has no commit-ready change set.
class OperationApplier {
  const OperationApplier._();

  static OperationApplicationResult apply({
    required NetworkIntent base,
    required String projectId,
    required String baseRevision,
    required List<PlanOperation> operations,
    String target = 'gns3',
  }) {
    var working = _deepCopy(base);
    final issues = <RequestIssue>[];
    final incidental = <String>[];
    final ids = <String>{};
    final accepted = <PlanOperation>[];
    final preserveOperations = operations
        .where((operation) => operation.kind == PlanOperationKind.preserve)
        .toList();
    final lockedDeviceNames = _lockedDeviceNames(base, preserveOperations);
    final explicitServiceTargets = {
      for (final operation in operations)
        if ({
              PlanOperationKind.assignService,
              PlanOperationKind.removeService,
            }.contains(operation.kind) &&
            operation.payload['deviceId'] is String &&
            !const {
              'another server',
              'other server',
            }.contains((operation.payload['deviceId'] as String).toLowerCase()))
          (operation.payload['deviceId'] as String).toLowerCase(),
    };

    void issue(
      PlanOperation? operation,
      String code,
      RequestIssueKind kind,
      String message,
    ) {
      final opId = operation?.operationId ?? 'request';
      issues.add(
        RequestIssue(
          id: 'apply-$opId-$code-${issues.length}',
          kind: kind,
          code: code,
          message: message,
          requirementIds: operation?.requirementIds ?? const [],
          sourceSpans: operation?.sourceSpans ?? const [],
        ),
      );
    }

    if (projectId.trim().isEmpty || baseRevision.trim().isEmpty) {
      issue(
        null,
        'missing_plan_identity',
        RequestIssueKind.missingInput,
        'The edit needs a project identity and the plan revision it was based on.',
      );
    } else if (base.revision != baseRevision) {
      issue(
        null,
        'stale_base_revision',
        RequestIssueKind.conflict,
        'The plan changed after these edits were interpreted. Reinterpret the request against the current plan.',
      );
    }

    for (final operation in operations) {
      if (!ids.add(operation.operationId)) {
        issue(
          operation,
          'duplicate_operation_id',
          RequestIssueKind.invalid,
          'This request contains the same edit more than once.',
        );
        continue;
      }
      if (operation.projectId != projectId ||
          operation.baseRevision != baseRevision) {
        issue(
          operation,
          'stale_operation_identity',
          RequestIssueKind.conflict,
          'This edit belongs to a different project or plan revision.',
        );
        continue;
      }
      if (operation.kind == PlanOperationKind.preserve) {
        accepted.add(operation);
        continue;
      }
      if (operation.scope.kind == RequirementScopeKind.site &&
          operation.kind != PlanOperationKind.addDevices &&
          operation.kind != PlanOperationKind.setDeviceCount) {
        issue(
          operation,
          'site_scope_not_representable',
          RequestIssueKind.unsupported,
          'This plan does not track site ownership, so a site-only edit cannot be applied safely.',
        );
        continue;
      }
      try {
        working = _applyOne(
          working,
          operation,
          target: target,
          incidental: incidental,
          lockedDeviceNames: lockedDeviceNames,
          explicitServiceTargets: explicitServiceTargets,
        );
        accepted.add(operation);
      } on _OperationProblem catch (problem) {
        issue(operation, problem.code, problem.kind, problem.message);
      } on FormatException catch (error) {
        issue(
          operation,
          'invalid_operation',
          RequestIssueKind.invalid,
          error.message,
        );
      } on ArgumentError {
        issue(
          operation,
          'unresolved_reference',
          RequestIssueKind.ambiguity,
          'One of the named devices or interfaces could not be resolved exactly.',
        );
      }
    }

    final renamedNames = _renamedNames(accepted);
    for (final operation in preserveOperations) {
      try {
        _checkPreservation(
          base,
          working,
          operation,
          renamedNames: renamedNames,
        );
      } on _OperationProblem catch (problem) {
        issue(operation, problem.code, problem.kind, problem.message);
      }
    }

    final beforeBlocking = <String, int>{};
    for (final finding in ValidatorService.validate(base, target: target)) {
      if (finding.blocks) {
        beforeBlocking.update(
          finding.message,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    for (final finding in ValidatorService.validate(working, target: target)) {
      if (!finding.blocks) continue;
      final existingCount = beforeBlocking[finding.message] ?? 0;
      if (existingCount > 0) {
        beforeBlocking[finding.message] = existingCount - 1;
        continue;
      }
      issue(
        null,
        'candidate_validation_failed',
        RequestIssueKind.invalid,
        'The edit would make the plan invalid: ${finding.message}',
      );
    }

    if (issues.isNotEmpty) {
      return OperationApplicationResult(
        candidate: null,
        heldCandidate: working,
        changeSet: null,
        issues: issues,
      );
    }

    final changeSet = PlanChangeSet(
      projectId: projectId,
      baseRevision: baseRevision,
      candidateRevision: working.revision,
      operations: accepted,
      oldValues: {'plan': base.toJson(includeSecrets: false)},
      newValues: {'plan': working.toJson(includeSecrets: false)},
      incidentalChanges: incidental.toSet().toList(),
      reasons: [for (final operation in accepted) operation.kind.name],
    );
    return OperationApplicationResult(
      candidate: working,
      heldCandidate: working,
      changeSet: changeSet,
      issues: const [],
    );
  }

  static NetworkIntent _applyOne(
    NetworkIntent intent,
    PlanOperation operation, {
    required String target,
    required List<String> incidental,
    required Set<String> lockedDeviceNames,
    required Set<String> explicitServiceTargets,
  }) {
    switch (operation.kind) {
      case PlanOperationKind.addDevices:
        return _addDevices(
          intent,
          operation,
          target: target,
          totalMode: false,
          lockedDeviceNames: lockedDeviceNames,
          incidental: incidental,
        );
      case PlanOperationKind.setDeviceCount:
        return _addDevices(
          intent,
          operation,
          target: target,
          totalMode: true,
          lockedDeviceNames: lockedDeviceNames,
          incidental: incidental,
        );
      case PlanOperationKind.removeDevices:
        return _removeDevices(intent, operation, incidental);
      case PlanOperationKind.renameDevice:
        return _renameDevice(intent, operation, incidental);
      case PlanOperationKind.setRouting:
        if (operation.scope.kind != RequirementScopeKind.project) {
          throw const _OperationProblem(
            RequestIssueKind.unsupported,
            'scoped_routing_not_representable',
            'This plan stores one routing protocol for the whole project, so a site-only routing change cannot be applied safely.',
          );
        }
        return intent.copyWith(
          routing: _string(operation, 'protocol').toLowerCase(),
        );
      case PlanOperationKind.setDeviceModel:
        return _setDeviceModel(intent, operation, target: target);
      case PlanOperationKind.assignService:
        return _service(
          intent,
          operation,
          remove: false,
          explicitServiceTargets: explicitServiceTargets,
        );
      case PlanOperationKind.removeService:
        return _service(
          intent,
          operation,
          remove: true,
          explicitServiceTargets: explicitServiceTargets,
        );
      case PlanOperationKind.setAddress:
        return _setAddress(intent, operation, target: target);
      case PlanOperationKind.setLink:
        return _setLink(intent, operation);
      case PlanOperationKind.setVlanMembership:
        throw const _OperationProblem(
          RequestIssueKind.unsupported,
          'vlan_membership_not_representable',
          'The current plan stores VLAN IDs but not per-device access or trunk membership, so this edit is held.',
        );
      case PlanOperationKind.setLayout:
        return _setLayout(intent, operation);
      case PlanOperationKind.preserve:
        return intent;
    }
  }

  static NetworkIntent _addDevices(
    NetworkIntent intent,
    PlanOperation operation, {
    required String target,
    required bool totalMode,
    required Set<String> lockedDeviceNames,
    required List<String> incidental,
  }) {
    final siteScoped = operation.scope.kind == RequirementScopeKind.site;
    final siteId = siteScoped
        ? _resolveSiteId(intent, operation.scope.scopeId)
        : null;
    if (operation.scope.kind != RequirementScopeKind.project && !siteScoped) {
      throw const _OperationProblem(
        RequestIssueKind.unsupported,
        'unsupported_inventory_scope',
        'Device inventory edits need a project or one exact site scope.',
      );
    }
    final type = _canonicalDeviceType(_string(operation, 'kind'));
    final amount = totalMode
        ? _integer(operation, 'total')
        : _integer(operation, 'count');
    final scopedInventory = intent.nodes
        .where((node) => node.type.toLowerCase() == type)
        .where((node) => !siteScoped || _sameSite(node.siteId, siteId))
        .toList();
    if (siteScoped &&
        !intent.nodes.any((node) => _sameSite(node.siteId, siteId))) {
      throw _OperationProblem(
        RequestIssueKind.ambiguity,
        'site_has_no_owned_devices',
        'The plan has no devices assigned to ${operation.scope.scopeId}. Identify the site or add its network first.',
      );
    }
    final current = scopedInventory.length;
    final delta = totalMode ? amount - current : amount;
    if (delta < 0) {
      final removable =
          scopedInventory
              .where(
                (node) => !lockedDeviceNames.contains(node.name.toLowerCase()),
              )
              .where((node) => !_isSecurityReferenced(intent, node.name))
              .toList()
            ..sort(_compareDeviceNames);
      if (removable.length < -delta) {
        throw _OperationProblem(
          RequestIssueKind.conflict,
          'count_reduction_conflicts_with_locked_devices',
          'The requested total is $amount $type device(s), but only ${removable.length} can be removed without violating a preservation rule or security reference. Name the devices to remove or resolve the protected references.',
        );
      }
      final removeNames = removable.reversed
          .take(-delta)
          .map((node) => node.name)
          .toSet();
      return _removeNodeNames(intent, removeNames, incidental);
    }
    if (delta == 0) return intent;
    if (ValidatorService.isPacketTracerTarget(target) &&
        intent.nodes.length + delta > ValidatorService.packetTracerMaxDevices) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'packet_tracer_device_limit',
        'The requested inventory exceeds Packet Tracer’s 50-device limit. The plan was left unchanged.',
      );
    }
    if (ValidatorService.isPacketTracerTarget(target) &&
        unsupportedDeviceKinds.contains(type)) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'device_type_not_buildable',
        'Packet Tracer cannot build the requested $type device type with the current templates.',
      );
    }

    if (siteScoped && type != 'pc') {
      throw const _OperationProblem(
        RequestIssueKind.unsupported,
        'site_add_topology_not_supported',
        'Site-scoped additions are currently supported for PCs; other device types need a site-specific topology rule.',
      );
    }
    final existing = siteScoped
        ? scopedInventory
        : intent.nodes
              .where((node) => node.type.toLowerCase() == type)
              .toList();
    final template = _unambiguousTemplate(
      existing.isNotEmpty
          ? existing
          : intent.nodes
                .where((node) => node.type.toLowerCase() == type)
                .toList(),
      type,
    );
    final requestedNames = totalMode
        ? const <String>[]
        : _stringList(operation.payload['names'], 'names', optional: true);
    if (requestedNames.isNotEmpty && requestedNames.length != delta) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'device_name_count_mismatch',
        'The number of exact device names must match the number of devices being added.',
      );
    }

    final taken = intent.nodes.map((node) => node.name.toLowerCase()).toSet();
    final prefix = devicePrefix(type);
    var serial = 1;
    String nextName() {
      while (taken.contains('$prefix$serial'.toLowerCase())) {
        serial++;
      }
      final name = '$prefix$serial';
      serial++;
      return name;
    }

    final added = <NetNode>[];
    for (var index = 0; index < delta; index++) {
      final name = requestedNames.isEmpty ? nextName() : requestedNames[index];
      if (name.trim().isEmpty || name != name.trim()) {
        throw const _OperationProblem(
          RequestIssueKind.invalid,
          'invalid_device_name',
          'A device name cannot be empty or padded with spaces.',
        );
      }
      if (!taken.add(name.toLowerCase())) {
        throw _OperationProblem(
          RequestIssueKind.conflict,
          'duplicate_device_name',
          'The name "$name" already belongs to another device.',
        );
      }
      added.add(
        NetNode(
          name: name,
          type: type,
          model: template?.model,
          exactModel: template?.exactModel ?? false,
          modules: template?.modules ?? const [],
          siteId: siteId,
        ),
      );
    }
    var candidate = intent.copyWith(nodes: [...intent.nodes, ...added]);
    if (siteScoped) {
      for (final device in added) {
        candidate = _attachSitePc(
          candidate,
          device,
          siteId: siteId!,
          incidental: incidental,
        );
      }
    }
    return candidate;
  }

  static String _resolveSiteId(NetworkIntent intent, String requested) {
    final siteIds = intent.nodes
        .map((node) => node.siteId?.trim())
        .whereType<String>()
        .where((site) => site.isNotEmpty)
        .toSet();
    final lowered = requested.trim().toLowerCase();
    if (siteIds.any((site) => site.toLowerCase() == lowered)) {
      return siteIds.singleWhere((site) => site.toLowerCase() == lowered);
    }
    final canonical = _canonicalSiteAlias(lowered);
    final matches = siteIds
        .where((site) => _canonicalSiteAlias(site.toLowerCase()) == canonical)
        .toList();
    if (matches.length == 1) return matches.single;
    if (matches.length > 1 ||
        (canonical == 'branch' &&
            siteIds.any((site) => site.toLowerCase().startsWith('branch#')))) {
      throw _OperationProblem(
        RequestIssueKind.ambiguity,
        'site_scope_ambiguous',
        'The site name "$requested" matches more than one location. Name the branch or site number.',
      );
    }
    throw _OperationProblem(
      RequestIssueKind.ambiguity,
      'site_scope_not_found',
      'The plan does not identify a site matching "$requested".',
    );
  }

  static String _canonicalSiteAlias(String site) {
    final normalized = site
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (const {'hq', 'headquarters', 'headquarter'}.contains(normalized)) {
      return 'hq';
    }
    const ordinals = {
      'first': 1,
      '1st': 1,
      'one': 1,
      'second': 2,
      '2nd': 2,
      'two': 2,
      'third': 3,
      '3rd': 3,
      'fourth': 4,
      '4th': 4,
      'fifth': 5,
      '5th': 5,
    };
    final ordinal = RegExp(
      r'^(?:(first|1st|one|second|2nd|two|third|3rd|fourth|4th|fifth|5th)\s+)?'
      r'(branch|office|site|building)(?:\s*#?\s*(\d+))?$',
    ).firstMatch(normalized.replaceFirst(RegExp(r'^the\s+'), ''));
    if (ordinal != null) {
      final type = ordinal.group(2)!;
      final number =
          int.tryParse(ordinal.group(3) ?? '') ??
          ordinals[ordinal.group(1) ?? ''];
      return number == null ? type : '$type#$number';
    }
    return normalized;
  }

  static bool _sameSite(String? left, String? right) =>
      left != null &&
      right != null &&
      _canonicalSiteAlias(left.toLowerCase()) ==
          _canonicalSiteAlias(right.toLowerCase());

  static NetworkIntent _attachSitePc(
    NetworkIntent intent,
    NetNode device, {
    required String siteId,
    required List<String> incidental,
  }) {
    final switches =
        intent.nodes
            .where((node) => node.type.toLowerCase() == 'switch')
            .where((node) => _sameSite(node.siteId, siteId))
            .toList()
          ..sort(_compareDeviceNames);
    if (switches.isEmpty) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'site_switch_not_found',
        'The plan has no access switch assigned to ${device.siteId}. Add or identify that site’s switch first.',
      );
    }
    NetNode? chosenSwitch;
    String? chosenPort;
    for (final accessSwitch in switches) {
      final capacity = NetworkIntent.switchPortCapacity(accessSwitch.model);
      final usedPorts = <int>{};
      for (final link in intent.links) {
        final iface = link.a == accessSwitch.name
            ? link.aIf
            : link.b == accessSwitch.name
            ? link.bIf
            : null;
        final match = iface == null
            ? null
            : RegExp(
                r'^(?:f|fa|fastethernet)0/(\d+)$',
                caseSensitive: false,
              ).firstMatch(iface.replaceAll(' ', ''));
        if (match != null) usedPorts.add(int.parse(match.group(1)!));
      }
      for (var port = 2; port <= capacity; port++) {
        if (usedPorts.contains(port)) continue;
        chosenSwitch = accessSwitch;
        chosenPort = 'f0/$port';
        break;
      }
      if (chosenSwitch != null) break;
    }
    if (chosenSwitch == null || chosenPort == null) {
      throw _OperationProblem(
        RequestIssueKind.conflict,
        'site_switch_has_no_free_port',
        'No compatible free switch port is available at ${device.siteId}. The plan was left unchanged.',
      );
    }
    NetLink? peerLink;
    for (final link in intent.links) {
      final neighborName = link.a == chosenSwitch.name
          ? link.b
          : link.b == chosenSwitch.name
          ? link.a
          : null;
      if (neighborName == null) continue;
      final neighbor = intent.nodes
          .where((node) => node.name == neighborName)
          .firstOrNull;
      if (neighbor == null ||
          neighbor.type.toLowerCase() == 'router' ||
          neighbor.type.toLowerCase() == 'switch' ||
          !_sameSite(neighbor.siteId, siteId)) {
        continue;
      }
      peerLink = link;
      break;
    }
    final endpointInterface = peerLink == null
        ? 'f0'
        : peerLink.a == chosenSwitch.name
        ? peerLink.bIf
        : peerLink.aIf;
    final newLink = NetLink(
      a: chosenSwitch.name,
      aIf: chosenPort,
      b: device.name,
      bIf: endpointInterface,
      cable: peerLink?.cable,
    );
    var wired = intent.copyWith(links: [...intent.links, newLink]);
    final subnets = _siteLanSubnets(wired, chosenSwitch.name, siteId);
    if (subnets.length != 1) {
      throw _OperationProblem(
        RequestIssueKind.ambiguity,
        subnets.isEmpty ? 'site_lan_not_found' : 'site_lan_ambiguous',
        subnets.isEmpty
            ? 'The plan has no addressable LAN at ${device.siteId} for the new PC.'
            : 'The site has more than one LAN subnet. Name the VLAN or LAN for the new PC.',
      );
    }
    final cidr = _nextFreeIpv4(subnets.single, wired.addressing);
    if (cidr == null) {
      throw _OperationProblem(
        RequestIssueKind.invalid,
        'site_lan_has_no_free_address',
        'No free host address remains on the selected site LAN.',
      );
    }
    wired = wired.copyWith(
      addressing: [
        ...wired.addressing,
        InterfaceAddr(node: device.name, iface: newLink.bIf, ipCidr: cidr),
      ],
    );
    incidental.add(
      'Connected ${device.name} to ${chosenSwitch.name} at ${device.siteId} and assigned $cidr.',
    );
    return wired;
  }

  static Set<String> _siteLanSubnets(
    NetworkIntent intent,
    String switchName,
    String siteId,
  ) {
    final subnets = <String>{};
    for (final link in intent.links) {
      final router = link.a == switchName
          ? intent.nodes.where((node) => node.name == link.b).firstOrNull
          : link.b == switchName
          ? intent.nodes.where((node) => node.name == link.a).firstOrNull
          : null;
      if (router == null ||
          router.type.toLowerCase() != 'router' ||
          !_sameSite(router.siteId, siteId)) {
        continue;
      }
      final iface = link.a == switchName ? link.bIf : link.aIf;
      for (final address in intent.addressing.where(
        (item) => item.node == router.name && item.iface == iface,
      )) {
        final network = _networkCidr(address.ipCidr);
        if (network != null) subnets.add(network);
      }
    }
    if (subnets.isNotEmpty) return subnets;

    final neighbors = <String>{
      for (final link in intent.links)
        if (link.a == switchName) link.b else if (link.b == switchName) link.a,
    };
    for (final address in intent.addressing) {
      final node = intent.nodes
          .where((item) => item.name == address.node)
          .firstOrNull;
      if (node == null ||
          !neighbors.contains(node.name) ||
          !_sameSite(node.siteId, siteId)) {
        continue;
      }
      final network = _networkCidr(address.ipCidr);
      if (network != null) subnets.add(network);
    }
    return subnets;
  }

  static String? _networkCidr(String value) {
    final match = RegExp(
      r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final octets = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
    final prefix = int.parse(match.group(5)!);
    if (octets.any((octet) => octet > 255) || prefix > 30) return null;
    final address =
        (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
    final mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
    final network = address & mask;
    return '${(network >> 24) & 255}.${(network >> 16) & 255}.${(network >> 8) & 255}.${network & 255}/$prefix';
  }

  static String? _nextFreeIpv4(String networkCidr, List<InterfaceAddr> rows) {
    final parts = networkCidr.split('/');
    final prefix = int.parse(parts[1]);
    final octets = parts[0].split('.').map(int.parse).toList();
    final network =
        (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
    final hostCount = 1 << (32 - prefix);
    if (hostCount < 4) return null;
    final used = <int>{};
    for (final row in rows) {
      final match = RegExp(
        r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$',
      ).firstMatch(row.ipCidr.trim());
      if (match == null || int.parse(match.group(5)!) != prefix) continue;
      final address =
          (int.parse(match.group(1)!) << 24) |
          (int.parse(match.group(2)!) << 16) |
          (int.parse(match.group(3)!) << 8) |
          int.parse(match.group(4)!);
      final mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
      if ((address & mask) == network) {
        used.add(address - network);
      }
    }
    final firstPreferred = hostCount > 12 ? 10 : 1;
    for (var host = firstPreferred; host < hostCount - 1; host++) {
      if (!used.contains(host)) {
        final address = network + host;
        return '${(address >> 24) & 255}.${(address >> 16) & 255}.${(address >> 8) & 255}.${address & 255}/$prefix';
      }
    }
    return null;
  }

  static int _compareDeviceNames(NetNode left, NetNode right) {
    final leftMatch = RegExp(r'^(.*?)(\d+)$').firstMatch(left.name);
    final rightMatch = RegExp(r'^(.*?)(\d+)$').firstMatch(right.name);
    if (leftMatch != null && rightMatch != null) {
      final prefix = leftMatch
          .group(1)!
          .toLowerCase()
          .compareTo(rightMatch.group(1)!.toLowerCase());
      if (prefix != 0) return prefix;
      final number = int.parse(
        leftMatch.group(2)!,
      ).compareTo(int.parse(rightMatch.group(2)!));
      if (number != 0) return number;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  }

  static NetNode? _unambiguousTemplate(List<NetNode> existing, String type) {
    if (existing.isEmpty) return null;
    final first = existing.first;
    for (final node in existing.skip(1)) {
      if (node.model != first.model ||
          node.exactModel != first.exactModel ||
          !jsonValueEquals(node.modules, first.modules)) {
        throw _OperationProblem(
          RequestIssueKind.ambiguity,
          'model_choice_required',
          'The project has different $type models or modules. Specify which hardware the new devices should use.',
        );
      }
    }
    return first;
  }

  static NetworkIntent _removeDevices(
    NetworkIntent intent,
    PlanOperation operation,
    List<String> incidental,
  ) {
    final references = _requiredStringList(
      operation.payload['deviceIds'],
      'deviceIds',
    );
    final resolved = <String>{};
    for (final reference in references) {
      final node = _resolveNode(intent, reference);
      resolved.add(node.name);
    }
    _checkSecurityReferences(intent, resolved);

    return _removeNodeNames(intent, resolved, incidental);
  }

  static NetworkIntent _removeNodeNames(
    NetworkIntent intent,
    Set<String> resolved,
    List<String> incidental,
  ) {
    final links = intent.links
        .where(
          (link) => !resolved.contains(link.a) && !resolved.contains(link.b),
        )
        .toList();
    final addresses = intent.addressing
        .where((address) => !resolved.contains(address.node))
        .toList();
    final layout = Map<String, Offset?>.from(intent.layout)
      ..removeWhere((name, _) => resolved.contains(name));
    if (links.length != intent.links.length) {
      incidental.add('Removed links attached to ${resolved.join(', ')}.');
    }
    if (addresses.length != intent.addressing.length) {
      incidental.add('Removed addresses belonging to ${resolved.join(', ')}.');
    }
    if (layout.length != intent.layout.length) {
      incidental.add(
        'Removed saved canvas positions for ${resolved.join(', ')}.',
      );
    }
    final notes = _rewriteLayoutNotes(intent.notes, removedNames: resolved);
    if (!jsonValueEquals(notes, intent.notes)) {
      incidental.add('Updated saved layout groups after removing devices.');
    }
    return intent.copyWith(
      nodes: intent.nodes
          .where((node) => !resolved.contains(node.name))
          .toList(),
      links: links,
      addressing: addresses,
      layout: layout,
      notes: notes,
    );
  }

  static Set<String> _securityReferences(NetworkIntent intent, String name) {
    final security = intent.security;
    return {
      for (final reference in [
        security.aaaServer,
        security.aaaRouter,
        security.vpnPeerA,
        security.vpnPeerB,
      ])
        if (reference != null && reference.toLowerCase() == name.toLowerCase())
          reference,
    };
  }

  static bool _isSecurityReferenced(NetworkIntent intent, String name) =>
      _securityReferences(intent, name).isNotEmpty;

  static Set<String> _lockedDeviceNames(
    NetworkIntent base,
    List<PlanOperation> preserveOperations,
  ) {
    final locked = <String>{};
    final allNames = {for (final node in base.nodes) node.name.toLowerCase()};
    for (final operation in preserveOperations) {
      if (operation.payload['entireSemantic'] == true) {
        locked.addAll(allNames);
      }
      if (operation.scope.kind == RequirementScopeKind.device) {
        final matchingNames = base.nodes
            .where(
              (node) =>
                  node.name.toLowerCase() ==
                  operation.scope.scopeId.toLowerCase(),
            )
            .map((node) => node.name.toLowerCase());
        locked.addAll(matchingNames);
      }
      if (operation.scope.kind == RequirementScopeKind.site) {
        String? siteId;
        try {
          siteId = _resolveSiteId(base, operation.scope.scopeId);
        } on _OperationProblem {
          continue;
        }
        final siteNames = base.nodes
            .where((node) => _sameSite(node.siteId, siteId))
            .map((node) => node.name.toLowerCase())
            .toSet();
        final properties = _readOptionalStringList(
          operation.payload['properties'],
          'properties',
        );
        final normalized = properties
            .map(
              (property) =>
                  property.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
            )
            .toSet();
        if (operation.payload['entireSemantic'] == true ||
            normalized.intersection({
              'node',
              'nodes',
              'device',
              'devices',
              'inventory',
              'devicecount',
              'devicecounts',
            }).isNotEmpty) {
          locked.addAll(siteNames);
        }
        continue;
      }
      if (operation.scope.kind != RequirementScopeKind.project) continue;
      final properties = _readOptionalStringList(
        operation.payload['properties'],
        'properties',
      );
      final normalizedProperties = properties
          .map(
            (property) =>
                property.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
          )
          .toSet();
      if (normalizedProperties.intersection({
        'node',
        'nodes',
        'device',
        'devices',
        'inventory',
        'devicecount',
        'devicecounts',
      }).isNotEmpty) {
        locked.addAll(allNames);
      }
    }
    return locked;
  }

  static void _checkSecurityReferences(
    NetworkIntent intent,
    Set<String> deviceNames,
  ) {
    final security = intent.security;
    final references = <String?>[
      security.aaaServer,
      security.aaaRouter,
      security.vpnPeerA,
      security.vpnPeerB,
    ];
    if (references.any(
      (value) => value != null && deviceNames.contains(value),
    )) {
      throw const _OperationProblem(
        RequestIssueKind.conflict,
        'security_reference_blocks_removal',
        'A selected device is referenced by AAA or VPN security. Update or remove that security relationship in the same request before removing the device.',
      );
    }
  }

  static NetworkIntent _renameDevice(
    NetworkIntent intent,
    PlanOperation operation,
    List<String> incidental,
  ) {
    final oldName = _string(operation, 'deviceId');
    final newName = _string(operation, 'newName');
    final node = _resolveNode(intent, oldName);
    if (newName.trim().isEmpty || newName != newName.trim()) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'invalid_device_name',
        'The new device name cannot be empty or padded with spaces.',
      );
    }
    if (intent.nodes.any(
      (candidate) =>
          candidate.name.toLowerCase() == newName.toLowerCase() &&
          candidate.name != node.name,
    )) {
      throw _OperationProblem(
        RequestIssueKind.conflict,
        'duplicate_device_name',
        'The name "$newName" already belongs to another device.',
      );
    }
    if (node.name == newName) return intent;
    final primary = intent.addressing
        .where((a) => a.node == node.name)
        .firstOrNull;
    final fallback = primary?.iface ?? deviceKindOf(node.type)?.port ?? 'g0/0';
    final renamed = TopologyEditService.editDevice(
      intent: intent,
      oldName: node.name,
      newName: newName,
      primaryIpv4: primary?.ipCidr ?? '',
      fallbackInterface: fallback,
    );
    final notes = _rewriteLayoutNotes(
      renamed.notes,
      renamedNames: {node.name: newName},
    );
    if (!jsonValueEquals(notes, renamed.notes)) {
      incidental.add(
        'Updated saved layout references from ${node.name} to $newName.',
      );
    }
    return renamed.copyWith(notes: notes);
  }

  static NetworkIntent _setDeviceModel(
    NetworkIntent intent,
    PlanOperation operation, {
    required String target,
  }) {
    final ids = _requiredStringList(
      operation.payload['deviceIds'],
      'deviceIds',
    );
    final model = _string(operation, 'model');
    if (ValidatorService.isPacketTracerTarget(target)) {
      final device = PacketTracerCatalog.instance.device(model);
      if (device == null || !device.placeable) {
        throw _OperationProblem(
          RequestIssueKind.unsupported,
          'model_not_buildable',
          'Packet Tracer has no buildable template for the exact model "$model". Choose a supported model explicitly.',
        );
      }
      final selectedNodes = ids.map((id) => _resolveNode(intent, id)).toList();
      for (final node in selectedNodes) {
        final expectedType = deviceKindOf(node.type);
        if (expectedType == null ||
            device.type.toLowerCase() != expectedType.type.toLowerCase()) {
          throw _OperationProblem(
            RequestIssueKind.invalid,
            'model_device_type_mismatch',
            'The exact model "$model" is not a ${node.type} model.',
          );
        }
      }
    }
    final names = ids.map((id) => _resolveNode(intent, id).name).toSet();
    return intent.copyWith(
      nodes: [
        for (final node in intent.nodes)
          if (names.contains(node.name))
            NetNode(
              name: node.name,
              type: node.type,
              model: model,
              exactModel: true,
              modules: node.modules,
              mgmtIp: node.mgmtIp,
              siteId: node.siteId,
              services: node.services,
              serviceRules: node.serviceRules,
            )
          else
            node,
      ],
    );
  }

  static NetworkIntent _service(
    NetworkIntent intent,
    PlanOperation operation, {
    required bool remove,
    required Set<String> explicitServiceTargets,
  }) {
    final device = _resolveServiceNode(
      intent,
      _string(operation, 'deviceId'),
      explicitServiceTargets: explicitServiceTargets,
    );
    final service = _canonicalService(_string(operation, 'service'));
    if (operation.scope.kind == RequirementScopeKind.service &&
        operation.scope.scopeId.isNotEmpty &&
        operation.scope.scopeId.toLowerCase() != service) {
      throw const _OperationProblem(
        RequestIssueKind.conflict,
        'service_scope_mismatch',
        'The service named by this edit does not match the service scope in its requirement.',
      );
    }
    final settings = operation.payload['settings'] == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(operation.payload['settings'] as Map);
    return intent.copyWith(
      nodes: [
        for (final node in intent.nodes)
          if (node.name != device.name)
            node
          else
            _copyNodeService(node, service, settings, remove: remove),
      ],
    );
  }

  static NetNode _resolveServiceNode(
    NetworkIntent intent,
    String reference, {
    required Set<String> explicitServiceTargets,
  }) {
    if (!const {
      'another server',
      'other server',
    }.contains(reference.toLowerCase())) {
      return _resolveNode(intent, reference);
    }
    final candidates = intent.nodes
        .where((node) => node.type.toLowerCase() == 'server')
        .where(
          (node) => !explicitServiceTargets.contains(node.name.toLowerCase()),
        )
        .toList();
    if (candidates.length == 1) return candidates.single;
    throw _OperationProblem(
      candidates.isEmpty
          ? RequestIssueKind.missingInput
          : RequestIssueKind.ambiguity,
      candidates.isEmpty ? 'server_not_found' : 'server_reference_ambiguous',
      candidates.isEmpty
          ? 'There is no unselected existing server for this service assignment.'
          : 'More than one unselected server could receive this service. Name the exact server.',
    );
  }

  static NetNode _copyNodeService(
    NetNode node,
    String service,
    Map<String, dynamic> settings, {
    required bool remove,
  }) {
    final services = node.services.toList();
    final rules = Map<String, dynamic>.from(
      mutableJsonCopy(node.serviceRules) as Map,
    );
    if (remove) {
      services.removeWhere((value) => value.toLowerCase() == service);
      rules.removeWhere((key, _) => key.toLowerCase() == service);
    } else {
      if (!services.any((value) => value.toLowerCase() == service)) {
        services.add(service);
      }
      if (settings.isNotEmpty) {
        final oldKey = rules.keys
            .where((key) => key.toLowerCase() == service)
            .firstOrNull;
        final old = oldKey != null && rules[oldKey] is Map
            ? Map<String, dynamic>.from(rules[oldKey] as Map)
            : <String, dynamic>{};
        rules.removeWhere((key, _) => key.toLowerCase() == service);
        rules[service] = _deepMerge(old, settings);
      }
    }
    return NetNode(
      name: node.name,
      type: node.type,
      model: node.model,
      exactModel: node.exactModel,
      modules: node.modules,
      mgmtIp: node.mgmtIp,
      siteId: node.siteId,
      services: services,
      serviceRules: rules,
    );
  }

  static Map<String, dynamic> _deepMerge(
    Map<String, dynamic> previous,
    Map<String, dynamic> next,
  ) {
    final merged = Map<String, dynamic>.from(previous);
    for (final entry in next.entries) {
      final old = merged[entry.key];
      final value = entry.value;
      merged[entry.key] = old is Map && value is Map
          ? _deepMerge(
              Map<String, dynamic>.from(old),
              Map<String, dynamic>.from(value),
            )
          : mutableJsonCopy(value);
    }
    return merged;
  }

  static NetworkIntent _setAddress(
    NetworkIntent intent,
    PlanOperation operation, {
    required String target,
  }) {
    final node = _resolveNode(intent, _string(operation, 'deviceId'));
    final iface = _string(operation, 'interfaceId');
    final family = _string(operation, 'family').toLowerCase();
    final value = _string(operation, 'value');
    if (iface.trim() != iface || iface.isEmpty) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'invalid_interface',
        'The interface name must be exact and non-empty.',
      );
    }
    if (ValidatorService.isPacketTracerTarget(target) &&
        !_packetTracerHasInterface(node, iface)) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'interface_not_on_device',
        '${node.name} does not have an exact "$iface" interface in its selected model and modules.',
      );
    }
    if (!ValidatorService.isPacketTracerTarget(target) &&
        !RegExp(
          r'^[A-Za-z][A-Za-z0-9-]*\d+(?:/\d+){0,2}(?:\.\d+)?$',
        ).hasMatch(iface)) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'invalid_interface',
        'The interface name is not in a supported IOS form.',
      );
    }
    final matches = <int>[];
    for (var index = 0; index < intent.addressing.length; index++) {
      final row = intent.addressing[index];
      if (row.node == node.name && ptPortName(row.iface) == ptPortName(iface)) {
        matches.add(index);
      }
    }
    if (matches.length > 1) {
      throw _OperationProblem(
        RequestIssueKind.ambiguity,
        'duplicate_address_rows',
        '${node.name} has more than one address row for $iface. Resolve the duplicate before editing this interface.',
      );
    }
    if (family == 'ipv6' && matches.isEmpty) {
      throw const _OperationProblem(
        RequestIssueKind.unsupported,
        'ipv6_only_address_row_not_representable',
        'The current plan requires an IPv4 address row before it can store IPv6 on that interface. Add or select the IPv4 row first.',
      );
    }
    final addresses = intent.addressing.toList();
    if (matches.isEmpty) {
      addresses.add(
        InterfaceAddr(
          node: node.name,
          iface: iface,
          ipCidr: family == 'ipv4' ? value : '',
          ip6Cidr: family == 'ipv6' ? value : null,
        ),
      );
    } else {
      final index = matches.single;
      final previous = addresses[index];
      addresses[index] = InterfaceAddr(
        node: previous.node,
        iface: previous.iface,
        ipCidr: family == 'ipv4' ? value : previous.ipCidr,
        ip6Cidr: family == 'ipv6' ? value : previous.ip6Cidr,
      );
    }
    return intent.copyWith(addressing: addresses);
  }

  static bool _packetTracerHasInterface(NetNode node, String iface) {
    final catalog = PacketTracerCatalog.instance;
    final model =
        node.model ?? deviceKindOf(node.type)?.models.firstOrNull ?? '';
    final device = catalog.device(model);
    if (device == null) return false;
    final physical = iface.split('.').first;
    final subinterface = iface.contains('.');
    if (subinterface &&
        (node.type != 'router' ||
            int.tryParse(iface.substring(iface.lastIndexOf('.') + 1)) ==
                null)) {
      return false;
    }
    return device.variants.any(
      (variant) =>
          node.modules.every(
            (module) => variant.modules.any(
              (available) => ptIdentity(available) == ptIdentity(module),
            ),
          ) &&
          variant.ports.any(
            (port) => ptPortName(port.name) == ptPortName(physical),
          ),
    );
  }

  static NetworkIntent _setLink(NetworkIntent intent, PlanOperation operation) {
    final action = _string(operation, 'action').toLowerCase();
    final aName = _resolveNode(intent, _string(operation, 'aDeviceId')).name;
    final bName = _resolveNode(intent, _string(operation, 'bDeviceId')).name;
    final aIf = _string(operation, 'aInterfaceId');
    final bIf = _string(operation, 'bInterfaceId');
    if (aName == bName) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'self_link',
        'A device cannot be connected to itself by this link operation.',
      );
    }
    bool sameEndpoints(NetLink link) =>
        ((link.a == aName && ptPortName(link.aIf) == ptPortName(aIf)) &&
            (link.b == bName && ptPortName(link.bIf) == ptPortName(bIf))) ||
        ((link.a == bName && ptPortName(link.aIf) == ptPortName(bIf)) &&
            (link.b == aName && ptPortName(link.bIf) == ptPortName(aIf)));
    final matches = intent.links.where(sameEndpoints).toList();
    final cable = _string(operation, 'cableType').toLowerCase();
    if (action == 'add') {
      if (matches.length == 1) {
        final existing = matches.single;
        if ((existing.cable ?? 'auto').toLowerCase() == cable) return intent;
        throw const _OperationProblem(
          RequestIssueKind.conflict,
          'link_already_exists',
          'Those exact ports already connect with a different cable. Use a replace operation to change the cable.',
        );
      }
      if (matches.length > 1) {
        throw const _OperationProblem(
          RequestIssueKind.ambiguity,
          'duplicate_links',
          'More than one link already uses those exact endpoints.',
        );
      }
      final link = _linkValue(aName, aIf, bName, bIf, cable);
      return intent.copyWith(links: [...intent.links, link]);
    }
    if (matches.length != 1) {
      throw _OperationProblem(
        matches.isEmpty
            ? RequestIssueKind.missingInput
            : RequestIssueKind.ambiguity,
        matches.isEmpty ? 'link_not_found' : 'duplicate_links',
        matches.isEmpty
            ? 'No existing link uses those exact endpoint devices and ports.'
            : 'More than one link uses those exact endpoints; choose which one to edit.',
      );
    }
    if (action == 'remove') {
      return intent.copyWith(
        links: intent.links.where((link) => !sameEndpoints(link)).toList(),
      );
    }
    final old = matches.single;
    final replacement = _linkValue(old.a, old.aIf, old.b, old.bIf, cable);
    return intent.copyWith(
      links: [
        for (final link in intent.links)
          sameEndpoints(link) ? replacement : link,
      ],
    );
  }

  static NetLink _linkValue(
    String a,
    String aIf,
    String b,
    String bIf,
    String cable,
  ) {
    final automatic = cable == 'auto';
    return NetLink(
      a: a,
      aIf: aIf,
      b: b,
      bIf: bIf,
      cable: automatic ? null : cable,
      exactPorts: true,
      dce: cable.startsWith('serial') ? 'a' : null,
    );
  }

  static NetworkIntent _setLayout(
    NetworkIntent intent,
    PlanOperation operation,
  ) {
    final style = _string(operation, 'style').toLowerCase();
    if (style != 'grouped' && !LayoutRequest.allStyles.contains(style)) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'layout_style_unsupported',
        'The layout style "$style" is not supported by the current renderer.',
      );
    }
    final rawZones = operation.payload['zones'];
    final Map zones = rawZones == null ? const {} : rawZones as Map;
    final sideKinds = _readOptionalStringList(
      zones['sideKinds'],
      'sideKinds',
    ).map((kind) => deviceKindOf(kind)?.type ?? kind).toList();
    final sideNames = _readOptionalStringList(
      zones['sideNames'],
      'sideNames',
    ).map((name) => _resolveNode(intent, name).name).toList();
    final edge = '${zones['sideEdge'] ?? 'left'}'.toLowerCase();
    if (edge != 'left' && edge != 'right') {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'invalid_layout_edge',
        'A grouped layout edge must be left or right.',
      );
    }
    final groupedZones = <LayoutZoneRequest>[];
    final nested = zones['zones'];
    if (nested != null) {
      if (nested is! List) {
        throw const _OperationProblem(
          RequestIssueKind.invalid,
          'invalid_layout_zones',
          'Layout zones must be a list of named device groups.',
        );
      }
      for (final item in nested) {
        if (item is! Map) {
          throw const _OperationProblem(
            RequestIssueKind.invalid,
            'invalid_layout_zone',
            'Each layout zone must be an object.',
          );
        }
        if (item.containsKey('sideEdge') &&
            item.containsKey('edge') &&
            '${item['sideEdge']}'.toLowerCase() !=
                '${item['edge']}'.toLowerCase()) {
          throw const _OperationProblem(
            RequestIssueKind.conflict,
            'conflicting_layout_edges',
            'A layout zone specifies two different edges. Keep only one edge value.',
          );
        }
        final zoneKinds = _readOptionalStringList(
          item['sideKinds'],
          'sideKinds',
        );
        final zoneNames = _readOptionalStringList(
          item['sideNames'],
          'sideNames',
        ).map((name) => _resolveNode(intent, name).name).toList();
        final canonicalZoneKinds = zoneKinds
            .map((kind) => deviceKindOf(kind)?.type ?? kind)
            .toList();
        final zoneEdge = '${item['sideEdge'] ?? item['edge'] ?? ''}'
            .toLowerCase();
        if (zoneEdge.isNotEmpty && zoneEdge != 'left' && zoneEdge != 'right') {
          throw const _OperationProblem(
            RequestIssueKind.invalid,
            'invalid_layout_edge',
            'Each layout zone edge must be left or right.',
          );
        }
        if (item.keys.any(
          (key) => !const {
            'sideKinds',
            'sideNames',
            'sideEdge',
            'edge',
          }.contains('$key'),
        )) {
          throw const _OperationProblem(
            RequestIssueKind.invalid,
            'unknown_layout_zone_field',
            'A layout zone contains an unsupported option.',
          );
        }
        if (canonicalZoneKinds.isEmpty && zoneNames.isEmpty) {
          throw const _OperationProblem(
            RequestIssueKind.missingInput,
            'layout_zone_empty',
            'Each named layout zone needs device kinds or exact device names.',
          );
        }
        _resolveLayoutTargets(intent, canonicalZoneKinds, zoneNames);
        groupedZones.add(
          LayoutZoneRequest(
            kinds: canonicalZoneKinds,
            names: zoneNames,
            edge: zoneEdge.isEmpty ? 'left' : zoneEdge,
          ),
        );
      }
    }
    if (zones.keys.any(
      (key) => !const {
        'sideKinds',
        'sideNames',
        'sideEdge',
        'zones',
      }.contains('$key'),
    )) {
      throw const _OperationProblem(
        RequestIssueKind.invalid,
        'unknown_layout_field',
        'The layout edit contains an unsupported option.',
      );
    }
    if (style == 'grouped') {
      _resolveLayoutTargets(intent, sideKinds, sideNames);
      if (groupedZones.isEmpty && sideKinds.isEmpty && sideNames.isEmpty) {
        throw const _OperationProblem(
          RequestIssueKind.missingInput,
          'layout_targets_missing',
          'A grouped layout needs the device kinds or exact device names to move.',
        );
      }
    } else if (groupedZones.isNotEmpty ||
        sideKinds.isNotEmpty ||
        sideNames.isNotEmpty) {
      throw const _OperationProblem(
        RequestIssueKind.unsupported,
        'layout_zones_require_grouped_style',
        'The current renderer supports named side zones only with the grouped layout style.',
      );
    }
    final note = LayoutRequest.noteFor(
      style,
      sideKinds: sideKinds,
      sideNames: sideNames,
      sideEdge: edge,
      zones: groupedZones,
    );
    final notes = [
      for (final current in intent.notes)
        if (!current.trim().toLowerCase().startsWith('layout:')) current,
      note,
    ];
    return intent.copyWith(notes: notes);
  }

  static void _resolveLayoutTargets(
    NetworkIntent intent,
    List<String> kinds,
    List<String> names,
  ) {
    for (final kind in kinds) {
      if (deviceKindOf(kind) == null) {
        throw _OperationProblem(
          RequestIssueKind.unsupported,
          'unknown_layout_device_kind',
          'The layout group names an unknown device kind "$kind".',
        );
      }
    }
    for (final name in names) {
      _resolveNode(intent, name);
    }
  }

  static NetworkIntent _deepCopy(NetworkIntent intent) =>
      NetworkIntent.fromJson(
        Map<String, dynamic>.from(intent.toJson(includeSecrets: true)),
      );

  static NetNode _resolveNode(NetworkIntent intent, String reference) {
    final matches = intent.nodes
        .where((node) => node.name.toLowerCase() == reference.toLowerCase())
        .toList();
    if (matches.length != 1) {
      throw _OperationProblem(
        matches.isEmpty
            ? RequestIssueKind.missingInput
            : RequestIssueKind.ambiguity,
        matches.isEmpty ? 'device_not_found' : 'device_name_ambiguous',
        matches.isEmpty
            ? 'No device named "$reference" exists in this plan. Use an exact current device name.'
            : 'More than one device matches "$reference"; select one exact device name.',
      );
    }
    return matches.single;
  }

  static String _canonicalDeviceType(String raw) {
    final type = raw.trim().toLowerCase();
    final kind = deviceKindOf(type);
    if (kind == null) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'unknown_device_kind',
        'The device type "$raw" is not in the planner’s supported vocabulary.',
      );
    }
    return kind.type.toLowerCase();
  }

  static String _canonicalService(String raw) {
    final value = raw.trim().toLowerCase();
    if (!const {
      'dhcp',
      'dns',
      'http',
      'aaa',
      'email',
      'ftp',
      'ntp',
      'tftp',
      'syslog',
      'dhcpv6',
      'iot',
      'prp',
      'snmp',
      'vm',
      'cme',
      'radiuseap',
    }.contains(value)) {
      throw _OperationProblem(
        RequestIssueKind.unsupported,
        'unknown_service',
        'The service "$raw" is not in the supported service vocabulary.',
      );
    }
    return value;
  }

  static String _string(PlanOperation operation, String key) {
    final value = operation.payload[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException(
        'Operation field "$key" must be a non-empty string.',
      );
    }
    return value;
  }

  static int _integer(PlanOperation operation, String key) {
    final value = operation.payload[key];
    if (value is! int) {
      throw FormatException('Operation field "$key" must be an integer.');
    }
    return value;
  }

  static List<String> _stringList(
    Object? value,
    String label, {
    bool optional = false,
  }) {
    if (optional && value == null) return const [];
    if (value is! List ||
        value.any((item) => item is! String || item.trim().isEmpty)) {
      throw FormatException(
        'Operation field "$label" must be a list of non-empty strings.',
      );
    }
    return value.cast<String>();
  }

  static List<String> _requiredStringList(Object? value, String label) {
    final values = _stringList(value, label);
    if (values.isEmpty) {
      throw FormatException('Operation field "$label" cannot be empty.');
    }
    if (values.map((item) => item.toLowerCase()).toSet().length !=
        values.length) {
      throw FormatException(
        'Operation field "$label" cannot contain duplicates.',
      );
    }
    return values;
  }

  static List<String> _readOptionalStringList(Object? value, String label) =>
      value == null ? const [] : _stringList(value, label);

  static Map<String, String> _renamedNames(List<PlanOperation> operations) {
    final names = <String, String>{};
    for (final operation in operations) {
      if (operation.kind != PlanOperationKind.renameDevice) continue;
      final oldName = _string(operation, 'deviceId');
      final newName = _string(operation, 'newName');
      for (final key in names.keys.toList()) {
        if (names[key]!.toLowerCase() == oldName.toLowerCase()) {
          names[key] = newName;
        }
      }
      names[oldName.toLowerCase()] = newName;
    }
    return names;
  }

  static void _checkPreservation(
    NetworkIntent base,
    NetworkIntent candidate,
    PlanOperation operation, {
    required Map<String, String> renamedNames,
  }) {
    if (operation.scope.kind != RequirementScopeKind.project &&
        operation.scope.kind != RequirementScopeKind.device &&
        operation.scope.kind != RequirementScopeKind.site) {
      throw const _OperationProblem(
        RequestIssueKind.unsupported,
        'preserve_scope_not_representable',
        'This plan can verify preservation only for the whole project, one exact site or device.',
      );
    }
    if (operation.payload['entireSemantic'] == true) {
      final unchanged = operation.scope.kind == RequirementScopeKind.site
          ? jsonValueEquals(
              {
                'devices': _preservedValue(base, operation.scope, 'devices'),
                'links': _preservedValue(base, operation.scope, 'links'),
                'addressing': _preservedValue(
                  base,
                  operation.scope,
                  'addressing',
                ),
                'layout': _preservedValue(base, operation.scope, 'layout'),
              },
              {
                'devices': _preservedValue(
                  candidate,
                  operation.scope,
                  'devices',
                ),
                'links': _preservedValue(candidate, operation.scope, 'links'),
                'addressing': _preservedValue(
                  candidate,
                  operation.scope,
                  'addressing',
                ),
                'layout': _preservedValue(candidate, operation.scope, 'layout'),
              },
            )
          : base.revision == candidate.revision;
      if (!unchanged) {
        throw const _OperationProblem(
          RequestIssueKind.conflict,
          'preserve_semantic_design_violated',
          'The candidate changes the semantic network while the request says to preserve the entire design.',
        );
      }
      return;
    }
    final properties = _readOptionalStringList(
      operation.payload['properties'],
      'properties',
    );
    for (final property in properties) {
      final before = _preservedValue(base, operation.scope, property);
      final scopeId = operation.scope.kind == RequirementScopeKind.device
          ? renamedNames[operation.scope.scopeId.toLowerCase()] ??
                operation.scope.scopeId
          : operation.scope.scopeId;
      final afterScope = RequirementScope(
        kind: operation.scope.kind,
        scopeId: scopeId,
      );
      final after = _preservedValue(candidate, afterScope, property);
      if (!jsonValueEquals(before, after)) {
        throw _OperationProblem(
          RequestIssueKind.conflict,
          'preserve_constraint_violated',
          'The candidate changes "$property", which the request asked to preserve.',
        );
      }
    }
  }

  static Object? _preservedValue(
    NetworkIntent intent,
    RequirementScope scope,
    String property,
  ) {
    final key = property.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (scope.kind == RequirementScopeKind.site) {
      final siteId = _resolveSiteId(intent, scope.scopeId);
      final nodes = intent.nodes
          .where((node) => _sameSite(node.siteId, siteId))
          .toList();
      final names = {for (final node in nodes) node.name};
      return switch (key) {
        'device' || 'node' || 'devices' || 'nodes' => [
          for (final node in nodes) node.toJson(includeSecrets: false),
        ],
        'inventory' || 'devicecount' || 'devicecounts' => _countsFor(nodes),
        'model' || 'models' || 'devicemodel' || 'devicemodels' => [
          for (final node in nodes)
            {'name': node.name, 'model': node.model, 'modules': node.modules},
        ],
        'services' || 'serviceroles' => [
          for (final node in nodes)
            {
              'name': node.name,
              'services': node.services,
              'rules': mutableJsonCopy(node.serviceRules),
            },
        ],
        'links' || 'topology' => [
          for (final link in intent.links)
            if (names.contains(link.a) || names.contains(link.b)) link.toJson(),
        ],
        'addressing' || 'addresses' => [
          for (final row in intent.addressing)
            if (names.contains(row.node)) row.toJson(),
        ],
        'layout' => {
          'positions': {
            for (final entry in intent.layout.entries)
              if (names.contains(entry.key))
                entry.key: entry.value == null
                    ? null
                    : {'x': entry.value!.dx, 'y': entry.value!.dy},
          },
          'notes': [
            for (final note in intent.notes)
              if (note.trim().toLowerCase().startsWith('layout:')) note,
          ],
        },
        'routing' || 'routingprotocol' => intent.routing,
        _ => throw _unknownPreserveProperty(property),
      };
    }
    if (scope.kind == RequirementScopeKind.device) {
      final node = _resolveNode(intent, scope.scopeId);
      return switch (key) {
        'device' || 'node' => node.toJson(includeSecrets: false),
        'name' || 'devicename' => node.name,
        'type' || 'devicetype' => node.type,
        'model' || 'devicemodel' => node.model,
        'services' || 'serviceroles' => {
          'services': node.services,
          'rules': mutableJsonCopy(node.serviceRules),
        },
        'addressing' || 'addresses' => [
          for (final row in intent.addressing)
            if (row.node == node.name) row.toJson(),
        ],
        'links' => [
          for (final link in intent.links)
            if (link.a == node.name || link.b == node.name) link.toJson(),
        ],
        'layout' =>
          intent.layout[node.name] == null
              ? null
              : {
                  'x': intent.layout[node.name]!.dx,
                  'y': intent.layout[node.name]!.dy,
                },
        _ => throw _unknownPreserveProperty(property),
      };
    }
    return switch (key) {
      'routing' || 'routingprotocol' => intent.routing,
      'nodes' || 'devices' => [
        for (final node in intent.nodes) node.toJson(includeSecrets: false),
      ],
      'devicecount' || 'devicecounts' || 'inventory' => _counts(intent),
      'model' || 'models' || 'devicemodel' || 'devicemodels' => [
        for (final node in intent.nodes)
          {'name': node.name, 'model': node.model, 'modules': node.modules},
      ],
      'services' || 'serviceroles' => [
        for (final node in intent.nodes)
          {
            'name': node.name,
            'services': node.services,
            'rules': mutableJsonCopy(node.serviceRules),
          },
      ],
      'links' || 'topology' => [for (final link in intent.links) link.toJson()],
      'addressing' ||
      'addresses' => [for (final row in intent.addressing) row.toJson()],
      'vlan' || 'vlans' => intent.vlans,
      'security' => intent.security.toJson(includeSecrets: false),
      'layout' => {
        'positions': intent.layout.map(
          (name, point) => MapEntry(
            name,
            point == null ? null : {'x': point.dx, 'y': point.dy},
          ),
        ),
        'notes': [
          for (final note in intent.notes)
            if (note.trim().toLowerCase().startsWith('layout:')) note,
        ],
      },
      'notes' => intent.notes,
      'projectname' => intent.projectName,
      _ => throw _unknownPreserveProperty(property),
    };
  }

  static _OperationProblem _unknownPreserveProperty(
    String property,
  ) => _OperationProblem(
    RequestIssueKind.unsupported,
    'preserve_property_unsupported',
    'The preservation property "$property" is not one the current plan can check.',
  );

  static Map<String, int> _counts(NetworkIntent intent) {
    return _countsFor(intent.nodes);
  }

  static Map<String, int> _countsFor(Iterable<NetNode> nodes) {
    final output = <String, int>{};
    for (final node in nodes) {
      output.update(node.type, (value) => value + 1, ifAbsent: () => 1);
    }
    return output;
  }

  static List<String> _rewriteLayoutNotes(
    List<String> notes, {
    Set<String> removedNames = const {},
    Map<String, String> renamedNames = const {},
  }) => [
    for (final note in notes)
      if (LayoutRequest.styleFromNote(note).isEmpty)
        note
      else
        _rewriteLayoutNote(
          note,
          removedNames: removedNames,
          renamedNames: renamedNames,
        ),
  ];

  static String _rewriteLayoutNote(
    String note, {
    required Set<String> removedNames,
    required Map<String, String> renamedNames,
  }) {
    final style = LayoutRequest.styleFromNote(note);
    final names = LayoutRequest.sideNamesFromNote(note)
        .where((name) => !removedNames.contains(name))
        .map((name) => renamedNames[name] ?? name)
        .toList();
    final zones = <LayoutZoneRequest>[];
    for (final zone in LayoutRequest.zonesFromNote(note)) {
      final zoneNames = zone.names
          .where((name) => !removedNames.contains(name))
          .map((name) => renamedNames[name] ?? name)
          .toList();
      if (zone.kinds.isNotEmpty || zoneNames.isNotEmpty) {
        zones.add(
          LayoutZoneRequest(
            kinds: zone.kinds,
            names: zoneNames,
            edge: zone.edge,
          ),
        );
      }
    }
    return LayoutRequest.noteFor(
      style,
      sideKinds: LayoutRequest.sideKindsFromNote(note),
      sideNames: names,
      sideEdge: LayoutRequest.sideEdgeFromNote(note),
      zones: zones,
    );
  }
}
