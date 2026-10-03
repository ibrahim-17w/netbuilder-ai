import 'dart:convert';
import '../../models/network_intent.dart';
import '../layout_engine.dart';
import '../layout_intent.dart';
import '../network_tools.dart';
import 'cisco_adapter.dart';

/// Packet Tracer has NO public API. This adapter produces:
/// 1) per-device CLI text files for manual paste or autopilot typing
/// 2) an autopilot plan JSON consumed by sidecar/pt_autopilot.py
class PacketTracerAdapter {
  static Map<String, String> deviceConfigs(NetworkIntent intent) =>
      CiscoAdapter.render(intent);

  /// End-device network settings for Desktop > IP Configuration
  /// (PCs AND servers have no CLI in PT). Gateway = the router .1 on
  /// the switch's router link.
  static Map<String, String> endpointIpConfig(
    NetworkIntent intent,
    String device,
  ) {
    final addr = intent.addressing.firstWhere(
      (a) => a.node == device,
      orElse: () =>
          const InterfaceAddr(node: '', iface: '', ipCidr: '0.0.0.0/24'),
    );
    final prefix = addr.ipCidr.split('/');
    final mask =
        const {
          '30': '255.255.255.252',
          '29': '255.255.255.248',
          '28': '255.255.255.240',
          '25': '255.255.255.128',
          '16': '255.255.0.0',
          '8': '255.0.0.0',
        }[prefix.length > 1 ? prefix[1] : '24'] ??
        '255.255.255.0';
    // device -> switch -> router: the router's address on that link
    // is the gateway
    var gw = '0.0.0.0';
    for (final up in intent.links) {
      if (up.a != device && up.b != device) continue;
      final sw = up.a == device ? up.b : up.a;
      for (final rlink in intent.links) {
        if (rlink.a != sw && rlink.b != sw) continue;
        final other = rlink.a == sw ? rlink.b : rlink.a;
        if (other == device) continue; // skip the device's own access link
        final isRouter = intent.nodes.any(
          (n) => n.name == other && n.type == 'router',
        );
        if (!isRouter) continue;
        final rt = intent.addressing
            .where((a) => a.node == other)
            .where(
              (a) => a.iface == (rlink.a == other ? rlink.aIf : rlink.bIf),
            );
        if (rt.isNotEmpty) gw = rt.first.ipCidr.split('/')[0];
      }
    }
    final out = <String, String>{'ip': prefix[0], 'mask': mask, 'gw': gw};
    final dns = _dnsServerIp(intent);
    if (dns != null) out['dns'] = dns;
    // Dual-stack plan: endpoints run SLAAC against the router
    // advertisements instead of a spelled-out address (see the builder's
    // IPV6_ENABLED/IPV6_ADDRESS_AUTOCONFIG port fields).
    final anyV6 = intent.addressing.any(
      (a) => a.ip6Cidr != null &&
          intent.nodes.any(
            (n) => n.name == a.node &&
                (n.type == 'router' || n.type == 'firewall'),
          ),
    );
    if (anyV6) out['ipv6'] = 'true';
    return out;
  }

  /// The first pool address of a /24: x.x.x.50 keeps the low addresses for
  /// statically addressed gear (routers, servers).
  static String _poolStart(String gatewayIp) {
    final o = gatewayIp.split('.');
    if (o.length != 4) return gatewayIp;
    return '${o[0]}.${o[1]}.${o[2]}.50';
  }

  static String? _dnsServerIp(NetworkIntent intent) {
    for (final node in intent.nodes) {
      if (node.type != 'server' || !node.services.contains('dns')) continue;
      for (final addr in intent.addressing) {
        if (addr.node != node.name) continue;
        final ip = addr.ipCidr.split('/').first;
        if (ip != '0.0.0.0') return ip;
      }
    }
    return null;
  }

  /// Kept for callers/tests written against the PC-only name.
  static Map<String, String> pcIpConfig(NetworkIntent intent, String pc) =>
      endpointIpConfig(intent, pc);

  /// Services-tab configuration for one server, derived from its LAN.
  /// Returns {service: params} for every role on the node, e.g. dhcp ->
  /// {gateway, dnsServer, startIp, mask, maxUsers}, dns -> {records},
  /// http -> {https}, aaa -> {users}, email/ftp -> {users/domain}.
  /// Roles without a detailed rule use {on:true, verification:state_only} so
  /// the executor can show exactly what was and was not verified.
  static Map<String, Map<String, dynamic>> serverServices(
    NetworkIntent intent,
    String srv,
  ) {
    final node = intent.nodes.firstWhere(
      (n) => n.name == srv,
      orElse: () => NetNode(name: srv, type: 'server'),
    );
    if (node.services.isEmpty) return {};
    final ipCfg = endpointIpConfig(intent, srv);
    final srvIp = ipCfg['ip'] ?? '0.0.0.0';
    final mask = ipCfg['mask'] ?? '255.255.255.0';
    final gw = ipCfg['gw'] ?? '0.0.0.0';
    final oct = srvIp.split('.');
    final prefix = oct.length == 4
        ? '${oct[0]}.${oct[1]}.${oct[2]}'
        : '192.168.10';
    final poolDns = _dnsServerIp(intent) ?? '192.168.1.101';
    final out = <String, Map<String, dynamic>>{};
    Map<String, dynamic> explicitRules(String role) =>
        Map<String, dynamic>.from(
          (node.serviceRules[role] as Map?) ?? const {},
        );
    for (final role in node.services) {
      switch (role) {
        case 'dhcp':
          final explicit = explicitRules('dhcp');
          if (explicit.containsKey('pools')) {
            out['dhcp'] = explicit;
            break;
          }
          // Inter-VLAN plans: one pool per VLAN, derived from the router's
          // dot1Q sub-interface addresses in the plan's addressing (the
          // single source of truth), so a lease's gateway always matches
          // the interface that actually serves that VLAN.
          final subIfaces = intent.addressing.where(
            (a) =>
                intent.nodes.any(
                  (n) => n.name == a.node && n.type == 'router',
                ) &&
                a.iface.contains('.'),
          ).toList();
          if (subIfaces.isNotEmpty) {
            out['dhcp'] = {
              'pools': [
                for (final a in subIfaces)
                  {
                    'poolName': 'VLAN${a.iface.split('.').last}',
                    'gateway': a.ipCidr.split('/').first,
                    'dnsServer':
                        node.services.contains('dns') ? srvIp : a.ipCidr.split('/').first,
                    'startIp': _poolStart(a.ipCidr.split('/').first),
                    'mask': '255.255.255.0',
                    'maxUsers': '100',
                  },
              ],
            };
            break;
          }
          final secDhcp = intent.security;
          if (secDhcp.branchNetwork != null && srv == 'DHCP1') {
            out['dhcp'] = {
              'pools': [
                {
                  'poolName': 'HQ_LAN',
                  'gateway': '192.168.1.1',
                  'dnsServer': poolDns,
                  'startIp': '192.168.1.150',
                  'mask': '255.255.255.0',
                  'maxUsers': '50',
                },
                {
                  'poolName': 'BRANCH_LAN',
                  'gateway': '192.168.2.1',
                  'dnsServer': poolDns,
                  'startIp': '192.168.2.100',
                  'mask': '255.255.255.0',
                  'maxUsers': '50',
                },
              ],
            };
          } else {
            // The builder reads pools out of 'pools' and nothing else, so a
            // pool described with flat keys is silently dropped and the DHCP
            // tab ends up switched on but empty - the reported bug.
            out['dhcp'] = {
              'pools': [
                {
                  'poolName': 'LAN',
                  'gateway': gw,
                  // serve our own DNS when this box is also the DNS server
                  'dnsServer': node.services.contains('dns') ? srvIp : gw,
                  'startIp': '$prefix.100',
                  'mask': mask,
                  'maxUsers': '100',
                },
              ],
              ...explicit,
            };
          }
        case 'dns':
          final explicit = explicitRules('dns');
          final inferred = <Map<String, String>>[];
          final seenNames = <String>{};
          // A router's LAN address is the one worth publishing: the transit
          // serial address is claimed first in the addressing list, so
          // without this the record for R1 pointed at its WAN IP.
          final ordered = [...intent.addressing]..sort((a, b) {
            int rank(InterfaceAddr addr) =>
                addr.iface.toLowerCase().startsWith('s') ? 1 : 0;
            return rank(a).compareTo(rank(b));
          });
          for (final addressed in ordered) {
            final addressedNode = intent.nodes.firstWhere(
              (candidate) => candidate.name == addressed.node,
              orElse: () => NetNode(name: addressed.node, type: ''),
            );
            if (!{'router', 'pc', 'server'}.contains(addressedNode.type)) {
              continue;
            }
            final address = addressed.ipCidr.split('/').first;
            final name = addressedNode.name.toLowerCase();
            if (address == '0.0.0.0' || !seenNames.add(name)) continue;
            inferred.add({'name': name, 'address': address});
          }
          if (inferred.isEmpty) {
            inferred.add({'name': srv.toLowerCase(), 'address': srvIp});
          }
          out['dns'] = {
            'records': explicit['records'] ?? inferred,
            ...explicit,
          };
        case 'http':
          // Packet Tracer's standard HTTP panel exposes HTTP reliably; do
          // not invent an HTTPS requirement unless the prompt supplied one.
          out['http'] = {'on': true, ...explicitRules('http')};
        case 'dhcpv6':
          final explicit = explicitRules('dhcpv6');
          if (explicit.containsKey('pools')) {
            out['dhcpv6'] = explicit;
            break;
          }
          // One stateful pool on this server's own LAN prefix.
          final p6 = srvIp.split('.');
          out['dhcpv6'] = {
            'pools': [
              {
                'poolName': 'LAN6',
                'prefix': '2001:db8:${p6.length == 4 ? p6[2] : '1'}::',
                'prefixLength': '64',
                'dnsServer': node.services.contains('dns') ? srvIp : '',
                'domainName': 'lab.local',
              },
            ],
            ...explicit,
          };
        case 'snmp':
          final explicit = explicitRules('snmp');
          out['snmp'] = {
            'enabled': true,
            'agentIp': srvIp,
            'readCommunity': explicit['readCommunity'] ?? 'public',
            'writeCommunity': explicit['writeCommunity'] ?? 'private',
            'version': explicit['version'] ?? '2c',
            ...explicit,
          };
        case 'vm':
          final explicit = explicitRules('vm');
          out['vm'] = {
            'vms': explicit['vms'] ??
                [
                  {'id': 'vm1', 'path': 'vm1', 'status': '1'},
                ],
            ...explicit,
          };
        case 'iot':
          final explicit = explicitRules('iot');
          out['iot'] = {
            'registration': explicit['registration'] ?? true,
            'users': explicit['users'] ??
                [
                  {'username': 'admin', 'password': 'cisco'},
                ],
            ...explicit,
          };
        case 'aaa':
          final secAaa = intent.security;
          final explicit = explicitRules('aaa');
          // The client entry is what makes the server usable: PT's AAA
          // server only answers a router it lists by IP, with the same
          // shared key the router sends (the router side writes
          // `tacacs-server|radius-server key <key>`).
          final isRadius = secAaa.aaaProtocol.trim().toLowerCase().startsWith(
            'radius',
          );
          final serverType = isRadius ? 'RADIUS' : 'TACACS';
          final clients = <Map<String, String>>[];
          // The shared key both ends must agree on. Kept apart from the
          // account password below: the key is what the listed client router
          // has to send, the account is what a user logs in with.
          final clientKey = (secAaa.aaaPassword ?? '').trim().isNotEmpty
              ? secAaa.aaaPassword!.trim()
              : 'cisco';
          if (secAaa.requested &&
              secAaa.aaa &&
              secAaa.aaaRouter != null) {
            final routerIp = intent.addressing
                .where((a) => a.node == secAaa.aaaRouter)
                .where((a) => !a.iface.toLowerCase().startsWith('s'))
                .map((a) => a.ipCidr.split('/').first)
                .where((ip) => ip != '0.0.0.0')
                .toList();
            if (routerIp.isNotEmpty) {
              clients.add({
                'hostIp': routerIp.first,
                'key': clientKey,
                'serverType': serverType,
                'description': secAaa.aaaRouter!,
              });
            }
          }
          // Saying "one server is AAA" names the role but not the client
          // router, the shared key or the accounts - and Packet Tracer leaves
          // AAA Off with an empty tab when there is no client entry. Derive
          // the client from the addressing the plan already has and use
          // documented defaults for the rest, so the tab is genuinely
          // configured rather than switched on and left blank.
          if (clients.isEmpty && gw != '0.0.0.0') {
            clients.add({
              'hostIp': gw,
              'key': clientKey,
              'serverType': serverType,
              'description': 'router on this LAN',
            });
          }
          // The account and the shared key are different secrets and belong in
          // different tabs: the account (name + its own password) is what the
          // server authenticates against, the key is what the listed client
          // router has to send.  Reading the account password as the key
          // produced a client entry the router could never satisfy.
          final accountUser = (secAaa.aaaUsername ?? '').trim();
          final accountPass = (secAaa.aaaAccountPassword ?? '').trim();
          final hasAccount = accountUser.isNotEmpty && accountPass.isNotEmpty;
          out['aaa'] = {
            'users': secAaa.requested && secAaa.aaa
                ? (hasAccount
                      ? [
                          {'username': accountUser, 'password': accountPass},
                        ]
                      : <Map<String, String>>[])
                : [
                    // Two accounts, so there is something to log in with and
                    // something to prove the server distinguishes them.
                    {'username': 'admin', 'password': 'cisco'},
                    {'username': 'operator', 'password': 'cisco123'},
                  ],
            'clients': clients,
            ...explicit,
          };
        case 'email':
        case 'ftp':
          final explicit = explicitRules(role);
          out[role] = {
            'on': true,
            'verification': explicit.isEmpty ? 'state_only' : 'rules',
            ...explicit,
          };
        case 'radiuseap':
          // WPA-Enterprise: the AAA server accepts EAP from the AP. The
          // builder writes the EAP_METHODS list; the AP side asks for the
          // same server IP in its Security tab.
          final explicit = explicitRules('radiusEap');
          out['radiusEap'] = {
            'enabled': true,
            'methods': explicit['methods'] ??
                const ['PEAP', 'TLS', 'TTLS', 'FAST', 'LEAP'],
            ...explicit,
          };
        case 'cme':
          // Cisco Unified CME runs ON a router (telephony-service), not in a
          // server's Services tab.  This case only supplies the parameters;
          // CiscoAdapter.voiceConfig compiles the actual IOS config onto the
          // gateway router, and each 7960 registers against it.
          final explicit = explicitRules('cme');
          out['cme'] = {
            'on': true,
            'verification': 'state_only',
            'router': explicit['router'],
            'directoryNumberBase': explicit['directoryNumberBase'] ?? '2001',
            'sourceAddress': srvIp,
            ...explicit,
          };
        default:
          final explicit = explicitRules(role);
          out[role] = {
            'on': true,
            'verification': explicit.isEmpty ? 'state_only' : 'rules',
            ...explicit,
          };
      }
    }
    return out;
  }

  /// [layout] is the drawing the plan asks for (`{'style': 'wide'}` and
  /// optionally `columns`/`spacing`); the engine reads it out of the plan and
  /// places every device accordingly, so asking for a different drawing really
  /// produces a different file.
  ///
  /// When [layout] is omitted the drawing is read from the plan's own notes
  /// (a chosen layout is stamped `layout: <style>`), so a style picked in the
  /// layout gallery reaches the engine on EVERY build path - the builder
  /// screen and the action hub included, not only the chat turn that set it.
  /// With neither, the engine uses its default (site trees).
  static Map<String, dynamic> autopilotPlan(
    NetworkIntent intent, {
    Map<String, dynamic>? layout,
  }) {
    final effective = (layout != null && layout.isNotEmpty)
        ? layout
        : intentLayoutFromNotes(intent);
    return {
      'project': intent.projectName,
      if (effective.isNotEmpty) 'layout': resolveLayoutForEngine(intent, effective),
      'requirement': 'PT window open, maximized, focused, uninterrupted',
    'steps': [
      {
        'action': 'create_nodes',
        'nodes': [for (final n in intent.nodes) n.toJson()],
      },
      {
        'action': 'create_links',
        // `wiredLinks`, not `links`: a copper link between two routers (or two
        // switches, or two hosts) needs a CROSSOVER cable, and Packet Tracer
        // holds the link down with a straight-through - red cable, both ports
        // down, every packet across it dropped. The plan used to leave the
        // cable kind unset for those pairs, so the default straight-through
        // went in and the whole transit network was dead in simulation.
        'links': [for (final l in intent.wiredLinks) l.toJson()],
      },
      {
        'action': 'paste_cli',
        // Firewalls speak ASA, not IOS, so they are never typed at live -
        // but their generated config still travels in the plan and lands in
        // the saved device inside the .pkt (see CiscoAdapter.firewallConfigs).
        'configs': {
          ...deviceConfigs(intent),
          ...CiscoAdapter.firewallConfigs(intent),
          // CME telephony config lands on the voice gateway router when the
          // plan carries phones + a cme-role server.
          ...CiscoAdapter.voiceConfig(intent),
        },
        'typing_delay_ms': 25,
        'verify_hostname': true,
      },
      {
        // Every kind PT configures through Desktop > IP Configuration:
        // PCs, servers, laptops and printers.  Phones/APs/cloud devices have
        // their own GUI and must not be typed at.
        'action': 'config_pcs',
        'pcs': {
          for (final n in intent.nodes.where(
            (n) => deviceKindOf(n.type)?.ipConfig ?? false,
          ))
            n.name: endpointIpConfig(intent, n.name),
        },
      },
      {
        'action': 'config_servers',
        'servers': {
          for (final n in intent.nodes.where(
            (n) => n.type == 'server' && n.services.isNotEmpty,
          ))
            n.name: {'services': serverServices(intent, n.name)},
        },
      },
      if (intent.security.requested)
        {'action': 'verify_security', 'checks': securityChecks(intent)},
      ],
    };
  }

/// The drawing a plan's own notes ask for, as an engine payload.
///
/// A chosen layout is stamped into the plan as `layout: <style>`; reading it
/// here is what makes that choice reach the engine on every build path. An
/// unknown or absent note returns an empty map, so the engine keeps its
/// default rather than being handed a style it does not know.
static Map<String, dynamic> intentLayoutFromNotes(NetworkIntent intent) {
    for (final note in intent.notes) {
      final style = LayoutRequest.styleFromNote(note);
      if (style.isEmpty) continue;
      final zones = LayoutRequest.zonesFromNote(note);
      if (zones.isNotEmpty) {
        return <String, dynamic>{
          'style': style,
          'zones': <Map<String, dynamic>>[
            for (final zone in zones)
              <String, dynamic>{
                if (zone.kinds.isNotEmpty) 'sideKinds': zone.kinds,
                if (zone.names.isNotEmpty) 'sideNames': zone.names,
                if (zone.edge.isNotEmpty) 'sideEdge': zone.edge,
              },
          ],
        };
      }
      final kinds = LayoutRequest.sideKindsFromNote(note);
      final names = LayoutRequest.sideNamesFromNote(note);
      return <String, dynamic>{
        'style': style,
        if (kinds.isNotEmpty) 'sideKinds': kinds,
        if (names.isNotEmpty) 'sideNames': names,
        if (kinds.isNotEmpty || names.isNotEmpty)
          'sideEdge': LayoutRequest.sideEdgeFromNote(note),
      };
    }
    return const {};
  }

/// Turn a drawing request into the payload the engine actually places with.
///
/// The request speaks in kinds ("the servers"); the engine speaks in device
/// names. This is the only place that holds both the plan and the payload, so
/// it is the only place that can do the translation - and doing it here means
/// every build path (chat redraw, gallery pick, builder screen, action hub)
/// parks the same devices, with no chance of one of them quietly drawing the
/// default instead.
////// A `grouped` request that names devices the plan does not have keeps its
/// style but carries no side list: the engine then draws it exactly as a tree,
/// which is honest rather than arbitrary.
///
/// The resolved payload also carries the spot every device was drawn at, so
/// the `.pkt` is parked on the coordinates the user was shown. Sending only
/// the style meant the sidecar recomputed the whole drawing from that string
/// alone: a second, independent implementation of the same ten algorithms,
/// which happened to agree until one side was edited and the preview quietly
/// stopped being the picture that got built. Resolving once here makes the
/// preview the single source of truth - the sidecar places what it is told,
/// and only falls back to computing its own when a caller sends a bare style.
static Map<String, dynamic> resolveLayoutForEngine(
  NetworkIntent intent,
  Map<String, dynamic> layout,
) {
  final out = _resolvedLayoutSettings(intent, layout);
  final spots = resolvedCanvasPositions(intent, out);
  if (spots.isNotEmpty) out['positions'] = spots;
  return out;
}

/// The drawing's resolved spot for every device, as the engine payload wants
/// it: `{"R1": [700, 60]}`, one whole-pixel `[x, y]` per device.
///
/// Exposed on its own so the parity test can compare what the preview draws
/// against what the build is handed, without reaching through the payload.
static Map<String, List<int>> resolvedCanvasPositions(
  NetworkIntent intent,
  Map<String, dynamic> layout,
) {
  final zones = <LayoutZone>[];
  final raw = layout['zones'];
  if (raw is List) {
    for (final zone in raw) {
      if (zone is! Map) continue;
      final names = _stringsIn(zone['side']);
      if (names.isEmpty) continue;
      zones.add(LayoutZone(names, edge: '${zone['sideEdge'] ?? ''}'));
    }
  }
  final snapshot = computeLayoutSnapshot(
    intent,
    style: '${layout['style'] ?? 'tree'}',
    side: zones.isEmpty ? _stringsIn(layout['side']) : const <String>[],
    sideEdge: '${layout['sideEdge'] ?? 'left'}',
    zones: zones,
  );
  return <String, List<int>>{
    for (final spot in snapshot.spots)
      spot.name: <int>[spot.x.toInt(), spot.y.toInt()],
  };
}

/// The payload the engine places with, from a drawing request - kinds
/// translated to device names - without the resolved spots, which
/// [resolveLayoutForEngine] adds on top.
static Map<String, dynamic> _resolvedLayoutSettings(
  NetworkIntent intent,
  Map<String, dynamic> layout,
) {
  final out = Map<String, dynamic>.from(layout);
  if ('${out['style'] ?? ''}' != 'grouped') {
    out.remove('sideKinds');
    out.remove('sideNames');
    out.remove('zones');
    return out;
  }
    final zones = <Map<String, dynamic>>[];
    final raw = out['zones'];
    if (raw is List) {
      for (final zone in raw) {
        if (zone is! Map) continue;
        final names = resolveSideNames(
          intent,
          kinds: _stringsIn(zone['sideKinds']),
          names: _stringsIn(zone['sideNames']),
        );
        if (names.isEmpty) continue;
        zones.add(<String, dynamic>{
          'side': names,
          'edge': '${zone['sideEdge'] ?? ''}',
        });
      }
    }
    out.remove('sideKinds');
    out.remove('sideNames');
    if (zones.isNotEmpty) {
      out['zones'] = zones;
      out.remove('side');
    } else {
      final names = resolveSideNames(
        intent,
        kinds: _stringsIn(layout['sideKinds']),
        names: _stringsIn(layout['sideNames']),
      );
      if (names.isEmpty) {
        out.remove('side');
      } else {
        out['side'] = names;
      }
      out['sideEdge'] = '${out['sideEdge'] ?? 'left'}';
    }
    return out;
  }

  static List<String> _stringsIn(Object? raw) => raw is List
      ? raw.map((e) => '$e').toList()
      : const <String>[];

  /// Live checks are deliberately expressed as read-only CLI commands.  The
  /// sidecar runs them after configuration and reports evidence, rather than
  /// trusting that a command was merely typed.
  static List<Map<String, dynamic>> securityChecks(NetworkIntent intent) {
    final s = intent.security;
    final checks = <Map<String, dynamic>>[];
    for (final n in intent.nodes.where((n) => n.type == 'switch')) {
      if (s.portSecurity) {
        checks.add({
          'device': n.name,
          'command': 'show port-security interface f0/2',
          'expected': 'port security',
          'kind': 'port_security',
          'requiredMarkers': [
            'port security',
            'enabled',
            'maximum mac addresses',
          ],
          'label': '${n.name} port security',
        });
      }
      if (s.dhcpSnooping) {
        checks.add({
          'device': n.name,
          'command': 'show ip dhcp snooping',
          'expected': 'dhcp snooping',
          'kind': 'dhcp_snooping',
          'requiredMarkers': [
            'dhcp snooping is enabled',
            'configured on following vlans',
            'vlan 1',
          ],
          'label': '${n.name} DHCP snooping',
        });
      }
    }
    for (final n in intent.nodes.where((n) => n.type == 'router')) {
      if (s.aaa && n.name == (s.aaaRouter ?? n.name)) {
        final proto = s.aaaProtocol.trim().toLowerCase().startsWith('radius')
            ? 'radius'
            : 'tacacs';
        checks.add({
          'device': n.name,
          'command':
              'show running-config | include aaa|tacacs|radius|login authentication|transport input',
          'expected': 'aaa',
          'kind': 'aaa',
          'requiredMarkers': [
            'aaa new-model',
            proto,
            'login authentication',
            'transport input telnet',
          ],
          'label': '${n.name} AAA/Telnet',
        });
      }
      if (s.extendedAcl && n.name == 'BR_Router') {
        checks.add({
          'device': n.name,
          'command': 'show access-lists BRANCH_TO_HQ',
          'expected': 'branch_to_hq',
          'kind': 'acl',
          'requiredMarkers': ['branch_to_hq', 'permit tcp', 'deny ip'],
          'label': '${n.name} branch ACL',
        });
      }
      if (s.ipsecVpn) {
        // ADVISORY, deliberately: the crypto block is generated into the
        // config but Packet Tracer's ISR images elide `crypto isakmp` / `crypto
        // ipsec` / `crypto map` until the Security Technology package is
        // licensed, which the executor reports as an unsupported feature. A
        // check that can never pass is not evidence, it is a false failure -
        // so the tunnel's state is still probed and reported, and it no longer
        // withholds the run's verification.
        final target = _tunnelTrafficTarget(intent, n.name);
        checks.add({
          'device': n.name,
          'command': 'show crypto isakmp sa',
          'expected': 'qm_idle',
          'kind': 'ike',
          'trafficTarget': ?target,
          'advisory': true,
          'label': '${n.name} IPSec IKE state',
        });
        checks.add({
          'device': n.name,
          'command': 'show crypto ipsec sa',
          'expected': 'pkts encaps',
          'kind': 'ipsec',
          'trafficTarget': ?target,
          'advisory': true,
          'label': '${n.name} IPSec traffic counters',
        });
      }
    }
    return checks;
  }

  /// A host to ping at the FAR end of the tunnel before the crypto probes:
  /// the first addressed endpoint that is not on this router's own LAN.
  ///
  /// The old value was two addresses lifted from the security-lab profile
  /// (192.168.2.10 / 192.168.1.102), which exist in no other plan - every
  /// other tunnel pinged a host that was not there and generated no traffic,
  /// so the very probes that follow had nothing to observe.
  static String? _tunnelTrafficTarget(NetworkIntent intent, String router) {
    final mine = <String>{};
    for (final a in intent.addressing) {
      if (a.node != router) continue;
      var wan = false;
      for (final l in intent.links) {
        final onThis = (l.a == router && l.aIf == a.iface) ||
            (l.b == router && l.bIf == a.iface);
        if (!onThis) continue;
        bool isRouter(String name) =>
            intent.nodes.any((x) => x.name == name && x.type == 'router');
        if (isRouter(l.a) && isRouter(l.b)) {
          wan = true;
          break;
        }
      }
      if (!wan) mine.add(NetworkTools.subnet(a.ipCidr)?.network ?? a.ipCidr);
    }
    for (final a in intent.addressing) {
      if (a.node == router) continue;
      final network = NetworkTools.subnet(a.ipCidr)?.network ?? a.ipCidr;
      if (mine.contains(network)) continue;
      final owner = intent.nodes.where((n) => n.name == a.node).firstOrNull;
      if (owner == null) continue;
      if (const ['router', 'switch', 'firewall'].contains(owner.type)) {
        continue;
      }
      return a.ipCidr.split('/').first;
    }
    return null;
  }

  static String exportPlanJson(NetworkIntent intent) =>
      const JsonEncoder.withIndent('  ').convert(autopilotPlan(intent));

  static String checklist(NetworkIntent intent) {
    final sb = StringBuffer();
    sb.writeln('PT Autopilot checklist for ${intent.projectName}:');
    sb.writeln('1. Open Packet Tracer, new workspace, maximize.');
    sb.writeln('2. Set display scaling 100%, close overlays.');
    sb.writeln('3. Press Start in NetBuilder, do not touch mouse/keyboard.');
    sb.writeln('4. Use Stop on any mis-click; retry pastes per device.');
    return sb.toString();
  }
}
