import '../models/network_intent.dart';

/// What a build says for itself: a concise preflight before compiling, and a
/// plan-vs-file comparison from the audit afterwards.
///
/// Two rules keep this honest, in the spirit of the rest of the app:
///
/// * every preflight line states something that was actually checked (the
///   validator already ran and passed - this class does not re-do it), never
///   a promise about the simulator;
/// * the comparison reports "agrees" only when an audit of the written file
///   was actually collected. No audit means "unverified", said in those
///   words - not silence.
class BuildPreflight {
  const BuildPreflight._();

  /// Concise preflight lines for compiling [plan] for [target].
  ///
  /// The caller has already blocked on validator findings, so the summary
  /// here covers: what is being built, where, and what the plan still
  /// carries open (assumptions and questions raised by the parser or the
  /// user's own wording).
  static List<String> lines({
    required NetworkIntent intent,
    required String target,
  }) {
    final lines = <String>[
      '- Target: ${targetName(target)} - offline compile; no Packet Tracer '
          'window is opened and nothing is typed anywhere.',
      '- Plan: ${describeDevices(intent)}; routing ${intent.routing}; '
          '${intent.links.length} link(s).',
    ];
    final assumptions = intent.assumptions
        .where((a) => a.trim().isNotEmpty)
        .toList();
    if (assumptions.isNotEmpty) {
      final shown = assumptions.take(3).join(' ');
      lines.add(
        '- Open assumptions (${assumptions.length}): $shown'
        '${assumptions.length > 3 ? ' (and ${assumptions.length - 3} more)' : ''}',
      );
    }
    final questions = intent.questions
        .where((q) => q.trim().isNotEmpty)
        .toList();
    if (questions.isNotEmpty) {
      lines.add(
        '- Open questions (${questions.length}): ${questions.first}'
        '${questions.length > 1 ? ' (and ${questions.length - 1} more)' : ''}',
      );
    }
    return lines;
  }

  /// The plan-vs-file comparison, from an audit that was really collected.
  ///
  /// [audit] is the engine's `/pkt/audit` result for the file that was just
  /// written; devices are compared by name. [builtDevices] is the generator's
  /// own record of what it wrote (`/pkt/generate` -> `devices`), which is what
  /// the links are checked against.
  ///
  /// The offline audit reads devices and their interfaces and carries NO link
  /// list, so the older pair-comparison against a missing key reported every
  /// planned link as "not found in the file" - on files that contained all of
  /// them. A check that cries wolf on every build is worse than no check, so
  /// links are verified by the ports that were really written.
  static ({bool verified, List<String> lines}) compare({
    required NetworkIntent intent,
    required Map<String, dynamic> audit,
    List<dynamic> builtDevices = const [],
  }) {
    final devices = audit['devices'];
    if (devices is! List) {
      return (
        verified: false,
        lines: const [
          '- Verification: not collected - the file was written but could not '
              'be audited, so the plan-vs-file match is unverified.',
        ],
      );
    }
    final plannedNames = {for (final n in intent.nodes) n.name.trim()};
    final foundNames = {
      for (final d in devices)
        if (d is Map) '${d['name'] ?? ''}'.trim(),
    }..remove('');
    final missing = plannedNames.difference(foundNames).toList()..sort();
    final extra = foundNames.difference(plannedNames).toList()..sort();

    // The ports the generator wrote, per device: {device: {planIf: realPort}}.
    final builtPorts = <String, Map<String, String>>{};
    for (final device in builtDevices) {
      if (device is! Map) continue;
      final ports = device['ports'];
      if (ports is! Map) continue;
      final name = '${device['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      builtPorts[name] = {
        for (final entry in ports.entries)
          '${entry.key}'.trim(): '${entry.value}'.trim(),
      };
    }

    // Link check 1: every endpoint the plan names must be an interface the
    // device really has.  Link check 2: one interface, one cable - the second
    // cable is the one Packet Tracer will not load, and the second `interface`
    // block in the config silently overwrites the first.
    final unbuilt = <String>[];
    final cabled = <String, int>{};
    for (final link in intent.links) {
      for (final endpoint in [
        (device: link.a, iface: link.aIf),
        (device: link.b, iface: link.bIf),
      ]) {
        final device = endpoint.device.trim();
        final port = builtPorts[device]?[endpoint.iface.trim()];
        if (port == null || port.isEmpty) {
          unbuilt.add('$device:${endpoint.iface}');
          continue;
        }
        final key = '$device:$port';
        cabled[key] = (cabled[key] ?? 0) + 1;
      }
    }
    final doubled = [
      for (final entry in cabled.entries)
        if (entry.value > 1) entry.key,
    ]..sort();
    final linksChecked = builtPorts.isNotEmpty;

    // ADDRESSING. Names, ports and cables can all agree and the file can
    // still carry a network that does not route: a gateway address the
    // template never received, an IP that landed on the wrong port after a
    // remap, or a template's stale address nobody asked for. The audit's
    // per-port saved IPs are the evidence; the generator's port table
    // translates a plan interface to the real port it landed on, so a
    // remapped cable is compared on the port that exists, not the one that
    // was requested.
    final auditRows = <String, List<({String name, String ip})>>{};
    for (final d in devices) {
      if (d is! Map) continue;
      final name = '${d['name'] ?? ''}'.trim();
      final rows = d['interfaces'];
      if (name.isEmpty || rows is! List) continue;
      auditRows[name.toLowerCase()] = [
        for (final row in rows)
          if (row is Map)
            (
              name: '${row['name'] ?? ''}'.trim(),
              ip: '${row['ip'] ?? ''}'.trim(),
            ),
      ];
    }
    final builtPortsLower = {
      for (final entry in builtPorts.entries)
        entry.key.toLowerCase(): entry.value,
    };
    String resolvePort(String device, String iface) =>
        builtPortsLower[device.toLowerCase()]?[iface.trim()] ?? iface.trim();

    final addressGaps = <String>[];
    final covered = <String, Set<String>>{}; // deviceLower -> canon ports
    var addressesNotComparable = 0;
    for (final a in intent.addressing) {
      final device = a.node.trim();
      final rows = auditRows[device.toLowerCase()];
      if (rows == null) continue; // the device itself is already reported
      if (rows.isEmpty) {
        // The audit could not read this device's interfaces at all (a host
        // panel, a model the reader does not cover): say so, do not fail the
        // build over evidence nobody collected.
        addressesNotComparable++;
        continue;
      }
      final wanted = a.ipCidr.split('/').first.trim();
      final port = resolvePort(device, a.iface);
      final row = _findByPort(rows, port);
      (covered[device.toLowerCase()] ??= <String>{}).add(
        _canonIface(row?.name ?? port),
      );
      if (row == null) {
        addressGaps.add(
          '$device: the file has no interface for ${a.iface}, which the plan '
          'assigns ${a.ipCidr}',
        );
      } else if (row.ip.isEmpty || row.ip.toLowerCase() == 'unassigned') {
        addressGaps.add(
          '$device ${a.iface} is unconfigured in the file; the plan assigns '
          '${a.ipCidr}',
        );
      } else if (row.ip.toLowerCase() != wanted.toLowerCase()) {
        addressGaps.add(
          '$device ${a.iface} carries ${row.ip} in the file; the plan assigns '
          '${a.ipCidr}',
        );
      }
    }
    // The other direction: a planned device carrying a saved address the plan
    // never assigned is template leftovers - exactly the state the builder
    // promises to clear, so it is a defect, not a bonus.
    final leftovers = <String>[];
    for (final entry in auditRows.entries) {
      final planned = intent.nodes
          .where((n) => n.name.trim().toLowerCase() == entry.key)
          .firstOrNull;
      if (planned == null) continue; // extra devices are reported above
      for (final row in entry.value) {
        if (row.ip.isEmpty || row.ip.toLowerCase() == 'unassigned') continue;
        final coveredPorts = covered[entry.key] ?? const <String>{};
        if (coveredPorts.contains(_canonIface(row.name))) continue;
        leftovers.add('${planned.name} ${row.name} = ${row.ip}');
      }
    }

    // THE SEMANTIC HALF. Everything above asks "is this the lab we asked
    // for?". That is not the same question as "is this a working lab": a file
    // can match its plan name-for-name and port-for-port and still carry a
    // duplicate address, a device wired to nothing, or a service role the
    // plan called for that the file never enabled. Those are exactly the
    // defect classes PlanRepairService fixes, so a file that has them is not
    // verified - otherwise a .pkt can come back clean holding the very defect
    // the repair pass was supposed to eliminate.
    final semantic = <String>[];
    final auditedFindings = audit['findings'];
    if (auditedFindings is List) {
      semantic.addAll(auditedFindings.map((f) => '$f'));
    }
    // A service the plan gave a role but the file never enabled. The audit
    // reports services per device, so this is checked device by device.
    final servicesByName = <String, Set<String>>{};
    for (final d in devices) {
      if (d is! Map) continue;
      final name = '${d['name'] ?? ''}'.trim();
      final svcs = d['services'];
      if (name.isEmpty || svcs is! List) continue;
      servicesByName[name] = svcs
          .map<String>((e) => '$e'.toLowerCase())
          .toSet();
    }
    final roleGaps = <String>[];
    for (final n in intent.nodes) {
      if (n.services.isEmpty) continue;
      final have = servicesByName[n.name.trim()];
      if (have == null) continue; // device not in the file: reported above
      final absent = n.services
          .map((s) => s.toLowerCase())
          .where((s) => !have.contains(s))
          .toList();
      if (absent.isNotEmpty) {
        roleGaps.add('${n.name} is missing ${absent.join(', ')}');
      }
    }
    semantic.addAll(roleGaps);

    if (missing.isEmpty &&
        extra.isEmpty &&
        unbuilt.isEmpty &&
        doubled.isEmpty &&
        addressGaps.isEmpty &&
        leftovers.isEmpty &&
        semantic.isEmpty) {
      final links = linksChecked
          ? '${intent.links.length} link(s) verified against the ports the '
                'generator wrote'
          : 'links not compared - the audit carries no link data and no '
                'generator report was collected';
      final compared = intent.addressing.length - addressesNotComparable;
      final addresses = intent.addressing.isEmpty
          ? ''
          : '; $compared address(es) verified against the saved ports'
                '${addressesNotComparable > 0 ? ' ($addressesNotComparable not comparable - no interface rows for that device)' : ''}';
      return (
        verified: true,
        lines: [
          '- Verification: the file agrees with the plan '
              '(${foundNames.length} device(s); $links$addresses).',
        ],
      );
    }
    final out = <String>[
      '- Verification found differences between the plan and the file:',
    ];
    if (missing.isNotEmpty) {
      out.add('    - missing from the file: ${_cap(missing)}');
    }
    if (extra.isNotEmpty) {
      out.add('    - in the file but not in the plan: ${_cap(extra)}');
    }
    if (unbuilt.isNotEmpty) {
      out.add(
        '    - the file has no interface for: ${_cap(unbuilt.toSet().toList()..sort())}',
      );
    }
    if (doubled.isNotEmpty) {
      out.add(
        '    - one interface carries more than one cable: '
        '${_cap(doubled)} - Packet Tracer cannot load a second cable on '
        'a port, and the extra interface config overwrites the first',
      );
    }
    if (addressGaps.isNotEmpty) {
      out.add(
        '    - the saved addresses do not match the plan: '
        '${_cap(addressGaps)}',
      );
    }
    if (leftovers.isNotEmpty) {
      out.add(
        '    - the file carries addresses the plan never assigned '
        '(template leftovers): ${_cap(leftovers)}',
      );
    }
    if (semantic.isNotEmpty) {
      out.add(
        '    - the file matches the plan but is not a working lab: '
        '${_cap(_sortedCopy(semantic))}',
      );
      out.add(
        '    - these are the same defect classes the repair pass fixes '
        '(duplicate address, uncabled device, missing service role), so a '
        'clean name-for-name match is not a clean build',
      );
    }
    if (!linksChecked) {
      out.add(
        '    - the links were not compared: the audit carries no link data and '
        'no generator report was collected',
      );
    }
    out.add(
      '    - Do not trust the file until this is resolved: rebuild, or '
      'analyze the file and inspect the differences.',
    );
    return (verified: false, lines: out);
  }

  /// "6 devices (2 routers, 2 switches, 2 PCs)" - a compact, truthful plan
  /// summary; anything beyond the common kinds is counted as "other".
  static String describeDevices(NetworkIntent plan) {
    final total = plan.nodes.length;
    final counts = <String, int>{};
    for (final n in plan.nodes) {
      counts[n.type] = (counts[n.type] ?? 0) + 1;
    }
    const names = {
      'router': 'routers',
      'switch': 'switches',
      'pc': 'PCs',
      'server': 'servers',
      'phone': 'phones',
      'wireless': 'APs',
      'firewall': 'firewalls',
      'cloud': 'clouds',
      'modem': 'modems',
    };
    final parts = <String>[];
    var other = 0;
    counts.forEach((type, n) {
      final name = names[type];
      if (name == null) {
        other += n;
      } else {
        parts.add('$n $name');
      }
    });
    if (other > 0) parts.add('$other other device(s)');
    return '$total device(s)${parts.isEmpty ? '' : ' (${parts.join(', ')})'}';
  }

  /// The friendly name of a build target.
  static String targetName(String target) {
    switch (target.trim().toLowerCase()) {
      case 'pt':
      case 'packet-tracer':
      case 'packettracer':
        return 'Packet Tracer';
      case 'gns3':
        return 'GNS3';
      default:
        return target.trim().isEmpty ? 'the default target' : target.trim();
    }
  }

  static List<String> _sortedCopy(List<String> items) => items.toList()..sort();

  static String _cap(List<String> items, [int n = 8]) => items.length <= n
      ? items.join(', ')
      : '${items.take(n).join(', ')}... (+${items.length - n} more)';

  /// The row whose port matches [port], comparing names the way Cisco
  /// abbreviates them: the plan says `g0/0`, the save says
  /// `GigabitEthernet0/0`, and both must read as the same interface.
  static ({String name, String ip})? _findByPort(
    List<({String name, String ip})> rows,
    String port,
  ) {
    final wanted = _canonIface(port);
    for (final row in rows) {
      if (_canonIface(row.name) == wanted) return row;
    }
    return null;
  }

  /// Canonical interface name: `FastEthernet0/1`, `fa0/1` and `f0/1` all
  /// become `f0/1`, so a plan written in shorthand compares against a save
  /// written in full. Dot1Q sub-interfaces keep their `.10` suffix.
  static String _canonIface(String raw) {
    var s = raw.trim().toLowerCase();
    s = s.replaceFirst(RegExp(r'^(?:gigabitethernet|gi)(?=[\d/])'), 'g');
    s = s.replaceFirst(RegExp(r'^(?:fastethernet|fa)(?=[\d/])'), 'f');
    s = s.replaceFirst(RegExp(r'^(?:serial|se)(?=[\d/])'), 's');
    s = s.replaceFirst(RegExp(r'^(?:ethernet|eth)(?=[\d/])'), 'e');
    return s;
  }
}
