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

  /// An audit whose devices match the plan exactly, so the structural half
  /// has nothing to complain about.
  Map<String, dynamic> cleanAudit({
    Map<String, List<String>>? services,
    List<String> findings = const [],
  }) {
    // A sound file enables exactly the services the plan gave each device.
    final svcs = services ??
        {
          for (final n in plan.nodes)
            n.name: n.services,
        };
    return {
      'devices': [
        for (final n in plan.nodes)
          {'name': n.name, 'type': n.type, 'services': svcs[n.name] ?? []},
      ],
      'links': <dynamic>[],
      'findings': findings,
    };
  }


  /// The generator's own report: every interface the plan names mapped to a
  /// real port. This is what the structural half compares against, so
  /// supplying it isolates the semantic half instead of letting "no interface
  /// for R1:g0/0" mask the finding under test.
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

  test('a file that matches the plan and is sound verifies', () {
    final r = BuildPreflight.compare(
          intent: plan, audit: cleanAudit(), builtDevices: builtPorts());
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

  test('a service role the plan asked for and the file lacks fails the build',
      () {
    // The plan gave its server 'dns'; the file enabled nothing.
    final server = plan.nodes.firstWhere((n) => n.type == 'server');
    expect(server.services, isNotEmpty,
        reason: 'the brief must give the server a role for this to test');

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
  });

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

  test('an audit that carries no findings key still verifies structurally',
      () {
    // Older audit shapes have no 'findings'. They must not crash, and must
    // not be treated as "findings were checked and were clean" - they are
    // simply silent, so a sound file still verifies.
    final audit = cleanAudit()..remove('findings');
    final r = BuildPreflight.compare(
        intent: plan, audit: audit, builtDevices: builtPorts());
    expect(r.verified, isTrue, reason: r.lines.join('\n'));
  });

  test('a device missing from the file is still caught by the structural half',
      () {
    final audit = cleanAudit();
    (audit['devices'] as List).removeLast();
    final r = BuildPreflight.compare(
        intent: plan, audit: audit, builtDevices: builtPorts());
    expect(r.verified, isFalse);
    expect(r.lines.join('\n'), contains('missing from the file'));
  });
}