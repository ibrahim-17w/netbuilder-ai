import 'dart:convert';

import '../../models/network_intent.dart';
import '../../models/request_contract_utils.dart';
import '../../models/request_coverage.dart';
import '../../models/request_requirement.dart';
import '../human_language.dart';
import '../network_tools.dart';
import '../packet_tracer/catalog.dart';
import '../packet_tracer/endpoint_reference.dart';
import 'target_capability_service.dart';

/// Checks the typed contract, not the prose or the generator's own claims.
/// Delivery is deliberately left pending: a plan is not artifact evidence.
class CoverageChecker {
  const CoverageChecker._();

  static CoverageReport check({
    required NetworkIntent? plan,
    required Iterable<Requirement> requirements,
    required String target,
    NetworkIntent? base,
  }) => CoverageReport(
    requirements: [
      for (final requirement in requirements)
        _check(requirement, plan: plan, base: base, target: target),
    ],
  );

  static RequirementCoverage _check(
    Requirement r, {
    required NetworkIntent? plan,
    required NetworkIntent? base,
    required String target,
  }) {
    RequirementCoverage result(PlanningStatus status, String explanation) =>
        RequirementCoverage(
          requirementId: r.id,
          planning: status,
          delivery:
              r.state == RequirementState.superseded ||
                  r.phase == RequirementPhase.planning
              ? DeliveryStatus.notRequested
              : DeliveryStatus.pending,
          explanation: explanation,
        );
    if (r.state == RequirementState.superseded) {
      return result(PlanningStatus.superseded, 'Replaced by a later decision.');
    }
    if (r.state == RequirementState.unresolved) {
      return result(
        PlanningStatus.unresolved,
        'The ${r.property} requirement is unresolved; its original constraint is retained.',
      );
    }
    if (plan == null) {
      return result(PlanningStatus.unresolved, 'No candidate plan to check.');
    }
    try {
      final finding = _measure(r, plan, base);
      if (finding.$1 != PlanningStatus.satisfied) {
        return result(finding.$1, finding.$2);
      }
      final capability = TargetCapabilityService.forRequirement(
        r,
        target: target,
        plan: plan,
      );
      // Unsupported generation must not be reported as full plan compliance.
      // Read-back/live support is independent and never inferred from this.
      for (final support in [capability.model, capability.generate]) {
        if (support.status == TargetSupportStatus.unsupported) {
          return result(
            PlanningStatus.unsupported,
            '${finding.$2} ${support.reason}'
            '${support.alternatives.isEmpty ? '' : ' Alternatives: ${support.alternatives.join('; ')}.'}',
          );
        }
      }
      return result(finding.$1, finding.$2);
    } on _Uncheckable catch (problem) {
      return result(problem.status, problem.message);
    } on FormatException catch (problem) {
      return result(PlanningStatus.unresolved, problem.message.toString());
    }
  }

  static (PlanningStatus, String) _measure(
    Requirement r,
    NetworkIntent plan,
    NetworkIntent? base,
  ) {
    if (r.comparator == RequirementComparator.preserve) {
      return _preservation(r, plan, base);
    }
    final property = RequirementPlanFacts.propertyKey(
      r.property,
      subject: r.subject,
    );
    switch (property) {
      case 'allocationsites':
        final value = r.value;
        if (value is! Map || value['sites'] is! List) {
          return _unknown('Site inventory must retain its known site IDs.');
        }
        final sites = (value['sites'] as List).whereType<String>().toList();
        final actual = plan.nodes
            .map((n) => n.siteId)
            .whereType<String>()
            .map(RequirementPlanFacts.canonicalSite)
            .toSet();
        return _boolean(
          sites.every(
            (s) => actual.contains(RequirementPlanFacts.canonicalSite(s)),
          ),
          'Requested sites $sites; modeled site ownership $actual.',
        );
      case 'ospfarea':
        if (r.value is! int) return _unknown('OSPF area requires an integer.');
        if (r.value != 0) {
          return _unsupported(
            'The current IOS and Packet Tracer OSPF generator emits area 0; area ${r.value} is not supported.',
          );
        }
        return _boolean(
          plan.routing.toLowerCase() == 'ospf',
          'OSPF area 0 is generated for every routed network.',
        );
      case 'gateway':
        final requested = _stringValue(r);
        final rows = RequirementPlanFacts.addressesInScope(plan, r.scope);
        final routers = plan.nodes
            .where((n) => n.type == 'router')
            .map((n) => n.name.toLowerCase())
            .toSet();
        return _boolean(
          rows.any(
            (a) =>
                routers.contains(a.node.toLowerCase()) &&
                a.ipCidr.split('/').first == requested,
          ),
          'Requested gateway $requested must be assigned to a routed interface in ${_scopeLabel(r.scope)}.',
        );
      case 'roledevicecount':
        final service = RequirementPlanFacts.service(r.scope.scopeId);
        final ownerScope =
            r.scope.parent ??
            (r.scope.siteId.isEmpty
                ? RequirementScope.project('')
                : RequirementScope(
                    kind: RequirementScopeKind.site,
                    scopeId: r.scope.siteId,
                  ));
        final count = RequirementPlanFacts.nodesInScope(plan, ownerScope)
            .where(
              (n) =>
                  n.type == r.subject &&
                  n.services.any(
                    (s) => RequirementPlanFacts.service(s) == service,
                  ),
            )
            .length;
        if (r.value is! int) {
          return _unknown('Role inventory must be a non-negative integer.');
        }
        return _compareNumber(
          r,
          count,
          r.value as int,
          '$service server allocation',
        );
      case 'connectivity':
        return _connectivity(r, plan);
      case 'unsupportedserviceconfiguration':
        return _unsupported(
          r.value is Map
              ? '${(r.value as Map)['reason']}'
              : 'The advanced server configuration is not implemented.',
        );
      case 'projectname':
        if (!_equalityComparator(r)) return _unknownComparator(r);
        return _boolean(
          plan.projectName == _stringValue(r),
          'Project name is "${plan.projectName}"; requested "${_stringValue(r)}".',
        );
      case 'addressingmode':
        final nodes = RequirementPlanFacts.nodesInScope(plan, r.scope);
        final mode = _stringValue(r).toLowerCase();
        return _boolean(
          nodes.isNotEmpty &&
              nodes.every(
                (n) => (n.serviceRules['addressing'] as Map?)?['mode'] == mode,
              ),
          'Addressing mode $mode is retained for ${nodes.map((n) => n.name).join(', ')}.',
        );
      case 'link':
        if (r.value is! Map || !_equalityComparator(r)) {
          return _unknown('An exact link needs endpoint/port facts.');
        }
        final wanted = NetLink.fromJson(
          Map<String, dynamic>.from(r.value as Map),
        );
        final a = EndpointReference.resolve(wanted.a, plan.nodes);
        final b = EndpointReference.resolve(wanted.b, plan.nodes);
        if (a.ambiguous || b.ambiguous) {
          return _unknown(
            'Name the specific devices for cable ${wanted.a}:${wanted.aIf} to ${wanted.b}:${wanted.bIf}; the endpoint reference is ambiguous.',
          );
        }
        bool matches(NetLink link) {
          bool end(
            String actual,
            String actualIf,
            NetNode? expected,
            String expectedIf,
          ) =>
              expected != null &&
              actual.toLowerCase() == expected.name.toLowerCase() &&
              ptPortName(actualIf) == ptPortName(expectedIf);
          final direct =
              end(link.a, link.aIf, a.node, wanted.aIf) &&
              end(link.b, link.bIf, b.node, wanted.bIf);
          final reversed =
              end(link.a, link.aIf, b.node, wanted.bIf) &&
              end(link.b, link.bIf, a.node, wanted.aIf);
          final cable =
              wanted.cable == null ||
              (PacketTracerCatalog.instance.cable(link.cable)?.id ??
                      link.cable) ==
                  (PacketTracerCatalog.instance.cable(wanted.cable)?.id ??
                      wanted.cable);
          return (direct || reversed) && cable;
        }
        final present = plan.links.any(matches);
        return _boolean(
          r.comparator == RequirementComparator.forbidden ? !present : present,
          'Requested cable ${wanted.a}:${wanted.aIf} to ${wanted.b}:${wanted.bIf} ${present ? 'is present' : 'is missing'}.',
        );
      case 'devicecount':
      case 'scale':
        if (r.quantityRole == QuantityRole.userLoad) {
          return _unknown(
            'User load needs an explicit capacity/sizing policy; it is not device inventory.',
          );
        }
        final expected = RequirementPlanFacts.expectedCount(r);
        if (expected == null || expected < 0) {
          return _unknown(
            r.quantityRole == QuantityRole.increment
                ? 'The increment has no bound original base and expected total. Reinterpret it against its original plan; do not add it again.'
                : 'The requested device count is not a non-negative integer.',
          );
        }
        final actual = RequirementPlanFacts.countDevices(
          plan,
          r.scope,
          r.subject,
        );
        return _compareNumber(
          r,
          actual,
          expected,
          '${r.subject} count in ${_scopeLabel(r.scope)}',
        );
      case 'devicename':
      case 'devicepresence':
        final name = _stringValue(r);
        if (!_equalityComparator(r)) return _unknownComparator(r);
        final nodes = RequirementPlanFacts.nodesInScope(
          plan,
          r.scope,
          allowMissingDevice: true,
        );
        final kind = RequirementPlanFacts.kind(r.subject);
        if (kind == null) {
          return _unknown('Unknown device kind "${r.subject}".');
        }
        final matches = nodes
            .where(
              (node) =>
                  node.name.toLowerCase() == name.toLowerCase() &&
                  (kind.isEmpty || node.type.toLowerCase() == kind),
            )
            .length;
        final present = matches == 1;
        return _boolean(
          r.comparator == RequirementComparator.forbidden
              ? matches == 0
              : present,
          'Device "$name" ${r.comparator == RequirementComparator.forbidden ? 'must be absent' : 'must exist exactly once'} in ${_scopeLabel(r.scope)}; found $matches.',
        );
      case 'devicetype':
        if (!_equalityComparator(r)) return _unknownComparator(r);
        final kind = RequirementPlanFacts.kind(_stringValue(r));
        if (kind == null || kind.isEmpty) {
          return _unknown('The requested device type is not recognized.');
        }
        final actual = RequirementPlanFacts.countDevices(plan, r.scope, kind);
        return _boolean(
          r.comparator == RequirementComparator.forbidden
              ? actual == 0
              : actual > 0,
          '${r.comparator == RequirementComparator.forbidden ? 'Excluded' : 'Requested'} $kind inventory in ${_scopeLabel(r.scope)}: $actual.',
        );
      case 'model':
      case 'devicemodel':
      case 'routermodel':
      case 'switchmodel':
        return _model(r, plan, property);
      case 'routing':
      case 'routingprotocol':
        if (r.scope.kind != RequirementScopeKind.project) {
          return _unsupported(
            'The plan has only project-wide routing; a ${r.scope.kind.name}-scoped protocol cannot be proven by that field.',
          );
        }
        if (!_equalityComparator(r)) return _unknownComparator(r);
        final expected = _stringValue(r).toLowerCase();
        if (!const {
          'static',
          'ospf',
          'eigrp',
          'bgp',
          'rip',
          'none',
        }.contains(expected)) {
          return _unknown(
            'No checker exists for routing protocol "$expected".',
          );
        }
        final routerCount = plan.nodes
            .where((n) => n.type.toLowerCase() == 'router')
            .length;
        final actual = routerCount == 0 ? 'none' : plan.routing.toLowerCase();
        return _boolean(
          r.comparator == RequirementComparator.forbidden
              ? actual != expected
              : actual == expected,
          'Routing is $actual; ${r.comparator == RequirementComparator.forbidden ? 'excluded' : 'requested'} protocol is $expected.',
        );
      case 'subnet':
      case 'basesubnet':
      case 'address':
      case 'ipaddress':
      case 'ipcidr':
        return _subnet(r, plan, property);
      case 'servicerole':
      case 'service':
      case 'excludedservice':
      case 'serviceexclusion':
      case 'dnsexcluded':
        return _service(r, plan, property);
      case 'vlan':
      case 'vlans':
      case 'vlanid':
        if (r.scope.kind != RequirementScopeKind.project &&
            r.scope.kind != RequirementScopeKind.vlan) {
          return _unsupported(
            'A global VLAN list does not prove device or site VLAN membership.',
          );
        }
        if (!_equalityComparator(r)) return _unknownComparator(r);
        final expected = r.value is List ? r.value as List : [r.value];
        if (expected.isEmpty ||
            expected.any((v) => v is! int || v < 1 || v > 4094)) {
          return _unknown('VLAN IDs must be integers from 1 through 4094.');
        }
        final matches = r.comparator == RequirementComparator.forbidden
            ? expected.every((v) => !plan.vlans.contains(v))
            : expected.every(plan.vlans.contains);
        return _boolean(
          matches,
          'Requested VLAN IDs $expected; plan VLAN IDs ${plan.vlans}.',
        );
      case 'segmentation':
        if (r.scope.kind != RequirementScopeKind.project) {
          return _unsupported(
            'Scoped segmentation is not represented by the global VLAN list.',
          );
        }
        if (!_equalityComparator(r)) return _unknownComparator(r);
        final value = _stringValue(r).toLowerCase();
        if (!const {'flat', 'none', 'vlan', 'vlans'}.contains(value)) {
          return _unknown('Unknown segmentation requirement "$value".');
        }
        final flat = value == 'flat' || value == 'none';
        final subnets = plan.addressing
            .map((a) => NetworkTools.subnet(a.ipCidr))
            .whereType<SubnetInfo>()
            .map((s) => '${s.network}/${s.prefix}')
            .toSet();
        final matches = flat
            ? plan.vlans.isEmpty &&
                  !plan.security.interVlanRouting &&
                  subnets.length <= 1
            : plan.vlans.isNotEmpty;
        return _boolean(
          r.comparator == RequirementComparator.forbidden ? !matches : matches,
          'Segmentation requested $value; '
          '${HumanLanguage.count(plan.vlans.length, 'VLAN')} and '
          '${HumanLanguage.count(subnets.length, 'addressed subnet')} are modeled.',
        );
      case 'isolationpolicy':
      case 'reachabilitypolicy':
      case 'accesspolicy':
        return _unsupported(
          'Arbitrary source/destination isolation policy is not modeled or generated. An ACL flag or a timeout is not proof of this policy.',
        );
      default:
        return _unknown(
          'No checker exists for ${r.property} in ${_scopeLabel(r.scope)}. This requirement has not been satisfied or discarded.',
        );
    }
  }

  static (PlanningStatus, String) _connectivity(
    Requirement r,
    NetworkIntent plan,
  ) {
    final wanted = RequirementPlanFacts.kind(r.subject);
    final clients = RequirementPlanFacts.nodesInScope(
      plan,
      r.scope,
    ).where((n) => wanted == '' || n.type == wanted).toList();
    if (clients.isEmpty) {
      return _unknown('No requested clients exist to check connectivity.');
    }
    final reached = <String>{clients.first.name};
    final queue = <String>[clients.first.name];
    while (queue.isNotEmpty) {
      final node = queue.removeLast();
      for (final link in plan.links) {
        final next = link.a == node
            ? link.b
            : link.b == node
            ? link.a
            : null;
        if (next != null && reached.add(next)) queue.add(next);
      }
    }
    final addressable = clients.every(
      (client) => plan.addressing.any(
        (a) => a.node == client.name && NetworkTools.subnet(a.ipCidr) != null,
      ),
    );
    final routed =
        plan.nodes.where((n) => n.type == 'router').length <= 1 ||
        const {
          'ospf',
          'eigrp',
          'bgp',
          'static',
        }.contains(plan.routing.toLowerCase());
    return _boolean(
      clients.every((n) => reached.contains(n.name)) && addressable && routed,
      'Client connectivity is modeled by connected links, IPv4 assignments and routing; '
      'live communication remains unverified until an independent runtime check.',
    );
  }

  static (PlanningStatus, String) _model(
    Requirement r,
    NetworkIntent plan,
    String property,
  ) {
    if (!_equalityComparator(r)) return _unknownComparator(r);
    final expected = _stringValue(r);
    final kind = property == 'routermodel'
        ? 'router'
        : property == 'switchmodel'
        ? 'switch'
        : RequirementPlanFacts.kind(r.subject);
    if (kind == null) {
      return _unknown(
        'Unknown device kind "${r.subject}" for the model constraint.',
      );
    }
    final nodes = RequirementPlanFacts.nodesInScope(
      plan,
      r.scope,
      allowMissingDevice: true,
    ).where((n) => kind.isEmpty || n.type.toLowerCase() == kind).toList();
    final wanted =
        PacketTracerCatalog.instance.device(expected)?.model ?? expected;
    bool matches(NetNode node) {
      // An unspecified/default model is not proof of an exact requested model.
      final actual = node.model;
      if (actual == null || actual.trim().isEmpty) return false;
      final canonical =
          PacketTracerCatalog.instance.device(actual)?.model ?? actual;
      return canonical.toLowerCase() == wanted.toLowerCase();
    }

    final pass = r.comparator == RequirementComparator.forbidden
        ? nodes.every((n) => !matches(n))
        : nodes.isNotEmpty && nodes.every(matches);
    return _boolean(
      pass,
      'Model ${r.comparator == RequirementComparator.forbidden ? 'exclusion' : 'requirement'} "$expected" in ${_scopeLabel(r.scope)}; actual ${nodes.isEmpty ? 'no matching devices' : nodes.map((n) => '${n.name}=${n.model ?? 'unspecified'}').join(', ')}.',
    );
  }

  static (PlanningStatus, String) _subnet(
    Requirement r,
    NetworkIntent plan,
    String property,
  ) {
    if (!_equalityComparator(r)) return _unknownComparator(r);
    final raw = _stringValue(r);
    final wanted = NetworkTools.subnet(raw);
    if (wanted == null) {
      return _unknown(
        'The subnet/address "$raw" is not a supported IPv4 CIDR. IPv6 needs a dedicated checker.',
      );
    }
    final rows = RequirementPlanFacts.addressesInScope(plan, r.scope);
    if (rows.any((a) => NetworkTools.parseCidr(a.ipCidr) == null)) {
      return _unknown(
        'The scoped plan contains invalid or unreadable addressing.',
      );
    }
    final exactAddress = const {
      'address',
      'ipaddress',
      'ipcidr',
    }.contains(property);
    bool matches(InterfaceAddr a) {
      final parsed = NetworkTools.parseCidr(a.ipCidr)!;
      if (exactAddress) {
        final expected = NetworkTools.parseCidr(raw)!;
        return parsed.$1 == expected.$1 && parsed.$2 == expected.$2;
      }
      // base_subnet is an allocation block; subnet is one exact subnet.
      if (property == 'basesubnet') {
        return parsed.$2 >= wanted.prefix &&
            NetworkTools.contains(raw, a.ipCidr.split('/').first);
      }
      return NetworkTools.sameSubnet(raw, a.ipCidr);
    }

    final relevant = rows.where((a) {
      if (property != 'basesubnet' ||
          r.scope.kind == RequirementScopeKind.device ||
          r.scope.kind == RequirementScopeKind.linkInterface) {
        return true;
      }
      // A WAN /30 is not part of the requested LAN allocation block.
      final node = plan.nodes
          .where((n) => n.name.toLowerCase() == a.node.toLowerCase())
          .firstOrNull;
      return node?.type.toLowerCase() != 'router' ||
          !ptPortName(a.iface).startsWith('serial');
    }).toList();
    final pass = r.comparator == RequirementComparator.forbidden
        ? relevant.every((a) => !matches(a))
        : relevant.isNotEmpty &&
              (property == 'basesubnet'
                  ? relevant.every(matches)
                  : relevant.any(matches));
    return _boolean(
      pass,
      '${r.property} ${r.comparator == RequirementComparator.forbidden ? 'excludes' : 'requires'} $raw in ${_scopeLabel(r.scope)}; observed ${relevant.map((a) => '${a.node}:${a.iface}=${a.ipCidr}').join(', ')}.',
    );
  }

  static (PlanningStatus, String) _service(
    Requirement r,
    NetworkIntent plan,
    String property,
  ) {
    if (!_equalityComparator(r)) return _unknownComparator(r);
    final value = r.value;
    if (value is Map &&
        value.keys.any(
          (k) => !const {'enabled', 'exclusive', 'settings'}.contains(k),
        )) {
      return _unknown('The service requirement contains unchecked settings.');
    }
    if (value is Map &&
        (value['settings'] != null ||
            value['enabled'] is! bool ||
            (value.containsKey('exclusive') && value['exclusive'] is! bool))) {
      return _unknown(
        'Service rule/settings fidelity needs its own checker; only typed enabled/exclusive flags are supported here.',
      );
    }
    final service = RequirementPlanFacts.service(
      property == 'dnsexcluded'
          ? 'dns'
          : value is String
          ? value
          : r.subject,
    );
    if (!TargetCapabilityService.modeledServices.contains(service)) {
      return _unknown('No service-state checker exists for "$service".');
    }
    if (r.scope.kind == RequirementScopeKind.service &&
        RequirementPlanFacts.service(r.scope.scopeId) != service) {
      return _unknown('The named service and service scope disagree.');
    }
    final nodes = r.scope.kind == RequirementScopeKind.service
        ? plan.nodes
        : RequirementPlanFacts.nodesInScope(
            plan,
            r.scope,
            allowMissingDevice: true,
          );
    final enabled = value is Map
        ? value['enabled'] == true
        : value is bool
        ? value
        : true;
    final absent =
        r.comparator == RequirementComparator.forbidden ||
        const {
          'excludedservice',
          'serviceexclusion',
          'dnsexcluded',
        }.contains(property) ||
        !enabled;
    bool hasService(NetNode node) =>
        node.services.any((s) => RequirementPlanFacts.service(s) == service);
    final assigned = nodes.where(hasService).toList();
    final exclusive = value is Map && value['exclusive'] == true;
    final selectedNames = nodes.map((n) => n.name.toLowerCase()).toSet();
    final outside = plan.nodes
        .where(
          (n) => !selectedNames.contains(n.name.toLowerCase()) && hasService(n),
        )
        .toList();
    final pass = absent
        ? assigned.isEmpty
        : assigned.isNotEmpty && (!exclusive || outside.isEmpty);
    return _boolean(
      pass,
      '${absent ? 'Excluded' : 'Requested'} service $service in ${_scopeLabel(r.scope)}; enabled on ${assigned.isEmpty ? 'no scoped devices' : assigned.map((n) => n.name).join(', ')}.'
      '${exclusive && outside.isNotEmpty ? ' Exclusive assignment violated by ${outside.map((n) => n.name).join(', ')}.' : ''}',
    );
  }

  static (PlanningStatus, String) _preservation(
    Requirement r,
    NetworkIntent plan,
    NetworkIntent? base,
  ) {
    final bound = r.value;
    final property = RequirementPlanFacts.preserveProperty(r.property);
    Object? expected;
    List<String> removed = const [];
    if (bound is Map && bound['binding'] == 'preserve_v1') {
      if (bound['property'] != property ||
          !bound.containsKey('expected') ||
          bound['baseRevision'] is! String ||
          (bound['baseRevision'] as String).isEmpty) {
        return _unknown(
          'The preservation snapshot is incomplete or does not match the requested property.',
        );
      }
      expected = bound['expected'];
      final ids = bound['removedDeviceIds'];
      if (ids is! List || ids.any((id) => id is! String)) {
        return _unknown('Invalid preservation removal binding.');
      }
      removed = ids.cast<String>();
    } else {
      if (base == null) {
        return _unknown(
          'Preservation needs the original plan snapshot, not the reopened candidate as its own baseline.',
        );
      }
      if (r.value != true) {
        return _unknown(
          'Unsupported preservation value; an original bound snapshot is required.',
        );
      }
      expected = RequirementPlanFacts.preservationSnapshot(
        base,
        r.scope,
        property,
        subject: r.subject,
      );
    }
    var actual = RequirementPlanFacts.preservationSnapshot(
      plan,
      r.scope,
      property,
      subject: r.subject,
      removedDeviceIds: removed,
    );
    if (property == 'addressing' && expected is List && actual is List) {
      // New devices may get addresses. Existing survivors may not lose,
      // change, or gain an address through an unrelated edit.
      final names = {
        for (final row in expected)
          if (row is Map) '${row['node']}'.toLowerCase(),
      };
      actual = actual
          .where(
            (row) =>
                row is Map && names.contains('${row['node']}'.toLowerCase()),
          )
          .toList();
    }
    return _boolean(
      RequirementPlanFacts.equalFacts(expected, actual),
      'Preserve $property in ${_scopeLabel(r.scope)} against the original bound snapshot${removed.isEmpty ? '' : ', excluding explicitly removed ${removed.join(', ')}'}.',
    );
  }

  static String _stringValue(Requirement r) {
    final value = r.value;
    if (value is! String || value.trim().isEmpty) {
      throw const _Uncheckable(
        PlanningStatus.unresolved,
        'A non-empty typed string value is required.',
      );
    }
    return value.trim();
  }

  static bool _equalityComparator(Requirement r) =>
      r.comparator == RequirementComparator.equals ||
      r.comparator == RequirementComparator.forbidden;
  static (PlanningStatus, String) _unknownComparator(Requirement r) => _unknown(
    'Comparator ${r.comparator.name} is not supported for ${r.property}.',
  );
  static (PlanningStatus, String) _unknown(String message) =>
      (PlanningStatus.unresolved, message);
  static (PlanningStatus, String) _unsupported(String message) =>
      (PlanningStatus.unsupported, message);
  static (PlanningStatus, String) _boolean(bool pass, String message) =>
      (pass ? PlanningStatus.satisfied : PlanningStatus.violated, message);
  static String _scopeLabel(RequirementScope scope) =>
      scope.kind == RequirementScopeKind.project
      ? 'the project'
      : '${scope.kind.name} "${scope.scopeId}"';
  static (PlanningStatus, String) _compareNumber(
    Requirement r,
    int actual,
    int expected,
    String label,
  ) {
    final pass = switch (r.comparator) {
      RequirementComparator.equals => actual == expected,
      RequirementComparator.atLeast => actual >= expected,
      RequirementComparator.atMost => actual <= expected,
      RequirementComparator.forbidden => actual != expected,
      RequirementComparator.preserve => false,
    };
    return _boolean(
      pass,
      '$label is $actual; required ${r.comparator.name} $expected.',
    );
  }
}

/// Shared facts for checking and binding. These read structured plan fields
/// only and reject ambiguous scopes rather than using naming heuristics.
class RequirementPlanFacts {
  const RequirementPlanFacts._();

  static String propertyKey(String value, {String subject = ''}) =>
      TargetCapabilityService.canonicalProperty(value, subject: subject);

  static String? kind(String raw) {
    final text = raw.trim().toLowerCase();
    if (const {
      'device',
      'devices',
      'node',
      'nodes',
      'network',
      'inventory',
      'all',
    }.contains(text)) {
      return '';
    }
    final direct = deviceKindOf(text) ?? deviceKindFor(text);
    if (direct != null) return direct.type;
    final singular = text.endsWith('es') && text.contains('switch')
        ? text.substring(0, text.length - 2)
        : text.endsWith('s')
        ? text.substring(0, text.length - 1)
        : text;
    return (deviceKindOf(singular) ?? deviceKindFor(singular))?.type;
  }

  static String service(String raw) => switch (raw.trim().toLowerCase()) {
    'web' || 'https' => 'http',
    'tacacs' || 'tacacs+' || 'radius' => 'aaa',
    final value => value,
  };

  static int? expectedCount(Requirement r) {
    if (r.quantityRole != QuantityRole.increment) {
      return r.value is int ? r.value as int : null;
    }
    final value = r.value;
    if (value is! Map || value['binding'] != 'device_count_delta_v1') {
      return null;
    }
    final delta = value['delta'],
        base = value['baseCount'],
        expected = value['expectedTotal'];
    if (delta is! int ||
        base is! int ||
        expected is! int ||
        delta < 0 ||
        base < 0 ||
        expected != base + delta ||
        value['baseRevision'] is! String ||
        (value['baseRevision'] as String).isEmpty) {
      return null;
    }
    return expected;
  }

  static RequirementScope canonicalScope(
    NetworkIntent plan,
    RequirementScope scope,
  ) {
    if (scope.kind != RequirementScopeKind.site) return scope;
    final sites = plan.nodes
        .map((n) => n.siteId?.trim())
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();
    final exact = sites
        .where((s) => s.toLowerCase() == scope.scopeId.trim().toLowerCase())
        .toList();
    final matches = exact.isNotEmpty
        ? exact
        : sites
              .where((s) => canonicalSite(s) == canonicalSite(scope.scopeId))
              .toList();
    if (matches.length != 1) {
      throw FormatException(
        matches.isEmpty
            ? 'The plan does not identify site "${scope.scopeId}"; site ownership must be explicit.'
            : 'Site "${scope.scopeId}" is ambiguous; name one exact site.',
      );
    }
    return RequirementScope(
      kind: scope.kind,
      scopeId: matches.single,
      parent: scope.parent,
      siteId: scope.siteId.isEmpty ? '' : matches.single,
      deviceId: scope.deviceId,
      networkRole: scope.networkRole,
    );
  }

  static String canonicalSite(String value) {
    var text = value
        .toLowerCase()
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(RegExp(r'^the\s+'), '');
    if (const {'hq', 'headquarters', 'headquarter'}.contains(text)) return 'hq';
    const ordinals = {
      'first': '1',
      '1st': '1',
      'one': '1',
      'second': '2',
      '2nd': '2',
      'two': '2',
      'third': '3',
      '3rd': '3',
      'fourth': '4',
      '4th': '4',
      'fifth': '5',
      '5th': '5',
    };
    final match = RegExp(
      r'^(?:(first|1st|one|second|2nd|two|third|3rd|fourth|4th|fifth|5th)\s+)?(branch|office|site|building)(?:\s*#?\s*(\d+))?$',
    ).firstMatch(text);
    if (match == null) return text;
    final number = match[3] ?? ordinals[match[1]];
    return '${match[2]}${number == null ? '' : '#$number'}';
  }

  static List<NetNode> nodesInScope(
    NetworkIntent plan,
    RequirementScope scope, {
    bool allowMissingDevice = false,
  }) {
    switch (scope.kind) {
      case RequirementScopeKind.project:
        return plan.nodes;
      case RequirementScopeKind.site:
        final bound = canonicalScope(plan, scope);
        return plan.nodes
            .where(
              (n) =>
                  n.siteId?.trim().toLowerCase() == bound.scopeId.toLowerCase(),
            )
            .toList();
      case RequirementScopeKind.device:
        final matches = plan.nodes
            .where(
              (n) => n.name.toLowerCase() == scope.scopeId.trim().toLowerCase(),
            )
            .toList();
        if (matches.length > 1 || (matches.isEmpty && !allowMissingDevice)) {
          throw FormatException(
            'Device "${scope.scopeId}" must identify exactly one device; found ${matches.length}.',
          );
        }
        return matches;
      case RequirementScopeKind.linkInterface:
        final endpoint = interfaceEndpoint(plan, scope.scopeId);
        return [endpoint.$1];
      default:
        throw FormatException(
          'Inventory cannot be established for ${scope.kind.name} scope "${scope.scopeId}".',
        );
    }
  }

  static int countDevices(
    NetworkIntent plan,
    RequirementScope scope,
    String subject,
  ) {
    final wanted = kind(subject);
    if (wanted == null) {
      throw FormatException('Unknown inventory kind "$subject".');
    }
    return nodesInScope(
      plan,
      scope,
      allowMissingDevice: true,
    ).where((n) => wanted.isEmpty || n.type.toLowerCase() == wanted).length;
  }

  static (NetNode, String) interfaceEndpoint(
    NetworkIntent plan,
    String scopeId,
  ) {
    final candidates = <(NetNode, String)>[];
    for (final node in plan.nodes) {
      for (final separator in [':', '|', ' ', '/']) {
        final prefix = '${node.name}$separator';
        if (scopeId.toLowerCase().startsWith(prefix.toLowerCase())) {
          final iface = scopeId.substring(prefix.length).trim();
          if (iface.isNotEmpty) candidates.add((node, iface));
        }
      }
    }
    if (candidates.length != 1) {
      throw FormatException(
        'Interface scope "$scopeId" must name one device and interface, for example R1:g0/0.',
      );
    }
    return candidates.single;
  }

  static List<InterfaceAddr> addressesInScope(
    NetworkIntent plan,
    RequirementScope scope,
  ) {
    if (scope.kind == RequirementScopeKind.linkInterface) {
      final (node, iface) = interfaceEndpoint(plan, scope.scopeId);
      return plan.addressing
          .where(
            (a) =>
                a.node.toLowerCase() == node.name.toLowerCase() &&
                ptPortName(a.iface) == ptPortName(iface),
          )
          .toList();
    }
    if (scope.kind == RequirementScopeKind.vlan) {
      final vlan = int.tryParse(
        scope.scopeId.replaceFirst(
          RegExp(r'^vlan\s*', caseSensitive: false),
          '',
        ),
      );
      if (vlan == null || !plan.vlans.contains(vlan)) {
        throw FormatException(
          'VLAN "${scope.scopeId}" is not identified in the plan.',
        );
      }
      final scopedNames = scope.siteId.isEmpty
          ? null
          : nodesInScope(
              plan,
              RequirementScope(
                kind: RequirementScopeKind.site,
                scopeId: scope.siteId,
              ),
            ).map((n) => n.name.toLowerCase()).toSet();
      final rows = plan.addressing
          .where(
            (a) =>
                (scopedNames == null ||
                    scopedNames.contains(a.node.toLowerCase())) &&
                (a.iface.toLowerCase() == 'vlan$vlan' ||
                    a.iface.endsWith('.$vlan')),
          )
          .toList();
      if (rows.isEmpty) {
        throw FormatException(
          'No explicit interface/subinterface addressing identifies VLAN $vlan.',
        );
      }
      return rows;
    }
    final names = nodesInScope(
      plan,
      scope,
      allowMissingDevice: true,
    ).map((n) => n.name.toLowerCase()).toSet();
    return plan.addressing
        .where((a) => names.contains(a.node.toLowerCase()))
        .toList();
  }

  static String preserveProperty(String raw) => switch (propertyKey(raw)) {
    'devicecount' || 'devicecounts' || 'inventory' => 'device_counts',
    'addressing' || 'addresses' => 'addressing',
    'semanticstate' || 'entiresemantic' => 'semantic_state',
    'device' || 'devices' || 'node' || 'nodes' => 'devices',
    'model' || 'models' || 'devicemodel' || 'devicemodels' => 'models',
    'service' || 'services' || 'serviceroles' => 'services',
    'link' || 'links' || 'topology' => 'links',
    'routing' || 'routingprotocol' => 'routing',
    'vlan' || 'vlans' => 'vlans',
    'layout' => 'layout',
    'security' => 'security',
    _ => throw FormatException(
      'The preservation property "$raw" has no checker.',
    ),
  };

  static Object? preservationSnapshot(
    NetworkIntent plan,
    RequirementScope scope,
    String property, {
    String subject = 'network',
    Iterable<String> removedDeviceIds = const [],
  }) {
    final key = preserveProperty(property);
    final removed = removedDeviceIds.map((n) => n.toLowerCase()).toSet();
    final nodes = nodesInScope(
      plan,
      scope,
    ).where((n) => !removed.contains(n.name.toLowerCase())).toList();
    final names = nodes.map((n) => n.name.toLowerCase()).toSet();
    final addresses = [
      for (final row in plan.addressing)
        if (names.contains(row.node.toLowerCase())) row.toJson(),
    ];
    final links = [
      for (final link in plan.links)
        if ((names.contains(link.a.toLowerCase()) ||
                names.contains(link.b.toLowerCase())) &&
            !removed.contains(link.a.toLowerCase()) &&
            !removed.contains(link.b.toLowerCase()))
          link.toJson(),
    ];
    final layout = {
      'positions': {
        for (final entry in plan.layout.entries)
          if (names.contains(entry.key.toLowerCase()))
            entry.key: entry.value == null
                ? null
                : {'x': entry.value!.dx, 'y': entry.value!.dy},
      },
      'notes': [
        for (final note in plan.notes)
          if (note.trim().toLowerCase().startsWith('layout:')) note,
      ],
    };
    switch (key) {
      case 'device_counts':
        final wanted = kind(subject);
        if (wanted == null) {
          throw FormatException('Unknown preserved inventory kind "$subject".');
        }
        final counts = <String, int>{if (wanted.isNotEmpty) wanted: 0};
        for (final node in nodes) {
          final type = node.type.toLowerCase();
          if (wanted.isEmpty || wanted == type) {
            counts[type] = (counts[type] ?? 0) + 1;
          }
        }
        return counts;
      case 'addressing':
        return addresses;
      case 'devices':
        return [for (final node in nodes) node.toJson(includeSecrets: false)];
      case 'models':
        return [
          for (final node in nodes)
            {
              'name': node.name,
              'model': node.model,
              'modules': node.modules,
              if (node.variantKey != null) 'variantKey': node.variantKey,
            },
        ];
      case 'services':
        return [
          for (final node in nodes)
            {
              'name': node.name,
              'services': node.services,
              'rules':
                  node.toJson(includeSecrets: false)['serviceRules'] ??
                  const {},
            },
        ];
      case 'links':
        return links;
      case 'layout':
        return layout;
      case 'routing':
      case 'vlans':
      case 'security':
        if (scope.kind != RequirementScopeKind.project) {
          throw FormatException(
            'The plan cannot verify $key preservation within ${scope.kind.name} scope.',
          );
        }
        return key == 'routing'
            ? plan.routing
            : key == 'vlans'
            ? plan.vlans
            : plan.security.toJson(includeSecrets: false);
      case 'semantic_state':
        return {
          'devices': [
            for (final node in nodes) node.toJson(includeSecrets: false),
          ],
          'links': links,
          'addressing': addresses,
          'layout': layout,
          if (scope.kind == RequirementScopeKind.project) ...{
            'routing': plan.routing,
            'vlans': plan.vlans,
            'security': plan.security.toJson(includeSecrets: false),
          },
        };
      default:
        throw FormatException('No preservation checker for $key.');
    }
  }

  static bool equalFacts(Object? a, Object? b) =>
      jsonValueEquals(_ordered(a), _ordered(b));
  static Object? _ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return {for (final key in keys) key: _ordered(value[key])};
    }
    if (value is List) {
      return value.map(_ordered).toList()
        ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    }
    return value;
  }
}

class _Uncheckable implements Exception {
  final PlanningStatus status;
  final String message;
  const _Uncheckable(this.status, this.message);
}
