import '../models/network_intent.dart';

/// One check a lab step is graded by, interpreted against the STANDING PLAN.
///
/// Deterministic on purpose: every check reads fields the planner actually
/// writes, so a pass is the app's own evidence, never a model's opinion.
/// A failing check carries a remedy in the plan's own terms ("add a server
/// with DHCP") that the user can act on by typing.
sealed class LabCheck {
  const LabCheck();

  /// (passed, remedy) - the remedy is null when the check passes.
  ({bool ok, String? remedy}) grade(NetworkIntent intent);
}

/// At least [count] devices of [type] are planned.
class MinDevices extends LabCheck {
  final String type;
  final int count;
  const MinDevices(this.type, this.count);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) {
    final n = intent.nodes.where((node) => node.type == type).length;
    return (
      ok: n >= count,
      remedy: n >= count
          ? null
          : 'plan $count $type${count == 1 ? '' : 's'} (the plan has $n)',
    );
  }
}

/// At least one link joins two devices of the given types (in either
/// order) - a router-router WAN, a switch-PC access link.
class LinkBetween extends LabCheck {
  final String typeA;
  final String typeB;
  const LinkBetween(this.typeA, this.typeB);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) {
    bool matches(String a, String b) =>
        (a == typeA && b == typeB) || (a == typeB && b == typeA);
    for (final link in intent.links) {
      final a = intent.nodes
          .where((node) => node.name == link.a)
          .map((node) => node.type)
          .firstOrNull;
      final b = intent.nodes
          .where((node) => node.name == link.b)
          .map((node) => node.type)
          .firstOrNull;
      if (a != null && b != null && matches(a, b)) {
        return (ok: true, remedy: null);
      }
    }
    return (
      ok: false,
      remedy:
          'cable a $typeA to a $typeB (a router-router link is the '
          "plan's transit)",
    );
  }
}

/// The routing protocol the plan carries equals [routing] ('none' means
/// static/no protocol on purpose).
class RoutingIs extends LabCheck {
  final String routing;
  const RoutingIs(this.routing);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) => (
    ok: intent.routing == routing,
    remedy: intent.routing == routing
        ? null
        : 'say "use $routing" and I will switch the routing',
  );
}

/// A server node carries [service] in its service roles.
class ServerService extends LabCheck {
  final String service;
  const ServerService(this.service);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) {
    final servers = intent.nodes
        .where(
          (node) => node.type == 'server' && node.services.contains(service),
        )
        .toList();
    return (
      ok: servers.isNotEmpty,
      remedy: servers.isNotEmpty
          ? null
          : 'add a server with $service (for example "add a $service server")',
    );
  }
}

/// A VLAN with id [vlan] is defined.
class VlanPresent extends LabCheck {
  final int vlan;
  const VlanPresent(this.vlan);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) => (
    ok: intent.vlans.contains(vlan),
    remedy: intent.vlans.contains(vlan)
        ? null
        : 'say "add VLAN $vlan" to the plan',
  );
}

/// Every node that must be cabled is: no island a ping could never leave.
/// Wireless joiners (AP clients) and placed-not-wired kinds do not count.
class NoIslands extends LabCheck {
  const NoIslands();

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) {
    final linked = {
      for (final l in intent.links) ...[l.a.toLowerCase(), l.b.toLowerCase()],
    };
    final islands = intent.nodes
        .where((node) => !linked.contains(node.name.toLowerCase()))
        .where((node) => !(node.type == 'pc' || node.type == 'server'))
        .toList();
    final cabledHosts = intent.nodes
        .where(
          (node) =>
              (node.type == 'pc' || node.type == 'server') &&
              linked.contains(node.name.toLowerCase()),
        )
        .length;
    return (
      ok: islands.isEmpty && cabledHosts > 0,
      remedy: islands.isEmpty
          ? (cabledHosts > 0 ? null : 'cable at least one host to a switch')
          : 'cable ${islands.take(3).join(', ')} - a device no cable reaches '
                'cannot pass traffic',
    );
  }
}

/// A security control was requested (the security section of the plan).
class SecurityRequested extends LabCheck {
  final bool Function(NetworkIntent intent) test;
  final String label;
  const SecurityRequested(this.test, this.label);

  @override
  ({bool ok, String? remedy}) grade(NetworkIntent intent) {
    final ok = test(intent);
    return (
      ok: ok,
      remedy: ok ? null : 'say "add $label" to request the control',
    );
  }
}

/// One step of a guided lab: what to do, why, and how it is graded.
class LabStep {
  final String title;
  final String instruction;
  final LabCheck check;

  const LabStep(this.title, this.instruction, this.check);
}

/// A guided lab: an ordered set of steps, graded against the standing plan.
class GuidedLab {
  final String id;
  final String title;
  final String blurb;
  final List<LabStep> steps;

  const GuidedLab({
    required this.id,
    required this.title,
    required this.blurb,
    required this.steps,
  });
}

/// The three starter labs. Each is buildable with what the offline planner
/// already parses, and each grade is a plan read, never a guess.
class LabCatalog {
  const LabCatalog._();

  static final List<GuidedLab> all = [
    GuidedLab(
      id: 'vlan-dhcp',
      title: 'Two VLANs with DHCP',
      blurb:
          'Segment a small office into two VLANs and hand out addresses '
          'from a DHCP server.',
      steps: [
        LabStep(
          'Switch and router',
          'Plan a router and at least one switch - the router routes between '
              'the VLANs, the switch hosts the access ports.',
          const MinDevices('switch', 1),
        ),
        LabStep(
          'Two VLANs',
          'Define VLAN 10 and VLAN 20 (for example staff and guests).',
          const VlanPresent(10),
        ),
        LabStep(
          'Second VLAN',
          'Define the second VLAN so the two broadcast domains exist.',
          const VlanPresent(20),
        ),
        LabStep(
          'DHCP server',
          'Add a server carrying the DHCP service; its pools hand addresses '
              'to both VLANs.',
          const ServerService('dhcp'),
        ),
        LabStep(
          'Everything cabled',
          'Cable the PCs and the server to the switch - a device no cable '
              'reaches cannot pass traffic.',
          const NoIslands(),
        ),
        LabStep(
          'Inter-VLAN routing',
          'The router needs an address in each VLAN; say "use router on a '
              'stick" or add addressing, then build the .pkt.',
          const MinDevices('router', 1),
        ),
      ],
    ),
    GuidedLab(
      id: 'ospf-wan',
      title: 'Two routers over a WAN with OSPF',
      blurb: 'Two sites, one serial transit link, OSPF advertising both LANs.',
      steps: [
        LabStep(
          'Two routers',
          'Plan exactly the two site routers.',
          const MinDevices('router', 2),
        ),
        LabStep(
          'A router-to-router link',
          'Cable the two routers together - this is the transit the routes '
              'run over.',
          const LinkBetween('router', 'router'),
        ),
        LabStep(
          'OSPF on',
          'Say "use OSPF" so both routers advertise their LANs.',
          const RoutingIs('ospf'),
        ),
        LabStep(
          'Hosts on both sides',
          'Give each site at least one switch and a PC.',
          const MinDevices('switch', 2),
        ),
        LabStep(
          'No islands',
          'Cable every PC to its site switch.',
          const NoIslands(),
        ),
      ],
    ),
    GuidedLab(
      id: 'secure-mgmt',
      title: 'Secure management',
      blurb:
          'A small LAN managed over SSH with AAA, port security, and no '
          'shared passwords.',
      steps: [
        LabStep(
          'A switch and a router',
          'The managed devices: one router, at least one switch.',
          const MinDevices('switch', 1),
        ),
        LabStep(
          'AAA server',
          'Add a server with the AAA service and an account on it - what a '
              'login needs is an ACCOUNT, not a shared key.',
          const ServerService('aaa'),
        ),
        LabStep(
          'AAA requested on the network',
          'Say "secure management with AAA" so the routers are told to ask '
              'the server.',
          SecurityRequested((intent) => intent.security.aaa, 'AAA'),
        ),
        LabStep(
          'Port security',
          'Request port security on the access switch.',
          SecurityRequested(
            (intent) => intent.security.portSecurity,
            'port security',
          ),
        ),
        LabStep(
          'Everything cabled',
          'Cable the hosts; the AAA server needs a link to the switch too.',
          const NoIslands(),
        ),
      ],
    ),
  ];

  static GuidedLab? byId(String id) =>
      all.where((lab) => lab.id == id).firstOrNull;

  /// Resolve a spoken name: "the vlan lab", "ospf", "secure management".
  static GuidedLab? byName(String text) {
    final t = text.toLowerCase();
    for (final lab in all) {
      if (t.contains(lab.id)) return lab;
    }
    if (t.contains('vlan') || t.contains('dhcp')) return byId('vlan-dhcp');
    if (t.contains('ospf') || t.contains('wan')) return byId('ospf-wan');
    if (t.contains('secure') || t.contains('management') || t.contains('aaa')) {
      return byId('secure-mgmt');
    }
    return null;
  }
}

/// The grade of a standing plan against one lab.
class LabProgress {
  final GuidedLab lab;
  final List<({LabStep step, bool ok, String? remedy})> results;

  const LabProgress(this.lab, this.results);

  int get passed => results.where((r) => r.ok).length;
  bool get complete => passed == results.length;
  LabStep? get nextStep =>
      results.where((r) => !r.ok).map((r) => r.step).firstOrNull;

  /// Markdown for the chat: the checked list, the first open step, done.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln(
        '**${lab.title}** - $passed of ${results.length} step(s) '
        '${complete ? 'COMPLETE' : 'met'}',
      )
      ..writeln();
    for (final r in results) {
      b.writeln('- ${r.ok ? '[x]' : '[ ]'} ${r.step.title}');
      if (!r.ok) {
        b.writeln('  - ${r.step.instruction}');
        b.writeln('  - _To meet it: ${r.remedy}_');
      }
    }
    if (complete) {
      b
        ..writeln()
        ..writeln(
          'Every step is met. Say "build the .pkt" to compile it, '
          'or "stop the lab" to close this checklist.',
        );
    } else {
      final next = nextStep!;
      b
        ..writeln()
        ..writeln('Next: **${next.title}** - ${next.instruction}');
    }
    return b.toString().trimRight();
  }
}

/// Grades a plan against a lab. Pure: reads the plan, writes nothing.
class LabGrader {
  const LabGrader._();

  static LabProgress grade(GuidedLab lab, NetworkIntent intent) =>
      LabProgress(lab, [
        for (final step in lab.steps)
          () {
            final verdict = step.check.grade(intent);
            return (step: step, ok: verdict.ok, remedy: verdict.remedy);
          }(),
      ]);
}

/// What the user wants from the lab flow.
enum LabAction { list, start, check, stop }

/// Reads what the user wants from the lab flow: list, start, check, stop.
class LabRequest {
  const LabRequest._();

  static ({LabAction action, GuidedLab? lab})? read(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('\u2019', "'");
    if (t.isEmpty || t.contains('\n')) return null;
    if (RegExp(r'^/lab$|^/?labs?\s*$').hasMatch(t)) {
      return (action: LabAction.list, lab: null);
    }
    final start = RegExp(
      r'^(?:please\s+)?(?:start|begin|do|open)\b.{0,24}\blab\b',
    ).hasMatch(t);
    final check = RegExp(
      r'^(?:please\s+)?(?:check|grade|how\s+am\s+i\s+doing\s+(?:on|in)\b.{0,10}?|'
      r'whats?\s+my\s+(?:progress|status)\s+(?:on|in)\b.{0,10}?)\b.{0,16}\blab\b'
      r'|^check\s+my\s+lab$',
    ).hasMatch(t);
    final stop = RegExp(
      r'^(?:please\s+)?(?:stop|exit|leave|quit|end)\b.{0,10}\blab\b',
    ).hasMatch(t);
    if (!start && !check && !stop) return null;
    if (stop) return (action: LabAction.stop, lab: null);
    if (check) return (action: LabAction.check, lab: null);
    return (action: LabAction.start, lab: LabCatalog.byName(t));
  }
}
