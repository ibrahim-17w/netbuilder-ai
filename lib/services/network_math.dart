import 'network_tools.dart';

/// The rest of IPv4 arithmetic, next to [NetworkTools].
///
/// [NetworkTools] answers "what is in this subnet?" - the questions the
/// validator needs while a plan is being checked. A network engineer at a
/// console asks more than that: how do I carve this block up, do these two
/// ranges collide, what is the ACL wildcard, what is the smallest set of
/// prefixes that covers this range (route summarization)? Each of those is
/// arithmetic, so it lives here rather than in a screen - pure, synchronous
/// and unit-tested, with no I/O anywhere.
class IpRange {
  final int start;
  final int end;

  const IpRange(this.start, this.end);

  String get startIp => NetworkTools.intToIp(start);
  String get endIp => NetworkTools.intToIp(end);

  /// Both ends inclusive, as a person counts addresses.
  int get count => end - start + 1;
}

/// How an address is scoped. This decides whether an address is routable on
/// the public internet, which is a question every design raises.
enum IpScope {
  rfc1918,
  publicAddress,
  loopback,
  linkLocal,
  multicast,
  carrierNat,
  documentation,
  benchmarking,
  reserved,
}

extension IpScopeLabel on IpScope {
  String get label => switch (this) {
    IpScope.rfc1918 => 'private (RFC 1918)',
    IpScope.publicAddress => 'public',
    IpScope.loopback => 'loopback',
    IpScope.linkLocal => 'link-local (APIPA)',
    IpScope.multicast => 'multicast',
    IpScope.carrierNat => 'carrier NAT (RFC 6598)',
    IpScope.documentation => 'documentation (RFC 5737)',
    IpScope.benchmarking => 'benchmarking (RFC 2544)',
    IpScope.reserved => 'reserved',
  };
}

/// One block allocated by [NetworkMath.vlsm].
class VlsmAllocation {
  final String name;
  final int hostsRequested;
  final String network;
  final int prefix;
  final String mask;
  final String firstHost;
  final String lastHost;
  final String broadcast;
  final int usableHosts;

  /// Empty when the row is fine; a sentence when it is not (it did not fit in
  /// the block, or it holds fewer hosts than asked for).
  final String note;

  const VlsmAllocation({
    required this.name,
    required this.hostsRequested,
    required this.network,
    required this.prefix,
    required this.mask,
    required this.firstHost,
    required this.lastHost,
    required this.broadcast,
    required this.usableHosts,
    this.note = '',
  });
}

class NetworkMath {
  const NetworkMath._();

  /// 255.255.255.0 -> 24. Returns null when the mask is not contiguous,
  /// because a holey mask is a config error and guessing a prefix from it
  /// would hide that.
  static int? prefixFromMask(String mask) {
    final value = NetworkTools.ipToInt(mask);
    if (value == null) return null;
    var seenZero = false;
    var bits = 0;
    for (var i = 31; i >= 0; i--) {
      final bit = (value >> i) & 1;
      if (bit == 0) {
        seenZero = true;
      } else {
        if (seenZero) return null; // a 1 after a 0: not a mask
        bits++;
      }
    }
    return bits;
  }

  /// The ACL inverse mask for a prefix: /24 -> 0.0.0.255.
  ///
  /// It is the bitwise complement of the subnet mask, which is *not* the same
  /// as a mask of the remaining bits: /26 is 0.0.0.63, not 252.0.0.0.
  static String wildcardFromPrefix(int prefix) =>
      NetworkTools.intToIp((~_maskOf(prefix)) & 0xFFFFFFFF);

  /// The ACL inverse mask for a dotted mask, or '' when it is not contiguous.
  static String wildcardFromMask(String mask) {
    final prefix = prefixFromMask(mask);
    return prefix == null ? '' : wildcardFromPrefix(prefix);
  }

  /// The address as 32 bits in four dotted groups - what "explain this
  /// address in binary" means to someone learning subnetting.
  static String binary(String ip) => _bits(NetworkTools.ipToInt(ip));

  /// The mask as 32 bits: 1s for the network part, 0s for the host part. The
  /// split between them is the thing a student is being asked to find.
  static String binaryMask(int prefix) =>
      _bits(prefix <= 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF);

  static String _bits(int? value) {
    if (value == null) return '';
    final out = <String>[];
    // 24, 16, 8, 0: the four octets. Shifting from 31 would read the top bit
    // of each byte rather than the byte itself.
    for (var shift = 24; shift >= 0; shift -= 8) {
      out.add(((value >> shift) & 0xFF).toRadixString(2).padLeft(8, '0'));
    }
    return out.join('.');
  }

  /// Two's-complement-free helpers. Shifts wider than 32 bits are avoided on
  /// purpose: they are the one place 32-bit and 64-bit integer behaviour
  /// disagree, and this file has to give the same answer everywhere.
  static int _floorLog2(int value) {
    var bits = 0;
    var v = value;
    while (v > 1) {
      v >>= 1;
      bits++;
    }
    return bits;
  }

  static int _trailingZeros(int value) {
    if (value == 0) return 32;
    var bits = 0;
    while (((value >> bits) & 1) == 0) {
      bits++;
    }
    return bits;
  }

  static int _maskOf(int prefix) =>
      prefix <= 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

  /// Every usable address of a CIDR as a closed range, or null when the CIDR
  /// itself is not valid.
  static IpRange? hostRange(String cidr) {
    final info = NetworkTools.subnet(cidr);
    if (info == null) return null;
    final start = NetworkTools.ipToInt(info.firstHost);
    final end = NetworkTools.ipToInt(info.lastHost);
    if (start == null || end == null) return null;
    return IpRange(start, end);
  }

  /// Where an address sits in the address plan: private, public, loopback and
  /// the rest of the special-purpose ranges.
  static IpScope scope(String ip) {
    final bare = ip.split('/').first.trim();
    final value = NetworkTools.ipToInt(bare);
    if (value == null) return IpScope.reserved;
    bool inRange(String cidr) => NetworkTools.contains(cidr, bare);
    if (inRange('10.0.0.0/8') ||
        inRange('172.16.0.0/12') ||
        inRange('192.168.0.0/16')) {
      return IpScope.rfc1918;
    }
    if (inRange('127.0.0.0/8')) return IpScope.loopback;
    if (inRange('169.254.0.0/16')) return IpScope.linkLocal;
    if (inRange('100.64.0.0/10')) return IpScope.carrierNat;
    if (inRange('192.0.2.0/24') ||
        inRange('198.51.100.0/24') ||
        inRange('203.0.113.0/24')) {
      return IpScope.documentation;
    }
    if (inRange('198.18.0.0/15')) return IpScope.benchmarking;
    if (inRange('224.0.0.0/4') || value == 0xFFFFFFFF) {
      return IpScope.multicast;
    }
    if (value == 0) return IpScope.reserved;
    if (inRange('240.0.0.0/4')) return IpScope.reserved;
    return IpScope.publicAddress;
  }

  static bool isPrivate(String ip) => scope(ip) == IpScope.rfc1918;

  /// The classful letter. Kept because a lab exercise asks for it and because
  /// old material still derives a default mask from it.
  static String classfulClass(String ip) {
    final value = NetworkTools.ipToInt(ip.split('/').first.trim());
    if (value == null) return '?';
    final first = (value >> 24) & 0xFF;
    if (first < 128) return 'A';
    if (first < 192) return 'B';
    if (first < 224) return 'C';
    if (first < 240) return 'D (multicast)';
    return 'E (reserved)';
  }

  static String classfulMask(String ip) => switch (classfulClass(ip)) {
    'A' => '255.0.0.0',
    'B' => '255.255.0.0',
    'C' => '255.255.255.0',
    _ => '',
  };

  /// Carve one network into equal smaller networks. "Split 10.0.0.0/22 into
  /// /24s" is a daily question, and typing the list out by hand is where
  /// mistakes come from.
  ///
  /// Returns an empty list for an invalid request, and refuses to build more
  /// than 4096 entries ([splitCount] says how many there would be, so a
  /// screen can explain the refusal instead of showing nothing).
  static List<String> split(String cidr, int newPrefix) {
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return const [];
    final (base, prefix) = parsed;
    if (newPrefix < prefix || newPrefix > 32) return const [];
    final count = 1 << (newPrefix - prefix);
    if (count > 4096) return const [];
    final network = base & _maskOf(prefix);
    final size = 1 << (32 - newPrefix);
    return [
      for (var i = 0; i < count; i++)
        '${NetworkTools.intToIp(network + i * size)}/$newPrefix',
    ];
  }

  /// Count of equal-sized subnets of [newPrefix] that fit in [cidr].
  static int splitCount(String cidr, int newPrefix) {
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return 0;
    final (_, prefix) = parsed;
    if (newPrefix < prefix || newPrefix > 32) return 0;
    return 1 << (newPrefix - prefix);
  }

  /// The smallest prefix that holds [hosts] usable addresses.
  ///
  /// "Usable" means "can be put on an interface". A /32 holds one address and
  /// a /30 holds the two that a point-to-point link wants, which is why two
  /// hosts deliberately gets a /30 rather than RFC 3021's /31: Packet Tracer
  /// and plenty of older gear still reject a /31 on a link.
  static int prefixForHosts(int hosts) {
    if (hosts <= 1) return 32;
    if (hosts == 2) return 30;
    var prefix = 32;
    while (prefix > 0) {
      if ((1 << (32 - prefix)) - 2 >= hosts) return prefix;
      prefix--;
    }
    return 0;
  }

  /// The VLSM plan for a list of named host requirements.
  ///
  /// Requirements are allocated largest-first - the only order that never
  /// wastes a block - and each allocation is the smallest that fits. When the
  /// base block runs out, the remaining rows come back with a note saying so:
  /// silently dropping a site would be worse than a plan that visibly does
  /// not fit.
  static List<VlsmAllocation> vlsm(
    String baseCidr,
    List<({String name, int hosts})> requirements,
  ) {
    final parsed = NetworkTools.parseCidr(baseCidr);
    if (parsed == null || requirements.isEmpty) return const [];
    final (base, basePrefix) = parsed;
    final limit = (base & _maskOf(basePrefix)) + (1 << (32 - basePrefix));
    var cursor = base & _maskOf(basePrefix);

    final ordered = [...requirements]
      ..sort((a, b) => b.hosts.compareTo(a.hosts));
    final out = <VlsmAllocation>[];

    for (final need in ordered) {
      final prefix = prefixForHosts(need.hosts);
      final size = 1 << (32 - prefix);
      // Align up: a block that does not start on its own network address is
      // not a block, and an unaligned cursor would produce one.
      final aligned = ((cursor + size - 1) ~/ size) * size;
      if (aligned + size > limit || aligned > 0xFFFFFFFF) {
        out.add(
          VlsmAllocation(
            name: need.name,
            hostsRequested: need.hosts,
            network: '',
            prefix: prefix,
            mask: '',
            firstHost: '',
            lastHost: '',
            broadcast: '',
            usableHosts: 0,
            note: 'does not fit in $baseCidr - it needs a /$prefix of its own',
          ),
        );
        continue;
      }
      final info =
          NetworkTools.subnet('${NetworkTools.intToIp(aligned)}/$prefix');
      if (info == null) continue;
      out.add(
        VlsmAllocation(
          name: need.name,
          hostsRequested: need.hosts,
          network: '${info.network}/$prefix',
          prefix: prefix,
          mask: info.mask,
          firstHost: info.firstHost,
          lastHost: info.lastHost,
          broadcast: info.broadcast,
          usableHosts: info.usableHosts,
          note: info.usableHosts >= need.hosts
              ? ''
              : 'holds ${info.usableHosts} usable, '
                    '${need.hosts - info.usableHosts} short',
        ),
      );
      cursor = aligned + size;
    }
    return out;
  }

  /// Do two CIDRs share any address? Same subnet, or one inside the other.
  static bool overlaps(String a, String b) {
    final pa = NetworkTools.parseCidr(a);
    final pb = NetworkTools.parseCidr(b);
    if (pa == null || pb == null) return false;
    final (baseA, prefixA) = pa;
    final (baseB, prefixB) = pb;
    final netA = baseA & _maskOf(prefixA);
    final netB = baseB & _maskOf(prefixB);
    // The wider (shorter-prefix) block decides: the narrower block only has
    // to fall inside it.
    if (prefixA <= prefixB) return (netB & _maskOf(prefixA)) == netA;
    return (netA & _maskOf(prefixB)) == netB;
  }

  /// Every pair in the input that overlaps - the check an address plan needs
  /// before it is handed to a device.
  static List<(String, String)> overlappingPairs(List<String> cidrs) {
    final out = <(String, String)>[];
    for (var i = 0; i < cidrs.length; i++) {
      for (var j = i + 1; j < cidrs.length; j++) {
        if (overlaps(cidrs[i], cidrs[j])) out.add((cidrs[i], cidrs[j]));
      }
    }
    return out;
  }

  /// Is [address] one of the two addresses a host may not take? Answers false
  /// for a /31 or /32, where nothing is reserved.
  static bool isReservedAddress(String cidr, String address) {
    final info = NetworkTools.subnet(cidr);
    if (info == null || info.prefix >= 31) return false;
    final ip = address.split('/').first;
    return ip == info.network || ip == info.broadcast;
  }

  /// Route summarization: the shortest list of prefixes that covers exactly
  /// the addresses the input list covers.
  ///
  /// Two blocks of the same size whose network addresses differ only in the
  /// last bit are one block one bit shorter. Applying that single rule until
  /// nothing merges is the whole algorithm.
  static List<String> summarize(List<String> cidrs) {
    final entries = <(int, int)>[];
    for (final cidr in cidrs) {
      final parsed = NetworkTools.parseCidr(cidr);
      if (parsed == null) continue;
      final (base, prefix) = parsed;
      entries.add((base & _maskOf(prefix), prefix));
    }
    if (entries.isEmpty) return const [];
    // The same block written twice is one block. Without this, "10.0.0.0/24
    // and 10.0.0.5/24" would come back as the same prefix twice instead of
    // once, which is the kind of duplicate that ends up in a routing table.
    final unique = <(int, int)>{...entries}.toList();
    entries
      ..clear()
      ..addAll(unique);

    var changed = true;
    var guard = 0;
    while (changed && guard++ < 4096) {
      changed = false;
      entries.sort(
        (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
      );
      for (var i = 0; i < entries.length - 1; i++) {
        final (baseA, prefixA) = entries[i];
        final (baseB, prefixB) = entries[i + 1];
        if (prefixA != prefixB || prefixA == 0) continue;
        // Same parent, adjacent halves: merge into that parent.
        if (baseA + (1 << (32 - prefixA)) != baseB) continue;
        entries[i] = (baseA & _maskOf(prefixA - 1), prefixA - 1);
        entries.removeAt(i + 1);
        changed = true;
        break;
      }
    }
    return [
      for (final (base, prefix) in entries)
        '${NetworkTools.intToIp(base)}/$prefix',
    ];
  }

  /// The CIDR list that covers the closed range [startIp] .. [endIp].
  ///
  /// A firewall rule is written as a range and a router wants prefixes; this
  /// is that translation, the way a routing table does it: take the largest
  /// aligned block that fits at the cursor and repeat.
  static List<String> rangeToCidrs(String startIp, String endIp) {
    final start = NetworkTools.ipToInt(startIp);
    final end = NetworkTools.ipToInt(endIp);
    if (start == null || end == null || start > end) return const [];
    // A separate cursor keeps the null-check promotion of `start` intact.
    var cursor = start;
    final out = <String>[];
    while (cursor <= end) {
      // The largest block that starts exactly at the cursor...
      final alignmentBits = _trailingZeros(cursor);
      // ...but never larger than what is left to cover.
      final remainingBits = _floorLog2(end - cursor + 1);
      final hostBits = alignmentBits < remainingBits
          ? alignmentBits
          : remainingBits;
      out.add('${NetworkTools.intToIp(cursor)}/${32 - hostBits}');
      cursor += 1 << hostBits;
      // A range this scattered is a typo, not a design.
      if (out.length > 512) break;
    }
    return out;
  }

  /// The reverse-DNS name for an address: 10.0.0.5 -> 5.0.0.10.in-addr.arpa.
  static String reverseDnsName(String ip) {
    final parts = ip.split('/').first.trim().split('.');
    if (parts.length != 4) return '';
    return '${parts.reversed.join('.')}.in-addr.arpa';
  }

  /// The reverse zone a subnet's PTR records belong in: a /24 or anything
  /// wider is delegated per /24, so a /16 answers with 16.172.in-addr.arpa
  /// and a /25 with 0.0.10.in-addr.arpa.
  static String reverseZone(String cidr) {
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return '';
    final (base, prefix) = parsed;
    final octets = NetworkTools.intToIp(base).split('.');
    final take = prefix >= 24 ? 3 : (prefix >= 16 ? 2 : 1);
    return '${octets.take(take).toList().reversed.join('.')}.in-addr.arpa';
  }

  /// The next subnet of the same size: what comes after this block.
  /// Walking a plan by hand is where off-by-one addressing errors start.
  static String? nextSubnet(String cidr) {
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return null;
    final (base, prefix) = parsed;
    final next = (base & _maskOf(prefix)) + (1 << (32 - prefix));
    if (next > 0xFFFFFFFF) return null;
    return '${NetworkTools.intToIp(next)}/$prefix';
  }

  static String? previousSubnet(String cidr) {
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return null;
    final (base, prefix) = parsed;
    final previous = (base & _maskOf(prefix)) - (1 << (32 - prefix));
    if (previous < 0) return null;
    return '${NetworkTools.intToIp(previous)}/$prefix';
  }

  /// The prefix that contains both addresses - "are these two hosts in the
  /// same /16?" answered as an address instead of a yes/no. Pass [prefix] to
  /// ask for a specific width, which is how a summary route is chosen to fit
  /// alongside the routes already in the table.
  static String? coveringPrefix(String a, String b, {int? prefix}) {
    final ia = NetworkTools.ipToInt(a.split('/').first);
    final ib = NetworkTools.ipToInt(b.split('/').first);
    if (ia == null || ib == null) return null;
    var bits = 32;
    while (bits > 0 && (ia >> (32 - bits)) != (ib >> (32 - bits))) {
      bits--;
    }
    final chosen = prefix != null && prefix <= bits ? prefix : bits;
    return '${NetworkTools.intToIp(ia & _maskOf(chosen))}/$chosen';
  }

  /// One line a network engineer recognises:
  /// "192.168.1.0/24 - mask 255.255.255.0 - 254 usable of 256 addresses -
  /// private (RFC 1918)".
  static String describe(String cidr) {
    final info = NetworkTools.subnet(cidr);
    if (info == null) return '$cidr is not a valid IPv4 network.';
    final host = cidr.split('/').first.trim();
    return '${info.network}/${info.prefix}  -  mask ${info.mask}  -  '
        '${info.usableHosts} usable of ${info.totalAddresses} addresses  -  '
        '${scope(host).label}';
  }

  /// Every fact about one CIDR, in one map, for a screen or a model prompt.
  static Map<String, dynamic> facts(String cidr) {
    final info = NetworkTools.subnet(cidr);
    if (info == null) return const {'ok': false};
    final host = cidr.split('/').first.trim();
    return {
      'ok': true,
      'network': info.network,
      'prefix': info.prefix,
      'mask': info.mask,
      'wildcard': wildcardFromPrefix(info.prefix),
      'broadcast': info.broadcast,
      'firstHost': info.firstHost,
      'lastHost': info.lastHost,
      'totalAddresses': info.totalAddresses,
      'usableHosts': info.usableHosts,
      'scope': scope(host).label,
      'classfulClass': classfulClass(host),
      'classfulMask': classfulMask(host),
      'binary': binary(host),
      'binaryMask': binaryMask(info.prefix),
      'reverseDns': reverseDnsName(host),
      'reverseZone': reverseZone(cidr),
      'next': nextSubnet(cidr) ?? '',
      'previous': previousSubnet(cidr) ?? '',
    };
  }
}
