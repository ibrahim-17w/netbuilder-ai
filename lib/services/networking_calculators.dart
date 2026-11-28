import 'network_tools.dart';

/// One computed answer from [NetworkingCalculators].
class CalcAnswer {
  final String text;
  final String topic;

  const CalcAnswer(this.text, {required this.topic});
}

/// The arithmetic layer behind [NetworkingIntellect]: the questions whose
/// honest answer is a computed number, not a remembered sentence.
///
/// The existing calculators in `networking_intellect.dart` cover route
/// selection, VLSM, splitting, ACL membership, wildcards, BDP and MSS. This
/// file covers the arithmetic a senior engineer is expected to do in their
/// head during a design review and get exactly right:
///
/// * how many subnets a prefix contains, and why the count is 2^n;
/// * the network, broadcast and host range of any block that is handed to
///   them, because a wrong broadcast address is a duplicate address;
/// * the smallest block two addresses share, which is how a point-to-point
///   link is chosen;
/// * IGP metrics from bandwidth and delay, and the reference-bandwidth trap;
/// * spanning-tree path cost in both the short and the long form;
/// * the MSS and underlay MTU a tunnel really needs;
/// * a PoE budget converted into a device count with headroom;
/// * how long a transfer takes at a link rate, with protocol efficiency.
///
/// Every method is pure, gated tightly enough not to steal a definition
/// question, and states the assumption behind its number.
class NetworkingCalculators {
  const NetworkingCalculators._();

  /// The computed answer, or null when the question is not arithmetic.
  static CalcAnswer? answer(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    return _prefixesInside(t) ??
        _subnetSplit(t) ??
        _subnetBounds(t) ??
        _sharedSubnet(t) ??
        _igpMetric(t) ??
        _stpPathCost(t) ??
        _tunnelMtu(t) ??
        _poeBudget(t) ??
        _rateUnits(t) ??
        _transferTime(t);
  }

  // --- parsing -------------------------------------------------------------

  static final RegExp _cidr = RegExp(
    r'\b\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2}\b',
  );
  static final RegExp _ip = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');
  static final RegExp _slashPrefix = RegExp(r'/\s*(\d{1,2})(?!\d)');

  static List<String> _cidrs(String t) => [
    for (final m in _cidr.allMatches(t)) m.group(0)!.replaceAll(' ', ''),
  ];

  static List<String> _ips(String t) => [
    for (final m in _ip.allMatches(t)) m.group(0)!,
  ];

  /// Prefixes written with a slash, deduplicated in order of appearance.
  static List<int> _prefixes(String t) {
    final seen = <int>[];
    for (final m in _slashPrefix.allMatches(t)) {
      final value = int.tryParse(m.group(1) ?? '');
      if (value == null || value < 0 || value > 32) continue;
      if (!seen.contains(value)) seen.add(value);
    }
    return seen;
  }

  /// A link rate in bits per second. A bare g, m or k only matches a real
  /// unit boundary, so '10 ms' is a delay and never 10 Mbps. A circuit named
  /// without a number - 'a gigabit link', 'a T1', 'an OC3' - resolves too,
  /// because that is how engineers name the circuit they are asking about.
  static int? _rateBits(String t) {
    final numbered = RegExp(
      r'(\d+(?:\.\d+)?)\s*(gbps|gbit|gigabit|gig|gbe|g|mbps|mbit|megabit|meg|m|kbps|kbit|kilobit|k)\b',
    ).firstMatch(t);
    if (numbered != null) {
      final value = double.tryParse(numbered.group(1)!);
      if (value != null && value > 0) {
        final unit = numbered.group(2)!;
        if (unit.startsWith('g')) return (value * 1e9).round();
        if (unit.startsWith('m')) return (value * 1e6).round();
        return (value * 1e3).round();
      }
    }
    final named = RegExp(
      r'\b(t1|t-1|ds1|ds0|e1|ds3|oc3|oc-3|oc12|oc-12|gigabit|'
      r'10[\s-]?gig(?:abit)?|100[\s-]?gig(?:abit)?|megabit|'
      r'10[\s-]?meg(?:abit)?|100[\s-]?meg(?:abit)?|kilobit)\b',
    ).firstMatch(t);
    if (named == null) return null;
    final name = named.group(1)!;
    if (name == 't1' || name == 't-1' || name == 'ds1') return 1544000;
    if (name == 'ds0') return 64000;
    if (name == 'e1') return 2048000;
    if (name == 'ds3') return 44736000;
    if (name == 'oc3' || name == 'oc-3') return 155520000;
    if (name == 'oc12' || name == 'oc-12') return 622080000;
    final digits = RegExp(r'^\d+').firstMatch(name)?.group(0);
    final multiplier = name.contains('gig') ? 1e9 : 1e6;
    final value = digits == null ? 1.0 : double.parse(digits);
    return (value * multiplier).round();
  }

  static String _rateLabel(int bits) {
    if (bits >= 1000000000) return '${_num(bits / 1e9)} Gbps';
    if (bits >= 1000000) return '${_num(bits / 1e6)} Mbps';
    return '${_num(bits / 1e3)} kbps';
  }

  static String _num(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    var text = value.toStringAsFixed(2);
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return text;
  }

  static String _thousands(int value) {
    final digits = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  static String _plural(int count, String one, String many) =>
      count == 1 ? one : many;

  // --- how many subnets a prefix holds -------------------------------------

  /// "How many /24s are in a /20" - 2^(24-20), the block alignment, and
  /// the fact that the count is not a design decision.
  static CalcAnswer? _prefixesInside(String t) {
    if (!RegExp(r'\bhow\s+many\b').hasMatch(t)) return null;
    final asksSubnets = RegExp(
      r'\b(?:subnets?|networks?|blocks?|prefixes?|subnetting)\b|/\s*\d{1,2}s\b',
    ).hasMatch(t);
    if (!asksSubnets) return null;
    final prefixes = _prefixes(t)..sort();
    if (prefixes.length < 2) return null;
    final bigBlock = prefixes.first;
    final smallBlock = prefixes.last;
    if (smallBlock <= bigBlock) return null;
    final bits = smallBlock - bigBlock;
    if (bits > 24) return null;
    final count = 1 << bits;
    final block = NetworkTools.subnet('0.0.0.0/$smallBlock');
    final outer = NetworkTools.subnet('0.0.0.0/$bigBlock');
    if (block == null || outer == null) return null;
    final b = StringBuffer();
    b.writeln(
      'A /$bigBlock holds $count /$smallBlock '
      '${_plural(count, 'subnet', 'subnets')} (2^$bits).',
    );
    b.writeln();
    b.writeln(
      '- Arithmetic: every extra prefix bit halves the block, so a '
      '/$bigBlock (${_thousands(outer.totalAddresses)} addresses) divided '
      'into ${_thousands(block.totalAddresses)}-address blocks gives $count.',
    );
    b.writeln(
      '- Alignment is the rule people get wrong: each /$smallBlock starts '
      'on a multiple of ${_thousands(block.totalAddresses)} in the address '
      'space. A subnet that is not aligned is not a subnet.',
    );
    b.writeln(
      '- Serviceable addresses per /$smallBlock: ${block.usableHosts} '
      '(the network and broadcast addresses are reserved).',
    );
    b.writeln(
      '- The plan writes these as a range and summarises it back to '
      '$count /$smallBlock in one /$bigBlock line. A plan that cannot be '
      'summarised grows the routing table with every new site.',
    );
    return CalcAnswer(b.toString().trim(), topic: 'prefixes-inside');
  }

  // --- the boundaries of a block -------------------------------------------

  /// "What is the broadcast address of 192.168.10.128/25" - the four
  /// addresses that decide whether the config on both ends is even legal.
  static CalcAnswer? _subnetBounds(String t) {
    final asks = RegExp(
      r'\b(?:broadcast|network\s+address|first\s+(?:usable|host|address)|'
      r'last\s+(?:usable|host|address)|usable\s+(?:range|hosts?|addresses?)|'
      r'host\s+range|address\s+range|range\s+of)\b',
    ).hasMatch(t);
    if (!asks) return null;
    final cidrs = _cidrs(t);
    if (cidrs.isEmpty) return null;
    final cidr = cidrs.first;
    final info = NetworkTools.subnet(cidr);
    final parsed = NetworkTools.parseCidr(cidr);
    if (info == null || parsed == null) return null;
    final prefix = parsed.$2;
    final b = StringBuffer();
    b.writeln('${info.network}/$prefix:');
    b.writeln();
    b.writeln('- Mask ${info.mask}, ${_thousands(info.totalAddresses)} addresses.');
    b.writeln('- Network ${info.network} (not assignable).');
    b.writeln('- First usable ${info.firstHost}, last usable ${info.lastHost}.');
    b.writeln('- Broadcast ${info.broadcast} (not assignable).');
    final next = NetworkTools.intToIp(
      (NetworkTools.ipToInt(info.broadcast) ?? 0) + 1,
    );
    b.writeln(
      '- The next block starts at $next, which is why the broadcast is '
      'always one below the next network.',
    );
    if (prefix == 31) {
      b.writeln(
        '- A /31 is the RFC 3021 point-to-point form: both addresses are '
        'usable and there is no network or broadcast, so a router link '
        'wastes nothing.',
      );
    } else if (prefix == 32) {
      b.writeln(
        '- A /32 is a single host route: one address, used for a loopback '
        'or a host route.',
      );
    } else {
      b.writeln(
        '- The configuration that matches it: ip address ${info.firstHost} '
        '${info.mask}, with the gateway inside '
        '${info.firstHost} - ${info.lastHost}.',
      );
    }
    return CalcAnswer(b.toString().trim(), topic: 'subnet-bounds');
  }

  // --- the smallest block two addresses share -------------------------------

  /// "What subnet do 10.0.0.1 and 10.0.0.6 share" - the covering prefix,
  /// and the /30-versus-/31 decision a router link turns on.
  static CalcAnswer? _sharedSubnet(String t) {
    if (_cidrs(t).isNotEmpty) return null;
    final ips = _ips(t);
    if (ips.length != 2) return null;
    if (!RegExp(
      r'\b(?:same|common|share|shares|shared|overlap|overlaps|between|'
      r'smallest|cover|covers|within|belong|both)\b',
    ).hasMatch(t)) {
      return null;
    }
    final first = NetworkTools.ipToInt(ips[0]);
    final second = NetworkTools.ipToInt(ips[1]);
    if (first == null || second == null) return null;
    final xor = first ^ second;
    if (xor == 0) return null;
    final prefix = 32 - xor.bitLength;
    final info = NetworkTools.subnet('${ips[0]}/$prefix');
    if (info == null) return null;
    final b = StringBuffer();
    b.writeln(
      '${ips[0]} and ${ips[1]} share the block ${info.network}/$prefix '
      '(${info.mask}).',
    );
    b.writeln();
    b.writeln(
      '- Range ${info.firstHost} - ${info.lastHost}, broadcast '
      '${info.broadcast}.',
    );
    b.writeln(
      '- The common bits decide it: XOR the two addresses, and the highest '
      'set bit is where they diverge. That gives $prefix, and the block is '
      'the aligned /$prefix that contains both.',
    );
    if (prefix >= 30) {
      b.writeln(
        '- On a router link a /30 gives two usable addresses, which is one '
        'per end with nothing wasted beyond the reserved pair. A /31 '
        '(RFC 3021) gives both addresses to the two ends and saves a prefix '
        'per link; use it where both platforms accept it, and avoid it on '
        'equipment that still rejects a /31 on a routed port.',
      );
    }
    b.writeln(
      '- Before configuring, confirm both addresses are on the same VLAN and '
      'both interfaces carry the same mask. Different masks on the same wire '
      'is a silent fault: each host thinks the other is off-link.',
    );
    return CalcAnswer(b.toString().trim(), topic: 'shared-subnet');
  }

  // --- IGP metrics ---------------------------------------------------------

  /// OSPF cost, EIGRP classic metric and the IS-IS default cost, computed
  /// from the link rate and delay rather than quoted from memory.
  static CalcAnswer? _igpMetric(String t) {
    if (!RegExp(r'\b(?:cost|metric)\b').hasMatch(t)) return null;
    final ospf = RegExp(r'\bospf\b').hasMatch(t);
    final eigrp = RegExp(r'\beigrp\b').hasMatch(t);
    final isis = RegExp(r'\bisis\b').hasMatch(t);
    if (!ospf && !eigrp && !isis) return null;
    final rate = _rateBits(t);
    final delayMs = _delayMs(t);
    if (ospf) return _ospfCost(t, rate);
    if (eigrp) return _eigrpMetric(t, rate, delayMs);
    return _isisMetric(t);
  }

  /// A delay in milliseconds from "10 ms", "10ms delay" or "20000 usec".
  static double? _delayMs(String t) {
    final micro = RegExp(
      r'(\d+(?:\.\d+)?)\s*(?:usec|us|microseconds?)\b',
    ).firstMatch(t);
    if (micro != null) {
      final value = double.tryParse(micro.group(1)!);
      if (value != null) return value / 1000;
    }
    final milli = RegExp(
      r'(\d+(?:\.\d+)?)\s*(?:ms|msec|milliseconds?)\b',
    ).firstMatch(t);
    if (milli == null) return null;
    return double.tryParse(milli.group(1)!);
  }

  static CalcAnswer? _ospfCost(String t, int? rateBits) {
    if (rateBits == null) return null;
    final b = StringBuffer();
    b.writeln('OSPF cost for a ${_rateLabel(rateBits)} link.');
    b.writeln();
    b.writeln('- The formula is reference bandwidth divided by interface '
        'bandwidth, as an integer, with a floor of 1.');
    for (final refMbps in const [100, 1000, 10000, 100000]) {
      final refBits = refMbps * 1000000;
      var cost = refBits ~/ rateBits;
      if (cost < 1) cost = 1;
      final label = refMbps >= 1000
          ? '${_num(refMbps / 1000)} Gbps'
          : '$refMbps Mbps';
      b.writeln('  - reference $label: cost $cost');
    }
    b.writeln();
    final defaultCost = 100000000 ~/ rateBits < 1 ? 1 : 100000000 ~/ rateBits;
    b.writeln(
      '- With the default reference of 100 Mbps this link costs '
      '$defaultCost. Any link at 100 Mbps or faster costs 1, which is why a '
      'Gigabit and a 10-Gigabit path tie and traffic takes the wrong one.',
    );
    b.writeln(
      '- The fix is one line on EVERY router in the domain: '
      'auto-cost reference-bandwidth 100000 (100 Gbps), so a 10G link costs '
      '10 and a 1G link costs 100. A mismatch between routers produces '
      'asymmetric costs and a path nobody can explain.',
    );
    b.writeln(
      '- To override one interface without changing the domain, use '
      'ip ospf cost <n> on that interface. Path cost is the sum of the '
      'outbound interface costs from the router to the prefix, so verify with '
      'show ip ospf interface brief and show ip route <prefix>.',
    );
    return CalcAnswer(b.toString().trim(), topic: 'ospf-cost-calc');
  }

  static CalcAnswer? _eigrpMetric(String t, int? rateBits, double? delayMs) {
    if (rateBits == null && delayMs == null) return null;
    final rate = rateBits ?? 1000000000;
    final kbps = (rate / 1000).round();
    // The classic metric uses the interface delay in tens of microseconds.
    // When the question omits it, the platform default for that rate is used
    // and named in the answer, because an unexplained input is a guess.
    final delayMicros = delayMs != null
        ? (delayMs * 1000).round()
        : _defaultDelayMicros(rate);
    final delayTens = delayMicros ~/ 10;
    final bandwidthTerm = 10000000 ~/ kbps;
    final metric = 256 * (bandwidthTerm + delayTens);
    final b = StringBuffer();
    b.writeln(
      'EIGRP classic metric for a ${_rateLabel(rate)} link with '
      '${_num(delayMicros / 1000)} ms delay.',
    );
    b.writeln();
    b.writeln('- Formula: 256 x (10^7 / bandwidth in kbps + delay in tens of microseconds).');
    b.writeln(
      '- Bandwidth term: 10^7 / $kbps = $bandwidthTerm. Delay term: '
      '$delayMicros us / 10 = $delayTens.',
    );
    b.writeln('- Metric: 256 x ($bandwidthTerm + $delayTens) = $metric.');
    if (delayMs == null) {
      b.writeln(
        '- The delay was not stated, so the platform default for this rate '
        'was used (${_num(delayMicros / 1000)} ms). The configured value wins: '
        'read it with show interface <intf> | include DLY.',
      );
    }
    b.writeln(
      '- Only bandwidth and delay are in the default metric; changing K '
      'values changes the default K1..K5 and breaks adjacency with every '
      'neighbour that kept the defaults. Do not touch them to make a path '
      'win - use an offset-list or a route-map instead.',
    );
    b.writeln(
      '- Path selection uses the feasible distance (this metric plus the '
      'reported distance of the neighbour). Unequal-cost load sharing needs '
      'variance and a feasible successor; without both, the backup stays in '
      'the topology table and carries nothing.',
    );
    b.writeln(
      '- In named mode the wide metric multiplies bandwidth and delay by '
      '65536, so the numbers look 65536 times larger. That is a scale change, '
      'not a different path.',
    );
    return CalcAnswer(b.toString().trim(), topic: 'eigrp-metric-calc');
  }

  static int _defaultDelayMicros(int rateBits) {
    if (rateBits >= 1000000000) return 10;
    if (rateBits >= 100000000) return 100;
    if (rateBits >= 10000000) return 1000;
    if (rateBits >= 1000000) return 20000;
    return 20000;
  }

  static CalcAnswer? _isisMetric(String t) {
    if (_rateBits(t) != null) return null;
    if (!RegExp(r'\b(?:cost|metric)\b').hasMatch(t)) return null;
    final b = StringBuffer();
    b.writeln('IS-IS interface cost is a configured number, not a computed '
        'one, and that is the design decision:');
    b.writeln();
    b.writeln('- Each interface defaults to cost 10 in wide (traffic '
        'engineering) metric, and the path cost is the sum along the path.');
    b.writeln('- Narrow metric caps an interface at 63 and a path at 1023, '
        'which is why modern designs run metric-style wide.');
    b.writeln('- Every router in an area must use the same metric style. A '
        'narrow/wide mismatch forms an adjacency and then silently ignores '
        'the other side routes, which is worse than a down link.');
    b.writeln();
    b.writeln('- Set it per interface: isis metric 20 level-2, and verify '
        'with show isis interface and show isis topology. Path selection is '
        'lowest cost, then ECMP across equal costs.');
    b.writeln('- Why a fixed cost is a feature: it lets you encode policy '
        '(a dark-fibre link at cost 5, a backup LTE link at cost 100) without '
        'the hardware rate deciding the path.');
    return CalcAnswer(b.toString().trim(), topic: 'isis-metric');
  }

  // --- spanning-tree path cost ---------------------------------------------

  /// Both cost scales, because a path cost is meaningless until the reader
  /// knows which one the switches are using.
  static CalcAnswer? _stpPathCost(String t) {
    if (!RegExp(r'\b(?:stp|spanning[\s-]?tree)\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:cost|metric)\b').hasMatch(t)) return null;
    final rate = _rateBits(t);
    if (rate == null) return null;
    // 802.1D-1998 short values, then the 802.1t long formula.
    final short = _shortStpCost(rate);
    final long = (20000000000000 / rate).round();
    final b = StringBuffer();
    b.writeln('Spanning-tree cost for a ${_rateLabel(rate)} port.');
    b.writeln();
    b.writeln('- 802.1D short (the default): $short.');
    b.writeln('- 802.1t long: $long (20,000,000,000,000 / link speed in bps).');
    b.writeln();
    b.writeln('- Path cost is the sum of port costs along the path to the '
        'root, and the root bridge costs 0 on its own ports. Two equal paths '
        'are load-shared per VLAN by port ID, not by bandwidth.');
    b.writeln('- The short scale stops differentiating above 1 Gbps (a 10G '
        'and a 100G port both cost 2), so two paths of very different speed '
        'look equal and the topology picks a slower one. Long mode exists to '
        'fix that; change it with spanning-tree pathcost method long on '
        'EVERY switch, because mixing scales produces a topology nobody can '
        'predict.');
    b.writeln('- Verify with show spanning-tree vlan <id> (Cost and '
        'Root Path Cost per port) and show spanning-tree summary.');
    return CalcAnswer(b.toString().trim(), topic: 'stp-cost-calc');
  }

  static int _shortStpCost(int rateBits) {
    if (rateBits >= 10000000000) return 2;
    if (rateBits >= 1000000000) return 4;
    if (rateBits >= 100000000) return 19;
    if (rateBits >= 16000000) return 62;
    if (rateBits >= 10000000) return 100;
    if (rateBits >= 4000000) return 250;
    return 250;
  }

  // --- tunnel MTU ----------------------------------------------------------

  /// The MTU a tunnel really needs, and the MSS that keeps it working when
  /// the underlay cannot be raised.
  static CalcAnswer? _tunnelMtu(String t) {
    if (!RegExp(r'\bmtu\b').hasMatch(t)) return null;
    final kind = _tunnelKind(t);
    if (kind == null) return null;
    final (name, overhead, note) = kind;
    final underlayNeeded = 1500 + overhead;
    final innerMss = 1500 - overhead - 40;
    final b = StringBuffer();
    b.writeln('$name MTU sizing, with a 1500-byte tenant frame as the input.');
    b.writeln();
    b.writeln('- Encapsulation cost: $overhead bytes. $note');
    b.writeln('- The underlay must carry ${1500 + overhead}-byte frames, so '
        'set it to at least $underlayNeeded (1600 is the usual round number; '
        '9216 for jumbo).');
    b.writeln('- The tenant interface keeps its 1500 MTU. Raising the tunnel '
        'interface MTU without raising the underlay moves the drop, not the fix.');
    b.writeln();
    b.writeln('- When the underlay is stuck at 1500, clamp instead: '
        'ip tcp adjust-mss $innerMss on the tunnel interface. That makes every '
        'TCP session advertise an MSS the encapsulation can carry.');
    b.writeln('- UDP and ICMP do not honour the clamp, so large UDP '
        '(voice video, DNS with EDNS0, monitoring probes) can still be lost. '
        'That is why the underlay MTU is the real answer and the clamp is the '
        'fallback.');
    b.writeln();
    b.writeln('- Prove it before and after: ping <peer> size ${1500 + overhead} '
        'df-bit, and show interfaces <intf> | include MTU. A ping that works '
        'at 1400 and fails at 1500 with DF set is the whole story in one test.');
    b.writeln('- Do not raise the MTU only on the two tunnel endpoints. Every '
        'device on the underlay path - including an L2 provider handoff - must '
        'carry the larger frame, or the fragmentation moves into the middle of '
        'the path where nobody is looking.');
    return CalcAnswer(b.toString().trim(), topic: 'tunnel-mtu');
  }

  static (String, int, String)? _tunnelKind(String t) {
    if (RegExp(r'\bvxlan\b').hasMatch(t)) {
      return ('VXLAN', 50, 'outer IPv4 20 + UDP 8 + VXLAN 8 + inner Ethernet 14.');
    }
    if (RegExp(r'\bgre\b').hasMatch(t)) {
      return ('GRE', 24, 'outer IPv4 20 + GRE 4.');
    }
    if (RegExp(r'\b(?:ipsec|esp)\b').hasMatch(t)) {
      return ('IPsec tunnel mode', 73, 'outer IP 20 + ESP (SPI, sequence, IV, padding, '
          'pad length, next header, ICV) of roughly 50 to 73 bytes depending '
          'on cipher and integrity algorithms. AES-GCM has the smaller header.');
    }
    if (RegExp(r'\bwireguard\b').hasMatch(t)) {
      return ('WireGuard', 60, 'outer IPv4 20 + UDP 8 + WireGuard 32.');
    }
    if (RegExp(r'\bpppoe\b').hasMatch(t)) {
      return ('PPPoE', 8, 'PPPoE header 6 + PPP protocol 2.');
    }
    if (RegExp(r'\b(?:6in4|ipip|sit)\b').hasMatch(t)) {
      return ('IP-in-IP', 20, 'outer IPv4 20.');
    }
    if (RegExp(r'\b(?:tunnel|overlay|encapsulation)\b').hasMatch(t)) {
      return null;
    }
    return null;
  }
  // --- PoE budget ----------------------------------------------------------

  /// A wattage converted into devices, at the PSE-side draw the standard
  /// actually charges, with the headroom a real install needs.
  static CalcAnswer? _poeBudget(String t) {
    if (!RegExp(r'\bpoe\b|power over ethernet').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:how\s+many|budget|watt|w)\b').hasMatch(t)) return null;
    final wattsMatch = RegExp(
      r'(\d{2,4})\s*(?:w|watt|watts)\b',
    ).firstMatch(t);
    if (wattsMatch == null) return null;
    final budget = int.tryParse(wattsMatch.group(1)!);
    if (budget == null || budget < 15 || budget > 20000) return null;
    final usable = budget * 0.85;
    final b = StringBuffer();
    b.writeln('A $budget W PoE budget, planned with 15% headroom '
        '(${_num(usable)} W usable):');
    b.writeln();
    b.writeln('- 802.3af (class 3, 15.4 W at the switch): '
        '${_devices(usable, 15.4)} devices.');
    b.writeln('- 802.3at (class 4, 30 W at the switch): '
        '${_devices(usable, 30)} devices.');
    b.writeln('- 802.3bt type 3 (60 W at the switch): '
        '${_devices(usable, 60)} devices.');
    b.writeln('- 802.3bt type 4 (90 W at the switch): '
        '${_devices(usable, 90)} devices.');
    b.writeln();
    b.writeln('- The classes, at the port: af 15.4 W, at 30 W, bt type 3 '
        '60 W, bt type 4 90 W. The device nameplate is the PD-side number '
        '(12.95, 25.5, 51, 71 W); the switch budgets the higher PSE figure.');
    b.writeln('- Cable loss is real at high power: around 4 to 5 W is lost in '
        '100 m of Cat5e at 60 W, which is why the PSE number is not the '
        'device number. Cat6/6a loses less.');
    b.writeln('- Do not plan against the PoE port count alone. A 24-port PoE '
        'switch with a 370 W budget cannot run 24 class-4 ports; the budget, '
        'not the port count, is the limit, and the same budget must cover the '
        'APs radios and the cameras IR at night.');
    b.writeln();
    b.writeln('- Verify on the box: show power inline (per-port allocation '
        'and the remaining budget) and show power inline police if you want '
        'the switch to shed low-priority ports instead of failing the whole '
        'budget.');
    return CalcAnswer(b.toString().trim(), topic: 'poe-budget');
  }

  static int _devices(double usable, double perDevice) =>
      usable <= 0 ? 0 : (usable / perDevice).floor();

  // --- transfer time -------------------------------------------------------

  /// "How long does a 500 GB backup take over a gigabit link" - the
  /// arithmetic that ends the argument about why a link is not the problem.
  static CalcAnswer? _transferTime(String t) {
    if (!RegExp(
      r'\b(?:long|time|take|takes|copy|transfer|backup|sync|upload|'
      r'download|replicate)\b',
    ).hasMatch(t)) {
      return null;
    }
    final sizeMatch = RegExp(
      r'(\d+(?:\.\d+)?)\s*(tb|tib|gb|gib|mb|mib)\b',
    ).firstMatch(t);
    final rate = _rateBits(t);
    if (sizeMatch == null || rate == null) return null;
    final value = double.tryParse(sizeMatch.group(1)!);
    if (value == null || value <= 0) return null;
    final unit = sizeMatch.group(2)!;
    final gigabytes = unit.startsWith('t')
        ? value * 1000
        : unit.startsWith('g')
        ? value
        : value / 1000;
    final bits = gigabytes * 8e9;
    final ideal = bits / rate;
    final real = ideal / 0.8;
    String span(double seconds) {
      final total = seconds.round();
      final hours = total ~/ 3600;
      final minutes = (total % 3600) ~/ 60;
      final secs = total % 60;
      if (hours > 0) return '${hours}h ${minutes}m';
      if (minutes > 0) return '${minutes}m ${secs}s';
      return '${secs}s';
    }

    final b = StringBuffer();
    b.writeln('${_num(value)} ${unit.toUpperCase()} over a '
        '${_rateLabel(rate)} link:');
    b.writeln();
    b.writeln('- At line rate: ${span(ideal)} '
        '(${_num((gigabytes * 8e9) / rate)} seconds).');
    b.writeln('- At a realistic 80% of line rate: ${span(real)}.');
    b.writeln();
    b.writeln('- The 80% is not pessimism: TCP slow start, per-packet '
        'overhead and a single flow that cannot fill the pipe all sit between '
        'line rate and the file. Several parallel flows or a tuned window '
        'close the gap; a bigger link does not fix a single-flow ceiling.');
    b.writeln('- Let the units fool you exactly once: a gigabit is 10^9 bits '
        'and a gigabyte is 8 x 10^9 bits, so a 1 Gbps link moves about '
        '125 MB/s at best, not 1000.');
    b.writeln('- Check the real rate before believing the link: iperf3 between '
        'the endpoints, then compare with the time the copy actually took. '
        'If iperf3 is fast and the copy is slow, the storage or the protocol '
        'is the limit, not the network.');
    return CalcAnswer(b.toString().trim(), topic: 'transfer-time');
  }
  // --- splitting a block into equal subnets --------------------------------

  /// "Split 10.0.0.0/22 into four equal subnets" - the arithmetic and the
  /// resulting list, because the count and the block size are the design.
  static CalcAnswer? _subnetSplit(String t) {
    if (!RegExp(r'\b(?:split|divide|carve)\b').hasMatch(t)) return null;
    final cidrs = _cidrs(t);
    if (cidrs.isEmpty) return null;
    final parsed = NetworkTools.parseCidr(cidrs.first);
    final info = NetworkTools.subnet(cidrs.first);
    if (parsed == null || info == null) return null;
    final source = parsed.$2;
    if (source < 8 || source >= 31) return null;
    final slashes = [for (final m in _slashPrefix.allMatches(t)) int.tryParse(m.group(1)!)].whereType<int>().toList();
    int? targetPrefix;
    if (slashes.length >= 2) {
      targetPrefix = slashes[1];
    } else {
      final words = RegExp(r'\b(?:into|as)\s+(\d{1,3}|two|three|four|eight|sixteen|thirty)\b').firstMatch(t);
      if (words == null) return null;
      final raw = words.group(1)!;
      final counts = <String, int>{'two': 2, 'three': 3, 'four': 4, 'eight': 8, 'sixteen': 16, 'thirty': 32};
      final count = int.tryParse(raw) ?? counts[raw];
      if (count == null || count < 2) return null;
      final bits = count == 2 ? 1 : count == 4 ? 2 : count == 8 ? 3 : count == 16 ? 4 : count == 32 ? 5 : -1;
      if (bits < 0) return null;
      targetPrefix = source + bits;
    }
    if (targetPrefix <= source || targetPrefix > 30) {
      return null;
    }
    final count = 1 << (targetPrefix - source);
    final size = 1 << (32 - targetPrefix);
    final base = NetworkTools.ipToInt(info.network) ?? 0;
    final usable = size - 2;
    final b = StringBuffer();
    b.writeln('Splitting ${info.network}/$source into $count equal /$targetPrefix blocks:');
    b.writeln();
    final shown = count <= 6 ? count : 4;
    for (var i = 0; i < shown; i++) {
      final start = base + i * size;
      final end = start + size - 1;
      b.writeln('- ${NetworkTools.intToIp(start)}/$targetPrefix (${NetworkTools.intToIp(start + 1)} - ${NetworkTools.intToIp(end - 1)}, broadcast ${NetworkTools.intToIp(end)})');
    }
    if (count > shown) {
      final lastStart = base + (count - 1) * size;
      b.writeln('- ... through ${NetworkTools.intToIp(lastStart)}/$targetPrefix');
    }
    b.writeln();
    b.writeln('- The arithmetic: ${targetPrefix - source} borrowed bits, so 2^${targetPrefix - source} = $count blocks, each of 2^${32 - targetPrefix} = ${_thousands(size)} addresses. The usable count per block is $usable.');
    b.writeln('- Every block loses its network and broadcast address, so $count x 2 = ${count * 2} addresses across the plan are not assignable.');
    b.writeln('- The trap: a /22 split into four is four /24s, not four /26s. The target prefix comes from the number of pieces, not from the number of hosts you had in mind.');
    b.writeln('- Verify with ipcalc against the first and the last block; if both match, the middle blocks follow from the block size.');
    return CalcAnswer(b.toString().trim(), topic: 'subnet-split');
  }

  // --- bits and bytes ------------------------------------------------------

  /// "How many bytes per second is 100 Mbps" - the factor-of-eight question,
  /// which is behind a large share of mistaken bandwidth sizing.
  static CalcAnswer? _rateUnits(String t) {
    final numeric = RegExp(r'(\d+(?:\.\d+)?)\s*(gbps|gbit|gigabit|mbps|mbit|megabit|kbps|kbit|kilobit|g|m|k)\b').firstMatch(t);
    if (numeric == null) return null;
    final asksBytes = RegExp(r'\b(?:bytes?|by/sec|b/s|mb/s|megabytes?|megs?)\b').hasMatch(t);
    if (!asksBytes) return null;
    if (!RegExp(r'\b(?:how many|how much|convert|equal|in)\b').hasMatch(t)) return null;
    final value = double.tryParse(numeric.group(1)!);
    if (value == null || value <= 0) return null;
    final unit = numeric.group(2)!;
    final bits = unit.startsWith('g') ? value * 1e9 : unit.startsWith('m') ? value * 1e6 : value * 1e3;
    final bytes = bits / 8;
    final megabytes = bytes / 1e6;
    final b = StringBuffer();
    b.writeln(
      '${_rateLabel(bits.round())} = ${_thousands(bytes.round())} bytes per '
      'second, which is ${_num(megabytes)} MB/s:',
    );
    b.writeln();
    b.writeln(
      '- The only arithmetic: 1 byte is 8 bits, so divide by 8 '
      '(${_thousands(bits.round())} / 8 = ${_thousands(bytes.round())}).',
    );
    b.writeln('- Rate units are decimal in networking: 1 Mbps = 1,000,000 bits/s = 125,000 bytes/s, and 1 Gbps = 125 MB/s. A 1 Gbps link does not move 1 GB per second.');
    b.writeln('- Storage units are binary: 1 GiB = 1,073,741,824 bytes, which is why a copy shows less than the rate suggests. That is a 7% difference on every large file, and it is not loss.');
    b.writeln('- Payload is smaller than line rate: Ethernet overhead (preamble, header, FCS, inter-frame gap) costs about 5% at 1500 bytes, TCP/IP another 3-4%. A saturated 1 Gbps link carries about 115 MB/s of application data, not 125.');
    b.writeln('- Verify with iperf3 in bits per second and with a file copy timed in bytes per second; the two should agree after the divide by 8.');
    return CalcAnswer(b.toString().trim(), topic: 'rate-units');
  }


}
