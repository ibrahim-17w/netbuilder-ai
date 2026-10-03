import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// A standing plan is stored redacted (`includeSecrets: false`), which removes
/// every `password` key - including the password inside an AAA account row.
/// Restoring that shape and validating it reported "an account missing username
/// or password" for a credential the brief HAD supplied, so the build card was
/// withheld forever and "fix the plan" could not clear it: inventing a password
/// is the one repair the app must never make. The transcript is the other half
/// of the record, so the withheld value is recovered from what the user typed.
const brief =
    'Build a corporate network for 40 users across 2 physical sites. Site A is '
    'the headquarters with 2 routers, 2 switches, 3 Server-PT devices '
    '(1 DHCP server, 1 AAA/TACACS+ server, 1 DNS+HTTP server) and 15 PCs. '
    'Site B is a branch with 1 router, 1 switch, 1 Server-PT device (the DHCP '
    'server) and 10 PCs. Use 192.168.10.0/24 at HQ and 192.168.20.0/24 at the '
    'branch, OSPF area 0, and set up AAA with the client name admin and '
    'password 123.';

List<ValidationIssue> blocking(NetworkIntent plan) => ValidatorService.validate(
  plan,
  target: 'packet-tracer',
).where((i) => i.severity == 'error' || i.severity == 'warning').toList();

/// The exact write/read pair chat_screen and the session state use.
NetworkIntent restored(NetworkIntent plan) => NetworkIntent.fromJson(
  Map<String, dynamic>.from(
    jsonDecode(jsonEncode(plan.toJson(includeSecrets: false))) as Map,
  ),
);

NetNode server(NetworkIntent plan, String name) =>
    plan.nodes.firstWhere((n) => n.name == name);

void main() {
  group('a redacted standing plan', () {
    test('loses the account password, which used to block the build', () {
      final plan = NetworkIntent.parseSimple('chat', brief);
      final back = restored(plan);
      final rules = server(back, 'SRV2').serviceRules['aaa'] as Map;
      expect((rules['users'] as List).single, {'username': 'admin'});
      expect(
        blocking(back).map((i) => i.message),
        contains(
          'SRV2 aaa rule has an account missing username or password; '
          'it will not be submitted.',
        ),
      );
    });

    test('gets its credential back from the transcript', () {
      final plan = NetworkIntent.parseSimple('chat', brief);
      final recovered = NetworkIntent.recoverRedactedSecrets(
        restored(plan),
        brief,
      );
      final rules = server(recovered, 'SRV2').serviceRules['aaa'] as Map;
      expect((rules['users'] as List).single, {
        'username': 'admin',
        'password': '123',
      });
      expect(recovered.security.aaaUsername, 'admin');
      expect(recovered.security.aaaAccountPassword, '123');
      expect(recovered.security.aaaPassword, '123');
      expect(blocking(recovered), isEmpty);
    });

    test('keeps the revision, so a card already written still fits it', () {
      // Recovering a password is not a change to the network, and the revision
      // deliberately hashes what the plan CONTAINS (devices, links, addressing,
      // services) rather than its secrets. If recovery moved the revision, every
      // build card on the conversation would read "stale" and the fix would
      // trade one dead end for another.
      final plan = NetworkIntent.parseSimple('chat', brief);
      final back = restored(plan);
      expect(
        NetworkIntent.recoverRedactedSecrets(back, brief).revision,
        back.revision,
      );
      expect(back.revision, plan.revision);
    });

    test('is repaired from the whole conversation, not only the first turn', () {
      final plan = NetworkIntent.parseSimple('chat', brief);
      const follow = 'the aaa username: admin and password 123';
      final recovered = NetworkIntent.recoverRedactedSecrets(
        restored(plan),
        '$brief\n$follow',
      );
      expect(blocking(recovered), isEmpty);
    });

    test('keeps a genuinely missing password missing', () {
      // The brief never states a password for the account, so nothing may be
      // recovered and the finding stands - that one really is the user's call.
      const bare = '2 routers 1 switch aaa server with username bob';
      final plan = NetworkIntent.parseSimple('chat', bare);
      final recovered = NetworkIntent.recoverRedactedSecrets(restored(plan), bare);
      expect(recovered.security.aaaAccountPassword, isNull);
    });

    test('leaves a transcript with no credential alone', () {
      final plan = NetworkIntent.parseSimple('chat', '2 routers 1 switch ospf');
      expect(
        identical(
          NetworkIntent.recoverRedactedSecrets(plan, 'make it bigger'),
          plan,
        ),
        isTrue,
      );
      expect(
        identical(NetworkIntent.recoverRedactedSecrets(plan, ''), plan),
        isTrue,
      );
    });

    test('recovers a stated enable secret and VPN pre-shared key', () {
      const secured =
          '1 router 1 switch 10 pcs with aaa username admin password 123, '
          'enable secret Cl@ss1 and a site-to-site vpn using pre-shared key '
          'LabKey1';
      final plan = NetworkIntent.parseSimple('chat', secured);
      final back = restored(plan);
      expect(back.security.enableSecret, isNull);
      expect(back.security.vpnPreSharedKey, isNull);
      final recovered = NetworkIntent.recoverRedactedSecrets(back, secured);
      expect(recovered.security.enableSecret, 'Cl@ss1');
      expect(recovered.security.vpnPreSharedKey, 'LabKey1');
    });
  });

  group('"fix the plan"', () {
    test('names the login sentence instead of only topology examples', () {
      // The account whose password the redaction dropped: this is the finding
      // the user kept being told to fix, with no way to act on it.
      const stated =
          '2 routers 1 switch 2 servers with aaa username admin password 123';
      final plan = restored(NetworkIntent.parseSimple('chat', stated));
      final reply = OfflineAssistantService.fixPlan(
        plan: plan,
        target: 'packet-tracer',
      );
      expect(reply.text, contains('missing username or password'));
      expect(reply.text, contains('AAA username admin password 123'));
      expect(reply.text, contains('SRV1'));
    });

    test('still offers the topology examples for other findings', () {
      final plan = NetworkIntent.parseSimple('chat', '1 router 1 switch 2 pcs');
      final broken = plan.copyWith(
        vlans: const [70000],
      );
      final reply = OfflineAssistantService.fixPlan(plan: broken, target: 'packet-tracer');
      expect(reply.text, isNot(contains('AAA username')));
    });
  });
}
