import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/build_preflight.dart';

/// The offline verification has two halves, and only one of them used to
/// exist.
///
/// The STRUCTURAL half asks "is this file the lab we asked for?" - right
/// names, right ports, one cable per interface. That is necessary and it is
/// not sufficient.
///
/// The SEMANTIC half asks "is this a working lab?" - no address claimed twice,
/// no device wired to nothing, no service role the plan asked for that the
/// file never enabled. Those are the defect classes PlanRepairService fixes,
/// so without this half a .pkt can come back verified:true holding the very
/// defect the repair pass was supposed to eliminate - and the repair-learning
/// loop then promotes a rule on the strength of a file that is still broken.
///
/// These tests drive BuildPreflight.compare directly, because that is the
/// public seam where the two halves meet.
void main() {
  // A plan with a server that has a role, and no links - so every structural
  // check passes and only the semantic half can fail the build.
  final plan = NetworkIntent.parseSimple('sem', '2 routers and a dns server');

  List<dynamic> builtPorts() {
    final ports = <String, Map<String, String>>{};
    for (final l in plan.links) {
      for (final pair in [(l.a, l.aIf), (l.b, l.bIf)]) {
        final device = pair.$1;
        ports.putIfAbsent(device, () => <String, String>{});
        ports[device]![pair.$2] = 'port${ports[device]!.length}';
      }
    }
    return [
      for (final e in ports.entries) {'name': e.key, 'ports': e.value},
    ];
  }

  /// An audit whose devices match the plan exactly, so the structural half
  /// has nothing to complain about.
  Map<String, dynamic> cleanAudit({
    Map<String, List<String>>? services,
    List<String> findings = const [],
  }) {
    // A sound file enables exactly the services the plan gave each device.
    final svcs = services ?? {for (final n in plan.nodes) n.name: n.services};
    return {
      'devices': [
        for (final n in plan.nodes)
          {'name': n.name, 'type': n.type, 'services': svcs[n.name] ?? []},
      ],
      'linkCount': plan.links.length,
      'links': [
        for (final l in plan.links)
          {
            'a': l.a,
            'aIf': builtPorts().cast<Map>().firstWhere(
              (d) => d['name'] == l.a,
            )['ports'][l.aIf],
            'b': l.b,
            'bIf': builtPorts().cast<Map>().firstWhere(
              (d) => d['name'] == l.b,
            )['ports'][l.bIf],
          },
      ],
      'findings': findings,
    };
  }

  /// The generator's own report: every interface the plan names mapped to a
  /// real port. This is what the structural half compares against, so
  /// supplying it isolates the semantic half instead of letting "no interface
  /// for R1:g0/0" mask the finding under test.
  test('a file that matches the plan and is sound verifies', () {
    final r = BuildPreflight.compare(
      intent: plan,
      audit: cleanAudit(),
      builtDevices: builtPorts(),
    );
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
  });

  test('an uncabled or duplicate-address finding fails the build', () {
    final r = BuildPreflight.compare(
      intent: plan,
      builtDevices: builtPorts(),
      audit: cleanAudit(
        findings: const [
          'duplicate_interface_address: 10.0.0.1 is claimed by both R1 and R2',
        ],
      ),
    );
    expect(r.verified, isFalse);
    final text = r.lines.join('\n');
    expect(text, contains('not a working lab'));
    // The finding must reach the user verbatim, not a summary of it.
    expect(text, contains('duplicate_interface_address'));
    expect(text, contains('10.0.0.1'));
  });

  test('a device wired to nothing fails the build', () {
    final r = BuildPreflight.compare(
      intent: plan,
      builtDevices: builtPorts(),
      audit: cleanAudit(
        findings: const ['uncabled_device: R2, S1 carry no cable'],
      ),
    );
    expect(r.verified, isFalse);
    expect(r.lines.join('\n'), contains('uncabled_device'));
  });

  test(
    'a service role the plan asked for and the file lacks fails the build',
    () {
      // The plan gave its server 'dns'; the file enabled nothing.
      final server = plan.nodes.firstWhere((n) => n.type == 'server');
      expect(
        server.services,
        isNotEmpty,
        reason: 'the brief must give the server a role for this to test',
      );

      final r = BuildPreflight.compare(
        intent: plan,
        builtDevices: builtPorts(),
        audit: cleanAudit(
          services: {for (final n in plan.nodes) n.name: <String>[]},
        ), // every device reports zero services
      );
      expect(r.verified, isFalse);
      final text = r.lines.join('\n');
      expect(text, contains('not a working lab'));
      expect(text, contains(server.name));
      expect(
        text.toLowerCase(),
        contains(server.services.first.toLowerCase()),
        reason: 'the user must be told which role is missing',
      );
    },
  );

  test('a service the file DID enable is not reported missing', () {
    final server = plan.nodes.firstWhere((n) => n.type == 'server');
    final r = BuildPreflight.compare(
      intent: plan,
      builtDevices: builtPorts(),
      audit: cleanAudit(
        services: {
          for (final n in plan.nodes)
            n.name: n.type == 'server' ? server.services : [],
        },
      ),
    );
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
  });

  test('an audit that carries no findings key still verifies structurally', () {
    // Older audit shapes have no 'findings'. They must not crash, and must
    // not be treated as "findings were checked and were clean" - they are
    // simply silent, so a sound file still verifies.
    final audit = cleanAudit()..remove('findings');
    final r = BuildPreflight.compare(
      intent: plan,
      audit: audit,
      builtDevices: builtPorts(),
    );
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
  });

  test(
    'a device missing from the file is still caught by the structural half',
    () {
      final audit = cleanAudit();
      (audit['devices'] as List).removeLast();
      final r = BuildPreflight.compare(
        intent: plan,
        audit: audit,
        builtDevices: builtPorts(),
      );
      expect(r.verified, isFalse);
      expect(r.lines.join('\n'), contains('missing from the file'));
    },
  );

  group('the saved addresses are compared too', () {
    // A plan whose addressing the audit can actually read: every interface
    // the plan assigns appears in the file with the same IP, spelled the
    // way Packet Tracer spells it in a save.
    Map<String, dynamic> auditedRows(
      Map<String, List<Map<String, String>>> rowsPerDevice,
    ) => {
      'linkCount': plan.links.length,
      'links': [
        for (final l in plan.links)
          {
            'a': l.a,
            'aIf': _expanded(l.aIf),
            'b': l.b,
            'bIf': _expanded(l.bIf),
          },
      ],
      'devices': [
        for (final n in plan.nodes)
          {
            'name': n.name,
            'type': n.type,
            'services': n.services,
            'interfaces': rowsPerDevice[n.name] ?? const <dynamic>[],
          },
      ],
      'findings': const <dynamic>[],
    };

    /// The plan's addressing as audit rows: {device: [{name, ip}]} with the
    /// interface names expanded to Packet Tracer's full spelling.
    Map<String, List<Map<String, String>>> matchingRows({
      String Function(String ip)? rewrite,
    }) {
      final rows = <String, List<Map<String, String>>>{};
      for (final a in plan.addressing) {
        rows.putIfAbsent(a.node, () => []);
        final ip = a.ipCidr.split('/').first;
        rows[a.node]!.add({
          'name': _expanded(a.iface),
          'ip': rewrite == null ? ip : rewrite(ip),
        });
      }
      return rows;
    }

    /// The generator's report for the addressing half: every plan interface
    /// mapped to the real Packet Tracer port it landed on. The shared
    /// `builtPorts()` helper writes fake names (`port0`), fine for the
    /// structural link check, but the address comparison would then look on
    /// a port that does not exist.
    List<dynamic> identityPorts() {
      final ports = <String, Map<String, String>>{};
      void map(String device, String iface) {
        ports
            .putIfAbsent(device, () => <String, String>{})
            .putIfAbsent(iface, () => _expanded(iface));
      }

      for (final a in plan.addressing) {
        map(a.node, a.iface);
      }
      // The structural link check reads the same table, so every endpoint
      // the plan cables needs a row too - grouped per device, or a device
      // with two interfaces would keep only its last one.
      for (final l in plan.links) {
        map(l.a, l.aIf);
        map(l.b, l.bIf);
      }
      return [
        for (final e in ports.entries) {'name': e.key, 'ports': e.value},
      ];
    }

    test('a file whose saved IPs match the plan verifies them by name', () {
      final r = BuildPreflight.compare(
        intent: plan,
        audit: auditedRows(matchingRows()),
        builtDevices: identityPorts(),
      );
      expect(r.verified, isTrue, reason: r.lines.join('\n'));
      expect(
        r.lines.join('\n'),
        contains('address(es) verified against the saved ports'),
      );
    });

    test('a gateway the file never received fails the verification', () {
      final r = BuildPreflight.compare(
        intent: plan,
        audit: auditedRows(
          matchingRows(rewrite: (ip) => ip.endsWith('.1') ? '' : ip),
        ),
        builtDevices: identityPorts(),
      );
      expect(r.verified, isFalse);
      final text = r.lines.join('\n');
      expect(text, contains('unconfigured in the file'));
    });

    test('a wrong saved IP is reported with both addresses', () {
      final r = BuildPreflight.compare(
        intent: plan,
        audit: auditedRows(
          matchingRows(rewrite: (ip) => ip.endsWith('.1') ? '10.9.9.1' : ip),
        ),
        builtDevices: identityPorts(),
      );
      expect(r.verified, isFalse);
      final text = r.lines.join('\n');
      expect(text, contains('carries 10.9.9.1'));
      expect(text, contains('the plan assigns'));
    });

    test('a template leftover address on a planned device fails', () {
      final rows = matchingRows();
      final firstRouter = plan.nodes.firstWhere((n) => n.type == 'router');
      rows[firstRouter.name]!.add({
        'name': 'GigabitEthernet0/9',
        'ip': '10.66.66.66',
      });
      final r = BuildPreflight.compare(
        intent: plan,
        audit: auditedRows(rows),
        builtDevices: identityPorts(),
      );
      expect(r.verified, isFalse);
      expect(r.lines.join('\n'), contains('template leftovers'));
    });

    test('a device the audit cannot read is not comparable, not failed', () {
      final rows = matchingRows();
      // The server's panel was never readable: no interface rows at all.
      final server = plan.nodes.firstWhere((n) => n.type == 'server');
      rows[server.name] = [];
      final r = BuildPreflight.compare(
        intent: plan,
        audit: auditedRows(rows),
        builtDevices: identityPorts(),
      );
      expect(r.verified, isTrue, reason: r.lines.join('\n'));
      expect(
        r.lines.join('\n'),
        contains('not comparable'),
        reason: 'the honest note belongs in the success line',
      );
    });
  });

  cableCheckTests();
}

/// `g0/0` as Packet Tracer saves it: `GigabitEthernet0/0`.
String _expanded(String iface) {
  final m = RegExp(r'^([a-z]+)(.*)$').firstMatch(iface.trim().toLowerCase());
  if (m == null) return iface;
  const full = {
    'g': 'GigabitEthernet',
    'gi': 'GigabitEthernet',
    'f': 'FastEthernet',
    'fa': 'FastEthernet',
    's': 'Serial',
    'se': 'Serial',
    'e': 'Ethernet',
    'eth': 'Ethernet',
  };
  return '${full[m.group(1)] ?? m.group(1)!.toUpperCase()}${m.group(2)}';
}

/// The saved cables are read back out of the file and compared against the
/// plan, endpoint pair against endpoint pair, order ignored - because a
/// generator report that says "the port was used" cannot tell a cable that
/// was written from one that was not, or one that landed on the wrong port.
void cableCheckTests() {
  // A small plan whose shape a cable inventory can be checked against.
  final plan = NetworkIntent.parseSimple('p', '1 router 1 switch 2 pcs');

  Map<String, String> portOf() => {
    for (final l in plan.links) ...{
      '${l.a}|${l.aIf}': _expanded(l.aIf),
      '${l.b}|${l.bIf}': _expanded(l.bIf),
    },
  };

  /// The audit the compare gets: devices named, generator port table, and a
  /// cable inventory whose rows are what the save actually holds.
  Map<String, dynamic> auditWithCables(List<Map<String, String>> cables) => {
    'devices': [
      for (final n in plan.nodes)
        {'name': n.name, 'type': n.type, 'services': n.services},
    ],
    'linkCount': cables.length,
    'summary': {'links': cables.length},
    'links': [
      for (final c in cables)
        {
          'a': c['a'],
          'aIf': c['aIf'],
          'b': c['b'],
          'bIf': c['bIf'],
          'medium': 'eCopper',
          'cable': 'eStraightThrough',
        },
    ],
  };

  List<dynamic> identityPorts() {
    // One entry PER DEVICE with every port it carries - a switch holds three
    // links here, and per-endpoint entries would overwrite each other.
    final ports = <String, Map<String, String>>{};
    for (final entry in portOf().entries) {
      final device = entry.key.split('|').first;
      final iface = entry.key.split('|').last;
      ports.putIfAbsent(device, () => {})[iface] = entry.value;
    }
    return [
      for (final e in ports.entries) {'name': e.key, 'ports': e.value},
    ];
  }

  /// The plan's cables exactly as the save should hold them.
  List<Map<String, String>> plannedCables() => [
    for (final l in plan.links)
      {'a': l.a, 'aIf': _expanded(l.aIf), 'b': l.b, 'bIf': _expanded(l.bIf)},
  ];

  test('a file whose saved cables match the plan verifies them by name', () {
    final r = BuildPreflight.compare(
      intent: plan,
      audit: auditWithCables(plannedCables()),
      builtDevices: identityPorts(),
    );
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
    expect(
      r.lines.join('\n'),
      contains('cable(s) verified against the saved file'),
    );
  });

  test('a removed cable fails even when counts and devices still match', () {
    // SW1 keeps the same number of cables - one is just wired to the wrong
    // place, so count-based checks see nothing.
    final cables = plannedCables()
      ..removeAt(plannedCables().length - 1)
      ..add({
        'a': 'SW1',
        'aIf': 'FastEthernet0/1',
        'b': 'PC1',
        'bIf': 'FastEthernet0',
      });
    final r = BuildPreflight.compare(
      intent: plan,
      audit: auditWithCables(cables),
      builtDevices: identityPorts(),
    );
    expect(r.verified, isFalse);
    final text = r.lines.join('\n');
    expect(text, contains('the saved cables do not match the plan'));
    expect(text, contains('in the file but not planned'));
  });

  test('a misconnected port is reported as missing plus unexpected', () {
    // The R1<->SW1 cable exists but lands on the switch's wrong port: same
    // device pair, same cable count, different endpoint.
    Map<String, String> swap(String a, String aIf, String b, String bIf) => {
      'a': a,
      'aIf': aIf,
      'b': b,
      'bIf': bIf,
    };
    final cables = plannedCables()
        .map((c) {
          if (c['a'] == 'SW1' || c['b'] == 'SW1') {
            return c['a'] == 'SW1'
                ? swap(c['a']!, c['aIf']!, c['b']!, c['bIf']!)
                : swap(c['b']!, c['bIf']!, c['a']!, c['aIf']!);
          }
          return c;
        })
        .map((c) {
          if (c['a'] == 'SW1') return {...c, 'aIf': 'FastEthernet0/24'};
          if (c['b'] == 'SW1') return {...c, 'bIf': 'FastEthernet0/24'};
          return c;
        })
        .toList();
    final r = BuildPreflight.compare(
      intent: plan,
      audit: auditWithCables(cables),
      builtDevices: identityPorts(),
    );
    expect(r.verified, isFalse);
    final text = r.lines.join('\n');
    expect(text, contains('missing'));
    expect(text, contains('in the file but not planned'));
  });

  test('endpoint order never decides: reversed rows still verify', () {
    final cables = plannedCables().map((c) {
      // Swap both ends of every second cable.
      return c;
    }).toList();
    if (cables.isNotEmpty) {
      cables[0] = {
        'a': cables[0]['b']!,
        'aIf': cables[0]['bIf']!,
        'b': cables[0]['a']!,
        'bIf': cables[0]['aIf']!,
      };
    }
    final r = BuildPreflight.compare(
      intent: plan,
      audit: auditWithCables(cables),
      builtDevices: identityPorts(),
    );
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
  });

  test(
    'an audit that answers zero cables for a cabled plan fails honestly',
    () {
      final r = BuildPreflight.compare(
        intent: plan,
        audit: {
          'devices': [
            for (final n in plan.nodes)
              {'name': n.name, 'type': n.type, 'services': n.services},
          ],
          'linkCount': 0,
          'summary': {'links': 0},
          'links': <dynamic>[],
        },
        builtDevices: identityPorts(),
      );
      expect(r.verified, isFalse);
      expect(r.lines.join('\n'), contains('missing'));
    },
  );

  test('an audit with no link data cannot verify saved cables', () {
    // The pre-link-data audit shape: empty list, no count anywhere.
    final r = BuildPreflight.compare(
      intent: plan,
      audit: {
        'devices': [
          for (final n in plan.nodes)
            {'name': n.name, 'type': n.type, 'services': n.services},
        ],
        'links': <dynamic>[],
      },
      builtDevices: identityPorts(),
    );
    expect(r.verified, isFalse, reason: r.lines.join('\n'));
    expect(r.lines.join('\n'), contains('unverified'));
  });
}
