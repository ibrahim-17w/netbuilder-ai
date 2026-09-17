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
            out['dhcp'] = {
              'gateway': gw,
              // serve our own DNS when this box is also the DNS server
              'dnsServer': node.services.contains('dns') ? srvIp : gw,
              'startIp': '$prefix.100',
              'mask': mask,
              'maxUsers': '100',
              ...explicit,
            };
          }
        case 'dns':
          final explicit = explicitRules('dns');
          final inferred = <Map<String, String>>[];
          final seenNames = <String>{};
          for (final addressed in intent.addressing) {
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
        case 'aaa':
          final secAaa = intent.security;
          final explicit = explicitRules('aaa');
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
                    {'username': 'admin', 'password': 'cisco'},
                  ],
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
        'configs': deviceConfigs(intent),
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
        checks.add({
          'device': n.name,
          'command':
              'show running-config | include aaa|tacacs|login authentication|transport input',
          'expected': 'aaa',
          'kind': 'aaa',
          'requiredMarkers': [
            'aaa new-model',
            'tacacs',
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
