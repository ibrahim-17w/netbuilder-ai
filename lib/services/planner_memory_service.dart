import '../models/network_intent.dart';
import 'request_understanding/requirement_merger.dart';

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
  // Design levers a seasoned engineer keeps consistent across a lab. These
  // map onto fields the plan already carries (notes, addressing), so learning
  // them needs no schema change and cannot invent anything the user did not
  // say.
  static const List<String> transitKeys = ['transit', 'wan_link', 'p2p'];
  static const List<String> managementVlanKeys = [
    'management_vlan',
    'mgmt_vlan',
  ];
  static const List<String> ospfAreaKeys = ['ospf_area', 'area'];
  static const List<String> stpModeKeys = ['stp', 'spanning_tree'];

  /// Return a copy of [intent] with the learned corrections applied.
  static NetworkIntent apply(
    NetworkIntent intent, {
    List<String> rules = const [],
    Map<String, String> preferences = const {},
    String instruction = '',
    RequirementMemoryProtection? requirementProtection,
  }) {
    if (rules.isEmpty && preferences.isEmpty && instruction.trim().isEmpty) {
      return intent;
    }

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
      if (transitKeys.contains(key)) wanted['transit'] = value.toLowerCase();
      if (managementVlanKeys.contains(key)) wanted['management_vlan'] = value;
      if (ospfAreaKeys.contains(key)) wanted['ospf_area'] = value;
      if (stpModeKeys.contains(key)) wanted['stp'] = value.toLowerCase();
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
      final cidr = RegExp(
        r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b',
      ).firstMatch(r);
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
      // Transit-link style: "/31" or "31-bit" means point-to-point /31;
      // "\/30" the classic two-address transit.
      if (r.contains('transit') ||
          r.contains('wan link') ||
          r.contains('point-to-point') ||
          r.contains('p2p')) {
        if (RegExp(r'\b/?31\b').hasMatch(r) || r.contains('31-bit')) {
          wanted.putIfAbsent('transit', () => 'p2p31');
        } else if (RegExp(r'\b/?30\b').hasMatch(r)) {
          wanted.putIfAbsent('transit', () => 'p2p30');
        }
      }
      // Management VLAN preference, e.g. "management on vlan 99".
      final mgmt = RegExp(
        r'management\s+(?:on\s+)?vlan\s+(\d{1,4})',
      ).firstMatch(r);
      if (mgmt != null) {
        wanted.putIfAbsent('management_vlan', () => mgmt.group(1)!);
      }
      // Explicit OSPF area, e.g. "ospf area 0" / "area 10".
      final area = RegExp(r'\barea\s+(\d{1,4})\b').firstMatch(r);
      if (area != null && (r.contains('ospf') || r.contains('area'))) {
        wanted.putIfAbsent('ospf_area', () => area.group(1)!);
      }
      // Spanning-tree mode, e.g. "use rapid-pvst".
      if (r.contains('rapid-pvst') || r.contains('rapid pvst')) {
        wanted.putIfAbsent('stp', () => 'rapid-pvst');
      } else if (r.contains('pvst')) {
        wanted.putIfAbsent('stp', () => 'pvst');
      } else if (r.contains('mst')) {
        wanted.putIfAbsent('stp', () => 'mst');
      }
    }

    final explicitRouterModels = <String, String>{
      ..._explicitModelsForNodes(
        instruction,
        intent.nodes.where((node) => node.type == 'router'),
      ),
      ...?requirementProtection?.routerModels,
    };
    final explicitSwitchModels = <String, String>{
      ..._explicitModelsForNodes(
        instruction,
        intent.nodes.where((node) => node.type == 'switch'),
      ),
      ...?requirementProtection?.switchModels,
    };
    final explicitLanNetworks = <String>{
      ..._explicitLanNetworks(instruction),
      ...?requirementProtection?.protectedSubnets,
    };

    // A learned convention fills a blank; it must not rewrite a choice made
    // in the instruction that produced this plan. The instruction is kept as
    // evidence rather than guessing explicitness from the generated plan:
    // a parser default and an explicit value can have the same field value.
    final explicitlySpecified = {
      ...explicitFieldsIn(instruction),
      ...?requirementProtection?.protectedFields,
    };
    wanted.removeWhere((key, _) {
      if (!explicitlySpecified.contains(key) &&
          !(key == 'add_dns' && explicitlySpecified.contains('dns_excluded'))) {
        return false;
      }
      if (key == 'router_model' && explicitRouterModels.isNotEmpty) {
        return false;
      }
      if (key == 'switch_model' && explicitSwitchModels.isNotEmpty) {
        return false;
      }
      if (key == 'base_subnet' && explicitLanNetworks.isNotEmpty) {
        return false;
      }
      return true;
    });

    var out = intent;
    if (explicitlySpecified.contains('dns_excluded')) {
      out = _withoutService(out, 'server', 'dns');
    }

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
          if (n.type == 'router') {
            final explicit = explicitRouterModels[n.name];
            if (explicit != null) return _withModel(n, explicit, exact: true);
            if ((routerModel ?? '').isNotEmpty) {
              return _withModel(n, routerModel!);
            }
          }
          if (n.type == 'switch') {
            final explicit = explicitSwitchModels[n.name];
            if (explicit != null) return _withModel(n, explicit, exact: true);
            if ((switchModel ?? '').isNotEmpty) {
              return _withModel(n, switchModel!);
            }
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
      out = out.copyWith(
        addressing: _rebased(
          out.addressing,
          baseSubnet,
          protectedNetworks: explicitLanNetworks,
        ),
      );
    }

    // 4. Default service, e.g. "always add a DNS server".
    if (wanted['add_dns'] == 'true') {
      out = _withService(out, 'server', 'dns');
    }

    // 5. Design conventions the user has taught us.  These annotate the plan
    //    (as notes) rather than silently rewriting addressing: a preference
    //    like "use /31 transit links" is advice the config generator reads,
    //    and it must be visible on the plan card so the user can see it was
    //    applied.  Nothing is invented - each note is a value the user gave.
    final designNotes = <String>[];
    final transit = wanted['transit'];
    if (transit == 'p2p31') {
      designNotes.add('Transit links: /31 point-to-point (learned convention)');
    } else if (transit == 'p2p30') {
      designNotes.add('Transit links: /30 (learned convention)');
    }
    final mgmtVlan = wanted['management_vlan'];
    if (mgmtVlan != null && mgmtVlan.isNotEmpty) {
      designNotes.add('Management VLAN: $mgmtVlan (learned convention)');
    }
    final area = wanted['ospf_area'];
    if (area != null && area.isNotEmpty) {
      designNotes.add('OSPF area: $area (learned convention)');
    }
    final stp = wanted['stp'];
    if (stp != null && stp.isNotEmpty) {
      designNotes.add('Spanning tree: $stp (learned convention)');
    }
    if (designNotes.isNotEmpty) {
      final merged = [...out.notes];
      for (final note in designNotes) {
        if (!merged.contains(note)) merged.add(note);
      }
      out = out.copyWith(notes: merged);
    }

    return out;
  }

  /// The planner fields this instruction addressed. These are deliberately
  /// limited to the levers [apply] can change; unrelated mentions do not
  /// prevent a different learned preference from filling its own blank.
  ///
  /// This is a precedence guard, not a replacement for the full brief parser.
  static Set<String> explicitFieldsIn(String instruction) {
    final text = instruction.toLowerCase();
    final fields = <String>{};
    if (NetworkIntent.resolveRouting(text) != null ||
        RegExp(r'\b(?:ospf|eigrp|bgp|static)\b').hasMatch(text) ||
        RegExp(r'\b(?:no|without)\s+(?:dynamic\s+)?routing\b').hasMatch(text)) {
      fields.add('routing');
    }

    for (final match in RegExp(r'\b(\d{4})\b').allMatches(text)) {
      final model = match.group(1)!;
      final before = text.substring(
        match.start > 32 ? match.start - 32 : 0,
        match.start,
      );
      final after = text.substring(
        match.end,
        match.end + 32 < text.length ? match.end + 32 : text.length,
      );
      final context = '$before $after';
      final namedDevice = RegExp(r'\b[a-z][a-z0-9_-]*\d+\b').hasMatch(context);
      if (NetworkIntent.ptRouters.contains(model) &&
          (RegExp(r'\brouters?\b').hasMatch(context) || namedDevice)) {
        fields.add('router_model');
      }
      if (NetworkIntent.ptSwitches.contains(model) &&
          (RegExp(r'\bswitch(?:es)?\b').hasMatch(context) || namedDevice)) {
        fields.add('switch_model');
      }
    }

    // The memory rule rebases every LAN /24. Any user-supplied subnet in the
    // brief is therefore protected, since its intended per-link scope may
    // not be expressible by the global preference.
    if (RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}\b').hasMatch(text)) {
      fields.add('base_subnet');
    }
    if (RegExp(r'\bdns\b').hasMatch(text)) fields.add('add_dns');
    if (RegExp(
      r"\b(?:no|without|never|avoid|do\s+not|don['’]?t)\b"
      r'[^.;,!?\n]{0,32}\bdns\b',
    ).hasMatch(text)) {
      fields.add('dns_excluded');
    }
    if (RegExp(r'\b(transit|wan\s+link|point.to.point|p2p)\b').hasMatch(text)) {
      fields.add('transit');
    }
    if (RegExp(r'\bmanagement\b[^.;!?]{0,28}\bvlan\b').hasMatch(text)) {
      fields.add('management_vlan');
    }
    if (RegExp(r'\b(?:ospf\s+)?area\s+\d{1,4}\b').hasMatch(text)) {
      fields.add('ospf_area');
    }
    if (RegExp(r'\b(?:rapid[- ]pvst|pvst|mst)\b').hasMatch(text)) {
      fields.add('stp');
    }
    return fields;
  }

  static NetNode _withModel(NetNode n, String model, {bool exact = false}) =>
      NetNode(
        name: n.name,
        type: n.type,
        model: model,
        exactModel: exact,
        modules: n.model == model ? n.modules : const [],
        mgmtIp: n.mgmtIp,
        siteId: n.siteId,
        services: n.services,
        serviceRules: n.serviceRules,
      );

  static Map<String, String> _explicitModelsForNodes(
    String instruction,
    Iterable<NetNode> nodes,
  ) {
    final text = instruction.toLowerCase();
    final capitalizedNames = {
      for (final match in RegExp(
        r'\b[A-Z][A-Za-z0-9_-]*\b',
      ).allMatches(instruction))
        match.group(0)!,
    };
    final result = <String, String>{};
    for (final node in nodes) {
      final likelyDeviceName =
          RegExp(r'\d').hasMatch(node.name) ||
          capitalizedNames.contains(node.name);
      if (!likelyDeviceName) continue;
      final models = node.type == 'router'
          ? NetworkIntent.ptRouters
          : NetworkIntent.ptSwitches;
      for (final model in models) {
        final name = RegExp.escape(node.name.toLowerCase());
        final pattern = RegExp(
          '\\b$name\\b\\s+(?:with\\s+)?model\\s+$model\\b|'
          '\\b$name\\b\\s+uses?\\s+$model\\b|'
          '\\bmodel\\s+$model\\s+(?:for|on)\\s+$name\\b',
        );
        if (pattern.hasMatch(text)) {
          result[node.name] = model;
          break;
        }
      }
    }
    return result;
  }

  static Set<String> _explicitLanNetworks(String instruction) {
    final networks = <String>{};
    for (final match in RegExp(
      r'\b(\d{1,3}(?:\.\d{1,3}){3})/24\b',
    ).allMatches(instruction)) {
      final before = instruction.substring(
        match.start > 48 ? match.start - 48 : 0,
        match.start,
      );
      // A per-device LAN mention scopes the explicit subnet. A generic
      // "LANs in X" statement describes the whole design and blocks a
      // project preference from rebasing the other segments too.
      if (!RegExp(
        r'\b[a-z][a-z0-9_-]*\d+\b',
        caseSensitive: false,
      ).hasMatch(before)) {
        continue;
      }
      final octets = match.group(1)!.split('.');
      networks.add('${octets[0]}.${octets[1]}.${octets[2]}.0/24');
    }
    return networks;
  }

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
      exactModel: node.exactModel,
      modules: node.modules,
      mgmtIp: node.mgmtIp,
      siteId: node.siteId,
      services: [...node.services, service],
      serviceRules: node.serviceRules,
    );
    return intent.copyWith(nodes: nodes);
  }

  static NetworkIntent _withoutService(
    NetworkIntent intent,
    String type,
    String service,
  ) {
    final nodes = intent.nodes.map((node) {
      final hasServiceRule = node.serviceRules.keys.any(
        (key) => key.toString().toLowerCase() == service,
      );
      if (node.type != type ||
          (!node.services.any((value) => value.toLowerCase() == service) &&
              !hasServiceRule)) {
        return node;
      }
      final rules = Map<String, dynamic>.from(node.serviceRules)
        ..removeWhere((key, _) => key.toString().toLowerCase() == service);
      return NetNode(
        name: node.name,
        type: node.type,
        model: node.model,
        exactModel: node.exactModel,
        modules: node.modules,
        mgmtIp: node.mgmtIp,
        siteId: node.siteId,
        services: node.services
            .where((value) => value.toLowerCase() != service)
            .toList(),
        serviceRules: rules,
      );
    }).toList();
    return intent.copyWith(nodes: nodes);
  }

  static List<InterfaceAddr> _rebased(
    List<InterfaceAddr> addresses,
    String base, {
    Set<String> protectedNetworks = const {},
  }) {
    final octets = base.split('/').first.split('.').map(int.parse).toList();
    if (octets.length != 4) return addresses;
    return addresses.map((a) {
      final parts = a.ipCidr.split('/');
      if (parts.length != 2) return a;
      final ip = parts[0].split('.');
      if (ip.length != 4) return a;
      // Only LAN-sized networks move; a transit /30 keeps its addressing.
      if (parts[1] != '24') return a;
      final network = '${ip[0]}.${ip[1]}.${ip[2]}.0/24';
      if (protectedNetworks.contains(network)) return a;
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

  /// True when [text] STATES a preference rather than asking for one lab:
  /// "always use OSPF", "from now on use a 4331", "I prefer /31 transit".
  /// These are the statements worth remembering as rules - a one-off
  /// "use ospf" changes one lab, an "always" changes every plan after it.
  /// A question is never a preference, whatever words it carries.
  static bool isPreferenceStatement(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty || t.endsWith('?')) return false;
    if (t.startsWith('/')) return false;
    return RegExp(
      r'\b(always|from now on|every time|each time|prefer|preference|'
      r'default to|stick to)\b',
    ).hasMatch(t);
  }

  static String? _protocolIn(String lower) {
    for (final p in const ['ospf', 'eigrp', 'bgp']) {
      if (RegExp('\\b$p\\b').hasMatch(lower)) return p;
    }
    if (lower.contains('static rout')) return 'static';
    return null;
  }
}
