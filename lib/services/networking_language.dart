/// How English questions are read before the networking corpus matches them.
///
/// The corpora in [NetworkingCatalog], [NetworkingFacts] and
/// [DiagnosticPlaybooks] are indexed by the words an experienced engineer uses
/// in a ticket title: "bgp session flapping", "ospf adjacency not forming",
/// "trunk not passing vlan". People do not write that. They write "our bgp
/// keeps bouncing", "the ospf neighbours never form", "vlan 20 is not getting
/// through the trunk", and a command that matches the ticket title but not the
/// sentence is a command that misses the question it was built for.
///
/// This layer closes that gap deterministically, so the depth of the corpus is
/// reachable from ordinary English with no model:
///
/// * **Symptom phrasing is expanded, never replaced.** "keeps bouncing" keeps
///   its words and gains the canonical "flapping", because the user's own
///   wording is evidence (it is what a ticket title would quote back) and the
///   canonical token is what the matcher indexes.
/// * **Vocabulary is normalised.** British spellings, split compounds
///   ("keep alive" -> "keepalive"), spelled-out numbers before a countable
///   noun ("five hundred hosts" -> "500 hosts") and long technology names
///   ("software defined wide area network") fold onto the short token the
///   corpus uses.
/// * **Frames are stripped.** "can you tell me", "quick question", "for my
///   ccna", "in simple terms" carry tone, not topic; leaving them in makes
///   the sentence longer without making it more specific, which is exactly
///   what a phrase-length scorer punishes.
///
/// It is pure, deterministic and idempotent, and it never rewrites a literal
/// value: every rule is a plain-English phrase made of letters and spaces, and
/// matching is whole-word, so an address, a CIDR or a command passes through
/// byte for byte.
class NetworkingLanguage {
  const NetworkingLanguage._();

  /// Longer text is a pasted configuration or a design brief, not a question,
  /// and it is read by dedicated readers. Jumping out keeps the hot path fast.
  static const int _maxLength = 2000;

  /// The understood form of [text]. Callers pass already-lowercased text; the
  /// result is lowercase too, and [understand] is idempotent.
  static String understand(String text) {
    var t = text.trim();
    if (t.isEmpty || t.length > _maxLength) return t;
    t = _collapse(t);
    t = _spokenPrefix(t);
    t = _numberWords(t);
    for (final (pattern, canonical, expand) in _rules) {
      if (!pattern.hasMatch(t)) continue;
      if (!expand) {
        t = t.replaceAll(pattern, canonical);
        continue;
      }
      // An expansion appends the canonical phrase once. If it is already
      // there - because the user wrote it, or because an earlier pass added
      // it - the match is left alone, which keeps the layer idempotent.
      final subject = t;
      t = subject.replaceAllMapped(pattern, (m) {
        // The canonical phrase may already be present anywhere later in the
        // sentence, not only immediately after the match: a shorter overlapping
        // rule can insert its own canonical between the two ("calls keep
        // dropping flapping drops calls"). Checking the whole remainder keeps
        // the layer idempotent without suppressing a phrase that is genuinely
        // absent.
        final after = subject.substring(m.end);
        if (after.contains(canonical)) return m.group(0)!;
        // "are not forming" already ends with "not forming": appending it
        // again would double the phrase and lengthen the sentence for the
        // phrase-length scorer, which is the opposite of the point.
        if (m.group(0)!.endsWith(canonical)) return m.group(0)!;
        return '${m.group(0)} $canonical';
      });
    }
    t = _stripFrames(t);
    // A stripped frame can leave its punctuation behind ("for my ccna: bgp").
    t = t.replaceFirst(RegExp(r'^[:;,\-\s]+'), '');
    return _collapse(t);
  }

  /// "slash 29" and "slash twenty nine" are how people say /29 out loud. The
  /// prefix is the question, so it has to become a real prefix before any
  /// matcher sees it.
  static String _spokenPrefix(String t) {
    if (!t.contains('slash')) return t;
    return t.replaceAllMapped(
      RegExp(
        '\\bslash\\s+(\\d{1,2}|${_ones.keys.join('|')}'
        '(?:[\\s-]+${_ones.keys.join('|')})?)\\b',
      ),
      (m) {
        final raw = m.group(1)!;
        final digits = int.tryParse(raw);
        if (digits != null) return '/$digits';
        var total = 0;
        for (final word in raw.split(RegExp(r'[\s-]+'))) {
          final value = _ones[word];
          if (value == null) return m.group(0)!;
          total += value;
        }
        return total > 0 ? '/$total' : m.group(0)!;
      },
    );
  }

  static String _collapse(String t) => t.replaceAll(RegExp(r'\s+'), ' ').trim();

  // --- symptom phrasing ----------------------------------------------------

  /// Phrasings people use, mapped to the canonical phrase the corpus indexes.
  /// The rewrite *keeps the original words* and appends the canonical ones, so
  /// the answer still sees the sentence the user actually wrote.
  static const Map<String, String> _symptoms = {
    // A session or link that comes back: the single most common English
    // description of a flap, and it never appears in a ticket title.
    'keeps bouncing': 'flapping',
    'keeps flapping': 'flapping',
    'is bouncing': 'flapping',
    'keeps coming and going': 'flapping',
    'comes and goes': 'flapping',
    'goes up and down': 'flapping',
    'keeps dropping': 'flapping',
    'keeps disconnecting': 'flapping',
    'keeps resetting': 'flapping',
    'keeps reconnecting': 'flapping',
    'drops repeatedly': 'flapping',
    'drops randomly': 'flapping',
    'keeps falling over': 'flapping',
    'randomly disconnects': 'flapping',
    // A session that never exists at all.
    'never comes up': 'not coming up',
    'never came up': 'not coming up',
    'will not come up': 'not coming up',
    'does not come up': 'not coming up',
    'cannot come up': 'not coming up',
    'never establishes': 'not coming up',
    'never forms': 'not forming',
    'never form': 'not forming',
    'do not form': 'not forming',
    'will not form': 'not forming',
    'does not form': 'not forming',
    'are not forming': 'not forming',
    'is not forming': 'not forming',
    'not establishing': 'not coming up',
    'fails to establish': 'not coming up',
    'cannot establish': 'not coming up',
    'will not establish': 'not coming up',
    // Reachability, in the words people use before they know which layer.
    'cannot reach': 'no connectivity',
    'cannot connect': 'no connectivity',
    'cannot get to': 'no connectivity',
    'cannot get through': 'no connectivity',
    'unable to reach': 'no connectivity',
    'unable to connect': 'no connectivity',
    'nothing gets through': 'no connectivity',
    'traffic dies': 'traffic not passing',
    'traffic stops': 'traffic not passing',
    'traffic does not pass': 'traffic not passing',
    'not passing traffic': 'traffic not passing',
    'traffic is not passing': 'traffic not passing',
    'not carrying': 'not passing',
    'is not carrying': 'not passing',
    'one way traffic': 'one way',
    'only works one way': 'one way',
    'works in one direction': 'one way',
    'goes out but does not come back': 'one way',
    // Address assignment.
    'get an ip address': 'no ip',
    'gets an ip address': 'no ip',
    'getting an ip address': 'no ip',
    'no ip address assigned': 'no ip',
    'without an ip': 'no ip',
    'no address assigned': 'no ip',
    'address assignment fails': 'no ip',
    'dhcp is down': 'dhcp not working',
    'dhcp stopped': 'dhcp not working',
    // Name resolution.
    'name resolution is broken': 'not resolving',
    'name resolution broken': 'not resolving',
    'names do not resolve': 'not resolving',
    'cannot look up': 'not resolving',
    'cannot resolve names': 'not resolving',
    'lookups fail': 'not resolving',
    'lookups are failing': 'not resolving',
    // Wireless.
    'cannot join': 'can not connect',
    'will not join': 'can not connect',
    'cannot associate': 'can not connect',
    'will not associate': 'can not connect',
    'do not associate': 'can not connect',
    'drop randomly': 'flapping',
    'keep dropping': 'flapping',
    'signal is weak': 'poor signal',
    'weak signal': 'poor signal',
    'low signal': 'poor signal',
    'keeps asking for the password': 'authentication failed',
    'password is rejected': 'authentication failed',
    // Voice.
    'no dial tone': 'calls failing',
    'calls will not connect': 'calls failing',
    'calls fail': 'calls failing',
    'calls are failing': 'calls failing',
    'cannot make calls': 'calls failing',
    'sound robotic': 'robotic',
    'sounds robotic': 'robotic',
    'sounds choppy': 'choppy',
    'is choppy': 'choppy',
    'cutting out': 'choppy',
    'breaking up': 'choppy',
    'audio breaks up': 'choppy',
    'one-way audio': 'one way audio',
    // Link and port state.
    'amber light': 'amber link',
    'orange light': 'amber link',
    'light is amber': 'amber link',
    'light is orange': 'amber link',
    'link light is off': 'no link',
    'no light on the port': 'no link',
    'went into lockdown': 'err-disabled',
    'into lockdown': 'err-disabled',
    'shut the port down': 'err-disabled',
    'port shut itself down': 'err-disabled',
    'port disabled itself': 'err-disabled',
    'port went down and stayed down': 'err-disabled',
    'blocking the wrong link': 'blocking the wrong port',
    'blocking wrong link': 'blocking the wrong port',
    // Security policy.
    'firewall is blocking': 'blocking',
    'acl is blocking': 'blocking',
    'security group is blocking': 'blocking',
    'policy is blocking': 'blocking',
    'traffic is being denied': 'denied',
    // Performance.
    'very slow': 'slow',
    'takes forever': 'slow',
    'is sluggish': 'slow',
    'lagging': 'laggy',
    'losing packets': 'packet loss',
    'drops packets': 'packet loss',
    'dropping packets': 'packet loss',
    'packets are being lost': 'packet loss',
    'cpu is maxed': 'high cpu',
    'cpu maxed out': 'high cpu',
    'interface is erroring': 'interface errors',
    'errors are climbing': 'interface errors',
    'counters are climbing': 'interface errors',
    'traceroute stops': 'stars in traceroute',
    // Tunnel and overlay.
    'tunnel is down': 'tunnel down',
    'vpn is down': 'tunnel down',
    'tunnel keeps dropping': 'flapping',
    'no vxlan routes': 'vxlan not passing traffic',
    'vxlan routes are missing': 'vxlan not passing traffic',
    'overlay is broken': 'vxlan not passing traffic',
    // Time.
    'clock is wrong': 'wrong time',
    'time is wrong': 'wrong time',
    'time drifted': 'wrong time',
    'not syncing time': 'not syncing',
    'calendar is off': 'wrong time',
    // Large-frame symptoms.
    'large pings fail': 'large pings fail',
    'big pings fail': 'large pings fail',
    'small pings work but large do not':
        'large pings fail but small pings work',
    'pings with df fail': 'large pings fail',
    'pages half load': 'pages half load',
    // Pace and trend, in the words a user brings.
    'slows down': 'slow',
    'has slowed down': 'slow',
    'crawling': 'slow',
    'keeps growing': 'is growing',
    'keeps increasing': 'is growing',
    'certs were rotated': 'certificate rotation',
    'certificates were rotated': 'certificate rotation',
    'cert was rotated': 'certificate rotation',
    'certificate was rotated': 'certificate rotation',
    'after the cert change': 'certificate rotation',
    'after a cert change': 'certificate rotation',
    'single attached server': 'orphan port',
    'single-attached server': 'orphan port',
    'single homed server': 'orphan port',
    'single-homed server': 'orphan port',
    // The way a helpdesk ticket actually says "no internet": the link is up,
    // the Wi-Fi says connected, and nothing loads. The canonical phrase is
    // what the connectivity playbooks index, and the original words stay in
    // the sentence as evidence.
    'no internet connection': 'no connectivity',
    'connected but no internet': 'no connectivity',
    'connected with no internet': 'no connectivity',
    'connected to wifi but no internet': 'no connectivity',
    'connected to the wifi but no internet': 'no connectivity',
    'says no internet': 'no connectivity',
    'cannot open websites': 'no connectivity',
    'cannot load websites': 'no connectivity',
    'web pages do not load': 'no connectivity',
    // Duplicate addressing, in the words a user brings rather than the words
    // a ticket title uses.
    'ip conflict': 'duplicate ip',
    'ip address conflict': 'duplicate ip',
    'duplicate addresses': 'duplicate ip',
    'same ip on two devices': 'duplicate ip',
    // The number fold runs first, so "two devices" is already "2 devices" by
    // the time these phrases are matched; both spellings therefore key on the
    // digit form that reaches this table.
    '2 devices have the same ip': 'duplicate ip',
    '2 devices with the same ip': 'duplicate ip',
    // Voice symptoms people describe instead of naming.
    'calls keep dropping': 'drops calls',
    'call keeps dropping': 'drops calls',
    'will not register': 'not registering',
    'phones will not register': 'not registering',
    'cannot hear them': 'one way audio',
    'they cannot hear me': 'one way audio',
    'audio only goes one way': 'one way audio',
    // Performance, in the words a user brings.
    'ping is high': 'high ping',
    'takes ages': 'slow',
    'website is slow': 'slow',
    'web is slow': 'slow',
    'very laggy': 'laggy',
    // Time and certificate symptoms, which are expiry questions before they
    // are routing questions.
    'certificate has expired': 'certificate expired',
    'cert expired': 'certificate expired',
    'certificate is expired': 'certificate expired',
    'clock is off': 'wrong time',
    'time is off': 'wrong time',
    'date is wrong': 'wrong time',
    // A link or session that keeps dropping, phrased as the object rather
    // than the protocol. The canonical word is what the flap playbooks index.
    'link keeps dropping': 'flapping',
    'port keeps dropping': 'flapping',
    'connection keeps dropping': 'flapping',
    'keeps losing connection': 'flapping',
    // Printing, access points and the verbs a helpdesk ticket uses. The
    // target is already a signal in the playbook corpus; the original words
    // stay in the sentence as evidence.
    'nobody can print': 'cannot print',
    'no one can print': 'cannot print',
    'nothing prints': 'cannot print',
    'printing is down': 'cannot print',
    'access point keeps rebooting': 'ap keeps rebooting',
    'access points keeps rebooting': 'ap keeps rebooting',
    'access points keep rebooting': 'ap keeps rebooting',
    // DNS and BGP, where the user describes the symptom instead of naming it.
    'dns server is not answering': 'dns not working',
    'dns is not answering': 'dns not working',
    'dns server is down': 'dns not working',
    'dns server is unresponsive': 'dns not working',
    'get no routes': 'no prefixes',
    'up but no routes': 'no prefixes',
    'no routes are arriving': 'no prefixes',
    // Voice, service state and the link LED.
    'sound like robots': 'robotic',
    'sounds like a robot': 'robotic',
    'sound like a robot': 'robotic',
    'says no service': 'not registering',
    'phone says no service': 'not registering',
    'shows amber': 'amber link',
    'shows an amber light': 'amber link',
    // Address assignment and VLAN forwarding, in the words on the ticket.
    '169 address': '169.254',
    '169 ip': '169.254',
    'gets a 169': '169.254',
    'not forwarding': 'not passing',
    // ACL and reachability verbs that the corpus indexes in another form.
    'acl blocks': 'acl blocking',
    'nobody can reach': 'unreachable',
    'no one can reach': 'unreachable',
    'cannot be reached': 'unreachable',
    'can no longer reach': 'unreachable',
    'lost network': 'no connectivity',
    'lost connectivity': 'no connectivity',
    'lost connection': 'no connectivity',
    'wifi is bad': 'poor signal',
    'wifi is terrible': 'poor signal',
    // A client that cannot see the SSID has a join problem, and the join
    // playbook's first cause is exactly discovery (broadcast, band, radio).
    'cannot see the wifi': 'cannot join the wifi',
    'cannot see the corporate wifi': 'cannot join the wifi',
    'cannot see the ssid': 'cannot join the wifi',
    'cannot see any wifi': 'cannot join the wifi',
    'cannot find the wifi': 'cannot join the wifi',
    'does not see the wifi': 'cannot join the wifi',
    'cannot join the guest network': 'cannot join the wifi',
    'cannot join the guest wifi': 'cannot join the wifi',
  };

  // --- vocabulary ----------------------------------------------------------

  /// Spelling, compound and long-name folding. The short token is what the
  /// corpus indexes; the long form is kept beside it because some entries are
  /// alias-ed by the long form ("route target") rather than the short one.
  static const Map<String, String> _vocab = {
    // Split compounds people type with a space.
    'keep alive': 'keepalive',
    'keep-alive': 'keepalive',
    'hold time': 'holdtime',
    'hold-time': 'holdtime',
    'dead time': 'deadtime',
    'peer link': 'peer-link',
    'port channel': 'port-channel',
    'next hop': 'next-hop',
    'max age': 'max-age',
    'time to live': 'ttl',
    'denial of service': 'denial-of-service',
    'split horizon': 'split-horizon',
    'route target': 'route-target',
    'route distinguisher': 'route-distinguisher',
    // British spellings, which this corpus otherwise misses entirely.
    'neighbour': 'neighbor',
    'neighbours': 'neighbors',
    'neighbouring': 'neighboring',
    'synchronise': 'synchronize',
    'synchronised': 'synchronized',
    'synchronisation': 'synchronization',
    'behaviour': 'behavior',
    'organised': 'organized',
    'analyse': 'analyze',
    'analysed': 'analyzed',
    'optimise': 'optimize',
    'optimised': 'optimized',
    'prioritise': 'prioritize',
    'authorise': 'authorize',
    'authorised': 'authorized',
    'utilise': 'utilize',
    'licence': 'license',
    'fibre': 'fiber',
    'centre': 'center',
    'catalogue': 'catalog',
    'defence': 'defense',
    // Long technology names -> the token the corpus triggers on. CasualEnglish
    // folds the classics; these are the modern names it predates.
    'software defined wide area network': 'sd-wan',
    'software-defined wide area network': 'sd-wan',
    'software defined wan': 'sd-wan',
    'software defined access': 'sd-access',
    'software defined networking': 'sdn',
    'virtual extensible local area network': 'vxlan',
    'virtual extensible lan': 'vxlan',
    'ethernet virtual private network': 'evpn',
    'ethernet vpn': 'evpn',
    'control plane policing': 'copp',
    'unicast reverse path forwarding': 'urpf',
    'reverse path forwarding check': 'rpf check',
    'resource public key infrastructure': 'rpki',
    'dynamic multipoint virtual private network': 'dmvpn',
    'dynamic multipoint vpn': 'dmvpn',
    'zero trust network access': 'ztna',
    'secure access service edge': 'sase',
    'web application firewall': 'waf',
    'distributed denial of service': 'ddos',
    'network access control': 'nac',
    'identity services engine': 'ise',
    'network policy server': 'nps',
    'virtual private cloud': 'vpc',
    'express route': 'expressroute',
    'express-route': 'expressroute',
    'container network interface': 'cni',
    'network functions virtualization': 'nfv',
    'precision time protocol': 'ptp',
    'segment routing over ipv6': 'srv6',
    'remote triggered black hole': 'rtbh',
    'carrier grade nat': 'cgnat',
    'carrier-grade nat': 'cgnat',
    'multi factor authentication': 'mfa',
    'public key infrastructure': 'pki',
    'certificate authority': 'ca',
    'wireless lan controller': 'wlc',
    'power over ethernet': 'poe',
    'link layer discovery protocol': 'lldp',
    'cisco discovery protocol': 'cdp',
    'internet group management protocol': 'igmp',
    'protocol independent multicast': 'pim',
    'bridge protocol data unit': 'bpdu',
    'first hop redundancy protocol': 'fhrp',
    'virtual routing and forwarding': 'vrf',
    'virtual routing forwarding': 'vrf',
    'access control entry': 'ace',
    'intrusion prevention system': 'ips',
    'intrusion detection system': 'ids',
  };

  /// Phrases that frame a question instead of describing it. Each carries what
  /// survives the strip: a polite request becomes "explain X", because the
  /// teaching shape is the meaning; "the point of X" becomes "when should I use
  /// X", because that is what was asked. Deleting the frame outright would
  /// leave a bare noun and the shuffler would lose the shape of the question.
  static final List<(RegExp, String)> _leadingFrames = [
    (RegExp(r'^(?:so|ok|okay|hi|hello|hey|dear|well)[, ]+'), ''),
    (
      RegExp(
        r'^(?:(?:can|could|would|will|may)\s+(?:you|u)\s+(?:please\s+)?'
        r'(?:tell|show|explain|help|teach)\s+(?:me|us)\s+(?:about|with|how)?'
        r'\s*)',
      ),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:please\s+)?(?:tell|show|explain|teach|walk)\s+(?:me|us)\s+'
        r'(?:about|through|how)\s*',
      ),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:i|we)\s+(?:would like|want|need)\s+to\s+'
        r'(?:know|understand|learn)\s+(?:about|how)?\s*',
      ),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:i am|im)\s+(?:just\s+)?(?:wondering|curious)\s+(?:about\s+)?',
      ),
      'explain ',
    ),
    (RegExp(r'^(?:just\s+)?wondering\s+(?:about\s+)?'), 'explain '),
    (
      RegExp(r'^(?:do|does)\s+(?:you|anyone)\s+know\s+(?:about\s+)?'),
      'explain ',
    ),
    (RegExp(r'^(?:any\s+idea|any\s+thoughts?)\s+(?:why|about|on|how)\s*'), ''),
    (RegExp(r'^(?:quick|simple|dumb|stupid|basic)\s+question[:\s]+'), ''),
    (RegExp(r'^(?:question|q)\s*[:\-]\s*'), ''),
    (
      RegExp(r'^(?:help|help me)\s+(?:to\s+)?(?:understand|with)\s*'),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:give|gimme)\s+(?:me\s+)?(?:a\s+)?(?:summary|rundown|overview)'
        r'\s+(?:of|on|about)\s*',
      ),
      'explain ',
    ),
    (
      RegExp(r'^what\s+(?:is\s+)?the\s+(?:point|purpose)\s+(?:with|of)\s*'),
      'when should i use ',
    ),
    (
      RegExp(r'^what\s+(?:is\s+)?the\s+(?:deal|story)\s+(?:with|of)\s*'),
      'what is ',
    ),
    (
      RegExp(
        r'^(?:is|are)\s+(.+?)\s+(?:still\s+)?(?:needed|relevant|obsolete|'
        r'dead|used\s+any\s*more)\s*[?]*$',
      ),
      'when should i use \$1',
    ),
    (
      RegExp(
        r'^(?:tell me|explain)\s+(?:everything|all|more)\s+(?:about|on)\s*',
      ),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:i|we)\s+(?:need|want)\s+(?:a\s+)?(?:refresher|reminder)\s+'
        r'(?:on|about)\s*',
      ),
      'explain ',
    ),
    (
      RegExp(
        r'^(?:for|in)\s+(?:a|my|the)\s+(?:ccna|ccnp|lab|exam|test|class|'
        r'course|homework)\s*,?\s*',
      ),
      '',
    ),
    (
      RegExp(r'^(?:in|for)\s+(?:packet\s+tracer|gns3|eve-ng|a\s*lab)\s*,?\s*'),
      '',
    ),
    (
      RegExp(
        r'^(?:at|in)\s+(?:work|production|the\s+office|our\s+company)\s*,?\s*',
      ),
      '',
    ),
  ];

  static final List<RegExp> _trailingFrames = [
    RegExp(r'[, ]+(?:please|thanks|thank you|thx|cheers|ta)\s*$'),
    RegExp(r'[, ]+(?:in\s+)?(?:simple|plain)\s+(?:terms|english)\s*$'),
    RegExp(r'[, ]+like\s+(?:i\s+am|im)\s+(?:five|5)\s*$'),
    RegExp(r'[, ]+for\s+(?:a\s+)?(?:dummies|beginners?|newbies?)\s*$'),
    RegExp(r'[, ]+eli5\s*$'),
    RegExp(r'[, ]+if\s+(?:that|this)\s+(?:makes\s+sense|is\s+possible)\s*$'),
    RegExp(r'[, ]+(?:for|in)\s+(?:a|my)\s+(?:lab|homework|exam)\s*$'),
  ];

  static String _stripFrames(String text) {
    var t = text;
    for (var pass = 0; pass < 3; pass++) {
      final before = t;
      for (final (pattern, replacement) in _leadingFrames) {
        t = t.replaceFirstMapped(pattern, (m) {
          if (!replacement.contains(r'$1') || m.groupCount < 1) {
            return replacement;
          }
          return replacement.replaceAll(r'$1', m.group(1) ?? '');
        });
      }
      for (final pattern in _trailingFrames) {
        t = t.replaceFirst(pattern, '');
      }
      t = t.trim();
      if (t == before) break;
    }
    return t;
  }

  // --- spelled-out numbers -------------------------------------------------

  static const Map<String, int> _ones = {
    'zero': 0,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'sixteen': 16,
    'seventeen': 17,
    'eighteen': 18,
    'nineteen': 19,
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
    'sixty': 60,
    'seventy': 70,
    'eighty': 80,
    'ninety': 90,
  };

  static const Map<String, int> _scales = {
    'hundred': 100,
    'thousand': 1000,
    'million': 1000000,
  };

  /// Countable design units. Only these nouns take a converted number: "one
  /// way audio" is a phrase, not the number 1, and rewriting it to "1 way
  /// audio" would break the symptom it describes.
  static const String _units =
      r'(?:hosts?|users?|devices?|sites?|branches?|buildings?|floors?|'
      r'ports?|vlans?|switches|routers?|pcs?|servers?|phones?|cameras?|'
      r'aps?|access-points?|seats?|calls?|employees|staff|endpoints?|'
      r'clients?|subnets?|addresses|racks?|offices?|classrooms?|'
      r'printers?|laptops?|tablets?|workstations?)';

  static final RegExp _numberUnit = RegExp(
    r'\b((?:' +
        _ones.keys.join('|') +
        r')(?:[\s-]+(?:' +
        '${_ones.keys.join('|')}|${_scales.keys.join('|')}' +
        r'))*(?:[\s-]+and[\s-]+(?:' +
        _ones.keys.join('|') +
        r'))?)\s+(' +
        _units +
        r')\b',
  );

  static String _numberWords(String t) {
    if (!_ones.keys.any(t.contains)) return t;
    return t.replaceAllMapped(_numberUnit, (m) {
      final words = m.group(1)!.toLowerCase().split(RegExp(r'[\s-]+'));
      var total = 0;
      var current = 0;
      var ok = true;
      for (final word in words) {
        if (word == 'and') continue;
        final scale = _scales[word];
        if (scale != null) {
          current = current == 0 ? scale : current * scale;
          if (scale >= 1000) {
            total += current;
            current = 0;
          }
          continue;
        }
        final value = _ones[word];
        if (value == null) {
          ok = false;
          break;
        }
        current += value;
      }
      if (!ok) return m.group(0)!;
      final number = total + current;
      if (number <= 0) return m.group(0)!;
      return '$number ${m.group(2)}';
    });
  }

  // --- compiled rules ------------------------------------------------------

  /// Every phrase rule, compiled once. Longest key first so "never comes up"
  /// is consumed whole and never cut down to "comes up" by a shorter rule.
  static final List<(RegExp, String, bool)> _rules = () {
    final rules = <(String, String, bool)>[];
    _symptoms.forEach((key, value) {
      // A phrase that is already its own index has nothing to add.
      if (key != value) rules.add((key, value, true));
    });
    _vocab.forEach((key, value) {
      // Vocabulary expands too: an entry may be spelled both ways in the
      // corpora ("route target" and "route-target" are aliases of different
      // entries), so the fold adds the short form and keeps the long one.
      if (key != value) rules.add((key, value, true));
    });
    rules.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    return [
      for (final (key, canonical, expand) in rules)
        (_wholePhrase(key), canonical, expand),
    ];
  }();

  static RegExp _wholePhrase(String phrase) =>
      RegExp(r'\b' + phrase.split(' ').map(RegExp.escape).join(r'\s+') + r'\b');

  /// The phrases the layer knows, for tests and for the capability catalogue.
  static List<String> get vocabulary => [..._symptoms.keys, ..._vocab.keys];
}
