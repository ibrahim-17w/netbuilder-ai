/// The networking-only scope gate.
///
/// NetBuilder answers networking questions and builds networks - nothing
/// else. This gate is what says "no" to a coding request, a homework
/// question or general chit-chat, deterministically and offline.
///
/// It is deliberately CONSERVATIVE in one direction only: anything that
/// mentions networking is in scope, always. A false decline (refusing a real
/// network question) is far worse than a false accept (answering something
/// vague), so a message is declined only when it matches a clear out-of-topic
/// pattern AND carries no networking vocabulary at all. When unsure, the gate
/// stays open and the assistant's own vague/howto handling takes over.
class ScopeGate {
  const ScopeGate._();

  /// Single-word networking vocabulary. Matched as whole tokens, never as
  /// substrings: `lan` must not match `plan`, and `cli` must not match
  /// `client`.
  static const Set<String> networkingWords = {
    // devices and hardware
    'router', 'routers', 'switch', 'switches', 'firewall', 'firewalls',
    'modem', 'modems', 'bridge', 'bridges', 'repeater', 'server', 'servers',
    'workstation', 'workstations', 'endpoint', 'endpoints',
    'patch', 'panel',
    // topologies and media
    'network', 'networks', 'topology', 'topologies', 'lan', 'lans', 'wan',
    'wans', 'vlan', 'vlans', 'trunk', 'trunks', 'ethernet', 'cable',
    'cables', 'cabling', 'crossover', 'fiber', 'fibre', 'wireless', 'wifi',
    'wlan', 'ssid', 'ssids',
    // addressing and services
    'subnet', 'subnets', 'cidr', 'addressing', 'gateway', 'gateways',
    'dhcp', 'dhcpv6', 'dns', 'nat', 'acl', 'acls', 'vpn', 'vpns', 'radius',
    'tacacs', 'aaa', 'loopback', 'mtu', 'qos', 'packet', 'packets', 'ssh',
    'telnet', 'ipsec', 'hsrp', 'vrrp', 'ftp', 'tftp', 'ntp', 'syslog',
    'smtp',
    'frame', 'frames', 'arp', 'ping', 'traceroute', 'bandwidth', 'proxy',
    // routing and switching protocols
    'ospf', 'eigrp', 'bgp', 'stp', 'routing', 'route', 'routes', 'lacp',
    'etherchannel', 'port-channel',
    // vendors, labs and tools
    'cisco', 'gns3', 'mikrotik', 'ubiquiti', 'juniper', 'aruba', 'fortinet',
    'asa', 'cli', 'pkt', 'lab', 'labs', 'simulator', 'simulators',
    // real-world gear and terminology the advisor answers questions about,
    // so "should I use PPPoE or DHCP?" is in scope before it is declined
    // for looking like general advice.
    'unifi', 'omada', 'pfsense', 'opnsense', 'fortigate', 'sonicwall',
    'netgear', 'tplink', 'eero', 'deco', 'starlink',
    'isp', 'pppoe', 'cgnat', 'ont', 'onu', 'vdsl', 'adsl', 'poe', 'cctv',
    'nvr', 'voip', 'mesh', 'sfp',
    // broader
    'ipv6', 'slaac', 'balancer',
  };

  /// Multi-word phrases (and punctuation-bearing terms), matched as
  /// substrings after lowercasing - a phrase cannot accidentally hit inside
  /// one unrelated word.
  static const List<String> networkingPhrases = [
    'access point', 'access points', 'wireless router', 'patch panel',
    'ip address', 'mac address', 'static route', 'inter-vlan',
    'router-on-a-stick', 'spanning tree', 'port forwarding', 'port forward',
    'packet tracer', 'running-config', 'startup-config', 'show run',
    'palo alto', 'tp-link', 'wi-fi', '802.11', 'load balancer',
    'intrusion detection', '.pkt', '802.1x',
    'power over ethernet', 'client isolation', 'guest wifi', 'guest wi-fi',
    'guest network', 'captive portal', 'site-to-site', 'fixed wireless',
    'fibre to the home', 'fiber to the home',
  ];

  /// True when the message carries networking vocabulary (or looks like a
  /// networking brief: device counts, labels, CIDR, IP addresses).
  static bool isNetworking(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return true; // nothing to decline

    // Whole-token word hits.
    final tokens = t
        .split(RegExp(r'[^a-z0-9+#./-]+'))
        .where((w) => w.isNotEmpty)
        .toSet();
    for (final word in networkingWords) {
      if (tokens.contains(word)) return true;
    }
    // Phrase hits.
    for (final phrase in networkingPhrases) {
      if (t.contains(phrase)) return true;
    }
    // Brief shapes: "2 routers", "R1", "192.168.1.0/24", "g0/0".
    if (RegExp(
      r'\b\d{1,3}\s*(routers?|switch(?:es)?|pcs?|servers?|aps?|firewalls?|'
      r'vlans?|laptops?|printers?|phones?)\b',
    ).hasMatch(t)) {
      return true;
    }
    if (RegExp(r'\b(?:r|sw|pc|srv|fw|ap|ph)\d{1,3}\b').hasMatch(t)) {
      return true;
    }
    if (RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?\b').hasMatch(t)) {
      return true;
    }
    if (RegExp(r'\b[a-z]\d(?:/\d+|\d)\b').hasMatch(t)) {
      return true; // interface names: g0/0, s0/0/0, fa0/1
    }
    return false;
  }

  // --- out-of-topic patterns ---------------------------------------------

  /// Asking for code, a script or a program.
  static final RegExp _codeAsk = RegExp(
    r'\b(write|create|make|give|build|deploy|debug|fix|review|refactor|'
    r'explain|teach|show|help)\b[^.?!]{0,60}\b(code|script|program|'
    r'function|class|algorithm|website|webpage|web page|api|bot|game|'
    r'query|regex)\b',
  );

  /// Programming languages and general tooling, named outright.
  static final RegExp _codeTools = RegExp(
    r'\b(python|javascript|java script|typescript|golang|c\+\+|c#|html|'
    r'css|sql|bash|powershell|shell script|php|ruby|rust|swift|kotlin|'
    r'flutter|vue|angular|django|flask|node\.js|npm|github|dockerfile|'
    r'kubernetes|pandas|numpy|recursion|big o|time complexity|leetcode|'
    r'stackoverflow|excel|vba|spreadsheet|matlab)\b',
  );

  /// Writing and schoolwork.
  static final RegExp _writingAsk = RegExp(
    r'\b(essay|homework|coursework|assignment|thesis|dissertation|'
    r'literature review|summar(?:y|ize|ise)|paraphrase|translate|'
    r'translation|poem|poetry|short story|novel|recipe|cover letter|'
    r'resume|letter of recommendation|book report)\b',
  );

  /// General knowledge, jokes and small talk about the world.
  static final RegExp _generalAsk = RegExp(
    r'\b(tell me (a|another|some) joke|horoscope|who won|world cup|'
    r"celebrity|gossip|what(?:'s| is| are) the (weather|capital|"
    r'population|price)|how many (grams|calories)|best (restaurant|hotel|'
    r'movie|song|book)|recommend a (book|movie|show)|weather today|'
    r'news today|stock (price|market)|exchange rate|write me an? '
    r'(email|letter|text message|caption|bio))\b',
  );

  /// Roleplay and "act as" asks that carry no networking word.
  static final RegExp _roleplay = RegExp(
    r'\b(act as|pretend (you are|to be)|you are (now )?an? '
    r'(ai|assistant|teacher|chef|poet|therapist))\b',
  );

  /// Greetings, thanks and questions about the assistant itself.
  ///
  /// These are not off-topic - refusing "hello" would be rude - but they
  /// describe NO network. That distinction matters: a message that names no
  /// devices used to be parsed anyway, which invented a default 1-router
  /// lab, and the reply then confidently announced "here is the lab I
  /// understand" to someone who had only said hello. Small talk is answered
  /// as conversation and never becomes a plan.
  static final RegExp _smallTalk = RegExp(
    r'^\s*(hi|hey|hello|yo|hiya|howdy|heyo|sup|good\s+(morning|afternoon|'
    r'evening|day)|greetings|thanks?|thank\s+you|thx|ty|cheers|ok|okay|'
    r'k|cool|nice|awesome|great|perfect|yes|yeah|yep|yup|no|nope|nah|'
    r'sure|alright|bye|goodbye|see\s+ya|later|good\s+night|welcome)\b',
  );

  /// Questions about what this assistant is or can do. "how are you" and
  /// "how's it going" belong here too: they are conversation about the
  /// assistant, and parsing them as a brief would invent a lab the same
  /// way "hello" once did.
  static final RegExp _identityAsk = RegExp(
    r'\b(who\s+(are|r)\s+you|what\s+(are|r)\s+you|what\s+can\s+you\s+do|'
    r'what\s+do\s+you\s+do|what\s+are\s+you\s+for|help\s+me|'
    r'how\s+(do|can)\s+(you|this)\s+(work|help)|are\s+you\s+(an?\s+)?'
    r'(ai|bot|human|robot)|how\s+(are|r)\s+you|how.?s\s+it\s+going)\b',
  );

  /// True when the message is conversation rather than a network request.
  ///
  /// Always false for anything carrying networking vocabulary: "hi, build me
  /// a lab" is a build request wearing a greeting, and treating it as
  /// small talk would lose the build.
  static bool isSmallTalk(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (isNetworking(t)) return false;
    if (isOffTopic(t)) return false;
    if (_identityAsk.hasMatch(t)) return true;
    // A greeting is only small talk when it is ONLY a greeting: "thanks,
    // now add a server" carries the request and must not be swallowed.
    if (!_smallTalk.hasMatch(t)) return false;
    final withoutOpener = t.replaceFirst(_smallTalk, '').trim();
    return withoutOpener.isEmpty ||
        RegExp(r'^[\s,.!?:;-]*(there|you|netbuilder|again|all|everyone|'
                r'ok|okay|sure|thanks?|thank you|cheers)?'
                r'([\s,.!?:;-]*(there|you|netbuilder|again|all|everyone|'
                r'ok|okay|sure|thanks?|thank you|cheers))?'
                r'[\s,.!?:;-]*$').hasMatch(withoutOpener);
  }

  /// True when the message is clearly NOT about networking and must be
  /// declined. Always false for anything carrying networking vocabulary.
  static bool isOffTopic(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (isNetworking(t)) return false;
    return _codeAsk.hasMatch(t) ||
        _codeTools.hasMatch(t) ||
        _writingAsk.hasMatch(t) ||
        _generalAsk.hasMatch(t) ||
        _roleplay.hasMatch(t);
  }

  /// The one-line decline. Short, says what this app IS, and points at the
  /// very thing it can do instead - a refusal with no door through it is
  /// just a wall.
  static const String decline =
      'I only do networking: planning, building and explaining Packet Tracer '
      'and GNS3 labs, and helping design real networks. I do not write code, '
      'answer general questions or do homework.\n\n'
      'Tell me what network you need - for example "10 employees and two '
      'floors, build the network" - or ask me a networking question.';
}
