import '../models/network_intent.dart';
import 'network_math.dart';

/// One row of the project address table: everything an address is, in one
/// place. The VLAN is only ever DERIVED - from a dot1Q sub-interface (`g0/1
/// .10` is VLAN 10) - because the plan carries VLAN ids globally and claims
/// a per-interface VLAN it cannot prove would be a lie with a number in it.
class AddressRow {
  final String device;
  final String iface;
  final String ipv4;
  final String ipv6;
  final String vlan;

  const AddressRow({
    required this.device,
    required this.iface,
    required this.ipv4,
    required this.ipv6,
    required this.vlan,
  });

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '$device $iface $ipv4 $ipv6 $vlan'.toLowerCase().contains(q);
  }
}

/// The plan's addresses as one filterable, exportable table.
///
/// Pure: the table reads the plan and writes nothing. Edits go through
/// [applyEdit], which produces a NEW addressing list the caller can save
/// through the existing plan-save path - the same chain any topology edit
/// takes, so a table edit is a versioned plan edit, never a side channel.
class AddressTable {
  const AddressTable._();

  static final _dot1q = RegExp(r'\.(\d{1,4})$');

  static List<AddressRow> rows(NetworkIntent intent) => [
    for (final a in intent.addressing)
      AddressRow(
        device: a.node,
        iface: a.iface,
        ipv4: a.ipCidr,
        ipv6: a.ip6Cidr ?? '',
        vlan: _dot1q.firstMatch(a.iface)?.group(1) ?? '',
      ),
  ];

  static List<AddressRow> filter(List<AddressRow> rows, String query) => [
    for (final row in rows)
      if (row.matches(query)) row,
  ];

  /// RFC 4180 CSV: quoted when the value carries a comma, quote or newline;
  /// a quote inside is doubled. The device and interface names come from the
  /// user's own brief, so they may be anything.
  static String toCsv(List<AddressRow> rows) {
    String field(String v) =>
        v.contains(',') || v.contains('"') || v.contains('\n')
        ? '"${v.replaceAll('"', '""')}"'
        : v;
    return [
      'device,interface,ipv4,ipv6,vlan',
      ...[
        for (final r in rows)
          [r.device, r.iface, r.ipv4, r.ipv6, r.vlan].map(field).join(','),
      ],
    ].join('\n');
  }

  /// A plan with one interface's addresses replaced - or null when the row
  /// does not exist. Pure: the input plan is untouched, the output is a new
  /// intent with a new addressing list, so the caller saves it through the
  /// normal versioned path and the validator sees a genuinely changed plan
  /// (the revision moves - see [NetworkIntent.revision], which hashes both
  /// the IPv4 and the IPv6 columns).
  static NetworkIntent? applyEdit(
    NetworkIntent intent,
    String device,
    String iface, {
    String? ipv4,
    String? ipv6,
  }) {
    final index = intent.addressing.indexWhere(
      (a) =>
          a.node.toLowerCase() == device.toLowerCase() &&
          a.iface.toLowerCase() == iface.toLowerCase(),
    );
    if (index < 0) return null;
    final current = intent.addressing[index];
    final updated = InterfaceAddr(
      node: current.node,
      iface: current.iface,
      ipCidr: (ipv4 == null || ipv4.trim().isEmpty)
          ? current.ipCidr
          : ipv4.trim(),
      ip6Cidr: ipv6 == null
          ? current.ip6Cidr
          : (ipv6.trim().isEmpty ? null : ipv6.trim()),
    );
    return intent.copyWith(
      addressing: [...intent.addressing]..[index] = updated,
    );
  }

  /// The address checks the edit dialog runs before an edit is accepted.
  /// Pure and shared with the validator's expectations: a bad address is
  /// refused at the table instead of discovered at the build.
  static String? validateAddress(String value, {required bool isV6}) {
    final v = value.trim();
    if (v.isEmpty) {
      return isV6 ? null : 'Enter an IPv4 address; it cannot be cleared here.';
    }
    if (isV6) {
      if (NetworkMath.ipv6Facts(v) == null) {
        return 'Use an IPv6 address with a prefix, e.g. 2001:db8:1::1/64';
      }
      return null;
    }
    final slash = v.indexOf('/');
    final ip = (slash < 0 ? v : v.substring(0, slash)).trim();
    final parts = ip.split('.');
    if (parts.length != 4 ||
        parts.any(
          (p) => !RegExp(r'^\d{1,3}$').hasMatch(p) || int.parse(p) > 255,
        )) {
      return 'Use four 0-255 octets, e.g. 192.168.1.10';
    }
    if (slash >= 0) {
      final prefix = int.tryParse(v.substring(slash + 1).trim());
      if (prefix == null || prefix < 0 || prefix > 32) {
        return 'The prefix must be 0-32, e.g. 192.168.1.10/24';
      }
    }
    return null;
  }
}
