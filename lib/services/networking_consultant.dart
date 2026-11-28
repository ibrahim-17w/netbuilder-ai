import 'casual_english.dart';
import 'network_tools.dart';
import 'phrase_match.dart';

/// One consulting answer, with the topic id that produced it.
class ConsultantAnswer {
  final String text;
  final String topic;

  const ConsultantAnswer(this.text, {required this.topic});
}

/// The capacity and architecture layer: the arithmetic a senior network
/// engineer does before drawing anything.
///
/// The corpus answers "what is X" and the fault playbooks answer "X is
/// broken". Neither answers the questions that decide whether a design is
/// sound: how many calls fit, what the access uplink must be, how large the
/// DHCP pool has to be, how many routes a box can hold, where the layer-2
/// domain must stop, how the address plan is carved, and which WAN pattern
/// fits the stated sites, bandwidth, latency and redundancy.
///
/// Every answer here follows the same discipline:
///
/// * it states the assumptions it used, because an estimate without its
///   inputs is a guess wearing a number;
/// * it shows the arithmetic, so the user can change one input and see the
///   effect;
/// * it names the design rule behind the arithmetic, not just the result;
/// * it ends with what would change the answer and the command that proves
///   the deployed result;
/// * it never invents a purchase recommendation. Sizing a link is
///   engineering; choosing a vendor is the advisor's job.
///
/// The layer is deliberately conservative about matching. A capacity or
/// architecture answer needs a quantitative or architectural signal, so an
/// ordinary definition question cannot be swallowed by a calculator.
class NetworkingConsultant {
  const NetworkingConsultant._();

  /// A build brief with a counted device list belongs to the planner, not to
  /// the architecture layer. "Design 3 buildings" is architecture; "build a
  /// network with 10 PCs, 2 switches and 1 DHCP server" is a plan.
  static final RegExp _buildVerb = RegExp(
    r'\b(?:build|make|create|design|set ?up|setup|add|deploy|produce|'
    r'generate|plan)\b',
  );

  static final RegExp _countedDevice = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches?|switch|pcs?|computers?|'
    r'workstations?|servers?|laptops?|printers?|phones?|firewalls?|'
    r'tablets?|access\s+points?|aps?|hosts?)\b',
  );

  /// The consulting answer, or null when the message is not one.
  static ConsultantAnswer? answer(String rawText) {
    final raw = rawText.trim().toLowerCase();
    final t = CasualEnglish.canonical(raw);
    if (t.isEmpty) return null;
    final evidence = raw == t ? t : '$raw\n$t';
    if (_buildVerb.hasMatch(t) && _countedDevice.hasMatch(t)) return null;

    return _migration(evidence) ??
        _wirelessDesign(evidence) ??
        _switchTiers(evidence) ??
        _dnsServers(evidence) ??
        _wanArchitecture(evidence) ??
        _campusDesign(evidence) ??
        _dmzDesign(evidence) ??
        _voice(evidence) ??
        _uplink(evidence) ??
        _dhcpServers(evidence) ??
        _dhcpPool(evidence) ??
        _bgpScale(evidence) ??
        _ospfScale(evidence) ??
        _stpDiameter(evidence) ??
        _ipv6Plan(evidence) ??
        _ipv4Plan(evidence) ??
        _wanSizing(evidence) ??
        _firewallScale(evidence) ??
        _broadcastDomain(evidence);
  }

  // --- shared parsing ------------------------------------------------------

  static bool _has(String t, String phrase) => PhraseMatch.has(t, phrase);

  static bool _any(String t, List<String> phrases) =>
      phrases.any((phrase) => _has(t, phrase));

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

  static int? _firstInt(RegExp pattern, String t) {
    final m = pattern.firstMatch(t);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }

  static final RegExp _usersPattern = RegExp(
    r'\b(\d{1,6})\s*(?:users?|employees?|staff|people|seats?|agents?|'
    r'students?|workers?|devices?|hosts?|phones?|endpoints?)\b',
  );

  static final RegExp _devicePattern = RegExp(
    r'\b(\d{1,6})\s+(?:[a-z]+\s+){0,2}(?:devices?|hosts?|endpoints?|'
    r'clients?|users?|phones?|laptops?|pcs?|workstations?)\b',
  );

  static final RegExp _sitesPattern = RegExp(
    r'\b(\d{1,6})\s+(?:[a-z]+\s+){0,2}(?:sites?|branches|offices|'
    r'locations|buildings?|campuses|campus|stores?|clinics?|warehouses?)\b',
  );

  static final RegExp _percentPattern = RegExp(r'(\d{1,3})\s*%');

  /// A link rate in Mbps. "10g", "2.5 gbps", "100 mbps" and "512 kbps" all
  /// resolve; "50 ms" does not, because no unit follows the m.
  static final RegExp _ratePattern = RegExp(
    r'(\d+(?:\.\d+)?)\s*(gbps|gbit|gbe|mbps|mbit|kbps|kbit|g|m|k)\b',
  );

  static double? _rateMbps(String t) {
    final m = _ratePattern.firstMatch(t);
    if (m == null) return null;
    final value = double.tryParse(m.group(1) ?? '');
    if (value == null) return null;
    final unit = m.group(2)!;
    if (unit.startsWith('g')) return value * 1000;
    if (unit.startsWith('m')) return value;
    return value / 1000;
  }

  static String _rateLabel(double mbps) {
    if (mbps >= 1000) return '${_num(mbps / 1000)} Gbps';
    if (mbps < 1) return '${_num(mbps * 1000)} kbps';
    return '${_num(mbps)} Mbps';
  }

  static final RegExp _prefixPattern = RegExp(r'/\s*(\d{1,3})\b');

  static int? _prefix(String t) {
    final m = _prefixPattern.firstMatch(t);
    if (m == null) return null;
    final value = int.tryParse(m.group(1) ?? '');
    if (value == null || value < 0 || value > 32) return null;
    return value;
  }

  // --- voice capacity ------------------------------------------------------

  /// Codec payload, on-the-wire rate and packet rate, from the vendor-neutral
  /// numbers every voice design starts from (20 ms packetisation, IPv4/UDP/
  /// RTP, Ethernet framing without a VLAN tag).
  static const Map<String, (int, double, double, String)> _codecs = {
    'g711': (64, 87.2, 50, 'G.711, 64 kbps payload'),
    'g722': (64, 87.2, 50, 'G.722, 64 kbps payload'),
    'g729': (8, 31.2, 50, 'G.729, 8 kbps payload'),
    'opus': (32, 55.0, 50, 'Opus, 32 kbps typical payload'),
  };

  static ConsultantAnswer? _voice(String t) {
    final voice = _any(t, const [
      'voice',
      'voip',
      'call',
      'calls',
      'codec',
      'g711',
      'g729',
      'g722',
      'opus',
      'erlang',
      'concurrent calls',
    ]);
    if (!voice) return null;
    final capacityAsk = RegExp(
      r'\b(?:how many|how much|capacity|size|concurrent|simultaneous|'
      r'bandwidth|mbps|kbps|link|support|handle|erlang|fit|fits|'
      r'utilization|headroom)\b',
    ).hasMatch(t);
    if (!capacityAsk) return null;
    // A quality complaint is a fault, not a capacity question. The playbook
    // layer owns it.
    if (RegExp(
      r'\b(?:bad|poor|choppy|garbled|jitter|delay|lag|quality|dropping|'
      r'drops?|broken|not working|one-way|one way|echo)\b',
    ).hasMatch(t)) {
      return null;
    }

    final key = _has(t, 'g729')
        ? 'g729'
        : _has(t, 'g722')
        ? 'g722'
        : _has(t, 'opus')
        ? 'opus'
        : 'g711';
    final codec = _codecs[key]!;
    final link = _rateMbps(t);
    final users = _firstInt(_usersPattern, t);
    final percent = _firstInt(_percentPattern, t);
    final literalCalls = _firstInt(
      RegExp(r'\b(\d{1,5})\s*(?:concurrent\s+|simultaneous\s+)?calls?\b'),
      t,
    );
    final erlangs = _firstInt(RegExp(r'\b(\d{1,6})\s*erlangs?\b'), t);

    // Every input is optional; the answer is built from what was said and
    // states the rest as an assumption.
    final busyHour = _any(t, const ['erlang', 'busy hour', 'busy-hour']);
    var demand = literalCalls;
    var concurrency = percent;
    if (demand == null && users != null && !busyHour) {
      concurrency ??= 10;
      demand = (users * concurrency / 100).ceil();
    }
    if (demand == null && erlangs != null) demand = erlangs;

    final perCallMbps = codec.$2 / 1000;
    final headroom = 0.8;
    final lineCapacity = link == null
        ? null
        : (link * headroom / perCallMbps).floor();

    if (demand == null && lineCapacity == null && erlangs == null) {
      // A bare "how much bandwidth does a voip call need" still deserves the
      // per-call table, and so does "how many calls per site" before the user
      // has given a user count.
      if (!RegExp(
        r'\b(?:bandwidth|kbps|mbps|size|how many|capacity|concurrent|'
        r'per site)\b',
      ).hasMatch(t)) {
        return null;
      }
    }

    final b = StringBuffer();
    b.writeln('Voice capacity - ${codec.$4}, 20 ms packetisation.');
    b.writeln();
    b.writeln('Per call, per direction:');
    b.writeln(
      '- ${codec.$1} kbps codec payload, ${_num(codec.$2)} kbps on the '
      'wire including IP/UDP/RTP and Ethernet framing.',
    );
    b.writeln(
      '- ${_num(codec.$3)} packets per second. Bandwidth is counted per '
      'direction, so a full-duplex link carries this many calls each way, '
      'not twice as many in one direction.',
    );
    b.writeln(
      '- Silence suppression cuts average load by roughly 40%, but never '
      'size to the average: a conference bridge or a hunt group has no '
      'silence.',
    );

    if (link != null && lineCapacity != null) {
      b.writeln();
      b.writeln(
        'On ${_rateLabel(link)} at ${(headroom * 100).round()}% usable: '
        '$lineCapacity concurrent calls per direction '
        '(${_num(lineCapacity * perCallMbps)} Mbps of voice).',
      );
      b.writeln(
        '- The remaining 20% is not waste: it absorbs signalling, a burst of '
        'simultaneous ringback, and the microbursts that a policer would '
        'otherwise drop.',
      );
    }

    if (demand == null && lineCapacity == null && erlangs == null) {
      b.writeln();
      b.writeln(
        'To turn this into a per-site number: at a typical office about 10% '
        'of users are on a call at the busiest moment, and a busy hour offers '
        'about 0.2 erlangs per user. 100 users is therefore about 10 '
        'concurrent calls, or 20 erlangs, which needs '
        '${_erlangB(20, 0.01)} circuits at 1% blocking. Use the real '
        'busy-hour figure if the site has one - a call centre is not an '
        'office.',
      );
    }

    if (demand != null) {
      final needed = demand * perCallMbps;
      b.writeln();
      b.writeln(
        'Demand: $demand concurrent calls need ${_num(needed)} Mbps of '
        'voice payload'
        '${concurrency != null && users != null ? ' (${_num(concurrency.toDouble())}% of $users users)' : ''}.',
      );
      if (link != null && lineCapacity != null) {
        final verdict = lineCapacity >= demand
            ? 'The link fits, with ${lineCapacity - demand} calls of room.'
            : 'The link does not fit: it is ${demand - lineCapacity} calls '
                  'short. The fix is a second link, a lower-bitrate codec, or '
                  'call admission control - not silence suppression.';
        b.writeln('- $verdict');
      }
    }

    if (erlangs != null || (users != null && busyHour)) {
      final offered = erlangs?.toDouble() ?? users! * 0.2;
      final circuits = _erlangB(offered, 0.01);
      b.writeln();
      b.writeln(
        'Erlang view: ${_num(offered)} erlangs of offered traffic needs '
        '$circuits circuits for 1% blocking (Erlang B). The concurrency '
        'count and the Erlang count answer different questions: one is peak '
        'simultaneous calls, the other is total busy-hour load. Provision for '
        'the peak, then confirm the busy hour.',
      );
    }

    b.writeln();
    b.writeln('Design rules that make the number real:');
    b.writeln(
      '- Put voice in a priority queue sized to the calculated peak, with a '
      'policer on it. An unpoliced priority queue starves data during a '
      'signalling storm.',
    );
    b.writeln(
      lineCapacity == null
          ? '- Enable call admission control at the WAN edge so the '
                'calculated peak cannot be exceeded by a busy hour.'
          : '- Enable call admission control at the WAN edge so the '
                '$lineCapacity call ceiling cannot be exceeded by a busy '
                'hour.',
    );
    b.writeln(
      '- Mark EF (DSCP 46) at the phone, trust it on the access switch, and '
      'keep the trust boundary off user ports.',
    );
    b.writeln(
      '- Budget one signalling stream per phone plus the call load: SIP '
      'registration bursts, not media, are what overflow a small queue.',
    );
    b.writeln();
    b.writeln(
      'Verify: show call active voice brief (per-call codec and jitter), '
      'show policy-map interface (priority-queue drops), and a real busy-hour '
      'sample - a calculated ceiling is only proven by observed load.',
    );
    b.writeln(
      'What changes it: a different codec (G.729 is about a third of G.711 '
      'on the wire), header compression, a VLAN tag adding 4 bytes, or '
      'SRTP adding authentication overhead.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'voice-capacity');
  }

  /// Erlang B: the number of circuits needed so that the probability of
  /// blocking stays at or below [target].
  static int _erlangB(double erlangs, double target) {
    if (erlangs <= 0) return 0;
    var blocking = 1.0;
    for (var circuits = 1; circuits <= 100000; circuits++) {
      blocking = erlangs * blocking / (circuits + erlangs * blocking);
      if (blocking <= target) return circuits;
    }
    return 100000;
  }

  // --- access uplink and oversubscription ----------------------------------

  static ConsultantAnswer? _uplink(String t) {
    final uplinkAsk =
        _has(t, 'oversubscription') ||
        _has(t, 'oversubscribed') ||
        ((_has(t, 'uplink') || _has(t, 'up-link')) &&
            (_any(t, const [
                  'size',
                  'bandwidth',
                  'how many',
                  'how much',
                  'what size',
                  'what uplink',
                  'ratio',
                ]) ||
                RegExp(r'\b\d{1,3}\s*:\s*1\b').hasMatch(t))) ||
        (_has(t, 'trunk') &&
            _any(t, const [
              'bandwidth',
              'size',
              'capacity',
              'oversubscription',
            ])) ||
        (_has(t, 'access switch') &&
            _any(t, const ['uplink', 'oversubscription']));
    if (!uplinkAsk) return null;

    final ports =
        _firstInt(RegExp(r'\b(\d{1,3})\s*(?:ports?|port)\b'), t) ?? 48;
    final speedMatch = RegExp(
      r'\b(\d{1,3}(?:\.\d+)?)\s*(?:g|gbps|gbe)\b',
    ).firstMatch(t);
    final portSpeed = double.tryParse(speedMatch?.group(1) ?? '') ?? 1;
    final ratio = _firstInt(RegExp(r'\b(\d{1,3})\s*(?::|to)\s*1\b'), t) ?? 20;

    final subscription = ports * portSpeed;
    final average = subscription / ratio;
    final peak = average * 1.5;

    final (recommend, why) = peak <= 20
        ? (
            '2 x 10 Gbps in a LAG (20 Gbps)',
            'two 10 Gbps members give a 20 Gbps bundle, survive one member '
                'failing, and keep the oversubscription near the design '
                'target without buying 40 Gbps for average traffic.',
          )
        : peak <= 40
        ? (
            '4 x 10 Gbps or 2 x 25 Gbps',
            'the busy-hour peak is above a single 20 Gbps bundle, so the '
                'uplink needs either four 10 Gbps members or two 25 Gbps '
                'members.',
          )
        : peak <= 80
        ? (
            '2 x 40 Gbps',
            'two 40 Gbps members carry the peak with one member of headroom; '
                'do not build this as a single 40 Gbps link.',
          )
        : peak <= 200
        ? (
            '2 x 100 Gbps',
            'the peak is beyond a 40 Gbps bundle, so the access layer needs a '
                '100 Gbps uplink pair and the core must have the ports for it.',
          )
        : (
            '4 x 100 Gbps',
            'at this rate one pair of 100 Gbps links is not enough; this is a '
                'fabric or core design, not an access-closet uplink.',
          );
    final bundle = peak <= 20
        ? 20.0
        : peak <= 40
        ? 40.0
        : peak <= 80
        ? 80.0
        : peak <= 200
        ? 200.0
        : 400.0;

    final b = StringBuffer();
    b.writeln(
      'Uplink sizing for $ports x ${_num(portSpeed)}G access ports at a '
      '$ratio:1 oversubscription target.',
    );
    b.writeln();
    b.writeln('The arithmetic:');
    b.writeln('- Line-rate subscription: ${_num(subscription)} Gbps.');
    b.writeln(
      '- Average load at $ratio:1: ${_num(average)} Gbps. Peak at 1.5x '
      'average: ${_num(peak)} Gbps.',
    );
    b.writeln('- Recommended bundle: $recommend.');
    b.writeln('- Why: $why');
    b.writeln(
      '- At that bundle the line-rate ratio is '
      '${_num(subscription / bundle)}:1 and the busy-hour peak is '
      '${_num(peak / bundle)}:1. Design to the peak, and treat the line-rate '
      'ratio as the growth ceiling.',
    );

    b.writeln();
    b.writeln('The ratios worth knowing:');
    b.writeln(
      '- Access to distribution: 20:1 is the common design target, 10:1 if '
      'the closets serve power users or imaging traffic.',
    );
    b.writeln(
      '- Distribution to core: 4:1. Core to core: 1:1 to 2:1, because every '
      'site and every server pair crosses it.',
    );
    b.writeln(
      '- These are busy-hour averages, not guarantees. A backup job, an OS '
      'deployment or a video all-hands can exceed the ratio for minutes at a '
      'time, which is why the uplink is sized to peak and not to average.',
    );

    b.writeln();
    b.writeln('What the ratio does not tell you:');
    b.writeln(
      '- A LAG hashes per flow, not per packet. One elephant flow uses one '
      'member, so a 20 Gbps bundle can still bottleneck a single 10 Gbps '
      'transfer.',
    );
    b.writeln(
      '- Stacking or a virtual chassis changes the failure domain: the bundle '
      'survives a member link, not the loss of the whole stack.',
    );
    b.writeln(
      '- A 1 Gbps access port is still 1 Gbps. Oversubscription is a bet that '
      'not every port is busy at once, and the bet is only safe when the '
      'busy-hour profile is known.',
    );
    b.writeln();
    b.writeln(
      'Verify: interface rate and errors on every member, a per-member '
      'traffic sample, and the interface load interval shortened to 30 s '
      'during the busy hour. show etherchannel summary proves the bundle is '
      'up; only counters prove it is not saturated.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'uplink-sizing');
  }

  // --- DHCP server redundancy ---------------------------------------------

  static ConsultantAnswer? _dhcpServers(String t) {
    if (!_has(t, 'dhcp')) return null;
    if (!_any(t, const [
      'server',
      'servers',
      'redundancy',
      'redundant',
      'failover',
      'high availability',
      'ha pair',
      'resilience',
      'resilient',
    ])) {
      return null;
    }
    if (!_any(t, const [
      'how many',
      'need',
      'design',
      'redundancy',
      'redundant',
      'failover',
      'resilience',
      'resilient',
      'best practice',
      'should i',
    ])) {
      return null;
    }

    final sites = _firstInt(_sitesPattern, t);
    final b = StringBuffer();
    b.writeln('DHCP server redundancy.');
    b.writeln();
    b.writeln(
      '- Two DHCP servers, on separate hosts or clusters, each with a full '
      'copy of every scope. One server is a single point of failure for every '
      'new lease and every renewal.',
    );
    b.writeln(
      '- Split scope: server A serves the first half, B the second, each '
      'excludes the other half, and the relay lists both. 50/50 is the modern '
      'split; 80/20 is legacy and leaves the second server idle.',
    );
    b.writeln(
      '- Failover: load-balance for offices, hot-standby for critical scopes, '
      'with MCLT and max-response-delay set and the failover state monitored. '
      'A pair sitting in recover state is not redundant.',
    );
    b.writeln(
      '- Do not run two independent servers with overlapping pools and no '
      'coordination; that is a duplicate-address generator, not redundancy.',
    );
    b.writeln(
      '- A central pair across the WAN works until the WAN fails: existing '
      'leases survive to T1, but new clients get nothing. Put a local '
      'survivable server at sites that cannot wait for the WAN, or run a pair '
      'per site.',
    );
    b.writeln(
      '- Servers static, NTP-synced, one scope per VLAN, relay on the SVI, '
      'and options for gateway, DNS and domain - not just an address pool.',
    );
    if (sites != null) {
      b.writeln();
      if (sites <= 1) {
        b.writeln(
          'For one site, two servers on separate hosts is the design; a '
          'second subnet on the same server is not redundancy.',
        );
      } else {
        b.writeln(
          'For $sites sites, decide explicitly whether a site must issue '
          'new leases during a WAN outage. If yes, each such site needs a '
          'local server (a pair for critical sites); if no, document that a '
          'WAN outage blocks new joins and plan the lease time around it.',
        );
      }
    }
    b.writeln();
    b.writeln(
      'Verify: show ip dhcp binding, show ip dhcp server statistics, the '
      'failover state on both servers, and a relay counter on the SVI. Then '
      'shut one server down and request a lease; a plan nobody has failed '
      'over is untested.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'dhcp-redundancy');
  }

  // --- DHCP pool sizing ----------------------------------------------------

  static ConsultantAnswer? _dhcpPool(String t) {
    final dhcp = _has(t, 'dhcp');
    if (!dhcp) return null;
    final poolAsk =
        _any(t, const ['pool', 'scope', 'how many', 'how big', 'size']) ||
        _has(t, 'lease');
    if (!poolAsk) return null;
    // Fault questions belong to the playbook.
    if (RegExp(
      r'\b(?:not working|fails?|failing|no ip|169\.254|snooping|relay|'
      r'rogue|conflict|stuck)\b',
    ).hasMatch(t)) {
      return null;
    }

    final devices = _firstInt(_devicePattern, t) ?? _firstInt(_usersPattern, t);
    final prefix = _prefix(t);
    final guest = _any(t, const ['guest', 'byod', 'visitor', 'public']);
    final office = _any(t, const ['office', 'staff', 'employee', 'campus']);

    final b = StringBuffer();
    b.writeln('DHCP scope sizing.');
    b.writeln();
    if (devices != null) {
      final factor = guest
          ? 3.0
          : office
          ? 1.5
          : 2.0;
      final needed = (devices * factor).ceil();
      b.writeln(
        '$devices devices with ${guest
            ? 'guest device churn (3x)'
            : office
            ? 'office churn (1.5x)'
            : 'a 2x pool factor'} '
        'needs about $needed addresses.',
      );
      b.writeln(
        '- A pool smaller than the device count fails on the day everyone '
        'arrives at once; a pool far larger than the device count wastes '
        'address space that another VLAN will need.',
      );
      const reserved = 20;
      final required = needed + reserved;
      final size = required <= 254
          ? '/24 (254 usable)'
          : required <= 510
          ? '/23 (510 usable)'
          : required <= 1022
          ? '/22 (1,022 usable)'
          : '/21 (2,046 usable)';
      b.writeln(
        '- Smallest scope that fits: $size. That is $needed leaseable '
        'addresses plus $reserved reserved for gateways, switches, printers '
        'and the DHCP server; exclude the reserved addresses from the pool.',
      );
    } else if (prefix != null) {
      final info = NetworkTools.subnet('0.0.0.0/$prefix');
      final usable = info?.usableHosts ?? 0;
      final devicesFit = ((usable - 20).clamp(0, usable) / (guest ? 3 : 1.5))
          .floor();
      b.writeln(
        '/$prefix gives $usable usable addresses; after 20 reserved for '
        'infrastructure it covers about $devicesFit devices at a '
        '${guest ? '3x guest' : '1.5x office'} factor. If the device count is '
        'higher, move to a shorter prefix; do not shrink the lease time to '
        'compensate for an undersized pool.',
      );
    } else {
      b.writeln(
        'The pool is sized from the device count, not from the subnet size: '
        'a /24 is 254 usable addresses, and a pool of 254 in an office with '
        '200 devices will exhaust at the first meeting.',
      );
    }

    b.writeln();
    b.writeln('Lease and relay rules:');
    b.writeln(
      '- Office wired and wireless: 8 hours. Guest: 1 to 2 hours. Servers '
      'and printers: reservations, not leases.',
    );
    b.writeln(
      '- T1 renews at 50% of the lease, T2 rebinds at 87.5%. A lease shorter '
      'than the DHCP outage you can tolerate turns one server problem into '
      'every device losing its address.',
    );
    b.writeln(
      '- One scope per VLAN, with the router as the relay agent '
      '(ip helper-address). A single flat scope across VLANs cannot '
      'distinguish them and cannot be secured.',
    );
    b.writeln(
      '- The relay must be reachable from the server, and the scope must '
      'match the relay interface, not the server subnet. That mismatch is '
      'the classic reason a relay answers nothing.',
    );
    b.writeln(
      '- Run DHCP snooping on access ports and trust only the uplink toward '
      'the real server. Without it, any laptop can become the default gateway '
      'for its segment.',
    );
    b.writeln();
    b.writeln(
      'Verify: show ip dhcp pool (used versus total), show ip dhcp binding, '
      'and a lease renewal test from a client in the furthest VLAN, not from '
      'the server room.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'dhcp-sizing');
  }

  // --- BGP scale -----------------------------------------------------------

  static ConsultantAnswer? _bgpScale(String t) {
    if (!_has(t, 'bgp')) return null;
    final ask = _any(t, const [
      'full table',
      'full-table',
      'internet table',
      'memory',
      'max-prefix',
      'max prefix',
      'prefix limit',
      'prefix-limit',
      'how many routes',
      'how many prefixes',
      'how many peers',
      'how many sessions',
      'scale',
      'fit',
      'table size',
    ]);
    if (!ask) return null;
    if (RegExp(
      r'\b(?:stuck|idle|active|flap|not working|no prefixes)\b',
    ).hasMatch(t)) {
      return null;
    }

    final peers = _firstInt(
      RegExp(r'\b(\d{1,4})\s*(?:peers?|sessions?|neighbors?|neighbours?)\b'),
      t,
    );
    final routes = _firstInt(
      RegExp(r'\b(\d{4,9})\s+(?:[a-z]+\s+){0,2}(?:routes?|prefixes?)\b'),
      t.replaceAll(',', ''),
    );
    final fullTable = _any(t, const [
      'full table',
      'full-table',
      'internet table',
    ]);
    final routeCount = routes ?? (fullTable ? 1000000 : null);

    final b = StringBuffer();
    b.writeln('BGP scale planning.');
    b.writeln();
    b.writeln('Reference numbers:');
    b.writeln(
      '- The global IPv4 table is around one million prefixes and the IPv6 '
      'table a few hundred thousand; both grow every year, so size to the '
      'next header, not to last year.',
    );
    b.writeln(
      '- Memory is roughly 0.5 to 1 KB per path depending on attributes and '
      'platform, so one million IPv4 paths is about 0.5 to 1 GB of RIB plus '
      'the FIB it feeds. Treat that as an order of magnitude, not a spec - '
      'the datasheet number is measured with a route profile, not yours.',
    );
    b.writeln(
      '- A route reflector removes the full-mesh session count but not the '
      'memory: every client still holds the paths it needs.',
    );

    final memoryGb = _firstInt(RegExp(r'\b(\d{1,3})\s*gb\b'), t);
    if (memoryGb != null) {
      b.writeln();
      b.writeln(
        'A $memoryGb GB box has roughly ${_thousands(memoryGb * 500000)} '
        'to ${_thousands(memoryGb * 1000000)} paths of BGP memory at 0.5 to '
        '1 KB per path. Halve that for FIB, process and attribute overhead: '
        'plan ${_thousands(memoryGb * 250000)} to '
        '${_thousands(memoryGb * 500000)} paths. On most platforms the FIB '
        'or TCAM limit binds before RAM does, so check both.',
      );
    }

    if (routeCount != null) {
      final low = routeCount / 1000000 * 0.5;
      final high = routeCount / 1000000 * 1.0;
      final maxPrefix = (routeCount * 1.1).ceil() + 1000;
      b.writeln();
      b.writeln(
        'For ${_thousands(routeCount)} received prefixes, plan about '
        '${_num(low)} to ${_num(high)} GB of BGP memory, then double it for '
        'headroom and for the second address family if both are carried.',
      );
      b.writeln(
        '- Set maximum-prefix ${_thousands(maxPrefix)} 80 so the session '
        'warns at 80% and shuts down rather than exhausting the box.',
      );
      b.writeln(
        '- The max-prefix value is not a security afterthought: an unfiltered '
        'session can advertise the whole table and take the router down.',
      );
    }

    if (peers != null) {
      b.writeln();
      b.writeln(
        'For $peers sessions, the cost is per-path memory plus one TCP '
        'session and one update queue per peer. Above roughly two dozen '
        'full-table peers on a single box, use route reflectors or an '
        'outbound route filter; above a few hundred, the control plane, not '
        'the bandwidth, is the limit.',
      );
    }

    b.writeln();
    b.writeln('Policy that keeps the scale honest:');
    b.writeln(
      '- Inbound: a prefix-list and an as-path filter before any route is '
      'accepted. A default route is not a substitute for a filter.',
    );
    b.writeln(
      '- Outbound: advertise only what you own, with a summary where the '
      'provider accepts one. Every extra prefix is memory in every peer.',
    );
    b.writeln(
      '- BFD for failure detection and a maximum-prefix with a restart timer '
      'for protection; BGP timers alone take minutes to notice a dead peer.',
    );
    b.writeln(
      '- Communities for policy (no-export, blackhole, customer traffic) '
      'instead of matching on prefixes that change.',
    );
    b.writeln();
    b.writeln(
      'Verify: show ip bgp summary (prefix count per peer), show ip bgp '
      'memory, show ip route summary, and show processes memory sorted '
      'during a full table refresh - not after it settles.',
    );
    b.writeln(
      'What changes it: route-reflector design, add-path (more paths, more '
      'memory), RPKI validation (more CPU), and whether the platform keeps '
      'the RIB in software or in hardware only.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'bgp-scale');
  }

  // --- OSPF scale ----------------------------------------------------------

  static ConsultantAnswer? _ospfScale(String t) {
    if (!_has(t, 'ospf')) return null;
    final ask = _any(t, const [
      'how many',
      'scale',
      'size',
      'limit',
      'maximum',
      'max routers',
      'database size',
    ]);
    if (!ask) return null;
    if (RegExp(
      r'\b(?:stuck|init|exstart|loading|twoway|not working|flap)\b',
    ).hasMatch(t)) {
      return null;
    }

    final routers = _firstInt(
      RegExp(r'\b(\d{1,5})\s*(?:routers?|nodes?)\b'),
      t,
    );
    final lsas = routers == null ? null : routers * 4;
    final b = StringBuffer();
    b.writeln('OSPF area sizing.');
    b.writeln();
    b.writeln(
      'An area is a flooding domain. Its size is bounded by LSAs and SPF '
      'time, not by a licence limit:',
    );
    b.writeln(
      '- Keep an area under about 50 routers and a few thousand LSAs. Beyond '
      'that every topology change forces a full SPF over a larger database '
      'and convergence becomes the problem, not bandwidth.',
    );
    b.writeln(
      '- Type 1 LSAs scale with routers, type 2 with broadcast segments, type '
      '3 with prefixes, and type 5 with every external route an ASBR '
      'redistributes. Externals are usually what actually fills the database.',
    );
    b.writeln(
      '- Area 0 must be contiguous. If it is not, fix the design or use a '
      'virtual link as a temporary bridge, not as architecture.',
    );
    if (routers != null) {
      b.writeln();
      b.writeln(
        'At $routers routers, plan for on the order of '
        '${_num(lsas!.toDouble())} router and network LSAs before summaries and '
        'externals (allowing four segments per router). That fits one area '
        'comfortably; the reason to split is failure isolation and summary '
        'control, not the raw count.',
      );
    }
    b.writeln();
    b.writeln('What a good hierarchy buys:');
    b.writeln(
      '- Summarization at the ABR: one type 3 per summary instead of one per '
      'prefix. A flapping edge link then stops affecting the core.',
    );
    b.writeln(
      '- Stub or totally stubby areas keep type 5 externals out of areas that '
      'do not need them. An NSSA does the same while allowing local '
      'redistribution.',
    );
    b.writeln(
      '- A stable router ID and loopback address per router makes the '
      'database readable; duplicate router IDs break adjacency in ways the '
      'routing table never explains.',
    );
    b.writeln();
    b.writeln(
      'Verify: show ip ospf database (counts by LSA type), show ip ospf '
      'statistics (SPF runs and durations), show ip ospf neighbor (all '
      'FULL), and show ip route ospf after a deliberate link bounce.',
    );
    b.writeln(
      'What changes it: summarization, stub areas, the number of externals, '
      'and whether the platform runs SPF incrementally. A big area with no '
      'externals is healthier than a small one flooded with type 5s.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'ospf-scale');
  }

  // --- spanning tree diameter ---------------------------------------------

  static ConsultantAnswer? _stpDiameter(String t) {
    final stp = _any(t, const [
      'spanning tree',
      'spanning-tree',
      'stp',
      'rstp',
      'layer 2 domain',
      'layer-2 domain',
      'l2 domain',
    ]);
    if (!stp) return null;
    final ask = _any(t, const [
      'how many switches',
      'how deep',
      'diameter',
      'hops',
      'how big',
      'size',
      'limit',
      'how far',
    ]);
    if (!ask) return null;

    final switches = _firstInt(
      RegExp(r'\b(\d{1,4})\s*(?:switches|bridges|nodes)\b'),
      t,
    );
    final b = StringBuffer();
    b.writeln('Layer-2 domain and spanning-tree diameter.');
    b.writeln();
    b.writeln(
      'The protocol limits are the easy part: classic 802.1D is seven bridges '
      'deep with a 20-hop BPDU budget, and RSTP/MSTP can run wider but still '
      'flushes MAC tables on every topology change.',
    );
    b.writeln(
      'The design limit is smaller than the protocol limit: keep any one '
      'layer-2 domain to about four to seven switch hops from the root. '
      'Beyond that, a single access-port flap is felt across the whole '
      'domain and convergence time stops being predictable.',
    );
    if (switches != null) {
      b.writeln();
      b.writeln(
        'For $switches switches, a single flat domain is over the practical '
        'limit once the topology is deeper than about seven hops. Split it '
        'into routed blocks at the distribution layer and let each block keep '
        'its own tree.',
      );
    }
    b.writeln();
    b.writeln('Design rules:');
    b.writeln(
      '- Put the root where the traffic goes, not on the oldest switch: set '
      'priority explicitly on the core pair (root primary and root '
      'secondary).',
    );
    b.writeln(
      '- PortFast and BPDU Guard on every user port. A user hub or a rogue '
      'switch behind a desk is how loops enter a well-built domain.',
    );
    b.writeln(
      '- Root Guard on ports toward other domains and Loop Guard on '
      'point-to-point links, so a unidirectional failure cannot create a '
      'silent loop.',
    );
    b.writeln(
      '- One tree is not one VLAN: with PVST the number of instances scales '
      'with VLANs, while MST maps many VLANs to a few instances. Choose MST '
      'above a few dozen VLANs and keep the region parameters identical.',
    );
    b.writeln(
      '- Faster than tuning STP: route the access layer. A routed link '
      'converges in milliseconds with BFD and does not block half the '
      'capacity.',
    );
    b.writeln();
    b.writeln(
      'Verify: show spanning-tree summary (root, topology changes), show '
      'spanning-tree vlan id detail (port roles and costs), and a monitored '
      'TC counter - a climb during a quiet period is a flapping port, not '
      'normal operation.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'stp-diameter');
  }

  // --- IPv6 address plan ---------------------------------------------------

  static ConsultantAnswer? _ipv6Plan(String t) {
    final prefixSignal = RegExp(r'/\s*(?:48|56|64)\b').hasMatch(t);
    if (!prefixSignal &&
        !_any(t, const ['ipv6', 'ip version 6', 'ipv6 plan'])) {
      return null;
    }
    final ask = _any(t, const [
      '/48',
      '/56',
      '/64',
      'plan',
      'address space',
      'how many',
      'sites',
      'site',
      'vlan',
    ]);
    if (!ask) return null;
    if (RegExp(
          r'\b(?:not working|no connectivity|stuck|neighbor|nd|ra)\b',
        ).hasMatch(t) &&
        !_any(t, const ['plan', 'subnet', '/48', '/56', '/64'])) {
      return null;
    }
    if (_any(t, const [
          'how many ips',
          'how many ip addresses',
          'how many addresses',
        ]) &&
        !_any(t, const ['/48', '/56', '/64', 'per site', 'plan'])) {
      return ConsultantAnswer(
        'IPv6 address count, in the units that matter:\n'
        '- The address space is 2^128, about 3.4 x 10^38 addresses. That is '
        'not a design number.\n'
        '- A /64 is 2^64, about 18.4 quintillion addresses, and is the unit '
        'for one LAN. SLAAC and Neighbor Discovery assume /64, so do not '
        'subnet it further to save space.\n'
        '- A /56 holds 256 /64s; a /48 holds 65,536 /64s. Those are the units '
        'you allocate.\n'
        '- Count prefixes, not addresses: a normal site needs one /48, a '
        'building one /56, and a VLAN one /64, regardless of how few hosts '
        'it has.\n'
        'Verify: show ipv6 interface, show ipv6 route, and the prefix '
        'delegation or RIR allocation record.',
        topic: 'ipv6-count',
      );
    }

    final sites = _firstInt(_sitesPattern, t);
    final vlans = _firstInt(
      RegExp(r'\b(\d{1,5})\s*(?:vlans?|subnets?|segments?)\b'),
      t,
    );
    final b = StringBuffer();
    b.writeln('IPv6 address plan.');
    b.writeln();
    b.writeln('The allocation units, and why they are these:');
    b.writeln(
      '- A /48 per site: 65,536 /64s. Enough for every building and VLAN a '
      'site will ever have, without a renumbering project.',
    );
    b.writeln(
      '- A /56 per building or floor: 256 /64s. The right unit when a large '
      'site has more than one distribution block.',
    );
    b.writeln(
      '- A /64 per VLAN: 18,446,744,073,709,551,616 addresses. This is not '
      'waste; SLAAC and Neighbor Discovery assume a /64, and a shorter '
      'prefix breaks them.',
    );
    b.writeln(
      '- /127 for router-to-router links (RFC 6164): two addresses, no '
      'subnet-router anycast surprise, no ping-pong. A /64 on a point-to-point '
      'link works but exposes the whole subnet to ND scanning.',
    );
    b.writeln(
      '- A /32 from the provider or RIR is the usual enterprise allocation: '
      '65,536 /48 sites.',
    );

    if (prefixSignal && RegExp(r'how many').hasMatch(t)) {
      b.writeln();
      b.writeln(
        'The counts: one /48 holds 65,536 /64s (2^16); one /56 holds 256 '
        '/64s (2^8); one /64 holds 2^64 host addresses. A /48 is the site '
        'unit, a /56 the building unit, a /64 the VLAN unit.',
      );
    }
    if (sites != null || vlans != null) {
      b.writeln();
      b.writeln('For the stated scale:');
      if (sites != null) {
        final smallest = 48 - (sites - 1).bitLength;
        var recommended = smallest - 2;
        recommended = (recommended ~/ 4) * 4;
        final blocks = 1 << (48 - recommended);
        if (sites > 65536) {
          b.writeln(
            '- $sites sites x /48 needs more than a /32 holds (65,536 /48s). '
            'You need a shorter allocation than /32, or several /32s from the '
            'RIR; do not renumber sites into a /32 that cannot hold them.',
          );
        } else {
          b.writeln(
            '- $sites sites x /48 needs at least a /$smallest '
            '(${1 << (48 - smallest)} /48s). Plan a /$recommended '
            '(${_thousands(blocks)} /48s) so growth does not force a '
            'renumbering; if you were given a /32, number sites inside it.',
          );
        }
      }
      if (vlans != null) {
        b.writeln(
          vlans <= 65536
              ? '- $vlans VLANs x /64 needs $vlans /64s, which fits one /48 '
                    '(65,536 /64s). Do not shrink the /64 to save space.'
              : '- $vlans VLANs x /64 needs $vlans /64s, which is more than one '
                    '/48. Allocate a building-level /48 per ${(vlans / 65536).ceil()} '
                    'blocks rather than shortening the /64.',
        );
      }
      b.writeln(
        '- Encode the site and VLAN in the prefix so the address itself says '
        'where it is: site:building:vlan::/64. Never encode the host role in '
        'the interface ID - privacy addresses and SLAAC will ignore it.',
      );
    }

    b.writeln();
    b.writeln('Design rules:');
    b.writeln(
      '- Dual stack first. An IPv6-only network needs NAT64/DNS64 or 464XLAT '
      'for the IPv4-only long tail, and that is a project, not a switchover.',
    );
    b.writeln(
      '- Router advertisements carry the default route and the prefix. Set '
      'the M and O flags deliberately: M for stateful DHCPv6, O for DNS only, '
      'and both clear for pure SLAAC.',
    );
    b.writeln(
      '- Filter ICMPv6 type 133-136 at the edge of a segment, never in the '
      'middle: ND is how IPv6 works, and a broad ICMPv6 block is the '
      'IPv6 equivalent of breaking ARP.',
    );
    b.writeln(
      '- Do not NAT66 as a habit. It hides the address plan and breaks the '
      'one thing IPv6 gives you: end-to-end reachability with a real '
      'security policy.',
    );
    b.writeln(
      '- Plan the DNS and DHCPv6 servers before the first prefix is '
      'announced. A network with addresses and no name service is not '
      'usable.',
    );
    b.writeln();
    b.writeln(
      'Verify: show ipv6 interface brief, show ipv6 route, show ipv6 '
      'neighbors, and a client test that proves SLAAC or DHCPv6 actually '
      'produced an address, a default route and a DNS server.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'ipv6-plan');
  }

  // --- IPv4 address planning ----------------------------------------------

  /// "How do I plan addresses for 40 branches" - the reserved block, the site
  /// formula and the summary, computed for the stated site count. The address
  /// plan is the one design decision that is expensive to change after the
  /// build, so it gets arithmetic instead of "use a /16".
  static ConsultantAnswer? _ipv4Plan(String t) {
    if (RegExp(
      r'\b(?:what\s+is|what\s+are|define|meaning\s+of)\b',
    ).hasMatch(t)) {
      return null;
    }
    final aboutAddresses = _any(t, const [
      'ip address',
      'ip addresses',
      'address',
      'addresses',
      'address plan',
      'addressing',
      'ip plan',
      'subnet plan',
      'subnetting',
      'ipv4',
      'address space',
    ]);
    final planning = _any(t, const [
      'plan',
      'planning',
      'scheme',
      'allocate',
      'allocation',
      'design',
      'lay out',
      'layout',
    ]);
    if (!aboutAddresses || !planning) return null;
    if (_has(t, 'ipv6')) return null;
    if (_has(t, 'mac address') ||
        _has(t, 'email') ||
        _has(t, 'e-mail') ||
        _has(t, 'physical address')) {
      return null;
    }
    final sites = _firstInt(_sitesPattern, t);
    if (sites == null) return null;
    if (sites < 2 || sites > 100000) return null;

    var blocks = 1;
    while (blocks < sites) {
      blocks <<= 1;
    }
    final banks = (sites / 256).ceil();
    final multiBank = banks > 1;
    final free = banks * 256 - sites;
    final p2pBlocks = (sites / 128).ceil();

    final b = StringBuffer();
    b.writeln('IPv4 address plan for $sites sites.');
    b.writeln();

    b.writeln('The site space:');
    if (!multiBank) {
      b.writeln(
        '- Reserve 10.20.0.0/16 for the site space: 256 /24 blocks, one per '
        'site. $free stay free, which is the point - the next hundred sites '
        'do not trigger a renumbering project.',
      );
    } else {
      b.writeln(
        '- $sites sites do not fit one /16 (256 /24s), so reserve a /12 for '
        'the site space and number the banks: 10.<20 + bank>.<index>.0/24 '
        'with bank = (site - 1) ~/ 256 and index = (site - 1) % 256. $banks '
        'banks are in use; $free blocks inside them are free.',
      );
    }
    if (multiBank) {
      b.writeln(
        '- Site formula: site k gets 10.<20 + (k - 1) ~/ 256>.<(k - 1) % '
        '256>.0/24 - site 1 is 10.20.0.0/24, site $sites is '
        '10.${20 + (sites - 1) ~/ 256}.${(sites - 1) % 256}.0/24. The address says '
        'where it is, so a route, an ACL or a syslog line is readable without '
        'a lookup.',
      );
    } else {
      b.writeln(
        '- Site formula: site k gets 10.20.<k-1>.0/24 - site 1 is '
        '10.20.0.0/24, site $sites is 10.20.${sites - 1}.0/24. The address '
        'says where it is, so a route, an ACL or a syslog line is readable '
        'without a lookup.',
      );
    }

    b.writeln();
    b.writeln('Inside each site /24:');
    b.writeln(
      '- Users /25 (126 addresses), voice /26 (62), guest/IoT /26 (62). That '
      'is the whole block with no overlap and no variable-length guesswork.',
    );
    b.writeln(
      '- A site above about 120 users gets a /23 instead - two consecutive '
      '/24s - rather than a squeezed /25. Size the site block to the user '
      'count, never to the current switch count.',
    );

    b.writeln();
    b.writeln('Keep this out of the site block:');
    b.writeln(
      '- Point-to-point links never come from a site /24. Reserve '
      '10.21.0.0/24 for $p2pBlocks x 128 /31s (RFC 3021), plus one more /24 '
      'per 128 links as the network grows.',
    );
    b.writeln(
      '- Loopbacks get their own block (10.21.1.0/24, one /32 per router) so '
      'a router ID or a BGP update-source never competes with a user VLAN.',
    );

    b.writeln();
    b.writeln('The summary is the product:');
    b.writeln(
      '- The WAN advertises 10.20.0.0/16, not $sites /24s. One route per '
      'region is what keeps the routing table small and the failure domain '
      'readable; a plan that cannot summarise is a plan that will be '
      'redesigned.',
    );
    b.writeln(
      '- Reserve a block per cloud VPC and per partner VPN now. Starting at '
      '10.0.0.0/16 guarantees an overlap with the default VPC, a merger or a '
      'vendor network later.',
    );
    b.writeln(
      '- IPv6 uses the same shape at a different scale: a /48 per site, a '
      '/64 per VLAN, /127 on point-to-point links.',
    );

    b.writeln();
    b.writeln(
      'Verify: an IPAM export diffed against the live ARP and route tables '
      '(no duplicate or overlapping block), show ip route summary before and '
      'after summarisation, and a DHCP scope per /25 sized to the block, not '
      'to today\'s headcount.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'ipv4-plan');
  }

  // --- WAN circuit sizing --------------------------------------------------

  /// "How do I size the WAN link for 200 users" - the circuit, from busy-hour
  /// arithmetic rather than a per-user rule of thumb. The number people quote
  /// ("100 kbps a user") is a starting point, not a design: the mix of voice,
  /// video and SaaS is what decides the circuit.
  static ConsultantAnswer? _wanSizing(String t) {
    if (_has(t, 'uplink') || _has(t, 'oversubscription')) return null;
    if (_has(t, 'ipv6')) return null;
    final wan = _any(t, const [
      'wan',
      'circuit',
      'internet link',
      'mpls',
      'sd-wan',
      'sdwan',
      'broadband',
      'leased line',
    ]);
    final sizing = _any(t, const [
      'size',
      'sizing',
      'bandwidth',
      'how much',
      'capacity',
      'how many mbps',
      'what speed',
    ]);
    if (!wan || !sizing) return null;
    final users = _firstInt(_usersPattern, t);
    final sites = _firstInt(_sitesPattern, t);
    if (users == null) return null;
    if (users < 2 || users > 1000000) return null;

    final perUser = _has(t, 'video')
        ? 1000.0
        : _any(t, const ['knowledge', 'saas', 'cloud', 'developer', 'design'])
        ? 400.0
        : 200.0;
    final busy = users * perUser / 1000;
    final withHeadroom = busy * 1.3;
    final calls = (users * 0.2).ceil();
    final voice = calls * 0.087;

    final circuit = withHeadroom <= 50
        ? 'a 50-100 Mbps circuit'
        : withHeadroom <= 100
        ? 'a 100 Mbps circuit, or 2 x 100 Mbps if the site is business critical'
        : withHeadroom <= 250
        ? '250 Mbps, or 2 x 100 Mbps in an active/active pair'
        : withHeadroom <= 500
        ? '500 Mbps, or 2 x 250 Mbps from different providers'
        : '1 Gbps or more, as a pair';

    final b = StringBuffer();
    b.writeln('WAN sizing for $users users.');
    b.writeln();
    b.writeln('The arithmetic:');
    b.writeln(
      '- Busy-hour rate: ${_num(perUser / 1000)} Mbps per user '
      '(${_num(busy)} Mbps for $users users). The busy hour is the design '
      'point; the daily average hides the ten minutes that matter.',
    );
    b.writeln(
      '- Add 30 percent for burst and growth: ${_num(withHeadroom)} Mbps, so '
      '$circuit. A circuit bought at exactly the busy hour is a circuit that '
      'is full on the first Monday of the next quarter.',
    );
    b.writeln(
      '- Voice is separate: about 20 percent of $users users on a call at '
      'once, at 87 kbps for G.711 (${_num(voice)} Mbps). It gets a strict '
      'priority queue sized to that plus 20 percent, and the circuit must '
      'have that much left after the data queue, not inside it.',
    );
    b.writeln();

    b.writeln('Rates that hold in practice:');
    b.writeln(
      '- 150-250 kbps per office user is the normal busy-hour figure; '
      '400-500 kbps if the site lives in SaaS; 1 Mbps if video is on all day '
      'and 2-4 Mbps per concurrent video stream on top.',
    );
    if (sites != null) {
      b.writeln(
        '- $sites sites sharing this figure is an aggregate, not a per-site '
        'number: size each site on its own busy hour and the WAN on the '
        'measured aggregate, because the busy hours do not line up.',
      );
    }

    b.writeln();
    b.writeln('Buy for failure, not for average:');
    b.writeln(
      '- Two circuits from two providers on two paths. Two circuits from the '
      'same ISP are one failure domain with a second invoice.',
    );
    b.writeln(
      '- Put the 95th percentile of the existing circuit next to the forecast '
      'before ordering: if the trend already crosses the new circuit inside '
      'the contract term, the size is wrong.',
    );

    b.writeln();
    b.writeln(
      'Verify: a busy-hour graph for 30 days, the top talkers, and a QoS '
      'policy that shows the voice class is actually getting its bandwidth '
      'when the link is at 100 percent.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'wan-sizing');
  }

  // --- firewall and inspection sizing -------------------------------------

  static ConsultantAnswer? _firewallScale(String t) {
    final firewall =
        _has(t, 'firewall') ||
        _has(t, 'ngfw') ||
        ((_has(t, 'ips') || _has(t, 'ids')) &&
            _any(t, const [
              'throughput',
              'inspection',
              'sessions',
              'tls',
              'ssl',
              'ngfw',
            ]));
    if (!firewall) return null;
    final ask = _any(t, const [
      'throughput',
      'sessions',
      'concurrent',
      'size',
      'how many',
      'ssl',
      'tls',
      'inspection',
      'active/active',
      'active/standby',
      'firewall failover',
      'capacity',
    ]);
    if (!ask) return null;
    if (RegExp(
      r'\b(?:not working|blocking|blocks|failover failed|stuck)\b',
    ).hasMatch(t)) {
      return null;
    }

    final wan = _rateMbps(t);
    final users = _firstInt(_usersPattern, t);
    final b = StringBuffer();
    b.writeln('Firewall and inspection sizing.');
    b.writeln();
    b.writeln(
      'Datasheet throughput is measured on large packets with no inspection. '
      'The number that matters is the one with the features you will actually '
      'turn on:',
    );
    b.writeln(
      '- Throughput with IPS and TLS inspection is typically one third to one '
      'fifth of the raw number. Size to that, not to the headline.',
    );
    b.writeln(
      '- IMIX (a realistic mix of packet sizes) is roughly half of the '
      'large-packet rate. Ask for IMIX with the feature set enabled.',
    );
    b.writeln(
      '- Concurrent sessions: about 50 to 200 per user depending on '
      'application mix, plus a growth factor. A browser tab is several '
      'sessions, and TLS 1.3 resumption does not remove them.',
    );
    b.writeln(
      '- New sessions per second: about 5 to 10 per user at the busy hour. '
      'This limit is hit before throughput in a web-heavy office.',
    );
    if (wan != null) {
      b.writeln();
      b.writeln(
        'For a ${_rateLabel(wan)} WAN the link itself is '
        '${_rateLabel(wan * 2)} aggregate across both directions; with 50% '
        'growth, size inspected throughput for about '
        '${_rateLabel(wan * 3)}. With IPS and TLS inspection enabled that '
        'usually means a box whose raw rating is three to five times higher.',
      );
    }
    if (users != null) {
      b.writeln(
        'For $users users, budget ${_thousands(users * 50)} to '
        '${_thousands(users * 200)} concurrent sessions and '
        '${_thousands(users * 5)} to ${_thousands(users * 10)} new '
        'sessions per second.',
      );
    }
    b.writeln();
    b.writeln('High availability:');
    b.writeln(
      '- Active/standby is simpler and is the right default: one box carries '
      'the traffic, the other holds the same state. Failover is a session '
      'table sync plus a gratuitous ARP, usually a few seconds.',
    );
    b.writeln(
      '- Active/active is not twice the throughput for a single flow. It '
      'balances flows across boxes, and asymmetric routing becomes the '
      'failure mode to design out.',
    );
    b.writeln(
      '- The HA sync link must be dedicated and on its own segment. A sync '
      'link that shares the data path is how a failover becomes an outage.',
    );
    b.writeln(
      '- Test failover in a window with real traffic. A pair that has never '
      'failed over is an assumption, not redundancy.',
    );
    b.writeln();
    b.writeln(
      'Verify: show failover (state and last transition), session counts '
      'and CPS during the busy hour, and a forced failover with a long-lived '
      'flow open to prove state sync.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'firewall-sizing');
  }

  // --- broadcast domain sizing --------------------------------------------

  static ConsultantAnswer? _broadcastDomain(String t) {
    final ask =
        _any(t, const [
          'broadcast domain size',
          'how big is a broadcast domain',
          'how many hosts per vlan',
          'how many hosts in a vlan',
          'vlan size',
          'subnet size',
          'how big should a vlan',
          'how big should the subnet',
        ]) ||
        (_has(t, 'vlan') &&
            _any(t, const ['how many hosts', 'how big', 'size', 'subnet']));
    if (!ask) return null;

    final hosts = _firstInt(
      RegExp(r'\b(\d{1,5})\s*(?:hosts?|devices?|users?|pcs?)\b'),
      t,
    );
    final b = StringBuffer();
    b.writeln('Broadcast-domain and VLAN sizing.');
    b.writeln();
    b.writeln(
      'The limit is not a protocol constant. It is the sum of broadcast, '
      'unknown unicast, ARP/ND and spanning-tree cost:',
    );
    b.writeln(
      '- A /24 (254 usable) is the default unit. It is small enough that a '
      'broadcast storm is survivable and large enough for a normal office '
      'floor.',
    );
    b.writeln(
      '- Above about 250 devices, move to a /23 rather than stretching a /24 '
      'with reservations and a second scope.',
    );
    b.writeln(
      '- Keep any one VLAN under about 500 hosts. Past that, broadcast and '
      'ARP noise, not address exhaustion, is the reason to split.',
    );
    b.writeln(
      '- One VLAN per function, not per department: staff, voice, guest, IoT, '
      'cameras, servers and management. A department VLAN grows by '
      'acquisition; a function VLAN does not.',
    );
    b.writeln(
      '- Never stretch one VLAN across sites. A layer-2 domain that spans a '
      'WAN turns a local loop into a network-wide outage and makes every '
      'broadcast pay for the link.',
    );
    if (hosts != null) {
      b.writeln();
      final planned = (hosts * 1.25).ceil();
      if (planned <= 510) {
        final size = planned <= 254 ? '/24' : '/23';
        b.writeln(
          'For $hosts hosts, plan $planned with 25% growth: a $size '
          '(${size == '/24' ? 254 : 510} usable) is the smallest block that '
          'holds it. Reserve the low addresses for gateways, switches and '
          'printers.',
        );
      } else {
        final count = (hosts / 400).ceil();
        final per = (hosts / count).ceil();
        final perPlanned = (per * 1.25).ceil();
        final size = perPlanned <= 254
            ? '/24'
            : perPlanned <= 510
            ? '/23'
            : '/22';
        b.writeln(
          'For $hosts hosts, do not put them in one /22. Split into $count '
          'VLANs of about $per hosts; each needs a $size after 25% growth. One '
          'flat VLAN would work at layer 3 but puts $hosts hosts in one '
          'broadcast domain, which is exactly what the 500-host rule avoids.',
        );
      }
    }
    b.writeln();
    b.writeln(
      'Verify: broadcast-rate counters on the VLAN SVI and show mac '
      'address-table count per VLAN. A broadcast rate above a few hundred per '
      'second on a quiet segment is a loop or a misbehaving device, not '
      'normal traffic.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'vlan-sizing');
  }

  // --- wireless design -----------------------------------------------------

  static ConsultantAnswer? _wirelessDesign(String t) {
    final wireless = _any(t, const [
      'wifi',
      'wi-fi',
      'wireless',
      'access point',
      'access points',
      'ap',
      'aps',
      'wlan',
      'ssid',
      'channel width',
    ]);
    if (!wireless) return null;
    // PoE budgeting belongs to the advisor's power topic.
    if (_any(t, const ['poe', 'power budget', 'power over ethernet'])) {
      return null;
    }
    if (_any(t, const ['not working', 'dropping', 'slow', 'interference'])) {
      return null;
    }
    // Clients per AP is a capacity fact, not an AP-count design question.
    if (_any(t, const [
      'clients per',
      'users per',
      'devices per',
      'per access point',
    ])) {
      return null;
    }

    if (_any(t, const [
      'channel width',
      'channel size',
      '20 mhz',
      '40 mhz',
      '80 mhz',
      '160 mhz',
    ])) {
      final b = StringBuffer();
      b.writeln(
        '5 GHz channel width is a reuse decision, not a peak-rate one.',
      );
      b.writeln();
      b.writeln(
        '- 20 MHz in a dense office, school or venue: it yields the most '
        'non-overlapping channels, so adjacent APs can coexist. 2.4 GHz is '
        'always 20 MHz.',
      );
      b.writeln(
        '- 40 MHz only where the AP count is low and a survey shows clean '
        'spectrum; it halves the number of reusable channels.',
      );
      b.writeln(
        '- 80 MHz is for a few APs or a dedicated high-throughput SSID. 160 '
        'MHz consumes eight 20 MHz channels and is rarely an enterprise '
        'default; one 160 MHz AP can starve its neighbours.',
      );
      b.writeln(
        '- DFS channels add spectrum, but a radar false alarm vacates the '
        'channel and can drop calls. Do not make voice depend on DFS alone.',
      );
      b.writeln();
      b.writeln(
        'Rule: start at 20 MHz, widen only when the channel plan and a site '
        'survey prove the reuse still works. A wider channel raises one '
        'client\'s peak rate and lowers every neighbour\'s airtime.',
      );
      b.writeln(
        'Verify: the AP channel plan, a spectrum analyser at the busiest '
        'spot, and a survey showing -67 dBm or better and 25 dB SNR at the '
        'cell edge.',
      );
      return ConsultantAnswer(b.toString().trim(), topic: 'wifi-channel-width');
    }

    final area = _firstInt(
      RegExp(
        r'\b(\d{1,6})\s*(?:sq\s*m|sqm|m2|square\s*met(?:er|re)s?|sq\s*ft|'
        r'square\s*feet|ft2)\b',
      ),
      t,
    );
    final users = _firstInt(_devicePattern, t) ?? _firstInt(_usersPattern, t);

    if (_has(t, 'ssid') &&
        _any(t, const ['how many', 'how much', 'count', 'design', 'best'])) {
      final b = StringBuffer();
      b.writeln('SSID count: two to four, not one per department.');
      b.writeln();
      b.writeln(
        '- Minimum: corporate (802.1X or WPA3-Enterprise) and guest '
        '(isolated, rate-limited, separate VLAN). Add IoT as a third when '
        'those devices cannot do 802.1X.',
      );
      b.writeln(
        '- Every SSID adds beacons and probe overhead. At a 100 ms beacon '
        'interval each SSID is about 10 beacons per second per AP; eight '
        'SSIDs is real airtime before a single client speaks.',
      );
      b.writeln(
        '- Split by policy, not by department or VLAN count. If two groups '
        'need the same policy, one SSID with dynamic VLAN or role assignment '
        'is cheaper than two SSIDs.',
      );
      b.writeln(
        '- Guest: client isolation, rate limit, captive portal and no route '
        'to internal subnets. IoT: separate VLAN, no east-west access, and a '
        'PSK that is rotated when a device leaves.',
      );
      b.writeln(
        '- Hiding the SSID is not security. Disable legacy rates, prefer WPA3 '
        'or WPA2-Enterprise, and disable WPS.',
      );
      b.writeln();
      b.writeln(
        'Rule: if you cannot state the policy difference in one sentence, it '
        'does not deserve its own SSID. Two is normal, three is common, four '
        'needs a reason.',
      );
      return ConsultantAnswer(b.toString().trim(), topic: 'ssid-design');
    }

    // A stated area or client count is wireless sizing, and the advisor owns
    // it: it returns the count as structured advice with options. The
    // consultant only covers the floor-plan rule when neither number is given.
    if (area != null || users != null) return null;
    if (!_any(t, const ['per floor', 'per room', 'coverage', 'capacity'])) {
      return null;
    }

    final b = StringBuffer();
    b.writeln('Wireless access-point count.');
    b.writeln();
    b.writeln(
      'Two limits decide the count, and you size to the larger: coverage '
      '(area per cell) and capacity (active clients per radio).',
    );
    b.writeln(
      '- Without an area or client count, use the rules: one AP per 100-150 '
      'm2 of office, or per 30-40 active clients. A 1,000 m2 floor is '
      'therefore 7-10 APs before any capacity check.',
    );
    b.writeln(
      '- PoE: at 30 W per Wi-Fi 6 AP (802.3at), budget 30 W per AP and add '
      '20-30% headroom. A Wi-Fi 6E/7 AP with 6 GHz radios may need 60 W '
      '(802.3bt).',
    );
    b.writeln(
      '- Uplink: one 1 Gbps port per AP is the floor; 2.5 Gbps where the AP '
      'and switch support it, especially for 6E/7.',
    );
    b.writeln();
    b.writeln(
      'Placement and validation: ceiling-mounted, clear of metal and concrete '
      'columns, on a 5 GHz channel plan with 20 MHz channels in dense areas. '
      'Design to -67 dBm and 25 dB SNR at the cell edge; voice needs about '
      '-65 dBm and 30 ms jitter or better.',
    );
    b.writeln(
      'Verify: a predictive survey, then a real site survey with the APs at '
      'production power. The floor plan is not evidence; the survey is.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'wifi-ap-count');
  }

  // --- core and distribution switch count ---------------------------------

  static ConsultantAnswer? _switchTiers(String t) {
    final tiers = _any(t, const [
      'core switch',
      'core switches',
      'distribution switch',
      'distribution switches',
      'collapsed core',
      'three-tier',
      'two-tier',
      'campus design',
    ]);
    if (!tiers) return null;
    if (!_any(t, const [
      'how many',
      'need',
      'design',
      'redundan',
      'redundancy',
      'redundant',
      'should i',
    ])) {
      return null;
    }

    final buildings = _firstInt(
      RegExp(r'\b(\d{1,4})\s*(?:buildings?|blocks?|floors?)\b'),
      t,
    );
    final b = StringBuffer();
    b.writeln('Core and distribution switch count.');
    b.writeln();
    b.writeln(
      '- Core: two switches, always a pair, in a single building or campus. '
      'One core is a planned outage; a pair with HSRP/VRRP, redundant links '
      'and separate power feeds is the minimum for a business network.',
    );
    b.writeln(
      '- Distribution: a pair per building or per distribution block, not '
      'one global pair. Each access switch dual-homes to both distribution '
      'switches, and the pair is the boundary for STP, gateways and policy.',
    );
    b.writeln(
      '- Collapsed core (core and distribution in one pair) is correct for a '
      'single building or a small campus, roughly under 200 users. Above '
      'that, separate the tiers so a distribution failure does not take the '
      'whole site.',
    );
    b.writeln(
      '- Access: 48-port switches per closet, planning 40-44 ports used so '
      'there is room for uplinks and growth. Count ports, not users: a user '
      'with a phone and a laptop is two ports.',
    );
    if (buildings != null) {
      b.writeln();
      b.writeln(
        'For $buildings buildings: two core switches, plus a distribution '
        'pair per building (${buildings * 2} distribution switches) if each '
        'building has its own access closets. That is not two distribution '
        'switches for the whole campus; it is a pair where the access layer '
        'concentrates.',
      );
    }
    b.writeln();
    b.writeln(
      'Rule: redundancy lives in pairs and in diverse paths, not in a '
      'larger chassis. Two fixed switches with dual links beat one modular '
      'chassis with a single supervisor.',
    );
    b.writeln(
      'Verify: STP root and secondary root are where you think, HSRP/VRRP is '
      'active/standby (not both active), every access switch has two uplinks '
      'to different distribution members, and a forced core failure keeps '
      'the site reachable.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'switch-tiers');
  }

  // --- DNS resolver redundancy --------------------------------------------

  static ConsultantAnswer? _dnsServers(String t) {
    if (!_has(t, 'dns')) return null;
    if (!_any(t, const ['server', 'servers', 'resolver', 'resolvers'])) {
      return null;
    }
    if (!_any(t, const [
      'how many',
      'need',
      'design',
      'redundan',
      'redundancy',
      'redundant',
      'should i',
    ])) {
      return null;
    }

    final sites = _firstInt(_sitesPattern, t);
    final b = StringBuffer();
    b.writeln('DNS resolver redundancy.');
    b.writeln();
    b.writeln(
      '- Two resolvers minimum, on separate hosts and diverse network paths, '
      'with every client and DHCP scope configured for both. One resolver is '
      'a single point of failure that looks like "the internet is down".',
    );
    b.writeln(
      '- Three or more for a large estate or a public-facing service, spread '
      'across sites or anycast. The count is for failure and locality, not '
      'for query throughput: a single modern resolver handles tens of '
      'thousands of queries per second.',
    );
    b.writeln(
      '- Multi-site: a local resolver or cache at each large site keeps DNS '
      'working through a WAN outage. Small sites can use the central pair, '
      'but document that a WAN failure takes DNS with it.',
    );
    b.writeln(
      '- Split horizon: internal zones authoritative on your resolvers, '
      'external recursion forwarded to public resolvers. Do not expose an '
      'open recursive resolver to the internet.',
    );
    b.writeln(
      '- Active Directory DNS: keep DNS on at least two domain controllers, '
      'with AD-integrated replication, and monitor replication. A single DC '
      'holding DNS is the same single point of failure with a different name.',
    );
    b.writeln(
      '- Clocks and monitoring: NTP on every resolver, query-rate and latency '
      'alerts, and a synthetic query that proves both servers answer.',
    );
    if (sites != null && sites > 1) {
      b.writeln();
      b.writeln(
        'For $sites sites, use the central pair plus a local resolver at '
        'each site that must resolve during a WAN outage. A central pair that '
        'depends on the WAN is redundant only while the WAN is up.',
      );
    }
    b.writeln();
    b.writeln(
      'Verify: query each resolver directly, confirm the client has both in '
      'its resolver list, and shut one down. A DNS plan that has never been '
      'failed over is a hope, not a design.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'dns-redundancy');
  }

  // --- multi-site WAN architecture ----------------------------------------

  static ConsultantAnswer? _wanArchitecture(String t) {
    final sites = _firstInt(_sitesPattern, t);
    if (sites == null || sites < 2) return null;
    if (_any(t, const [
      'concurrent calls',
      'calls fit',
      'codec',
      'erlang',
      'bandwidth per call',
    ])) {
      return null;
    }
    final wanAsk = _any(t, const [
      'wan',
      'connect',
      'network',
      'design',
      'link',
      'links',
      'redundan',
      'failover',
      'mpls',
      'sd-wan',
      'sdwan',
      'vpn',
      'internet',
      'cloud',
      'latency',
      'voice',
      'site-to-site',
    ]);
    if (!wanAsk) return null;
    // Buildings on one campus are a LAN design, not a WAN design.
    if (_has(t, 'building') &&
        !_any(t, const [
          'wan',
          'mpls',
          'sd-wan',
          'sdwan',
          'vpn',
          'internet',
          'provider',
          'branch',
          'remote site',
          'latency',
          'voice',
          'cloud',
        ])) {
      return null;
    }
    // "Build a 3-site network" is a planning brief, not a design question.
    // Only an explicit WAN requirement earns the architecture answer.
    if (RegExp(r'\b(?:build|create|make\s+me)\b').hasMatch(t) &&
        !_any(t, const [
          'wan',
          'mpls',
          'sd-wan',
          'sdwan',
          'vpn',
          'redundan',
          'failover',
          'latency',
          'cloud',
          'voice',
        ])) {
      return null;
    }
    // A pure device count is a build brief.
    if (RegExp(
          r'\b(?:routers?|switches|pcs?|servers?|firewalls?|access points?)\b',
        ).hasMatch(t) &&
        !_any(t, const ['wan', 'sites', 'branches', 'mpls', 'sd-wan', 'vpn'])) {
      return null;
    }

    final perSite = _rateMbps(t);
    final users = _firstInt(_usersPattern, t);
    final realtime = _any(t, const [
      'voice',
      'voip',
      'real-time',
      'real time',
      'latency',
      'jitter',
      'sla',
      'guaranteed',
      'critical',
      'erp',
    ]);
    final redundancy = _any(t, const [
      'redundan',
      'failover',
      'fail over',
      'dual',
      'backup',
      'high availability',
      'ha',
      'resilien',
      'diverse',
    ]);
    final cloud = _any(t, const [
      'cloud',
      'aws',
      'azure',
      'gcp',
      'saas',
      'o365',
      'm365',
    ]);
    final budget = _any(t, const [
      'cheap',
      'budget',
      'tight',
      'low cost',
      'cost effective',
    ]);
    final managed = _any(t, const [
      'managed',
      'carrier',
      'provider sla',
      'outsource',
    ]);
    final growing = _any(t, const [
      'grow',
      'growth',
      'future',
      'expand',
      'new sites',
    ]);

    final score = <String, int>{
      'sdwan': 0,
      'mpls': 0,
      'vpn': 0,
      'dedicated': 0,
    };
    if (sites >= 8) {
      score['sdwan'] = score['sdwan']! + 2;
      score['mpls'] = score['mpls']! + 1;
      score['vpn'] = score['vpn']! + 1;
    } else if (sites <= 4) {
      score['vpn'] = score['vpn']! + 2;
      score['sdwan'] = score['sdwan']! + 1;
      score['mpls'] = score['mpls']! + 1;
    } else {
      score['sdwan'] = score['sdwan']! + 2;
      score['mpls'] = score['mpls']! + 1;
    }
    if (realtime) {
      score['mpls'] = score['mpls']! + 3;
      score['sdwan'] = score['sdwan']! + 2;
      score['vpn'] = score['vpn']! - 1;
    }
    if (redundancy) {
      score['sdwan'] = score['sdwan']! + 2;
      score['mpls'] = score['mpls']! + 1;
      score['vpn'] = score['vpn']! + 1;
    }
    if (cloud) {
      score['sdwan'] = score['sdwan']! + 2;
      score['mpls'] = score['mpls']! + 1;
    }
    if (budget) {
      score['vpn'] = score['vpn']! + 2;
      score['sdwan'] = score['sdwan']! + 1;
      score['mpls'] = score['mpls']! - 2;
    }
    if (managed) {
      score['mpls'] = score['mpls']! + 1;
    }
    if (growing) {
      score['sdwan'] = score['sdwan']! + 2;
      score['mpls'] = score['mpls']! - 1;
    }
    if (perSite != null && perSite >= 500) {
      score['sdwan'] = score['sdwan']! + 2;
      score['dedicated'] = score['dedicated']! + 1;
      score['vpn'] = score['vpn']! - 1;
    }
    if (perSite != null && perSite <= 100) {
      score['vpn'] = score['vpn']! + 1;
      score['sdwan'] = score['sdwan']! + 1;
    }
    // For a handful of sites without real-time or cloud requirements, the
    // simpler hub-and-spoke VPN is the better engineering choice: one overlay,
    // one place to troubleshoot, no extra orchestration layer.
    if (sites <= 4 && !realtime && !cloud) {
      score['vpn'] = score['vpn']! + 1;
    }
    final ranked = score.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final winner = ranked.first.key;
    final runnerUp = ranked[1].key;

    String label(String key) => switch (key) {
      'sdwan' => 'SD-WAN over dual internet links',
      'mpls' => 'MPLS L3VPN from a provider',
      'vpn' => 'internet VPN, hub and spoke',
      'dedicated' => 'dedicated point-to-point or wavelength',
      _ => key,
    };

    final b = StringBuffer();
    b.writeln(
      'WAN architecture for $sites sites'
      '${perSite != null ? ' at ${_rateLabel(perSite)} each' : ''}'
      '${users != null ? ', $users users per site' : ''}.',
    );
    b.writeln();
    b.writeln('Verdict: ${label(winner)}.');
    b.writeln();
    b.writeln('Why this one, on the facts given:');
    b.writeln(
      '- Site count: $sites. A handful of sites fits a hub-and-spoke '
      'overlay; a growing estate wants a policy-driven overlay rather than '
      'a bigger hub.',
    );
    if (perSite != null) {
      final rate = _rateLabel(perSite);
      final transport = switch (winner) {
        'mpls' =>
          'a private circuit at this rate is bought per Mbps, so contract '
              'the rate, the latency and the per-class QoS together',
        'vpn' =>
          'broadband is cheap at this rate, but the hub must aggregate every '
              'branch, so size the hub for the sum and not the average',
        'dedicated' =>
          'at this rate a protected wavelength or point-to-point circuit is '
              'the transport; a broadband overlay cannot carry it predictably',
        _ =>
          'broadband plus an overlay is usually the only way to buy this '
              'capacity without per-Mbps private-circuit pricing',
      };
      b.writeln('- Per-site bandwidth: $rate - $transport.');
    }
    if (realtime) {
      b.writeln(
        '- Real-time traffic: stated. The transport must carry a latency and '
        'jitter budget end to end, and the design needs a priority queue plus '
        'admission control - an internet-only path without an SLA cannot '
        'promise it.',
      );
    }
    if (redundancy) {
      b.writeln(
        '- Redundancy: stated. Two independent paths at the hub and at every '
        'critical branch, with BFD or IP SLA driving the decision.',
      );
    }
    if (cloud) {
      b.writeln(
        '- Cloud: stated. Direct cloud on-ramps or local internet breakout '
        'belong in the design; backhauling SaaS traffic through a hub adds '
        'latency and hub bandwidth for no security gain.',
      );
    }
    if (budget) {
      b.writeln(
        '- Budget: tight. Per-Mbps private circuits are the first thing to '
        'go; the overlay must then carry the reliability burden.',
      );
    }

    b.writeln();
    b.writeln('Design that makes it work:');
    if (winner == 'sdwan') {
      b.writeln(
        '- Transport: two internet providers on separate physical paths at '
        'the hub and at every site that matters, with BGP or the overlay '
        'controller choosing the active path.',
      );
      b.writeln(
        '- Branches: two links where the business case allows, or one link '
        'plus cellular/5G. Two links from the same provider are one failure '
        'domain, not two.',
      );
      b.writeln(
        '- Overlay: IPsec with a dynamic routing protocol or an SD-WAN '
        'controller, per-tunnel BFD/IP SLA, and local internet breakout for '
        'SaaS so the hub is not a detour.',
      );
    } else if (winner == 'mpls') {
      b.writeln(
        '- Transport: MPLS L3VPN with dual PE attachment at the hub and '
        'dual-homed CE at every critical site. The contract must name '
        'latency, jitter, loss and per-class QoS, not only bandwidth.',
      );
      b.writeln(
        '- CE-PE: BGP with provider-assigned private AS or static routes with '
        'BFD. Summarize each site; never let the provider carry your VLANs.',
      );
      b.writeln(
        '- Backup: an internet IPsec tunnel for non-real-time traffic is '
        'cheaper than a second MPLS port. Do not put voice on it unless the '
        'SLA is measured, not assumed.',
      );
    } else if (winner == 'vpn') {
      b.writeln(
        '- Hub: a router pair with HSRP/VRRP and two internet links. Every '
        'branch tunnel terminates on both, so one hub failure is not the '
        'whole WAN.',
      );
      b.writeln(
        '- Branches: one link is a single point of failure; add LTE/5G only '
        'if the outage cost justifies it, and state the risk if it does not.',
      );
      b.writeln(
        '- Overlay: IPsec with BGP or OSPF across the tunnels, a probe through '
        'the tunnel rather than a ping to the endpoint, and a documented '
        'hub-and-spoke path for branch-to-branch traffic.',
      );
    } else {
      b.writeln(
        '- Transport: a protected point-to-point circuit or wavelength between '
        'the high-rate sites, on diverse fiber where the service allows it.',
      );
      b.writeln(
        '- Routing: BGP across the circuit for fast failover and a summary per '
        'site; do not stretch layer 2 across it.',
      );
    }
    b.writeln(
      '- QoS: trust and remark at the branch edge, then a priority queue for '
      'voice, a bandwidth queue for video, and a scavenger class. The '
      'transport must preserve DSCP or the whole policy dies at the first '
      'encapsulation.',
    );
    b.writeln(
      '- Segmentation: one VRF or one overlay per security zone. A flat '
      'overlay that connects guest, staff and OT is a flat network with '
      'extra steps.',
    );
    b.writeln(
      '- Address plan: one summary per site, so the WAN table is sites, not '
      'VLANs, and a new VLAN never changes the core.',
    );
    b.writeln();
    b.writeln('Failure behaviour to design and test:');
    b.writeln(
      '- Link down: BFD or IP SLA detects it in under a second; BGP withdraws '
      'the route and the tunnel rebuilds. Test with the primary physically '
      'down, not administratively shut.',
    );
    b.writeln(
      '- Provider down: the second path must carry voice too, or the design '
      'has redundancy only for data.',
    );
    b.writeln(
      '- Hub down: a branch-to-branch path or a second hub is the only thing '
      'that keeps sites talking. If the budget does not allow it, state that '
      'as a known single point of failure.',
    );
    b.writeln(
      '- Tunnel up but broken: a probe through the tunnel, not a ping to the '
      'tunnel endpoint, is what proves the overlay is usable.',
    );
    b.writeln();
    final runnerWhy = switch (runnerUp) {
      'mpls' =>
        'the SLA is contractual, the traffic is regulated, or a provider is '
            'already on site',
      'sdwan' =>
        'the estate is growing, cloud on-ramps matter, or per-Mbps private '
            'circuits stop making economic sense',
      'vpn' =>
        'there are only a handful of sites, the link is modest, and there is '
            'no real-time SLA',
      'dedicated' =>
        'one or two very high-rate sites justify a private wavelength',
      _ => 'the facts change',
    };
    b.writeln('Runner-up: ${label(runnerUp)}. Choose it if $runnerWhy.');
    b.writeln();
    b.writeln(
      'What I would not do: run one provider, one link and one tunnel for '
      'every site and call it a WAN. That is a single failure domain with a '
      'routing protocol on top.',
    );
    b.writeln();
    b.writeln(
      'Verify before cutover: per-tunnel IP SLA, BGP summary per peer, a '
      'forced failover with a voice call up, and a throughput test through '
      'the tunnel at the contracted rate.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'wan-architecture');
  }

  // --- multi-building campus LAN -------------------------------------------

  static ConsultantAnswer? _campusDesign(String t) {
    final buildings = _firstInt(
      RegExp(r'\b(\d{1,3})\s*(?:buildings?|blocks?)\b'),
      t,
    );
    if (buildings == null || buildings < 2) return null;
    if (!_any(t, const [
      'design',
      'campus',
      'network',
      'connect',
      'lan',
      'infrastructure',
      'plan',
    ])) {
      return null;
    }
    // A WAN or provider question is not a campus LAN question.
    if (_any(t, const [
      'wan',
      'mpls',
      'sd-wan',
      'sdwan',
      'vpn',
      'internet',
      'provider',
      'branch',
      'remote',
      'latency',
      'voice',
      'cloud',
      'lease',
      'dedicated',
    ])) {
      return null;
    }

    final b = StringBuffer();
    b.writeln('Campus LAN for $buildings buildings.');
    b.writeln();
    b.writeln(
      '- Topology: a core pair in the main building (MDF), and a '
      'distribution pair in every other building (IDF). That is two core '
      'switches plus ${buildings * 2} distribution switches. Access switches '
      'dual-home to both distribution members; no access switch chains to '
      'another access switch.',
    );
    b.writeln(
      '- Inter-building links: single-mode fiber for runs beyond about 500 m '
      'or between buildings on different electrical grounds; OM4 multimode '
      'for shorter runs inside a building. Copper between buildings is a '
      'lightning and ground-potential mistake, not a cost saving.',
    );
    b.writeln(
      '- Diversity: two fiber paths on different routes into each building, '
      'each on its own conduit. If only one path exists, say so as a single '
      'point of failure rather than calling the design redundant.',
    );
    b.writeln(
      '- Capacity: 10 Gbps per building uplink is the floor and 40/100 Gbps '
      'where the core and fiber support it. Bundle two links with LACP for '
      'bandwidth and one-link failure, or route with OSPF/IS-IS if you want '
      'fast reconvergence and no spanning tree between buildings.',
    );
    b.writeln(
      '- Addressing: one summarizable block per building, with VLANs inside '
      'it, so the core carries a route per building, not a route per VLAN. '
      'Keep the building summary stable when a new VLAN appears.',
    );
    b.writeln(
      '- Layer 2: STP root primary on core A and secondary on core B, per '
      'VLAN or per MST instance. Enable BPDU Guard and Root Guard on access '
      'ports so a rogue switch cannot become root.',
    );
    b.writeln(
      '- Power and environment: a UPS in every IDF sized for the switches and '
      'PoE load, plus cooling and a lock. A distribution closet without '
      'power protection is where the outage starts.',
    );
    b.writeln(
      '- Physical: lightning protection and grounding at each building '
      'entrance, labeled fiber and copper, conduit spare capacity, and an '
      'OTDR/loss test per strand before acceptance.',
    );
    b.writeln();
    b.writeln(
      'What I need to size it: users and access closets per building, the '
      'longest fiber run, and whether the buildings already have conduit. '
      'Those three numbers decide the uplink rate and the fiber type.',
    );
    b.writeln(
      'Verify: pull one core uplink and one building fiber, confirm every '
      'VLAN still reaches its gateway, STP root stays where you put it, and '
      'a voice call survives the failover.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'campus-design');
  }

  // --- DMZ architecture ----------------------------------------------------

  static ConsultantAnswer? _dmzDesign(String t) {
    if (!_has(t, 'dmz')) return null;
    if (!_any(t, const [
      'design',
      'architect',
      'build',
      'set up',
      'setup',
      'how do i',
      'segmentation',
      'public',
      'expose',
    ])) {
      return null;
    }
    if (_any(t, const ['not working', 'down', 'troubleshoot', 'slow'])) {
      return null;
    }

    final b = StringBuffer();
    b.writeln('DMZ design.');
    b.writeln();
    b.writeln(
      '- Shape: a DMZ is a policy zone between the untrusted side and the '
      'internal network, not a second LAN. One firewall with three interfaces '
      '(outside, DMZ, inside) is workable for a small site; two firewalls from '
      'different vendors or an HA pair is the design for a regulated or '
      'high-value service.',
    );
    b.writeln(
      '- Placement: only the public-facing service lives there - web, mail '
      'relay, reverse proxy, VPN concentrator. No domain controller, no file '
      'server, no management server, and never a server dual-homed to both '
      'the DMZ and the inside.',
    );
    b.writeln(
      '- Rules: default deny. Outside to DMZ opens only the published ports '
      '(443, 80, 25 as needed). DMZ to inside is denied, not inspected and '
      'allowed. DMZ to internet is limited to updates and the service\'s '
      'own dependencies, not arbitrary browsing.',
    );
    b.writeln(
      '- NAT: publish a VIP/static NAT to the DMZ address, never to an '
      'internal address. Put HTTP behind a reverse proxy or WAF so the '
      'backend is not directly reachable and TLS terminates where you can '
      'inspect it.',
    );
    b.writeln(
      '- Layer 2: its own VLAN or VRF, with no stretched VLAN into the '
      'inside and no route leaking. If the firewall routes between zones, '
      'the DMZ switch is a stub, not a transit path.',
    );
    b.writeln(
      '- Host hardening: patch the service, remove unused daemons, run a '
      'host firewall, disable SMB/RDP from the internet, and keep logs '
      'shipped to a collector the DMZ cannot modify.',
    );
    b.writeln(
      '- Addressing: a dedicated /24, default route to the firewall, and no '
      'internal routes on the DMZ hosts. The less the host knows about the '
      'inside, the less a compromise can discover.',
    );
    b.writeln();
    b.writeln(
      'Verify: an external scan sees only the published ports, a DMZ host '
      'cannot reach an internal address or the firewall management plane, '
      'the failover pair keeps the VIP, and the logs show the denied '
      'attempts. A DMZ that has never been tested from the outside is a '
      'diagram, not a control.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'dmz-design');
  }

  // --- migration and cutover ----------------------------------------------

  static ConsultantAnswer? _migration(String t) {
    final ask = _any(t, const [
      'migrate',
      'migration',
      'cutover',
      'cut over',
      'without downtime',
      'zero downtime',
      'rollback plan',
      'transition plan',
      'replace the core',
      'replace the firewall',
    ]);
    if (!ask) return null;
    final network = _any(t, const [
      'network',
      'router',
      'routing',
      'ospf',
      'eigrp',
      'bgp',
      'isis',
      'switch',
      'firewall',
      'wan',
      'isp',
      'vlan',
      'ipv6',
      'mpls',
      'sd-wan',
      'sdwan',
      'core',
      'access',
    ]);
    if (!network) return null;
    // A migration briefing is not a build request; the planner keeps counts.
    if (RegExp(r'\b(?:build|create|make me)\b').hasMatch(t) &&
        !_any(t, const ['migrate', 'cutover', 'cut over', 'replace'])) {
      return null;
    }

    final routingMigration =
        _any(t, const ['ospf', 'eigrp', 'isis', 'rip', 'bgp']) &&
        _any(t, const ['migrate', 'migration', 'cutover', 'replace']);
    final firewallMigration =
        _has(t, 'firewall') &&
        _any(t, const ['migrate', 'migration', 'cutover', 'replace']);
    final ispMigration =
        _any(t, const ['isp', 'provider', 'wan']) &&
        _any(t, const ['migrate', 'migration', 'cutover', 'replace']);
    final ipv6Migration =
        _has(t, 'ipv6') &&
        _any(t, const [
          'migrate',
          'migration',
          'cutover',
          'transition',
          'dual stack',
        ]);
    final sdwanMigration =
        _any(t, const ['sd-wan', 'sdwan']) &&
        _any(t, const [
          'migrate',
          'migration',
          'cutover',
          'replace',
          'transition',
        ]);
    final coreMigration =
        !routingMigration &&
        !firewallMigration &&
        !ispMigration &&
        _any(t, const [
          'core switch',
          'core',
          'switch',
          'switching',
          'distribution',
        ]) &&
        _any(t, const [
          'replace',
          'migrate',
          'migration',
          'cutover',
          'refresh',
          'upgrade',
        ]);

    final b = StringBuffer();
    b.writeln('Migration plan.');
    b.writeln();
    b.writeln(
      'A cutover is a sequence of reversible steps with a proof after each '
      'one. The plan below is the shape I would insist on; the specifics come '
      'from the running config, not from this answer.',
    );

    if (ipv6Migration) {
      b.writeln();
      b.writeln('IPv6 migration - dual stack, not a switchover:');
      b.writeln(
        '1. Inventory every dependency first: applications, firewalls, load '
        'balancers, DNS, DHCP, monitoring and any device that accepts only an '
        'IPv4 literal. A dual stack fails on the one component nobody listed.',
      );
      b.writeln(
        '2. Turn up IPv6 in the core and transit first, then a pilot VLAN. '
        'Leave IPv4 exactly as it is; the two run side by side.',
      );
      b.writeln(
        '3. Decide RA and DHCPv6 deliberately: M and O flags, DNS via RDNSS or '
        'DHCPv6, and a /64 per VLAN. Publish AAAA for the pilot services and '
        'measure, rather than announcing the whole estate at once.',
      );
      b.writeln(
        '4. Write the IPv6 firewall policy with the same default-deny as IPv4. '
        'Do not rely on NAT for security, and permit ICMPv6 133-137 or Neighbor '
        'Discovery breaks.',
      );
      b.writeln(
        '5. Move one service or site at a time. Retire IPv4 only when every '
        'consumer has AAAA, monitoring covers both families, and a rollback '
        'still has an IPv4 path.',
      );
      b.writeln();
      b.writeln(
        'Rollback: dual stack means each step is reversible on its own. '
        'Withdraw the pilot prefix or disable RA/DHCPv6 on that VLAN and IPv4 '
        'still carries the traffic. An IPv6-only pilot has no rollback.',
      );
    } else if (sdwanMigration) {
      b.writeln();
      b.writeln('SD-WAN migration:');
      b.writeln(
        '1. Fix the underlay before the overlay: each ISP, public addressing, '
        'NAT behaviour, MTU (1500 minimum, 1600 preferred for the tunnel) and '
        'the real busy-hour rate. An overlay cannot repair a bad circuit.',
      );
      b.writeln(
        '2. Bring up the controller first: certificates, organization, clock '
        'and the control ports. Enroll one device and prove a template before '
        'touching production policy.',
      );
      b.writeln(
        '3. Pilot one branch with the old path still available. Tune BFD and '
        'application-aware routing against measured loss and latency, not '
        'against defaults copied from a lab.',
      );
      b.writeln(
        '4. Migrate in waves by template and site class. Keep the old DMVPN, '
        'static or MPLS path until the new overlay has carried a real busy '
        'hour and the failover has been tested with a voice call up.',
      );
      b.writeln(
        '5. Move routing and DNS last, then decommission the old tunnels only '
        'after a full change cycle.',
      );
      b.writeln();
      b.writeln(
        'Rollback: the old path is still configured, so re-point the default '
        'route or re-apply the previous template. Test that direction in the '
        'window; a rollback nobody has executed is a hope.',
      );
    } else if (routingMigration) {
      b.writeln();
      b.writeln('Routing-protocol migration:');
      b.writeln(
        '1. Establish a baseline: show ip route summary, neighbor counts, '
        'and a route-by-route export. Without it, nobody can prove the new '
        'protocol carried everything.',
      );
      b.writeln(
        '2. Run both protocols in parallel on the edge pair. Advertise the '
        'same prefixes into both and keep the new one less preferred with a '
        'distance or a route-map, so it is present but not installed.',
      );
      b.writeln(
        '3. Lower the preference on one non-critical segment and verify the '
        'exact prefix set, next hops and metrics. A missing summary or a '
        'passive interface is what shows up here.',
      );
      b.writeln(
        '4. Move one area or one site at a time. Keep a per-step gate: the '
        'prefix count matches the baseline, no route loops, and a known '
        'destination still reaches its far end.',
      );
      b.writeln(
        '5. Remove the old protocol only after a full business cycle, not '
        'after one quiet hour.',
      );
      b.writeln();
      b.writeln(
        'Rollback: the old protocol is still configured and one distance or '
        'route-map change restores it. Never remove it before the new path '
        'has survived a real busy hour.',
      );
    } else if (firewallMigration) {
      b.writeln();
      b.writeln('Firewall replacement:');
      b.writeln(
        '1. Export the rule base, NAT, VPN and routing table, then convert '
        'and diff rule-by-rule. A rule that cannot be explained is a rule to '
        'challenge, not to copy.',
      );
      b.writeln(
        '2. Put the new pair in parallel on a test segment and replay real '
        'traffic profiles: web, voice, VPN, inbound publish. Measure what it '
        'drops, not only what it passes.',
      );
      b.writeln(
        '3. Pre-stage the HA pair, sync it, and prove failover before it '
        'carries production.',
      );
      b.writeln(
        '4. Cut with a routing or ARP change, not by editing both boxes at '
        'once. The old pair stays powered and configured for the rollback '
        'window.',
      );
      b.writeln(
        '5. Keep the old rule base for one change cycle, then decommission '
        'deliberately.',
      );
      b.writeln();
      b.writeln(
        'Rollback: restore the old path by moving the route or the virtual '
        'address back. Session state on the old pair is stale, so a rollback '
        'is a short outage for long-lived flows even when it is fast.',
      );
    } else if (ispMigration) {
      b.writeln();
      b.writeln('Provider or WAN migration:');
      b.writeln(
        '1. Bring the new circuit up beside the old one and prove it with '
        'BGP or a static route, not with a ping to the provider edge.',
      );
      b.writeln(
        '2. Announce a small test prefix outbound and verify it from an '
        'external looking glass before touching production prefixes.',
      );
      b.writeln(
        '3. Prefer the new path with a local preference, move inbound with a '
        'more specific prefix or an AS-path prepend on the old one, and '
        'watch the traffic shift.',
      );
      b.writeln(
        '4. Keep the old circuit for at least one billing cycle. The failure '
        'you did not predict happens in week two.',
      );
      b.writeln();
      b.writeln(
        'Rollback: the old session is still up, so a local-preference or '
        'prepend change puts traffic back in seconds. Test that direction '
        'before the window, not during it.',
      );
    } else if (coreMigration) {
      b.writeln();
      b.writeln('Core or distribution switch refresh:');
      b.writeln(
        '1. Baseline the old core: topology, STP root and priorities, '
        'HSRP/VRRP state, LACP bundles, routes, ACLs, QoS and NetFlow. The '
        'baseline is the acceptance test for the new pair.',
      );
      b.writeln(
        '2. Build the new pair beside the old one with the same VLANs, VRFs '
        'and gateways. Prove routing and spanning tree with the old core '
        'isolated, not with both live and hoping.',
      );
      b.writeln(
        '3. Pre-stage out-of-band management, console access and power. A core '
        'refresh that depends on the network being refreshed for access can '
        'strand the engineer mid-cutover.',
      );
      b.writeln(
        '4. Move one distribution block at a time: links, LACP, STP role, '
        'HSRP/VRRP and routes - then verify a known flow through that block '
        'before the next one.',
      );
      b.writeln(
        '5. Keep the old core powered and configured for the rollback window; '
        'wipe it only after a full business cycle.',
      );
      b.writeln();
      b.writeln(
        'Rollback: the old core is still cabled and configured, so moving the '
        'links back is minutes, not a rebuild. Do not wipe or repurpose it '
        'until the new pair has survived a busy hour.',
      );
    } else {
      b.writeln();
      b.writeln('The general sequence:');
      b.writeln(
        '1. Discover and document: topology, addresses, routing, policy and '
        'the business flows that must not break.',
      );
      b.writeln(
        '2. Build the target beside the source and prove it with tests, not '
        'with a successful config load.',
      );
      b.writeln(
        '3. Pilot on the least critical segment. A pilot that is not allowed '
        'to fail is not a pilot.',
      );
      b.writeln(
        '4. Cut over in a window with a named rollback trigger and the '
        'person who can call it.',
      );
      b.writeln(
        '5. Verify business flows, not just link state, and keep the old '
        'path until the next business day.',
      );
    }

    b.writeln();
    b.writeln('Every step needs three things:');
    b.writeln(
      '- a pre-check that proves the starting state; - the change itself, '
      'applied from a reviewed script or template; - a post-check that proves '
      'the intended result and nothing else moved.',
    );
    b.writeln(
      'If a post-check fails, stop and roll back. Continuing past a failed '
      'gate is how one fault becomes an outage with no known-good state.',
    );
    b.writeln();
    b.writeln(
      'Out-of-band access is not optional. A migration that depends on the '
      'path being migrated for management access can strand the engineer '
      'mid-cutover.',
    );
    b.writeln();
    b.writeln(
      'Verify end to end: a ping and a traceroute from both directions, a '
      'real application transaction, and the monitoring alert that would '
      'have caught the failure if the change had gone wrong.',
    );
    return ConsultantAnswer(b.toString().trim(), topic: 'migration-plan');
  }
}
