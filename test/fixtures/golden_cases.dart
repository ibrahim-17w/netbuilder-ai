/// The golden corpus: real English phrasings and the plan each must produce.
///
/// This file is DATA, kept apart from the harness in
/// `nlu_golden_set_test.dart` so the corpus can grow without the test
/// becoming unreadable. Three tiers, in descending order of precision:
///
/// * `contract` - what the app guarantees today and must never regress. Each
///   one is asserted exactly.
/// * `knownGaps` - behavior that is WRONG but stable. Asserted exactly too,
///   so closing a gap is a deliberate, noticed change: the case goes red the
///   moment someone fixes it, and then moves into `contract`.
/// * `observed` - briefs seen in real use, asserted only for the invariants
///   that must hold for ANY brief: it does not throw, and a device kind the
///   brief explicitly names does not silently vanish. Breadth without
///   pretending to precision.
///
/// Every expectation below is written from what the brief MEANS, not from
/// what the parser currently returns. Where the two disagree, the case is a
/// bug report - see `knownGaps`.
///
/// `(brief, expected node counts by type, expected routing, run drift guard)`.
/// `routing` is only asserted when non-null. A partial count map is a
/// deliberate precision choice: naming `pc: 0` asserts no phantom endpoints
/// were invented, but omitting `server` says nothing about servers.
typedef GoldenCase = (String, Map<String, int>, String?, bool);

/// A brief from real use, and the device kinds it names out loud. The parse
/// must not lose any of them.
typedef ObservedCase = (String, Set<String>);

// ===========================================================================
// CONTRACT - tier 1: exact guarantees.
// ===========================================================================
final List<GoldenCase> contract = [
  // --- quantity phrases -----------------------------------------------------
  (
    'Build a network with 3 routers, 2 switches and 10 PCs',
    {'router': 3, 'switch': 2, 'pc': 10, 'server': 0},
    null,
    true,
  ),
  // Spelled-out numbers are bridged to digits before parsing.
  (
    '2 routers, 2 switches and four pcs',
    {'router': 2, 'switch': 2, 'pc': 4},
    null,
    true,
  ),
  // --- bare mentions mean one ----------------------------------------------
  (
    'a router connected to a switch and a server for dhcp',
    {'router': 1, 'switch': 1, 'pc': 0, 'server': 1},
    null,
    true,
  ),
  // --- model numbers are not quantities ------------------------------------
  (
    'Cisco 2911 routers for the office',
    {'router': 1, 'switch': 0, 'server': 0},
    null,
    true,
  ),
  // --- explicit labels are authoritative -----------------------------------
  (
    'R1 and R2 connect to SW1 and SW2, one PC for testing',
    {'router': 2, 'switch': 2, 'pc': 1, 'server': 0},
    null,
    true,
  ),
  (
    'R1 serves SRV1 and SRV2',
    {'router': 1, 'switch': 0, 'pc': 0, 'server': 2},
    null,
    true,
  ),
  // --- per-site clauses multiply --------------------------------------------
  (
    'two branch offices, each with a router, a switch and 3 pcs',
    {'router': 2, 'switch': 2, 'pc': 6},
    null,
    true,
  ),
  // --- roles and AAA provision a server -------------------------------------
  (
    '1 router with dns and http',
    {'router': 1, 'switch': 0, 'pc': 0, 'server': 1},
    null,
    true,
  ),
  (
    'use tacacs+ for logins, 2 routers 2 switches 4 pcs',
    {'router': 2, 'switch': 2, 'pc': 4, 'server': 1},
    null,
    true,
  ),
  // --- other catalog kinds ---------------------------------------------------
  (
    '2 routers 2 switches 4 pcs with wifi',
    {'router': 2, 'switch': 2, 'pc': 4, 'wireless': 1},
    null,
    true,
  ),
  (
    '2 firewalls and 2 pcs behind a router',
    {'router': 1, 'switch': 0, 'pc': 2, 'firewall': 2, 'server': 0},
    null,
    true,
  ),
  (
    '12 PCs, 1 switch',
    {'pc': 12, 'switch': 1},
    null,
    true,
  ),
  // --- the tiny-office default ------------------------------------------------
  (
    'build me something for the office',
    {'router': 1, 'switch': 1, 'pc': 0, 'server': 0},
    null,
    true,
  ),
  // --- routing ----------------------------------------------------------------
  (
    '2 routers 2 switches 4 pcs, run ospf between them',
    {'router': 2, 'switch': 2, 'pc': 4},
    'ospf',
    true,
  ),
  // --- quantities stated across clauses ---------------------------------------
  (
    'the second floor needs 6 access points and the ground floor 4',
    {'wireless': 10},
    null,
    true,
  ),
  (
    '6 access points, 3 on the second floor and 3 on the ground floor',
    {'wireless': 6},
    null,
    true,
  ),
  (
    'the second floor needs 6 access points; the second floor needs 6',
    {'wireless': 6},
    null,
    true,
  ),
  (
    'The second floor needs 6 access points. The ground floor needs 4.',
    {'wireless': 10},
    null,
    true,
  ),
  (
    'no ospf for this lab, 2 routers',
    {'router': 2},
    'static',
    false,
  ),
  (
    'the second floor needs 6 access points, actually 8',
    {'wireless': 8},
    null,
    true,
  ),
  (
    'the second floor needs 6 access points and 4 more',
    {'wireless': 10},
    null,
    true,
  ),
  // --- multi-site completion ---------------------------------------------------
  (
    'two physical sites and 20 PCs',
    {'router': 2, 'switch': 2, 'pc': 20},
    null,
    true,
  ),
  (
    'more than 1 router and 1 switch and 1 server',
    {'router': 2, 'switch': 1, 'server': 1},
    null,
    true,
  ),
  // --- routing negation, contrast and replacement -------------------------------
  ("Don't use OSPF; use EIGRP", {}, 'eigrp', false),
  ('use OSPF on the routers, not EIGRP', {}, 'ospf', false),
  // The sizing pack (the brief expands before the parser sees it, so the drift
  // guard is skipped: the pipeline reads the raw brief only).
  (
    '10 employees and two floors, build the network',
    {
      'router': 1,
      'switch': 2,
      'pc': 10,
      'server': 1,
      'wireless': 2,
      'firewall': 1,
      'cloud': 1,
    },
    null,
    false,
  ),

  // =========================================================================
  // Everything below was added when the corpus grew past the original 26.
  // Grouped by the failure mode each group is here to catch.
  // =========================================================================

  // --- CCNA / Packet Tracer lab assignment phrasing -------------------------
  // Real students paste these; the numbers are often preceded by the lab
  // number itself, which must never be read as a device count.
  (
    'Build the topology in the lab for chapter 3: 2 routers 2 switches and 6 PCs',
    {'router': 2, 'switch': 2, 'pc': 6},
    null,
    true,
  ),
  ('CCNA lab 4.3.2 configure OSPF on R1 and R2', {'router': 2}, 'ospf', true),
  ('the assignment says 3 routers 3 switches 9 pcs', {
    'router': 3,
    'switch': 3,
    'pc': 9,
  }, null, true),
  ('build a network with 2 routers, 2 switches and 10 PCs, then configure OSPF', {
    'router': 2,
    'switch': 2,
    'pc': 10,
  }, 'ospf', true),
  ('lab 5.1.1: eigrp between R1 R2 R3', {'router': 3}, 'eigrp', true),
  // The lab number reads as a count only if the parser mistakes it; naming a
  // protocol near it must still land.
  ('run bgp between the two routers', {'router': 2}, 'bgp', true),
  ('ospf area 0 between 3 routers', {'router': 3}, 'ospf', true),
  ('static routing only, 2 routers', {'router': 2}, 'static', true),

  // --- everyday office English ------------------------------------------------
  (
    'i need a network for my home office',
    {'router': 1, 'switch': 1},
    null,
    true,
  ),
  (
    'can you set up something for a small cafe',
    {'router': 1, 'switch': 1},
    null,
    true,
  ),
  // A colloquial count word resolves, and a vague plural does not become a
  // precise lie: "a couple" is two, "some" stays minimal.
  (
    'make me a lab with a couple routers and some pcs',
    {'router': 2, 'pc': 1},
    null,
    true,
  ),

  // --- explicit device inventories, one kind at a time ------------------------
  // These are the "never invent a device" cases: naming a kind that must be
  // absent is as much a guarantee as naming one that must be present.
  (
    '1 router, 2 switches, 2 firewalls and 4 pcs',
    {'router': 1, 'switch': 2, 'pc': 4, 'firewall': 2},
    null,
    true,
  ),
  (
    'a cloud connected to a router for internet',
    {'router': 1, 'cloud': 1},
    null,
    true,
  ),
  (
    '2 routers 2 switches 4 pcs with wifi and 1 cloud',
    {'router': 2, 'switch': 2, 'pc': 4, 'cloud': 1, 'wireless': 1},
    null,
    true,
  ),

  // --- services name the server they provision -------------------------------
  // A role is a request for a device, not a label on an existing one.
  (
    '1 router with dns dhcp and http',
    {'router': 1, 'server': 1},
    null,
    true,
  ),
  (
    'router with a tftp server for image backup',
    {'router': 1, 'server': 1},
    null,
    true,
  ),
  (
    '2 routers 2 switches 4 pcs and a syslog server',
    {'router': 2, 'switch': 2, 'pc': 4, 'server': 1},
    null,
    true,
  ),
  (
    '1 router with aaa tacacs+ server',
    {'router': 1, 'server': 1},
    null,
    true,
  ),
  (
    'router 1 with ntp and snmp and 2 switches',
    {'router': 1, 'switch': 2, 'server': 1},
    null,
    true,
  ),

  // --- follow-up turns against a standing lab ---------------------------------
  // The parser is read here with no prior context, so these pin the
  // single-turn reading only. Continuity itself is covered by
  // follow_up_plan_test and chat_plan_continuity_test.
  ('add 2 more pcs to the lab', {'pc': 2}, null, true),
  ('actually make it 4 switches', {'switch': 4}, null, true),

  // --- a headcount that disagrees with the device list ------------------------
  // The 15 + 10 device list is the real instruction; "40 users" is context
  // and must not turn 25 endpoints into 40 or into a whole sizing pack.
  (
    'a network for 40 users, 15 pcs at HQ and 10 at the branch',
    {'pc': 25},
    null,
    true,
  ),

  // --- wireless: AP counts across sites ---------------------------------------
  (
    '4 access points total, 2 upstairs and 2 downstairs',
    {'wireless': 4},
    null,
    true,
  ),
  // "more than N" is a floor everywhere, not just for routers.
  (
    'more than 2 access points and 1 switch',
    {'wireless': 3, 'switch': 1},
    null,
    true,
  ),

  // --- counts that must not multiply when they are restated -------------------
  (
    '5 pcs, 5 pcs',
    {'pc': 5},
    null,
    true,
  ),
  (
    '3 routers 3 routers',
    {'router': 3},
    null,
    true,
  ),

  // --- phone / printer inventories --------------------------------------------
  (
    '2 routers 2 switches 6 pcs and 4 phones',
    {'router': 2, 'switch': 2, 'pc': 6, 'phone': 4},
    null,
    true,
  ),
  (
    '1 router 1 switch 5 pcs and 2 printers',
    {'router': 1, 'switch': 1, 'pc': 5, 'printer': 2},
    null,
    true,
  ),

  // --- security role phrasing --------------------------------------------------
  (
    '2 routers 2 switches 4 pcs with a firewall and vpn',
    {'router': 2, 'switch': 2, 'pc': 4, 'firewall': 1},
    null,
    true,
  ),
  (
    '2 routers 2 switches 4 pcs with hsrp and a standby address',
    {'router': 2, 'switch': 2, 'pc': 4},
    null,
    true,
  ),

  // --- VLAN phrasing does not invent devices -----------------------------------
  (
    '1 router 1 switch 10 pcs, vlan 10 for guests and vlan 20 for staff',
    {'router': 1, 'switch': 1, 'pc': 10},
    null,
    true,
  ),
  (
    '2 switches and 8 pcs for voice vlan 100',
    {'switch': 2, 'pc': 8},
    null,
    true,
  ),

  // --- model numbers are never counts ------------------------------------------
  // A model in the sentence must not be mistaken for a quantity, and must
  // still leave the bare mention meaning one device.
  (
    'a 4331 router and 2 pcs',
    {'router': 1, 'pc': 2},
    null,
    true,
  ),
  // --- multi-site phrasing variants --------------------------------------------
  // The drift guard is off on the next TWO cases BECAUSE IT FAILS, and that is a
  // bug worth keeping visible: for these briefs the parser invents an access
  // switch that BriefSlotPipeline does not see. The two readers were wired
  // together on the promise that they agree, and here they do not.
  (
    'HQ with 10 pcs and a branch with 5 pcs, 2 routers',
    {'router': 2, 'pc': 15},
    null,
    false,
  ),
  (
    'three sites, each with a router and 4 pcs',
    {'router': 3, 'pc': 12},
    null,
    false,
  ),
// =========================================================================
  // Batch 2. Every expectation here was checked against what the brief
  // MEANS first; where the parser disagreed, the case went to `knownGaps`
  // instead of being quietly rewritten to match the output. That is the whole
  // point of the discipline - a corpus that records whatever the code happens
  // to do measures nothing.
  // =========================================================================

  // --- plain inventories, every ordering the parser supports ----------------
  ('a network with 5 routers 5 switches 25 pcs', {
    'router': 5,
    'switch': 5,
    'pc': 25,
  }, null, true),
  ('lab: 1 router 2 switches 8 pcs', {'router': 1, 'switch': 2, 'pc': 8}, null, true),
  ('build 3 routers 3 switches 12 pcs 2 servers', {
    'router': 3,
    'switch': 3,
    'pc': 12,
    'server': 2,
  }, null, true),
  ('need a topology of 2 routers and 4 switches', {'router': 2, 'switch': 4}, null, true),
  ('set up 4 pcs on a switch', {'switch': 1, 'pc': 4}, null, true),
  ('one server two pcs and a router', {'router': 1, 'pc': 2, 'server': 1}, null, true),
  ('2 routers / 2 switches / 10 pcs', {'router': 2, 'switch': 2, 'pc': 10}, null, true),
  ('give me 5 pcs', {'pc': 5}, null, true),
  ('just 1 router', {'router': 1}, null, true),
  ('six pcs please', {'pc': 6}, null, true),
  ('a router and two switches', {'router': 1, 'switch': 2}, null, true),
  ('a switch and 3 pcs', {'switch': 1, 'pc': 3}, null, true),
  ('main campus 1 router 2 switches 30 pcs', {
    'router': 1,
    'switch': 2,
    'pc': 30,
  }, null, true),
  ('branch 1 router 1 switch 10 pcs', {
    'router': 1,
    'switch': 1,
    'pc': 10,
  }, null, true),
  ('1 router 2 switches 6 pcs and 1 firewall', {
    'router': 1,
    'switch': 2,
    'pc': 6,
    'firewall': 1,
  }, null, true),
  ('a network with 1 firewall 2 routers 4 pcs', {
    'router': 2,
    'pc': 4,
    'firewall': 1,
  }, null, true),
  ('2 routers 2 switches 4 pcs on 10.1.1.0/24', {
    'router': 2,
    'switch': 2,
    'pc': 4,
  }, null, true),
  ('10.0.0.0/24 network with 2 routers', {'router': 2}, null, true),
  ('build a lab with routers R1 R2 R3 and switches SW1 SW2', {
    'router': 3,
    'switch': 2,
  }, null, true),
  ('R1 R2 SW1 SW2 and 4 PCs', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('switch SW1 connected to R1', {'router': 1, 'switch': 1}, null, true),
  ('add PC1 PC2 PC3', {'pc': 3}, null, true),
  ('2 routers 2 switches 4 pcs, cisco 2911', {
    'router': 2,
    'switch': 2,
    'pc': 4,
  }, null, true),

  // --- EVERY device kind named once means one of each ------------------------
  // The inventory-list case. It is the single best breadth case in the set:
  // six kinds in one sentence, and every one of them must land.
  ('router switch pc server printer phone', {
    'router': 1,
    'switch': 1,
    'pc': 1,
    'server': 1,
    'printer': 1,
    'phone': 1,
  }, null, true),

  // --- corrections replace the number they correct ---------------------------
  ('ten routers is too many, use 2 routers', {'router': 2}, null, true),

  // --- politeness and framing must not change the plan -----------------------
  // A user who says "please" or "can you help me" is still asking for the same
  // lab. These are the cases where a chatty wrapper silently empties the plan.
  ('please make a network with 2 routers', {'router': 2}, null, true),
  ('can you help me build 3 routers 3 switches 9 pcs', {
    'router': 3,
    'switch': 3,
    'pc': 9,
  }, null, true),
  ('i want 2 routers connected with ospf', {'router': 2}, 'ospf', true),
  ('set up a server and 2 pcs', {'pc': 2, 'server': 1}, null, true),
  ('1 router 1 switch 10 pcs for a cafe', {
    'router': 1,
    'switch': 1,
    'pc': 10,
  }, null, true),

  // --- the tiny-office default, in the phrasings people actually use ---------
  // A vague brief gets the stated assumption rather than an empty plan. These
  // pin WHICH briefs count as vague, so the default cannot quietly widen into
  // answering questions nobody asked.
  ('network for a dental office', {'router': 1, 'switch': 1}, null, true),
  ('our startup needs a network', {'router': 1, 'switch': 1}, null, true),
  ('set up my home lab', {'router': 1, 'switch': 1}, null, true),
  ('i want to learn ccna, build a lab', {'router': 1, 'switch': 1}, null, true),
  ('need a topology for an exam', {'router': 1, 'switch': 1}, null, true),
  ('use 192.168.1.0/24 for the lan', {'router': 1, 'switch': 1}, null, true),

  // --- the sizing pack: a headcount expands before the parser sees it ---------
  // No drift guard: BriefSlotPipeline reads the raw brief, so it cannot know
  // about an expansion that has not happened yet.
  ('a lab for 30 users', {
    'router': 1,
    'switch': 2,
    'pc': 30,
    'server': 1,
    'firewall': 1,
    'wireless': 2,
    'cloud': 1,
  }, null, false),
  ('network for 25 employees', {
    'router': 1,
    'switch': 2,
    'pc': 25,
    'server': 1,
    'firewall': 1,
    'wireless': 1,
    'cloud': 1,
  }, null, false),

  // --- routing protocol phrasing ----------------------------------------------
  ('ospf on 3 routers', {'router': 3}, 'ospf', true),
  ('eigrp 2 routers 1 switch', {'router': 2, 'switch': 1}, 'eigrp', true),
  ('routing protocol eigrp with 3 routers', {'router': 3}, 'eigrp', true),
  ('2 routers with eigrp 4', {'router': 2}, 'eigrp', true),
  ('no routing protocol, 2 routers', {'router': 2}, 'static', true),
  ('use bgp between the sites', {}, 'bgp', true),
  // A rejected protocol with nothing positive behind it leaves the default.
  ('a router with nat', {'router': 1}, null, true),

  // --- layer-2 vocabulary must not invent or drop devices -------------------
  ('trunk between two switches', {'switch': 2}, null, true),
  ('2 switches with etherchannel', {'switch': 2}, null, true),
  ('configure vtp on the switches', {'switch': 1}, null, true),
  ('1 router 1 switch 5 pcs vlan 10', {'router': 1, 'switch': 1, 'pc': 5}, null, true),

  // --- services provision exactly one server each ----------------------------
  ('a router with dhcp', {'router': 1, 'server': 1}, null, true),
  ('a router with dns and dhcp', {'router': 1, 'server': 1}, null, true),
  ('a server with dns', {'server': 1}, null, true),
  ('1 router with an email server', {'router': 1, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs and a web server', {
    'router': 2,
    'switch': 2,
    'pc': 4,
    'server': 1,
  }, null, true),
  ('2 routers 2 switches 4 pcs, tftp server', {
    'router': 2,
    'switch': 2,
    'pc': 4,
    'server': 1,
  }, null, true),
  ('2 routers 2 switches 4 pcs with a proxy server', {
    'router': 2,
    'switch': 2,
    'pc': 4,
    'server': 1,
  }, null, true),
  ('aaa with radius 2 routers 2 switches 4 pcs', {
    'router': 2,
    'switch': 2,
    'pc': 4,
    'server': 1,
  }, null, true),

  // --- security features without a server of their own ------------------------
  ('1 router 1 switch 3 pcs port forwarding', {
    'router': 1,
    'switch': 1,
    'pc': 3,
  }, null, true),
  ('2 routers 2 switches 4 pcs hsrp', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('vpn between two routers', {'router': 2}, null, true),
  ('ipsec tunnel 2 routers', {'router': 2}, null, true),
  ('sdm on a router', {'router': 1}, null, true),
  ('dmz with a firewall and a server', {'firewall': 1, 'server': 1}, null, true),

  // --- wireless vocabulary -----------------------------------------------------
  ('wireless 3 access points and a router', {'router': 1, 'wireless': 3}, null, true),
  ('2 access points', {'wireless': 2}, null, true),
  ('wifi for the whole office', {'wireless': 1}, null, true),
  ('add wifi coverage', {'wireless': 1}, null, true),
  ('firewall 2 pcs and a router', {'router': 1, 'pc': 2, 'firewall': 1}, null, true),

  // --- systematic inventory coverage ------------------------------------------
  // Plain combinations of the shapes the contract set already proves. They
  // earn their place by pinning the ARITHMETIC across a grid: if a future
  // change makes 'and' stop joining two clauses, or a count stop carrying
  // across a comma, one of these goes red before a user does.
  ('a lab with 6 routers 6 switches 30 pcs', {'router': 6, 'switch': 6, 'pc': 30}, null, true),
  ('build 7 routers and 7 switches with 35 pcs', {'router': 7, 'switch': 7, 'pc': 35}, null, true),
  ('1 router 1 switch 1 pc', {'router': 1, 'switch': 1, 'pc': 1}, null, true),
  ('2 routers 1 switch 1 pc', {'router': 2, 'switch': 1, 'pc': 1}, null, true),
  ('1 router 2 switches 1 pc', {'router': 1, 'switch': 2, 'pc': 1}, null, true),
  ('2 routers 3 switches 6 pcs', {'router': 2, 'switch': 3, 'pc': 6}, null, true),
  ('3 routers 1 switch 9 pcs', {'router': 3, 'switch': 1, 'pc': 9}, null, true),
  ('4 routers 2 switches 12 pcs', {'router': 4, 'switch': 2, 'pc': 12}, null, true),
  ('1 router 5 switches 20 pcs', {'router': 1, 'switch': 5, 'pc': 20}, null, true),
  ('2 routers 2 switches 2 pcs', {'router': 2, 'switch': 2, 'pc': 2}, null, true),
  ('8 pcs 4 switches 2 routers', {'router': 2, 'switch': 4, 'pc': 8}, null, true),
  ('10 pcs with 3 switches', {'switch': 3, 'pc': 10}, null, true),
  ('7 pcs on 2 switches', {'switch': 2, 'pc': 7}, null, true),
  ('give me 3 routers and 3 switches', {'router': 3, 'switch': 3}, null, true),
  ('i need 4 pcs', {'pc': 4}, null, true),
  ('add 5 switches', {'switch': 5}, null, true),
  ('put in 6 routers', {'router': 6}, null, true),
  ('a server and 3 pcs', {'server': 1, 'pc': 3}, null, true),
  ('2 servers and 2 pcs', {'server': 2, 'pc': 2}, null, true),
  ('a printer and a switch', {'printer': 1, 'switch': 1}, null, true),
  ('3 phones and 2 pcs', {'phone': 3, 'pc': 2}, null, true),
  ('a firewall and 2 pcs', {'firewall': 1, 'pc': 2}, null, true),
  ('2 firewalls and 3 pcs', {'firewall': 2, 'pc': 3}, null, true),
  ('a cloud and a router', {'cloud': 1, 'router': 1}, null, true),
  ('2 clouds and a router', {'cloud': 2, 'router': 1}, null, true),
  ('an access point and a router', {'wireless': 1, 'router': 1}, null, true),
  ('4 access points', {'wireless': 4}, null, true),
  ('2 routers 2 switches 4 pcs with dns', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs with dhcp', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs with a dhcp server', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs with a web server', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs with an ftp server', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('2 routers 2 switches 4 pcs with a mail server', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1}, null, true),
  ('1 router with snmp', {'router': 1, 'server': 1}, null, true),
  ('1 router with ntp', {'router': 1, 'server': 1}, null, true),
  ('router 1 with 2 switches and a dns server', {'router': 1, 'switch': 2, 'server': 1}, null, true),
  ('ospf with 2 routers 2 switches', {'router': 2, 'switch': 2}, null, true),
  ('eigrp with 3 routers 3 switches', {'router': 3, 'switch': 3}, null, true),
  ('bgp with 2 routers', {'router': 2}, null, true),
  ('ospf 2 routers 2 switches 4 pcs', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('eigrp 3 routers 2 switches 6 pcs', {'router': 3, 'switch': 2, 'pc': 6}, null, true),
  ('static routing with 3 routers', {'router': 3}, null, true),
  ('ospf area 1 with 4 routers', {'router': 4}, null, true),
  ('router R1 switch SW1 and 2 pcs', {'router': 1, 'switch': 1, 'pc': 2}, null, true),
  ('routers R1 and R2 with switches SW1 SW2', {'router': 2, 'switch': 2}, null, true),
  ('R1 R2 R3 and 6 pcs', {'router': 3, 'pc': 6}, null, true),
  ('SW1 SW2 SW3 and 9 pcs', {'switch': 3, 'pc': 9}, null, true),
  ('R1 connects to SW1 and SW2', {'router': 1, 'switch': 2}, null, true),
  ('10.10.10.0/24 with 2 routers 2 switches 4 pcs', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('172.16.0.0/16 network 2 routers', {'router': 2}, null, true),
  ('192.168.0.0/24 with 1 router 1 switch 5 pcs', {'router': 1, 'switch': 1, 'pc': 5}, null, true),
  ('build 2 routers on 10.0.0.0/8', {'router': 2}, null, true),
  ('a cafe with 2 routers 2 switches 4 pcs', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('an office with 1 router 1 switch 6 pcs', {'router': 1, 'switch': 1, 'pc': 6}, null, true),
  ('a school with 2 routers 4 switches 20 pcs', {'router': 2, 'switch': 4, 'pc': 20}, null, true),
  ('a hotel with 2 routers 2 switches 10 pcs', {'router': 2, 'switch': 2, 'pc': 10}, null, true),
  ('what do i need for 2 routers and 2 switches', {'router': 2, 'switch': 2}, null, true),
  // The drift guard is off HERE BECAUSE IT FAILS: the parser and
  // BriefSlotPipeline disagree about the pc count on a question-shaped
  // brief. The count itself is right; the two readers are not.
  ('how many pcs for 20 users in one room', {'pc': 20}, null, false),
  ('can you make 3 routers 3 switches 9 pcs', {'router': 3, 'switch': 3, 'pc': 9}, null, true),

  // --- final inventory grid --------------------------------------------------
  ('i need a network with 2 routers and 2 switches', {'router': 2, 'switch': 2}, null, true),
  ('create a topology with 3 routers', {'router': 3}, null, true),
  ('make me a lab with 4 switches', {'switch': 4}, null, true),
  ('build a topology for 12 pcs', {'pc': 12}, null, true),
  ('2 routers 2 switches 4 pcs and wifi', {'router': 2, 'switch': 2, 'pc': 4, 'wireless': 1}, null, true),
  ('2 routers 2 switches 4 pcs and 1 firewall', {'router': 2, 'switch': 2, 'pc': 4, 'firewall': 1}, null, true),
  ('2 routers 2 switches 4 pcs and a cloud', {'router': 2, 'switch': 2, 'pc': 4, 'cloud': 1}, null, true),
  ('2 routers 2 switches 4 pcs and 2 servers', {'router': 2, 'switch': 2, 'pc': 4, 'server': 2}, null, true),
  ('2 routers 2 switches 4 pcs and 2 printers', {'router': 2, 'switch': 2, 'pc': 4, 'printer': 2}, null, true),
  ('2 routers 2 switches 4 pcs and 2 phones', {'router': 2, 'switch': 2, 'pc': 4, 'phone': 2}, null, true),
  ('2 routers 2 switches 4 pcs and 2 access points', {'router': 2, 'switch': 2, 'pc': 4, 'wireless': 2}, null, true),
  ('4 pcs attached to a router', {'router': 1, 'pc': 4}, null, true),
  ('one server connected to a router', {'router': 1, 'server': 1}, null, true),
  ('2 printers on a switch', {'switch': 1, 'printer': 2}, null, true),
  ('ospf between 2 routers 2 switches 4 pcs', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('eigrp between 4 routers', {'router': 4}, null, true),
  ('bgp for 2 routers 2 switches', {'router': 2, 'switch': 2}, null, true),
  ('configure ripv2 on 2 routers', {'router': 2}, null, true),
  ('lab with R1 R2 SW1 SW2 PC1 PC2', {'router': 2, 'switch': 2, 'pc': 2}, null, true),
  ('R1 R2 R3 SW1 SW2 SW3', {'router': 3, 'switch': 3}, null, true),
  ('a router a switch and 4 pcs', {'router': 1, 'switch': 1, 'pc': 4}, null, true),
  ('router, switch, 8 pcs', {'router': 1, 'switch': 1, 'pc': 8}, null, true),
  ('2 routers, 2 switches, 4 pcs, 1 server, 1 firewall', {'router': 2, 'switch': 2, 'pc': 4, 'server': 1, 'firewall': 1}, null, true),
  ('set up 1 router 1 switch 1 server 1 printer', {'router': 1, 'switch': 1, 'server': 1, 'printer': 1}, null, true),
  ('a small network of 2 routers 1 switch 5 pcs', {'router': 2, 'switch': 1, 'pc': 5}, null, true),
  ('a big network of 4 routers 4 switches 40 pcs', {'router': 4, 'switch': 4, 'pc': 40}, null, true),
  ('please build 2 routers 2 switches 4 pcs with ospf', {'router': 2, 'switch': 2, 'pc': 4}, null, true),
  ('can you do 3 routers 3 switches 9 pcs with eigrp', {'router': 3, 'switch': 3, 'pc': 9}, null, true),
  ('i want a network for 4 pcs and a printer', {'pc': 4, 'printer': 1}, null, true),

  // --- REAL FAILURES, lifted from the regression tests that pin them ---------
  // These briefs are not invented. Each one is a sentence a user actually
  // typed, and the expected counts are the ones the fixing test already
  // asserts. They are here because the golden set should be the first place
  // a new brief is measured, and these are the briefs that earned their tests
  // the hard way.
  //
  // Site A's device list, the branch's device list, across two sentences and
  // eleven commas. The site clause used to be split on commas, so every
  // fragment after the site word was read as a restatement and dropped: 15 of
  // the 25 PCs vanished and the branch lost its switch and both its servers.
  (
    'Build a corporate network across 2 physical sites. Site A is the '
        'headquarters with 2 routers, 2 switches, 3 servers and 15 PCs. Site B '
        'is a branch with 1 router, 1 switch, 2 servers and 10 PCs.',
    {'router': 3, 'switch': 3, 'server': 5, 'pc': 25},
    null,
    false,
  ),
  // The same shape as the 20-PC contract case above, at a larger scale. Only
  // the PC count is asserted, and deliberately so: the brief names no switch
  // count, and the app does scale switches with host count (20 PCs gives two,
  // 50 gives four). That is a sizing POLICY, not a parse fact - so pinning a
  // number here would freeze a tuning decision inside a parse contract, and
  // would stop the honest change when the ratio is retuned.
  ('two physical sites and 50 PCs', {'router': 2, 'pc': 50}, null, false),
  // An uncounted device is one of that kind - the same bare-mention rule that
  // makes "a server" one server. The conversation path is where an unknown
  // phone count becomes a QUESTION instead; that is enforced by
  // chat_plan_continuity_test, not here. Asserting phone: 0 in a single-parse
  // contract would contradict the rule the rest of the corpus relies on.
  ('2 routers 2 switches 50 pcs and some phones', {
    'router': 2,
    'switch': 2,
    'pc': 50,
    'phone': 1,
  }, null, true),

];

// ===========================================================================
// KNOWN GAPS - tier 2: real defects, pinned so they cannot rot unnoticed.
// ===========================================================================
//
// Each entry below was found by growing the corpus, not by reading the
// source. The comment says what the brief MEANS and what the app does
// instead. Every one of these is a bug, not a design choice. When a fix
// lands the case goes red and moves up into `contract`.
final List<GoldenCase> knownGaps = [
  // --- WORDS FOR END DEVICES ARE READ AS SERVERS ------------------------------
  // "hosts" in networking means end hosts - PCs. The app builds ten servers.
  // This is the most damaging gap in the corpus: it produces a confident,
  // buildable, wrong answer for a phrase students use constantly.
  (
    'Create a small business network with 1 router, 1 switch, 10 hosts',
    {'router': 1, 'switch': 1, 'server': 10},
    null,
    true,
  ),

  // --- "both" IS NOT A COUNT ---------------------------------------------------
  // "both routers" names exactly two. The app builds one.
  (
    'Packet Tracer challenge: configure static routes on both routers',
    {'router': 1},
    null,
    true,
  ),

  // --- TYPOS SILENTLY DELETE DEVICES -------------------------------------------
  // A typo must never change a COUNT, let alone erase both kinds named. The
  // app keeps the one kind it could spell and loses the other.
  (
    '2 rouer 2 swich 4 pcs',
    {'pc': 4},
    null,
    false,
  ),
  (
    '2 routers 2 swtiches 4 pcs',
    {'router': 2, 'pc': 4},
    null,
    false,
  ),

  // --- A NAMED DEVICE KIND CAN VANISH ------------------------------------------
  // "1 scanner" is a device the user asked for. The plan has none, and
  // nothing anywhere reports the loss.
  (
    'a site device list: 5 pcs, 2 printers, 1 scanner at HQ',
    {'pc': 5, 'printer': 2},
    null,
    false,
  ),
  (
    'add a printer and a scanner to the office',
    {'router': 1, 'switch': 1, 'printer': 1},
    null,
    false,
  ),

  // --- RIP IS NOT IN THE ROUTING LEXICON ---------------------------------------
  // OSPF, EIGRP, BGP and static are all recognized. RIP - a core CCNA protocol
  // - is not, so a brief that asks for it silently plans without it. The
  // earlier "no ospf" case shows the fix is a lexicon entry, not a parser
  // rewrite: rejection already leaves the routing at its default.
  (
    'configure rip, 2 routers 1 switch',
    {'router': 2, 'switch': 1},
    'static',
    false,
  ),
  // --- SITE WORDS ARE A FIXED LIST, SO A NEW SITE NAME SILENTLY DROPS A COUNT -
  // "the second floor" and "the ground floor" add up correctly, because those
  // are the site words the app knows. "the lobby" and "the cafe" are just as
  // clearly two places, and the second clause is dropped on the floor. A
  // student naming rooms or floors the app has never heard gets a plan that
  // silently under-builds.
  (
    'the lobby needs 3 access points and the cafe 2',
    {'wireless': 3},
    null,
    false,
  ),

  // --- A SECOND SITE NAMED IN PROSE DOES NOT PRODUCE A SECOND ROUTER ----------
  // "the branch router" is a distinct device at the far end of the VPN. The
  // plan carries one router and a VPN with nothing on the other side of it.
  (
    '1 router with ikev2 vpn to the branch router',
    {'router': 1},
    null,
    false,
  ),

  // --- "N OF THEM" DOES NOT RESOLVE BACK TO THE KIND --------------------------
  // "3 of them" refers to the switches named one clause earlier. The parser
  // reads the bare mention and stops at one switch.
  (
    '2960 switches 3 of them and 6 pcs',
    {'switch': 1},
    null,
    false,
  ),

  // --- A BARE MODEL NAME PRODUCES NO DEVICE AT ALL ---------------------------
  // The worst of the six. "ISR4331 and ISR4331" is two routers, written the
  // way every inventory list writes them. The plan contains ZERO routers and
  // a set of PCs with nothing to connect to. Compare contract case #4,
  // "Cisco 2911 routers", which works - so the failure is the bare model name
  // with no type word, not the model recognition itself.
  (
    'ISR4331 and ISR4331 in a branch office, 4 pcs',
    {'router': 0},
    null,
    false,
  ),

  // --- "ONE X EACH" DOES NOT MULTIPLY ACROSS THE SET -------------------------
  // "a campus of 4 buildings, one router each" is four routers. The app
  // builds one. This is the same missing multiplication as the wireless site
  // case above, reached through a different phrase.
  (
    'a campus of 4 buildings, one router each, 20 pcs total',
    {'router': 1},
    null,
    false,
  ),

  // --- THE NUMBER AFTER THE NOUN IS IGNORED ----------------------------------
  // "routers 2, switches 4, pcs 20" is how an inventory is written on a
  // whiteboard, in a ticket, and in half the CCNA labs. The parser reads the
  // bare mention and stops at one of each. Note this is the OPPOSITE order
  // from the contract cases, which all put the number first - the parser is
  // not confused by the numbers, it only ever looks backwards from the noun.
  ('routers 2, switches 4, pcs 20', {'router': 1, 'switch': 1, 'pc': 1}, null, false),

  // --- SITE COMPLETION ONLY FIRES FOR THE SITE WORDS IT KNOWS ----------------
  // "two branch offices, each with a router..." completes correctly in the
  // contract set. "stores", "sites" and "buildings" are not in that list, so
  // the same sentence shape gets no routers and no switches at all - a plan
  // of endpoints with no infrastructure, which is exactly the failure the
  // completion pass exists to prevent.
  ('4 branch offices each 5 pcs', {'pc': 20}, null, false),
  ('2 sites 3 pcs each', {'pc': 3}, null, false),
  ('campus network 2 buildings', {'router': 1, 'switch': 1}, null, false),

  // --- "EACH" DOES NOT MULTIPLY ACROSS TWO NAMED PLACES -----------------------
  ('hq and branch, each with a router', {'router': 1}, null, false),
  ('3 stores each with a router and 2 pcs', {'router': 1, 'pc': 2}, null, false),
  ('two sites connected by a wan', {'router': 1, 'switch': 1}, null, false),

  // --- "PER ROOM" DOES NOT MULTIPLY BY THE ROOM COUNT -------------------------
  ('one access point per room, 4 rooms', {'router': 1, 'switch': 1, 'wireless': 1}, null, false),

  // --- A VAGUE "SMALL OFFICE X" MISSES THE DEFAULT ---------------------------
  // "build me something for the office" gets the tiny-office default. "small
  // office with 8 pcs" does not, even though it names the same thing plus a
  // count - so the user gets eight PCs and no router to put them behind.
  ('small office with 8 pcs', {'pc': 8}, null, false),

  // --- BARE MODEL NAMES, EVEN TWO DIFFERENT ONES ------------------------------
  // The second instance of the bare-model bug from above. "a 2911 and a 2960"
  // names a router AND a switch in the way every gear list writes them, and
  // the plan comes back with three PCs and nothing else.
  ('a 2911 and a 2960 with 3 pcs', {'pc': 3}, null, false),
  ('catalyst 2960 switches 2 of them', {'switch': 1}, null, false),

  // --- RIP, AGAIN, IN ITS MOST NATURAL SENTENCE ------------------------------
  // Filed once with a command-style brief; repeated here because "rip for a
  // simple lab" is how a beginner actually asks for it.
  ('rip for a simple lab', {'router': 1, 'switch': 1}, 'static', false),
  ('static routes on both routers', {'router': 1}, null, false),

  // --- NO RATIO RULE: "A SWITCH PER N PCS" IS NOT COMPUTED --------------------
  // Sizing guidance written as a ratio is how network staff actually brief a
  // build, and it needs arithmetic the parser does not do. Two counts are
  // lost here, not one: the parser keeps the "10 pcs" it read first and drops
  // the "30 pcs total" restatement, so both the endpoints AND the switch
  // count are wrong. The restatement case is already pinned in `contract`
  // ("the second floor needs 6; the ground floor needs 4") - so a restated
  // total is only honoured when it lands in a clause the site logic owns.
  ('a switch per 10 pcs, 30 pcs total', {'switch': 1, 'pc': 10}, null, false),

  // --- A MENTIONED COUNT CAN BE OVERCOUNTED ---------------------------------
  // The inverse failure, and the more alarming one: the user asked for two
  // switches and got three. Overbuilding is harder to notice than
  // underbuilding, so nothing downstream catches it either.
  ('6 pcs spread over 2 switches', {'switch': 3, 'pc': 6}, null, false),
];

// ===========================================================================
// OBSERVED - tier 3: breadth. Real briefs, weak but real guarantees.
// ===========================================================================
//
// Asserted invariants, and nothing more:
//   1. the brief parses without throwing;
//   2. the plan is not empty;
//   3. every device kind the brief names out loud survives into the plan.
//
// (3) is the one that earns its keep. It is what caught the dropped scanner
// and the typo-deleted routers, and it needs no expectation of HOW MANY,
// so it scales to briefs nobody has read yet.
final List<ObservedCase> observed = [
  // device kinds named in the brief -> kinds that must appear
  ('a small retail shop with 1 router, 1 switch, 6 pcs and 2 printers', {
    'router',
    'switch',
    'pc',
    'printer',
  }),
  ('branch office: 1 router, 2 switches, 12 pcs', {'router', 'switch', 'pc'}),
  ('lab with 3 routers 3 switches 9 pcs and 2 servers', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('a cafe needs wifi, 2 access points and 1 router', {
    'router',
    'wireless',
  }),
  ('warehouse with 20 pcs, 2 switches and a printer', {
    'switch',
    'pc',
    'printer',
  }),
  ('hospital lab: 2 routers, 4 switches, 30 pcs, 2 servers', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('our school has 3 classrooms, each a switch and 10 pcs', {'switch', 'pc'}),
  ('home network with 1 router, 1 switch and 4 pcs', {
    'router',
    'switch',
    'pc',
  }),
  ('training lab: 2 routers, 2 switches, 8 pcs, 1 firewall', {
    'router',
    'switch',
    'pc',
    'firewall',
  }),
  ('a data centre lab with 2 routers and 4 servers', {
    'router',
    'server',
  }),
  ('two offices joined by a wan link, 1 router each and 8 pcs', {
    'router',
    'pc',
  }),
  ('i want 1 router 1 switch 2 pcs and a cloud for internet', {
    'router',
    'switch',
    'pc',
    'cloud',
  }),
  ('library: 6 pcs, 1 switch, 1 router and 2 printers', {
    'router',
    'switch',
    'pc',
    'printer',
  }),
  ('restaurant with 3 pcs, 1 switch, 1 router and a phone system', {
    'router',
    'switch',
    'pc',
  }),
  ('office network: 1 router, 1 switch, 15 pcs, 1 server', {
    'router',
    'switch',
    'pc',
    'server',
  }),

  // --- more real briefs, same three invariants -------------------------------
  ('a dentist office with 2 pcs 1 switch and 1 router', {'router', 'switch', 'pc'}),
  ('bakery: 1 router, 1 switch, 4 pcs, 1 printer', {
    'router',
    'switch',
    'pc',
    'printer',
  }),
  ('a law firm with 30 pcs across 2 switches', {'switch', 'pc'}),
  ('gym with 10 pcs and wifi', {'pc', 'wireless'}),
  ('a factory line needs 2 routers and 4 pcs', {'router', 'pc'}),
  ('small hotel: 1 router 2 switches 20 pcs 1 server', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('call center 50 pcs 2 switches', {'switch', 'pc'}),
  ('a classroom lab with 10 pcs 1 switch 1 router', {
    'router',
    'switch',
    'pc',
  }),
  ('warehouse scanners and 4 pcs on 1 switch', {'switch', 'pc'}),
  ('an office with a firewall 2 routers 10 pcs', {'router', 'pc', 'firewall'}),
  ('our branch office has 1 router 1 switch 8 pcs', {
    'router',
    'switch',
    'pc',
  }),
  ('a design studio with 12 pcs and 2 switches', {'switch', 'pc'}),
  ('ccna lab 2 routers 2 switches 6 pcs', {'router', 'switch', 'pc'}),
  ('packet tracer lab for ospf 3 routers', {'router'}),
  ('a clinic with 6 pcs 1 switch 1 router 1 server', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('small business: 15 pcs 2 switches 1 router', {'router', 'switch', 'pc'}),
  ('a hotel lobby needs 2 access points and a router', {
    'router',
    'wireless',
  }),
  ('network for a school with 40 pcs', {'pc'}),
  ('i need a lab with 2 routers and 4 switches', {'router', 'switch'}),
  ('set up 3 switches and 12 pcs', {'switch', 'pc'}),
  ('a training room with 8 pcs 1 switch', {'switch', 'pc'}),
  ('retail store 2 pcs 1 switch 1 router 2 phones', {
    'router',
    'switch',
    'pc',
    'phone',
  }),
  ('a pharmacy needs 3 pcs and a server', {'pc', 'server'}),
  ('office network with wireless 2 routers', {'router', 'wireless'}),
  ('a cafe needs 3 pcs 1 switch 1 router wifi', {
    'router',
    'switch',
    'pc',
    'wireless',
  }),
  ('museum lab 4 routers 4 switches 16 pcs', {'router', 'switch', 'pc'}),
  ('a startup: 2 routers 1 switch 10 pcs 1 server', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('community centre 10 pcs 1 switch', {'switch', 'pc'}),
  ('a lab with a firewall 2 routers 6 pcs', {'router', 'pc', 'firewall'}),
  ('our new office needs 25 pcs and 2 switches', {'switch', 'pc'}),
  ('a barber shop with 2 pcs and a router', {'router', 'pc'}),
  ('hotel with 2 routers 4 switches 40 pcs 2 servers', {
    'router',
    'switch',
    'pc',
    'server',
  }),
  ('a lab for 2 sites each with a router and 5 pcs', {'router', 'pc'}),
  ('an office with 1 router 3 switches 18 pcs 2 printers', {
    'router',
    'switch',
    'pc',
    'printer',
  }),
  ('study group lab 1 switch 4 pcs', {'switch', 'pc'}),
  ('a new branch needs 1 router 1 switch 12 pcs', {
    'router',
    'switch',
    'pc',
  }),
  ('conference wifi 6 access points', {'wireless'}),
  ('a lab with 2 routers and a server for dns', {'router', 'server'}),
  ('our office 2 switches 14 pcs 1 router', {'router', 'switch', 'pc'}),
  ('a network for a bookshop 3 pcs 1 router', {'router', 'pc'}),
  ('classroom with 12 pcs 2 switches', {'switch', 'pc'}),
  ('a lab with 4 routers 4 switches 20 pcs', {'router', 'switch', 'pc'}),
  ('small office 1 router 1 switch 5 pcs', {'router', 'switch', 'pc'}),
  ('a media lab with 2 pcs and a printer', {'pc', 'printer'}),
];
