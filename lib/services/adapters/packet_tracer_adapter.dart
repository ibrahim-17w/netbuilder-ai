import 'dart:convert';
import '../../models/network_intent.dart';
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
                // Same key on both ends: the router side writes it from the
                // same field, defaulting to 'cisco' when none was supplied.
                'key': (secAaa.aaaPassword != null &&
                        secAaa.aaaPassword!.isNotEmpty)
                    ? secAaa.aaaPassword!
                    : 'cisco',
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
              'key': 'cisco',
              'serverType': serverType,
              'description': 'router on this LAN',
            });
          }
          out['aaa'] = {
            'users': secAaa.requested && secAaa.aaa
                ? secAaa.aaaUsername != null && secAaa.aaaPassword != null
                      ? [
                          {
                            'username': secAaa.aaaUsername,
                            'password': secAaa.aaaPassword,
                          },
                        ]
                      : <Map<String, String>>[]
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

  static Map<String, dynamic> autopilotPlan(NetworkIntent intent) => {
    'project': intent.projectName,
    'requirement': 'PT window open, maximized, focused, uninterrupted',
    'steps': [
      {
        'action': 'create_nodes',
        'nodes': [for (final n in intent.nodes) n.toJson()],
      },
      {
        'action': 'create_links',
        'links': [for (final l in intent.links) l.toJson()],
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
        checks.add({
          'device': n.name,
          'command': 'show crypto isakmp sa',
          'expected': 'qm_idle',
          'kind': 'ike',
          'trafficTarget': n.name == 'HQ_Router'
              ? '192.168.2.10'
              : '192.168.1.102',
          'label': '${n.name} IPSec IKE state',
        });
        checks.add({
          'device': n.name,
          'command': 'show crypto ipsec sa',
          'expected': 'pkts encaps',
          'kind': 'ipsec',
          'trafficTarget': n.name == 'HQ_Router'
              ? '192.168.2.10'
              : '192.168.1.102',
          'label': '${n.name} IPSec traffic counters',
        });
      }
    }
    return checks;
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
