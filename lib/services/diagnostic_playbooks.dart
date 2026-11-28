/// The fault corpus behind [NetworkingPlaybooks].
///
/// A senior engineer does not answer "it is broken" with a definition.
/// They say what the observed state proves, rank the causes that fit it,
/// name the one command that separates them, and state the rule that keeps
/// the fix from coming back. Each entry below is one such playbook:
///
/// * [subjects] name the technology the symptom belongs to, so "stuck in
///   active" is never answered with OSPF text when the message says BGP.
/// * [signals] are the symptom phrasings that select this playbook. They are
///   matched as phrases, and a longer phrase wins, so "stuck in exstart"
///   beats a generic "stuck".
/// * [causes] are ranked most-likely-first and each one carries its own
///   discriminator, because a list of five causes with no way to tell them
///   apart is not an answer.
/// * [checks] are read-only commands with what each one proves.
/// * [rule] is the judgment call: what would change the answer, and the
///   mistake that turns one fault into two.
///
/// This file is data only; matching and rendering live in
/// `networking_playbooks.dart`.
library;

class PlaybookCheck {
  /// The read-only command to run.
  final String command;

  /// What the output proves, in one line.
  final String proves;

  const PlaybookCheck(this.command, this.proves);
}

class PlaybookVariant {
  /// The platform this command set belongs to (NX-OS, Junos, EOS...).
  final String platform;
  final String commands;

  const PlaybookVariant(this.platform, this.commands);
}

class DiagnosticPlaybook {
  final String id;

  /// The state this playbook diagnoses, phrased the way an engineer says it.
  final String title;

  /// Technology words that must appear. Empty means the signals are
  /// specific enough on their own.
  final List<String> subjects;

  /// Symptom phrasings that select this playbook.
  final List<String> signals;

  /// Phrases that mean this playbook is not the right one.
  final List<String> excludes;

  /// What the observed state actually proves.
  final String meaning;

  /// Ranked causes, most likely first, each with its discriminator.
  final List<String> causes;

  final List<PlaybookCheck> checks;

  /// The fix, once a check names the cause.
  final String fix;

  /// The judgment call and the mistake that turns one fault into two.
  final String rule;

  /// Equivalent commands on other platforms. Empty when IOS is the honest
  /// answer.
  final List<PlaybookVariant> variants;

  const DiagnosticPlaybook({
    required this.id,
    required this.title,
    this.subjects = const [],
    required this.signals,
    this.excludes = const [],
    required this.meaning,
    required this.causes,
    required this.checks,
    required this.fix,
    required this.rule,
    this.variants = const [],
  });
}

/// Ordered for readability only; matching is by phrase length.
const List<DiagnosticPlaybook> diagnosticPlaybooks = [
  DiagnosticPlaybook(
    id: 'bgp-active',
    title: 'BGP neighbour stuck in Active',
    subjects: ['bgp', 'ebgp', 'ibgp', 'border gateway protocol'],
    signals: [
      'stuck in active',
      'in active state',
      'active state',
      'stays active',
      'stuck active',
      'shows active',
      'is active',
      'peer active',
    ],
    excludes: ['hsrp', 'vrrp', 'standby'],
    meaning:
        'Active means the router keeps trying to open TCP 179 and the peer '
        'never accepts. No OPEN has been exchanged, so the AS number, the '
        'password and the route policy have not been tested yet - this is a '
        'transport failure, not a BGP policy failure.',
    causes: [
      'No route to the exact neighbour address. A default route that points '
          'into a black hole looks like a route and behaves like none.',
      'Something in the path drops TCP 179: an inbound ACL on the peer, a '
          'firewall, provider uRPF, or an interface ACL. This is the most '
          'common cause when the peer is a provider edge.',
      'The peer listens on a different address than the one you configured '
          '(loopback vs physical, or the wrong VIP), or it sources its reply '
          'from a different address.',
      'eBGP across more than one hop without ebgp-multihop. The SYN dies at '
          'TTL 1 and both sides look Active.',
      'The far side is in Idle because it cannot reach you. BGP cannot come '
          'up one-sided, so fix the side with no route first.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route <peer>',
        'the neighbour address must resolve through a real route, not a '
            'default that leads nowhere',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer>',
        'the configured remote address, update-source and last reset reason; '
            'a changing local address is a source-selection fault',
      ),
      PlaybookCheck(
        'telnet <peer> 179 (or Test-NetConnection <peer> -Port 179)',
        'a refusal means IP works and the BGP socket is closed; a timeout '
            'means the SYN is being dropped in the path',
      ),
      PlaybookCheck(
        'show ip bgp summary',
        'State and Up/Down; Active with a timer climbing by about 60 seconds '
            'is a fresh attempt each time, not a stuck process',
      ),
    ],
    fix:
        'Fix the first check that fails. For loopback peering, add '
        'neighbor <ip> update-source Loopback0 on BOTH sides and make the '
        'loopbacks reachable. For eBGP through a device, use a direct link or '
        'ebgp-multihop plus a route, and never use it to paper over a missing '
        'route. Open 179 only between the two peer addresses, not to the world.',
    rule:
        'Active is TCP failing. Idle is not even trying. OpenSent or '
        'OpenConfirm is TCP working but the OPEN disagreeing. Established with '
        'zero prefixes is policy or next hop. Diagnose the layer before you '
        'change a single policy line.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show bgp ipv4 unicast summary; show bgp neighbor <peer>',
      ),
      PlaybookVariant('Junos', 'show bgp neighbor <peer>; show route <peer>'),
    ],
  ),
  DiagnosticPlaybook(
    id: 'bgp-idle',
    title: 'BGP neighbour stuck in Idle',
    subjects: ['bgp', 'ebgp', 'ibgp', 'border gateway protocol'],
    signals: [
      'stuck in idle',
      'in idle',
      'idle state',
      'stays idle',
      'goes idle',
    ],
    meaning:
        'Idle means BGP is not attempting a session at all. Either there is '
        'no route to the neighbour, the neighbour is shut or misconfigured, or '
        'the session just dropped and is waiting to retry. It usually turns '
        'into Active within a minute - if it does not, nothing is starting it.',
    causes: [
      'No route to the neighbour address, so the peer is never started.',
      'neighbor ... shutdown, or a peer-group that is shut or has no '
          'remote-as, so the neighbour inherits an incomplete config.',
      'No update-source while the outgoing interface changes (a flap, a '
          'floating route), so the peer sees a different source each time.',
      'A just-expired session: hold timer, BFD down or maximum-prefix. The '
          'last reset reason says which.',
      'The neighbour lives in a VRF but was queried in the global table, so '
          'the session you are looking at is not the one that is up.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp summary',
        'Idle plus the Up/Down time; if it flips to Active, switch to that '
            'playbook instead of guessing here',
      ),
      PlaybookCheck(
        'show ip route <peer>',
        'no route means BGP has nothing to connect to',
      ),
      PlaybookCheck(
        'show run | section router bgp',
        'remote-as, update-source, shutdown, peer-group membership - the '
            'whole cause is usually visible in one screen',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> | include BGP state|Last reset|hold',
        'the reset reason turns "Idle" into a specific fault',
      ),
    ],
    fix:
        'Restore reachability, then correct the neighbour statement. Loopback '
        'peering needs update-source on both sides and IGP reachability. '
        'Remove shutdown, supply remote-as. If the reset reason is a hold '
        'timer, the path is dropping keepalives - prove it with ping/BFD and '
        'look at CoPP or a policer before touching BGP timers.',
    rule:
        'Idle after a session that was working is almost always a routing '
        'change, not a BGP change. Compare the route to the peer with the last '
        'known-good state before editing BGP.',
    variants: [PlaybookVariant('NX-OS', 'show bgp ipv4 unicast summary')],
  ),
  DiagnosticPlaybook(
    id: 'bgp-no-prefixes',
    title: 'BGP session is up but no prefixes arrive',
    subjects: ['bgp', 'ebgp', 'ibgp', 'border gateway protocol', 'pfxrcd'],
    signals: [
      'no prefixes',
      'zero prefixes',
      '0 prefixes',
      'pfxrcd 0',
      'not receiving routes',
      'not receiving prefixes',
      'not advertising',
      'no routes from',
      'routes not showing',
      'missing routes',
      'routes are missing',
      'dropping prefixes',
      'dropping bgp prefixes',
      'not visible on the looking glass',
      'prefix not visible',
    ],
    meaning:
        'Established with PfxRcd 0 splits into three different faults: the '
        'sender is not advertising, the receiver is filtering what arrived, or '
        'the prefix is in the BGP table but unusable (next hop or RIB '
        'failure). Prove the direction before changing policy.',
    causes: [
      'The sender has no exact matching route for its network statement. '
          'BGP advertises a network only when an exact prefix is in the IGP, '
          'static or connected table.',
      'An outbound filter on the sender: prefix-list, route-map, '
          'distribute-list, or a missing default-originate.',
      'iBGP next hop unreachable at the receiver. iBGP does not rewrite the '
          'next hop, so the edge needs next-hop-self or the receiver needs an '
          'IGP route to it.',
      'An inbound filter or an AS-path loop - your own AS already in the '
          'path - which is visible before policy in show ip bgp.',
      'Address-family mismatch: the peer sends IPv4 unicast while you '
          'activated only VPNv4, EVPN or IPv6.',
    ],
    checks: [
      PlaybookCheck(
        'on the sender: show ip bgp neighbors <us> advertised-routes',
        'the definitive direction test: empty means the fault is on the '
            'sender, not the receiver',
      ),
      PlaybookCheck(
        'show ip bgp <prefix>',
        'is the prefix in the BGP table at all, what is the next hop, and is '
            'it marked r (RIB failure)?',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> routes',
        'what the receiver accepted before its inbound policy ran',
      ),
      PlaybookCheck(
        'show ip route <prefix>',
        'BGP table present but no RIB entry means next hop, distance or CEF - '
            'not an advertisement problem',
      ),
    ],
    fix:
        'If advertised-routes is empty, fix the sender: add the exact route '
        'the network statement needs, or correct its outbound policy. If the '
        'prefix is in the BGP table with r, fix the next hop. If it is in the '
        'RIB, follow the route to its consumer - the fault is downstream.',
    rule:
        'Run advertised-routes on the sender before adding a filter on the '
        'receiver. Filters added on the wrong side are the most common '
        'self-inflicted BGP outage.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show bgp ipv4 unicast neighbors <peer> advertised-routes; '
            'show bgp ipv4 unicast <prefix>',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'bgp-max-prefix',
    title: 'BGP session shut by maximum-prefix',
    subjects: ['bgp', 'ebgp', 'ibgp'],
    signals: [
      'maximum-prefix',
      'max-prefix',
      'prefix limit',
      'max prefix',
      'shut down due to prefix',
      'prefix-limit',
    ],
    meaning:
        'The peer sent more prefixes than maximum-prefix allows, so the '
        'session was torn down. It will retry and may flap on a timer until '
        'either the limit or the leak is fixed.',
    causes: [
      'The peer is leaking more specifics, a full table, or a default plus '
          'the table it covers - usually a missing outbound filter on the '
          'sender.',
      'The limit was set to today\'s observed count with no headroom for '
          'growth.',
      'A redistribution of connected or static routes into BGP with no '
          'prefix-list, which grows every time a subnet is added.',
      'warning-only was intended but the config uses the default shutdown '
          'behaviour.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp summary',
        'PfxRcd at the limit and the state cycling between Idle and Active',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> | include maximum|prefix|reset',
        'the configured limit and the reset reason',
      ),
      PlaybookCheck(
        'show log | include MAXPFX|maximum-prefix',
        'the timestamp of the shutdown, which matches the last change on the '
            'sender',
      ),
    ],
    fix:
        'Raise the limit to the contracted count plus growth headroom and set '
        'a warning threshold at 80 percent, or use warning-only while the leak '
        'is fixed. Then find the leak: an outbound prefix-list on the sender is '
        'the real repair.',
    rule:
        'Set max-prefix from the peering agreement, never from what you '
        'happen to see today. Alert at 80 percent so the first news of a leak '
        'is not a dropped session.',
  ),

  DiagnosticPlaybook(
    id: 'ospf-exstart',
    title: 'OSPF neighbour stuck in EXSTART or EXCHANGE',
    subjects: ['ospf', 'ospfv3', 'ospf neighbor', 'adjacency'],
    signals: [
      'exstart',
      'exstart exchange',
      'exchange state',
      'stuck in exchange',
      'stuck in exstart',
    ],
    meaning:
        'EXSTART means hellos succeeded and the two routers are negotiating '
        'who starts the database exchange. Sticking there is almost always an '
        'MTU mismatch: the first DBD packet is larger than the neighbour can '
        'accept, so the exchange retries forever.',
    causes: [
      'MTU mismatch on the link. One side at 1500 and the other at 1400, or '
          'a tunnel/Jumbo mismatch. This is the cause in the large majority of '
          'EXSTART cases.',
      'Duplicate router IDs on the segment, so both think they are the '
          'master.',
      'Unicast reachability between the neighbours is broken even though '
          'multicast hellos arrive (an ACL that permits 224.0.0.5 but not '
          'unicast).',
      'Network type mismatch: one side broadcast, the other point-to-point, '
          'or an NBMA cloud without neighbour statements.',
      'Damaged or fragmented DBD packets from an MTU or hardware issue, '
          'visible as retransmissions and drops.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf interface <intf>',
        'the MTU on both ends side by side, plus the network type, hello and '
            'dead timers',
      ),
      PlaybookCheck(
        'show ip ospf neighbor <router-id>',
        'state and the retransmit count; a climbing retransmit count points '
            'at MTU or one-way unicast',
      ),
      PlaybookCheck(
        'show ip ospf | include router ID',
        'both neighbours must have different router IDs',
      ),
      PlaybookCheck(
        'debug ip ospf adj',
        'the DBD exchange with the actual MSS/MTU complaint - run it briefly, '
            'then turn it off',
      ),
    ],
    fix:
        'Make the MTU match on both ends. If the design needs different MTUs, '
        'put ip ospf mtu-ignore on both sides knowing that you just accepted '
        'the risk of a fragmented database; the better fix is a consistent '
        'MTU. Clear the adjacency with clear ip ospf process only after the '
        'fix, and never clear it on a production router without checking the '
        'impact first.',
    rule:
        'EXSTART is a data-plane disagreement, not a hello problem. Hellos '
        'prove L3 multicast works; the DBD proves the link can carry the '
        'router\'s idea of a maximum frame. Fix the MTU, not the timers.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip ospf interface <intf>; show ip ospf neighbor',
      ),
      PlaybookVariant(
        'Junos',
        'show ospf interface detail; show ospf neighbor',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'ospf-init',
    title: 'OSPF neighbour stuck in INIT',
    subjects: ['ospf', 'ospfv3', 'ospf neighbor', 'adjacency'],
    signals: ['init state', 'stuck in init', 'in init', 'only init'],
    meaning:
        'INIT means this router hears the neighbour\'s hellos but the '
        'neighbour does not list this router as seen. Hellos are arriving one '
        'way, or the parameters inside them do not agree.',
    causes: [
      'Area mismatch. The hello carries the area ID and a router will not '
          'form an adjacency across areas.',
      'Hello or dead interval mismatch. Both are carried in the hello, so '
          'the timers must match exactly.',
      'Authentication mismatch: type, key or key ID. One side drops the '
          'packet before it ever counts as a neighbour.',
      'An ACL or firewall blocking 224.0.0.5 in one direction, or blocking '
          'the unicast replies.',
      'Passive interface or a network-type mismatch on one side, so the '
          'router sends hellos but never processes the peer\'s.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf interface <intf>',
        'area, network type, hello/dead, authentication - compare it with the '
            'same output on the peer',
      ),
      PlaybookCheck(
        'show ip ospf neighbor',
        'the state and the address the hello came from',
      ),
      PlaybookCheck(
        'debug ip ospf hello',
        'shows hellos sent and received and the exact mismatch reason',
      ),
    ],
    fix:
        'Make area, timers, authentication and network type identical on both '
        'ends. Remove the passive interface from the transit link. If an ACL '
        'is in the path, permit 224.0.0.5 and 224.0.0.6 (and the unicast '
        'addresses) in both directions.',
    rule:
        'INIT is a hello-level failure; EXSTART is a DBD-level failure. Do '
        'not tune SPF timers for a hello problem - the neighbour never got far '
        'enough for SPF to matter.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show ospf interface detail; show ospf neighbor',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'ospf-twoway',
    title: 'OSPF neighbour stuck in 2-WAY',
    subjects: ['ospf', 'ospfv3', 'ospf neighbor', 'adjacency'],
    signals: [
      'two way',
      '2-way',
      '2way',
      'twoway',
      'stuck in 2way',
      'stuck in two way',
    ],
    meaning:
        '2-WAY is normal on a broadcast segment between two routers that are '
        'not the DR or BDR - they never need a full adjacency. It is a fault '
        'only on a point-to-point link, or when no router on the segment '
        'reaches FULL.',
    causes: [
      'Normal behaviour between DROthers on a broadcast or NBMA segment - '
          'check whether the DR and BDR are FULL before calling it a fault.',
      'Both interfaces at priority 0, so no router can become DR and the '
          'segment never converges.',
      'Duplicate router IDs, which makes one router refuse the adjacency.',
      'On a point-to-point link: a network-type mismatch or unicast filtering '
          'that lets hellos through but not the DBD exchange.',
      'An NBMA frame-relay or DMVPN hub-spoke segment where the DR must be '
          'the hub and is not.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf neighbor',
        'are the DR and BDR FULL? If yes, the 2-WAY rows are correct',
      ),
      PlaybookCheck(
        'show ip ospf interface <intf>',
        'priority, network type and DR/BDR addresses',
      ),
      PlaybookCheck(
        'show ip ospf | include router ID',
        'duplicate router IDs are visible here',
      ),
    ],
    fix:
        'On a broadcast segment, set the core to a higher priority and give '
        'the access side priority 0 so the election is deliberate. On a '
        'point-to-point link, fix the network type to point-to-point. Never '
        'clear the process to hide an election you did not design.',
    rule:
        '2-WAY is a diagnosis, not always a fault. Read who is DR before you '
        'change anything - the fastest way to break a healthy segment is to '
        'force an adjacency it never needed.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip ospf neighbor; show ip ospf interface brief',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'ospf-loading',
    title: 'OSPF neighbour stuck in LOADING',
    subjects: ['ospf', 'ospfv3', 'ospf neighbor', 'adjacency'],
    signals: ['loading state', 'stuck in loading', 'in loading'],
    meaning:
        'LOADING means the exchange finished but LSAs that were requested in '
        'the database description never arrived. The neighbour is waiting on '
        'specific link-state requests that are being dropped or lost.',
    causes: [
      'Packet loss or an MTU problem on the link, so LSR/LSU retransmissions '
          'never complete.',
      'An ACL or CoPP policy that permits hellos and DBD but drops LSR/LSU '
          'unicast traffic.',
      'A router with a damaged or full LSDB that cannot answer the request.',
      'One side flapping during the exchange, so the queue is stale - often '
          'seen with a marginal link that passes just enough traffic to look '
          'up.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf neighbor <router-id>',
        'the retransmit and request counters, and whether the state moves',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include errors|drops|CRC',
        'physical loss is the usual root cause behind LOADING',
      ),
      PlaybookCheck(
        'debug ip ospf adj',
        'shows the LSR/LSU exchange and what is being retried',
      ),
    ],
    fix:
        'Fix the loss first: cable, optic, duplex, CRC. Then remove any ACL or '
        'CoPP rule that treats OSPF unicast differently from its multicast. '
        'Clear the adjacency only after the link is clean.',
    rule:
        'LOADING is a delivery problem, not a database problem. A perfectly '
        'correct LSDB on both sides still sticks in LOADING if the packets '
        'carrying it are dropped.',
  ),
  DiagnosticPlaybook(
    id: 'isis-adjacency',
    title: 'IS-IS adjacency not coming up',
    subjects: ['isis', 'is-is', 'intermediate system'],
    signals: [
      'not coming up',
      'no adjacency',
      'stuck in init',
      'adjacency down',
      'not forming',
      'flapping',
    ],
    meaning:
        'IS-IS adjacency states are DOWN, INIT and UP. INIT means hellos are '
        'seen one way. Unlike OSPF, IS-IS runs directly over layer 2, so a '
        'layer-2 mismatch or a padding/MTU issue can break it while IP still '
        'pings.',
    causes: [
      'Level mismatch: one interface is level-1 only, the other level-2 '
          'only, so they never share a level.',
      'Area mismatch: L1 adjacencies require the same area ID; L2 does not '
          'care, so an L2-only design hides the mistake until a migration.',
      'MTU/padding mismatch. IS-IS pads hellos to the interface MTU, and a '
          'link that cannot carry the padded hello stays in INIT.',
      'Duplicate system IDs (the NET), which is a design error, not a link '
          'error.',
      'Authentication mismatch or a layer-2 encapsulation mismatch (one side '
          'trunking, the other access).',
    ],
    checks: [
      PlaybookCheck('show isis neighbors', 'state and level per neighbour'),
      PlaybookCheck(
        'show isis interface <intf>',
        'circuit type, level, hello padding and the MTU',
      ),
      PlaybookCheck(
        'show isis database',
        'duplicate system IDs and the level each router is advertising into',
      ),
    ],
    fix:
        'Match the level and area on both ends, keep the NET unique, and '
        'either fix the MTU or disable hello padding consistently on both '
        'sides. Confirm the layer-2 path with show cdp/lldp neighbors before '
        'touching IS-IS.',
    rule:
        'IS-IS sits under IP. If the adjacency is down but IP works, the '
        'problem is in the layer-2 details IS-IS depends on - level, MTU, '
        'padding, authentication - not in the IP addressing.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show isis adjacency; show isis interface detail',
      ),
    ],
  ),

  DiagnosticPlaybook(
    id: 'eigrp-sia',
    title: 'EIGRP stuck in Active (SIA)',
    subjects: ['eigrp'],
    signals: [
      'stuck in active',
      'sia',
      'active state',
      'stuck active',
      'stays active',
      'active timer',
    ],
    meaning:
        'EIGRP goes Active when a route is lost and it has no feasible '
        'successor. It sends queries to every neighbour; if any query is not '
        'answered before the active timer (three minutes by default), the '
        'route is declared Stuck in Active and the neighbour that failed to '
        'answer is dropped.',
    causes: [
      'The query or the reply was lost: an ACL, a congested link, a policer, '
          'or a one-way path. Look for the neighbour that did not answer.',
      'The query went too far. Without stub routing or summarization at the '
          'edge, one failed access link queries the whole domain.',
      'A neighbour is down or being reset, so its queries can never return.',
      'Redistribution or a distribute-list creates a route that cannot be '
          'resolved, so the query loops in policy.',
      'The network is genuinely large and slow to converge - a design '
          'problem that shows up as SIA after every event.',
    ],
    checks: [
      PlaybookCheck(
        'show ip eigrp topology active',
        'the route in Active, the query origin, and which neighbour has not '
            'replied',
      ),
      PlaybookCheck(
        'show ip eigrp neighbors',
        'hold timers and reset counts; a neighbour that keeps resetting is '
            'the one losing packets',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include errors|drops|CRC',
        'loss on the link explains a lost query before any EIGRP config does',
      ),
      PlaybookCheck(
        'show log | include DUAL|SIA|EIGRP',
        'the exact neighbour and route that triggered the SIA',
      ),
    ],
    fix:
        'Fix the transport loss first. Then shrink the query domain: '
        'eigrp stub connected summary on branch routers, summary-address at '
        'area boundaries, and distribute-lists that do not create '
        'unresolvable routes. Stub is the single highest-value change on a '
        'hub-and-spoke network.',
    rule:
        'SIA is a query-scope disease. Adding bandwidth fixes the symptom '
        'once; summarization and stub routing fix it for every future event.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip eigrp topology active; show ip eigrp neighbors',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'route-missing',
    title: 'A route is missing from the routing table',
    subjects: ['route', 'routing table', 'bgp', 'ospf', 'eigrp', 'rib'],
    signals: [
      'not in routing table',
      'not in the routing table',
      'missing from routing table',
      'not installed',
      'route missing',
      'doesn\'t show in show ip route',
      'does not show in show ip route',
      'not showing in the routing table',
      'rib failure',
      'rib-failure',
    ],
    meaning:
        'A route can exist in a protocol table and still not be installed. '
        'The routing table (RIB) is a competition: the longest prefix wins, '
        'then the lowest administrative distance, then the metric. If a '
        'protocol shows the prefix and show ip route does not, one of those '
        'three decided against it.',
    causes: [
      'A more specific prefix for the same destination is already installed, '
          'so the summary is unused - correct behaviour, not a fault.',
      'A lower administrative distance won: connected 0, static 1, eBGP 20, '
          'EIGRP 90, OSPF 110, IS-IS 115, RIP 120, iBGP 200.',
      'The next hop is unreachable (recursive lookup failed), so the route is '
          'marked inaccessible - common with iBGP and a missing route to the '
          'peer address.',
      'An inbound or outbound filter removed it: distribute-list, prefix-list, '
          'route-map, or an ACL on the protocol.',
      'It is in a different VRF, or the interface is down so a connected '
          'route never appears.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route <prefix>',
        'what is actually installed and by which source, with the distance',
      ),
      PlaybookCheck(
        'show ip bgp <prefix> / show ip ospf database / show ip eigrp topology',
        'the protocol view: present, valid next hop, and any r or inaccessibility '
            'marker',
      ),
      PlaybookCheck(
        'show ip route vrf <name> <prefix>',
        'proves the route is not simply in another VRF',
      ),
      PlaybookCheck(
        'show ip cef <prefix>',
        'the forwarding entry; an unresolved or drop adjacency explains '
            'control-plane/forwarding disagreement',
      ),
    ],
    fix:
        'Match the cause: withdraw the more specific competitor, lower the '
        'distance only with a documented reason, repair the recursive next hop, '
        'or remove the filter. Change one input, then re-check show ip route - '
        'never change distance and filter at the same time.',
    rule:
        'Protocol table and routing table are different answers. Always say '
        'which one you are looking at; "the route is there" means nothing '
        'until you name the table.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip route <prefix>; show ip route vrf all <prefix>',
      ),
      PlaybookVariant(
        'Junos',
        'show route <prefix> detail; show route table inet.0',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'routing-loop',
    title: 'Packets loop between routers',
    subjects: ['route', 'routing', 'traceroute', 'ttl', 'loop'],
    signals: [
      'routing loop',
      'ttl exceeded',
      'traceroute loops',
      'loops between',
      'hops back and forth',
      'keeps looping',
      'ttl expired',
    ],
    meaning:
        'A routing loop is two or more routers each believing the other is '
        'the correct next hop. TTL expiry, a traceroute that revisits the same '
        'addresses, and a link that passes traffic only to have it return are '
        'all the same fault seen from different tools.',
    causes: [
      'A summary or default route pointing back toward the source while a '
          'more specific route points out - the classic black-hole/summary '
          'asymmetry.',
      'Mutual redistribution without tags or filters, so each protocol '
          'learns the other\'s route back.',
      'A static route with the wrong next hop or interface (especially a '
          'default route on both sides of a link).',
      'A stale route that was never withdrawn after a link failure, or a '
          'floating static that activated on the wrong side.',
      'Policy-based routing that sends traffic to a next hop whose return path '
          'is not the same.',
    ],
    checks: [
      PlaybookCheck(
        'traceroute <destination>',
        'the repeating addresses are the loop; the first repeated pair is '
            'where to start',
      ),
      PlaybookCheck(
        'show ip route <destination>',
        'the next hop on each router in the loop, compared pair by pair',
      ),
      PlaybookCheck(
        'show ip route <prefix> longer-prefixes / show ip cef <destination>',
        'a more specific route or a CEF adjacency that disagrees with the RIB',
      ),
      PlaybookCheck(
        'show log | include TTL|loop|routing',
        'ICMP TTL-exceeded messages and the interface they arrive on',
      ),
    ],
    fix:
        'Break the cycle at the boundary: filter the redistributed route with '
        'a tag or prefix-list, or replace the offending summary with a more '
        'specific route. Then confirm with a traceroute from both directions - '
        'a loop can be one-way.',
    rule:
        'Find the loop by following the next hop, not by reading configs. '
        'Traceroute from both ends; a one-way loop is still a loop and is the '
        'usual cause of "it works from here but not from there".',
    variants: [
      PlaybookVariant(
        'Junos',
        'traceroute <destination>; show route <destination> detail',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'redistribution-loop',
    title: 'Mutual redistribution is looping routes',
    subjects: ['redistribution', 'redistribute', 'ospf', 'eigrp', 'bgp'],
    signals: [
      'redistribution loop',
      'redistribution problem',
      'routes looping',
      'feedback',
      'mutual redistribution',
      'both directions',
      'redistributed back',
    ],
    meaning:
        'When two protocols redistribute into each other, a route learned from '
        'A can be fed back into A with a worse metric, so the two copies keep '
        'replacing each other and the network never converges.',
    causes: [
      'No seed metric on the redistribution, so the route enters with an '
          'infinite or arbitrary metric and is re-advertised unpredictably.',
      'No route tag or filter, so a route learned from the other protocol is '
          'redistributed straight back.',
      'Administrative distance working against you: EIGRP external is 170, '
          'OSPF is 110, so the OSPF copy wins and the feedback looks stable '
          'until the topology changes.',
      'Redistributing connected or static at two boundaries with no summary, '
          'so each boundary injects the other\'s copy.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route <prefix>',
        'the source and distance of the installed copy, and whether it '
            'changes between checks',
      ),
      PlaybookCheck(
        'show ip ospf database external / show ip eigrp topology',
        'the same prefix advertised by both protocols with different metrics',
      ),
      PlaybookCheck(
        'show route-map / show ip prefix-list',
        'whether a tag or filter actually exists on the redistribution',
      ),
    ],
    fix:
        'Redistribute in one direction wherever possible. Where both directions '
        'are required, tag routes on the way in and deny the tag on the way '
        'out, set an explicit seed metric, and summarize at the boundary. Then '
        'clear the protocol once and verify the route source is stable.',
    rule:
        'One-way redistribution with a default route is almost always better '
        'than mutual redistribution. If you must have both, a tag is the '
        'contract - not a comment in the config.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip route <prefix>; show ip ospf database external',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'bfd-down',
    title: 'BFD session not coming up',
    subjects: ['bfd', 'bidirectional forwarding detection'],
    signals: [
      'not coming up',
      'down',
      'session down',
      'not forming',
      'flapping',
      'stuck',
    ],
    meaning:
        'BFD is a fast failure detector, not a routing protocol. A BFD '
        'session that will not come up means the two ends cannot agree on '
        'transport, timers, or the path the packets take - and every protocol '
        'that depends on it will fail over or never converge.',
    causes: [
      'The BFD packets are not reaching the peer: an ACL, a firewall, uRPF, '
          'or a path that does not carry UDP 3784/3785.',
      'Timer mismatch or an interval the platform cannot honour. BFD '
          'negotiates the slower side, but a 50 ms request on a device that '
          'cannot do it stays down.',
      'One side single-hop, the other multihop (different destination ports '
          'and TTL rules).',
      'Echo mode enabled on one side and blocked in the path - the session '
          'fails even though the control packets arrive.',
      'The routing protocol is not bound to BFD, or the interface is down, so '
          'the session is never started.',
    ],
    checks: [
      PlaybookCheck(
        'show bfd neighbors details',
        'state, the negotiated timers, and the discriminator values from each '
            'side',
      ),
      PlaybookCheck(
        'show ip route <peer> / show ip cef <peer>',
        'the path BFD packets actually take',
      ),
      PlaybookCheck(
        'show run interface <intf> | include bfd',
        'whether the interface is actually enabled for BFD',
      ),
    ],
    fix:
        'Permit UDP 3784 (single-hop), 3785 (echo) and 4784 (multihop) in both '
        'directions, match echo mode on both ends, and set intervals the '
        'slowest device in the path can deliver. Bind the protocol explicitly '
        '(ip ospf bfd, ip bgp neighbors <peer> fall-over bfd).',
    rule:
        'BFD turns a slow failure into a fast one, and a false positive into a '
        'network-wide flap. Tune the multiplier for the path, not for the '
        'demo: 3 x 300 ms is a common starting point, not a universal truth.',
    variants: [PlaybookVariant('Junos', 'show bfd session detail')],
  ),

  DiagnosticPlaybook(
    id: 'vlan-trunk',
    title: 'VLAN traffic is not crossing the trunk',
    subjects: ['vlan', 'trunk', 'dot1q', '802.1q', 'inter-vlan'],
    signals: [
      'not passing',
      'not reaching',
      'not getting through',
      'missing',
      'not working',
      'no connectivity',
      'can\'t reach',
      'cannot reach',
      'doesn\'t pass',
      'does not pass',
      'not allowed',
      'blocked',
      'dropping',
      'no traffic',
      'pruning vlan',
    ],
    meaning:
        'A VLAN that exists on both switches but does not cross the trunk is '
        'a layer-2 forwarding fault. The frame is either not tagged onto the '
        'link, tagged with a different VLAN, not in the allowed list, or '
        'blocked by spanning tree before it ever reaches the far side.',
    causes: [
      'The VLAN is not in the trunk\'s allowed list. switchport trunk '
          'allowed vlan replaces the default all-VLANs behaviour, so a new '
          'VLAN is denied until it is added.',
      'Native VLAN mismatch on the two ends. Untagged frames land in '
          'different VLANs and CDP reports the mismatch - or does not, if CDP '
          'is off.',
      'Encapsulation mismatch: one side dot1q, the other ISL, or an access '
          'port where a trunk was intended. DTP can negotiate it away without '
          'anyone noticing.',
      'The VLAN does not exist on the far switch (VTP mode, no vlan command), '
          'so the frame arrives for a VLAN with no bridge domain.',
      'Spanning tree is blocking the only path for that VLAN, or Root Guard '
          'moved the port to inconsistent.',
      'The port is an access port in the wrong VLAN, or a voice VLAN/private '
          'VLAN configuration overrides the intended one.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces trunk',
        'the VLANs actually allowed and forwarding, the native VLAN, and '
            'which VLANs are pruned or not in the list',
      ),
      PlaybookCheck(
        'show vlan brief',
        'the VLAN exists and its access ports are in the right place',
      ),
      PlaybookCheck(
        'show interfaces switchport',
        'administrative vs operational mode, encapsulation, and native VLAN',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <id>',
        'the port is forwarding, not blocking or root-inconsistent',
      ),
      PlaybookCheck(
        'show cdp neighbors detail',
        'the native VLAN mismatch warning, when CDP is enabled',
      ),
    ],
    fix:
        'Add the VLAN to switchport trunk allowed vlan on every trunk in the '
        'path, align the native VLAN on both ends, and make the encapsulation '
        'explicit. For a new VLAN, create it on every switch or use VTP '
        'deliberately. Then verify from both ends with show interfaces trunk.',
    rule:
        'A trunk problem is proved hop by hop, not end to end. Ping the '
        'far-side SVI from the near-side switch - if that fails, the problem '
        'is the trunk, not the hosts.',
    variants: [
      PlaybookVariant('NX-OS', 'show interface trunk; show vlan brief'),
      PlaybookVariant(
        'Junos',
        'show ethernet-switching interfaces; show vlans',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'err-disabled',
    title: 'Switch port is err-disabled',
    subjects: ['port', 'interface', 'switchport', 'switch'],
    signals: [
      'err-disabled',
      'errdisabled',
      'error disabled',
      'err disable',
      'disabled by',
      'went down and stayed down',
    ],
    meaning:
        'Err-disable is the switch protecting itself: a feature detected '
        'something it refuses to forward through. The cause is recorded - '
        're-enabling the port without removing it just repeats the shutdown.',
    causes: [
      'BPDU Guard fired because a switch, a virtual switch or a loop was '
          'plugged into an access port with PortFast.',
      'Port security violation: too many MAC addresses, a different MAC, or '
          'a sticky address mismatch.',
      'Link flap: the interface bounced repeatedly (often a bad cable, optic '
          'or duplex mismatch).',
      'Storm control tripped on broadcast, multicast or unknown unicast.',
      'DHCP rate limit, Dynamic ARP Inspection, or IP Source Guard dropped '
          'traffic that tripped its own protective limit.',
      'LACP/PAgP mismatch or a channel-group error on one member link.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces status err-disabled',
        'the exact cause and the port - this is the answer, not a guess',
      ),
      PlaybookCheck(
        'show errdisable recovery',
        'which causes auto-recover and the interval; if all are off, nobody '
            'is bringing it back',
      ),
      PlaybookCheck(
        'show log | include ERR|DISABLE|SECURITY|BPDUGUARD',
        'the timestamp and the feature that fired',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include error|CRC|flap',
        'physical faults behind link-flap and storm-control causes',
      ),
    ],
    fix:
        'Remove the cause first: disconnect the rogue switch, correct the '
        'cable, fix the port-security config. Then shutdown / no shutdown on '
        'the port, or clear the specific errdisable cause. Enable '
        'errdisable recovery only for causes you have made safe to recover.',
    rule:
        'Never configure errdisable recovery for BPDU Guard on access ports. '
        'The loop coming back every five minutes is worse than a port that '
        'stays down until someone investigates.',
    variants: [PlaybookVariant('NX-OS', 'show interface status err-disabled')],
  ),
  DiagnosticPlaybook(
    id: 'mac-flap',
    title: 'MAC address is flapping between ports',
    subjects: ['mac', 'mac address', 'switch', 'vlan'],
    signals: [
      'mac flap',
      'flapping mac',
      'mac address flap',
      'mac moves',
      'mac keeps moving',
      'mac table churn',
      'flapping between',
      'flapping',
      'keeps flapping',
    ],
    meaning:
        'The same MAC is learned on two ports in quick succession. Either a '
        'real loop exists, the same MAC genuinely appears in two places, or a '
        'link aggregation member is misconfigured and the switch sees one '
        'host on two links.',
    causes: [
      'A switching loop: an unmanaged switch, a cross-connect, or a port with '
          'BPDU filtering enabled. This is the cause to rule out first.',
      'A port-channel that is not actually bundling, so the switch learns the '
          'same MAC on two member links.',
      'Duplicate MAC addresses: a cloned VM, a NIC teaming driver in the wrong '
          'mode, or a replaced server with a copied address.',
      'vPC/MLAG misconfiguration, where the peer link is not carrying the '
          'MAC correctly.',
      'Wireless roaming with a client MAC appearing on two WLC/uplink ports '
          'during the move (usually transient, but noisy).',
    ],
    checks: [
      PlaybookCheck(
        'show mac address-table address <mac>',
        'the ports and VLAN where the MAC was learned, and how recently',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <id>',
        'topology changes and any port that keeps moving between roles',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include broadcasts|multicast|drops',
        'a broadcast rate near line rate is the signature of a loop',
      ),
      PlaybookCheck(
        'show log | include MAC|FLAP|STP',
        'the flap timestamps and the STP topology-change events that match',
      ),
    ],
    fix:
        'Break the loop first, then correct the aggregate. Add BPDU Guard on '
        'access ports and Loop Guard on non-designated ports so the next '
        'unmanaged switch cannot repeat it.',
    rule:
        'A MAC flap is a symptom. Do not "fix" it with a static MAC entry '
        'until you have proved there is no loop - a static entry hides the '
        'symptom and lets the storm keep growing.',
  ),
  DiagnosticPlaybook(
    id: 'layer2-loop',
    title: 'Broadcast storm or layer-2 loop',
    subjects: [
      'network',
      'switch',
      'vlan',
      'stp',
      'spanning tree',
      'broadcast',
    ],
    signals: [
      'broadcast storm',
      'network loop',
      'switching loop',
      'layer 2 loop',
      'l2 loop',
      'storm control',
      'cpu is 100',
      'everything is slow',
    ],
    meaning:
        'A layer-2 loop forwards one broadcast frame in a circle forever. '
        'Within seconds the segment is saturated, the CPU is busy, the MAC '
        'table churns, and every host on the VLAN loses connectivity.',
    causes: [
      'A physical loop: two links between the same switches, a cross-connect, '
          'or a desk loop through an unmanaged switch.',
      'Spanning tree disabled, or BPDU filtering on an uplink so the loop is '
          'invisible to STP.',
      'A misconfigured port-channel where members are not actually bundled '
          'and both forward.',
      'NIC teaming in an active/active mode that the switch does not support, '
          'or a hypervisor virtual switch bridging two uplinks.',
      'A wireless bridge or mesh link creating an unintended L2 path.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces | include broadcast|multicast|output rate',
        'a broadcast rate pinned at line rate identifies the saturated link',
      ),
      PlaybookCheck(
        'show mac address-table count',
        'a MAC count far above the number of real hosts is a loop signature',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <id>',
        'topology changes and a port oscillating between roles',
      ),
      PlaybookCheck(
        'show processes cpu sorted',
        'the CPU consumer; a storm shows as a high interrupt or spanning-tree '
            'load',
      ),
    ],
    fix:
        'Shut the offending port or disconnect the loop first - in an active '
        'storm, speed beats elegance. Then enable BPDU Guard, Loop Guard and '
        'storm control at the access edge so the next loop is contained to one '
        'port.',
    rule:
        'Contain first, diagnose second. A storm that is not stopped within '
        'minutes takes the whole VLAN down, and every extra command you type '
        'while it runs is a command you type twice.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show interface counters broadcast; show mac address-table count',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'lacp-bundle',
    title: 'Port-channel will not bundle',
    subjects: [
      'lacp',
      'etherchannel',
      'port-channel',
      'port channel',
      'link aggregation',
      'pagp',
    ],
    signals: [
      'not bundling',
      'not coming up',
      'won\'t bundle',
      'wont bundle',
      'individual',
      'suspended',
      'not forming',
      'only one link',
      'down',
    ],
    meaning:
        'A port-channel only forwards when every member is compatible and the '
        'two ends agree on the protocol. show etherchannel summary is the '
        'whole diagnosis: each member is flagged with its state and the reason.',
    causes: [
      'Mode mismatch: one side active/passive and the other "on", or one side '
          'not in a channel at all. LACP needs active or passive; "on" is '
          'static and will not negotiate.',
      'Member configuration mismatch: speed, duplex, MTU, trunk/access mode, '
          'allowed VLANs, or spanning-tree settings differ across members.',
      'One member is physically down or has errors, so the bundle is '
          'partial and traffic is not balanced.',
      'The switch does not support the number of links or the hashing you '
          'expect; more than eight active members is not possible in one LACP '
          'bundle on most platforms.',
      'LACP system priority or port priority makes the wrong side the '
          'controller, which usually still bundles but can leave links '
          'standby.',
    ],
    checks: [
      PlaybookCheck(
        'show etherchannel summary',
        'each member\'s flag (P bundled, I individual, s suspended, D down) '
            'and the reason',
      ),
      PlaybookCheck(
        'show lacp neighbor',
        'the partner\'s system ID, port state and timers - proves both ends '
            'speak LACP',
      ),
      PlaybookCheck(
        'show interfaces <member> | include error|CRC|duplex|speed',
        'a bad member is removed from the bundle, and the summary says so',
      ),
    ],
    fix:
        'Make the member configs identical, set one side active and the other '
        'active or passive, and shut/no shut the port-channel after fixing '
        'members. Never put an interface into a channel that is already '
        'forwarding without checking the summary first.',
    rule:
        'Design for two links and a working single link. A bundle that takes '
        'down both members when one fails is worse than no bundle at all.',
    variants: [
      PlaybookVariant('NX-OS', 'show port-channel summary; show lacp neighbor'),
    ],
  ),
  DiagnosticPlaybook(
    id: 'vpc-mlag',
    title: 'vPC or MLAG will not form',
    subjects: ['vpc', 'mlag', 'virtual port channel', 'peer-link', 'peer link'],
    signals: [
      'not forming',
      'peer-link down',
      'peer link down',
      'peer-link is down',
      'peer link is down',
      'keepalive',
      'split brain',
      'not coming up',
      'suspended',
      'primary secondary',
      'inconsistent',
    ],
    meaning:
        'vPC (Nexus) and MLAG (Arista and others) make two switches look like '
        'one for a downstream port-channel. They need two independent paths: '
        'the peer-link for data and control, and the keepalive for split-brain '
        'detection. A failure in either shows up differently.',
    causes: [
      'Peer-link down or not a port-channel with all VLANs allowed, so the '
          'two switches cannot synchronise.',
      'Keepalive unreachable (wrong VRF, wrong source, ACL, or a path through '
          'the peer-link itself) - it must not share fate with the peer-link.',
      'Domain ID, vPC role or NX-OS version mismatch between the peers.',
      'Type-1 consistency failure: MTU, STP mode, allowed VLANs or LACP '
          'settings differ across the peer-link.',
      'A member port is up before the vPC domain is ready, so it is suspended '
          'until the peer is reachable.',
    ],
    checks: [
      PlaybookCheck(
        'show vpc',
        'peer status, role, peer-link state and the vPC number states - one '
            'screen answers most of it',
      ),
      PlaybookCheck(
        'show vpc consistency-parameters global',
        'the exact parameter that differs between the peers',
      ),
      PlaybookCheck(
        'show vpc peer-keepalive',
        'whether keepalive is over the right path and not through the '
            'peer-link',
      ),
      PlaybookCheck(
        'show port-channel summary',
        'the peer-link and member bundles at the physical level',
      ),
    ],
    fix:
        'Fix the peer-link first, then keepalive, then consistency. Bring them '
        'up in order: peer-link, keepalive, vPC domain, member ports. '
        'Never let keepalive share a path with the peer-link - that is how a '
        'split brain becomes a real outage.',
    rule:
        'The peer-link and the keepalive must fail independently. If they '
        'share a switch, a card or a cable, you have a split-brain design '
        'dressed as redundancy.',
    variants: [
      PlaybookVariant('Comware/other MLAG', 'display link-aggregation verbose'),
    ],
  ),

  DiagnosticPlaybook(
    id: 'dhcp-client-no-ip',
    title: 'Client gets no DHCP address (169.254 / APIPA)',
    subjects: ['dhcp', 'client', 'pc', 'laptop', 'address', 'ip'],
    signals: [
      '169.254',
      'apipa',
      'no ip',
      'no address',
      'not getting an ip',
      'doesn\'t get an ip',
      'does not get an ip',
      'can\'t get an ip',
      'cannot get an ip',
      'no dhcp',
      'dhcp not working',
      'not giving an ip',
      'not giving ip',
      'giving ip',
      'dhcp is not working',
      'dhcp failing',
    ],
    meaning:
        'A 169.254.x.x address is Windows saying DHCP never answered - not '
        'that the address is bad. The client reached layer 2, so '
        'the fault is in the DHCP path: the request never left, the server '
        'never answered, or the answer was dropped on the way back.',
    causes: [
      'The client is in the wrong VLAN, or its port is down or in the wrong '
          'access VLAN, so the broadcast never reaches the relay.',
      'No helper address on the gateway SVI, or the helper points at a server '
          'that is unreachable from that subnet.',
      'The scope is wrong or exhausted: wrong subnet, all leases in use, or '
          'excluded addresses cover the range.',
      'DHCP snooping is enabled and the uplink is untrusted, so the offer is '
          'dropped before the client sees it.',
      'A firewall or ACL permits DHCP requests but not the unicast reply, or '
          'option 82 is inserted by a relay the server rejects.',
      'Port security or 802.1X holds the port in an unauthorised state, so no '
          'DHCP frame is forwarded at all.',
    ],
    checks: [
      PlaybookCheck(
        'ipconfig /all on the client',
        'the media state, the APIPA address and whether the lease is empty',
      ),
      PlaybookCheck(
        'show ip interface <svi> | include helper',
        'the helper address the gateway actually relays to',
      ),
      PlaybookCheck(
        'show ip dhcp binding / show ip dhcp pool',
        'whether the server ever saw the request and whether the pool has '
            'free addresses',
      ),
      PlaybookCheck(
        'show ip dhcp snooping / show ip dhcp snooping binding',
        'snooping state, trusted ports and whether a binding exists for the '
            'client',
      ),
      PlaybookCheck(
        'debug ip dhcp server events',
        'the request arriving and the reason the server did not answer - '
            'briefly, on a lab or quiet device',
      ),
    ],
    fix:
        'Fix the layer 2 path first, then the relay, then the scope, then '
        'snooping trust. A DHCP fault is almost never fixed on the server - '
        'the request is usually dying before it gets there.',
    rule:
        'A 169.254 address proves the cable and the NIC work and the DHCP '
        'exchange did not. Do not static-configure the client to "test" it '
        'unless you keep the static config out of the final answer.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip dhcp relay address; show ip dhcp snooping binding',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'dhcp-snooping',
    title: 'DHCP snooping is dropping clients',
    subjects: ['dhcp snooping', 'dhcp'],
    signals: [
      'blocking',
      'blocked',
      'drops',
      'not getting an address',
      'untrusted',
    ],
    meaning:
        'DHCP snooping drops server replies on every untrusted port. It only '
        'works when the path to the legitimate server - the uplink, not the '
        'access port - is explicitly trusted.',
    causes: [
      'The uplink to the DHCP server or relay is not trusted, so the OFFER '
          'and ACK are discarded.',
      'Snooping is enabled on the VLAN but the client\'s VLAN is not in the '
          'enabled list, or vice versa.',
      'The binding table is empty because the client\'s VLAN never saw a '
          'request (wrong VLAN or a relay that bypasses the switch).',
      'Option 82 insertion breaks a relay that rejects the option.',
      'A trusted port was trusted in both directions on a link that should '
          'not be, and a rogue server is now answering.',
    ],
    checks: [
      PlaybookCheck(
        'show ip dhcp snooping',
        'VLANs enabled, trusted ports, and the option-82 setting',
      ),
      PlaybookCheck(
        'show ip dhcp snooping binding',
        'whether the client ever got a binding, and on which VLAN',
      ),
      PlaybookCheck(
        'show ip dhcp snooping statistics',
        'the drop counters, which name the interface and reason',
      ),
    ],
    fix:
        'Trust only the uplink toward the real server, enable snooping on the '
        'client VLANs, and keep option 82 only if the server supports it. Then '
        'renew the lease and confirm a binding appears.',
    rule:
        'Snooping is a security control, not a convenience. Trust exactly one '
        'direction and one port; every extra trusted port is a rogue server '
        'waiting to happen.',
  ),
  DiagnosticPlaybook(
    id: 'dai-failing',
    title: 'Dynamic ARP Inspection is dropping traffic',
    subjects: ['dynamic arp inspection', 'dai', 'arp inspection'],
    signals: [
      'drops',
      'dropping',
      'blocking',
      'not working',
      'fails',
      'failing',
      'not passing',
      'untrusted',
    ],
    meaning:
        'DAI validates every ARP packet against the DHCP snooping binding '
        'table (or a static ARP ACL). No binding means no valid ARP, and the '
        'host cannot resolve its gateway even though DHCP worked.',
    causes: [
      'The host has a static IP and therefore no DHCP binding - DAI drops its '
          'ARP unless a static ARP ACL exists.',
      'DHCP snooping is off or its binding table is empty, so DAI has nothing '
          'to validate against.',
      'The uplink is untrusted, so the gateway\'s ARP replies are dropped.',
      'A wireless controller or hypervisor proxies ARP with a MAC that does '
          'not match the binding.',
      'DAI is enabled on a VLAN where the clients are not DHCP at all.',
    ],
    checks: [
      PlaybookCheck(
        'show ip arp inspection',
        'the VLANs, trusted ports and the configured validation checks',
      ),
      PlaybookCheck(
        'show ip arp inspection statistics',
        'the drop count per VLAN - the number that proves DAI is the cause',
      ),
      PlaybookCheck(
        'show ip dhcp snooping binding',
        'the binding for the affected host; missing means static or no DHCP',
      ),
    ],
    fix:
        'Trust the uplink, make sure snooping is running, and add a static ARP '
        'ACL for genuinely static hosts. If a proxy device rewrites ARP, '
        'exclude it from DAI rather than disabling DAI on the VLAN.',
    rule:
        'DAI without snooping is a lock with no key list. Deploy them together, '
        'and never enable DAI on a VLAN of static servers without an ARP ACL.',
  ),
  DiagnosticPlaybook(
    id: 'fhrp-failover',
    title: 'HSRP/VRRP gateway does not fail over',
    subjects: ['hsrp', 'vrrp', 'glbp', 'fhrp', 'standby', 'gateway redundancy'],
    signals: [
      'not failing over',
      'doesn\'t fail over',
      'does not fail over',
      'both active',
      'two active',
      'split brain',
      'not taking over',
      'stays standby',
      'no failover',
      'active not changing',
    ],
    meaning:
        'First-hop redundancy moves the virtual IP when the active stops '
        'hearing the peers or when its tracked object fails. If the standby '
        'never takes over, either it still hears the active, it is not '
        'allowed to preempt, or the failure it is tracking is not the one that '
        'happened.',
    causes: [
      'Preempt is off on the intended active, so it never takes the role back '
          'after a reload or recovery.',
      'The L2 path between the peers is broken while each still reaches the '
          'LAN - both become active, or neither hears the other.',
      'Group number, version (HSRP v1 vs v2), authentication or hello/hold '
          'timers differ between the peers.',
      'Interface tracking is configured on the wrong interface, or the '
          'decrement is too small to lose the election.',
      'The failure is upstream (WAN or core) and nothing is tracking it, so '
          'the gateway is healthy while the path behind it is not.',
    ],
    checks: [
      PlaybookCheck(
        'show standby brief / show vrrp brief',
        'who is active, the priority and the preempt flag on each router',
      ),
      PlaybookCheck(
        'show standby <group>',
        'timers, authentication, tracked objects and the active/standby '
            'addresses',
      ),
      PlaybookCheck(
        'show vrrp detail',
        'the VRID, priority, preempt and advertisement interval for VRRP',
      ),
      PlaybookCheck(
        'debug standby events',
        'why the state did not change - run it on the standby during the test',
      ),
    ],
    fix:
        'Set preempt on the intended primary, make group/version/auth/timers '
        'identical, and track the object that actually represents the path '
        '(uplink, IP SLA, route). Test the failover by shutting the tracked '
        'link, not by shutting the router.',
    rule:
        'A gateway that stays up while its uplink is down is worse than no '
        'redundancy: the hosts keep sending traffic to a dead end. Track the '
        'path, and test the failure you are afraid of.',
    variants: [
      PlaybookVariant('NX-OS', 'show hsrp brief; show hsrp group <n>'),
    ],
  ),
  DiagnosticPlaybook(
    id: 'ntp-not-sync',
    title: 'NTP is not syncing',
    subjects: ['ntp', 'time', 'clock'],
    signals: [
      'not syncing',
      'not synchronized',
      'wrong time',
      'out of sync',
      'unsynchronized',
      'stratum 16',
      'no sync',
      'clock is wrong',
    ],
    meaning:
        'NTP keeps time by comparing a local clock to a server over UDP 123. '
        'Unsynchronised means either the server is unreachable, the reply is '
        'filtered, authentication fails, or the server itself has no valid '
        'time source (stratum 16).',
    causes: [
      'The server is unreachable: no route, ACL blocking UDP 123, or a '
          'firewall in the path.',
      'Authentication mismatch: key number, key string or trusted-key list '
          'differs, so every packet is rejected.',
      'The server is stratum 16 (unsynchronised itself), so it cannot serve '
          'time.',
      'ntp server vs ntp peer wrong direction, or the source interface is not '
          'the one the server expects.',
      'The local clock is so far off that the first sync takes a long time, '
          'or the device is in a state that refuses large steps.',
    ],
    checks: [
      PlaybookCheck(
        'show ntp status',
        'the stratum and reference clock - stratum 16 means not synced',
      ),
      PlaybookCheck(
        'show ntp associations',
        'the configured servers, their reachability (the reach column) and the '
            'selected source',
      ),
      PlaybookCheck(
        'show run | include ntp',
        'authenticate, trusted-key, ntp server and source interface',
      ),
      PlaybookCheck(
        'debug ntp packets',
        'requests leaving and replies arriving - briefly, on a quiet device',
      ),
    ],
    fix:
        'Correct the path and the key list, point at a source that is itself '
        'synchronised, and use the loopback as the source so a link flap does '
        'not change the time source. Verify with show ntp status, not by '
        'reading the clock once.',
    rule:
        'Time is a security control: certificates, logs, Kerberos and 802.1X '
        'all fail quietly when the clock drifts. Monitor stratum and offset, '
        'not just "is NTP configured".',
  ),
  DiagnosticPlaybook(
    id: 'dns-failing',
    title: 'DNS resolution is failing',
    subjects: ['dns', 'name resolution', 'resolve', 'nslookup', 'domain'],
    signals: [
      'not resolving',
      'can\'t resolve',
      'cannot resolve',
      'resolution fails',
      'resolution failing',
      'nxdomain',
      'servfail',
      'dns fails',
      'dns not working',
      'dns is not working',
      'dns is broken',
      'dns does not work',
      'name does not resolve',
      'timeout',
    ],
    meaning:
        'Split the problem at the resolver: ask the local resolver, then the '
        'forwarder, then the authoritative server. A failure at only one step '
        'names the layer that is broken.',
    causes: [
      'The client points at a resolver it cannot reach (wrong DNS server, or '
          'UDP/TCP 53 blocked).',
      'The resolver has no route or no forwarder to the internet, so it '
          'returns SERVFAIL.',
      'Split-horizon or a search-domain mismatch: the short name resolves '
          'internally but not externally, or the client appends the wrong '
          'suffix.',
      'The record is wrong or missing at the authoritative server, or the '
          'zone is not delegated.',
      'DNSSEC validation fails (expired signature, broken chain), which '
          'returns SERVFAIL rather than NXDOMAIN.',
    ],
    checks: [
      PlaybookCheck(
        'nslookup <name> <server> / dig @<server> <name>',
        'ask the same name at the client resolver and then at a public '
            'resolver; the first failure names the layer',
      ),
      PlaybookCheck(
        'show hosts / ip name-server on the device',
        'the configured servers and any static entries that shadow DNS',
      ),
      PlaybookCheck(
        'nslookup -debug / dig +trace',
        'where the delegation stops and whether the answer is authoritative',
      ),
      PlaybookCheck(
        'test TCP 53 as well as UDP 53',
        'a large answer or DNSSEC response needs TCP; a UDP-only test can pass '
            'while real resolution fails',
      ),
    ],
    fix:
        'Point clients at a reachable resolver, give the resolver a working '
        'forwarder or recursion path, and fix the authoritative record if that '
        'is where the trace stops. Keep search suffixes consistent with the '
        'zone design.',
    rule:
        'DNS failures look like application failures. Always test by IP and by '
        'name: if IP works and the name does not, you are debugging DNS, not '
        'the application.',
  ),

  DiagnosticPlaybook(
    id: 'ipsec-phase1',
    title: 'IPsec tunnel is down at phase 1 (IKE)',
    subjects: ['ipsec', 'vpn', 'ike', 'tunnel', 'isakmp'],
    signals: [
      'phase 1',
      'phase1',
      'isakmp',
      'ike sa',
      'no sa',
      'mm_no_state',
      'tunnel down',
      'not establishing',
      'won\'t come up',
      'wont come up',
      'stuck',
    ],
    meaning:
        'Phase 1 is the IKE security association: the peers must agree on '
        'encryption, hashing, Diffie-Hellman group, authentication and '
        'identity before any encrypted traffic can flow. Down at phase 1 means '
        'nothing beyond that negotiation has been tested.',
    causes: [
      'The peer is not reachable: wrong remote address, no route to it, or '
          'UDP 500/4500 blocked in the path.',
      'Pre-shared key or certificate mismatch. The error is usually '
          'deliberately vague, so compare the key on both ends character by '
          'character.',
      'Proposal mismatch: encryption, hash, DH group or lifetime differs. '
          'IKEv1 and IKEv2 are not interchangeable; one side must match the '
          'other\'s version or support both.',
      'Identity mismatch: the peer expects an FQDN or a certificate subject '
          'and you send an IP, or the local/remote ID is reversed.',
      'NAT in the path without NAT-T, or an ACL that blocks ISAKMP but '
          'permits ESP.',
    ],
    checks: [
      PlaybookCheck(
        'show crypto isakmp sa / show crypto ikev2 sa',
        'the state (QM_IDLE, MM_NO_STATE, READY) and whether an SA exists at '
            'all',
      ),
      PlaybookCheck(
        'show crypto isakmp policy / show crypto ikev2 proposal',
        'the proposal list, compared with the peer\'s',
      ),
      PlaybookCheck(
        'debug crypto isakmp / debug crypto ikev2',
        'which proposal or identity was rejected - the error names the field',
      ),
      PlaybookCheck(
        'show crypto session / show crypto ipsec sa',
        'whether phase 2 exists - a phase 1 fault stops before this',
      ),
    ],
    fix:
        'Align the proposals, the pre-shared key and the identity. If NAT is '
        'between the peers, enable NAT-T and keep UDP 4500 open both ways. '
        'Remove every unmatched proposal rather than adding more guesses.',
    rule:
        'Change one IKE parameter at a time and clear the SA before retrying. '
        'Three simultaneous changes produce a working tunnel you cannot '
        'explain and cannot reproduce.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show security ike sa; show security ike policy',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'ipsec-phase2',
    title: 'IPsec phase 2 is up but traffic does not pass',
    subjects: ['ipsec', 'vpn', 'tunnel', 'esp'],
    signals: [
      'phase 2',
      'phase2',
      'ipsec sa',
      'no ipsec sa',
      'tunnel up but',
      'ping fails',
      'traffic not passing',
      'no traffic',
      'encaps but no decaps',
    ],
    meaning:
        'Phase 2 is the IPsec SA that actually encrypts traffic, and it is '
        'built for specific proxy identities or traffic selectors. Up with no '
        'traffic almost always means the traffic does not match the tunnel, '
        'the return path is missing, or the SAs are one-sided.',
    causes: [
      'The interesting-traffic ACL does not match what is being sent, or the '
          'two ends\' ACLs are not mirrored (source and destination swapped).',
      'Transform-set or PFS mismatch: phase 1 succeeded, but the ESP proposal '
          'or PFS group differs.',
      'Only one direction has an SA. Encapsulation counters climb and '
          'decapsulation stays at zero.',
      'No route back to the remote subnet, or the remote subnet overlaps a '
          'local one.',
      'MTU and fragmentation: the tunnel comes up, pings pass, large flows '
          'stall because ICMP needs-fragmentation is blocked.',
    ],
    checks: [
      PlaybookCheck(
        'show crypto ipsec sa',
        'the proxy identities, the SAs in each direction, and the encaps/'
            'decaps counters',
      ),
      PlaybookCheck(
        'show crypto ipsec transform-set / show crypto map',
        'the proposals and the ACL the map points at',
      ),
      PlaybookCheck(
        'show ip route <remote-subnet>',
        'a missing return route explains one-way traffic with healthy SAs',
      ),
      PlaybookCheck(
        'ping <remote-host> size 1400 df-bit',
        'proves the path can carry a full-size encrypted packet',
      ),
    ],
    fix:
        'Mirror the ACLs exactly, match the transform set and PFS, route the '
        'remote subnet into the tunnel, and clamp MSS or set the tunnel MTU. '
        'Clear the SA only after all three are aligned.',
    rule:
        'Phase 1 proves the peers trust each other. Phase 2 proves the '
        'selectors agree. A tunnel that is "up" but carries nothing is a '
        'selector or routing fault, not a crypto fault.',
  ),
  DiagnosticPlaybook(
    id: 'ipsec-flap',
    title: 'IPsec tunnel drops after a while',
    subjects: ['ipsec', 'vpn', 'tunnel', 'ike'],
    signals: [
      'drops after',
      'disconnects',
      'rekey',
      'every hour',
      'after a few hours',
      'flaps',
      'flapping',
      'resets every',
      'keeps dropping',
      'drops every',
    ],
    meaning:
        'A tunnel that works and then dies on a schedule is rekeying, path '
        'failure detection, or an MTU/keepalive issue - not a configuration '
        'that is simply wrong, because it worked once.',
    causes: [
      'Lifetime mismatch: the two peers rekey at different times and one '
          'drops the SA the other is still using.',
      'DPD (dead peer detection) fires because the path drops probes or the '
          'timers are too aggressive.',
      'NAT-T keepalives stop, so an intermediate NAT device ages out the UDP '
          'mapping.',
      'MTU or fragmentation: a large transfer fills a buffer or triggers a '
          'drop, and the session stalls until the SA rekeys.',
      'One ISP path is asymmetric or flapping, so the tunnel moves between '
          'paths and the peer sees a different source address.',
    ],
    checks: [
      PlaybookCheck(
        'show crypto ipsec sa | include lifetime|status|remaining',
        'the SA lifetime and how long each side believes it has left',
      ),
      PlaybookCheck(
        'show crypto session detail',
        'the peer, the DPD state and the last error',
      ),
      PlaybookCheck(
        'show crypto isakmp sa',
        'whether phase 1 stays up while phase 2 is rebuilt - that points at '
            'lifetime or PFS',
      ),
      PlaybookCheck(
        'show interfaces | include MTU|drops',
        'the tunnel and physical MTU, and any drops on the encrypted path',
      ),
    ],
    fix:
        'Match lifetimes on both peers and let one side be the rekey '
        'initiator. Relax DPD to survive the path\'s real loss, keep NAT-T '
        'alive, and clamp MSS on the tunnel. Then leave it running long '
        'enough to prove the next rekey succeeds.',
    rule:
        'A scheduled failure is a timer or a path, not a policy. Find the '
        'interval and compare it with the lifetimes and DPD settings before '
        'changing any crypto parameter.',
  ),
  DiagnosticPlaybook(
    id: 'nat-failing',
    title: 'NAT is not translating',
    subjects: ['nat', 'pat', 'translation', 'overload'],
    signals: [
      'not translating',
      'no translation',
      'nat not working',
      'nat fails',
      'doesn\'t translate',
      'can\'t reach the internet',
      'cannot reach the internet',
      'one way',
      'outside can\'t reach',
    ],
    meaning:
        'NAT is applied between routing and forwarding, and only on interfaces '
        'marked inside or outside. No translation usually means the packet '
        'never crossed an inside-to-outside boundary the router recognized, or '
        'the ACL did not match it.',
    causes: [
      'ip nat inside / ip nat outside is missing or on the wrong interfaces, '
          'so the packet is routed without translation.',
      'The NAT ACL does not match the source (wrong subnet, wrong wildcard, or '
          'the ACL is applied in the wrong direction).',
      'No route back for the translated address, or the outside interface has '
          'no default route.',
      'Overload is missing, so only one host can use the public address.',
      'Order of operations: NAT happens before or after routing and ACLs '
          'depending on direction, so a NAT ACL that looks right still sees '
          'the untranslated or translated address at the wrong moment.',
      'PAT port exhaustion or a very short translation timeout under heavy '
          'load.',
    ],
    checks: [
      PlaybookCheck(
        'show ip nat translations',
        'whether any entry exists - none means the packet never matched',
      ),
      PlaybookCheck(
        'show ip nat statistics',
        'the inside/outside interfaces, the ACL hits and the misses',
      ),
      PlaybookCheck(
        'show ip interface brief',
        'that inside and outside are marked on the interfaces you think',
      ),
      PlaybookCheck(
        'debug ip nat',
        'the translate-or-not decision with addresses - briefly, sparingly',
      ),
    ],
    fix:
        'Mark the interfaces, fix the ACL, add overload, and make sure a '
        'default route exists toward the outside. For one-way failures, check '
        'the return route and any outside ACL before touching NAT rules.',
    rule:
        'Read NAT inside out: route first, then translate on the way out; '
        'translate first on the way in, then route. Most "NAT is broken" '
        'tickets are a missing default route or a wrong interface.',
  ),
  DiagnosticPlaybook(
    id: 'acl-blocking',
    title: 'An ACL or firewall rule is blocking traffic',
    subjects: [
      'acl',
      'access-list',
      'firewall',
      'security group',
      'rule',
      'policy',
    ],
    signals: [
      'blocking',
      'blocked',
      'denied',
      'permit not working',
      'unexpectedly blocked',
      'rule does not work',
      'rule is not working',
      'allows the subnet but not the host',
      'subnet but not the host',
      'traffic blocked',
      'implicit deny',
      'not matching',
      'hit count',
    ],
    meaning:
        'ACLs are evaluated top-down and stop at the first match, with an '
        'implicit deny at the end. A rule that looks correct but sits below a '
        'broader rule never runs.',
    causes: [
      'A broader rule above it matches first - the hit counters show which '
          'line actually fired.',
      'Direction is reversed: the ACL is applied inbound where the traffic is '
          'outbound, or on the wrong interface.',
      'The wildcard mask is wrong, so the rule matches more or less than '
          'intended.',
      'The implicit deny catches the return traffic or an ephemeral port; '
          'stateful inspection must be on the correct direction.',
      'NAT changes the address before the ACL sees it, so the rule was '
          'written for the wrong side of the translation.',
      'In hardware (TCAM), an ACL can be compiled differently from the '
          'running config; show access-lists counters is the truth.',
    ],
    checks: [
      PlaybookCheck(
        'show ip access-lists <name>',
        'the per-line match counters - the first line with hits is the one '
            'that decided',
      ),
      PlaybookCheck(
        'show ip interface <intf>',
        'which ACL is applied in which direction',
      ),
      PlaybookCheck(
        'show running-config | section access-list',
        'the actual order, including entries added later at the bottom',
      ),
      PlaybookCheck(
        'show logging | include DENY|denied',
        'the implicit-deny log line, with the interface and addresses',
      ),
    ],
    fix:
        'Move the specific permit above the broader deny, correct the '
        'direction and wildcard, and clear the counters after the change so '
        'the next test is readable. Use object-groups or named ACLs so future '
        'edits have a place to go.',
    rule:
        'Never add a deny above a working permit to "test" a theory. Use the '
        'counters, then change exactly one line and clear them.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show ip access-lists <name>; show ip interface <intf>',
      ),
      PlaybookVariant(
        'Junos',
        'show firewall filter <name>; show interfaces filters',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'dot1x-failing',
    title: '802.1X authentication is failing',
    subjects: ['802.1x', 'dot1x', 'eap', 'supplicant', 'radius', 'mab'],
    signals: [
      'not authenticating',
      'authentication fails',
      'fails authentication',
      'unauthorized',
      'keeps failing',
      'rejected',
      'failing',
      'fails',
      'not getting on the network',
    ],
    meaning:
        '802.1X has three parties: the supplicant, the switch (authenticator) '
        'and the RADIUS server. A failure names a party and a stage - '
        'discovery, EAP exchange, or authorization - and each has different '
        'checks.',
    causes: [
      'The port is not configured for 802.1X (no authentication port-control '
          'auto), or 802.1X is not globally enabled.',
      'RADIUS is unreachable or the shared secret differs, so every request '
          'times out.',
      'EAP method mismatch: the supplicant offers PEAP and the server expects '
          'EAP-TLS, or the certificate is not trusted.',
      'The user or machine is in the wrong group, or the authorization policy '
          'returns a VLAN that does not exist.',
      'MAB is expected but the MAC is not in the identity store, or the port '
          'is in a critical VLAN that bypasses authentication entirely.',
    ],
    checks: [
      PlaybookCheck(
        'show authentication sessions',
        'the method, the domain and the final status per port',
      ),
      PlaybookCheck(
        'show dot1x all',
        'the authenticator state and the EAP exchange summary',
      ),
      PlaybookCheck(
        'show radius server-group / test aaa group',
        'that the switch can actually reach and authenticate to the server',
      ),
      PlaybookCheck(
        'RADIUS server log for the same timestamp',
        'the server-side reason, which the switch only reports as a failure',
      ),
    ],
    fix:
        'Fix the lowest failing stage: link, then EAPOL, then RADIUS '
        'reachability, then the policy. Use a critical VLAN for the '
        'infrastructure, and test with one port before enabling a site.',
    rule:
        '802.1X failures are almost never fixed on the switch alone. Read the '
        'RADIUS log for the same second - it names the reason the switch only '
        'calls "authentication failed".',
  ),

  DiagnosticPlaybook(
    id: 'wifi-join',
    title: 'Wireless client cannot join the network',
    subjects: ['wifi', 'wi-fi', 'wireless', 'ssid', 'access point', 'client'],
    signals: [
      'can\'t connect',
      'cannot connect',
      'won\'t connect',
      'wont connect',
      'won\'t join',
      'wont join',
      'cannot join',
      'fails to connect',
      'not associating',
      'authentication failed',
      'no internet',
      'cant get on the wifi',
      'cannot get on the wifi',
      'cant join the wifi',
      'cannot join the wifi',
      'will not join the wifi',
      'new laptop cannot get on the wifi',
    ],
    meaning:
        'A wireless join has four stages: discover the SSID, associate, '
        'authenticate, then get an address. The stage that fails names the '
        'fault, and the client UI usually shows which one it reached.',
    causes: [
      'The client cannot see the SSID: broadcast disabled, wrong band, or the '
          'AP radio is down.',
      'Association fails: the client and AP disagree on security type, or the '
          'AP is at its client limit.',
      'Authentication fails: wrong PSK, WPA3 transition issues, an expired '
          'certificate for EAP-TLS, or the RADIUS server rejects the user.',
      'Association and authentication succeed but no address arrives - that '
          'is the DHCP playbook, not a wireless fault.',
      'A captive portal or DNS policy blocks the client after it joins.',
    ],
    checks: [
      PlaybookCheck(
        'the client\'s connection log',
        'the exact stage: scanning, associating, authenticating, obtaining an '
            'address',
      ),
      PlaybookCheck(
        'show wireless client summary / show ap summary on the controller',
        'whether the AP sees the client and how far the join got',
      ),
      PlaybookCheck(
        'show radius server-group / RADIUS log',
        'the authentication result for the same client MAC',
      ),
      PlaybookCheck(
        'the DHCP scope and VLAN for that SSID',
        'an empty or exhausted scope looks exactly like a wireless fault',
      ),
    ],
    fix:
        'Fix the failing stage: broadcast the SSID or correct the band, align '
        'the security settings, then check the RADIUS result, then the DHCP '
        'path. Change one layer at a time and retest with the same client.',
    rule:
        'Wireless problems are layered problems with a radio on top. Test with '
        'a wired client on the same VLAN before blaming the AP - the fault is '
        'often the DHCP or VLAN path the SSID maps to.',
  ),
  DiagnosticPlaybook(
    id: 'wifi-drops',
    title: 'Wireless clients keep dropping or perform poorly',
    subjects: [
      'wifi',
      'wi-fi',
      'wireless',
      'client',
      'roam',
      'roaming',
      'access point',
    ],
    signals: [
      'keeps dropping',
      'keep dropping',
      'keeps disconnecting',
      'dropping clients',
      'disconnects',
      'flaky',
      'is trash',
      'is awful',
      'unstable',
      'poor signal',
      'slow wifi',
      'slow wireless',
      'sticky',
      'roams',
      'randomly disconnects',
      'drop randomly',
      'drops randomly',
      'drop out',
      'drop out randomly',
      'flapping',
      'keeps reconnecting',
    ],
    meaning:
        'Intermittent wireless is either radio (coverage, interference, '
        'channel width), mobility (roaming decisions), or the wired path '
        'behind the AP (PoE, uplink, DHCP). The client\'s RSSI and the AP\'s '
        'view of the same client separate the three quickly.',
    causes: [
      'Weak coverage or a low SNR at the client\'s location, often at the '
          'cell edge where the AP and client are both shouting.',
      'Co-channel interference or a too-wide channel: 80 MHz in a dense 5 GHz '
          'deployment creates overlap and retries.',
      'Sticky client: the client stays on a distant AP because roaming is '
          'left entirely to the client. 802.11k/v/r and a minimum RSSI fix it.',
      'AP power or channel set by auto-RF that changes on its own, moving the '
          'cell boundary during the day.',
      'The wired path behind the AP: PoE budget, uplink congestion, or DHCP '
          'lease renewal failing.',
    ],
    checks: [
      PlaybookCheck(
        'show wireless client detail <mac> / controller client view',
        'RSSI, SNR, retry rate, the AP and the band the client is really on',
      ),
      PlaybookCheck(
        'show ap summary / show ap auto-rf',
        'channel, width and transmit power per radio, and whether auto-RF '
            'keeps changing',
      ),
      PlaybookCheck(
        'a site survey (Ekahau, Wi-Fi Analyzer)',
        'coverage and interference from the client\'s actual location - the '
            'only honest source for SNR',
      ),
      PlaybookCheck(
        'show power inline and the AP uplink counters',
        'the wired cause hiding behind a wireless symptom',
      ),
    ],
    fix:
        'Fix coverage before tuning: add an AP or lower the cell size, then set '
        'a deliberate channel plan. Enable 802.11k/v and fast transition for '
        'roaming, and a minimum RSSI so clients leave a weak AP. Test with the '
        'same client and the same location.',
    rule:
        'Do not tune roaming before you have measured coverage. A "sticky '
        'client" on a bad channel plan is a coverage problem wearing a '
        'roaming label.',
  ),
  DiagnosticPlaybook(
    id: 'vxlan-dataplane',
    title: 'VXLAN/EVPN hosts cannot reach each other',
    subjects: ['vxlan', 'evpn', 'vni', 'vtep', 'overlay'],
    signals: [
      'hosts can\'t reach',
      'hosts cannot reach',
      'traffic not passing',
      'not passing traffic',
      'vni',
      'tunnel down',
      'no connectivity',
      'arp fails',
      'packet loss',
      'black hole',
    ],
    meaning:
        'VXLAN has two independent planes: the IP underlay that must carry '
        'the encapsulated packet, and the EVPN overlay that must know where '
        'each MAC/IP lives. Prove the underlay first, then the VNI, then the '
        'routing.',
    causes: [
      'The underlay MTU is too small. A 50-byte VXLAN header on a 1500-byte '
          'frame needs 1550, and large frames vanish while pings pass.',
      'VTEP loopback addresses are not reachable, so no tunnel forms even '
          'though the physical links are up.',
      'VLAN-to-VNI mapping or the VNI itself differs on the two VTEPs.',
      'EVPN route targets or the L2 VNI is not imported, so MAC/IP routes '
          'never install.',
      'First-hop routing: anycast gateway MAC or VRF is not consistent, so '
          'the host ARPs for a gateway that does not answer locally.',
      'ARP suppression drops the ARP because the EVPN entry is missing.',
    ],
    checks: [
      PlaybookCheck(
        'ping <remote-vtep> size 1600 df-bit',
        'proves the underlay can carry an encapsulated frame - the first test '
            'in every VXLAN fault',
      ),
      PlaybookCheck(
        'show nve peers / show nve vni',
        'peer state and the VNI-to-VTEP mapping; no peer means underlay or '
            'control plane',
      ),
      PlaybookCheck(
        'show bgp l2vpn evpn',
        'the EVPN routes actually received, with their route targets',
      ),
      PlaybookCheck(
        'show vlan mapping / show nve vni',
        'the VLAN-to-VNI mapping on both ends',
      ),
    ],
    fix:
        'Raise the underlay MTU (usually 1600 or 9000 on the fabric links) and '
        'clamp MSS for routed traffic. Then align the VNI, the route targets '
        'and the anycast gateway. Test with a ping between hosts, not just '
        'between VTEPs.',
    rule:
        'The overlay cannot be healthy if the underlay is not. A VXLAN ticket '
        'that starts at show bgp evpn is a ticket that ignores the most likely '
        'cause: MTU.',
    variants: [
      PlaybookVariant(
        'NX-OS',
        'show nve peers; show nve vni; show bgp l2vpn evpn',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'multicast-failing',
    title: 'Multicast traffic is not reaching receivers',
    subjects: ['multicast', 'pim', 'igmp', 'mroute', 'rendezvous'],
    signals: [
      'not working',
      'no multicast',
      'receivers not getting',
      'not receiving',
      'not reaching',
      'pim',
      'rp',
      'rpf',
      'stream not playing',
      'multicast fails',
    ],
    meaning:
        'Multicast forwarding is reverse-path based: a router forwards a '
        'multicast packet only if it arrives on the interface it would use to '
        'reach the source. Most failures are an RPF check, a missing RP, or '
        'IGMP snooping pruning the last hop.',
    causes: [
      'No RPF route to the source, so every packet fails the RPF check and is '
          'dropped silently.',
      'The RP is not reachable or the group-to-RP mapping differs per router, '
          'so the shared tree never forms.',
      'PIM is not enabled on the interface facing the source or receiver '
          '(only one side of a link is enough to break the tree).',
      'IGMP snooping on the access switch has no querier, so the group is '
          'pruned after the first report.',
      'A multicast boundary, TTL threshold, or firewall rule drops the group.',
      'SSM groups are being used with a sparse-mode RP design that does not '
          'match.',
    ],
    checks: [
      PlaybookCheck(
        'show ip rpf <source>',
        'the exact reason the RPF check passes or fails - start here',
      ),
      PlaybookCheck(
        'show ip mroute <group>',
        'the (S,G) and (*,G) entries, the incoming interface and the outgoing '
            'list',
      ),
      PlaybookCheck(
        'show ip pim rp mapping / show ip pim neighbor',
        'the RP each router believes in, and whether PIM neighbours exist',
      ),
      PlaybookCheck(
        'show ip igmp snooping / show ip igmp groups',
        'the last-hop pruning and whether a querier exists',
      ),
    ],
    fix:
        'Restore unicast reachability to the source, make the RP mapping '
        'identical everywhere, enable PIM on both sides of every transit link, '
        'and give each VLAN a querier (usually the SVI). Then verify with '
        'show ip mroute that the outgoing list contains the receiver\'s '
        'interface.',
    rule:
        'Multicast is unicast routing with an RPF rule attached. If unicast '
        'to the source is broken, multicast cannot work; fix unicast first.',
  ),
  DiagnosticPlaybook(
    id: 'voice-quality',
    title: 'Voice calls are choppy, garbled or one-way',
    subjects: ['voice', 'voip', 'call', 'qos', 'sip', 'rtp'],
    signals: [
      'choppy',
      'garbled',
      'one way audio',
      'one-way audio',
      'poor voice',
      'jitter',
      'echo',
      'drops calls',
      'calls drop',
      'voice quality',
      'robotic',
    ],
    meaning:
        'Voice is a latency, jitter and loss problem before it is a QoS '
        'problem. One-way audio is usually signalling or NAT; choppy audio is '
        'loss, jitter or a congested queue. Measure before you mark.',
    causes: [
      'Congestion on the WAN or uplink with no priority queue for the voice '
          'class, so RTP waits behind bulk data.',
      'The trust boundary is wrong: phones mark EF but the switch or router '
          'rewrites it to 0, so the queue never sees it.',
      'Jitter buffer underrun from a variable path - the average latency looks '
          'fine while the peaks do not.',
      'One-way audio: SIP signalling works but RTP is blocked, NAT is not '
          'traversing correctly, or the firewall treats the media path '
          'asymmetrically.',
      'Codec mismatch or transcoding overload on the call control server.',
    ],
    checks: [
      PlaybookCheck(
        'show policy-map interface <wan>',
        'the EF class counters and drops, and whether the priority queue is '
            'actually matching',
      ),
      PlaybookCheck(
        'show call active voice brief / RTCP stats',
        'jitter, loss and the codec actually negotiated, end to end',
      ),
      PlaybookCheck(
        'a ping sweep with the voice packet size and a jitter test',
        'whether the path itself is the problem, before any QoS tuning',
      ),
      PlaybookCheck(
        'the firewall or NAT session table for the RTP ports',
        'one-way audio is usually a media path that was never opened',
      ),
    ],
    fix:
        'Trust the phone\'s marking at the access edge, keep it through every '
        'hop, and give EF a bounded priority queue on the WAN. Fix the media '
        'path for one-way audio, then re-measure. QoS cannot repair a path '
        'that is already losing packets at line rate.',
    rule:
        'Measure loss, latency and jitter before touching a QoS policy. If the '
        'path is clean and the calls are still bad, the fault is signalling '
        'or the call server, not the network.',
  ),
  DiagnosticPlaybook(
    id: 'poe-failing',
    title: 'A PoE device is not powering up',
    subjects: ['poe', 'power over ethernet', 'power', 'ap', 'phone', 'camera'],
    signals: [
      'not powering',
      'no power',
      'insufficient power',
      'poe budget exceeded',
      'poe budget exhausted',
      'not turning on',
      'keeps rebooting',
      'power inline',
      'device not powering',
      'reboots at night',
      'reboot at night',
    ],
    meaning:
        'PoE is negotiated before the device boots: the switch classifies the '
        'device, checks the remaining power budget and the port capability, '
        'then delivers. A device that never powers has failed one of those '
        'steps, or the cable cannot carry the current.',
    causes: [
      'The port has no PoE capability or PoE is disabled on it.',
      'The switch power budget is exhausted, so the port is denied power.',
      'The device needs 802.3at/bt and the port only offers 802.3af.',
      'The cable is too long, damaged or low quality, so the PD cannot draw '
          'the negotiated current and keeps rebooting.',
      'The device is drawing more than its class allows, or LLDP/CDP power '
          'negotiation is disabled and the switch falls back to class power.',
    ],
    checks: [
      PlaybookCheck(
        'show power inline <intf>',
        'the operating state, the class, the allocated and drawn watts',
      ),
      PlaybookCheck(
        'show power inline',
        'the total budget and what is left - a full budget denies new ports',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include error|CRC',
        'a marginal cable shows as errors before it shows as a power fault',
      ),
      PlaybookCheck(
        'the device\'s own power requirement',
        'af is 15.4 W, at 30 W, bt up to 90 W at the source; match the class '
            'to the port',
      ),
    ],
    fix:
        'Free budget or move the device to a higher-class port, enable LLDP '
        'power negotiation, and replace the cable run. For a reboot loop, '
        'watch the drawn watts - a device drawing at the class limit on a long '
        'cable is the classic cause.',
    rule:
        'Check the watts, not just the port state. "PoE is enabled" and "the '
        'device gets the power it needs" are different claims.',
  ),
  DiagnosticPlaybook(
    id: 'cloud-connectivity',
    title: 'A cloud instance is unreachable',
    subjects: [
      'aws',
      'azure',
      'gcp',
      'cloud',
      'instance',
      'security group',
      'nacl',
      'vpc',
    ],
    signals: [
      'unreachable',
      'can\'t reach',
      'cannot reach',
      'connection timed out',
      'timeout',
      'not reachable',
      'no connectivity',
      'connectivity failing',
      'ping fails',
      'ssh fails',
    ],
    meaning:
        'Cloud reachability is four independent layers: the subnet route '
        'table, the security group, the network ACL, and the instance itself. '
        'A security group that allows the port does not help if the route '
        'table has no path or the NACL denies the return traffic.',
    causes: [
      'The subnet route table has no route to the internet gateway, NAT '
          'gateway, transit gateway or peer.',
      'The security group has no inbound rule for the port, or no outbound '
          'rule for the return traffic (security groups are allow-only and '
          'stateful, but the outbound rule still matters).',
      'The network ACL denies the traffic in either direction. NACLs are '
          'stateless, so the ephemeral return ports must be allowed too.',
      'The instance has no public IP or elastic IP, or it sits in a private '
          'subnet with no NAT.',
      'Overlapping CIDRs make peering or a VPN impossible, even though the '
          'config looks correct.',
      'The host firewall or the application is not listening - the cloud '
          'layer is fine and the instance is not.',
    ],
    checks: [
      PlaybookCheck(
        'VPC Reachability Analyzer (or the equivalent path test)',
        'the exact hop where the path is denied, instead of four guesses',
      ),
      PlaybookCheck(
        'VPC Flow Logs for the ENI',
        'ACCEPT/REJECT at the security group, and whether packets arrived at '
            'all',
      ),
      PlaybookCheck(
        'the route table associated with the instance\'s subnet',
        'the route that the instance actually uses, not the one in the main '
            'table',
      ),
      PlaybookCheck(
        'security group inbound and outbound, then the NACL both ways',
        'the two filters in the order they are evaluated',
      ),
    ],
    fix:
        'Fix the first layer that rejects: route table, then security group, '
        'then NACL, then the instance. Keep the NACL rules symmetric, and use '
        'Reachability Analyzer to prove the path after the change.',
    rule:
        'Security groups are stateful; NACLs are not. A rule that works '
        'inbound still fails if the ephemeral return range is denied - the '
        'most common silent cloud firewall fault.',
  ),

  DiagnosticPlaybook(
    id: 'slow-network',
    title: 'The network is slow',
    subjects: [
      'network',
      'latency',
      'performance',
      'lag',
      'internet',
      'browsing',
    ],
    signals: [
      'network is slow',
      'everything is slow',
      'slow',
      'sluggish',
      'high latency',
      'laggy',
      'pages load slow',
      'traffic is slow',
      'takes forever',
      'poor performance',
      'slow throughput',
      'high ping',
    ],
    meaning:
        '"Slow" is not a measurement. Split it into latency, jitter, loss and '
        'throughput, then locate it: one host, one VLAN, one site, one '
        'application, or everything. The answer changes completely at each '
        'boundary.',
    causes: [
      'A duplex or speed mismatch on one link, which shows as late collisions '
          'and retransmissions rather than a down port.',
      'Congestion on an uplink or WAN, including a policer or shaper that '
          'drops in bursts.',
      'Packet loss on a wireless or long-haul path, which TCP reads as '
          'latency because it keeps reducing its window.',
      'DNS or proxy delay in front of the application - the network is fast '
          'and the name lookup is not.',
      'MTU black hole: small requests fly, large responses stall.',
      'Control-plane CPU high from a storm, SNMP polling or routing churn, '
          'which slows forwarding on some platforms.',
    ],
    checks: [
      PlaybookCheck(
        'ping and iperf3 between the same two hosts, then to the gateway',
        'separates path latency from host/application latency; compare the '
            'numbers, do not average them in your head',
      ),
      PlaybookCheck(
        'show interfaces | include duplex|speed|errors|drops|CRC',
        'the physical layer and any output drops on the actual path',
      ),
      PlaybookCheck(
        'show policy-map interface <wan>',
        'whether a QoS policy is dropping or shaping the traffic under test',
      ),
      PlaybookCheck(
        'dig/nslookup timing and a request to the server by IP',
        'proves or removes DNS and proxy from the list in under a minute',
      ),
    ],
    fix:
        'Fix the measurement first, then the largest contributor. In practice '
        'that is duplex/CRC, then congestion or policer, then DNS, then MTU. '
        'Re-run the same test after each change so the improvement is proved, '
        'not hoped for.',
    rule:
        'Never accept "the network is slow" as a problem statement. Ask what '
        'is slow, from where, since when, and compared with what - the four '
        'questions that turn a complaint into a fault.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show interfaces extensive; show class-of-service interface',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'packet-loss',
    title: 'Traffic is losing packets',
    subjects: ['packet loss', 'loss', 'network', 'drops', 'throughput'],
    signals: [
      'packet loss',
      'dropping packets',
      'drops packets',
      'intermittent',
      'random loss',
      'loss',
      'retransmissions',
      'tcp retries',
      'some packets',
    ],
    meaning:
        'Loss is either physical (errors), congestion (queue drops), policy '
        '(policer or ACL), or path (wireless retries, ECMP asymmetry). '
        'Interface counters tell physical from policy; a per-hop test tells '
        'where the path starts losing.',
    causes: [
      'Physical errors: CRC, input errors, bad optic or cable, duplex '
          'mismatch.',
      'Congestion: output drops, a full queue, or a policer set below the '
          'real rate.',
      'MTU/fragmentation: large packets dropped while small ones pass.',
      'ECMP hashing asymmetry: one member link is congested or broken, and '
          'only flows hashing to it see loss.',
      'Wireless retries or a roaming event.',
      'A firewall, IPS or load balancer dropping the flow silently.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces | include errors|CRC|drops|overrun',
        'physical and queue loss per interface, in both directions',
      ),
      PlaybookCheck(
        'a per-hop ping with a fixed size and interval, plus mtr',
        'the first hop where loss appears, not the destination where it is '
            'noticed',
      ),
      PlaybookCheck(
        'show policy-map interface / show ip interface | include policy',
        'a policer or shaper dropping the class under test',
      ),
      PlaybookCheck(
        'show ip cef exact-route <src> <dst>',
        'which ECMP member the flow takes; if one member is bad, only some '
            'flows lose',
      ),
    ],
    fix:
        'Replace the bad physical component, raise or re-shape the policer, '
        'fix the MTU, or remove the failing ECMP member from service. Then '
        'test with the same flow and packet size that failed.',
    rule:
        'Loss is measured per direction and per hop. A test that only proves '
        '"some loss exists" has not found anything yet.',
  ),
  DiagnosticPlaybook(
    id: 'mtu-black-hole',
    title: 'Large packets fail while pings succeed (MTU black hole)',
    subjects: [
      'mtu',
      'mss',
      'pmtud',
      'fragmentation',
      'packet',
      'large ping',
      'small ping',
    ],
    signals: [
      'large ping fails',
      'large pings fail',
      'large pings',
      'large ping',
      'small pings work',
      'big packets',
      'small packets work',
      'pmtud',
      'df bit',
      'black hole',
      'some sites don\'t load',
      'ssh hangs',
      'ssl hangs',
      'pages half load',
      'large transfers fail',
    ],
    meaning:
        'A path MTU black hole: small packets pass, large packets are dropped, '
        'and the ICMP fragmentation-needed message that would tell the sender '
        'to shrink them is filtered. Logins, TLS handshakes and file transfers '
        'stall while ping looks perfect.',
    causes: [
      'A tunnel (GRE, IPsec, VXLAN, PPPoE) reduced the MTU and ICMP is blocked '
          'in the path, so PMTUD cannot learn the new size.',
      'A firewall or ACL denies ICMP type 3 code 4 (fragmentation needed) and '
          'ICMPv6 packet-too-big.',
      'A middlebox rewrites or drops large frames without returning ICMP.',
      'MSS clamping is missing on the tunnel interface.',
      'Jumbo frames configured on one link and not the rest of the path.',
    ],
    checks: [
      PlaybookCheck(
        'ping <dst> size 1472 df-bit, then 1400, then 1200',
        'the largest size that passes is the real path MTU; binary-search it',
      ),
      PlaybookCheck(
        'traceroute with the same packet size',
        'the hop where the large packet stops is the MTU boundary',
      ),
      PlaybookCheck(
        'show interfaces <tunnel> | include MTU',
        'the configured tunnel MTU and the physical MTU it sits on',
      ),
      PlaybookCheck(
        'a packet capture at both ends',
        'whether ICMP fragmentation-needed is generated and whether it '
            'arrives',
      ),
    ],
    fix:
        'Set a correct tunnel MTU and ip tcp adjust-mss (usually 1360-1400 for '
        'IPsec/GRE), and allow ICMP type 3 code 4 and ICMPv6 type 2 through '
        'the firewall. PMTUD is the mechanism; blocking it is the bug.',
    rule:
        'If pings work and TLS hangs, test packet size before anything else. '
        'It is the fastest, cheapest test in networking and it eliminates half '
        'the suspects.',
    variants: [
      PlaybookVariant('Junos', 'ping <dst> size 1472 do-not-fragment'),
    ],
  ),
  DiagnosticPlaybook(
    id: 'asymmetric-routing',
    title: 'Traffic works one way only',
    subjects: [
      'route',
      'routing',
      'asymmetric',
      'return path',
      'firewall',
      'one way',
      'one-way',
    ],
    signals: [
      'asymmetric',
      'one way',
      'one-way',
      'outbound works',
      'inbound works',
      'return path',
      'one direction',
      'works from here but not',
      'reply not coming back',
    ],
    meaning:
        'Forward and return traffic are taking different, asymmetric paths. Routers '
        'usually cope; stateful firewalls, NAT and uRPF do not, because they '
        'expect to see both halves of the flow.',
    causes: [
      'A stateful firewall sees the SYN on one interface and the SYN-ACK on '
          'another, so it drops the reply as out of state.',
      'uRPF strict mode rejects the packet because the reverse path is not '
          'the receiving interface.',
      'NAT translates outbound but the return traffic arrives at a different '
          'edge that has no translation state.',
      'Two default routes or policy-based routing pick different exits per '
          'flow or per direction.',
      'An IGP metric or summary change moved one direction without the other.',
    ],
    checks: [
      PlaybookCheck(
        'traceroute from both ends to the other end',
        'the two paths side by side - the asymmetry is usually obvious',
      ),
      PlaybookCheck(
        'show ip cef exact-route <src> <dst> and the reverse',
        'the forwarding decision in each direction',
      ),
      PlaybookCheck(
        'firewall session table / show conn',
        'whether the reply arrived on a different interface than the state',
      ),
      PlaybookCheck(
        'show ip interface <intf> | include verify',
        'uRPF mode on the interfaces in the path',
      ),
    ],
    fix:
        'Make the return path symmetric: prefer IGP metrics that keep both '
        'directions on the same edge, or make the firewall/NAT pair stateful '
        'across both. Use uRPF loose mode where symmetry cannot be guaranteed, '
        'and document why.',
    rule:
        'Always test in both directions. A one-way fault is a design or state '
        'problem, not a missing route - the route usually exists, it just is '
        'not the same one.',
  ),
  DiagnosticPlaybook(
    id: 'high-cpu',
    title: 'Router or switch CPU is high',
    subjects: ['cpu', 'router', 'switch', 'control plane'],
    signals: [
      'high cpu',
      'cpu high',
      'cpu is 100',
      'cpu spike',
      'cpu at',
      'router cpu is at 100 percent',
      'cpu is at 100',
      'cpu is pegged',
      'switch cpu is high',
      'control plane is overloaded',
      'cpu spikes and the network drops',
      'control plane cpu',
      'processor is busy',
    ],
    meaning:
        'High CPU is a symptom of how packets reach the CPU, not a problem in '
        'itself. Interrupt CPU means traffic is being punted; process CPU means '
        'a protocol or management task is working hard. The split names the '
        'cause.',
    causes: [
      'A broadcast storm or a loop, which punts frames to the CPU.',
      'ARP or ND churn, often from a scan, a duplicate subnet or a broken '
          'host.',
      'Routing protocol churn: an unstable link causing constant SPF or BGP '
          'recalculation.',
      'SNMP polling or syslog at an aggressive interval.',
      'CoPP missing or too permissive, so management and transit traffic '
          'compete with the control plane.',
      'Software forwarding after a hardware resource (TCAM/Adjacency) is '
          'exhausted.',
    ],
    checks: [
      PlaybookCheck(
        'show processes cpu sorted (and history)',
        'interrupt vs process CPU and the top consumer',
      ),
      PlaybookCheck(
        'show interfaces | include broadcast|multicast',
        'storm traffic hitting the CPU',
      ),
      PlaybookCheck(
        'show ip traffic / show ip arp statistics',
        'ARP/ND and punted packet rates',
      ),
      PlaybookCheck(
        'show policy-map control-plane',
        'CoPP counters - what is being policed, and what is not covered',
      ),
    ],
    fix:
        'Remove the source (loop, scan, churn), then protect the control plane '
        'with CoPP sized for the platform. Do not simply rate-limit everything '
        '- that turns a CPU problem into a dropped-adjacency problem.',
    rule:
        'Read interrupt CPU before process CPU. If it is interrupt, the problem '
        'is traffic; if it is process, the problem is a task or a protocol. '
        'They have completely different fixes.',
  ),
  DiagnosticPlaybook(
    id: 'interface-errors',
    title: 'Interface shows CRC, input errors or drops',
    subjects: ['interface', 'port', 'link', 'crc', 'errors'],
    signals: [
      'crc',
      'input errors',
      'late collision',
      'runts',
      'giants',
      'flapping interface',
      'interface flapping',
      'link flapping',
      'errors on',
      'interface errors',
      'interface error',
      'output drops',
      'fcs',
    ],
    meaning:
        'The counter names the layer. CRC and input errors are physical. Runts '
        'and collisions are duplex or a shared segment. Giants are MTU. Output '
        'drops are congestion or a policer, not a bad cable.',
    causes: [
      'CRC/FCS: damaged cable, bad optic, dirty connector, or EMI along the '
          'run.',
      'Late collisions and runts: a duplex mismatch, almost always one side '
          'hard-coded and the other auto.',
      'Giants: MTU mismatch or a jumbo frame on one side only.',
      'Output drops: congestion, a policer, or a speed mismatch at the egress.',
      'Flapping: a marginal optic, PoE power issue, or a cable being moved.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces counters errors',
        'which counter is climbing and on which interface',
      ),
      PlaybookCheck(
        'show interfaces <intf>',
        'duplex and speed on both ends, plus the error breakdown',
      ),
      PlaybookCheck(
        'show interfaces transceiver',
        'optical power and temperature on fiber links',
      ),
      PlaybookCheck(
        'clear counters, wait, then re-read',
        'whether the errors are historical or still happening - the only '
            'honest way to tell',
      ),
    ],
    fix:
        'CRC: replace the cable or optic. Duplex: set both sides to auto or '
        'both to the same fixed setting. Giants: match MTU. Drops: add '
        'bandwidth, fix the policer, or shape. Never "fix" CRC with a config '
        'change.',
    rule:
        'CRC is never a software problem. If the counter climbs after a '
        'cable/optic swap, move the port - the line card or the patch panel is '
        'the remaining suspect.',
  ),
  DiagnosticPlaybook(
    id: 'traceroute-stars',
    title: 'Traceroute shows stars',
    subjects: ['traceroute', 'tracert', 'stars', 'hop'],
    signals: [
      'traceroute stars',
      'stars in traceroute',
      'asterisks',
      '***',
      'shows stars',
      'hops show',
      'trace shows stars',
    ],
    meaning:
        'Stars are "no response to that probe", not "no connectivity". A hop '
        'that does not answer may still forward perfectly. Read the pattern: '
        'stars at one hop with later hops answering is filtering; stars from a '
        'point onward is a break; alternating paths are load balancing.',
    causes: [
      'The router rate-limits or filters ICMP TTL-exceeded replies.',
      'The probe is filtered but the forwarded traffic is not.',
      'The path is asymmetric, so replies come back through a different route.',
      'MPLS or a tunnel hides the intermediate hops, so the TTL expires '
          'inside a core that does not generate replies.',
      'The destination itself drops the probe type while accepting TCP.',
    ],
    checks: [
      PlaybookCheck(
        'ping each hop individually',
        'a hop that pings but shows stars in traceroute is filtering, not '
            'broken',
      ),
      PlaybookCheck(
        'a TCP traceroute (tcptrace/mtr -T) to a real port',
        'distinguishes ICMP filtering from a real forwarding break',
      ),
      PlaybookCheck(
        'traceroute from the far end back',
        'the reverse path, which often explains the apparent stars',
      ),
    ],
    fix:
        'If later hops answer and the destination is reachable, the stars are '
        'cosmetic - do not chase them. If the trace stops, use the last '
        'answering hop plus the route on that router to find the break.',
    rule:
        'A traceroute is evidence, not a verdict. The destination\'s ping and '
        'the application test decide whether the stars matter.',
  ),
  DiagnosticPlaybook(
    id: 'vrf-route',
    title: 'Route is missing inside a VRF',
    subjects: ['vrf', 'vrf-lite', 'vpn', 'route leaking', 'mpls'],
    signals: [
      'not in vrf',
      'route missing',
      'vrf route',
      'not leaking',
      'leak',
      'can\'t reach',
      'cannot reach',
      'no route',
      'empty vrf',
    ],
    meaning:
        'A VRF is a separate routing table. The route can exist in the global '
        'table and still be absent from the VRF. Check the VRF table first, '
        'then the import/export policy that is supposed to populate it.',
    causes: [
      'The interface is not in the VRF (ip vrf forwarding), so its connected '
          'route is in the global table.',
      'The VRF has no route to the destination and no default - a VRF does not '
          'inherit the global table by default.',
      'MPLS VPN: the route target import/export does not match, or the RD is '
          'wrong, so the prefix never enters the VRF.',
      'VRF-lite: the static or dynamic route was configured without vrf, and '
          'landed in global.',
      'Route leaking is intended but no export map/import map exists.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route vrf <name> <prefix>',
        'the VRF table itself - the first thing to look at',
      ),
      PlaybookCheck(
        'show ip vrf / show ip vrf interfaces',
        'which interfaces are actually in the VRF',
      ),
      PlaybookCheck(
        'show ip bgp vpnv4 vrf <name> / show ip route vrf <name> summary',
        'the VPN routes and the import/export policy in effect',
      ),
      PlaybookCheck(
        'show ip route vrf <name> 0.0.0.0',
        'whether the VRF even has a default route',
      ),
    ],
    fix:
        'Put the interface in the VRF, add the VRF-specific route (ip route '
        'vrf <name> ...), or fix the route targets on both sides of the VPN. '
        'Leak deliberately with an export/import map, never by adding a second '
        'default route.',
    rule:
        'In a VRF design, "the route exists" is a statement about a table. '
        'Always name the VRF and check that table - the global table is a '
        'different network.',
  ),
  DiagnosticPlaybook(
    id: 'port-security',
    title: 'Port security is shutting the port',
    subjects: ['port security', 'port-security', 'mac', 'switchport'],
    signals: [
      'violation',
      'port security',
      'err-disabled',
      'psecure',
      'sticky',
      'too many mac',
      'security violation',
    ],
    meaning:
        'Port security allows a fixed number of MAC addresses on a port and '
        'then takes an action: protect (drop), restrict (drop and log) or '
        'shutdown (err-disable). The violation counter names which rule was '
        'broken.',
    causes: [
      'A downstream switch, hub or virtual switch presents multiple MACs on '
          'one access port.',
      'The maximum is set too low for the host (a laptop with a dock and a '
          'virtual adapter can present several).',
      'A replacement device has a different MAC and the old sticky entry is '
          'still there.',
      'The port is in the wrong VLAN or the same MAC appears on two ports.',
      'The violation mode is shutdown when the design intended restrict.',
    ],
    checks: [
      PlaybookCheck(
        'show port-security interface <intf>',
        'the max, the current count, the violation count and the last source '
            'MAC',
      ),
      PlaybookCheck(
        'show mac address-table interface <intf>',
        'which MACs are actually behind the port',
      ),
      PlaybookCheck(
        'show port-security address',
        'sticky and static entries that no longer match the device',
      ),
    ],
    fix:
        'Raise the max for a genuine multi-MAC port (or convert it to a trunk '
        'with the right controls), clear the stale sticky entry, and choose '
        'restrict instead of shutdown where a violation should not take the '
        'port down. Then re-enable the port.',
    rule:
        'Port security on a port that legitimately has many MACs is a '
        'self-inflicted outage. Know what is behind the port before you set '
        'the maximum.',
  ),
  DiagnosticPlaybook(
    id: 'duplex-mismatch',
    title: 'Duplex mismatch on an Ethernet link',
    subjects: [
      'duplex',
      'ethernet',
      'interface',
      'link',
      'uplink',
      'half duplex',
    ],
    signals: [
      'duplex mismatch',
      'half duplex',
      'half-duplex',
      'late collisions',
      'late collision',
      'speed mismatch',
    ],
    meaning:
        'One side is full duplex and the other is half duplex, or the speeds '
        'disagree. The full-duplex side sends whenever it wants; the '
        'half-duplex side treats the resulting frames as collisions. The link '
        'stays up, which is what makes this fault so persistent.',
    causes: [
      'Speed or duplex is hard-coded on one side and left auto on the other. '
          'Auto-negotiation cannot agree with a fixed setting, so the fixed side '
          'falls back and the other side guesses.',
      'A cable or pair fault that forces a fallback to half duplex. A link '
          'that negotiates 100 half on gigabit hardware is a cabling problem '
          'first.',
      'A media converter or an old hub in the path that only supports half '
          'duplex.',
      'Duplex configured correctly on both sides but one side is a virtual '
          'interface that does not pass the setting through.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces <intf>',
        'the actual duplex and speed, plus late collisions and FCS errors',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include duplex|speed|collision|error',
        'whether the error counters are climbing rather than historical',
      ),
      PlaybookCheck(
        'show interfaces status',
        'the negotiated speed and duplex for every port at once',
      ),
    ],
    fix:
        'Set both ends the same way: auto on both is the default and the right '
        'answer for copper. If one end must be fixed, fix both. Then replace '
        'the cable or the converter if the link still negotiates half duplex.',
    rule:
        'A duplex mismatch presents as slow throughput and rising late '
        'collisions, not as a down link. Never fix it by setting one side to '
        'full duplex and leaving the other auto - that is how it started.',
  ),
  DiagnosticPlaybook(
    id: 'interface-flap',
    title: 'Interface is flapping up and down',
    subjects: ['interface', 'port', 'link', 'ethernet'],
    signals: [
      'flapping',
      'flap',
      'keeps going down',
      'up and down',
      'goes down repeatedly',
      'link down',
      'link is down',
      'link is down on',
      'interface down',
      'port is down on',
      'bouncing',
    ],
    meaning:
        'The physical link is losing carrier repeatedly. Each transition '
        'clears the interface state, reruns spanning tree, and may withdraw a '
        'route, so the symptom is intermittent loss for everything behind the '
        'port.',
    causes: [
      'A bad cable, connector or patch panel. Intermittent carrier is the most '
          'common physical cause and the cheapest to rule out.',
      'Optics at the edge of their power budget, or a dirty connector. Check '
          'the receive power against the datasheet before replacing the switch.',
      'Power or hardware: a failing port, a PoE device drawing more than the '
          'port can supply, or a device that reboots and drops carrier.',
      'A speed or duplex setting that the far end does not support, so the '
          'link trains and then fails repeatedly.',
      'Err-disabled recovery: the port is being disabled by a protection '
          'feature, not by the cable. The reason is in the log.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces <intf>',
        'the up/down count, the last transition, and the error counters',
      ),
      PlaybookCheck(
        'show logging | include <intf>',
        'the exact reason for each transition: carrier, err-disable, PoE',
      ),
      PlaybookCheck(
        'show interfaces transceiver detail',
        'Rx power and temperature against the optic specification',
      ),
    ],
    fix:
        'Replace the cable and the optic first, then the port. If the log shows '
        'an err-disable reason, fix that cause and clear the error rather than '
        'shutting and unshutting the port.',
    rule:
        'A flapping port is a physical investigation until the log proves '
        'otherwise. Replacing the switch before the cable is an expensive way '
        'to learn the same lesson.',
  ),
  DiagnosticPlaybook(
    id: 'duplicate-ip',
    title: 'Duplicate IP address on the network',
    subjects: ['duplicate', 'ip', 'address', 'arp', 'conflict'],
    signals: [
      'duplicate ip',
      'duplicate address',
      'ip conflict',
      'address conflict',
      'two devices same ip',
      'same ip address',
      'arp conflict',
    ],
    meaning:
        'Two devices claim the same IPv4 address. ARP resolves to one MAC and '
        'then the other, so traffic alternates, connections reset, and the '
        'symptom looks like intermittent packet loss rather than an addressing '
        'fault.',
    causes: [
      'A statically configured address inside a DHCP pool, so the server also '
          'leases it. This is the classic cause and the pool exclusion is the '
          'fix.',
      'A DHCP reservation that was changed on one server but not the other, or '
          'a second DHCP server with an overlapping scope.',
      'A restored VM or a cloned template that kept the source address.',
      'A rogue device or a misconfigured router interface on the same subnet.',
    ],
    checks: [
      PlaybookCheck(
        'show ip arp <address>',
        'the MAC currently bound to the address, and whether it changes',
      ),
      PlaybookCheck(
        'show mac address-table address <mac>',
        'the port the MAC is learned on, which identifies the device',
      ),
      PlaybookCheck(
        'show ip dhcp binding <address>',
        'whether DHCP also owns the address, which proves the overlap',
      ),
      PlaybookCheck(
        'arping or a gratuitous ARP capture',
        'which device answers, and whether two answers arrive',
      ),
    ],
    fix:
        'Find both devices, move the static one outside the pool, add the '
        'exclusion, and clear the ARP cache on the router and the affected '
        'hosts. Then verify the binding and the MAC are stable.',
    rule:
        'A duplicate IP is an addressing process failure, not a routing '
        'failure. Fix the allocation so it cannot recur; clearing the cache '
        'only hides it until the next lease.',
  ),
  DiagnosticPlaybook(
    id: 'stp-root-flap',
    title: 'Spanning-tree root bridge keeps changing',
    subjects: ['spanning tree', 'spanning-tree', 'stp', 'root', 'bridge'],
    signals: [
      'root bridge',
      'root keeps changing',
      'root flap',
      'topology change',
      'tc counter',
      'root guard',
      'root election',
    ],
    excludes: [
      'which switch should',
      'should be the root',
      'where should the root',
    ],
    meaning:
        'The root bridge election is unstable, so the active topology keeps '
        'recomputing. Every change flushes MAC tables and can briefly blackhole '
        'traffic across the whole layer-2 domain.',
    causes: [
      'No explicit root priority, so the election follows the lowest MAC and '
          'changes when a new switch is added or an old one reboots.',
      'A switch with a lower priority than the intended root is introduced '
          'behind an access port. Root Guard on the access edge prevents this.',
      'A flapping link or a unidirectional fiber that makes BPDUs appear and '
          'disappear.',
      'Two separate layer-2 domains bridged by accident, so each sees the '
          'other as a better root.',
    ],
    checks: [
      PlaybookCheck(
        'show spanning-tree root',
        'the current root, its priority and the path cost from this switch',
      ),
      PlaybookCheck(
        'show spanning-tree summary',
        'the topology change count and the root bridge priority',
      ),
      PlaybookCheck(
        'show spanning-tree inconsistentports',
        'ports blocked by Root Guard or Loop Guard, which names the intruder',
      ),
    ],
    fix:
        'Set root primary and secondary explicitly on the core pair, enable '
        'Root Guard on every access port, and clear the inconsistent state '
        'after the cause is removed.',
    rule:
        'An unset root priority is a design decision made by the lowest MAC '
        'address. Set it deliberately or the network will decide for you.',
  ),
  DiagnosticPlaybook(
    id: 'bgp-route-reflector',
    title: 'BGP routes are missing through a route reflector',
    subjects: ['bgp', 'route reflector', 'rr', 'ibgp'],
    signals: [
      'route reflector',
      'rr client',
      'reflected route',
      'missing routes ibgp',
      'ibgp full mesh',
      'cluster id',
    ],
    meaning:
        'The reflector received the route but did not reflect it, or the '
        'client did not accept it. The session can be up while the prefix is '
        'absent, so a neighbor check alone proves nothing.',
    causes: [
      'The client is not configured as a route-reflector-client on the '
          'reflector, so the route is treated as a normal iBGP route and is not '
          'reflected to other clients.',
      'A cluster ID or originator ID loop: the reflector sees its own cluster '
          'ID in the path and drops the route as a loop.',
      'The next hop is unreachable in the client VRF or has no IGP route, so '
          'the route is valid but not best.',
      'An inbound or outbound route map or prefix list filters the prefix on '
          'the reflector or the client.',
      'A second reflector with the same cluster ID, which makes the pair '
          'discard each other as loops.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp <prefix>',
        'the path, the originator, the cluster list and whether it is best',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> advertised-routes',
        'what the reflector actually sent to this client',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> | include reflector|cluster',
        'whether the session is a client and which cluster ID is used',
      ),
    ],
    fix:
        'Add the client under the correct address family, use a unique cluster '
        'ID per reflector pair, and check the next hop reachability in the '
        'client context. Then soft-clear the session rather than bouncing it.',
    rule:
        'A route reflector is a control-plane amplifier, not a router. If the '
        'session is up and the prefix is absent, read the advertised-routes '
        'output before changing any policy.',
  ),
  DiagnosticPlaybook(
    id: 'mpls-ldp',
    title: 'MPLS LDP session is down or labels are missing',
    subjects: ['mpls', 'ldp', 'label', 'vrf'],
    signals: [
      'ldp session',
      'ldp down',
      'no label',
      'label missing',
      'mpls not working',
      'ldp neighbor',
      'label stack',
    ],
    meaning:
        'LDP has not exchanged label bindings, or the transport route to the '
        'peer is missing. Without labels the VPN or the traffic-engineered path '
        'cannot forward, even though IP routing looks healthy.',
    causes: [
      'The LDP router ID is not reachable: a loopback without an IGP route, or '
          'an LDP transport address that points at an interface that is down.',
      'An ACL blocks TCP 646 or UDP 646 between the peers.',
      'The interface is not enabled for MPLS or LDP, so no hello is sent.',
      'Authentication or label distribution mode mismatch between vendors.',
      'The label is present but the forwarding entry is not programmed, which '
          'is a platform or TCAM issue rather than LDP.',
    ],
    checks: [
      PlaybookCheck(
        'show mpls ldp neighbor',
        'the session state and the transport address of each peer',
      ),
      PlaybookCheck(
        'show mpls ldp bindings',
        'the label bound to each prefix, local and remote',
      ),
      PlaybookCheck(
        'show mpls forwarding-table',
        'whether the label is actually installed, not just advertised',
      ),
      PlaybookCheck(
        'show ip route <peer-id>',
        'the transport route LDP depends on',
      ),
    ],
    fix:
        'Make the router ID a loopback that the IGP advertises, permit TCP/UDP '
        '646, enable MPLS on the core interfaces, and clear the LDP session '
        'after the transport route is correct.',
    rule:
        'LDP rides on IP reachability. When LDP breaks, check the route to the '
        'router ID before you check the LDP configuration.',
  ),
  DiagnosticPlaybook(
    id: 'dhcp-relay',
    title: 'DHCP relay is not answering',
    subjects: ['dhcp', 'relay', 'helper-address', 'scope'],
    signals: [
      'dhcp relay',
      'helper-address',
      'no dhcp',
      'not getting ip',
      'no ip address dhcp',
      'dhcp not working',
      '169.254',
      'apipa',
    ],
    meaning:
        'The client sends a Discover and no Offer comes back. The relay either '
        'did not forward it, the server did not match a scope, or the reply '
        'cannot return to the client.',
    causes: [
      'No ip helper-address on the client SVI, so the broadcast dies at the '
          'router.',
      'The helper points at a server that is unreachable, or the return route '
          'to the relay is missing.',
      'The scope does not match the relay giaddr, which is the interface that '
          'received the request, not the server subnet.',
      'The pool is exhausted or all addresses are excluded, so the server has '
          'nothing to offer.',
      'A DHCP snooping trust misconfiguration on the relay path drops the '
          'server reply.',
    ],
    checks: [
      PlaybookCheck(
        'show running-config interface <svi>',
        'whether the helper is present on the interface that serves the VLAN',
      ),
      PlaybookCheck(
        'show ip dhcp pool',
        'used versus total addresses and the excluded ranges',
      ),
      PlaybookCheck(
        'debug ip dhcp server packet',
        'whether the Discover arrives with the expected giaddr',
      ),
      PlaybookCheck(
        'show ip dhcp snooping binding',
        'whether snooping is dropping the offer before it reaches the client',
      ),
    ],
    fix:
        'Add the helper on the SVI, correct the scope to the relay subnet, free '
        'or expand the pool, and trust the uplink toward the real server. Then '
        'test from a client in the affected VLAN.',
    rule:
        'The scope follows the relay interface, not the server address. That '
        'one sentence explains most DHCP relay failures.',
  ),
  DiagnosticPlaybook(
    id: 'ipv6-ra',
    title: 'IPv6 host has no address or no default route',
    subjects: ['ipv6', 'ra', 'router advertisement', 'slaac', 'nd'],
    signals: [
      'no ipv6 address',
      'no ipv6',
      'slaac not working',
      'ra not received',
      'no default route ipv6',
      'ipv6 not working',
      'router advertisement',
    ],
    meaning:
        'The host is not receiving router advertisements, or it received a '
        'prefix but no usable default route. Without an RA there is no SLAAC '
        'address and no gateway, even if the link is up.',
    causes: [
      'IPv6 unicast routing is not enabled on the router, so it does not send '
          'RAs even with an address configured.',
      'The interface has no global or link-local address in the advertised '
          'prefix, or RA is suppressed.',
      'An ACL blocks ICMPv6 types 133-134, or IPv6 ND inspection is dropping '
          'the messages.',
      'The M and O flags tell the host to use DHCPv6 and no DHCPv6 server is '
          'answering.',
      'The host has IPv6 disabled, or its privacy policy is not producing an '
          'address from the advertised prefix.',
    ],
    checks: [
      PlaybookCheck(
        'show ipv6 interface <intf>',
        'the link-local, the global address and whether RA is enabled',
      ),
      PlaybookCheck(
        'show ipv6 routers',
        'the RAs the router itself has heard, which proves the segment works',
      ),
      PlaybookCheck(
        'show ipv6 neighbors',
        'whether the host is resolving the gateway at all',
      ),
      PlaybookCheck(
        'a capture of ICMPv6 133/134 on the segment',
        'whether the RA is sent and whether the host asks for it',
      ),
    ],
    fix:
        'Enable ipv6 unicast-routing, give the SVI a global address in the '
        'prefix, permit ICMPv6 133-137 on the access port, and align the M/O '
        'flags with the services that actually exist.',
    rule:
        'IPv6 does not have ARP or a default gateway without ND. If you block '
        'ICMPv6 broadly, you have broken IPv6 and the link still looks up.',
  ),
  DiagnosticPlaybook(
    id: 'nat-exhaustion',
    title: 'NAT translation table is exhausted',
    subjects: ['nat', 'pat', 'translation', 'port'],
    signals: [
      'nat exhaustion',
      'nat table full',
      'translation table full',
      'no translations',
      'port exhaustion',
      'nat failing under load',
    ],
    meaning:
        'Every public address and port pair is in use, so new flows cannot be '
        'translated. Existing flows keep working, which makes the fault look '
        'like an application problem until the table is checked.',
    causes: [
      'A scan or a worm creating many short-lived flows, each holding a '
          'translation until the timeout.',
      'Too few public addresses for the inside population at peak concurrency.',
      'A very short UDP timeout that is still longer than the flow rate, or a '
          'very long TCP timeout that holds dead entries.',
      'An application that opens a new connection per request without reusing '
          'them, multiplying the port demand.',
    ],
    checks: [
      PlaybookCheck(
        'show ip nat statistics',
        'used versus total translations, hits and misses',
      ),
      PlaybookCheck(
        'show ip nat translations | count',
        'the live count and the top inside hosts by translation count',
      ),
      PlaybookCheck(
        'show ip nat translations verbose',
        'the age and timeout of the entries that are not expiring',
      ),
      PlaybookCheck(
        'show ip traffic | include nat',
        'whether the drop is at translation or later in the path',
      ),
    ],
    fix:
        'Block the source of the churn, reduce the timeout for the offending '
        'protocol within reason, and add public addresses or move to a larger '
        'PAT pool. Then confirm the table drains.',
    rule:
        'A full NAT table is a capacity and security symptom, not a bug in '
        'NAT. Find what is opening the flows before adding addresses.',
  ),
  DiagnosticPlaybook(
    id: 'firewall-ha-failover',
    title: 'Firewall HA pair failed over unexpectedly',
    subjects: ['firewall', 'failover', 'ha', 'active standby'],
    signals: [
      'firewall failover',
      'failed over',
      'failover happened',
      'ha pair',
      'standby became active',
      'failover flapping',
    ],
    meaning:
        'The standby took over because a monitored condition failed, or the '
        'pair lost its hello path. The trigger matters more than the fact of '
        'the failover: a link failure and a control-plane failure need '
        'different fixes.',
    causes: [
      'A monitored interface went down, so the unit relinquished the active '
          'role even though the appliance was healthy.',
      'The failover link or hello path failed, so each unit thought the other '
          'was gone and both tried to be active.',
      'A resource or inspection engine failure on the active unit, which is a '
          'real hardware or software fault.',
      'Configuration drift between the units, so the standby could not sync '
          'and was not actually ready.',
    ],
    checks: [
      PlaybookCheck(
        'show failover',
        'the current state, the last transition reason and the monitored '
            'interfaces',
      ),
      PlaybookCheck(
        'show failover history',
        'the sequence of events, which distinguishes a link from a resource',
      ),
      PlaybookCheck(
        'show interface <failover-link>',
        'whether the sync path itself is erroring',
      ),
      PlaybookCheck(
        'show logging | include failover',
        'the exact trigger and whether both units logged it',
      ),
    ],
    fix:
        'Fix the monitored condition or the sync link, verify the standby is '
        'in sync, and only then fail back in a window. Do not disable '
        'monitoring to stop the alarms.',
    rule:
        'A failover that fires for a monitored link is the design working. '
        'Removing the monitor to silence it is the design failing.',
  ),
  DiagnosticPlaybook(
    id: 'stack-member',
    title: 'Stack member is missing or not joining',
    subjects: ['stack', 'stacking', 'member', 'switch stack'],
    signals: [
      'stack member',
      'member not joining',
      'switch missing from stack',
      'stack cable',
      'stack port down',
      'stack split',
    ],
    meaning:
        'A stacking member is not elected, not provisioned, or has lost its '
        'stack links. A split stack can produce two active switches with the '
        'same management address, which is worse than a single dead member.',
    causes: [
      'A stack cable is loose, in the wrong port, or in a chain rather than a '
          'ring.',
      'The member is running a different firmware version and cannot join the '
          'stack.',
      'The member is not provisioned, or its priority causes an unexpected '
          'master election.',
      'The stack has split because both ring cables failed, so each half '
          'elected its own master.',
    ],
    checks: [
      PlaybookCheck(
        'show switch',
        'the member state, the master, and whether a member is provisioned',
      ),
      PlaybookCheck(
        'show switch stack-ports',
        'whether each stack port is up and in a ring',
      ),
      PlaybookCheck(
        'show version | include switch',
        'the firmware of every member, which must match',
      ),
    ],
    fix:
        'Reseat or replace the cable, match the firmware, provision the member '
        'with the right priority, and restore the ring. Then verify the stack '
        'is one logical switch before returning it to service.',
    rule:
        'A stack is one failure domain. Maintain it as one device, with one '
        'upgrade window and one tested ring, not as independent switches.',
  ),
  DiagnosticPlaybook(
    id: 'dmvpn-nhrp',
    title: 'DMVPN spoke cannot reach another spoke',
    subjects: ['dmvpn', 'nhrp', 'spoke', 'hub', 'tunnel'],
    signals: [
      'spoke to spoke',
      'nhrp',
      'spoke cannot reach',
      'tunnel mapping',
      'nhrp resolution',
      'spokes cannot reach each other',
      'spokes cannot reach',
      'spoke to spoke fails',
    ],
    meaning:
        'The spoke-to-spoke shortcut did not form, so traffic either stays on '
        'the hub path or is dropped. NHRP resolution and the tunnel protection '
        'must both work before the direct path exists.',
    causes: [
      'NHRP registration failed, so the hub has no mapping for the spoke '
          'tunnel address.',
      'The spoke has no route to the other spoke tunnel address, or the '
          'redirect is not enabled on the hub (phase 3).',
      'IPsec tunnel protection drops the NHRP or the shortcut traffic because '
          'the ACL or the profile does not cover it.',
      'A NAT device in the path rewrites the tunnel address without NAT-T.',
    ],
    checks: [
      PlaybookCheck(
        'show dmvpn',
        'the peer state, the NBMA address and whether the tunnel is up',
      ),
      PlaybookCheck(
        'show ip nhrp',
        'the registered mappings on the hub and the resolved cache on the '
            'spoke',
      ),
      PlaybookCheck(
        'show crypto ipsec sa',
        'whether the shortcut SA exists and is passing packets',
      ),
    ],
    fix:
        'Correct the NHRP network ID and authentication, enable redirect on '
        'the hub for phase 3, and make sure the tunnel protection profile '
        'covers the spoke-to-spoke flow. Then clear the NHRP cache and test.',
    rule:
        'A DMVPN tunnel that is up is not a spoke-to-spoke path. Prove the '
        'shortcut with the NHRP cache and the SA counters, not with a ping to '
        'the hub.',
  ),
  DiagnosticPlaybook(
    id: 'sdwan-tunnel',
    title: 'SD-WAN tunnel is down or flapping',
    subjects: ['sd-wan', 'sdwan', 'vmanage', 'viptela'],
    signals: [
      'sdwan tunnel',
      'sd-wan tunnel',
      'overlay down',
      'tunnel flapping',
      'control connection down',
      'bfd down sdwan',
    ],
    meaning:
        'The overlay tunnel is not established or is unstable. The underlay '
        'may be healthy while the overlay fails on certificates, keys, ports or '
        'path quality, so check the layers in order.',
    causes: [
      'The control connection is down: wrong controller address, certificate '
          'or organization name, or UDP 12346 blocked.',
      'The BFD probe fails because the underlay path drops the probe or the '
          'latency and loss exceed the threshold.',
      'A NAT or firewall in the path rewrites the tunnel endpoint without the '
          'required keepalive or port range.',
      'The device certificate expired, or the controller clock is wrong.',
    ],
    checks: [
      PlaybookCheck(
        'show sdwan control connections',
        'the controller state, the certificate status and the last error',
      ),
      PlaybookCheck(
        'show sdwan bfd sessions',
        'the per-tunnel state, loss, latency and jitter',
      ),
      PlaybookCheck(
        'show sdwan tunnel statistics',
        'whether the tunnel is passing traffic or only flapping',
      ),
      PlaybookCheck(
        'show clock',
        'a wrong clock invalidates certificates and breaks the control plane',
      ),
    ],
    fix:
        'Restore the control connection first, then the certificate, then the '
        'BFD path. Do not tune the BFD thresholds to hide a lossy underlay.',
    rule:
        'SD-WAN is an overlay on an underlay. When the tunnel is down, prove '
        'the underlay path and the certificate before touching the policy.',
  ),
  DiagnosticPlaybook(
    id: 'lb-502',
    title: 'Load balancer returns 502 or 503',
    subjects: ['load balancer', 'lb', 'haproxy', 'f5', 'nginx', 'pool'],
    signals: [
      '502',
      '503',
      'bad gateway',
      'service unavailable',
      'pool member down',
      'health check failing',
      'load balancer error',
    ],
    meaning:
        'The load balancer could not get a valid response from a pool member '
        '(502) or has no member it considers available (503). The client sees '
        'a proxy error, not an application error, so the backend is the place '
        'to look.',
    causes: [
      'The health check is failing: wrong path, wrong port, a TLS mismatch, or '
          'a response code the check does not accept.',
      'The member is up but the application is not listening, or it is '
          'listening on a different port than the pool.',
      'A firewall or network policy between the load balancer and the member '
          'blocks the health check but not the data, or the reverse.',
      'All members are at their connection limit, so the balancer returns 503 '
          'without trying.',
    ],
    checks: [
      PlaybookCheck(
        'show pool <name>',
        'member state, health monitor result and current connections',
      ),
      PlaybookCheck(
        'a direct request from the load balancer host to the member',
        'whether the member answers on the exact health-check path and port',
      ),
      PlaybookCheck(
        'the load balancer logs for the request',
        'the selected member, the response code and the failure reason',
      ),
    ],
    fix:
        'Correct the health check to match the application, fix the member or '
        'the policy between the balancer and the member, and confirm the pool '
        'is green before sending traffic back.',
    rule:
        'A 502 is a member response problem; a 503 is a capacity or health '
        'problem. The distinction halves the search space.',
  ),
  DiagnosticPlaybook(
    id: 'certificate-expiry',
    title: 'Certificate expired or is not trusted',
    subjects: ['certificate', 'tls', 'ssl', 'pki', 'ca'],
    signals: [
      'certificate expired',
      'cert expired',
      'certificate error',
      'not trusted',
      'untrusted certificate',
      'handshake failure',
      'x509',
    ],
    meaning:
        'The TLS handshake fails because the peer cannot validate the '
        'certificate chain, the name does not match, or the validity window '
        'has passed. The application sees a generic handshake failure, so the '
        'certificate is the first thing to check.',
    causes: [
      'The certificate is past its notAfter date, or the client clock is wrong '
          'and believes it is not yet valid.',
      'The chain is incomplete: the server sends its leaf but not the '
          'intermediate, so the client cannot build a path to the trusted root.',
      'The subject alternative name does not include the hostname the client '
          'used.',
      'The client does not trust the issuing CA, which is common with an '
          'internal CA or a TLS inspection proxy.',
    ],
    checks: [
      PlaybookCheck(
        'openssl s_client -connect host:443 -servername host',
        'the presented chain, the dates and the verification error',
      ),
      PlaybookCheck(
        'openssl x509 -in cert.pem -noout -dates -subject -ext subjectAltName',
        'the validity window and the names the certificate actually covers',
      ),
      PlaybookCheck(
        'the client and server clocks',
        'a skew of minutes is enough to invalidate a valid certificate',
      ),
    ],
    fix:
        'Renew before expiry, install the full chain including the '
        'intermediate, add every hostname to the SAN, and distribute the '
        'internal CA to the clients that must trust it.',
    rule:
        'Certificate failures are time, name and trust. Check those three '
        'before you debug the application.',
  ),
  DiagnosticPlaybook(
    id: 'tcam-exhaustion',
    title: 'Hardware table or TCAM is exhausted',
    subjects: ['tcam', 'fib', 'hardware table', 'route table', 'acl'],
    signals: [
      'tcam full',
      'tcam exhaustion',
      'fib full',
      'hardware table full',
      'cannot install route',
      'route not in hardware',
      'acl not programmed',
    ],
    meaning:
        'The control plane has the route or ACL, but the forwarding hardware '
        'cannot install it. The result is silent: the prefix is in the RIB and '
        'missing from the FIB, or an ACL entry is not enforced.',
    causes: [
      'A full internet table plus ACLs and QoS entries competing for the same '
          'TCAM space.',
      'An ACL expansion that is far larger than the configured lines, because '
          'each line with ports expands into many entries.',
      'IPv6 routes and neighbor entries consuming a partition that was sized '
          'for IPv4 only.',
      'A platform carving TCAM per feature, so the region for routes is small '
          'even though the total is large.',
    ],
    checks: [
      PlaybookCheck(
        'show platform tcam utilization',
        'which region is full and what is using it',
      ),
      PlaybookCheck(
        'show ip route <prefix>',
        'whether the route is in the RIB but not the FIB',
      ),
      PlaybookCheck(
        'show ip cef <prefix>',
        'whether the forwarding entry is installed or dropped',
      ),
      PlaybookCheck(
        'show processes memory sorted',
        'whether the limit is memory rather than TCAM',
      ),
    ],
    fix:
        'Reduce what the hardware must hold: summarize routes, remove unused '
        'ACLs, move policy to a firewall, and re-carve the TCAM if the platform '
        'supports it. Then verify the prefix is in the FIB, not just the RIB.',
    rule:
        'A route in the routing table is not a route in the forwarding path. '
        'Check the FIB before you blame the routing protocol.',
  ),
  // --- Routing: sessions that flap, never form, or lie ---------------------
  DiagnosticPlaybook(
    id: 'bgp-flap',
    title: 'BGP session flapping',
    subjects: ['bgp', 'ebgp', 'ibgp', 'border gateway protocol'],
    signals: [
      'flapping',
      'flaps',
      'keeps bouncing',
      'keeps dropping',
      'keeps resetting',
      'resets',
      'session drops',
      'session dropped',
      'comes up and down',
      'up and down',
      'bouncing',
    ],
    excludes: ['ospf', 'eigrp', 'isis', 'bfd', 'ipsec', 'tunnel'],
    meaning:
        'A session that reaches Established and then resets is failing after '
        'the OPEN exchange, so the transport works at least once. The reset '
        'reason in the log names the layer: hold-timer expiry is one-way '
        'traffic or CPU starvation, "connection reset" is a policy or MTU '
        'drop, and a TCP checksum or retransmit burst is congestion or a '
        'bad link. Flapping is never a single cause until the log says so.',
    causes: [
      'MTU mismatch on the path. The OPEN is small and establishes; the '
          'first full UPDATE over 1500 bytes is dropped, the hold timer '
          'expires, and the session restarts. This is the classic "up for '
          'three minutes, then down" flap.',
      'Keepalive or hold-time mismatch (default 60 / 180). A hold time lower '
          'than three keepalives tears the session down under normal load.',
      'One-way reachability: the return path takes a different exit or the '
          'peer filters TCP 179 only in one direction, so TCP goes to '
          'retransmission and then resets.',
      'Control-plane policing or CPU stuck in the same priority lane as BGP '
          'traffic (CoPP drops the keepalives first, by design).',
      'Route processor overloaded: full table churn, a redistribution loop, '
          'or BGP scanning a huge policy every update.',
    ],
    checks: [
      PlaybookCheck(
        'show log | include BGP',
        'the reset reason the neighbour never tells you',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer>',
        'uptime, hold time, last reset reason, and the keepalive counters',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> | include maximum|data',
        'whether a max-prefix limit is shutting the session down',
      ),
      PlaybookCheck(
        'ping <peer> size 1500 df-bit repeat 10',
        'proves whether the path carries a full-size packet',
      ),
      PlaybookCheck(
        'show control-plane host open-ports',
        'whether CoPP or a rate limiter is policing port 179',
      ),
    ],
    fix:
        'Fix the layer the reset reason names. For MTU, either raise the path '
        'MTU or lower the adjacency MTU (ip tcp path-mtu-discovery plus '
        'ip tcp adjust-mss on the transit interfaces). For policy, permit '
        '179 in both directions with the TTL and the source address the peer '
        'actually sees. For load, apply max-prefix with a warning threshold '
        'to stop the churn at the source.',
    rule:
        'A flapping session is an evidence problem: do not touch the policy '
        'until the log names the reset reason. Two changes at once destroys '
        'the evidence you need.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show log messages | match BGP; show bgp neighbor <peer>; '
            'show configuration protocols bgp',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'bgp-not-establishing',
    title: 'BGP session never establishes',
    subjects: ['bgp', 'ebgp', 'ibgp', 'border gateway protocol'],
    signals: [
      'not coming up',
      'never comes up',
      'will not come up',
      'never establishes',
      'cannot establish',
      'no session',
      'no adjacency',
      'peer down',
    ],
    excludes: ['ospf', 'eigrp', 'isis', 'bfd', 'ipsec', 'tunnel', 'hsrp'],
    meaning:
        'If it never reaches Established, the failure is before any prefix is '
        'exchanged: either the TCP handshake never completes, or the OPEN is '
        'rejected. The state is the whole diagnosis - Idle means the router '
        'has not even tried, Active means it is trying, Connect means TCP is '
        'in progress, OpenSent means the peer answered and the OPEN was '
        'rejected, OpenConfirm means only the keepalives are missing.',
    causes: [
      'No route to the neighbour address, or the route points at the wrong '
          'interface (loopback peering without an update-source).',
      'TCP 179 filtered by an ACL, a firewall, or a provider.',
      'AS number mismatch: the OPEN arrives and is rejected immediately, '
          'leaving OpenSent/Idle with a "bad AS" notification in the log.',
      'MD5/TCP-AO authentication mismatch; the peer silently drops the '
          'segment because the signature never validates.',
      'The peer is configured with a different address for us (NAT in the '
          'path is the usual cause) and rejects the source.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp summary',
        'the state of every peer: Idle, Active, OpenSent, Established',
      ),
      PlaybookCheck(
        'show log | include BGP',
        'the notification code: bad AS, bad auth, bad peer address',
      ),
      PlaybookCheck(
        'telnet <peer> 179',
        'whether anything binds TCP 179 end to end (a refused or timed-out '
            'connect separates policy from reachability)',
      ),
      PlaybookCheck(
        'show ip route <peer>',
        'whether a route exists and which interface it uses',
      ),
      PlaybookCheck(
        'show tcp brief | include 179',
        'the local socket state: SYN-SENT means the peer never answered',
      ),
    ],
    fix:
        'Make the transport work first: route, then policy for 179 in both '
        'directions, then the exact neighbour address and AS. Only then look '
        'at the OPEN: update-source, ebgp-multihop, password, and the peer '
        'address the far side has configured for you.',
    rule:
        'Never troubleshoot BGP policy before the session is Established. '
        'Policy only runs on prefixes, and there are none yet.',
  ),
  DiagnosticPlaybook(
    id: 'bgp-as-path-loop',
    title: 'BGP rejects a prefix with an AS path loop',
    subjects: ['bgp', 'ebgp', 'ibgp', 'as path', 'as-path'],
    signals: [
      'as path loop',
      'as-path loop',
      'as loop',
      'own as in path',
      'path contains my as',
      'rejected due to as path',
      'prepend loop',
    ],
    meaning:
        'BGP drops any UPDATE whose AS_PATH already contains the receiving '
        'AS. That is loop prevention working, not failing: the prefix came '
        'back around a ring of peers (or through a route reflector pair with '
        'a misconfigured cluster), so the receiving router refuses it.',
    causes: [
      'A provider is leaking a prefix back with your AS already prepended - '
          'the usual peering misconfiguration.',
      'A mutual redistribution loop: the prefix leaves your AS, gets '
          'redistributed into another AS and comes back.',
      'allowas-in configured on one side, which lets the loop back in and '
          'hides the real mistake.',
      'Route reflector or confederation misconfiguration, where the same '
          'prefix is reflected back to its originator with a path it should '
          'never have seen.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp <prefix>',
        'every path received, with the AS path and the reason each was '
            'rejected',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> routes',
        'what that peer sent and which paths were filtered',
      ),
      PlaybookCheck(
        'show ip as-path-access-list',
        'whether an AS-path filter is doing this on purpose',
      ),
    ],
    fix:
        'Ask the peer to filter their leak; do not allowas-in to hide it. If '
        'the loop is yours, break the redistribution with a tag or a prefix '
        'list, and keep allowas-in only where the backup path genuinely needs '
        'it.',
    rule:
        'An AS path loop is usually the other network\'s leak. Fixing it on '
        'your side with allowas-in moves the black hole instead of removing '
        'it.',
  ),
  DiagnosticPlaybook(
    id: 'ospf-adjacency',
    title: 'OSPF adjacency does not form or keeps resetting',
    subjects: ['ospf', 'ospfv3', 'ospf neighbor', 'adjacency'],
    signals: [
      'not forming',
      'not coming up',
      'no adjacency',
      'adjacency down',
      'neighbor down',
      'keeps resetting',
      'flapping',
      'drops',
      'stuck',
    ],
    excludes: ['bgp', 'eigrp', 'isis', 'bfd'],
    meaning:
        'One neighbour that never reaches FULL is a unicast Hello problem or '
        'a parameter mismatch; neighbours that reach FULL and drop repeatedly '
        'are usually a timer mismatch, an MTU problem on the DBD exchange, or '
        'a flapping physical link. The neighbour state after the reset tells '
        'you which half you are in.',
    causes: [
      'Hello or dead interval mismatch: on broadcast media the timers must '
          'match exactly, and the mismatch leaves the neighbour in INIT.',
      'Area or stub mismatch: both sides must agree on the area ID, and on '
          'whether the area is stub, NSSA or normal.',
      'MTU mismatch: the DBD exchange stalls in EXSTART/EXCHANGE because the '
          'larger DBD is silently dropped.',
      'Duplicate router ID, which makes one router ignore the other.',
      'Unicast hellos blocked by an ACL, while the broadcast hellos on the '
          'same segment still work - so "some neighbours form" and others do '
          'not.',
      'Physical or L2 flap below OSPF, which resets the adjacency every time '
          'the link bounces.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf neighbor',
        'state, uptime, dead time and the interface each neighbour is on',
      ),
      PlaybookCheck(
        'show ip ospf interface <intf>',
        'area, timers, network type, MTU and the hello counters',
      ),
      PlaybookCheck(
        'show ip ospf',
        'router ID and the list of areas - duplicates show up here',
      ),
      PlaybookCheck(
        'show ip ospf neighbor detail',
        'the last state change and the options mismatch',
      ),
      PlaybookCheck(
        'show interface <intf> | include flaps|reset|duplex',
        'whether the layer below is bouncing the adjacency',
      ),
    ],
    fix:
        'Match the parameters the state points at: timers, area and stub '
        'flags, MTU (ip mtu / ip ospf mtu-ignore only as a documented '
        'workaround), and router IDs. If the link flaps, fix the link - OSPF '
        'is only reporting it.',
    rule:
        'A neighbour that reaches FULL and falls back is a link or timer '
        'problem; a neighbour that never gets past INIT is a Hello problem. '
        'Never tune OSPF timers to hide a flapping link.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show ospf neighbor; show ospf interface detail; show log messages '
            '| match OSPF',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'eigrp-neighbor',
    title: 'EIGRP neighbour will not form',
    subjects: ['eigrp'],
    signals: [
      'not forming',
      'not coming up',
      'no neighbor',
      'no neighbour',
      'neighbor down',
      'stuck',
      'flapping',
    ],
    meaning:
        'EIGRP forms only with a matching AS number and matching K values, '
        'on the same primary subnet, with the same authentication. A mismatch '
        'of any one of them leaves the neighbour absent with no error on the '
        'console - the hellos are simply discarded.',
    causes: [
      'Different autonomous-system number on the two routers.',
      'K-value mismatch (metric weights), which shows as a mismatch in '
          'debug eigrp packets.',
      'Authentication key or key chain mismatch, or the key is not yet valid.',
      'Interfaces on different subnets, or a secondary address that the '
          'primary network statement does not cover.',
      'Passive interface on one side, which stops hellos outright.',
    ],
    checks: [
      PlaybookCheck(
        'show ip eigrp neighbors',
        'whether the adjacency exists at all',
      ),
      PlaybookCheck(
        'show ip protocols',
        'the AS number, the K values and the network statements in effect',
      ),
      PlaybookCheck(
        'show ip eigrp interfaces detail',
        'which interfaces are passive, and the authentication mode',
      ),
      PlaybookCheck(
        'show key chain',
        'whether the key is valid now, not later',
      ),
    ],
    fix:
        'Match the AS, the K values, the subnet and the key chain. Remove '
        'passive-interface from the link, and make sure the interface address '
        'is covered by the network statement rather than assumed.',
    rule:
        'EIGRP is quiet about mismatches. When a neighbour is missing and the '
        'interface is up, compare configuration line by line before you '
        'debug.',
  ),
  DiagnosticPlaybook(
    id: 'bgp-rpki-invalid',
    title: 'BGP prefixes marked RPKI invalid',
    subjects: ['rpki', 'roa', 'origin validation', 'bgp'],
    signals: [
      'rpki invalid',
      'invalid prefix',
      'roa mismatch',
      'origin validation',
      'not-valid',
      'invalid route',
    ],
    meaning:
        'An RPKI invalid route means the origin AS in the AS_PATH does not '
        'match any ROA for that prefix. The route may still be the real one - '
        'origin validation proves who is allowed to originate the prefix, not '
        'that the path is good - so dropping invalid on a partial view is how '
        'a network loses reachability it actually needs.',
    causes: [
      'The prefix is announced by a downstream customer whose AS is not in '
          'the ROA (a missing or stale ROA on the registry side).',
      'A route leak: someone else is originating a prefix they do not own.',
      'A multi-origin prefix, where one origin is covered by a ROA and the '
          'other is not.',
      'A stale RPKI cache, so the validator is serving old data.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp <prefix>',
        'the validation state per path and the origin AS each one carries',
      ),
      PlaybookCheck(
        'show rpki prefix-table <prefix>',
        'the ROA actually loaded: AS, prefix length and max length',
      ),
      PlaybookCheck(
        'show rpki servers',
        'whether the cache is connected and how stale its data is',
      ),
    ],
    fix:
        'Publish or correct the ROA for your own space first. For received '
        'routes, prefer "invalid: prefer-valid over not-found over invalid" '
        'until the cache and the ROAs are clean, and drop invalid only where '
        'you can see the full table.',
    rule:
        'RPKI validates origin only. Rely on it to stop a hijack, never to '
        'prove a path is optimal.',
  ),

  // --- Switching ----------------------------------------------------------
  DiagnosticPlaybook(
    id: 'stp-wrong-blocking',
    title: 'Spanning tree blocks the wrong link',
    subjects: ['stp', 'spanning tree', 'rstp', 'mst', 'pvst'],
    signals: [
      'blocking the wrong port',
      'blocking the wrong link',
      'blocks the wrong',
      'wrong port blocked',
      'blocks the uplink',
      'blocked the wrong',
      'traffic takes the long path',
    ],
    meaning:
        'STP blocks a port by root path cost, then by sender bridge ID, then '
        'by port priority, then by port number. If the "wrong" link is '
        'blocked, one of those four inputs is not what you think: a port '
        'priority or path cost left at default, a different root, or a '
        'topology you assumed was a triangle and is actually a longer chain.',
    causes: [
      'Port cost or priority set manually on one side, so the intended '
          'primary path loses on the tie-break.',
      'A different bridge is the root than you assumed, changing every cost '
          'in the tree.',
      'MST region misconfiguration: an instance maps to a different VLAN on '
          'one switch, so the two do not share a tree.',
      'A hub or an unmanaged switch in the path, flattening the topology '
          'without appearing in the topology diagram.',
      'EtherChannel one side down, so STP sees two separate slow links '
          'instead of one bundle.',
    ],
    checks: [
      PlaybookCheck(
        'show spanning-tree root',
        'who the root is and the total path cost to it',
      ),
      PlaybookCheck(
        'show spanning-tree interface <intf> detail',
        'the per-port cost, priority and the role the switch chose',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <vlan>',
        'the root port on each switch and which port is blocking',
      ),
      PlaybookCheck(
        'show etherchannel summary',
        'whether a bundle is degraded and being counted as individual links',
      ),
    ],
    fix:
        'Set the intended primary path explicitly: lower cost or higher port '
        'priority on the primary uplink, and confirm the root by hand. For a '
        'ring, keep one side of every pair pre-blocked with a cost and treat '
        'the rest as backup.',
    rule:
        'Never leave STP to choose the production path by accident. The '
        'topology you intend is a configuration, not a default.',
  ),
  DiagnosticPlaybook(
    id: 'bpduguard-errdisable',
    title: 'Port disabled by BPDU Guard',
    subjects: ['bpduguard', 'bpdu guard', 'portfast', 'switchport'],
    signals: [
      'err-disabled',
      'errdisabled',
      'disabled by bpdu',
      'err disabled by bpdu',
      'port went down',
      'edge port disabled',
    ],
    meaning:
        'BPDU Guard disables any portfast port that receives a BPDU. That is '
        'the feature doing its job: something on the edge is either a switch, '
        'a hub, or a VM bridge that is speaking spanning tree. The cause is '
        'always the device that sent the BPDU, never the switch.',
    causes: [
      'A wireless AP, IP phone or VM host bridging two ports, so BPDUs reach '
          'the access port.',
      'A user plugged in a small unmanaged switch that speaks STP.',
      'The port is a trunk or uplink but was configured with portfast.',
      'A loopback cable from a maintenance test left in place.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces status err-disabled',
        'which ports are down by policy and the reason recorded',
      ),
      PlaybookCheck(
        'show spanning-tree interface <intf>',
        'whether the port is portfast and whether it sees a BPDU',
      ),
      PlaybookCheck(
        'show log | include BPDU',
        'the timestamp and the port, which identifies the device that was '
            'plugged in',
      ),
      PlaybookCheck(
        'show mac address-table interface <intf>',
        'how many MACs the port learned, which proves something is bridging',
      ),
    ],
    fix:
        'Find and remove the bridge, then bounce the port. If the device is '
        'legitimate (an AP or an IP phone), configure the right feature - '
        'trunk plus BPDU Filter on the AP port, or the phone VLAN by CDP/LLDP '
        '- rather than disabling BPDU Guard globally.',
    rule:
        'Do not clear an err-disabled edge port without identifying what sent '
        'the BPDU. It comes back within a minute if the bridge is still '
        'there.',
  ),
  DiagnosticPlaybook(
    id: 'trunk-native-mismatch',
    title: 'Trunk nominal but native VLAN or allowed list is wrong',
    subjects: ['trunk', 'dot1q', '802.1q', 'switchport'],
    signals: [
      'native vlan mismatch',
      'native vlan',
      'cdp mismatch',
      'vlan mismatch',
      'untagged traffic',
      'allowed vlan',
      'not allowed on trunk',
    ],
    meaning:
        'The trunk is up, so every VLAN you allowed flows. Two things still '
        'break: untagged frames land on the wrong VLAN when the native VLAN '
        'differs, and a VLAN can be in the database but not in the allowed '
        'list. IOS reports the first as a CDP native VLAN mismatch; the '
        'second is silent.',
    causes: [
      'The native VLAN is default VLAN 1 on one side and an unused VLAN on '
          'the other, so untagged management or CDP traffic lands in the '
          'wrong broadcast domain.',
      'The VLAN is missing from the allowed list on one trunk, or pruned by '
          'VTP.',
      'A VLAN is not in the local database at all, so "switchport trunk '
          'allowed vlan add" fails silently on some platforms.',
      'VLAN 1 is used for untagged traffic and becomes the security hole '
          'nobody owns.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces trunk',
        'allowed, active and forwarding VLANs per trunk, plus the native '
            'VLAN in use',
      ),
      PlaybookCheck(
        'show vlan brief',
        'whether the VLAN exists locally at all',
      ),
      PlaybookCheck(
        'show interfaces switchport',
        'the configured native VLAN and the administrative mode',
      ),
      PlaybookCheck(
        'show cdp neighbors detail',
        'the native VLAN mismatch warning, if CDP is enabled',
      ),
    ],
    fix:
        'Set an explicit, unused native VLAN on both ends, allow only the '
        'VLANs that exist, and add new VLANs to the allowed list everywhere '
        'in the same change window. If pruning is on, verify it before '
        'believing the allowed list.',
    rule:
        'A trunk is a policy object, not a cable. The allowed list is the '
        'policy and it is silent when wrong.',
  ),
  DiagnosticPlaybook(
    id: 'arp-incomplete',
    title: 'ARP incomplete - the host cannot be resolved',
    subjects: ['arp', 'arp cache', 'layer 2', 'switch'],
    signals: [
      'arp incomplete',
      'incomplete arp',
      'arp entry incomplete',
      'arp not resolving',
      'cannot resolve mac',
      'no mac address',
      'arp timeout',
    ],
    meaning:
        'An incomplete ARP entry means the router sent the request and '
        'nothing answered on that segment. The IP path stops here: either '
        'the destination is not on that L2 segment, or it is there but its '
        'reply is filtered, or the request never reaches it.',
    causes: [
      'Wrong VLAN or wrong subnet: the target is on another segment and the '
          'gateway is not in the path.',
      'The target host is firewalled (Windows Firewall or a private VLAN) '
          'and drops broadcast ARP.',
      'Private VLAN or port isolation on the access port, which prevents '
          'peer-to-peer traffic even inside one subnet.',
      'A MAC address table overflow or a flapping MAC, so the switch no '
          'longer knows where the destination is.',
      'DAI with a missing binding: the switch forwards the request but drops '
          'the reply.',
    ],
    checks: [
      PlaybookCheck(
        'show ip arp <ip>',
        'the entry state and the interface it was learned on',
      ),
      PlaybookCheck(
        'show mac address-table address <mac>',
        'which port the destination actually sits on',
      ),
      PlaybookCheck(
        'show ip dhcp snooping binding',
        'whether DAI has a binding to validate against',
      ),
      PlaybookCheck(
        'show interface <intf> | include broadcasts|drops',
        'whether the segment is dropping broadcasts',
      ),
    ],
    fix:
        'Confirm the VLAN and subnet match, then check the access-port '
        'policy (private VLAN, DAI, port ACL). For a host that must be seen '
        'by peers, that policy is the fault even though ARP looks broken.',
    rule:
        'ARP does not cross a broadcast boundary. When ARP is incomplete, '
        'the first question is which broadcast domain each side is in.',
  ),
  DiagnosticPlaybook(
    id: 'vlan-not-propagating',
    title: 'A VLAN exists on one switch but not another',
    subjects: ['vlan', 'vtp', 'vlan database'],
    signals: [
      'vlan missing',
      'vlan not there',
      'vlan not created',
      'vlan does not exist',
      'vtp',
      'vlan not propagating',
      'missing vlan',
    ],
    meaning:
        'A VLAN is local state: it must exist in the switch database before '
        'it can carry traffic on a trunk, and a trunk that allows a VLAN the '
        'switch does not have will drop it silently. VTP can create it on '
        'your behalf - including deleting it everywhere, which is why VTP '
        'transparent or off is the senior default.',
    causes: [
      'The VLAN was never created on that switch.',
      'VTP mode server/client with a lower revision number, so the newer '
          'database did not overwrite it.',
      'VTP pruning removing the VLAN from a trunk because no access port '
          'needs it yet.',
      'The allowed list excludes it even though it exists.',
    ],
    checks: [
      PlaybookCheck('show vlan brief', 'the local VLAN database'),
      PlaybookCheck(
        'show vtp status',
        'mode, domain, revision and whether pruning is on',
      ),
      PlaybookCheck(
        'show interfaces trunk',
        'the allowed list and whether pruning removed the VLAN',
      ),
    ],
    fix:
        'Create the VLAN where it is missing, then allow it on every trunk in '
        'the path. If VTP is the reason it disappeared, move to transparent '
        'mode and own the database.',
    rule:
        'A VLAN is not a broadcast that carries itself from switch to switch. '
        'Create it, allow it, then verify it.',
  ),
  DiagnosticPlaybook(
    id: 'port-channel-imbalance',
    title: 'EtherChannel is up but traffic uses one link',
    subjects: ['etherchannel', 'port-channel', 'lacp', 'lag'],
    signals: [
      'one link busy',
      'only one link active',
      'not balancing',
      'imbalanced',
      'uneven traffic',
      'hash',
      'one member',
    ],
    meaning:
        'A bundle forwards each flow over exactly one member, chosen by a '
        'hash of the fields in the load-balance setting. If every flow has '
        'the same hash inputs - one server pair, one destination MAC under '
        'L2 hashing - every flow lands on the same member. The bundle is fine; '
        'the hash inputs are not diverse.',
    causes: [
      'The load-balance method uses a single field (for example '
          'src-dst-mac) and all traffic shares one MAC pair through a router.',
      'All flows are one elephant flow, which cannot be split by a hash.',
      'Some members are in hot-standby or suspended state, so the bundle has '
          'fewer paths than you think.',
      'The hash is computed per member platform and asymmetric across the '
          'chassis, so the return path uses a different member.',
    ],
    checks: [
      PlaybookCheck(
        'show etherchannel load-balance',
        'which fields the hash uses',
      ),
      PlaybookCheck(
        'show etherchannel summary',
        'member state: bundled, hot-standby, suspended',
      ),
      PlaybookCheck(
        'show interfaces port-channel <n> | include rate',
        'per-member utilisation over the same interval',
      ),
    ],
    fix:
        'Choose the hash that matches the traffic: src-dst-ip for routed '
        'flows, src-dst-mac for switched ones, and a 5-tuple where the '
        'platform offers it. For a single elephant flow, accept that the '
        'bundle does not help, or split the flow across flows.',
    rule:
        'A bundle multiplies flows, never a single flow. Capacity planning '
        'that assumes one flow can use the whole bundle is wrong by design.',
  ),

  // --- Performance --------------------------------------------------------
  DiagnosticPlaybook(
    id: 'qos-marking-lost',
    title: 'QoS markings are lost in transit',
    subjects: ['qos', 'dscp', 'cos', 'marking'],
    signals: [
      'markings lost',
      'marking stripped',
      'dscp reset',
      'dscp zero',
      'cos zero',
      'qos not working',
      'qos not applied',
      'class map not matching',
    ],
    meaning:
        'A DSCP value survives only if every device in the path trusts or '
        'rewrites it deliberately. A switch port that does not trust DSCP '
        'rewrites it to 0 on ingress, which makes the whole downstream queue '
        'policy match nothing. Trust boundaries are the whole design.',
    causes: [
      'The access port is in mls qos disabled state (all markings become 0 '
          'for that port) or does not trust the incoming CoS/DSCP.',
      'A policy-map on the router rewrites the value in a different class '
          'intended, often at the WAN edge but not the LAN edge.',
      'The marking happens on the host or phone but the switch rewrites it '
          'on ingress before any trust is set.',
      'The tunnel or overlay copies the inner header and the outer header '
          'carries a different DSCP (or none).',
    ],
    checks: [
      PlaybookCheck(
        'show mls qos interface <intf>',
        'trust state and default CoS per ingress port',
      ),
      PlaybookCheck(
        'show policy-map interface <intf>',
        'which class matched and how many packets each class saw',
      ),
      PlaybookCheck(
        'show mls qos maps dscp-cos',
        'the mapping in use, in case a mark survives but the CoS is remapped',
      ),
      PlaybookCheck(
        'show queuing interface <intf>',
        'per-queue counters, which prove whether the marked traffic got its '
            'queue',
      ),
    ],
    fix:
        'Place the trust boundary where the marking is authoritative (an IP '
        'phone or an access port with a trusted device), keep the marking '
        'consistent across L2 and L3, and verify per-class counters on the '
        'egress interface - not just the policy configuration.',
    rule:
        'A QoS design is a trust-boundary document. If nobody can say where '
        'marking becomes trusted, the design is not done.',
  ),
  DiagnosticPlaybook(
    id: 'microburst',
    title: 'Packet drops at 1 Gbps with no average utilisation',
    subjects: ['interface', 'switch', 'uplink', 'port'],
    signals: [
      'microburst',
      'burst drops',
      'drops at low utilization',
      'drops with low utilization',
      'output drops',
      'buffer drops',
      'queue drops',
      'no bandwidth problem',
    ],
    meaning:
        'Output drops with an idle interface are microbursts: several ports '
        'send to one egress port at the same instant, the egress queue fills '
        'for a millisecond, and the tail is dropped. Average utilisation '
        'never shows it, because averaging is exactly what hides a burst.',
    causes: [
      'Incast: many-to-one traffic (backup, replication, storage) hits one '
          'egress port for a moment.',
      'Speed mismatch: 10 Gb/s ingress into a 1 Gb/s egress with small '
          'buffers.',
      'Queue too shallow or a shaper that is stricter than the line rate.',
      'A single elephant flow plus a burst queue with no WRED or ECN.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces <intf> | include output drops|output queue',
        'the drop counter and how deep the queue runs',
      ),
      PlaybookCheck(
        'show platform qos queue stats <intf>',
        'per-queue drop counters on platforms that expose them',
      ),
      PlaybookCheck(
        'show buffers | include failures|misses',
        'whether the drops are buffer allocation failures rather than queue '
            'depth',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include rate|bits',
        'the peak, not the average, over a short interval',
      ),
    ],
    fix:
        'Put the egress at least at the aggregate of its potential ingress, '
        'or shape the sources. Deepen the queue where latency allows, enable '
        'WRED for the bulk class, and treat storage replication as its own '
        'design problem rather than a LAN accident.',
    rule:
        'Average utilisation is not capacity evidence. If the counters show '
        'drops, the link is full at some instant.',
  ),
  // --- Voice ---------------------------------------------------------------
  DiagnosticPlaybook(
    id: 'voice-registration',
    title: 'Phones do not register or have no dial tone',
    subjects: [
      'voice',
      'phone',
      'phones',
      'cucm',
      'call manager',
      'sip',
      'sccp',
    ],
    signals: [
      'no dial tone',
      'phones cannot call out',
      'phones cant call out',
      'cannot make calls',
      'cannot dial out',
      'no dialtone',
      'cannot register',
      'not registering',
      'registration failed',
      'phones are down',
      'calls fail',
      'calls failing',
      'rejecting calls',
      'rejects calls',
      'fast busy',
      'no ringback',
      'cannot make calls',
    ],
    meaning:
        'A phone with no dial tone has no call-control relationship at all: '
        'it has not registered to the call manager, so there is nothing to '
        'dial through. That is a network or a credential problem, never a '
        'dial-plan problem. Registration needs DHCP for the phone, a route '
        'to the call manager, TCP 2000 (SCCP) or TCP/TLS 5060/5061 (SIP), '
        'and a valid TFTP configuration file.',
    causes: [
      'The phone is in the data VLAN instead of the voice VLAN (no LLDP or '
          'CDP voice VLAN, or a native VLAN mistake), so it gets the wrong '
          'DHCP scope and never reaches the call manager.',
      'Option 150 (TFTP) missing or pointing at the wrong address, so the '
          'phone cannot fetch its configuration file.',
      'A firewall or ACL blocking the signalling port or the media range, '
          'often added by the same change that fixed something else.',
      'Expired or revoked certificate, or a wrong cluster security mode, '
          'after a call-manager upgrade.',
      'Call manager itself is out of licences or the device pool is full.',
    ],
    checks: [
      PlaybookCheck(
        'show power inline <intf>',
        'whether the phone has power at all, before anything about voice',
      ),
      PlaybookCheck(
        'show lldp neighbors detail | include Voice',
        'the voice VLAN actually advertised to the phone',
      ),
      PlaybookCheck(
        'show ip dhcp binding <phone-ip>',
        'which scope the phone landed in and the option 150 it received',
      ),
      PlaybookCheck(
        'show call active voice brief',
        'on the gateway, whether calls reach it and why they fail',
      ),
      PlaybookCheck(
        'debug ccsip messages',
        'the SIP response code, which is the registration verdict (briefly, '
            'and only for one phone)',
      ),
    ],
    fix:
        'Fix the phone into the right VLAN with the right DHCP options, then '
        'the path to the call manager, then the signalling policy. Confirm '
        'registration on the call manager, then test one call end to end.',
    rule:
        'A dial-tone fault is a registration fault. Do not touch the dial '
        'plan until the phone shows registered.',
  ),
  DiagnosticPlaybook(
    id: 'voice-one-way',
    title: 'One-way or no audio on a call',
    subjects: ['voice', 'rtp', 'sip', 'phone', 'media'],
    signals: [
      'one way audio',
      'one-way audio',
      'no audio',
      'cannot hear',
      'hear them but they cannot hear me',
      'audio cuts out',
      'silent call',
    ],
    meaning:
        'Signalling worked and both ends think the call is up, so the fault '
        'is in the media path. RTP is unidirectional per leg: one address '
        'pair per direction, usually UDP 16384-32767. One-way audio means one '
        'direction reaches its destination and the other does not - an '
        'asymmetric route, a NAT that only forwards one way, or a firewall '
        'that inspects the signalling and never opened the media for the '
        'return.',
    causes: [
      'Asymmetric routing, so the return media arrives from a different '
          'address than the firewall or NAT expects.',
      'NAT without a media proxy (no ALG or no ICE), so the SDP advertises a '
          'private address the far end cannot reach.',
      'The firewall permits signalling but not the media UDP range.',
      'A codec mismatch negotiated one way, leaving RTP counters rising on '
          'one side and flat on the other.',
      'A QoS or policing policy dropping the media class on one path while '
          'the signalling class passes.',
    ],
    checks: [
      PlaybookCheck(
        'show call active voice brief | include rx|tx',
        'whether RTP packets are received and sent in both directions',
      ),
      PlaybookCheck(
        'show ip route <far-end-media-address>',
        'whether the return path uses the interface the media arrived on',
      ),
      PlaybookCheck(
        'show policy-map interface <wan> | include voice|class',
        'whether the media class is dropping packets on the egress',
      ),
      PlaybookCheck(
        'show sip-ua calls | include m-line|media',
        'the SDP addresses actually negotiated',
      ),
    ],
    fix:
        'Make the media path symmetric: pin the return route, add the media '
        'range to the firewall, and let the ALG or the SBC rewrite the SDP. '
        'Then prove it with the RTP counters from both ends at once.',
    rule:
        'One-way audio is a routing or NAT question wearing a voice mask. '
        'Trace the return path first; the dial plan is not involved.',
  ),

  // --- Internet edge ------------------------------------------------------
  DiagnosticPlaybook(
    id: 'internet-fails-lan-works',
    title: 'Internal traffic works but the internet does not',
    subjects: [],
    signals: [
      'internet does not work',
      'internet fails',
      'no internet',
      'cannot reach the internet',
      'lan works',
      'internal works',
      'local works but internet',
      'internet is down',
      'website not loading',
    ],
    excludes: ['vpn', 'tunnel', 'mpls', 'sd-wan'],
    meaning:
        'The LAN and the default route are the two halves of this test. If '
        'two internal hosts reach each other and nothing leaves the site, the '
        'fault is at the edge or beyond: the default route, NAT, the ISP '
        'circuit, or DNS. Each fails differently, and the traceroute says '
        'which one you are in.',
    causes: [
      'The default route points at the wrong next hop, or a summary route '
          'blackholes it.',
      'NAT is not translating the inside subnet that this host is in (a new '
          'VLAN added without a NAT statement).',
      'The ISP circuit is down or the BGP session to the provider dropped, '
          'so the edge has no default route.',
      'DNS is failing while routing is fine: ping 1.1.1.1 works, ping a '
          'name does not.',
      'A firewall policy allows the LAN but not the subnet that the host is '
          'actually in.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route 0.0.0.0',
        'whether a default route exists and where it points',
      ),
      PlaybookCheck(
        'show ip nat translations | include <inside-ip>',
        'whether the host is translated at all',
      ),
      PlaybookCheck(
        'ping 1.1.1.1 source <inside-ip>',
        'routing and NAT without DNS in the way',
      ),
      PlaybookCheck(
        'traceroute 1.1.1.1 source <inside-ip>',
        'where the packet stops: edge, provider, or beyond',
      ),
      PlaybookCheck(
        'show ip bgp summary',
        'whether the provider session is up if this is a BGP edge',
      ),
    ],
    fix:
        'Follow the traceroute hop by hop: inside the edge means routing or '
        'NAT, on the edge means the circuit or the session, beyond the edge '
        'means the provider or a policy at the far side. Fix that one layer.',
    rule:
        'Split the fault with two pings - one by IP, one by name - before '
        'any change. It tells you whether you are debugging routing or DNS.',
  ),

  // --- Physical -----------------------------------------------------------
  DiagnosticPlaybook(
    id: 'amber-link',
    title: 'Link light is amber or off',
    subjects: ['link', 'interface', 'port', 'light', 'led', 'sfp'],
    signals: [
      'amber',
      'amber light',
      'orange light',
      'no link light',
      'link light is off',
      'link led',
      'no light',
      'link down',
    ],
    meaning:
        'A copper port LED is a tiny state machine, not a diagnostic: green '
        'means link negotiated, amber on many platforms means link up but '
        'speed, duplex or PoE is wrong, and dark means no link at all. An SFP '
        'port with a dark LED is usually an unsupported optic, a speed '
        'mismatch, or a disabled port.',
    causes: [
      'Speed or duplex mismatch: one side hard-set, the other auto, which '
          'gives link up with errors and often the amber state.',
      'PoE budget exceeded, so the port powers the PD briefly and then '
          'cycles (the LED flickers, the device reboots).',
      'Wrong optic: a 1G SFP in a 10G-only port, or a DAC that the platform '
          'does not recognise (show interface transceiver).',
      'Cabling: damaged pair, wrong pinout, or a crossover where auto-MDIX '
          'is off.',
      'The port is administratively shut, or err-disabled, in which case the '
          'LED and the status disagree.',
    ],
    checks: [
      PlaybookCheck(
        'show interfaces status',
        'connected/notconnect, the negotiated speed and duplex',
      ),
      PlaybookCheck(
        'show interface <intf> | include duplex|speed|error|late',
        'late collisions and FCS errors, which prove a duplex or cable fault',
      ),
      PlaybookCheck(
        'show interfaces transceiver detail',
        'whether an optic is present, recognised and within power budget',
      ),
      PlaybookCheck(
        'show power inline <intf>',
        'whether PoE is delivering power and how much of the budget is used',
      ),
    ],
    fix:
        'Match speed and duplex (auto on both ends, or hard-set on both), '
        'replace the optic or cable that the counters implicate, and free PoE '
        'budget before adding another powered device.',
    rule:
        'Never hard-set one side of a copper link and leave the other on '
        'auto. That is the most common self-inflicted amber port.',
  ),

  // --- Wireless -----------------------------------------------------------
  DiagnosticPlaybook(
    id: 'wifi-no-ip',
    title: 'Wi-Fi client associates but gets no address',
    subjects: ['wifi', 'wireless', 'wlan', 'client'],
    signals: [
      'associates but no ip',
      'connects but no internet',
      'no ip address',
      'cannot get an ip',
      'ip address failed',
      'dhcp fails on wifi',
      'wifi connected no internet',
    ],
    meaning:
        'Association is the 802.11 layer, and it succeeding proves the RF '
        'link, the SSID and the security handshake. Getting an address is the '
        'next layer: the WLAN must map to a VLAN or a tunnel that reaches a '
        'DHCP server. Failures here are almost always the VLAN or the '
        'tunnel, not the radio.',
    causes: [
      'The WLAN maps to a VLAN that does not exist on the controller path, '
          'or is not allowed on the trunk to the access point.',
      'The DHCP scope is exhausted, so association works and DHCP offers '
          'nothing.',
      'The AP is in local mode with a broken CAPWAP data tunnel, so control '
          'is up and client data is not.',
      'Client DHCP timeout from a slow 802.1X post-authentication VLAN '
          'change.',
      'A guest anchor or a firewall between the WLAN and the DHCP server '
          'dropping broadcasts.',
    ],
    checks: [
      PlaybookCheck(
        'show wireless client summary',
        'whether the client is associated and in which VLAN it was placed',
      ),
      PlaybookCheck(
        'show wlan <id>',
        'the interface or VLAN the WLAN is bound to',
      ),
      PlaybookCheck(
        'show interfaces trunk | include <vlan>',
        'whether that VLAN actually reaches the AP',
      ),
      PlaybookCheck(
        'show ip dhcp pool',
        'exhaustion: leases used against the total',
      ),
    ],
    fix:
        'Fix the mapping from SSID to VLAN to DHCP, and verify it with a '
        'wired host on the same VLAN. If the wired host also fails, the fault '
        'was never wireless.',
    rule:
        'Association proves the RF. Address assignment proves the path. Test '
        'the same VLAN from a wire before blaming the AP.',
  ),
  DiagnosticPlaybook(
    id: 'ap-capwap-join',
    title: 'Access point will not join the controller',
    subjects: ['ap', 'access point', 'wlc', 'capwap', 'controller'],
    signals: [
      'ap not joining',
      'ap will not join',
      'ap not registered',
      'capwap',
      'ap down',
      'ap stuck',
      'ap is not joining',
      'not joining the controller',
      'cannot join',
    ],
    meaning:
        'An AP that never joins has not found the controller, or has found it '
        'and been rejected. Discovery needs an address (DHCP), a route to the '
        'controller, and CAPWAP UDP 5246/5247 open both ways. Rejection after '
        'discovery is a certificate, licence, model or firmware question.',
    causes: [
      'The AP is on a network where DHCP option 43 is missing and DNS does '
          'not resolve the controller name.',
      'CAPWAP is blocked by an ACL, a firewall or a provider between the AP '
          'and the controller (the UDP ports, not just IP reachability).',
      'Certificate or image mismatch: the AP has an old image or a '
          'manufacturing certificate the controller no longer trusts.',
      'The AP is in a different country regulatory domain than the '
          'controller allows, so it is refused.',
      'Licence exhaustion on the controller.',
    ],
    checks: [
      PlaybookCheck(
        'show ap summary',
        'whether the AP is known, its state, and its IP',
      ),
      PlaybookCheck(
        'debug capwap packet',
        'discovery requests and the response code if the AP is being '
            'rejected (briefly, one AP)',
      ),
      PlaybookCheck(
        'show ap config general <ap>',
        'the image and certificate the AP is actually running',
      ),
      PlaybookCheck('show license summary', 'whether there is a seat left'),
    ],
    fix:
        'Fix discovery first (option 43 or DNS), then the CAPWAP path, then '
        'the certificate or image. Change one of those at a time - each one '
        'produces the same symptom.',
    rule:
        'An AP that never joins is a discovery problem until the debug says '
        'it was rejected. Do not reload the controller to find out.',
  ),

  // --- Cloud and containers ----------------------------------------------
  DiagnosticPlaybook(
    id: 'cloud-egress-blocked',
    title: 'Cloud instance cannot reach the internet outbound',
    subjects: [
      'ec2',
      'instance',
      'security group',
      'cloud',
      'aws',
      'azure',
      'gcp',
    ],
    signals: [
      'no outbound',
      'cannot reach out',
      'egress rule',
      'nat gateway',
      'cannot download',
      'no internet from instance',
    ],
    meaning:
        'Cloud paths are stateful policy on two layers: the security group or '
        'NSG at the interface, and the subnet route table for egress. An '
        'instance with a private address needs a NAT gateway (or an instance '
        'NAT) in the route table; one with a public address needs an internet '
        'gateway route. A missing egress rule in the group is the other half, '
        'and it is silent.',
    causes: [
      'The subnet route table has no 0.0.0.0/0 route, or it points at the '
          'wrong NAT gateway or a blackhole.',
      'The security group or NSG has no outbound rule for the protocol and '
          'port, or the outbound rule targets the wrong prefix.',
      'The instance has no public address and no NAT gateway, so it can talk '
          'inside the VPC only.',
      'A network ACL denies the return traffic (stateless, unlike the '
          'security group).',
      'Private DNS or a proxy is required by policy and the instance is not '
          'pointed at it.',
    ],
    checks: [
      PlaybookCheck(
        'describe-route-tables --filters Name=association.subnet-id,'
            'Values=<subnet>',
        'the route actually used by that subnet',
      ),
      PlaybookCheck(
        'describe-security-groups --group-ids <sg>',
        'whether an egress rule covers the flow at all',
      ),
      PlaybookCheck(
        'describe-network-acls',
        'the stateless layer that the security group check misses',
      ),
      PlaybookCheck(
        'traceroute from inside the instance',
        'whether egress dies at the gateway or beyond',
      ),
    ],
    fix:
        'Give the subnet a route to a NAT gateway (or an internet gateway for '
        'public instances), add the egress rule, and open the matching '
        'inbound rule on the destination. Verify from inside the instance, '
        'not from the console.',
    rule:
        'In cloud, "no route" and "no egress rule" produce the same timeout. '
        'Check both layers before you rebuild the instance.',
  ),
  DiagnosticPlaybook(
    id: 'cloud-route-blackhole',
    title: 'Cloud route points at a blackhole or the wrong target',
    subjects: ['route table', 'vpc', 'subnet', 'cloud', 'aws', 'azure', 'gcp'],
    signals: [
      'blackhole',
      'route table wrong',
      'wrong route',
      'traffic goes nowhere',
      'cannot reach on prem',
      'vpn route missing',
      'transit gateway',
    ],
    meaning:
        'A cloud route table is longest-prefix match over targets, and the '
        'target is a gateway object, not an interface. A prefix that matches '
        'but whose target is detached shows as blackhole and every packet is '
        'dropped with no ICMP. Overlapping VPC or on-prem prefixes are the '
        'other trap: the more specific local route wins over the VPN route, '
        'so traffic never enters the tunnel.',
    causes: [
      'The VPN or transit gateway attachment is down, so its route is '
          'blackholed while the prefix stays in the table.',
      'The VPC local route (the VPC CIDR itself) is more specific than the '
          'on-prem route, so the traffic never uses the tunnel.',
      'Two attachments advertise the same prefix and the propagation picks '
          'the wrong one.',
      'The subnet has its own route table that overrides the VPC main table, '
          'and nobody updated it.',
    ],
    checks: [
      PlaybookCheck(
        'describe-route-tables --filters Name=vpc-id,Values=<vpc>',
        'every table, its associations and the state of each target',
      ),
      PlaybookCheck(
        'describe-vpn-connections',
        'whether the tunnel is up and which routes it advertised',
      ),
      PlaybookCheck(
        'describe-transit-gateway-route-tables',
        'the chosen path and its state for the prefix in question',
      ),
      PlaybookCheck(
        'describe-subnets --filters Name=vpc-id,Values=<vpc>',
        'which subnets use a non-default table',
      ),
    ],
    fix:
        'Repair the attachment or the target first (the route follows the '
        'attachment), then resolve prefix overlap by summarising on-prem '
        'space so the local VPC route never shadows it.',
    rule:
        'A blackhole route is a detached attachment, not a typo. Fix the '
        'tunnel and the route heals itself.',
  ),
  DiagnosticPlaybook(
    id: 'cloud-vpn-down',
    title: 'Site-to-site VPN to the cloud is down',
    subjects: ['vpn', 'ipsec', 'tunnel', 'cloud', 'aws', 'azure'],
    signals: [
      'vpn down',
      'tunnel down',
      'site to site vpn',
      'ipsec down',
      'tunnel is down',
      'vpn not connecting',
      'phase 2 down',
    ],
    excludes: [
      'dmvpn',
      'nhrp',
      'client vpn',
      'sdwan',
      'sd-wan',
      'mpls',
      'vxlan',
    ],
    meaning:
        'A cloud VPN has two tunnels by design, each with IKE (phase 1) and '
        'IPsec (phase 2). The provider console tells you which tunnel and '
        'which phase is down, and that is the only place to start: phase 1 '
        'down is proposal, authentication or reachability; phase 2 down with '
        'phase 1 up is the traffic selector or the proxy IDs.',
    causes: [
      'Phase 1 proposal mismatch (encryption, hash, DH group) or the wrong '
          'pre-shared key.',
      'Phase 2 traffic selectors do not match: the cloud side expects the '
          'exact local and remote prefixes, and a summary or a 0.0.0.0/0 '
          'selector is rejected.',
      'The public IP of the customer gateway changed and the tunnel still '
          'points at the old one.',
      'A NAT device in front of the customer gateway, so IKE arrives with a '
          'different source than expected (NAT-T is required).',
      'One of the two tunnels is down and the routing still prefers it.',
    ],
    checks: [
      PlaybookCheck(
        'show crypto ikev2 sa',
        'phase 1 state, the proposal chosen and the peer identity',
      ),
      PlaybookCheck(
        'show crypto ipsec sa',
        'phase 2 selectors, the SAs and whether packets are being encrypted '
            'and decrypted',
      ),
      PlaybookCheck(
        'show crypto isakmp policy',
        'the proposals the local side offers',
      ),
      PlaybookCheck(
        'cloud console tunnel status',
        'which of the two tunnels is up and the last error',
      ),
    ],
    fix:
        'Match the proposal and the PSK first, then the traffic selectors '
        'exactly. Keep both tunnels configured and let the routing prefer the '
        'live one, so a single provider tunnel failure is not an outage.',
    rule:
        'Never run a cloud VPN with one tunnel. The second tunnel is the '
        'design, not a spare part.',
  ),
  DiagnosticPlaybook(
    id: 'k8s-service-unreachable',
    title: 'Kubernetes service is unreachable from pods',
    subjects: ['kubernetes', 'k8s', 'pod', 'service', 'cni', 'cluster'],
    signals: [
      'service unreachable',
      'cannot reach service',
      'cluster ip',
      'pod cannot reach',
      'cni',
      'kube proxy',
      'service not working',
      'connection refused to service',
    ],
    meaning:
        'A ClusterIP service is a virtual address programmed into every '
        'node: kube-proxy (iptables or IPVS) or an eBPF datapath rewrites it '
        'to a pod endpoint. A failure is one of four layers: no ready '
        'endpoint, a network policy drop, a CNI routing problem between '
        'nodes, or the service port and the container port disagreeing.',
    causes: [
      'No ready endpoints: the pod is failing its readiness probe, so the '
          'service has nothing to forward to.',
      'A NetworkPolicy selects the pod and denies ingress from the client '
          'namespace.',
      'The CNI overlay is broken between two nodes (VXLAN or IPIP tunnel '
          'down), so same-node works and cross-node fails.',
      'The service targetPort does not match the container port, or the pod '
          'listens on 127.0.0.1 only.',
      'kube-proxy is not running on the node, or the node was added before '
          'the CNI was ready.',
    ],
    checks: [
      PlaybookCheck(
        'kubectl get endpointslices -n <ns>',
        'whether the service has ready addresses at all',
      ),
      PlaybookCheck(
        'kubectl get networkpolicy -n <ns> -o yaml',
        'which policies select the pod and what they allow',
      ),
      PlaybookCheck(
        'kubectl exec <pod> -- curl -sv <service>:<port>',
        'the layer the failure happens at: DNS, connect, or reset',
      ),
      PlaybookCheck(
        'kubectl get pods -n kube-system -o wide',
        'whether the CNI and kube-proxy pods are running on the node',
      ),
    ],
    fix:
        'Make the endpoint ready, then the policy, then the datapath. Test '
        'from a pod on the same node and a different node: that one '
        'comparison tells you whether it is policy or CNI.',
    rule:
        'If it works on one node and not another, it is the CNI. If it fails '
        'everywhere, it is the endpoint or the policy.',
  ),
  DiagnosticPlaybook(
    id: 'k8s-dns-failing',
    title: 'DNS resolution fails inside the cluster',
    subjects: ['kubernetes', 'k8s', 'dns', 'coredns', 'cluster'],
    signals: [
      'dns fails in cluster',
      'coredns',
      'cluster dns',
      'cannot resolve service',
      'nxdomain',
      'dns timeout in pod',
      'name resolution in pod',
    ],
    meaning:
        'Cluster DNS is CoreDNS behind a service address, and pods reach it '
        'through the node-local DNS cache or directly. Failures split cleanly: '
        'NXDOMAIN means the name or the search path is wrong; a timeout means '
        'the packet never reached CoreDNS, which is a CNI, policy or '
        'conntrack problem.',
    causes: [
      'The pod resolv.conf search path is wrong, so short names do not '
          'expand to <svc>.<ns>.svc.cluster.local.',
      'A NetworkPolicy blocks UDP/TCP 53 to the DNS namespace.',
      'CoreDNS pods are not running, or they cannot reach the API server to '
          'watch Services and Endpoints.',
      'A conntrack table full condition on a node, which drops new DNS flows '
          'first.',
      'ndots set so high that every lookup tries the search list before the '
          'absolute name, adding latency and timeouts.',
    ],
    checks: [
      PlaybookCheck(
        'kubectl exec <pod> -- cat /etc/resolv.conf',
        'the nameserver and the search list actually in use',
      ),
      PlaybookCheck(
        'kubectl get pods -n kube-system -l k8s-app=kube-dns',
        'whether CoreDNS is up and on which nodes',
      ),
      PlaybookCheck(
        'kubectl logs -n kube-system <coredns-pod>',
        'errors talking to the API server, or forwarding failures upstream',
      ),
      PlaybookCheck(
        'cat /proc/sys/net/netfilter/nf_conntrack_count',
        'on the node, whether the table is at its limit',
      ),
    ],
    fix:
        'Fix the search path first (it is the cheapest), then the policy, '
        'then CoreDNS itself. Test with the fully qualified name - if that '
        'works, the search path is the fault.',
    rule:
        'NXDOMAIN and timeout are different faults. One is naming, the other '
        'is the path to the resolver.',
  ),

  // --- Operations ---------------------------------------------------------
  DiagnosticPlaybook(
    id: 'netflow-missing',
    title: 'Flow export shows nothing for a link',
    subjects: ['netflow', 'ipfix', 'flow', 'sflow', 'telemetry'],
    signals: [
      'no netflow',
      'netflow not working',
      'no flows',
      'flow export',
      'ipfix',
      'sflow',
      'collector sees nothing',
    ],
    meaning:
        'Flow export has three independent requirements: the exporter is '
        'enabled on the interface in the right direction, the collector '
        'address and port are reachable, and the templates or the cache '
        'settings mean the collector can decode what arrives. Traffic that '
        'never matches an enabled interface exports nothing, and UDP 2055 '
        'being "open" does not prove that the exporter is on.',
    causes: [
      'The flow exporter is configured globally but not applied to the '
          'interface, or applied only in one direction.',
      'The collector address is wrong, or a firewall or ACL blocks UDP 2055 '
          'from the router loopback.',
      'The router is exporting with a source address the collector cannot '
          'route back to.',
      'The cache is set to export only on expiry, and the interval is longer '
          'than the observation window.',
      'The exporter is v9/v10 and the collector has not received the '
          'template (or the template expired).',
    ],
    checks: [
      PlaybookCheck(
        'show flow exporter <name>',
        'destination, port, source interface and the export counters',
      ),
      PlaybookCheck(
        'show flow monitor <name> cache format table',
        'whether flows are being measured at all, before export',
      ),
      PlaybookCheck(
        'show interfaces <intf> | include flow',
        'whether the interface has the monitor applied and in which '
            'direction',
      ),
      PlaybookCheck(
        'show ip interface <intf> | include flow',
        'the legacy NetFlow setting, which some platforms still use',
      ),
    ],
    fix:
        'Confirm the cache first (flows measured), then the exporter '
        '(packets sent), then the collector (packets received). The counters '
        'on the exporter tell you which of the three is empty.',
    rule:
        'A missing flow is usually a missing interface statement, not a '
        'broken collector. Check the exporter counters before the collector '
        'logs.',
  ),
  DiagnosticPlaybook(
    id: 'snmp-timeout',
    title: 'SNMP polling times out or returns nothing',
    subjects: ['snmp', 'polling', 'monitoring', 'mib'],
    signals: [
      'snmp timeout',
      'snmp not working',
      'snmp times out',
      'polling fails',
      'cannot poll',
      'no snmp response',
      'snmpv3',
    ],
    meaning:
        'SNMP is UDP 161 and has no session: a timeout means the request or '
        'the reply was dropped, or the credentials did not match. It is the '
        'quietest failure in the network, because the device has no reason to '
        'log it. v3 adds authentication and privacy, which turn a timeout '
        'into a wrong-user or wrong-engine-ID problem.',
    causes: [
      'An ACL blocks the poller address, or the poller is behind a NAT and '
          'the device answers to a different source.',
      'Community string mismatch (v2c) or wrong user/auth/priv (v3).',
      'v3 engine ID or the discovery step failing, so every request is '
          'rejected before authentication.',
      'The device CPU is at 100% and drops the low-priority SNMP queue.',
      'The MIB branch is not supported on that platform, so the device '
          'answers noSuchObject rather than a timeout.',
    ],
    checks: [
      PlaybookCheck(
        'snmpwalk -v2c -c <community> <device> sysDescr',
        'whether the transport and the community work at all',
      ),
      PlaybookCheck(
        'snmpwalk -v3 -l authPriv -u <user> -a SHA -x AES <device> '
            'sysDescr',
        'the v3 credential path end to end',
      ),
      PlaybookCheck('show snmp', 'whether SNMP is enabled and the engine ID'),
      PlaybookCheck(
        'show access-lists | include 161',
        'whether an ACL is answering silently on the device side',
      ),
    ],
    fix:
        'Get one OID working with snmpwalk before touching the monitoring '
        'system. Then align the ACL, the source address and the credential, '
        'in that order.',
    rule:
        'A monitoring gap is an outage you find out about late. Fix the '
        'polling path before the next change window, not after.',
  ),
  DiagnosticPlaybook(
    id: 'syslog-missing',
    title: 'Device logs never arrive at the collector',
    subjects: ['syslog', 'logging', 'collector', 'siem'],
    signals: [
      'no syslog',
      'logs not arriving',
      'syslog missing',
      'no logs',
      'logging not working',
      'collector empty',
    ],
    meaning:
        'Syslog is UDP 514 (or TCP/TLS) and fire-and-forget: a device can log '
        'locally and never deliver, with nothing on the console. The three '
        'things that break are the source address (the device sends from the '
        'interface nearest the collector, which may be the wrong one), the '
        'severity threshold, and the path.',
    causes: [
      'logging host configured but the source interface is not pinned, so '
          'the packets leave an interface the collector cannot reach.',
      'Severity set to a level that excludes what you are looking for '
          '(logging trap warnings drops informational messages).',
      'An ACL or firewall blocks UDP 514 in the outbound direction (rarely '
          'tested, often assumed).',
      'The collector is configured for TLS and the device still sends plain '
          'UDP, or the certificate expired.',
    ],
    checks: [
      PlaybookCheck(
        'show logging',
        'the destination, the trap severity and the source interface in use',
      ),
      PlaybookCheck(
        'show logging | include host',
        'the collector address actually configured',
      ),
      PlaybookCheck(
        'show ip interface brief | include <source-intf>',
        'whether the pinned source is up and routable to the collector',
      ),
      PlaybookCheck(
        'tcpdump on the collector, port 514',
        'whether packets arrive at all, which separates the device from the '
            'path',
      ),
    ],
    fix:
        'Pin the source interface to the loopback, set the trap level '
        'deliberately, and confirm one message end to end on the collector. '
        'Then alert on the absence of logs, so the next outage tells you.',
    rule:
        'Logging is not monitoring until the collector proves the message '
        'arrived. A device with logging configured and nothing delivered is '
        'still blind.',
  ),
  DiagnosticPlaybook(
    id: 'config-drift',
    title: 'Device configuration has drifted from the baseline',
    subjects: ['config', 'configuration', 'baseline', 'drift'],
    signals: [
      'config drift',
      'configuration drift',
      'config changed',
      'who changed the config',
      'diff config',
      'unexpected change',
      'running config differs',
    ],
    meaning:
        'Drift is the normal state of a network without a control loop: '
        'someone fixed an incident at 2 a.m. and did not commit it. The '
        'senior response is not to revert blindly - the change may be the '
        'only thing keeping a service up - but to diff, attribute, and '
        'decide whether the old baseline is still right.',
    causes: [
      'An emergency change applied by hand and never added to the template.',
      'A template rollout that failed halfway, leaving some devices on the '
          'old configuration.',
      'A device replaced from spare parts, restored from an old backup.',
      'Automation running from a different source of truth than the one the '
          'team is reading.',
    ],
    checks: [
      PlaybookCheck(
        'show archive config differences',
        'the exact lines that differ from the last archived copy',
      ),
      PlaybookCheck(
        'show configuration commit list',
        'the commit history with author and time (Junos)',
      ),
      PlaybookCheck(
        'show logging | include CONFIG_I',
        'who logged in and when, from the device side',
      ),
      PlaybookCheck(
        'show running-config | include ntp|logging|snmp|aaa',
        'the usual suspects: the small lines that drift first',
      ),
    ],
    fix:
        'Diff against the baseline, decide line by line whether the device '
        'or the baseline is right, then fix the source of truth and redeploy. '
        'Add the mounted diff to the change record.',
    rule:
        'Never revert drift you cannot explain. The unexplained line is '
        'sometimes the mitigation.',
  ),
  DiagnosticPlaybook(
    id: 'ap-reboot',
    title: 'Access points reboot or drop off the controller repeatedly',
    subjects: ['ap', 'access point', 'wlc', 'capwap', 'controller'],
    signals: [
      'ap keeps rebooting',
      'aps keep rebooting',
      'ap restarts',
      'ap rebooting',
      'ap keeps restarting',
      'access points keep rebooting',
      'ap goes offline',
      'ap disappears',
      'shows the ap as down',
      'ap shows down',
      'ap is down',
    ],
    meaning:
        'An AP that reboots on its own is almost never the AP software: it is '
        'losing power (PoE budget or a flaky injector), losing its CAPWAP '
        'control connection and watchdogging, or reloading on a crash. The '
        'uptime counter and the power draw separate those three in one look.',
    causes: [
      'PoE budget exceeded: the port powers the AP, the AP draws more than '
          'the class allows, the PSE cuts power and cycles it.',
      'The CAPWAP control path drops (ACL, MTU, DTLS) and the AP watchdog '
          'reloads after it cannot rejoin.',
      'An image or certificate mismatch during upgrade, so the AP reloads '
          'into a loop.',
      'A flaky cable or injector causing link flaps that the AP interprets '
          'as a power event.',
      'Controller-driven reboot loop from a bad AP group or regulatory '
          'domain setting.',
    ],
    checks: [
      PlaybookCheck(
        'show ap uptime',
        'whether the AP really rebooted and how long it has been up',
      ),
      PlaybookCheck(
        'show power inline <intf>',
        'the wattage delivered against the class the AP negotiated',
      ),
      PlaybookCheck(
        'show log | include AP|CAPWAP|reload',
        'the reboot reason and the event just before it',
      ),
      PlaybookCheck(
        'show interface <intf> | include flaps|reset',
        'whether the physical link is cycling under the AP',
      ),
    ],
    fix:
        'Fix power first (budget, injector, cable), then the CAPWAP path, then '
        'the image. A reboot loop that survives all three is a hardware RMA, '
        'not a config problem.',
    rule:
        'Check the power draw before you open a TAC case: a rebooting AP is a '
        'power symptom more often than a software one.',
  ),
  DiagnosticPlaybook(
    id: 'default-route',
    title: 'Default route is missing or not being used',
    subjects: [],
    signals: [
      'default route not working',
      'no default route',
      'default route missing',
      'default gateway not working',
      'gateway of last resort',
      'cannot reach the internet by default',
      'default route not advertised',
    ],
    excludes: ['vpn', 'tunnel', 'mpls'],
    meaning:
        'A default route fails in four distinct ways: it does not exist, it '
        'exists but is not installed (a more specific route or an '
        'administrative-distance loser), it is installed but points at a dead '
        'next hop, or it exists only in one direction and the return traffic '
        'has no route. The routing table and the FIB answer the first three; '
        'traceroute answers the fourth.',
    causes: [
      'No static route and no dynamic default: nothing originates 0.0.0.0/0.',
      'A floating static with a better administrative distance is present but '
          'its interface is down, so the backup never takes over.',
      'The default is learned from a protocol but filtered by a distribute '
          'list or a route map.',
      'The default exists on the edge but is not redistributed or advertised '
          'to the inside.',
      'Next hop unreachable: the route is in the table, but the ARP for the '
          'gateway fails and everything is dropped.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route 0.0.0.0',
        'whether the route exists and which protocol installed it',
      ),
      PlaybookCheck(
        'show ip cef 0.0.0.0',
        'whether it reached the forwarding table with a valid adjacency',
      ),
      PlaybookCheck(
        'show ip route <next-hop>',
        'whether the next hop itself is reachable',
      ),
      PlaybookCheck(
        'show ip protocols',
        'whether a distribute list or an offset list is filtering it',
      ),
      PlaybookCheck(
        'traceroute 1.1.1.1',
        'the first hop that dies, which tells you which side is missing the '
            'route',
      ),
    ],
    fix:
        'Make the route exist, make it win, make the next hop reachable, then '
        'make it propagate inside. For a floating static, verify the tracked '
        'object is up - a track that never fails is a backup that never '
        'works.',
    rule:
        'A default route is a policy, not a fallback: decide who originates '
        'it, who filters it, and how the return path exists.',
  ),
  DiagnosticPlaybook(
    id: 'ospf-one-way-adjacency',
    title: 'OSPF adjacency forms on one link but not the other',
    subjects: ['ospf', 'adjacency', 'neighbor', 'neighbour'],
    signals: [
      'forms on one link but not the other',
      'comes up on one link but not the other',
      'adjacency on one link only',
      'neighbor on one link only',
      'one link forms an adjacency',
      'one side forms an adjacency',
      'ospf up on one link',
      'ospf down on one link',
      'one ospf neighbor is missing',
      'neighbor forms on one side',
      'comes up on one side only',
      'neighbour comes up on one side',
      'comes up on one side but not the other',
      'neighbours come up on one side',
      'neighbors come up on one side',
      'neighbours form on one side',
    ],
    excludes: ['stuck in exstart', 'stuck in init'],
    meaning:
        'Two links to the same neighbor are not the same path, and an '
        'adjacency that forms on one and not the other proves the fault is in '
        'the per-link configuration or the per-link path, not in the OSPF '
        'process. Hellos are getting through on at least one side, so the '
        'protocol itself works.',
    causes: [
      'An MTU mismatch on the failing link. The adjacency reaches EXSTART and '
          'stops because the DBD exchange never agrees; the link that works '
          'carries the same MTU as its peer.',
      'A hello/dead interval or area ID mismatch on that interface only - '
          'often because a template or a per-interface command set it there '
          'and nowhere else.',
      'The interface is passive, in the wrong VRF, or has no network/interface '
          'statement covering it, so OSPF never sends a hello on that link.',
      'A layer 2 problem specific to that link: wrong VLAN on the trunk, '
          'native VLAN mismatch, or a firewall/ACL filtering OSPF (protocol 89) '
          'or multicast 224.0.0.5/6.',
      'Duplicate router IDs or an authentication mismatch, where one link has '
          'the key and the other does not.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf neighbor',
        'which neighbor is FULL on which interface, and which is missing',
      ),
      PlaybookCheck(
        'show ip ospf interface <working> and <failing>',
        'area, network type, hello/dead, MTU, passive state and cost side by '
            'side; the difference is the answer',
      ),
      PlaybookCheck(
        'show ip ospf interface <failing> | include MTU|Hello|Dead|Area',
        'the four values that stop an adjacency, in one screen',
      ),
      PlaybookCheck(
        'show ip ospf neighbor on the far end of the failing link',
        'whether the reverse adjacency is FULL - one-way hellos look like a '
            'missing neighbor, not a broken link',
      ),
      PlaybookCheck(
        'debug ip ospf hello (briefly, with a filter)',
        'whether this router sends a hello on that link at all',
      ),
    ],
    fix:
        'Match MTU, area, timers and authentication on both ends of the failing '
        'link, and make sure the interface is not passive. If the MTU cannot be '
        'matched (a provider handoff), ip ospf mtu-ignore gets the adjacency up '
        'but hides a real fragmentation problem - fix the MTU instead.',
    rule:
        'When one of two parallel links fails, compare the two interfaces line '
        'by line before touching the protocol. OSPF is not choosing to work on '
        'one link; the links are not the same.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show ospf neighbor; show ospf interface detail',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'suboptimal-path',
    title: 'Traffic takes the backup link',
    subjects: ['traffic', 'backup', 'path', 'link', 'route'],
    signals: [
      'taking the backup link',
      'takes the backup link',
      'using the backup link',
      'traffic is on the backup',
      'traffic goes over the backup',
      'prefers the backup',
      'not using the primary link',
      'not using the preferred path',
      'using the secondary link',
      'taking the long way',
      'asymmetric',
    ],
    excludes: ['stuck in', 'flapping', 'down'],
    meaning:
        'Both links are up, so this is not a failure - it is a ranking. Some '
        'protocol compared two candidates and preferred the one you did not '
        'want, and until you find which protocol made that decision, changing '
        'anything is guessing.',
    causes: [
      'For a dynamic route: metric, cost, local preference, AS-path length, '
          'MED or administrative distance favours the backup. An OSPF cost '
          'above default reference bandwidth is the classic: every link at '
          '100 Mbps or faster costs 1, so the tie is broken by whatever was '
          'installed first.',
      'Two equal-cost paths exist and the hash, not a metric, is choosing - '
          'ECMP per-flow means half the traffic legitimately takes the backup.',
      'For layer 2: spanning-tree root path cost or an unintended root bridge '
          'puts the fast link in a blocking state.',
      'Route recursion or a floating static that is no longer floating, because '
          'the tracked object never fails.',
      'Policy: route maps, local preference from a BGP community, or PBR that '
          'matches more traffic than intended.',
    ],
    checks: [
      PlaybookCheck(
        'show ip route <prefix> (and the same on the return path)',
        'the chosen next hop, its metric and its administrative distance - the '
            'answer is in the bracket',
      ),
      PlaybookCheck(
        'show ip ospf interface brief / show ip eigrp topology <prefix>',
        'the per-link cost or feasible distance the router actually computed',
      ),
      PlaybookCheck(
        'show ip cef <prefix> internal',
        'whether the forwarding table agrees with the routing table, and how '
            'many next hops are installed',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <id>',
        'for a layer 2 answer: which port is forwarding, and the root path cost '
            'of each',
      ),
      PlaybookCheck(
        'traceroute from a source inside the affected subnet',
        'the actual path; a traceroute from the router itself may show a '
            'different one',
      ),
    ],
    fix:
        'Change the input the protocol is ranking on, not the protocol: set the '
        'IGP cost or reference bandwidth consistently, add a local preference '
        'or AS-path prepend for BGP, or fix the STP root and cost. Verify the '
        'forward and return paths separately - fixing one direction is how you '
        'get asymmetric routing.',
    rule:
        'Traffic follows the winner of a comparison you did not watch. Find '
        'which process chose the path, and the fix is one number in that '
        'process.',
  ),
  DiagnosticPlaybook(
    id: 'ssh-mgmt-timeout',
    title: 'SSH to a device times out while ping works',
    subjects: ['ssh', 'vty', 'management', 'switch', 'router'],
    signals: [
      'ssh times out but ping works',
      'ssh times out but ping',
      'ssh hangs but ping works',
      'cannot ssh but can ping',
      'can ping but cannot ssh',
      'ssh fails but ping works',
      'ssh to the switch times out',
      'ssh connection times out',
      'ssh drops after login',
      'ssh works from one subnet',
    ],
    excludes: ['public key', 'ssh key'],
    meaning:
        'ICMP reaches the box and TCP 22 does not, so routing and layer 2 are '
        'fine and the break is above them: something is filtering the port, the '
        'listener is absent, or the reply path differs from the request path. '
        'Ping proves reachability, never service.',
    causes: [
      'An ACL applied to the VTY lines or an interface ACL that permits ICMP '
          'but not TCP 22, often from a management subnet that was added later.',
      'The SSH server is not enabled or has no RSA key: SSH needs a host key '
          'and, on some platforms, a domain name before it will generate one.',
      'The management VRF or a control-plane policing policy drops SSH above a '
          'rate, so interactive sessions time out while ping is untouched.',
      'An asymmetric return path through a stateful firewall, which drops the '
          'SYN-ACK because it never saw the SYN.',
      'The VTY lines are all in use, or transport input does not include ssh '
          'on that platform, or AAA is unreachable and fallback is disabled.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ssh and show crypto key mypubkey rsa',
        'whether the server is enabled and whether a host key exists at all',
      ),
      PlaybookCheck(
        'show running-config | include ^line vty|transport input|access-class',
        'which protocols the VTY accepts and which ACL guards it',
      ),
      PlaybookCheck(
        'show ip interface <intf> | include access list',
        'whether an inbound ACL could be dropping TCP 22',
      ),
      PlaybookCheck(
        'telnet <ip> 22 from the same source, or nc -vz <ip> 22',
        'open, refused or filtered - refused means no listener, filtered means '
            'a drop in the path',
      ),
      PlaybookCheck(
        'show users and show tcp brief',
        'whether all VTY lines are occupied or the SYN never arrives',
      ),
    ],
    fix:
        'Permit TCP 22 from the management subnet in the VTY access-class, '
        'enable the SSH server with a key, and exempt management traffic from '
        'control-plane policing. Keep an out-of-band path (console server) so a '
        'bad ACL cannot lock you out of the device you need to fix.',
    rule:
        'Ping tests the path, not the service. When ping works, test the port '
        'before you test the route.',
    variants: [
      PlaybookVariant(
        'Junos',
        'show system services; show configuration | match ssh',
      ),
    ],
  ),
  DiagnosticPlaybook(
    id: 'wifi-busy-hour',
    title: 'Wi-Fi is slow at busy times of day',
    subjects: ['wifi', 'wi-fi', 'wireless', 'wlan', 'wifi6', 'wifi5'],
    signals: [
      'slow in the afternoon',
      'slow in the morning',
      'slow at peak',
      'slow during busy hours',
      'slow at busy times',
      'slows down when busy',
      'slow when the office is full',
      'fine in the morning',
      'bad at lunchtime',
      'slow every afternoon',
      'slower when people are in',
      'slows down in the afternoon',
      'slows down during the day',
      'slow after lunch',
    ],
    meaning:
        'A predictable time-of-day pattern is a capacity and airtime story, not '
        'a coverage story. When more clients share the same channel, each one '
        'waits longer for its turn; the signal can be strong and the throughput '
        'still terrible.',
    causes: [
      'Airtime exhaustion: too many clients and APs on one channel, so every '
          'frame waits. Check the channel utilization per radio at the bad hour.',
      'Co-channel interference from APs on the same channel with high power, '
          'which makes clients hear each other and defer.',
      'One AP carrying an outsized share because clients cling to it (sticky '
          'clients) or because the controller is balancing badly.',
      'A saturated uplink from the AP to the switch at the same hour, which '
          'looks like Wi-Fi from the client side.',
      'A non-Wi-Fi interferer that runs on a schedule: a microwave, a wireless '
          'camera, or a neighbouring network that turns up at 2 pm.',
    ],
    checks: [
      PlaybookCheck(
        'show ap dot11 5ghz summary / the controller channel-utilization report',
        'channel utilization and client count per AP at the bad hour, not now',
      ),
      PlaybookCheck(
        'show ap auto-rf <ap> (or the RRM channel/power history)',
        'whether the RF profile moved the AP and when',
      ),
      PlaybookCheck(
        'the AP switch port counters (show interface <port>)',
        'uplink utilization and errors during the same window',
      ),
      PlaybookCheck(
        'a spectrum analysis on the worst AP',
        'non-Wi-Fi interference and the real noise floor',
      ),
      PlaybookCheck(
        'client detail for the affected users',
        'data rate, retries, and which AP and band they actually joined',
      ),
    ],
    fix:
        'Reduce cell size (lower power) and add APs rather than raising power; '
        'use 20/40 MHz on 5 GHz in dense areas instead of 80 MHz; disable low '
        'legacy rates; move the offending interferer or change channel. Fix the '
        'uplink if the port, not the air, is the ceiling.',
    rule:
        'Measure at the bad hour. A Wi-Fi problem that only exists at 2 pm '
        'cannot be diagnosed at 9 am, and a speed test from the closet is not '
        'the same test as a client in the room.',
  ),
  DiagnosticPlaybook(
    id: 'rogue-dhcp',
    title: 'Two DHCP servers are both answering',
    subjects: ['dhcp', 'lease', 'scope', 'address'],
    signals: [
      'two dhcp servers are both answering',
      'two dhcp servers',
      'both dhcp servers',
      'second dhcp server',
      'another dhcp server',
      'rogue dhcp',
      'wrong dhcp server',
      'dhcp from the wrong server',
      'clients get addresses from the wrong',
      'unknown dhcp server',
    ],
    meaning:
        'A client takes the first offer it receives, so a second server is not '
        'a redundancy win - it is a race, and half the clients lose it. The '
        'symptom is usually intermittent: some clients get an address from the '
        'wrong scope and cannot reach anything that matters.',
    causes: [
      'A router, firewall, NAS or wireless controller is still running DHCP '
          'with a default scope, often after a migration or a factory reset.',
      'Two servers with overlapping scopes on the same segment, where one was '
          'meant to be standby but is not actually disabled or excluded.',
      'A DHCP relay or helper-address pointing at the wrong server for that '
          'VLAN, so the offer comes from a scope meant for another site.',
      'A rogue device (a consumer router plugged into the wall) serving its own '
          '192.168.x.0/24 scope.',
    ],
    checks: [
      PlaybookCheck(
        'show ip dhcp snooping binding (or the switch equivalent)',
        'which port and which server MAC handed out each lease',
      ),
      PlaybookCheck(
        'show ip dhcp snooping / show ip dhcp snooping trust',
        'whether snooping is on and which ports are trusted uplinks',
      ),
      PlaybookCheck(
        'a packet capture of DHCP on the access VLAN',
        'the server identifier and the offer order, which names the rogue',
      ),
      PlaybookCheck(
        'show ip helper-address on the gateway for that VLAN',
        'which servers the relay is actually reaching',
      ),
    ],
    fix:
        'Enable DHCP snooping with only the real server ports trusted, and rate '
        'limit DHCP on access ports so an offer flood cannot win. Then remove '
        'or scope-limit the second server, and correct any helper-address that '
        'points at the wrong one.',
    rule:
        'Two DHCP servers on one segment is a failover design only when they '
        'split the scope or coordinate; otherwise it is a race, and snooping '
        'is what decides it.',
  ),
  DiagnosticPlaybook(
    id: 'dns-selective',
    title: 'DNS resolves some names but not others',
    subjects: ['dns', 'resolve', 'name', 'domain', 'resolver'],
    signals: [
      'works for some names but not others',
      'some names resolve and others do not',
      'some names resolve',
      'some dns names fail',
      'dns fails for some names',
      'one domain does not resolve',
      'internal names do not resolve',
      'external names resolve but internal',
      'some hosts do not resolve',
      'only certain domains',
      'dns works for some',
      'different from inside and outside',
      'different inside and outside',
      'split horizon',
      'split-horizon',
    ],
    meaning:
        'Partial resolution is the most useful DNS symptom there is: the '
        'resolver is reachable and answering, so the fault is in the path for '
        'specific names - a forwarder, a zone, a search suffix or a view. '
        'Compare one failing name with one working name and the difference is '
        'the diagnosis.',
    causes: [
      'The failing names live in an internal zone the resolver does not host '
          'and has no conditional forwarder for, so it answers NXDOMAIN for the '
          'whole suffix.',
      'Split-horizon or a DNS view: the internal client gets the internal '
          'answer and the external one does not, or the reverse.',
      'A search suffix mismatch: short names resolve for some clients because '
          'their suffix list includes the domain, and not for others.',
      'A firewall or policy that permits UDP 53 but drops answers larger than '
          '512 bytes (EDNS0/TCP fallback), which breaks names with many '
          'records.',
      'DNSSEC validation failing for one signed zone, so the resolver returns '
          'SERVFAIL for that zone only.',
    ],
    checks: [
      PlaybookCheck(
        'dig +trace <failing name> and dig <failing name> @<resolver>',
        'whether the resolver answers, and which step of delegation fails',
      ),
      PlaybookCheck(
        'dig <failing name> @<resolver> +norecurse',
        'whether the resolver is authoritative for the zone or forwarding it',
      ),
      PlaybookCheck(
        'show running-config | include domain lookup|name-server|domain name',
        'the client suffix list and the resolvers it actually uses',
      ),
      PlaybookCheck(
        'the resolver query log for the failing name',
        'the rcode and the forwarder it asked - NXDOMAIN and SERVFAIL name '
            'different faults',
      ),
    ],
    fix:
        'Add the missing conditional forwarder or zone, make the suffix list '
        'identical for all clients, and allow DNS over TCP and EDNS0 through '
        'the firewall. If DNSSEC is the cause, fix the trust anchor or chain, '
        'not the client.',
    rule:
        'Two names, one working and one failing, tell you more than any amount '
        'of resolver restarts. The difference between them is the fault.',
  ),
  DiagnosticPlaybook(
    id: 'fhrp-flap',
    title: 'The first-hop gateway keeps flapping between routers',
    subjects: ['vrrp', 'hsrp', 'glbp', 'fhrp', 'gateway'],
    signals: [
      'vrrp is flapping',
      'vrrp flaps',
      'hsrp is flapping',
      'hsrp flaps',
      'fhrp is flapping',
      'gateway keeps changing',
      'virtual ip moves',
      'vrrp state changes',
      'goes active and standby',
      'keeps taking over',
    ],
    excludes: ['both active', 'two active', 'split brain'],
    meaning:
        'A flapping FHRP group is usually not an FHRP bug: the routers keep '
        'reaching different conclusions about who is healthier, so the virtual '
        'MAC moves and every client on the segment loses its ARP entry and its '
        'default gateway at the same moment.',
    causes: [
      'Preempt is on and the priority or the tracked object oscillates - an '
          'interface that goes up and down, or a track that follows a flapping '
          'uplink.',
      'Hellos are being lost intermittently: unicast hellos blocked by an ACL, '
          'multicast 224.0.0.18 filtered, or a layer 2 loop delivering them '
          'twice.',
      'A priority tie with preempt enabled on both, so each one takes over '
          'from the other on every hello.',
      'The tracked object tracks the wrong thing (the local interface rather '
          'than the uplink path), so a healthy router decrements itself.',
      'BFD is configured with a timer shorter than the platform can honour, '
          'which turns normal jitter into a declared failure.',
    ],
    checks: [
      PlaybookCheck(
        'show standby brief / show vrrp brief (repeat twice, 30 s apart)',
        'which router is active now and whether it changed',
      ),
      PlaybookCheck(
        'show standby <group> all / show vrrp detail',
        'priority, preempt, track state and the last state change reason',
      ),
      PlaybookCheck(
        'show log | include VRRP|STANDBY|TRACK',
        'the flap history with timestamps, which correlates with a link event',
      ),
      PlaybookCheck(
        'show interface <uplink> | include flaps|last input',
        'whether the tracked uplink is itself unstable',
      ),
    ],
    fix:
        'Decide one intended active and set preempt plus a real priority gap, '
        'track the uplink rather than the local port, and fix the underlying '
        'link flap first. Add BFD only where both ends support the timer; '
        'otherwise keep the hello/dead ratio conservative.',
    rule:
        'A flapping gateway is a layer 1 or layer 2 fact surfacing as a layer 3 '
        'symptom. Fix the link, not the timer.',
  ),
  DiagnosticPlaybook(
    id: 'https-selective',
    title: 'Some HTTPS sites work and others fail',
    subjects: ['https', 'tls', 'ssl', 'site', 'website', 'browser'],
    signals: [
      'some https sites fail',
      'some https sites',
      'some websites fail but others work',
      'some sites fail but others work',
      'only some https sites',
      'certain https sites',
      'some secure sites fail',
      'https works for some sites',
    ],
    meaning:
        'A per-site HTTPS failure is almost never a routing fault, because the '
        'same path carries the sites that work. The differences that matter are '
        'packet size (MTU), certificate chain, TLS version or cipher, and '
        'whether the name is intercepted by a proxy.',
    causes: [
      'An MTU black hole: the TLS handshake gets through but the first large '
          'response is dropped, so a site with a big certificate chain or a big '
          'landing page stalls while a small site works.',
      'The site presents an incomplete chain or a certificate the client does '
          'not trust, and only that site is affected.',
      'The client or a middlebox cannot negotiate the site TLS version or '
          'cipher suite, which is increasingly the case with older clients.',
      'TLS inspection or a captive portal rewriting the connection for some '
          'destinations only.',
      'DNS returning a wrong or hijacked address for those names.',
    ],
    checks: [
      PlaybookCheck(
        'curl -v https://<failing site> from the affected client',
        'how far the handshake gets: TCP, TLS, certificate, or HTTP',
      ),
      PlaybookCheck(
        'openssl s_client -connect <site>:443 -servername <site>',
        'the chain, the negotiated version and whether verification fails',
      ),
      PlaybookCheck(
        'ping <site> size 1472 df-bit and again at 1200',
        'whether the large-packet path is the difference',
      ),
      PlaybookCheck(
        'the firewall/proxy log for the failing destination',
        'a reset, a certificate error, or a policy block - three different '
            'fixes',
      ),
    ],
    fix:
        'If the size test fails, fix the MTU or clamp MSS; if the chain is '
        'incomplete, fix the server certificate; if a cipher or version is '
        'refused, update the client or the policy. Do not disable inspection '
        'as a first move - find which of the four is true.',
    rule:
        'When some sites work, the internet path is fine. Compare a working '
        'site and a failing site on size, certificate and TLS version, and '
        'stop looking at the routing table.',
  ),
  DiagnosticPlaybook(
    id: 'bgp-table-growth',
    title: 'The BGP table keeps growing',
    subjects: ['bgp', 'table', 'prefix', 'route'],
    signals: [
      'bgp table is growing',
      'table is growing fast',
      'bgp table growth',
      'route table is growing',
      'prefix count is climbing',
      'bgp table keeps growing',
      'too many prefixes',
      'receiving too many prefixes',
      'table grew overnight',
      'table keeps growing',
      'routing table keeps growing',
      'table grows overnight',
    ],
    excludes: ['maximum-prefix', 'max-prefix', 'prefix limit'],
    meaning:
        'A table that grows without a matching topology change is a '
        'redistribution leak or a missing inbound filter, not a scaling '
        'problem. Left alone it exhausts FIB/TCAM, and the failure mode is '
        'silent: new prefixes stop being installed while old ones stay.',
    causes: [
      'A redistribution statement without a route map pulled connected or '
          'static routes into BGP, so every new subnet becomes a prefix.',
      'The upstream is sending more specifics than before (traffic '
          'engineering, or a leak from a downstream customer), and no '
          'prefix-list or max-prefix is bounding it.',
      'A route reflector or iBGP full mesh is advertising paths it should '
          'never have received, often after a filter was removed.',
      'BGP is receiving the full internet table where only a default was '
          'intended.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp summary',
        'PfxRcd per neighbor and which peer is contributing the growth',
      ),
      PlaybookCheck(
        'show ip bgp neighbors <peer> received-routes | summary',
        'the count and the shape of what that peer sends, before filtering',
      ),
      PlaybookCheck(
        'show ip bgp | include <suspicious AS or prefix>',
        'the AS path of the new prefixes, which names the source',
      ),
      PlaybookCheck(
        'show running-config | include redistribute|neighbor .* route-map',
        'whether anything is redistributed unfiltered',
      ),
      PlaybookCheck(
        'show ip route summary / the platform TCAM/FIB usage',
        'how close the table is to the hardware limit',
      ),
    ],
    fix:
        'Filter inbound with a prefix-list and an AS-path filter, set '
        'maximum-prefix with warning-only headroom, and hang a route map on '
        'the redistribution. Then summarise: advertise the aggregate, not the '
        'components.',
    rule:
        'A routing table only grows by redistribution or by what a peer sends. '
        'Find which of the two, then bound it - filters are cheaper than '
        'memory.',
  ),
  DiagnosticPlaybook(
    id: 'aaa-cert-rotation',
    title: 'AAA logins fail after a certificate rotation',
    subjects: [
      'tacacs',
      'radius',
      'aaa',
      'certificate',
      'login',
      'authentication',
    ],
    signals: [
      'after a certificate rotation',
      'certificate rotation',
      'tacacs login fails after',
      'radius fails after cert',
      'aaa broke after',
      'login fails after certificate',
      'login fails after cert renewal',
      'authentication fails after cert',
      'certificates were rotated',
      'certs were rotated',
      'after the cert rotation',
    ],
    meaning:
        'The certificate changed and authentication broke at the same time, so '
        'the cause is the trust relationship, not the credentials: either the '
        'new certificate is not trusted by the client, or the name in it no '
        'longer matches the address the client uses.',
    causes: [
      'The new certificate was issued by a CA the network devices do not have '
          'in their trust store, so every TLS or RadSec connection fails '
          'validation.',
      'The subject or SAN no longer contains the FQDN the devices dial, so '
          'hostname verification fails even though the chain is valid.',
      'The devices still hold the old certificate or the old CA as an '
          'explicit trust anchor, so rotation left them pinned to an expired '
          'root.',
      'Time skew: a device clock outside the new certificate validity window '
          'rejects it as not yet valid.',
      'For TACACS+ over TLS, the server requires client certificates and the '
          'device certificate was not replaced at the same time.',
    ],
    checks: [
      PlaybookCheck(
        'test aaa group tacacs+ <user> <pass> legacy (or the platform test command)',
        'whether the failure is transport, TLS or credentials',
      ),
      PlaybookCheck(
        'show crypto pki certificates / show crypto ca certificates',
        'which certificate and which trust anchor the device actually holds',
      ),
      PlaybookCheck(
        'openssl s_client -connect <aaa-server>:<port> -showcerts',
        'the chain the server presents now compared with before',
      ),
      PlaybookCheck(
        'show clock and the certificate notBefore/notAfter',
        'whether the device considers the certificate valid in time',
      ),
    ],
    fix:
        'Import the new CA into every device trust store, re-enrol the device '
        'certificate if the server requires client auth, and confirm the SAN '
        'matches the address in the AAA server definition. Keep the old anchor '
        'until every device has the new one, then remove it.',
    rule:
        'A certificate rotation is a trust migration, not a file swap. Rotate '
        'the trust anchor first, the leaf second, and never both at once.',
  ),
  DiagnosticPlaybook(
    id: 'multicast-freeze',
    title: 'Multicast video freezes at the receiver',
    subjects: ['multicast', 'video', 'iptv', 'stream', 'igmp'],
    signals: [
      'video freezes at the receiver',
      'multicast video freezes',
      'multicast freezes',
      'stream freezes',
      'video stutters',
      'picture freezes',
      'video freezes',
      'multicast video stutters',
      'freezes after a few minutes',
    ],
    excludes: ['not receiving', 'no multicast', 'rpf'],
    meaning:
        'A stream that plays and then freezes is not a routing failure - the '
        'join worked and packets arrived. The freeze means the receiver stopped '
        'getting packets for long enough to drain its buffer, which is a '
        'snooping, pruning, queueing or path-change question, not a PIM one.',
    causes: [
      'IGMP snooping without a querier on the VLAN: the switch ages out the '
          'group membership and prunes the stream after a few minutes, then the '
          'next join restores it.',
      'The receiver leaves and rejoins (channel change) and the prune/join '
          'latency is longer than the decoder buffer - often a last-hop IGMP '
          'version mismatch.',
      'Bursty video overruns a queue on one link, so a few hundred milliseconds '
          'of packets are dropped in a way average utilization never shows.',
      'The multicast path changes at the RP or during SPT switchover and the '
          'stream is interrupted while the new branch is built.',
      'TTL or the group range is filtered on one hop, so only some channels or '
          'some receivers are affected.',
    ],
    checks: [
      PlaybookCheck(
        'show ip igmp snooping querier / show ip igmp snooping groups',
        'whether a querier exists and whether the group is still joined when '
            'the freeze happens',
      ),
      PlaybookCheck(
        'show ip mroute <group> and show ip mroute count',
        'the incoming interface, the outgoing list, and whether the (S,G) '
            'entry was rebuilt',
      ),
      PlaybookCheck(
        'show interface <uplink> | include drops|queue|output rate',
        'tail drops or queue overruns at the moment of the freeze',
      ),
      PlaybookCheck(
        'a capture of IGMP on the receiver VLAN',
        'joins, leaves and the query interval - a missing query is the classic',
      ),
    ],
    fix:
        'Enable an IGMP querier on the VLAN (the router usually should be it), '
        'match IGMP versions end to end, and give video a queue that survives '
        'its bursts. Keep the group range consistent on every hop so a channel '
        'change does not wait for a new tree.',
    rule:
        'A stream that starts and then stops is a pruning or queueing fault. A '
        'stream that never starts is a routing or join fault. Diagnose '
        'accordingly.',
  ),
  DiagnosticPlaybook(
    id: 'gre-tunnel-drop',
    title: 'Traffic drops over a GRE tunnel',
    subjects: ['gre', 'tunnel', 'overlay', 'ipsec'],
    signals: [
      'drops over a gre tunnel',
      'traffic drops over gre',
      'gre tunnel drops',
      'packet loss over the tunnel',
      'tunnel drops large packets',
      'gre tunnel flapping',
      'tunnel goes up and down',
      'tunnel mtu problem',
    ],
    meaning:
        'GRE adds 24 bytes and hides the inner path, so a tunnel that drops '
        'traffic is usually one of three things: the encapsulated packet is too '
        'big for the underlay, the tunnel source is reached through the tunnel '
        '(recursion), or the tunnel is up but the underlay path for the source '
        'is not.',
    causes: [
      'MTU and DF: the inner packet plus 24 bytes exceeds the underlay MTU and '
          'the ICMP error never reaches the sender, so large transfers stall.',
      'Recursive routing: the route to the tunnel destination points into the '
          'tunnel itself, so the tunnel oscillates up and down.',
      'The underlay path changed and the tunnel source address is no longer '
          'reachable, while keepalives are absent so the tunnel still shows up.',
      'An ACL or firewall on the underlay dropping protocol 47 (GRE) or the '
          'return traffic, which breaks one direction at a time.',
      'Fragmentation is enabled on the tunnel and the fragments are dropped by '
          'a middlebox.',
    ],
    checks: [
      PlaybookCheck(
        'show interface tunnel <n> | include MTU|line protocol|packets',
        'the tunnel MTU, whether it is truly up, and the drop counters',
      ),
      PlaybookCheck(
        'show ip route <tunnel destination>',
        'whether the destination is reached via the tunnel - recursion in one '
            'line',
      ),
      PlaybookCheck(
        'ping <tunnel peer> size 1400 df-bit from the tunnel source',
        'the real MTU the underlay supports, before and after encapsulation',
      ),
      PlaybookCheck(
        'show interface <underlay> | include MTU|errors|drops',
        'underlay errors or MTU smaller than 1500 that the tunnel inherited',
      ),
    ],
    fix:
        'Set the tunnel MTU to underlay minus 24, add ip tcp adjust-mss 1436, '
        'and keep the route to the tunnel destination out of the tunnel (a '
        'static route via the underlay, or a host route). Enable keepalives so '
        'a dead underlay does not look like an up tunnel.',
    rule:
        'A tunnel is only as good as the underlay path to its source. Check '
        'that path, then the MTU, then the tunnel itself - in that order.',
  ),
  DiagnosticPlaybook(
    id: 'vpc-orphan-port',
    title: 'A vPC orphan port is blocking or dropping traffic',
    subjects: ['vpc', 'mlag', 'orphan', 'port-channel', 'lacp'],
    signals: [
      'vpc orphan port',
      'orphan port',
      'mlag orphan',
      'single-homed device on vpc',
      'orphan port blocking',
      'vpc orphan',
      'single attached server',
      'vpc port blocking',
      'orphan port not forwarding',
    ],
    meaning:
        'An orphan port is a port on a vPC pair that is not itself part of a '
        'vPC - a single-homed server, firewall or router. It is expected to '
        'work, and it fails when the peer-link or the vPC domain is unhealthy, '
        'because the orphan port needs the peer link to reach the other half of '
        'the topology.',
    causes: [
      'The peer-link is down or the vPC domain is not formed, so orphan ports '
          'are suspended to prevent a loop.',
      'The orphan port is on a VLAN that is not allowed on the peer-link, so '
          'the two halves have inconsistent VLAN databases.',
      'A configuration inconsistency (STP, MTU, allowed VLANs) between the vPC '
          'peers leaves the port in a suspended or blocking state.',
      'The device is dual-homed but the port-channel is not a vPC, so STP '
          'blocks one side and the other side carries everything.',
    ],
    checks: [
      PlaybookCheck(
        'show vpc brief and show vpc orphan-ports',
        'peer-link state, vPC role, and which ports are orphaned and why',
      ),
      PlaybookCheck(
        'show vpc consistency-parameters global',
        'the settings that must match on both peers and currently do not',
      ),
      PlaybookCheck(
        'show spanning-tree interface <orphan port>',
        'whether the port is blocking and what it is waiting for',
      ),
      PlaybookCheck(
        'show interface <peer-link> and show port-channel summary',
        'peer-link health and whether the bundle is up on both sides',
      ),
    ],
    fix:
        'Restore the peer-link and make the vPC domain consistent, then allow '
        'every orphan VLAN on the peer-link. If the device can be dual-homed, '
        'make it a vPC instead of an orphan - that removes the dependency '
        'entirely.',
    rule:
        'An orphan port is a design decision with a failure dependency. If the '
        'device matters, dual-home it; if it cannot be, document that its '
        'availability is the peer-link availability.',
  ),
  DiagnosticPlaybook(
    id: 'single-host-latency',
    title: 'High latency to one host only',
    subjects: ['latency', 'host', 'ping', 'slow'],
    signals: [
      'high latency to one host',
      'latency to one host only',
      'one host is slow',
      'ping to one host is slow',
      'only one host has latency',
      'slow to a single host',
      'one server is slow',
      'everything else is fine',
    ],
    meaning:
        'One slow host and a healthy network is a host or last-hop problem. '
        'The network path is shared, so if the path were the cause, more than '
        'one destination would show it - the exception is a per-port queue or a '
        'duplex fault on that one link.',
    causes: [
      'The host itself: CPU saturated, storage stalled, or a service that '
          'answers slowly. Ping to the host and ping through it behave '
          'differently.',
      'Duplex mismatch or a bad cable on the host port: latency climbs under '
          'load and the interface shows late collisions or CRC errors.',
      'Energy-efficient Ethernet or NIC offload interacting badly with the '
          'switch, adding per-packet delay that a bulk transfer hides.',
      'A QoS queue or policing policy applied only to that port or VLAN, so '
          'small probes queue behind other traffic.',
      'The host is reached over a different path (a secondary link, a proxy, '
          'or inspection) that the rest of the traffic does not use.',
    ],
    checks: [
      PlaybookCheck(
        'ping <host> and ping <host gateway> from the same source',
        'whether the latency starts at the host or beyond it',
      ),
      PlaybookCheck(
        'show interface <host port> | include errors|collisions|duplex|speed',
        'CRC, late collisions and duplex - the classic single-port causes',
      ),
      PlaybookCheck(
        'traceroute <host> and compare with a host on the same subnet',
        'whether the path differs at a hop or only at the destination',
      ),
      PlaybookCheck(
        'iperf3 between two other hosts on the same switch',
        'proves the switch and the path are healthy, isolating the host',
      ),
    ],
    fix:
        'Fix the host port first (speed/duplex, cable, offload), then the host '
        'itself, then any policy applied only to that port. If the path really '
        'is different, make it symmetric.',
    rule:
        'One slow host is never a network-wide latency problem. Prove the '
        'network healthy with a second host, then work outward from the host.',
  ),
  DiagnosticPlaybook(
    id: 'slow-wan-transfer',
    title:
        'A file transfer or backup over the WAN takes far longer than the bandwidth suggests',
    subjects: [
      'wan',
      'tcp',
      'transfer',
      'bandwidth',
      'latency',
      'backup',
      'copy',
    ],
    signals: [
      'backup takes',
      'backup window is too short',
      'takes 14 hours',
      'takes all night',
      'transfer is slow over the wan',
      'file copy over the wan is slow',
      'copy to the branch is slow',
      'backup window is not enough',
      'replication is behind',
    ],
    meaning:
        'A single TCP stream over a WAN is limited by bandwidth-delay product, '
        'not by the link rate. With 100 Mbps and 40 ms RTT the window must be '
        'about 500 KB just to fill the pipe; a default 64 KB window gives '
        'roughly 13 Mbps per stream, no matter what the circuit says.',
    causes: [
      'TCP window scaling disabled or a small receive buffer, so one stream '
          'cannot fill the pipe (the classic 64 KB window ceiling).',
      'The backup tool uses a single stream and the path has 40 ms or more '
          'of latency, so the BDP limits it long before the circuit does.',
      'Packet loss on the path: 1% loss collapses a single TCP stream far '
          'more than it affects the link utilisation counter.',
      'The tool is reading from a slow disk or deduplicating at line rate, '
          'so the bottleneck is the server, not the network.',
    ],
    checks: [
      PlaybookCheck(
        'ping across the path and note the RTT',
        'the number that turns bandwidth into a per-stream ceiling',
      ),
      PlaybookCheck(
        'a capture on the sender: look at the SYN window scale option',
        'whether scaling is negotiated at all',
      ),
      PlaybookCheck(
        'two parallel streams with iperf3 -P 4',
        'if four streams reach line rate, the limit is per-stream, not the link',
      ),
      PlaybookCheck(
        'show interface | include drops, and the WAN SLA latency/loss report',
        'whether loss or a policer is the real limiter',
      ),
    ],
    fix:
        'Fix the window first: enable TCP window scaling and raise the '
        'receive buffer on both ends. Then make the tool multi-stream and '
        'size the backup window from the measured per-stream rate, not from '
        'the circuit speed. If loss is real, fix that before adding bandwidth '
        '- a lossy 100 Mbps is slower than a clean 20 Mbps.',
    rule:
        'Over a WAN, throughput per stream = window / RTT. The circuit rate '
        'is an upper bound the protocol rarely reaches.',
  ),
  DiagnosticPlaybook(
    id: 'incompatible-optic',
    title: 'A 10G link will not come up with a third-party optic',
    subjects: ['optic', 'sfp', 'sfp+', 'transceiver', '10g', 'fiber'],
    signals: [
      'third party optic',
      'third-party optic',
      'sfp is not recognized',
      'sfp not recognized',
      'unsupported transceiver',
      'optic is not supported',
      '10g link will not come up',
      'link does not come up with the new optic',
    ],
    meaning:
        'A link that stays down with a third-party optic is usually an '
        'identity problem, not a light problem: the switch reads an EEPROM in '
        'the module and refuses to enable the port if the vendor code or the '
        'checksum is not one it accepts. That refusal looks exactly like a '
        'dead link.',
    causes: [
      'Vendor coding or an unsupported part number, so the port stays in a '
          'not-present or unsupported state.',
      'A DAC or optic that is the wrong flavour for the port (SFP+ in a '
          'QSFP+ cage, 10GBASE-LR into a -SR port), or a 1G module in a 10G '
          'port that does not negotiate down.',
      'Mismatched speed and FEC settings between the two ends, common on '
          '25G and above.',
      'A dirty or crossed fibre, or a transmit/receive pair swapped on one '
          'side, which shows light on one end only.',
    ],
    checks: [
      PlaybookCheck(
        'show interface <intf> transceiver (or show inventory)',
        'whether the switch even sees the module and what it thinks it is',
      ),
      PlaybookCheck(
        'show interface <intf> | include error|down|FEC',
        'the port state and any FEC or speed mismatch message',
      ),
      PlaybookCheck(
        'swap the optic with a known-good one, then swap the fibre pair',
        'separates module, cage and fibre in two moves',
      ),
      PlaybookCheck(
        'read the DOM values (rx power) on both ends',
        'no light at all points at the fibre or the TX side, not the coding',
      ),
    ],
    fix:
        'Use a module the platform supports, or a vendor-blessed coded '
        'equivalent, and set speed and FEC explicitly on both ends. Where '
        'the platform allows it, enable the unsupported-transceiver mode as '
        'a documented exception, not a default.',
    rule:
        'A transceiver is a component with a compatibility contract. The '
        'link being dark is a symptom; the EEPROM is often the cause.',
  ),
  DiagnosticPlaybook(
    id: 'microwave-interference',
    title: 'Wi-Fi drops when the microwave or another appliance runs',
    subjects: ['wifi', 'wi-fi', 'wireless', '2.4', 'channel', 'interference'],
    signals: [
      'when someone uses the microwave',
      'microwave',
      'drops at lunch',
      'drops when the kettle',
      'interference from an appliance',
      'non wi-fi interference',
      'spectrum is dirty',
      '2.4 ghz is unusable',
    ],
    meaning:
        'A microwave oven leaks energy across 2.4 GHz, which is the same band '
        'as channels 1-11. It is not a Wi-Fi signal, so the AP does not see a '
        'neighbour to avoid; it sees noise that raises the noise floor and '
        'breaks frames, and the retries show up as latency for every client '
        'in that cell.',
    causes: [
      'The clients are on 2.4 GHz because 5 GHz coverage or band steering is '
          'not reaching that area, so they have no better band to use.',
      'The AP is placed in or next to a kitchen, break room or utility area, '
          'where the appliance and the AP share a wall.',
      'Bluetooth, wireless cameras, baby monitors or a leaky cable are also '
          'raising the noise floor, not just the microwave.',
    ],
    checks: [
      PlaybookCheck(
        'a spectrum analysis of the area (Ekahau, Chanalyzer, or the AP '
            'vendor tool)',
        'the noise floor and the interferer signature - a microwave is a broad '
            'hump, not a clean carrier',
      ),
      PlaybookCheck(
        'show ap dot11 24ghz summary / client details',
        'which band the affected clients are actually on and their retry rate',
      ),
      PlaybookCheck(
        'the time of day and duration of the drops',
        'a 3-5 minute pattern that repeats at lunch is the appliance, not the AP',
      ),
    ],
    fix:
        'Move the clients to 5 GHz (band steering, more 5 GHz APs, 20 MHz '
        'channels) and move the AP out of the kitchen. On 2.4 GHz, lower the '
        'power and use 1/6/11 so the noise hits a smaller cell. If the '
        'appliance cannot move, treat 2.4 GHz as coverage-only for IoT and '
        'stop expecting throughput from it.',
    rule:
        'A microwave is an interferer you cannot channel-plan around. The fix '
        'is band and placement, not a different 2.4 GHz channel.',
  ),
  DiagnosticPlaybook(
    id: 'poe-budget-overrun',
    title:
        'PoE devices reboot or ports cycle when the power budget is exceeded',
    subjects: ['poe', 'power', 'inline', 'phone', 'camera', 'ap'],
    signals: [
      'phones reboot when the poe budget',
      'poe budget is exceeded',
      'poe budget exceeded',
      'not enough poe power',
      'power inline denied',
      'devices reboot when more cameras come online',
      'poe ports cycle',
      'ap reboots when the heaters come on',
    ],
    meaning:
        'A PoE switch has a fixed power supply and a smaller PoE budget. When '
        'the sum of the negotiated classes exceeds it, the switch denies new '
        'ports - and on a device that is already up, a reboot loop is the '
        'symptom because the port comes up, draws power, and is cut off when '
        'the budget is re-evaluated.',
    causes: [
      'The budget is planned from port count, not watts: 24 PoE ports do '
          'not mean 24 x 30 W.',
      'Devices are negotiating a higher class than expected (802.3at or bt '
          'devices on an af budget), or a device is drawing its peak at boot.',
      'One oversized load (a PTZ camera with heater, a bt access point) is '
          'starving the rest, and there is no per-port priority configured.',
    ],
    checks: [
      PlaybookCheck(
        'show power inline (or the vendor equivalent)',
        'the total allocated, the total available, and which ports are denied',
      ),
      PlaybookCheck(
        'show power inline <intf> detail',
        'the negotiated class and the actual draw per device',
      ),
      PlaybookCheck(
        'the device nameplates and the PoE class of each type',
        'the budget arithmetic - af 15.4 W, at 30 W, bt 60/90 W at the PSE',
      ),
    ],
    fix:
        'Recalculate the budget with 15% headroom, set port priorities so the '
        'APs and phones win over cameras, and split the load across a second '
        'switch or a PoE injector for the heaters. If the switch cannot be '
        'replaced, cap the per-port allocation and document which devices '
        'cannot run at peak together.',
    rule:
        'The PoE budget is a watts contract, not a port count. Plan the '
        'simultaneous peak, not the average.',
  ),
  DiagnosticPlaybook(
    id: 'periodic-routing-flap',
    title: 'A routing adjacency or link flaps on a regular interval',
    subjects: ['ospf', 'bgp', 'eigrp', 'isis', 'flap', 'adjacency'],
    signals: [
      'flaps every 30 minutes',
      'flaps every 15 minutes',
      'flaps every hour',
      'flaps on a schedule',
      'flaps at the same time every day',
      'drops every 30 minutes',
      'resets on a timer',
    ],
    meaning:
        'A regular interval is a timer or a scheduled event, not a random '
        'failure. The period usually names the cause: a dead interval just '
        'shorter than the hold time, a keepalive that is being dropped, a '
        'telemetry or copy job that saturates the link, or a scheduled '
        'process (backup, scan, config archive) that runs on the same clock.',
    causes: [
      'Hello and dead timers mismatched between neighbours, so one side '
          'expires the adjacency every time the other is slow to answer.',
      'The control plane is being starved: a periodic job, CoPP policer or '
          'CPU spike that makes the keepalives late exactly on that interval.',
      'A flapping physical layer (bad optic, dirty fibre, duplex mismatch, '
          'PoE device rebooting) that recovers each time and looks periodic.',
      'An MTU or fragmentation problem that only affects large update '
          'packets, so the session survives until a full update is sent.',
    ],
    checks: [
      PlaybookCheck(
        'show ip ospf neighbor / show ip bgp summary repeatedly, or a log '
            'with timestamps',
        'the exact period and which side tears the session down first',
      ),
      PlaybookCheck(
        'show run | include timers|hello|dead|hold',
        'a timer mismatch is the single most common periodic cause',
      ),
      PlaybookCheck(
        'show interface | include flap|reset|error and the log for link state',
        'whether the interface itself bounced at the same moment',
      ),
      PlaybookCheck(
        'show processes cpu history',
        'a spike aligned with the period, which is the real trigger',
      ),
    ],
    fix:
        'Fix the timers first and verify they match on both ends. If the '
        'interface is bouncing, fix the physical layer. If a scheduled job is '
        'the trigger, move it or give control traffic priority with CoPP and '
        'QoS, so the routing protocol is never the victim of a backup job.',
    rule:
        'A flap with a period has a cause with a period. Find the timer or '
        'the job before you touch the protocol.',
  ),
  DiagnosticPlaybook(
    id: 'post-change-slowdown',
    title: 'One area is slow right after a VLAN or gateway change',
    subjects: ['vlan', 'gateway', 'svi', 'slow', 'change'],
    signals: [
      'slow after the vlan change',
      'slow since the vlan change',
      'slow after the gateway change',
      'slow after the move',
      'slow after we changed the vlan',
      'one floor is slow after',
      'slower since the network change',
    ],
    meaning:
        'A change that makes one area slow usually moved traffic, not dropped '
        'it. The new path is longer, crosses a slower link, hairpins through a '
        'router or firewall, or the gateway is no longer where the clients '
        'expect it - so every flow takes a detour that the old design did not.',
    causes: [
      'The gateway (SVI) stayed on a switch that is now off the shortest '
          'path, so traffic crosses the core twice for local destinations.',
      'The new VLAN is not allowed on a trunk, so traffic takes a longer '
          'fallback path or leans on a single uplink.',
      'Asymmetric routing after the move: the return path goes through a '
          'different device, and a stateful firewall drops or slows it.',
      'STP reconverged on the change and a blocked port became the active '
          'one, which is a slower or oversubscribed link.',
    ],
    checks: [
      PlaybookCheck(
        'traceroute from the affected host to a local peer and to the gateway',
        'the number of hops and whether the gateway is the first hop',
      ),
      PlaybookCheck(
        'show interfaces trunk and show spanning-tree vlan <id>',
        'whether the VLAN is active on the path you think it is',
      ),
      PlaybookCheck(
        'show ip arp and the MAC table for the affected VLAN',
        'whether clients and gateway are where the design says',
      ),
      PlaybookCheck(
        'compare latency and throughput to a host in the same VLAN and in '
            'another VLAN',
        'local slow means L2 or the access path; cross-VLAN slow means routing',
      ),
    ],
    fix:
        'Put the gateway back on the shortest path (locally on the access '
        'switch pair, or a first-hop redundancy pair), allow the VLAN on the '
        'trunk that is actually on the path, and re-check the STP topology '
        'after the change. Verify with a traceroute and a before/after latency '
        'measurement, not with an opinion.',
    rule:
        'A change that slows one area down changed the path. Find the new '
        'path before you touch the bandwidth.',
  ),
  DiagnosticPlaybook(
    id: 'video-freeze-ping-fine',
    title: 'Video or voice calls freeze while ping stays clean',
    subjects: ['teams', 'zoom', 'voice', 'video', 'jitter', 'call'],
    signals: [
      'teams calls freeze',
      'calls freeze but ping is fine',
      'video freezes but ping is fine',
      'call drops but ping works',
      'voice is bad only in calls',
      'video stutters',
      'calls break up but ping is clean',
    ],
    meaning:
        'Ping proves reachability and round-trip time for tiny UDP packets. A '
        'call needs a steady 20-50 ms of jitter and nearly zero loss for '
        'minutes, and it fails on things ping never samples: microbursts, a '
        'congested queue, an MTU black hole, a blocked UDP range, or '
        'asymmetric routing that strands media.',
    causes: [
      'Bufferbloat on the WAN uplink: a saturated queue adds hundreds of ms '
          'of jitter while ping between calls looks fine.',
      'Media ports blocked or NAT-ed badly (UDP 3478-3481 for Teams, a '
          'restrictive firewall, or a proxy that does not pass media).',
      'MTU or fragmentation on the media path, so large key frames and '
          'screen shares break while audio survives.',
      'Wi-Fi client on 2.4 GHz with retries, or roaming between APs mid-call.',
    ],
    checks: [
      PlaybookCheck(
        'the call quality dashboard or the client stats (jitter, loss, RTT)',
        'the metric that is actually bad, per direction',
      ),
      PlaybookCheck(
        'a continuous ping with 50-byte and 1400-byte payloads during a call',
        'jitter and loss that appear only under load or only at size',
      ),
      PlaybookCheck(
        'show policy-map interface on the WAN edge',
        'whether the voice queue exists and whether it is actually matching',
      ),
      PlaybookCheck(
        'the firewall session table for the media flow, both directions',
        'a one-way flow or a half-open state, which audio tolerates badly',
      ),
    ],
    fix:
        'Give voice and video a real queue with priority on the WAN edge and '
        'shape the parent to 90% of the circuit, mark at the source and trust '
        'at the boundary, open the media ports, and clamp MSS on any tunnel. '
        'On Wi-Fi, put the clients on 5 GHz and enable roaming assistance.',
    rule:
        'Ping is a reachability test, not a quality test. Calls fail on '
        'jitter, loss and policy - measure those.',
  ),
  DiagnosticPlaybook(
    id: 'failover-too-slow',
    title: 'Internet or WAN failover takes much longer than expected',
    subjects: ['failover', 'bgp', 'hsrp', 'vrrp', 'ip sla', 'wan'],
    signals: [
      'internet failover takes',
      'failover takes 90 seconds',
      'failover takes a minute',
      'failover is too slow',
      'takes 90 seconds to fail over',
      'convergence takes minutes',
      'failover takes 3 minutes',
    ],
    meaning:
        'Failover time is the sum of the detection time and the convergence '
        'time. A 90-second failover is usually BGP hold time (90 s default) '
        'plus nothing else: the link is dead but nobody has told the routing '
        'protocol yet, because there is no fast failure signal.',
    causes: [
      'No BFD and no IP SLA, so the only detector is the BGP hold timer or '
          'the default route timing out.',
      'The backup path is not pre-installed: it is learned only after the '
          'primary withdraws, so there is nothing to switch to immediately.',
      'NAT or firewall state is tied to one uplink, so the path moves but the '
          'sessions do not.',
      'The FHRP (HSRP/VRRP) timers are default (3 s hello, 10 s hold), so the '
          'LAN gateway moves more slowly than the WAN did.',
    ],
    checks: [
      PlaybookCheck(
        'show ip bgp neighbors | include hold|keepalive|BFD',
        'the detection timers actually in effect, per peer',
      ),
      PlaybookCheck(
        'show ip sla statistics and the tracking object state',
        'whether anything is probing the path and how fast it reacts',
      ),
      PlaybookCheck(
        'a planned shutdown of the primary, timed with a continuous ping',
        'the real measured failover, not the designed one',
      ),
      PlaybookCheck(
        'show standby brief / show vrrp brief',
        'the LAN gateway timers, so you know which half is slow',
      ),
    ],
    fix:
        'Add BFD (sub-second detection) or IP SLA tracking with a tight '
        'interval, shorten the hold timer only where both ends agree, keep '
        'the backup default route pre-installed with a worse metric or local '
        'preference, and make NAT and firewall state follow the path. Then '
        'measure the failover again with a planned test.',
    rule:
        'Failover is detection plus convergence. If nobody detects the '
        'failure, the timers are the design.',
  ),
  DiagnosticPlaybook(
    id: 'lacp-hash-imbalance',
    title: 'A port channel is up but traffic only uses one member link',
    subjects: ['lacp', 'port-channel', 'etherchannel', 'hash', 'lag'],
    signals: [
      'port channel is up but traffic only uses one link',
      'bundle is up but only one link carries traffic',
      'etherchannel uses one link',
      'lacp hashing is uneven',
      'lag is not load balancing',
      'one member link is idle',
    ],
    meaning:
        'A port channel is one logical link, and the switch pins each flow to '
        'one member by hashing the headers. A single flow - one TCP session, '
        'one backup job, one iperf stream - always uses one member, so a link '
        'that looks idle is often a hash with nothing else on it.',
    causes: [
      'The test is a single flow: iperf with one stream cannot spread across '
          'members because the hash of that 5-tuple never changes.',
      'Every flow has the same hash input (same source and destination pair, '
          'or a router in the path that rewrites nothing), so the hash '
          'collapses onto one link.',
      'The two ends use different hash algorithms, or one end is a server '
          'using a single MAC and IP pair, which is a common asymmetry.',
    ],
    checks: [
      PlaybookCheck(
        'show etherchannel load-balance and the per-link counters',
        'which hash fields are used and whether the split is per flow',
      ),
      PlaybookCheck(
        'iperf3 with -P 8 between many client/server pairs',
        'whether multiple flows spread, which separates hash from a broken member',
      ),
      PlaybookCheck(
        'show interfaces <member> | include rate|packets',
        'the real per-member utilisation, not the aggregate',
      ),
    ],
    fix:
        'Change the hash to include L4 ports where the platform allows it (and '
        'only where the traffic is not fragmented), add more distinct flows, '
        'or accept that one flow gets one link. If the goal is a single fast '
        'transfer, use multiple streams or a faster single link.',
    rule:
        'A port channel balances flows, not packets. One flow is one member, '
        'always.',
  ),
  DiagnosticPlaybook(
    id: 'asymmetric-return',
    title: 'The firewall drops return traffic or sessions half-open',
    subjects: ['firewall', 'stateful', 'return', 'asymmetric', 'nat'],
    signals: [
      'firewall drops the return traffic',
      'return traffic is dropped',
      'sessions are half open',
      'traffic goes out but not back',
      'works outbound but not inbound',
      'asymmetric routing causes drops',
    ],
    meaning:
        'A stateful firewall builds a session table keyed on the forward flow. '
        'If the reply comes back by a different path - another router, another '
        'uplink, another firewall in a pair - the device that sees the reply '
        'has no session for it and drops it as unsolicited. The symptom is a '
        'connection that establishes and then stalls, or dies after the first '
        'packet.',
    causes: [
      'Two equal-cost paths and per-flow or per-packet load sharing, so the '
          'forward and return directions hash differently.',
      'A routing change on one side only (a static route, a summary, a '
          'floating route) that moves the return path without moving the '
          'forward path.',
      'A firewall pair without session synchronisation or with asymmetric '
          'routing enabled incorrectly.',
      'NAT applied on one path only, so the reply addresses do not match the '
          'session.',
    ],
    checks: [
      PlaybookCheck(
        'traceroute in both directions from both endpoints',
        'the two paths side by side, which is the whole diagnosis',
      ),
      PlaybookCheck(
        'the firewall session table for the flow (show session / conntrack)',
        'whether the reply finds a session and which interface it arrives on',
      ),
      PlaybookCheck(
        'the firewall drop log with the source and destination of the reply',
        'usually an async or invalid-state drop that names the interface',
      ),
    ],
    fix:
        'Make the path symmetric: fix the routing so both directions use the '
        'same pair of devices, or make the device that sees the reply trust '
        'the flow. Disable per-packet load sharing, synchronise the firewall '
        'state, and keep NAT on the same pair as the session.',
    rule:
        'Stateful devices require symmetric paths. If the reply takes a '
        'different road, it arrives as a stranger.',
  ),
  DiagnosticPlaybook(
    id: 'dns-first-request-slow',
    title: 'The first DNS lookup is slow and later ones are fast',
    subjects: ['dns', 'resolver', 'forwarder', 'cache', 'lookup'],
    signals: [
      'dns resolves slowly for the first request',
      'first lookup is slow',
      'first dns request takes seconds',
      'dns is slow the first time',
      'lookup takes 5 seconds',
      'dns times out then works',
    ],
    meaning:
        'A slow first lookup followed by fast repeats is a cold cache and a '
        'forwarder problem, not a network problem. The resolver has to recurse '
        'or forward to a server that is slow, unreachable, or being asked over '
        'a broken path, and the second query is served from cache.',
    causes: [
      'A forwarder that is unreachable or dropping, so each uncached query '
          'waits for the timeout before trying the next one.',
      'IPv6 or a second server configured on the client, so every query tries '
          'the dead address first and falls back after a timeout.',
      'Recursion disabled on the internal resolver, so it cannot answer for '
          'external names and has to time out or fail upward.',
      'EDNS or a large response blocked by a firewall or a middlebox, so the '
          'first answer truncates and retries over TCP.',
    ],
    checks: [
      PlaybookCheck(
        'dig @<resolver> name +stats, repeated twice',
        'the query time on the first and second run, which proves caching',
      ),
      PlaybookCheck(
        'dig name @<resolver> +trace (from the resolver itself, if allowed)',
        'where the recursion stalls - root, TLD or the authoritative server',
      ),
      PlaybookCheck(
        'the resolver forwarder list and its health',
        'a dead forwarder is the most common single cause',
      ),
      PlaybookCheck(
        'a capture on the resolver during the slow query',
        'whether it is waiting on upstream, on TCP retry, or not sending at all',
      ),
    ],
    fix:
        'Remove dead forwarders and dead client-side DNS entries, allow '
        'recursion where it is required, allow UDP 53 and TCP 53 end to end, '
        'and size the cache so the working set stays warm. Verify with a '
        'cold-cache query after a resolver restart.',
    rule:
        'The first lookup is the only one that measures the resolver. Later '
        'ones measure the cache.',
  ),
  DiagnosticPlaybook(
    id: 'single-stream-slow',
    title: 'iperf shows a gigabit but a file copy is slow',
    subjects: ['iperf', 'throughput', 'tcp', 'smb', 'copy', 'stream'],
    signals: [
      'iperf shows 1 gig but file copy is slow',
      'iperf is fast but the copy is slow',
      'file copy is slower than iperf',
      'throughput is fine but the transfer is slow',
      'smb copy is slow',
      'single stream is slow',
    ],
    meaning:
        'iperf with parallel streams measures the path. A file copy measures '
        'one stream plus the storage, the protocol and the client. When the '
        'two disagree by an order of magnitude, the difference is the '
        'bottleneck, not the network.',
    causes: [
      'A single TCP stream over a latency-bound path, limited by window and '
          'RTT rather than by bandwidth.',
      'SMB signing or encryption, antivirus scanning, or a small block size, '
          'which makes the copy CPU-bound on the client or server.',
      'Disk or storage latency on either end, invisible to iperf because '
          'iperf never touches the disk.',
      'MTU or fragmentation on the path, where the large transfer pays a '
          'retransmission cost that a synthetic test with small buffers does not.',
    ],
    checks: [
      PlaybookCheck(
        'iperf3 with -P 1 and -P 8 on the same path',
        'the gap between one stream and many is the window or latency story',
      ),
      PlaybookCheck(
        'copy the same file to a local disk versus over the network',
        'isolates storage from the path',
      ),
      PlaybookCheck(
        'a capture during the copy: retransmissions and the window size',
        'loss, zero-window or a small window names the limiter',
      ),
    ],
    fix:
        'Fix the stream first: window scaling, a faster single path, or more '
        'streams in the tool. Then look at signing, scanning and storage. Do '
        'not buy bandwidth for a problem that a window and a disk cause.',
    rule:
        'iperf measures the network; a copy measures the whole stack. Blame '
        'the stack only for what it actually limits.',
  ),
  DiagnosticPlaybook(
    id: 'mgmt-lockout',
    title: 'You cannot reach the switch after an ACL or VTY change',
    subjects: [
      'acl',
      'vty',
      'ssh',
      'telnet',
      'management',
      'lockout',
      'locked',
      'console',
    ],
    signals: [
      'cannot ssh to the switch after the acl change',
      'locked out of the switch',
      'locked out of the router',
      'cannot ssh to the switch',
      'locked out of the switch',
      'ssh stopped working after the acl',
      'management access is blocked',
      'cannot reach the device after the change',
      'no console access',
      'cannot console',
      'cannot log in to the switch',
      'cannot log into the switch',
      'console access is blocked',
    ],
    meaning:
        'An ACL applied to the VTY lines is evaluated against the source '
        'address and the destination port, in order, and the implicit deny at '
        'the end is what locks you out. The change was probably correct and the '
        'ordering or the direction was not.',
    causes: [
      'The permit for your management subnet sits below a deny that already '
          'matched, so it is never evaluated.',
      'The ACL was applied in the wrong direction (in on the interface when '
          'your traffic is out, or out when it is in).',
      'A NAT or a proxy changes the source address, so the source the device '
          'sees is not the one you wrote in the permit.',
      'The default route or the return path was removed with the change, so '
          'the reply never leaves the device.',
    ],
    checks: [
      PlaybookCheck(
        'the console or out-of-band access - always the first move',
        'a path that does not depend on the ACL under test',
      ),
      PlaybookCheck(
        'show ip access-lists <name> with the hit counters',
        'which line matched your session, which names the real cause',
      ),
      PlaybookCheck(
        'show run | include access-class|line vty|transport input',
        'the ACL in force on the VTYs and the transport allowed',
      ),
      PlaybookCheck(
        'a capture on the device or a debug ip packet with an ACL',
        'the source address the device actually sees',
      ),
    ],
    fix:
        'Get in by console or out-of-band first, then put the permit above '
        'the deny (or add an explicit permit for the management subnet at the '
        'top), correct the direction, and test from a second host before you '
        'close the session. Keep a rollback: reload in 5 and cancel it.',
    rule:
        'An ACL is ordered and implicitly denies. Writing it is easy; keeping '
        'a way in while you test it is the skill.',
  ),
  DiagnosticPlaybook(
    id: 'vlan-isolation-broken',
    title: 'A guest or isolated VLAN can reach a network it should not',
    subjects: ['vlan', 'guest', 'isolation', 'acl', 'native'],
    signals: [
      'guest network can reach the management vlan',
      'guest can reach the servers',
      'guest vlan is not isolated',
      'isolated vlan can reach',
      'guest wifi can ping the lan',
      'isolation is not working',
    ],
    meaning:
        'A VLAN is a broadcast domain, not a security boundary. Guest and '
        'server VLANs on the same switch are only separated by the policy you '
        'put on the gateway, and any of the four common shortcuts leaks them '
        'back together.',
    causes: [
      'No ACL on the guest SVI: routing between VLANs is on by default on a '
          'layer 3 switch.',
      'A native VLAN mismatch or an untagged port that bridges the two VLANs '
          'on a trunk.',
      'The guest VLAN is allowed on a trunk it should not be on, or a switch '
          'port is left in the wrong VLAN after a move.',
      'The wireless controller terminates guest traffic on the internal '
          'interface instead of a DMZ or an anchor.',
    ],
    checks: [
      PlaybookCheck(
        'show vlan brief and show interfaces trunk on every switch in the path',
        'where the guest VLAN exists and which trunks allow it',
      ),
      PlaybookCheck(
        'show ip route on the core for the guest and management subnets',
        'a route that should not exist is the whole answer',
      ),
      PlaybookCheck(
        'the ACL or VRF on the guest gateway, with hit counters',
        'whether the policy is applied and whether it is matching',
      ),
      PlaybookCheck(
        'a traceroute from a guest host to the management subnet',
        'the device that forwards it is the device missing the policy',
      ),
    ],
    fix:
        'Put the guest gateway in its own VRF or behind the firewall, deny '
        'guest-to-internal traffic explicitly on the SVI or the firewall, '
        'prune the guest VLAN off every trunk that does not need it, and fix '
        'the native VLAN mismatch. Verify by testing from the guest, not by '
        'reading the config.',
    rule:
        'VLANs segment, they do not secure. Isolation is a policy on the '
        'gateway, and it has to be applied everywhere traffic can go.',
  ),
  DiagnosticPlaybook(
    id: 'ios-upgrade-fails',
    title: 'A switch will not accept or boot the new software image',
    subjects: ['ios', 'firmware', 'upgrade', 'flash', 'boot'],
    signals: [
      'will not take the new ios',
      'switch will not boot the new image',
      'ios upgrade fails',
      'firmware upgrade fails',
      'not enough flash for the image',
      'boot variable is wrong',
      'image is not compatible',
    ],
    meaning:
        'An image that copies but will not boot is a compatibility or a boot '
        'variable problem, not a copy problem. The platform checks the image '
        'signature against the bootloader, the flash has to hold two images '
        'during the upgrade, and the boot statement has to point at the file '
        'you actually copied.',
    causes: [
      'Flash too small for both images, so the copy is truncated or deleted '
          'to make room.',
      'The boot variable still points at the old file name, or the image was '
          'copied to a different filesystem than the one boot reads.',
      'The image is not supported on that platform or requires a ROMMON '
          'upgrade first, and the release notes say so.',
      'The image is for a different hardware revision or a different license '
          'level, so it boots into a limited or failed state.',
    ],
    checks: [
      PlaybookCheck(
        'show flash: (or dir) for the free space and the file size',
        'whether both images fit at the same time',
      ),
      PlaybookCheck(
        'show boot / show run | include boot',
        'the variable that decides which image actually loads',
      ),
      PlaybookCheck(
        'show version and the hardware revision',
        'the compatibility matrix entry for this exact model and revision',
      ),
      PlaybookCheck(
        'the console output during boot',
        'the signature or bootloader message, which names the real refusal',
      ),
    ],
    fix:
        'Free flash, set the boot variable to the new file and verify with '
        'show boot, upgrade ROMMON first if the notes require it, and keep the '
        'old image until the new one has booted twice. Never upgrade without '
        'console access and a known-good rollback image.',
    rule:
        'A copy that succeeds is not a boot that succeeds. Verify the boot '
        'variable and the compatibility matrix before the maintenance window.',
  ),
  DiagnosticPlaybook(
    id: 'new-isp-inbound-mail',
    title: 'Inbound mail or remote access fails after moving to a new ISP',
    subjects: ['isp', 'mx', 'mail', 'dns', 'ptr', 'port 25'],
    signals: [
      'inbound mail fails',
      'inbound mail stopped',
      'inbound mail fails after the isp change',
      'moved to a new isp and mail stopped',
      'mail stopped after the isp move',
      'mx records point to the old isp',
      'port 25 is blocked by the isp',
      'remote access fails after the isp change',
    ],
    meaning:
        'An ISP move changes the public address, and everything that named the '
        'old address keeps pointing at it: MX records, PTR, SPF, VPN peers, '
        'and firewall NAT rules. Mail also has a second trap - many residential '
        'and some business circuits block outbound port 25 and sometimes '
        'inbound.',
    causes: [
      'MX and SPF still reference the old address or the old ISP mail host.',
      'Reverse DNS (PTR) is not set for the new address, so receivers reject '
          'the mail or mark it as spam.',
      'Port 25 is blocked by the new ISP, so the mail server cannot talk to '
          'the world even with correct DNS.',
      'The firewall NAT or the VPN peer address still uses the old public IP.',
    ],
    checks: [
      PlaybookCheck(
        'dig MX and dig TXT for the domain, from outside the network',
        'what the world is actually told, not what you intended',
      ),
      PlaybookCheck(
        'dig -x <new public ip>',
        'whether PTR matches the hostname the mail server presents',
      ),
      PlaybookCheck(
        'a telnet or nc test to port 25 from outside, and to your server',
        'whether the ISP blocks the port or the server blocks the sender',
      ),
      PlaybookCheck(
        'the firewall NAT and VPN config for the old public address',
        'every leftover reference to the previous circuit',
      ),
    ],
    fix:
        'Update MX, SPF, DKIM and DMARC, ask the ISP for matching PTR, confirm '
        'port 25 is allowed (or relay through the ISP or a mail gateway), and '
        're-point NAT and VPN peers at the new address before you cancel the '
        'old circuit. Keep both circuits until propagation is verified from '
        'outside.',
    rule:
        'Changing ISP changes your public identity. DNS, PTR and port policy '
        'are part of the cutover, not after it.',
  ),
  DiagnosticPlaybook(
    id: 'provider-dispute',
    title: 'The circuit shows no errors but users say it is bad',
    subjects: ['wan', 'circuit', 'provider', 'sla', 'latency', 'loss'],
    signals: [
      'wan circuit shows no errors',
      'provider says the circuit is fine',
      'carrier says there is no problem',
      'circuit is clean but the app is slow',
      'no interface errors but users complain',
      'provider blames our side',
    ],
    meaning:
        'Interface counters only see what happens on the port: a circuit can '
        'be error-free and still lose packets, add latency or police bursts in '
        'the provider cloud. The error-free interface is evidence about one '
        'point, not about the path.',
    causes: [
      'Microbursts above the committed rate, absorbed by the provider policer '
          'and dropped without any local interface error.',
      'A provider-side routing change or a congested upstream link adding '
          'latency and jitter that no local counter shows.',
      'Asymmetric paths: the return traffic takes a different provider and '
          'the loss appears on a path you do not monitor.',
      'The application or an MTU/PMTUD problem using the circuit, not the '
          'circuit failing.',
    ],
    checks: [
      PlaybookCheck(
        'a continuous ping with timestamps and 1400-byte payloads to both '
            'ends, plus a traceroute on both directions',
        'loss and latency per hop, and whether the path is symmetric',
      ),
      PlaybookCheck(
        'show interface | include rate|drops|errors on both ends',
        'local errors, and the burst rate against the committed rate',
      ),
      PlaybookCheck(
        'an SLA measurement (IP SLA, TWAMP, or a probe at both ends)',
        'the numbers you can hand the provider - not a complaint',
      ),
      PlaybookCheck(
        'the class-map/policer config on the edge',
        'whether the circuit is policing in the provider or shaping locally',
      ),
    ],
    fix:
        'Shape the egress to 90-95% of the committed rate so bursts are '
        'smoothed before the provider polices them, measure loss and latency '
        'per hop in both directions, and open a ticket with the measurements '
        'and the test window. Do not accept a port-counter answer for a '
        'path-quality question.',
    rule:
        'Interface counters describe the port. Path quality needs a probe at '
        'both ends, in both directions.',
  ),
  DiagnosticPlaybook(
    id: 'clock-drift-dst',
    title: 'Devices are an hour off after a daylight-saving change',
    subjects: ['ntp', 'clock', 'time', 'timezone', 'logs', 'timestamps'],
    signals: [
      'ntp is an hour off',
      'clock is an hour off',
      'an hour off after the daylight',
      'an hour off after daylight',
      'time is wrong after daylight',
      'logs are an hour behind',
      'timestamps are an hour off',
      'off by one hour',
    ],
    meaning:
        'An exact one-hour offset is a timezone or rule problem, not clock '
        'drift. NTP distributes UTC; the local offset and the summer-time '
        'rule are applied on the device, and it is those two settings that '
        'disagree after a change.',
    causes: [
      'The timezone offset is configured but the summer-time rule is not, so '
          'the device stays on standard time all year.',
      'The rule is configured with the wrong dates or the wrong offset for '
          'that hemisphere or country.',
      'Some devices use UTC and others use local time in their logs, so the '
          'offset is in the reporting, not in the clock.',
      'The device is not synchronised at all and has drifted, which is a '
          'different symptom: it shows stratum 16 and no reference.',
    ],
    checks: [
      PlaybookCheck(
        'show clock detail',
        'the time source and the configured zone, side by side',
      ),
      PlaybookCheck(
        'show ntp status and show ntp associations',
        'whether the clock is synchronised at all - rule out drift first',
      ),
      PlaybookCheck(
        'show run | include timezone|summer-time',
        'the offset and whether a rule exists to shift it',
      ),
      PlaybookCheck(
        'the same comparison against a reference in UTC',
        'UTC matching while local time differs proves the rule, not NTP',
      ),
    ],
    fix:
        'Set the zone offset and the summer-time rule explicitly on every '
        'device, keep logs in UTC for correlation, and verify against a '
        'reference in UTC after the change. Treat a missing rule as a config '
        'defect, not as a quirk.',
    rule:
        'NTP moves UTC. Everything local is a rule, and a rule you did not '
        'configure is a rule that will be wrong twice a year.',
  ),
  DiagnosticPlaybook(
    id: 'total-outage',
    title: 'Everything is down - or so the first report says',
    // No subject gate: the whole point of this playbook is that people describe
    // a total outage without naming a technology at all.
    subjects: [],
    signals: [
      'internet is dead',
      'internet is down',
      'nobody can connect',
      'no one can connect',
      'nothing works',
      'nothing can connect',
      'everyone is offline',
      'the network is down',
      'whole network is down',
      'all users are down',
    ],
    meaning:
        'A total-outage report is a scope problem before it is a fault: one host, one VLAN, one floor, one site or everything. The answer is not a list of commands, it is the smallest set of tests that finds the boundary between what works and what does not. Every minute spent guessing instead of scoping is a minute added to the outage.',
    causes: [
      'A single upstream fault that looks total: the ISP circuit, the edge router, the core uplink, or one power strip feeding the IDF.',
      'A layer-2 event: a loop, a broadcast storm, a blocked trunk, or a spanning-tree reconvergence that took the management path with it.',
      'A layer-3 event: the default route withdrawn, an IGP adjacency down, a duplicate address or a failed HSRP/VRRP pair.',
      'A name-resolution fault: everything is up but nothing resolves, which users report as no internet.',
      'A change: the last person who touched the device, and the config that was not committed back.',
    ],
    checks: [
      PlaybookCheck(
        'the scope: ask one affected user to ping the gateway, 8.8.8.8 and a name, and one unaffected user the same',
        'the boundary - host, VLAN, site or everything - which halves the search space',
      ),
      PlaybookCheck(
        'show interfaces status / show ip interface brief on the core and the edge',
        'a down uplink or an err-disabled port, which is the fastest total-outage cause',
      ),
      PlaybookCheck(
        'show spanning-tree vlan <id> and show mac address-table count',
        'a loop, a flapping root or a MAC table explosion',
      ),
      PlaybookCheck(
        'show ip route and the default route specifically, then ping the ISP next hop',
        'whether the failure is before or after the edge',
      ),
      PlaybookCheck(
        'the device logs and the last change, with timestamps',
        'the trigger, which is usually a config line or a link event at the same minute',
      ),
    ],
    fix:
        'Work outward from the boundary: restore the lowest layer that is broken, one change at a time, and re-test after each. Do not reload the core to make it feel better. If the change is not understood, roll back to the last known-good config and keep the evidence. Then scope the blast radius so the next report is not a guess.',
    rule:
        'Total outage means unknown scope. Find the boundary first, then fix the first broken layer; a change you cannot explain is a second outage waiting.',
  ),
  DiagnosticPlaybook(
    id: 'cannot-reach-host',
    title: 'One host cannot be reached',
    subjects: [],
    signals: [
      'cannot reach the server',
      'cant reach the server',
      'cannot ping the server',
      'cant ping the server',
      'server is unreachable',
      'host is unreachable',
      'cannot reach a host',
      'cannot reach that server',
      'cannot access the shared drive',
      'cannot access the file share',
      'cannot open the shared drive',
    ],
    excludes: ['internet', 'website', 'vpn'],
    meaning:
        'One unreachable host is a path question with four possible breaks: name resolution, layer 2 (ARP and VLAN), layer 3 (route and ACL) and the host itself (firewall, listening socket, wrong interface). Narrow it in that order and do not restart anything until you know which layer failed.',
    causes: [
      'Name resolution: the name resolves to the wrong address or does not resolve at all, so the connection never leaves.',
      'Layer 2: the destination is on the same subnet but the ARP entry is incomplete, the port is in the wrong VLAN, or a private VLAN isolates it.',
      'Layer 3: a missing or asymmetric route, an ACL on an interface or VRF, or a NAT rule that does not cover this source.',
      'The host: its local firewall, a service bound to loopback, or a second NIC with the wrong default gateway.',
    ],
    checks: [
      PlaybookCheck(
        'nslookup <name> and ping <ip> (not the name)',
        'whether the name or the path is broken - the first split',
      ),
      PlaybookCheck(
        'tracert/traceroute to the address, plus ping with the same size the application uses',
        'where the path stops, and whether a large packet fails where a small one passes',
      ),
      PlaybookCheck(
        'show ip arp <ip>, show mac address-table address <mac>, show interface status',
        'the same-subnet case: present, learned on the wrong port, or missing entirely',
      ),
      PlaybookCheck(
        'show ip route <ip>, then the ACLs on the path (show ip access-lists and the interface counters)',
        'the routed case: no route, a less specific route, or a deny with a hit counter',
      ),
      PlaybookCheck(
        'on the server: netstat -an | findstr :443 (or ss -lntp) and the local firewall log',
        'whether anything is listening and whether the host itself is dropping',
      ),
    ],
    fix:
        'Fix the layer that failed and re-run the same two tests. If the packet arrives but no reply leaves, the problem is on the host, not the network - and that is a finding, not a failure.',
    rule:
        'One host unreachable is a path, not an outage: resolve the name, prove the L2 adjacency, prove the route, then look at the host. Never start with a reload.',
  ),
  DiagnosticPlaybook(
    id: 'device-wont-boot',
    title: 'A switch or router will not boot',
    subjects: ['switch', 'router', 'device', 'chassis'],
    signals: [
      'will not boot',
      'wont boot',
      'does not power on',
      'will not power on',
      'dead switch',
      'no lights on the switch',
      'stuck at rommon',
      'boot loop',
    ],
    meaning:
        'A device that will not boot has three separate questions: power, POST and the boot image. They fail differently and only one of them is a reload away from working. The console output is the evidence; guessing is how a spare gets ordered for a bad power cable.',
    causes: [
      'Power: no live circuit, a failed PSU, a wrong voltage or a UPS that is on battery and depleted.',
      'POST or hardware: a failed fan tray, a memory fault, or an amber status LED that names the failed component.',
      'Boot image: a missing or corrupt IOS, a wrong boot variable, or a bootflash that no longer holds the image.',
      'Configuration: a boot loop caused by a config that reloads (a scheduled reload, a watchdog reset, or a crash in a feature).',
    ],
    checks: [
      PlaybookCheck(
        'the outlet, the PSU LED and the power cable, then a known-good outlet',
        'power before anything else - it is the cheapest cause and the most common',
      ),
      PlaybookCheck(
        'a console session at 9600 8N1 through a rollover cable',
        'POST output, the boot variable, and the exact point where it stops',
      ),
      PlaybookCheck(
        'rommon: dir flash: / dir bootflash:',
        'whether the image is present and what the boot variable points at',
      ),
      PlaybookCheck(
        'the system LED and the fan tray; show version after it boots',
        'a hardware fault versus a software one',
      ),
    ],
    fix:
        'Boot from a known image (boot flash:<image>), correct the boot variable (boot system flash:<image>), and only then change the config. If the image is missing, recover it over TFTP from rommon (tftpdnld) or USB. If POST fails, replace the part - no config change fixes a dead fan tray.',
    rule:
        'Power, POST, image - in that order, with the console open. A device that will not boot is a hardware and boot-loader question, not a routing one.',
  ),
  DiagnosticPlaybook(
    id: 'printer-offline',
    title: 'The printer is offline or nothing prints',
    subjects: ['printer', 'print'],
    signals: [
      'printer is offline',
      'printer offline',
      'cannot print',
      'cant print',
      'print queue is stuck',
      'jobs stay in the queue',
    ],
    meaning:
        'Printing crosses three boundaries that fail independently: the client to the queue, the queue to the device, and the device to the paper. Offline in Windows usually means the queue cannot open a TCP session to the printer, which is a network fact, not a driver fact.',
    causes: [
      'The printer has an address the network does not route, or it lost its DHCP lease and changed address.',
      'The printer is on a different VLAN (guest, IoT) with no path to the queue, or a wireless printer is on the guest SSID with client isolation.',
      'Discovery fails across subnets: mDNS/Bonjour does not cross a router without a reflector, so the driver cannot find the device.',
      'The queue points at a hostname that no longer resolves, or the wrong driver on the print server.',
    ],
    checks: [
      PlaybookCheck(
        'ping the printer by IP from the print server, then open its web page',
        'the network path to the device, independent of the driver',
      ),
      PlaybookCheck(
        'show ip arp <printer-ip> and the switch port status',
        'whether the device is on the network at all, and on which VLAN',
      ),
      PlaybookCheck(
        'the printer self-test page with its IP, mask and gateway',
        'what the device believes about itself - the fastest way to catch a wrong mask or gateway',
      ),
      PlaybookCheck(
        'the print server queue and port configuration',
        'a stale hostname, a wrong port (WSD versus TCP 9100), or a paused queue',
      ),
    ],
    fix:
        'Give the printer a DHCP reservation or a static address, put it on a VLAN with a route to the print server, and point the queue at the IP rather than the name. Add an mDNS reflector if discovery has to cross subnets; otherwise print by IP.',
    rule:
        'A printer offline is a reachability question first. Print by IP, and reserve the address, before you touch a driver.',
  ),
  DiagnosticPlaybook(
    id: 'device-offline',
    title: 'A device keeps going offline',
    subjects: [
      'camera',
      'printer',
      'sensor',
      'nvr',
      'pos',
      'device',
      'endpoint',
      'ap',
      'access point',
      'phone',
    ],
    signals: [
      'keeps going offline',
      'goes offline',
      'drops offline',
      'disappears from the network',
      'disappears from the controller',
      'disappears from the nvr',
      'shows offline',
      'keeps dropping off',
      'offline every few minutes',
      'keeps leaving the network',
    ],
    meaning:
        'A device that is online and then offline is losing one of four '
        'things, in this order: power, link, address, or its management path. '
        'The device uptime tells power from link, the switch counters tell link '
        'from address, and the lease/ARP table tells address from management. '
        'The order matters because a factory reset destroys the evidence for '
        'the first three.',
    causes: [
      'Power: PoE budget or class, a failing injector, or a power supply that '
          'cannot hold the load. The device uptime resets and the switch log '
          'shows the port cycling.',
      'Link: a cable, connector or optic at the edge of its budget, or a '
          'speed/duplex mismatch that only fails under traffic. CRC, input '
          'errors and interface resets name it.',
      'Address: the DHCP lease expired and the device came back on a '
          'different address, a duplicate IP displaced it, or 802.1X/snooping '
          'put the port back in an unauthorised state.',
      'Wireless: weak RSSI, a roam to a worse AP, or power-save that the '
          'infrastructure reads as offline. The controller log shows the roam '
          'and the signal at the drop.',
      'Management path: the device is up but the controller, NVR or monitoring '
          'host cannot reach it - a VLAN/ACL/NAT change or a route that only '
          'covers the old subnet.',
      'Device: a watchdog, firmware bug or thermal fault that reloads it '
          'without touching the network. That is the last hypothesis, not the '
          'first.',
    ],
    checks: [
      PlaybookCheck(
        'the device uptime and `show power inline <intf> detail`',
        'whether it rebooted (power) or stayed up (link/address/management)',
      ),
      PlaybookCheck(
        '`show interfaces <intf> | include reset|CRC|drops|duplex`',
        'physical and queue loss on the port, and whether the link itself '
            'reset',
      ),
      PlaybookCheck(
        '`show ip dhcp binding` and `show ip arp` for the device MAC',
        'whether the address moved, expired or was taken by another device',
      ),
      PlaybookCheck(
        '`show log | include <intf>|POE|LINEPROTO`',
        'the reason and timestamp of each drop, which is the timeline you '
            'match against the controller/NVR event log',
      ),
      PlaybookCheck(
        'the controller/NVR event log and the RSSI at the drop (wireless)',
        'a roam or a coverage hole looks exactly like a dead device to the '
            'management system',
      ),
    ],
    fix:
        'Fix the layer the checks name: reserve the address or make it static, '
        'replace the cable/injector, raise the PoE budget/class, or correct the '
        'VLAN/ACL path to the management host. Update firmware only after the '
        'uptime and counters show the device itself is reloading.',
    rule:
        'Offline is power, link, address, management - in that order. Do not '
        'factory-reset a device before the port counters and the lease say '
        'which layer failed; the reset erases the only evidence you had.',
  ),

  DiagnosticPlaybook(
    id: 'gateway-unreachable',
    title: 'A host has an address but cannot ping its gateway',
    subjects: [
      'pc',
      'laptop',
      'host',
      'client',
      'workstation',
      'gateway',
      'default gateway',
    ],
    signals: [
      'cannot ping the gateway',
      'cannot ping my gateway',
      'cannot ping the default gateway',
      'gets an ip but cannot ping',
      'has an ip but cannot ping',
      'cannot reach the gateway',
      'can ping other hosts but not the gateway',
      'can ping the lan but not the gateway',
    ],
    meaning:
        'An address proves DHCP and the local broadcast domain worked; it '
        'does not prove the host can reach the router. A failed gateway ping is '
        'local: wrong VLAN or port, port security/802.1X, an SVI ACL, a '
        'duplicate address, proxy ARP, or the host firewall. The ARP entry is '
        'the fork in the road: no MAC means layer 2, a MAC but no reply means '
        'the gateway itself is dropping it.',
    causes: [
      'The access port is on the wrong VLAN, or the phone/NIC is passing an '
          'untagged frame into a voice VLAN, so the host is not in the subnet '
          'its address claims.',
      'Port security, 802.1X or DHCP snooping put the port in a restricted '
          'state after the address was assigned.',
      'A duplicate IP: another device answers ARP for the gateway address, or '
          'the host itself is using the gateway address.',
      'An ACL on the SVI or the router interface drops ICMP/ARP, often added '
          'with a management ACL and forgotten.',
      'A host firewall or VPN client owns the route and sends the gateway '
          'traffic into a tunnel instead of the physical link.',
      'Proxy ARP or a secondary subnet masks a wrong mask: the host thinks the '
          'gateway is on-link when it is not.',
    ],
    checks: [
      PlaybookCheck(
        '`ipconfig /all` or `ip addr` on the host: address, mask and default '
            'gateway',
        'a wrong mask makes a correct gateway look unreachable',
      ),
      PlaybookCheck(
        '`arp -a <gateway-ip>` on the host',
        'incomplete means the host never got an ARP reply (layer 2/VLAN); a MAC '
            'means the frame reached a device that did not answer',
      ),
      PlaybookCheck(
        'the switch MAC table for the host MAC and `show interface status`',
        'the port, VLAN and err-disabled/port-security state the host is '
            'actually using',
      ),
      PlaybookCheck(
        '`show ip interface brief`, `show ip arp <gateway-ip>` and `show ip '
            'interface <svi>` on the gateway',
        'whether the gateway sees the host and whether its SVI is up/up with an '
            'ACL',
      ),
      PlaybookCheck(
        'ping another host in the same subnet, then the gateway',
        'same-subnet success with gateway failure points at the SVI/ACL, not '
            'the access port',
      ),
    ],
    fix:
        'Correct the access VLAN and mask, clear the port-security/802.1X '
        'restriction, remove the duplicate address, or permit ARP/ICMP on the '
        'SVI. If the host firewall or a VPN client owns the route, fix the '
        'route before touching the switch.',
    rule:
        'An address without a gateway is a layer-2/ARP problem until `arp -a` '
        'shows a MAC. Read the ARP entry before you read the routing table.',
  ),
  DiagnosticPlaybook(
    id: 'device-reloads',
    title: 'A network device reloads or restarts by itself',
    subjects: [
      'router',
      'switch',
      'firewall',
      'asa',
      'ap',
      'access point',
      'controller',
      'device',
    ],
    signals: [
      'reloaded by itself',
      'reloads by itself',
      'rebooted by itself',
      'reboots by itself',
      'restarted on its own',
      'restarts on its own',
      'unexpected reload',
      'reloads randomly',
      'reboots randomly',
      'restarts randomly',
    ],
    meaning:
        'A device that reloads without a command leaves a reason behind: a '
        'power event, a crash, a watchdog, a scheduled reload, or an '
        'environmental fault. The uptime and the reload cause distinguish them, '
        'and the crashinfo/core file is the only evidence that survives a '
        'power cycle.',
    causes: [
      'Power: a failing PSU, a bad UPS transfer, or a circuit that also feeds '
          'a compressor. `show version` uptime and the PSU status tell you.',
      'Crash or watchdog: a software defect, a memory leak, or a process that '
          'stops responding. The crashinfo/core file and the last log lines '
          'before the reload name the process.',
      'Scheduled reload: `show reload` or a configuration archive job. It is '
          'the first thing to rule out because it is the cheapest to fix.',
      'Environmental: overtemperature, fan failure, or a voltage sensor. The '
          'environment status and the log show the thermal shutdown.',
      'A management action that looks automatic: an orchestrator, auto-upgrade '
          'job or power controller reloading the device on a schedule.',
    ],
    checks: [
      PlaybookCheck(
        '`show version` uptime and `show reload`',
        'whether the reload was scheduled and how long the device has actually '
            'been up',
      ),
      PlaybookCheck(
        '`show logging` around the reload, and the crashinfo/core files',
        'the last process or exception before the restart - the only cause '
            'that survives',
      ),
      PlaybookCheck(
        'PSU, fan and temperature status (`show environment`)',
        'a power or thermal event, which will repeat until the hardware is '
            'fixed',
      ),
      PlaybookCheck(
        'the orchestration/auto-upgrade scheduler and the config archive',
        'an automatic job that reloads the device on a timetable',
      ),
    ],
    fix:
        'Remove the scheduled reload or automatic job first. Replace the '
        'failing PSU/fan, fix the cooling, then upgrade the firmware only if '
        'the crashinfo names a known defect. Keep the crash file before you '
        'reload again.',
    rule:
        'A reload without a command has a reason in `show version`, `show '
        'reload` or the crashinfo. Read the reason before replacing hardware.',
  ),
  // __END__
];
