import '../models/network_intent.dart';
import 'nlu/lexicon.dart';

/// Pure-Dart pre-deploy validator. No plugins, fully unit-testable.
class ValidationIssue {
  final String severity; // error, warning, info
  final String message;

  /// Whether this finding WITHHOLDS the build.
  ///
  /// An error does, and so does a warning - unless the warning is one the app
  /// already acts on by itself. A cable the engine remaps to a free port, a
  /// restriction Packet Tracer cannot enforce, plain advice: none of those
  /// needs a decision from the user, and making them withhold the build meant
  /// "2 routers with a serial link" - a perfectly ordinary brief - could never
  /// be built by anything the user typed, and "fix the plan" answered with a
  /// hardware note no reply can change. The finding is still REPORTED (it is
  /// in the plan check and in the card), it just no longer refuses the build.
  final bool? blocking;

  const ValidationIssue(this.severity, this.message, {this.blocking});

  bool get blocks => blocking ?? severity != 'info';
}

class ValidatorService {
  /// Cisco interface names: `g0/1`, `Serial0/0/0`, and now dot1Q
  /// sub-interfaces (`g0/1.10`) - the router-on-a-stick rows are real
  /// addressing, not typos.
  static final _interfacePattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9-]*\d+(?:/\d+){0,2}(?:\.\d+)?$',
  );
  /// FastEthernet and above on a switch: `f0/1`, `fa0/1`, `gi0/1`. Used to
  /// count how many distinct switch ports a plan cables.
  static final _switchPortPattern = RegExp(r'^f[a-z]*0?/\d+$');
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
    'cme',
    'radiuseap',
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
            blocking: false,
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
        // Both sides are named the same way. The old message printed the
        // second node bare and the first as "node iface", so a self-collision
        // - one router holding the same address on two of its own interfaces -
        // read as "Duplicate IP 192.168.10.1 on R1 and R1 g0/0": the interface
        // that needed the change was the one thing the line did not name.
        issues.add(
          ValidationIssue(
            'error',
            'Duplicate IP $ip is assigned to both ${nets[ip]} and '
            '${a.node} ${a.iface}; give one of them the next free host '
            'address on its own LAN.',
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

    // A device the plan never cables is not part of the network: it ships as
    // an island on the canvas, and any advice that mentions it ("trunk the
    // switches") then describes a link the file does not contain. Report it
    // at the same severity a build would carry into the .pkt.
    final linked = <String>{};
    for (final l in intent.links) {
      linked.add(l.a.toLowerCase());
      linked.add(l.b.toLowerCase());
    }
    // A device that JOINS instead of being cabled - an IoT device, a tablet,
    // a phone, the access point itself - is not standing alone: it associates,
    // and association is not a link in the file. Counting those as islands
    // made an IoT lab a blocking error ("no links are defined, so all 4
    // devices would ship standing alone") for a network whose whole design is
    // that they are not cabled.
    bool joinsInsteadOfCabling(NetNode n) {
      final kind = deviceKindOf(n.type);
      if (kind == null) return false;
      if (kind.wireless) return true;
      // A kind with no port name is placed without a cable BY DESIGN - the
      // device table's own rule is "empty means the executor must not invent
      // a cable for it" (the WLC's Packet Tracer port menu has no stable name
      // across builds). That is not a stranded island, and blocking the build
      // on it asked the user to supply a cable the plan itself refused to
      // invent.
      return kind.port.isEmpty;
    }

    final islands = intent.nodes
        .where((n) => !linked.contains(n.name.toLowerCase()))
        .where((n) => !joinsInsteadOfCabling(n))
        .map((n) => n.name)
        .toList();
    // Uncabled by design is still uncabled: say it once, as advice, instead
    // of either blocking the build or pretending the device is wired.
    final placedNotWired = intent.nodes
        .where((n) => !linked.contains(n.name.toLowerCase()))
        .where((n) => joinsInsteadOfCabling(n))
        .where((n) => !(deviceKindOf(n.type)?.wireless ?? false))
        .map((n) => n.name)
        .toList();
    if (placedNotWired.isNotEmpty) {
      issues.add(
        ValidationIssue(
          'info',
          '${placedNotWired.join(', ')} '
          '${placedNotWired.length == 1 ? 'is' : 'are'} placed but not cabled '
          'by the plan: Packet Tracer names this device type\'s port '
          'differently across builds, so the cable is left to the canvas '
          '(the live run discovers the port on the device).',
          blocking: false,
        ),
      );
    }

    if (islands.isNotEmpty) {
      final everything = islands.length == intent.nodes.length;
      issues.add(
        ValidationIssue(
          everything ? 'error' : 'warning',
          everything
              ? 'No links are defined, so all ${intent.nodes.length} '
                    'device(s) (${islands.take(3).join(', ')}...) would ship '
                    'standing alone; cable the plan before building it.'
              : '${islands.join(', ')} '
                    '${islands.length == 1 ? 'has' : 'have'} no link in the '
                    'plan, so '
                    '${islands.length == 1 ? 'it' : 'they'} would ship standing '
                    'alone on the canvas; cable '
                    '${islands.length == 1 ? 'it' : 'them'} or say so.',
        ),
      );
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
            // The build DOES the remap, so this cannot be a decision only the
            // user can make: with it blocking, every serial WAN brief was
            // unbuildable and "fix the plan" answered with a hardware note.
            blocking: false,
          ),
        );
      }
    }

    // PORT CAPACITY: a switch cannot hold more cables than it has ports. 30
    // PCs plus a server plus a router uplink on a 24-port 2960 planned ports
    // f0/25..f0/32, which the device does not have - and nothing in the build
    // path objects, so the .pkt was quietly written with dangling cables.
    final usedPorts = <String, Set<String>>{};
    for (final l in intent.links) {
      for (final endpoint in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)]) {
        if (!_switchPortPattern.hasMatch(endpoint.value.toLowerCase())) {
          continue;
        }
        (usedPorts[endpoint.key] ??= <String>{}).add(endpoint.value.toLowerCase());
      }
    }
    for (final node in intent.nodes) {
      if (node.type != 'switch') continue;
      final used = usedPorts[node.name] ?? const <String>{};
      if (used.isEmpty) continue;
      final capacity = NetworkIntent.switchPortCapacity(node.model);
      if (used.length <= capacity) continue;
      final over = used.length - capacity;
      issues.add(
        ValidationIssue(
          'error',
          '${node.name} is cabled to ${used.length} devices but a Packet '
          'Tracer ${node.model ?? '2960'} has only $capacity ports; '
          '$over cable(s) land on interfaces the switch does not have. '
          'Remedy: add another switch, or use a model with more ports '
          '(a 3560 has 24 FastEthernet plus 4 GigabitEthernet).',
        ),
      );
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
              blocking: false,
            ),
          );
        }
      }
      for (final entry in node.serviceRules.entries) {
        final role = entry.key.trim().toLowerCase();
        if (!node.services.map((s) => s.toLowerCase()).contains(role) &&
            !_roleIsIntrinsicTo(role, node.type)) {
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
            blocking: false,
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
          // A Packet Tracer licensing gap the plan cannot act on: the config
          // is generated either way, so it is a note, not a refusal.
          blocking: false,
        ),
      );
    }
    final officeHours = security.officeHours?.trim() ?? '';
    if (security.hsrp &&
        !intent.nodes.where((n) => n.type == 'router').any(
          (n) => intent.addressing.any(
            (a) =>
                a.node == n.name &&
                !intent.links.any((l) => _isTransitEndpoint(l, a.node, a.iface)),
          ),
        )) {
      issues.add(
        const ValidationIssue(
          'warning',
          'HSRP is requested but no router has a LAN interface; the standby '
          'groups were not applied.',
        ),
      );
    }
    if (security.etherChannel &&
        intent.nodes.where((n) => n.type == 'switch').length < 2) {
      issues.add(
        const ValidationIssue(
          'error',
          'EtherChannel needs at least two switches to bundle between.',
        ),
      );
    }
    if (security.interVlanRouting && intent.vlans.isEmpty) {
      issues.add(
        const ValidationIssue(
          'warning',
          'Inter-VLAN routing was requested but the plan defines no VLANs; '
          'no dot1Q sub-interfaces were created.',
        ),
      );
    }
    if (security.interVlanRouting &&
        intent.vlans.isNotEmpty &&
        !intent.nodes.any((n) => n.type == 'router')) {
      issues.add(
        const ValidationIssue(
          'error',
          'Inter-VLAN routing needs a router; the plan has none.',
        ),
      );
    }
    if (officeHours.isNotEmpty) {
      issues.add(
        ValidationIssue(
          'warning',
          'Packet Tracer does not implement time-range, so the office-hours VTY '
          'restriction ($officeHours) cannot be enforced on the device; the '
          'plain manager-only ACL is applied instead and the time window is '
          'reported as unsupported.',
          blocking: false,
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
        // What AAA actually needs to work is an ACCOUNT on the server, not a
        // shared key: the key is a documented lab default the adapters fill
        // in, while an empty account list means nothing can log in at all.
        // Checking the key instead reported a missing credential on plans that
        // had a working login, and missed a configured one.
        final server = intent.nodes
            .where((n) => n.name == security.aaaServer)
            .firstOrNull;
        final users =
            (server?.serviceRules['aaa'] as Map?)?['users'];
        final hasAccount =
            (users is List && users.isNotEmpty) ||
            ((security.aaaUsername ?? '').isNotEmpty &&
                (security.aaaAccountPassword ?? '').isNotEmpty);
        if (!hasAccount) {
          issues.add(
            const ValidationIssue(
              'warning',
              'The AAA server holds no account, so no login can be verified. '
              'Add one - for example "AAA client name admin password 123" - '
              'and it is written into the server\'s Services tab.',
            ),
          );
        }
      }
      if (security.managerIp != null && security.officeHours == null) {
        issues.add(
          const ValidationIssue(
            'warning',
            'The manager-only VTY rule has no office hours; confirm the time window before relying on it.',
            blocking: false,
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
        // What a tunnel needs is a ROUTED link between its two peers - that
        // is the link the crypto map rides on, and the message below has
        // always said "serial or routed peer link". The test only ever looked
        // for a serial port, so every ordinary Ethernet WAN ("2 routers, 2
        // switches and 8 pcs each, site-to-site ipsec vpn") was reported as
        // missing one it plainly had. A serial link is a special case of a
        // routed one, and it is the case that needs the module note.
        NetLink? peerLink;
        for (final l in intent.links) {
          final a = intent.nodes.where((n) => n.name == l.a).firstOrNull;
          final b = intent.nodes.where((n) => n.name == l.b).firstOrNull;
          if (a?.type == 'router' && b?.type == 'router') {
            peerLink = l;
            break;
          }
        }
        if (peerLink == null) {
          issues.add(
            const ValidationIssue(
              'error',
              'IPSec is requested but no router-to-router link exists for the '
              'tunnel to run over.',
            ),
          );
        } else if (peerLink.isSerial && target == 'packet-tracer') {
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
            blocking: false,
          ),
        );
      }
      if (intent.nodes.length > 20) {
        // INFO, not a warning: nothing about a 35-device lab is baked into the
        // file as a defect - it is a heads-up about how long the autopilot
        // takes. Carrying it at warning severity withheld the Build card for
        // an entirely correct plan ("the plan still has 1 finding that would
        // be baked into the .pkt"), and no phrasing from the user could clear
        // it, because there was nothing to clear.
        issues.add(
          const ValidationIssue(
            'info',
            'Large topologies are slow in Packet Tracer autopilot.',
          ),
        );
      }
    }

    return issues;
  }

  static bool hasErrors(List<ValidationIssue> issues) =>
      issues.any((i) => i.severity == 'error');

  // --- memoized read of the same findings, for the UI hot path -------------

  /// The one entry [validateCached] keeps. `NetworkIntent` is compared by
  /// identity (not `==`), because the plan a chat screen holds is one mutable
  /// object the user edits in place, and a value comparison would walk the
  /// whole topology on every call - the very cost the cache exists to avoid.
  static NetworkIntent? _cachedIntent;
  static String? _cachedTarget;
  static String? _cachedRevision;
  static List<ValidationIssue>? _cachedIssues;

  /// The findings [validate] reports for [intent], served from a one-entry
  /// cache when nothing that can change them has moved.
  ///
  /// WHY: the chat screen asks the same question about the same plan over and
  /// over - every rebuild of the activity list, every badge, every card - and
  /// [validate] walks every node, every address, every link and every service
  /// rule each time. A plan with 54 devices costs a few milliseconds, which is
  /// a dropped frame or two while a reply is still streaming.
  ///
  /// WHY THE KEY IS THREE THINGS AND NOT ONE:
  ///
  /// * `identical(intent)` - a plan is a long-lived object the UI keeps
  ///   handing to the same widgets, so identity catches the common case for
  ///   free. It is NOT enough on its own: the plan is edited in place by
  ///   follow-up messages, so the identical object can hold a different
  ///   network a moment later.
  /// * `intent.revision` - recomputed on every call, because it is cheap
  ///   relative to the pass it saves (see the gate in
  ///   `test/dart_perf_gates_test.dart`), and it moves on any real edit. It is
  ///   NOT a sufficient key on its own either: `revision` deliberately does
  ///   not hash `serviceRules`, `users` or `security.records` (they are the
  ///   fields the parser fills in as prose, and hashing them made a canvas
  ///   drag look like an edit) - and [validate] DOES read all three.
  /// * `target` - the findings are target-specific.
  ///
  /// The returned list is a copy: a caller appending to it must not be able
  /// to poison the next read. [validate] stays the single source of truth and
  /// is called on every miss, so a cache hit can only ever return what
  /// [validate] would have returned for the identical key.
  static List<ValidationIssue> validateCached(
    NetworkIntent intent, {
    String? target,
  }) {
    final issues = _cachedIssues;
    if (issues != null &&
        identical(_cachedIntent, intent) &&
        _cachedTarget == target &&
        _cachedRevision == intent.revision) {
      return List.of(issues);
    }
    final fresh = target == null
        ? validate(intent)
        : validate(intent, target: target);
    _cachedIntent = intent;
    _cachedTarget = target;
    _cachedRevision = intent.revision;
    _cachedIssues = fresh;
    return List.of(fresh);
  }

  /// Drops the memo. Only a test needs this; the entry is one object.
  static void clearCacheForTest() {
    _cachedIntent = null;
    _cachedTarget = null;
    _cachedRevision = null;
    _cachedIssues = null;
  }

  /// A rule a device's own TYPE carries, without asking for a "service".
  ///
  /// An access point or wireless router holds its SSID and its WPA key on the
  /// `wireless` rule: there is no Services tab to tick for it and no other
  /// place the setting could live. Reporting it as "rules for a service it did
  /// not request; the rules will be ignored" told the user something was
  /// wrong with the only thing that device exists to do.
  static bool _roleIsIntrinsicTo(String role, String type) =>
      role == 'wireless' &&
      (type == 'wireless' || type == 'wireless-router' || type == 'ap');

  /// True when this node+interface pair is an endpoint of a
  /// router-to-router link (the deterministic "transit" definition both
  /// the planner and the adapters share).
  static bool _isTransitEndpoint(NetLink l, String node, String iface) {
    final spec = l.a == node ? l.aIf : (l.b == node ? l.bIf : null);
    return spec != null &&
        spec.toLowerCase() == iface.toLowerCase() &&
        l.isSerial; // serial links are the plan's transit links
  }
}
