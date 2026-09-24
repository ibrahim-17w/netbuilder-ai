import '../models/network_intent.dart';

/// Applies the durable corrections the user has taught the app to a plan the
/// local planner just produced.
///
/// This is what makes the offline path *evolve*: the local planner has no
/// model to learn from, so a lesson the user accepted (a saved rule or
/// preference) changes the next plan deterministically. Everything here is
/// pure and scoped - a rule only touches the plan when its wording matches,
/// and no credential or value the user did not supply is ever invented.
class PlannerMemoryService {
  const PlannerMemoryService._();

  static const List<String> routingKeys = ['routing', 'routing_protocol'];
  static const List<String> routerModelKeys = ['router_model', 'router'];
  static const List<String> switchModelKeys = ['switch_model', 'switch'];
  static const List<String> baseSubnetKeys = [
    'base_subnet',
    'subnet',
    'base_cidr',
  ];

  /// Return a copy of [intent] with the learned corrections applied.
  static NetworkIntent apply(
    NetworkIntent intent, {
    List<String> rules = const [],
    Map<String, String> preferences = const {},
  }) {
    if (rules.isEmpty && preferences.isEmpty) return intent;

    final wanted = <String, String>{};

    // Explicit key/value preferences win over free-text rules.
    preferences.forEach((k, v) {
      final key = k.trim().toLowerCase();
      final value = v.trim();
      if (value.isEmpty) return;
      if (routingKeys.contains(key)) wanted['routing'] = value.toLowerCase();
      if (routerModelKeys.contains(key)) wanted['router_model'] = value;
      if (switchModelKeys.contains(key)) wanted['switch_model'] = value;
      if (baseSubnetKeys.contains(key)) wanted['base_subnet'] = value;
    });

    // Free-text rules read the same levers out of sentence wording, e.g.
    // "always use OSPF", "use a 4331 router", "LANs in 10.20.0.0/24",
    // "always add a DNS server".
    for (final raw in rules) {
      final r = raw.toLowerCase();
      final protocol = _protocolIn(r);
      if (protocol != null && !wanted.containsKey('routing')) {
        wanted['routing'] = protocol;
      }
      final cidr =
          RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b').firstMatch(r);
      if (cidr != null &&
          (r.contains('subnet') ||
              r.contains('network') ||
              r.contains('base') ||
              r.contains('lan'))) {
        wanted.putIfAbsent('base_subnet', () => cidr.group(1)!);
      }
      final model = RegExp(r'\b(\d{4})\b').firstMatch(r);
      if (model != null) {
        final m = model.group(1)!;
        if (NetworkIntent.ptRouters.contains(m) && r.contains('router')) {
          wanted.putIfAbsent('router_model', () => m);
        }
        if (NetworkIntent.ptSwitches.contains(m) && r.contains('switch')) {
          wanted.putIfAbsent('switch_model', () => m);
        }
      }
      if (RegExp(r'\bdns\b').hasMatch(r)) wanted['add_dns'] = 'true';
    }

    var out = intent;

    // 1. Routing protocol.
    final routing = wanted['routing'];
    if (routing != null && _isKnownProtocol(routing)) {
      out = out.copyWith(routing: routing);
    }

    // 2. Preferred router / switch models.
    final routerModel = wanted['router_model'];
    final switchModel = wanted['switch_model'];
    if ((routerModel ?? '').isNotEmpty || (switchModel ?? '').isNotEmpty) {
      out = out.copyWith(
        nodes: out.nodes.map((n) {
          if (n.type == 'router' && (routerModel ?? '').isNotEmpty) {
            return _withModel(n, routerModel!);
          }
          if (n.type == 'switch' && (switchModel ?? '').isNotEmpty) {
            return _withModel(n, switchModel!);
          }
          return n;
        }).toList(),
      );
    }

    // 3. Base subnet: move every /24 LAN onto the preferred /16, keeping each
    //    LAN's own third octet and every host octet, so .1 stays the gateway
    //    and each LAN stays a distinct subnet. A /30 WAN is left untouched.
    final baseSubnet = wanted['base_subnet'];
    if (baseSubnet != null && _isCidr(baseSubnet)) {
      out = out.copyWith(addressing: _rebased(out.addressing, baseSubnet));
    }

    // 4. Default service, e.g. "always add a DNS server".
    if (wanted['add_dns'] == 'true') {
      out = _withService(out, 'server', 'dns');
    }

    return out;
  }

  static NetNode _withModel(NetNode n, String model) => NetNode(
    name: n.name,
    type: n.type,
    model: model,
    mgmtIp: n.mgmtIp,
    services: n.services,
    serviceRules: n.serviceRules,
  );

  static NetworkIntent _withService(
    NetworkIntent intent,
    String type,
    String service,
  ) {
    final idx = intent.nodes.indexWhere((n) => n.type == type);
    if (idx < 0) return intent;
    final node = intent.nodes[idx];
    if (node.services.contains(service)) return intent;
    final nodes = [...intent.nodes];
    nodes[idx] = NetNode(
      name: node.name,
      type: node.type,
      model: node.model,
      mgmtIp: node.mgmtIp,
      services: [...node.services, service],
      serviceRules: node.serviceRules,
    );
    return intent.copyWith(nodes: nodes);
  }

  static List<InterfaceAddr> _rebased(
    List<InterfaceAddr> addresses,
    String base,
  ) {
    final octets = base.split('/').first.split('.').map(int.parse).toList();
    if (octets.length != 4) return addresses;
    return addresses.map((a) {
      final parts = a.ipCidr.split('/');
      if (parts.length != 2) return a;
      final ip = parts[0].split('.');
      if (ip.length != 4) return a;
      // Only LAN-sized networks move; a transit /30 keeps its addressing.
      if (parts[1] != '24') return a;
      return InterfaceAddr(
        node: a.node,
        iface: a.iface,
        ipCidr: '${octets[0]}.${octets[1]}.${ip[2]}.${ip[3]}/24',
      );
    }).toList();
  }

  static bool _isCidr(String s) =>
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}$').hasMatch(s.trim());

  static bool _isKnownProtocol(String s) =>
      const ['static', 'ospf', 'eigrp', 'bgp', 'none'].contains(s);

  static String? _protocolIn(String lower) {
    for (final p in const ['ospf', 'eigrp', 'bgp']) {
      if (RegExp('\\b$p\\b').hasMatch(lower)) return p;
    }
    if (lower.contains('static rout')) return 'static';
    return null;
  }
}
