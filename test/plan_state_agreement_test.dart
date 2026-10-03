import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/build_preflight.dart';
import 'package:net_builder/services/file_edit_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// The reported session, replayed: a 10-PC / 3-server / 2-switch / 2-router
/// company lab where the model service was down (HTTP 503) so the offline
/// planner answered, and the user then asked to edit the file to give one
/// server AAA and another DHCP.
///
/// Every check here is about ONE plan version being described consistently by
/// the chat summary, the validation, the build card and the .pkt, because the
/// reported failure was a card that advertised 2 devices while the plan, the
/// summary and the built file all said 17.
const String brief =
    'build a company network 10 pc 3 servers(1 dhcp server and 1 AAA server) '
    '2 switches and 2 routers suggest the network and if any of the devices '
    'need changing (for the AAA server clinet name admin password 123)';

const String editAsk =
    'edit the file and make one server an AAA server and another server as '
    'dhcp server';

NetworkIntent _plan(String project) => NetworkIntent.parseSimple(project, brief);
void main() {
  group('the original request produces one buildable 17-device plan', () {
    final plan = NetworkIntent.parseSimple('offline-chat', brief);

    test('every requested device is present and cabled', () {
      int of(String type) => plan.nodes.where((n) => n.type == type).length;
      expect(of('pc'), 10);
      expect(of('server'), 3);
      expect(of('switch'), 2);
      expect(of('router'), 2);
      expect(plan.nodes.length, 17);
      for (final node in plan.nodes) {
        expect(
          plan.links.any((l) => l.a == node.name || l.b == node.name),
          isTrue,
          reason: '${node.name} is in the plan but has no cable',
        );
      }
    });

    test('the request is a follow-up, not a fresh tiny office', () {
      expect(plan.revision, isNotEmpty);
      expect(plan.revisionLabel, contains('17 device(s)'));
      expect(plan.revisionLabel, contains('16 link(s)'));
    });

    test('"1 dhcp server and 1 AAA server" lands on two different servers', () {
      final dhcp = plan.nodes
          .where((n) => n.type == 'server' && n.services.contains('dhcp'))
          .toList();
      final aaa = plan.nodes
          .where((n) => n.type == 'server' && n.services.contains('aaa'))
          .toList();
      expect(dhcp, hasLength(1), reason: 'one server runs DHCP');
      expect(aaa, hasLength(1), reason: 'one server runs AAA');
      expect(
        dhcp.single.name,
        isNot(aaa.single.name),
        reason: 'the brief asked for two roles on two servers, not both on one',
      );
    });

    test('the AAA credentials in the brief are read, not dropped', () {
      // "clinet name admin password 123" is the same three facts as
      // "username admin password 123".
      expect(plan.security.aaa, isTrue);
      expect(plan.security.aaaUsername, 'admin');
      expect(plan.security.aaaAccountPassword, '123');
      expect(plan.security.aaaServer, isNotNull);
      expect(plan.security.aaaRouter, isNotNull);
      final aaaServer = plan.nodes.firstWhere(
        (n) => n.name == plan.security.aaaServer,
      );
      final users =
          (aaaServer.serviceRules['aaa'] as Map)['users'] as List;
      expect(users, isNotEmpty);
      expect(
        users.first,
        containsPair('username', 'admin'),
        reason: 'the account reaches the server\'s Services tab',
      );
    });

    test('nothing blocks the build, so the build card is offered', () {
      final issues = ValidatorService.validate(plan, target: 'packet-tracer');
      final blocking = issues
          .where((i) => i.severity == 'error' || i.severity == 'warning')
          .toList();
      expect(
        blocking,
        isEmpty,
        reason: 'the reported "AAA credentials are missing" warning must not '
            'fire for a brief that supplied an account: '
            '${blocking.map((b) => b.message).join(' | ')}',
      );
    });

    test('the reply describes this plan, by revision, and offers the build',
        () {
      final reply = OfflineAssistantService.reply(
        rawText: brief,
        normalized: brief,
        target: 'packet-tracer',
        plan: plan,
        modelError: 'HTTP 503',
      );
      expect(reply.text, contains('17'));
      expect(reply.text, contains(plan.revision));
      expect(reply.text, contains('Build the .pkt'));
      expect(reply.quickReplies, contains('Build the .pkt'));
    });

    test('the .pkt the builder receives carries the same counts', () {
      final steps = PacketTracerAdapter.autopilotPlan(plan)['steps'] as List;
      Map<String, dynamic> step(String action) => steps
          .cast<Map<String, dynamic>>()
          .firstWhere((s) => s['action'] == action);
      expect((step('create_nodes')['nodes'] as List), hasLength(17));
      expect((step('create_links')['links'] as List), hasLength(16));
      // Every advertised service is actually configured, not merely named.
      final servers = step('config_servers')['servers'] as Map;
      final aaa = ((servers[plan.security.aaaServer]! as Map)['services']
          as Map)['aaa'] as Map;
      expect((aaa['users'] as List), isNotEmpty);
      expect((aaa['clients'] as List), isNotEmpty,
          reason: 'a client entry is what makes the AAA tab usable');
      final dhcpNode = plan.nodes.firstWhere(
        (n) => n.services.contains('dhcp'),
      );
      final dhcp = ((servers[dhcpNode.name]! as Map)['services'] as Map)['dhcp']
          as Map;
      expect((dhcp['pools'] as List), isNotEmpty);
    });

    test('the router configures AAA against the server that holds the account',
        () {
      final r1 = CiscoAdapter.render(plan)[plan.security.aaaRouter]!;
      expect(r1, contains('aaa new-model'));
      expect(r1, contains('tacacs-server host'));
      expect(r1, contains('tacacs-server key'));
      // The account is not the shared key: the router's own login uses the
      // account password so it matches what the server holds.
      expect(r1, contains('username admin secret 0 123'));
    });

    test('preflight reports these counts, not a different plan', () {
      final lines = BuildPreflight.lines(intent: plan, target: 'packet-tracer')
          .join('\n');
      expect(lines, contains('17 device(s)'));
      expect(lines, contains('16 link(s)'));
    });
  });

  group('"edit the file" is read as an edit, and keeps the network', () {
    test('the wording is recognised as editing the existing file', () {
      expect(
        FileEditIntentReader.read(editAsk, hasArtifact: true, candidates: 1),
        FileEditIntent.editExisting,
        reason: 'the user said "edit the file" and named no second file, so '
            'there is nothing ambiguous about it',
      );
    });

    test('applying it keeps every device and link, changing only the roles',
        () {
      final before = _plan('offline-chat');
      final outcome = NetworkIntent.followUp(
        previous: before,
        previousBrief: brief,
        brief: editAsk,
        parsed: NetworkIntent.parseSimple('chat', editAsk),
        project: 'chat',
      );
      final after = outcome.plan;
      // The whole lab survives: an edit is a focused update, not a rebuild
      // from the words of one sentence.
      expect(after.nodes.length, before.nodes.length);
      expect(after.links.length, before.links.length);
      for (final node in before.nodes) {
        expect(after.nodes.any((n) => n.name == node.name), isTrue);
      }
      for (final link in before.links) {
        expect(
          after.links.any((l) =>
              l.a == link.a &&
              l.b == link.b &&
              l.aIf == link.aIf &&
              l.bIf == link.bIf),
          isTrue,
        );
      }
      // Addressing and routing are preserved.
      expect(after.routing, before.routing);
      expect(after.addressing.length, before.addressing.length);
      // The two named roles exist on two different servers.
      final aaa = after.nodes
          .where((n) => n.type == 'server' && n.services.contains('aaa'))
          .toList();
      final dhcp = after.nodes
          .where((n) => n.type == 'server' && n.services.contains('dhcp'))
          .toList();
      expect(aaa, hasLength(1));
      expect(dhcp, hasLength(1));
      expect(aaa.single.name, isNot(dhcp.single.name));
      // And the revision moved, so a card written for the old plan is stale.
      expect(after.revision, isNot(before.revision));
    });
  });

  group('a plan with blocking findings is not offered as ready', () {
    // AAA with no server, no router and no account: the reported state the app
    // used to describe as fine and then refuse to build.
    final broken = NetworkIntent.parseSimple(
      'chat',
      '1 router 1 switch 1 server, an AAA server for login authentication',
    );

    test('the summary withholds the build and names the blocker', () {
      final reply = OfflineAssistantService.reply(
        rawText: 'ok build it',
        normalized: 'ok build it',
        target: 'packet-tracer',
        plan: broken,
      );
      final blocking = ValidatorService.validate(broken, target: 'packet-tracer')
          .where((i) => i.severity == 'error' || i.severity == 'warning')
          .toList();
      if (blocking.isNotEmpty) {
        expect(reply.quickReplies, isNot(contains('Build the .pkt')));
        expect(reply.text, contains('cannot build this one yet'));
        expect(reply.text, isNot(contains('Press "Build the .pkt" below')));
      }
    });
  });
}
