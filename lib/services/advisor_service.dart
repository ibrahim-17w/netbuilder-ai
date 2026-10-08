import '../models/environment_profile.dart';
import '../models/network_intent.dart';

/// A deterministic advisor for the questions the builder never answers:
/// which gear to use, how much of it, which of two designs fits, and how a
/// real deployment differs from the lab.
///
/// The contract, the same one the model prompt is given (see
/// `ChatService.systemContext`):
///
/// * a recommendation FIRST, then 2-4 options, each with "choose this when"
///   and its trade-off;
/// * the reasons are grounded in what the user said and in the plan on the
///   table - the lab answer first, the real-world equivalent next, because a
///   user with a Packet Tracer lab asks "what router should I use" about the
///   lab as often as about the office;
/// * at most two questions, and only ones whose answer changes the
///   recommendation;
/// * no prices, no made-up part numbers or availability - gear is named as
///   examples, in classes (home all-in-one, business firewall, L2/L3 switch);
/// * ADVICE NEVER CHANGES THE PLAN. Nothing here mutates a device, and the
///   only "next step" that touches the plan is a sentence the user can tap,
///   which the planner then treats like any other request.
///
/// The configuration knowledge - IOS steps, verification commands, fault
/// ladders - stays in [OfflineKnowledge]; this service owns the design
/// judgement the knowledge table did not have.
class AdvisorService {
  const AdvisorService._();

  /// The advisory answer for [text], or null when the message is not an
  /// advisory turn. Callers keep their existing routing when this returns
  /// null: a how-to question is still answered by the concept/knowledge
  /// paths, and a build request still goes to the planner.
  static AdviceAnswer? advise(
    String text, {
    NetworkIntent? plan,
    String target = 'packet-tracer',
    // The remembered environment (see [EnvironmentProfile]). The message is
    // still the authority: a fact it states wins, and the profile only fills
    // in what the message leaves unsaid - so "how many APs for 40 users?"
    // answered in the office the profile remembers sizes for 40, not for the
    // profile's stale number.
    EnvironmentProfile? environmentProfile,
  }) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    // A stated device count is a build request - but only when the sentence
    // asks to build. "Recommend 2 routers and 4 pcs" plans; "what switch do
    // I need for 30 PCs?" is a sizing question whose subject is counted.
    if (_deviceCount.hasMatch(t) &&
        (!_questionShaped(t) || _buildVerb.hasMatch(t))) {
      return null;
    }
    final kind = AdviceIntentReader.read(t);
    if (kind == AdviceKind.none) return null;
    final ctx = _AdvisorContext(
      t: t,
      plan: plan,
      target: target,
      kind: kind,
      profile: environmentProfile,
    );
    for (final topic in _topics) {
      if (topic.match(ctx)) {
        return topic.answer(ctx).withBasis(_basisFor(ctx));
      }
    }
    // Advice was asked for, but no specific topic matched: the design
    // review is the honest answer ("what do you recommend?" with no object
    // named). Selection/comparison phrasings without a topic return null so
    // the concept and knowledge answers keep owning protocol questions.
    if (ctx.kind == AdviceKind.review ||
        ctx.kind == AdviceKind.troubleshoot ||
        _generalAdviceWords.hasMatch(t)) {
      return _designReview(ctx).withBasis(_basisFor(ctx));
    }
    return null;
  }

  /// Where an answer stands on - the provenance line every advice answer
  /// ends with, so the user can tell a lab recommendation from a real-world
  /// one and knows the gear names are examples rather than stock or prices.
  static String _basisFor(_AdvisorContext c) {
    if (c.hasPlan) {
      return 'the lab on the table (${c.labLine()}) and how those Packet '
          'Tracer/GNS3 devices behave.';
    }
    // A model-number ask is about the simulators' own catalogs, not about a
    // purchase: the honest provenance is the device list those tools ship
    // with, plus the datasheet caveat for anything a real buy hangs on.
    if (_namedModels(c.t).isNotEmpty) {
      return 'the device catalogs Packet Tracer/GNS3 ship with; the model '
          "details here are the simulator's, so check current datasheets "
          'before a real purchase.';
    }
    if (c.lab) {
      return 'the way Packet Tracer/GNS3 behave; the models named are the '
          'ones those tools ship with.';
    }
    return 'what you told me about your site. The gear is named as examples '
        '- I do not track prices or stock, so check current prices and what '
        'your local suppliers or ISP offer before buying.';
  }

  // --- talking points -------------------------------------------------------

  static final RegExp _deviceCount = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
    r'printers?|phones?|firewalls?|tablets?|access\s+points?|aps?)\b',
  );

  /// Verbs that make a sentence a request TO build rather than a question
  /// about what to build. A count beside one of these is a specification.
  static final RegExp _buildVerb = RegExp(
    r'\b(?:build|make|create|design|set ?up|setup|add|deploy|produce|'
    r'generate|compile)\b',
  );

  static bool _questionShaped(String t) =>
      t.endsWith('?') ||
      RegExp(
        r'^(?:what|which|how|why|who|when|where|should|could|would|is|are|'
        r'do|does|can)\b',
      ).hasMatch(t);

  /// The phrasings that mean "tell me what YOU would do" even when no topic
  /// matched, so the design review is a real answer rather than a dead end.
  static final RegExp _generalAdviceWords = RegExp(
    r'\b(?:recommend|advice|suggest|your opinion|'
    r'what would you (?:do|use|pick|choose)|best approach|best practices?|'
    r'pros and cons)\b',
  );

  /// Every topic, most specific first. A match must be precise enough that a
  /// configuration question or a build request can never land here.
  static final List<
    ({
      bool Function(_AdvisorContext) match,
      AdviceAnswer Function(_AdvisorContext) answer,
    })
  >
  _topics = [
    (
      match: (c) =>
          c.kind == AdviceKind.troubleshoot ||
          (c.mentionsAny(const ['slow', 'dead spot', 'dropping', 'buffering']) &&
              c.mentionsAny(const ['wifi', 'wi-fi', 'wireless', 'internet'])),
      answer: _slowWifi,
    ),
    (
      // Two or more named lab models are the most specific signal a message
      // can carry - a model number beats every topic noun below - so the
      // model comparison outranks them all (except troubleshooting above).
      // "which is better, 2911 or 4331?" used to reach the lab topic and
      // get the generic answer that never compared the two.
      match: (c) =>
          c.kind != AdviceKind.review && _namedModels(c.t).length >= 2,
      answer: _modelComparison,
    ),
    (
      // Power and the cabinet come first: a UPS question that mentions the
      // router and modem is about power, not about the ISP handoff below.
      match: (c) =>
          c.words(const ['rack', 'ups']) ||
          c.mentionsAny(const [
            'patch panel',
            'cabinet',
            'structured cabling',
          ]),
      answer: _rackAndPower,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'pppoe',
            'cgnat',
            'static ip',
            'public ip',
            'double nat',
            'bridge mode',
            'isp ',
          ]) ||
          c.words(const ['isp', 'modem', 'ont']) ||
          c.mentionsAny(const ['from the isp', 'internet provider', 'fibre box']),
      answer: _ispEdge,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'firewall',
            'utm',
            'fortigate',
            'pfsense',
            'opnsense',
            'sonicwall',
            'security appliance',
          ]),
      answer: _firewallSelection,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'cameras',
            'camera',
            'cctv',
            'nvr',
            'ip camera',
          ]) ||
          (c.mentions('poe') && c.mentionsAny(const ['camera', 'nvr'])),
      answer: _cameraNetwork,
    ),
    (
      match: (c) =>
          c.mentions('poe') ||
          c.mentionsAny(const ['power over ethernet', 'poe budget', 'poe switch']),
      answer: _poeBudget,
    ),
    // Wireless-generation questions before the general AP topic, so "is
    // wifi 6 worth it?" is answered by the generation comparison.
    (
      match: (c) =>
          c.mentionsAny(const [
            'wifi 5',
            'wifi 6',
            'wifi 7',
            'wi-fi 5',
            'wi-fi 6',
            'wi-fi 7',
            '802.11',
            'ax ',
            'ac ',
          ]),
      answer: _wifiStandards,
    ),
    (
      match: (c) =>
          c.kind == AdviceKind.comparison &&
          c.mentions('router') &&
          c.words(const ['switch', 'switches']),
      answer: _routerVsSwitch,
    ),
    (
      match: (c) =>
          c.words(const ['router', 'routers', 'gateway', 'modem']) ||
          c.mentions('wifi router') ||
          c.mentions('wireless router'),
      answer: _routerSelection,
    ),
    (
      // A cable question that names a switch ("what cable do I use between
      // two switches") belongs to the cabling knowledge answer, not to
      // switch selection.
      match: (c) =>
          c.words(const ['switch', 'switches']) &&
          !c.words(const ['cable', 'cables', 'cabling', 'copper', 'fiber', 'fibre']),
      answer: _switchSelection,
    ),
    (
      // Wireless itself, unless the question is really about a different
      // box that happens to have Wi-Fi (a router, firewall or switch).
      match: (c) =>
          c.mentionsAny(const ['access point', 'access points', 'mesh']) ||
          (c.words(const ['ap', 'aps', 'wifi', 'wi-fi', 'wireless', 'ssid']) &&
              !c.words(const [
                'router',
                'routers',
                'modem',
                'gateway',
                'firewall',
                'switch',
                'switches',
              ])),
      answer: _apSelection,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'guest wifi',
            'guest wi-fi',
            'guest network',
            'captive portal',
            'visitor',
            'customers use',
          ]) ||
          c.words(const ['guest', 'guests', 'visitor', 'visitors']),
      answer: _guestWifi,
    ),
    (
      // "Should X be on its own VLAN?" - segmentation by trust level. Below
      // the guest topic (a guest question gets the guest answer) and above
      // the routing-shape topic.
      match: (c) =>
          c.words(const ['vlan', 'vlans', 'subnet', 'subnets']) &&
          (c.kind == AdviceKind.recommendation || c.kind == AdviceKind.review),
      answer: _segmentation,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'port forward',
            'port forwarding',
            'dmz',
            'remote access',
            'expose',
            'from outside',
            'outside the office',
          ]),
      answer: _remoteAccess,
    ),
    (
      match: (c) => c.words(const ['vpn', 'vpns']),
      answer: _vpnTypes,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'fiber',
            'fibre',
            'copper',
            'cat5',
            'cat 5',
            'cat6',
            'cat 6',
            'cat6a',
            'distance',
            'long run',
            'between buildings',
            '100 m',
            '100m',
            'meters',
            'metres',
          ]),
      answer: _cabling,
    ),
    (
      match: (c) =>
          (c.words(const ['l3', 'layer 3']) && c.words(const ['switch'])) ||
          c.mentionsAny(const ['inter-vlan', 'inter vlan', 'router-on-a-stick']),
      answer: _l3Switch,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'failover',
            'second isp',
            'second internet',
            'second line',
            'second provider',
            'backup internet',
            'backup line',
            'two lines',
            'redundan',
            'uptime',
            'two isps',
            'dual wan',
          ]),
      answer: _backupWan,
    ),
    (
      match: (c) =>
          c.mentionsAny(const [
            'server',
            'dhcp',
            'dns',
            'file share',
            'nas',
          ]) &&
          (c.kind == AdviceKind.recommendation || c.kind == AdviceKind.review),
      answer: _serverPlacement,
    ),
    (
      // One named model with no other topic claiming the question ("is a
      // 2911 enough for my lab?") routes to the same comparison machinery,
      // with the model's siblings as the other options. Topic-specific
      // asks - VLANs, PoE, VPN, cabling - matched above keep their own
      // answers, and a review still reviews.
      match: (c) =>
          c.kind != AdviceKind.review && _namedModels(c.t).length == 1,
      answer: _modelComparison,
    ),
    // Lab-model questions: which Cisco device to place in Packet Tracer or
    // GNS3. Guarded to the tools/lab/Cisco-model vocabulary, and never a
    // review (a design review belongs to the design topic below).
    (
      match: (c) =>
          c.kind != AdviceKind.review &&
          (c.mentionsAny(const ['packet tracer', 'gns3']) ||
              c.words(const ['lab', 'labs']) ||
              c.mentionsAny(const [
                '2960',
                '3560',
                '2911',
                '4331',
                'isr',
                'catalyst',
              ])),
      answer: _labModels,
    ),
    // Generic sizing last among the topics, so a named subject (access
    // points, ports, PoE) is measured by its own topic and everything else
    // - bandwidth, capacity, "enough for" - gets the sizing rules.
    (
      match: (c) => c.kind == AdviceKind.sizing,
      answer: _sizing,
    ),
  ];

  // --- topics ---------------------------------------------------------------

  /// The lab-first lead. When a plan is on the table, "which should I
  /// use?" is at least partly about THAT lab, so the lab answer comes
  /// first and the real-world recommendation follows in the same breath.
  static String _labFirst(_AdvisorContext c, String realWorld) =>
      c.hasPlan
          ? 'For the lab on the table (${c.labLine()}), the models are the '
              'ones Packet Tracer ships - there the choice is the feature '
              'the lab grades, not the brand. For the real hardware behind '
              'your question: $realWorld'
          : realWorld;

  static AdviceAnswer _routerSelection(_AdvisorContext c) {
    final home = c.venue == _Venue.home;
    final office = c.venue == _Venue.office ||
        c.venue == _Venue.school ||
        c.venue == _Venue.clinic ||
        c.venue == _Venue.hospitality ||
        c.venue == _Venue.industrial;
    final rec = _labFirst(
      c,
      home
          ? 'For a home, one all-in-one Wi-Fi router is the right answer: it '
              'does routing, Wi-Fi and a few LAN ports in one box, and it is '
              'the least gear to buy, power and keep updated. Put it as '
              'central as the building allows, not in a metal cabinet or on '
              'the floor.'
          : office
          ? 'For an office, split the jobs. Let a business router or '
                'firewall at the edge own the WAN, DHCP/DNS and the firewall '
                'policy, then let a PoE switch and wired access points own '
                'the building. All-in-one boxes work up to roughly 20-30 '
                'devices, then their Wi-Fi and NAT table become the '
                'bottleneck.'
          : 'It depends on how it is used. For a home or a single flat an '
                'all-in-one Wi-Fi router is enough; for a business - say '
                'more than 20 devices, guests, or anything that must stay '
                'up - separate the edge router/firewall from the Wi-Fi, '
                'with a PoE switch and wired access points.',
    );
    return AdviceAnswer(
      topic: 'router_selection',
      kind: c.kind,
      recommendation: rec,
      options: const [
        AdviceOption(
          label: 'All-in-one Wi-Fi router (home class)',
          chooseWhen: 'a home or small flat, up to ~20-30 devices, one '
              'location',
          tradeOff: 'Wi-Fi and NAT weaken under load, and features like VLANs '
              'or guest isolation are limited or absent',
        ),
        AdviceOption(
          label: 'Business router / firewall at the edge',
          chooseWhen: 'an office, guests, VLANs, site-to-site VPN, or a '
              'connection that must stay up',
          tradeOff: 'more boxes and a little configuration; you need to keep '
              'the firmware updated',
        ),
        AdviceOption(
          label: 'ISP-supplied router left in place',
          chooseWhen: 'the budget is fixed and the ISP device already does '
              'what you need',
          tradeOff: 'often weak Wi-Fi and closed firmware; you may not be '
              'able to bridge it or run the features you want later',
        ),
      ],
      reasons: [
        'Pick the router from the WAN side first: what the ISP hands you '
            '(Ethernet/DHCP, PPPoE credentials, or a modem) decides which '
            'devices can even terminate the connection.',
        'Next comes NAT/firewall throughput, then Wi-Fi. Marketing Wi-Fi '
            'speed is never the bottleneck for a small office - NAT and the '
            'WAN plan are.',
        if (c.scale != null)
          'You mentioned about ${c.scale} users/devices: past ~30 concurrent '
              'devices, plan an edge router plus a switch and access points '
              'instead of one all-in-one.',
        if (c.hasPlan)
          'For the lab on the table (${c.labLine()}) the Packet Tracer '
              'devices that match are the 2911/4331 routers (or a Wireless '
              'Router-PT when you want the all-in-one shape).',
      ],
      questions: [
        if (!home && !office) 'Is this for a home or for a business/office?',
        if (c.scale == null && office)
          'Roughly how many people and devices will be online at once?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        if (!home && !office) 'What router should I get for a home?',
        if (!office) 'What router should I get for an office with 20 employees?',
        if (office) 'What firewall do we need for an office with guests?',
        if (office) 'How many access points do I need for 40 users?',
      ],
      nextStep: home
          ? 'Say how many rooms and floors it must cover and I will tell you '
              'whether one router is enough or you need mesh/access points.'
          : 'Tell me the number of users and whether Wi-Fi must cover one '
              'floor or several, and I will size the edge and the access '
              'points.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _firewallSelection(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'firewall_selection',
      kind: c.kind,
      recommendation: _labFirst(
          c,
          'Use a real firewall when you need to ENFORCE policy, not just '
          'share the internet: rules between VLANs, logging, VPN '
          'termination and updates. For a home or a tiny office the '
          'router\'s own ACL/NAT is usually enough; from an office '
          'upward, a dedicated firewall pays for itself the first time a '
          'camera or a guest device is compromised.'),
      options: const [
        AdviceOption(
          label: 'SMB firewall appliance / UTM',
          chooseWhen: 'an office with guests, VLANs, VPN or compliance needs '
              '(examples: FortiGate 40F/60F, Sophos, SonicWall, or pfSense/'
              'OPNsense on a small PC)',
          tradeOff: 'subscriptions for filtering/threat feeds and a learning '
              'curve; inspected traffic lowers throughput',
        ),
        AdviceOption(
          label: 'Router with ACLs / zone-based firewall',
          chooseWhen: 'budget is tight and the policy is simple (block '
              'guest-to-staff, allow a few services)',
          tradeOff: 'no threat inspection, no easy logging; you maintain '
              'every rule yourself',
        ),
        AdviceOption(
          label: 'Cloud-managed gateway',
          chooseWhen: 'several small sites and you want one dashboard '
              '(examples: UniFi, Omada, Meraki Go)',
          tradeOff: 'you depend on the vendor cloud, and advanced policy '
              'lives behind their UI',
        ),
      ],
      reasons: [
        'The firewall question is really "what must be separated?" - guest '
            'from staff, cameras from users, one site from another. A '
            'firewall that only does NAT adds cost without changing that.',
        'Plan the WAN throughput you are paying for: an entry appliance with '
            'inspection on is usually good for a few hundred Mbit/s, not a '
            'full gigabit.',
        if (c.hasPlan && c.plan!.security.requested)
          'The lab on the table already asks for security controls, so put '
              'the ACL/zone policy ON the router in the plan rather than '
              'assuming a separate appliance.',
        if (c.hasPlan)
          'Packet Tracer ships an ASA 5505/5506 firewall, but ASA is not IOS '
              '- this app deliberately does not auto-configure it. Plan the '
              'policy on the router, or add the ASA by hand.',
      ],
      questions: const [
        'Is the goal to protect the office from the internet, or to separate '
            'groups inside it (guests, cameras, staff)?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        'Plan a small office with a firewall, guest wifi and staff VLANs',
      ],
      nextStep: 'Tell me what must be kept apart and I will turn it into '
          'VLANS/ACLs in the plan - or name the appliance and I will say what '
          'it can and cannot do.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _routerVsSwitch(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'router_vs_switch',
      kind: c.kind,
      recommendation: 'A switch connects devices inside one network; a router '
          'connects different networks and is what talks to the internet. '
          'A home needs both in one box; an office usually needs a router at '
          'the edge and switches for the desks - and if you have VLANs, '
          'either a router with subinterfaces or one layer-3 switch.',
      options: const [
        AdviceOption(
          label: 'Router for the edge, switches inside',
          chooseWhen: 'a normal office or lab: internet, NAT, VPN and '
              'inter-VLAN routing at the router',
          tradeOff: 'all inter-VLAN traffic passes the router\'s uplink, so a '
              'fast-growing LAN can bottleneck there',
        ),
        AdviceOption(
          label: 'Layer-3 switch for the core',
          chooseWhen: 'many VLANs or server-to-server traffic that should not '
              'make the trip to the edge',
          tradeOff: 'can cost more than an L2 switch and needs routing '
              'configured on the switch too',
        ),
        AdviceOption(
          label: 'Router-on-a-stick (subinterfaces)',
          chooseWhen: 'a small lab or office with a couple of VLANs and one '
              'router',
          tradeOff: 'single physical link carries every VLAN - fine for '
              'practice and small sites, not for heavy traffic',
        ),
      ],
      reasons: [
        'Layer 2 (switching) decides who can reach whom on the same subnet; '
            'layer 3 (routing) decides how subnets reach each other. VLANs '
            'are how one switch keeps those subnets apart.',
        if (c.hasPlan)
          'Your plan has ${c.count('router')} router(s) and '
              '${c.count('switch')} switch(es): in Packet Tracer, '
              'router-on-a-stick is a 2911/4331 plus a 2960, and inter-VLAN '
              'routing on the switch itself needs a 3560 (or another L3 '
              'switch).',
      ],
      questions: const [
        'How many VLANs/subnets do you expect to route between?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        'Plan 2 routers, 1 switch and 2 VLANs',
      ],
      nextStep: 'Say how many VLANs you need and I will plan the routing '
          'shape (router-on-a-stick or L3 switch) into the lab.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _switchSelection(_AdvisorContext c) {
    final devices = c.scale;
    final needsPoe = c.mentions('poe') ||
        c.mentionsAny(const ['access point', 'camera', 'phone']);
    return AdviceAnswer(
      topic: 'switch_selection',
      kind: c.kind,
      recommendation: _labFirst(
          c,
          needsPoe
              ? 'Buy a managed PoE switch: PoE powers access points, '
                  'cameras and phones from the switch, and "managed" is '
                  'what gives you VLANs, port security and per-port '
                  'diagnosis later. An unmanaged switch is only for a '
                  'home or a single room where none of that is wanted.'
              : 'Buy a managed switch, even if you only use it as '
                  'unmanaged today: VLANs, port security and a second '
                  'SSID for guests all need it, and the price difference '
                  'is small. Choose the port count from the devices plus '
                  'uplinks plus spare.'),
      options: const [
        AdviceOption(
          label: 'Unmanaged switch',
          chooseWhen: 'a home, or a small add-on for meeting-room ports',
          tradeOff: 'no VLANs, no port security, no monitoring - a loop or a '
              'bad cable takes down everything on it',
        ),
        AdviceOption(
          label: 'L2 managed PoE switch',
          chooseWhen: 'an office: desk ports, PoE access points, VLANs, port '
              'security (examples: Cisco CBS350, UniFi Switch, Omada, '
              'MikroTik CRS)',
          tradeOff: 'needs configuration, and PoE budget must be counted '
              'against the devices it powers',
        ),
        AdviceOption(
          label: 'L3 managed switch (core)',
          chooseWhen: 'several VLANs or servers that should route at wire '
              'speed without going through the router',
          tradeOff: 'more expensive and more advanced to configure; '
              'inter-VLAN ACLs have to be planned too',
        ),
      ],
      reasons: [
        if (devices != null)
          'About $devices wired endpoints: a 24-port switch covers roughly '
              '15-18 devices once uplinks and spare ports are counted, so '
              'plan the 48-port model past that.',
        'Port count rule: devices + uplinks + 20% spare. Two 24-port '
            'switches beat a single 48-port when they are in different '
            'rooms, and never chain more than two hops of access switches.',
        if (c.hasPlan)
          'In the lab, the 2960-24TT is the L2 switch and the 3560-24PS is '
              'the L3/PoE one - the plan already reads ${c.labLine()}.',
      ],
      questions: [
        if (devices == null) 'Roughly how many wired devices will there be?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        'How many ports do I need for 30 devices?',
      ],
      nextStep: 'Count the wired devices (PCs, printers, APs, cameras) and '
          'add uplinks plus spare - tell me the number and I will size the '
          'switch.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _apSelection(_AdvisorContext c) {
    final scale = c.scale;
    final aps = scale == null ? null : (scale / 25).ceil().clamp(1, 64);
    return AdviceAnswer(
      topic: 'ap_selection',
      kind: c.kind,
      recommendation: 'For anything larger than a flat, wired access points '
          'beat mesh: a mesh node spends half its radio repeating the '
          'signal, while a wired AP uses both radios for clients. If a cable '
          'cannot be run, mesh is the honest fallback - but run the cable if '
          'you possibly can, it is cheap once the wall is open.',
      options: const [
        AdviceOption(
          label: 'One all-in-one router',
          chooseWhen: 'a small flat or one floor under ~80-100 m2 with no '
              'thick walls',
          tradeOff: 'dead spots at the edges and no roaming to speak of',
        ),
        AdviceOption(
          label: 'Wired ceiling APs + PoE switch',
          chooseWhen: 'an office, multi-floor home, or any space with more '
              'than ~30 devices (examples: UniFi U6/U7, Omada EAP, Aruba '
              'Instant On)',
          tradeOff: 'needs cabling to each AP and a controller/app for '
              'management; roaming still depends on good coverage overlap',
        ),
        AdviceOption(
          label: 'Mesh kit (wireless backhaul)',
          chooseWhen: 'rented space, historic walls, or no way to run cable',
          tradeOff: 'each hop loses roughly half the throughput, and latency '
              'rises - fine for browsing, poor for many video calls',
        ),
      ],
      reasons: [
        if (aps != null)
          'About $scale active devices: at the dense end (one AP per ~25 '
              'devices) that is $aps AP(s); for lighter use assume ~50 per '
              'AP. Then add APs for coverage - one per 2-4 rooms, or per '
              'floor in open plan.',
        'Wi-Fi is a shared medium: more APs on the same channel do not add '
            'capacity, they add interference. Place by coverage first, then '
            'tune channels.',
        'Two rules that prevent most complaints: wire every AP, and keep '
            '2.4 GHz on channels 1/6/11 only.',
        if (c.hasPlan)
          'The lab already has its wireless covered (${c.labLine()}); in '
              'Packet Tracer an Access Point-PT associates wirelessly, so no '
              'cable is drawn to the laptop.',
      ],
      questions: [
        if (aps == null) 'How many people/devices will be connected at once?',
        'Is the space one floor or several (and are the walls thick)?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        'How many access points do I need for 40 users?',
      ],
      nextStep: 'Give me the floor count and the busiest moment\'s device '
          'count and I will turn the AP plan into a topology you can build.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _wifiStandards(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'wifi_standards',
      kind: c.kind,
      recommendation: 'Wi-Fi 6 (802.11ax) is the sensible default today: it '
          'handles many devices per AP far better than Wi-Fi 5, and the '
          'price gap has closed. Wi-Fi 5 (ac) is still fine for light use '
          'and small budgets. Wi-Fi 7 (be) is future-proofing you only need '
          'if your clients and internet plan can already use it. One rule '
          'cuts through the whole 5-vs-6-vs-7 question: you cannot tell '
          'them apart by speed at home - pick by how many devices share the '
          'AP, and keep every AP on the same generation so the oldest '
          'client never drags the airtime down.',
      options: const [
        AdviceOption(
          label: 'Wi-Fi 5 (802.11ac)',
          chooseWhen: 'a small site, phones/laptops only, and the budget is '
              'tight',
          tradeOff: 'weaker under density; 2.4 GHz on old gear can drag the '
              'whole experience down',
        ),
        AdviceOption(
          label: 'Wi-Fi 6 / 6E (802.11ax)',
          chooseWhen: 'an office, school or any space with many devices per '
              'AP (the usual recommendation)',
          tradeOff: '6 GHz in 6E has shorter range and needs its own survey; '
              'benefits need Wi-Fi 6 clients to be felt fully',
        ),
        AdviceOption(
          label: 'Wi-Fi 7 (802.11be)',
          chooseWhen: 'new build with a fast plan, high-density spaces, and '
              'budget for matching clients',
          tradeOff: 'premium price for benefits most networks cannot yet '
              'measure',
        ),
      ],
      reasons: [
        'The generation matters most when many devices share one AP. If a '
            'single AP serves 5 clients, Wi-Fi 5 and Wi-Fi 6 feel the same; '
            'at 40 clients it is night and day.',
        'Never mix one old 2.4 GHz-only AP into an otherwise modern setup: '
            'clients cling to it and the whole floor suffers.',
        'Whatever you buy, the backhaul matters: a Wi-Fi 6 AP on a 100 Mbit '
            'uplink is a Wi-Fi 5 AP in practice.',
      ],
      quickReplies: const [
        'How many access points do I need for 40 users?',
        'Plan a small office with 2 access points and 1 PoE switch',
      ],
      nextStep: 'Tell me the device count and whether the space is dense '
          '(classroom, cafe) or sparse (offices), and I will pick the tier.',
    );
  }

  static AdviceAnswer _poeBudget(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'poe_budget',
      kind: c.kind,
      recommendation: 'Add up the PoE budget before choosing the switch: '
          'budget ~15 W per Wi-Fi 5 AP, ~25-30 W per Wi-Fi 6 AP, ~8-15 W per '
          'fixed camera and 25-60 W per PTZ camera, then add 20-30% headroom. '
          'Pick a switch whose total PoE budget is above that sum, not just '
          'one with PoE on every port.',
      options: const [
        AdviceOption(
          label: 'PoE switch',
          chooseWhen: '3 or more powered devices, or any ceiling device',
          tradeOff: 'costs more and its total budget - not the per-port '
              'standard - is the number that matters',
        ),
        AdviceOption(
          label: 'PoE injectors',
          chooseWhen: 'one or two devices on an existing non-PoE switch',
          tradeOff: 'a wall wart per device, no remote power-cycling, and '
              'easy to mis-cable',
        ),
        AdviceOption(
          label: 'PoE++ (802.3bt) for the heavy devices',
          chooseWhen: 'PTZ cameras, Wi-Fi 7 APs, or anything above ~30 W',
          tradeOff: 'premium switches, and heat in the rack goes up',
        ),
      ],
      reasons: [
        'The standards: 802.3af ~15.4 W, 802.3at ~30 W, 802.3bt 60-90 W. A '
            'device negotiates its class, but the switch total is a hard '
            'ceiling.',
        'Power budgeting is a wiring-closet decision: run the sum now and '
            'the switch does not have to be replaced when the second AP '
            'arrives.',
      ],
      quickReplies: const [
        'Plan a small office with 2 access points and PoE cameras',
      ],
      nextStep: 'List the powered devices (APs, cameras, phones) and I will '
          'total the budget for you.',
    );
  }

  static AdviceAnswer _cameraNetwork(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'camera_network',
      kind: c.kind,
      recommendation: 'Put cameras on their own VLAN, powered by a PoE '
          'switch that has the budget for them, recorded by an NVR on that '
          'same VLAN, and reach them remotely through a VPN - never by '
          'port-forwarding the NVR. Cameras are the most commonly attacked '
          'device on a small network, and almost none of them get security '
          'updates.',
      options: const [
        AdviceOption(
          label: 'NVR + cameras on a dedicated camera VLAN',
          chooseWhen: 'any real deployment - the usual answer',
          tradeOff: 'needs a VLAN and firewall rules (block camera-to-LAN, '
              'allow NVR), and a switch with the PoE budget',
        ),
        AdviceOption(
          label: 'Cameras on the general LAN',
          chooseWhen: 'a home with one or two cameras and no guests',
          tradeOff: 'one compromised camera can reach your PCs; noise and '
              'broadcast traffic share the network',
        ),
        AdviceOption(
          label: 'Cloud cameras',
          chooseWhen: 'no NVR wanted and recurring fees are acceptable',
          tradeOff: 'the video leaves your premises, and the uplink becomes '
              'the recording\'s bottleneck',
        ),
      ],
      reasons: [
        'The rule that matters: cameras can talk to the NVR and nothing '
            'else, the NVR can be reached by VPN only, and none of it is '
            'exposed to the internet.',
        if (c.hasPlan)
          'In the lab this is a VLAN plus ACL exercise (${c.labLine()}) - '
              'say the word and I plan the VLAN and the ACL.',
      ],
      quickReplies: const [
        'Plan a camera VLAN with an ACL to the NVR',
        'How many cameras can a PoE switch handle?',
      ],
      nextStep: 'Tell me how many cameras (and whether any are PTZ) and I '
          'will size the PoE switch and plan the VLAN.',
    );
  }

  static AdviceAnswer _ispEdge(_AdvisorContext c) {
    final pppoe = c.mentions('pppoe');
    final cgnat = c.mentions('cgnat');
    return AdviceAnswer(
      topic: 'isp_edge',
      kind: c.kind,
      recommendation: 'Terminate the ISP connection on your own router and '
          'put the ISP box into bridge/modem mode, so there is one NAT, one '
          'firewall and one place for rules. '
          '${pppoe ? 'With PPPoE, keep the credentials in your router\'s WAN settings (the ISP can read them out to you if you do not have them) and set MTU ~1492 if large transfers fail. ' : ''}'
          'If bridging is impossible, the middle ground is to set the ISP '
          'router to DMZ/forward-all to your router - double NAT is survivable '
          'that way, but two firewalls still means two places to look.',
      options: const [
        AdviceOption(
          label: 'Bridge the ISP box, dial/connect on your router',
          chooseWhen: 'the usual, best answer: PPPoE credentials or DHCP on '
              'your WAN port',
          tradeOff: 'needs the credentials or a modem-only mode from the ISP; '
              'support calls have to be repeated if they replace the box',
        ),
        AdviceOption(
          label: 'Keep the ISP router in router mode (double NAT)',
          chooseWhen: 'you cannot get bridge mode, and the network is simple',
          tradeOff: 'port forwarding must be done twice, VPNs and some games '
              'break, and there are two DHCP servers to keep straight',
        ),
        AdviceOption(
          label: 'ISP router in DMZ to your router',
          chooseWhen: 'bridge mode is unavailable but you still want your own '
              'firewall in charge',
          tradeOff: 'the ISP box still NATs, and its Wi-Fi (if used) sits '
              'outside your policy',
        ),
      ],
      reasons: [
        if (cgnat)
          'You mentioned CGNAT: check the WAN address your router gets. '
              '100.64.0.0/10, or an address that differs from what an '
              '"what is my IP" page shows, means you are behind the ISP\'s '
              'NAT - no inbound connections, whatever you configure. Ask for '
              'a public/static IP, or use a VPN/relay that dials out instead.',
        'Check the handoff type before buying anything: Ethernet from an ONT '
            '(DHCP or PPPoE), a coax modem, or an integrated box. The router '
            'must speak that WAN type.',
        'Test the line itself before blaming Wi-Fi: a wired speed test at '
            'the peak hour is the number that counts.',
      ],
      questions: const [
        'What does the ISP hand you - Ethernet, a modem, or one box that '
            'does everything?',
        'Do you need to reach anything inside the network from outside it?',
      ],
      quickReplies: const [
        'What router should I get for PPPoE with a fast fibre line?',
        'What should I use for remote access if I am behind CGNAT?',
      ],
      nextStep: 'Tell me the handoff and what must be reachable from '
          'outside, and I will lay out the WAN plan step by step.',
    );
  }

  static AdviceAnswer _guestWifi(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'guest_wifi',
      kind: c.kind,
      recommendation: 'Give guests their own SSID on their own VLAN, with '
          'client isolation ON, a bandwidth limit, and no route to the staff '
          'or camera networks. A guest network that only has a different '
          'password is still one flat network.',
      options: const [
        AdviceOption(
          label: 'Guest SSID + guest VLAN + isolation',
          chooseWhen: 'any office, clinic, cafe or shop with visitors - the '
              'default answer',
          tradeOff: 'needs managed APs/switches or a router that supports '
              'guest isolation',
        ),
        AdviceOption(
          label: 'Guest SSID only',
          chooseWhen: 'a home with visitors for an evening',
          tradeOff: 'guests are on your LAN: they can see printers, NAS and '
              'sometimes the router',
        ),
        AdviceOption(
          label: 'Captive portal with vouchers/terms',
          chooseWhen: 'public spaces where you must show terms or hand out '
              'codes',
          tradeOff: 'extra device/software and an onboarding step for '
              'guests; support calls go up',
        ),
      ],
      reasons: [
        'The #1 reason to isolate guests is not politeness, it is '
            'containment: an infected visitor laptop should not be able to '
            'touch the NVR or the file server.',
        'Bandwidth-limit guest traffic so one streamer does not starve the '
            'point-of-sale terminal.',
      ],
      questions: const [
        'Do guests need to reach anything on the staff network (a printer, '
            'a display)?',
      ],
      quickReplies: const [
        'Plan a small office with guest wifi and staff VLANs',
      ],
      nextStep: 'Say what guests must reach (usually nothing) and I will '
          'plan the guest VLAN and the ACL that separates it.',
    );
  }

  static AdviceAnswer _remoteAccess(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'remote_access',
      kind: c.kind,
      recommendation: 'Open a port only for one specific service, and use a '
          'VPN when you need to reach the network itself. Port forwarding '
          'publishes whatever is behind it to the whole internet; a VPN lets '
          'you in first, then everything else works as if you were on site. '
          'Avoid DMZ entirely unless the device behind it is hardened and '
          'expendable.',
      options: const [
        AdviceOption(
          label: 'VPN (WireGuard/OpenVPN/Tailscale-class)',
          chooseWhen: 'you need files, cameras, remote desktop or the NVR - '
              'the usual answer',
          tradeOff: 'a client to install and keys to manage; throughput '
              'depends on the router\'s CPU',
        ),
        AdviceOption(
          label: 'Port forward',
          chooseWhen: 'exactly one service (a web server, a game server) and '
              'you can keep it patched',
          tradeOff: 'exposed to scanning bots on day one; every service is '
              'its own risk, and double NAT breaks it',
        ),
        AdviceOption(
          label: 'A published cloud relay/tunnel',
          chooseWhen: 'CGNAT blocks inbound access, or you have no public IP',
          tradeOff: 'traffic passes a third party, and availability depends '
              'on their service',
        ),
      ],
      reasons: [
        if (c.mentions('dmz'))
          'DMZ is a "publish everything on this address" rule: it disables '
              'the protection for that host. If you must use it, make sure '
              'nothing else shares that host.',
        'Whichever way in, add lockout/2FA on the service itself. The '
            'internet finds open ports within hours.',
        if (c.hasPlan)
          'In the lab, expose services through the edge router with a static '
              'NAT and an ACL rather than opening the whole DMZ.',
      ],
      questions: const [
        'What exactly must be reachable from outside: a service, files, or '
            'the whole office LAN?',
      ],
      quickReplies: const [
        'What should I use for remote access if I am behind CGNAT?',
      ],
      nextStep: 'Name the service or the need and I will pick the safest of '
          'the three for it.',
    );
  }

  static AdviceAnswer _vpnTypes(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'vpn_types',
      kind: c.kind,
      recommendation: 'Two different jobs: site-to-site VPN joins two '
          'offices permanently (always-on, router-to-router), and '
          'remote-access VPN lets people in from home (client dials in). '
          'Most small networks need both eventually; pick by who initiates '
          'and whether humans are involved.',
      options: const [
        AdviceOption(
          label: 'Site-to-site (IPsec or WireGuard)',
          chooseWhen: 'two or more fixed sites that must act like one network',
          tradeOff: 'both ends need matching configuration; one side breaks '
              'and both lose the link',
        ),
        AdviceOption(
          label: 'Remote-access (OpenVPN/WireGuard/SSL VPN)',
          chooseWhen: 'staff work from home or travel',
          tradeOff: 'per-user accounts/keys; split-tunnel choices affect what '
              'can be reached',
        ),
        AdviceOption(
          label: 'Zero-trust/overlay (Tailscale-class)',
          chooseWhen: 'no public IP, CGNAT, or you want it working in minutes',
          tradeOff: 'control plane lives with the provider; not ideal for '
              'strict compliance',
        ),
      ],
      reasons: [
        'A site-to-site tunnel is a route plus a policy; a remote-access '
            'tunnel is an identity. Different failure modes, different '
            'support.',
        'Keep IPsec MSS in mind: tunnels break large packets if MSS is not '
            'clamped - the classic "ping works, login hangs".',
      ],
      quickReplies: const [
        'What should I use for a site-to-site VPN between two offices?',
      ],
      nextStep: 'Tell me whether you are joining offices or letting people '
          'dial in, and I will lay out the endpoints for each side.',
    );
  }

  static AdviceAnswer _cabling(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'cabling',
      kind: c.kind,
      recommendation: 'Copper (Cat5e/Cat6) is right for everything inside '
          'one building, up to 100 m per run. Use fiber for runs over 100 m, '
          'between buildings, or for a 10G backbone - and never run copper '
          'between two buildings over a long distance: ground potential '
          'differences can damage both ends.',
      options: const [
        AdviceOption(
          label: 'Cat6/Cat6a copper',
          chooseWhen: 'desk runs, APs, cameras - runs up to 100 m',
          tradeOff: 'thick conduit, and 10G needs Cat6a/short runs; cheap '
              'cable or bad crimps fail at gigabit first',
        ),
        AdviceOption(
          label: 'Fiber (single-mode/multimode) between buildings',
          chooseWhen: 'long runs, buildings, or electrical isolation',
          tradeOff: 'SFP ports/media converters on each end, and terminations '
              'need the right tools or a contractor',
        ),
        AdviceOption(
          label: 'Point-to-point wireless bridge',
          chooseWhen: 'a short-to-medium span with clear line of sight and no '
              'way to trench',
          tradeOff: 'weather and line-of-sight dependent; adds latency and a '
              'second device to power/aim',
        ),
      ],
      reasons: [
        'The 100 m limit is the link budget, not a suggestion: test a long '
            'run before assuming it will pass at gigabit.',
        'Buy one spool of cable and label both ends. Labor, not cable, is '
            'the cost - the second run in each room is nearly free while the '
            'walls are open.',
      ],
      quickReplies: const [
        'Review my network design for a two-building office',
      ],
      nextStep: 'Tell me the longest run and how many buildings, and I will '
          'say copper, fiber or wireless.',
    );
  }

  static AdviceAnswer _l3Switch(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'l3_vs_router',
      kind: c.kind,
      recommendation: 'For a handful of VLANs, a router with subinterfaces '
          '(router-on-a-stick) is enough and costs nothing extra. When '
          'inter-VLAN traffic grows or servers must talk to each other at '
          'line rate, let a layer-3 switch do the routing in the core and '
          'leave the router for WAN, NAT and VPN.',
      options: const [
        AdviceOption(
          label: 'Router-on-a-stick',
          chooseWhen: 'up to ~3-4 VLANs and modest traffic (the usual lab '
              'answer)',
          tradeOff: 'one interface carries every VLAN, so inter-VLAN traffic '
              'shares the router uplink',
        ),
        AdviceOption(
          label: 'L3 switch core + router at the edge',
          chooseWhen: 'many VLANs, server traffic, or a growing office',
          tradeOff: 'more cost and configuration; ACLs between VLANs must be '
              'planned on the switch',
        ),
      ],
      reasons: [
        'VLANs isolate by default; routing is what connects them back. '
            'Design the gateways alongside the VLAN list - one router '
            'subinterface (or switch SVI) per VLAN.',
        if (c.hasPlan && c.plan!.vlans.isNotEmpty)
          'Your plan lists VLANs ${c.plan!.vlans.join(', ')}; the routing '
              'shape follows from whether the switches are 2960 '
              '(router-on-a-stick) or 3560 (SVI).',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
      ],
      nextStep: 'Say how many VLANs you expect and whether the switches are '
          'learnable models, and I will plan the gateways.',
      planBrief: c.planBrief,
    );
  }

  static AdviceAnswer _backupWan(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'backup_wan',
      kind: c.kind,
      recommendation: 'If internet downtime costs money, order a second line '
          'from a DIFFERENT provider (or 5G/LTE as the standby) and use a '
          'router with WAN failover. A second line from the same provider '
          'shares the same cabinet, the same fiber and often the same outage.',
      options: const [
        AdviceOption(
          label: 'Second wireline ISP + failover router',
          chooseWhen: 'two providers exist locally and you need bandwidth as '
              'well as uptime',
          tradeOff: 'monthly cost for a line that idles; both lines may use '
              'the same duct into the building',
        ),
        AdviceOption(
          label: '4G/5G standby',
          chooseWhen: 'the budget allows one primary line and a modem/'
              'sim-router as backup (the pragmatic answer)',
          tradeOff: 'data caps and latency; check indoor signal where the '
              'router lives',
        ),
        AdviceOption(
          label: 'One line plus UPS and good support',
          chooseWhen: 'a small site where a few hours\' outage is tolerable',
          tradeOff: 'not redundancy: the line, the ISP and often the power '
              'share the same failure',
        ),
      ],
      reasons: [
        'Test failover rather than trusting it: unplug the primary and '
            'confirm the network actually switches, including DNS.',
        'Tie the failover router and modem/ONT to the UPS - most "outages" '
            'under 30 minutes are power events.',
      ],
      quickReplies: const [
        'Which router should I get for WAN failover with two internet lines?',
      ],
      nextStep: 'Tell me the downtime budget and what providers reach the '
          'building, and I will choose between a second line and 5G standby.',
    );
  }

  static AdviceAnswer _serverPlacement(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'server_placement',
      kind: c.kind,
      recommendation: 'Keep DHCP and DNS where the network can always reach '
          'them: the router for a small network, a server/NAS on a server '
          'VLAN once there are file shares or central authentication. Never '
          'put DHCP on a laptop or a VM that is not always on.',
      options: const [
        AdviceOption(
          label: 'Services on the router/gateway',
          chooseWhen: 'a home or small office with a single subnet (the '
              'default)',
          tradeOff: 'limited roles and storage; the router becomes the '
              'single point of failure',
        ),
        AdviceOption(
          label: 'Small server or NAS on a server VLAN',
          chooseWhen: 'file shares, media, backups, or central login',
          tradeOff: 'needs its own VLAN/firewall rules, power protection '
              'and patching',
        ),
        AdviceOption(
          label: 'Cloud services',
          chooseWhen: 'no on-site hardware wanted and the uplink is stable',
          tradeOff: 'internet outage equals service outage; recurring fees',
        ),
      ],
      reasons: [
        'What must be local: DHCP/DNS for the LAN, and anything latency- or '
            'privacy-sensitive. What can move: mail, files, backups.',
        if (c.hasPlan)
          'The lab already names its servers (${c.labLine()}) - give each '
              'one a role (DHCP/DNS/AAA) so the build configures its '
              'services tab rather than leaving it idle.',
      ],
      quickReplies: const [
        'Plan a small office with a DHCP/DNS server and a file server',
      ],
      nextStep: 'List the services you actually need and I will say what '
          'belongs on the router and what belongs on a server.',
    );
  }

  static AdviceAnswer _rackAndPower(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'rack_and_power',
      kind: c.kind,
      recommendation: 'Treat the cabinet as a small project: a patch panel '
          'with every run labeled, a PoE switch, the router/firewall and a '
          'line-interactive UPS sized above the real load. Label both ends '
          'of every cable while you install it - nobody ever regrets labels.',
      options: const [
        AdviceOption(
          label: 'Small wall cabinet + UPS',
          chooseWhen: 'a home or one-room office (the usual first step)',
          tradeOff: 'heat builds up in closed cabinets; leave ventilation',
        ),
        AdviceOption(
          label: 'Floor rack with patch panel + PDU/UPS',
          chooseWhen: 'an office with multiple rooms or cabling runs',
          tradeOff: 'cost and space; get the depth right for the switch '
              'before buying',
        ),
        AdviceOption(
          label: 'No cabinet (gear on a shelf)',
          chooseWhen: 'one router and one switch, nothing else',
          tradeOff: 'no protection, no labeling, and cables become the '
              'documentation',
        ),
      ],
      reasons: [
        'A UPS is not only for power cuts: it rides through brownouts and '
            'lets you shut down cleanly. Size it from the switch + router + '
            'PoE budget (a small office is often 100-300 W).',
        'Document once - port, cable, room - and every future fault becomes '
            'a five-minute job instead of an afternoon.',
      ],
      quickReplies: const [
        'Review my network design for a small office',
      ],
      nextStep: 'Tell me the room count and what is powered in the cabinet '
          'and I will list what belongs in it.',
    );
  }

  static AdviceAnswer _segmentation(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'segmentation',
      kind: c.kind,
      recommendation: 'Yes - group devices by trust level and give each '
          'group its own VLAN: staff, guests, cameras, point-of-sale/IoT, '
          'and voice if you run it. The VLAN is half the job; the other half '
          'is one rule per pair on the router/firewall (guests to staff = '
          'deny, cameras to NVR = allow, everyone to DHCP/DNS = allow).',
      options: const [
        AdviceOption(
          label: 'VLAN per role + ACLs/firewall rules',
          chooseWhen: 'any office, school, clinic or cafe with guests, '
              'cameras or a POS - the usual answer',
          tradeOff: 'the rules must be written and tested; one permissive '
              '"any" rule wastes the whole exercise',
        ),
        AdviceOption(
          label: 'One flat network with separate SSIDs',
          chooseWhen: 'a home, or a site with only trusted devices',
          tradeOff: 'a separate Wi-Fi name on one flat subnet is a label, '
              'not isolation - guests can still reach every device',
        ),
        AdviceOption(
          label: 'Physical separation (own switch/uplink)',
          chooseWhen: 'industrial or high-security segments that must not '
              'share infrastructure at all',
          tradeOff: 'doubles cabling and hardware; rarely worth it outside '
              'those cases',
        ),
      ],
      reasons: [
        'Decide what may NOT talk to what, then make the VLANs: '
            'guest-to-staff, camera-to-user and POS-to-workstation are the '
            'three that matter in small networks.',
        'Keep DHCP, DNS and each VLAN\'s gateway reachable in the rules, or '
            'you will spend an evening fixing a "broken VLAN" that is one '
            'missing allow.',
        if (c.hasPlan && c.plan!.vlans.isNotEmpty)
          'The lab on the table lists VLANs ${c.plan!.vlans.join(', ')}; the '
              'ACLs between them follow the same trust order.',
      ],
      questions: const [
        'Which of these must never reach each other: staff, guests, '
            'cameras, or local servers?',
      ],
      quickReplies: const [
        'Plan a small office with guest wifi and staff VLANs',
      ],
      nextStep: 'Name the groups to separate and I will list the VLANs and '
          'the rules between them - or plan them into the lab.',
    );
  }

  static AdviceAnswer _labModels(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'lab_models',
      kind: c.kind,
      recommendation: 'In Packet Tracer, build on the workhorse set: 2911 or '
          '4331 routers, 2960-24TT switches for access-layer work, 3560-24PS '
          'when the lab grades inter-VLAN routing or PoE, Access Point-PT '
          'for wireless, and an ASA 5505/5506 only for firewall labs (ASA is '
          'not IOS, so this app will not auto-configure it). In GNS3 use the '
          'IOSv or 7200-class images you are licensed for - the topology '
          'logic is the same.',
      options: const [
        AdviceOption(
          label: 'Routers: 2911 / 4331',
          chooseWhen: 'routing, WAN, NAT, ACL and VPN-style labs',
          tradeOff: 'no switching ports, so VLAN work still needs a switch '
              'model',
        ),
        AdviceOption(
          label: 'Switches: 2960-24TT (L2) / 3560-24PS (L3, PoE)',
          chooseWhen: '2960 for access/VLAN/STP labs; 3560 when the lab needs '
              'SVIs, routing or powered ports',
          tradeOff: 'the 3560 is the heavier model, and not every Packet '
              'Tracer build ships the same device catalog',
        ),
        AdviceOption(
          label: 'Wireless: Access Point-PT / Wireless Router-PT',
          chooseWhen: 'a wireless lab: AP-PT associates clients with no '
              'cable; Wireless Router-PT is the all-in-one shape',
          tradeOff: 'the PT wireless models cover 2.4 GHz and simple WPA, not '
              'full enterprise WLAN features',
        ),
      ],
      reasons: [
        'Match the model to the feature being graded: inter-VLAN routing on '
            'a 2960 alone cannot work (it is layer 2), and a 1941 cannot '
            'stand in for a 4331 when the lab is about throughput or '
            'licensing.',
        'Keep one model family across a lab: mixing routers is technically '
            'fine but makes the screenshots and the configs inconsistent.',
        if (c.hasPlan)
          'The plan on the table already reads ${c.labLine()}, so the model '
              'choice is about the feature the lab grades - nothing here '
              're-plans the lab.',
      ],
      questions: const [
        'What does the lab need to grade: routing, VLANs, wireless, or '
            'security?',
      ],
      quickReplies: const [
        'Which switch should I get for a packet tracer lab?',
        'What is the difference between a router and a switch?',
      ],
      nextStep: 'Name the feature the lab grades and the model follows from '
          'it - or say "plan it" with the device counts and I will plan the '
          'matching models.',
    );
  }

  // --- lab model comparison -------------------------------------------------

  /// Every model the comparison can answer about, one row per model
  /// ("isr4331", "isr 4331" and "4331" all land on the 4331 row). Keep the
  /// token set in step with AdviceIntentReader._topicWords in
  /// network_intent.dart - that reader is what lets a model-number message
  /// classify as advice at all. The facts are grounded: the roles and
  /// trade-offs are the lab-models topic's, and the port counts and device
  /// kinds are what the app's own device catalog ships
  /// (sidecar/pkt_templates/manifest.json) - nothing is invented.
  static final List<_LabModel> _modelTable = [
    _LabModel(
      token: RegExp(r'\b1841\b'),
      key: '1841',
      name: '1841',
      family: 'router',
      rank: 1,
      tagline: 'the small classic ISR router, two FastEthernet ports plus '
          'WIC slots for serial links',
      chooseWhen: 'the course or the template names it, or the lab is '
          'serial-WAN practice on WIC cards',
      tradeOff: 'it is the oldest and smallest of the router set - routing, '
          'NAT and ACL practice runs fine, but a lab graded on throughput '
          'needs a bigger ISR',
    ),
    _LabModel(
      token: RegExp(r'\b2811\b'),
      key: '2811',
      name: '2811',
      family: 'router',
      rank: 2,
      tagline: 'the older ISR router, two FastEthernet ports and NM/WIC '
          'module slots',
      chooseWhen: 'the exercise is about modules and slots, or the template '
          'names it',
      tradeOff: 'it is FastEthernet-only and superseded - the 2901/2911 do '
          'the same jobs on newer hardware',
    ),
    _LabModel(
      token: RegExp(r'\b1941\b'),
      key: '1941',
      name: '1941',
      family: 'router',
      rank: 3,
      tagline: 'the small ISR G2 router, two GigabitEthernet ports',
      chooseWhen: 'the lab is small routing/NAT/ACL work, or the course '
          'ships 1941 images',
      tradeOff: 'it cannot stand in for a 4331 when the lab grades '
          'throughput or licensing',
    ),
    _LabModel(
      token: RegExp(r'\b2901\b'),
      key: '2901',
      name: '2901',
      family: 'router',
      rank: 4,
      tagline: 'the ISR G2 router with two GigabitEthernet ports',
      chooseWhen: 'the lab wants gigabit routing inside the G2 family the '
          'course uses',
      tradeOff: 'two ports is the whole box - the 2911 adds one more '
          'GigabitEthernet and nothing else changes',
    ),
    _LabModel(
      token: RegExp(r'\b2911\b'),
      key: '2911',
      name: '2911',
      family: 'router',
      rank: 5,
      tagline: 'the Packet Tracer workhorse ISR G2 router, three '
          'GigabitEthernet ports',
      chooseWhen: 'it is the standard router lab: routing, WAN, NAT, ACL, '
          'OSPF, VPN-style labs',
      tradeOff: 'there are no switching ports, so VLAN work still needs a '
          'switch model',
    ),
    _LabModel(
      token: RegExp(r'\b(?:isr ?)?4321\b'),
      key: '4321',
      name: 'ISR 4321',
      family: 'router',
      rank: 6,
      tagline: 'the ISR 4000 router with two GigabitEthernet ports',
      chooseWhen: 'the lab or its image set names the ISR 4000 generation',
      tradeOff: 'in the simulator its feature set sits close to the 2911 - '
          'capacity is the real difference',
    ),
    _LabModel(
      token: RegExp(r'\b(?:isr ?)?4331\b'),
      key: '4331',
      name: 'ISR 4331',
      family: 'router',
      rank: 7,
      tagline: 'the big ISR 4000 router with three GigabitEthernet ports',
      chooseWhen: 'the lab grades the big-platform things - throughput, '
          'licensing, headroom',
      tradeOff: 'few labs grade the capacity - if none does, the 2911 '
          'builds the identical topology',
    ),
    _LabModel(
      token: RegExp(r'\b2950\b'),
      key: '2950',
      name: '2950-24',
      family: 'switch',
      rank: 1,
      tagline: 'the older layer-2 switch with 24 FastEthernet ports',
      chooseWhen: 'the course names it - the access/VLAN/STP jobs are the '
          "2960's otherwise",
      tradeOff: 'it is superseded by the 2960-24TT in every Packet Tracer '
          'catalog that ships both',
    ),
    _LabModel(
      token: RegExp(r'\b2960\b'),
      key: '2960',
      name: '2960-24TT',
      family: 'switch',
      rank: 2,
      tagline: 'the layer-2 access switch with 24 FastEthernet ports',
      chooseWhen: 'the lab is access-layer work: VLANs, STP, port security',
      tradeOff: 'it is layer 2 only - inter-VLAN routing on a 2960 alone '
          'cannot work',
    ),
    _LabModel(
      token: RegExp(r'\b3560\b'),
      key: '3560',
      name: '3560-24PS',
      family: 'switch',
      rank: 3,
      tagline: 'the layer-3 PoE switch with 24 FastEthernet ports',
      chooseWhen: 'the lab needs SVIs, inter-VLAN routing, or powered ports',
      tradeOff: 'it is the heavier model, and not every Packet Tracer build '
          'ships the same device catalog',
    ),
    _LabModel(
      token: RegExp(r'\b(?:access ?point|accesspoint|ap)-?pt\b'),
      key: 'ap-pt',
      name: 'Access Point-PT',
      family: 'wireless',
      rank: 1,
      tagline: 'the Packet Tracer access point, one wired port and a '
          '2.4 GHz radio',
      chooseWhen: 'wireless clients must associate with no cable drawn',
      tradeOff: 'it covers 2.4 GHz and simple WPA, not full enterprise WLAN '
          'features',
    ),
    _LabModel(
      token: RegExp(r'\b(?:wireless )?router-?pt\b'),
      key: 'router-pt',
      name: '(Wireless) Router-PT',
      family: 'wireless',
      rank: 2,
      tagline: 'the generic PT boxes - Wireless Router-PT is the all-in-one '
          'shape',
      chooseWhen: 'a quick all-in-one shape matters more than the '
          "box's name",
      tradeOff: 'it is generic sim hardware - the named models carry the '
          'feature depth',
    ),
    _LabModel(
      token: RegExp(r'\bisa-?3000\b'),
      key: 'isa-3000',
      name: 'ISA-3000',
      family: 'firewall',
      rank: 1,
      tagline: 'the industrial security appliance, cataloged ASA-kind by '
          'this app',
      chooseWhen: 'an industrial-security lab names it',
      tradeOff: 'the same rule as the ASA applies: firewall configuration '
          'is by hand, never auto-configured',
    ),
    _LabModel(
      token: RegExp(r'\basa\b'),
      key: 'asa',
      name: 'ASA 5505/5506',
      family: 'firewall',
      rank: 2,
      tagline: 'the ASA firewall appliance',
      chooseWhen: 'the firewall lab is about the ASA CLI itself',
      tradeOff: 'ASA is not IOS, so this app will not auto-configure it - '
          'plan the policy on the router or configure the ASA by hand',
    ),
  ];

  /// The lab models [t] names, in table order, deduped by construction:
  /// one row per model, so "isr4331" and "4331" both land on one entry.
  static List<_LabModel> _namedModels(String t) =>
      [for (final m in _modelTable) if (m.token.hasMatch(t)) m];

  /// The answer when the ask names known lab models: a recommendation
  /// first, then one row per model - what it is, when to choose it, what it
  /// costs - grounded in the same lab context the lab-models topic uses. A
  /// single-model ask ("is a 2911 enough for my lab?") gets the same table
  /// with the model's nearest siblings as the other options, so the answer
  /// is still a choice and never a dead end.
  static AdviceAnswer _modelComparison(_AdvisorContext c) {
    final named = _namedModels(c.t);
    final shown = named.take(4).toList();
    final options = <AdviceOption>[
      for (final m in shown)
        AdviceOption(
          label: '${m.name} - ${m.tagline}',
          chooseWhen: m.chooseWhen,
          tradeOff: m.tradeOff,
        ),
    ];
    const familyJob = {
      'router': 'the box that routes, NATs and holds the ACLs',
      'switch': 'the box the wired devices plug into',
      'wireless': 'the radio the wireless clients associate to',
      'firewall': 'the policy box - the one this app leaves to hand config',
    };
    final sameFamily =
        shown.map((m) => m.family).toSet().length == 1;
    final String recommendation;
    if (shown.length >= 2 && sameFamily) {
      final best = shown.reduce((a, b) => a.rank >= b.rank ? a : b);
      final others = shown
          .where((m) => m.key != best.key)
          .map((m) => m.name)
          .join(' or ');
      recommendation = 'Take the ${best.name} unless your course or template '
          'names the $others: ${best.chooseWhen}. The trade-off: '
          '${best.tradeOff}. The honest caveat either way - these models '
          'build the same Packet Tracer topology, so matching the model the '
          'course materials use keeps the configs and screenshots '
          'consistent.';
    } else if (shown.length >= 2) {
      final jobs = shown
          .map((m) => 'the ${m.name} is ${familyJob[m.family]!}')
          .join(' and ');
      recommendation = 'These are not rivals - $jobs. A working lab needs '
          'one of each, so choose by the job the lab grades, not one model '
          'against the other.';
    } else {
      final m = shown.first;
      recommendation = '${m.name} - ${m.tagline}. For a Packet Tracer lab: '
          'enough for its own jobs (${m.chooseWhen}); it is the wrong box '
          'only when the lab grades what it lacks - ${m.tradeOff}.';
      final siblings = _modelTable
          .where((s) => s.family == m.family && s.key != m.key)
          .toList()
        ..sort(
          (a, b) =>
              (a.rank - m.rank).abs().compareTo((b.rank - m.rank).abs()),
        );
      for (final s in siblings.take(2)) {
        options.add(
          AdviceOption(
            label: '${s.name} - ${s.tagline}',
            chooseWhen: s.chooseWhen,
            tradeOff: s.tradeOff,
          ),
        );
      }
    }
    return AdviceAnswer(
      topic: 'lab_model_comparison',
      kind: c.kind,
      recommendation: recommendation,
      options: options,
      reasons: [
        if (shown.length >= 2 && sameFamily)
          'The one trap: a smaller ISR cannot stand in for a bigger one when '
              'the lab grades throughput or licensing - the 1941-for-4331 '
              'swap is the classic example.'
        else if (shown.length >= 2)
          'A router has no switching ports and a 2960 cannot route between '
              'VLANs, so "which is better" across families is really "which '
              'job is first": inter-VLAN routing needs a 3560, or '
              'router-on-a-stick on the router.',
        'Keep one model family across the lab: mixing is technically fine, '
            'but the configs and the screenshots stop matching.',
        if (c.hasPlan)
          'The plan on the table reads ${c.labLine()} - nothing here '
              're-plans it; swap a model only when a graded feature says so.',
        'Model catalogs differ a little between Packet Tracer versions - if '
            'a name is missing in your install, the closest sibling builds '
            'the same lab.',
      ],
      questions: const [
        'What does the lab need to grade: routing, VLANs, wireless, or '
            'security?',
      ],
      quickReplies: const [
        'Which switch should I get for a packet tracer lab?',
        'What is the difference between a router and a switch?',
      ],
      nextStep: 'Name the feature the lab grades and the model follows from '
          'it - or say "plan it" with the device counts and I will plan the '
          'matching models.',
    );
  }

  static AdviceAnswer _sizing(_AdvisorContext c) {
    final n = c.scale;
    final browse = n == null ? null : (n * 7.5).round();
    final calls = n == null ? null : n * 25;
    return AdviceAnswer(
      topic: 'sizing',
      kind: c.kind,
      recommendation: 'Size from the busy hour, not the average: budget '
          '5-10 Mbit/s per user for browsing, 25+ Mbit/s per user when '
          'several video-call at once, and 25-50% headroom on the WAN. For '
          'ports, count devices + uplinks + 20% spare. For Wi-Fi, one access '
          'point per ~25-50 active devices, then add APs for coverage - '
          'coverage first, capacity second.',
      options: const [
        AdviceOption(
          label: 'Capacity-led',
          chooseWhen: 'the busiest hour decides (offices, schools at lesson '
              'change)',
          tradeOff: 'needs a density-aware design; cheap APs crack under the '
              'load',
        ),
        AdviceOption(
          label: 'Coverage-led',
          chooseWhen: 'dead spots are the complaint (home, warehouse, thick '
              'walls)',
          tradeOff: 'APs placed only for coverage may still be slow at peak',
        ),
        AdviceOption(
          label: 'Hybrid (the usual)',
          chooseWhen: 'almost always: coverage first, then capacity where '
              'people gather',
          tradeOff: 'costs one more AP than a single-led design',
        ),
      ],
      reasons: [
        if (n != null && browse != null && calls != null)
          'At $n users: about $browse Mbit/s for browsing, about $calls '
              'Mbit/s if everyone video-calls at once - that upper number is '
              'when QoS and wired backhaul matter more than a faster plan.',
        'WAN sizing and Wi-Fi sizing are separate jobs: a faster line '
            'cannot fix airtime, and more APs cannot fix a slow line.',
      ],
      questions: [
        if (n == null) 'How many people use the network at the same time?',
        'What is the busiest thing they do - browsing, video calls, or file '
            'transfers?',
      ],
      quickReplies: const [
        'How many access points do I need for 40 users?',
      ],
      nextStep: 'Tell me the user count and the busiest activity and I will '
          'turn the numbers into a plan.',
    );
  }

  static AdviceAnswer _slowWifi(_AdvisorContext c) {
    return AdviceAnswer(
      topic: 'slow_wifi',
      kind: c.kind,
      recommendation: 'Work from the wire outward before buying anything: '
          'test on a wired connection first, then fix Wi-Fi placement and '
          'channels, then add APs/capacity, and only then look at QoS or the '
          'ISP plan. Most "slow internet" is local Wi-Fi or DNS, not the '
          'line.',
      options: const [
        AdviceOption(
          label: 'Prove where it is slow',
          chooseWhen: 'always, first step: wired PC speed test at the same '
              'moment',
          tradeOff: 'costs ten minutes; without it you may buy an AP for an '
              'ISP problem',
        ),
        AdviceOption(
          label: 'Fix coverage and channels',
          chooseWhen: 'dead spots, one end of the building, or many '
              'neighbouring networks on the same channel',
          tradeOff: 'may need to move/re-cable an AP; moving an AP is often '
              'more effective than adding one',
        ),
        AdviceOption(
          label: 'Add capacity (APs, wired backhaul, QoS)',
          chooseWhen: 'wired speed is fine but calls break when the office '
              'is full',
          tradeOff: 'spend; mis-placed APs add interference rather than '
              'capacity',
        ),
      ],
      reasons: [
        'The classic order of blame: cable/link, placement, channels/'
            'interference, number of clients per AP, then the ISP.',
        'If video calls stutter only when others are working, it is airtime '
            'or uplink saturation: QoS for the calls and wired backhaul for '
            'the APs fix more than a faster plan does.',
        if (c.hasPlan)
          'For a lab, ask the same question with `show interfaces`/'
              '`show ip interface brief` and ping across each hop - the '
              'offline knowledge answers those commands.',
      ],
      questions: const [
        'Is it slow everywhere or only on Wi-Fi in parts of the building?',
      ],
      quickReplies: const [
        'How many access points do I need for 40 users?',
        'Is mesh or wired access points better?',
      ],
      nextStep: 'Tell me wired-vs-wifi and where in the building it is bad, '
          'and I will narrow the cause to one of the four layers.',
    );
  }

  /// The answer when someone asks for advice without naming a topic: a
  /// design review, led by the layers a network is actually judged on, and
  /// grounded in the plan when there is one.
  static AdviceAnswer _designReview(_AdvisorContext c) {
    final counts = c.hasPlan
        ? '${c.count('router')} router(s), ${c.count('switch')} switch(es), '
            '${c.count('pc')} PC(s)'
        : '';
    return AdviceAnswer(
      topic: 'design_review',
      kind: c.kind,
      recommendation: c.hasPlan
          ? 'Judged as it stands ($counts), the plan covers the core. What I '
              'would check next, in order: the edge (default route + NAT), '
              'one address plan per VLAN, the services (DHCP/DNS) reachable '
              'from each LAN, and a security control on the user ports.'
          : 'Start from the edge and work inward: one router/firewall at the '
              'internet, a managed switch for the desks, wired access points, '
              'one VLAN per role (staff / guest / voice / cameras), DHCP and '
              'DNS somewhere always-on, and a backup path if downtime costs '
              'money.',
      options: const [
        AdviceOption(
          label: 'Review the design as it stands',
          chooseWhen: 'a plan or a built network already exists',
          tradeOff: 'finds the gaps you already own rather than the ones you '
              'might buy for',
        ),
        AdviceOption(
          label: 'Size it for a named scale',
          chooseWhen: 'you can say how many users, rooms or devices',
          tradeOff: 'numbers without a floor plan are still estimates',
        ),
        AdviceOption(
          label: 'Compare two candidate designs',
          chooseWhen: 'you have two concrete options in mind',
          tradeOff: 'needs both options named to be useful',
        ),
      ],
      reasons: [
        if (c.hasPlan)
          'The lab on the table is $counts; say "check the plan" for the '
              'validator\'s own findings, or name the layer you care about '
              'and I will go deep on it.'
        else
          'A design review is only as good as its inputs: users, rooms/floors, '
              'what must be kept apart, and what must survive an outage.',
        'Wireless and security are where reviews find the most value: '
            'coverage overlap, guest isolation, and an unused (or '
            'over-permissive) ACL.',
        if (c.budget)
          'On a tight budget, spend first on the edge router and the '
              'cabling, then add access points: a wired AP can be added any '
              'time, a weak edge cannot be fixed with more Wi-Fi.',
      ],
      questions: [
        if (!c.hasPlan) 'What are you building - a home, an office, or a lab?',
        if (!c.hasPlan)
          'Roughly how many users/devices, and how many floors or rooms?',
      ],
      quickReplies: [
        if (c.planBrief != null) c.planBrief!,
        if (c.hasPlan) 'Should I segment this plan into VLANs?',
        if (!c.hasPlan) 'What router should I get for an office with 20 employees?',
        if (!c.hasPlan) 'How many access points do I need for 40 users?',
      ],
      nextStep: c.hasPlan
          ? 'Say the layer to check - addressing, routing, services, security '
              'or wireless - and I will review it against the lab.'
          : 'Answer the two questions above and I will produce a design you '
              'can turn into a plan.',
      planBrief: c.planBrief,
    );
  }
}

/// One option in an advice answer: what it is, when to choose it, and what
/// it costs you (in trade-offs, never in prices).
class AdviceOption {
  final String label;
  final String chooseWhen;
  final String tradeOff;

  const AdviceOption({
    required this.label,
    required this.chooseWhen,
    required this.tradeOff,
  });
}

/// A complete advisory answer.
///
/// Structured as well as rendered: the tests assert on the parts (a
/// recommendation exists, options carry a trade-off, the plan was never
/// touched), while the chat renders [toText].
class AdviceAnswer {
  /// Stable id of the topic answered (see the topic list in
  /// [AdvisorService]).
  final String topic;

  /// The reading that produced this answer.
  final AdviceKind kind;

  /// The lead recommendation. Always present: advice answers start with
  /// what the advisor would do.
  final String recommendation;

  /// 1-4 options, each with "choose this when" and its trade-off.
  final List<AdviceOption> options;

  /// Why this fits THIS user: their words, their scale, and the plan.
  final List<String> reasons;

  /// At most two questions, and only ones that change the recommendation.
  final List<String> questions;

  /// One-tap next messages. Every one is a sentence the offline path can
  /// act on, so a tap never dead-ends.
  final List<String> quickReplies;

  /// The single concrete next action.
  final String nextStep;

  /// A plan-able sentence for "turn this into a plan", or null when the
  /// topic has nothing to plan.
  final String? planBrief;

  /// What this answer is grounded in: the lab on the table, the way the lab
  /// simulators behave, or the user's own description of their site (with
  /// the "gear names are examples, check current prices" caveat). Filled in
  /// by [AdvisorService.advise].
  final String basis;

  const AdviceAnswer({
    required this.topic,
    required this.kind,
    required this.recommendation,
    this.options = const [],
    this.reasons = const [],
    this.questions = const [],
    this.quickReplies = const [],
    required this.nextStep,
    this.planBrief,
    this.basis = '',
  });

  /// The same answer with its provenance line attached.
  AdviceAnswer withBasis(String basis) => AdviceAnswer(
    topic: topic,
    kind: kind,
    recommendation: recommendation,
    options: options,
    reasons: reasons,
    questions: questions,
    quickReplies: quickReplies,
    nextStep: nextStep,
    planBrief: planBrief,
    basis: basis,
  );

  /// The chat text: recommendation first, then the options and their
  /// trade-offs, then why it fits, then one next step. Markdown, because
  /// the chat renders it (tables included).
  String toText() {
    final b = StringBuffer()..writeln('**What I would do:** $recommendation');
    if (options.isNotEmpty) {
      b
        ..writeln()
        ..writeln('| Option | Choose it when | Trade-off |')
        ..writeln('| --- | --- | --- |');
      for (final o in options) {
        b.writeln('| ${o.label} | ${o.chooseWhen} | ${o.tradeOff} |');
      }
    }
    if (reasons.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Why this fits here:');
      for (final r in reasons) {
        b.writeln('- $r');
      }
    }
    if (basis.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Based on: $basis');
    }
    b
      ..writeln()
      ..writeln('Next step: $nextStep');
    if (questions.isNotEmpty) {
      b
        ..writeln()
        ..writeln('To narrow it down: ${questions.join(' ')}');
    }
    b
      ..writeln()
      ..writeln(
        'Nothing about your plan changed - advice never edits the lab. '
        'If you want this in the build, say the word and I will plan it.',
      );
    return b.toString().trimRight();
  }
}

// --- context ----------------------------------------------------------------

/// One row of the advisor's lab-model table ([AdvisorService._modelTable]):
/// the token that names it (the way a user types it) and the facts a
/// comparison row shows. [rank] is the capacity/generation order inside a
/// family; it only ever picks a default between two models, never a spec.
class _LabModel {
  final RegExp token;
  final String key;
  final String name;
  final String family;
  final int rank;
  final String tagline;
  final String chooseWhen;
  final String tradeOff;

  _LabModel({
    required this.token,
    required this.key,
    required this.name,
    required this.family,
    required this.rank,
    required this.tagline,
    required this.chooseWhen,
    required this.tradeOff,
  });
}

enum _Venue { home, office, school, clinic, hospitality, industrial, unknown }

/// What the message and the standing plan say, read once and used by every
/// topic: venue, scale, budget band, and the plan facts.
class _AdvisorContext {
  final String t;
  final NetworkIntent? plan;
  final String target;
  final AdviceKind kind;
  final _Venue venue;
  final int? scale;
  final bool budget;

  /// The remembered skill level, when the profile states one ("beginner").
  /// The message never states it mid-answer, so unlike venue/scale there is
  /// no per-turn override to consider - it is purely the stored fact.
  final String skill;

  _AdvisorContext({
    required this.t,
    required this.plan,
    required this.target,
    required this.kind,
    EnvironmentProfile? profile,
  }) : venue = _venueFor(t, profile),
       scale = _scaleFor(t, profile),
       budget = _budget.hasMatch(t) || (profile?.budget ?? false),
       skill = (profile == null || profile.skill.isEmpty) ? '' : profile.skill;

  /// The message's venue when it states one; the remembered venue otherwise.
  static _Venue _venueFor(String t, EnvironmentProfile? profile) {
    final stated = _venueOf(t);
    if (stated != _Venue.unknown) return stated;
    final remembered = profile?.venue ?? '';
    if (remembered.isEmpty) return _Venue.unknown;
    for (final v in _Venue.values) {
      if (v.name == remembered) return v;
    }
    return _Venue.unknown;
  }

  /// The message's count of people/devices when it states one; the
  /// remembered scale otherwise.
  static int? _scaleFor(String t, EnvironmentProfile? profile) {
    final stated = _scaleOf(t);
    if (stated != null) return stated;
    final remembered = profile?.scale ?? 0;
    return remembered > 0 ? remembered : null;
  }

  bool get hasPlan => plan != null && plan!.nodes.isNotEmpty;

  static final RegExp _budget = RegExp(
    r'\b(?:cheap|cheapest|budget|affordable|low[- ]cost|inexpensive|'
    r'tight budget|small budget|low budget|free)\b',
  );

  static final RegExp _homeWords = RegExp(
    r'\b(?:home|house|apartment|flat|villa|family|bedroom|residential)\b',
  );
  static final RegExp _schoolWords = RegExp(
    r'\b(?:school|university|college|campus|classroom|students)\b',
  );
  static final RegExp _clinicWords = RegExp(
    r'\b(?:clinic|hospital|medical|pharmacy|patients)\b',
  );
  static final RegExp _hospitalityWords = RegExp(
    r'\b(?:cafe|café|restaurant|hotel|shop|store|salon|customers|guests)\b',
  );
  static final RegExp _industrialWords = RegExp(
    r'\b(?:warehouse|factory|industrial|production|workshop)\b',
  );
  static final RegExp _officeWords = RegExp(
    r'\b(?:office|business|company|branches?|startup|employees|staff|'
    r'workstations?)\b',
  );

  static _Venue _venueOf(String t) {
    if (_schoolWords.hasMatch(t)) return _Venue.school;
    if (_clinicWords.hasMatch(t)) return _Venue.clinic;
    if (_hospitalityWords.hasMatch(t)) return _Venue.hospitality;
    if (_industrialWords.hasMatch(t)) return _Venue.industrial;
    if (_officeWords.hasMatch(t)) return _Venue.office;
    if (_homeWords.hasMatch(t)) return _Venue.home;
    return _Venue.unknown;
  }

  static final RegExp _scalePattern = RegExp(
    r'\b(\d{1,4})\s*[- ]?\s*(?:active\s+)?(?:users?|employees?|people|staff|'
    r'students?|patients?|clients?|guests?|customers?|pcs?|computers?|'
    r'devices?|seats?|workstations?|endpoints?|rooms?|floors?|sites?)\b',
  );

  /// The first number that is a count of people/devices/rooms, or null.
  static int? _scaleOf(String t) {
    final m = _scalePattern.firstMatch(t);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!);
    if (n == null || n <= 0 || n > 5000) return null;
    return n;
  }

  bool mentions(String phrase) => t.contains(phrase);

  bool mentionsAny(List<String> phrases) =>
      phrases.any((p) => t.contains(p));

  bool words(List<String> words) => words.any(
    (w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(t),
  );

  int count(String type) =>
      plan?.nodes.where((n) => n.type == type).length ?? 0;

  bool get lab =>
      hasPlan ||
      target.toLowerCase().contains('pt') ||
      target.toLowerCase().contains('gns3') ||
      t.contains('packet tracer') ||
      t.contains('gns3') ||
      words(const ['lab', 'labs']);

  /// The plan in one clause, in plurals a person would use.
  String labLine() {
    if (!hasPlan) return '';
    final p = plan!;
    String many(int n, String one, String plural) =>
        '$n ${n == 1 ? one : plural}';
    final bits = <String>[
      if (count('router') > 0) many(count('router'), 'router', 'routers'),
      if (count('switch') > 0) many(count('switch'), 'switch', 'switches'),
      if (count('pc') > 0) many(count('pc'), 'PC', 'PCs'),
      if (count('server') > 0) many(count('server'), 'server', 'servers'),
      if (p.vlans.isNotEmpty) 'VLANs ${p.vlans.join(', ')}',
    ];
    return bits.isEmpty ? '${p.nodes.length} device(s)' : bits.join(', ');
  }

  /// The plan-able sentence the answer can offer as a one-tap next step,
  /// or null when there is nothing to add to the plan.
  String? get planBrief {
    if (!lab) return null;
    if (hasPlan) return null; // the lab already exists; advice must not re-plan it
    final v = venue;
    if (v == _Venue.home) {
      return 'Build a home network with 1 wireless router and 4 PCs';
    }
    return 'Build a small office with 1 router, 1 switch, 2 access points '
        'and 10 PCs';
  }
}
