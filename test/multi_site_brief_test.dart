import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/validator_service.dart';

/// Two failures a large multi-site brief produced, both of which lost or
/// invented things the user never asked for.
void main() {
  group('a site device list is not cut short by its own commas', () {
    // The site clause is split on commas and on "and", so only the fragment
    // holding the site word used to keep its label. Every later fragment was
    // read as an unlabeled repeat - a restatement - and dropped: 15 of 25 PCs
    // vanished and the branch lost its switch and its server.
    const brief =
        'Build a corporate network across 2 physical sites. '
        'Site A is the headquarters with 2 routers, 2 switches, 3 servers '
        'and 15 PCs. '
        'Site B is a branch with 1 router, 1 switch, 2 servers and 10 PCs.';

    final plan = NetworkIntent.parseSimple('multi-site', brief);
    int of(String type) => plan.nodes.where((n) => n.type == type).length;

    test('every kind in a site list is counted, not just the first', () {
      expect(of('router'), 3, reason: '2 at HQ + 1 at the branch');
      expect(of('switch'), 3, reason: '2 at HQ + 1 at the branch');
      expect(of('server'), 5, reason: '3 at HQ + 2 at the branch');
      expect(of('pc'), 25, reason: '15 at HQ + 10 at the branch');
    });

    test('every device is cabled', () {
      for (final node in plan.nodes) {
        expect(
          plan.links.any((l) => l.a == node.name || l.b == node.name),
          isTrue,
          reason: '${node.name} has no cable',
        );
      }
    });

    test('"Site A" and "Site B" are two sites, not one restatement', () {
      final twoSites = NetworkIntent.parseSimple(
        'labelled',
        'Site A has 2 switches. Site B has 3 switches.',
      );
      expect(twoSites.nodes.where((n) => n.type == 'switch'), hasLength(5));
    });

    test('a distribution of one stated total is still not added to', () {
      // The rule that protects "6 access points: 3 upstairs and 3 downstairs"
      // must survive the site-label change.
      final split = NetworkIntent.parseSimple(
        'split',
        '6 access points: 3 upstairs and 3 downstairs',
      );
      expect(
        split.nodes.where((n) => n.type == 'wireless'),
        hasLength(6),
      );
    });

    test('a single-site brief is unchanged', () {
      final single = NetworkIntent.parseSimple(
        'office',
        'a small office with 3 routers, 2 switches and 10 PCs',
      );
      expect(single.nodes.where((n) => n.type == 'router'), hasLength(3));
      expect(single.nodes.where((n) => n.type == 'switch'), hasLength(2));
      expect(single.nodes.where((n) => n.type == 'pc'), hasLength(10));
    });

    test('a parenthetical role list never shrinks the device count', () {
      // "3 Server-PT devices (1 DHCP server, 1 AAA server, 1 DNS server)"
      // states how many devices there are and then what they run. Reading the
      // inner numbers as restatements replaced 3 with 1.
      final plan = NetworkIntent.parseSimple(
        'roles',
        '1 router 1 switch, 3 Server-PT devices (1 DHCP server, 1 AAA server, '
        '1 DNS server) and 15 PCs',
      );
      expect(plan.nodes.where((n) => n.type == 'server'), hasLength(3));
      expect(plan.nodes.where((n) => n.type == 'pc'), hasLength(15));
    });
  });

  group('an address range is not an office-hours window', () {
    // The DHCP pool "192.168.10.100-192.168.10.200" matched the time-range
    // pattern, which produced "weekdays 00-19" - a VTY control the user never
    // asked for, which Packet Tracer cannot enforce, and which therefore
    // blocked the build with no way to clear it.
    //
    // Every brief here carries site wording AND a security word, because that
    // is what routes a brief into the security profile - the one place hours
    // and tunnel keys are read. Without both, these checks would pass for the
    // wrong reason.
    const pool =
        'The headquarters has 2 routers and the branch has 1 router, port '
        'security on the user ports, a DHCP pool of 192.168.10.100-'
        '192.168.10.200, and AAA with tacacs+.';

    test('these briefs really do reach the security profile', () {
      final plan = NetworkIntent.parseSimple('pool', pool);
      expect(
        plan.security.aaa || plan.security.portSecurity,
        isTrue,
        reason: 'otherwise the office-hours checks below prove nothing',
      );
    });

    test('a pool range does not become a time window', () {
      final plan = NetworkIntent.parseSimple('pool', pool);
      expect(plan.security.officeHours, isNull);
    });

    test('an unrequested manager-only VTY rule is not invented', () {
      final plan = NetworkIntent.parseSimple('pool', pool);
      expect(plan.security.managerIp, isNull);
    });

    test('no time-range finding is reported for a plan that asked for none', () {
      final plan = NetworkIntent.parseSimple('pool', pool);
      final issues = ValidatorService.validate(plan, target: 'packet-tracer');
      expect(
        issues.where((i) => i.message.contains('time-range')),
        isEmpty,
      );
    });

    test('hours the user DID state are still read', () {
      final plan = NetworkIntent.parseSimple(
        'hours',
        'AAA with tacacs+ for router logins at the branch during business '
            'hours 09:00 to 17:00.',
      );
      expect(plan.security.officeHours, contains('09:00-17:00'));
    });

    test('hours in Arabic are still read', () {
      final plan = NetworkIntent.parseSimple(
        'arabic-hours',
        'مشروع أمن الشبكات في الفرع الرئيسي والفرع الفرعي. استخدم TACACS+ '
            'للدخول الى الموجه. أوقات الدوام الرسمي من 8:00 الى 16:00.',
      );
      expect(plan.security.officeHours, contains('8:00-16:00'));
    });

    test('a tunnel key is only requested for a tunnel the brief asked for', () {
      final noVpn = NetworkIntent.parseSimple('pool', pool);
      expect(
        noVpn.questions.where((q) => q.toLowerCase().contains('ipsec')),
        isEmpty,
        reason: 'the brief never mentioned a VPN, so it is never asked for '
            'a pre-shared key',
      );
      final withVpn = NetworkIntent.parseSimple(
        'vpn',
        'an ipsec vpn between the headquarters and the branch router, with '
            'port security on the user ports and AAA',
      );
      expect(
        withVpn.questions.where((q) => q.toLowerCase().contains('pre-shared')),
        isNotEmpty,
        reason: 'a brief that asks for a tunnel is asked for its key',
      );
    });

    test('a brief that counts its devices is not taken over by the profile',
        () {
      // The profile is a fixed ten-device lab. A brief that states its own
      // counts has already chosen, and its numbers win - otherwise 25 PCs and
      // 4 servers were replaced by the profile's ten devices, and a follow-up
      // re-parsed to the profile and the merge refused to shrink the lab.
      final counted = NetworkIntent.parseSimple(
        'counted',
        'The headquarters has 2 routers, 2 switches and 4 servers and the '
            'branch has 1 router, 1 switch and 1 server, with AAA at the '
            'branch.',
      );
      expect(
        counted.nodes.length,
        greaterThan(10),
        reason: 'the profile\'s fixed ten devices must not replace a '
            'specification that names 11',
      );
      expect(
        counted.nodes.where((n) => n.type == 'server'),
        hasLength(5),
      );
    });
  });
}
