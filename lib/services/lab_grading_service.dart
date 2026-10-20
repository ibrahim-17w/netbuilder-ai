import 'dart:io';

import '../models/network_intent.dart';
import 'adapters/packet_tracer_adapter.dart';

class LabCheckResult {
  final String label;
  final String hint;
  final bool passed;

  const LabCheckResult({
    required this.label,
    required this.hint,
    required this.passed,
  });
}

/// Grades the structured plan and the configuration the Packet Tracer adapter
/// would generate from it. It does not claim that the live simulator passed.
class LabGradingService {
  const LabGradingService._();

  static List<LabCheckResult> grade(String labId, NetworkIntent plan) {
    final nodes = {for (final node in plan.nodes) node.name: node};
    List<NetNode> byType(String type) =>
        plan.nodes.where((node) => node.type.toLowerCase() == type).toList();
    final connected = _connectedComponents(plan);
    final checks = switch (labId) {
      'office-vlans-dhcp' => <LabCheckResult>[
        _check(
          'Include a router',
          'Add a router to route between the office networks.',
          byType('router').isNotEmpty,
        ),
        _check(
          'Include a switch',
          'Connect the office devices through a switch.',
          byType('switch').isNotEmpty,
        ),
        _check(
          'Create VLAN 10 and VLAN 20',
          'Include both VLAN IDs from the challenge.',
          plan.vlans.toSet().containsAll(const {10, 20}),
        ),
        _check(
          'Configure DHCP pools',
          'Add a DHCP server and generated pools with a start address, gateway, mask, and lease count for both VLANs.',
          _hasDhcpPools(plan, minimum: 2),
        ),
        _check(
          'Cable the router and switch',
          'Connect the router to the switching network.',
          plan.links.any(
            (link) => _pairHasTypes(nodes, link, 'router', 'switch'),
          ),
        ),
      ],
      'dns-web-services' => <LabCheckResult>[
        _check(
          'Add a client',
          'Include a PC or laptop.',
          byType('pc').isNotEmpty || byType('laptop').isNotEmpty,
        ),
        _check(
          'Configure DNS records',
          'Enable DNS on a server and generate at least one usable name-to-address record.',
          _hasDnsRecords(plan),
        ),
        _check(
          'Enable HTTP',
          'Enable HTTP on a server in the generated service configuration.',
          _hasService(plan, 'http', (config) => config['on'] == true),
        ),
        _check(
          'Connect client and servers',
          'Cable the client, DNS server, and web server into one connected topology.',
          _clientAndServiceServersConnected(plan, nodes, connected),
        ),
      ],
      'two-routers-ospf' => <LabCheckResult>[
        _check(
          'Add two routers',
          'The lab needs two routers.',
          byType('router').length >= 2,
        ),
        _check(
          'Enable OSPF',
          'Select OSPF as the routing protocol.',
          plan.routing.toLowerCase() == 'ospf',
        ),
        _check(
          'Configure the router transit link',
          'Cable the routers directly and put valid addresses from the same IPv4 subnet on both cable interfaces.',
          _hasAddressedRouterLink(plan, nodes),
        ),
        _check(
          'Connect two LANs',
          'Give each router a path to a switch and an end device.',
          _hasTwoRoutedLans(plan, nodes),
        ),
      ],
      'secure-device-management' => <LabCheckResult>[
        _check(
          'Include a router and switch',
          'Add both devices that this security lab configures.',
          byType('router').isNotEmpty && byType('switch').isNotEmpty,
        ),
        _check(
          'Enable SSH and disable Telnet',
          'Set secure SSH access and leave Telnet disabled.',
          plan.security.ssh && !plan.security.telnet,
        ),
        _check(
          'Enable port security',
          'Apply port security to the access switch.',
          plan.security.portSecurity,
        ),
        _check(
          'Give the router a management address',
          'Assign an IPv4 address to a router interface or management interface.',
          plan.addressing.any(
                (a) =>
                    nodes[a.node]?.type == 'router' && _validIpv4Cidr(a.ipCidr),
              ) ||
              byType('router').any((n) => _validIpv4Cidr(n.mgmtIp ?? '')),
        ),
      ],
      _ => const <LabCheckResult>[],
    };
    return checks;
  }

  static LabCheckResult _check(String label, String hint, bool passed) =>
      LabCheckResult(label: label, hint: hint, passed: passed);

  static bool _hasService(
    NetworkIntent plan,
    String role,
    bool Function(Map<String, dynamic>) configured,
  ) {
    for (final server in plan.nodes.where((n) => n.type == 'server')) {
      if (!server.services.contains(role)) continue;
      final services = PacketTracerAdapter.serverServices(plan, server.name);
      final value = services[role];
      if (value != null && configured(value)) return true;
    }
    return false;
  }

  static bool _hasDhcpPools(NetworkIntent plan, {required int minimum}) =>
      _hasService(plan, 'dhcp', (config) {
        final pools = config['pools'];
        if (pools is! List || pools.length < minimum) return false;
        final valid = pools.every((pool) {
          if (pool is! Map) return false;
          final startIp = '${pool['startIp'] ?? ''}';
          final gateway = '${pool['gateway'] ?? ''}';
          final mask = '${pool['mask'] ?? ''}';
          final users = int.tryParse('${pool['maxUsers'] ?? ''}') ?? 0;
          return _validIpv4Cidr(startIp) &&
              _validIpv4Cidr(gateway) &&
              _validIpv4Mask(mask) &&
              users > 0;
        });
        final gateways = pools
            .whereType<Map>()
            .map((pool) => '${pool['gateway'] ?? ''}')
            .toSet();
        return valid && gateways.length >= minimum;
      });

  static bool _hasDnsRecords(NetworkIntent plan) =>
      _hasService(plan, 'dns', (config) {
        final records = config['records'];
        return records is List &&
            records.any((record) {
              if (record is! Map) return false;
              return '${record['name'] ?? ''}'.trim().isNotEmpty &&
                  _validIpv4Cidr('${record['address'] ?? ''}');
            });
      });

  static bool _clientAndServiceServersConnected(
    NetworkIntent plan,
    Map<String, NetNode> nodes,
    Map<String, Set<String>> components,
  ) {
    final clients = plan.nodes.where(
      (n) => n.type == 'pc' || n.type == 'laptop',
    );
    final dns = plan.nodes.where(
      (n) => n.type == 'server' && n.services.contains('dns'),
    );
    final web = plan.nodes.where(
      (n) => n.type == 'server' && n.services.contains('http'),
    );
    return clients.any(
          (client) =>
              dns.any(
                (d) => components[client.name]?.contains(d.name) == true,
              ) &&
              web.any((w) => components[client.name]?.contains(w.name) == true),
        ) &&
        nodes.isNotEmpty;
  }

  static bool _pairHasTypes(
    Map<String, NetNode> nodes,
    NetLink link,
    String a,
    String b,
  ) {
    final left = nodes[link.a]?.type.toLowerCase();
    final right = nodes[link.b]?.type.toLowerCase();
    return (left == a && right == b) || (left == b && right == a);
  }

  static bool _hasAddressedRouterLink(
    NetworkIntent plan,
    Map<String, NetNode> nodes,
  ) {
    for (final link in plan.links) {
      if (!_pairHasTypes(nodes, link, 'router', 'router')) continue;
      final left = plan.addressing
          .where((a) => a.node == link.a && a.iface == link.aIf)
          .firstOrNull;
      final right = plan.addressing
          .where((a) => a.node == link.b && a.iface == link.bIf)
          .firstOrNull;
      if (left != null &&
          right != null &&
          _sameIpv4Subnet(left.ipCidr, right.ipCidr)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasTwoRoutedLans(
    NetworkIntent plan,
    Map<String, NetNode> nodes,
  ) {
    final routers = plan.nodes.where((n) => n.type == 'router').toList();
    if (routers.length < 2) return false;
    return routers.take(2).every((router) {
      for (final routerLink in plan.links) {
        final switchName = routerLink.a == router.name
            ? routerLink.b
            : routerLink.b == router.name
            ? routerLink.a
            : '';
        if (switchName.isEmpty || nodes[switchName]?.type != 'switch') continue;
        final routerInterface = routerLink.a == router.name
            ? routerLink.aIf
            : routerLink.bIf;
        final routerAddress = _interfaceAddress(
          plan,
          router.name,
          routerInterface,
        );
        if (routerAddress == null) continue;
        for (final clientLink in plan.links) {
          final clientName = clientLink.a == switchName
              ? clientLink.b
              : clientLink.b == switchName
              ? clientLink.a
              : '';
          if (clientName.isEmpty ||
              (nodes[clientName]?.type != 'pc' &&
                  nodes[clientName]?.type != 'laptop')) {
            continue;
          }
          final clientInterface = clientLink.a == clientName
              ? clientLink.aIf
              : clientLink.bIf;
          final clientAddress = _interfaceAddress(
            plan,
            clientName,
            clientInterface,
          );
          if (clientAddress != null &&
              _sameIpv4Subnet(routerAddress, clientAddress)) {
            return true;
          }
        }
      }
      return false;
    });
  }

  static String? _interfaceAddress(
    NetworkIntent plan,
    String node,
    String iface,
  ) => plan.addressing
      .where((address) => address.node == node && address.iface == iface)
      .map((address) => address.ipCidr)
      .firstOrNull;

  static Map<String, Set<String>> _connectedComponents(NetworkIntent plan) {
    final graph = <String, Set<String>>{
      for (final node in plan.nodes) node.name: {},
    };
    for (final link in plan.links) {
      graph.putIfAbsent(link.a, () => {}).add(link.b);
      graph.putIfAbsent(link.b, () => {}).add(link.a);
    }
    final result = <String, Set<String>>{};
    for (final start in graph.keys) {
      final seen = <String>{start};
      final queue = <String>[start];
      while (queue.isNotEmpty) {
        for (final peer in graph[queue.removeAt(0)] ?? const <String>{}) {
          if (seen.add(peer)) queue.add(peer);
        }
      }
      result[start] = seen;
    }
    return result;
  }

  static bool _validIpv4Cidr(String value) {
    final ip = value.split('/').first;
    final parsed = InternetAddress.tryParse(ip);
    if (parsed?.type != InternetAddressType.IPv4 ||
        ip == '0.0.0.0' ||
        ip == '255.255.255.255') {
      return false;
    }
    if (!value.contains('/')) return true;
    final prefix = int.tryParse(value.split('/').last);
    return prefix != null && prefix >= 0 && prefix <= 32;
  }

  static bool _validIpv4Mask(String value) {
    final address = InternetAddress.tryParse(value);
    if (address?.type != InternetAddressType.IPv4) return false;
    var zeroSeen = false;
    for (final byte in address!.rawAddress) {
      for (var bit = 7; bit >= 0; bit--) {
        final set = (byte & (1 << bit)) != 0;
        if (!set) zeroSeen = true;
        if (set && zeroSeen) return false;
      }
    }
    return true;
  }

  static bool _sameIpv4Subnet(String left, String right) {
    final leftParts = left.split('/');
    final rightParts = right.split('/');
    if (leftParts.length != 2 || rightParts.length != 2) return false;
    final prefix = int.tryParse(leftParts[1]);
    if (prefix == null ||
        prefix != int.tryParse(rightParts[1]) ||
        prefix < 0 ||
        prefix > 32) {
      return false;
    }
    final a = InternetAddress.tryParse(leftParts.first);
    final b = InternetAddress.tryParse(rightParts.first);
    if (a?.type != InternetAddressType.IPv4 ||
        b?.type != InternetAddressType.IPv4) {
      return false;
    }
    final aBytes = a!.rawAddress;
    final bBytes = b!.rawAddress;
    for (var bit = 0; bit < prefix; bit++) {
      final mask = 1 << (7 - bit % 8);
      if ((aBytes[bit ~/ 8] & mask) != (bBytes[bit ~/ 8] & mask)) return false;
    }
    return true;
  }
}
