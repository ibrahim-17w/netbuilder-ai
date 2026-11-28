import 'network_math.dart';
import 'network_tools.dart';

/// The design arithmetic a senior engineer does before touching a device:
/// how many subnets a headcount needs, how to carve a block for floors,
/// whether the core needs BGP, how to multihome, how to absorb an
/// acquisition's overlapping addresses, and how to prepare a backbone for
/// 100G.
///
/// This layer is separate from the consultant for one reason: the consultant
/// owns the pattern (which WAN shape, which campus tier), and this layer owns
/// the number that follows from the stated scale. Every answer names its
/// assumptions, shows the arithmetic, and ends with the check that proves it
/// on the real network.
class DesignAnswer {
  final String text;
  final String topic;

  const DesignAnswer(this.text, this.topic);
}

class NetworkingDesign {
  const NetworkingDesign._();

  static final RegExp _buildVerb = RegExp(
    r'\b(?:build|set\s+up|setup|create|deploy|plan)\b',
  );

  static final RegExp _deviceTally = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches?|pcs?|servers?|printers?|'
    r'firewalls?|laptops?|aps?|access\s+points?)\b',
  );

  /// The design answer, or null when the question is not one of these.
  static DesignAnswer? answer(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty || t.length > 2000) return null;
    // A purchase decision belongs to the advisor, not to the design math.
    if (RegExp(r'\b(?:buy|purchase|pricing|price|quote|worth\s+it)\b')
        .hasMatch(t)) {
      return null;
    }
    // A brief that asks to build a topology is the planner's: it names devices
    // and counts, and the answer is a plan, not a paragraph.
    if (_buildVerb.hasMatch(t) && _deviceTally.hasMatch(t)) return null;
    return _subnetCount(t) ??
        _floorSplit(t) ??
        _vlanCount(t) ??
        _addressExhaustion(t) ??
        _qosTrust(t) ??
        _warehouseAps(t) ??
        _apCount(t) ??
        _channelPlan(t) ??
        _stpRoot(t) ??
        _ospfAreaDesign(t) ??
        _multihoming(t) ??
        _bgpInbound(t) ??
        _cabling(t) ??
        _overlapping(t) ??
        _backbone100g(t) ??
        _bgpAtCore(t) ??
        _cloudReadiness(t);
  }

  // --- how many subnets -----------------------------------------------

  static DesignAnswer? _subnetCount(String t) {
    if (!RegExp(r'\b(?:how\s+many|number\s+of)\b').hasMatch(t)) {
      return null;
    }
    if (!RegExp(r'\bsubnets?\b').hasMatch(t)) return null;
    final n = _headcount(t);
    if (n == null || n < 10) return null;
    final devices = (n * 1.4).ceil();
    final addresses = (devices * 1.2).ceil();
    final userSubnets = (addresses / 254).ceil();
    const functionSubnets = 6;
    final total = userSubnets + functionSubnets;
    final block = _blockFor(total);
    final b = StringBuffer();
    b.writeln('Sizing subnets for $n people, worked from addresses rather '
        'than rules of thumb:');
    b.writeln();
    b.writeln('- $n people x 1.4 devices (laptop plus phone) = $devices devices.');
    b.writeln('- Plus 20% growth = $addresses addresses to plan for.');
    b.writeln('- A /24 carries 254 usable addresses, so $addresses need '
        '$userSubnets user subnets.');
    b.writeln('- Add the function VLANs every site needs - voice, guest, '
        'management, IoT and printers, and a transit or DMZ pair: about '
        '$functionSubnets.');
    b.writeln('- Total: $total /24s. The smallest block that holds $total '
        '/24s is $block.');
    b.writeln();
    b.writeln('Carve it so it summarises:');
    b.writeln('- $block split into one /22 or /21 per building, then /24s per '
        'floor inside that. The building boundary is what lets one summary '
        'route cover every floor.');
    b.writeln('- Keep one /24 out of every /22 empty. That is the growth '
        'reserve that prevents the next re-addressing project, and it costs '
        'nothing but discipline.');
    b.writeln('- Put guest, IoT and voice in their own blocks, not inside the '
        'user block, because their security policy and their growth rate are '
        'different.');
    b.writeln();
    b.writeln('Check the assumption before you build: pull the actual device '
        'count from the DHCP lease table and the switch MAC tables. If the '
        'real ratio is 2.5 devices per person, the plan needs roughly double '
        'the addresses - and that is a cheaper discovery now than a renumber '
        'later.');
    b.writeln('Rule: size from a measured device ratio, reserve a block for '
        'growth, and summarise at the building. A plan that cannot be '
        'summarised costs routing table entries forever.');
    return DesignAnswer(b.toString().trim(), 'subnet-count');
  }

  static int? _headcount(String t) {
    final m = RegExp(
      r'(\d[\d,]*)\s*(?:employees|users|staff|people|seats|students|'
      r'devices|workers|patients|guests|customers)\b',
    ).firstMatch(t);
    if (m == null) return null;
    return int.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  /// The smallest aligned block that holds [subnets] /24s.
  static String _blockFor(int subnets) {
    var bits = 0;
    while ((1 << bits) < subnets) {
      bits++;
    }
    final prefix = 24 - bits;
    final addresses = 1 << (32 - prefix);
    return '/$prefix (${_num(addresses.toDouble())} addresses)';
  }

  // --- splitting a block across floors --------------------------------

  static DesignAnswer? _floorSplit(String t) {
    if (!RegExp(r'\b(?:split|carve|divide|subnet|allocate)\b').hasMatch(t)) {
      return null;
    }
    var cidr = _firstCidr(t);
    final bare = cidr == null ? _barePrefix(t) : null;
    if (cidr == null && bare == null) return null;
    cidr ??= '10.0.0.0/$bare';
    final count = _floors(t);
    if (count == null || count < 2 || count > 64) return null;
    final group = NetworkTools.subnet(cidr);
    if (group == null) return null;
    final total = group.totalAddresses;
    final tightBits = _bitsFor(count);
    final tightPrefix = group.prefix + tightBits;
    final growthPrefix = tightPrefix + 1;
    final b = StringBuffer();
    if (bare != null) {
      b.writeln('(10.0.0.0/$bare is the example block - substitute your own; ');
      b.writeln('the sizes and alignment are what matter.)');
      b.writeln();
    }
    b.writeln('Splitting $cidr (${_num(total.toDouble())} addresses) across '
        '$count floors:');
    b.writeln();
    if (tightPrefix > 32) {
      b.writeln('- $cidr cannot hold $count subnets at all: $count needs '
          '$tightBits more bits than the block has. Start from a larger block.');
      return DesignAnswer(b.toString().trim(), 'floor-split');
    }
    final tightSubnets = 1 << tightBits;
    final tightEach = total ~/ tightSubnets;
    b.writeln('- Tight fit: $tightSubnets subnets of /$tightPrefix, '
        '${_num(tightEach.toDouble())} addresses each, '
        '${_num((tightEach - 2).toDouble())} usable. That uses '
        '$count of $tightSubnets and leaves ${tightSubnets - count} spare, '
        'which is not room to grow.');
    b.writeln('- With room to grow, size each floor at double the tight '
        'block: /$growthPrefix per floor. $count floors then need '
        '${count * 2} /24-equivalents, and the whole thing fits in a block '
        'one bit larger than $cidr.');
    b.writeln();
    b.writeln('Proposed plan:');
    final tightPlan = NetworkMath.split(cidr, tightPrefix);
    for (var i = 0; i < count && i < tightPlan.length; i++) {
      final floor = tightPlan[i];
      final info = NetworkTools.subnet(floor);
      b.writeln('- Floor ${i + 1}: $floor (gateway '
          '${info?.firstHost ?? ''}, usable '
          '${info?.usableHosts ?? 0})');
    }
    b.writeln();
    b.writeln('The growth reserve is the other half of the same block: keep '
        'the matching /$growthPrefix next to each floor /$tightPrefix and '
        'assign from it only when that floor passes about 70% utilization.');
    b.writeln();
    b.writeln('Why not hand out /${tightPrefix + 1} for every floor and stop '
        'there: it works today and wastes nothing visibly, but it leaves no '
        'aligned block to grow into, so the first new team forces a renumber '
        'of a live floor.');
    b.writeln('Check before configuring: every subnet must be aligned on its '
        'own size boundary, and the gateways must be documented. Take the '
        'first usable address of each block as the gateway and reserve the '
        'last few addresses for VIPs and HSRP/VRRP virtual addresses.');
    b.writeln('Rule: split for the floors you have, reserve the bit that '
        'doubles it, and never fill the last subnet of a block.');
    return DesignAnswer(b.toString().trim(), 'floor-split');
  }

  static String? _firstCidr(String t) {
    final m = RegExp(
      r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b',
    ).firstMatch(t);
    return m?.group(1);
  }

  static int? _floors(String t) {
    final m = RegExp(
      r'(\d+)\s*(?:floors?|buildings?|sites?|departments?|offices?|'
      r'classrooms?|wards?|tenants?|vlans?)\b',
    ).firstMatch(t);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static int? _barePrefix(String t) {
    final m = RegExp(r'(?:^|[^0-9.])/(\d{1,2})\b').firstMatch(t);
    if (m == null) return null;
    final p = int.tryParse(m.group(1)!);
    return p == null || p < 8 || p > 30 ? null : p;
  }

  static int _bitsFor(int count) {
    var bits = 0;
    while ((1 << bits) < count) {
      bits++;
    }
    return bits;
  }

  // --- how many VLANs --------------------------------------------------

  static DesignAnswer? _vlanCount(String t) {
    if (!RegExp(r'\b(?:how\s+many|number\s+of)\b').hasMatch(t)) return null;
    if (!RegExp(r'\bvlans?\b').hasMatch(t)) return null;
    final n = _headcount(t);
    if (n == null || n < 10) return null;
    final devices = (n * 1.5).ceil();
    final prefix = NetworkMath.prefixForHosts(devices);
    final usable = (1 << (32 - prefix)) - 2;
    final b = StringBuffer();
    b.writeln('For $n users, VLAN count is a policy question and address '
        'count is an arithmetic one. Do the arithmetic first:');
    b.writeln();
    b.writeln('- $n users x 1.5 devices = $devices addresses, so the user '
        'VLAN needs /$prefix ($usable usable), not a /24 by reflex.');
    b.writeln('- Then add one VLAN per boundary you actually enforce: voice, '
        'guest, management, IoT and printers, servers, and a transit or DMZ '
        'pair. That is five to seven, and they exist at every site.');
    b.writeln('- Total: two to three VLANs per 200 users for data plus the '
        'function VLANs. Past roughly 250 devices in one broadcast domain, '
        'split it - not for broadcast traffic, which is small on modern '
        'switches, but for fault domain and policy.');
    b.writeln();
    b.writeln('What not to do:');
    b.writeln('- One VLAN per department. Departments change; the VLAN plan '
        'then becomes a history of reorganisations.');
    b.writeln('- One VLAN for everything because broadcast is cheap. It is, '
        'until one infected laptop needs to be contained by an ACL.');
    b.writeln('- A VLAN per floor and nothing else, with voice and guest '
        'sharing it. Their policy and their DHCP options are not the same.');
    b.writeln();
    b.writeln('Check: show vlan brief and the interface VLAN assignment, then '
        'confirm each VLAN has exactly one gateway owner (an SVI or '
        'HSRP/VRRP) and that the DHCP scope matches the subnet. A VLAN with '
        'two gateways is a duplicate-IP incident waiting for a failover.');
    return DesignAnswer(b.toString().trim(), 'vlan-count');
  }

  // --- address exhaustion ----------------------------------------------

  static DesignAnswer? _addressExhaustion(String t) {
    if (!RegExp(
      r'out\s+of\s+(?:ip\s+)?addresses|no\s+free\s+(?:ip|address)|'
      r'address\s+space\s+(?:is\s+)?(?:exhausted|full)|'
      r'dhcp\s+pool\s+(?:is\s+)?(?:full|exhausted)|'
      r'ran\s+out\s+of\s+(?:ip\s+)?addresses',
    ).hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Out of addresses is a measurement problem before it is a '
        'subnetting problem. Work in this order:');
    b.writeln();
    b.writeln('1. Measure the real utilization. A /24 that looks full usually '
        'is not:');
    b.writeln('   - show ip dhcp pool (total, leased, available) and the '
        'lease table, not the DHCP console count.');
    b.writeln('   - show arp and a ping sweep of the subnet, then compare: '
        'addresses that answer but have no lease are static or stale.');
    b.writeln('   - Compare leases against MACs seen on the switch: a lease '
        'with no live MAC is a reservation nobody renewed.');
    b.writeln();
    b.writeln('2. Reclaim before you expand. Typical finds: 10-30% of a /24 is '
        'stale reservations, printers moved to another VLAN, and guest leases '
        'with a 7-day timer that should be 2 hours.');
    b.writeln('3. Shorten the lease time on guest and wireless, then let it '
        'turn over for one lease cycle before re-measuring.');
    b.writeln('4. Only then extend: supernet the VLAN to the next prefix down '
        'and move the mask on the gateway and the DHCP scope at the same '
        'time. Remember the devices keeping a static IP with the old mask - '
        'they still think half the subnet is off-link.');
    b.writeln('5. Fix the cause: if one VLAN serves users, voice and guest, '
        'split the VLANs before adding addresses to the shared one.');
    b.writeln();
    b.writeln('The order matters because adding a /24 to a VLAN that is 70% '
        'stale doubles the broadcast domain to solve a problem that was never '
        'sized correctly.');
    b.writeln('Rule: exhaustion is measured with leases plus ARP, never with '
        'a gut feeling. Reclaim first, re-plan second, extend last.');
    return DesignAnswer(b.toString().trim(), 'address-exhaustion');
  }


  // --- QoS trust boundary ----------------------------------------------

  static DesignAnswer? _qosTrust(String t) {
    if (!RegExp(r'\bqos\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:trust|marking|mark|dscp|cos|priority)\b').hasMatch(t)) {
      return null;
    }
    if (!RegExp(r'\b(?:edge|access|boundary|wan|user|port|phone|ap)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Trust nothing by default. A trust boundary is the line where '
        'the network stops believing the markings it receives, and the only '
        'correct place for it is where you control both ends of the cable.');
    b.writeln();
    b.writeln('Where to trust:');
    b.writeln('- The switch port facing a phone or an AP: trust DSCP (or CoS on '
        'the trunk) because those devices mark their own traffic correctly.');
    b.writeln('- Trunks between your own switches and to the WAN router: trust '
        'DSCP across them, because you marked it inside.');
    b.writeln('- Nowhere else. A user PC port, a guest port and an internet '
        'handoff are untrusted: re-mark to 0 and classify from scratch.');
    b.writeln();
    b.writeln('The eight classes worth keeping (DSCP):');
    b.writeln('- EF 46 voice bearer, CS5 40 voice signalling, AF41 34 '
        'interactive video, AF31 26 call signalling/transactional, AF21 18 '
        'business data, AF11 10 bulk, CS1 8 scavenger, 0 best effort. CS6/CS7 '
        'are reserved for network control - never for user traffic.');
    b.writeln();
    b.writeln('How to enforce it: on the untrusted access port, police the '
        'class and re-mark what exceeds it, rather than trusting and hoping. '
        'At the WAN edge, police inbound to the committed rate and drop '
        'scavenger first - a trust boundary without a policer is a suggestion.');
    b.writeln('Commands to check the real state: show mls qos interface <port> '
        '(the trust state and the default COS), show policy-map interface '
        '<port> (matches and drops per class), and show mls qos map cos-dscp '
        'to confirm the mapping you think you have.');
    b.writeln();
    b.writeln('Rule: trust is a security decision, not a performance setting. '
        'One trusted port that anything can plug into re-marks the whole '
        'network, and voice quality then depends on what a laptop decided to '
        'send.');
    return DesignAnswer(b.toString().trim(), 'qos-trust');
  }

  // --- warehouse AP count ----------------------------------------------

  static DesignAnswer? _warehouseAps(String t) {
    if (!RegExp(r'\b(?:aps?|access\s+points?)\b').hasMatch(t)) return null;
    final area = _areaSqFt(t);
    if (area == null) return null;
    final warehouse = RegExp(r'\b(?:warehouse|racking|racks|forklift|'
      r'high\s+ceiling|mezzanine|dock)\b').hasMatch(t);
    final perAp = warehouse ? 8000.0 : 2500.0;
    final coverage = (area / perAp).ceil();
    final b = StringBuffer();
    b.writeln('About $coverage APs for ${_num(area)} sq ft '
        '(${warehouse ? 'warehouse' : 'office'} coverage). Worked out:');
    b.writeln();
    b.writeln('- A warehouse AP covers roughly 7,500-10,000 sq ft when the '
        'ceiling is high and racking blocks line of sight; an office AP covers '
        '1,500-2,500 sq ft. ${_num(area)} / ${_num(perAp)} = $coverage.');
    b.writeln('- Add one AP for the mezzanine and one for the loading dock or '
        'any area with a different ceiling height - they are not covered by '
        'the grid.');
    b.writeln('- Check capacity too: scanners and handhelds are low-rate but '
        'many, and one AP comfortably serves 30-50 active data clients. If the '
        'site runs 150 scanners, capacity gives 3-5 APs, so take the larger of '
        'coverage and capacity.');
    b.writeln();
    b.writeln('The warehouse-specific decisions:');
    b.writeln('- Mount APs down the aisles with directional or downtilt '
        'antennas, not above the rack tops where metal blocks them. Aim along '
        'the aisle, not across it.');
    b.writeln('- Use 5 GHz at 20 MHz for the scanners and keep 2.4 GHz narrow '
        'if the devices need it - 2.4 GHz has only three non-overlapping '
        'channels, so a big grid cannot use it for capacity.');
    b.writeln('- Budget PoE+ and a 2.5G uplink per AP. The radio is faster than '
        'a 1G port the moment two clients use it.');
    b.writeln();
    b.writeln('Verify after racking is installed, not before: a survey that '
        'targets -67 dBm at the scanner height with 25 dB SNR, and an '
        'overlap of about 20% between cells. Surveying an empty warehouse is '
        'surveying a different building.');
    b.writeln('Rule: in a warehouse, coverage comes from geometry and '
        'mounting, capacity comes from channel width and AP count. Solve them '
        'separately and take the larger number.');
    return DesignAnswer(b.toString().trim(), 'warehouse-aps');
  }

  static double? _areaSqFt(String t) {
    final m = RegExp(
      r'(\d[\d,]*(?:\.\d+)?)\s*(?:sq\.?\s*ft|sqft|square\s+feet|'
      r'square\s+foot)\b',
    ).firstMatch(t);
    if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', ''));
    final meters = RegExp(
      r'(\d[\d,]*(?:\.\d+)?)\s*(?:sq\.?\s*m|sqm|square\s+met(?:er|re)s?)\b',
    ).firstMatch(t);
    if (meters == null) return null;
    final value = double.tryParse(meters.group(1)!.replaceAll(',', ''));
    return value == null ? null : value * 10.7639;
  }

  // --- channel plan ----------------------------------------------------

  static DesignAnswer? _channelPlan(String t) {
    if (!RegExp(r'\b(?:channels?|channel\s+plan)\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:2\.4|2\.4ghz|dense|office|interference)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('A 2.4 GHz plan for a dense office starts with an uncomfortable '
        'fact: there are only three non-overlapping channels, so 2.4 GHz '
        'cannot be the capacity band.');
    b.writeln();
    b.writeln('The plan:');
    b.writeln('- 20 MHz only on 2.4 GHz, channels 1, 6 and 11. 40 MHz in 2.4 GHz '
        'consumes the whole band and is never right in an office.');
    b.writeln('- Reuse 1-6-11 in a diagonal pattern so no two APs on the same '
        'channel are adjacent, and lower the power (5-11 dBm) so each cell '
        'stays small. High power on 2.4 GHz is how a floor gets one giant '
        'collision domain.');
    b.writeln('- Put 2.4 GHz on coverage duty only: IoT, legacy scanners, '
        'guest fallback. Disable the low legacy rates (1, 2, 5.5, 11 Mbps) so '
        'a slow client cannot hold airtime for everyone.');
    b.writeln('- Put the capacity on 5 GHz: 20 MHz channels in dense areas, '
        '40 MHz in sparse ones. There are around 25 non-overlapping 20 MHz '
        'channels in the 5 GHz band (fewer where DFS is restricted), which is '
        'the actual density budget.');
    b.writeln('- Use 6 GHz where the APs and clients support it: 7 x 160 MHz or '
        '14 x 80 MHz, no legacy interference, and 6 GHz clients get the '
        'airtime they need.');
    b.writeln();
    b.writeln('A three-AP office cluster, for example: 2.4 GHz 1/6/11 rotating '
        'by row, 5 GHz 36/44/52 (or 36/48/149 where DFS is avoided), all at '
        '20 MHz. Verify with show ap dot11 24ghz channel, the controller DCA '
        'history, and a spectrum analysis of the worst floor.');
    b.writeln('Rule: channel width is a capacity decision made per band. '
        'Widening a channel in a dense office trades capacity for peak rate, '
        'and peak rate is what the speed test shows while everyone else '
        'waits.');
    return DesignAnswer(b.toString().trim(), 'channel-plan');
  }

  // --- OSPF area design ------------------------------------------------

  static DesignAnswer? _ospfAreaDesign(String t) {
    if (!RegExp(r'\bospf\b').hasMatch(t)) return null;
    if (!RegExp(
      r'\b(?:single|one|multi)\s*[- ]?areas?\b|'
      r'\bmulti-?area\b|\bmultiarea\b|'
      r'\bhow\s+many\s+(?:ospf\s+)?areas\b|\barea\s+design\b',
    ).hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Single area or multiple areas is a scale question, and the '
        'thresholds are small enough to name:');
    b.writeln();
    b.writeln('- Single area 0 is right for one administrative domain with '
        'fewer than about 50 routers and under roughly 1,000 prefixes, stable '
        'links, and no need to summarise. Most campus networks fit, and every '
        'area you add is configuration you must keep consistent.');
    b.writeln('- Go multi-area when the LSDB grows past what a router can hold '
        'or SPF churn becomes visible (a flapping access link causing '
        'network-wide SPF runs), when you need summarisation at a boundary, '
        'or when different regions have different policy.');
    b.writeln();
    b.writeln('The design rules that make multi-area work:');
    b.writeln('- Area 0 is the backbone and must be contiguous. Every other '
        'area attaches to it through an ABR. A virtual link is a patch for a '
        'broken design, not a design.');
    b.writeln('- Keep area 0 for the core only: no access VLANs, no user '
        'subnets. Areas are built around summarisation boundaries, not around '
        'buildings.');
    b.writeln('- Summarise at the ABR with area range, and make leaf areas '
        'stub or NSSA so they do not carry external LSAs they cannot use.');
    b.writeln('- LSA types tell you where a route came from: 1/2 intra-area, '
        '3 inter-area from an ABR, 4/5 external, 7 from an NSSA. If a route '
        'is missing, the type it should have been is the first question.');
    b.writeln();
    b.writeln('Verify: show ip ospf (SPF run count and area list), show ip '
        'ospf database (LSAs per area), show ip ospf statistics (churn), and '
        'show ip route ospf on both sides of an ABR to confirm the summary is '
        'what you intended.');
    b.writeln('Rule: add an area when it buys summarisation or isolates '
        'churn, not because the diagram looks tidier. An area that does '
        'neither is another failure domain to troubleshoot.');
    return DesignAnswer(b.toString().trim(), 'ospf-area-design');
  }

  // --- multihoming ------------------------------------------------------

  static DesignAnswer? _multihoming(String t) {
    if (!RegExp(r'\b(?:multihom\w*|multi-hom\w*|two\s+isps?|2\s+isps?|'
      r'dual\s+isp|second\s+isp|two\s+internet)\b').hasMatch(t)) {
      return null;
    }
    // EVPN multihoming is a fabric feature, not a WAN design question.
    if (RegExp(r'\b(?:evpn|vxlan|fabric|esi)\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:isps?|internet|providers?|wan|uplinks?|routers?|'
            r'links?|offices?|sites?)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Multihoming has three patterns, and they fail differently. '
        'Pick by what you are protecting against:');
    b.writeln();
    b.writeln('1. One router, two ISPs, BGP to both. Cheapest and simplest. '
        'Protects against an ISP failure, not against the router failing. '
        'NAT must be per ISP (a pool and a route-map per uplink), because a '
        'packet that leaves ISP A cannot come back through ISP B.');
    b.writeln('2. Two routers, eBGP to each ISP, iBGP between them, HSRP/VRRP '
        'to the LAN, NAT on each router. Protects against either failure. '
        'This is the normal enterprise answer; the cost is that return paths '
        'must be symmetric for stateful devices.');
    b.writeln('3. SD-WAN overlay over both links. Same physics, but policy is '
        'per application and the failover is faster. It does not remove the '
        'need for a working underlay and non-overlapping addressing.');
    b.writeln();
    b.writeln('The details that decide whether it works:');
    b.writeln('- Provider-assigned space means no stable inbound service: use '
        'NAT for outbound and put anything inbound behind a provider-independent '
        'block or a load balancer in a third location.');
    b.writeln('- Prefer the primary with local preference; let the backup '
        'win by default only when the primary withdraws. Verify with show ip '
        'bgp and the best path the router actually chose, not with a ping.');
    b.writeln('- Failover time is BGP hold time (90 s default) plus '
        'convergence. If 90 seconds is too long, use BFD or provider '
        'agreed timers, and test it.');
    b.writeln('- Monitor the path, not the interface: an IP SLA probe to a '
        'reliable destination is what notices a dead provider whose link '
        'still shows up.');
    b.writeln();
    b.writeln('Verify with a planned test: shut the primary uplink in a '
        'maintenance window, watch the default route and the NAT pool move, '
        'and measure how long an outbound session takes to recover. Then shut '
        'the router instead - if that takes the site down, you chose pattern 1 '
        'and should know it.');
    b.writeln('Rule: two ISPs on one router is not redundancy. Redundancy is '
        'no single device, no single link and no single path, and it is only '
        'proven by a test.');
    return DesignAnswer(b.toString().trim(), 'multihoming');
  }

  // --- influencing inbound BGP ------------------------------------------

  static DesignAnswer? _bgpInbound(String t) {
    if (!RegExp(r'\bbgp\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:inbound|incoming|influence|prefer|traffic\s+in)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Inbound traffic is not yours to choose. You can only make '
        'your advertisement less attractive on one path and let the other '
        'network agree - and every lever below is a suggestion it can ignore.');
    b.writeln();
    b.writeln('The levers, strongest first:');
    b.writeln('- AS-path prepend on the path you do not want: prepend your own '
        'AS two to four times outbound toward that provider. It is the most '
        'portable lever and the bluntest; prepending too much also lengthens '
        'the backup path for failover.');
    b.writeln('- MED: lower is better, but MED is compared only between '
        'routes from the same neighbour AS, is not transitive, and most '
        'providers strip it. Use it between your own two connections to one '
        'provider, not across two providers.');
    b.writeln('- Communities your provider documents: they translate a '
        'community into their local preference or prepend for you. This is '
        'the only lever that changes the provider own decision, so read their '
        'documentation before inventing one.');
    b.writeln('- More-specific advertisements: a /24 wins over a /16 by '
        'longest match everywhere. It works, it also grows the global table, '
        'and some providers filter prefixes longer than /24.');
    b.writeln();
    b.writeln('Verify from outside, not from your router: a looking glass at '
        'a third network, or a traceroute from a cloud host in the region you '
        'care about. Your own show ip bgp shows what you sent, not what the '
        'internet chose.');
    b.writeln('Rule: outbound is a local decision (local preference, weight). '
        'Inbound is a request. Design for the case where the other network '
        'ignores it.');
    return DesignAnswer(b.toString().trim(), 'bgp-inbound');
  }

  // --- cabling for 10G --------------------------------------------------

  static DesignAnswer? _cabling(String t) {
    final media = RegExp(r'\b(?:cat\s?5e?|cat\s?6a?|cable|cabling|fiber|'
      r'fibre|copper|dac)\b').hasMatch(t);
    final speed = RegExp(r'\b(?:10\s?g(?:b|ig)?|10gbe|10gb|25\s?g|40\s?g|'
      r'100\s?g|10\s+gig)\b').hasMatch(t);
    if (!media || !speed) return null;
    final b = StringBuffer();
    b.writeln('10G over 100 metres has exactly one copper answer and several '
        'fiber ones:');
    b.writeln();
    b.writeln('- Cat6a: 10GBASE-T to 100 m. This is the copper standard for a '
        '100 m 10G run, and the one to pull if the run might ever be 10G.');
    b.writeln('- Cat6: 10GBASE-T to about 55 m, and that limit depends on '
        'bundle size and installation. Fine for short desk runs and patch '
        'panels, not for a 90 m horizontal run.');
    b.writeln('- Cat5e: 1G to 100 m, 2.5G to 100 m on good cable. Not a 10G '
        'cable at any useful length.');
    b.writeln('- Multimode fiber (OM4, 850 nm SR4): 100 m is comfortable '
        '(OM4 is rated to 400 m at 10G, OM3 to 300 m). Cheaper optics than '
        'single-mode and the normal choice inside a building or data center.');
    b.writeln('- Single-mode fiber (OS2, LR): 10 km, the choice between '
        'buildings and for any run where the optics budget, not the cable, is '
        'the constraint.');
    b.writeln('- DAC/AOC: 1-7 m inside a rack, cheapest and lowest latency, '
        'not a building cable.');
    b.writeln();
    b.writeln('The trade you are actually making: 10GBASE-T copper is cheap '
        'cable and expensive power - roughly 3-5 W per port - and it needs '
        'Cat6a, shielded jacks and careful termination to pass. Fiber has '
        'cheaper per-metre electronics at distance but costs optics and '
        'cleaning discipline.');
    b.writeln('Verify with a certifier, not a continuity tester: a Cat6a run '
        'must pass Cat6a permanent-link tests for insertion loss, NEXT and '
        'return loss. A cable that links at 1G and fails at 10G is a '
        'termination problem, not a mystery.');
    b.writeln('Rule: copper for the last 100 m inside a building, fiber '
        'between buildings and anywhere the run exceeds 100 m. If the answer '
        'is Cat6 and the run is 90 m, the answer is Cat6a.');
    return DesignAnswer(b.toString().trim(), 'cabling-10g');
  }

  // --- overlapping addresses after an acquisition ----------------------

  static DesignAnswer? _overlapping(String t) {
    final overlap = RegExp(r'\b(?:overlap\w*|acquisition|acquisitions|'
      r'merger|merging|merge)\b').hasMatch(t);
    final addr = RegExp(r'\b(?:address\w*|subnets?|ips?|ranges?)\b')
        .hasMatch(t);
    if (!overlap || !addr) return null;
    final b = StringBuffer();
    b.writeln('Two networks using the same RFC1918 range cannot both be '
        'routed. There are only three honest answers, and they differ in '
        'cost, not in correctness:');
    b.writeln();
    b.writeln('1. Renumber the smaller side. Permanent, no translation, no '
        'surprises for applications - and the only option that gets easier '
        'the sooner it is done. Move one subnet per window, dual-home the '
        'gateway during the move, lower DNS TTLs a week before, and update '
        'the firewall rules as you go.');
    b.writeln('2. Keep both and separate them with VRFs. No address change '
        'and each side keeps its own table, but something must route between '
        'them: a firewall with a leg in each VRF, or a NAT/ALG gateway. '
        'Budget real work for every application that must cross.');
    b.writeln('3. NAT between them. Fastest to stand up, and the one that '
        'breaks quietly: DNS records, certificates, SIP, hard-coded server '
        'addresses and anything that embeds an IP in a payload stop working '
        'in ways that look like an application bug.');
    b.writeln();
    b.writeln('Do this first: inventory the overlap from the route tables, '
        'the ARP tables and the DNS zones - not from the diagram. Then '
        'classify the subnets by what is hard to move: a /24 of laptops is '
        'easy, a /24 with a certificate-bound appliance is a project. Pick '
        'the target plan for the combined company before you move the first '
        'subnet, or you will renumber twice.');
    b.writeln('Rule: never bring up a link between two overlapping networks '
        'just to see what happens - the more specific route wins and one side '
        'disappears. Isolate first, decide, then interconnect.');
    return DesignAnswer(b.toString().trim(), 'overlapping-addresses');
  }

  // --- 100G backbone ---------------------------------------------------

  static DesignAnswer? _backbone100g(String t) {
    final fast = RegExp(r'\b(?:100\s?g(?:b|ig|igabit)?|40\s?g(?:b|ig)?)\b')
        .hasMatch(t);
    final core = RegExp(r'\b(?:backbone|core|aggregation|uplink|fabric)\b')
        .hasMatch(t);
    if (!fast || !core) return null;
    final b = StringBuffer();
    b.writeln('A 100G backbone is a cabling and power project before it is a '
        'switch project. In order:');
    b.writeln();
    b.writeln('1. Where it belongs: aggregation and core, and storage or '
        'GPU traffic. Access stays 1G/2.5G/10G - putting 100G on an access '
        'switch buys nothing the copper can carry.');
    b.writeln('2. Media and reach: DAC 1-3 m in the rack, AOC to about 20 m, '
        '100GBASE-SR4 to 100 m on OM4, DR4 to 500 m, FR4 to 2 km, LR4 to '
        '10 km on single-mode. Pick the optics by reach and by what the '
        'switch port supports - a QSFP28 port that does not list DR4 will not '
        'come up with one.');
    b.writeln('3. Fiber and panels: pre-terminated MPO trunks to each rack '
        'are what make the cutover a patch, not a pull. Test every strand '
        'with an OLTS (loss and length), and keep the report - it is how you '
        'prove a bad link is the optic and not the cable.');
    b.writeln('4. Power and cooling: a 100G optic is roughly 3.5-6 W and a '
        'fully populated 32-port 100G line card is a space heater. Check the '
        'PSU budget and the cold-aisle capacity before the order, not after.');
    b.writeln('5. Design: MLAG/vPC or EVPN multihoming on the pairs, ECMP '
        'across the backbone, MTU 9216 end to end, and jumbo frames only if '
        'every hop agrees. For storage traffic, lossless (PFC/ECN) is a '
        'separate design decision with its own failure modes.');
    b.writeln('6. Monitoring: 100G moves more in a microburst than SNMP can '
        'sample. Use streaming telemetry or at least 10-30 s interface '
        'counters, and watch buffer drops, not just utilization.');
    b.writeln();
    b.writeln('Migration that does not gamble: keep the existing 40G LAG as '
        'the protection, bring the first 100G link up and pass traffic on it '
        'alone for a week, then raise its routing metric. Do not mix 40G and '
        '100G member links inside one LAG - the bundle runs at the slower '
        'rate and hashes unevenly.');
    b.writeln('Rule: buy the cable and the optics for the life of the '
        'building, and the switches for the next five years.');
    return DesignAnswer(b.toString().trim(), 'backbone-100g');
  }

  // --- does the core need BGP? -----------------------------------------

  static DesignAnswer? _bgpAtCore(String t) {
    if (!RegExp(r'\bbgp\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:core|cores|between|internal|inside|igp)\b')
        .hasMatch(t)) {
      return null;
    }
    if (!RegExp(r'\b(?:need|needs|needed|necessary|should|why|worth|'
            r'required)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Not by default. Inside one autonomous system an IGP plus ECMP '
        'does the job, and BGP adds sessions, policy and a second protocol to '
        'troubleshoot. Run BGP at the core when one of these is true:');
    b.writeln();
    b.writeln('- More than one exit to the internet, or more than one AS in '
        'the path (ISPs, partners, an acquired company with its own AS).');
    b.writeln('- You need per-prefix policy - prefer this path for these '
        'prefixes, tag those, filter that - rather than per-destination '
        'routing.');
    b.writeln('- The internal table is large or churny enough that an IGP '
        'cannot summarise it, or you run MPLS/VPN or EVPN where BGP is the '
        'control plane.');
    b.writeln();
    b.writeln('If you do run iBGP inside: two route reflectors instead of a '
        'full mesh (20 routers full-mesh is 190 sessions; with two RRs it is '
        'about 40), an IGP underneath for next-hop reachability and loopback '
        'addresses, and next-hop-self or a shared next-hop policy at the '
        'edge. The IGP does not go away - BGP runs on top of it.');
    b.writeln('If the answer is no: OSPF or IS-IS with ECMP, summarisation at '
        'the ABRs or area boundaries, and static defaults that are tracked. '
        'That is simpler, converges faster and fails in ways you already know.');
    b.writeln('Rule: BGP is a policy tool between autonomous systems. At a '
        'single-site core it is usually the most expensive way to pick the '
        'path the IGP would have picked for free.');
    return DesignAnswer(b.toString().trim(), 'bgp-at-core');
  }

  // --- cloud readiness -------------------------------------------------

  static DesignAnswer? _cloudReadiness(String t) {
    if (!RegExp(r'\bcloud\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:readiness|ready|move|moving|migrat\w*|prepared|'
      r'assessment)\b').hasMatch(t)) {
      return null;
    }
    final users = _headcount(t);
    final b = StringBuffer();
    b.writeln('Cloud readiness is an address, egress and identity question '
        'before it is a firewall question. Check these in order:');
    b.writeln();
    b.writeln('1. Address plan. Compare your RFC1918 ranges with the '
        'provider VPC/VNet defaults (10.0.0.0/16 is the usual collision) and '
        'decide the cloud ranges before the first workload moves. Fixing '
        'this after a VPN is up means renumbering live servers.');
    b.writeln('2. Egress capacity. Budget 50-100 kbps per user for ordinary '
        'SaaS, and up to 1 Mbps per user for video or VDI.');
    if (users != null) {
      final low = (users * 0.05).ceil();
      b.writeln('   - For $users users that is roughly $low Mbps at the low '
          'end and $users Mbps at the video end, so size the circuit for '
          'the peak you actually intend to support.');
    } else {
      b.writeln('   - Multiply by peak concurrency, not headcount.');
    }
    b.writeln('3. Latency. Interactive apps want under about 40 ms RTT to '
        'the region, voice under 150 ms one way. Measure with mtr or the '
        'provider latency tool from the actual office, not from a laptop on '
        'home broadband.');
    b.writeln('4. Path redundancy. Two ISPs, or a dedicated interconnect plus '
        'an internet VPN backup. Test the failover before you depend on it.');
    b.writeln('5. DNS and identity. Lower TTLs on anything you will move, '
        'and make sure identity is SAML/OIDC with MFA - if it is still '
        'NTLM or LDAP on the LAN, that is the real blocker, not bandwidth.');
    b.writeln('6. Security and operations. Egress filtering and TLS '
        'inspection sized for the new traffic, logs shipped to the SIEM, '
        'and a monitoring point beyond your own edge so you can see the '
        'provider path.');
    b.writeln();
    b.writeln('Then migrate in the order that reduces risk: a low-value, '
        'well-understood application first, then the identity and DNS '
        'dependencies, then the workloads that matter. The network work is '
        'usually the shortest part of the plan.');
    b.writeln('Rule: no cloud migration survives an address collision. Check '
        'the ranges and the egress path first - everything else is a '
        'configuration change.');
    return DesignAnswer(b.toString().trim(), 'cloud-readiness');
  }
  // --- spanning-tree root placement -------------------------------------

  static DesignAnswer? _stpRoot(String t) {
    if (!RegExp(r'\b(?:stp|spanning\s*tree|spanning-tree)\b').hasMatch(t)) {
      return null;
    }
    if (!RegExp(r'\broot\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:which|where|who|place|position|primary|secondary|'
            r'choose|pick|should)\b')
        .hasMatch(t)) {
      return null;
    }
    final b = StringBuffer();
    b.writeln('Put the root where the layer-3 gateway is, and choose it '
        'with a number - never let the election pick it.');
    b.writeln();
    b.writeln('- The root belongs on the core or distribution pair, the '
        'closest switch to the router or firewall. Every path is measured '
        'from it, so a root in a closet sends all inter-VLAN traffic through '
        'that closet.');
    b.writeln('- Set it explicitly: spanning-tree vlan <id> root primary on '
        'one core (priority 4096) and root secondary on the other (8192). A '
        'pair gives a deterministic topology and a standby root, and both '
        'values beat the default 32768 without fighting each other.');
    b.writeln('- One root per VLAN, or one root for a group of VLANs that '
        'share the same topology. Two roots for the same VLAN is two '
        'different topologies and a loop waiting for a link event.');
    b.writeln('- Keep the diameter at three or four switches. STP converges '
        'per hop, and a deep tree turns one link flap into a long blackhole.');
    b.writeln('- Protect the election: root guard on every port facing away '
        'from the root, BPDU guard with PortFast on edge ports, loop guard '
        'on the blocked (non-designated) ports.');
    b.writeln();
    b.writeln('Verify with show spanning-tree vlan <id> root - the root '
        'priority, the root ID and the path cost - and show spanning-tree '
        'summary for the port states and the guards. If the root priority is '
        '32768 or 32769, nobody chose the root.');
    b.writeln('Rule: a predictable topology beats a short one. The root is '
        'a design decision, and its default is an accident.');
    return DesignAnswer(b.toString().trim(), 'stp-root');
  }


  // --- how many access points -------------------------------------------------

  /// "How many APs for 120 users at 30 per AP" - device count, airtime math
  /// and the coverage floor that usually wins over the capacity number.
  static DesignAnswer? _apCount(String t) {
    if (!RegExp(r'\b(?:aps?|access\s+points?|waps?)\b').hasMatch(t)) return null;
    if (RegExp(r'\b(?:buy|purchase|price|pricing|which\s+ap|recommend)\b').hasMatch(t)) return null;
    final asks = RegExp(r'\b(?:how\s+many|number\s+of|size|plan|design)\b').hasMatch(t);
    if (!asks) return null;
    // The advisor owns "how many access points do I need for 300 students".
    // The engineer answers the capacity arithmetic only when the question
    // already states a per-AP density to work from.
    if (!RegExp(r'\b(?:per|each|an?)\s+(?:ap|access\s+point)\b').hasMatch(t)) {
      return null;
    }
    final users = RegExp(r'(\d{1,5})\s*(?:users?|clients?|people|staff|patients|students|devices?)\b').firstMatch(t);
    if (users == null) return null;
    final perAp = RegExp(r'(\d{1,3})\s*(?:users?|clients?|devices?)\s*(?:per|an?|each)\s*(?:ap|access\s+point)\b').firstMatch(t);
    final density = perAp == null ? 30 : int.tryParse(perAp.group(1)!) ?? 30;
    if (density < 1 || density > 200) return null;
    final count = int.parse(users.group(1)!);
    if (count < 1) return null;
    final devices = (count * 1.5).ceil();
    final apCount = (devices / density).ceil();
    final coverage = (count / 25).ceil();
    final planned = apCount > coverage ? apCount : coverage;
    final b = StringBuffer();
    b.writeln('For $count users at about $density active devices per AP:');
    b.writeln();
    b.writeln('- Assumption stated first: 1.5 devices per user (laptop plus phone), so $count users is about $devices concurrent devices. If everyone is a desk phone user, or a student with a tablet, that factor changes and the answer with it.');
    b.writeln('- Capacity floor: $devices devices / $density per AP = $apCount APs.');
    b.writeln('- Coverage floor: an office AP covers roughly 1,500-2,000 sq ft, which is about 20-25 users of floor area. For $count users that is at least $coverage APs, so plan for $planned.');
    b.writeln('- The usual mistake is quoting the capacity number only. A room with 6 users still needs its own AP, so a plan with $apCount APs for $count users fails in the corners, not in the middle.');
    b.writeln('- Channels: 5 GHz has about 25 non-overlapping 20 MHz channels in the US (19 in the EU, and fewer once DFS is excluded). $planned APs fit in 5 GHz with a 1/6/11-style reuse plan; they do not fit in 2.4 GHz, which has 3.');
    b.writeln('- Airtime is the real constraint: 30 devices per AP at 20% each is 600% of airtime. Plan for under 50% channel utilisation at peak, and use 40 MHz only where the AP count allows it.');
    b.writeln('- Verify after deployment: show ap client summary, per-AP airtime, retry rate and the number of clients above -67 dBm. If utilisation is above 50% or retries above 10%, add APs before you add bandwidth.');
    return DesignAnswer(b.toString().trim(), 'ap-count');
  }

  static String _num(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(1);
  }
}
