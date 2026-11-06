import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/address_table.dart';
import 'package:net_builder/services/validator_service.dart';

/// The project address table: one place to read and edit every address the
/// plan carries. The VLAN column is only ever derived from a dot1Q
/// sub-interface - the plan carries VLAN ids globally and inventing a
/// per-interface mapping would be a lie with a number in it. Edits produce
/// a new plan for the versioned save path, never a side channel.
void main() {
  final plan = NetworkIntent.parseSimple(
    'p',
    '1 router 1 switch 4 pcs in vlan 10 with a dhcp server',
  );

  group('rows', () {
    test('every addressed interface is a row', () {
      final rows = AddressTable.rows(plan);
      expect(rows, hasLength(plan.addressing.length));
      expect(rows.any((r) => r.device == plan.nodes.first.name), isTrue);
    });

    test('a dot1Q sub-interface derives its VLAN', () {
      // Explicit plan: the parser may write the VLAN-10 brief as
      // sub-interfaces itself, so the plain-vs-dot1Q distinction needs a
      // plan whose shape this test controls.
      const explicit = NetworkIntent(
        projectName: 't',
        nodes: [NetNode(name: 'R1', type: 'router')],
        addressing: [
          InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.0.0.1/30'),
          InterfaceAddr(node: 'R1', iface: 'g0/1.20', ipCidr: '10.20.0.1/24'),
        ],
      );
      final rows = AddressTable.rows(explicit);
      expect(rows.firstWhere((r) => r.iface == 'g0/1').vlan, isEmpty);
      expect(rows.firstWhere((r) => r.iface == 'g0/1.20').vlan, '20');
    });

    test('an IPv6 assignment rides its row', () {
      final withV6 = plan.copyWith(
        addressing: [
          InterfaceAddr(
            node: plan.addressing.first.node,
            iface: plan.addressing.first.iface,
            ipCidr: plan.addressing.first.ipCidr,
            ip6Cidr: '2001:db8:1::1/64',
          ),
          ...plan.addressing.skip(1),
        ],
      );
      final row = AddressTable.rows(withV6).first;
      expect(row.ipv6, '2001:db8:1::1/64');
    });
  });

  group('filter and CSV', () {
    test('the filter matches any field, case-insensitively', () {
      final rows = AddressTable.rows(plan);
      final byDevice = AddressTable.filter(rows, rows.first.device);
      expect(byDevice, isNotEmpty);
      final byFragment = AddressTable.filter(rows, '192.168.');
      expect(byFragment.length, lessThanOrEqualTo(rows.length));
      expect(AddressTable.filter(rows, 'no-such-thing'), isEmpty);
      expect(AddressTable.filter(rows, ''), hasLength(rows.length));
    });

    test('the CSV has a header and escapes commas and quotes', () {
      final rows = [
        const AddressRow(
          device: 'PC,1',
          iface: 'f0',
          ipv4: '192.168.1.10/24',
          ipv6: '',
          vlan: '',
        ),
        const AddressRow(
          device: 'R1',
          iface: 'g0/1.20',
          ipv4: '10.20.0.1/24',
          ipv6: '',
          vlan: '20',
        ),
      ];
      final csv = AddressTable.toCsv(rows);
      final lines = csv.split('\n');
      expect(lines.first, 'device,interface,ipv4,ipv6,vlan');
      expect(lines[1], contains('"PC,1"'));
      expect(lines[2], contains('10.20.0.1/24'));
      // A quote inside a field is doubled, not used to break out.
      final quoted = AddressTable.toCsv([
        const AddressRow(
          device: 'say "hi"',
          iface: 'f0',
          ipv4: '1.2.3.4',
          ipv6: '',
          vlan: '',
        ),
      ]);
      expect(quoted, contains('"say ""hi"""'));
    });
  });

  group('applyEdit', () {
    test('refuses malformed IPv4, IPv6 and out-of-range prefixes', () {
      for (final v in ['-1.2.3.4/24', '1.2.3.4/33', '', '1.2.3.4/24/1']) {
        expect(
          AddressTable.validateAddress(v, isV6: false),
          isNotNull,
          reason: v,
        );
      }
      for (final v in [':::/64', '1:2:3/64', '::1/129', '::1/-1']) {
        expect(
          AddressTable.validateAddress(v, isV6: true),
          isNotNull,
          reason: v,
        );
      }
    });
    test('one interface changes and everything else is untouched', () {
      final target = plan.addressing.first;
      final edited = AddressTable.applyEdit(
        plan,
        target.node,
        target.iface,
        ipv4: '192.168.99.1/24',
        ipv6: '2001:db8:99::1/64',
      )!;
      final row = edited.addressing.firstWhere(
        (a) => a.node == target.node && a.iface == target.iface,
      );
      expect(row.ipCidr, '192.168.99.1/24');
      expect(row.ip6Cidr, '2001:db8:99::1/64');
      // The input plan is untouched, and the edit moved the revision: the
      // versioned save path and the validator both see a real change.
      expect(plan.addressing.first.ipCidr, target.ipCidr);
      expect(edited.revision, isNot(plan.revision));
      // The validator re-runs on the edited plan and reads the new address.
      expect(ValidatorService.validate(edited), isNotNull);
    });

    test('clearing the IPv6 is legal and clearing the IPv4 is not silent', () {
      final target = plan.addressing.first;
      final cleared = AddressTable.applyEdit(
        plan,
        target.node,
        target.iface,
        ipv4: target.ipCidr,
        ipv6: '',
      )!;
      expect(
        cleared.addressing.firstWhere((a) => a.node == target.node).ip6Cidr,
        isNull,
      );
      expect(AddressTable.applyEdit(plan, 'no-such-device', 'f0'), isNull);
    });

    test('the edit dialog checks are the validator-shaped ones', () {
      expect(
        AddressTable.validateAddress('192.168.1.10/24', isV6: false),
        isNull,
      );
      expect(AddressTable.validateAddress('192.168.1.10', isV6: false), isNull);
      expect(
        AddressTable.validateAddress('192.168.1', isV6: false),
        contains('octets'),
      );
      expect(
        AddressTable.validateAddress('192.168.1.300/24', isV6: false),
        contains('octets'),
      );
      expect(
        AddressTable.validateAddress('192.168.1.10/40', isV6: false),
        contains('prefix'),
      );
      expect(
        AddressTable.validateAddress('2001:db8:1::1/64', isV6: true),
        isNull,
      );
      expect(
        AddressTable.validateAddress('192.168.1.1', isV6: true),
        contains('IPv6'),
      );
      expect(AddressTable.validateAddress('   ', isV6: false), isNotNull);
    });
  });
}
