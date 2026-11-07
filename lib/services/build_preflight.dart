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

    // THE SAVED CABLES. Ports and counts agreeing still leaves one hole: a
    // cable that was never written, or one written between the wrong pair
    // of ports, reads in the generator's report as a port that was "used".
    // The audit reads the LINK blocks back out of the save, so the plan's
    // cables are compared against the file's actual cables - endpoints
    // normalized (Cisco shorthand vs the full save name), pair order
    // ignored. Link data is only comparable when the audit explicitly says
    // what it counted: rows present, or a linkCount/summary that answers
    // zero. An empty list with no count is the OLD audits' "no link data"
    // shape and keeps the ports-based verdict plus the honest note.
    final savedRows = [
      for (final row in (audit['links'] as List?) ?? const [])
        if (row is Map)
          (
            a: '${row['a'] ?? ''}'.trim(),
            aIf: '${row['aIf'] ?? ''}'.trim(),
            b: '${row['b'] ?? ''}'.trim(),
            bIf: '${row['bIf'] ?? ''}'.trim(),
          ),
    ];
    final declaredLinkCount =
        (audit['linkCount'] as num?)?.toInt() ??
        (audit['summary'] is Map
            ? ((audit['summary'] as Map)['links'] as num?)?.toInt()
            : null);
    final linksComparable =
        savedRows.isNotEmpty ||
        (declaredLinkCount != null && declaredLinkCount == 0);
    String pairKey(String devA, String ifA, String devB, String ifB) {
      final left = '${devA.toLowerCase()}|${_canonIface(ifA)}';
      final right = '${devB.toLowerCase()}|${_canonIface(ifB)}';
      return left.compareTo(right) <= 0 ? '$left<->$right' : '$right<->$left';
    }

    final savedCables = <String>{
      for (final row in savedRows)
        if (row.a.isNotEmpty && row.b.isNotEmpty)
          pairKey(row.a, row.aIf, row.b, row.bIf),
    };
    final plannedCables = <String>{
      for (final l in intent.links)
        pairKey(l.a, resolvePort(l.a, l.aIf), l.b, resolvePort(l.b, l.bIf)),
    };
    final cablesMissing = plannedCables.difference(savedCables).toList()
      ..sort();
    final cablesUnexpected = savedCables.difference(plannedCables).toList()
      ..sort();
    if (linksComparable &&
        (cablesMissing.isNotEmpty || cablesUnexpected.isNotEmpty)) {
      semantic.add(
        'the saved cables do not match the plan: '
        '${cablesMissing.isEmpty ? '' : 'missing ${_cap(cablesMissing)}'}'
        '${cablesMissing.isNotEmpty && cablesUnexpected.isNotEmpty ? '; ' : ''}'
        '${cablesUnexpected.isEmpty ? '' : 'in the file but not planned: ${_cap(cablesUnexpected)}'}',
      );
    }

    if (missing.isEmpty &&
        extra.isEmpty &&
        unbuilt.isEmpty &&
        doubled.isEmpty &&
        addressGaps.isEmpty &&
        leftovers.isEmpty &&
        semantic.isEmpty) {
      final links = linksComparable
          ? '${savedCables.length} cable(s) verified against the saved file'
          : linksChecked
          ? '${intent.links.length} link(s) verified against the ports '
                'the generator wrote'
          : 'links not compared - the audit carries no link data and no '
                'generator report was collected';
      final compared = intent.addressing.length - addressesNotComparable;
      final addresses = intent.addressing.isEmpty
          ? ''
          : '; $compared address(es) verified against the saved ports'
                '${addressesNotComparable > 0 ? ' ($addressesNotComparable not comparable - no interface rows for that device)' : ''}';
      return (
        verified: linksComparable || intent.links.isEmpty,
        lines: [
          '- Verification: ${linksComparable || intent.links.isEmpty ? 'the file agrees with the plan' : 'unverified - saved cable evidence was not collected'} '
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

  /// The generator's own export status for the file it just wrote.
  ///
  /// A build can end with a file on disk and still not be the lab the plan
  /// asked for: an unsupported model is dropped or substituted, a requested
  /// port does not exist, or the caller explicitly allowed an incomplete
  /// export. The generator reports all of that structurally (`status`,
  /// `missingDevices`, `missingLinks`, `modelSubstitutions`,
  /// `interfaceRemappings`, `verification`) and the build message used to
  /// drop it on the floor - so a partial file read as a success. Printing it
  /// here, next to the counts it qualifies, is the fix.
  static List<String> exportStatus(Map<String, dynamic> report) {
    if (report.isEmpty) return const <String>[];
    final status = '${report['status'] ?? ''}'.trim().toUpperCase();
    final written = _intOf(report['deviceCount']);
    final planned = _intOf(report['plannedDevices']);
    final cables = _intOf(report['linkCount']);
    final plannedCables = _intOf(report['plannedLinks']);
    final counts = planned != null && plannedCables != null
        ? '${written ?? '?'}/$planned device(s), '
              '${cables ?? '?'}/$plannedCables cable(s) written'
        : '${written ?? '?'} device(s), ${cables ?? '?'} cable(s) written';
    final complete =
        report['complete'] == true ||
        status == 'VALID' ||
        status == 'VALID_WITH_WARNINGS';
    final lines = <String>[];
    if (status.isEmpty) {
      lines.add(
        '- Export status: not reported - the generator did not say whether '
        'every planned device and cable was written ($counts).',
      );
    } else if (complete) {
      lines.add(
        '- Export status: $status - every planned device and cable is in the '
        'file ($counts).',
      );
    } else {
      lines.add(
        '- Export status: $status - **the file is not the plan** ($counts).',
      );
    }
    final missingDevices = _deviceEntries(report['missingDevices']);
    if (missingDevices.isNotEmpty) {
      lines.add('    - missing devices: ${_cap(missingDevices)}');
    }
    final missingLinks = _linkEntries(report['missingLinks']);
    if (missingLinks.isNotEmpty) {
      lines.add('    - missing cables: ${_cap(missingLinks)}');
    }
    final substitutions = _remapEntries(report['modelSubstitutions']);
    if (substitutions.isNotEmpty) {
      lines.add(
        '    - model substitutions: ${_cap(substitutions)} - these devices are '
        'in the file as a different model from the one the plan named',
      );
    }
    final remaps = _remapEntries(report['interfaceRemappings']);
    if (remaps.isNotEmpty) {
      lines.add(
        '    - interface remaps: ${_cap(remaps)} - the plan asked for a port '
        'the device does not have, so the cable went to a different one',
      );
    }
    final verification = report['verification'];
    if (verification is Map && verification.isNotEmpty) {
      final onDisk = _intOf(verification['deviceCountOnDisk']);
      final cablesOnDisk = _intOf(verification['linkCountOnDisk']);
      lines.add(
        verification['ok'] == true
            ? '    - read back from disk: ${onDisk ?? '?'} device(s), '
                  '${cablesOnDisk ?? '?'} cable(s) - matches the build.'
            : '    - read back from disk did NOT match the build: '
                  '${onDisk ?? '?'} device(s), ${cablesOnDisk ?? '?'} cable(s) '
                  '- do not trust this file.',
      );
    }
    return lines;
  }

  static int? _intOf(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}'.trim());

  static List<String> _deviceEntries(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    for (final entry in raw) {
      if (entry is Map) {
        final name = '${entry['name'] ?? '?'}'.trim();
        final reason = '${entry['reason'] ?? ''}'.trim();
        out.add(reason.isEmpty ? name : '$name ($reason)');
      } else if ('$entry'.trim().isNotEmpty) {
        out.add('$entry'.trim());
      }
    }
    return out;
  }

  static List<String> _linkEntries(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    for (final entry in raw) {
      if (entry is Map) {
        out.add('${entry['a'] ?? '?'}-${entry['b'] ?? '?'}');
      } else if ('$entry'.trim().isNotEmpty) {
        out.add('$entry'.trim());
      }
    }
    return out;
  }

  static List<String> _remapEntries(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    for (final entry in raw) {
      if (entry is Map) {
        out.add(
          '${entry['device'] ?? '?'}: '
          '${entry['requested'] ?? '?'} -> ${entry['used'] ?? '?'}',
        );
      } else if ('$entry'.trim().isNotEmpty) {
        out.add('$entry'.trim());
      }
    }
    return out;
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
