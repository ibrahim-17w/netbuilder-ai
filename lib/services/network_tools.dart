import 'dart:convert';

/// Deterministic networking facts. Spec §5: the app decides the technical
/// truth, the model only decides what to look at.
///
/// Everything here is pure and testable: IPv4 maths, subnet membership,
/// duplicate-address detection, gateway validity and a size-bounded structured
/// view of an opened .pkt (spec §6). No I/O, no model, no side effects.
class SubnetInfo {
  final String network;
  final String broadcast;
  final String firstHost;
  final String lastHost;
  final int prefix;
  final int totalAddresses;
  final int usableHosts;

  const SubnetInfo({
    required this.network,
    required this.broadcast,
    required this.firstHost,
    required this.lastHost,
    required this.prefix,
    required this.totalAddresses,
    required this.usableHosts,
  });

  String get mask => NetworkTools.prefixToMask(prefix);

  Map<String, dynamic> toJson() => {
    'network': network,
    'broadcast': broadcast,
    'firstHost': firstHost,
    'lastHost': lastHost,
    'prefix': prefix,
    'mask': mask,
    'totalAddresses': totalAddresses,
    'usableHosts': usableHosts,
  };
}

class NetworkTools {
  const NetworkTools._();

  /// 10.0.0.5/24 -> 4294967040 style mask, as the dotted quad a Cisco config
  /// shows (`255.255.255.0`).
  static String prefixToMask(int prefix) {
    if (prefix < 0 || prefix > 32) return '';
    final value = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
        '${(value >> 8) & 0xFF}.${value & 0xFF}';
  }

  /// Parse "10.0.0.5/24" (or an address + a separate prefix).
  static (int, int)? parseCidr(String cidr) {
    final parts = cidr.trim().split('/');
    if (parts.length != 2) return null;
    final ip = ipToInt(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (ip == null || prefix == null || prefix < 0 || prefix > 32) return null;
    return (ip, prefix);
  }

  static int? ipToInt(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      value = (value << 8) | octet;
    }
    return value;
  }

  static String intToIp(int value) =>
      '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
      '${(value >> 8) & 0xFF}.${value & 0xFF}';

  /// Everything you can state about one CIDR.
  static SubnetInfo? subnet(String cidr) {
    final parsed = parseCidr(cidr);
    if (parsed == null) return null;
    final (ip, prefix) = parsed;
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final network = ip & mask;
    final broadcast = network | (~mask & 0xFFFFFFFF);
    final total = prefix == 32 ? 1 : (1 << (32 - prefix));
    // A /31 and /32 have no "network/broadcast" reservation in modern practice.
    final usable = prefix >= 31 ? total : (total >= 2 ? total - 2 : 0);
    return SubnetInfo(
      network: intToIp(network),
      broadcast: intToIp(broadcast),
      firstHost: intToIp(prefix >= 31 ? network : network + 1),
      lastHost: intToIp(prefix >= 31 ? broadcast : broadcast - 1),
      prefix: prefix,
      totalAddresses: total,
      usableHosts: usable,
    );
  }

  /// Do two interfaces sit in the same subnet? This is the question behind
  /// "are these devices on the same subnet?".
  static bool sameSubnet(String cidrA, String cidrB) {
    final a = parseCidr(cidrA);
    final b = parseCidr(cidrB);
    if (a == null || b == null) return false;
    final (ipA, prefixA) = a;
    final (ipB, prefixB) = b;
    // They can only be in one subnet if the masks agree.
    if (prefixA != prefixB) return false;
    final mask = prefixA == 0 ? 0 : (0xFFFFFFFF << (32 - prefixA)) & 0xFFFFFFFF;
    return (ipA & mask) == (ipB & mask);
  }

  /// Is an address inside a subnet? (Ignoring the network/broadcast rules,
  /// which is what a user means when they ask it.)
  static bool contains(String cidr, String address) {
    final net = parseCidr(cidr);
    final ip = ipToInt(address);
    if (net == null || ip == null) return false;
    final (base, prefix) = net;
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (ip & mask) == (base & mask);
  }

  /// A gateway must be a usable address inside the host's own subnet.
  static Map<String, dynamic> checkGateway({
    required String hostCidr,
    required String gateway,
  }) {
    final info = subnet(hostCidr);
    final gw = ipToInt(gateway);
    if (info == null) {
      return {'ok': false, 'reason': 'the host address `$hostCidr` is not valid'};
    }
    if (gw == null) {
      return {'ok': false, 'reason': 'the gateway `$gateway` is not valid'};
    }
    if (!contains(hostCidr, gateway)) {
      return {
        'ok': false,
        'reason': '$gateway is outside ${info.network}/${info.prefix}',
        'subnet': info.toJson(),
      };
    }
    if (gateway == info.network) {
      return {'ok': false, 'reason': '$gateway is the network address'};
    }
    if (gateway == info.broadcast) {
      return {'ok': false, 'reason': '$gateway is the broadcast address'};
    }
    if (gateway == hostCidr.split('/').first) {
      return {'ok': false, 'reason': 'the gateway is the host itself'};
    }
    return {'ok': true, 'reason': '$gateway is usable inside '
        '${info.network}/${info.prefix}', 'subnet': info.toJson()};
  }

  /// Any address that appears twice on the same subnet is a real fault.
  static List<Map<String, dynamic>> duplicateAddresses(
    List<Map<String, dynamic>> interfaces,
  ) {
    final seen = <String, List<String>>{};
    for (final entry in interfaces) {
      final cidr = (entry['ipCidr'] ?? '').toString();
      final ip = cidr.split('/').first;
      if (ip.isEmpty) continue;
      seen.putIfAbsent(ip, () => []).add(
        '${entry['node'] ?? '?'} ${entry['iface'] ?? ''}'.trim(),
      );
    }
    return [
      for (final entry in seen.entries)
        if (entry.value.length > 1)
          {'address': entry.key, 'usedBy': entry.value},
    ];
  }

  /// Spec §6: one clean representation for the model - never raw .pkt bytes.
  /// [maxChars] keeps a huge capture from flooding the context window.
  static Map<String, dynamic> buildContext(
    Map<String, dynamic> audit, {
    int maxChars = 12000,
  }) {
    final devices = <Map<String, dynamic>>[];
    final interfaces = <Map<String, dynamic>>[];
    final findings = <Map<String, dynamic>>[];
    for (final d in ((audit['devices'] as List?) ?? const [])) {
      final device = Map<String, dynamic>.from(d as Map);
      devices.add({
        'name': device['name'],
        'type': device['type'],
        'model': device['model'],
      });
      for (final i in ((device['interfaces'] as List?) ?? const [])) {
        interfaces.add(Map<String, dynamic>.from(i as Map));
      }
      for (final f in ((device['findings'] as List?) ?? const [])) {
        findings.add(Map<String, dynamic>.from(f as Map));
      }
    }
    final context = <String, dynamic>{
      'devices': devices,
      'interfaces': interfaces,
      'links': (audit['links'] as List?) ?? const [],
      'vlans': (audit['vlans'] as List?) ?? const [],
      'routes': (audit['routes'] as List?) ?? const [],
      'services': (audit['services'] as List?) ?? const [],
      'findings': findings,
      'duplicateAddresses': duplicateAddresses(interfaces),
    };
    var encoded = jsonEncode(context);
    if (encoded.length > maxChars) {
      // Trim the least useful part first, then say that we did.
      context['findings'] = findings.take(20).toList();
      context['interfaces'] = interfaces.take(80).toList();
      context['truncated'] = true;
      encoded = jsonEncode(context);
      if (encoded.length > maxChars) {
        context['links'] = const [];
        context['routes'] = const [];
        encoded = jsonEncode(context);
      }
    }
    return context;
  }
}
