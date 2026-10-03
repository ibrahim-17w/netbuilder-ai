/// Deterministic sizing: a business request becomes a bill of materials.
///
/// "I have 10 employees and two floors and want to build the network" is not
/// a device list, but it *is* enough to size one. This service does that
/// inference with rules, not a model: the same facts always produce the same
/// plan, every line of the BOM carries its reason, and anything the request
/// did not say becomes a named assumption or a question instead of a silent
/// invention.
///
/// It never speaks device vocabulary itself. [forBrief] returns null for any
/// brief that already states device counts - the planner's own parser covers
/// those exactly - and only answers for a brief that talks about *people*
/// and *spaces*: employees, students, guests, customers, floors, classrooms.
/// The result carries [expandedBrief], a deterministic rewrite that the
/// existing parser reads as if the user had typed a device list, so the
/// topology, addressing, adapters and verification are the same code paths
/// every other brief already uses.
library;

/// The kind of place a brief describes. The rules differ: a school sizes its
/// PC count from students, a cafe has no fixed PCs at all, a clinic wants the
/// edge locked down.
enum OrgKind { office, school, clinic, guest, home, industrial }

class SizingPlan {
  final OrgKind org;

  /// The people fact: how many, and the word the brief used for them.
  final int people;
  final String peopleWord;

  /// The space fact: how many floors/rooms, and the word used.
  final int zones;
  final String zoneWord;

  final int routers;
  final int switches;
  final int pcs;
  final int accessPoints;
  final int servers;
  final int firewalls;
  final int clouds;
  final int phones;
  final int printers;
  final List<String> serverServices;
  final List<int> vlans;

  /// Why each part of the BOM exists, in the user's own terms.
  final List<String> reasons;

  /// What was assumed because the request did not say it.
  final List<String> assumptions;

  /// The 2-3 things genuinely worth asking before the build.
  final List<String> questions;

  /// The brief the parser actually reads.
  final String expandedBrief;

  final double confidence;

  const SizingPlan({
    required this.org,
    required this.people,
    required this.peopleWord,
    required this.zones,
    required this.zoneWord,
    required this.routers,
    required this.switches,
    required this.pcs,
    required this.accessPoints,
    required this.servers,
    required this.firewalls,
    required this.clouds,
    required this.phones,
    required this.printers,
    required this.serverServices,
    required this.vlans,
    required this.reasons,
    required this.assumptions,
    required this.questions,
    required this.expandedBrief,
    required this.confidence,
  });
}

class SizingService {
  const SizingService._();

  // --- vocabulary ---------------------------------------------------------

  /// People the brief may count. A person is a workstation in an office and a
  /// student seat in a school, but a *guest* word means the opposite: those
  /// people bring their own devices, so they size the wireless network rather
  /// than the PC count.
  static final _people = RegExp(
    r'\b(\d{1,4})\s*(employees?|staff|workers?|people|persons?|users?|'
    r'students?|pupils?|learners?|kids|children|teenagers?|guests?|visitors?|'
    r'customers?|clients?|patients?|residents?|seats?|desks?|workstations?|'
    r'agents?|members?|teachers?|nurses?|doctors?|engineers?|technicians?|'
    r'accountants?|lawyers?|operators?|attendees?|passengers?)\b',
    caseSensitive: false,
  );

  /// The people words that mean "their own devices", not "our workstations".
  static final _guestPeople = RegExp(
    r'guests?|visitors?|customers?|clients?|patients?|attendees?|'
    r'passengers?|members?',
    caseSensitive: false,
  );

  /// The spaces devices are spread over. A floor is an access switch and an
  /// access point; a classroom is an access point zone. Sites/branches are
  /// deliberately NOT here - those are multi-site briefs the parser already
  /// multiplies per site.
  static final _spaces = RegExp(
    r'\b(\d{1,3})\s*(floors?|storeys?|stories|levels?|rooms?|classrooms?|'
    r'wards?|departments?|counters?|tables?)\b',
    caseSensitive: false,
  );

  static bool _has(String lower, String word) =>
      RegExp('\\b${RegExp.escape(word)}').hasMatch(lower);

  static final _orgWords = <OrgKind, List<String>>{
    OrgKind.school: [
      'school', 'college', 'university', 'academy', 'kindergarten', 'campus',
      'institute', 'library', 'training centre', 'training center',
    ],
    OrgKind.clinic: [
      'clinic', 'hospital', 'medical centre', 'medical center',
      'health centre', 'health center', 'pharmacy', 'dentist', 'dental',
      'surgery', 'care home', 'nursing home',
    ],
    OrgKind.guest: [
      'cafe', 'coffee shop', 'coffee', 'restaurant', 'bar', 'pub', 'hotel',
      'motel', 'hostel', 'b&b', 'guest house', 'shop', 'store', 'boutique',
      'supermarket', 'salon', 'barber', 'gym', 'fitness', 'retail',
    ],
    OrgKind.home: [
      'home', 'apartment', 'flat', 'villa', 'house', 'residence', 'studio',
    ],
    OrgKind.industrial: [
      'warehouse', 'factory', 'workshop', 'industrial', 'plant', 'depot',
      'logistics', 'farm',
    ],
    OrgKind.office: [
      'office', 'company', 'business', 'firm', 'agency', 'startup',
      'enterprise', 'coworking', 'co-working', 'bank', 'insurance',
      'call centre', 'call center', 'law office', 'accounting',
    ],
  };

  /// A brief that already states device counts is the parser's business and
  /// is answered exactly as written - the sizing pack must never second-guess
  /// "2 routers, 1 switch and 4 pcs".
  static final _explicitCounts = RegExp(
    r'\b\d{1,3}\s*(routers?|switches|switch|pcs?|servers?|laptops?|'
    r'printers?|firewalls?|access points?|aps?|phones?|tablets?|clouds?|'
    r'modems?|cameras?|tvs?)\b',
    caseSensitive: false,
  );

  static final _deviceLabels = RegExp(r'\b(?:R|SW|PC|SRV|FW|AP|PH|LT)\d{1,3}\b');

  /// The user ruled wifi (or the edge) out; respect it rather than sizing it.
  static final _noWifi = RegExp(
    r'\bno\s+(?:wi[- ]?fi|wireless|wlan)\b|wired[ -]only|'
    r'without\s+(?:wi[- ]?fi|wireless)',
    caseSensitive: false,
  );
  static final _noEdge = RegExp(
    r'\bno\s+(?:internet|firewall|isp)\b|\bstandalone\b|\bisolated\b|'
    r'\boffline lab\b|\bno edge\b',
    caseSensitive: false,
  );
  static final _flat = RegExp(
    r'\bflat\b|\bno vlans?\b|\bsingle vlan\b|\bno segmentation\b',
    caseSensitive: false,
  );
  static final _wifiWanted = RegExp(
    r'\b(wi[- ]?fi|wireless|wlan|mobiles?|phones?|laptops?|tablets?)\b',
    caseSensitive: false,
  );
  static final _voice = RegExp(r'\b(ip phones?|voip|voice)\b', caseSensitive: false);
  static final _printer = RegExp(r'\bprinters?\b', caseSensitive: false);

  // --- the entry point ----------------------------------------------------

  /// A sizing plan for a business brief, or null when the brief is not one.
  ///
  /// The text must already be bridged (see `NetworkIntent.bridgeBrief`), so
  /// the numbers are digits and the device words are English.
  static SizingPlan? forBrief(String bridged) {
    final lower = bridged.toLowerCase();
    if (_explicitCounts.hasMatch(lower) || _deviceLabels.hasMatch(lower)) {
      return null;
    }
    final peopleMatch = _people.firstMatch(lower);
    final spaceMatch = _spaces.firstMatch(lower);
    final org = _org(lower);
    if (peopleMatch == null) {
      // A place with no fixed desks (a cafe, a home) can be sized from its
      // spaces alone. Anywhere people sit at workstations needs the headcount
      // first: a school with "4 classrooms" and no students is answered by
      // the assistant's question, not by an invented PC count.
      final places = const [OrgKind.guest, OrgKind.home];
      if (org == null || !places.contains(org) || spaceMatch == null) {
        return null;
      }
    }
    return _plan(
      lower: lower,
      people: peopleMatch == null ? 0 : int.parse(peopleMatch.group(1)!),
      peopleWord: (peopleMatch?.group(2) ?? '').toLowerCase(),
      zones: spaceMatch == null ? 1 : int.parse(spaceMatch.group(1)!),
      zoneWord: (spaceMatch?.group(2) ?? 'floor').toLowerCase(),
      org: org,
      original: bridged,
    );
  }

  /// The rewrite for a brief, or the brief itself when it is not one.
  ///
  /// The chat's follow-up merge re-reads the original request together with a
  /// new sentence; expanding the original the same deterministic way keeps
  /// the sized topology (VLANs, APs, edge) through that re-read instead of
  /// collapsing it back to the words that were typed.
  static String expandBrief(String bridged) =>
      forBrief(bridged)?.expandedBrief ?? bridged;

  static OrgKind? _org(String lower) {
    for (final entry in _orgWords.entries) {
      for (final word in entry.value) {
        if (_has(lower, word)) return entry.key;
      }
    }
    return null;
  }

  // --- the rules ----------------------------------------------------------

  static SizingPlan _plan({
    required String lower,
    required int people,
    required String peopleWord,
    required int zones,
    required String zoneWord,
    required OrgKind? org,
    required String original,
  }) {
    // People without a place kind are a company: that is the brief the whole
    // pack is shaped around ("10 employees ... build the network").
    final kind = org ?? OrgKind.office;
    final guestFacing = _guestPeople.hasMatch(peopleWord);
    final wifi = !_noWifi.hasMatch(lower);
    final edge = !_noEdge.hasMatch(lower);
    final flat = _flat.hasMatch(lower);

    final peopleCount = people.clamp(1, 400);
    final zonesCount = zones.clamp(1, 40);

    // --- services the brief named, plus the ones this kind of site needs.
    final named = <String>{};
    void service(String word, String role) {
      if (_has(lower, word)) named.add(role);
    }

    service('dhcp', 'dhcp');
    service('dns', 'dns');
    service('http', 'http');
    service('https', 'http');
    service('web server', 'http');
    service('email', 'email');
    service('mail', 'email');
    service('ftp', 'ftp');
    service('file server', 'ftp');
    service('ntp', 'ntp');
    service('tftp', 'tftp');
    service('syslog', 'syslog');
    service('aaa', 'aaa');
    service('radius', 'aaa');
    service('tacacs', 'aaa');

    final services = <String>{
      ...switch (kind) {
        OrgKind.office || OrgKind.clinic || OrgKind.industrial => ['dhcp', 'dns'],
        OrgKind.school => ['dhcp', 'dns', 'http'],
        _ => const <String>[],
      },
      ...named,
    };
    if (guestFacing && named.isEmpty) services.clear();

    // --- workstations: one per person, unless the people are guests.
    final pcs = guestFacing ? 0 : peopleCount;

    // --- wireless: one AP per zone, raised when the density says more. A
    //     guest-facing brief (cafe, hotel) has no wired desks at all, so its
    //     zone count alone sizes the wireless.
    final density = (peopleCount / 25).ceil();
    final aps = wifi ? (density > zonesCount ? density : zonesCount) : 0;

    final phones = _voice.hasMatch(lower) ? zonesCount : 0;
    final printers = _printer.hasMatch(lower) ? 1 : 0;

    // --- switched ports: every wired endpoint, a 20% spare margin, and one
    //     uplink per switch, packed 22 per 24-port access switch. At least
    //     one switch per zone, so "two floors" is always two access switches.
    final wired = pcs + aps + phones + printers + (services.isEmpty ? 0 : 1);
    final ports = (wired * 1.2).ceil() + zonesCount;
    final byPorts = (ports / 22).ceil();
    final switches = byPorts > zonesCount ? byPorts : zonesCount;

    final servers = services.isEmpty ? 0 : 1;
    final firewalls =
        edge && kind != OrgKind.home && kind != OrgKind.guest ? 1 : 0;
    final clouds = edge ? 1 : 0;

    // --- VLANs: staff and guest separated whenever there is both a wired
    //     LAN and wifi to keep off it.
    final guestSafe = !guestFacing &&
        wifi &&
        !flat &&
        pcs > 0 &&
        kind != OrgKind.home;
    final vlans = guestSafe ? <int>[10, 20] : <int>[];

    // --- the reasons, in the user's own terms.
    final reasons = <String>[];
    void reason(String s) => reasons.add(s);
    String many(int n, String one, String plural) =>
        '$n ${n == 1 ? one : plural}';

    if (!guestFacing) {
      reason(
        '${many(peopleCount, peopleWord, peopleWord)} '
        '→ ${many(pcs, 'workstation', 'workstations')} (one per desk).',
      );
    } else {
      reason(
        '${many(peopleCount, peopleWord, peopleWord)} bring their own '
        'devices → the wireless network is sized for them, and no fixed PCs '
        'are assumed.',
      );
    }
    reason(
      '${many(zonesCount, zoneWord, '${zoneWord}s')} → '
      '${many(switches, 'access switch', 'access switches')} (24-port, '
      'one per zone) with a 20% spare-port margin for printers, phones and '
      'future desks.',
    );
    if (aps > 0) {
      reason(
        'Wifi: ${many(aps, 'access point', 'access points')} - one per '
        'zone${(peopleCount / 25).ceil() > zonesCount ? ', plus one for the density the headcount implies' : ''}.',
      );
    }
    // One L3 boundary is always planned (see below: routers is always 1).
    reason(
      'One L3 boundary (R1): inter-zone and inter-VLAN routing, and the '
      'default gateway every device points at.',
    );
    if (vlans.isNotEmpty) {
      reason(
        'Staff and guest are separate VLANs - staff PCs and servers in '
        'VLAN 10, the access points in VLAN 20 - so guest wi-fi never sits '
        'on the staff subnet.',
      );
    }
    if (servers > 0) {
      reason(
        'SRV1 runs ${services.map((s) => s.toUpperCase()).join(' + ')} so '
        'clients get addresses, names and services without the router doing '
        'that work.',
      );
    }
    if (firewalls > 0 || clouds > 0) {
      reason(
        'A firewall and an ISP cloud at the edge: internet access with the '
        'LAN kept behind the ASA.',
      );
    }

    // --- assumptions: everything assumed, said out loud.
    final assumptions = <String>[
      'No device counts were given, so this BOM was sized from the request; '
          'name any count by hand ("10 pcs", "3 switches") to pin it.',
      'Models, cabling and addressing are the planner\'s deterministic '
          'defaults (first-fit Packet Tracer models; VLAN 10 in '
          '192.168.10.0/24 and VLAN 20 in 192.168.20.0/24).',
      if (wifi && !_wifiWanted.hasMatch(lower))
        'Wifi was not mentioned explicitly, so one access point per zone is '
            'planned; say "wired only" to drop the wireless.',
      if (firewalls > 0 || clouds > 0)
        'Internet access is assumed (firewall + ISP cloud); say "standalone" '
            'to drop the edge.',
      if (servers > 0 && services.length > 1)
        'One server carries all roles (${services.join(', ')}); say "another '
            'server" to split them.',
    ];

    // --- the questions worth asking before a build.
    final questions = <String>[
      if (servers > 0)
        'Should staff logins be centralised on an AAA server, or stay local '
            'on the devices?',
      if (servers > 0)
        'Is a file server (FTP) wanted on the LAN, or are DHCP and DNS '
            'enough?',
      if (vlans.isNotEmpty)
        'Should guests be blocked from the staff VLAN by an ACL?',
      if (servers == 0 && aps > 0)
        'Do guests need only internet, or local services (a captive portal '
            'or a printer) as well?',
    ].take(3).toList();

    final expanded = _expanded(
      routers: 1,
      switches: switches,
      pcs: pcs,
      servers: servers,
      aps: aps,
      phones: phones,
      printers: printers,
      firewalls: firewalls,
      clouds: clouds,
      services: services.toList(),
      vlans: vlans,
      pcsIn: vlans.isNotEmpty ? 10 : 0,
      serversIn: vlans.isNotEmpty ? 10 : 0,
      apsIn: vlans.isNotEmpty ? 20 : 0,
      apOnSwitch: aps > 0 && aps <= switches,
      original: original,
    );

    final coverage = 0.55 +
        (people > 0 ? 0.1 : 0) +
        (zones > 1 ? 0.05 : 0) +
        (org != null ? 0.05 : 0) +
        (named.isNotEmpty ? 0.05 : 0);

    return SizingPlan(
      org: kind,
      people: people,
      peopleWord: peopleWord,
      zones: zonesCount,
      zoneWord: zoneWord,
      routers: 1,
      switches: switches,
      pcs: pcs,
      accessPoints: aps,
      servers: servers,
      firewalls: firewalls,
      clouds: clouds,
      phones: phones,
      printers: printers,
      serverServices: services.toList(),
      vlans: vlans,
      reasons: reasons,
      assumptions: assumptions,
      questions: questions,
      expandedBrief: expanded,
      confidence: coverage > 0.85 ? 0.85 : coverage,
    );
  }

  /// The device-list rewrite the parser reads. Kept in one place so the counts
  /// the BOM shows and the counts the planner builds can never drift.
  static String _expanded({
    required int routers,
    required int switches,
    required int pcs,
    required int servers,
    required int aps,
    required int phones,
    required int printers,
    required int firewalls,
    required int clouds,
    required List<String> services,
    required List<int> vlans,
    required int pcsIn,
    required int serversIn,
    required int apsIn,
    required bool apOnSwitch,
    required String original,
  }) {
    String many(int n, String one, String plural) =>
        '$n ${n == 1 ? one : plural}';
    final parts = <String>[
      many(routers, 'router', 'routers'),
      if (switches > 0) many(switches, 'switch', 'switches'),
      if (pcs > 0) '$pcs pcs',
      if (servers > 0) many(servers, 'server', 'servers'),
      if (aps > 0) many(aps, 'access point', 'access points'),
      if (phones > 0) many(phones, 'ip phone', 'ip phones'),
      if (printers > 0) many(printers, 'printer', 'printers'),
      if (firewalls > 0) many(firewalls, 'firewall', 'firewalls'),
      if (clouds > 0) many(clouds, 'cloud', 'clouds'),
      if (servers > 0 && services.isNotEmpty)
        'server with ${services.join(' and ')}',
      if (vlans.isNotEmpty) 'vlans ${vlans.join(' and ')}',
      if (pcsIn > 0 && pcs > 0) 'pcs in vlan $pcsIn',
      if (serversIn > 0 && servers > 0) 'servers in vlan $serversIn',
      if (apsIn > 0 && aps > 0) 'access points in vlan $apsIn',
      if (apOnSwitch)
        for (var i = 1; i <= aps; i++) 'AP$i to SW$i f0/20',
      // The user's own words stay in the brief: they carry the routing,
      // security and service wording the sizing layer deliberately does not
      // interpret, and the parser reads the counts above first.
      original,
    ];
    return parts.join(' ');
  }
}
