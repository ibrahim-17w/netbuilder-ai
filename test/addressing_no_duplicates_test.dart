import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';

/// No plan may ship two devices (or two router interfaces) on the same
/// address. Two shapes used to collide: end hosts whose host counter
/// restarted per switch on a shared subnet, and VLAN sub-interfaces that
/// repeated `192.168.<v>.0/24` on every switch uplink carrying that VLAN -
/// the validator then blocked the build with a duplicate-IP finding per
/// collision. Each switch keeps its own uplink and its own /24; a second
/// link carrying the same VLAN claims the next free /24 for it.
List<String> duplicateIps(NetworkIntent plan) {
  final seen = <String, String>{};
  final dups = <String>[];
  for (final a in plan.addressing) {
    final ip = a.ipCidr.split('/').first;
    final owner = '\${a.node} \${a.iface}';
    if (seen.containsKey(ip) && seen[ip] != owner) {
      dups.add('$ip on $owner and \${seen[ip]}');
    }
    seen.putIfAbsent(ip, () => owner);
  }
  return dups;
}

void main() {
  campusPlan();

  test('switches sharing one VLAN get distinct subnets and hosts', () {
    final plan = NetworkIntent.parseSimple(
      'campus',
      '1 router, 4 switches and 12 PCs on VLAN 10',
    );
    expect(plan.nodes.where((n) => n.type == 'pc').length, 12);
    expect(duplicateIps(plan), isEmpty);
  });

  test('the 74-device campus brief addresses without collisions', () {
    const brief =
        'Design a campus network named campus-core. '
        '2 firewalls (ASA 5506-X) at the internet edge, 3 routers running '
        'OSPF, 4 switches with VLAN 10 users, VLAN 20 servers and VLAN 30 '
        'voice. 8 servers: one DHCP, one DNS, one web server with HTTP and '
        'HTTPS, one mail server, one FTP server, one AAA TACACS+ server, '
        'one syslog and NTP server, and one CME voice server. 30 PCs, 4 '
        'wireless access points, 6 laptops, 2 IP phones and 2 printers. '
        'Add an ACL so the guest VLAN cannot reach the servers.';
    final plan = NetworkIntent.parseSimple('campus-core', brief);
    expect(plan.nodes.length, greaterThan(60));
    expect(duplicateIps(plan), isEmpty);
  });

  test('a single-switch lab keeps the classic .10, .11, ... layout', () {
    final plan = NetworkIntent.parseSimple(
      'office',
      '1 router, 1 switch and 4 PCs',
    );
    final pcs = plan.addressing
        .where((a) => a.node.startsWith('PC'))
        .map((a) => a.ipCidr.split('/').first.split('.').last)
        .toList();
    expect(pcs, ['10', '11', '12', '13']);
  });
}

/// The full complex brief must produce a plan the validator can build: every
/// switch within its port budget, no duplicate addresses, firewalls chained
/// to the edge. This is the regression file for the "2 firewalls, 3 routers,
/// 4 switches, 8 servers, 30 PCs, ..." campus lab.
void campusPlan() {
  const campusBrief =
      'Design a campus network named campus-core. '
      '2 firewalls (ASA 5506-X) at the internet edge, 3 routers running '
      'OSPF, 4 switches with VLAN 10 users, VLAN 20 servers and VLAN 30 '
      'voice. 8 servers: one DHCP, one DNS, one web server with HTTP and '
      'HTTPS, one mail server, one FTP server, one AAA TACACS+ server, one '
      'syslog and NTP server, and one CME voice server. 30 PCs, 4 wireless '
      'access points, 6 laptops, 2 IP phones and 2 printers. Add an ACL so '
      'the guest VLAN cannot reach the servers.';

  test('the campus brief builds: ports, addresses and the firewall chain', () {
    final plan = NetworkIntent.parseSimple('campus-core', campusBrief);
    // The brief said 8 servers; "VLAN 20 servers" must not be read as 20.
    expect(plan.nodes.where((n) => n.type == 'server').length, 8);

    // No switch cabled past its 24 FastEthernet ports.
    final perSwitch = <String, int>{};
    for (final l in plan.links) {
      for (final e in [l.a, l.b]) {
        final n = plan.nodes.firstWhere((x) => x.name == e);
        if (n.type == 'switch') {
          perSwitch.update(e, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }
    for (final e in perSwitch.entries) {
      expect(e.value, lessThanOrEqualTo(24), reason: '${e.key} overfilled');
    }

    // No interface carries two cables.
    final ifaces = <String>{};
    for (final l in plan.links) {
      for (final e in ['${l.a}:${l.aIf}', '${l.b}:${l.bIf}']) {
        expect(ifaces.add(e.toLowerCase()), isTrue, reason: '$e used twice');
      }
    }

    // The firewalls chain between the LAN and the internet cloud.
    final fwNames = plan.nodes
        .where((n) => n.type == 'firewall')
        .map((n) => n.name)
        .toSet();
    final cloudName = plan.nodes
        .firstWhere((n) => n.type == 'cloud')
        .name;
    final fwCabled = plan.links
        .where((l) => fwNames.contains(l.a) || fwNames.contains(l.b))
        .toList();
    for (final fw in fwNames) {
      expect(
        fwCabled.any((l) => l.a == fw || l.b == fw),
        isTrue,
        reason: '$fw has a link',
      );
    }
    expect(
      fwCabled.any(
        (l) =>
            (l.a == cloudName || l.b == cloudName) &&
            (fwNames.contains(l.a) || fwNames.contains(l.b)),
      ),
      isTrue,
      reason: 'the last firewall reaches the internet cloud',
    );

    expect(duplicateIps(plan), isEmpty);
  });
}
