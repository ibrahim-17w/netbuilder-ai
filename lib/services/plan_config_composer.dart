import '../models/network_intent.dart';
import 'network_math.dart';
import 'network_tools.dart';

/// PLAN-AWARE CONFIG ANSWERS.
///
/// The assistant's generic answers (the corpus table and the concept chain)
/// teach a topic with placeholder commands. When the user has an open plan,
/// the answer can go one step further: this composer reads the plan's own
/// devices, links, interfaces, subnets, VLANs and security facts and appends
/// a "Your lab:" section whose commands name THEIR router, THEIR subnet,
/// THEIR gateway - lines no generic answer could contain.
///
/// The rules that keep it honest, in priority order:
///
/// * fail closed. A fact the plan does not carry is never invented: no
///   address is conjured, no cable is assumed, no password is made up. When
///   the plan cannot support a topic at all the answer is null, and when the
///   topic is otherwise supportable but one fact is missing the section is
///   one explicit gap line that says what to tell the app ("use 10.0.0.0/24")
///   - a gap the user can close beats an answer that quietly guessed.
/// * every network, wildcard and mask is computed from the plan's CIDRs by
///   [NetworkTools]/[NetworkMath] - the same services the validator and the
///   adapters trust - so the chat answer and the compiled config can never
///   disagree about the arithmetic.
/// * the section never greets and never explains what the commands mean in
///   general: the generic answer directly above it already did that. Only
///   lab-specific lines live here.
///
/// Pure and synchronous: no I/O, no model, no clock - the same plan and topic
/// always produce the same text.
class PlanConfigComposer {
  PlanConfigComposer._();

  /// How many device blocks one section renders in full. A ten-router lab
  /// would blow the ~30-line budget, so the first routers get their blocks
  /// and the rest are named in one closing line rather than silently dropped.
  static const int _maxRouters = 3;

  /// How many per-switch device ports one VLAN section lists in full before
  /// the remaining ports are summarised in a closing line.
  static const int _maxPortsPerSwitch = 3;

  /// The concept keys this composer can ground in a plan. The keys are the
  /// assistant's concept-chain names ('internet' is the chain's key for NAT,
  /// 'default_route' its default-route explainer, 'trunk' its switchport
  /// question); a key outside this set returns null and the generic answer
  /// stands alone.
  static const Set<String> topics = {
    'ospf',
    'eigrp',
    'static',
    'default_route',
    'ssh',
    'dhcp',
    'vlan',
    'trunk',
    'acl',
    'internet',
  };

  /// The composer topic a question maps to, or null.
  ///
  /// This matcher serves the KNOWLEDGE-table path and the no-generic-answer
  /// rescue - the concept chain passes its own key directly, so concept-
  /// owned keys (vlan, acl, internet, dhcp, eigrp, trunk) never need to be
  /// detected here. What it covers is the topics that reach the knowledge
  /// table or fall through entirely today: bare "how do I configure ospf"
  /// has no concept hook, and ssh has no concept at all. Full names arrive
  /// already canonicalized, so only short forms are matched.
  static String? topicFor(String text) {
    final t = text.trim().toLowerCase();
    if (_word(t, 'ssh') || _has(t, 'secure shell')) return 'ssh';
    if (_word(t, 'ospf')) return 'ospf';
    if (_has(t, 'static route') ||
        _has(t, 'static routing') ||
        _has(t, 'ip route')) {
      return 'static';
    }
    if (_has(t, 'default route') ||
        _has(t, 'gateway of last resort') ||
        _has(t, 'route of last resort')) {
      return 'default_route';
    }
    return null;
  }

  static bool _word(String t, String word) =>
      RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(t);

  static bool _has(String t, String phrase) => t.contains(phrase);

  /// A lab-specific "For your lab:" section for [topic], or null when the
  /// plan cannot support it.
  ///
  /// [topic] is one of [topics] - the same keys the concept chain uses.
  /// [target] ('pt', 'gns3', ...) is accepted for the caller's contract but
  /// deliberately not branched on: the IOS shown here is the same IOS the
  /// cisco adapter writes for every target, so a per-target variant would be
  /// a second source of truth with nothing real to differ.
  static String? compose({
    required NetworkIntent plan,
    required String topic,
    required String target,
  }) {
    if (!topics.contains(topic)) return null;
    if (plan.nodes.isEmpty) return null;
    switch (topic) {
      case 'ospf':
        return _routingProtocol(plan, ospf: true);
      case 'eigrp':
        return _routingProtocol(plan, ospf: false);
      case 'static':
        return _staticRoutes(plan);
      case 'default_route':
        return _defaultRoute(plan);
      case 'ssh':
        return _ssh(plan);
      case 'dhcp':
        return _dhcp(plan);
      case 'vlan':
      case 'trunk':
        // A trunk question is grounded by the same section: the trunk lines
        // are exactly the ports where the VLANs cross this plan.
        return _vlan(plan);
      case 'acl':
        return _acl(plan);
      case 'internet':
        return _nat(plan);
    }
    // Unreachable while [topics] and the switch agree; kept fail-closed.
    return null;
  }

  // --- plan facts ----------------------------------------------------------

  static List<NetNode> _routers(NetworkIntent plan) =>
      plan.nodes.where((n) => n.type == 'router').toList();

  static List<NetNode> _switches(NetworkIntent plan) =>
      plan.nodes.where((n) => n.type == 'switch').toList();

  /// 'GigabitEthernet0/1' and 'g0/1' are the same interface, and so are
  /// 'Serial0/0/0' and 's0/0/0' - the plan's addressing and its links spell
  /// interface names in different lengths all the time (the same rule the
  /// cisco adapter matches on), so every node+iface comparison is normalised.
  static String _normIface(String spec) {
    var t = spec.toLowerCase().replaceAll(' ', '');
    for (final full in const [
      'gigabitethernet',
      'fastethernet',
      'serial',
      'ethernet',
    ]) {
      if (t.startsWith(full)) return '${full[0]}${t.substring(full.length)}';
    }
    return t;
  }

  static InterfaceAddr? _addressOf(
    NetworkIntent plan,
    String node,
    String iface,
  ) {
    for (final a in plan.addressing) {
      if (a.node != node) continue;
      if (_normIface(a.iface) != _normIface(iface)) continue;
      return a;
    }
    return null;
  }

  /// One usable subnet fact set, or null when the plan's CIDR is malformed.
  /// Every composer path goes through here, so a bad address can only shrink
  /// the section - it can never print a guessed network.
  static _Net? _netOf(String cidr) {
    final info = NetworkTools.subnet(cidr);
    if (info == null) return null;
    final host = cidr.split('/').first.trim();
    if (NetworkTools.ipToInt(host) == null) return null;
    return _Net(
      network: info.network,
      prefix: info.prefix,
      mask: info.mask,
      wildcard: NetworkMath.wildcardFromPrefix(info.prefix),
      host: host,
    );
  }

  /// The addressed interfaces of one device with their subnet facts, deduped
  /// per subnet (two interfaces on one subnet advertise it once).
  static List<({String iface, _Net net})> _netsOf(
    NetworkIntent plan,
    String node,
  ) {
    final out = <({String iface, _Net net})>[];
    final seen = <String>{};
    for (final a in plan.addressing) {
      if (a.node != node) continue;
      final net = _netOf(a.ipCidr);
      if (net == null) continue;
      if (!seen.add('${net.network}/${net.prefix}')) continue;
      out.add((iface: a.iface, net: net));
    }
    return out;
  }

  /// A router-to-router link is the plan's transit - the established
  /// definition the cisco adapter's static-route and ACL renderers share.
  static bool _onTransitLink(NetworkIntent plan, String node, String iface) {
    final norm = _normIface(iface);
    for (final l in plan.links) {
      if (!_isRouterNamed(plan, l.a) || !_isRouterNamed(plan, l.b)) continue;
      final spec = l.a == node ? l.aIf : (l.b == node ? l.bIf : null);
      if (spec != null && _normIface(spec) == norm) return true;
    }
    return false;
  }

  static bool _isRouterNamed(NetworkIntent plan, String name) =>
      plan.nodes.any((n) => n.name == name && n.type == 'router');

  /// The plan's LAN subnets of one router: addressed interfaces that are not
  /// on a router-to-router transit link. Dot1Q sub-interfaces (`g0/1.10`)
  /// count as LANs - they are the gateways of the VLANs.
  static List<({String iface, _Net net})> _lansOf(
    NetworkIntent plan,
    String router,
  ) => _netsOf(plan, router)
      .where((e) => !_onTransitLink(plan, router, e.iface))
      .toList();

  /// The device and device type on the far end of [node]'s interface.
  static (String peer, String peerType)? _peerOf(
    NetworkIntent plan,
    String node,
    String iface,
  ) {
    final norm = _normIface(iface);
    for (final l in plan.links) {
      if (l.a == node && _normIface(l.aIf) == norm) {
        return (l.b, _typeOf(plan, l.b));
      }
      if (l.b == node && _normIface(l.bIf) == norm) {
        return (l.a, _typeOf(plan, l.a));
      }
    }
    return null;
  }

  static String _typeOf(NetworkIntent plan, String name) => plan.nodes
      .firstWhere((n) => n.name == name, orElse: () => const NetNode(name: '', type: ''))
      .type;

  /// The interface of [node] that faces [peer], from the plan's links.
  static String? _ifaceToward(NetworkIntent plan, String node, String peer) {
    for (final l in plan.links) {
      if (l.a == node && l.b == peer) return l.aIf;
      if (l.b == node && l.a == peer) return l.bIf;
    }
    return null;
  }

  /// The interface of [router] that faces a cloud or modem - the plan's
  /// internet edge, the same reading the adapter's edge-NAT renderer uses.
  static String? _edgeIfaceOf(NetworkIntent plan, String router) {
    for (final l in plan.links) {
      final mine = l.a == router ? l.aIf : (l.b == router ? l.bIf : null);
      if (mine == null) continue;
      final otherType = _typeOf(plan, l.a == router ? l.b : l.a);
      if (otherType == 'cloud' || otherType == 'modem') return mine;
    }
    return null;
  }

  /// One gap line: what the plan is missing and the words that fix it. The
  /// partial-section form of fail-closed - it prints no command that would
  /// pretend the missing fact exists.
  static String _gap(String factLine) => 'Your lab: $factLine';

  /// One line per router naming the transit and LAN subnets it owns - the
  /// lead sentence the routing sections open with.
  static String _routingLead(NetworkIntent plan, List<NetNode> routers) {
    final transit = <String>{};
    for (final l in plan.links) {
      if (!_isRouterNamed(plan, l.a) || !_isRouterNamed(plan, l.b)) continue;
      final a = _addressOf(plan, l.a, l.aIf);
      if (a == null) continue;
      final net = _netOf(a.ipCidr);
      if (net != null) transit.add('${net.network}/${net.prefix}');
    }
    final names = routers.map((r) => r.name).toList();
    final lanBits = <String>[];
    for (final r in routers) {
      final lans = _lansOf(plan, r.name);
      if (lans.isEmpty) continue;
      lanBits.add(
        '${r.name} owns '
        '${lans.map((e) => '${e.net.network}/${e.net.prefix}').join(' and ')}',
      );
    }
    final lead = StringBuffer('Your lab: ')..write(names.join(' and '));
    if (transit.isNotEmpty) lead.write(' link over ${transit.join(' and ')}');
    if (lanBits.isNotEmpty) {
      lead.write(transit.isEmpty ? '' : '; ');
      lead.write(lanBits.join(', '));
    }
    lead.write('.');
    return lead.toString();
  }

  // --- routing protocols ---------------------------------------------------

  /// OSPF and EIGRP share one shape: per-router `router <proto>` blocks with
  /// one network line per subnet the plan addresses that router on - the
  /// same statements the cisco adapter writes, computed from the same CIDRs.
  static String? _routingProtocol(NetworkIntent plan, {required bool ospf}) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null; // a routing protocol needs a router
    final anyAddressed = routers.any((r) => _netsOf(plan, r.name).isNotEmpty);
    if (!anyAddressed) {
      // No addressing anywhere: name the gap and the words that fix it,
      // instead of printing network statements for subnets nobody has.
      final names = routers.map((r) => r.name).join(' and ');
      return _gap(
        '$names ${routers.length == 1 ? 'is' : 'are'} planned but have no '
        'addresses yet - add them with \'use 10.0.0.0/24\' and the '
        '${ospf ? 'OSPF' : 'EIGRP'} statements will follow the real '
        'subnets.',
      );
    }
    final protoName = ospf ? 'OSPF' : 'EIGRP';
    final sb = StringBuffer()
      ..writeln(_routingLead(plan, routers))
      ..writeln();
    var step = 1;
    var shown = 0;
    final skipped = <String>[];
    final rest = <String>[];
    for (final r in routers) {
      final nets = _netsOf(plan, r.name);
      if (nets.isEmpty) {
        // Other routers are addressed, this one is not: one gap line for it
        // instead of an invented network statement.
        skipped.add(r.name);
        continue;
      }
      if (shown >= _maxRouters) {
        // Addressed but past the render budget: named in the closing line
        // rather than silently dropped.
        rest.add(r.name);
        continue;
      }
      shown++;
      sb.writeln('$step. On ${r.name}:');
      sb.writeln();
      sb.writeln('```');
      if (ospf) {
        sb.writeln('router ospf 1');
        var count = 0;
        for (final e in nets) {
          if (count >= 5) {
            sb.writeln('! plus one network line per remaining subnet');
            break;
          }
          sb.writeln(' network ${e.net.network} ${e.net.wildcard} area 0');
          count++;
        }
      } else {
        // One process, one AS number - the same AS 10 the adapter writes on
        // every router, because the neighbours never form on a mismatch.
        sb.writeln('router eigrp 10');
        sb.writeln(' no auto-summary');
        var count = 0;
        for (final e in nets) {
          if (count >= 5) {
            sb.writeln('! plus one network line per remaining subnet');
            break;
          }
          sb.writeln(' network ${e.net.network} ${e.net.wildcard}');
          count++;
        }
      }
      sb.writeln('```');
      sb.writeln();
      step++;
    }
    if (skipped.isNotEmpty) {
      sb.writeln(
        '${skipped.join(' and ')} ${skipped.length == 1 ? 'has' : 'have'} no '
        'address yet - address ${skipped.length == 1 ? 'it' : 'them'} (say '
        '\'use 10.0.0.0/30\') and $protoName will cover it too.',
      );
      sb.writeln();
      step++;
    }
    if (rest.isNotEmpty) {
      sb.writeln('The same block goes on ${rest.join(', ')}.');
      sb.writeln();
      step++;
    }
    final verify = ospf
        ? (routers.length > 1
              ? 'show ip ospf neighbor'
              : 'show ip route ospf')
        : 'show ip eigrp neighbors';
    sb.write(
      '$step. Verify: `$verify`'
      '${ospf && routers.length > 1 ? ' - the neighbors should reach FULL.' : '.'}',
    );
    return sb.toString().trimRight();
  }

  // --- static and default routes -------------------------------------------

  /// Static routes between the plan's routers, one per remote LAN, via the
  /// far end's address on the shared link - the same walk the cisco adapter
  /// performs when no protocol was requested, including its chain rule:
  /// R1 : R2 : R3 means R1 reaches R3's LAN via R2's near address.
  static String? _staticRoutes(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.length < 2) return null; // nothing to route between

    String? ipOn(String node, String iface) {
      final a = _addressOf(plan, node, iface);
      if (a == null) return null;
      return _netOf(a.ipCidr)?.host;
    }

    final sb = StringBuffer()
      ..writeln(_routingLead(plan, routers))
      ..writeln();
    var step = 1;
    var shown = 0;
    var sawTransit = false;
    var sawRoute = false;
    final rest = <String>[];
    for (final r in routers) {
      if (shown >= _maxRouters) {
        // Past the render budget: named in the closing line rather than
        // silently dropped.
        rest.add(r.name);
        continue;
      }
      // Directly reachable routers and the far end's address on the wire,
      // from THIS router's perspective.
      final nextHop = <String, String>{};
      for (final l in plan.links) {
        if (!_isRouterNamed(plan, l.a) || !_isRouterNamed(plan, l.b)) continue;
        final selfIsA = l.a == r.name;
        final selfIsB = l.b == r.name;
        if (!selfIsA && !selfIsB) continue;
        final peer = selfIsA ? l.b : l.a;
        final peerIface = selfIsA ? l.bIf : l.aIf;
        final hop = ipOn(peer, peerIface);
        if (hop != null) {
          nextHop[peer] = hop;
          sawTransit = true;
        }
      }
      if (nextHop.isEmpty) continue;
      // Routers further along the chain are reached through the same first
      // hop - the adapter's BFS, so the answer and the config agree.
      final reachable = <String, String>{...nextHop};
      final queue = [...nextHop.keys];
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        for (final l in plan.links) {
          if (!_isRouterNamed(plan, l.a) || !_isRouterNamed(plan, l.b)) {
            continue;
          }
          final other = l.a == current ? l.b : (l.b == current ? l.a : null);
          if (other == null || other == r.name) continue;
          if (reachable.containsKey(other)) continue;
          reachable[other] = nextHop[current]!;
          queue.add(other);
        }
      }
      final routes = <String>[];
      final emitted = <String>{};
      for (final entry in reachable.entries) {
        for (final e in _lansOf(plan, entry.key)) {
          if (!emitted.add('${e.net.network}/${e.net.prefix}')) continue;
          routes.add('ip route ${e.net.network} ${e.net.mask} ${entry.value}');
        }
      }
      if (routes.isEmpty) continue;
      sawRoute = true;
      shown++;
      sb.writeln('$step. On ${r.name}:');
      sb.writeln();
      sb.writeln('```');
      for (final route in routes) {
        sb.writeln(route);
      }
      sb.writeln('```');
      sb.writeln();
      step++;
    }
    if (rest.isNotEmpty) {
      sb.writeln(
        'The same one-route-per-remote-LAN block goes on '
        '${rest.join(', ')}.',
      );
      sb.writeln();
      step++;
    }
    if (!sawRoute) {
      // Fail closed: say which fact is missing instead of printing a route
      // to a next hop nobody assigned.
      final names = routers.map((r) => r.name).join(' and ');
      if (sawTransit) {
        return _gap(
          '$names link over addressed transit but own no LAN subnets to '
          'route to yet - add LANs with \'use 192.168.1.0/24\'.',
        );
      }
      final linked = plan.links.any(
        (l) => _isRouterNamed(plan, l.a) && _isRouterNamed(plan, l.b),
      );
      return _gap(
        linked
            ? 'the ${routers.first.name}-${routers.last.name} link has no '
                'addresses yet - say \'use 10.0.0.0/30\' and the static '
                'routes will name the real next hop.'
            : 'there is no router-to-router link yet - connect '
                '${routers.first.name} to ${routers.last.name} and address '
                'it (say \'use 10.0.0.0/30\'), then the static routes will '
                'name the real next hop.',
      );
    }
    sb.write(
      '$step. Verify: `show ip route` - each remote LAN shows as an S route.',
    );
    return sb.toString().trimRight();
  }

  /// The default route, anchored on the plan's real internet edge: the
  /// interface that faces a cloud or modem. Without an edge the gap is named
  /// rather than pretending a next hop exists.
  static String? _defaultRoute(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null;
    for (final r in routers) {
      final outside = _edgeIfaceOf(plan, r.name);
      if (outside == null) continue;
      final peer = _peerOf(plan, r.name, outside);
      // A next hop the plan actually addresses on the edge device, else the
      // exit interface - both are real plan facts, never a guessed address.
      String? hop;
      if (peer != null) {
        final peerIface = _ifaceToward(plan, peer.$1, r.name);
        if (peerIface != null) {
          hop = ipHostOf(plan, peer.$1, peerIface);
        }
      }
      final sb = StringBuffer()
        ..writeln(
          'Your lab: ${r.name} reaches the internet through $outside'
          '${peer == null ? '' : ' (${peer.$1})'}.',
        )
        ..writeln()
        ..writeln('1. On ${r.name}:')
        ..writeln()
        ..writeln('```')
        ..writeln(
          hop != null
              ? 'ip route 0.0.0.0 0.0.0.0 $hop'
              : 'ip route 0.0.0.0 0.0.0.0 $outside',
        )
        ..writeln('```')
        ..writeln()
        // The cross-reference to NAT comes BEFORE the verification line, so
        // the section keeps the corpus's shape: the verify command is the
        // last thing the user reads.
        ..writeln(
          'Pair it with NAT (ask "how do I configure NAT") so the LAN '
          'addresses are translated on $outside.',
        )
        ..writeln()
        ..writeln('2. Verify: `show ip route` - the gateway of last resort.');
      return sb.toString().trimRight();
    }
    return _gap(
      '${routers.first.name} has no internet edge yet - say \'add internet '
      'access\' (a cloud or modem at the edge) and the default route will '
      'point out of the new link.',
    );
  }

  static String? ipHostOf(NetworkIntent plan, String node, String iface) {
    final a = _addressOf(plan, node, iface);
    if (a == null) return null;
    return _netOf(a.ipCidr)?.host;
  }

  // --- ssh -----------------------------------------------------------------

  /// Device management SSH, per router, on the plan's real hostnames. The
  /// domain and key are the same block the adapters write (hostname-derived
  /// domain, 1024-bit key - what Packet Tracer accepts locally); the account
  /// is the plan's AAA account when the brief stated one, and the password is
  /// a placeholder because a secret the plan does not carry is never invented.
  static String? _ssh(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null;
    final account = (plan.security.aaaUsername ?? '').trim();
    final password = (plan.security.aaaAccountPassword ?? '').trim();
    final login = account.isEmpty ? 'admin' : account;
    final sb = StringBuffer()
      ..writeln(
        'Your lab: SSH lands on the VTY lines of '
        '${routers.map((r) => r.name).join(' and ')}.',
      )
      ..writeln();
    var step = 1;
    var shown = 0;
    for (final r in routers) {
      if (shown >= _maxRouters) break;
      shown++;
      sb.writeln('$step. On ${r.name}:');
      sb.writeln();
      sb.writeln('```');
      sb.writeln('hostname ${r.name}');
      sb.writeln('ip domain-name ${r.name.toLowerCase()}.lab.local');
      sb.writeln('crypto key generate rsa');
      sb.writeln('1024');
      sb.writeln(
        'username $login secret 0 '
        '${password.isEmpty ? '<password>' : password}',
      );
      sb.writeln('line vty 0 4');
      sb.writeln(' transport input ssh');
      sb.writeln(' login local');
      sb.writeln('```');
      sb.writeln();
      step++;
    }
    if (routers.length > _maxRouters) {
      final rest = routers.skip(_maxRouters).map((r) => r.name).join(', ');
      sb.writeln('The same block goes on $rest.');
      sb.writeln();
      step++;
    }
    // The one address SSH actually points at: the router's first LAN address.
    var loginLine = '';
    for (final r in routers.take(_maxRouters)) {
      final lan = _lansOf(plan, r.name);
      if (lan.isEmpty) continue;
      loginLine = ' Then from a PC: `ssh -l $login ${lan.first.net.host}`.';
      break;
    }
    sb.write('$step. Verify: `show ip ssh`.$loginLine');
    return sb.toString().trimRight();
  }

  // --- dhcp ----------------------------------------------------------------

  /// One `ip dhcp pool` per LAN subnet the plan addresses a router on, with
  /// `default-router` = that router's real interface address and an
  /// excluded-address range covering the addresses the plan already assigned
  /// statically (the gateway and the addressed PCs/servers) - facts no
  /// generic answer has.
  static String? _dhcp(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null;
    final lansByRouter = <String, List<({String iface, _Net net})>>{};
    for (final r in routers) {
      final lans = _lansOf(plan, r.name);
      if (lans.isNotEmpty) lansByRouter[r.name] = lans;
    }
    if (lansByRouter.isEmpty) {
      return _gap(
        '${routers.map((r) => r.name).join(' and ')} '
        '${routers.length == 1 ? 'has' : 'have'} no LAN address yet - add '
        'one with \'use 192.168.1.0/24\' and the pool will follow the real '
        'subnet and gateway.',
      );
    }
    // A DNS server the plan carries (a server node running dns, addressed)
    // is named in every pool; without one the line is left out rather than
    // pointing at an invented 8.8.8.8.
    String? dnsIp;
    for (final n in plan.nodes) {
      if (n.type != 'server' ||
          !n.services.any((s) => s.toLowerCase() == 'dns')) {
        continue;
      }
      for (final a in plan.addressing) {
        if (a.node != n.name) continue;
        dnsIp = _netOf(a.ipCidr)?.host;
        break;
      }
      if (dnsIp != null) break;
    }
    final sb = StringBuffer()
      ..writeln(_dhcpLead(plan, lansByRouter))
      ..writeln();
    var step = 1;
    var shown = 0;
    for (final entry in lansByRouter.entries) {
      if (shown >= _maxRouters) break;
      shown++;
      sb.writeln('$step. On ${entry.key}:');
      sb.writeln();
      sb.writeln('```');
      var count = 0;
      for (final lan in entry.value) {
        if (count >= 2) {
          sb.writeln('! plus one pool per remaining LAN subnet');
          break;
        }
        count++;
        // Every address the plan already assigned inside this subnet; the
        // pool must not hand those out again. The excluded-address lines are
        // global config, so they go BEFORE the pool block (inside `ip dhcp
        // pool` mode IOS rejects them).
        final taken = <int>[];
        for (final a in plan.addressing) {
          final net = _netOf(a.ipCidr);
          if (net == null) continue;
          if (!NetworkTools.sameSubnet(
            '${net.network}/${net.prefix}',
            '${lan.net.network}/${lan.net.prefix}',
          )) {
            continue;
          }
          if (net.host == lan.net.network) continue; // network address row
          taken.add(NetworkTools.ipToInt(net.host)!);
        }
        if (taken.isEmpty) {
          taken.add(NetworkTools.ipToInt(lan.net.host)!);
        }
        taken.sort();
        final first = NetworkTools.intToIp(taken.first);
        final last = NetworkTools.intToIp(taken.last);
        sb.writeln(
          first == last
              ? 'ip dhcp excluded-address $first'
              : 'ip dhcp excluded-address $first $last',
        );
        sb.writeln('ip dhcp pool LAN_${lan.net.network.replaceAll('.', '_')}');
        sb.writeln(' network ${lan.net.network} ${lan.net.mask}');
        sb.writeln(' default-router ${lan.net.host}');
        if (dnsIp != null) sb.writeln(' dns-server $dnsIp');
        sb.writeln('exit');
      }
      sb.writeln('```');
      sb.writeln();
      step++;
    }
    if (lansByRouter.length > _maxRouters) {
      final rest = lansByRouter.keys.skip(_maxRouters).join(', ');
      sb.writeln('The same one-pool-per-LAN block goes on $rest.');
      sb.writeln();
      step++;
    }
    sb.write('$step. Verify: `show ip dhcp binding` after a PC renews.');
    return sb.toString().trimRight();
  }

  static String _dhcpLead(
    NetworkIntent plan,
    Map<String, List<({String iface, _Net net})>> lansByRouter,
  ) {
    final bits = <String>[];
    for (final entry in lansByRouter.entries) {
      for (final lan in entry.value) {
        bits.add(
          '${entry.key} hands out ${lan.net.network}/${lan.net.prefix} '
          '(gateway ${lan.net.host})',
        );
      }
    }
    return 'Your lab: ${bits.join(', ')}.';
  }

  // --- vlans ---------------------------------------------------------------

  /// The plan's VLANs on the plan's switches: `vlan <n>` per requested VLAN,
  /// access mode on the ports where end devices actually hang, trunk on the
  /// switch-to-switch links (and the router uplink once the VLANs need a
  /// router) - with each access port's VLAN derived from the plan's own
  /// addressing (the dot1Q sub-interface in the same subnet), falling back to
  /// the same round-robin the adapters apply.
  static String? _vlan(NetworkIntent plan) {
    final switches = _switches(plan);
    if (switches.isEmpty) return null;
    final vlans = plan.vlans.where((v) => v >= 1 && v <= 4094).toList();
    if (vlans.isEmpty) {
      return _gap(
        '${switches.map((s) => s.name).join(' and ')} '
        '${switches.length == 1 ? 'is' : 'are'} planned but name no VLAN '
        'numbers yet - say \'add vlan 10 and vlan 20\' and the access and '
        'trunk ports will follow.',
      );
    }
    // VLAN -> subnet from the plan's own dot1Q sub-interface rows
    // (`g0/1.10` = VLAN 10): the single source of truth the parser writes
    // and the adapters render from.
    final vlanSubnet = <String, int>{};
    final vlanGateway = <int, String>{};
    for (final a in plan.addressing) {
      if (!_isRouterNamed(plan, a.node)) continue;
      final m = RegExp(r'\.(\d+)$').firstMatch(a.iface);
      if (m == null) continue;
      final net = _netOf(a.ipCidr);
      if (net == null) continue;
      final v = int.tryParse(m.group(1)!) ?? 0;
      vlanSubnet['${net.network}/${net.prefix}'] = v;
      vlanGateway[v] = net.host;
    }

    final sb = StringBuffer()
      ..writeln(
        'Your lab: VLANs ${vlans.join(', ')} across '
        '${switches.map((s) => s.name).join(' and ')}.',
      )
      ..writeln();
    var step = 1;
    var shownSwitches = 0;
    var leftoverPorts = 0;
    for (final sw in switches) {
      if (shownSwitches >= 2) break;
      shownSwitches++;
      // This switch's ports: trunk toward other switches (and the router
      // once several VLANs ride one link), access where an end device hangs.
      final trunkPorts = <String>[];
      final access = <({String port, int vlan})>[];
      for (final l in plan.links) {
        final mine = l.a == sw.name ? l.aIf : (l.b == sw.name ? l.bIf : null);
        if (mine == null) continue;
        final otherName = l.a == sw.name ? l.b : l.a;
        final otherType = _typeOf(plan, otherName);
        if (otherType == 'switch' ||
            (otherType == 'router' && vlans.length > 1)) {
          trunkPorts.add(mine);
          continue;
        }
        if (otherType == 'router') continue; // single-VLAN uplink: layer-2
        // The endpoint's VLAN, from the plan's addressing where it can be
        // derived, else the same round-robin the adapters apply.
        int? vlan;
        for (final a in plan.addressing) {
          if (a.node != otherName) continue;
          final net = _netOf(a.ipCidr);
          if (net == null) continue;
          vlan = vlanSubnet['${net.network}/${net.prefix}'];
          break;
        }
        vlan ??= vlans[plan.links.indexOf(l) % vlans.length];
        access.add((port: mine, vlan: vlan));
      }
      sb.writeln('$step. On ${sw.name}:');
      sb.writeln();
      sb.writeln('```');
      for (final v in vlans) {
        sb.writeln('vlan $v');
      }
      for (final port in trunkPorts) {
        sb.writeln('interface $port');
        sb.writeln(' switchport mode trunk');
        sb.writeln(' switchport trunk allowed vlan ${vlans.join(',')}');
      }
      var count = 0;
      for (final p in access) {
        if (count >= _maxPortsPerSwitch) {
          leftoverPorts += access.length - count;
          break;
        }
        count++;
        sb.writeln('interface ${p.port}');
        sb.writeln(' switchport mode access');
        sb.writeln(' switchport access vlan ${p.vlan}');
      }
      sb.writeln('```');
      sb.writeln();
      step++;
    }
    if (switches.length > 2) {
      final rest = switches.skip(2).map((s) => s.name).join(', ');
      sb.writeln('The same block goes on $rest.');
      sb.writeln();
      step++;
    }
    if (leftoverPorts > 0) {
      sb.writeln(
        '$leftoverPorts more device '
        '${leftoverPorts == 1 ? 'port takes' : 'ports take'} the same access '
        'setting.',
      );
      sb.writeln();
      step++;
    }
    if (vlanGateway.isNotEmpty) {
      final gateways = vlanGateway.entries
          .map((e) => 'VLAN ${e.key} - ${e.value}')
          .join(', ');
      sb.writeln('Gateways from the plan: $gateways.');
      sb.writeln();
      step++;
    }
    sb.write('$step. Verify: `show vlan brief` and `show interfaces trunk`.');
    return sb.toString().trimRight();
  }

  // --- acl -----------------------------------------------------------------

  /// ACLs from the plan's own security facts, in priority order: the
  /// protected-server policy the plan carries (allow web, deny the rest from
  /// the remote LANs, riding the WAN interface - the placement the adapter
  /// renders), else the manager-only VTY rule, else one gap line: an ACL
  /// without a policy is the missing fact, and only the user can supply it.
  static String? _acl(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null;
    final s = plan.security;
    final protectedIp = (s.protectedServerIp ?? '').trim();
    if (protectedIp.isNotEmpty && NetworkTools.ipToInt(protectedIp) != null) {
      // The router that owns the protected server's LAN, and the remote LANs
      // the policy filters (the other routers' LANs, plus the branch block
      // the plan itself names). Keyed by subnet so nothing duplicates.
      String? owner;
      for (final r in routers) {
        if (_lansOf(plan, r.name).any(
          (e) => NetworkTools.contains(
            '${e.net.network}/${e.net.prefix}',
            protectedIp,
          ),
        )) {
          owner = r.name;
          break;
        }
      }
      final remoteLans = <String, _Net>{};
      final branch = (s.branchNetwork ?? '').trim();
      // Only a branch block the plan states WITH its prefix is used as
      // given; guessing a /24 onto a bare address would invent a fact.
      if (branch.contains('/')) {
        final branchNet = _netOf(branch);
        if (branchNet != null) remoteLans['${branchNet.network}/${branchNet.prefix}'] = branchNet;
      }
      for (final r in routers) {
        if (r.name == owner) continue;
        for (final e in _lansOf(plan, r.name)) {
          if (NetworkTools.contains(
            '${e.net.network}/${e.net.prefix}',
            protectedIp,
          )) {
            continue;
          }
          remoteLans['${e.net.network}/${e.net.prefix}'] = e.net;
        }
      }
      remoteLans.removeWhere(
        (key, _) => NetworkTools.contains(key, protectedIp),
      );
      // The applying router: a non-owner with a transit interface (the ACL
      // rides the WAN).
      String? applier;
      String? applierIface;
      for (final r in routers) {
        if (r.name == owner) continue;
        for (final e in _netsOf(plan, r.name)) {
          if (_onTransitLink(plan, r.name, e.iface)) {
            applier = r.name;
            applierIface = e.iface;
            break;
          }
        }
        if (applier != null) break;
      }
      if (applier == null || remoteLans.isEmpty) {
        return _gap(
          'the plan protects $protectedIp but no remote LAN on a WAN link '
          'filters it yet - state what to allow or block and the list will '
          'use the real subnets.',
        );
      }
      // The device the address belongs to, named from the plan.
      var serverName = protectedIp;
      for (final a in plan.addressing) {
        if (a.ipCidr.split('/').first == protectedIp) {
          serverName = a.node;
          break;
        }
      }
      final webIp = (s.allowedWebServerIp ?? '').trim();
      final webOk = webIp.isNotEmpty && NetworkTools.ipToInt(webIp) != null;
      final sources = remoteLans.values
          .map((n) => '${n.network}/${n.prefix}')
          .join(' and ');
      final sb = StringBuffer()
        ..writeln(
          'Your lab: protect $serverName ($protectedIp) from $sources, '
          'applied on $applier.',
        )
        ..writeln();
      sb.writeln('1. On $applier:');
      sb.writeln();
      sb.writeln('```');
      sb.writeln('ip access-list extended PROTECTED_SERVER');
      for (final n in remoteLans.values) {
        if (webOk) {
          sb.writeln(' permit tcp ${n.network} ${n.wildcard} host $webIp eq 80');
        }
        sb.writeln(' deny ip ${n.network} ${n.wildcard} host $protectedIp');
      }
      sb.writeln(' permit ip any any');
      sb.writeln('```');
      sb.writeln();
      sb.writeln('2. Ride it on the WAN interface $applierIface:');
      sb.writeln();
      sb.writeln('```');
      sb.writeln('interface $applierIface');
      sb.writeln(' ip access-group PROTECTED_SERVER out');
      sb.writeln('```');
      sb.writeln();
      sb.writeln('3. Verify: `show access-lists` - the matches move.');
      return sb.toString().trimRight();
    }
    final managerIp = (s.managerIp ?? '').trim();
    if (managerIp.isNotEmpty && NetworkTools.ipToInt(managerIp) != null) {
      // The named manager device, so the section says who the address is.
      var managerName = managerIp;
      for (final a in plan.addressing) {
        if (a.ipCidr.split('/').first == managerIp) {
          managerName = a.node;
          break;
        }
      }
      final names = routers.map((r) => r.name).join(' and ');
      final sb = StringBuffer()
        ..writeln(
          'Your lab: only $managerName ($managerIp) may reach the VTY lines '
          'of $names.',
        )
        ..writeln();
      sb.writeln('1. On each router:');
      sb.writeln();
      sb.writeln('```');
      sb.writeln('ip access-list standard VTY_MANAGER_ONLY');
      sb.writeln(' permit host $managerIp');
      sb.writeln(' deny any');
      sb.writeln('```');
      sb.writeln();
      sb.writeln('2. Apply it to the lines:');
      sb.writeln();
      sb.writeln('```');
      sb.writeln('line vty 0 4');
      sb.writeln(' access-class VTY_MANAGER_ONLY in');
      sb.writeln('```');
      sb.writeln();
      sb.writeln(
        '3. Verify: `show access-lists` and one login attempt from a '
        'non-manager PC (it must fail).',
      );
      return sb.toString().trimRight();
    }
    return _gap(
      'the plan names no ACL policy yet - say what to allow or block (for '
      'example \'block 192.168.2.0/24 from reaching 192.168.1.0/24\') and '
      'the list will use the real subnets.',
    );
  }

  // --- nat -----------------------------------------------------------------

  /// NAT at the plan's real edge: `ip nat inside` on the LAN interfaces the
  /// plan addresses, `ip nat outside` on the interface that faces the cloud
  /// or modem, one `permit` per inside LAN - the same shape the adapter's
  /// edge-NAT renderer writes. A server the plan runs HTTP on gets a static
  /// mapping for the port it actually serves.
  static String? _nat(NetworkIntent plan) {
    final routers = _routers(plan);
    if (routers.isEmpty) return null;
    for (final r in routers) {
      final outside = _edgeIfaceOf(plan, r.name);
      if (outside == null) continue;
      final lans = _lansOf(plan, r.name)
          .where((e) => _normIface(e.iface) != _normIface(outside))
          .toList();
      if (lans.isEmpty) continue;
      final peer = _peerOf(plan, r.name, outside);
      final sb = StringBuffer()
        ..writeln(
          'Your lab: ${r.name}\'s LANs '
          '${lans.map((e) => '${e.net.network}/${e.net.prefix}').join(' and ')} '
          'go out through $outside${peer == null ? '' : ' (${peer.$1})'}.',
        )
        ..writeln()
        ..writeln('1. On ${r.name}, the two sides:')
        ..writeln()
        ..writeln('```');
      for (final e in lans) {
        sb
          ..writeln('interface ${e.iface}')
          ..writeln(' ip nat inside');
      }
      sb
        ..writeln('interface $outside')
        ..writeln(' ip nat outside')
        ..writeln('```')
        ..writeln()
        ..writeln('2. Permit the LANs and overload the edge:')
        ..writeln()
        ..writeln('```');
      for (final e in lans) {
        sb.writeln(
          'access-list 100 permit ip ${e.net.network} ${e.net.wildcard} any',
        );
      }
      sb
        ..writeln('ip nat inside source list 100 interface $outside overload')
        ..writeln('```')
        ..writeln();
      var step = 3;
      // An inside server the plan serves HTTP from gets a static mapping.
      for (final n in plan.nodes) {
        if (n.type != 'server' ||
            !n.services.any((srv) => srv.toLowerCase() == 'http')) {
          continue;
        }
        _Net? onLan;
        for (final a in plan.addressing) {
          if (a.node != n.name) continue;
          final net = _netOf(a.ipCidr);
          if (net == null) continue;
          if (lans.any(
            (e) => NetworkTools.sameSubnet(
              '${net.network}/${net.prefix}',
              '${e.net.network}/${e.net.prefix}',
            ),
          )) {
            onLan = net;
            break;
          }
        }
        if (onLan == null) continue;
        sb
          ..writeln('$step. Keep ${n.name} (${onLan.host}) reachable outside:')
          ..writeln()
          ..writeln('```')
          ..writeln(
            'ip nat inside source static tcp ${onLan.host} 80 interface '
            '$outside 80',
          )
          ..writeln('```')
          ..writeln();
        step++;
        break;
      }
      sb.write(
        '$step. Verify: `show ip nat translations` after a PC loads a page.',
      );
      return sb.toString().trimRight();
    }
    return _gap(
      '${routers.first.name} has no internet edge yet - say \'add internet '
      'access\' (a cloud or modem on the edge) and NAT will anchor on the '
      'new link.',
    );
  }
}

/// One subnet's computed facts, all derived from the plan's own CIDR.
class _Net {
  final String network;
  final int prefix;
  final String mask;
  final String wildcard;
  final String host;

  const _Net({
    required this.network,
    required this.prefix,
    required this.mask,
    required this.wildcard,
    required this.host,
  });
}
