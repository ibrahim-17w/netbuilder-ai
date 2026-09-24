import '../models/network_intent.dart';

/// Pure-Dart pre-deploy validator. No plugins, fully unit-testable.
class ValidationIssue {
  final String severity; // error, warning
  final String message;
  const ValidationIssue(this.severity, this.message);
}

class ValidatorService {
  static final _interfacePattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9-]*\d+(?:/\d+){0,2}$',
  );
  static final _serviceNames = <String>{
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
  };

  static List<int>? _ipv4(String raw) {
    final parts = raw.trim().split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return octets;
  }

  static int? _prefix(String cidr) {
    final slash = cidr.indexOf('/');
    if (slash < 1 || slash == cidr.length - 1) return null;
    final prefix = int.tryParse(cidr.substring(slash + 1).trim());
    return prefix != null && prefix >= 0 && prefix <= 32 ? prefix : null;
  }

  static List<ValidationIssue> validate(
    NetworkIntent intent, {
    String target = 'gns3',
  }) {
    final issues = <ValidationIssue>[];

    if (intent.nodes.isEmpty) {
      issues.add(const ValidationIssue('error', 'No nodes defined.'));
      return issues;
    }

    // Duplicate names
    final names = intent.nodes.map((n) => n.name).toList();
    if (names.toSet().length != names.length) {
      issues.add(const ValidationIssue('error', 'Duplicate device names.'));
    }

    // Hostname rules (Cisco)
    for (final n in intent.nodes) {
      if (n.name.contains(' ')) {
        issues.add(
          ValidationIssue('error', 'Hostname "${n.name}" contains spaces.'),
        );
      }
      if (n.name == 'VLAN1' || n.name == 'Vlan1') {
        issues.add(
          const ValidationIssue(
            'warning',
            'Avoid using VLAN 1 for user traffic.',
          ),
        );
      }
    }

    // Addressing checks. The old validator treated every address as /24,
    // which let malformed CIDRs through and missed duplicate assignments on
    // the same interface. Keep host addresses in the same LAN valid while
    // still validating every target and exact IP.
    final nets = <String, String>{}; // IP -> node:iface
    final addressSlots = <String, String>{};
    final known = names.toSet();
    for (final a in intent.addressing) {
      final cidr = a.ipCidr.trim();
      final ip = cidr.split('/').first.trim();
      final oct = _ipv4(ip);
      final prefix = _prefix(cidr);
      if (!known.contains(a.node)) {
        issues.add(
          ValidationIssue(
            'error',
            'Address ${a.ipCidr} targets unknown node ${a.node}.',
          ),
        );
      }
      if (a.iface.trim().isEmpty ||
          !_interfacePattern.hasMatch(a.iface.trim())) {
        issues.add(
          ValidationIssue(
            'error',
            '${a.node} has invalid interface name "${a.iface}".',
          ),
        );
      }
      final slotKey = '${a.node.toLowerCase()}|${a.iface.toLowerCase()}';
      if (addressSlots.containsKey(slotKey)) {
        issues.add(
          ValidationIssue(
            'error',
            'Interface ${a.node} ${a.iface} has multiple IP assignments.',
          ),
        );
      } else {
        addressSlots[slotKey] = a.ipCidr;
      }
      if (oct == null || prefix == null) {
        issues.add(
          ValidationIssue(
            'error',
            '${a.node} ${a.iface} has invalid IP ${a.ipCidr}.',
          ),
        );
        continue;
      }
      if (oct.every((value) => value == 255) ||
          (prefix == 32 && oct.every((value) => value == 255))) {
        issues.add(
          ValidationIssue(
            'warning',
            '${a.node} ${a.iface} uses a broadcast-style host address $ip.',
          ),
        );
      }
      if (nets.containsKey(ip)) {
        issues.add(
          ValidationIssue(
            'error',
            'Duplicate IP $ip on ${a.node} and ${nets[ip]}.',
          ),
        );
      } else {
        nets[ip] = '${a.node} ${a.iface}';
      }
    }

    // Every Desktop > IP Configuration device (pc, server, laptop,
    // printer) must have exactly one usable addressing entry. Without it
    // the executor types mask/gateway but leaves the IPv4 row empty
    // (user screenshot: blank IP with 10.0.0.2 gateway) - fail the plan
    // here instead of producing that half-configured panel.
    final addrByNode = <String, List<InterfaceAddr>>{};
    for (final a in intent.addressing) {
      addrByNode.putIfAbsent(a.node.toLowerCase(), () => []).add(a);
    }
    for (final node in intent.nodes) {
      if (!(deviceKindOf(node.type)?.ipConfig ?? false)) continue;
      final addrs = addrByNode[node.name.toLowerCase()] ?? const [];
      final usable = addrs.where((a) {
        final ip = a.ipCidr.split('/').first.trim();
        return _ipv4(ip) != null && ip != '0.0.0.0';
      }).toList();
      if (usable.isEmpty) {
        issues.add(
          ValidationIssue(
            'error',
            '${node.name} needs Desktop > IP Configuration but has no addressing entry; '
            'assign ${node.name} the next free .10+ host on its switch LAN.',
          ),
        );
      }
    }

    // Links reference existing nodes
    final linkEndpoints = <String, int>{};
    final linkKeys = <String>{};
    for (final l in intent.links) {
      if (!known.contains(l.a) || !known.contains(l.b)) {
        issues.add(
          ValidationIssue(
            'error',
            'Link references unknown node ${l.a}-${l.b}.',
          ),
        );
      }
      if (l.a == l.b) {
        issues.add(
          ValidationIssue(
            'error',
            'Self-link ${l.a} is not a valid topology link.',
          ),
        );
      }
      for (final endpoint in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)]) {
        final iface = endpoint.value.trim();
        if (iface.isEmpty || !_interfacePattern.hasMatch(iface)) {
          issues.add(
            ValidationIssue(
              'error',
              'Link endpoint ${endpoint.key}:${endpoint.value} has an invalid interface.',
            ),
          );
        }
        final key = '${endpoint.key.toLowerCase()}|${iface.toLowerCase()}';
        linkEndpoints[key] = (linkEndpoints[key] ?? 0) + 1;
      }
      final left = '${l.a.toLowerCase()}|${l.aIf.toLowerCase()}';
      final right = '${l.b.toLowerCase()}|${l.bIf.toLowerCase()}';
      final key = left.compareTo(right) <= 0
          ? '$left<->$right'
          : '$right<->$left';
      if (!linkKeys.add(key)) {
        issues.add(
          ValidationIssue(
            'error',
            'Duplicate link ${l.a}:${l.aIf} - ${l.b}:${l.bIf}.',
          ),
        );
      }
    }
    for (final entry in linkEndpoints.entries) {
      if (entry.value > 1) {
        final parts = entry.key.split('|');
        issues.add(
          ValidationIssue(
            'error',
            'Interface ${parts[0]}:${parts[1]} is used by ${entry.value} links.',
          ),
        );
      }
    }

    // Packet Tracer hardware gap. A default PT ISR unit ships without a
    // serial HWIC, so a requested serial WAN cannot use the exact interface:
    // the build remaps the cable to a spare routed port. Report that
    // substitution here instead of letting the plan look exact.
    final modelsByName = <String, String?>{
      for (final n in intent.nodes) n.name: n.model,
    };
    final serialWarned = <String>{};
    for (final l in intent.links) {
      for (final endpoint in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)]) {
        final iface = endpoint.value.trim();
        // Covers s0/0/0, Se0/0/0 and Serial0/0/0.
        if (!iface.toLowerCase().startsWith('s')) continue;
        final model = modelsByName[endpoint.key]?.trim() ?? '';
        if (!NetworkIntent.ptRouters.contains(model)) continue;
        if (!serialWarned.add('${endpoint.key}|$iface'.toLowerCase())) {
          continue;
        }
        issues.add(
          ValidationIssue(
            'warning',
            '${endpoint.key} requests serial interface $iface, but a '
            'default Packet Tracer $model has no serial module; the '
            'cable will be remapped to a spare routed port at build '
            'time, so the result is not the requested exact interface. '
            'Remedy: open the router Physical tab, power it off, drag '
            'an HWIC-2T into an empty HWIC slot, power it back on, then '
            're-run - $iface exists after that and no remap is needed.',
          ),
        );
      }
    }

    // Services are only executable on Server-PT nodes. Unknown roles are
    // retained as warnings so the planner can still show the user's intent.
    for (final node in intent.nodes) {
      for (final service in node.services) {
        final normalized = service.trim().toLowerCase();
        if (node.type != 'server') {
          issues.add(
            ValidationIssue(
              'error',
              '${node.name} requests $service service but is not a server.',
            ),
          );
        } else if (!_serviceNames.contains(normalized)) {
          issues.add(
            ValidationIssue(
              'warning',
              '${node.name} requests unsupported Packet Tracer service "$service"; it will be staged for review.',
            ),
          );
        }
      }
      for (final entry in node.serviceRules.entries) {
        final role = entry.key.trim().toLowerCase();
        if (!node.services.map((s) => s.toLowerCase()).contains(role)) {
          issues.add(
            ValidationIssue(
              'warning',
              '${node.name} has rules for $role but did not request that service; the rules will be ignored.',
            ),
          );
          continue;
        }
        final rule = entry.value is Map
            ? Map<String, dynamic>.from(entry.value as Map)
            : const <String, dynamic>{};
        final records = (rule['records'] as List?) ?? const [];
        for (final record in records) {
          final row = record is Map
              ? Map<String, dynamic>.from(record)
              : const <String, dynamic>{};
          final name = row['name']?.toString().trim() ?? '';
          final address = row['address']?.toString().trim() ?? '';
          if (name.isEmpty || _ipv4(address) == null) {
            issues.add(
              ValidationIssue(
                'error',
                '${node.name} $role rule has an invalid DNS record; use name + IPv4 address.',
              ),
            );
          }
        }
        final users = (rule['users'] as List?) ?? const [];
        for (final user in users) {
          final row = user is Map
              ? Map<String, dynamic>.from(user)
              : const <String, dynamic>{};
          if ((row['username']?.toString().trim() ?? '').isEmpty ||
              (row['password']?.toString().trim() ?? '').isEmpty) {
            issues.add(
              ValidationIssue(
                'error',
                '${node.name} $role rule has an account missing username or password; it will not be submitted.',
              ),
            );
          }
        }
      }
    }

    // VLAN range
    for (final v in intent.vlans) {
      if (v < 1 || v > 4094) {
        issues.add(ValidationIssue('error', 'VLAN $v out of range 1-4094.'));
      }
      if (v == 1) {
        issues.add(
          const ValidationIssue(
            'warning',
            'VLAN 1 is default; prefer dedicated VLANs.',
          ),
        );
      }
    }

    // Security controls need explicit evidence and prerequisites.  Missing
    // secrets/office hours are warnings rather than invented defaults: the
    // topology can still be built, but the plan clearly says which security
    // checks will remain incomplete until the user supplies the value.
    final security = intent.security;

    // Packet Tracer emulation gaps in the security intent.  These are
    // reported rather than silently dropped from the plan, and the wording
    // says exactly what is missing: PT does ship the IPsec feature set, but
    // its ISR images only accept the crypto commands once the Security
    // Technology package is licensed - the crypto block is written into the
    // config, yet the executor logs it as skipped instead of typing it.
    if (security.ipsecVpn) {
      issues.add(
        const ValidationIssue(
          'warning',
          'The IPsec/site-to-site VPN block is generated into the config, but a '
          'stock Packet Tracer ISR image rejects crypto isakmp / crypto ipsec / '
          'crypto map until the Security Technology package is licensed, so the '
          'live executor reports the block as skipped. To make it take effect: '
          'license boot module c2900 technology-package securityk9, then '
          'reload, then re-run - the same commands are already in the config '
          'view for pasting by hand.',
        ),
      );
    }
    final officeHours = security.officeHours?.trim() ?? '';
    if (officeHours.isNotEmpty) {
      issues.add(
        ValidationIssue(
          'warning',
          'Packet Tracer does not implement time-range, so the office-hours VTY '
          'restriction ($officeHours) cannot be enforced on the device; the '
          'plain manager-only ACL is applied instead and the time window is '
          'reported as unsupported.',
        ),
      );
    }

    if (security.requested) {
      bool hasNode(String name, String type) =>
          intent.nodes.any((n) => n.name == name && n.type == type);
      if (security.aaa) {
        if (security.aaaServer == null ||
            !hasNode(security.aaaServer!, 'server')) {
          issues.add(
            const ValidationIssue(
              'error',
              'AAA is requested but its server is missing from the plan.',
            ),
          );
        }
        if (security.aaaRouter == null ||
            !hasNode(security.aaaRouter!, 'router')) {
          issues.add(
            const ValidationIssue(
              'error',
              'AAA is requested but its router is missing from the plan.',
            ),
          );
        }
        if (security.aaaUsername == null || security.aaaPassword == null) {
          issues.add(
            const ValidationIssue(
              'warning',
              'TACACS+ credentials are missing; the base network can build, but AAA login cannot be verified yet.',
            ),
          );
        }
      }
      if (security.managerIp != null && security.officeHours == null) {
        issues.add(
          const ValidationIssue(
            'warning',
            'The manager-only VTY rule has no office hours; confirm the time window before relying on it.',
          ),
        );
      }
      if (security.ipsecVpn) {
        if (security.vpnPeerA == null ||
            security.vpnPeerB == null ||
            security.vpnLocalNetwork == null ||
            security.vpnRemoteNetwork == null) {
          issues.add(
            const ValidationIssue(
              'error',
              'IPSec is requested but peer IPs or protected networks are missing.',
            ),
          );
        }
        if (security.vpnPreSharedKey == null ||
            security.vpnPreSharedKey!.isEmpty) {
          issues.add(
            const ValidationIssue(
              'warning',
              'The IPSec pre-shared key is missing; the tunnel will be staged but cannot establish.',
            ),
          );
        }
        final serial = intent.links.any(
          (l) =>
              l.aIf.toLowerCase().startsWith('s') ||
              l.bIf.toLowerCase().startsWith('s'),
        );
        if (!serial) {
          issues.add(
            const ValidationIssue(
              'error',
              'IPSec WAN requirements need a serial or routed peer link.',
            ),
          );
        } else if (target == 'packet-tracer') {
            issues.add(
              const ValidationIssue(
                'info',
                'A serial WAN needs a serial module on each router. The '
                'executor fits an HWIC-2T itself (Physical tab: power '
                'off -> module into an empty HWIC slot -> power on), '
                'wires the link with a Serial DCE/DTE cable and puts the '
                'clock rate on the clocking end. If the module cannot be '
                'fitted, the run reports the exact step it stopped at and '
                'either uses another serial port it proved on the device '
                'or remaps the WAN to a spare routed port - which is an '
                'exact-interface mismatch and cannot pass validation.',
              ),
            );
        }
      }
      if (security.portSecurity &&
          !intent.nodes.any((n) => n.type == 'switch')) {
        issues.add(
          const ValidationIssue(
            'error',
            'Port security is requested but no switch is defined.',
          ),
        );
      }
    }

    // Target-specific
    if (target == 'packet-tracer') {
      // Every kind the plan model knows is placeable and cableable: the
      // executor's palette table is gated against this very list
      // (sidecar/test_device_palette.py), so the two cannot drift apart.
      final supportedTypes = {for (final k in deviceKinds) k.type};
      for (final node in intent.nodes) {
        if (!supportedTypes.contains(node.type)) {
          issues.add(
            ValidationIssue(
              'error',
              'Packet Tracer autopilot cannot build ${node.name} of type ${node.type}.',
            ),
          );
        }
      }
      if (intent.nodes.length > 50) {
        issues.add(
          const ValidationIssue(
            'error',
            'Packet Tracer plan contains more than 50 devices; refusing to run an unsafe or likely misparsed plan.',
          ),
        );
      }
      if (intent.routing == 'bgp') {
        issues.add(
          const ValidationIssue(
            'warning',
            'Packet Tracer BGP support is limited; verify commands.',
          ),
        );
      }
      if (intent.nodes.length > 20) {
        issues.add(
          const ValidationIssue(
            'warning',
            'Large topologies are slow in Packet Tracer autopilot.',
          ),
        );
      }
    }

    return issues;
  }

  static bool hasErrors(List<ValidationIssue> issues) =>
      issues.any((i) => i.severity == 'error');
}
