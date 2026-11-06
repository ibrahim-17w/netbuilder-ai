import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/plan_repair_service.dart';

/// The validator's own remedy text tells the user to type 'AAA client name
/// admin password 123' - and the follow-up machinery used to file that
/// sentence under "no device named, keep the plan", dropping the credentials
/// it carried so the finding could never clear by typing what was suggested.
void main() {
  _perFindingFixCards();
  _serverRolesDistribute();
  _countCorrectionNotFileEdit();
  test('the validator\'s suggested AAA phrase lands on the standing lab', () {
    final standing = NetworkIntent.parseSimple(
      'campus',
      '1 router, 1 switch, 10 pcs and 1 AAA server',
    );
    expect(standing.security.aaa, isTrue);

    final turn = NetworkIntent.followUp(
      previous: standing,
      previousBrief: '1 router, 1 switch, 10 pcs and 1 AAA server',
      brief: 'AAA client name admin password Lab123',
      parsed: NetworkIntent.parseSimple('campus', 'AAA client name admin password Lab123'),
      project: 'campus',
    );

    final aaaNode = turn.plan.nodes.firstWhere(
      (n) => (n.serviceRules['aaa'] as Map?)?['users'] != null,
    );
    final users = (aaaNode.serviceRules['aaa'] as Map)['users'] as List;
    expect(users, isNotEmpty);
    expect(users.first['username'], 'admin');
    expect(users.first['password'], 'Lab123');
    expect(turn.plan.security.aaaUsername, 'admin');
  });

  test('re-stating a credential does not overwrite the one the lab holds', () {
    final standing = NetworkIntent.parseSimple(
      'campus',
      '1 router, 1 switch and 1 AAA server with the client name boss '
          'password Keep123',
    );
    final turn = NetworkIntent.followUp(
      previous: standing,
      previousBrief: 'brief',
      brief: 'AAA client name admin password Other123',
      parsed: NetworkIntent.parseSimple('campus', 'AAA client name admin password Other123'),
      project: 'campus',
    );
    final aaaNode = turn.plan.nodes.firstWhere(
      (n) => (n.serviceRules['aaa'] as Map?)?['users'] != null,
    );
    final users = ((aaaNode.serviceRules['aaa'] as Map)['users'] as List)
        .cast<Map>();
    expect(users.map((u) => u['username']), contains('boss'));
  });
}

void _countCorrectionNotFileEdit() {
  test(
    '"make it 60 PCs" on a standing lab is a count correction, not a file edit',
    () {
      final standing = NetworkIntent.parseSimple(
        'enterprise',
        'Build the enterprise network for company Contoso. HQ: 2 firewalls '
        '(ASA 5506-X) at the internet edge, 2 core routers running OSPF, '
        '2 distribution switches and 3 access switches. 40 PCs. A branch '
        'office with 1 router, 1 switch, 10 PCs and 1 printer connected '
        'over a serial WAN.',
      );
      // The chat's file-intent gate must skip the file-edit reading for a
      // count correction: "it" in "make it 60 PCs" is the lab, not the
      // .pkt artifact.
      expect(NetworkIntent.readsAsCountCorrection('make it 60 PCs'), isTrue);
      final turn = NetworkIntent.followUp(
        previous: standing,
        previousBrief:
            'Build the enterprise network for company Contoso. HQ: 2 '
            'firewalls (ASA 5506-X) at the internet edge, 2 core routers '
            'running OSPF, 2 distribution switches and 3 access switches. '
            '40 PCs. A branch office with 1 router, 1 switch, 10 PCs and 1 '
            'printer connected over a serial WAN.',
        brief: 'make it 60 PCs',
        parsed: NetworkIntent.parseSimple('enterprise', 'make it 60 PCs'),
        project: 'enterprise',
      );
      int countOf(NetworkIntent p, String type) =>
          p.nodes.where((n) => n.type == type).length;
      expect(countOf(turn.plan, 'pc'), 60);
      // Everything the correction did not name SURVIVES - the whole-lab
      // replacement read sixty orphan PCs over the enterprise topology.
      expect(countOf(turn.plan, 'router'), 3);
      expect(countOf(turn.plan, 'switch'), 6);
      expect(turn.plan.links, isNotEmpty);
    },
  );
}

void _serverRolesDistribute() {
  test(
    '"8 servers: one role each" gives every server a role, not the first one',
    () {
      final plan = NetworkIntent.parseSimple(
        'enterprise',
        'Server farm with 8 servers: DHCP, DNS, web with HTTP and HTTPS, '
        'mail, FTP, AAA TACACS+, syslog and NTP, CME voice. 40 PCs.',
      );
      final servers = plan.nodes.where((n) => n.type == 'server').toList();
      expect(servers.length, 8);
      // The colon-list shape ("8 servers: role, role, ...") used to pile
      // every role onto SRV1, so the built file shipped seven empty server
      // panels and one server doing everything.
      final withRole = servers.where((s) => s.services.isNotEmpty).length;
      expect(withRole, 8, reason: 'every server carries its role');
      expect(
        servers.map((s) => s.services.first),
        containsAll(['dhcp', 'dns', 'http', 'email', 'ftp', 'aaa']),
      );
    },
  );
}

void _perFindingFixCards() {
  test('every blocking finding maps to the repair that clears it', () {
    // The classifier is what the per-finding "Apply this fix" cards decide
    // from: a finding with no mapping gets no card and stays an honest dead
    // end, and every mapped finding must be a kind the repair understands.
    final known = {
      'duplicate_lan_address',
      'missing_ip_config',
      'shared_port',
      'uncabled_device',
      'switch_overflow',
      'aaa_account_missing',
      'ipsec_psk_missing',
    };
    final messages = {
      'Duplicate IP 192.168.10.1 is assigned to both R1 g0/1 and R2 g0/1':
          'duplicate_lan_address',
      'no device holds 192.168.10.1 (the usual gateway for 192.168.10.10)':
          'missing_ip_config',
      'Interface r1:g0/2 is used by 2 links.': 'shared_port',
      'FW1 has no link in the plan, so it would ship standing alone on the '
          'canvas; cable it or say so': 'uncabled_device',
      'SW1 is cabled to 32 devices but a Packet Tracer 2960 has only 24 '
          'ports; 8 cable(s) land on interfaces the switch does not have.':
          'switch_overflow',
      'The AAA server holds no account, so no login can be verified. Add '
          'one - for example "AAA client name admin password 123" - and it '
          'is written into the server\'s Services tab.': 'aaa_account_missing',
      'R1: no IPSec pre-shared key was stated, so the tunnel is staged and '
          'cannot establish until one is given': 'ipsec_psk_missing',
    };
    for (final e in messages.entries) {
      expect(
        PlanRepairService.fixKindFor(e.key),
        e.value,
        reason: e.key,
      );
      expect(known, contains(e.value));
    }
    // A finding with no deterministic repair maps to nothing - the card then
    // says what it needs instead of offering a button that cannot work.
    expect(
      PlanRepairService.fixKindFor(
        'This plan has 120 devices, above the 50-device build limit.',
      ),
      isNull,
    );
  });

  test('an only-gated repair runs ONE pass and leaves the rest standing', () {
    // Two findings, two kinds: a shared port and a missing endpoint address.
    // Applying ONLY the shared_port fix must move the cable and touch
    // nothing else - the per-finding card promises one visible change.
    const brief =
        '2 routers, 2 switches and 3 PCs. R1 g0/0 connects to SW1 '
        'FastEthernet0/1. R2 g0/0 connects to SW1 FastEthernet0/1. '
        'PC1 connects to SW1 FastEthernet0/1. PC2 connects to SW1 '
        'FastEthernet0/2. PC3 connects to SW1 FastEthernet0/2.';
    final plan = NetworkIntent.parseSimple('lab', brief);
    final all = PlanRepairService.repair(plan, target: 'packet-tracer');
    expect(all.fixes, isNotEmpty);

    final gated = PlanRepairService.repair(
      plan,
      target: 'packet-tracer',
      only: {'shared_port'},
    );
    // Every change the gated run made belongs to the requested kind.
    final gatedKinds = gated.fixes.map((f) => f.kind).toSet();
    expect(gatedKinds, {'shared_port'});
  });
}
