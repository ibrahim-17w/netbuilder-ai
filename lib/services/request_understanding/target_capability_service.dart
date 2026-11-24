import '../../models/network_intent.dart';
import '../../models/request_requirement.dart';
import '../packet_tracer/catalog.dart';
import '../packet_tracer/model_compatibility.dart';
import '../validator_service.dart';

/// Support describes implemented code, never whether a particular artifact
/// or a live network has passed a check.
enum TargetSupportStatus { supported, unsupported, unknown, notApplicable }

enum TargetCapabilityPhase { model, generate, readBack, liveCheck }

class TargetPhaseSupport {
  final TargetSupportStatus status;
  final String reason;
  final List<String> alternatives;

  const TargetPhaseSupport(
    this.status,
    this.reason, {
    this.alternatives = const [],
  });

  bool get isSupported =>
      status == TargetSupportStatus.supported ||
      status == TargetSupportStatus.notApplicable;
}

class TargetFeatureCapability {
  final String feature;
  final TargetPhaseSupport model;
  final TargetPhaseSupport generate;
  final TargetPhaseSupport readBack;
  final TargetPhaseSupport liveCheck;

  const TargetFeatureCapability({
    required this.feature,
    required this.model,
    required this.generate,
    required this.readBack,
    required this.liveCheck,
  });

  TargetPhaseSupport forPhase(TargetCapabilityPhase phase) => switch (phase) {
    TargetCapabilityPhase.model => model,
    TargetCapabilityPhase.generate => generate,
    TargetCapabilityPhase.readBack => readBack,
    TargetCapabilityPhase.liveCheck => liveCheck,
  };
}

/// Conservative inventory of the existing adapters/templates/auditors.
/// Packet Tracer phases are grounded in catalog.dart, PacketTracerAdapter,
/// pkt_engine_builder and OnDevicePktBuilder's saved-file auditor. The GNS3
/// adapter exports topology + IOS config, not server panels. TerraformAdapter
/// is an example VPC renderer, not a faithful network compiler.
class TargetCapabilityService {
  const TargetCapabilityService._();

  static const modeledServices = {
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
  };
  static const _readableServices = {
    'dhcp',
    'dns',
    'http',
    'aaa',
    'email',
    'ftp',
    'ntp',
    'tftp',
    'syslog',
  };
  static const _routing = {'static', 'ospf', 'eigrp', 'bgp', 'none'};
  static const _notLive = TargetPhaseSupport(
    TargetSupportStatus.unknown,
    'No requirement-specific live observation has been collected. A saved file or a timed-out probe does not verify live behavior.',
  );
  static const _notRead = TargetPhaseSupport(
    TargetSupportStatus.unknown,
    'The shared saved-file auditor cannot currently prove this property. Delivery stays unverified without an independent observation.',
  );

  static String canonicalTarget(String target) {
    final value = target.trim().toLowerCase();
    if (ValidatorService.isPacketTracerTarget(value)) return 'packet-tracer';
    if (const {'ios', 'cisco-ios', 'cisco'}.contains(value)) return 'cisco';
    return value;
  }

  /// Older saved requests used routing/protocol. Only that qualified pair
  /// aliases routing_protocol; "protocol" on an arbitrary subject is unknown.
  static String canonicalProperty(String property, {String subject = ''}) {
    final key = _key(property);
    return key == 'protocol' && subject.trim().toLowerCase() == 'routing'
        ? 'routingprotocol'
        : key;
  }

  static TargetFeatureCapability forRequirement(
    Requirement requirement, {
    required String target,
    NetworkIntent? plan,
  }) {
    final property = canonicalProperty(
      requirement.property,
      subject: requirement.subject,
    );
    final t = canonicalTarget(target);
    if (property == 'ospfarea') {
      return requirement.value == 0
          ? _structural('OSPF area 0', t, readable: false)
          : _unsupported(
              'OSPF area ${requirement.value}',
              'The current routing generator implements area 0 only.',
            );
    }
    if (property == 'unsupportedserviceconfiguration') {
      return _unsupported(
        'advanced server configuration',
        requirement.value is Map
            ? '${(requirement.value as Map)['reason']}'
            : 'This advanced server configuration has no faithful generator.',
      );
    }
    if (const {
      'isolationpolicy',
      'reachabilitypolicy',
      'accesspolicy',
    }.contains(property)) {
      const noPolicy = TargetPhaseSupport(
        TargetSupportStatus.unsupported,
        'Arbitrary guest/staff or source/destination isolation has no typed policy model and faithful generator. A generic ACL flag is insufficient.',
        alternatives: [
          'Specify a supported concrete ACL with exact source, destination, protocol and direction, or review the policy without building it',
        ],
      );
      return const TargetFeatureCapability(
        feature: 'isolation policy',
        model: noPolicy,
        generate: noPolicy,
        readBack: _notRead,
        liveCheck: _notLive,
      );
    }
    if (requirement.comparator == RequirementComparator.preserve) {
      const preserved = {
        'devicecount',
        'devicecounts',
        'inventory',
        'addressing',
        'addresses',
        'semanticstate',
        'entiresemantic',
        'device',
        'devices',
        'node',
        'nodes',
        'model',
        'models',
        'devicemodel',
        'devicemodels',
        'service',
        'services',
        'serviceroles',
        'link',
        'links',
        'topology',
        'routing',
        'routingprotocol',
        'vlan',
        'vlans',
        'layout',
        'security',
      };
      if (!preserved.contains(property)) return _unknown(requirement.property);
      final readable = const {
        'devicecount',
        'devicecounts',
        'inventory',
        'addressing',
        'addresses',
        'model',
        'models',
        'devicemodel',
        'devicemodels',
        'link',
        'links',
        'topology',
        'layout',
      }.contains(property);
      return _structural(
        'preserve ${requirement.property}',
        t,
        readable: readable,
      );
    }
    if (const {
      'model',
      'devicemodel',
      'routermodel',
      'switchmodel',
    }.contains(property)) {
      if (requirement.comparator == RequirementComparator.forbidden) {
        return _structural('model exclusion', t);
      }
      final model = requirement.value;
      if (model is! String || model.trim().isEmpty) return _unknown('model');
      final kind = property == 'routermodel'
          ? 'router'
          : property == 'switchmodel'
          ? 'switch'
          : requirement.subject;
      return deviceModel(target: t, type: kind, model: model, exact: true);
    }
    if (property == 'routing' || property == 'routingprotocol') {
      if (requirement.scope.kind != RequirementScopeKind.project) {
        return _unsupported(
          'scoped routing',
          'The plan/IOS adapter has one project-wide routing protocol, not an independently scoped protocol.',
        );
      }
      if (requirement.comparator == RequirementComparator.forbidden) {
        return _structural('routing exclusion', t, readable: false);
      }
      return routingProtocol('${requirement.value}', target: t);
    }
    if (const {
      'service',
      'servicerole',
      'excludedservice',
      'serviceexclusion',
      'dnsexcluded',
    }.contains(property)) {
      final value = requirement.value;
      final service = _service(
        property == 'dnsexcluded'
            ? 'dns'
            : value is String
            ? value
            : requirement.subject,
      );
      final excluded =
          requirement.comparator == RequirementComparator.forbidden ||
          property.contains('exclusion') ||
          property == 'excludedservice' ||
          property == 'dnsexcluded' ||
          value == false ||
          (value is Map && value['enabled'] == false);
      if (excluded) {
        return modeledServices.contains(service)
            ? _structural(
                '$service exclusion',
                t,
                readable: _readableServices.contains(service),
              )
            : _unknown(service);
      }
      final selected =
          plan?.nodes
              .where(
                (node) =>
                    node.services.any((s) => _service(s) == service) &&
                    (requirement.scope.kind != RequirementScopeKind.device ||
                        node.name.toLowerCase() ==
                            requirement.scope.scopeId.toLowerCase()),
              )
              .toList() ??
          const <NetNode>[];
      return serviceRole(
        service,
        target: t,
        onRouter:
            selected.isNotEmpty &&
            selected.every(
              (node) =>
                  node.type.toLowerCase() == 'router' &&
                  node.serviceRules[service] is Map &&
                  (node.serviceRules[service] as Map).isNotEmpty,
            ),
        onServer:
            selected.isEmpty ||
            selected.every((node) => node.type.toLowerCase() == 'server'),
      );
    }
    if (const {
      'devicecount',
      'allocationsites',
      'roledevicecount',
      'gateway',
      'connectivity',
      'projectname',
      'addressingmode',
      'link',
      'devicename',
      'devicepresence',
      'devicetype',
      'scale',
      'subnet',
      'basesubnet',
      'address',
      'ipaddress',
      'ipcidr',
      'segmentation',
      'vlan',
      'vlans',
      'vlanid',
      'layout',
    }.contains(property)) {
      return _structural(
        requirement.property,
        t,
        readable: !const {
          'segmentation',
          'vlan',
          'vlans',
          'vlanid',
        }.contains(property),
      );
    }
    return _unknown(requirement.property);
  }

  static TargetFeatureCapability deviceModel({
    required String target,
    required String type,
    required String? model,
    bool exact = false,
  }) {
    final t = canonicalTarget(target);
    final kind = type.toLowerCase();
    final catalog = PacketTracerCatalog.instance;
    final effective = model?.trim().isNotEmpty == true
        ? model!.trim()
        : deviceKindOf(kind)?.models.firstOrNull ?? '';
    const represented = TargetPhaseSupport(
      TargetSupportStatus.supported,
      'The intent model retains the device kind and exact model independently of template availability.',
    );
    if (t == 'packet-tracer') {
      final device = catalog.device(effective);
      final supported = device?.placeable == true && device?.type == kind;
      final alternatives = supported
          ? const <String>[]
          : PacketTracerModelCompatibility.compatibleModels(
              UnsupportedPacketTracerModel(
                type: kind,
                model: effective,
                deviceNames: const [],
              ),
            );
      return TargetFeatureCapability(
        feature:
            '$kind model ${effective.isEmpty ? '(unspecified)' : effective}',
        model: represented,
        generate: TargetPhaseSupport(
          supported
              ? TargetSupportStatus.supported
              : TargetSupportStatus.unsupported,
          supported
              ? 'Packet Tracer catalog ${catalog.version} has a buildable $kind template for ${device!.model}.'
              : 'No buildable $kind template exists for ${effective.isEmpty ? 'the unspecified model' : effective}. Recognition alone does not make it buildable; no substitution has been made.',
          alternatives: alternatives,
        ),
        readBack: const TargetPhaseSupport(
          TargetSupportStatus.supported,
          'The saved-file audit can observe the written device kind and model; missing fields still leave delivery unverified.',
        ),
        liveCheck: _notLive,
      );
    }
    if (t == 'gns3') {
      final m = effective.toLowerCase();
      final remapped = const {
        '4331',
        '4321',
        '2911',
        '2901',
        '1941',
        '829',
        '1240',
        '2960',
        '2950',
        '3560',
        'pc-pt',
      }.contains(m);
      final supportedKind = const {'router', 'switch', 'pc'}.contains(kind);
      return TargetFeatureCapability(
        feature: '$kind model $effective',
        model: represented,
        generate: TargetPhaseSupport(
          !supportedKind || (exact && remapped)
              ? TargetSupportStatus.unsupported
              : TargetSupportStatus.supported,
          !supportedKind
              ? 'Gns3Adapter has no faithful $kind template mapping; its generic fallback is not evidence of support.'
              : exact && remapped
              ? 'Gns3Adapter remaps $effective to a different template, so it cannot honor this exact model.'
              : 'Gns3Adapter can export this template reference. Installed GNS3 image availability must still be checked by the target.',
          alternatives: !supportedKind || (exact && remapped)
              ? [
                  kind == 'switch'
                      ? 'Ethernet switch'
                      : kind == 'pc'
                      ? 'VPCS'
                      : 'c3725',
                  'Use Packet Tracer with an available compatible model',
                ]
              : const [],
        ),
        readBack: _notRead,
        liveCheck: _notLive,
      );
    }
    if (t == 'cisco') {
      return TargetFeatureCapability(
        feature: '$kind model $effective',
        model: represented,
        generate: TargetPhaseSupport(
          exact
              ? TargetSupportStatus.unsupported
              : TargetSupportStatus.notApplicable,
          exact
              ? 'IOS text does not deliver or verify an exact hardware model.'
              : 'Configuration export does not provision hardware.',
        ),
        readBack: _notRead,
        liveCheck: _notLive,
      );
    }
    return _unsupported(
      'device model',
      'Target "$target" has no faithful device-model compiler.',
    );
  }

  static TargetFeatureCapability routingProtocol(
    String protocol, {
    required String target,
  }) {
    final p = protocol.toLowerCase();
    final t = canonicalTarget(target);
    if (!_routing.contains(p)) {
      return _unsupported(
        '$p routing',
        'CiscoAdapter has no renderer for routing protocol "$p".',
        alternatives: _routing.toList(),
      );
    }
    return _structural('$p routing', t, readable: false);
  }

  static TargetFeatureCapability serviceRole(
    String service, {
    required String target,
    bool onServer = true,
    bool onRouter = false,
  }) {
    final s = _service(service);
    if (!modeledServices.contains(s)) return _unknown('$s service');
    final t = canonicalTarget(target);
    if (onRouter && s == 'dhcp') {
      return _structural('$s router service', t, readable: false);
    }
    if (t != 'packet-tracer' || !onServer) {
      return TargetFeatureCapability(
        feature: '$s service',
        model: const TargetPhaseSupport(
          TargetSupportStatus.supported,
          'The intent retains the requested service role.',
        ),
        generate: TargetPhaseSupport(
          TargetSupportStatus.unsupported,
          !onServer
              ? 'This service role is not compiled on a non-server node merely because it appears in services.'
              : 'The $t adapter does not generate server Services-tab state.',
          alternatives: const [
            'Use a supported Packet Tracer server service',
            'Export a plan for manual service configuration without claiming delivery',
          ],
        ),
        readBack: _notRead,
        liveCheck: _notLive,
      );
    }
    return _structural(
      '$s service',
      t,
      readable: _readableServices.contains(s),
    );
  }

  static List<TargetFeatureCapability> forPlan(
    NetworkIntent plan, {
    required String target,
  }) => [
    _structural('network artifact', canonicalTarget(target)),
    for (final node in plan.nodes)
      deviceModel(
        target: target,
        type: node.type,
        model: node.model,
        exact: node.exactModel,
      ),
    if (plan.nodes.any((node) => node.type.toLowerCase() == 'router'))
      routingProtocol(plan.routing, target: target),
    for (final node in plan.nodes)
      for (final service in node.services)
        serviceRole(
          service,
          target: target,
          onServer: node.type.toLowerCase() == 'server',
          onRouter:
              node.type.toLowerCase() == 'router' &&
              node.serviceRules[service] is Map &&
              (node.serviceRules[service] as Map).isNotEmpty,
        ),
  ];

  static TargetFeatureCapability _structural(
    String feature,
    String target, {
    bool readable = true,
  }) {
    final supported = const {'packet-tracer', 'gns3', 'cisco'}.contains(target);
    return TargetFeatureCapability(
      feature: feature,
      model: const TargetPhaseSupport(
        TargetSupportStatus.supported,
        'Structured intent fields can represent this property.',
      ),
      generate: TargetPhaseSupport(
        supported
            ? TargetSupportStatus.supported
            : TargetSupportStatus.unsupported,
        supported
            ? 'Implemented $target adapter can generate this property; this is not proof of the saved result.'
            : 'Target "$target" has no faithful compiler for $feature. The example Terraform VPC renderer does not reproduce a network contract.',
        alternatives: supported
            ? const []
            : const [
                'Use a supported Packet Tracer target',
                'Review/export the abstract plan without claiming a matching deployed network',
              ],
      ),
      readBack: target == 'packet-tracer' && readable
          ? const TargetPhaseSupport(
              TargetSupportStatus.supported,
              'A saved-file checker can observe this property when the audit contains the required fields.',
            )
          : _notRead,
      liveCheck: _notLive,
    );
  }

  static TargetFeatureCapability _unknown(String feature) {
    final unsupported = TargetPhaseSupport(
      TargetSupportStatus.unknown,
      'No implemented capability/checker is registered for "$feature". The hard requirement stays unresolved.',
    );
    return TargetFeatureCapability(
      feature: feature,
      model: unsupported,
      generate: unsupported,
      readBack: _notRead,
      liveCheck: _notLive,
    );
  }

  static TargetFeatureCapability _unsupported(
    String feature,
    String reason, {
    List<String> alternatives = const [],
  }) {
    final unsupported = TargetPhaseSupport(
      TargetSupportStatus.unsupported,
      reason,
      alternatives: alternatives,
    );
    return TargetFeatureCapability(
      feature: feature,
      model: unsupported,
      generate: unsupported,
      readBack: _notRead,
      liveCheck: _notLive,
    );
  }

  static String _key(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  static String _service(String value) => switch (value.toLowerCase()) {
    'web' || 'https' => 'http',
    'tacacs' || 'tacacs+' || 'radius' => 'aaa',
    final service => service,
  };
}
