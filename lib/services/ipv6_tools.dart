import 'dart:math';

/// IPv6 address arithmetic for the Network toolkit: canonical forms, address
/// classification, EUI-64 interface identifiers and prefix sizes.
///
/// Everything here is pure and deterministic, like the subnet arithmetic in
/// [NetworkTools] - the toolkit renders what these functions return and can
/// never disagree with a unit test about what an address is.
class Ipv6Tools {
  const Ipv6Tools._();

  /// The 16 bytes of a valid IPv6 address, or null when [input] is not one.
  ///
  /// Accepts every RFC 4291 text form: full, `::`-compressed, embedded
  /// IPv4 (`::ffff:192.168.1.1`) and a trailing `%zone` (the zone is
  /// ignored for arithmetic).
  static List<int>? parse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    final zone = text.indexOf('%');
    if (zone >= 0) text = text.substring(0, zone);
    // Split on the compression marker; at most one is legal.
    final doubleColon = text.indexOf('::');
    final head = doubleColon < 0 ? text : text.substring(0, doubleColon);
    final tail = doubleColon < 0 ? '' : text.substring(doubleColon + 2);
    if (doubleColon >= 0 && text.indexOf('::', doubleColon + 1) >= 0) {
      return null;
    }
    final groups = <int>[];
    // An IPv4 tail is 2 groups' worth embedded in the last 32 bits.
    final headParts = head.isEmpty ? <String>[] : head.split(':');
    final tailParts = tail.isEmpty ? <String>[] : tail.split(':');
    if (headParts.isNotEmpty && _ipv4Tail(headParts.last)) {
      final v4 = _ipv4Groups(headParts.removeLast());
      if (v4 == null) return null;
      headParts.addAll(v4);
    }
    if (tailParts.isNotEmpty && _ipv4Tail(tailParts.last)) {
      final v4 = _ipv4Groups(tailParts.removeLast());
      if (v4 == null) return null;
      tailParts.addAll(v4);
    }
    for (final part in [...headParts, ...tailParts]) {
      if (part.length > 4) return null;
      final value = int.tryParse(part, radix: 16);
      if (value == null || value < 0 || value > 0xffff) return null;
      groups.add(value);
    }
    if (doubleColon < 0) {
      if (groups.length != 8) return null;
    } else {
      if (groups.length > 7) return null;
      final missing = 8 - groups.length;
      if (headParts.isEmpty && tailParts.isEmpty) {
        // "::" alone is the unspecified address: 16 zero BYTES.
        return List<int>.filled(16, 0);
      }
      groups.insertAll(headParts.length, List<int>.filled(missing, 0));
    }
    final out = <int>[];
    for (final g in groups) {
      out.addAll([(g >> 8) & 0xff, g & 0xff]);
    }
    return out;
  }

  static bool _ipv4Tail(String part) => part.contains('.');

  /// The two GROUP TEXTS an embedded dotted-quad contributes, or null when
  /// it is not a valid IPv4 address.
  static List<String>? _ipv4Groups(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final p in parts) {
      final octet = int.tryParse(p);
      if (octet == null || octet < 0 || octet > 255) return null;
      value = (value << 8) | octet;
    }
    return [
      ((value >> 16) & 0xffff).toRadixString(16),
      (value & 0xffff).toRadixString(16),
    ];
  }

  static String _group(List<int> bytes, int i) =>
      ((bytes[i * 2] << 8) | bytes[i * 2 + 1]).toRadixString(16);

  /// The fully expanded form: eight lowercase 4-digit groups.
  static String? expand(String input) {
    final bytes = parse(input);
    if (bytes == null) return null;
    return [for (var i = 0; i < 8; i++) _group(bytes, i).padLeft(4, '0')]
        .join(':');
  }

  /// The canonical compressed form per RFC 5952: lowercase, leading zeros
  /// suppressed, and one `::` covering the LONGEST run of zero groups (the
  /// leftmost on a tie); a run of a single group is not compressed.
  static String? compress(String input) {
    final bytes = parse(input);
    if (bytes == null) return null;
    final groups = [for (var i = 0; i < 8; i++) _group(bytes, i)];
    var bestStart = -1;
    var bestLen = 0;
    var runStart = -1;
    for (var i = 0; i < 8; i++) {
      if (groups[i] == '0') {
        if (runStart < 0) runStart = i;
        final len = i - runStart + 1;
        if (len > bestLen) {
          bestLen = len;
          bestStart = runStart;
        }
      } else {
        runStart = -1;
      }
    }
    if (bestLen < 2) {
      // A lone zero group stays literal, and no run means no "::" at all.
      return groups.join(':');
    }
    final head = bestStart < 0
        ? groups
        : groups.sublist(0, bestStart);
    final tail = bestStart < 0
        ? const <String>[]
        : groups.sublist(bestStart + bestLen);
    return '${head.join(':')}::${tail.join(':')}';
  }

  /// What the address is for, in the words a toolkit user can act on.
  static String? classify(String input) {
    final bytes = parse(input);
    if (bytes == null) return null;
    final g0 = (bytes[0] << 8) | bytes[1];
    if (bytes.every((b) => b == 0)) return 'unspecified (::)';
    if (bytes[15] == 1 && bytes.sublist(0, 15).every((b) => b == 0)) {
      return 'loopback (::1)';
    }
    if (bytes[0] == 0xff) return 'multicast (ff00::/8)';
    if (bytes.sublist(0, 10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return 'IPv4-mapped (::ffff:0:0/96)';
    }
    if ((bytes[0] & 0xfe) == 0xfc) return 'unique-local (fc00::/7)';
    if ((bytes[0] & 0xff) == 0xfe && (bytes[1] & 0xc0) == 0x80) {
      return 'link-local (fe80::/10)';
    }
    if (g0 == 0x2002) return '6to4 (2002::/16)';
    final g1 = (bytes[2] << 8) | bytes[3];
    if (g0 == 0x2001 && g1 == 0x0db8) {
      return 'documentation (2001:db8::/32)';
    }
    if ((bytes[0] & 0xe0) == 0x20) return 'global unicast (2000::/3)';
    return 'other (reserved or special-purpose)';
  }

  /// The bytes of a MAC address in `xx:xx:xx:xx:xx:xx` or `xx-...` form,
  /// or null.
  static List<int>? parseMac(String input) {
    final clean = input.trim().replaceAll(':', '').replaceAll('-', '');
    if (clean.length != 12) return null;
    final out = <int>[];
    for (var i = 0; i < 12; i += 2) {
      final b = int.tryParse(clean.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }

  /// The EUI-64 interface identifier bytes for [mac]: ff:fe spliced into the
  /// middle and the universal/local bit flipped.
  static List<int>? eui64(String mac) {
    final m = parseMac(mac);
    if (m == null) return null;
    return [
      m[0] ^ 0x02,
      m[1],
      m[2],
      0xff,
      0xfe,
      m[3],
      m[4],
      m[5],
    ];
  }

  /// The address a host with [mac] gets inside [prefixCidr] (a /64 by the
  /// Ethernet SLAAC convention), or null when either input is invalid or the
  /// prefix is not /64.
  static String? eui64Address(String mac, String prefixCidr) {
    final id = eui64(mac);
    if (id == null) return null;
    final slash = prefixCidr.indexOf('/');
    if (slash < 0) return null;
    final prefix = parse(prefixCidr.substring(0, slash));
    if (prefix == null) return null;
    final bits = int.tryParse(prefixCidr.substring(slash + 1));
    if (bits == null || bits < 0 || bits > 128) return null;
    if (bits != 64) return null; // EUI-64 lives in the second half
    final address = [...prefix.sublist(0, 8), ...id];
    return compress(_fromBytes(address));
  }

  /// The solicited-node multicast address of [input]:
  /// ff02::1:ffXX:XXXX, the last 24 bits of the address.
  static String? solicitedNode(String input) {
    final bytes = parse(input);
    if (bytes == null) return null;
    final g6 = 'ff${_hexByte(bytes[13])}';
    final g7 = '${_hexByte(bytes[14])}${_hexByte(bytes[15])}';
    return 'ff02::1:$g6:$g7';
  }

  static String _hexByte(int b) => b.toRadixString(16).padLeft(2, '0');

  /// The link-local address a host with [mac] self-assigns: fe80::/64 plus
  /// the EUI-64 identifier.
  static String? linkLocalFromMac(String mac) {
    final id = eui64(mac);
    if (id == null) return null;
    return compress(
      _fromBytes([0xfe, 0x80, 0, 0, 0, 0, 0, 0, ...id]),
    );
  }

  static String _fromBytes(List<int> bytes) =>
      [for (var i = 0; i < 8; i++) _group(bytes, i)].join(':');

  /// The facts a prefix panel shows, or null when [cidr] is not IPv6.
  static Map<String, String>? prefixInfo(String cidr) {
    final slash = cidr.indexOf('/');
    if (slash < 0) return null;
    final bytes = parse(cidr.substring(0, slash));
    if (bytes == null) return null;
    final bits = int.tryParse(cidr.substring(slash + 1));
    if (bits == null || bits < 0 || bits > 128) return null;
    final hostBits = 128 - bits;
    final total = BigInt.two.pow(hostBits);
    final subnet64 = hostBits >= 64
        ? BigInt.two.pow(hostBits - 64)
        : BigInt.one;
    // The first address of the prefix, with the host bits masked off.
    final masked = <int>[...bytes];
    for (var i = 0; i < 16; i++) {
      final bitIndex = i * 8; // from the left
      if (bitIndex + 8 <= bits) continue; // fully inside the prefix
      if (bitIndex >= bits) {
        masked[i] = 0; // fully inside the host part
      } else {
        final keep = bits - bitIndex;
        masked[i] = bytes[i] & (0xff << (8 - keep)) & 0xff;
      }
    }
    return {
      'network': compress(_fromBytes(masked))!,
      'prefix': '/$bits',
      'host bits': '$hostBits',
      'total addresses': total.toString(),
      '/64 subnets': subnet64.toString(),
      'first address': compress(_fromBytes(masked))!,
    };
  }

  /// Split [cidr] into its first [count] `/<newPrefix>` child subnets.
  /// Returns null when the split is impossible or [count] does not fit.
  static List<String>? split(String cidr, int newPrefix, {int count = 8}) {
    final slash = cidr.indexOf('/');
    if (slash < 0) return null;
    final bytes = parse(cidr.substring(0, slash));
    if (bytes == null) return null;
    final bits = int.tryParse(cidr.substring(slash + 1));
    if (bits == null || bits < 0 || bits > 128) return null;
    if (newPrefix <= bits || newPrefix > 128) return null;
    final width = 1 << (newPrefix - bits);
    final shown = min(count, width);
    if (shown <= 0) return null;
    final out = <String>[];
    for (var i = 0; i < shown; i++) {
      final child = <int>[...bytes];
      for (var b = bits; b < newPrefix; b++) {
        final byteIndex = b ~/ 8;
        final bitIndex = 7 - (b % 8);
        final set = (i >> (newPrefix - 1 - b)) & 1;
        child[byteIndex] =
            (child[byteIndex] | (set << bitIndex)) & 0xff;
      }
      out.add('${compress(_fromBytes(child))}/$newPrefix');
    }
    return out;
  }
}
