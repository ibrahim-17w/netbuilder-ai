import '../models/network_intent.dart';
import 'validator_service.dart';

/// One thing the repair pass changed, in the shape learning can use.
///
/// [changes] is written for the user and is therefore unusable as learning:
/// it names the device, the address and the port of THIS plan, so reading it
/// back as a rule would tell a later plan to reuse one network's numbers.
/// A [RepairFix] keeps the same event as a stable [kind] plus a positive,
/// self-contained [rule] - what a good plan does - which is all a planner may
/// be told.
class RepairFix {
  /// Stable id for the finding this fixes ('shared_port', ...). Used for
  /// de-duplication, never for display.
  final String kind;

  /// One prescriptive sentence, scoped to the class of problem rather than to
  /// the plan it was found in.
  final String rule;

  const RepairFix(this.kind, this.rule);
}

/// What one repair pass did, in the user's words, and what it could not do.
class PlanRepair {
  /// The repaired plan (the original when nothing could be fixed).
  final NetworkIntent plan;

  /// One plain sentence per change, in the order they were made.
  final List<String> changes;

  /// The same events in machine form, for the learning loop. Never empty when
  /// [changes] is not: a change that cannot state its own rule is a change
  /// the app does not learn from.
  final List<RepairFix> fixes;

  /// The findings that still block a build, computed from the repaired plan
  /// with the same validator and target the build card uses.
  final List<ValidationIssue> remaining;

  const PlanRepair({
    required this.plan,
    required this.changes,
    required this.fixes,
    required this.remaining,
  });

  bool get changed => changes.isNotEmpty;

  /// True when the repaired plan clears every blocking finding.
  bool get clear => remaining.isEmpty;
}

/// A deterministic, offline repair pass over the findings that stop a build.
///
/// This is the body behind "fix the plan" - in the chat, on the build card, or
/// from a quick reply - and it exists because the alternative was a dead end:
/// the app told the user which findings would be baked into the .pkt and then
/// offered no way to act on them, so the only path forward was to retype the
/// whole brief and hope the parser landed differently.
///
/// It repairs only what can be repaired without guessing at the user's intent:
///
/// * an interface carrying two addresses keeps the first;
/// * one address used by two interfaces moves the later one to a free host on
///   the same LAN (or, when that LAN is full, to the next free /24);
/// * a device that needs Desktop > IP Configuration but has no address gets
///   the next free .10+ host on the LAN it is cabled to;
/// * a device the plan never cabled is cabled to a switch with a free port;
/// * two cables landing on one interface move to a free port on the same
///   device (the interface can only hold one, and the second cable would be
///   dropped on the way into the .pkt);
/// * a switch cabled to more devices than it has ports gets the overflow moved
///   onto a switch that does have room, and the devices that moved are
///   re-addressed on the LAN they now sit on.
///
/// Everything else is reported as still blocking, with the validator's own
/// wording, rather than papered over. The pass is pure: the same plan always
/// repairs to the same plan.
class PlanRepairService {
  const PlanRepairService._();

  /// PT routers whose LAN ports are gigabit (`g0/0`), matching the parser's
  /// own interface naming.
  static const List<String> _gigRouters = [
    '4331',
    '4321',
    '2911',
    '2901',
    '1941',
    '829',
  ];

  static PlanRepair repair(
    NetworkIntent intent, {
    String target = 'packet-tracer',
  }) {
    var nodes = [...intent.nodes];
    var links = [...intent.links];
    var addressing = [...intent.addressing];
    final changes = <String>[];
    final fixes = <RepairFix>[];

    // 1. One address per interface: a second row on an interface is a parse
    //    artefact, never a second address a router can hold.
    final slots = <String>{};
    addressing = addressing.where((a) {
      final key = '${a.node.toLowerCase()}|${a.iface.toLowerCase()}';
      if (slots.add(key)) return true;
      changes.add(
        'removed the second address (${a.ipCidr}) from ${a.node} ${a.iface}',
      );
      fixes.add(
        const RepairFix(
          'duplicate_interface_address',
          'Plan one address per interface: a second address on the same '
              'interface is a parse artefact and is dropped from the .pkt.',
        ),
      );
      return false;
    }).toList();

    // 2. Cable anything the plan left standing alone, before addressing it -
    //    an uncabled device has no LAN to be addressed on.
    final linked = <String>{};
    for (final l in links) {
      linked
        ..add(l.a)
        ..add(l.b);
    }
    for (final node in nodes) {
      if (linked.contains(node.name)) continue;
      final uplink = _cableablePort(node, nodes, links);
      if (uplink == null) continue;
      links = [
        ...links,
        NetLink(
          a: uplink.$1,
          aIf: uplink.$2,
          b: node.name,
          bIf: _endpointPort(node),
        ),
      ];
      linked.add(node.name);
      changes.add(
        'cabled ${node.name} to ${uplink.$1} ${uplink.$2} so it is not '
        'standing alone on the canvas',
      );
      fixes.add(
        const RepairFix(
          'uncabled_device',
          'Cable every device in the plan: a device with no link is not part '
              'of the topology and is left standing alone on the canvas.',
        ),
      );
    }

    // 2b. One cable per interface. Two cables on one port is not a topology,
    //     it is a parse artefact - and the interface only holds one, so the
    //     second cable is dropped between the plan and the .pkt. Keep the
    //     first claim and move the rest to a free port on the same device.
    final claimed = <String, Set<String>>{};
    final rewired = <NetLink>[];
    for (final link in links) {
      var current = link;
      for (final end in [
        MapEntry(current.a, current.aIf),
        MapEntry(current.b, current.bIf),
      ]) {
        final port = end.value.trim().toLowerCase();
        final ports = claimed.putIfAbsent(end.key, () => <String>{});
        if (ports.add(port)) continue;
        NetNode? node;
        for (final n in nodes) {
          if (n.name == end.key) node = n;
        }
        final free = node == null ? null : _freePortOn(node, ports, links: links);
        if (free == null) break; // nowhere to move it; leave the finding
        ports.add(free.toLowerCase());
        final moved = _withPort(current, end.key, free) ?? current;
        changes.add(
          'moved ${end.key} off the shared port ${end.value} onto $free, so '
          'each interface carries one cable',
        );
        fixes.add(
          const RepairFix(
            'shared_port',
            'Give every interface its own port: two cables landing on one '
                'port cannot be carried into the .pkt and the second is '
                'dropped on the way in.',
          ),
        );
        current = moved;
      }
      rewired.add(current);
    }
    links = rewired;

    // 2c. A switch cannot hold more cables than it has ports. Move the
    //     overflow to a switch that does have room, and re-address whatever
    //     moved onto the LAN it now sits on.
    for (final node in nodes.where((n) => n.type == 'switch')) {
      final capacity = NetworkIntent.switchPortCapacity(node.model);
      final mine = [
        for (var i = 0; i < links.length; i++)
          if (_portOn(links[i], node.name) != null) i,
      ];
      if (mine.length <= capacity) continue;
      final overflow = mine.sublist(capacity);
      for (final index in overflow) {
        final link = links[index];
        final peer = link.a == node.name ? link.b : link.a;
        // A switch with room, never the device's own switch and never the
        // device itself (a switch cabled to a switch is a different repair).
        NetNode? target;
        String? free;
        for (final n in nodes) {
          if (n.type != 'switch' || n.name == node.name || n.name == peer) {
            continue;
          }
          final slot = _freePortOn(n, _usedPorts(n.name, links), links: links);
          if (slot == null) continue;
          target = n;
          free = slot;
          break;
        }
        if (target == null || free == null) continue;
        final moved = _withPort(link, node.name, free, toDevice: target.name);
        if (moved == null) continue;
        final trial = [...links]..[index] = moved;
        // Only move when the device that moved can be addressed where it now
        // sits: a cable that leaves a device without a LAN is not a repair.
        if (_lanSubnetFor(peer, nodes, trial, addressing) == null) continue;
        links = trial;
        changes.add(
          'moved $peer from ${node.name} to ${target.name} $free: ${node.name} '
          'has only $capacity ports and was cabled to ${mine.length} devices',
        );
        fixes.add(
          const RepairFix(
            'switch_overflow',
            'Count the cables on a switch against its port capacity and '
                'spread the overflow onto a switch that has room, rather '
                'than over-filling the first one.',
          ),
        );
        final stale = addressing.where(
          (a) => a.node.toLowerCase() == peer.toLowerCase(),
        );
        final subnet = _lanSubnetFor(peer, nodes, links, addressing);
        if (stale.isNotEmpty && subnet != null &&
            !_inSubnet(stale.first.ipCidr, subnet)) {
          addressing = [
            for (final a in addressing)
              if (a.node.toLowerCase() != peer.toLowerCase()) a,
          ];
          changes.add(
            'cleared $peer\'s old address so it gets one on the '
            '${target.name} LAN',
          );
          fixes.add(
            const RepairFix(
              'stale_address_after_move',
              'Re-address a device on the LAN it now sits on: moving a cable '
                  'onto another switch means the address it carried with it '
                  'is no longer reachable.',
            ),
          );
        }
      }
    }

    // 3. Every device that needs Desktop > IP Configuration gets an address
    //    on the LAN it is plugged into.
    final used = <String>{
      for (final a in addressing)
        if (_ip(a.ipCidr).isNotEmpty) _ip(a.ipCidr),
    };
    for (final node in nodes) {
      if (!(deviceKindOf(node.type)?.ipConfig ?? false)) continue;
      final rows = [
        for (final a in addressing)
          if (a.node.toLowerCase() == node.name.toLowerCase()) a,
      ];
      final hasUsable = rows.any((a) {
        final ip = _ip(a.ipCidr);
        return _toInt(ip) != null && ip != '0.0.0.0';
      });
      if (hasUsable) continue;
      final subnet = _lanSubnetFor(node.name, nodes, links, addressing);
      if (subnet == null) continue;
      final host =
          _freeHostIn(subnet, used, from: 10) ?? _freeHostIn(subnet, used);
      if (host == null) continue;
      used.add(_ip(host));
      final iface = rows.isEmpty ? _endpointPort(node) : rows.first.iface;
      addressing = [
        for (final a in addressing)
          if (a.node.toLowerCase() != node.name.toLowerCase() ||
              a.iface.toLowerCase() != iface.toLowerCase())
            a,
        InterfaceAddr(node: node.name, iface: iface, ipCidr: host),
      ];
      changes.add(
        'gave ${node.name} $host so its Desktop > IP Configuration has an '
        'address instead of 0.0.0.0',
      );
      fixes.add(
        const RepairFix(
          'missing_ip_config',
          'Give every device that uses Desktop > IP Configuration an '
              'address on the LAN it is cabled to, instead of leaving it '
              'at 0.0.0.0.',
        ),
      );
    }

    // 4. One address, one interface: the later holder moves. This runs LAST,
    //    after the passes above have finished adding addresses.
    final taken = <String>{};
    for (var i = 0; i < addressing.length; i++) {
      final a = addressing[i];
      final ip = _ip(a.ipCidr);
      if (_toInt(ip) == null) continue;
      if (taken.add(ip)) continue;
      final isRouter = nodes.any(
        (n) => n.name == a.node && n.type == 'router',
      );
      final moved = _freeAddress(a, taken, router: isRouter);
      if (moved == null) continue;
      addressing[i] = InterfaceAddr(
        node: a.node,
        iface: a.iface,
        ipCidr: moved,
        ip6Cidr: a.ip6Cidr,
      );
      taken.add(_ip(moved));
      changes.add(
        'moved ${a.node} ${a.iface} off the shared address $ip to $moved',
      );
      fixes.add(
        const RepairFix(
          'duplicate_lan_address',
          'Give every interface its own address: when two interfaces claim '
              'one address, the later one takes a free host on the LAN it '
              'sits on.',
        ),
      );
    }

    final repaired = intent.copyWith(
      nodes: _repairAccountRows(intent, changes, fixes),
      links: links,
      addressing: addressing,
      security: _repairSecurity(intent, changes, fixes),
    );
    // The same gate the build card uses (`ValidationIssue.blocks`), so this
    // pass can never call a plan clean when the card still refuses it - or
    // report a finding as blocking when the build handles it itself.
    final remaining = ValidatorService.validate(repaired, target: target)
        .where((i) => i.blocks)
        .toList();
    return PlanRepair(
      plan: repaired,
      changes: changes,
      fixes: fixes,
      remaining: remaining,
    );
  }

  // --- credentials the findings ask for ------------------------------------

  /// Complete the account rows the brief half-specified.
  ///
  /// "aaa username admin password 123" leaves a server whose AAA rule names a
  /// user and no password, and the validator stops the build on it: the row
  /// "will not be submitted". The remedy used to tell the user to retype the
  /// same sentence, which changes nothing - the parser already read the name
  /// and it is the missing half it cannot know. Writing the placeholder that
  /// pairs with the name is the repair.
  static List<NetNode> _repairAccountRows(
    NetworkIntent intent,
    List<String> changes,
    List<RepairFix> fixes,
  ) {
    var touched = false;
    final out = <NetNode>[];
    for (final node in intent.nodes) {
      Map<String, dynamic>? rebuilt;
      for (final role in node.serviceRules.keys) {
        final raw = node.serviceRules[role];
        if (raw is! Map) continue;
        final users = raw['users'];
        if (users is! List || users.isEmpty) continue;
        final rows = <dynamic>[];
        for (final user in users) {
          if (user is! Map) {
            rows.add(user);
            continue;
          }
          final row = Map<String, dynamic>.from(user);
          final name = (row['username'] ?? '').toString().trim();
          final secret = (row['password'] ?? '').toString().trim();
          if (name.isEmpty && secret.isEmpty) {
            rows.add(row);
            continue;
          }
          if (name.isNotEmpty && secret.isNotEmpty) {
            rows.add(row);
            continue;
          }
          // One half is there, so the account was meant. Fill the other.
          row['username'] = name.isEmpty ? 'admin' : name;
          row['password'] = secret.isEmpty ? _placeholderPassword : secret;
          rows.add(row);
          touched = true;
          changes.add(
            'completed the ${role.toString().toUpperCase()} account on '
            '${node.name}: ${row['username']} / ${row['password']} '
            '(placeholder - change it before you rely on it)',
          );
        }
        rebuilt ??= Map<String, dynamic>.from(node.serviceRules);
        rebuilt[role] = {...Map<String, dynamic>.from(raw), 'users': rows};
      }
      if (rebuilt == null) {
        out.add(node);
        continue;
      }
      out.add(
        NetNode(
          name: node.name,
          type: node.type,
          model: node.model,
          mgmtIp: node.mgmtIp,
          services: node.services,
          serviceRules: rebuilt,
        ),
      );
    }
    if (!touched) return intent.nodes;
    fixes.add(
      const RepairFix(
        'account_row_incomplete',
        'An account the brief half-specified (a user and no password, or the '
            'other way round) will not be submitted: complete it with a '
            'placeholder and say so, rather than asking for the sentence that '
            'cannot finish it.',
      ),
    );
    return out;
  }

  /// Fill in the two lab credentials the brief leaves out, by request of the
  /// build that is trying to compile it.
  ///
  /// These two findings used to be a dead end. "Fix the plan" repaired cables
  /// and addresses but not these, so the answer was "each one needs a choice
  /// only you can make" - and the choice it offered, 'Add one - for example
  /// "AAA client name admin password 123"', did NOTHING when typed: no phrase
  /// in the parser turns that sentence into an account. The user pressed Fix
  /// again, and again, and the plan never changed.
  ///
  /// The remedy is to write the placeholder the app itself was suggesting, and
  /// to say so in the same breath - a placeholder credential in a Packet
  /// Tracer lab is not a secret, but an invented password that is never
  /// mentioned is worse than useless, so it is reported in `changes` like every
  /// other repair here.
  static SecurityIntent _repairSecurity(
    NetworkIntent intent,
    List<String> changes,
    List<RepairFix> fixes,
  ) {
    final security = intent.security;
    if (!security.aaa && !security.ipsecVpn) return security;

    var aaaUsername = security.aaaUsername;
    var aaaAccountPassword = security.aaaAccountPassword;
    var vpnKey = security.vpnPreSharedKey;
    var changed = false;

    if (security.aaa) {
      final server = intent.nodes
          .where((n) => n.name == security.aaaServer)
          .firstOrNull;
      final users = (server?.serviceRules['aaa'] as Map?)?['users'];
      final hasAccount = users is List && users.isNotEmpty;
      final hasCredential =
          (security.aaaUsername ?? '').isNotEmpty &&
          (security.aaaAccountPassword ?? '').isNotEmpty;
      if (!hasAccount && !hasCredential) {
        aaaUsername ??= 'admin';
        aaaAccountPassword ??= _placeholderPassword;
        changed = true;
        changes.add(
          'added the placeholder account $aaaUsername on '
          '${server?.name ?? 'the AAA server'} (password $aaaAccountPassword) '
          '- change it before you rely on it',
        );
        fixes.add(
          const RepairFix(
            'aaa_account_missing',
            'The AAA server holds no account, so no login can be verified: '
                'write a placeholder one and say so, rather than leaving a '
                'finding that only a sentence the parser does not read can '
                'clear.',
          ),
        );
      }
    }

    if (security.ipsecVpn && (vpnKey ?? '').isEmpty) {
      vpnKey = _placeholderKey;
      changed = true;
      changes.add(
        'added the placeholder IPsec pre-shared key "$vpnKey" - the tunnel can '
        'now establish; swap it for your own',
      );
      fixes.add(
        const RepairFix(
          'ipsec_psk_missing',
          'An IPSec tunnel with no pre-shared key is staged but cannot '
              'establish: write the documented lab default and report it, '
              'instead of asking for a key the parser has no wording for.',
        ),
      );
    }

    if (!changed) return security;
    return security.copyWith(
      aaaUsername: aaaUsername,
      aaaAccountPassword: aaaAccountPassword,
      vpnPreSharedKey: vpnKey,
    );
  }

  static const String _placeholderPassword = 'cisco123';
  static const String _placeholderKey = 'cisco123';

  // --- cabling ------------------------------------------------------------
  /// A free port that can reach [node]: a switch port while one is available,
  /// otherwise a spare routed port on a router (a two-router plan with no
  /// switch still has somewhere to plug a PC).
  static (String, String)? _cableablePort(
    NetNode node,
    List<NetNode> nodes,
    List<NetLink> links,
  ) {
    for (final switchNode in nodes.where((n) => n.type == 'switch')) {
      final used = _usedPorts(switchNode.name, links);
      final capacity = NetworkIntent.switchPortCapacity(switchNode.model);
      for (var port = 1; port <= capacity; port++) {
        final name = 'f0/$port';
        if (!used.contains(name)) return (switchNode.name, name);
      }
    }
    for (final router in nodes.where((n) => n.type == 'router')) {
      if (router.name == node.name) continue;
      final used = _usedPorts(router.name, links);
      final prefix = _gigRouters.contains(router.model?.trim() ?? '') ? 'g' : 'f';
      for (var port = 0; port <= 3; port++) {
        final name = '${prefix}0/$port';
        if (!used.contains(name)) return (router.name, name);
      }
    }
    return null;
  }

  /// The port of [device] this link lands on, or null when it is not an end.
  static String? _portOn(NetLink link, String device) {
    if (link.a == device) return link.aIf;
    if (link.b == device) return link.bIf;
    return null;
  }

  /// The same link with [device]'s end moved to [port].
  ///
  /// [toDevice] renames that end as well: an over-full switch's overflow cable
  /// moves the SWITCH side onto another switch, while the PC keeps its port.
  static NetLink? _withPort(
    NetLink link,
    String device,
    String port, {
    String? toDevice,
  }) {
    final name = toDevice ?? device;
    if (link.a == device) {
      return NetLink(
        a: name,
        aIf: port,
        b: link.b,
        bIf: link.bIf,
        cable: link.cable,
        dce: link.dce,
      );
    }
    if (link.b == device) {
      return NetLink(
        a: link.a,
        aIf: link.aIf,
        b: name,
        bIf: port,
        cable: link.cable,
        dce: link.dce,
      );
    }
    return null;
  }

  /// A free interface on [device], skipping everything in [taken].
  ///
  /// [links] is the plan the ports are counted from, so a port another cable
  /// already claims is never handed out twice.
  static String? _freePortOn(
    NetNode node,
    Set<String> taken, {
    List<NetLink> links = const [],
  }) {
    final claimed = {
      for (final p in taken) p.toLowerCase(),
      for (final l in links)
        if (_portOn(l, node.name) != null)
          _portOn(l, node.name)!.toLowerCase(),
    };
    bool free(String p) => p.isNotEmpty && !claimed.contains(p.toLowerCase());
    if (node.type == 'switch') {
      final ports = NetworkIntent.switchPortCapacity(node.model);
      for (var p = 1; p <= ports; p++) {
        if (free('f0/$p')) return 'f0/$p';
      }
      return null;
    }
    final gig = _gigRouters.contains(node.model?.trim() ?? '');
    for (var p = 0; p <= 3; p++) {
      if (free('${gig ? 'g' : 'f'}0/$p')) return '${gig ? 'g' : 'f'}0/$p';
    }
    // A router's second bank is how the planner keeps a second WAN apart.
    for (var p = 0; p <= 3; p++) {
      if (free('g1/$p')) return 'g1/$p';
    }
    return null;
  }

  /// True when [cidr] is a host address inside [subnet].
  static bool _inSubnet(String cidr, String subnet) {
    final prefix = _prefix(subnet);
    final net = _toInt(_ip(subnet));
    final host = _toInt(_ip(cidr));
    if (prefix == null || net == null || host == null) return false;
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (host & mask) == (net & mask);
  }

  static Set<String> _usedPorts(String nodeName, List<NetLink> links) {
    final out = <String>{};
    for (final l in links) {
      if (l.a == nodeName) out.add(l.aIf.toLowerCase());
      if (l.b == nodeName) out.add(l.bIf.toLowerCase());
    }
    return out;
  }

  static String _endpointPort(NetNode node) {
    final kind = deviceKindOf(node.type);
    return (kind != null && kind.port.isNotEmpty) ? kind.port : 'f0';
  }

  /// The subnet the device is plugged into: an already-addressed neighbour on
  /// its switch, the router uplink feeding that switch, or the router port it
  /// is cabled to directly.
  static String? _lanSubnetFor(
    String name,
    List<NetNode> nodes,
    List<NetLink> links,
    List<InterfaceAddr> addressing,
  ) {
    String? typeOf(String node) {
      for (final n in nodes) {
        if (n.name == node) return n.type;
      }
      return null;
    }

    String? addressOn(String node, String iface) {
      for (final a in addressing) {
        if (a.node == node && a.iface.toLowerCase() == iface.toLowerCase()) {
          return a.ipCidr;
        }
      }
      return null;
    }

    for (final l in links) {
      final peer = l.a == name ? l.b : (l.b == name ? l.a : null);
      if (peer == null) continue;
      final peerType = typeOf(peer);
      if (peerType == 'router') {
        final cidr = addressOn(peer, l.a == name ? l.bIf : l.aIf);
        if (cidr != null && _ip(cidr) != '0.0.0.0') return cidr;
        continue;
      }
      if (peerType != 'switch') continue;
      // Another device already on this switch tells us its LAN.
      for (final other in links) {
        final isSwitchEnd = other.a == peer || other.b == peer;
        if (!isSwitchEnd) continue;
        final otherName = other.a == peer ? other.b : other.a;
        if (otherName == name) continue;
        if (typeOf(otherName) == 'router') {
          continue; // handled below, through the router's own address
        }
        for (final a in addressing) {
          if (a.node == otherName && _toInt(_ip(a.ipCidr)) != null) {
            if (_ip(a.ipCidr) != '0.0.0.0') return a.ipCidr;
          }
        }
      }
      // The router feeding this switch.
      for (final other in links) {
        if (other.a != peer && other.b != peer) continue;
        final otherName = other.a == peer ? other.b : other.a;
        if (typeOf(otherName) != 'router') continue;
        final cidr = addressOn(otherName, other.a == peer ? other.bIf : other.aIf);
        if (cidr != null && _ip(cidr) != '0.0.0.0') return cidr;
      }
    }
    return null;
  }

  // --- addresses ----------------------------------------------------------

  static String _ip(String cidr) => cidr.split('/').first.trim();

  static int? _prefix(String cidr) {
    final slash = cidr.indexOf('/');
    if (slash < 0) return null;
    final p = int.tryParse(cidr.substring(slash + 1).trim());
    return p != null && p >= 0 && p <= 32 ? p : null;
  }

  static int? _toInt(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      value = (value << 8) | n;
    }
    return value;
  }

  static String _fromInt(int value) =>
      '${(value >> 24) & 255}.${(value >> 16) & 255}.${(value >> 8) & 255}.'
      '${value & 255}';

  /// The lowest free host in [cidr] (starting from [from], then from the top
  /// of the range), or null when the subnet has no free host left.
  static String? _freeHostIn(String cidr, Set<String> used, {int from = 1}) {
    final prefix = _prefix(cidr);
    final address = _toInt(_ip(cidr));
    if (prefix == null || address == null) return null;
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final network = address & mask;
    final maxHost = prefix >= 31 ? 0 : (1 << (32 - prefix)) - 2;
    if (maxHost < 1) return null;
    for (var pass = 0; pass < 2; pass++) {
      for (var h = pass == 0 ? from : 1; h <= maxHost; h++) {
        final candidate = _fromInt(network + h);
        if (!used.contains(candidate)) return '$candidate/$prefix';
      }
    }
    return null;
  }

  /// A replacement address for an interface whose address is taken: a free
  /// host on its own subnet, else the next free /24 in the same block.
  static String? _freeAddress(
    InterfaceAddr row,
    Set<String> used, {
    required bool router,
  }) {
    final cidr = row.ipCidr.trim();
    final ip = _ip(cidr);
    final host = _toInt(ip);
    final sameSubnet = _freeHostIn(
      cidr,
      used,
      from: host == null ? 1 : (host & 0xff) + 1,
    );
    if (sameSubnet != null) return sameSubnet;
    final octets = ip.split('.');
    if (octets.length != 4) return null;
    final first = int.tryParse(octets[0]);
    final second = int.tryParse(octets[1]);
    final thirdStart = int.tryParse(octets[2]);
    if (first == null || second == null || thirdStart == null) return null;
    var third = thirdStart;
    for (var i = 1; i < 254; i++) {
      third = (third + 1) % 255;
      final prefix = '$first.$second.$third.';
      if (used.any((u) => u.startsWith(prefix))) continue;
      final host = router ? 1 : 10;
      return '$prefix$host/24';
    }
    return null;
  }
}
