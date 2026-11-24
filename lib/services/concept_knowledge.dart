import 'casual_english.dart';
import 'learned_answers_service.dart';

/// One concept the knowledge can be filed under. The alias sets are
/// curated, not inferred: an alias is only listed when saying it really
/// means this concept, reusing the vocabulary the rest of the app already
/// ships ([CasualEnglish] protocol names, [OfflineKnowledge] triggers,
/// [DomainVocabulary] device words).
class ConceptSpec {
  final String concept;
  final String label;
  final String category;
  final List<String> related;
  final List<String> aliases;
  const ConceptSpec({
    required this.concept,
    required this.label,
    required this.category,
    required this.related,
    required this.aliases,
  });
}

/// One stored knowledge entry (a row of the `knowledge_concept` table).
class KnowledgeConcept {
  final int id;
  final String concept;
  final String label;
  final String category;

  /// The main explanation, as learned - never rewritten.
  final String answer;

  /// Optional shorter version, learned separately or written by the user.
  final String summary;

  /// Optional beginner-friendly version.
  final String beginner;

  /// Optional example.
  final String example;

  /// The provider label or "user" - where the knowledge came from.
  final String source;
  final String origin; // 'provider' | 'user'

  /// 'unverified' | 'confirmed' | 'conflict'. Verification is its own
  /// statement, never implied by relevance.
  final String status;

  /// The normalized key of the question the knowledge was first learned
  /// from (the exact-replay tier owns that question; this row owns the
  /// concept).
  final String qkey;
  final int seenCount;
  final String createdAt;
  final String updatedAt;

  const KnowledgeConcept({
    this.id = 0,
    required this.concept,
    this.label = '',
    this.category = '',
    required this.answer,
    this.summary = '',
    this.beginner = '',
    this.example = '',
    this.source = '',
    this.origin = 'provider',
    this.status = 'unverified',
    this.qkey = '',
    this.seenCount = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get verified => status == 'confirmed';

  /// The display name: the curated label when this concept is one of ours,
  /// else the raw stored name.
  String get displayName {
    if (label.isNotEmpty) return label;
    return ConceptKnowledge.specs[concept]?.label ?? concept;
  }
}

/// The explanation styles a query can ask for, derived from the query's own
/// words. The default is the full saved explanation.
enum ExplanationStyle { full, brief, beginner, example, detailed }

/// What to do with an incoming answer for a concept that already has one.
enum IncomingDecision { agrees, conflicts }

/// One alias occurrence inside a query, with its span (for the
/// longer-alias-shadows-shorter rule in [ConceptKnowledge.namedConcepts]).
class _AliasHit {
  final ConceptSpec spec;
  final int start;
  final int end;
  final int length;
  const _AliasHit(this.spec, this.start, this.end, this.length);
}

/// What one query retrieved from the concept store.
class ConceptRetrieval {
  /// Every named concept the store actually knows, best first.
  final List<KnowledgeConcept> known;

  /// Concepts the query NAMES that the store does not know. Non-empty
  /// means the answer must acknowledge them, not invent them.
  final List<ConceptSpec> missing;

  /// 1.0 for an alias-anchored match; the token-overlap score for a weaker
  /// one. Relevance, never the probability that the content is true.
  final double score;

  /// 'high': alias-anchored, everything the query names is known.
  /// 'medium': alias-anchored but partial, or an overlap-only match.
  /// 'low' is never returned - a low-confidence retrieval is null instead.
  final String confidence;
  final ExplanationStyle style;

  const ConceptRetrieval({
    required this.known,
    required this.missing,
    required this.score,
    required this.confidence,
    required this.style,
  });

  bool get isPartial => missing.isNotEmpty && known.isNotEmpty;
}

/// Concept-based knowledge: what the app learned, organized by the THING
/// the knowledge is about rather than by the words of the question.
///
/// The exact-question replay ([LearnedAnswers]) stays the top tier - "same
/// question, same answer" is a promise and is not touched. This layer is
/// the tier under it: when a learned answer exists but the question is
/// worded differently ("What is an IP?" learned, "Explain an IP address"
/// asked), the stored knowledge is retrieved by CONCEPT, with an honest
/// confidence tier and an explicit statement of what the app does NOT know.
///
/// The rules that keep it honest:
///
/// * aliases resolve to the same concept only when the app's own vocabulary
///   already says they are the same thing ("ip address", "internet protocol
///   address" -> ip-address). Nothing is inferred from surface similarity
///   alone;
/// * a question naming TWO concepts of which only one is stored is answered
///   PARTIALLY: the known part explained, the missing part named as
///   missing - never invented;
/// * a low-confidence match is never served: below the medium threshold the
///   retrieval is null and the ask falls through to the curated corpus and
///   the open-questions backlog, exactly as before;
/// * a relevance score is presented as relevance, never as the probability
///   that the content is correct - verification status is carried
///   separately and shown as its own line;
/// * stored answers are TEXT replayed into the chat. Nothing here feeds the
///   planner: a build request never reaches this layer (see
///   [ConceptKnowledge.isKnowledgeAsk]), and no branch of the app executes
///   or parses saved answers as configuration.
///
/// Pure and synchronous: MemoryService owns persistence; this class owns
/// the decisions. Every list operation is linear over small per-concept
/// token sets, so a 10k-row library stays well inside one frame (measured
/// in test/concept_knowledge_perf_test.dart).
class ConceptKnowledge {
  const ConceptKnowledge._();

  /// The concepts the offline brain can organize knowledge under, keyed by
  /// canonical name.
  static const Map<String, ConceptSpec> specs = {
    'ip-address': ConceptSpec(
      concept: 'ip-address',
      label: 'IP address',
      category: 'addressing',
      related: ['subnet', 'subnet-mask', 'default-gateway', 'dhcp'],
      aliases: [
        'ip',
        'ip address',
        'ip addresses',
        'internet protocol address',
        'internet protocol',
        'ipv4',
        'ips',
      ],
    ),
    'ipv6': ConceptSpec(
      concept: 'ipv6',
      label: 'IPv6',
      category: 'addressing',
      related: ['ip-address', 'dhcpv6'],
      aliases: ['ipv6', 'ip version 6', 'slaac', 'link-local', 'ndp'],
    ),
    'subnet': ConceptSpec(
      concept: 'subnet',
      label: 'Subnet',
      category: 'addressing',
      related: ['subnet-mask', 'cidr', 'vlsm', 'ip-address'],
      aliases: ['subnet', 'subnets', 'subnetting', 'network segment'],
    ),
    'subnet-mask': ConceptSpec(
      concept: 'subnet-mask',
      label: 'Subnet mask',
      category: 'addressing',
      related: ['subnet', 'cidr', 'wildcard-mask'],
      aliases: ['subnet mask', 'netmask', 'network mask', 'mask'],
    ),
    'cidr': ConceptSpec(
      concept: 'cidr',
      label: 'CIDR',
      category: 'addressing',
      related: ['subnet', 'subnet-mask'],
      aliases: ['cidr', 'prefix length', 'prefix notation', 'slash notation'],
    ),
    'vlsm': ConceptSpec(
      concept: 'vlsm',
      label: 'VLSM',
      category: 'addressing',
      related: ['subnet', 'subnet-mask'],
      aliases: ['vlsm', 'variable length subnet mask'],
    ),
    'wildcard-mask': ConceptSpec(
      concept: 'wildcard-mask',
      label: 'Wildcard mask',
      category: 'addressing',
      related: ['subnet-mask', 'acl'],
      aliases: ['wildcard', 'wildcard mask'],
    ),
    'default-gateway': ConceptSpec(
      concept: 'default-gateway',
      label: 'Default gateway',
      category: 'addressing',
      related: ['ip-address', 'static-routing', 'router'],
      aliases: ['default gateway', 'gateway'],
    ),
    'mac-address': ConceptSpec(
      concept: 'mac-address',
      label: 'MAC address',
      category: 'addressing',
      related: ['arp', 'switch', 'mac-table'],
      aliases: [
        'mac',
        'mac address',
        'mac addresses',
        'hardware address',
        'physical address',
        'media access control',
      ],
    ),
    'arp': ConceptSpec(
      concept: 'arp',
      label: 'ARP',
      category: 'addressing',
      related: ['mac-address', 'ping'],
      aliases: ['arp', 'address resolution protocol', 'arp table'],
    ),
    'mac-table': ConceptSpec(
      concept: 'mac-table',
      label: 'MAC address table',
      category: 'switching',
      related: ['mac-address', 'switch'],
      aliases: [
        'mac address table',
        'mac address-table',
        'mac table',
        'mac learning',
      ],
    ),
    'dhcp': ConceptSpec(
      concept: 'dhcp',
      label: 'DHCP',
      category: 'services',
      related: ['dns', 'ip-address', 'dhcp-relay', 'dhcp-snooping'],
      aliases: [
        'dhcp',
        'dynamic host configuration protocol',
        'dhcp pool',
        'dhcp scope',
      ],
    ),
    'dhcp-relay': ConceptSpec(
      concept: 'dhcp-relay',
      label: 'DHCP relay',
      category: 'services',
      related: ['dhcp'],
      aliases: [
        'dhcp relay',
        'relay agent',
        'ip helper-address',
        'helper address',
      ],
    ),
    'dhcp-snooping': ConceptSpec(
      concept: 'dhcp-snooping',
      label: 'DHCP snooping',
      category: 'security',
      related: ['dhcp'],
      aliases: ['dhcp snooping', 'snooping', 'rogue dhcp'],
    ),
    'dhcpv6': ConceptSpec(
      concept: 'dhcpv6',
      label: 'DHCPv6',
      category: 'services',
      related: ['dhcp', 'ipv6'],
      aliases: ['dhcpv6', 'dhcp for ipv6', 'ipv6 dhcp'],
    ),
    'dns': ConceptSpec(
      concept: 'dns',
      label: 'DNS',
      category: 'services',
      related: ['dhcp', 'reverse-dns'],
      aliases: [
        'dns',
        'domain name system',
        'name server',
        'name resolution',
        'dns lookup',
      ],
    ),
    'reverse-dns': ConceptSpec(
      concept: 'reverse-dns',
      label: 'Reverse DNS',
      category: 'services',
      related: ['dns'],
      aliases: ['reverse dns', 'reverse lookup', 'ptr record', 'in-addr'],
    ),
    'ospf': ConceptSpec(
      concept: 'ospf',
      label: 'OSPF',
      category: 'routing',
      related: ['eigrp', 'static-routing', 'ospf-adjacency'],
      aliases: [
        'ospf',
        'open shortest path first',
        'ospf area',
        'ospf process',
        'router ospf',
      ],
    ),
    'ospf-adjacency': ConceptSpec(
      concept: 'ospf-adjacency',
      label: 'OSPF adjacency',
      category: 'routing',
      related: ['ospf'],
      aliases: [
        'ospf neighbor',
        'ospf adjacency',
        'adjacency state',
        'exstart',
        'two-way state',
      ],
    ),
    'eigrp': ConceptSpec(
      concept: 'eigrp',
      label: 'EIGRP',
      category: 'routing',
      related: ['ospf', 'static-routing'],
      aliases: ['eigrp', 'enhanced interior gateway routing protocol'],
    ),
    'bgp': ConceptSpec(
      concept: 'bgp',
      label: 'BGP',
      category: 'routing',
      related: ['ospf'],
      aliases: ['bgp', 'border gateway protocol', 'autonomous system'],
    ),
    'static-routing': ConceptSpec(
      concept: 'static-routing',
      label: 'Static routing',
      category: 'routing',
      related: ['ospf', 'default-gateway'],
      aliases: [
        'static route',
        'static routing',
        'ip route',
        'default route',
        'floating static',
      ],
    ),
    'routing-protocol-choice': ConceptSpec(
      concept: 'routing-protocol-choice',
      label: 'Choosing a routing protocol',
      category: 'routing',
      related: ['ospf', 'eigrp', 'bgp', 'static-routing'],
      aliases: ['routing protocol', 'dynamic routing'],
    ),
    'router': ConceptSpec(
      concept: 'router',
      label: 'Router',
      category: 'devices',
      related: ['switch', 'default-gateway', 'static-routing'],
      aliases: ['router', 'routers'],
    ),
    'switch': ConceptSpec(
      concept: 'switch',
      label: 'Switch',
      category: 'devices',
      related: ['router', 'vlan', 'mac-table'],
      aliases: ['switch', 'switches', 'layer 2 switch'],
    ),
    'server': ConceptSpec(
      concept: 'server',
      label: 'Server',
      category: 'devices',
      related: ['dhcp', 'dns', 'http'],
      aliases: ['server', 'servers', 'server-pt'],
    ),
    'vlan': ConceptSpec(
      concept: 'vlan',
      label: 'VLAN',
      category: 'switching',
      related: ['trunk', 'inter-vlan-routing', 'switch'],
      aliases: [
        'vlan',
        'vlans',
        'virtual lan',
        'access vlan',
        'native vlan',
        'vlan 1',
      ],
    ),
    'trunk': ConceptSpec(
      concept: 'trunk',
      label: 'Trunk',
      category: 'switching',
      related: ['vlan', 'inter-vlan-routing'],
      aliases: ['trunk', 'trunking', 'trunk port', 'dot1q', '802.1q', 'dtp'],
    ),
    'inter-vlan-routing': ConceptSpec(
      concept: 'inter-vlan-routing',
      label: 'Inter-VLAN routing',
      category: 'switching',
      related: ['vlan', 'trunk'],
      aliases: [
        'inter-vlan routing',
        'intervlan routing',
        'vlan routing',
        'router on a stick',
        'subinterface',
        'svi',
        'layer 3 switch',
      ],
    ),
    'stp': ConceptSpec(
      concept: 'stp',
      label: 'STP',
      category: 'switching',
      related: ['rstp', 'switch'],
      aliases: ['stp', 'spanning tree', 'root bridge', 'root primary'],
    ),
    'rstp': ConceptSpec(
      concept: 'rstp',
      label: 'RSTP',
      category: 'switching',
      related: ['stp'],
      aliases: ['rstp', 'rapid pvst', 'rapid spanning tree'],
    ),
    'portfast': ConceptSpec(
      concept: 'portfast',
      label: 'PortFast / BPDU guard',
      category: 'switching',
      related: ['stp'],
      aliases: ['portfast', 'bpduguard', 'edge port'],
    ),
    'port-security': ConceptSpec(
      concept: 'port-security',
      label: 'Port security',
      category: 'security',
      related: ['switch', 'mac-address'],
      aliases: ['port security', 'port-security', 'sticky mac'],
    ),
    'nat': ConceptSpec(
      concept: 'nat',
      label: 'NAT',
      category: 'security',
      related: ['ip-address', 'wan'],
      aliases: [
        'nat',
        'network address translation',
        'pat',
        'port address translation',
        'nat overload',
        'inside local',
      ],
    ),
    'acl': ConceptSpec(
      concept: 'acl',
      label: 'ACL',
      category: 'security',
      related: ['wildcard-mask', 'firewall'],
      aliases: ['acl', 'acls', 'access control list', 'access list'],
    ),
    'firewall': ConceptSpec(
      concept: 'firewall',
      label: 'Firewall',
      category: 'security',
      related: ['acl', 'nat'],
      aliases: ['firewall', 'firewalls', 'asa', 'zone-based firewall'],
    ),
    'ssh': ConceptSpec(
      concept: 'ssh',
      label: 'SSH',
      category: 'security',
      related: ['telnet'],
      aliases: ['ssh', 'secure shell'],
    ),
    'telnet': ConceptSpec(
      concept: 'telnet',
      label: 'Telnet',
      category: 'security',
      related: ['ssh'],
      aliases: ['telnet'],
    ),
    'enable-secret': ConceptSpec(
      concept: 'enable-secret',
      label: 'Device passwords',
      category: 'security',
      related: ['ssh', 'telnet'],
      aliases: [
        'enable secret',
        'enable password',
        'console password',
        'line password',
        'vty password',
        'password encryption',
        'banner motd',
      ],
    ),
    'vpn': ConceptSpec(
      concept: 'vpn',
      label: 'VPN',
      category: 'security',
      related: ['wan', 'firewall'],
      aliases: ['vpn', 'ipsec', 'site-to-site', 'gre tunnel', 'crypto map'],
    ),
    'wan': ConceptSpec(
      concept: 'wan',
      label: 'WAN / serial links',
      category: 'networking',
      related: ['router', 'vpn', 'ppp'],
      aliases: [
        'wan',
        'serial link',
        'serial cable',
        'leased line',
        'lease line',
        'dce',
        'dte',
        'clock rate',
      ],
    ),
    'lan': ConceptSpec(
      concept: 'lan',
      label: 'LAN',
      category: 'networking',
      related: ['switch', 'vlan'],
      aliases: ['lan', 'local area network'],
    ),
    'ppp': ConceptSpec(
      concept: 'ppp',
      label: 'PPP',
      category: 'networking',
      related: ['wan'],
      aliases: ['ppp', 'chap', 'pap', 'encapsulation ppp'],
    ),
    'tcp': ConceptSpec(
      concept: 'tcp',
      label: 'TCP',
      category: 'transport',
      related: ['udp', 'http'],
      aliases: [
        'tcp',
        'transmission control protocol',
        'three-way handshake',
        'tcp adjust-mss',
        'adjust-mss',
      ],
    ),
    'udp': ConceptSpec(
      concept: 'udp',
      label: 'UDP',
      category: 'transport',
      related: ['tcp'],
      aliases: ['udp', 'user datagram protocol'],
    ),
    'http': ConceptSpec(
      concept: 'http',
      label: 'HTTP / web service',
      category: 'services',
      related: ['dns', 'server'],
      aliases: ['http', 'https', 'web server', 'web service'],
    ),
    'ftp': ConceptSpec(
      concept: 'ftp',
      label: 'FTP / TFTP',
      category: 'services',
      related: ['server'],
      aliases: ['ftp', 'tftp', 'file transfer'],
    ),
    'email': ConceptSpec(
      concept: 'email',
      label: 'Email services',
      category: 'services',
      related: ['dns', 'server'],
      aliases: ['smtp', 'pop3', 'email server', 'mail server', 'email service'],
    ),
    'ntp': ConceptSpec(
      concept: 'ntp',
      label: 'NTP',
      category: 'services',
      related: ['syslog'],
      aliases: ['ntp', 'network time', 'time sync', 'clock sync'],
    ),
    'syslog': ConceptSpec(
      concept: 'syslog',
      label: 'Syslog',
      category: 'services',
      related: ['ntp'],
      aliases: ['syslog', 'logging host', 'log server'],
    ),
    'snmp': ConceptSpec(
      concept: 'snmp',
      label: 'SNMP',
      category: 'services',
      related: ['server'],
      aliases: ['snmp', 'community string', 'snmp trap'],
    ),
    'qos': ConceptSpec(
      concept: 'qos',
      label: 'QoS',
      category: 'networking',
      related: ['tcp'],
      aliases: ['qos', 'quality of service'],
    ),
    'hsrp': ConceptSpec(
      concept: 'hsrp',
      label: 'Gateway redundancy',
      category: 'networking',
      related: ['default-gateway', 'router'],
      aliases: [
        'hsrp',
        'vrrp',
        'glbp',
        'gateway redundancy',
        'first hop redundancy',
      ],
    ),
    'wireless-security': ConceptSpec(
      concept: 'wireless-security',
      label: 'Wireless security',
      category: 'wireless',
      related: ['access-point'],
      aliases: ['wpa', 'wpa2', 'wep', 'wireless security', 'wifi security'],
    ),
    'access-point': ConceptSpec(
      concept: 'access-point',
      label: 'Wireless access',
      category: 'wireless',
      related: ['wireless-security', 'switch'],
      aliases: [
        'access point',
        'wireless',
        'wifi',
        'ssid',
        'wireless controller',
        'wlc',
      ],
    ),
    'loopback': ConceptSpec(
      concept: 'loopback',
      label: 'Loopback interface',
      category: 'networking',
      related: ['ospf'],
      aliases: ['loopback', 'loopback0', 'loopback interface'],
    ),
    'cabling': ConceptSpec(
      concept: 'cabling',
      label: 'Cabling',
      category: 'networking',
      related: ['wan'],
      aliases: [
        'crossover',
        'straight-through',
        'straight through',
        'rollover',
        'console cable',
        'cable type',
      ],
    ),
    'duplex': ConceptSpec(
      concept: 'duplex',
      label: 'Duplex / speed',
      category: 'networking',
      related: ['cabling'],
      aliases: [
        'duplex',
        'auto negotiation',
        'speed mismatch',
        'late collision',
      ],
    ),
    'ping': ConceptSpec(
      concept: 'ping',
      label: 'Ping / traceroute',
      category: 'troubleshooting',
      related: ['arp', 'default-gateway'],
      aliases: ['ping', 'traceroute', 'tracert', 'connectivity test'],
    ),
    'packet-tracer': ConceptSpec(
      concept: 'packet-tracer',
      label: 'Packet Tracer usage',
      category: 'tools',
      related: ['cabling'],
      aliases: ['packet tracer'],
    ),
  };

  // --- asking ----------------------------------------------------------------

  /// Confidence tiers. An alias-anchored hit is high when the query names
  /// only known concepts; medium when it names something the store lacks
  /// (partial) or when only token overlap supports it. Anything below the
  /// medium floor is not served at all.
  static const double mediumFloor = 0.40;

  /// True when [text] is a knowledge ask this layer may answer.
  ///
  /// Everything [LearnedAnswers.isLearnableQuestion] accepts is one; so is
  /// an explanation imperative ("explain ospf", "tell me about dhcp"),
  /// which the CAPTURE gate deliberately stays away from - only
  /// question-shaped asks are ever stored from provider replies - but a
  /// retrieval tier that refused "Explain OSPF." while knowing OSPF would
  /// be answering questions and ignoring instructions to answer. The
  /// planner guards are shared either way: a device count is a build brief
  /// and a change verb is an instruction, whatever the shaping.
  static bool isKnowledgeAsk(String text) {
    final t = text.trim().toLowerCase();
    if (t.length < 8 || t.contains('\n') || t.startsWith('/')) return false;
    // The planner owns these, whatever the shaping - same guards as the
    // capture gate, kept literal so the two can never drift apart.
    if (RegExp(
      r'\d+\s*(routers?|switches|switch|pcs?|servers?|laptops?|printers?'
      r'|firewalls?)',
    ).hasMatch(t)) {
      return false;
    }
    if (RegExp(
      r'^(add|remove|delete|fix|repair|change|set|use|build|make)\b',
    ).hasMatch(t)) {
      return false;
    }
    if (LearnedAnswers.isLearnableQuestion(text)) return true;
    return RegExp(
      r'^(explain|describe|tell me about|what about)\b',
    ).hasMatch(t);
  }

  /// Retrieve the saved knowledge for [query], or null when nothing clears
  /// the medium floor. [rows] is the store (one row per concept).
  static ConceptRetrieval? retrieve(String query, List<KnowledgeConcept> rows) {
    final t = CasualEnglish.canonical(query.trim().toLowerCase());
    if (t.isEmpty) return null;
    final style = styleFor(query);
    final named = namedConcepts(t);
    if (named.isEmpty) {
      // No alias in the query: the only honest signal left is token overlap
      // between the query and the stored concepts. A strong overlap earns a
      // QUALIFIED (medium) answer, phrased as "this may be about X" - never
      // a confident one.
      final best = _overlapBest(t, rows);
      if (best == null || best.$2 < mediumFloor) return null;
      return ConceptRetrieval(
        known: [best.$1],
        missing: const [],
        score: best.$2,
        confidence: 'medium',
        style: style,
      );
    }
    final known = <KnowledgeConcept>[];
    final missing = <ConceptSpec>[];
    for (final spec in named) {
      final row = _rowFor(spec.concept, rows);
      if (row == null) {
        missing.add(spec);
      } else {
        known.add(row);
      }
    }
    if (known.isEmpty) {
      // Every concept the query names is unknown. Serving a "I know nothing
      // about X" line here would swallow the curated corpus, which may
      // still answer - the caller falls through instead.
      return null;
    }
    // Alias-anchored: 1.0, minus a little when the query names concepts the
    // store lacks (the answer will be partial, and honesty must show).
    final score = missing.isEmpty ? 1.0 : 0.9;
    return ConceptRetrieval(
      known: known,
      missing: missing,
      score: score,
      confidence: missing.isEmpty ? 'high' : 'medium',
      style: style,
    );
  }

  /// Every concept [query] names, in the order the aliases appear. A query
  /// naming two concepts ("IP versus MAC") returns both - the caller needs
  /// the FULL coverage picture to answer partially without inventing.
  ///
  /// Overlapping aliases resolve to the SPECIFIC one: "gateway redundancy"
  /// names hsrp, not default-gateway (whose shorter 'gateway' alias matches
  /// inside it), and "wildcard mask" names wildcard-mask, not subnet-mask.
  /// A match survives only when no OTHER concept matched a strictly longer
  /// alias covering the same words.
  static List<ConceptSpec> namedConcepts(String query) {
    // All alias hits, earliest first.
    final hits = <_AliasHit>[];
    for (final entry in _aliasPatterns) {
      final m = entry.$2.firstMatch(query);
      if (m != null) {
        hits.add(_AliasHit(entry.$1, m.start, m.end, m.end - m.start));
      }
    }
    if (hits.isEmpty) return const [];
    hits.sort(
      (a, b) => a.start != b.start ? a.start - b.start : (b.length - a.length),
    );
    // Keep a hit only when no longer hit from a DIFFERENT concept covers it.
    final kept = <_AliasHit>[];
    for (final hit in hits) {
      final shadowed = kept.any(
        (k) => k.spec.concept != hit.spec.concept && _covers(k, hit),
      );
      if (!shadowed) kept.add(hit);
    }
    // One hit per concept: its earliest surviving alias. Deterministic
    // order: the order the aliases appear in the query, so "IP vs MAC"
    // reads ip-address first, mac-address second.
    final out = <ConceptSpec>[];
    for (final hit in kept) {
      if (!out.any((s) => s.concept == hit.spec.concept)) {
        out.add(hit.spec);
      }
    }
    return out;
  }

  /// True when [k] starts at or before [hit], ends at or after it, and the
  /// two spans actually overlap - so a longer alias at the same words wins.
  static bool _covers(_AliasHit k, _AliasHit hit) =>
      k.start <= hit.start && k.end >= hit.end;

  /// One precompiled whole-phrase pattern per alias, built once: compiling
  /// ~250 regexes per ask would dominate retrieval on a low-end phone, and
  /// the alias table is fixed for the app's lifetime.
  static final List<(ConceptSpec, RegExp)> _aliasPatterns = [
    for (final spec in specs.values)
      for (final alias in spec.aliases)
        (spec, RegExp('\\b${RegExp.escape(alias)}\\b')),
  ];

  /// The explanation style the query asks for, by its own words.
  static ExplanationStyle styleFor(String query) {
    final t = query.trim().toLowerCase();
    if (RegExp(
      r'\b(briefly|brief|in short|short version|one line|summarize|summarise|'
      r'summary|tl;?dr|nutshell)\b',
    ).hasMatch(t)) {
      return ExplanationStyle.brief;
    }
    if (RegExp(
      r"\b(beginner|simple terms|simply|eli5|like i'm new|new to "
      r'networking|explain it simply|easy terms)\b',
    ).hasMatch(t)) {
      return ExplanationStyle.beginner;
    }
    if (RegExp(
      r'\b(example|examples|for instance|real.?world example|sample)\b',
    ).hasMatch(t)) {
      return ExplanationStyle.example;
    }
    if (RegExp(
      r'\b(detailed|in detail|more detail|deeper|elaborate|explain more|'
      r'in depth|fuller)\b',
    ).hasMatch(t)) {
      return ExplanationStyle.detailed;
    }
    return ExplanationStyle.full;
  }

  // --- capture -----------------------------------------------------------------

  /// The concept a learned question/answer pair belongs to, or null when
  /// the pair does not clearly name one.
  ///
  /// Precision over recall: the QUESTION must name the concept. When it
  /// does not, the ANSWER's first sentence may, but only when it names
  /// exactly ONE distinct concept - an answer that opens by naming DHCP and
  /// DNS has no single owner, and filing it under either would be a guess.
  /// A question naming several concepts has no single owner either: the
  /// pair is stored as a raw learned answer (the exact replay still serves
  /// it verbatim), not as concept knowledge.
  static String? extractConcept(String question, String answer) {
    final qNamed = namedConcepts(
      CasualEnglish.canonical(question.trim().toLowerCase()),
    );
    if (qNamed.length == 1) return qNamed.first.concept;
    if (qNamed.length > 1) return null;
    final firstSentence = _firstSentence(answer);
    final aNamed = namedConcepts(
      CasualEnglish.canonical(firstSentence.toLowerCase()),
    );
    return aNamed.length == 1 ? aNamed.first.concept : null;
  }

  /// Classify an incoming answer against the stored one.
  ///
  /// The base signal is the same directional-containment agreement
  /// [LearnedAnswers] uses for repeated model answers. Containment alone,
  /// though, can bless a contradiction that reuses the stored words - "it
  /// never assigns addresses" shares nearly every token with "assigns
  /// addresses". Two more signals run on the OPENING sentences, where an
  /// explanation commits to what the thing IS:
  ///
  /// * negation contrast - a content token the stored opening asserts and
  ///   the incoming opening denies ("never assigns"), or the reverse, is
  ///   the classic silent-contradiction shape and goes to review;
  /// * opening overlap - openings drawing on entirely different vocabulary
  ///   also go to review, since the containment above may simply be
  ///   matching scaffolding.
  ///
  /// A false conflict costs one user review in the Memory screen; a false
  /// agreement poisons the knowledge (Test E). The stored entry is never
  /// silently overwritten either way: a conflict is its own row.
  static IncomingDecision classifyIncoming(
    KnowledgeConcept existing,
    String incoming,
  ) {
    if (!LearnedAnswers.answersAgree(existing.answer, incoming)) {
      return IncomingDecision.conflicts;
    }
    final headA = _headTokens(existing.answer);
    final headB = _headTokens(incoming);
    if (_negationContrast(existing.answer, incoming, headA, headB)) {
      return IncomingDecision.conflicts;
    }
    if (headA.isEmpty || headB.isEmpty) return IncomingDecision.agrees;
    final shared = headA.intersection(headB).length;
    final smaller = headA.length < headB.length ? headA.length : headB.length;
    if (shared == 0 || shared / smaller < 0.5) {
      return IncomingDecision.conflicts;
    }
    return IncomingDecision.agrees;
  }

  /// True when one opening denies what the other asserts: the same content
  /// token negated on one side and positive on the other.
  static bool _negationContrast(
    String stored,
    String incoming,
    Set<String> headA,
    Set<String> headB,
  ) {
    final negA = _negatedTokens(stored);
    final negB = _negatedTokens(incoming);
    for (final t in negA) {
      if (headB.contains(t) && !negB.contains(t)) return true;
    }
    for (final t in negB) {
      if (headA.contains(t) && !negA.contains(t)) return true;
    }
    return false;
  }

  /// Content tokens sitting within one word after an explicit negator:
  /// "never assigns", "does not hand out", "cannot route". The one-word
  /// window keeps the check conservative - "no manual configuration needed"
  /// negates only 'manual', not every token in the sentence.
  static Set<String> _negatedTokens(String text) {
    final out = <String>{};
    for (final m in RegExp(
      r"\b(?:never|not|no|cannot|can't|cant|doesn'?t|don'?t|isn'?t|aren'?t|"
      r"won'?t|without|neither|nor)\s+([a-z]+)",
    ).allMatches(text.toLowerCase())) {
      final w = m.group(1)!;
      if (w.length >= 3) out.add(_stem(w));
    }
    return out;
  }

  /// Content tokens of an answer's opening sentence, canonicalized so
  /// "Dynamic Host Configuration Protocol" and "DHCP" compare equal.
  static Set<String> _headTokens(String answer) {
    final head = CasualEnglish.canonical(_firstSentence(answer).toLowerCase());
    return {
      for (final w in head.split(RegExp(r'[^a-z0-9]+')))
        if (w.length >= 3 && !LearnedAnswers.stopwords.contains(w)) _stem(w),
    };
  }

  static String _stem(String w) {
    for (final suffix in const ['ing', 'ies', 'es', 's']) {
      if (w.length > suffix.length + 2 && w.endsWith(suffix)) {
        return w.substring(0, w.length - suffix.length);
      }
    }
    return w;
  }

  // --- composing the answer ------------------------------------------------------

  /// The answer text for [retrieval], composed honestly from what is
  /// stored.
  ///
  /// * full / detailed: the saved explanation (detailed notes when the
  ///   store has no deeper version than the one it already serves).
  /// * brief: the saved one-line summary when one was learned; otherwise
  ///   the first paragraph of the saved explanation, LABELLED as an
  ///   excerpt - trimming stored text is deterministic, inventing it is
  ///   not.
  /// * beginner: the saved beginner explanation when one was learned;
  ///   otherwise the full explanation plus a line saying no simpler
  ///   version exists.
  /// * example: the saved example when one was learned; otherwise a line
  ///   saying no example was saved, with the main explanation offered.
  ///
  /// A partial retrieval (the query named concepts the store lacks) is
  /// answered with the known part plus an explicit cannot-determine line
  /// naming the missing concepts. A multi-concept hit joins the concepts'
  /// explanations under one header each. Nothing here is generated: every
  /// sentence comes from stored text or from a fixed honest template.
  static String composeAnswer(ConceptRetrieval retrieval) {
    final b = StringBuffer();
    final partial = retrieval.isPartial;
    final multi = retrieval.known.length > 1;
    if (partial) {
      b.write(
        'I can explain what I know here, but not everything this asks '
        'about:\n',
      );
    }
    for (final row in retrieval.known) {
      if (multi || partial) b.write('\n**${row.displayName}**\n');
      b.write(_styledBody(row, retrieval.style));
    }
    if (partial) {
      final names = [for (final m in retrieval.missing) m.label].join(' and ');
      b.write(
        '\n\nWhat I cannot determine: I have no saved knowledge about '
        '$names. I will not invent that part - enable your API provider '
        'and ask again, and the answer can be saved alongside this.',
      );
    }
    if (multi && !partial) {
      b.write(
        '\n\nThat is the whole of what I hold on both - ask about one at '
        'a time for more depth on either.',
      );
    }
    return b.toString().trim();
  }

  /// One provenance line, appended by the caller under the answer: where
  /// the knowledge came from and whether it is verified. Relevance is not
  /// presented as correctness - status is its own statement.
  static String provenanceLine(KnowledgeConcept row) {
    final source = row.source.isEmpty ? 'your AI provider' : row.source;
    final origin = row.origin == 'user'
        ? 'you taught me'
        : 'learned from $source';
    final status = row.verified ? 'verified' : 'unverified';
    return 'From saved knowledge on this device - $origin · $status.';
  }

  static String _styledBody(KnowledgeConcept row, ExplanationStyle style) {
    switch (style) {
      case ExplanationStyle.brief:
        final hasSummary = row.summary.trim().isNotEmpty;
        final short = hasSummary ? row.summary.trim() : _excerpt(row.answer);
        return hasSummary
            ? short
            : '$short\n\n(Short version - I have the fuller saved '
                  'explanation if you ask for it in detail.)';
      case ExplanationStyle.beginner:
        if (row.beginner.trim().isNotEmpty) return row.beginner.trim();
        return '${row.answer}\n\n(I have no simpler version of this saved '
            'yet.)';
      case ExplanationStyle.example:
        if (row.example.trim().isNotEmpty) return row.example.trim();
        return 'I have no example saved for ${row.displayName} yet. Here is '
            'the explanation I do have:\n\n${row.answer}';
      case ExplanationStyle.detailed:
      case ExplanationStyle.full:
        return row.answer;
    }
  }

  /// The first paragraph of a stored explanation - a deterministic excerpt
  /// of text the app already holds, never new wording.
  static String _excerpt(String answer) {
    final text = answer.trim();
    final para = text.split(RegExp(r'\n\s*\n')).first.trim();
    if (para.length <= 320) return para;
    final cut = para.indexOf(RegExp(r'(?<=[.!?]) '), 200);
    return cut > 0 ? para.substring(0, cut + 1) : para;
  }

  // --- matching internals --------------------------------------------------------

  static KnowledgeConcept? _rowFor(
    String concept,
    List<KnowledgeConcept> rows,
  ) {
    for (final r in rows) {
      if (r.concept == concept) return r;
    }
    return null;
  }

  /// The best overlap-only match: content tokens of the query against the
  /// concept's own vocabulary (name parts + label + the head of the stored
  /// answer). The answer head only, not the whole text, which keeps the
  /// per-row cost small; measured at test/concept_knowledge_perf_test.dart,
  /// the full sweep at a 10,000-row library averages a few tens of ms on
  /// desktop hardware - acceptable for a fallback that runs once per ask,
  /// because the alias path above answers the common case first.
  static (KnowledgeConcept, double)? _overlapBest(
    String query,
    List<KnowledgeConcept> rows,
  ) {
    final content = <String>{
      for (final w in query.split(_words))
        if (w.length >= 3 && !LearnedAnswers.stopwords.contains(w)) w,
    };
    if (content.isEmpty) return null;
    (KnowledgeConcept, double)? best;
    for (final row in rows) {
      final vocab = _vocabularyOf(row);
      var shared = 0;
      for (final w in content) {
        if (vocab.contains(w)) shared++;
      }
      final score = shared / content.length;
      if (best == null || score > best.$2) best = (row, score);
    }
    return best;
  }

  /// The tokens a row can be matched on, computed once per row instance.
  /// Rows are immutable query results, and repeated asks over the same
  /// library (the store now returns the same list) reuse the tokenising
  /// work instead of rebuilding four sets per row per query.
  static final Expando<Set<String>> _vocabularyCache = Expando<Set<String>>(
    'concept-vocabulary',
  );

  static Set<String> _vocabularyOf(KnowledgeConcept row) =>
      _vocabularyCache[row] ??= <String>{
        ...row.concept.split('-'),
        ...row.displayName.toLowerCase().split(' '),
        ...row.label.toLowerCase().split(' '),
        for (final w in _answerHead(row.answer).split(_words))
          if (w.length >= 3 && !LearnedAnswers.stopwords.contains(w)) w,
      };

  /// One compiled splitter for the whole file: the retrieval sweep calls it
  /// once per row, so a fresh RegExp there was millions of compilations a
  /// second on a large library.
  static final RegExp _words = RegExp(r'[^a-z0-9]+');

  static String _answerHead(String answer) {
    final text = answer.trim();
    return text.length <= 400 ? text : text.substring(0, 400);
  }

  static String _firstSentence(String text) {
    final t = text.trim();
    final m = RegExp(r'^(.*?[.!?])\s').firstMatch(t);
    if (m != null && m.group(1)!.length > 10) return m.group(1)!;
    return t.length <= 200 ? t : t.substring(0, 200);
  }
}
