/// The senior networking corpus behind [NetworkingIntellect].
///
/// Each entry is written the way a strong network engineer answers: what it
/// is, how it actually works, when to use it, what it costs, the commands
/// that configure and verify it, and the mistakes that bite in production.
/// The fields are separate so the renderer can answer the *shape* of the
/// question - a definition, a why, a how-to, or a diagnosis - from the same
/// facts instead of replaying one canned blob.
///
/// This file is data only. Matching, calculations and rendering live in
/// `networking_intellect.dart`.
library;

class NetworkTech {
  final String id;
  final String name;
  final List<String> aliases;

  /// One sentence a colleague would accept as the answer.
  final String summary;

  /// The mechanism: what actually happens on the wire or in the control
  /// plane. This is where the depth lives.
  final String mechanism;

  final String whenToUse;
  final String tradeoffs;

  /// Configuration, when a command is the honest answer. Empty for topics
  /// that are design or architecture rather than CLI.
  final String commands;

  final String verify;

  /// Failure modes and the mistakes that are common in real deployments.
  final String pitfalls;

  /// Words that make this entry the right answer even when a broader
  /// concept answer already exists for the same protocol.
  final List<String> aspects;

  /// True when an existing concept answer owns the basic question, so this
  /// entry only answers a named aspect (for example BGP path selection).
  final bool conceptOwned;

  /// Extra comparison dimensions (port, standard, range, unit...).
  final Map<String, String> facts;

  const NetworkTech({
    required this.id,
    required this.name,
    required this.aliases,
    required this.summary,
    required this.mechanism,
    required this.whenToUse,
    required this.tradeoffs,
    this.commands = '',
    this.verify = '',
    this.pitfalls = '',
    this.aspects = const [],
    this.conceptOwned = false,
    this.facts = const {},
  });
}

/// Entries are ordered only for readability; matching is by alias.
const List<NetworkTech> networkCatalog = [
  NetworkTech(
    id: 'bgp',
    name: 'BGP',
    aliases: ['bgp', 'ebgp', 'ibgp', 'route reflector', 'as path'],
    summary:
        'BGP is the path-vector protocol that carries routes between '
        'autonomous systems; it picks paths by policy, not by speed.',
    mechanism:
        'eBGP peers open TCP 179 and exchange prefixes with attributes. The '
        'decision order is weight, local preference, locally originated, '
        'shortest AS_PATH, lowest origin, lowest MED, eBGP over iBGP, lowest '
        'IGP metric to the next hop, oldest route, lowest router ID. iBGP '
        'needs a full mesh or route reflectors; confederations are the other '
        'scaling option. `next-hop-self` matters because iBGP does not '
        'rewrite the next hop.',
    whenToUse:
        'At an ISP edge, between organizations, or in a policy-heavy core '
        'that needs traffic engineering. Inside one enterprise, OSPF or '
        'EIGRP converges faster and is simpler.',
    tradeoffs:
        'Very scalable and policy-rich, but deliberately slow to converge, '
        'easy to black-hole with one missing filter, and it needs explicit '
        'prefix limits and max-prefix protection.',
    commands:
        'router bgp 65001\n'
        ' bgp log-neighbor-changes\n'
        ' neighbor 10.0.0.2 remote-as 65002\n'
        ' neighbor 10.0.0.2 description ISP-A\n'
        ' network 192.0.2.0 mask 255.255.255.0\n'
        ' neighbor 10.0.0.2 route-map ISP-IN in\n'
        ' neighbor 10.0.0.2 maximum-prefix 500 80',
    verify:
        'show ip bgp summary (State/PfxRcd is a number, not Idle/Active), '
        'show ip bgp (the best path carries >), and show ip bgp neighbors '
        '10.0.0.2 advertised-routes.',
    pitfalls:
        'Advertising a prefix that is not in the routing table - network '
        'matches an exact IGP route by default. Forgetting next-hop-self on '
        'iBGP. Accepting a full table on a router that cannot hold it. '
        'Treating BGP as a fast-failover mechanism instead of using BFD.',
    aspects: [
      'path selection',
      'attribute',
      'route reflector',
      'community',
      'prefix limit',
      'next hop',
      'as path',
      'local preference',
      'med',
    ],
    conceptOwned: true,
    facts: {
      'Type': 'Path-vector EGP',
      'Transport': 'TCP 179',
      'Scope': 'Between autonomous systems',
      'Convergence': 'Policy-driven, seconds to minutes',
    },
  ),
  NetworkTech(
    id: 'ospf',
    name: 'OSPF',
    aliases: ['ospf'],
    summary:
        'OSPF is a link-state IGP: every router builds the same topology '
        'database and runs Dijkstra to install the shortest paths in an area.',
    mechanism:
        'Hellos (10 s on broadcast, 40 s dead) form adjacencies. Type 1 and 2 '
        'LSAs stay inside an area; ABRs inject type 3 summaries; ASBRs inject '
        'type 5 externals (type 7 inside NSSA). Cost is reference bandwidth '
        'divided by interface bandwidth - 10^8/BW by default, so Gigabit and '
        'faster all cost 1 until you raise auto-cost reference-bandwidth. '
        'On a broadcast segment a DR and BDR are elected by highest interface '
        'priority, then highest router ID; priority 0 never becomes DR.',
    whenToUse:
        'Multi-vendor enterprise routing with a hierarchy: keep area 0 '
        'small, put growth in areas, summarize at ABRs. A single area is '
        'right for labs and small campuses.',
    tradeoffs:
        'Open and well understood, but areas add design work and the default '
        'cost makes fast links tie. Fast convergence needs BFD or tuned '
        'timers, not defaults.',
    commands:
        'router ospf 1\n'
        ' router-id 1.1.1.1\n'
        ' network 10.10.0.0 0.0.0.255 area 0\n'
        ' passive-interface g0/2\n'
        ' auto-cost reference-bandwidth 10000\n'
        ' area 1 stub',
    verify:
        'show ip ospf neighbor (FULL), show ip ospf interface brief (cost), '
        'show ip route ospf, show ip ospf database.',
    pitfalls:
        'An MTU mismatch leaves neighbors stuck in EXSTART. Duplicate router '
        'IDs break adjacency. A stub area rejects type-5 LSAs. Summarizing '
        'too aggressively black-holes more-specific routes.',
    aspects: [
      'area',
      'lsa',
      'cost',
      'stub',
      'nssa',
      'summar',
      'election',
      'virtual link',
      'reference bandwidth',
    ],
    conceptOwned: true,
    facts: {
      'Type': 'Link-state IGP',
      'Algorithm': 'Dijkstra SPF',
      'Metric': 'Cost = reference BW / interface BW',
      'Transport': 'IP protocol 89',
    },
  ),
  NetworkTech(
    id: 'eigrp',
    name: 'EIGRP',
    aliases: ['eigrp'],
    summary:
        'EIGRP is a Cisco advanced distance-vector protocol whose DUAL '
        'algorithm keeps a loop-free backup path ready before a link fails.',
    mechanism:
        'Each router stores feasible distance (FD), advertised distance (AD) '
        'and the reported distance from each neighbor. A neighbor becomes a '
        'feasible successor only when its AD is lower than the local FD - the '
        'feasibility condition. The composite metric is bandwidth plus delay '
        'by default (256 x (10^7/min bandwidth + summed delay)), with K '
        'values for load and reliability. variance lets unequal-cost paths '
        'share traffic.',
    whenToUse:
        'An all-Cisco network that wants fast convergence, simple '
        'summarization per interface and unequal-cost load sharing.',
    tradeoffs:
        'Excellent convergence and easy summarization, but vendor lock-in, '
        'and the classic K-value/metric confusion causes more trouble than '
        'the protocol itself.',
    commands:
        'router eigrp 100\n'
        ' network 10.10.0.0 0.0.0.255\n'
        ' passive-interface g0/2\n'
        ' variance 2\n'
        ' eigrp stub connected summary',
    verify:
        'show ip eigrp neighbors, show ip eigrp topology (P and A entries), '
        'show ip route eigrp.',
    pitfalls:
        'A neighbor that is not a feasible successor forces a query, and '
        'queries that never answer leave the route active. Mismatched AS '
        'numbers or K values prevent adjacency. Summarizing at the wrong '
        'interface creates black holes.',
    aspects: [
      'feasible successor',
      'metric',
      'variance',
      'query',
      'stub',
      'dual',
      'k value',
    ],
    conceptOwned: true,
    facts: {
      'Type': 'Advanced distance-vector',
      'Algorithm': 'DUAL',
      'Metric': 'Bandwidth + delay (default K values)',
      'Transport': 'IP protocol 88',
    },
  ),
  NetworkTech(
    id: 'mpls',
    name: 'MPLS',
    aliases: [
      'mpls',
      'label switching',
      'ldp',
      'l3vpn',
      'pe router',
      'ce router',
    ],
    summary:
        'MPLS forwards by short labels instead of longest-prefix IP lookups, '
        'which is what lets one provider carry isolated customer VPNs.',
    mechanism:
        'At the edge (PE), a label is pushed onto the packet; provider (P) '
        'routers swap labels without inspecting the IP header; the egress PE '
        'pops the label (PHP). Labels are distributed by LDP or RSVP-TE, and '
        'the label stack can carry a VPN label plus a transport label. VRFs '
        'on the PE keep customer routes separate, with route targets '
        'controlling which VRFs import which routes.',
    whenToUse:
        'Provider or large-enterprise WANs that need traffic engineering, '
        'fast reroute, or many isolated L3VPNs over one core.',
    tradeoffs:
        'Excellent isolation and TE, but operationally heavy, label and MTU '
        'sensitive, and hard to troubleshoot without hop-by-hop label '
        'visibility. SD-WAN has replaced it for many branch use cases.',
    verify:
        'show mpls ldp neighbor, show mpls forwarding-table, show mpls ldp '
        'bindings, and a traceroute that shows label stacks.',
    pitfalls:
        'MTU on the core is smaller than the customer frame once labels are '
        'added. A broken LDP session silently removes labels for a prefix. '
        'Route targets that do not match leave a VRF empty with no obvious '
        'error.',
    facts: {
      'Layer': '2.5 (between L2 and L3)',
      'Label size': '4 bytes per entry',
      'Control plane': 'LDP, RSVP-TE, BGP (VPNv4/VPNv6)',
      'Typical use': 'Provider L3VPN, TE, FRR',
    },
  ),
  NetworkTech(
    id: 'vxlan',
    name: 'VXLAN',
    aliases: ['vxlan', 'vtep', 'vni', 'flood and learn'],
    summary:
        'VXLAN wraps layer-2 frames inside UDP so a layer-3 fabric can carry '
        'thousands of isolated segments; EVPN supplies the control plane.',
    mechanism:
        'A VTEP encapsulates the original frame with a VXLAN header carrying '
        'a 24-bit VNI, then outer UDP (destination 4789), IP and Ethernet. '
        'The underlay only needs IP reachability and ECMP; the overlay hides '
        'the layer-2 domain. BUM traffic is replicated per VTEP or handled by '
        'multicast, while EVPN (BGP address family 25) advertises MAC and IP '
        'reachability so flooding is not the default.',
    whenToUse:
        'Data-center fabrics, multi-tenant clouds and any design that needs '
        'many isolated L2 segments across a routed L3 underlay.',
    tradeoffs:
        'Huge scale and mobility, but 50 bytes of overhead (so raise the '
        'underlay MTU or clamp MSS), and troubleshooting now spans underlay '
        'and overlay.',
    verify:
        'show nve peers, show nve vni, show bgp l2vpn evpn, and a ping with '
        'the DF bit set to prove the underlay MTU.',
    pitfalls:
        'Underlay MTU left at 1500 - large frames vanish. A VNI mismatch '
        'between VTEPs isolates the segment. EVPN route targets that do not '
        'match the tenant. ARP flooding masked by EVPN until it is not.',
    facts: {
      'Encapsulation': 'MAC-in-UDP',
      'VNI space': '24 bits (about 16 million)',
      'Overhead': '50 bytes',
      'Control plane': 'EVPN (BGP) or flood-and-learn',
    },
  ),
  NetworkTech(
    id: 'sdwan',
    name: 'SD-WAN',
    aliases: ['sd-wan', 'sdwan', 'software defined wan', 'app-aware routing'],
    summary:
        'SD-WAN builds an encrypted overlay over any mix of MPLS, broadband '
        'and LTE, then steers each application by policy and live link quality.',
    mechanism:
        'Edge devices form IPsec tunnels to each other through a controller, '
        'which distributes policy and topology. The overlay measures loss, '
        'latency and jitter per path (often with BFD-style probes) and moves '
        'a flow to the best path when a SLA is missed. Local internet '
        'breakout sends SaaS traffic direct instead of back through the '
        'data center.',
    whenToUse:
        'Many branches, mixed WAN transports, and a need for application '
        'steering, local internet breakout or faster provisioning.',
    tradeoffs:
        'Cheaper and far more agile than MPLS, but it depends on underlay '
        'quality, adds a controller and licensing layer, and encryption '
        'plus probing overhead must be planned.',
    pitfalls:
        'Assuming SD-WAN fixes a bad underlay. Asymmetric paths breaking '
        'stateful firewalls. Overlay MTU smaller than the application frame. '
        'Controller unreachable during an upgrade.',
    facts: {
      'Overlay': 'IPsec (usually)',
      'Underlay': 'MPLS, broadband, LTE/5G',
      'Key idea': 'Policy and per-app path selection',
      'Replaces': 'Much of branch MPLS and DMVPN',
    },
  ),
  NetworkTech(
    id: 'redistribution',
    name: 'Route redistribution',
    aliases: ['redistribution', 'redistribute', 'mutual redistribution'],
    summary:
        'Redistribution injects routes from one routing protocol into another, '
        'and it is where most routing loops, suboptimal paths and seed-metric '
        'mistakes come from.',
    mechanism:
        'The router takes routes from the source protocol and advertises them '
        'into the target with a seed metric, because the target cannot infer '
        'a metric from another protocol. Administrative distance decides which '
        'source wins when both know a prefix. A route tag carried through the '
        'target lets the original protocol refuse its own route on the way '
        'back.',
    whenToUse:
        'Mergers, migrations, and any edge between a legacy IGP and a new one. '
        'Prefer one protocol end to end when you can.',
    tradeoffs:
        'Unavoidable in mixed networks, but every boundary needs filtering, '
        'seed metrics and usually tags; the complexity is in policy, not in '
        'the command.',
    commands:
        'router ospf 1\n'
        ' redistribute eigrp 100 subnets route-map EIGRP-TO-OSPF\n'
        'router eigrp 100\n'
        ' redistribute ospf 1 metric 10000 100 255 1 1500 route-map OSPF-TO-EIGRP\n'
        'route-map EIGRP-TO-OSPF permit 10\n'
        ' match tag 100\n'
        ' set tag 200',
    verify:
        'show ip route, show ip protocols (which sources are redistributed), '
        'and a traceroute toward both sides to catch a suboptimal exit.',
    pitfalls:
        'No seed metric means the route is not redistributed at all. Mutual '
        'redistribution without tags creates a loop that looks like flapping. '
        'Redistributing connected or static routes without a filter leaks '
        'management networks.',
    facts: {
      'Key settings': 'Seed metric, AD, route tag, filter',
      'Common fault': 'Feedback loop at two boundaries',
      'Best practice': 'One-way where possible, tag always',
    },
  ),
  NetworkTech(
    id: 'prefix-list',
    name: 'Prefix-list',
    aliases: ['prefix-list', 'prefix list', 'distribute-list'],
    summary:
        'A prefix-list matches routes by prefix and prefix length, is read top '
        'to bottom, and ends with an implicit deny.',
    mechanism:
        'Each line is permit or deny plus a network and optional ge/le '
        'length guards. `permit 10.0.0.0/8 ge 16 le 24` means any prefix that '
        'starts inside 10/8 and is between /16 and /24 - the ge/le pair is '
        'what makes it precise. A prefix-list does not match packet contents, '
        'only routes, which is why it is faster and safer than an ACL for '
        'routing policy.',
    whenToUse:
        'Filtering BGP updates, OSPF/EIGRP redistribute lists, and any route '
        'policy where the subject is a prefix rather than a packet.',
    tradeoffs:
        'Precise and efficient, but the implicit deny and the ge/le semantics '
        'are the two things people get wrong; test with show commands before '
        'applying on a live session.',
    commands:
        'ip prefix-list ALLOW-HQ seq 10 permit 10.10.0.0/16\n'
        'ip prefix-list ALLOW-HQ seq 20 deny 0.0.0.0/0 le 32\n'
        'router bgp 65001\n'
        ' neighbor 10.0.0.2 prefix-list ALLOW-HQ in',
    verify:
        'show ip prefix-list ALLOW-HQ, show ip bgp neighbors 10.0.0.2 '
        'received-routes, and show ip protocols for a distribute-list.',
    pitfalls:
        'Forgetting the final deny is implicit. Using `le 32` and expecting '
        'only the exact prefix. Applying an inbound BGP prefix-list without '
        'soft reconfiguration and then wondering why nothing refreshed.',
    facts: {
      'Matches': 'Routes, not packets',
      'Order': 'First match wins, implicit deny',
      'Length guards': 'ge = minimum, le = maximum',
    },
  ),
  NetworkTech(
    id: 'route-map',
    name: 'Route-map',
    aliases: ['route-map', 'route map', 'policy-based routing', 'pbr'],
    summary:
        'A route-map is an ordered policy: match conditions, then set actions, '
        'with the first matching sequence winning.',
    mechanism:
        'Sequences are evaluated in order. A permit sequence with a match '
        'that succeeds runs its set clauses; if no set clause exists it is a '
        'pure filter. A deny sequence stops evaluation immediately. Unlike a '
        'prefix-list, a route-map can change attributes - metric, tag, local '
        'preference, AS path, next hop - which makes it the tool for '
        'redistribution, BGP policy and PBR.',
    whenToUse:
        'Anywhere policy needs to change a route or a packet path, not just '
        'permit or deny it.',
    tradeoffs:
        'Powerful but stateful in the reader\'s head: sequence order, implicit '
        'deny, and whether a permit line with no match means everything are '
        'the usual sources of outages.',
    commands:
        'route-map SET-LP permit 10\n'
        ' match ip address prefix-list HQ-ROUTES\n'
        ' set local-preference 200\n'
        ' set community 65001:100 additive\n'
        'route-map PBR-VOICE permit 10\n'
        ' match ip address 110\n'
        ' set ip next-hop 10.0.0.2',
    verify:
        'show route-map, show ip bgp <prefix> (attributes changed as '
        'expected), and show ip policy for PBR interfaces.',
    pitfalls:
        'A route-map with only match clauses and no set is a filter - easy to '
        'forget. An empty permit sequence matches everything. PBR next-hop '
        'that is not recursively reachable drops the traffic.',
    facts: {
      'Order': 'Sequence number, first match wins',
      'Can change': 'Metric, tag, LP, MED, AS path, next hop',
      'Implicit': 'Deny at the end',
    },
  ),
  NetworkTech(
    id: 'admin-distance',
    name: 'Administrative distance and longest prefix match',
    aliases: [
      'administrative distance',
      'longest prefix match',
      'longest prefix',
      'route selection',
      'floating static',
    ],
    summary:
        'A router forwards by the longest matching prefix first; administrative '
        'distance only breaks ties between routes for the exact same prefix.',
    mechanism:
        'The forwarding table lookup is longest-prefix first: a /24 always '
        'beats a /16 for an address inside the /24, even if the /16 came from '
        'a supposedly better protocol. When two sources offer the same prefix, '
        'the lower administrative distance wins - connected 0, static 1, eBGP '
        '20, EIGRP 90, OSPF 110, IS-IS 115, RIP 120, iBGP 200. If distance is '
        'also equal, the protocol metric decides, and equal-cost paths can be '
        'installed for ECMP.',
    whenToUse:
        'Every route troubleshooting conversation, and deliberately when you '
        'build a floating static route that should take over only if the IGP '
        'route disappears.',
    tradeoffs:
        'The rule is simple; the confusion is that distance is a tie-breaker, '
        'not a global preference. A floating static needs a distance above '
        'the IGP or it will never be a backup.',
    commands:
        'ip route 0.0.0.0 0.0.0.0 10.0.0.1\n'
        'ip route 0.0.0.0 0.0.0.0 10.0.0.5 250',
    verify:
        'show ip route <address> shows the chosen prefix and its source; show '
        'ip route shows the codes and distances.',
    pitfalls:
        'Assuming a lower distance wins across different prefix lengths. '
        'Building a floating static with the default distance 1. Forgetting '
        'that a more-specific BGP route can override a summary static.',
    facts: {
      'First': 'Longest prefix match',
      'Second': 'Lowest administrative distance',
      'Third': 'Lowest metric, then ECMP',
      'Connected / static': '0 / 1 (default)',
    },
  ),
  NetworkTech(
    id: 'qos',
    name: 'QoS',
    aliases: [
      'qos',
      'dscp',
      'priority queue',
      'llq',
      'cbwfq',
      'shaping',
      'policing',
    ],
    summary:
        'QoS is four separate decisions - classify, mark, queue, and police or '
        'shape - and only the queueing stage can protect latency-sensitive '
        'traffic when a link is congested.',
    mechanism:
        'Classify as close to the source as possible, mark DSCP (EF 46 for '
        'voice, AF41 34 for video, CS3 for signaling), trust the marking on '
        'uplinks, and put each class in a queue. LLQ gives voice a strict '
        'priority queue with a policer; CBWFQ gives the rest bandwidth '
        'percentages. Policing drops or remarks above a rate; shaping buffers '
        'and delays. WRED drops low-priority packets early to avoid tail drop.',
    whenToUse:
        'Any WAN or uplink where voice, video and bulk traffic share a link, '
        'or where a provider hands you a rate limit you must not exceed.',
    tradeoffs:
        'It only matters under congestion, and badly marked traffic makes it '
        'worse. End-to-end QoS needs every hop to agree on the marking, which '
        'is an operational commitment, not a one-device config.',
    commands:
        'class-map match-any VOICE\n'
        ' match dscp ef\n'
        'policy-map WAN-EDGE\n'
        ' class VOICE\n'
        '  priority percent 20\n'
        ' class class-default\n'
        '  fair-queue\n'
        'interface g0/1\n'
        ' service-policy output WAN-EDGE',
    verify:
        'show policy-map interface g0/1 (class counters and drops), and show '
        'class-map / show policy-map to confirm the marking.',
    pitfalls:
        'Marking at the core instead of the edge, so the trust boundary is '
        'already lost. A strict priority queue without a policer starves '
        'everything else. Shaping on the LAN side of a provider rate limit '
        'does not stop the provider dropping.',
    aspects: [
      'policing',
      'shaping',
      'dscp',
      'queue',
      'priority',
      'trust',
      'congestion',
      'nbar',
      'marking',
      'markings',
      'verify the marking',
      'verify markings',
      'end to end',
      'over internet',
      'internet links',
      'wan links',
      'wan circuit',
    ],
    conceptOwned: true,
    facts: {
      'Voice DSCP': 'EF (46)',
      'Video DSCP': 'AF41 (34)',
      'Policing': 'Drops or remarks',
      'Shaping': 'Buffers and delays',
    },
  ),
  NetworkTech(
    id: 'dot1x',
    name: '802.1X',
    aliases: ['802.1x', 'dot1x', 'nac', 'supplicant'],
    summary:
        '802.1X authenticates a device or user before the switch lets it use '
        'the port - the wired equivalent of requiring a Wi-Fi password.',
    mechanism:
        'The supplicant (client) talks EAP over LAN to the authenticator '
        '(switch), which relays EAP to the authentication server (RADIUS). '
        'Until authentication succeeds the port is in an unauthorized state, '
        'limited to EAPOL; after success it can move to a dynamic VLAN or ACL. '
        'MAB falls back to the device MAC for printers and cameras that cannot '
        'run a supplicant. CoA lets the server change a session after login.',
    whenToUse:
        'Campus and office access where unknown devices must not get a live '
        'port, and as the identity layer under zero-trust segmentation.',
    tradeoffs:
        'Strong access control, but it needs a RADIUS server, a supplicant '
        'rollout, and a fallback plan for headless devices. A misconfigured '
        'fallback can lock out the IT team.',
    commands:
        'aaa new-model\n'
        'aaa authentication dot1x default group radius\n'
        'dot1x system-auth-control\n'
        'interface g1/0/10\n'
        ' switchport mode access\n'
        ' authentication port-control auto\n'
        ' dot1x pae authenticator\n'
        ' mab',
    verify:
        'show dot1x all, show authentication sessions, and the RADIUS server '
        'log for the accept/reject.',
    pitfalls:
        'No critical VLAN for the switch uplink - a RADIUS outage takes the '
        'whole site offline. MAB treated as strong authentication. Forgetting '
        'the EAPOL pass-through on a voice port.',
    facts: {
      'Roles': 'Supplicant, authenticator, auth server',
      'Transport': 'EAPOL (L2), RADIUS (L3)',
      'Fallback': 'MAB by MAC address',
      'Standard': 'IEEE 802.1X',
    },
  ),
  NetworkTech(
    id: 'radius',
    name: 'RADIUS',
    aliases: ['radius'],
    summary:
        'RADIUS is the UDP-based AAA protocol used for network access '
        'authentication - 802.1X, VPN and Wi-Fi logins.',
    mechanism:
        'The client (switch, WLC or VPN gateway) sends Access-Request with '
        'attributes; the server answers Access-Accept, Access-Challenge or '
        'Access-Reject. Accounting uses UDP 1813. Only the password field is '
        'encrypted with the shared secret; the rest of the attributes are '
        'protected only by the request authenticator. Vendor attributes carry '
        'VLAN, ACL and session-timeout instructions.',
    whenToUse:
        '802.1X, Wi-Fi enterprise authentication, VPN and any access control '
        'where the server must return network attributes, not just a yes/no.',
    tradeoffs:
        'Universally supported and attribute-rich, but UDP, only the password '
        'is hidden, and per-command authorization is not its job.',
    commands:
        'radius server ISE\n'
        ' address ipv4 10.10.0.20 auth-port 1812 acct-port 1813\n'
        ' key 7 <secret>',
    verify:
        'test aaa group radius <user> <password> new-code, plus the server\'s '
        'live log.',
    pitfalls:
        'Shared-secret mismatch is the classic silent failure. Using RADIUS '
        'for per-command authorization it was not designed for. Letting '
        'accounting fill the disk.',
    facts: {
      'Transport': 'UDP 1812/1813',
      'Encrypts': 'Password only',
      'Best at': 'Network access attributes',
      'Standard': 'RFC 2865/2866',
    },
  ),
  NetworkTech(
    id: 'tacacs',
    name: 'TACACS+',
    aliases: ['tacacs', 'tacacs+'],
    summary:
        'TACACS+ is the TCP-based AAA protocol Cisco devices use for '
        'administrative login and per-command authorization.',
    mechanism:
        'The NAS sends an authentication start, then authorization requests '
        'per command or service, then accounting records. The whole payload is '
        'encrypted with the shared key, not just the password. That per-command '
        'model is why it can permit `show` but deny `configure terminal` for '
        'the same user.',
    whenToUse:
        'Device administration: router and switch logins, privilege levels, '
        'command authorization and command accounting.',
    tradeoffs:
        'Best-in-class command control and full payload encryption, but '
        'Cisco-centric, TCP 49 (often blocked by firewalls), and it needs a '
        'server '
        'that understands per-command policy.',
    commands:
        'aaa new-model\n'
        'tacacs server TAC1\n'
        ' address ipv4 10.10.0.30\n'
        ' key <secret>\n'
        'aaa authentication login default group tacacs+ local\n'
        'aaa authorization exec default group tacacs+ local\n'
        'aaa accounting commands 15 default start-stop group tacacs+',
    verify:
        'show tacacs, then a real login; the server log shows the command '
        'authorization decisions.',
    pitfalls:
        'No local fallback - a server outage locks every admin out. TCP 49 '
        'blocked by a firewall. Sending only authentication and expecting '
        'per-command authorization to work.',
    facts: {
      'Transport': 'TCP 49',
      'Encrypts': 'Entire payload',
      'Best at': 'Per-command authorization',
      'Typical use': 'Device administration',
    },
  ),
  NetworkTech(
    id: 'ipsec',
    name: 'IPsec',
    aliases: ['ipsec', 'ike', 'ikev2', 'esp', 'ah', 'nat-t'],
    summary:
        'IPsec protects IP packets with ESP encryption and integrity, with IKE '
        'negotiating the keys and security associations.',
    mechanism:
        'IKE phase 1 builds a secure channel (ISAKMP/IKE SA), phase 2 builds '
        'the IPsec SA for the data. ESP provides confidentiality and integrity; '
        'AH provides integrity only and breaks through NAT. Tunnel mode wraps '
        'the whole original packet; transport mode protects the payload only. '
        'Perfect forward secrecy gives each new SA fresh key material. NAT-T '
        'encapsulates ESP in UDP 4500.',
    whenToUse:
        'Site-to-site VPNs, remote-access gateways, and any traffic that must '
        'cross an untrusted network with confidentiality and integrity.',
    tradeoffs:
        'Standards-based and strong, but the two-phase configuration is easy to '
        'mirror incorrectly, MTU overhead is real, and troubleshooting is '
        'crypto-policy-by-crypto-policy.',
    verify:
        'show crypto isakmp sa (QM/MM state), show crypto ipsec sa (packets '
        'encapsulated/decapsulated), and a ping across the tunnel with the DF '
        'bit set.',
    pitfalls:
        'Mismatched transform sets or pre-shared keys. ACLs that do not mirror '
        'on both peers. MTU 1500 inside a tunnel without MSS clamping. '
        'Assuming AH survives NAT.',
    facts: {
      'IKE': 'UDP 500, NAT-T 4500',
      'Data': 'ESP (IP protocol 50)',
      'Modes': 'Tunnel and transport',
      'Overhead': 'About 50-73 bytes with ESP tunnel',
    },
  ),
  NetworkTech(
    id: 'firewall',
    name: 'Firewall',
    aliases: [
      'firewall',
      'stateful inspection',
      'ngfw',
      'security zone',
      'dmz',
    ],
    summary:
        'A firewall enforces a policy between zones and, if it is stateful, '
        'lets the return traffic of an allowed flow back without a second rule.',
    mechanism:
        'Rules are evaluated top to bottom per direction and zone pair. A '
        'stateful firewall records the flow in a session table, so the reply '
        'from an inside host is permitted even though there is no inbound '
        'rule. A DMZ is a third zone for public services: outside may reach '
        'the published port, the DMZ may reach outside for updates, and the '
        'DMZ may not initiate into the inside.',
    whenToUse:
        'Every internet edge, and between trust levels inside the network '
        '(users, servers, management, guest, OT).',
    tradeoffs:
        'State gives real protection and simpler rules, but asymmetric routing '
        'breaks it, and a single pair is a single point of failure. NGFW '
        'features (app-ID, IPS, TLS inspection) cost CPU and create privacy '
        'and certificate work.',
    commands:
        'object network WEB-SERVER\n'
        ' host 192.0.2.10\n'
        'nat (dmz,outside) static 203.0.113.10\n'
        'access-list OUTSIDE-IN extended permit tcp any object WEB-SERVER eq 443\n'
        'access-group OUTSIDE-IN in interface outside',
    verify:
        'show conn (live sessions), show access-list (hit counters), and a '
        'packet-tracer/Azure-style flow test before production.',
    pitfalls:
        'A permit at the top that shadows later denies. Rules added for the '
        'return path in a stateful firewall. No logging on the default deny. '
        'Forgetting that the DMZ needs its own egress policy.',
    aspects: ['dmz', 'stateful', 'zone', 'ngfw', 'policy', 'rule', 'session'],
    facts: {
      'Stateful': 'Tracks flows in a session table',
      'DMZ': 'Public services in their own zone',
      'Default': 'Deny, with logging',
      'Failure mode': 'Asymmetric routing breaks state',
    },
  ),
  NetworkTech(
    id: 'ids',
    name: 'IDS',
    aliases: ['ids', 'intrusion detection'],
    summary:
        'An IDS detects and alerts on malicious traffic but does not sit in the '
        'forwarding path, so it cannot block what it sees.',
    mechanism:
        'Sensors receive a copy of traffic from a SPAN port or TAP and match '
        'it against signatures and anomaly models. Because the copy is passive, '
        'an alert is forensic: the attack already happened. It is the right '
        'tool when you need visibility without risking an outage.',
    whenToUse:
        'Monitoring a segment where a false positive must never drop traffic, '
        'or as a second layer beside inline prevention.',
    tradeoffs:
        'No outage risk and good evidence, but no prevention, and encrypted '
        'traffic is invisible without decryption.',
    verify:
        'Check sensor interface drops, signature update age, and alert '
        'quality - a noisy sensor is an ignored sensor.',
    pitfalls:
        'Tuning by disabling signatures instead of scoping them. A SPAN port '
        'that oversubscribes and silently drops. Treating an alert as proof '
        'of compromise.',
    facts: {
      'Placement': 'Out of band (SPAN/TAP)',
      'Action': 'Alert only',
      'Blind spot': 'Encrypted traffic',
    },
  ),
  NetworkTech(
    id: 'ips',
    name: 'IPS',
    aliases: ['ips', 'intrusion prevention'],
    summary:
        'An IPS sits inline and can drop or reset malicious traffic in real '
        'time, which also means a bad signature can break good traffic.',
    mechanism:
        'Traffic passes through the engine, which reassembles flows, matches '
        'signatures and protocol anomalies, and applies an action: alert, '
        'drop, reset or block for a timeout. Inline placement gives prevention '
        'but adds latency and a failure domain.',
    whenToUse:
        'North-south internet edges and critical internal boundaries where '
        'blocking is worth the operational risk.',
    tradeoffs:
        'Real prevention, but latency, throughput cost, false positives and '
        'the need for a bypass/fail-open decision.',
    verify:
        'Inline interface pair state, drop counters by signature, and a '
        'deliberate test signature in a maintenance window.',
    pitfalls:
        'Deploying in block mode without a tuning period. No bypass pair, so '
        'the IPS becomes the outage. Ignoring TLS inspection coverage.',
    facts: {
      'Placement': 'Inline',
      'Action': 'Drop/reset/block',
      'Cost': 'Latency and false positives',
    },
  ),
  NetworkTech(
    id: 'zero-trust',
    name: 'Zero trust',
    aliases: ['zero trust', 'ztna', 'least privilege'],
    summary:
        'Zero trust is an operating model: authenticate and authorize every '
        'access request from a known device and identity, and grant the least '
        'privilege needed for that session.',
    mechanism:
        'It combines strong identity (MFA, SSO), device posture, policy '
        'enforcement points (ZTNA proxy, firewall, 802.1X, microsegmentation) '
        'and continuous logging. The network is no longer trusted because a '
        'packet came from inside; east-west traffic is segmented by workload '
        'or user role, and access is brokered per application rather than by '
        'VPN into a flat subnet.',
    whenToUse:
        'Remote and hybrid work, SaaS access, and any environment where a '
        'flat inside network would let one compromised laptop reach everything.',
    tradeoffs:
        'It reduces blast radius and enables remote access without a full '
        'tunnel, but it is a multi-year program, needs an identity source of '
        'truth, and application discovery is the hard part.',
    pitfalls:
        'Buying a product and calling it a strategy. Segmenting the network '
        'but leaving shared admin credentials. No inventory, so the policy '
        'cannot name what it protects.',
    facts: {
      'Core idea': 'Never trust, always verify',
      'Enablers': 'Identity, posture, segmentation, logging',
      'Not': 'A single product',
    },
  ),
  NetworkTech(
    id: 'load-balancer',
    name: 'Load balancer',
    aliases: [
      'load balancer',
      'load balancing',
      'adc',
      'l4 load balancer',
      'l7 load balancer',
    ],
    summary:
        'A load balancer spreads client traffic across healthy backends and, at '
        'layer 7, can route by URL, host or header.',
    mechanism:
        'A virtual IP receives the connection and a pool holds the real '
        'servers. Layer 4 balances TCP/UDP by five-tuple; layer 7 terminates '
        'or inspects HTTP and can send /api to one pool and /images to '
        'another. Health checks remove dead members, persistence keeps a '
        'client on the same server when state demands it, and TLS can '
        'terminate at the balancer or pass through.',
    whenToUse:
        'Any service with more than one backend, TLS offload, blue-green '
        'deployment, or a need for health-based failover.',
    tradeoffs:
        'Removes a single server as a failure point and enables scaling, but '
        'it becomes a critical path itself, adds a certificate and DNS layer, '
        'and persistence can defeat even balancing.',
    verify:
        'Pool member health, connection distribution per backend, and a '
        'synthetic request through the VIP from outside the subnet.',
    pitfalls:
        'Health check passing on a login page while the API is broken. '
        'Source-IP persistence concentrating traffic. No SNAT, so return '
        'traffic bypasses the balancer. TLS terminated in two places.',
    facts: {
      'L4': 'TCP/UDP five-tuple',
      'L7': 'HTTP host/path/header',
      'Key settings': 'Health check, persistence, TLS',
      'Algorithms': 'Round robin, least connections, hash',
    },
  ),
  NetworkTech(
    id: 'poe',
    name: 'PoE',
    aliases: ['poe', 'power over ethernet', '802.3af', '802.3at', '802.3bt'],
    summary:
        'PoE delivers DC power over the same Ethernet cable as data, which is '
        'why access points, cameras and phones need no local power outlet.',
    mechanism:
        'The power sourcing equipment (PSE - switch) detects a valid powered '
        'device (PD), negotiates a class, and delivers power on the spare '
        'pairs or over the data pairs. 802.3af gives up to 15.4 W at the PSE '
        '(about 12.95 W at the PD), 802.3at (PoE+) up to 30 W, and 802.3bt up '
        'to 60 W on two pairs or 90 W on four. The switch has a total budget, '
        'not just a per-port limit.',
    whenToUse:
        'Ceiling APs, IP cameras, desk phones, and any device where a local '
        'power outlet is expensive or unavailable.',
    tradeoffs:
        'One cable and central UPS backup, but cable heating, voltage drop on '
        'long runs, and a finite switch budget that is easy to exceed.',
    commands:
        'show power inline\n'
        'show power inline g1/0/10 detail\n'
        'power inline auto\n'
        'power inline static max 30000',
    verify:
        'show power inline shows the allocated and remaining budget per port; '
        'the PD should draw within its class.',
    pitfalls:
        'Counting only per-port watts and ignoring the switch budget. Long or '
        'thin cable causing the PD to reset. A non-PoE injector on a port that '
        'expects negotiation. 802.3bt four-pair PDs on two-pair cabling.',
    facts: {
      '802.3af': 'Up to 15.4 W (PoE)',
      '802.3at': 'Up to 30 W (PoE+)',
      '802.3bt': 'Up to 60/90 W (4PPoE)',
      'Limit': 'Switch total power budget',
    },
  ),
  NetworkTech(
    id: 'wifi',
    name: 'Wi-Fi design',
    aliases: ['wifi', 'wi-fi', 'wireless', '802.11', 'access point', 'ssid'],
    summary:
        'Wi-Fi is a shared, half-duplex medium: design for coverage and channel '
        'reuse first, then add access points for capacity, not for signal bars.',
    mechanism:
        '2.4 GHz uses channels 1/6/11 at 20 MHz; 5 GHz has many non-overlapping '
        'channels including DFS; 6 GHz (Wi-Fi 6E/7) adds clean 160 MHz channels. '
        'Wider channels raise peak rate but reduce reuse and increase '
        'co-channel interference. Clients roam when the new AP is roughly 10-15 '
        'dB better, helped by 802.11k/v/r. Capacity is airtime per AP, not '
        'advertised PHY rate.',
    whenToUse:
        'Every office, school and warehouse. Do a site survey or at least a '
        'post-install validation; place APs on ceilings, not in closets.',
    tradeoffs:
        'Convenience and mobility, but unpredictable RF, shared airtime, and a '
        'design that must be revisited when walls, stock or client density '
        'change.',
    verify:
        'A survey tool showing SNR (25 dB or better), channel overlap, and '
        'per-AP client counts; a real roaming test with a call in progress.',
    pitfalls:
        'Using 40 MHz on 2.4 GHz. Every AP on channel 1. Adding APs to fix a '
        'capacity problem without lowering power. Treating mesh as equivalent '
        'to wired backhaul.',
    aspects: [
      'channel',
      'roam',
      '6 ghz',
      'six ghz',
      'capacity',
      'survey',
      'snr',
      'band steering',
      'coverage',
    ],
    conceptOwned: true,
    facts: {
      '2.4 GHz': '3 non-overlapping channels',
      '5 GHz': 'Many channels, some DFS',
      '6 GHz': 'Wi-Fi 6E/7, no legacy',
      'Coverage target': 'About -67 dBm, SNR 25 dB',
    },
  ),
  NetworkTech(
    id: 'wpa2',
    name: 'WPA2',
    aliases: ['wpa2', 'ccmp'],
    summary:
        'WPA2 uses AES-CCMP and is still acceptable, but its WPA2-Personal '
        'handshake can be captured and attacked offline.',
    mechanism:
        'WPA2-Enterprise runs 802.1X/EAP for per-user credentials and key '
        'material; WPA2-Personal derives keys from a shared passphrase via the '
        'four-way handshake. CCMP provides confidentiality and integrity. The '
        'PMKID/four-way capture enables offline dictionary attacks against weak '
        'passphrases.',
    whenToUse:
        'Existing clients that do not support WPA3, or a mixed estate during '
        'migration.',
    tradeoffs:
        'Universally supported and fast, but no forward secrecy and weaker '
        'protection against offline guessing than SAE.',
    pitfalls:
        'A short or shared passphrase across sites. TKIP left enabled for old '
        'clients. No management-frame protection, so deauth attacks still work.',
    aspects: ['ccmp', 'psk', 'four-way', 'enterprise'],
    conceptOwned: true,
    facts: {
      'Encryption': 'AES-CCMP',
      'Personal': 'Pre-shared key',
      'Enterprise': '802.1X/EAP',
      'Weakness': 'Offline guessing of the handshake',
    },
  ),
  NetworkTech(
    id: 'wpa3',
    name: 'WPA3',
    aliases: ['wpa3', 'sae', 'pmf', 'protected management frames'],
    summary:
        'WPA3 replaces the pre-shared-key handshake with SAE, which resists '
        'offline guessing, and makes protected management frames mandatory.',
    mechanism:
        'SAE (Simultaneous Authentication of Equals) is a password-authenticated '
        'key exchange: each session derives fresh keys and an observer cannot '
        'test guesses offline. WPA3-Enterprise can use 192-bit suites. PMF '
        'protects deauth and disassociate frames, so trivial deauth attacks '
        'stop working. Transition mode still allows WPA2 clients.',
    whenToUse:
        'New deployments and any network where guest or PSK Wi-Fi is exposed to '
        'the public.',
    tradeoffs:
        'Much better password and management-frame protection, but older '
        'clients may not join, and transition mode weakens the guarantee.',
    pitfalls:
        'Turning on transition mode and believing you have WPA3 everywhere. A '
        'weak passphrase still weakens SAE. Assuming WPA3 encrypts the whole '
        'management plane - it protects specific frames.',
    aspects: ['sae', 'pmf', '192', 'enterprise', 'transition'],
    facts: {
      'Handshake': 'SAE (dragonfly)',
      'Management frames': 'PMF mandatory',
      'Enterprise': 'Up to 192-bit',
      'Backward compatibility': 'Transition mode',
    },
  ),
  NetworkTech(
    id: 'single-mode',
    name: 'Single-mode fiber',
    aliases: ['single mode', 'single-mode', 'smf', 'os2'],
    summary:
        'Single-mode fiber has a tiny core and carries one light path, which is '
        'why it reaches kilometers where copper and multimode cannot.',
    mechanism:
        'A 9-micron core with a laser source (often 1310 or 1550 nm) avoids '
        'modal dispersion, so distance is limited by optical budget rather than '
        'by the fiber type: 10 km with standard LR optics, 40-80 km with ER/ZR '
        'and the right budget. It is the normal choice between buildings and '
        'for ISP handoffs.',
    whenToUse:
        'Runs beyond a few hundred meters, between buildings, and any backbone '
        'where future 10/25/40/100G upgrades are expected.',
    tradeoffs:
        'Best distance and future capacity, but the optics cost more and the '
        'connector/termination work needs care; a dirty end face is the most '
        'common failure.',
    facts: {
      'Core': 'About 9 microns',
      'Light source': 'Laser (1310/1550 nm)',
      'Typical reach': '10-80 km',
      'Best for': 'Building-to-building, ISP uplinks',
    },
  ),
  NetworkTech(
    id: 'multimode',
    name: 'Multimode fiber',
    aliases: ['multimode', 'multi-mode', 'mmf', 'om3', 'om4', 'om5'],
    summary:
        'Multimode fiber uses a wider core and inexpensive VCSEL optics for '
        'short runs inside a building or data center.',
    mechanism:
        'A 50- or 62.5-micron core carries several light paths; modal dispersion '
        'limits reach. OM3 is rated for 300 m at 10G, OM4 for 400 m, OM5 adds '
        'wideband shortwave division multiplexing. SR optics are cheaper than '
        'single-mode LR optics, which is why multimode dominates within a room '
        'or a floor.',
    whenToUse:
        'Data-center and intra-building runs up to a few hundred meters, '
        'especially where many 10/25G links are needed at low cost.',
    tradeoffs:
        'Cheap optics and easy termination, but limited distance and a modal '
        'bandwidth ceiling; mixing OM3 and OM4 is fine, but old 62.5-micron '
        'plant can bottleneck the link.',
    facts: {
      'Core': '50 or 62.5 microns',
      'Light source': 'VCSEL (850 nm)',
      'Typical reach': '300-400 m at 10G',
      'Best for': 'Data center, intra-building',
    },
  ),
  NetworkTech(
    id: 'cat6',
    name: 'Cat6',
    aliases: ['cat6', 'cat 6', 'category 6'],
    summary:
        'Cat6 copper supports 1G to 100 m and 10G to about 55 m, which makes it '
        'the default desk and access-point cable.',
    mechanism:
        'Four twisted pairs with tighter twist and better crosstalk control '
        'than Cat5e. At 10GBASE-T it is limited to roughly 55 m because alien '
        'crosstalk rises with frequency; the exact limit depends on installation '
        'and bundle size.',
    whenToUse:
        'Desk runs, access points and cameras inside one building where the run '
        'is under 55 m if 10G is a real requirement.',
    tradeoffs:
        'Cheap, familiar and PoE-capable, but 10G at full 100 m needs Cat6a. '
        'Cheap patch cables and bad terminations fail at 1G first.',
    facts: {
      '1G': '100 m',
      '10G': 'About 55 m',
      'PoE': 'Yes',
      'Connector': 'RJ45',
    },
  ),
  NetworkTech(
    id: 'cat6a',
    name: 'Cat6a',
    aliases: ['cat6a', 'cat 6a', 'category 6a', 'cat7', 'cat8'],
    summary:
        'Cat6a is shielded or tighter-spec copper rated for 10G at the full '
        '100 m channel.',
    mechanism:
        'Higher specification and usually a foil shield around pairs or the '
        'cable; that shield must be bonded and grounded at both ends or it '
        'becomes an antenna. Cat8 goes further for 25/40G but only to 30 m and '
        'is a data-center cable, not a desk cable.',
    whenToUse:
        'New builds that expect 10G to the desk or AP, long 10G runs, and '
        'backbones inside a building.',
    tradeoffs:
        'Future-proof and full-distance 10G, but thicker, stiffer, more '
        'expensive and requires proper shielded termination and grounding.',
    facts: {
      '1G': '100 m',
      '10G': '100 m',
      'Shield': 'Usually F/UTP or S/FTP',
      'Cat8': '25/40G to 30 m',
    },
  ),
  NetworkTech(
    id: 'stp',
    name: 'Spanning Tree',
    aliases: [
      'spanning tree',
      'pvst',
      'rapid-pvst',
      'mst',
      'root guard',
      'bpdu guard',
    ],
    summary:
        'Spanning Tree blocks redundant layer-2 paths so a loop cannot multiply '
        'broadcasts forever; RSTP and MSTP are the versions worth designing with.',
    mechanism:
        'Switches elect one root by lowest bridge ID (priority, then MAC). '
        'Every other switch picks one root port, and each segment one designated '
        'port; the rest are alternate/blocking. Classic STP converges in 30-50 s '
        'through listening and learning; RSTP uses port roles and '
        'proposal/agreement to converge in seconds. MSTP maps VLANs to '
        'instances so you '
        'do not need one tree per VLAN. PortFast skips the waiting states on '
        'access ports; BPDU Guard shuts a port that unexpectedly sends BPDUs; '
        'Root Guard stops a downstream switch from becoming root. Bridge ID is '
        'compared in two parts: priority first (default 32768, in steps of '
        '4096) and the MAC only breaks a tie, which is why a design that never '
        'sets a priority makes the oldest switch root. Path cost is cumulative '
        '- 10 Gbps costs 2, 1 Gbps 4, 100 Mbps 19 - so the root port is the '
        'lowest total cost, not the fewest hops. In MST the region name, '
        'revision and VLAN-to-instance map must match exactly, or the switches '
        'form separate regions and loop protection quietly stops agreeing.',
    whenToUse:
        'Every layer-2 domain with redundant links. In a routed leaf-spine '
        'fabric, STP is mostly a safety net rather than the primary design.',
    tradeoffs:
        'Simple and vendor-neutral, but it deliberately leaves capacity unused, '
        'and a topology change can flush MAC tables across the domain.',
    commands:
        'spanning-tree mode rapid-pvst\n'
        'spanning-tree vlan 10 root primary\n'
        'interface g1/0/10\n'
        ' spanning-tree portfast\n'
        ' spanning-tree bpduguard enable',
    verify:
        'show spanning-tree vlan 10 (root and port roles), show spanning-tree '
        'summary, and a deliberate loop test in a lab only.',
    pitfalls:
        'PortFast on a switch-to-switch link. No BPDU Guard on access ports, so '
        'a user switch creates a loop. Root priority left at default and the '
        'oldest access switch becomes root. Mixing PVST and MST without a '
        'migration plan.',
    aspects: [
      'root',
      'guard',
      'mst',
      'rstp',
      'portfast',
      'priority',
      'election',
    ],
    conceptOwned: true,
    facts: {
      'Elects': 'Root by lowest bridge ID',
      'RSTP': 'Seconds, port roles',
      'MSTP': 'VLANs mapped to instances',
      'Safety': 'BPDU Guard, Root Guard, Loop Guard',
    },
  ),
  NetworkTech(
    id: 'vtp',
    name: 'VTP',
    aliases: ['vtp', 'vlan trunking protocol'],
    summary:
        'VTP propagates VLAN definitions between switches, and its revision '
        'number is why a rogue switch can delete every VLAN in the domain.',
    mechanism:
        'A server holds the VLAN database and advertises it to clients over '
        'trunks; a higher configuration revision always wins, regardless of '
        'which switch is correct. Transparent mode relays advertisements but '
        'does not apply them; off disables the protocol entirely.',
    whenToUse:
        'Rarely. Transparent mode if a legacy design requires it; otherwise '
        'define VLANs from automation or a template.',
    tradeoffs:
        'Convenient at first, but the revision-number failure mode is severe '
        'and the protocol is not needed in a modern template-driven network.',
    pitfalls:
        'Connecting a lab switch with a higher revision into production. No '
        'VTP password. Assuming transparent mode still synchronizes VLANs.',
    facts: {
      'Modes': 'Server, client, transparent, off',
      'Decides': 'Highest revision number',
      'Risk': 'VLAN database wipe',
    },
  ),
  NetworkTech(
    id: 'fhrp',
    name: 'First-hop redundancy (HSRP/VRRP/GLBP)',
    aliases: [
      'hsrp',
      'vrrp',
      'glbp',
      'first hop redundancy',
      'gateway redundancy',
    ],
    summary:
        'A first-hop redundancy protocol gives hosts one virtual gateway address '
        'that survives the failure of the router currently answering for it.',
    mechanism:
        'HSRP has active and standby routers, a virtual IP and MAC, and preempt '
        'plus interface tracking to move the active role deliberately. VRRP is '
        'the standards-based equivalent with a master and backups (RFC 5798) and '
        'works multi-vendor. GLBP adds active virtual forwarders so several '
        'routers can share the load. Hosts keep one gateway and never see the '
        'failover.',
    whenToUse:
        'Any subnet with two or more routers where the gateway cannot be a '
        'single point of failure.',
    tradeoffs:
        'Hardware failure becomes a sub-second event, but the protocol adds '
        'virtual MACs, tracking design and a split-brain risk if the peers '
        'cannot hear each other.',
    commands:
        'interface g0/1\n'
        ' standby 10 ip 192.168.10.254\n'
        ' standby 10 priority 150\n'
        ' standby 10 preempt\n'
        ' standby 10 track 1 decrement 60\n'
        'interface g0/1\n'
        ' vrrp 10 ip 192.168.10.254',
    verify:
        'show standby brief or show vrrp brief - one Active/Master and one '
        'Standby/Backup, with tracking state visible.',
    pitfalls:
        'Both routers active because the L2 path between them is broken. '
        'Preempt off on the router you expected to take over. Tracking the '
        'wrong interface, so the gateway moves while the path does not.',
    aspects: ['standby', 'virtual ip', 'glbp', 'track', 'preempt', 'master'],
    conceptOwned: true,
    facts: {
      'HSRP': 'Cisco active/standby',
      'VRRP': 'Standard master/backup',
      'GLBP': 'Load-sharing gateways',
      'Virtual IP': 'Shared by the group',
    },
  ),
  NetworkTech(
    id: 'tcp',
    name: 'TCP',
    aliases: [
      'tcp',
      'three-way handshake',
      'window scaling',
      'congestion control',
    ],
    summary:
        'TCP gives a reliable, ordered byte stream by acknowledging data, '
        'retransmitting loss and adapting its sending rate to the path.',
    mechanism:
        'A connection opens with SYN, SYN-ACK, ACK. Sequence and acknowledgement '
        'numbers track every byte; the receive window advertises buffer space '
        'and window scaling lets it exceed 64 KB. Slow start grows the '
        'congestion window exponentially, congestion avoidance grows it '
        'linearly, and fast recovery retransmits after duplicate ACKs. '
        'Throughput for one flow is bounded by window divided by round-trip '
        'time, which is why latency hurts more than raw bandwidth for a single '
        'session.',
    whenToUse:
        'Anything that must not lose or reorder data: web, SSH, file transfer, '
        'API calls, database sessions.',
    tradeoffs:
        'Reliability and flow control, but head-of-line blocking and a slow '
        'start after every new connection; loss on a long fat path can cut '
        'throughput far below the link rate.',
    verify:
        'A capture showing the handshake, retransmissions and zero-window '
        'events; on the host, ss -ti or netstat -s shows retransmit and window '
        'counters.',
    pitfalls:
        'Blaming the application for retransmissions caused by loss. A tiny '
        'receive window or no window scaling on a high-RTT path. Middleboxes '
        'that drop SYN or rewrite MSS.',
    aspects: [
      'window',
      'throughput',
      'handshake',
      'retransmit',
      'congestion',
      'mss',
    ],
    conceptOwned: true,
    facts: {
      'Reliability': 'ACKs and retransmission',
      'Ordering': 'Sequence numbers',
      'Flow control': 'Receive window',
      'Congestion control': 'Slow start, AIMD',
    },
  ),
  NetworkTech(
    id: 'udp',
    name: 'UDP',
    aliases: ['udp', 'datagram'],
    summary:
        'UDP is a minimal datagram transport: no handshake, no retransmission, '
        'no ordering - the application owns reliability if it needs it.',
    mechanism:
        'A UDP header carries source port, destination port, length and checksum. '
        'That is all. DNS, DHCP, RADIUS, SNMP, VoIP media, QUIC and most '
        'real-time traffic use it because a late packet is worse than a lost one '
        'and the application can recover or tolerate loss itself.',
    whenToUse:
        'Real-time media, short request/response protocols, discovery and any '
        'case where the application implements its own reliability or does not '
        'need it.',
    tradeoffs:
        'Low overhead and no head-of-line blocking, but no congestion control '
        'by default, so a careless UDP flow can crowd out TCP; spoofing is also '
        'easier because there is no handshake.',
    facts: {
      'Header': '8 bytes',
      'Reliability': 'None',
      'Ordering': 'None',
      'Used by': 'DNS, DHCP, RADIUS, VoIP, QUIC',
    },
  ),
  NetworkTech(
    id: 'mtu',
    name: 'MTU and MSS',
    aliases: ['mtu', 'mss', 'pmtud', 'fragmentation', 'jumbo frames'],
    summary:
        'MTU is the largest IP packet an interface will send; MSS is the TCP '
        'payload that fits after the IP and TCP headers, and tunnels shrink both.',
    mechanism:
        'Ethernet defaults to 1500 bytes. A tunnel adds outer headers - GRE 24, '
        'IPsec tunnel about 50-73, VXLAN 50, PPPoE 8 - so the inner MTU must be '
        'smaller or the packet is dropped when the DF bit is set. Path MTU '
        'discovery relies on ICMP fragmentation-needed messages; when a firewall '
        'blocks them you get a PMTUD black hole (small pings work, large '
        'transfers hang). MSS clamping rewrites the SYN so both ends size their '
        'segments to fit.',
    whenToUse:
        'Every tunnel, VPN and overlay design, and any complaint that small '
        'pings work while web pages or logins hang.',
    tradeoffs:
        'Clamping MSS is a reliable workaround but hides a real MTU problem; '
        'jumbo frames help storage traffic but must be end-to-end or they make '
        'things worse.',
    commands:
        'interface tunnel0\n'
        ' ip mtu 1400\n'
        ' ip tcp adjust-mss 1360',
    verify:
        'ping with DF set and increasing size (ping -f -l 1472 on Windows, ping '
        '-M do -s 1472 on Linux), and a capture showing ICMP fragmentation-needed.',
    pitfalls:
        'Blocking ICMP type 3 code 4. Setting the tunnel IP MTU but not MSS. '
        'Mixing jumbo and standard MTU on the same VLAN.',
    aspects: [
      'pmtud',
      'gre',
      'vxlan',
      'jumbo',
      'fragment',
      'overhead',
      'path mtu',
      'test path mtu',
      'mtu discovery',
    ],
    conceptOwned: true,
    facts: {
      'Ethernet MTU': '1500 bytes',
      'IPv4 + TCP headers': '40 bytes',
      'GRE overhead': '24 bytes',
      'VXLAN overhead': '50 bytes',
    },
  ),
  NetworkTech(
    id: 'netflow',
    name: 'NetFlow (IPFIX)',
    aliases: ['netflow', 'ipfix', 'flow export', 'flow telemetry'],
    summary:
        'Flow telemetry summarizes who talked to whom, on which port, for how '
        'long and how many bytes - the traffic evidence a packet capture cannot '
        'give you at scale.',
    mechanism:
        'The device keeps a flow table keyed by the five-tuple plus interfaces '
        'and exports records when a flow ages out or a cache timer fires. '
        'NetFlow and IPFIX export UDP templates first, then records; sFlow '
        'samples packets instead of tracking every flow, which is cheaper but '
        'estimates rather than counts. A collector stores and graphs the '
        'records. Top-talkers, interface utilization and a sudden new flow to '
        'an odd port all come from this data.',
    whenToUse:
        'Any network that needs capacity planning, billing evidence, or an '
        'answer to "who is using the link" without standing up a span port.',
    tradeoffs:
        'Cheap visibility at line rate, but the export itself costs CPU and '
        'bandwidth, sampling hides short flows, and nothing is encrypted so '
        'the collector is a privacy decision.',
    commands:
        'ip flow-export destination 10.10.0.50 2055\n'
        'ip flow-export version 9\n'
        'interface g0/1\n'
        ' ip flow ingress\n'
        ' ip flow egress',
    verify:
        'show ip cache flow (active flows and top talkers) and the collector '
        'receiving templates within a minute or two of enabling the export.',
    pitfalls:
        'Exporting from every interface and overloading the collector. '
        'Forgetting the return path in a VRF. A sampling rate set so high that '
        'short flows never appear. No time sync, so records cannot be '
        'correlated with logs.',
    facts: {
      'Key': 'Five-tuple plus interfaces',
      'Transport': 'UDP 2055 (NetFlow), 4739 (IPFIX)',
      'sFlow': 'Packet sampling, not per-flow',
      'Use': 'Top talkers, capacity, security evidence',
    },
  ),
  NetworkTech(
    id: 'vrf',
    name: 'VRF',
    aliases: ['vrf', 'vrf-lite', 'route leaking', 'virtual routing forwarding'],
    summary:
        'A VRF is a separate routing table on the same router, so two tenants '
        'can use 10.0.0.0/8 at once without seeing each other.',
    mechanism:
        'Each VRF has its own RIB, FIB and interface set; a packet arriving on '
        'an interface in a VRF is looked up only in that table. VRFs can run '
        'their own OSPF or EIGRP process. VRF-lite is the same idea without '
        'MPLS - the links between VRFs are usually subinterfaces, one per '
        'tenant. Route leaking copies selected prefixes between tables with '
        '`import map`, which is how a shared service is reached without '
        'merging the tables.',
    whenToUse:
        'Overlapping address space (mergers, multi-tenant, management vs '
        'production), and separating a guest or OT network on shared hardware.',
    tradeoffs:
        'Strong isolation with no extra hardware, but every service, default '
        'route, NAT rule and troubleshooting command now needs the VRF named, '
        'and a missing `vrf forwarding` silently moves an interface back to '
        'the global table.',
    commands:
        'vrf definition TENANT-A\n'
        ' rd 65001:10\n'
        'interface g0/1.10\n'
        ' encapsulation dot1Q 10\n'
        ' vrf forwarding TENANT-A\n'
        ' ip address 10.10.10.1 255.255.255.0\n'
        'ip route vrf TENANT-A 0.0.0.0 0.0.0.0 10.10.10.254',
    verify:
        'show vrf, show ip route vrf TENANT-A, and a ping with `ping vrf '
        'TENANT-A ...` - an unqualified ping tests the wrong table.',
    pitfalls:
        'Adding `vrf forwarding` after the IP address, which removes the '
        'address. A default route in the global table that the VRF cannot see. '
        'Forgetting the VRF on the default route, NAT or the syslog source.',
    facts: {
      'Isolates': 'Routing and forwarding table',
      'VRF-lite': 'No MPLS, subinterfaces per tenant',
      'Leaking': 'Controlled import/export of prefixes',
      'Common fault': 'Unqualified show/ping commands',
    },
  ),
  NetworkTech(
    id: 'multicast',
    name: 'IP multicast',
    aliases: ['multicast', 'pim', 'igmp', 'rendezvous point', 'pim-sm'],
    summary:
        'Multicast sends one copy of a stream that the network replicates only '
        'where receivers asked for it, which is why it beats unicast for many '
        'viewers of the same feed.',
    mechanism:
        'Receivers join a group with IGMP; the last-hop router queries them. '
        'PIM-SM builds a shared tree to a rendezvous point and switches to a '
        'shortest-path tree once traffic flows; PIM-DM floods and prunes. '
        'Reverse path forwarding checks that the packet arrived on the '
        'interface the router would use to reach the source - an RPF failure is '
        'the classic multicast fault. 232.0.0.0/8 is SSM, where the receiver '
        'names the source and no RP is needed.',
    whenToUse:
        'Live video to many sites, market data, IPTV, and any one-to-many feed '
        'where unicast replication would multiply the WAN load.',
    tradeoffs:
        'Efficient on the WAN and scales to many receivers, but it needs '
        'multicast routing end to end, an RP design, and RPF-aware routing; '
        'one asymmetric path breaks it.',
    commands:
        'ip multicast-routing\n'
        'interface g0/1\n'
        ' ip pim sparse-mode\n'
        'ip pim rp-address 10.10.0.5\n'
        'ip igmp version 3',
    verify:
        'show ip mroute (the (S,G) and (*,G) entries and their incoming '
        'interface), show ip igmp groups, and `show ip rpf <source>` for the '
        'RPF check.',
    pitfalls:
        'RPF failure because the unicast route back to the source uses another '
        'interface. No `ip pim sparse-mode` on one transit link. IGMP snooping '
        'off on the access switch, so the stream floods every port. An RP that '
        'is not reachable from every router.',
    facts: {
      'Group range': '224.0.0.0/4',
      'SSM range': '232.0.0.0/8',
      'Host signalling': 'IGMP (v2/v3)',
      'Tree types': 'Shared (*,G) and shortest-path (S,G)',
    },
  ),
  NetworkTech(
    id: 'cloud-vpc',
    name: 'Cloud VPC networking',
    aliases: [
      'vpc',
      'aws vpc',
      'gcp vpc',
      'cloud vpc',
      'vpc peering',
      'cloud network',
      'security group',
      'subnet in aws',
      'vnet',
    ],
    summary:
        'A cloud VPC is a private, software-defined network: subnets, route '
        'tables, a gateway to the internet and security groups that act as '
        'stateful firewalls on each interface.',
    mechanism:
        'A VPC has a CIDR, split into subnets that are either public (routed '
        'to an internet gateway) or private (routed to a NAT gateway). Route '
        'tables decide where traffic goes, and every subnet implicitly routes '
        'inside the VPC. Security groups are stateful and allow-only; network '
        'ACLs are stateless and evaluated in order. Reach another VPC through '
        'peering or a transit gateway; reach on-premises through a VPN or '
        'Direct Connect. The cloud provider drops unsolicited inbound traffic '
        'before it ever reaches your instance.',
    whenToUse:
        'Any workload in AWS, Azure or GCP, and any hybrid design where the '
        'on-premises ranges must not overlap the cloud CIDR.',
    tradeoffs:
        'Fast to build and isolated by default, but address planning is hard '
        'to change later, NAT gateways cost per GB, and security groups plus '
        'NACLs plus host firewalls is three places for one rule to be missing.',
    verify:
        'Reachability Analyzer or VPC Flow Logs to prove the path, and a '
        'source/destination check on the instance for routed traffic.',
    pitfalls:
        'Overlapping CIDRs between VPC and on-premises, which makes peering '
        'impossible. A private subnet with no NAT route, so updates fail '
        'silently. A security group that allows the port but the NACL denies '
        'the ephemeral return port. Assuming a subnet is private because it is '
        'named private.',
    facts: {
      'Isolation': 'VPC/VNet boundary',
      'Stateful filter': 'Security group',
      'Stateless filter': 'Network ACL',
      'Interconnect': 'Peering, transit gateway, VPN, Direct Connect',
    },
  ),
  NetworkTech(
    id: 'spine-leaf',
    name: 'Spine-leaf fabric',
    aliases: [
      'spine leaf',
      'spine-leaf',
      'leaf spine',
      'clos fabric',
      'underlay',
      'fabric underlay',
      'network underlay',
    ],
    summary:
        'A spine-leaf fabric is a two-tier Clos: every leaf connects to every '
        'spine, so any server is the same number of hops from any other and '
        'capacity grows by adding links, not by redesigning.',
    mechanism:
        'Leaves connect to servers and to every spine; spines connect only to '
        'leaves and never to each other. Routing is layer 3 with ECMP across '
        'all equal-cost spine paths, so no link is blocked the way STP blocks '
        'them. Overlay options are VXLAN/EVPN for layer-2 extension or pure '
        'layer 3 to the host. Oversubscription is a design number: 1:1 for '
        'storage, 3:1 or 4:1 for general compute.',
    whenToUse:
        'Data centers and any dense east-west environment - virtualization '
        'clusters, storage, AI training - where a three-tier design would '
        'bounce traffic through oversubscribed uplinks.',
    tradeoffs:
        'Predictable latency and horizontal scale, but it needs more physical '
        'links, a routing design to the host, and a real address plan; it is '
        'overkill for a 40-user office.',
    verify:
        'ECMP hashing across all spine links, per-link utilization that is even, '
        'and a traceroute showing a single hop leaf-to-leaf.',
    pitfalls:
        'Hashing that is not per-flow, so one elephant flow uses one link. '
        'Spine-to-spine links that quietly turn the fabric back into a '
        'three-tier. Under-provisioned spines, which cap the whole fabric. '
        'Layer 2 stretched across leaves without EVPN.',
    facts: {
      'Topology': 'Two-tier Clos',
      'Routing': 'Layer 3 with ECMP',
      'Hops leaf-to-leaf': 'Two (leaf-spine-leaf)',
      'Overlay': 'VXLAN/EVPN or routed to host',
    },
  ),
  NetworkTech(
    id: 'evpn',
    name: 'EVPN',
    aliases: ['evpn', 'ethernet vpn', 'route type 2', 'mac mobility'],
    summary:
        'EVPN is the BGP control plane for VXLAN: it advertises which MAC and '
        'IP addresses live behind which VTEP, so the fabric learns reachability '
        'instead of flooding.',
    mechanism:
        'EVPN runs in MP-BGP (AFI 25, SAFI 70) and carries typed routes. Type 2 '
        'advertises a MAC/IP pair with its VNI and next hop; type 3 carries the '
        'inclusive multicast list for BUM traffic; type 5 carries IP prefixes '
        'for symmetric routing; type 1 and type 4 handle multihoming and the '
        'Ethernet segment. A route distinguisher makes each prefix unique per '
        'VTEP or VRF, and route targets decide which VRFs import it. ARP '
        'suppression answers an ARP locally when the MAC/IP is already known '
        'from a type 2 route. An anycast gateway gives every leaf the same '
        'gateway MAC and IP, so a host keeps its gateway after a live '
        'migration.',
    whenToUse:
        'Any VXLAN fabric beyond a lab: it removes flood-and-learn, gives '
        'fast reconvergence, supports multihoming with ESI, and is the only '
        'sane way to run a large multi-tenant overlay. It is also the right '
        'choice when ARP flooding would be a broadcast problem at scale.',
    tradeoffs:
        'It is BGP, with all of BGP operational weight: route targets, address '
        'families, and a control plane that fails silently when a route target '
        'is missing. The underlay still needs a correct MTU and routing '
        'protocol. Troubleshooting moves from "is the link up" to "did the '
        'right route type arrive".',
    commands:
        'router bgp 65000\n'
        ' address-family l2vpn evpn\n'
        '  neighbor 10.0.0.11 activate\n'
        '  neighbor 10.0.0.11 send-community extended\n'
        'vlan 100\n'
        ' vn-segment 10100\n'
        'interface nve1\n'
        ' no shutdown\n'
        ' source-interface loopback0\n'
        ' member vni 10100\n'
        '  ingress-replication protocol bgp',
    verify:
        'show bgp l2vpn evpn summary (peers Established), show bgp l2vpn evpn '
        '(types 2 and 3 present for the VNI), show nve vni (the VNI is up with '
        'the right VTEPs), and show l2route evpn mac all on a leaf.',
    pitfalls:
        'A missing or mismatched route target produces a VNI that is up with '
        'no remote MACs - the classic "tunnel works, hosts cannot talk". '
        'Advertising type 2 without the IP makes ARP suppression useless. '
        'Duplicated ESI values create a split-brain multihoming state. And an '
        'underlay MTU below 1550 makes everything work until a large frame '
        'arrives.',
    aspects: [
      'route type',
      'esi',
      'multihoming',
      'anycast gateway',
      'mac mobility',
    ],
    facts: {
      'Control plane': 'MP-BGP AFI 25 / SAFI 70',
      'Encapsulation': 'VXLAN, UDP 4789',
      'VNI size': '24 bits',
      'Overhead': '50 bytes',
      'Route types': '1, 2, 3, 4, 5',
    },
  ),
  NetworkTech(
    id: 'vpc-mlag',
    name: 'vPC / MLAG',
    aliases: [
      'mlag',
      'virtual port channel',
      'vpc peer-link',
      'vpc peer',
      'vpc domain',
      'peer-link',
      'multi-chassis lag',
    ],
    summary:
        'vPC (Nexus) and MLAG (most other vendors) make two switches present one '
        'logical port-channel, so a server or access switch can dual-home '
        'without a spanning-tree blocked link.',
    mechanism:
        'The two peers synchronise MAC, ARP and IGMP state over the peer-link, '
        'a port-channel that carries all VLANs and the control traffic. A '
        'separate peer-keepalive heartbeat detects a peer that is alive but '
        'isolated from the peer-link. One peer becomes primary and the other '
        'secondary; they exchange consistency parameters, and a type-1 mismatch '
        '(MTU, STP mode, allowed VLANs) suspends member ports. Traffic from a '
        'dual-homed host is hashed across both peers, and orphan ports are '
        'forwarded through the peer-link if the uplink fails.',
    whenToUse:
        'Data center access or aggregation where servers dual-home and you '
        'want both links active, and where STP blocking would waste half the '
        'bandwidth. It is also the standard way to dual-home a firewall or a '
        'load balancer without an active/standby link.',
    tradeoffs:
        'The peer-link becomes a critical path and a capacity path: if it is '
        'oversubscribed, orphan traffic suffers. Split-brain is the failure '
        'mode that hurts, and it is why the keepalive must not share fate with '
        'the peer-link. It does not remove the need for a loop-free L3 design '
        'behind it.',
    commands:
        'vpc domain 10\n'
        ' peer-keepalive destination 10.0.0.2 source 10.0.0.1 vrf management\n'
        ' peer-gateway\n'
        ' ip arp synchronize\n'
        'interface port-channel10\n'
        ' switchport mode trunk\n'
        ' vpc peer-link\n'
        'interface port-channel20\n'
        ' vpc 20',
    verify:
        'show vpc (peer status, role, peer-link, vPC states), show vpc '
        'consistency-parameters global (the parameter that differs), show vpc '
        'peer-keepalive, and show port-channel summary.',
    pitfalls:
        'Keepalive routed through the peer-link defeats split-brain '
        'detection. A type-1 mismatch suspends ports with no obvious link '
        'fault. Forgetting to allow a VLAN on the peer-link black-holes orphan '
        'traffic. And a vPC domain ID that differs between peers prevents the '
        'domain from forming at all.',
    aspects: ['peer-link', 'keepalive', 'split brain', 'consistency', 'orphan'],
    facts: {
      'Peers': 'Two',
      'Peer-link': 'Port-channel, all VLANs',
      'Keepalive': 'Separate L3 path, UDP 3200',
      'Roles': 'Primary / secondary',
    },
  ),
  NetworkTech(
    id: 'segment-routing',
    name: 'Segment Routing',
    aliases: ['segment routing', 'sr-mpls', 'srv6', 'sr mpls', 'sid', 'ti-lfa'],
    summary:
        'Segment routing encodes the path in the packet as a list of SIDs, so '
        'the core forwards on labels or IPv6 addresses without per-path state '
        'in every router.',
    mechanism:
        'In SR-MPLS a node SID is an MPLS label bound to a loopback, and an '
        'adjacency SID is bound to a link; the ingress pushes a stack and each '
        'hop pops or swaps according to the SID. SRv6 does the same with '
        '128-bit SIDs carried in an IPv6 routing header. Because the path is '
        'in the packet, there is no LDP or RSVP-TE state to maintain, and '
        'TI-LFA can pre-compute a loop-free backup that is installed before a '
        'failure happens. Segment routing works with an IGP (IS-IS or OSPF) '
        'extended to advertise SIDs.',
    whenToUse:
        'Service provider cores and large data centers that want traffic '
        'engineering and 50 ms protection without RSVP state, and networks '
        'moving toward a software-defined fabric. SRv6 is attractive where the '
        'core is already IPv6-only.',
    tradeoffs:
        'Requires hardware that understands the SID stack, and SRv6 costs 40 '
        'bytes per SID in the header - MTU again. Operational tooling and '
        'skills lag behind MPLS LDP. The design and the failure analysis are '
        'less familiar than plain OSPF, which is a real cost at 3 a.m.',
    commands:
        'segment-routing mpls\n'
        ' connected-prefix-sid-map\n'
        '  address-family ipv4\n'
        '   10.0.0.1/32 index 1 range 1\n'
        'interface Loopback0\n'
        ' ip address 10.0.0.1 255.255.255.255\n'
        ' isis prefix-sid index 1',
    verify:
        'show segment-routing mpls state, show isis segment-routing prefix-sid, '
        'show mpls forwarding-table (the SID and its outgoing label), and a '
        'traceroute that shows the SID stack.',
    pitfalls:
        'A duplicate index breaks the SID-to-prefix mapping. TI-LFA needs the '
        'topology to have a valid post-convergence path; on a ring it can '
        'produce a backup that is longer than the failure. And an SRv6 policy '
        'with too many SIDs exceeds the MTU without an obvious error.',
    aspects: ['sid', 'ti-lfa', 'traffic engineering', 'srv6'],
    facts: {
      'SR-MPLS label': 'Node or adjacency SID',
      'SRv6 SID': '128 bits, 40 bytes overhead',
      'IGP extensions': 'IS-IS or OSPF',
      'Protection': 'TI-LFA, sub-50 ms',
    },
  ),
  NetworkTech(
    id: 'isis',
    name: 'IS-IS',
    aliases: [
      'isis',
      'is-is',
      'intermediate system to intermediate system',
      'is-is adjacency',
    ],
    summary:
        'IS-IS is a link-state IGP that runs directly on layer 2 and scales to '
        'very large flat domains, which is why service providers prefer it to '
        'OSPF.',
    mechanism:
        'Routers are identified by a NET (an NSAP address) and form level 1 '
        '(intra-area) and level 2 (backbone) adjacencies. It uses TLVs for '
        'everything, so extending it does not require a new protocol version. '
        'A DIS is elected on broadcast segments and creates a pseudonode, the '
        'equivalent of an OSPF DR but with preemption. Wide metrics are 32-bit '
        'and support traffic engineering; narrow metrics are the legacy 6-bit '
        'form. It runs over CLNS directly, so it does not depend on IP being '
        'up on the link, which is useful for bootstrapping and for '
        'troubleshooting an IP fault.',
    whenToUse:
        'Provider cores, very large fabrics, and any network that wants a '
        'single flat IGP with fast convergence and vendor-neutral extensions. '
        'It is also common in data centers running EVPN.',
    tradeoffs:
        'The addressing (NET) and level design confuse people raised on OSPF, '
        'and a level-1 router follows a default route toward level 2 unless '
        'you leak prefixes deliberately. The TLV model is elegant but the '
        'tooling is less familiar.',
    commands:
        'router isis CORE\n'
        ' net 49.0001.0100.0000.0001.00\n'
        ' metric-style wide\n'
        ' is-type level-2-only\n'
        'interface GigabitEthernet0/0\n'
        ' ip router isis CORE\n'
        ' isis metric 10',
    verify:
        'show isis neighbors (levels and state), show isis database (the LSPs '
        'and their sequence numbers), show isis topology, and show clns '
        'interface - the NET and the level must be up on the link itself.',
    pitfalls:
        'Duplicate system IDs cause constant LSP churn. Level-1-only routers '
        'black-hole traffic that needs level 2. MTU mismatch breaks IIH '
        'padding and keeps an adjacency down while pings pass. And changing '
        'metric style without doing it everywhere produces a topology nobody '
        'can read.',
    aspects: ['level', 'net', 'metric', 'tlv', 'adjacency'],
    facts: {
      'Levels': 'Level 1, level 2, level 1-2',
      'Address': 'NET / NSAP',
      'Metric': 'Wide 32-bit',
      'Transport': 'Directly over L2 (CLNS)',
      'DIS': 'Preempts, unlike OSPF DR',
    },
  ),
  NetworkTech(
    id: 'bfd',
    name: 'BFD',
    aliases: [
      'bfd',
      'bidirectional forwarding detection',
      'fast failure detection',
    ],
    summary:
        'BFD is a small hello protocol that detects a dead path in '
        'milliseconds, independent of the routing protocol that uses it.',
    mechanism:
        'Two endpoints negotiate transmit and receive intervals and a '
        'detection multiplier; failure is declared after the multiplier is '
        'exceeded, so 50 ms x 3 is about 150 ms. Asynchronous mode sends '
        'periodic control packets (UDP 3784 single-hop, 4784 multihop) and '
        'expects them back. Echo mode loops packets through the forwarding '
        'path, which catches a one-way failure that hellos miss. BFD does not '
        'route or advertise anything - it is a client of the IGP, BGP, HSRP or '
        'a static route, and it tells that client the path is gone.',
    whenToUse:
        'Anywhere the routing protocol timers are too slow for the '
        'application: OSPF/BGP/HSRP failover, WAN links, and ECMP members. It '
        'is the correct way to get sub-second convergence without shrinking '
        'hello timers everywhere.',
    tradeoffs:
        'Both ends must match session type and timers, and aggressive timers '
        'flap on a jittery WAN. It detects failure, not degradation - it will '
        'not help with a link that is up but losing 20% of packets.',
    commands:
        'interface GigabitEthernet0/0\n'
        ' bfd interval 50 min_rx 50 multiplier 3\n'
        'router ospf 1\n'
        ' bfd all-interfaces\n'
        'router bgp 65000\n'
        ' neighbor 10.0.0.2 fall-over bfd',
    verify:
        'show bfd neighbors (state Up and the negotiated timers), show bfd '
        'neighbors details (the client and the echo state), and the routing '
        'protocol neighbour table going down within the expected time.',
    pitfalls:
        'Timers that do not match keep the session down with no obvious '
        'error. BFD over a tunnel inherits the tunnel MTU. And a BFD session '
        'that is up while the forwarding path is broken means echo mode is '
        'off and the failure is one-way.',
    aspects: ['timer', 'echo', 'multiplier', 'session'],
    facts: {
      'Single-hop port': 'UDP 3784',
      'Multihop port': 'UDP 4784',
      'Echo port': 'UDP 3785',
      'Typical': '50 ms x 3 = 150 ms',
    },
  ),
  NetworkTech(
    id: 'dmvpn',
    name: 'DMVPN',
    aliases: [
      'dmvpn',
      'nhrp',
      'dynamic multipoint vpn',
      'hub and spoke tunnel',
    ],
    summary:
        'DMVPN builds a hub-and-spoke VPN with mGRE and NHRP, so spokes can '
        'come up dynamically and, in phase 3, talk to each other directly '
        'without a static tunnel per site.',
    mechanism:
        'The hub has a multipoint GRE interface and each spoke registers its '
        'public address with NHRP. In phase 1 all traffic goes through the '
        'hub. Phase 2 lets a spoke ask NHRP for another spoke and build a '
        'direct GRE tunnel, but the next hop is still the hub address. Phase 3 '
        'uses NHRP shortcuts and a summarized tunnel network so the direct '
        'path is used for the actual destination. IPsec protects the GRE, and '
        'the tunnel MTU must account for GRE and IPsec overhead.',
    whenToUse:
        'Many branch sites over the internet that need dynamic tunnels, '
        'multicast or routing protocols across the overlay, and a simple '
        'hub-and-spoke policy. It is the classic pre-SD-WAN design and still '
        'common in networks that cannot replace hardware.',
    tradeoffs:
        'The hub is a capacity and policy bottleneck, phase 3 adds NHRP and '
        'routing complexity, and troubleshooting crosses three layers (NHRP, '
        'GRE, IPsec). SD-WAN replaces it with per-application policy and '
        'centralised management.',
    commands:
        'interface Tunnel0\n'
        ' ip address 172.16.0.1 255.255.255.0\n'
        ' tunnel source GigabitEthernet0/0\n'
        ' tunnel mode gre multipoint\n'
        ' ip nhrp network-id 1\n'
        ' ip nhrp map multicast dynamic\n'
        ' ip nhrp redirect\n'
        ' ip nhrp shortcut\n'
        ' tunnel protection ipsec profile DMVPN',
    verify:
        'show dmvpn (peers, state, and whether the path is direct or via the '
        'hub), show ip nhrp (registrations and shortcuts), show crypto ipsec '
        'sa, and a traceroute that shows the direct spoke-to-spoke path in '
        'phase 3.',
    pitfalls:
        'MTU and MSS: the tunnel must clamp or the large flows stall. NHRP '
        'network IDs must match. A spoke behind NAT needs NAT-T and the right '
        'NHRP registration. And phase 2 without redirect sends traffic through '
        'the hub even when a direct path exists.',
    aspects: ['nhrp', 'phase', 'hub', 'shortcut'],
    facts: {
      'Encapsulation': 'mGRE',
      'Mapping': 'NHRP',
      'Phases': '1 hub, 2 direct data, 3 direct with shortcuts',
      'Overhead': 'GRE 24 + IPsec',
    },
  ),
  NetworkTech(
    id: 'gre',
    name: 'GRE',
    aliases: [
      'gre',
      'generic routing encapsulation',
      'gre tunnel',
      'ip tunnel',
    ],
    summary:
        'GRE is a simple IP-in-IP tunnel that carries anything - multicast, '
        'non-IP, IPv6 - but adds 24 bytes of overhead and no encryption.',
    mechanism:
        'The original packet is wrapped in a GRE header and a new outer IP '
        'header between the tunnel endpoints. The tunnel interface is a '
        'separate subnet, so routing inside the tunnel is ordinary routing. '
        'GRE is stateless: there is no negotiation, no keepalive unless you '
        'configure one, and no authentication. It carries multicast, which is '
        'why it is used for routing protocols over a non-multicast underlay '
        'and for IPv6 transition (6in4 uses protocol 41, not GRE).',
    whenToUse:
        'Carrying multicast or routing protocols across an IP-only underlay, '
        'joining two sites over a provider that cannot do MPLS, and as the '
        'outer layer under IPsec when you need multicast or dynamic routing '
        'protected by IPsec.',
    tradeoffs:
        'No confidentiality, integrity or replay protection on its own, and '
        'the 24-byte overhead breaks 1500-byte paths unless the MTU or MSS is '
        'adjusted. Recursive routing is a classic own-goal: the tunnel '
        'endpoint route learned through the tunnel.',
    commands:
        'interface Tunnel0\n'
        ' ip address 10.10.10.1 255.255.255.252\n'
        ' tunnel source 203.0.113.1\n'
        ' tunnel destination 198.51.100.1\n'
        ' tunnel mode gre ip\n'
        ' ip mtu 1476\n'
        ' ip tcp adjust-mss 1436',
    verify:
        'show interfaces Tunnel0 (up/up means the endpoints resolve), ping '
        'with size 1476 df-bit, and a traceroute that shows the tunnel hop. '
        'show ip route for the tunnel endpoint must not point into the tunnel.',
    pitfalls:
        'Recursive routing takes the tunnel down as soon as the endpoint '
        'route is learned through it - always pin the endpoint route or use a '
        'specific static route. Forgetting the MTU/MSS makes small pings pass '
        'and TLS hang. And GRE without IPsec is plaintext, whatever the '
        'tunnel name suggests.',
    aspects: ['overhead', 'mtu', 'multicast', 'recursive routing'],
    facts: {
      'Overhead': '24 bytes',
      'IP protocol': '47',
      'Encryption': 'None (pair with IPsec)',
      'Multicast': 'Supported',
    },
  ),
  NetworkTech(
    id: 'anycast',
    name: 'Anycast',
    aliases: ['anycast', 'anycast ip', 'anycast gateway'],
    summary:
        'Anycast gives the same IP address to several devices, and routing '
        'delivers each client to the nearest one.',
    mechanism:
        'Each site advertises the same prefix (or the same loopback) into BGP '
        'or an IGP; the routing system picks the closest instance by metric, '
        'AS path or IGP cost, and every client reaches whichever is nearest. '
        'It is stateless from the network point of view - if a site withdraws '
        'the route, traffic moves to the next instance. DNS root servers, CDNs '
        'and anycast gateways in EVPN fabrics all work this way. A common '
        'variant inside a data center is an anycast distributed gateway: every '
        'leaf has the same SVI IP and MAC, so a host keeps its default gateway '
        'after migration.',
    whenToUse:
        'Services that can run independently in several places and tolerate a '
        'site failure: DNS, NTP, CDN edges, stateless APIs, and the distributed '
        'gateway in a VXLAN/EVPN fabric.',
    tradeoffs:
        'Sessions do not survive a path change unless the service is stateless '
        'or replicates state, and a routing change can move a client mid-flow. '
        'Debugging is harder because "the server" is several servers. Anycast '
        'also defeats simple per-site capacity planning.',
    commands:
        'interface Loopback0\n'
        ' ip address 192.0.2.10 255.255.255.255\n'
        'router bgp 65000\n'
        ' network 192.0.2.10 mask 255.255.255.255\n'
        ' ! every site advertises the same /32',
    verify:
        'From several locations, traceroute to the anycast address and confirm '
        'each lands on a different instance; check the BGP table for the same '
        'prefix from multiple next hops, and test a withdraw to see traffic '
        'move.',
    pitfalls:
        'Stateful services on anycast break when the path moves. A site that '
        'advertises but cannot serve still attracts traffic. And in an EVPN '
        'anycast gateway, a mismatched gateway MAC between leaves causes '
        'silent ARP failures.',
    aspects: ['gateway', 'bgp', 'nearest', 'stateless'],
    facts: {
      'Same address': 'Multiple sites',
      'Selection': 'Routing metric / AS path',
      'State': 'Must be shared or stateless',
      'Classic use': 'DNS roots, CDN, distributed gateway',
    },
  ),
  NetworkTech(
    id: 'ptp',
    name: 'PTP (IEEE 1588)',
    aliases: [
      'ptp',
      'precision time protocol',
      '1588',
      'ieee 1588',
      'boundary clock',
    ],
    summary:
        'PTP synchronises clocks to sub-microsecond accuracy over the network, '
        'which NTP cannot do, by timestamping packets in hardware.',
    mechanism:
        'A grandmaster sends Sync and Follow_Up messages, and the slave '
        'measures the offset using hardware timestamps at the PHY. Delay_Req '
        'and Delay_Resp measure the path delay, so the slave can correct for '
        'it. Ordinary clocks are endpoints, boundary clocks timestamp and '
        'forward, and transparent clocks correct the residence time in the '
        'switch. Best Master Clock Algorithm elects the grandmaster. PTP runs '
        'over Ethernet (layer 2, EtherType 0x88F7) or over UDP (319/320).',
    whenToUse:
        'Financial trading, mobile fronthaul, power substations, broadcast and '
        'any application where NTP millisecond accuracy is not enough. Also '
        'where you need a stable frequency reference, not just wall-clock time.',
    tradeoffs:
        'Needs hardware timestamping and PTP-aware switches; a switch that '
        'does not support it adds variable delay and ruins the accuracy. It is '
        'a separate management domain from NTP, and a misconfigured domain '
        'number silently keeps the slave unsynchronised.',
    commands:
        'ptp clock ordinary domain 0\n'
        ' clock-port MASTER master\n'
        'ptp clock boundary domain 0\n'
        ' interface GigabitEthernet0/1\n'
        '  ptp enable',
    verify:
        'show ptp clock (offset, grandmaster identity, domain), show ptp port, '
        'and on the slave the offset should be sub-microsecond and stable. A '
        'drifting offset points at a non-PTP switch in the path.',
    pitfalls:
        'Mixing PTP domains. A non-transparent switch adding queueing delay. '
        'Asymmetric paths (one direction longer) bias the offset. And assuming '
        'PTP is encrypted - it is not; it needs a protected management domain.',
    aspects: ['grandmaster', 'boundary clock', 'transparent clock', 'accuracy'],
    facts: {
      'Accuracy': 'Sub-microsecond',
      'L2 EtherType': '0x88F7',
      'UDP ports': '319 event, 320 general',
      'Election': 'Best Master Clock Algorithm',
    },
  ),
  NetworkTech(
    id: 'streaming-telemetry',
    name: 'Streaming telemetry',
    aliases: [
      'telemetry',
      'gnmi',
      'grpc telemetry',
      'streaming telemetry',
      'model driven telemetry',
    ],
    summary:
        'Streaming telemetry pushes device data continuously over gRPC instead '
        'of polling it with SNMP every five minutes.',
    mechanism:
        'The device runs a gRPC server (gNMI or a vendor dial-out) and streams '
        'telemetry according to a subscription: a path in the YANG model, a '
        'sample interval, and a mode (periodic, on-change, or target-defined). '
        'Data is encoded with GPB or JSON and sent over TLS to a collector. '
        'Because the subscription is push-based, a 10-second interface counter '
        'stream is cheap, while SNMP walking the same table every 10 seconds '
        'would cost real CPU.',
    whenToUse:
        'Any network large enough that five-minute SNMP polling hides the '
        'incident: congestion microbursts, route churn, optics degradation, and '
        'fabric health. It is also the data plane behind intent-based '
        'assurance.',
    tradeoffs:
        'It needs a collector and a data pipeline, YANG models differ between '
        'vendors and versions, and a misconfigured subscription can generate '
        'more data than the network can carry. It complements SNMP; it does '
        'not replace the trap for a discrete event.',
    commands:
        'telemetry ietf subscription 1\n'
        ' encoding encode-kvgpb\n'
        ' filter xpath /interfaces/interface/state/counters\n'
        ' source-address 10.0.0.1\n'
        ' stream yang-push\n'
        ' update-policy periodic 1000\n'
        ' receiver ip address 10.0.0.100 57500 protocol grpc-tcp',
    verify:
        'show telemetry ietf subscription all (state and last update), the '
        'collector receiving samples at the configured interval, and TLS '
        'session health. A subscription that is "configured" but not '
        '"connected" is the usual first fault.',
    pitfalls:
        'Subscribing to a huge table at 1-second intervals - the cure is worse '
        'than the disease. Certificate mismatch on the gRPC TLS session. And '
        'assuming the timestamps are synchronised when NTP is not configured.',
    aspects: ['gnmi', 'subscription', 'yang', 'collector'],
    facts: {
      'Transport': 'gRPC over TLS',
      'Encoding': 'GPB or JSON',
      'Modes': 'Periodic, on-change, target-defined',
      'Model': 'YANG',
    },
  ),
  NetworkTech(
    id: 'sase',
    name: 'SASE',
    aliases: [
      'sase',
      'secure access service edge',
      'sse',
      'ztna',
      'swg',
      'casb',
    ],
    summary:
        'SASE combines network connectivity (SD-WAN) with cloud-delivered '
        'security (secure web gateway, CASB, ZTNA, firewall) in one policy '
        'plane.',
    mechanism:
        'Instead of backhauling branch traffic to a data center firewall, the '
        'branch sends it to a nearby SASE point of presence, where identity, '
        'device posture and application are evaluated and the traffic is '
        'inspected. ZTNA replaces the VPN concentrator with per-application '
        'access: the user is authenticated to the application, not to the '
        'network. The same policy follows the user to home and mobile.',
    whenToUse:
        'Distributed branches and remote workers that consume SaaS directly, '
        'where backhauling to a central firewall adds latency and cost, and '
        'where the security policy must follow the user rather than the '
        'network port.',
    tradeoffs:
        'Latency depends on PoP proximity, the vendor becomes a critical '
        'dependency, and inspection of encrypted traffic is a policy and '
        'privacy decision, not just a technical one. Migrating from a '
        'hub-and-spoke VPN changes the routing and the troubleshooting model.',
    commands: '',
    verify:
        'Measure the path from a branch to the SaaS application with and '
        'without the SASE PoP, confirm the identity provider is the source of '
        'truth, and test that a user without posture is denied at the '
        'application, not just at the network.',
    pitfalls:
        'Buying SASE and keeping the old backhaul "for safety" - the latency '
        'stays and the benefit disappears. Forgetting that DNS and SNI are now '
        'part of the policy. And a local internet breakout without local '
        'security becomes a direct path to the internet.',
    aspects: ['ztna', 'sse', 'sd-wan', 'cloud security'],
    facts: {
      'Components': 'SD-WAN, SWG, CASB, ZTNA, FWaaS',
      'Delivery': 'Cloud PoP',
      'Access model': 'Per application, per identity',
      'Replaces': 'Hub-and-spoke backhaul, VPN concentrator',
    },
  ),
  NetworkTech(
    id: 'macsec',
    name: 'MACsec',
    aliases: ['macsec', '802.1ae', 'mka', 'link encryption'],
    summary:
        'MACsec encrypts and authenticates every Ethernet frame on a link, at '
        'line rate, before it is switched.',
    mechanism:
        'MACsec (802.1AE) adds a SecTAG and an integrity check to each frame, '
        'using keys negotiated by MKA (802.1X-2010). It protects the link '
        'between two directly connected devices, so a tap on the cable sees '
        'ciphertext. Because it works below switching, it protects everything '
        'on that link including ARP, LLDP and routing hellos. It is often '
        'combined with 802.1X: the supplicant authenticates, then MKA derives '
        'the keys.',
    whenToUse:
        'Links that physically leave a controlled space: building-to-building '
        'fiber, provider handoffs, data center interconnects over third-party '
        'fiber, and any compliance regime that requires encryption in transit '
        'at layer 2.',
    tradeoffs:
        'Point-to-point only - it does not protect a multi-hop path. It needs '
        'hardware support for line-rate encryption, and a key or MKA failure '
        'takes the link down, which is a new failure mode. It does not replace '
        'IPsec for traffic that crosses untrusted routers.',
    commands:
        'interface GigabitEthernet0/1\n'
        ' macsec\n'
        ' mka policy MKA-POLICY\n'
        'access-session interface GigabitEthernet0/1\n'
        ' macsec policy MUST-SECURE',
    verify:
        'show macsec interface (secured or not), show mka sessions (the key '
        'server and the cipher suite), and the interface counters for '
        'encrypted versus dropped frames.',
    pitfalls:
        'Mismatched cipher suites or key servers keep the link down with a '
        'layer-1-looking symptom. MACsec on a link that carries a provider '
        'tag can break the provider. And assuming it protects beyond the next '
        'device - it does not.',
    aspects: ['mka', 'link encryption', '802.1ae'],
    facts: {
      'Standard': '802.1AE',
      'Key agreement': 'MKA (802.1X-2010)',
      'Scope': 'Point-to-point link',
      'Overhead': 'About 32 bytes',
    },
  ),
  NetworkTech(
    id: 'dhcp-snooping',
    name: 'DHCP snooping',
    aliases: ['dhcp snooping', 'dhcp snooping binding', 'option 82'],
    summary:
        'DHCP snooping filters DHCP at layer 2: replies are allowed only from '
        'trusted ports, and every lease is recorded in a binding table.',
    mechanism:
        'The switch listens to DHCP DISCOVER/REQUEST/ACK on untrusted ports '
        'and builds a binding of MAC, IP, VLAN, port and lease time. Server '
        'replies (OFFER/ACK) arriving on an untrusted port are dropped, which '
        'stops a rogue server. Option 82 can be inserted so the server knows '
        'which port and VLAN the request came from. The binding table is the '
        'input for Dynamic ARP Inspection and IP Source Guard, so snooping is '
        'the foundation of the other two, not an alternative to them.',
    whenToUse:
        'Every access switch that serves untrusted devices - campus, branch, '
        'guest, and any port where a user could plug in a laptop or a small '
        'router. It is also mandatory before enabling DAI.',
    tradeoffs:
        'It drops DHCP if the uplink is not trusted, which looks like a DHCP '
        'server outage. The binding table has a size limit on low-end '
        'switches. And a legitimate relay or a virtualised environment that '
        'rewrites MAC addresses needs an exception.',
    commands:
        'ip dhcp snooping\n'
        'ip dhcp snooping vlan 10,20\n'
        'interface GigabitEthernet1/0/1\n'
        ' ip dhcp snooping trust\n'
        'interface range GigabitEthernet1/0/2-48\n'
        ' ip dhcp snooping limit rate 10',
    verify:
        'show ip dhcp snooping (VLANs and trusted ports), show ip dhcp '
        'snooping binding (the leases learned), and show ip dhcp snooping '
        'statistics for drops. A client that gets no address with snooping on '
        'is almost always an untrusted uplink.',
    pitfalls:
        'Forgetting to trust the uplink takes down every client at once. '
        'Enabling snooping on the server VLAN but not the client VLAN empties '
        'the binding table. And a rate limit set too low drops a legitimate '
        'renewal burst.',
    aspects: ['binding', 'trusted port', 'option 82', 'rogue server'],
    facts: {
      'Trusted ports': 'Uplink and server only',
      'Binding table': 'MAC, IP, VLAN, port, lease',
      'Feeds': 'DAI and IP Source Guard',
      'Option 82': 'Relay agent information',
    },
  ),
  NetworkTech(
    id: 'dai',
    name: 'Dynamic ARP Inspection',
    aliases: [
      'dai',
      'dynamic arp inspection',
      'arp inspection',
      'arp spoofing',
    ],
    summary:
        'DAI validates ARP packets against the DHCP snooping binding table, so '
        'a host cannot claim an IP or MAC that is not its own.',
    mechanism:
        'For every ARP request or reply on an untrusted port, the switch '
        'checks the sender MAC and IP against the binding table (or a static '
        'ARP ACL). A mismatch is dropped and logged. Trusted ports bypass the '
        'check. The validation can include source MAC, destination MAC and IP, '
        'and the default is to check both sender fields. Because it depends on '
        'the binding table, DAI only works where DHCP snooping is enabled and '
        'the host actually used DHCP.',
    whenToUse:
        'Any access network where ARP spoofing could redirect or intercept '
        'traffic: campus, guest, industrial, and any network with a compliance '
        'requirement for layer-2 security.',
    tradeoffs:
        'Static hosts break unless you add a static ARP ACL. Virtualisation '
        'and wireless controllers that proxy ARP can present a MAC that does '
        'not match the binding. And the CPU cost of inspecting every ARP on a '
        'large VLAN is real on older hardware.',
    commands:
        'ip arp inspection vlan 10,20\n'
        'interface GigabitEthernet1/0/1\n'
        ' ip arp inspection trust\n'
        'arp access-list STATIC-HOSTS\n'
        ' permit ip host 10.0.0.50 mac host 0011.2233.4455\n'
        'ip arp inspection filter STATIC-HOSTS vlan 10',
    verify:
        'show ip arp inspection (VLANs and trusted ports), show ip arp '
        'inspection statistics (drops per VLAN), and show ip dhcp snooping '
        'binding (the entry DAI is checking against).',
    pitfalls:
        'Enabling DAI before snooping, so every ARP is dropped. Forgetting the '
        'static ARP ACL for servers, printers and routers. And trusting an '
        'access port because "the phone needs it", which reopens the hole.',
    aspects: ['static host', 'trusted port', 'validation'],
    facts: {
      'Source of truth': 'DHCP snooping binding',
      'Trusted': 'Uplink and server ports',
      'Static hosts': 'ARP ACL required',
      'Deploy with': 'DHCP snooping',
    },
  ),
  NetworkTech(
    id: 'ip-source-guard',
    name: 'IP Source Guard',
    aliases: ['ip source guard', 'source guard', 'ip verify source'],
    summary:
        'IP Source Guard adds a per-port filter that permits only the IP (and '
        'optionally MAC) that DHCP assigned to that port.',
    mechanism:
        'The switch installs a PACL or a hardware filter from the DHCP '
        'snooping binding: traffic from the port must match the assigned '
        'source IP, and with port-security integration, the source MAC. A host '
        'that statically configures an address other than its lease is dropped '
        'at the port. It is the layer-2 complement to uRPF, which does the '
        'same job at layer 3.',
    whenToUse:
        'Access ports where users must not spoof a source address, especially '
        'in combination with DHCP snooping and DAI. It is the third leg of the '
        'access-security triad.',
    tradeoffs:
        'Static hosts need a static binding or the port breaks. It adds a '
        'hardware filter per port, which can exhaust TCAM on a low-end switch. '
        'And a host that changes its address legitimately needs a new lease '
        'before the filter updates.',
    commands:
        'interface GigabitEthernet1/0/2\n'
        ' ip verify source\n'
        ' ! or, to check MAC as well:\n'
        ' ip verify source port-security',
    verify:
        'show ip verify source (the per-port filter and the binding it uses), '
        'show ip dhcp snooping binding, and a test from a host with a static '
        'address outside its lease - it should fail and be logged.',
    pitfalls:
        'Enabling it on a port with no binding blocks the host completely. '
        'Forgetting the static entry for the printer. And assuming it protects '
        'routed traffic - it is a layer-2 ingress filter.',
    aspects: ['spoofing', 'binding', 'static host'],
    facts: {
      'Filter': 'Source IP (+ MAC with port-security)',
      'Source of truth': 'DHCP snooping binding',
      'Layer': 'Layer 2 ingress',
      'Equivalent': 'uRPF at layer 3',
    },
  ),
  NetworkTech(
    id: 'qinq',
    name: 'QinQ (802.1ad)',
    aliases: [
      'qinq',
      'q-in-q',
      '802.1ad',
      'provider bridging',
      'double tagging',
    ],
    summary:
        'QinQ stacks two 802.1Q tags so a provider can carry many customer '
        'VLANs over one service VLAN without coordinating VLAN IDs.',
    mechanism:
        'The customer frame arrives with a C-VLAN tag; the provider edge adds '
        'an S-VLAN tag (EtherType 0x88A8) and forwards on the outer tag only. '
        'The inner tag is preserved end to end, so two customers can both use '
        'VLAN 10. The provider core sees one S-VLAN per customer or per '
        'service, which keeps the core VLAN space small. Selective QinQ maps '
        'specific C-VLANs to specific S-VLANs, and the outer tag adds 4 bytes '
        'of overhead.',
    whenToUse:
        'Metro Ethernet, multi-tenant buildings, and any provider that must '
        'transparently carry a customer VLAN plan across a shared '
        'infrastructure.',
    tradeoffs:
        'MTU: the double tag costs 4 bytes and can push a 1500-byte frame over '
        'the limit. The provider cannot see the customer VLANs, which is the '
        'point but also limits per-C-VLAN policy. And some customer equipment '
        'drops 0x88A8 frames.',
    commands:
        'interface GigabitEthernet0/1\n'
        ' switchport mode dot1q-tunnel\n'
        ' switchport access vlan 100\n'
        ' ! selective:\n'
        ' switchport vlan mapping 10 100\n'
        ' switchport vlan mapping 20 200',
    verify:
        'show interfaces trunk (the outer tag), show vlan mapping, and a '
        'capture at the provider edge that shows both tags. End-to-end, the '
        'customer should see its own VLAN unchanged.',
    pitfalls:
        'Forgetting the extra 4 bytes in the MTU. Mapping two customers to the '
        'same S-VLAN, which merges their broadcast domains. And assuming QinQ '
        'hides the customer MAC addresses - it does not.',
    aspects: ['s-vlan', 'c-vlan', 'double tag'],
    facts: {
      'Outer tag': 'S-VLAN, EtherType 0x88A8',
      'Inner tag': 'C-VLAN, 0x8100',
      'Overhead': '4 bytes',
      'Standard': '802.1ad',
    },
  ),
  NetworkTech(
    id: 'lacp',
    name: 'LACP',
    aliases: [
      'lacp',
      'etherchannel',
      'link aggregation',
      'port-channel',
      '802.3ad',
    ],
    summary:
        'LACP negotiates a bundle of parallel links into one logical port, so '
        'bandwidth and redundancy increase without a spanning-tree blocked '
        'link.',
    mechanism:
        'Both ends exchange LACPDUs with a system ID, port priority and key. '
        'Matching key, speed, duplex, MTU and VLAN configuration allows the '
        'links to bundle; the active/standby split keeps at most eight active '
        'members (16 maximum) with the rest hot standby. Forwarding is hashed '
        'per flow over the active members, so a single flow uses one link. '
        'Short timers (1 s, 3 s timeout) detect a member failure faster than '
        'long timers (30 s, 90 s).',
    whenToUse:
        'Switch-to-switch uplinks, server dual-homing and any place where two '
        'or more physical links should act as one. LACP is preferred over a '
        'static bundle because it detects a one-sided misconfiguration.',
    tradeoffs:
        'Per-flow hashing means a single large flow never exceeds one member. '
        'A member that fails without LACP notification (a unidirectional '
        'fault) can black-hole the flows hashed to it. And a misconfigured '
        'member is suspended rather than forwarded, which is safer but looks '
        'like a dead link.',
    commands:
        'interface range GigabitEthernet1/0/1-2\n'
        ' channel-group 10 mode active\n'
        'interface Port-channel10\n'
        ' switchport mode trunk\n'
        ' switchport trunk allowed vlan 10,20\n'
        ' lacp rate fast',
    verify:
        'show etherchannel summary (the flags: SU is in use, s is suspended), '
        'show lacp neighbor (the peer system ID and port state), and show '
        'etherchannel port-channel for the hash distribution.',
    pitfalls:
        'One member with a different speed silently prevents the bundle. A '
        'static side against an LACP side never comes up. And hashing that is '
        'not tuned leaves one member at 90% while the others idle.',
    aspects: ['hashing', 'active', 'passive', 'member'],
    facts: {
      'Max members': '16 (8 active)',
      'Short timer': '1 s, 3 s timeout',
      'Long timer': '30 s, 90 s timeout',
      'Hashing': 'Per flow, not per packet',
    },
  ),
  NetworkTech(
    id: 'capwap',
    name: 'CAPWAP',
    aliases: ['capwap', 'split mac', 'ap join', 'capwap tunnel'],
    summary:
        'CAPWAP is the tunnel between a lightweight access point and a '
        'wireless controller, carrying control and data over UDP.',
    mechanism:
        'The AP discovers the controller by DHCP option 43, DNS or broadcast, '
        'joins over CAPWAP control (UDP 5246) and sets up a data tunnel (UDP '
        '5247). In split-MAC, the AP handles real-time 802.11 functions '
        '(beacons, ACKs, encryption) and the controller handles '
        'authentication, roaming and policy. Control traffic is DTLS-encrypted '
        'by default; data can be tunnelled to the controller (centralised) or '
        'switched locally at the AP (flexconnect/local switching).',
    whenToUse:
        'Any managed wireless deployment where central policy, roaming and '
        'RF management matter. Local switching is used when traffic should '
        'break out at the branch instead of crossing the WAN to the '
        'controller.',
    tradeoffs:
        'Centralised data tunnelling adds latency and WAN load, and the '
        'controller is a scaling and failure point. Split-MAC means the AP '
        'depends on the controller for new joins. MTU and firewall rules for '
        '5246/5247 are a common deployment blocker.',
    commands:
        'interface GigabitEthernet0/1\n'
        ' switchport mode trunk\n'
        ' switchport trunk native vlan 10\n'
        ' ! AP gets its address from DHCP with option 43 = controller IP\n'
        'ap profile default\n'
        ' hyperlocation enable',
    verify:
        'On the controller: show ap summary (APs joined and their state), show '
        'ap config general (the AP IP and controller), show capwap summary. On '
        'the switch: the AP is in the right VLAN and can reach the controller '
        'on 5246/5247.',
    pitfalls:
        'AP stuck in "discovering" is almost always DHCP option 43 or a '
        'firewall on 5246. A native VLAN mismatch puts the AP in the wrong '
        'subnet. And centralised data tunnelling across a slow WAN makes '
        'roaming and voice unusable.',
    aspects: ['ap join', 'split mac', 'local switching', 'option 43'],
    facts: {
      'Control': 'UDP 5246 (DTLS)',
      'Data': 'UDP 5247',
      'Discovery': 'DHCP 43, DNS, broadcast',
      'Modes': 'Local (tunnelled) or flexconnect',
    },
  ),
  NetworkTech(
    id: 'wifi6',
    name: 'Wi-Fi 6 (802.11ax)',
    aliases: ['wifi 6', 'wifi6', '802.11ax'],
    summary:
        'Wi-Fi 6 raises efficiency, not just peak rate: OFDMA, MU-MIMO, '
        'BSS colouring and target wake time make a dense network work better.',
    mechanism:
        'OFDMA divides a channel into resource units so several clients '
        'transmit in one time slot instead of waiting their turn; MU-MIMO '
        'serves several clients spatially; 1024-QAM raises the peak rate when '
        'the signal is very good. BSS colouring tags frames from neighbouring '
        'APs so a client can ignore an overlapping basic service set instead '
        'of deferring to it, and target wake time lets IoT devices sleep and '
        'schedule their wake windows. Wi-Fi 6E extends the same technology '
        'into the 6 GHz band, which has no legacy clients and 59 clean 20 MHz '
        'channels.',
    whenToUse:
        'Dense environments - offices, stadiums, schools, warehouses - where '
        'the problem is many clients and airtime, not peak throughput on one '
        'laptop. 6E is the right choice when you can control the client mix '
        'and want clean spectrum.',
    tradeoffs:
        'The efficiency gains need Wi-Fi 6 clients; legacy clients still '
        'consume airtime the old way. 6 GHz has shorter range and needs more '
        'APs, and its clients may not roam back to 5 GHz sensibly. And a wide '
        'channel in a dense area still hurts, whatever the generation.',
    commands:
        'ap profile WIFI6\n'
        ' dot11ax enable\n'
        ' dot11 5ghz channel-width 40\n'
        ' dot11 6ghz enable\n'
        ' ! keep 20/40 MHz in dense areas, not 80/160',
    verify:
        'show ap summary (the radio and band), show ap auto-rf (channel and '
        'width), and a client view showing the negotiated PHY rate, RSSI and '
        'retry rate. A high retry rate at good RSSI is usually co-channel '
        'interference, not a bad AP.',
    pitfalls:
        'Turning on 80 MHz everywhere in a dense office. Leaving legacy rates '
        'enabled so one old client slows the whole cell. And assuming 6 GHz '
        'coverage equals 5 GHz coverage - it does not, so the AP count must '
        'increase.',
    aspects: ['ofdma', 'bss coloring', '6 ghz', 'twt'],
    facts: {
      'Bands': '2.4, 5, 6 GHz (6E)',
      'Max width': '160 MHz',
      'Modulation': '1024-QAM',
      'Key gain': 'Efficiency (OFDMA), not peak rate',
    },
  ),
  NetworkTech(
    id: 'wifi7',
    name: 'Wi-Fi 7 (802.11be)',
    aliases: ['wifi 7', 'wifi7', '802.11be', 'multi-link operation', 'mlo'],
    summary:
        'Wi-Fi 7 adds 320 MHz channels, 4096-QAM and multi-link operation, so '
        'a client can use several bands at once and survive interference on '
        'one of them.',
    mechanism:
        'Multi-link operation (MLO) lets a client associate on 2.4, 5 and 6 '
        'GHz simultaneously and move a flow between links without a '
        'reassociation, which cuts latency and improves reliability. 320 MHz '
        'channels and 4096-QAM raise the peak rate, and multi-RU and '
        'puncturing let the AP use a channel even when part of it is '
        'interfered with. The gains depend heavily on the client and on clean '
        'spectrum - 320 MHz fits only in 6 GHz.',
    whenToUse:
        'High-density, high-throughput environments with a modern client mix: '
        'AR/VR, 8K video, dense offices, and venues that want headroom for the '
        'next five years. It is an access-layer upgrade, not a fix for poor '
        'coverage.',
    tradeoffs:
        'Early hardware is expensive, 320 MHz channels reduce reuse, and '
        'benefits are invisible to Wi-Fi 5/6 clients. MLO behaviour across '
        'vendors is still maturing, and the AP power budget and cabling may '
        'need an upgrade.',
    commands:
        'ap profile WIFI7\n'
        ' dot11be enable\n'
        ' dot11 6ghz channel-width 320\n'
        ' dot11 5ghz channel-width 80\n'
        ' ! 320 MHz is a 6 GHz-only decision',
    verify:
        'show ap summary and the client detail view for the MLO links, the '
        'negotiated width and the retry rate. Test with a Wi-Fi 7 client, not '
        'an older laptop, or you are measuring the client.',
    pitfalls:
        'Deploying 320 MHz in a multi-AP design and wondering why co-channel '
        'interference got worse. Expecting MLO to fix sticky clients. And '
        'upgrading APs without upgrading PoE or the uplink, so the radio is '
        'faster than the wire.',
    aspects: ['mlo', '320 mhz', '4096-qam', 'puncturing'],
    facts: {
      'Max width': '320 MHz (6 GHz)',
      'Modulation': '4096-QAM',
      'Key gain': 'MLO and puncturing',
      'Bands': '2.4, 5, 6 GHz',
    },
  ),
  NetworkTech(
    id: 'roaming',
    name: 'Wi-Fi roaming',
    aliases: [
      'roaming',
      'fast roaming',
      '802.11r',
      '802.11k',
      '802.11v',
      'okc',
      'sticky client',
    ],
    summary:
        'Roaming is the client moving from one AP to another without losing '
        'its session; 802.11k/v/r and a sane RF design make it fast and '
        'predictable.',
    mechanism:
        'The client decides to roam, usually when RSSI drops below its own '
        'threshold - which is why a sticky client stays on a far AP. 802.11k '
        'gives the client a neighbour report so it knows which APs are '
        'candidates; 802.11v sends a BSS transition request so the '
        'infrastructure can suggest a better AP; 802.11r (fast BSS transition) '
        'pre-authenticates the new AP so the 802.1X exchange does not repeat. '
        'OKC and PMK caching achieve a similar result on older clients. The '
        'new AP must be on the same mobility domain and VLAN, or the client '
        'gets a new address and the session breaks.',
    whenToUse:
        'Any multi-AP deployment, and specifically voice and clinical '
        'environments where a 2-second roam drops a call. The three standards '
        'should be enabled together, not selectively.',
    tradeoffs:
        'Not every client implements k/v/r, and some implement r badly, so a '
        'mixed client fleet needs testing. Fast transition across VLANs is '
        'harder. And tuning roaming without fixing coverage just moves the '
        'cliff.',
    commands:
        'ap profile ROAM\n'
        ' dot11k enable\n'
        ' dot11v enable\n'
        ' dot11r enable\n'
        ' ! mobility domain and VLAN must match on both APs',
    verify:
        'A client roam trace on the controller (the roam time, the old and new '
        'AP, the reason), packet capture of the reassociation, and the ping '
        'loss during the roam. Under 50 ms is good for voice; over 200 ms is a '
        'call drop.',
    pitfalls:
        'Turning on 802.11r for clients that do not support it, which can '
        'prevent association entirely. Roaming between APs on different VLANs '
        'without a mobility tunnel. And a minimum RSSI set so aggressively '
        'that clients bounce between APs.',
    aspects: ['802.11r', 'sticky client', 'mobility domain', 'fast transition'],
    facts: {
      'Neighbour report': '802.11k',
      'Transition request': '802.11v',
      'Fast transition': '802.11r',
      'Target roam': 'Under 50 ms for voice',
    },
  ),
  NetworkTech(
    id: 'eap-tls',
    name: 'EAP-TLS',
    aliases: [
      'eap-tls',
      'eap tls',
      'certificate authentication',
      'peap',
      'eap',
    ],
    summary:
        'EAP-TLS authenticates both the client and the server with '
        'certificates, which removes the password from 802.1X entirely.',
    mechanism:
        'The supplicant presents a client certificate and the server presents '
        'its own; both validate the chain against a trusted CA. Because the '
        'client proves possession of a private key, there is no password to '
        'phish or reuse. The certificate is usually provisioned by MDM or '
        'Active Directory auto-enrolment, and the identity in the certificate '
        'is what the RADIUS policy evaluates. PEAP/MSCHAPv2 is the common '
        'alternative; it authenticates the server with a certificate but the '
        'user with a password inside the TLS tunnel.',
    whenToUse:
        'Corporate wireless and wired 802.1X where you can manage certificates '
        'on the endpoints. It is the right choice for machine authentication, '
        'headless devices and a zero-trust posture.',
    tradeoffs:
        'Certificate lifecycle is the hard part: expiry, renewal and revocation '
        'must be automated or you will have an outage on a fixed date. The CA '
        'itself becomes critical infrastructure. And a client with a valid '
        'certificate is trusted, so device posture is a separate control.',
    commands:
        '! RADIUS policy: EAP-TLS only, validate the client chain\n'
        'aaa authentication dot1x default group radius\n'
        'dot1x system-auth-control\n'
        'interface GigabitEthernet1/0/2\n'
        ' authentication port-control auto\n'
        ' dot1x pae authenticator',
    verify:
        'The RADIUS log for the client certificate subject and the chain '
        'result, show authentication sessions on the switch, and a test with '
        'an expired certificate to confirm it is actually rejected.',
    pitfalls:
        'An expired CA or client certificate takes the whole fleet offline. A '
        'server certificate with the wrong SAN. And trusting any certificate '
        'from the CA without checking the template, so a user certificate '
        'authenticates a machine.',
    aspects: ['certificate', 'radius', 'supplicant', 'peap'],
    facts: {
      'Client auth': 'Certificate',
      'Server auth': 'Certificate',
      'Password': 'None',
      'Alternative': 'PEAP/MSCHAPv2',
    },
  ),
  NetworkTech(
    id: 'cloud-tgw',
    name: 'Cloud transit gateway',
    aliases: ['transit gateway', 'tgw', 'hub and spoke cloud', 'cloud hub'],
    summary:
        'A transit gateway is a regional router that connects many VPCs, VPNs '
        'and on-premises links through one attachment point instead of a full '
        'mesh of peerings.',
    mechanism:
        'Each VPC attaches to the transit gateway, and the gateway route table '
        'decides which attachments can reach which prefixes. Route tables can '
        'be segmented (prod, dev, shared services) so a default route in one '
        'segment does not leak into another. VPN and Direct Connect attach to '
        'the same gateway, which makes hybrid routing one policy problem '
        'instead of N. It is regional; multi-region designs peer gateways or '
        'use a global backbone.',
    whenToUse:
        'More than a handful of VPCs, a hybrid connection that must reach many '
        'networks, or a landing zone with separate prod/dev/shared segments. '
        'Below that, VPC peering is cheaper and simpler.',
    tradeoffs:
        'It costs per attachment and per GB, and it adds a hop and an '
        'attachment limit. Route tables multiply and a misassociated table is '
        'a silent black hole. It does not solve overlapping CIDRs - that is '
        'still a NAT or re-IP problem.',
    commands:
        '! AWS CLI sketch\n'
        'aws ec2 create-transit-gateway --description core\n'
        'aws ec2 create-transit-gateway-vpc-attachment \\\n'
        '  --transit-gateway-id tgw-123 --vpc-id vpc-123 \\\n'
        '  --subnet-ids subnet-123\n'
        'aws ec2 associate-transit-gateway-route-table \\\n'
        '  --transit-gateway-route-table-id tgw-rtb-123 \\\n'
        '  --transit-gateway-attachment-id tgw-attach-123',
    verify:
        'The attachment state is available, the association and propagation '
        'are correct for each VPC, and a reachability test from a source in '
        'one VPC to a destination in another. Flow logs show whether the '
        'packet left the source VPC.',
    pitfalls:
        'Forgetting to associate a VPC attachment with a route table, so it '
        'can send but not receive. Overlapping CIDRs across VPCs. And a '
        'default route in the shared-services table that sends all traffic to '
        'the inspection VPC and never comes back.',
    aspects: ['attachment', 'route table', 'segmentation'],
    facts: {
      'Scope': 'Regional',
      'Connects': 'VPCs, VPN, Direct Connect',
      'Replaces': 'Full-mesh peering',
      'Limit': 'Attachments and routes per gateway',
    },
  ),
  NetworkTech(
    id: 'private-link',
    name: 'PrivateLink / Private Endpoint',
    aliases: [
      'private link',
      'privatelink',
      'vpc endpoint',
      'private endpoint',
      'service endpoint',
    ],
    summary:
        'A private endpoint puts a managed service on a private IP inside your '
        'VPC, so traffic never crosses the public internet.',
    mechanism:
        'The service is exposed through a network load balancer and an '
        'endpoint service; the consumer creates an interface endpoint, which '
        'places an elastic network interface with a private IP in a chosen '
        'subnet. DNS resolves the service name to that private address, so the '
        'application connects exactly as before. Security groups on the '
        'endpoint control access, and the service owner controls who may '
        'connect. Gateway endpoints (S3, DynamoDB) are a different mechanism: '
        'a route-table entry, no ENI, no security group.',
    whenToUse:
        'Consuming a SaaS or internal service privately, meeting a compliance '
        'requirement that traffic not traverse the internet, and avoiding NAT '
        'gateway data charges for service traffic.',
    tradeoffs:
        'It is per-service and per-AZ, so cost and DNS complexity grow. '
        'Interface endpoints need a security group and a private DNS override. '
        'Gateway endpoints cannot be reached from on-premises through a '
        'transit gateway without extra design.',
    commands:
        'aws ec2 create-vpc-endpoint \\\n'
        '  --vpc-id vpc-123 --service-name com.amazonaws.region.s3 \\\n'
        '  --vpc-endpoint-type Interface \\\n'
        '  --subnet-ids subnet-123 --security-group-ids sg-123 \\\n'
        '  --private-dns-enabled',
    verify:
        'The endpoint state is available, DNS from inside the VPC resolves to '
        'the private IP, and a connection test succeeds while the public '
        'endpoint is blocked. Flow logs show the ENI address, not the public '
        'one.',
    pitfalls:
        'Forgetting private DNS, so the application still resolves the public '
        'name. A security group that allows the client but not the ephemeral '
        'return. And assuming a gateway endpoint works from another region or '
        'from on-premises - it does not.',
    aspects: ['endpoint', 'dns', 'gateway endpoint'],
    facts: {
      'Interface endpoint': 'ENI with a private IP',
      'Gateway endpoint': 'Route table, S3/DynamoDB',
      'DNS': 'Private hosted zone override',
      'Traffic': 'Never public',
    },
  ),
  NetworkTech(
    id: 'campus-design',
    name: 'Campus LAN design',
    aliases: [
      'campus',
      'campus design',
      'campus network',
      'campus lan',
      'three tier',
      'collapsed core',
      'access layer design',
      'closet',
    ],
    summary:
        'A campus is an access layer sized by ports and PoE, a distribution '
        'layer that aggregates and routes, and a core that connects buildings '
        'and the data center - with redundancy at every layer that matters.',
    mechanism:
        'Access switches sit in wiring closets, one per floor or per zone, and '
        'connect to distribution over fibre, usually in a redundant pair. '
        'Distribution is the layer-3 boundary in a modern design: SVIs, DHCP '
        'relay, policy and summarization toward the core. The core is a small, '
        'fast, highly available block that connects distribution blocks, the '
        'data center and the WAN edge. Sizing starts from port count and cable '
        'length, not from user count: a 48-port switch per closet, a fibre '
        'pair per uplink, and a PoE budget that covers the phones and APs with '
        'headroom.',
    whenToUse:
        'Any building or group of buildings with more than a handful of '
        'closets. A single small site can collapse core and distribution into '
        'one pair if the failure domain and port count allow it.',
    tradeoffs:
        'Three tiers add a hop and cost; a collapsed core is simpler and '
        'cheaper but concentrates risk. Layer-2 access with layer-3 '
        'distribution is the common compromise: simple host configuration, '
        'controlled broadcast domains, and routing where it is cheap. Every '
        'layer of redundancy costs ports and complexity, so match it to the '
        'actual outage cost.',
    commands:
        '! Distribution SVI and relay\n'
        'interface Vlan100\n'
        ' ip address 10.10.100.1 255.255.255.0\n'
        ' ip helper-address 10.10.0.10\n'
        ' standby 100 ip 10.10.100.254\n'
        ' standby 100 priority 110\n'
        ' standby 100 preempt',
    verify:
        'Per-closet port count and PoE headroom, uplink utilisation, STP root '
        'placement (the distribution pair should be root), HSRP/VRRP state, '
        'and a failure test: pull one distribution uplink and confirm the '
        'closet stays up with no more than a short interruption.',
    pitfalls:
        'Sizing by user count and running out of PoE or ports. One uplink per '
        'closet with no redundant path. STP root left on a random access '
        'switch, so traffic takes a silly path. And a flat VLAN across the '
        'whole campus, which makes every broadcast everyone else problem.',
    aspects: ['three tier', 'collapsed core', 'closet', 'sizing', 'redundancy'],
    facts: {
      'Access': '48-port, PoE, one per closet',
      'Distribution': 'L3 boundary, SVIs, summarization',
      'Core': 'Fast, redundant, few ports',
      'Uplink': 'Fibre, redundant pair',
    },
  ),
  NetworkTech(
    id: 'l2-vs-l3-access',
    name: 'Layer-2 vs layer-3 access',
    aliases: [
      'l2 access',
      'l3 access',
      'layer 2 access',
      'layer 3 access',
      'routed access',
      'l2 vs l3 access',
      'l2 and l3 to the access',
      'l2 or l3 to the access',
      'layer 2 or layer 3 to the access',
    ],
    summary:
        'Layer-2 access keeps VLANs and STP in the closet and routes at '
        'distribution; layer-3 access routes at the closet and removes STP from '
        'the access layer entirely.',
    mechanism:
        'In an L2 access design, the access switch is a bridge: the SVI lives '
        'on the distribution pair, HSRP/VRRP provides the gateway, and STP '
        'blocks the redundant uplink. Broadcasts stay inside the VLAN, which '
        'spans closets. In an L3 access design, each access switch runs OSPF '
        'or EIGRP on its uplinks, the gateway is on the closet, and the '
        'uplinks are routed point-to-point links. STP still exists but only '
        'inside the closet; the uplink redundancy is handled by ECMP and '
        'routing convergence.',
    whenToUse:
        'L2 access for small and medium sites, and where a VLAN must span '
        'floors (legacy applications, some virtualisation). L3 access for large '
        'campuses, data centers and any design where fast convergence and '
        'bounded failure domains matter more than flat VLANs.',
    tradeoffs:
        'L2 access is simpler for hosts and for moves, adds and changes, but '
        'grows one big STP domain and a single VLAN can take down a building. '
        'L3 access scales and converges faster but needs an IP plan per closet, '
        'more routing configuration, and a clear summarization scheme.',
    commands:
        '! L3 access uplink\n'
        'interface GigabitEthernet1/0/49\n'
        ' no switchport\n'
        ' ip address 10.255.1.2 255.255.255.252\n'
        ' ip router ospf 1 area 0\n'
        'interface Vlan100\n'
        ' ip address 10.10.100.1 255.255.255.0',
    verify:
        'The access switch has an adjacency on its uplink and a route to the '
        'core, the host gateway is local, and a failure test on one uplink '
        'converges without STP. In L2 access, verify the root bridge and the '
        'blocked port are where the design says.',
    pitfalls:
        'L3 access with no summarization, so every closet carries the whole '
        'campus table. An L2 design where the VLAN spans buildings and a loop '
        'takes out the site. And mixing both models without a clear boundary, '
        'which is how you get an asymmetric path nobody can explain.',
    aspects: ['routed access', 'stp domain', 'summarization'],
    facts: {
      'L2 access gateway': 'Distribution SVI + HSRP',
      'L3 access gateway': 'Access SVI, routed uplink',
      'STP scope': 'Whole L2 domain vs closet only',
      'Failure domain': 'Large vs small',
    },
  ),
  NetworkTech(
    id: 'failure-domain',
    name: 'Failure domain',
    aliases: [
      'failure domain',
      'blast radius',
      'fault domain',
      'redundancy design',
    ],
    summary:
        'A failure domain is everything that stops working when one component '
        'fails; good design makes it as small as the business can tolerate.',
    mechanism:
        'Failure domains are created by topology and by protocol scope: a '
        'VLAN is a broadcast domain and usually a failure domain, an OSPF area '
        'bounds SPF, a spanning-tree domain bounds a loop, and a power feed or '
        'a single uplink bounds a closet. Redundancy reduces the probability '
        'of a failure; segmentation reduces the impact. N+1 means one spare '
        'component, 2N means full duplication, and neither helps if both paths '
        'share a conduit or a power strip.',
    whenToUse:
        'Every design review. State the failure domains explicitly: what '
        'happens if a closet switch dies, an uplink fails, a distribution pair '
        'loses one member, the core loses a line card, or the WAN edge fails.',
    tradeoffs:
        'Small failure domains cost more (more subnets, more routing, more '
        'links). Large ones are cheaper and simpler until the day they are '
        'not. The right size is set by how long an outage is acceptable, not '
        'by a preference for symmetry.',
    commands: '',
    verify:
        'Walk the failure modes on the diagram: remove each link, each switch '
        'and each power feed in turn, and check that the remaining path is '
        'real and not sharing a physical conduit. Then test one in a change '
        'window.',
    pitfalls:
        'Two "redundant" fibre paths in the same duct. A vPC pair on the same '
        'power feed. A default route that points at a single firewall with no '
        'state sharing. And a design that survives a link failure but not a '
        'line-card failure.',
    aspects: ['blast radius', 'n+1', '2n', 'segmentation'],
    facts: {
      'Broadcast domain': 'VLAN',
      'Routing domain': 'OSPF area / IS-IS level',
      'Redundancy': 'N+1 or 2N',
      'Real limit': 'Shared conduit, power, or state',
    },
  ),
  NetworkTech(
    id: 'convergence',
    name: 'Network convergence',
    aliases: [
      'convergence',
      'fast convergence',
      'sub second convergence',
      'failover time',
    ],
    summary:
        'Convergence is the time from a failure to every router forwarding on '
        'the new path: detect, propagate, compute, install.',
    mechanism:
        'Detection is the protocol hello or BFD: OSPF waits 40 s by default, '
        'EIGRP 15 s, BFD about 150 ms. Propagation floods the change; '
        'computation runs SPF or the diffusing update; installation writes the '
        'new prefix into the FIB. Each phase can dominate, and tuning the hello '
        'timer alone rarely reaches the target because SPF and FIB update still '
        'cost time. Fast reroute (FRR, TI-LFA) pre-computes the backup so the '
        'data plane switches before the control plane converges.',
    whenToUse:
        'Design reviews and any SLA that names a failover time. Voice, video, '
        'financial trading and industrial control have hard numbers; a general '
        'office can tolerate seconds.',
    tradeoffs:
        'Aggressive detection flaps on a marginal link, and pre-computed '
        'backup paths consume memory and require a topology that supports '
        'them. Hierarchical design (areas, summarization) speeds computation '
        'at the cost of optimal routing.',
    commands:
        'interface GigabitEthernet0/0\n'
        ' bfd interval 50 min_rx 50 multiplier 3\n'
        'router ospf 1\n'
        ' bfd all-interfaces\n'
        ' timers throttle spf 10 100 5000',
    verify:
        'Measure it: shut a link in a lab and time the ping loss, or use the '
        'protocol event log timestamps. show ip ospf stat and show ip route '
        'summary before and after. The number you measure is the only number '
        'that matters.',
    pitfalls:
        'Tuning hellos on a WAN that jitters, causing more outages than it '
        'prevents. Forgetting the FIB installation phase. And a backup path '
        'that is longer than the failure it protects against.',
    aspects: ['detection', 'spf', 'fib', 'fast reroute'],
    facts: {
      'OSPF default': 'Hello 10 s, dead 40 s',
      'EIGRP default': 'Hello 5 s, hold 15 s',
      'BFD': 'About 150 ms at 50 ms x 3',
      'Target': 'Sub-second enterprise, 50 ms carrier',
    },
  ),
  NetworkTech(
    id: 'copp',
    name: 'CoPP (control plane policing)',
    aliases: [
      'copp',
      'control plane policing',
      'control plane protection',
      'protect the control plane',
      'cppr',
    ],
    summary:
        'CoPP rate-limits the traffic that is destined to the router itself, '
        'so a storm or a scan cannot starve routing protocols and management.',
    mechanism:
        'A policy-map attached to the control plane classifies punted traffic '
        '(routing protocols, ICMP, SSH, SNMP, ARP, BGP) and applies a policer '
        'per class. Traffic above the rate is dropped, not queued, which '
        'protects the CPU at the cost of the excess. It is the router '
        'equivalent of a bouncer: it does not make the attack disappear, it '
        'keeps the control plane alive while the attack is handled.',
    whenToUse:
        'Every internet-facing router and every large campus core. It is also '
        'the first thing to check when CPU is high and the cause is not obvious.',
    tradeoffs:
        'A policer set too low drops legitimate BGP updates or OSPF hellos, '
        'which looks like a routing bug. It is platform-specific and the '
        'default policies differ, so a copied config may not fit. And it does '
        'not protect the forwarding plane from a data-plane flood.',
    commands:
        'class-map match-any CONTROL\n'
        ' match protocol bgp\n'
        ' match protocol ospf\n'
        'policy-map CONTROL-PLANE\n'
        ' class CONTROL\n'
        '  police 5000000 conform-action transmit exceed-action drop\n'
        'control-plane\n'
        ' service-policy input CONTROL-PLANE',
    verify:
        'show policy-map control-plane (per-class rates and drops), show '
        'processes cpu sorted during the event, and a BGP/OSPF neighbour check '
        'after applying it - the adjacency must stay up.',
    pitfalls:
        'Policing all traffic in one class, so a scan drops the routing '
        'protocols with it. Setting the rate from a lab number instead of the '
        'platform guidance. And enabling it during an incident instead of '
        'before one.',
    aspects: ['policer', 'control plane', 'punt'],
    facts: {
      'Protects': 'Traffic to the router',
      'Action': 'Police, excess dropped',
      'Attached': 'control-plane service-policy',
      'Risk': 'Rate too low drops adjacencies',
    },
  ),
  NetworkTech(
    id: 'urpf',
    name: 'uRPF',
    aliases: [
      'urpf',
      'unicast reverse path forwarding',
      'reverse path forwarding',
      'ip verify unicast',
    ],
    summary:
        'uRPF drops a packet whose source address does not route back out the '
        'interface it arrived on, which blocks spoofed source addresses.',
    mechanism:
        'Strict mode checks that the reverse path to the source is the '
        'receiving interface - correct for a stub or a symmetrical design, but '
        'it breaks any asymmetric path. Loose mode checks only that a route to '
        'the source exists anywhere, which blocks obvious spoofing without '
        'requiring symmetry. Feasible mode uses the RPF table plus a '
        'reachability check. It is the layer-3 complement to IP Source Guard.',
    whenToUse:
        'Internet edges (strict where the topology is clean, loose where it is '
        'not) and any access layer that must stop source spoofing. It is also '
        'a useful diagnostic: an unexplained drop with a valid route is often '
        'uRPF.',
    tradeoffs:
        'Strict mode plus asymmetric routing equals a silent outage. Loose '
        'mode is weaker but safe. It adds a lookup per packet on some '
        'platforms, and it does nothing for spoofing that uses a valid source.',
    commands:
        'interface GigabitEthernet0/0\n'
        ' ip verify unicast source reachable-via rx\n'
        ' ! loose mode:\n'
        ' ip verify unicast source reachable-via any',
    verify:
        'show ip interface GigabitEthernet0/0 | include verify, the interface '
        'counters for drops, and a test ping with a spoofed source (lab only). '
        'A sudden one-way failure after enabling strict mode is the signature.',
    pitfalls:
        'Strict uRPF on a dual-homed or asymmetric network. Enabling it on the '
        'wrong interface direction. And assuming it validates the destination '
        '- it validates the source.',
    aspects: ['strict', 'loose', 'spoofing'],
    facts: {
      'Strict': 'Reverse path is the receiving interface',
      'Loose': 'Any route to the source exists',
      'Layer': 'Layer 3 ingress',
      'Equivalent': 'IP Source Guard at layer 2',
    },
  ),
  NetworkTech(
    id: 'rpki',
    name: 'RPKI',
    aliases: [
      'rpki',
      'route origin validation',
      'roa',
      'bgp hijack',
      'origin validation',
    ],
    summary:
        'RPKI lets a network publish signed statements about which AS may '
        'originate which prefix, so a BGP router can reject hijacks.',
    mechanism:
        'A prefix holder creates a Route Origin Authorization (ROA) naming the '
        'prefix, the maximum length and the authorised origin AS. Validators '
        'build a cache from the distributed repositories, and routers fetch it '
        'over RTR (TCP 323) and mark each BGP path as valid, invalid or not '
        'found. A typical policy accepts valid and not-found, and drops '
        'invalid - which is the actual protection. ASPA adds the missing '
        'half: validating the full AS path, not just the origin.',
    whenToUse:
        'Every network that accepts a full internet table. It is the cheapest '
        'real improvement to internet routing security, and it is now expected '
        'at transit edges.',
    tradeoffs:
        'A missing or wrong ROA marks legitimate prefixes invalid, so a '
        'drop-invalid policy can black-hole a customer. The validator cache is '
        'a dependency. And RPKI only validates the origin, not the path, so it '
        'does not stop every hijack.',
    commands:
        'router bgp 65000\n'
        ' bgp rpki server tcp 10.0.0.50 port 323 refresh 60\n'
        ' route-map RPKI-IN permit 10\n'
        '  match rpki valid\n'
        ' route-map RPKI-IN permit 20\n'
        '  match rpki not-found\n'
        ' route-map RPKI-IN deny 30',
    verify:
        'show bgp rpki server (the cache connection and prefix counts), show '
        'ip bgp <prefix> (the RPKI state per path), and a lab prefix with a '
        'deliberately wrong ROA to prove the policy drops it.',
    pitfalls:
        'Dropping not-found as well as invalid, which removes most of the '
        'internet. A stale validator cache. And ROAs with a max length that '
        'does not cover the more-specifics actually announced.',
    aspects: ['roa', 'invalid', 'validator', 'hijack'],
    facts: {
      'Record': 'ROA (prefix, max length, origin AS)',
      'Transport': 'RTR, TCP 323',
      'States': 'Valid, invalid, not found',
      'Policy': 'Accept valid and not-found, drop invalid',
    },
  ),
  NetworkTech(
    id: 'ospfv3',
    name: 'OSPFv3',
    aliases: ['ospfv3', 'ospf v3', 'ospf for ipv6', 'ipv6 ospf'],
    summary:
        'OSPFv3 is OSPF for IPv6: the same SPF and areas, but it runs per link '
        'instead of per subnet and authenticates with IPsec rather than its own '
        'header.',
    mechanism:
        'OSPFv3 is enabled on an interface, not by a network statement; the '
        'router ID is still a 32-bit IPv4-style value and must be unique. '
        'Hellos go to ff02::5 (all OSPF routers) and ff02::6 (DR/BDR) and use '
        'the link-local address as source, so two routers can form an '
        'adjacency even if their global prefixes disagree. The LSA types are '
        'the same idea with new names: router, network, inter-area prefix, '
        'inter-area router, AS-external, NSSA and link LSAs. Authentication is '
        'not in the OSPF header - it uses IPsec AH or ESP, which is why the '
        'old plaintext authentication commands do not exist.',
    whenToUse:
        'Any dual-stack network that already runs OSPF and wants one IGP for '
        'both families, and IPv6-only networks that need hierarchy and '
        'summarization.',
    tradeoffs:
        'Two address families mean two LSDBs and double the memory and SPF '
        'work unless you use the address-family model carefully. IPv6 '
        'neighbours over link-local addresses make some verification commands '
        'less obvious. And IPsec authentication adds configuration that OSPFv2 '
        'did not need.',
    commands:
        'ipv6 unicast-routing\n'
        'interface GigabitEthernet0/0\n'
        ' ipv6 address 2001:db8:1::1/64\n'
        ' ipv6 ospf 1 area 0\n'
        ' ipv6 ospf authentication ipsec spi 500 sha1 SECRET\n'
        'router ospfv3 1\n'
        ' router-id 10.0.0.1\n'
        ' address-family ipv6 unicast\n'
        '  passive-interface default\n'
        '  no passive-interface GigabitEthernet0/0',
    verify:
        'show ospfv3 neighbor (state and the interface it formed on), show '
        'ospfv3 interface (timers, DR, and the link-local peers), show ospfv3 '
        'database, and show ipv6 route ospf.',
    pitfalls:
        'No router-id, so the adjacency never forms. Enabling OSPFv3 on the '
        'interface but not globally. A link-local-only adjacency with '
        'mismatched global prefixes, which looks up but forwards nothing. And '
        'forgetting that the old authentication commands are rejected.',
    aspects: ['link local', 'ipsec', 'address family', 'router id'],
    facts: {
      'Multicast': 'ff02::5, ff02::6',
      'Enable on': 'Interface, not network statement',
      'Authentication': 'IPsec AH/ESP',
      'Router ID': '32-bit, required',
    },
  ),
  NetworkTech(
    id: 'slaac',
    name: 'SLAAC',
    aliases: [
      'slaac',
      'stateless address autoconfiguration',
      'router advertisement',
      'ra',
      'autoconfiguration',
    ],
    summary:
        'SLAAC lets an IPv6 host build its own address from a router '
        'advertisement, with no DHCP server involved.',
    mechanism:
        'The host sends a router solicitation to ff02::2, the router answers '
        'with a router advertisement containing a prefix and flags. With the '
        'autonomous flag set, the host forms an interface identifier (EUI-64 '
        'from the MAC, or a stable-privacy value) and appends it to the /64. '
        'The M flag says "use DHCPv6 for addresses", the O flag says "use '
        'DHCPv6 for other settings"; both can be combined with SLAAC. Duplicate '
        'address detection runs before the address is used, and the default '
        'router comes from the RA with a lifetime.',
    whenToUse:
        'Networks that want zero-touch IPv6 addressing without DHCP state: '
        'campus, IoT, and any dual-stack deployment where DNS is distributed '
        'by RDNSS. DHCPv6 is still needed when you must track leases or push '
        'options that RA cannot carry.',
    tradeoffs:
        'No central lease database, so address accounting is harder. Privacy '
        'extensions change the address over time, which breaks logging that '
        'assumes a stable IP. RA Guard and DHCPv6 Guard become necessary '
        'because a rogue RA can take over the default route.',
    commands:
        'interface GigabitEthernet0/1\n'
        ' ipv6 nd ra interval 30\n'
        ' ipv6 nd prefix 2001:db8:1::/64 2592000 604800\n'
        ' ipv6 nd other-config-flag\n'
        ' ipv6 nd ra dns server 2001:db8::53',
    verify:
        'show ipv6 interface (the link-local and global address and the RA '
        'settings), show ipv6 routers on the host side, and the host address '
        'plus its default route. A host with a link-local only is not '
        'receiving RAs.',
    pitfalls:
        'Two routers advertising the same prefix with different lifetimes. A '
        'prefix length other than /64, which breaks SLAAC on most stacks. '
        'And no RDNSS, so the host has an address and no DNS.',
    aspects: ['ra', 'eui-64', 'privacy', 'dhcpv6'],
    facts: {
      'Prefix': '/64 for SLAAC',
      'RA flags': 'A, M, O',
      'DAD': 'Duplicate address detection',
      'Router solicitation': 'ff02::2',
    },
  ),
  NetworkTech(
    id: 'nd',
    name: 'IPv6 Neighbor Discovery',
    aliases: ['neighbor discovery', 'ndp', 'ipv6 nd', 'neighbour discovery'],
    summary:
        'Neighbor Discovery is IPv6 ARP, router discovery and redirect rolled '
        'into ICMPv6, and it is the protocol that makes IPv6 work on a link.',
    mechanism:
        'Router solicitation (133) and router advertisement (134) discover '
        'the default gateway and prefixes. Neighbor solicitation (135) and '
        'neighbor advertisement (136) resolve a link-layer address and perform '
        'duplicate address detection; redirect (137) tells a host about a '
        'better first hop. ND messages use hop limit 255 and are accepted only '
        'if they were not routed, which is what allows RA Guard and ND '
        'inspection to work. Neighbor cache entries move through reachable, '
        'stale, delay and probe states.',
    whenToUse:
        'Always - it is mandatory for IPv6. The design question is how to '
        'protect it: RA Guard on access ports, ND inspection, and rate limits '
        'on the ND cache.',
    tradeoffs:
        'The neighbor cache is a finite resource and a known exhaustion '
        'target; a /64 with a scan can fill it. ND has no authentication, so '
        'spoofing is trivial without RA Guard and ND inspection. And because '
        'it is ICMPv6, an ACL that blocks all ICMPv6 breaks IPv6 entirely.',
    commands:
        'interface GigabitEthernet1/0/2\n'
        ' ipv6 nd raguard attach-policy HOST\n'
        ' ipv6 nd inspection policy ND-INSPECT\n'
        ' ipv6 nd cache expire 300\n'
        ' ! never filter ICMPv6 types 133-137 on an access port',
    verify:
        'show ipv6 neighbors (state and reachability), show ipv6 nd raguard '
        'policy, and a capture of RS/RA/NS/NA. On a host, the default router '
        'and the neighbour entry for it are the two things to check first.',
    pitfalls:
        'Blocking ICMPv6 and breaking IPv6 completely. Filling the ND cache '
        'with a scan on a flat /64. And a rogue RA that becomes the default '
        'router because RA Guard was not deployed.',
    aspects: ['ns', 'na', 'ra', 'dad', 'cache'],
    facts: {
      'RS / RA': '133 / 134',
      'NS / NA': '135 / 136',
      'Redirect': '137',
      'Hop limit': '255 (not forwarded)',
    },
  ),
  NetworkTech(
    id: 'nat',
    name: 'NAT and PAT',
    aliases: [
      'nat',
      'pat',
      'network address translation',
      'port address translation',
      'source nat',
      'destination nat',
      'cgnat',
      'nat overload',
    ],
    summary:
        'NAT rewrites addresses at a translation boundary; PAT also rewrites '
        'the port so many inside hosts can share one public address.',
    mechanism:
        'A router translates the source or destination of a packet as it '
        'crosses an inside/outside interface. Static NAT maps one address to '
        'one address. Dynamic NAT maps to a pool. PAT overloads one address '
        'by rewriting the source port and keeping a translation table that '
        'maps inside address and port to outside address and port. Order '
        'matters: routing decides the egress interface, then NAT is applied, '
        'then the ACL sees the translated packet. Return traffic is matched '
        'against the table, not by a fresh route lookup. Timeouts are protocol '
        'specific: TCP established is typically 24 hours, UDP 5 minutes, ICMP '
        '1 minute, and a half-open TCP entry is much shorter.',
    whenToUse:
        'At the internet edge when private addresses must reach a public '
        'network, for publishing an internal service through destination NAT, '
        'and for overlapping address space between merged networks. IPv6 does '
        'not need it, and using it there gives up end-to-end reachability for '
        'no benefit.',
    tradeoffs:
        'It breaks end-to-end addressing, so applications that embed addresses '
        'in payloads (SIP, FTP active mode, some H.323) need an ALG or a fix. '
        'Logging becomes essential because the translation table is the only '
        'record of who did what. And a stateful firewall plus NAT doubles the '
        'state that a failover must synchronize.',
    commands:
        'interface GigabitEthernet0/0\n'
        ' ip nat outside\n'
        'interface GigabitEthernet0/1\n'
        ' ip nat inside\n'
        'ip nat inside source list 10 interface GigabitEthernet0/0 overload\n'
        'access-list 10 permit 10.0.0.0 0.0.255.255',
    verify:
        'show ip nat translations (the live table), show ip nat statistics '
        '(hits and misses), and a packet capture on both sides to prove the '
        'address actually changed. For a published service, test from outside '
        'the organization, not from a host that can route around the edge.',
    pitfalls:
        'Forgetting one interface as inside or outside, so half the flows '
        'translate and half do not. An ACL that permits the private address '
        'instead of the translated one. A SIP ALG that rewrites the wrong '
        'header. And a translation table that fills during a scan, after '
        'which every new flow fails while existing flows still work.',
    aspects: [
      'pat',
      'overload',
      'hairpin',
      'hairpinning',
      'cgnat',
      'static nat',
      'destination nat',
      'translation table',
      'alg',
    ],
    conceptOwned: true,
    facts: {
      'TCP timeout': '24 hours established',
      'UDP timeout': '5 minutes',
      'ICMP timeout': '1 minute',
      'Port range': '1024-65535 by default',
    },
  ),
  NetworkTech(
    id: 'dhcp',
    name: 'DHCP',
    aliases: [
      'dhcp',
      'dynamic host configuration protocol',
      'dhcp relay',
      'ip helper-address',
      'dhcp option 82',
      'dhcp lease',
    ],
    summary:
        'DHCP hands a host an address, a mask, a gateway, DNS servers and other '
        'options through a four-message exchange, usually through a relay.',
    mechanism:
        'The client broadcasts Discover. A relay on the segment receives it '
        'and unicasts it to the server with the gateway address (giaddr) set '
        'to the relay interface, which is how the server picks the scope. The '
        'server offers an address (Offer), the client requests it (Request) '
        'and the server acknowledges (Ack). The lease carries T1 (renew at '
        '50%) and T2 (rebind at 87.5%). Option 82 carries the circuit and '
        'remote ID so the relay can prove where the request came from. Release '
        'returns the address early; a client that cannot reach a server keeps '
        'its old lease until it expires.',
    whenToUse:
        'Every access network with endpoints. Servers, printers, network gear '
        'and anything you will firewall by address should be a reservation or '
        'a static address; a lease is for clients.',
    tradeoffs:
        'Central DHCP is simple to manage but depends on the relay path being '
        'up; a local server survives a WAN cut but multiplies the scopes. '
        'Leases are a compromise between churn absorption and address '
        'accounting: too long and a moved device holds an address, too short '
        'and a server outage becomes an address outage.',
    commands:
        'ip dhcp excluded-address 10.0.0.1 10.0.0.20\n'
        'ip dhcp pool STAFF\n'
        ' network 10.0.0.0 255.255.255.0\n'
        ' default-router 10.0.0.1\n'
        ' dns-server 10.0.0.53\n'
        ' lease 0 8\n'
        'interface Vlan10\n'
        ' ip helper-address 10.0.0.53',
    verify:
        'show ip dhcp pool (used and free), show ip dhcp binding, show ip dhcp '
        'conflict, and a client test in the furthest VLAN. On the relay, debug '
        'ip dhcp relay is noisy but proves whether the Discover arrived.',
    pitfalls:
        'A scope that does not match the relay giaddr, so the relay answers '
        'nothing. A pool with no excluded addresses, so a gateway is handed '
        'out. Option 82 changing between the relay and the server, so the '
        'server cannot classify the request. And a second rogue DHCP server on '
        'a flat segment.',
    aspects: [
      'relay',
      'helper-address',
      'option 82',
      'lease',
      't1',
      't2',
      'dora',
      'reservation',
      'scope',
    ],
    conceptOwned: true,
    facts: {
      'Messages': 'Discover, Offer, Request, Ack',
      'Server port': '67',
      'Client port': '68',
      'Renew / rebind': '50% / 87.5% of lease',
    },
  ),
  NetworkTech(
    id: 'dns',
    name: 'DNS',
    aliases: [
      'dns',
      'domain name system',
      'resolver',
      'recursive dns',
      'authoritative dns',
      'dns record',
      'dnssec',
    ],
    summary:
        'DNS turns names into addresses and service records; a resolver walks '
        'the delegation tree, and an authoritative server answers for a zone.',
    mechanism:
        'A stub resolver asks its configured recursive resolver. The resolver '
        'checks its cache, then walks the tree from the root: root servers '
        'point at the top-level domain, the TLD points at the zone, and the '
        'authoritative server returns the record or a referral. Answers carry '
        'a TTL that bounds caching. Records include A and AAAA for addresses, '
        'CNAME for an alias, MX for mail, TXT for policy and verification, SRV '
        'for service location, and PTR for reverse lookup. DNSSEC signs the '
        'zone so the resolver can prove the answer was not forged; it does not '
        'encrypt it. DoT and DoH encrypt the transport to the resolver but do '
        'not make the answer trustworthy on their own.',
    whenToUse:
        'Every network. The design decisions are where the recursive '
        'resolvers sit (local to the site, or anycast), how the zones are '
        'delegated, and whether internal names are split-horizon from public '
        'ones.',
    tradeoffs:
        'A single resolver is a single point of failure for every name lookup. '
        'Short TTLs make failover fast but raise query load; long TTLs do the '
        'opposite. Split-horizon DNS fixes internal naming but doubles the '
        'zones to keep consistent.',
    commands:
        'ip name-server 10.0.0.53 10.0.1.53\n'
        'ip domain lookup\n'
        'ip domain name example.internal\n'
        '! authoritative example on BIND or Windows DNS\n'
        '! zone example.internal { type master; file db.example; };',
    verify:
        'dig +trace example.com (the delegation path), dig @10.0.0.53 name '
        'A +short, and dig +dnssec to see the signatures. On a client, check '
        'the configured server before blaming the server itself.',
    pitfalls:
        'A resolver that recurses for the whole internet and becomes an '
        'amplification source. A zone with an NS record pointing at a name '
        'inside the same zone, which is a circular delegation. And a stale '
        'cache after a migration, which looks exactly like a broken server.',
    aspects: [
      'record',
      'ttl',
      'recursion',
      'authoritative',
      'dnssec',
      'doh',
      'dot',
      'ptr',
      'srv',
      'cname',
      'split horizon',
    ],
    conceptOwned: true,
    facts: {
      'Port': '53 UDP and TCP',
      'DoT': '853',
      'DoH': '443',
      'Root hints': '13 named servers, many anycast',
    },
  ),
  NetworkTech(
    id: 'arp',
    name: 'ARP',
    aliases: [
      'arp',
      'address resolution protocol',
      'gratuitous arp',
      'proxy arp',
      'arp cache',
      'arp table',
    ],
    summary:
        'ARP resolves an IPv4 address to a MAC address on the local segment by '
        'broadcasting a question and caching the answer.',
    mechanism:
        'The sender broadcasts "who has 10.0.0.1" with its own address and '
        'MAC. The owner replies unicast with its MAC, and both sides cache the '
        'mapping for a few minutes. A gratuitous ARP is an unsolicited reply '
        'used to announce a new address or to update caches after a failover; '
        'it is also how duplicate address detection works. Proxy ARP lets a '
        'router answer on behalf of a host on another subnet, which hides a '
        'routing problem rather than solving it.',
    whenToUse:
        'It is mandatory on IPv4 Ethernet. The design work is protecting it: '
        'Dynamic ARP Inspection with a DHCP snooping binding, port security, '
        'and arp inspection limits on access ports.',
    tradeoffs:
        'ARP has no authentication, so any host can claim any address. The '
        'cache is finite, so a scan can exhaust it. Proxy ARP makes a host '
        'reachable without a correct gateway but breaks the visibility of '
        'where the traffic actually goes.',
    commands:
        'arp 10.0.0.1 0011.2233.4455 ARPA\n'
        'interface Vlan10\n'
        ' ip arp inspection vlan 10\n'
        ' ip arp inspection validate src-mac dst-mac ip\n'
        'ip arp inspection limit rate 100',
    verify:
        'show ip arp (the cache and age), show ip arp inspection statistics, '
        'and a capture that shows the request and the reply. A host that can '
        'ping its gateway but not a peer usually has a stale or missing entry.',
    pitfalls:
        'Duplicate IP addresses, which produce intermittent loss and a MAC '
        'that flaps between two ports. Proxy ARP left on by default across a '
        'subnet boundary. And an ARP cache that fills during a scan, after '
        'which the router drops traffic it could route fine.',
    aspects: [
      'gratuitous',
      'proxy arp',
      'cache',
      'inspection',
      'spoofing',
      'duplicate address',
    ],
    conceptOwned: true,
    facts: {
      'Request': 'Broadcast ff:ff:ff:ff:ff:ff',
      'Cache': 'Typically 4 hours, platform dependent',
      'Gratuitous': 'Unsolicited announcement',
      'Security': 'DAI plus DHCP snooping',
    },
  ),
  NetworkTech(
    id: 'icmp',
    name: 'ICMP',
    aliases: [
      'icmp',
      'icmpv6',
      'ping',
      'traceroute',
      'type 3',
      'packet too big',
    ],
    summary:
        'ICMP carries control and error messages for IP: unreachable, time '
        'exceeded, redirect, echo and, in IPv6, the whole of neighbor '
        'discovery.',
    mechanism:
        'An echo request and reply are types 8 and 0. Destination unreachable '
        'is type 3, with codes for network, host, protocol and port; code 4 is '
        'fragmentation needed, and it carries the next-hop MTU, which is how '
        'path MTU discovery works. Time exceeded is type 11, which is what '
        'traceroute elicits by incrementing the TTL. Redirect is type 5. ICMPv6 '
        'adds types 133 to 137 for router and neighbor discovery, and it is '
        'mandatory, not optional.',
    whenToUse:
        'Always. The design decision is which types to permit at an edge: '
        'echo may be restricted, but type 3 code 4 and ICMPv6 133-137 must be '
        'allowed or PMTUD and IPv6 break.',
    tradeoffs:
        'Blocking all ICMP is a common policy that silently breaks large '
        'packets and IPv6. Allowing all of it exposes the network to scanning '
        'and to ICMP floods, so rate-limit rather than deny.',
    commands:
        'ip access-list extended EDGE-IN\n'
        ' permit icmp any any echo-reply\n'
        ' permit icmp any any unreachable\n'
        ' permit icmp any any time-exceeded\n'
        ' permit icmp any any packet-too-big\n'
        ' deny icmp any any\n'
        ' permit ip any any',
    verify:
        'ping with a large payload and the DF bit set, then traceroute. A '
        'session that establishes but stalls on large packets is the classic '
        'sign that type 3 code 4 is being dropped.',
    pitfalls:
        'Denying fragmentation-needed and calling it a security policy. '
        'Rate-limiting ICMPv6 so aggressively that neighbor discovery times '
        'out. And trusting ping success as proof that the application works.',
    aspects: [
      'type 3',
      'code 4',
      'pmtud',
      'fragmentation',
      'unreachable',
      'redirect',
      'icmpv6',
    ],
    conceptOwned: true,
    facts: {
      'Echo': 'Type 8 request, 0 reply',
      'Unreachable': 'Type 3',
      'Time exceeded': 'Type 11',
      'Frag needed': 'Type 3 code 4',
    },
  ),
  NetworkTech(
    id: 'mpls-l3vpn',
    name: 'MPLS L3VPN',
    aliases: [
      'mpls l3vpn',
      'l3vpn',
      'vpnv4',
      'vrf',
      'route distinguisher',
      'route target',
      'pe-ce',
      'mp-bgp',
    ],
    summary:
        'An L3VPN carries customer routes across a provider core using VRFs on '
        'the PE routers and MP-BGP to exchange them, so the customer never sees '
        'the provider backbone.',
    mechanism:
        'Each customer gets a VRF on the PE: its own routing table, interfaces '
        'and CE peers. The PE adds a route distinguisher to make the customer '
        'prefix unique and a route target to control which VRFs import it. '
        'MP-BGP carries the VPNv4 or VPNv6 routes between PEs, each with a VPN '
        'label. The ingress PE pushes that label plus a transport label toward '
        'the egress PE, which pops the transport label and forwards on the VPN '
        'label. Penultimate-hop popping removes the transport label one hop '
        'early. The CE runs plain OSPF, EIGRP, BGP or static with the PE.',
    whenToUse:
        'Multi-site enterprises that want the provider to carry and isolate '
        'their routing, especially when sites need any-to-any reachability and '
        'predictable SLAs. It is also the reference design behind carrier '
        'Ethernet and many SD-WAN underlays.',
    tradeoffs:
        'Excellent isolation and SLA, but per-Mbps cost, long provisioning '
        'times, and the provider controls the failure domain. The enterprise '
        'still owns routing policy, summarization and the CE edge, so an '
        'L3VPN does not remove the need for a network team.',
    commands:
        'ip vrf CUSTOMER-A\n'
        ' rd 65000:1\n'
        ' route-target export 65000:1\n'
        ' route-target import 65000:1\n'
        'interface GigabitEthernet0/1\n'
        ' ip vrf forwarding CUSTOMER-A\n'
        ' ip address 10.1.0.1 255.255.255.252\n'
        'router bgp 65000\n'
        ' address-family vpnv4\n'
        '  neighbor 10.0.0.2 activate\n'
        '  neighbor 10.0.0.2 send-community extended',
    verify:
        'show ip vrf (interfaces and RD), show ip route vrf CUSTOMER-A, show '
        'bgp vpnv4 vrf CUSTOMER-A, and the label stack with a traceroute that '
        'shows MPLS labels. On the CE, the PE neighbor must be up and the '
        'routes must be present, not just the link.',
    pitfalls:
        'A missing route target, so the route exists on the PE and never '
        'appears in the remote VRF. A VRF interface without an RD or RT. And '
        'overlapping customer addresses without distinct VRFs, which is exactly '
        'what the VRF is for.',
    aspects: ['vrf', 'rd', 'route target', 'vpnv4', 'label stack', 'pe-ce'],
    facts: {
      'Label stack': 'Transport label plus VPN label',
      'Control plane': 'MP-BGP VPNv4 or VPNv6',
      'Isolation': 'One VRF per customer',
      'PHP': 'Penultimate hop popping',
    },
  ),
  NetworkTech(
    id: 'pim',
    name: 'PIM',
    aliases: [
      'pim',
      'pim-sm',
      'pim sparse mode',
      'pim dense mode',
      'rp',
      'rendezvous point',
      'spt',
      'multicast routing',
    ],
    summary:
        'PIM builds the multicast distribution tree; sparse mode uses a '
        'rendezvous point to join receivers and then switches to the shortest '
        'path tree.',
    mechanism:
        'In sparse mode the last-hop router sends a PIM join toward the '
        'rendezvous point, creating the shared (*,G) tree. The source registers '
        'with the RP, and traffic flows down the shared tree until the '
        'last-hop router learns the source and sends a source-specific join, '
        'building the (S,G) shortest path tree. Reverse path forwarding checks '
        'that the packet arrived on the interface the unicast route points to; '
        'a failure there silently drops the stream. Dense mode floods and '
        'prunes, and is only useful in small, dense labs.',
    whenToUse:
        'Market data, IPTV, video distribution, and any one-to-many feed where '
        'replicating at the source would waste bandwidth. Sparse mode is the '
        'default choice; SSM (PIM-SSM with IGMPv3) removes the RP for known '
        'sources.',
    tradeoffs:
        'Sparse mode needs a stable RP, and anycast-RP or MSDP adds complexity. '
        'RPF failures are the hardest multicast faults because the unicast '
        'table looks correct while the stream is dropped. And multicast is '
        'often blocked by default in cloud networks.',
    commands:
        'ip multicast-routing\n'
        'interface GigabitEthernet0/1\n'
        ' ip pim sparse-mode\n'
        'ip pim rp-address 10.0.0.10\n'
        'ip pim ssm default',
    verify:
        'show ip mroute (the (*,G) and (S,G) entries and the incoming '
        'interface), show ip rpf 10.1.1.1 (the RPF check), and show ip igmp '
        'groups on the last-hop router. A stream that arrives but is not '
        'forwarded is usually an RPF failure.',
    pitfalls:
        'An RP reachable by a route that does not match the RPF interface. '
        'Multicast enabled on the source but not on the transit hop. And an '
        'ACL that permits UDP but not IGMP or PIM.',
    aspects: ['rp', 'sparse', 'dense', 'ssm', 'rpf', 'spt', 'igmp'],
    facts: {
      'PIM protocol': 'IP protocol 103',
      'IGMP': 'IP protocol 2',
      'RPF': 'Reverse path forwarding check',
      'SSM range': '232.0.0.0/8',
    },
  ),
  NetworkTech(
    id: 'ipv6-transition',
    name: 'IPv6 transition',
    aliases: [
      'ipv6 transition',
      'dual stack',
      'nat64',
      'dns64',
      '464xlat',
      '6rd',
      'ds-lite',
      'ipv6 migration',
    ],
    summary:
        'Dual stack runs IPv4 and IPv6 together; translation and tunneling '
        'carry one family over the other where a host or a link cannot do both.',
    mechanism:
        'Dual stack gives every interface both addresses and lets the host '
        'choose by destination, which is the only transition that preserves '
        'end-to-end behavior for both families. NAT64 translates IPv6 to IPv4 '
        'at a gateway; DNS64 synthesizes AAAA records from A records so an '
        'IPv6-only client can reach an IPv4-only server. 464XLAT puts a '
        'stateless translator on the client and a stateful one in the network, '
        'which is how mobile networks run IPv6-only. 6rd and DS-Lite tunnel '
        'IPv6 across an IPv4 access network; they are provider tools, not '
        'enterprise design.',
    whenToUse:
        'Dual stack everywhere first. Translation only where a device or an '
        'access network genuinely cannot run both, and always with the '
        'application limitations documented.',
    tradeoffs:
        'Dual stack doubles the address plan, the ACLs and the monitoring. '
        'NAT64 breaks protocols that embed addresses and needs DNS64 to be '
        'consistent. Tunnels add MTU and latency, and every one of them is '
        'another thing to troubleshoot.',
    commands:
        'interface GigabitEthernet0/1\n'
        ' ip address 10.0.0.1 255.255.255.0\n'
        ' ipv6 address 2001:db8:1::1/64\n'
        ' ipv6 enable\n'
        'ipv6 unicast-routing\n'
        '! NAT64 on a translator platform\n'
        '! nat64 prefix 64:ff9b::/96',
    verify:
        'On a dual-stack host, the address, the default route and the DNS '
        'answer must all have an IPv6 path; a host with an IPv6 address and an '
        'IPv4-only resolver is common. Test with a destination that is '
        'IPv6-only, not just a dual-stack one.',
    pitfalls:
        'Turning on IPv6 without a firewall policy, so it bypasses the IPv4 '
        'controls. A DNS64 that synthesizes records for a domain that also has '
        'real AAAA records. And an MTU that was never raised for a tunnel.',
    aspects: ['dual stack', 'nat64', 'dns64', '464xlat', '6rd', 'ds-lite'],
    facts: {
      'NAT64 prefix': '64:ff9b::/96',
      'DNS64': 'Synthesizes AAAA from A',
      'Dual stack': 'Both families on every interface',
      '464XLAT': 'CLAT plus PLAT',
    },
  ),
  NetworkTech(
    id: 'dhcpv6',
    name: 'DHCPv6',
    aliases: [
      'dhcpv6',
      'stateful dhcpv6',
      'stateless dhcpv6',
      'ia_na',
      'ia_pd',
      'prefix delegation',
    ],
    summary:
        'DHCPv6 supplies addresses, prefixes and options that router '
        'advertisements cannot carry; stateful mode tracks leases, stateless '
        'mode only supplies options.',
    mechanism:
        'Clients and servers use UDP 546 and 547. A solicit is answered by an '
        'advertise, the client sends a request and the server replies with a '
        'reply carrying an identity association: IA_NA for addresses, IA_PD '
        'for a delegated prefix to a downstream router. The M flag in the RA '
        'tells the host to use stateful DHCPv6, the O flag tells it to use '
        'DHCPv6 for other options only. DUID identifies the client across '
        'reboots. Prefix delegation is how a home or branch router gets a '
        'routable block from the provider.',
    whenToUse:
        'When you need lease tracking, DNS servers that RA cannot carry, or '
        'prefix delegation. Pure SLAAC plus RDNSS is simpler for a campus of '
        'clients and is often enough.',
    tradeoffs:
        'Stateful DHCPv6 gives accounting and control but adds a server '
        'dependency and a lease table to protect. Stateless mode is simpler '
        'but leaves address assignment to the host. Windows, Android and '
        'network gear differ in which flags they honor, so test the actual '
        'client mix.',
    commands:
        'ipv6 dhcp pool STAFF-V6\n'
        ' address prefix 2001:db8:10::/64\n'
        ' dns-server 2001:db8::53\n'
        'interface Vlan10\n'
        ' ipv6 address 2001:db8:10::1/64\n'
        ' ipv6 dhcp server STAFF-V6\n'
        ' ipv6 nd managed-config-flag\n'
        ' ipv6 nd other-config-flag',
    verify:
        'show ipv6 dhcp pool, show ipv6 dhcp binding, and on the client the '
        'address plus the DNS server. A host with a link-local only is not '
        'seeing RAs; a host with an address but no DNS is an M/O flag problem.',
    pitfalls:
        'Setting the M flag and not running a stateful server, so clients wait '
        'for an address that never comes. Mixing SLAAC and stateful DHCPv6 '
        'without deciding which owns the address. And a relay that is not '
        'configured for DHCPv6 at all.',
    conceptOwned: true,
    aspects: ['ia_na', 'ia_pd', 'stateful', 'duid', 'prefix delegation'],
    facts: {
      'Server port': '547',
      'Client port': '546',
      'IA_NA': 'Address association',
      'IA_PD': 'Prefix delegation',
    },
  ),
  NetworkTech(
    id: 'pbr',
    name: 'Policy-based routing',
    aliases: [
      'pbr',
      'policy based routing',
      'policy routing',
      'route-map',
      'ip sla',
      'next-hop',
    ],
    summary:
        'PBR overrides the destination-based routing table with a policy that '
        'matches source, protocol or port and sets a next hop, interface or '
        'mark.',
    mechanism:
        'An interface applies a route map to received packets before the '
        'normal lookup. The map matches an ACL, a packet length or a mark, and '
        'sets a next hop, an interface, a DSCP value or a default. If no clause '
        'matches, normal routing resumes. PBR is evaluated per packet, so it '
        'does not fail over by itself; tracking with IP SLA and a reliable '
        'static route is what makes it resilient.',
    whenToUse:
        'Two ISPs with different traffic classes, a guest network that must '
        'exit locally, or a migration where one subnet must use the new path '
        'before the default route changes. It is also useful to steer traffic '
        'to a firewall that is not on the default path.',
    tradeoffs:
        'It is powerful and easy to break: a policy that points at a dead next '
        'hop black-holes traffic, and a policy that matches too broadly '
        'bypasses the routing protocol. It also complicates troubleshooting, '
        'because the routing table no longer explains the path.',
    commands:
        'ip access-list extended VOICE-OUT\n'
        ' permit udp any any range 16384 32767\n'
        'route-map VOICE-VIA-ISP2 permit 10\n'
        ' match ip address VOICE-OUT\n'
        ' set ip next-hop 192.0.2.1\n'
        'interface GigabitEthernet0/1\n'
        ' ip policy route-map VOICE-VIA-ISP2',
    verify:
        'show route-map (match counters), show ip policy, and a traceroute '
        'from the matching source. A policy with zero matches is not applied '
        'where you think it is.',
    pitfalls:
        'A next hop that is not on a directly connected subnet, so the set '
        'fails. Recursion between two policies. And a policy that matches '
        'return traffic, which is not on the same interface and therefore '
        'never sees the map.',
    aspects: ['route-map', 'set next-hop', 'ip sla', 'policy routing'],
    facts: {
      'Order': 'Before the routing table',
      'Match': 'ACL, length, mark',
      'Set': 'Next hop, interface, DSCP',
      'Failover': 'Needs tracking',
    },
  ),
  NetworkTech(
    id: 'firewall-ha',
    name: 'Firewall high availability',
    aliases: [
      'firewall ha',
      'active standby',
      'active/active',
      'failover',
      'state sync',
      'ha pair',
    ],
    summary:
        'A firewall HA pair keeps a synchronized state table so a failover is '
        'a short interruption rather than a rebuild of every session.',
    mechanism:
        'Both units share a virtual address and exchange hello messages over a '
        'dedicated link. The standby receives the connection table, NAT '
        'translations and routing state, so established flows survive. A '
        'failover triggers when interfaces, hello timers or a monitored object '
        'fail. Active/standby sends all traffic through one unit; '
        'active/active distributes flows across both, which does not double '
        'the throughput of a single flow and introduces asymmetric routing.',
    whenToUse:
        'Any firewall that carries business traffic. Active/standby is the '
        'default; active/active only when flow-level distribution is genuinely '
        'needed and the routing is designed for it.',
    tradeoffs:
        'State sync costs bandwidth and CPU, and a pair multiplies the '
        'configuration that can drift. A failover that has never been tested '
        'is a hope. Active/active adds complexity for a modest capacity gain.',
    commands:
        'failover\n'
        'failover lan unit primary\n'
        'failover lan interface FAILOVER GigabitEthernet0/3\n'
        'failover link FAILOVER GigabitEthernet0/3\n'
        'failover interface ip FAILOVER 10.255.0.1 255.255.255.252 standby 10.255.0.2\n'
        'monitor-interface outside',
    verify:
        'show failover (state, last transition, monitored interfaces), then a '
        'forced switchover with a long-lived flow open. The flow must survive, '
        'not just the ping.',
    pitfalls:
        'A sync link that shares the data path, so a failover storm takes both '
        'units down. Asymmetric routing that makes each unit see half a flow. '
        'And configuration drift because changes were made on the standby '
        'while it was standby.',
    aspects: ['active standby', 'active/active', 'state sync', 'failover link'],
    facts: {
      'Default': 'Active/standby',
      'Sync': 'Connection and NAT table',
      'Trigger': 'Interface, hello, monitored object',
      'Risk': 'Asymmetric routing',
    },
  ),
  NetworkTech(
    id: 'tls-inspection',
    name: 'TLS inspection',
    aliases: [
      'tls inspection',
      'ssl inspection',
      'break and inspect',
      'certificate inspection',
      'https inspection',
      'mitm proxy',
      'inspect tls',
      'inspect ssl',
      'tls decryption',
      'ssl decryption',
    ],
    summary:
        'TLS inspection terminates the client connection, inspects the plaintext '
        'and re-encrypts to the server, which requires trusting a proxy CA on '
        'every client.',
    mechanism:
        'The firewall presents a certificate signed by its own CA for the '
        'requested name, completes TLS with the client, opens a second TLS '
        'session to the server, and inspects between them. The client must '
        'trust the proxy CA or every HTTPS site warns. Certificate pinning, '
        'mutual TLS and some applications deliberately fail under inspection. '
        'The proxy must also honor policy: bypass categories for banking and '
        'health, and bypass for pinned applications.',
    whenToUse:
        'Where policy requires visibility into encrypted traffic and the '
        'organization can deploy and govern a trusted CA. It is a legal and '
        'privacy decision as much as a technical one.',
    tradeoffs:
        'It is expensive: throughput drops to a fraction of the raw rating, '
        'latency rises, and the CA private key becomes a high-value target. '
        'Bypass lists grow, and users notice breakage before security does.',
    commands:
        '! Generate an inspection CA, distribute only the certificate\n'
        '! to endpoints via MDM or GPO, and keep the private key on the\n'
        '! firewall or an HSM. Never install the CA private key on clients.',
    verify:
        'Open a known HTTPS site from a managed endpoint and check the issuer '
        'is the proxy CA. Test a pinned application and confirm the bypass. '
        'Measure inspected throughput with inspection on, not off.',
    pitfalls:
        'Deploying inspection without the CA, so every site warns and users '
        'learn to click through. Inspecting banking or health traffic and '
        'creating a compliance incident. And sizing to the raw throughput '
        'number, then collapsing under real TLS.',
    aspects: ['ssl inspection', 'break and inspect', 'proxy ca', 'pinning'],
    facts: {
      'Trust': 'Proxy CA on every client',
      'Performance': 'A fraction of raw throughput',
      'Breaks': 'Pinning, mTLS, some apps',
      'Key': 'Protect the CA private key',
    },
  ),
  NetworkTech(
    id: 'ddos',
    name: 'DDoS mitigation',
    aliases: [
      'ddos',
      'denial of service',
      'syn flood',
      'rtbh',
      'blackhole',
      'scrubbing center',
      'amplification',
    ],
    summary:
        'DDoS defense is layered: anycast and capacity absorb volume, edge '
        'filters drop known-bad patterns, and a scrubbing path removes the rest '
        'before it reaches the service.',
    mechanism:
        'Volumetric attacks fill the pipe; the only real answer is more '
        'capacity in more places, which is why anycast spreads a service across '
        'many points of presence. Protocol attacks exhaust state tables with '
        'SYNs or fragments; SYN cookies and per-source limits help. '
        'Application attacks look like real requests and need behavioral '
        'filtering, rate limits and a challenge. Remote-triggered black hole '
        'routes the target prefix to null when it is under attack, which '
        'sacrifices availability to protect the rest of the network.',
    whenToUse:
        'Any internet-facing service. The design question is what the provider '
        'offers (always-on scrubbing, on-demand diversion, RTBH) and what the '
        'organization can do itself at the edge.',
    tradeoffs:
        'Always-on scrubbing adds latency and cost; on-demand diversion takes '
        'time to detect and reroute. RTBH is fast and blunt: it stops the '
        'attack and the service at the same time.',
    commands:
        'ip route 203.0.113.10 255.255.255.255 Null0\n'
        '! announce the host route with the blackhole community\n'
        'route-map RTBH permit 10\n'
        ' set community 65000:666',
    verify:
        'Baseline normal traffic first, then measure during an attack: pps, '
        'bps, new sessions and top talkers. A filter that drops the attack and '
        'the legitimate traffic is not a mitigation.',
    pitfalls:
        'Buying scrubbing and not testing the diversion path. Blocking a '
        'source range that contains real customers. And treating a 10 Gbps '
        'scrubber as protection for a 40 Gbps link.',
    aspects: ['syn flood', 'rtbh', 'scrubbing', 'amplification', 'anycast'],
    facts: {
      'Volumetric': 'Fill the link',
      'Protocol': 'Exhaust state',
      'Application': 'Looks legitimate',
      'RTBH': 'Route to null',
    },
  ),
  NetworkTech(
    id: 'microsegmentation',
    name: 'Microsegmentation',
    aliases: [
      'microsegmentation',
      'micro-segmentation',
      'security group',
      'east-west security',
      'workload segmentation',
    ],
    summary:
        'Microsegmentation puts a policy boundary around each workload or group '
        'instead of around the VLAN, so lateral movement needs an explicit '
        'allow.',
    mechanism:
        'Policy is expressed as labels or security groups (application, '
        'environment, tenant) and enforced by a distributed firewall in the '
        'hypervisor, the host or the switch fabric. Traffic between two '
        'workloads on the same subnet is still checked. The hard part is '
        'discovery: you must learn the real flows before writing deny rules, '
        'or the first policy change becomes an outage.',
    whenToUse:
        'Data centers and clouds where east-west traffic dominates and a flat '
        'VLAN would let one compromised host reach everything. It complements '
        'VRF and VLAN segmentation; it does not replace the north-south '
        'firewall.',
    tradeoffs:
        'Excellent containment, but operationally heavy: flow discovery, '
        'label hygiene, and a policy engine that must be highly available. '
        'Every bypass for a legacy application becomes permanent technical '
        'debt if it is not reviewed.',
    commands:
        '! Policy is platform specific. The invariant is:\n'
        '! default deny between groups, allow only observed flows,\n'
        '! log denies, and review every exception on a schedule.',
    verify:
        'Run in monitor mode first and compare the would-be denies with the '
        'real flow log. Then enforce one group at a time and prove that the '
        'allowed application still works and an unlisted port does not.',
    pitfalls:
        'Enforcing before discovery, which breaks an application nobody '
        'documented. Label drift, so a new VM lands in the wrong group. And '
        'leaving the policy engine as a single point of failure.',
    aspects: [
      'security group',
      'east-west',
      'distributed firewall',
      'zero trust',
    ],
    facts: {
      'Boundary': 'Per workload or group',
      'Enforcement': 'Hypervisor, host or fabric',
      'Default': 'Deny',
      'Prerequisite': 'Flow discovery',
    },
  ),
  NetworkTech(
    id: 'sd-access',
    name: 'SD-Access',
    aliases: [
      'sd-access',
      'sd access',
      'dna center',
      'catalyst center',
      'fabric edge',
      'fabric border',
      'lisp fabric',
    ],
    summary:
        'SD-Access builds a campus fabric in which edge nodes tunnel user '
        'traffic to a border, and policy follows the user instead of the port.',
    mechanism:
        'A control plane node maps endpoint identity (EID) to a routing '
        'locator (RLOC) using LISP. Edge nodes encapsulate traffic in VXLAN '
        'toward the border, which hands it to the outside. Cisco ISE supplies '
        'identity through 802.1X or profiling, and the fabric applies a '
        'security group tag (SGT) so policy is enforced between groups, not '
        'between subnets. A fabric can be single-site or stretched across '
        'sites with a transit control plane.',
    whenToUse:
        'A campus with a large, mobile user base and a requirement to apply '
        'consistent policy regardless of where a user plugs in. It is most '
        'valuable when the existing design is a patchwork of VLANs and ACLs.',
    tradeoffs:
        'It moves complexity into the controller and the underlay: a broken '
        'control plane affects every edge, and troubleshooting spans LISP, '
        'VXLAN, ISE and the underlay. It also tends to anchor the campus to one '
        'vendor.',
    commands:
        '! Fabric configuration is controller-driven. The underlay is a\n'
        '! routed, summarized topology; the overlay carries the policy.\n'
        'show lisp instance-id 4099 ipv4 database\n'
        'show fabric border handoff',
    verify:
        'show lisp database (EID to RLOC), show fabric edge handoff, and a '
        'client that authenticates and receives an SGT. Then test the same '
        'client on a different edge port: policy must follow it.',
    pitfalls:
        'An underlay that is not summarized, so the fabric table grows with '
        'every access link. ISE down with no fallback policy. And a border '
        'that is a single point of failure for every fabric site.',
    aspects: ['lisp', 'vxlan', 'sgt', 'ise', 'fabric border', 'fabric edge'],
    facts: {
      'Control plane': 'LISP',
      'Data plane': 'VXLAN',
      'Identity': '802.1X, profiling, SGT',
      'Policy': 'Group-based, not subnet-based',
    },
  ),
  NetworkTech(
    id: 'aci',
    name: 'Cisco ACI',
    aliases: [
      'aci',
      'application centric infrastructure',
      'apic',
      'tenant',
      'epg',
      'endpoint group',
      'contract',
    ],
    summary:
        'ACI is a policy-driven data-center fabric: tenants contain EPGs, and '
        'contracts define which EPGs may talk to each other.',
    mechanism:
        'The APIC cluster is the policy controller; switches run the fabric '
        'and forward VXLAN-encapsulated traffic. An endpoint group is a set of '
        'endpoints with the same policy, a bridge domain is the L2 boundary, '
        'and a VRF is the L3 boundary. A contract is a named policy with '
        'subjects, filters and ports; without a contract, EPGs cannot talk. '
        'Service graphs steer traffic through a firewall or load balancer.',
    whenToUse:
        'A data center that needs repeatable, auditable application policy and '
        'a fabric that can stretch across pods. It is heavy for a small '
        'estate; a pair of Nexus switches with VRFs and ACLs is often enough.',
    tradeoffs:
        'The policy model is powerful and enforces intent, but it is a '
        'different mental model from VLANs and ACLs, and the APIC cluster plus '
        'fabric is a significant operational commitment. Contract mistakes '
        'produce silent denies that look like routing failures.',
    commands:
        '! ACI is configured through the APIC GUI or API, not the CLI.\n'
        '! The equivalent intent: tenant > VRF > bridge domain > EPG > contract.\n'
        'show fabric membership\n'
        'show endpoint ip 10.1.1.10',
    verify:
        'show endpoint (the learned endpoint and its EPG), the contract stats '
        'on the APIC, and a ping between two EPGs before and after the '
        'contract. A missing contract is the first thing to check when one EPG '
        'cannot reach another.',
    pitfalls:
        'Forgetting that EPGs are isolated by default. A contract that allows '
        'the port but not the return traffic. And an APIC cluster with no '
        'backup, so a controller failure becomes a rebuild.',
    aspects: ['apic', 'epg', 'contract', 'tenant', 'bridge domain'],
    facts: {
      'Controller': 'APIC cluster',
      'Data plane': 'VXLAN',
      'Policy unit': 'Contract',
      'Default': 'Deny between EPGs',
    },
  ),
  NetworkTech(
    id: 'evpn-multihoming',
    name: 'EVPN multihoming',
    aliases: [
      'evpn multihoming',
      'esi',
      'ethernet segment identifier',
      'df election',
      'all-active',
      'evpn aliasing',
    ],
    summary:
        'EVPN multihoming lets several leaf switches share one Ethernet segment '
        'and all forward for it, using an ESI and a designated forwarder per '
        'VLAN.',
    mechanism:
        'Every leaf attached to the same segment is configured with the same '
        'ESI. The leaves advertise the ESI in their EVPN routes, and the '
        'remote leaves install an anycast path with aliasing so traffic can '
        'use any attached leaf. A designated forwarder election per VLAN '
        'decides which leaf floods broadcast and unknown unicast, which '
        'prevents duplicates. On failure, the ESI withdraws and the remaining '
        'leaves take over.',
    whenToUse:
        'A server or an access switch that dual-homes to two leaves and needs '
        'active/active forwarding without MLAG or a spanning-tree blocked '
        'link. It is the modern replacement for vPC in an EVPN fabric.',
    tradeoffs:
        'It removes the peer link and the orphan-port problem, but it requires '
        'a consistent ESI and VLAN-to-EVI mapping across leaves, and '
        'troubleshooting spans EVPN type 1 and type 4 routes. Not every server '
        'NIC or OS supports active/active LACP the same way.',
    commands:
        'interface Ethernet1/1\n'
        ' evpn multihoming\n'
        '  ethernet-segment 0011.2233.4455.6677.8899\n'
        '  lacp system-id 0011.2233.4455\n'
        'evpn\n'
        ' ethernet-segment 0011.2233.4455.6677.8899\n'
        '  df-election wait-time 3',
    verify:
        'show evpn ethernet-segment (ESI state and DF per VLAN), show evpn '
        'multihoming, and the type 1 and type 4 routes in the EVPN table. A '
        'segment that is up on one leaf and not the other is usually an ESI '
        'or system-id mismatch.',
    pitfalls:
        'A different ESI or LACP system-id on the two leaves, so the server '
        'sees two independent bundles. A DF election that flaps because the '
        'wait time is too short. And an access switch that is not configured '
        'for the same LACP mode.',
    aspects: ['esi', 'df election', 'aliasing', 'all-active'],
    facts: {
      'Route types': '1 and 4 for multihoming',
      'Election': 'Designated forwarder per VLAN',
      'Benefit': 'Active/active without MLAG',
      'Key': 'Same ESI on every leaf',
    },
  ),
  NetworkTech(
    id: 'gpon',
    name: 'GPON',
    aliases: [
      'gpon',
      'olt',
      'ont',
      'optical line terminal',
      'splitter',
      'tcont',
      'xgpon',
    ],
    summary:
        'GPON is a passive optical access network: one OLT port feeds a passive '
        'splitter and many ONTs, with downstream broadcast and upstream '
        'time-slot arbitration.',
    mechanism:
        'The OLT transmits downstream at 2.5 Gbps and receives upstream at '
        '1.25 Gbps in GPON; XGS-PON raises both to 10 Gbps. A passive splitter '
        'divides the fiber, typically 1:32 or 1:64. Downstream frames are '
        'encrypted and addressed to an ONT ID; upstream is shared by '
        'time-division multiple access, with the OLT granting timeslots so '
        'ONTs do not collide. T-CONTs are the upstream schedulers, and DBA '
        'allocates bandwidth per service.',
    whenToUse:
        'Campus and ISP access where fiber reaches many endpoints and no active '
        'electronics are wanted in the field. It is also common for building '
        'access, CCTV backhaul and branch connectivity.',
    tradeoffs:
        'Very low cost per subscriber and no field power, but the splitter is '
        'a shared bottleneck and a fiber cut takes out every ONT behind it. '
        'Troubleshooting requires optical power readings and ONT state, not '
        'just interface counters.',
    commands:
        '! GPON is provisioned on the OLT, not on a switch port.\n'
        'show gpon onu detail-info\n'
        'show gpon onu state\n'
        'show interface gpon 0/1\n'
        '! Check Rx optical power at the ONT against the splitter budget.',
    verify:
        'The ONT optical receive power (typically -8 to -27 dBm for GPON), the '
        'ONU state (working), and the DBA profile. A low optical reading is a '
        'splitter, connector or bend problem before it is a configuration '
        'problem.',
    pitfalls:
        'A splitter ratio that exceeds the optical budget. Dirty connectors, '
        'which cost more decibels than the splitter. And an ONT that registers '
        'but has no service because the T-CONT or VLAN mapping is missing.',
    aspects: ['olt', 'ont', 'splitter', 'tcont', 'dba', 'xgpon'],
    facts: {
      'GPON': '2.5 Gbps down, 1.25 Gbps up',
      'XGS-PON': '10 Gbps symmetrical',
      'Split': '1:32 or 1:64 typical',
      'Optical budget': 'About 28 dB class B+',
    },
  ),
  NetworkTech(
    id: 'dwdm',
    name: 'DWDM',
    aliases: [
      'dwdm',
      'wdm',
      'cwdm',
      'roadm',
      'oadm',
      'wavelength',
      'optical channel',
    ],
    summary:
        'DWDM puts many independent wavelengths on one fiber pair, so capacity '
        'grows without new fiber.',
    mechanism:
        'Each transponder emits a narrowly spaced wavelength (50 or 100 GHz on '
        'the ITU grid). A multiplexer combines them, optical amplifiers boost '
        'the whole band, and a demultiplexer separates them at the far end. An '
        'OADM drops or adds selected wavelengths at an intermediate site; a '
        'ROADM makes that reconfigurable. Dispersion and OSNR limit reach, and '
        'the optical budget must account for every connector, splice and '
        'amplifier.',
    whenToUse:
        'Metro and long-haul transport where fiber is scarce or expensive and '
        'the capacity requirement is many 10G or 100G circuits. It is also '
        'used for data-center interconnect.',
    tradeoffs:
        'Enormous capacity on existing fiber, but the optics, amplifiers and '
        'filtering are a specialist discipline with high capital cost. A '
        'misconfigured amplifier can take out every channel at once.',
    commands:
        '! DWDM is provisioned on the optical platform, not the router.\n'
        'show interface optics\n'
        'show facility-alarm status\n'
        '! Check OSNR, Rx power and dispersion per channel.',
    verify:
        'Per-channel Rx power and OSNR, the amplifier gain and tilt, and an '
        'end-to-end BER test. A link that is up but erroring is usually OSNR '
        'margin, not a bad transponder.',
    pitfalls:
        'Dirty fiber connectors and exceeded bend radius. An amplifier that '
        'is gain-tilted, so the higher channels are starved. And a channel '
        'plan that reuses a wavelength on the same fiber.',
    aspects: ['roadm', 'oadm', 'lambda', 'osnr', 'amplifier'],
    facts: {
      'Grid': '50 or 100 GHz',
      'Bands': 'C band most common',
      'Amplifier': 'EDFA',
      'Limit': 'OSNR and dispersion',
    },
  ),
  NetworkTech(
    id: 'optics',
    name: 'Optics and transceivers',
    aliases: [
      'optics',
      'transceiver',
      'sfp',
      'sfp+',
      'qsfp',
      'qsfp28',
      'ddm',
      'dom',
      'fiber module',
      'dac',
    ],
    summary:
        'The transceiver decides reach, speed and fiber type; the port must '
        'match it, and the optical budget must close with real loss.',
    mechanism:
        'An SFP or QSFP converts electrical to optical and back. Multi-mode '
        'optics (SR) use 850 nm and short reach; single-mode (LR, ER, ZR) use '
        '1310 or 1550 nm and reach kilometers. A DAC is a fixed copper '
        'assembly for short in-rack links. Digital diagnostics (DOM/DDM) expose '
        'Tx power, Rx power, temperature and bias current, which is how you '
        'prove a link is healthy before it errors. Coding and FEC must match on '
        'both ends, and a 100G port may be broken out into four 25G lanes.',
    whenToUse:
        'Every fiber link. The design rule is simple: choose the optic for the '
        'distance and the fiber, then verify the receive power is inside the '
        'specified window with margin.',
    tradeoffs:
        'Longer reach costs more and consumes more power. Third-party optics '
        'are cheaper but may be unsupported or blocked by the switch. And a '
        'link that is barely within budget works in cool weather and fails in '
        'summer.',
    commands:
        'show interfaces transceiver detail\n'
        'show interfaces GigabitEthernet1/0/1 transceiver\n'
        '! Compare Rx power with the optic datasheet sensitivity and overload.',
    verify:
        'Rx power within the vendor window, Tx power near nominal, and a clean '
        'error count over 24 hours. A link that is up with rising CRC errors is '
        'an optical margin problem.',
    pitfalls:
        'Mismatched fiber type (single-mode optic on multi-mode fiber). A '
        'dirty connector, which costs 1 to 3 dB. And a breakout that is wired '
        'in the wrong lane order.',
    aspects: ['sfp', 'qsfp', 'dom', 'ddm', 'dac', 'reach', 'fec'],
    facts: {
      'SR': '850 nm, short reach',
      'LR': '1310 nm, 10 km class',
      'ER': '1550 nm, 40 km class',
      'DOM': 'Tx, Rx, temperature, bias',
    },
  ),
  NetworkTech(
    id: 'fixed-wireless-5g',
    name: 'Fixed wireless and 5G',
    aliases: [
      'fixed wireless',
      '5g',
      'lte',
      'cpe',
      'cellular backup',
      'private 5g',
      'cbrs',
    ],
    summary:
        'Fixed wireless uses a radio link where fiber cannot go; 5G and LTE '
        'make it a viable primary or backup WAN path with a real SLA option.',
    mechanism:
        'A customer premises equipment radio associates with a base station '
        'and presents Ethernet to the router. Throughput and latency depend on '
        'signal quality, band, sector load and distance. Private 5G (including '
        'CBRS) runs its own core and base station for campus coverage. For a '
        'branch, the CPE is just another WAN interface with DHCP or PPPoE and '
        'often a carrier NAT in front of it.',
    whenToUse:
        'A branch or temporary site where fiber is months away, a backup path '
        'for a primary wireline link, or a campus where cabling is impractical. '
        'It is also useful for rapid deployment and construction sites.',
    tradeoffs:
        'Fast to deploy and often cheap per month, but shared spectrum means '
        'variable performance, and carrier NAT breaks inbound services. '
        'Latency is higher and jitter less predictable than fiber, so voice '
        'needs measurement before commitment.',
    commands:
        'interface Cellular0/1/0\n'
        ' ip address negotiated\n'
        ' dialer in-band\n'
        ' dialer-group 1\n'
        'ip route 0.0.0.0 0.0.0.0 Cellular0/1/0 200',
    verify:
        'Signal metrics (RSRP, SINR), a throughput test at the busy hour, and '
        'latency plus jitter over a sustained period. A speed test at 03:00 '
        'proves nothing about the busy hour.',
    pitfalls:
        'Carrier NAT that makes a site unreachable for inbound VPN. A backup '
        'link that has never been used and whose credentials expired. And '
        'sizing to the peak speed rather than the sustained rate.',
    aspects: ['5g', 'lte', 'cpe', 'cbrs', 'private 5g', 'signal'],
    facts: {
      'Backup': 'Common primary use',
      'Carrier NAT': 'Breaks inbound',
      'Metric': 'RSRP and SINR',
      'Private 5G': 'CBRS or licensed band',
    },
  ),
  NetworkTech(
    id: 'stacking',
    name: 'Switch stacking',
    aliases: [
      'stacking',
      'stackwise',
      'virtual chassis',
      'vss',
      'stack cable',
      'switch stack',
    ],
    summary:
        'Stacking turns several physical switches into one logical switch with '
        'one control plane, one management address and a shared backplane.',
    mechanism:
        'Members elect a master (or active and standby) and share a single '
        'configuration. Traffic between members crosses the stack cables, '
        'which have a fixed capacity; a ring topology survives one cable '
        'failure, a chain does not. A stack is one failure domain: a bad '
        'firmware upgrade or a control-plane fault can take every member down '
        'at once. VSS is the same idea for two chassis; vPC and MLAG keep '
        'separate control planes and are a different trade-off.',
    whenToUse:
        'Wiring closets where a single management point and simple dual-homing '
        'are worth the shared risk, and where the stack bandwidth is enough '
        'for the closet.',
    tradeoffs:
        'Simplifies operations and lets a server dual-home without STP, but '
        'the stack is one logical device with one upgrade window and one '
        'control plane. Stack cables are a bottleneck and a common physical '
        'failure.',
    commands:
        'switch 1 priority 15\n'
        'switch 1 provision ws-c9300-48p\n'
        'show switch\n'
        'show stack-power\n'
        '! Save config, then reload the whole stack in one window.',
    verify:
        'show switch (member state and master), show switch stack-ports (ring '
        'or chain), and a cable-pull test during a maintenance window. A stack '
        'in a chain topology has no redundancy and often nobody notices.',
    pitfalls:
        'A chain instead of a ring. Mixing firmware versions during an upgrade '
        'and rebooting the whole stack. And assuming the stack backplane can '
        'carry every member at line rate.',
    aspects: ['stackwise', 'virtual chassis', 'vss', 'stack cable', 'master'],
    facts: {
      'Control plane': 'One logical switch',
      'Ring': 'Survives one cable',
      'Chain': 'No redundancy',
      'Risk': 'Shared failure domain',
    },
  ),
  NetworkTech(
    id: 'ipam',
    name: 'IPAM',
    aliases: [
      'ipam',
      'ip address management',
      'ddi',
      'infoblox',
      'address plan',
      'subnet management',
    ],
    summary:
        'IPAM is the system of record for addresses, subnets and DHCP and DNS '
        'scopes; without one, the address plan drifts into duplicates.',
    mechanism:
        'A DDI platform combines IPAM, DHCP and DNS so a lease creates a DNS '
        'record and a subnet is allocated from a defined hierarchy. It '
        'discovers addresses by scanning or by integrating with DHCP and the '
        'network devices, then reconciles what is documented with what is live. '
        'The value is not the database; it is the workflow that refuses an '
        'overlapping allocation and the audit trail that shows who changed what.',
    whenToUse:
        'As soon as there is more than one site or more than one person '
        'allocating addresses. It is mandatory before an IPv6 rollout, where '
        'the size of the space makes manual tracking impossible.',
    tradeoffs:
        'A DDI platform is a real cost and a critical dependency; if it is '
        'down, DNS and DHCP may be down with it. A spreadsheet is free and '
        'always out of date. The middle ground is a documented plan with a '
        'review step, which works until it does not.',
    commands:
        '! The artifact that matters is the plan:\n'
        '! 10.0.0.0/8 split by site, then by function, then by VLAN,\n'
        '! with a reserved block for growth and a documented owner per block.',
    verify:
        'Reconcile the IPAM export against the live ARP and routing tables once '
        'a quarter. Every address that answers but is not documented is either '
        'a discovery gap or a rogue device.',
    pitfalls:
        'Two sites using the same range after a merger. A DHCP scope that is '
        'wider than the documented subnet. And an IPv6 plan that assigns /64s '
        'by hand until nobody knows what is free.',
    aspects: ['ddi', 'subnet management', 'address plan', 'discovery'],
    facts: {
      'Scope': 'IPAM plus DHCP plus DNS',
      'Value': 'No overlap, audit trail',
      'IPv6': 'Makes manual tracking impossible',
      'Reconcile': 'Quarterly against live',
    },
  ),
  NetworkTech(
    id: 'network-automation',
    name: 'Network automation',
    aliases: [
      'network automation',
      'netmiko',
      'ansible',
      'napalm',
      'python',
      'ci/cd for network',
      'infrastructure as code',
      'terraform',
    ],
    summary:
        'Network automation replaces hand-typed changes with a reviewed, '
        'versioned source of truth and a repeatable push, plus a validation '
        'step that proves the result.',
    mechanism:
        'A source of truth (YAML, a database, NetBox) holds intent. A template '
        'renders device configuration. A runner (Ansible, Nornir, a custom '
        'Python tool) pushes it over SSH or NETCONF, ideally in a lab first. '
        'Validation compares the post-change state with the intent: routes '
        'present, interfaces up, reachability proven. A CI pipeline runs the '
        'same checks on a pull request, so the change is reviewed before it '
        'touches production.',
    whenToUse:
        'Repeated changes across many devices, a compliance requirement for '
        'review and rollback, or any environment where a typo in an ACL has '
        'caused an outage. Start with read-only collection and validation; '
        'automate writes only after the checks are trusted.',
    tradeoffs:
        'It scales review and removes typos, but a bad template scales the '
        'mistake to every device at once. It also requires discipline: a '
        'source of truth that is not the real source is worse than none.',
    commands:
        '! Read-only first:\n'
        'ansible -m ios_command -a "commands=show ip route summary" all\n'
        '! Then a template, then a diff, then a change window.',
    verify:
        'A dry run that shows the exact diff, a post-change assertion suite, '
        'and a rollback that is also automated. If rollback is manual, the '
        'automation is only half built.',
    pitfalls:
        'Automating a process nobody understands. Storing credentials in the '
        'repository. And pushing to all devices at once without a canary or a '
        'maintenance window.',
    aspects: ['ansible', 'netmiko', 'terraform', 'source of truth', 'ci/cd'],
    facts: {
      'Transport': 'SSH, NETCONF, RESTCONF',
      'Source': 'Version-controlled intent',
      'Gate': 'Diff plus validation',
      'First step': 'Read-only collection',
    },
  ),
  NetworkTech(
    id: 'capacity-planning',
    name: 'Capacity planning',
    aliases: [
      'capacity planning',
      'baseline',
      'utilization',
      'growth plan',
      'bandwidth forecast',
      'busy hour',
    ],
    summary:
        'Capacity planning is a measured busy-hour baseline plus a growth rate '
        'and a threshold that triggers action, not a one-time guess.',
    mechanism:
        'Collect interface rates, errors and discards at a short interval, '
        'then keep the busy hour, not the daily average. A ninety-fifth '
        'percentile is the usual billing and design figure because it ignores '
        'the top five percent of samples that are usually backups. Plot the '
        'trend, calculate months to the threshold at the current growth rate, '
        'and tie the threshold to a lead time: if procurement takes three '
        'months, the trigger must be three months ahead of saturation.',
    whenToUse:
        'Every WAN circuit, uplink and firewall. It is also the evidence that '
        'justifies an upgrade, which is more persuasive than a feeling that '
        'the network is slow.',
    tradeoffs:
        'Monitoring costs little and prevents surprises, but the data is only '
        'as good as the polling interval and the retention. A five-minute poll '
        'misses microbursts; a one-minute poll for a year is a lot of data.',
    commands:
        'show interfaces summary\n'
        'show interfaces GigabitEthernet1/0/1 | include rate|errors|drops\n'
        '! Export to a time-series store; keep at least 13 months for a\n'
        '! year-over-year comparison.',
    verify:
        'A busy-hour graph for the last 30 days, the top five talkers, and a '
        'calculated months-to-threshold. If the graph is flat, check that the '
        'polling is actually working before believing it.',
    pitfalls:
        'Planning on averages. Ignoring errors and discards, which saturate '
        'before bandwidth does. And a growth rate taken from a migration month '
        'rather than a normal one.',
    aspects: [
      'busy hour',
      '95th percentile',
      'growth',
      'baseline',
      'threshold',
    ],
    facts: {
      'Use': 'Busy hour, not average',
      'Billing': '95th percentile common',
      'Retention': '13 months for YoY',
      'Trigger': 'Threshold minus lead time',
    },
  ),
  NetworkTech(
    id: 'change-management',
    name: 'Change management',
    aliases: [
      'change management',
      'change window',
      'moc',
      'rollback',
      'maintenance window',
      'peer review',
    ],
    summary:
        'A network change is safe when it has a reviewed plan, a pre-check, a '
        'post-check, a rollback trigger and a named person who can call it.',
    mechanism:
        'The plan states what will change, why, the exact commands or template, '
        'the expected effect, the verification and the rollback. A peer review '
        'catches the missing interface or the ACL that blocks management. The '
        'window is chosen for business impact, and out-of-band access is '
        'confirmed before the first command. During the change, each step is '
        'gated: if the post-check fails, stop and roll back, do not continue '
        'and hope the next step fixes it.',
    whenToUse:
        'Every production change. The depth of the process should match the '
        'blast radius: a single access port is a ticket, a core routing change '
        'is a reviewed plan with a bridge call.',
    tradeoffs:
        'Process slows individual changes and prevents the outages that cost '
        'far more. Too much process and engineers route around it; too little '
        'and one typo becomes a weekend.',
    commands:
        '! The artifacts: change record, config diff, pre/post check list,\n'
        '! rollback commands, and a communication plan. The CLI is the easy part.',
    verify:
        'The post-check proves the intended state and that nothing else moved: '
        'neighbor counts, route counts, interface state, and one real '
        'application transaction.',
    pitfalls:
        'A rollback that was never tested. A change made outside the window '
        'because it was small. And no record of the starting state, so nobody '
        'can prove what changed.',
    aspects: ['rollback', 'change window', 'peer review', 'pre-check'],
    facts: {
      'Gate': 'Pre-check, change, post-check',
      'Rollback': 'Tested and ready',
      'Access': 'Out-of-band confirmed',
      'Record': 'Diff and starting state',
    },
  ),
  NetworkTech(
    id: 'rca',
    name: 'Root cause analysis',
    aliases: [
      'root cause',
      'rca',
      'postmortem',
      'post-mortem',
      'five whys',
      'incident review',
    ],
    summary:
        'A root-cause analysis finds the earliest decision or condition that '
        'made the incident possible, then fixes the system so the same class of '
        'failure cannot repeat.',
    mechanism:
        'Start with the timeline from monitoring and logs, not memory. Separate '
        'the trigger (the link that failed) from the cause (no redundancy) and '
        'the contributing factors (the alert that nobody saw, the runbook that '
        'was wrong). The five whys is a tool to keep asking why past the first '
        'convenient answer; it is not a ritual. End with owned actions, dates '
        'and a way to verify each one, and classify the incident so trends are '
        'visible.',
    whenToUse:
        'After every customer-impacting incident, and after near misses. A near '
        'miss reviewed is cheaper than the outage that would have followed.',
    tradeoffs:
        'It costs engineer time and can turn into blame if it is not run as a '
        'blameless review. Without follow-through on actions, it becomes '
        'paperwork that repeats every quarter.',
    commands:
        '! Evidence to collect: device logs with timestamps, syslog, flow data,\n'
        '! change records for the preceding 72 hours, and the monitoring graph\n'
        '! at the moment of impact.',
    verify:
        'Each action has an owner, a date and a test. Re-run the failure '
        'scenario in a lab or a maintenance window to prove the fix, not just '
        'that the symptom stopped.',
    pitfalls:
        'Stopping at human error. A timeline built from memory. And actions '
        'that are all "be more careful" rather than a design or automation '
        'change that removes the possibility.',
    aspects: ['postmortem', 'five whys', 'timeline', 'blameless'],
    facts: {
      'Start': 'Timeline from evidence',
      'Separate': 'Trigger, cause, factors',
      'End': 'Owned actions with dates',
      'Tone': 'Blameless',
    },
  ),
  NetworkTech(
    id: 'wifi6e',
    name: 'Wi-Fi 6E',
    aliases: ['wifi 6e', 'wi-fi 6e', '6 ghz', '6ghz', '6e', 'wifi6e'],
    summary:
        'Wi-Fi 6E is Wi-Fi 6 extended into the 6 GHz band, which adds clean '
        'channels and removes legacy interference at the cost of shorter range.',
    mechanism:
        '6 GHz offers up to 1200 MHz of spectrum, with 14 additional 80 MHz '
        'channels and seven 160 MHz channels, and only 6E devices may use it. '
        'That means no legacy 2.4 or 5 GHz clients, so airtime is not spent on '
        'protection or slower rates. The trade-off is propagation: 6 GHz does '
        'not penetrate walls as well as 2.4 GHz, so coverage needs more APs or '
        'closer placement. Clients also need to support 6E and the AP must '
        'advertise the reduced neighbor report so clients can find the band.',
    whenToUse:
        'High-density areas with modern clients: offices, auditoriums, '
        'classrooms. It is not a replacement for 2.4 GHz coverage for IoT and '
        'legacy devices.',
    tradeoffs:
        'Clean spectrum and higher throughput, but shorter range, new client '
        'hardware and a design that must account for three bands. An AP that '
        'advertises 6 GHz but has no backhaul capacity simply moves the '
        'bottleneck.',
    commands:
        '! Controller-driven: enable the 6 GHz radio, set the channel width\n'
        '! (80 MHz is a sane default), and keep 2.4 GHz for IoT only.\n'
        'show ap summary\n'
        'show ap dot11 6ghz summary',
    verify:
        'Survey on 6 GHz with a 6E client, check the channel width and the '
        'actual PHY rate, and confirm the client is not falling back to 5 GHz. '
        'A clean spectrum survey is not a coverage survey.',
    pitfalls:
        'Designing 6 GHz with 5 GHz coverage assumptions. Using 160 MHz '
        'everywhere and running out of channels. And expecting legacy clients '
        'to benefit.',
    aspects: ['6 ghz', '6e', '160 mhz', 'reduced neighbor report'],
    facts: {
      'Spectrum': 'Up to 1200 MHz',
      'Channels': 'Seven 160 MHz',
      'Range': 'Shorter than 5 GHz',
      'Clients': '6E only',
    },
  ),
  NetworkTech(
    id: 'vrf-lite',
    name: 'VRF-lite',
    aliases: ['vrf-lite', 'vrf lite', 'virtual routing forwarding', 'vrf'],
    summary:
        'VRF-lite keeps separate routing tables on one device without MPLS, so '
        'overlapping addresses and separate policies coexist.',
    mechanism:
        'Each VRF has its own interfaces, routing table and protocol instances. '
        'Traffic cannot cross between VRFs unless it is routed through a '
        'firewall, a leak point or a shared service VRF. VRF-lite is the '
        'enterprise version of the provider VRF: no MPLS labels, no MP-BGP '
        'VPNv4, just local tables and static or IGP routes. Route leaking is '
        'deliberately explicit, which is the point.',
    whenToUse:
        'Segmentation on a campus or branch, overlapping addresses after a '
        'merger, and separating guest, staff, OT and management without buying '
        'a firewall for every boundary.',
    tradeoffs:
        'Strong isolation and clean policy, but every inter-VRF path needs an '
        'explicit device and rule. It also multiplies routing protocol '
        'instances and makes troubleshooting require the VRF context on every '
        'command.',
    commands:
        'ip vrf GUEST\n'
        ' rd 65000:20\n'
        'interface GigabitEthernet0/2.20\n'
        ' encapsulation dot1Q 20\n'
        ' ip vrf forwarding GUEST\n'
        ' ip address 192.168.20.1 255.255.255.0\n'
        '! Inter-VRF traffic must route through a firewall or a leak.',
    verify:
        'show ip route vrf GUEST, show ip vrf interfaces, and a ping with the '
        'VRF specified. A ping that works without the VRF keyword went through '
        'the global table by mistake.',
    pitfalls:
        'Forgetting the VRF keyword on a show or debug command and concluding '
        'the route is missing. A route leak that quietly joins two VRFs. And a '
        'default route in every VRF that sends guest traffic to the core.',
    aspects: ['vrf', 'route leaking', 'segmentation', 'overlapping addresses'],
    facts: {
      'Tables': 'One per VRF',
      'Labels': 'None, unlike MPLS L3VPN',
      'Crossing': 'Explicit leak or firewall',
      'Command': 'Add the vrf keyword',
    },
  ),
  NetworkTech(
    id: 'wan-topology',
    name: 'WAN topology',
    aliases: [
      'hub and spoke',
      'hub-and-spoke',
      'full mesh',
      'partial mesh',
      'wan topology',
      'spoke',
    ],
    summary:
        'Hub-and-spoke centralizes policy and cost; full mesh removes the hub '
        'from the path but multiplies tunnels and complexity.',
    mechanism:
        'In hub-and-spoke every branch has a tunnel to the hub, so branch to '
        'branch traffic goes through it. That is simple to secure and easy to '
        'monitor, and it makes the hub a capacity and failure bottleneck. Full '
        'mesh gives every site a path to every other, which is best for '
        'low-latency any-to-any traffic but needs a scalable tunnel technology '
        '(DMVPN phase 3, SD-WAN, or a provider VPN) or it collapses under N '
        'squared tunnels. Partial mesh keeps the hub for policy and adds direct '
        'paths for the heavy pairs.',
    whenToUse:
        'Hub-and-spoke for a small or policy-centralized estate; full mesh for '
        'real-time any-to-any traffic and a small number of sites; partial mesh '
        'when most traffic is to the data center but a few pairs need a direct '
        'path.',
    tradeoffs:
        'The hub is cheap and simple until it is the bottleneck. Full mesh is '
        'fast until the tunnel count and the routing policy become the '
        'operational problem. The right answer follows the traffic matrix, not '
        'a preference.',
    commands:
        '! DMVPN phase 3 on the hub:\n'
        'interface Tunnel0\n'
        ' ip nhrp network-id 1\n'
        ' ip nhrp redirect\n'
        ' tunnel protection ipsec profile DMVPN',
    verify:
        'The traffic matrix first: which site pairs actually exchange traffic '
        'and how much. Then per-tunnel latency and throughput, and a hub '
        'failure test. A topology diagram is not a traffic matrix.',
    pitfalls:
        'Building full mesh because it sounds better, then discovering the hub '
        'still carries most traffic. A hub with no redundant path. And a '
        'spoke-to-spoke path that exists on paper but is never used because '
        'the routing policy still points at the hub.',
    aspects: ['hub and spoke', 'full mesh', 'partial mesh', 'dmvpn'],
    facts: {
      'Hub': 'Central policy, single bottleneck',
      'Full mesh': 'Any-to-any, N squared tunnels',
      'Partial': 'Hub plus direct pairs',
      'Driver': 'Traffic matrix',
    },
  ),
  NetworkTech(
    id: 'ntp',
    name: 'NTP',
    aliases: [
      'ntp',
      'network time protocol',
      'time sync',
      'chrony',
      'stratum',
      'clock sync',
    ],
    summary:
        'NTP keeps clocks within milliseconds so logs correlate, certificates '
        'validate and authentication protocols do not reject each other.',
    mechanism:
        'A client exchanges timestamps with a server and computes offset and '
        'round-trip delay. Stratum 0 is the reference clock, stratum 1 is '
        'directly attached, and each layer adds stratum. A client needs several '
        'servers to detect a falseticker; a single server is a single point of '
        'wrong time. Authentication (symmetric keys or NTS) prevents spoofing. '
        'Kerbos and tokens often reject a clock skew above five minutes, and '
        'certificate validation fails outside its validity window.',
    whenToUse:
        'Every device and server. The design question is where the internal '
        'servers get their time and how the network reaches them without '
        'depending on the path being fixed.',
    tradeoffs:
        'Accurate time is cheap and essential, but an internal NTP server that '
        'is itself wrong is worse than none. Blocking NTP at the edge without '
        'an internal source leaves devices drifting.',
    commands:
        'ntp server 10.0.0.10 prefer\n'
        'ntp server 10.0.1.10\n'
        'ntp authentication-key 1 md5 SECRET\n'
        'ntp trusted-key 1\n'
        'clock timezone UTC 0',
    verify:
        'show ntp status (synchronized and stratum), show ntp associations '
        '(the offset and jitter per server), and the same on a server. A '
        'device with the right time but the wrong timezone still logs the '
        'wrong local hour.',
    pitfalls:
        'One NTP server, so a falseticker is trusted. An ACL that blocks UDP '
        '123 from the management network. And a virtualized server whose clock '
        'drifts because the hypervisor is not disciplined.',
    aspects: ['stratum', 'chrony', 'time sync', 'clock skew'],
    facts: {
      'Port': 'UDP 123',
      'Stratum': 'Distance from reference',
      'Skew limit': 'Often 5 minutes for auth',
      'Best practice': 'Multiple servers',
    },
  ),
  NetworkTech(
    id: 'syslog-snmp',
    name: 'Syslog and SNMP',
    aliases: ['syslog', 'snmp', 'snmpv3', 'trap', 'logging'],
    summary:
        'Syslog carries event messages and SNMP polls or traps state; both need '
        'accurate time, a reachable collector and a retention policy.',
    mechanism:
        'Syslog sends UDP 514 (or TCP/TLS 6514) messages with a facility, '
        'severity and timestamp. SNMP polls OIDs over UDP 161 and sends traps '
        'to 162; version 3 adds authentication and encryption. Traps are '
        'unreliable by design (UDP, no acknowledgement), so polling is the '
        'source of truth and traps are the fast hint. Streaming telemetry '
        'pushes structured data on a schedule and is replacing SNMP for rate '
        'and counter data on modern platforms.',
    whenToUse:
        'Every production network. The design decision is what is collected, '
        'where it is retained, and which events page a human versus fill a '
        'dashboard.',
    tradeoffs:
        'More data is not more visibility: an unparsed syslog stream is noise, '
        'and a trap that nobody routes is worse than no trap. SNMPv2c sends '
        'community strings in clear text; SNMPv3 should be the default.',
    commands:
        'logging host 10.0.0.20\n'
        'logging trap informational\n'
        'logging source-interface Loopback0\n'
        'snmp-server group OPS v3 priv\n'
        'snmp-server host 10.0.0.20 version 3 priv OPS',
    verify:
        'A test message arrives with the right timestamp and source, and a '
        'poll returns the expected OID. Check the collector, not just the '
        'device: a full disk or a broken parser looks like no logs at all.',
    pitfalls:
        'Logging without time sync, so events cannot be correlated. SNMPv2c '
        'with the default public community. And alerting on every trap until '
        'the important one is ignored.',
    conceptOwned: true,
    aspects: [
      'snmpv3',
      'trap',
      'facility',
      'severity',
      'telemetry',
      'collector',
    ],
    facts: {
      'Syslog': 'UDP 514, TCP/TLS 6514',
      'SNMP': 'UDP 161, traps 162',
      'SNMPv3': 'Auth and privacy',
      'Traps': 'UDP, unacknowledged',
    },
  ),
  NetworkTech(
    id: 'switch-hardening',
    name: 'Switch hardening',
    aliases: [
      'switch hardening',
      'secure a switch',
      'switch security',
      'harden a switch',
      'harden',
      'harden a cisco switch',
      'harden cisco switches',
      'management plane security',
    ],
    summary:
        'A switch is a management endpoint with a forwarding chip attached: '
        'harden the management plane, the control plane and the unused ports, '
        'in that order.',
    mechanism:
        'Management access is separated into a dedicated VLAN or out-of-band '
        'network, authenticated through AAA (TACACS+ or RADIUS) with SSHv2 '
        'only. The control plane is protected with BPDU Guard, Root Guard, '
        'storm control and control-plane policing. The data plane gets DHCP '
        'snooping, dynamic ARP inspection, port security and private VLAN or '
        'isolation where the platform supports it. Every unused port is shut '
        'down and assigned to an unused VLAN.',
    whenToUse:
        'Every production switch, before it carries traffic. The order matters: '
        'if management is reachable from a user VLAN, the rest of the hardening '
        'is decoration.',
    tradeoffs:
        'Hardening adds operational friction: a lost password or a mis-scoped '
        'AAA server can lock you out, and BPDU Guard turns a misconfigured '
        'downstream switch into an err-disabled port. Keep a tested '
        'out-of-band path and a break-glass local account with a rotated '
        'password.',
    commands:
        'enable secret <strong-secret>\n'
        'aaa new-model\n'
        'aaa authentication login default group tacacs+ local\n'
        'ip ssh version 2\n'
        'line vty 0 15\n'
        ' transport input ssh\n'
        'login authentication default\n'
        'interface range GigabitEthernet0/1-48\n'
        ' switchport mode access\n'
        ' switchport access vlan 999\n'
        ' shutdown',
    verify:
        'Telnet is refused, SSHv2 works with a central account, the '
        'management VLAN is not reachable from a user port, an unused port is '
        'shut and in the parking VLAN, and BPDU Guard err-disables a test '
        'switch connected to an access port.',
    pitfalls:
        'Leaving Telnet enabled because a tool still uses it. A shared local '
        'password with no AAA. A management VLAN that is also the user VLAN. '
        'And hardening the config without testing the out-of-band path first.',
    aspects: ['ssh', 'aaa', 'bpdu guard', 'dhcp snooping', 'port security'],
    facts: {
      'Management': 'Dedicated VLAN or out-of-band',
      'Access': 'SSHv2 and AAA, no Telnet',
      'Control plane': 'BPDU Guard, Root Guard, storm control',
      'Unused ports': 'Shut, parking VLAN',
    },
  ),
  // --- Forwarding and design judgment -------------------------------------
  NetworkTech(
    id: 'ecmp',
    name: 'ECMP',
    aliases: [
      'ecmp',
      'equal cost',
      'equal-cost',
      'multipath',
      'multipath routing',
      'load sharing',
      'load balancing across links',
    ],
    summary:
        'ECMP installs every equal-cost next hop for a prefix and hashes '
        'each flow onto one of them, so capacity is shared per flow, never '
        'per packet.',
    mechanism:
        'The routing table can hold several next hops for one prefix when '
        'the metric is identical. The forwarding chip hashes selected header '
        'fields - usually source and destination IP, sometimes the 5-tuple or '
        'the label stack - into a bucket, and each bucket maps to one next '
        'hop. The hash is per flow and sticky, so a flow stays on one path; '
        'that keeps TCP in order but means one elephant flow cannot use more '
        'than one link. Unequal-cost multipath (EIGRP variance, or BGP '
        'multipath with as-path and router-ID relaxations) works the same '
        'way with weights.',
    whenToUse:
        'Two or more links of the same cost to the same destination, where '
        'you want both used and can accept per-flow spread: dual-homed '
        'servers, two providers of the same bandwidth, parallel WAN links.',
    tradeoffs:
        'Flow-level imbalance is inherent: a few large flows can fill one '
        'member while the other idles. ECMP also forces symmetric-path care - '
        'stateful firewalls and NAT break when the return flow takes a '
        'different member. Some platforms limit the number of hash buckets or '
        'next hops per prefix.',
    commands:
        'router eigrp 100\n'
        ' variance 2\n'
        'router bgp 65001\n'
        ' maximum-paths 4\n'
        ' maximum-paths ibgp 4\n'
        'ip cef load-sharing algorithm tuple',
    verify:
        'show ip route 0.0.0.0 (all next hops listed), show ip cef '
        '<prefix> (the hash buckets and their interfaces), and show '
        'interfaces | include rate to confirm both members carry traffic.',
    pitfalls:
        'ECMP across a stateful firewall: the return packet arrives on a '
        'different member and is dropped as out of state. ECMP with NAT on '
        'the box: translations differ per path. Assuming ECMP spreads a '
        'single backup job - it will not.',
    aspects: ['ecmp', 'multipath', 'hash', 'has'],
    facts: {
      'Hash basis': '5-tuple or src/dst IP, per platform',
      'Spread': 'per flow, not per packet',
      'Unequal cost': 'EIGRP variance, BGP multipath',
    },
  ),
  NetworkTech(
    id: 'loop-prevention',
    name: 'Loop prevention',
    aliases: [
      'loop prevention',
      'prevent a loop',
      'prevent loops',
      'layer 2 loop',
      'l2 loop',
      'routing loop',
      'split horizon',
      'poison reverse',
      'count to infinity',
    ],
    summary:
        'Layer 2 loops are stopped by a spanning tree; layer 3 loops are '
        'stopped by TTL and by the protocol rules that refuse to advertise a '
        'route back the way it came.',
    mechanism:
        'STP elects one root and blocks every port that would close a loop, '
        'recomputing on a topology change; without it, a broadcast frame '
        'multiplies until the MAC table and the links saturate. At layer 3 '
        'the TTL is the last line of defence, but convergence loops are '
        'prevented earlier: split horizon does not advertise a route out the '
        'interface it was learned on, poison reverse advertises it with an '
        'infinite metric, and route tags stop redistribution from feeding a '
        'route back into the protocol that produced it. BGP refuses any path '
        'whose AS_PATH already contains the local AS. In an overlay, the '
        'underlay must not have a loop either: a VXLAN or EVPN loop is a '
        'broadcast storm with extra steps.',
    whenToUse:
        'Every design with more than one path: redundant switch pairs, dual '
        'WAN, any redistribution between protocols, and every overlay whose '
        'underlay is a triangle.',
    tradeoffs:
        'STP costs you half the redundant links (one blocked), and the '
        'blocked link is capacity you paid for. Routing loops are cheaper to '
        'prevent than to find: a tag or a filter is one line, a TTL-expired '
        'trace at 2 a.m. is an outage.',
    commands:
        'spanning-tree mode rapid-pvst\n'
        'spanning-tree vlan 10 root primary\n'
        'spanning-tree vlan 10 root secondary\n'
        'interface range g0/1-2\n'
        ' spanning-tree guard root\n'
        'router ospf 1\n'
        ' redistribute static subnets route-map TAG-ONLY\n'
        'route-map TAG-ONLY permit 10\n'
        ' match tag 100',
    verify:
        'show spanning-tree vlan 10 (root and blocked ports), show ip route '
        '<prefix> (metric and next hop after convergence), and show ip bgp '
        '<prefix> for an AS path that contains the local AS.',
    pitfalls:
        'Redistributing in both directions without tags or prefix filters, '
        'which is how a static route becomes an infinite metric loop. '
        'Blocking STP on an access port with BPDU Filter and then bridging '
        'it. Trusting a stack or an MLAG pair to be loop-free without a '
        'protocol check.',
    aspects: ['split horizon', 'poison reverse', 'loop guard', 'root guard'],
    facts: {
      'L2': 'STP/RSTP/MST blocks one path per loop',
      'L3': 'TTL plus split horizon, poison reverse, tags',
      'BGP': 'AS_PATH contains local AS is refused',
    },
  ),
  NetworkTech(
    id: 'tcam',
    name: 'TCAM',
    aliases: [
      'tcam',
      'ternary cam',
      'cam table',
      'tcam exhaustion',
      'hardware table',
      'forwarding table',
      'fib',
    ],
    summary:
        'TCAM is the expensive, parallel-lookup memory that holds ACLs, '
        'policy and forwarding entries; RAM is the cheap, sequential memory '
        'that holds the routing table and everything the CPU works on.',
    mechanism:
        'A ternary CAM compares every entry against the key in one clock '
        'cycle and supports a wildcard bit (0, 1, don\'t-care), which is '
        'exactly what an ACL or an LPM lookup needs. That parallelism costs '
        'silicon area and power, so a switch has a few thousand TCAM entries '
        'and must carve them into regions for ACLs, unicast routes, multicast '
        'routes and QoS. The RIB lives in ordinary RAM, where prefixes are '
        'cheap; the FIB is the subset that fits in TCAM. When a feature is '
        'enabled, it takes a slice of the same table, and something else has '
        'to give.',
    whenToUse:
        'Any time a design adds ACLs, policy-based routing, VXLAN, IPv6 or '
        'multicast: check the platform table sizes before the design, not '
        'after the deploy.',
    tradeoffs:
        'TCAM is fast but finite and shared: an ACL-heavy edge can exhaust '
        'the table and start punting to the CPU, which looks like a routing '
        'problem and is a memory allocation problem. Vendors carve it '
        'differently, and a software upgrade can change the default carve.',
    commands:
        'show platform tcam utilization\n'
        'show sdm prefer\n'
        'sdm prefer routing\n'
        'show ip cef summary',
    verify:
        'show platform tcam utilization (per-region used and free), show sdm '
        'prefer (the template in effect and what it needs to reboot), and '
        'show ip cef <prefix> to prove the entry is in the FIB, not only the '
        'RIB.',
    pitfalls:
        'Adding 200 ACL lines to a platform with 1,000 TCAM entries in the '
        'ACL region and calling it a performance problem. Assuming the FIB '
        'and the RIB are the same table. Changing the SDM template without '
        'noticing it requires a reload.',
    aspects: ['tcam', 'memory', 'table size', 'carve'],
    facts: {
      'TCAM': 'parallel, wildcard, small, expensive',
      'RAM': 'sequential, large, cheap',
      'Shared by': 'ACLs, routes, QoS, tunnels',
    },
  ),
  NetworkTech(
    id: 'portfast',
    name: 'PortFast and BPDU Guard',
    aliases: [
      'portfast',
      'port fast',
      'edge port',
      'bpdu guard',
      'bpduguard',
      'bpdu filter',
      'spanning tree edge',
    ],
    summary:
        'PortFast skips the listening and learning wait on an edge port, so '
        'a PC can DHCP at power-on; BPDU Guard is the safety catch that '
        'disables the port if it ever hears spanning tree.',
    mechanism:
        'A normal STP port goes blocking, listening, learning, forwarding - '
        'about 30 seconds with classic STP, a few seconds with RSTP - and a '
        'PC that boots faster than that gets no address. PortFast puts the '
        'port straight into forwarding because an edge port cannot create a '
        'loop. The moment a switch is plugged into that port, the assumption '
        'is false, so BPDU Guard err-disables it on the first BPDU. BPDU '
        'Filter is the opposite: it stops sending and receiving BPDUs, which '
        'is only defensible on a port that must stay up (a hypervisor or a '
        'third-party switch you do not control).',
    whenToUse:
        'PortFast on every port that faces a single host: workstations, '
        'printers, phones, AP ports, hypervisor uplinks. BPDU Guard with it, '
        'always. BPDU Filter almost never.',
    tradeoffs:
        'PortFast on an uplink is a loop waiting to happen, and BPDU Guard '
        'turns that into a partial outage instead of a broadcast storm - '
        'which is the better failure. BPDU Filter on an uplink hides the loop '
        'from STP entirely.',
    commands:
        'interface range g1/0/1-24\n'
        ' spanning-tree portfast\n'
        ' spanning-tree bpduguard enable\n'
        'errdisable recovery cause bpduguard\n'
        'errdisable recovery interval 300',
    verify:
        'show spanning-tree interface g1/0/1 (edge/portfast state), show '
        'spanning-tree summary (PortFast and BPDU Guard defaults), and show '
        'interfaces status err-disabled after an event.',
    pitfalls:
        'Global portfast default without BPDU Guard, so an accidental uplink '
        'is both fast and looped. Clearing an err-disabled port without '
        'finding the device that sent the BPDU. BPDU Filter on a trunk.',
    // The concept layer owns "what is portfast / which ports need it"; this
    // entry answers the uplink and trunk questions, where the risk lives.
    aspects: [
      'portfast on an uplink',
      'portfast on a trunk',
      'portfast on a link',
      'enable portfast',
      'bpdu guard on an uplink',
    ],
    conceptOwned: true,
    facts: {
      'Classic STP wait': '30 s to forwarding',
      'RSTP edge': 'immediate forwarding',
      'BPDU Guard': 'err-disables on first BPDU',
    },
  ),
  NetworkTech(
    id: 'ip-planning',
    name: 'IP address planning',
    aliases: [
      'ip address plan',
      'ip addressing plan',
      'address plan',
      'ip scheme',
      'ip addressing scheme',
      'address scheme',
      'subnet plan',
      'addressing plan',
      'ipam plan',
      'plan ip addresses',
      'plan addresses',
      'address planning',
      'subnet planning',
      'plan address space',
    ],
    summary:
        'An address plan is a budget: summarise at every layer so the '
        'routing table stays small, leave room in each block for growth, and '
        'derive every site block from one formula so nobody has to guess.',
    mechanism:
        'Start from the largest summarisable unit. Allocate a block per '
        'region, a /16 or a /20 inside it per site, then carve site blocks '
        'by function (loopbacks, point-to-point, users, voice, servers, '
        'management, guest, IoT) using fixed offsets so the layout is '
        'predictable. Point-to-point links get /31 (RFC 3021) or /30; user '
        'VLANs get the smallest block that holds the site with 30-50 percent '
        'headroom. IPv6 uses the same shape at a different scale: /48 per '
        'site, /64 per VLAN, and never anything longer than /64 on a LAN that '
        'uses SLAAC.',
    whenToUse:
        'Before the first device, and again before every merger, cloud '
        'connection or new site type. Retrofitting a plan onto live space is '
        'the expensive version.',
    tradeoffs:
        'A tidy plan wastes addresses and looks wasteful in a spreadsheet; '
        'a tight plan becomes 20 summary routes and a redesign in two years. '
        'Choose the waste you can afford.',
    commands:
        'ip address 10.20.0.1 255.255.255.252\n'
        'ip address 10.20.255.1 255.255.255.255\n'
        'ipv6 address 2001:db8:20::1/64\n'
        'ipv6 address 2001:db8:20:ffff::1/128',
    verify:
        'show ip route summary (prefix count before and after '
        'summarisation), show ip interface brief (no overlaps), and an IPAM '
        'export diffed against the live ARP and route tables.',
    pitfalls:
        'Using 192.168.0.0/24 everywhere and then needing VPNs between sites. '
        'Allocating a /24 per site when the WAN has to carry the summary. '
        'Overlapping with a cloud VPC or a partner network because nobody '
        'checked the RFC 1918 plan against the cloud ranges.',
    aspects: ['plan', 'scheme', 'summarise', 'summarize'],
    facts: {
      'Site block': '/48 per site is the IPv6 rule of thumb',
      'Point-to-point': '/31 preferred, /30 accepted',
      'Cloud': 'reserve a block per VPC/region',
    },
  ),

  // --- Service provider and transit ---------------------------------------
  NetworkTech(
    id: 'vlan-plan',
    name: 'VLAN numbering plan',
    aliases: [
      'vlan plan',
      'vlan numbering',
      'vlan number plan',
      'vlan allocation',
      'vlan scheme',
      'vlan standard',
      'vlan naming',
      'plan vlans',
      'planning vlans',
      'vlan design',
      'vlan id plan',
    ],
    summary:
        'A VLAN plan is a numbering standard, not a list of VLANs: the same '
        'function gets the same VLAN ID at every site, the site lives in the '
        'subnet, and the numbers nobody may use are written down before the '
        'first switch is configured.',
    mechanism:
        'Give each function a fixed ID (10 management, 20 users, 30 voice, 40 '
        'guest, 50 IoT, 60 servers, 70 DMZ, 80 transit) so a template, an ACL '
        'or a monitoring rule is identical at every site and a technician can '
        'read "VLAN 30" as voice anywhere. Keep the site in the IP prefix, not '
        'in the VLAN ID: VLANs are local to the switch, so reusing 20 for users '
        'at every site costs nothing and avoids a numbering map nobody '
        'maintains. Reserve 1, 1002-1005 and 4095 as never-use, and leave gaps '
        'between blocks so a new function can slot in without renumbering. '
        'Where VXLAN/EVPN carries the VLAN across sites, map the local VLAN to '
        'a VNI with the same function offset (VLAN 20 -> VNI 10020) instead of '
        'trying to make the VLAN ID globally unique.',
    whenToUse:
        'Before the first access switch, and again before a template rollout, a '
        'merger, or a WLAN/EVPN project that will cross sites.',
    tradeoffs:
        'Function-based IDs keep templates simple and are wrong the day two '
        'sites must share a Layer 2 segment - then the segment needs its own '
        'ID and the VNI mapping. Site-based IDs are self-documenting but '
        'explode into hundreds of VLANs, TCAM pressure and a numbering '
        'spreadsheet that nobody updates.',
    commands:
        'vlan 10\n'
        ' name MGMT\n'
        'vlan 20\n'
        ' name USERS\n'
        'vlan 30\n'
        ' name VOICE\n'
        'vlan 999\n'
        ' name PARKING\n'
        '! No VTP: vtp mode transparent\n'
        '! Trunks: switchport trunk allowed vlan 10,20,30,999',
    verify:
        'show vlan brief (no unused VLAN carries ports), show interfaces '
        'switchport (native VLAN is the parking VLAN, allowed lists match the '
        'standard), and a diff of every switch against the VLAN template in the '
        'source of truth.',
    pitfalls:
        'Using VLAN 1 for users because it is already there. Numbering by site '
        'and then running out at 4094. Allowing every VLAN on every trunk '
        '(broadcast and STP reach where they should not). Turning on VTP server '
        'mode and erasing another site VLAN database. Leaving the voice VLAN to '
        'be discovered by hand instead of LLDP/CDP.',
    aspects: ['numbering', 'allocation', 'naming', 'standard', 'vlan plan'],
    facts: {
      'Reserved': '1, 1002-1005, 4095',
      'Normal range': '2-1001',
      'Extended': '1006-4094 (not on all platforms)',
      'Trunk default': 'All VLANs allowed until pruned',
    },
  ),

  NetworkTech(
    id: 'srv6',
    name: 'SRv6',
    aliases: [
      'srv6',
      'segment routing v6',
      'segment routing ipv6',
      'srv6 sid',
      'network programming',
    ],
    summary:
        'SRv6 carries the segment list inside the IPv6 header as a sequence '
        'of 128-bit SIDs, so the network is programmed with addresses instead '
        'of MPLS labels.',
    mechanism:
        'Each node advertises a SID from its locator. The headend pushes a '
        'segment list into a segment routing header (SRH) and sets the '
        'destination to the first SID; each hop executes the behaviour '
        'encoded in that SID (end, end.x, end.dx4) and advances the pointer. '
        'Because the SIDs are IPv6 addresses, they are routable without MPLS, '
        'which makes SRv6 attractive on hardware that already forwards IPv6 '
        'at line rate. TI-LFA gives sub-50 ms repair by precomputing a '
        'backup segment list per destination.',
    whenToUse:
        'A service provider or large enterprise wanting traffic engineering '
        'and fast repair without an MPLS stack, especially where the hardware '
        'and the operations team are already IPv6-first.',
    tradeoffs:
        'The SRH is large: a 10-segment list costs 160 bytes of header, '
        'which eats into the MTU and needs careful MSS handling. Encapsulation '
        'is heavier than MPLS, and troubleshooting is IPv6 troubleshooting - '
        'harder to read for many teams. Not every ASIC does the full set of '
        'behaviours.',
    commands:
        'segment-routing srv6\n'
        ' locator MAIN\n'
        '  prefix 2001:db8:100::/48\n'
        'interface g0/1\n'
        ' segment-routing srv6',
    verify:
        'show segment-routing srv6 locator (SID allocation), show segment-'
        'routing srv6 sid (installed behaviours), and traceroute with the '
        'SRH visible to prove the segment list is being followed.',
    pitfalls:
        'Forgetting the MTU: a full segment list plus a 1500-byte payload '
        'fragments or drops. Assuming SRv6 is automatically on - the underlay '
        'still needs a working IGP and BGP. Testing only the happy path: '
        'delete a link and check TI-LFA repaths.',
    aspects: ['srv6', 'sid', 'srh', 'locator', 'ti-lfa'],
    facts: {
      'SID': '128-bit IPv6 address',
      'Header': 'SRH, 8 bytes per segment plus overhead',
      'Repair': 'TI-LFA sub-50 ms',
    },
  ),
  NetworkTech(
    id: 'mpls-te',
    name: 'MPLS traffic engineering',
    aliases: [
      'mpls te',
      'traffic engineering',
      'rsvp-te',
      'rsvp te',
      'mpls traffic engineering',
      'tunnel te',
    ],
    summary:
        'MPLS TE builds explicit label-switched paths with reserved bandwidth '
        'so traffic can be steered away from the IGP shortest path.',
    mechanism:
        'The headend computes a path against the traffic engineering '
        'database (IGP extensions advertise link bandwidth and affinity), '
        'signals it with RSVP-TE, and reserves bandwidth hop by hop. The '
        'resulting tunnel is a label stack that the IGP does not see, so you '
        'can move traffic off a congested shortest path without changing '
        'metrics. Autoroute or forwarding adjacency then injects the tunnel '
        'into the IGP so normal routing can use it.',
    whenToUse:
        'Provider cores and large enterprise backbones where the IGP '
        'shortest path concentrates traffic on one link and you need '
        'deterministic placement or fast reroute.',
    tradeoffs:
        'RSVP state per tunnel at every hop does not scale like segment '
        'routing, and the tunnels need governance: an unmanaged TE mesh '
        'becomes a second, undocumented topology. Bandwidth reservation is '
        'advisory - it reserves, it does not police.',
    commands:
        'interface tunnel 10\n'
        ' ip unnumbered Loopback0\n'
        ' tunnel mode mpls traffic-eng\n'
        ' tunnel destination 10.255.255.2\n'
        ' tunnel mpls traffic-eng bandwidth 100000\n'
        ' tunnel mpls traffic-eng path-option 10 explicit name VIA-R2',
    verify:
        'show mpls traffic-eng tunnels (path, bandwidth, state), show mpls '
        'traffic-eng topology (the TED the headend computes against), and '
        'show mpls forwarding-table to confirm the label stack.',
    pitfalls:
        'Reserving bandwidth on links whose real capacity is a provider '
        'rate limit. Pinning a path and then never re-optimising it. Forgetting '
        'that TE does not fix a routing loop - it steers around congestion.',
    aspects: ['te', 'rsvp', 'explicit path', 'bandwidth'],
    facts: {
      'Signalling': 'RSVP-TE',
      'Scale': 'state per LSP per hop',
      'Modern alternative': 'SR-MPLS / SRv6',
    },
  ),
  NetworkTech(
    id: 'bgp-flowspec',
    name: 'BGP FlowSpec',
    aliases: [
      'flowspec',
      'bgp flowspec',
      'flow spec',
      'rtbh',
      'remote triggered blackhole',
      'blackhole routing',
    ],
    summary:
        'FlowSpec distributes a match-and-action rule through BGP, so a '
        'DDoS can be dropped or rate-limited at the edge in seconds instead '
        'of being null-routed by hand.',
    mechanism:
        'A FlowSpec NLRI carries a match (destination prefix, source, '
        'protocol, ports, packet length, DSCP, TCP flags) and an action '
        'community: discard, rate-limit, redirect to a VRF, or mark. Because '
        'it rides BGP, it inherits the peer policy and the propagation, and '
        'it can be validated with RPKI origin validation. RTBH is the cruder '
        'cousin: advertise the target with a blackhole community and the '
        'whole prefix is dropped, including legitimate traffic.',
    whenToUse:
        'DDoS mitigation at the edge, provider-to-customer scrubbing '
        'control, and any case where a filter must be installed on many '
        'routers at once without touching each one.',
    tradeoffs:
        'FlowSpec rules are policy in the control plane, so a mistake is '
        'network-wide and instant. Hardware support for the action set varies '
        '(rate-limit especially), and the rules need a change-control path '
        'that is faster than the attack, which is a process problem, not a '
        'protocol one.',
    commands:
        'router bgp 65001\n'
        ' address-family ipv4 flowspec\n'
        '  neighbor 10.0.0.2 activate\n'
        'flow-spec ipv4\n'
        ' match destination 198.51.100.0/24 protocol tcp destination-port 443\n'
        ' action discard',
    verify:
        'show bgp ipv4 flowspec (received and installed rules), show '
        'flowspec ipv4 rules, and interface counters proving the drop.',
    pitfalls:
        'Blackholing a whole /24 for one attacked host, which is an outage '
        'you caused. No validation of received FlowSpec, so a peer can drop '
        'your traffic. Forgetting that the rule survives after the attack if '
        'nobody removed it.',
    aspects: ['flowspec', 'rtbh', 'ddos', 'action'],
    facts: {
      'Match': 'prefix, port, protocol, length, DSCP, flags',
      'Actions': 'discard, rate-limit, redirect, mark',
      'Scope': 'per peer, per address family',
    },
  ),
  NetworkTech(
    id: 'cgnat',
    name: 'CGNAT',
    aliases: [
      'cgnat',
      'carrier grade nat',
      'carrier-grade nat',
      'large scale nat',
      'lsn',
      'nat444',
      '100.64',
    ],
    summary:
        'CGNAT puts a second NAT layer at the provider so many subscribers '
        'share one public address pool, which breaks anything that assumes '
        'end-to-end addressing.',
    mechanism:
        'The subscriber gets a private address (often 100.64.0.0/10, RFC '
        '6598), the CGNAT translates it to a public address and port, and '
        'the provider logs the mapping per session. Port ranges are allocated '
        'per subscriber so a single customer cannot exhaust the pool, and the '
        'logging is what makes attribution possible. Port control protocol '
        '(PCP) or UPnP can punch holes for inbound services; without them, '
        'inbound does not exist.',
    whenToUse:
        'An ISP or a mobile network that has run out of public IPv4, as a '
        'bridge to IPv6 - never as a permanent substitute for it.',
    tradeoffs:
        'It breaks peer-to-peer, some games and VoIP, IPsec without NAT-T, '
        'and any protocol that embeds addresses. It also puts the provider in '
        'the middle of every session, with the logging obligations that '
        'implies. Port exhaustion for a heavy user is real.',
    commands:
        'ip nat inside source list CGN pool PUBLIC overload\n'
        'ip nat inside source list CGN pool PUBLIC overload\n'
        'ip nat log translations syslog\n'
        'access-list CGN permit 100.64.0.0 0.63.255.255',
    verify:
        'show ip nat translations total (pool usage), show ip nat statistics '
        '(hits, misses, pool exhaustion), and the syslog export proving '
        'per-session logging.',
    pitfalls:
        'Assuming a 100.64/10 address is private space you can route - it is '
        'provider space. No logging, so nobody can answer a lawful request or '
        'debug a session. Expecting inbound connections to work.',
    aspects: ['cgnat', 'nat444', 'port range', 'logging'],
    facts: {
      'Shared space': '100.64.0.0/10 (RFC 6598)',
      'Breaks': 'inbound, P2P, embedded-address protocols',
      'Mitigation': 'PCP, IPv6',
    },
  ),
  NetworkTech(
    id: 'peering',
    name: 'Internet peering',
    aliases: [
      'peering',
      'ixp',
      'internet exchange',
      'peering policy',
      'transit vs peering',
      'settlement free',
    ],
    summary:
        'Peering is two networks agreeing to exchange only their own and '
        'their customers\' routes for free; transit is paying someone to '
        'carry everything else.',
    mechanism:
        'At an internet exchange both parties connect to a shared switch '
        'fabric and peer over it, or they cross-connect directly. The '
        'technical shape is one eBGP session with strict filters: only your '
        'own prefixes and your customers\' out, only the peer\'s and their '
        'customers\' in, and a max-prefix limit. The economics are the point: '
        'traffic that stays on peering avoids transit cost, so the traffic '
        'ratio and the prefix list are negotiated, not assumed.',
    whenToUse:
        'When a meaningful share of your traffic goes to one network or one '
        'region, and you can meet the other side\'s peering policy (traffic '
        'ratio, presence, NOC).',
    tradeoffs:
        'Peering saves money but adds sessions, filters and a second failure '
        'domain to operate. A bad import filter turns a peer into a default '
        'route. The IXP fabric itself is a shared failure domain.',
    commands:
        'router bgp 65001\n'
        ' neighbor 192.0.2.1 remote-as 65002\n'
        ' neighbor 192.0.2.1 description IXP-PEER\n'
        ' neighbor 192.0.2.1 maximum-prefix 5000 90\n'
        ' neighbor 192.0.2.1 route-map PEER-IN in\n'
        ' neighbor 192.0.2.1 route-map PEER-OUT out',
    verify:
        'show ip bgp summary (session and prefix count), show ip bgp '
        'neighbors 192.0.2.1 received-routes (need soft-reconfiguration or '
        'route refresh), and the looking glass for the reverse direction.',
    pitfalls:
        'Leaking transit routes to a peer, which makes you a free transit '
        'provider. No max-prefix, so a peer misconfiguration takes your '
        'router down. Peering without monitoring the session.',
    aspects: ['peering', 'ixp', 'transit', 'filter'],
    facts: {
      'Cost': 'settlement-free, no money changes hands',
      'Filters': 'own and customer prefixes only',
      'Risk': 'route leak into or out of your AS',
    },
  ),

  // --- Automation and observability ---------------------------------------
  NetworkTech(
    id: 'netconf-yang',
    name: 'NETCONF and YANG',
    aliases: [
      'netconf',
      'yang',
      'yang model',
      'netconf yang',
      'candidate config',
      'commit confirmed',
    ],
    summary:
        'NETCONF is a transaction-oriented configuration protocol over SSH, '
        'and YANG is the data model that says what the configuration looks '
        'like - together they are how automation changes a device safely.',
    mechanism:
        'The session runs over SSH on port 830 with XML-encoded RPCs. The '
        'device exposes a datastore: running, candidate, and startup. The '
        'candidate datastore lets a tool stage edits, validate them against '
        'the YANG models, and commit atomically; commit confirmed applies the '
        'change but rolls it back automatically unless it is confirmed within '
        'a timeout, which is the safety net that makes remote changes '
        'survivable. YANG models the tree, including must and when '
        'constraints, so validation is done by the device, not the script.',
    whenToUse:
        'Any change at scale: templated rollouts, drift detection, and '
        'configuration that must be atomic or roll back on its own.',
    tradeoffs:
        'Model coverage is uneven - vendor deviations mean the same intent '
        'is a different XML path on different platforms. It is verbose, and '
        'the tooling is heavier than CLI. Commit confirmed is not universal, '
        'and a platform without it needs an out-of-band rollback plan.',
    commands:
        'netconf-yang\n'
        'aaa authorization exec default local\n'
        'ssh server v2\n'
        'ssh server netconf port 830',
    verify:
        'A get-config against the running datastore returning the expected '
        'tree, and a candidate commit that fails validation for a malformed '
        'model - proving validation is actually happening.',
    pitfalls:
        'Editing running directly instead of candidate plus commit, which '
        'loses atomicity. No commit confirmed, so a bad change locks you out. '
        'Trusting the model rather than the device: read back after commit.',
    aspects: ['netconf', 'yang', 'candidate', 'commit'],
    facts: {
      'Transport': 'SSH, port 830',
      'Encoding': 'XML RPCs',
      'Safety': 'candidate datastore and commit confirmed',
    },
  ),
  NetworkTech(
    id: 'gnmi',
    name: 'gNMI and OpenConfig',
    aliases: [
      'gnmi',
      'g rpc',
      'grpc',
      'openconfig',
      'streaming telemetry',
      'telemetry subscription',
    ],
    summary:
        'gNMI is a gRPC interface for getting, setting and streaming '
        'telemetry from network devices, and OpenConfig is the vendor-neutral '
        'model it usually speaks.',
    mechanism:
        'A gNMI client opens one HTTP/2 connection and issues Get, Set or '
        'Subscribe RPCs against paths in a tree. Subscribe can be ONCE, POLL '
        'or STREAM, and STREAM can send SAMPLE, ON_CHANGE or TARGET_DEFINED '
        'updates, which is what turns telemetry from a polled snapshot into a '
        'near-real-time feed. OpenConfig paths are the same across vendors '
        'where the model is implemented, which is the whole point: one '
        'collector, many platforms.',
    whenToUse:
        'High-frequency telemetry (interface counters, queue depth, optics), '
        'anywhere polling every five minutes is too slow or too expensive.',
    tradeoffs:
        'Model coverage still varies, and a path that exists on one platform '
        'may be absent or differently typed on another. The streaming volume '
        'is real: sample fast enough to see microbursts and you are moving '
        'megabytes per device per minute.',
    commands:
        'gnmic -a 192.0.2.10:57400 -u admin --insecure subscribe \\\n'
        '  --path /interfaces/interface/state/counters \\\n'
        '  --mode stream --stream-mode sample --sample-interval 10s',
    verify:
        'gnmic get --path /interfaces/interface[name=Ethernet1]/state, and '
        'the collector showing a steady stream rather than one snapshot.',
    pitfalls:
        'Sampling slower than the burst you are trying to find. Leaving '
        'STREAM subscriptions on interfaces during a maintenance window and '
        'flooding the collector. Assuming every path is implemented.',
    aspects: ['gnmi', 'telemetry', 'openconfig', 'stream'],
    facts: {
      'Transport': 'gRPC over HTTP/2, port 57400 typical',
      'Modes': 'once, poll, stream (sample/on-change)',
      'Model': 'OpenConfig paths',
    },
  ),
  NetworkTech(
    id: 'terraform-network',
    name: 'Terraform for networks',
    aliases: [
      'terraform',
      'infrastructure as code',
      'iac',
      'plan apply',
      'state file',
      'gitops',
      'pipeline deploy',
    ],
    summary:
        'Terraform turns network intent into a plan you can read, apply, and '
        'diff, with a state file that is the record of what it believes it '
        'built.',
    mechanism:
        'Providers describe resources; a plan compares the desired '
        'configuration against the state and the real API and shows the diff '
        'before anything changes. Apply executes it and updates the state. '
        'Because the state is the anchor, it must be remote and locked, or two '
        'engineers apply at once and the second one deletes the first one\'s '
        'work. Modules package the site pattern so 40 branches are the same '
        'code with different variables.',
    whenToUse:
        'Anything with more than a handful of devices or cloud objects, and '
        'every environment that must be reproducible after a failure.',
    tradeoffs:
        'A bad plan applied at scale is a fast outage, so the review of the '
        'plan is the control, and the pipeline must require it. State '
        'management is the operational cost: drift, imports and secrets need '
        'a policy. Terraform is not a configuration manager - for device CLI '
        'state, a NETCONF or Ansible layer usually sits under it.',
    commands:
        'terraform init\n'
        'terraform plan -out plan.tfplan\n'
        'terraform apply plan.tfplan\n'
        'terraform state list\n'
        'terraform import <addr> <id>',
    verify:
        'The plan output showing no unexpected destroys, and a post-apply '
        'plan that is empty (no drift).',
    pitfalls:
        'Local state, no lock, two pipelines. apply without reading the plan. '
        'Secrets in the state file in a public bucket. Rebuilding a resource '
        'that was renamed instead of moved.',
    aspects: ['terraform', 'plan', 'state', 'module'],
    facts: {
      'Core artifact': 'state file (remote, locked)',
      'Control': 'review the plan diff',
      'Not for': 'per-device CLI drift alone',
    },
  ),
  NetworkTech(
    id: 'ansible-network',
    name: 'Ansible for networks',
    aliases: [
      'ansible',
      'playbook',
      'ansible network',
      'napalm',
      'configuration management',
      'idempotent config',
    ],
    summary:
        'Ansible pushes declarative tasks over SSH or an API and is '
        'idempotent per task, which makes it the pragmatic choice for '
        'device configuration when a full model-driven stack is too much.',
    mechanism:
        'A playbook lists tasks against an inventory of devices. Network '
        'modules (ios_config, napalm, or vendor collections) either push CLI '
        'or speak NETCONF/RESTCONF. Idempotence is per task: ios_config only '
        'sends the lines that are missing, so a second run is a no-op - '
        'provided the module can read the state, which is why "check mode" '
        'and a diff are the safety features that matter.',
    whenToUse:
        'Brownfield estates where devices speak CLI, repeatable operational '
        'tasks (backups, compliance reads, VLAN rollouts), and as the '
        'execution layer under a source of truth.',
    tradeoffs:
        'CLI modules are text-matching, not model-validated, so a typo is '
        'discovered on the device. Large inventories are slow without forks '
        'and fact caching. It is not a source of truth - without one, the '
        'playbook is just a script.',
    commands:
        '- name: baseline ntp and logging\n'
        '  hosts: switches\n'
        '  gather_facts: false\n'
        '  tasks:\n'
        '    - name: ntp\n'
        '      cisco.ios.ios_config:\n'
        '        lines:\n'
        '          - ntp server 10.0.0.10\n'
        '        save_when: modified',
    verify:
        'Run with --check --diff first, then run twice: the second run must '
        'report changed=0, which is the idempotence proof.',
    pitfalls:
        'Running against all devices at once with no canary. Saving the '
        'config on every run, which churns the archive. Using a playbook as '
        'the source of truth and then wondering why the network drifted.',
    aspects: ['ansible', 'playbook', 'idempotent', 'inventory'],
    facts: {
      'Transport': 'SSH or API, agentless',
      'Idempotence': 'per task, needs state read',
      'Risk': 'CLI text match, not model validation',
    },
  ),
  NetworkTech(
    id: 'ipfix',
    name: 'IPFIX and flow telemetry',
    aliases: [
      'ipfix',
      'netflow v9',
      'flow telemetry',
      'flow collector',
      'flexible netflow',
      'flow export',
    ],
    summary:
        'IPFIX is the IETF flow-export standard: the device summarises '
        'traffic into flow records, ships templates that describe the fields, '
        'and the collector reconstructs conversations from them.',
    mechanism:
        'A flow is identified by a key (usually the 5-tuple plus ingress '
        'interface), and the cache holds counters per flow until it expires '
        'or is exported. Templates define the field layout and must be sent '
        'before or with the data records; a collector that missed the '
        'template shows unparsed data. IPFIX adds variable-length fields and '
        'structured data over NetFlow v9, and it runs over SCTP or UDP/TCP '
        '4739. Sampling (1 in N) is how high-rate interfaces keep the export '
        'volume sane, at the cost of accuracy.',
    whenToUse:
        'Traffic accounting, capacity planning, security analytics, and '
        'proving which conversation filled a link.',
    tradeoffs:
        'Sampling trades accuracy for volume, and short flows may never be '
        'sampled at all. Export is one-way UDP by default: records are lost '
        'silently when the path is busy. The collector is a second system '
        'that must scale with the network.',
    commands:
        'flow exporter EXP\n'
        ' destination 10.0.0.50\n'
        ' source Loopback0\n'
        ' transport udp 4739\n'
        'flow monitor MON\n'
        ' exporter EXP\n'
        ' cache timeout active 60\n'
        'interface g0/1\n'
        ' ip flow monitor MON input',
    verify:
        'show flow exporter statistics (records sent and errors), show flow '
        'monitor cache (flows actually measured), and the collector showing '
        'templates and decoded records.',
    pitfalls:
        'Enabling export but not the monitor on the interface, or only one '
        'direction. Cache timeouts longer than the investigation window. '
        'Forgetting that sampled flows undercount short conversations.',
    aspects: ['ipfix', 'flow', 'template', 'sampling'],
    facts: {
      'Transport': 'UDP/TCP/SCTP 4739 (NetFlow 2055)',
      'Key': '5-tuple plus interfaces',
      'Sampling': '1 in N trades accuracy for volume',
    },
  ),
  // --- Containers and cloud-native ---------------------------------------
  NetworkTech(
    id: 'kubernetes-networking',
    name: 'Kubernetes networking',
    aliases: [
      'kubernetes networking',
      'k8s networking',
      'cni',
      'container network interface',
      'pod network',
      'overlay network for containers',
    ],
    summary:
        'Kubernetes assumes every pod has a routable address and can reach '
        'every other pod without NAT; the CNI plugin is what makes that true, '
        'usually with an overlay or with BGP-advertised pod routes.',
    mechanism:
        'Each node runs a CNI plugin that allocates pod addresses from a '
        'per-node block and programs the dataplane: veth pairs into a bridge, '
        'policy routing, and eBPF or iptables rules. Pod-to-pod traffic either '
        'is routed natively (the pod CIDRs are advertised into the underlay '
        'with BGP) or is encapsulated (VXLAN, IPIP, Geneve) between nodes. '
        'Services add a virtual IP layer: kube-proxy programs iptables or IPVS '
        'to DNAT the ClusterIP to one ready endpoint, while an eBPF datapath '
        'does the same in the kernel. The underlay must carry the '
        'encapsulation MTU - a 1500-byte underlay gives roughly 1450 to pods, '
        'and nobody remembers to set it.',
    whenToUse:
        'Any cluster that must be reachable from outside, and every '
        'multi-node cluster - a single-node lab hides every CNI bug.',
    tradeoffs:
        'Overlays are portable but cost MTU and some throughput; native '
        'routing is faster but couples the cluster to the underlay and needs '
        'address space from the network team. Every choice moves complexity '
        'between the cluster and the network.',
    commands:
        'kubectl get nodes -o wide\n'
        'kubectl get pods -n kube-system -l k8s-app=calico-node\n'
        'kubectl get ippools\n'
        'kubectl describe node <node> | grep -A3 PodCIDR',
    verify:
        'A pod ping and TCP connect to a pod on a different node, the node '
        'showing the expected pod CIDR, and the encapsulation interface '
        'carrying traffic (ip -s link show vxlan.calico).',
    pitfalls:
        'An MTU that fits the underlay but not the overlay, so large '
        'requests hang. Overlapping pod CIDRs with the on-prem or VPC ranges, '
        'which breaks every route that has to reach the cluster. Assuming '
        'kube-proxy is doing the work when the CNI replaced it.',
    aspects: ['cni', 'pod cidr', 'kube-proxy', 'overlay'],
    facts: {
      'Model': 'every pod routable, no NAT between pods',
      'MTU cost': 'VXLAN ~50 bytes, IPIP ~20',
      'Service layer': 'kube-proxy iptables/IPVS or eBPF',
    },
  ),
  NetworkTech(
    id: 'cilium',
    name: 'Cilium and eBPF',
    aliases: [
      'cilium',
      'ebpf',
      'xdp',
      'hubble',
      'ebpf datapath',
      'kernel datapath',
    ],
    summary:
        'Cilium replaces iptables and often kube-proxy with eBPF programs '
        'attached in the kernel, so forwarding, load balancing and policy '
        'happen in one programmable datapath.',
    mechanism:
        'eBPF programs are loaded into kernel hook points (TC ingress and '
        'egress, XDP at the driver) and consult maps that Cilium fills from '
        'Kubernetes objects: endpoints, services, identities and policies. '
        'Because the identity is attached to the packet metadata rather than '
        'derived from an IP, policy is expressed as "label A may reach label '
        'B on port 443" and survives pod restarts. Hubble exports flow '
        'visibility from the same datapath, which is the observability that '
        'iptables never gave you.',
    whenToUse:
        'Large or fast-changing clusters where iptables rule counts are a '
        'real scaling problem, and anywhere the security model is '
        'identity-based rather than address-based.',
    tradeoffs:
        'It needs a recent kernel and a platform team comfortable debugging '
        'eBPF, and every CNI feature you enable is another thing that can '
        'break the dataplane. ClusterIP with eBPF bypasses kube-proxy, so the '
        'old troubleshooting habits do not apply.',
    commands:
        'cilium status\n'
        'cilium connectivity test\n'
        'cilium monitor --type drop\n'
        'kubectl get ciliumendpoints -A',
    verify:
        'cilium status showing the datapath mode, cilium connectivity test '
        'passing across nodes, and hubble observe showing the flow with its '
        'verdict.',
    pitfalls:
        'Mixing a CNI with a second overlay and wondering which one drops '
        'the packet. Old kernel without the required helpers. Debugging with '
        'tcpdump on the pod interface when the drop happened earlier in TC.',
    aspects: ['ebpf', 'cilium', 'datapath', 'hubble'],
    facts: {
      'Hooks': 'XDP, TC ingress/egress, socket',
      'Policy identity': 'labels, not addresses',
      'Visibility': 'Hubble flows',
    },
  ),
  NetworkTech(
    id: 'k8s-network-policy',
    name: 'Kubernetes NetworkPolicy',
    aliases: [
      'network policy',
      'networkpolicy',
      'k8s policy',
      'pod firewall',
      'namespace isolation',
    ],
    summary:
        'A NetworkPolicy is a namespaced allow-list for pods; the moment any '
        'policy selects a pod, everything not explicitly allowed to or from '
        'it is denied - but only if the CNI enforces it.',
    mechanism:
        'The policy selects pods by label and lists ingress and egress rules, '
        'each with peers (pod, namespace or CIDR selectors) and ports. '
        'Policies are additive: if two select the same pod, the union of '
        'their allows applies, and there is no deny rule. Enforcement is the '
        'CNI plugin\'s job - Calico, Cilium and Antrea implement it; a plugin '
        'that ignores NetworkPolicy objects will happily accept the YAML and '
        'drop nothing.',
    whenToUse:
        'Every multi-tenant cluster, and any namespace holding data that '
        'should not be reachable from the default namespace by default.',
    tradeoffs:
        'Default-deny is the right starting point but it breaks things '
        'loudly on day one, and DNS egress is the rule everyone forgets. '
        'Policies are per-namespace and do not compose across clusters '
        'without a mesh or a CNI-wide policy layer.',
    commands:
        'kubectl apply -f default-deny.yaml\n'
        'kubectl get networkpolicy -n app\n'
        'kubectl describe networkpolicy -n app allow-dns',
    verify:
        'A connection from an unselected namespace fails while the allowed '
        'one succeeds, and the CNI policy counters show the drop.',
    pitfalls:
        'Forgetting egress DNS to kube-dns, so every name lookup fails with '
        'a timeout that looks like a service problem. Assuming a policy '
        'exists because the YAML is in git. Writing a policy in a cluster '
        'whose CNI does not enforce it.',
    aspects: ['networkpolicy', 'default deny', 'egress dns'],
    facts: {
      'Semantics': 'additive allow-list, no deny rule',
      'Enforced by': 'the CNI plugin',
      'Classic miss': 'egress to kube-dns',
    },
  ),
  NetworkTech(
    id: 'service-mesh',
    name: 'Service mesh',
    aliases: [
      'service mesh',
      'istio',
      'linkerd',
      'sidecar',
      'envoy',
      'mtls between services',
      'ambient mesh',
    ],
    summary:
        'A service mesh moves service-to-service policy, identity and '
        'telemetry out of the application and into a sidecar proxy or a '
        'per-node datapath.',
    mechanism:
        'Each workload gets a proxy (or, in ambient mode, a per-node ztunnel) '
        'that terminates mTLS with a workload certificate, enforces L7 '
        'policy, retries, times out and records telemetry. A control plane '
        'distributes identity and configuration. Because the identity is the '
        'certificate, policy is "service A may call service B on /v1" rather '
        'than an IP rule, and traffic between services is encrypted in transit '
        'by default.',
    whenToUse:
        'Many services, multiple teams, and a requirement for mTLS, per-route '
        'policy or consistent telemetry that the application teams will not '
        'implement themselves.',
    tradeoffs:
        'A sidecar adds a hop, memory and a version to manage for every pod; '
        'ambient mode removes the per-pod cost but adds a node-level '
        'component. Debugging moves from the network team to the platform '
        'team, and that is an organisational change as much as a technical '
        'one.',
    commands:
        'istioctl analyze\n'
        'istioctl proxy-status\n'
        'kubectl get peerauthentication -A\n'
        'kubectl get authorizationpolicy -A',
    verify:
        'istioctl proxy-status showing every proxy synced, and a request '
        'between two services succeeding with mTLS confirmed by the mesh '
        'dashboard or the proxy config.',
    pitfalls:
        'Installing STRICT mTLS before every workload has a sidecar, which '
        'breaks plaintext callers. Policies that allow everything because the '
        'default was permissive. Adding a mesh to fix a problem a load '
        'balancer already solved.',
    aspects: ['istio', 'mtls', 'sidecar', 'authorizationpolicy'],
    facts: {
      'Identity': 'workload certificate (SPIFFE)',
      'Cost': 'one proxy hop per sidecar',
      'Control': 'L7 policy and telemetry',
    },
  ),

  // --- Cloud plumbing -----------------------------------------------------
  NetworkTech(
    id: 'direct-connect',
    name: 'Direct Connect and ExpressRoute',
    aliases: [
      'direct connect',
      'expressroute',
      'express route',
      'dedicated interconnect',
      'private circuit to cloud',
      'cloud interconnect',
    ],
    summary:
        'A private circuit from your site or colocation into a cloud region: '
        'predictable latency and no internet in the path, but also a '
        'physical dependency with a long lead time.',
    mechanism:
        'You order a circuit from a provider into a cloud location, the '
        'provider hands it to the cloud as a virtual interface (VLAN, BGP '
        'peering), and the cloud advertises VPC prefixes and learns yours '
        'over BGP. The cloud side is a gateway per region; the customer side '
        'is a router in a colocation or an exchange. Because it is BGP, the '
        'filters and the prefix limits matter exactly as they do on the '
        'internet, and the MTU is usually 1500 or 9000 depending on the '
        'provider.',
    whenToUse:
        'Steady, high-volume traffic between a data centre and a cloud '
        'region, or any latency-sensitive path where the internet is not '
        'acceptable.',
    tradeoffs:
        'Months of lead time, a monthly cost independent of usage, and a '
        'single physical path unless you buy diversity (which is a separate '
        'circuit, often from a different provider). Failover to a VPN is a '
        'design requirement, not an afterthought.',
    commands:
        'interface g0/0.100\n'
        ' encapsulation dot1Q 100\n'
        ' ip address 169.254.1.2 255.255.255.252\n'
        'router bgp 65001\n'
        ' neighbor 169.254.1.1 remote-as 64512\n'
        ' neighbor 169.254.1.1 maximum-prefix 200\n'
        ' neighbor 169.254.1.1 route-map CLOUD-IN in',
    verify:
        'The cloud console showing the virtual interface up, BGP Established '
        'with the expected prefix count, and a traceroute that stays on the '
        'private path.',
    pitfalls:
        'One circuit and no VPN backup, so a provider maintenance is an '
        'outage. Advertising a default route into the cloud VPC. MTU 9000 on '
        'one side and 1500 on the other, which breaks large flows.',
    aspects: ['direct connect', 'expressroute', 'vif', 'bgp peering'],
    facts: {
      'Lead time': 'weeks to months',
      'Failover': 'VPN over internet, designed in advance',
      'MTU': '1500 or 9000, must match end to end',
    },
  ),
  NetworkTech(
    id: 'nat-gateway',
    name: 'Cloud NAT gateway',
    aliases: [
      'nat gateway',
      'cloud nat',
      'egress gateway',
      'internet gateway',
      'ngw',
    ],
    summary:
        'A managed NAT gateway gives private subnets outbound internet '
        'without giving them inbound reachability, and it is the default '
        'egress path in every cloud VPC.',
    mechanism:
        'The subnet route table sends 0.0.0.0/0 to the NAT gateway in a '
        'public subnet; the gateway translates the source to its own elastic '
        'address and tracks the flow. Because it is stateful and managed, the '
        'return traffic is allowed automatically, but the gateway is zonal or '
        'regional by design and has a bandwidth and connection limit per '
        'address. Multiple addresses scale it; a single NAT gateway in one '
        'zone is a failure domain.',
    whenToUse:
        'Any private subnet that needs patching, package pulls, or API calls '
        'to the internet, which is most of them.',
    tradeoffs:
        'It costs per hour and per gigabyte, and it is a single point of '
        'failure if deployed in one zone. It also hides the source address '
        'from the destination, so the far side\'s logs show the gateway, not '
        'the instance.',
    commands:
        'aws ec2 create-nat-gateway --subnet-id <public> '
        '--allocation-id <eip>\n'
        'aws ec2 create-route --route-table-id <private> '
        '--destination-cidr-block 0.0.0.0/0 --nat-gateway-id <ngw>',
    verify:
        'The route table association, the NAT gateway state, and an outbound '
        'curl from a private instance that returns its public address as the '
        'gateway address.',
    pitfalls:
        'One NAT gateway for every AZ and then a zone outage takes the '
        'egress with it. Source-address-dependent logging that now points at '
        'the gateway. Assuming the NAT gateway is a firewall - it is not, '
        'and it does not inspect.',
    aspects: ['nat gateway', 'egress', 'elastic ip'],
    facts: {
      'Scope': 'zonal (AWS), regional (GCP)',
      'Scaling': 'more addresses, not a bigger gateway',
      'Cost': 'hourly plus per GB',
    },
  ),
  NetworkTech(
    id: 'hybrid-dns',
    name: 'Hybrid DNS',
    aliases: [
      'hybrid dns',
      'dns forwarding',
      'route 53 resolver',
      'private dns',
      'split dns',
      'conditional forwarder',
      'dns between on prem and cloud',
    ],
    summary:
        'Hybrid DNS is two authoritative domains that must see each other: '
        'on-prem forwarders for cloud zones, cloud resolver rules for on-prem '
        'zones, and one direction of truth for each name.',
    mechanism:
        'Each side remains authoritative for its own zone. The on-prem '
        'resolver forwards the cloud zone to the cloud inbound resolver, and '
        'the cloud resolver forwards the on-prem zone to the on-prem DNS '
        'servers (an outbound rule with a target). Resolution then works in '
        'both directions, and the search suffixes must be managed so a short '
        'name resolves to the local domain before the remote one. Latency and '
        'the resolver cache determine how quickly a change propagates.',
    whenToUse:
        'Any hybrid estate where users and servers on one side must resolve '
        'names on the other, which includes every VPN or Direct Connect '
        'deployment.',
    tradeoffs:
        'Two authorities mean two change processes, and a stale forwarder is '
        'a silent outage for one domain only. Split horizon (same name, '
        'different answer per side) is powerful and easy to get wrong.',
    commands:
        'ip name-server 10.0.0.53\n'
        'ip domain lookup\n'
        'ip dns forwarding\n'
        'ip dns server\n'
        'ip dns forwarding domain corp.example.com 10.0.0.53',
    verify:
        'nslookup with the FQDN from both sides, dig +trace from the '
        'resolver, and the cloud resolver rule showing the association.',
    pitfalls:
        'A forwarder loop between the two resolvers, which times out with no '
        'error. Forgetting the reverse zone, so traceroute and logs show '
        'names only one way. Assuming the VPC resolver is authoritative for '
        'the on-prem zone.',
    aspects: ['forwarder', 'split dns', 'resolver rule', 'search suffix'],
    facts: {
      'Direction': 'forward per zone, not per query',
      'Classic fault': 'forwarder loop',
      'Also needs': 'reverse zones',
    },
  ),
  NetworkTech(
    id: 'waf',
    name: 'Web application firewall',
    aliases: [
      'waf',
      'web application firewall',
      'owasp rules',
      'layer 7 firewall',
      'application firewall',
    ],
    summary:
        'A WAF inspects HTTP semantics - methods, headers, parameters, '
        'bodies - and blocks requests that match attack patterns, which a '
        'packet filter cannot see.',
    mechanism:
        'The WAF terminates or proxies the TLS session, parses the request '
        'and scores it against rule sets (OWASP core rules, or a managed '
        'vendor set), plus rate limits and reputation. It can run in '
        'detection or blocking mode, and most teams run detection first to '
        'tune false positives before turning on blocking. A CDN-fronted WAF '
        'adds a shared edge and a short TTL for rules.',
    whenToUse:
        'Any internet-facing HTTP service, especially one that cannot be '
        'patched quickly, and where the compliance regime expects layer 7 '
        'inspection.',
    tradeoffs:
        'It is a proxy: it adds latency, needs the TLS key or a '
        're-termination model, and the rule set produces false positives on '
        'legitimate uploads and APIs. It does not fix an application bug - it '
        'only filters the obvious exploitation of it.',
    commands:
        'aws wafv2 create-web-acl --name edge --scope REGIONAL '
        '--default-action Allow={}\n'
        'aws wafv2 associate-web-acl --web-acl-arn <arn> '
        '--resource-arn <alb>',
    verify:
        'A known-bad request blocked while normal traffic passes, the WAF '
        'logs showing the rule that matched, and a canary test after each '
        'rule change.',
    pitfalls:
        'Blocking mode on day one and breaking the customer login page. JSON '
        'or multipart bodies the parser does not inspect. A WAF in front of '
        'an origin that is still directly reachable.',
    aspects: ['waf', 'owasp', 'layer 7', 'rules'],
    facts: {
      'Inspects': 'method, headers, body, parameters',
      'Modes': 'detect, block',
      'Not': 'a fix for an application bug',
    },
  ),
  NetworkTech(
    id: 'nac',
    name: 'Network access control',
    aliases: [
      'nac',
      'network access control',
      '802.1x deployment',
      'byod onboarding',
      'device posture',
      'mab',
      'mac authentication bypass',
      'guest onboarding',
    ],
    summary:
        'NAC decides what a device is allowed to do when it connects - '
        'before it gets an address - using 802.1X identity, MAB, or a guest '
        'portal, and a policy server that returns a VLAN or an ACL.',
    mechanism:
        'The switch is the authenticator, the endpoint is the supplicant, '
        'and RADIUS is the transport to the policy server. On 802.1X the '
        'supplicant proves its identity with EAP (EAP-TLS with a certificate '
        'is the strong form); MAB falls back to the MAC address for devices '
        'that cannot do 802.1X, which is spoofable and should be limited to '
        'known OUIs. The server returns an authorization result: a VLAN, a '
        'dACL, or a redirect for onboarding. Posture checks add a phase after '
        'authentication.',
    whenToUse:
        'Every wired and wireless edge in an organisation with contractors, '
        'BYOD or compliance requirements, and any site where an unmanaged '
        'device on the LAN is a real risk.',
    tradeoffs:
        'It is an operational project, not a config: certificates, '
        'onboarding, a supplicant that works on every OS, and a fallback for '
        'devices that fail. Done badly it produces outages at every '
        'connection, which is why pilot VLANs and monitor mode come first.',
    commands:
        'aaa new-model\n'
        'aaa authentication dot1x default group radius\n'
        'aaa authorization network default group radius\n'
        'interface g1/0/1\n'
        ' authentication port-control auto\n'
        ' dot1x pae authenticator\n'
        ' mab',
    verify:
        'show authentication sessions (method, status, assigned VLAN), show '
        'dot1x interface, and the RADIUS server logs showing the '
        'authorization result.',
    pitfalls:
        'No critical VLAN, so a RADIUS outage locks every port. MAB on every '
        'port with no MAB policy, which is just an open network with extra '
        'steps. Certificate expiry, which becomes a site-wide outage.',
    aspects: ['nac', 'mab', 'posture', 'onboarding'],
    facts: {
      'Transport': 'RADIUS (1812/1813)',
      'Strong form': 'EAP-TLS certificates',
      'Fallback': 'MAB, spoofable, limit by OUI',
    },
  ),
  // --- Identity, certificates and zero trust ------------------------------
  NetworkTech(
    id: 'pki',
    name: 'PKI for networks',
    aliases: [
      'pki',
      'public key infrastructure',
      'certificate authority',
      'csr',
      'certificate renewal',
      'est',
      'sca',
    ],
    summary:
        'A network PKI is a trust anchor, a hierarchy of CAs, and a renewal '
        'process; the certificates are easy, the lifecycle is what breaks.',
    mechanism:
        'A root CA signs an intermediate, the intermediate signs device and '
        'service certificates, and every participant trusts the root. The '
        'certificate binds a name to a public key, so the device identity in '
        'an IPsec, 802.1X or web UI session is the name in the certificate - '
        'which is why a wrong SAN breaks a working tunnel. EST or SCEP '
        'automates enrolment, and OCSP or CRL handles revocation. Lifetime, '
        'renewal lead time and clock accuracy are the three things that '
        'decide whether renewal is boring or an outage.',
    whenToUse:
        'Anywhere identity must be stronger than a pre-shared key: device '
        'VPNs, 802.1X, management access, and service-to-service TLS.',
    tradeoffs:
        'A CA is a single point of trust with an operational burden: protect '
        'the root offline, publish CRLs, monitor expiry. Self-signed '
        'certificates avoid the process and create per-device exceptions that '
        'never get cleaned up.',
    commands:
        'crypto pki trustpoint CORP\n'
        ' enrollment terminal\n'
        ' subject-name CN=r1.corp.example.com\n'
        ' revocation-check crl\n'
        'crypto pki authenticate CORP\n'
        'crypto pki enroll CORP',
    verify:
        'show crypto pki certificates (the chain and the expiry), show '
        'crypto pki trustpoints (the trustpoint state), and a test connection '
        'that fails when the certificate is revoked.',
    pitfalls:
        'Renewing at the last minute with no canary. A SAN that does not '
        'match the address peers use. A clock that is off by minutes, which '
        'makes a valid certificate look expired.',
    aspects: ['pki', 'crl', 'ocsp', 'san', 'renewal'],
    facts: {
      'Chain': 'root offline, intermediate online',
      'Revocation': 'CRL or OCSP',
      'Silent killer': 'clock skew',
    },
  ),
  NetworkTech(
    id: 'ztna',
    name: 'ZTNA',
    aliases: [
      'ztna',
      'zero trust network access',
      'zero trust access',
      'beyondcorp',
      'app connector',
      'zero trust proxy',
    ],
    summary:
        'ZTNA replaces "on the network means trusted" with a per-application '
        'broker: identity and device posture are checked per request, and the '
        'user never gets a network position.',
    mechanism:
        'A client or a browser authenticates to a broker, which evaluates '
        'identity, device posture and policy, then steers the connection to '
        'an app connector inside the private network. The connector makes an '
        'outbound connection to the broker, so no inbound port is opened and '
        'the application is never internet-reachable. Authorization is '
        'per application and per request, not per subnet.',
    whenToUse:
        'Remote and contractor access to internal apps, and as the '
        'replacement for a VPN concentrator that grants a whole subnet.',
    tradeoffs:
        'Application-by-application onboarding is real work, and the broker '
        'is a dependency that must be highly available. Legacy protocols that '
        'need raw IP access fit badly; UDP-heavy and non-HTTP services are '
        'the usual exceptions.',
    commands:
        'The configuration lives in the broker: an application segment, a '
        'connector group, and a policy binding identity and posture to the '
        'segment.',
    verify:
        'A user reaching the allowed app and being denied another app in the '
        'same network, with the broker log showing the policy decision.',
    pitfalls:
        'Publishing a whole subnet as one application, which recreates the '
        'VPN. No posture check, so an unpatched laptop has the same access as '
        'a managed one. Forgetting the break-glass path for the app team.',
    aspects: ['ztna', 'broker', 'connector', 'posture'],
    facts: {
      'Unit of access': 'application, not network',
      'Connector': 'outbound-only to the broker',
      'Breaks': 'raw IP and non-HTTP protocols',
    },
  ),

  // --- Physical and wireless ---------------------------------------------
  NetworkTech(
    id: 'dac',
    name: 'DAC, AOC and transceivers',
    aliases: [
      'dac',
      'direct attach cable',
      'aoc',
      'active optical cable',
      'transceiver',
      'sfp',
      'qsfp',
      'optic',
      'twinax',
    ],
    summary:
        'A DAC is copper twinax for short runs inside a rack; an AOC is a '
        'fibre cable with the optics fixed on both ends; a transceiver plus '
        'fibre is the flexible, expensive option for anything longer.',
    mechanism:
        'A passive DAC carries the electrical signal with no retimer, so it '
        'is cheap, low-power, and limited to a few metres at 25G and less at '
        '100G. An AOC converts to light inside the connector and is lighter '
        'and longer than a DAC with lower power than separate optics. A '
        'transceiver (SFP28, QSFP28, QSFP-DD, OSFP) is a hot-pluggable module '
        'that must match the port speed, the fibre type, the reach and the '
        'vendor coding; a mismatch shows as a link that never comes up or a '
        'module the switch refuses to enable.',
    whenToUse:
        'DAC inside a rack for server and leaf-spine links, AOC for a few '
        'tens of metres, optics for anything over 100 m or between buildings.',
    tradeoffs:
        'DAC is cheapest and least flexible: a fixed length and a stiff '
        'cable that stresses the port. Optics cost more, burn more power, and '
        'add a component that can fail or be coded wrongly. Vendor lock-in '
        'via transceiver coding is a commercial problem disguised as a '
        'technical one.',
    commands:
        'show interfaces transceiver detail\n'
        'show interfaces transceiver eeprom\n'
        'show interfaces <intf> capabilities',
    verify:
        'The transceiver is recognised, the receive power is inside the '
        'budget for that reach, and the link comes up at the expected speed '
        'and FEC setting.',
    pitfalls:
        'A 10G optic in a port configured for 25G. Wrong fibre core or '
        'connector (single-mode on a multimode port). FEC mismatch on 100G, '
        'where one side is on and one is off and the link never passes '
        'traffic.',
    aspects: ['dac', 'aoc', 'sfp', 'fec', 'reach'],
    facts: {
      'DAC': 'metres, passive, lowest cost',
      'AOC': 'tens of metres, fixed optics',
      'Optics': 'longest reach, highest cost and power',
    },
  ),
  NetworkTech(
    id: 'cwdm',
    name: 'CWDM and DWDM',
    aliases: [
      'cwdm',
      'dwdm',
      'wdm',
      'coarse wavelength',
      'dense wavelength',
      'muxponder',
      'dark fiber',
      'wavelength division',
    ],
    summary:
        'WDM puts several independent links on one fibre by giving each a '
        'different colour of light; CWDM is the cheap, wide-spaced version, '
        'DWDM the dense, long-haul one.',
    mechanism:
        'A multiplexer combines wavelengths onto one strand and a demux '
        'splits them at the far end, so 8 CWDM channels or 40+ DWDM channels '
        'share the fibre without interacting. CWDM channels are 20 nm apart '
        'over 1270-1610 nm and need no amplification; DWDM channels are 0.8 '
        'nm apart on the C-band and rely on EDFAs for distance. Each channel '
        'carries a normal client signal - 10G, 25G, 100G - so WDM is a '
        'physical-layer multiplier, not a protocol.',
    whenToUse:
        'A fibre shortage between sites or buildings, a long span that needs '
        'amplification, or capacity growth where trenching a new fibre is '
        'impossible.',
    tradeoffs:
        'CWDM is passive and cheap but limited in channel count and '
        'distance; DWDM scales much further at several times the cost and '
        'with an optical budget that must be engineered (loss, dispersion, '
        'amplifier placement). Both make the fibre a shared dependency: a '
        'bend or a dirty connector takes every channel down at once.',
    commands:
        'show interfaces transceiver detail\n'
        'show interfaces <intf> | include error|CRC|input errors',
    verify:
        'Per-channel optical power at both ends inside the budget, zero '
        'increasing CRC errors, and a light-level test after every patch '
        'change.',
    pitfalls:
        'Dirty connectors, which are the most common WDM outage. Mixing '
        'CWDM and DWDM optics on one mux. No spare channel or spare optic, so '
        'a single failure has no quick workaround.',
    aspects: ['cwdm', 'dwdm', 'mux', 'optical budget'],
    facts: {
      'CWDM': '20 nm spacing, passive, short/medium reach',
      'DWDM': '0.8 nm spacing, amplifiers, long haul',
      'Shared risk': 'one fibre, all channels',
    },
  ),
  NetworkTech(
    id: 'site-survey',
    name: 'Wireless site survey',
    aliases: [
      'site survey',
      'wireless survey',
      'rf survey',
      'predictive survey',
      'ap placement',
      'coverage survey',
      'spectrum analysis',
    ],
    summary:
        'A site survey is measurement, not a floor plan: it sets the AP '
        'count from the client density and the RF environment, then proves '
        'coverage and roaming with a real survey after install.',
    mechanism:
        'Start with a predictive survey from the floor plan to estimate AP '
        'count and placement, then a passive survey to see the noise floor '
        'and the existing interference, then an active survey walking the '
        'floor with the real client and the real applications. Coverage '
        'targets are secondary to capacity: -67 dBm for voice and data, SNR '
        '25 dB, and a cell overlap of 15-20 percent at the edges so roaming '
        'has a target. Channel reuse and transmit power are set from the '
        'measured cells, not from the defaults.',
    whenToUse:
        'Every new building, every warehouse or high-density venue, and '
        'before any design that claims a coverage number.',
    tradeoffs:
        'A survey is days of work and a report that goes stale the moment '
        'the layout changes; skipping it produces an install that is tuned by '
        'complaint. High-density venues (stadiums, auditoriums) need a '
        'different design entirely: more APs at lower power.',
    commands:
        'show ap summary\n'
        'show ap auto-rf 802.11b\n'
        'show wireless client summary detail',
    verify:
        'The post-install survey meets the coverage and SNR targets on both '
        'bands, and a roaming test walks the floor without a dropped call.',
    pitfalls:
        'Designing for coverage and ignoring capacity, so 300 people in a '
        'room share one AP. Surveying with a laptop when the client is a '
        'scanner or a phone. Leaving auto-RF to retune power every night in a '
        'venue that needs stable cells.',
    aspects: ['site survey', 'coverage', 'capacity', 'snr'],
    facts: {
      'Coverage target': '-67 dBm, SNR 25 dB',
      'Overlap': '15-20 percent at cell edge',
      'Capacity first': 'clients per AP, not area',
    },
  ),
  NetworkTech(
    id: 'wireless-mesh',
    name: 'Wireless mesh',
    aliases: [
      'wireless mesh',
      'mesh network',
      'mesh backhaul',
      'wireless backhaul',
      'point to point wireless',
      'bridge link',
    ],
    summary:
        'A mesh replaces the cable to an AP with a radio backhaul, which is '
        'the right answer when trenching is impossible and a poor one when '
        'capacity matters.',
    mechanism:
        'Each mesh AP has a backhaul radio (or shares the client radio) and '
        'forms a tree toward the root AP, which is wired. The backhaul hops '
        'halve the throughput each time in a shared-radio design and add '
        'latency, and the mesh must pick and re-form paths as links fade. '
        'Dedicated-backhaul products avoid the halving at the cost of a '
        'second radio and a second channel.',
    whenToUse:
        'Outdoor coverage, warehouses with no cable path, temporary sites, '
        'and a link to a building across a car park where fibre is not '
        'feasible.',
    tradeoffs:
        'Latency and jitter make it unsuitable for voice and real-time '
        'control after one or two hops. Throughput drops per hop, and the '
        'shared medium means one bad link degrades the tree. It is also a '
        'security surface: the backhaul must be encrypted.',
    commands:
        'show mesh neighbor\n'
        'show mesh path\n'
        'show ap summary | include Mesh',
    verify:
        'The backhaul link RSSI and SNR, the hop count to the root, and a '
        'throughput test from a client at the far end.',
    pitfalls:
        'Chaining five hops and expecting voice to work. No dedicated '
        'backhaul radio, so clients and backhaul fight for airtime. A tree '
        'with one root and no alternate path.',
    aspects: ['mesh', 'backhaul', 'hop'],
    facts: {
      'Throughput': 'roughly halves per shared-radio hop',
      'Voice': 'not beyond one hop',
      'Root': 'the only wired AP',
    },
  ),
  NetworkTech(
    id: 'roce',
    name: 'RoCE and lossless Ethernet',
    aliases: [
      'roce',
      'rdma',
      'lossless ethernet',
      'dcb',
      'pfc',
      'ecn',
      'priority flow control',
      'storage network',
    ],
    summary:
        'RoCE runs RDMA over Ethernet and needs a lossless path: PFC to stop '
        'dropping rather than retransmit, ECN to slow senders early, and a '
        'network designed so a pause storm cannot deadlock the fabric.',
    mechanism:
        'RDMA writes directly into remote memory, bypassing the kernel, '
        'which is why it is fast and why it cannot tolerate loss. Priority '
        'Flow Control sends a PAUSE frame per class, so a congested port '
        'stalls its neighbour instead of dropping; ECN marks packets before '
        'the queue is full and the sender backs off. The design needs a '
        'dedicated lossless class, a consistent MTU, and a topology that '
        'avoids PFC deadlocks (a cycle of paused ports is a real failure '
        'mode).',
    whenToUse:
        'Storage and AI clusters - NVMe-oF, distributed file systems, GPU '
        'training - where the CPU bypass is the point and latency is measured '
        'in microseconds.',
    tradeoffs:
        'Lossless is fragile: a PFC storm can spread congestion across the '
        'fabric, and a misconfigured class can pause traffic that was never '
        'meant to be lossless. It is a specialist fabric, not a general LAN.',
    commands:
        'priority-flow-control mode on\n'
        'priority-flow-control priority 3\n'
        'dcb pfc tlv\n'
        'interface ethernet 1/1\n'
        ' mtu 9216',
    verify:
        'show priority-flow-control (per-port pause counters), show '
        'interface counters (no discards in the lossless class), and the '
        'application latency at the 99th percentile.',
    pitfalls:
        'Enabling PFC on all classes, which turns a single slow receiver '
        'into a fabric-wide pause. A different MTU on one leaf. Treating '
        'RoCE like TCP/IP and adding routers along the path.',
    aspects: ['roce', 'pfc', 'ecn', 'rdma'],
    facts: {
      'Lossless': 'PFC pause, ECN marking',
      'MTU': 'usually 9000 end to end',
      'Deadlock': 'a PFC pause cycle stops the fabric',
    },
  ),

  // --- Practice: how a senior engineer works a problem --------------------
  NetworkTech(
    id: 'troubleshooting-method',
    name: 'Structured troubleshooting',
    aliases: [
      'troubleshooting methodology',
      'structured troubleshooting',
      'where do i start',
      'how do i approach',
      'isolate the fault',
      'bottom up troubleshooting',
      'top down troubleshooting',
      'intermittent connectivity',
      'intermittent problems',
      'intermittent',
      'prove the network',
      'network is not the problem',
      'not the network',
    ],
    summary:
        'Work from the layer you can prove, change one variable at a time, '
        'and keep a written record of what each check eliminated.',
    mechanism:
        'Define the fault in one sentence (who, what, when, where, how '
        'much), then choose a direction: bottom-up from the physical layer, '
        'top-down from the application, or divide-and-conquer from the middle '
        '(ping a known-good point, then bisect the path). Every check must '
        'have a predicted result before you run it; if the result does not '
        'change your hypothesis, it was not a diagnostic. Compare a working '
        'case with the broken one - the diff is the answer more often than '
        'any single command.',
    whenToUse:
        'Every incident, and especially the ones where the first theory is '
        'already wrong.',
    tradeoffs:
        'Slow and deliberate feels wrong during an outage, but it is faster '
        'than three guesses applied at once. The discipline costs a few '
        'minutes up front and saves the rollback.',
    commands:
        'show interface <intf> | include error|duplex|rate\n'
        'show ip route <prefix>\n'
        'ping <target> repeat 20 size 1400 df-bit\n'
        'traceroute <target>',
    verify:
        'The fault is reproduced on demand and then no longer reproduces '
        'after the change, and the same check is run before and after.',
    pitfalls:
        'Changing two things at once, which makes the next fault '
        'unexplainable. Trusting a single ping. Fixing the symptom (a reload) '
        'without the cause, so it returns.',
    aspects: ['method', 'isolate', 'bisect', 'hypothesis'],
    facts: {
      'Rule': 'one change, one verification',
      'Best tool': 'compare working vs broken',
      'Record': 'what each check eliminated',
    },
  ),
  NetworkTech(
    id: 'incident-response',
    name: 'Incident response for networks',
    aliases: [
      'incident response',
      'outage process',
      'major incident',
      'war room',
      'restore first',
      'postmortem',
      'post mortem',
      'blameless review',
    ],
    summary:
        'During an outage the job is to restore service with the smallest '
        'safe change and keep the evidence; the root cause comes after, in a '
        'review that changes something.',
    mechanism:
        'Declare the incident and give it one commander who is not also '
        'debugging. Separate the restore path (rollback, failover, bypass) '
        'from the diagnosis, so restoring does not destroy the evidence. '
        'Timebox the diagnosis: if the fix is not clear in the timebox, '
        'restore and investigate on a copy. Then run a blameless review that '
        'ends in specific, owned, dated actions - a review with no action is '
        'a meeting.',
    whenToUse:
        'Any outage that touches customers or a critical service, and any '
        'change that could have.',
    tradeoffs:
        'Process during an outage can feel like overhead; without it, five '
        'engineers change five things and nobody knows which one fixed it. '
        'Restore-first sometimes means the cause is never fully understood, '
        'which is why the review and the evidence capture matter.',
    commands:
        'show logging | include <timestamp>\n'
        'show archive config differences\n'
        'show interfaces | include down|error\n'
        'show processes cpu sorted | include 1 minute',
    verify:
        'Service restored and monitored for a full interval, the timeline '
        'written from logs rather than memory, and every action item has an '
        'owner.',
    pitfalls:
        'No rollback plan, so the fix becomes another change. Restoring '
        'without capturing the state first. A postmortem that blames a person '
        'instead of a process, which guarantees the same incident again.',
    aspects: ['incident', 'rollback', 'postmortem', 'timeline'],
    facts: {
      'First': 'restore, with the smallest safe change',
      'Keep': 'evidence before you change anything',
      'Ends with': 'owned, dated actions',
    },
  ),
  NetworkTech(
    id: 'sla-metrics',
    name: 'SLAs and network metrics',
    aliases: [
      'sla',
      'service level',
      'slo',
      'availability target',
      'latency budget',
      'mttr',
      'error budget',
    ],
    summary:
        'An SLA is a measurement contract: what is measured, over what '
        'window, from where, and what the excluded maintenance is - everything '
        'else is a wish.',
    mechanism:
        'Define the service, the indicator (availability, latency p95, loss), '
        'the measurement point (probe, synthetic transaction, device '
        'telemetry), and the window (monthly, rolling 30 days). Availability '
        'of 99.9 percent monthly is about 43 minutes of downtime; 99.99 is '
        'about 4.3 minutes, which rules out manual failover. An error budget '
        'turns the target into a decision rule: when the budget is spent, '
        'changes slow down.',
    whenToUse:
        'Any service handed to users or to another team, and any network '
        'whose failure has a contractual or financial consequence.',
    tradeoffs:
        'Measuring from inside the network flatters the number; measuring '
        'from the user is honest and harder. Aggressive targets cost money '
        'and design complexity, and an SLA nobody reports against is '
        'decoration.',
    commands:
        'show ip sla statistics\n'
        'show ip sla configuration\n'
        'ip sla 1\n'
        ' icmp-echo 203.0.113.1 source-interface Loopback0\n'
        ' frequency 60',
    verify:
        'The reported number matches an independent measurement, the '
        'exclusions are listed, and the monthly report is generated from data '
        'rather than from memory.',
    pitfalls:
        'An SLA measured only on the device CPU. Counting planned maintenance '
        'as availability. A 99.99 target on a design with a single '
        'supervisor.',
    aspects: ['sla', 'slo', 'availability', 'mttr'],
    facts: {
      '99.9%': '~43 min/month',
      '99.99%': '~4.3 min/month',
      'Measure': 'from the user, not the core',
    },
  ),
  NetworkTech(
    id: 'design-review',
    name: 'Design review',
    aliases: [
      'design review',
      'review my design',
      'is my design good',
      'design checklist',
      'architecture review',
      'peer review',
    ],
    summary:
        'A design review asks the questions the design does not answer: what '
        'fails, what happens next, how it is operated, and how it is undone.',
    mechanism:
        'Walk the failure domains first (a link, a device, a site, a '
        'provider, a control plane), and for each one state the impact, the '
        'detection and the recovery time. Then the operational questions: who '
        'pages, what is the runbook, how is it monitored, how is it changed, '
        'how is it backed up and restored. Then the numbers: capacity and '
        'growth, convergence, address plan, MTU, and the licensing or support '
        'that the design silently assumes.',
    whenToUse:
        'Before building anything that will be hard to change: a campus '
        'core, a WAN, a data centre fabric, a cloud landing zone.',
    tradeoffs:
        'A review slows the project and surfaces problems that are expensive '
        'to fix - which is the point, because they are more expensive later. '
        'A review that only checks the diagram is theatre.',
    commands:
        '(No CLI. The output of the review is a document with failure '
        'domains, runbooks and numbers.)',
    verify:
        'Every failure domain has a stated impact and recovery, every number '
        'has a source, and the design names what it does not cover.',
    pitfalls:
        'Reviewing the diagram instead of the failure modes. No owner for the '
        'runbook. A design that assumes a skill the team does not have.',
    aspects: ['review', 'failure domain', 'runbook', 'checklist'],
    facts: {
      'First question': 'what fails, and what happens next',
      'Second': 'who operates it at 2 a.m.',
      'Third': 'the numbers and their source',
    },
  ),
  // --- Second wave: the questions operators actually ask -------------------
  NetworkTech(
    id: 'serverless',
    name: 'Serverless networking',
    aliases: [
      'serverless',
      'lambda',
      'lambda function',
      'cloud function',
      'azure function',
      'faas',
      'function as a service',
    ],
    summary:
        'A serverless function runs inside a managed network namespace you do '
        'not own, so connectivity is decided by the VPC attachment, the '
        'subnets, the security groups and the route tables you gave it.',
    mechanism:
        'A function configured for VPC access gets an elastic network '
        'interface in one of your subnets, and from then on it is a host on '
        'that subnet: it can reach anything the subnet can route to and '
        'nothing it cannot. Without VPC attachment it runs in a managed '
        'network with internet access but no path to your private space. '
        'Concurrency creates more interfaces, which is why an address-exhausted '
        'subnet breaks a function under load rather than at deploy time.',
    whenToUse:
        'Event-driven glue - image resizing, queue consumers, API handlers - '
        'where the scaling and the patching are the problem you want to give '
        'away.',
    tradeoffs:
        'The network is invisible: no packet capture, no routing table you '
        'control, and a cold start that has its own latency budget. VPC '
        'attachment adds an interface per concurrent execution, so subnet '
        'maths and security-group rules become the scaling limit.',
    commands:
        'aws lambda update-function-configuration '
        '--function-name <fn> --vpc-config '
        'SubnetIds=<subnet-a>,<subnet-b>,SecurityGroupIds=<sg>\n'
        'aws ec2 describe-network-interfaces '
        '--filters Name=description,Values="AWS Lambda VPC ENI*"',
    verify:
        'The function logs the egress address it sees, the security group '
        'and route table allow it, and a private target is reachable by name '
        'only through the resolver that subnet uses.',
    pitfalls:
        'Attaching the function to a private-only subnet with no NAT gateway, '
        'so every outbound call times out. A /28 subnet sized for a few hosts '
        'and then concurrency scales to 50 interfaces. Forgetting the '
        'function now needs the private DNS that only the VPC has.',
    aspects: ['lambda', 'function', 'cold start', 'eni'],
    facts: {
      'VPC-linked': 'one ENI per concurrent execution',
      'No VPC': 'internet only, no private reach',
      'Debug': 'log the egress address, not the console',
    },
  ),
  NetworkTech(
    id: 'fast-failover',
    name: 'Sub-second failover',
    aliases: [
      'sub second failover',
      'sub-second failover',
      'fast failover',
      'subsecond convergence',
      'fast reroute',
      'ti-lfa',
      'bfd failover',
      'carrier grade convergence',
    ],
    summary:
        'Sub-second failover is three things at once: detection under a '
        'second (BFD), a pre-computed repair path, and a forwarding table that '
        'is ready when the failure happens.',
    mechanism:
        'BFD sends small packets every 50-300 ms with a 3x multiplier, so a '
        'link failure is detected in 150-900 ms instead of waiting for a '
        'routing protocol timer. TI-LFA or a pre-installed backup path is '
        'already in the FIB, so repair is a local rewrite rather than a full '
        'SPF run. The control plane then converges while traffic already '
        'flows on the repair. Without all three, you get detection without '
        'repair, or a repair with no route installed.',
    whenToUse:
        'Voice and video, financial and industrial traffic, and any SLA that '
        'promises less than a second of interruption.',
    tradeoffs:
        'BFD at high rates costs CPU and can flap on a marginal link, which '
        'is why it needs the same damping discipline as a routing protocol. '
        'TI-LFA needs segment routing or a comparable pre-computation '
        'mechanism, and the design gets harder to read for everyone who '
        'inherits it.',
    commands:
        'interface g0/1\n'
        ' bfd interval 100 min_rx 100 multiplier 3\n'
        'router ospf 1\n'
        ' bfd all-interfaces\n'
        'ip route 0.0.0.0 0.0.0.0 203.0.113.1 track 1',
    verify:
        'show bfd neighbors (state Up and the negotiated timers), a controlled '
        'link failure with a packet-loss measurement, and show ip route proving '
        'the backup is pre-installed.',
    pitfalls:
        'BFD timers faster than the link can carry, so it flaps on its own '
        'congestion. Track objects that never fail. Testing failover by '
        'shutting an interface instead of by denying a real path.',
    aspects: ['bfd', 'ti-lfa', 'convergence', 'repair'],
    facts: {
      'Detect': 'BFD 300 ms x 3 typical',
      'Repair': 'pre-installed backup (TI-LFA)',
      'Prove it': 'controlled failure plus loss measurement',
    },
  ),
  NetworkTech(
    id: 'vpc-peering',
    name: 'Connecting two VPCs',
    aliases: [
      'vpc peering',
      'peer two vpcs',
      'connect two vpcs',
      'vnet peering',
      'connect two vnets',
      'cross vpc traffic',
    ],
    summary:
        'VPC peering joins two VPCs as if they were one routing domain over '
        'private addresses; a transit gateway or hub-and-spoke design is what '
        'you need once there are more than a handful of them.',
    mechanism:
        'A peering connection is non-transitive: A peered to B and B to C '
        'does not let A reach C, because there is no route through B. Both '
        'sides must also add a route for the other side prefix, and security '
        'groups or NSGs must allow the flow - the peering alone changes no '
        'policy. Overlapping CIDRs cannot be peered at all, which is why the '
        'address plan has to happen before the cloud does.',
    whenToUse:
        'Two or three VPCs that need full reach: shared services, a '
        'production-to-staging link, or an acquisition.',
    tradeoffs:
        'It is free or cheap and has no bandwidth bottleneck, but the mesh '
        'grows as n(n-1)/2 connections and every one needs routes and rules. '
        'Overlapping ranges are fatal and unfixable without re-addressing.',
    commands:
        'aws ec2 create-vpc-peering-connection --vpc-id <a> --peer-vpc-id <b>\n'
        'aws ec2 create-route --route-table-id <a-rt> '
        '--destination-cidr-block <b-cidr> --vpc-peering-connection-id <pcx>\n'
        'aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id <pcx>',
    verify:
        'The peering status is active, both route tables carry the peer '
        'prefix, and a flow between instances succeeds with the security '
        'group logs showing the allow.',
    pitfalls:
        'Assuming peering is transitive and then wondering why the third VPC '
        'is unreachable. Forgetting the return route on one side only. '
        'Peering with an overlapping VPC and discovering it at cutover.',
    aspects: ['peering', 'transitive', 'overlap'],
    facts: {
      'Transitive': 'no, each pair needs its own connection',
      'Route': 'both sides need a route and a rule',
      'Fatal': 'overlapping CIDRs',
    },
  ),
  NetworkTech(
    id: 'guest-network',
    name: 'Guest network isolation',
    aliases: [
      'guest network',
      'guest wifi',
      'guest vlan',
      'guest isolation',
      'isolate guests',
      'stop guests reaching the lan',
      'visitor network',
    ],
    summary:
        'A guest network is a separate broadcast domain with its own DHCP, '
        'its own egress and a deny to everything internal - client isolation '
        'inside the guest VLAN is the part people forget.',
    mechanism:
        'Put guest SSIDs on a dedicated VLAN or a separate anchor, give them '
        'a captive portal and a NAT to the internet, and drop every packet '
        'from that VLAN to RFC 1918 space and to the management VLAN. Enable '
        'peer-to-peer blocking (or AP isolation) so guests cannot scan each '
        'other. The default gateway for the guest VLAN is the only internal '
        'address they can reach, and it should do nothing but route out.',
    whenToUse:
        'Any office, retail floor or warehouse where visitors, contractors or '
        'personal devices need connectivity.',
    tradeoffs:
        'Isolation costs support: printers, casting and IoT on the guest '
        'network stop working, and the portal adds a support call per new '
        'user. A guest network that is an open SSID bridged into the corporate '
        'VLAN is worse than no guest network.',
    commands:
        'vlan 900\n'
        ' name GUEST\n'
        'interface g1/0/24\n'
        ' switchport access vlan 900\n'
        ' switchport protected\n'
        'ip access-list extended GUEST-IN\n'
        ' deny ip any 10.0.0.0 0.255.255.255\n'
        ' deny ip any 172.16.0.0 0.15.255.255\n'
        ' deny ip any 192.168.0.0 0.0.255.255\n'
        ' permit ip any any',
    verify:
        'From a guest client: a public IP works, a private address times out, '
        'and another guest client is unreachable. Then confirm DNS and DHCP '
        'still work through the portal.',
    pitfalls:
        'Blocking RFC 1918 but leaving the management VLAN reachable through a '
        'second interface. No isolation between guests. Portal and DNS on the '
        'same VLAN, so a guest can poison it.',
    aspects: ['guest', 'isolation', 'portal'],
    facts: {
      'Must deny': 'all internal RFC 1918 and management',
      'Often missed': 'guest-to-guest isolation',
      'Egress': 'NAT to internet only',
    },
  ),
  NetworkTech(
    id: 'mac-spoofing',
    name: 'MAC spoofing defence',
    aliases: [
      'mac spoofing',
      'mac spoof',
      'spoofed mac',
      'mac address spoofing',
      'mac flooding',
      'cam table overflow',
    ],
    summary:
        'A MAC address is not an identity: anyone can set it in software, so '
        'defence is port security limits, DHCP snooping and DAI on the access '
        'edge, plus 802.1X where the device must prove itself.',
    mechanism:
        'Port security limits how many MACs a port may learn and can shut the '
        'port on violation, which stops both spoofing and CAM table flooding. '
        'DHCP snooping records the real binding of IP to MAC to port, and DAI '
        'validates every ARP against that binding, so a forged ARP reply is '
        'dropped. IP Source Guard goes further and drops any IP that does not '
        'match the binding. None of it identifies the person - only 802.1X '
        'with certificates does that.',
    whenToUse:
        'Every access port in a shared or semi-public space, and anywhere a '
        'rogue device could impersonate a gateway or a server.',
    tradeoffs:
        'All of it is per-port state that must be maintained: a move or a '
        'replacement means clearing a binding, and a misconfigured trunk can '
        'err-disable a whole uplink. It stops casual spoofing, not a '
        'determined insider.',
    commands:
        'interface g1/0/1\n'
        ' switchport port-security\n'
        ' switchport port-security maximum 2\n'
        ' switchport port-security violation restrict\n'
        'ip dhcp snooping\n'
        'ip dhcp snooping vlan 10\n'
        'ip arp inspection vlan 10\n'
        'ip verify source',
    verify:
        'show port-security interface (violation counters), show ip dhcp '
        'snooping binding (the real bindings), and a test spoof that is '
        'dropped while the legitimate host still works.',
    pitfalls:
        'Enabling DAI before the snooping bindings exist, which black-holes '
        'every host with a static address. Trusting the wrong uplink for DHCP '
        'snooping. Treating a MAC as evidence of identity in an audit.',
    aspects: ['spoofing', 'port security', 'arp inspection'],
    facts: {
      'Limits': 'MACs per port, violation action',
      'Validates': 'DHCP bindings, ARP, source IP',
      'Identity': 'only 802.1X certificates prove it',
    },
  ),
  NetworkTech(
    id: 'iot-segmentation',
    name: 'IoT and OT segmentation',
    aliases: [
      'iot segmentation',
      'segment iot',
      'iot vlan',
      'ot network',
      'industrial network',
      'iot devices on the network',
      'building management network',
    ],
    summary:
        'IoT and OT devices are unpatched, chatty and often have no security '
        'agent, so they get their own segment with a deny-by-default path out '
        'and a policy that names the few destinations they need.',
    mechanism:
        'Put the devices on dedicated VLANs per function (cameras, badges, '
        'HVAC, PLCs), route them through a firewall or an internal segmentation '
        'firewall rather than a layer-2 trunk, and write the egress rules from '
        'the vendor documentation: a camera talks to its NVR and its time '
        'source, a badge reader talks to its controller. Drop internet egress '
        'unless the vendor requires a cloud service, and if it does, pin the '
        'destination. Passive monitoring (SPAN or a tap) is how you find the '
        'traffic the documentation did not mention.',
    whenToUse:
        'Every building with cameras, access control, HVAC or industrial '
        'control, and before the first device is plugged in.',
    tradeoffs:
        'Segmentation breaks discovery protocols (mDNS, broadcast-based tools) '
        'and the vendor\'s remote support, so each one needs a documented '
        'exception. It is also a change to a network nobody wants to touch '
        'during production hours.',
    commands:
        'vlan 400\n'
        ' name IOT-CAMERA\n'
        'interface vlan 400\n'
        ' ip address 10.40.0.1 255.255.255.0\n'
        'ip access-list extended IOT-OUT\n'
        ' permit tcp 10.40.0.0 0.0.0.255 host 10.50.0.10 eq 554\n'
        ' permit udp 10.40.0.0 0.0.0.255 host 10.0.0.20 eq 123\n'
        ' deny ip any any log',
    verify:
        'A device works for its actual function while a scan from the IoT '
        'segment to the corporate VLAN is denied and logged.',
    pitfalls:
        'One big IoT VLAN, so a compromised camera reaches the badge system. '
        'Opening "any" to the NVR because the vendor could not say which '
        'ports. Leaving the vendor cloud tunnel open to the whole segment.',
    aspects: ['iot', 'ot', 'segmentation', 'unpatched'],
    facts: {
      'Pattern': 'one VLAN per function, firewall between',
      'Policy': 'allow the few flows, deny the rest',
      'Find the rest': 'passive monitoring',
    },
  ),
  NetworkTech(
    id: 'trustsec',
    name: 'Cisco TrustSec and SGT',
    aliases: [
      'trustsec',
      'sgt',
      'security group tag',
      'scalable group tag',
      'group based policy',
      'sxp',
      'inline tagging',
    ],
    summary:
        'TrustSec tags a packet with a Security Group Tag at ingress and '
        'enforces policy on the tag, so rules are written between groups of '
        'users and servers instead of between subnets.',
    mechanism:
        'The switch classifies the ingress frame by identity (802.1X, VLAN, '
        'static mapping) and inserts the SGT inline in the Ethernet header or '
        'propagates it with SXP to devices that cannot tag. The egress device '
        'enforces a Security Group ACL (SGACL) matrix: tag 5 may reach tag 9 '
        'on 443, everything else denied. Because the tag travels with the '
        'packet, policy follows the user across VLANs and wireless without '
        're-addressing anything.',
    whenToUse:
        'Large campus or data centre estates where subnet-based ACLs have '
        'become unmaintainable, and where users and workloads move.',
    tradeoffs:
        'It is a platform-wide capability: every device in the path must '
        'carry or learn the tag, or the policy silently does not apply. The '
        'matrix is powerful and easy to make unreadable, and troubleshooting '
        'moves from "which ACL" to "which tag did this packet get".',
    commands:
        'cts credentials id <device> password <secret>\n'
        'cts authorization list ISE\n'
        'interface g1/0/1\n'
        ' cts manual\n'
        '  policy static sgt 5 trusted\n'
        'cts role-based enforcement',
    verify:
        'show cts environment-data (the SGTs learned), show cts role-based '
        'sgt-map (how traffic was classified), and the SGACL hit counters on '
        'the enforcement device.',
    pitfalls:
        'Tagging only part of the path, so the SGACL never matches. A default '
        'permit matrix that makes the deployment look successful and enforces '
        'nothing. Rolling it out without a fallback for devices that cannot '
        'tag.',
    aspects: ['sgt', 'sgacl', 'sxp', 'tag'],
    facts: {
      'Tag': '16-bit SGT in the Ethernet header',
      'Enforcement': 'SGACL matrix between tags',
      'Dependency': 'every hop must carry or learn the tag',
    },
  ),
  NetworkTech(
    id: 'ra-guard',
    name: 'IPv6 RA Guard',
    aliases: [
      'ra guard',
      'rogue ra',
      'rogue router advertisement',
      'ipv6 ra guard',
      'block rogue ra',
      'ipv6 router advertisement',
    ],
    summary:
        'RA Guard drops Router Advertisements on ports that should never see '
        'one, which stops a rogue device from becoming the IPv6 default '
        'gateway for the whole segment.',
    mechanism:
        'The switch inspects ICMPv6 type 134 (Router Advertisement) and type '
        '135/136 (Neighbor Solicitation and Advertisement) and drops them on '
        'untrusted ports. Host ports are untrusted; the port facing the real '
        'router is trusted. Without it, an attacker with a laptop advertises a '
        'prefix and a default route and every dual-stack host silently prefers '
        'IPv6, which is the classic "the network is slow" outage.',
    whenToUse:
        'Every IPv6-enabled access layer, and every lab or guest segment where '
        'a device could speak IPv6.',
    tradeoffs:
        'RA Guard is per-port policy that must be maintained like any other: '
        'a trusted port left untrusted breaks the real router, and a virtual '
        'switch that legitimately sends RAs must be configured explicitly.',
    commands:
        'interface range g1/0/1-24\n'
        ' ipv6 nd raguard attach-policy HOST\n'
        'interface g1/0/25\n'
        ' no ipv6 nd raguard attach-policy HOST',
    verify:
        'A test RA from an untrusted port is dropped while the real router '
        'still advertises, and the host keeps the legitimate default route.',
    pitfalls:
        'Enabling RA Guard globally and cutting off the real router. '
        'Forgetting the hypervisor port that legitimately provides RAs for '
        'its guests. Relying on RA Guard alone when DHCPv6 and ND spoofing '
        'need their own guards.',
    aspects: ['ra', 'rogue', 'nd', 'guard'],
    facts: {
      'Drops': 'ICMPv6 type 134 on untrusted ports',
      'Trust': 'only the real router port',
      'Also needs': 'DHCPv6 Guard, ND inspection',
    },
  ),
  NetworkTech(
    id: 'fiber-testing',
    name: 'Testing a fibre link',
    aliases: [
      'test a fiber link',
      'fiber test',
      'fibre test',
      'otdr',
      'light meter',
      'optical power',
      'fiber link test',
    ],
    summary:
        'Test fibre from the light inward: power meter first, then a loopback '
        'or an OTDR for the fault location - and clean the connector before '
        'you believe any of the numbers.',
    mechanism:
        'A light meter reads the received power at the far end and compares '
        'it with the optic\'s receive range; below the floor is a dirty '
        'connector, a bad splice or too much loss. An OTDR sends a pulse and '
        'plots reflections, which shows the distance to a break, a bend or a '
        'bad connector. A loopback (transmit into a receive on the same port) '
        'proves the port and the optic in isolation. Each test answers a '
        'different question, so one of them alone is not a diagnosis.',
    whenToUse:
        'Bringing up any new fibre run, after any patch-panel change, and '
        'whenever an interface shows a rising CRC count.',
    tradeoffs:
        'The test gear is expensive and the readings only mean something if '
        'the reference launch cable is clean and the connector type matches '
        '(PC versus APC: an APC into a PC port is a permanent 3-4 dB loss). '
        'A link can pass a power test and still fail under 100G FEC.',
    commands:
        'show interfaces transceiver detail\n'
        'show interfaces <intf> | include CRC|input errors|output errors',
    verify:
        'Received power inside the budget on both ends, CRC errors flat over '
        'a sustained transfer, and an OTDR trace with no event closer than the '
        'expected loss per connector.',
    pitfalls:
        'Testing without cleaning, then replacing a perfectly good optic. '
        'Mismatched connector polish. Believing a power reading while the CRC '
        'counters keep climbing under load.',
    aspects: ['otdr', 'power', 'connector', 'crc'],
    facts: {
      'First': 'clean, then measure',
      'Meter': 'received power vs optic range',
      'OTDR': 'distance to the fault',
    },
  ),
  NetworkTech(
    id: 'config-backup',
    name: 'Configuration backup',
    aliases: [
      'config backup',
      'back up configs',
      'backup switch configs',
      'configuration backup',
      'archive config',
      'config archive',
      'restore config',
      'back up switch configs',
      'backup switch configs',
      'back up the config',
      'config versioning',
    ],
    summary:
        'A configuration backup is only a backup if it is automatic, '
        'versioned, off the device, and test-restored - otherwise it is a '
        'folder of files nobody has read.',
    mechanism:
        'Configure an archive destination on the device (or a scheduled pull '
        'from a tool) so every write-memory keeps the previous version with a '
        'timestamp, then copy those versions to a server over SCP/SFTP with a '
        'credential that is not a personal login. Store the running config, '
        'the startup config and the licence/feature state, and keep the '
        'binary image reference too. Test-restore into a lab device on a '
        'schedule, because a truncated or unreadable archive is discovered at '
        'the worst moment.',
    whenToUse:
        'Every production device, before the first change, and as a scheduled '
        'job rather than a manual habit.',
    tradeoffs:
        'The archive holds secrets (passwords, keys, pre-shared keys), so it '
        'needs the same protection as the device. Full backups of a large '
        'estate are heavy and noisy; configuration-only backups are small but '
        'do not rebuild the device alone.',
    commands:
        'archive\n'
        ' log config\n'
        '  logging enable\n'
        '  notify syslog contenttype plaintext\n'
        ' path scp://backup@10.0.0.20/\$h-\$t\n'
        ' write-memory\n'
        'show archive',
    verify:
        'A restore in the lab produces a working device, and the archive '
        'listing shows a version per change with a timestamp and a size that '
        'is not zero.',
    pitfalls:
        'A single copy on the device itself. Backups with no retention, so '
        'the config from before the bad change is already gone. Never testing '
        'a restore. Secrets in a world-readable directory.',
    aspects: ['backup', 'archive', 'restore'],
    facts: {
      'Trigger': 'every write-memory, automatically',
      'Store': 'off-device, versioned, access-controlled',
      'Prove it': 'test restore',
    },
  ),
  NetworkTech(
    id: 'network-monitoring',
    name: 'What to monitor on network devices',
    aliases: [
      'what should i monitor',
      'network monitoring',
      'monitor a switch',
      'monitoring stack',
      'observability',
      'monitoring a network',
      'what metrics matter',
    ],
    summary:
        'Monitor the four things that fail in order: the physical layer, the '
        'control plane, the forwarding path and the service - and alert on '
        'trends that predict them, not on the outage after it happened.',
    mechanism:
        'At the device: interface up/down and flap counts, CRC and input '
        'errors, optic receive power, CPU and memory, PoE budget, power supply '
        'and fan state, temperature. At the control plane: routing protocol '
        'adjacency counts and age, BFD state, STP topology changes, TCAM and '
        'ARP table utilisation, DHCP pool usage. At the service: latency, '
        'jitter, loss and availability from a synthetic probe on the paths '
        'users actually take. Log and flow export fill in the "what changed" '
        'question after an alert fires.',
    whenToUse:
        'Before the first production cutover, and reviewed every time an '
        'incident reveals a blind spot.',
    tradeoffs:
        'Every counter is cheap; alerting on all of them is not. Too many '
        'alerts and the team stops reading them, which is worse than no '
        'alerting. Polling at five minutes hides a flapping link that a '
        'one-minute poll would show.',
    commands:
        'snmp-server host 10.0.0.30 version 3 auth <user>\n'
        'snmp-server enable traps snmp linkdown linkup\n'
        'ip flow-export destination 10.0.0.30 2055\n'
        'logging host 10.0.0.30',
    verify:
        'A deliberately failed link, an exhausted DHCP pool and a full TCAM '
        'each produce an alert; a normal busy day does not.',
    pitfalls:
        'Monitoring up/down only, so a degrading optic with CRC errors is '
        'invisible until it dies. Alerting on CPU that is always high by '
        'design. No baseline, so nobody can say what "normal" is.',
    aspects: ['snmp', 'flow', 'baseline', 'alerting'],
    facts: {
      'Physical': 'CRC, optics, power, temperature',
      'Control plane': 'adjacency, TCAM, DHCP pool',
      'Service': 'latency, jitter, loss, availability',
    },
  ),
  NetworkTech(
    id: 'runbook',
    name: 'Runbook',
    aliases: [
      'runbook',
      'ops runbook',
      'operating procedure',
      'standard operating procedure',
      'sop',
      'operational checklist',
    ],
    summary:
        'A runbook is the exact sequence a tired engineer at 03:00 can follow '
        'without judgement: pre-checks, the commands, the expected output, the '
        'rollback and the verification.',
    mechanism:
        'Good runbooks are written from a real execution, not from memory: '
        'copy the commands with their output, note the decision points and '
        'the values that must be read before proceeding, and name the person '
        'who approves a stop. They live next to the device inventory, are '
        'versioned with the change, and are exercised in a lab or during a '
        'maintenance window before they are needed in anger.',
    whenToUse:
        'Anything repeated more than twice: upgrades, circuit turn-ups, '
        'failover tests, certificate renewals, incident first response.',
    tradeoffs:
        'They rot. A runbook that is not exercised becomes a false comfort, '
        'so it needs a review date and an owner; a stale runbook is worse than '
        'none because it is trusted.',
    commands:
        'show version\n'
        'show ip interface brief\n'
        'show run | include hostname\n'
        'copy running-config startup-config',
    verify:
        'Someone who did not write it executes it correctly, and the rollback '
        'step was tested at least once.',
    pitfalls:
        'A runbook that only lists commands, with no expected output. No '
        'rollback. No stop condition. Written by the person who will never '
        'run it.',
    aspects: ['runbook', 'procedure', 'rollback'],
    facts: {
      'Needs': 'pre-check, steps, expected output, rollback',
      'Proof': 'someone else executes it',
      'Lifespan': 'review date and an owner',
    },
  ),
  NetworkTech(
    id: 'network-documentation',
    name: 'Network documentation',
    aliases: [
      'document a network',
      'network documentation',
      'network diagram',
      'as built',
      'as-built',
      'ipam',
      'documentation',
    ],
    summary:
        'Documentation that survives is generated, not written: a topology '
        'diagram from the discovery data, an address plan from IPAM, and a '
        'decision record for every "why" that the config cannot show.',
    mechanism:
        'Three layers, each with one source of truth. The physical and logical '
        'topology from discovery (CDP/LLDP plus a polling tool) - accurate '
        'only if it is regenerated, not hand-drawn. The address plan from IPAM '
        'with owner, VLAN, site and purpose - never a spreadsheet per engineer. '
        'The decision record: why this design, what was rejected, what breaks '
        'if it changes. The config is the implementation, not the '
        'documentation.',
    whenToUse:
        'From day one; retroactively for any network you inherit, starting '
        'with the topology and the address plan.',
    tradeoffs:
        'Documentation is a tax on every change: if it is not part of the '
        'change workflow it decays within two quarters. Full CMDB-grade '
        'documentation for a small network is overkill; a diagram and IPAM is '
        'not.',
    commands:
        'show cdp neighbors detail\n'
        'show lldp neighbors detail\n'
        'show ip interface brief\n'
        'show vlan brief',
    verify:
        'A new engineer can trace a user\'s path from the port to the internet '
        'using the documents alone, and the IPAM has no duplicate allocation.',
    pitfalls:
        'Visio diagrams that were true last year. IPAM owned by one person. '
        'No record of why a workaround exists, so it becomes permanent.',
    aspects: ['diagram', 'ipam', 'decision record'],
    facts: {
      'Topology': 'generated from discovery',
      'Addresses': 'IPAM is the only source',
      'Why': 'decision record per design',
    },
  ),
  NetworkTech(
    id: 'floating-static',
    name: 'Floating static route',
    aliases: [
      'floating static',
      'floating static route',
      'backup static route',
      'standby static route',
    ],
    summary:
        'A floating static is a backup route with a deliberately worse '
        'administrative distance, so it is only installed when the primary '
        'disappears - and it needs a track object to disappear when the '
        'primary path dies silently.',
    mechanism:
        'Administrative distance decides between two routes to the same '
        'prefix from different sources; the lower wins. A static default at '
        'distance 250 sits below OSPF (110) and BGP (20), so it stays out of '
        'the table while the dynamic route exists. The trap is that the '
        'physical interface can stay up while the path beyond it is dead, so '
        'the static needs a track object (IP SLA or BFD) that withdraws it.',
    whenToUse:
        'A second WAN with no dynamic routing, a backup tunnel, or a last-resort '
        'route when the primary is another protocol.',
    tradeoffs:
        'It is manual and asymmetric: the return path may not match, and '
        'without tracking the backup can black-hole traffic. It does not '
        'scale past a handful of prefixes.',
    commands:
        'ip sla 1\n'
        ' icmp-echo 203.0.113.1 source-interface g0/1\n'
        ' frequency 5\n'
        'ip sla schedule 1 life forever start-time now\n'
        'track 1 ip sla 1 reachability\n'
        'ip route 0.0.0.0 0.0.0.0 198.51.100.1 250 track 1',
    verify:
        'The static is absent from show ip route while the primary is up, '
        'appears when the primary is withdrawn, and the track object goes '
        'down when the far end is unreachable but the link is up.',
    pitfalls:
        'A static with a better distance than the protocol it is meant to '
        'back up. No track, so a dead path keeps the route. Both directions '
        'using different paths and the firewall dropping the return.',
    aspects: ['distance', 'track', 'backup'],
    facts: {
      'Wins by': 'worse administrative distance',
      'Needs': 'track or IP SLA',
      'Risk': 'asymmetric return path',
    },
  ),
  NetworkTech(
    id: 'conditional-default',
    name: 'Conditional default origination',
    aliases: [
      'conditional default',
      'default originate',
      'default-information originate',
      'default route origination',
      'inject a default route',
      'originate a default route',
      'conditional default route',
    ],
    summary:
        'Originate a default route only while this router actually has a '
        'working path out - otherwise every downstream device follows you '
        'into a black hole.',
    mechanism:
        'OSPF default-information originate is unconditional by default: the '
        'router injects 0.0.0.0/0 whether or not it has one. Add always only '
        'when you mean it, and otherwise rely on the implicit condition - OSPF '
        'advertises the default only if a default exists in the routing table. '
        'For a stricter condition, attach a route map that matches the '
        'upstream default, a specific prefix or a track object, so the '
        'injection follows the real path state. BGP uses a default-originate '
        'neighbor statement with an optional route map for the same reason.',
    whenToUse:
        'Dual-homed edge routers, any site where the IGP default must follow '
        'the WAN, and designs with a backup path that must not be advertised '
        'as primary.',
    tradeoffs:
        'A conditional default creates a dependency between the edge state '
        'and the whole IGP: when the condition is misconfigured, the failure '
        'mode is total loss of egress rather than a slower path. It is also '
        'hard to see from the inside - the downstream router just has no '
        'default.',
    commands:
        'ip route 0.0.0.0 0.0.0.0 203.0.113.1\n'
        'ip prefix-list DEFAULT seq 5 permit 0.0.0.0/0\n'
        'route-map ORIGIN-DEFAULT permit 10\n'
        ' match ip address prefix-list DEFAULT\n'
        ' match ip next-hop 203.0.113.1\n'
        'router ospf 1\n'
        ' default-information originate route-map ORIGIN-DEFAULT',
    verify:
        'The default appears in the neighbours\' tables while the upstream is '
        'up, and is withdrawn when the upstream route disappears - test it by '
        'withdrawing the route, not by shutting the interface alone.',
    pitfalls:
        'default-information originate always on a router with no default. A '
        'route map that matches a prefix the router learns only sometimes. '
        'Both edge routers originating unconditionally, so half the traffic '
        'leaves through the dead one.',
    aspects: ['originate', 'route map', 'default'],
    facts: {
      'OSPF': 'default-information originate (always optional)',
      'Condition': 'route map matching the upstream path',
      'Failure': 'no default anywhere downstream',
    },
  ),
  NetworkTech(
    id: 'flat-network',
    name: 'Is a flat network ever acceptable',
    aliases: [
      'flat network',
      'flat l2 network',
      'single vlan',
      'one vlan for everything',
      'is a flat network ok',
    ],
    summary:
        'A flat network is acceptable only when it is small, single-purpose, '
        'and its failure domain is already the whole site - and then it must '
        'be a deliberate, documented choice rather than an accident.',
    mechanism:
        'Everything on one VLAN means one broadcast domain, one STP topology '
        'and one subnet: a loop takes down every device, a broadcast storm '
        'saturates every link, and a compromised host can reach every other '
        'host at layer 2 without passing a router or a firewall. The case for '
        'it is a lab, a small shop with a single switch, or a temporary '
        'construction site where the cost of segmentation outweighs the risk '
        'for a few weeks.',
    whenToUse:
        'A single-switch site with no servers, no guest access and no '
        'compliance scope - and even then, isolate the management interface.',
    tradeoffs:
        'Simplicity and zero design cost against a blast radius that is the '
        'entire site. The migration later is a re-address, which is why "we '
        'will segment it later" is usually a lie.',
    commands:
        'show vlan brief\n'
        'show spanning-tree summary\n'
        'show ip arp | count\n'
        'show mac address-table count',
    verify:
        'You can state the blast radius, the VLAN count and the reason in one '
        'sentence - if any of those is "we never decided", it is not a design.',
    pitfalls:
        'Flat by default and then called a design. A flat network with a guest '
        'SSID bridged into it. No management VLAN, so a compromised host can '
        'reach the switches.',
    aspects: ['flat', 'broadcast domain', 'blast radius'],
    facts: {
      'Blast radius': 'the whole site',
      'Hidden cost': 're-addressing later',
      'Minimum': 'separate management and guest',
    },
  ),
  NetworkTech(
    id: 'redundancy-cost',
    name: 'Redundancy without doubling cost',
    aliases: [
      'redundant without doubling cost',
      'redundancy cost',
      'cheap redundancy',
      'how much redundancy',
      'redundancy on a budget',
      'high availability on a budget',
    ],
    summary:
        'Buy redundancy at the layers where a single failure is catastrophic, '
        'and buy restoration everywhere else: not every component needs a '
        'twin, but every component needs a known recovery time.',
    mechanism:
        'Rank the failure modes by blast radius and time to repair. A dead '
        'core switch is a site outage, so it gets a pair and a protocol to '
        'fail over. A dead access switch is one closet, so it gets a spare on '
        'the shelf and a four-hour replacement. A dead WAN link is a site '
        'outage, so it gets a cheap secondary circuit or LTE, not a second '
        'MPLS. Duplicate power and optics are usually cheaper than duplicate '
        'chassis - a second supervisor or a second power supply buys most of '
        'the availability for a fraction of the cost.',
    whenToUse:
        'Every design review where the bill for full redundancy is the reason '
        'the project stalls.',
    tradeoffs:
        'The cheap option trades recovery time for capital: a spare on the '
        'shelf is only redundant if someone can install it. Shared risk - both '
        'links in the same duct, both PSUs on the same feed - makes the '
        'redundancy fictional.',
    commands:
        'show environment all\n'
        'show power inline\n'
        'show inventory\n'
        'show redundancy',
    verify:
        'A failure test of each single point shows the recovery time you '
        'documented, and the shared-risk review found no common duct, feed or '
        'upstream device.',
    pitfalls:
        'Redundant chassis on one power feed. A backup link through the same '
        'provider. Spares with no documented restore procedure. Counting '
        'uptime instead of time to restore.',
    aspects: ['cost', 'single point of failure', 'shared risk'],
    facts: {
      'Duplicate': 'core, WAN, power, optics',
      'Spare': 'access switches, transceivers',
      'Check': 'shared risk, not device count',
    },
  ),
  NetworkTech(
    id: 'ospf-over-wan',
    name: 'Running OSPF over a WAN',
    aliases: [
      'ospf over a wan',
      'ospf over the wan',
      'ospf over wan',
      'ospf across the wan',
      'igp over the wan',
      'ospf across sites',
      'igp over the wan',
      'ospf on the wide area',
    ],
    summary:
        'Yes, with constraints: OSPF belongs on the WAN only when the links '
        'are point-to-point, the topology is small, and you control both ends '
        '- otherwise BGP with an IGP underneath is the right tool.',
    mechanism:
        'OSPF floods link state to every router in the area, so a flapping '
        'WAN link causes SPF runs everywhere. On a full-mesh of VPN tunnels, '
        'OSPF over GRE or DMVPN works but the neighbour count and the '
        'broadcast network type multiply the flooding. BGP is designed for '
        'policy and scale: it summarizes, it attributes, and it does not flood '
        'the topology.',
    whenToUse:
        'A handful of sites on managed point-to-point circuits, a single '
        'provider MPLS L3VPN where the provider runs the IGP and you run BGP, '
        'or a lab.',
    tradeoffs:
        'Integration is simple and the metrics are easy to reason about, but '
        'you inherit flooding, area design and convergence coupling. BGP '
        'needs policy work and is harder to read, but it fails locally.',
    commands:
        'interface tunnel0\n'
        ' ip ospf network point-to-point\n'
        ' ip ospf hello-interval 10\n'
        ' ip ospf dead-interval 40\n'
        'router ospf 1\n'
        ' area 1 stub no-summary',
    verify:
        'A single link flap does not trigger a full-area SPF, the neighbour '
        'count matches the design, and summarization keeps the remote area\'s '
        'detail out of the core.',
    pitfalls:
        'Broadcast network type over a non-broadcast WAN, so DR election '
        'becomes a lottery. One area for the whole WAN. OSPF over an '
        'untrusted internet path without IPsec. Ignoring MTU differences, so '
        'adjacency sticks in EXSTART.',
    aspects: ['wan', 'flooding', 'area', 'bgp'],
    facts: {
      'Works': 'point-to-point, small topology',
      'Better at scale': 'BGP with an IGP under it',
      'Watch': 'flooding, area design, MTU',
    },
  ),
  NetworkTech(
    id: 'landing-zone',
    name: 'Cloud landing zone network',
    aliases: [
      'landing zone',
      'cloud landing zone',
      'account structure',
      'multi account network',
      'aws organization network',
      'cloud foundation',
    ],
    summary:
        'A landing zone fixes the address plan, the account boundaries and '
        'the connectivity model before the first workload exists, because '
        'those three are the only parts that are expensive to change.',
    mechanism:
        'Start with a non-overlapping address plan per region and environment, '
        'sized so growth needs no re-addressing; allocate from a /16 per '
        'environment and reserve a /16 for future regions. Then decide the '
        'connectivity model: one shared network account with transit gateway '
        'or a hub VPC, spokes attached to it, and every spoke using the hub '
        'for on-premises and internet egress. Security groups and network '
        'ACLs are the policy, and centralized egress (a firewall VPC or the '
        'cloud native inspection) is what makes the log one place. Keep '
        'production, non-production and shared services in separate accounts '
        'with separate VPCs, and make the network account the only place '
        'transit lives.',
    whenToUse:
        'Any organisation standing up its first serious cloud footprint, or '
        'one whose second account was created before anyone planned the first.',
    tradeoffs:
        'Centralized egress and a transit hub are easy to reason about and '
        'add a hop, a cost line and a failure domain. A flat peered mesh is '
        'cheaper per byte until the fifth account, then it becomes an audit '
        'finding.',
    commands:
        'aws ec2 create-transit-gateway --description core-tgw\n'
        'aws ec2 create-transit-gateway-vpc-attachment '
        '--transit-gateway-id <tgw> --vpc-id <vpc> --subnet-ids <a> <b>\n'
        'aws ec2 create-route --route-table-id <spoke-rt> '
        '--destination-cidr-block 10.0.0.0/8 --transit-gateway-id <tgw>',
    verify:
        'The CIDR plan has no overlap across accounts, every spoke reaches '
        'on-premises and the internet through the same inspected path, and '
        'the network account owns every transit attachment.',
    pitfalls:
        'Overlapping CIDRs found at the first merger. One account for '
        'everything, so the blast radius is the company. Egress through a '
        'NAT gateway per VPC, so the bill and the logs are everywhere.',
    aspects: ['address plan', 'transit', 'accounts', 'egress'],
    facts: {
      'First': 'non-overlapping CIDR plan',
      'Hub': 'transit gateway or hub VPC',
      'Accounts': 'prod, non-prod, shared, network',
    },
  ),
  NetworkTech(
    id: 'sflow',
    name: 'sFlow',
    aliases: ['sflow', 'sampled flow', 'packet sampling'],
    summary:
        'sFlow counts traffic by sampling packets at a fixed rate, so it shows '
        'volume and top talkers on every port without keeping a flow table.',
    mechanism:
        'The switch copies one packet in every N (commonly 1 in 1000 to 1 in '
        '4096) and ships it, plus per-interface counters, to a collector. '
        'Because nothing is cached, a collector can derive conversations and '
        'applications statistically, and the sampling rate is the accuracy '
        'limit: a flow that sends ten packets at 1:1000 is simply not seen.',
    whenToUse:
        'Fleet-wide visibility where per-flow state would cost memory or CPU, '
        'and where the question is how much traffic and from where rather '
        'than the exact session count.',
    tradeoffs:
        'Cheap and line-rate, but it estimates: short flows, retransmissions '
        'and per-session detail are invisible, and the numbers are only as '
        'good as the sampling rate.',
    commands:
        'sflow agent-ip 10.10.0.5\n'
        'sflow collector 10.10.0.50 6343\n'
        'sflow sampling-rate 1000\n'
        'sflow polling-interval 30',
    verify:
        'Confirm the collector receives datagrams (tcpdump udp port 6343 on '
        'the collector), then compare a sampled top-talker graph with an '
        'interface counter for the same minute.',
    pitfalls:
        'Setting 1:1000 on a 100G port, where the collector drowns. Leaving '
        'sampling on for a busy port and blaming the CPU. And treating sFlow '
        'counts as exact for capacity planning or billing.',
    facts: {
      'Method': 'Packet sampling',
      'State kept': 'None per flow',
      'Accuracy': 'Statistical',
      'Best at': 'Volume and top talkers',
    },
  ),
  NetworkTech(
    id: 'pagp',
    name: 'PAgP',
    aliases: ['pagp', 'port aggregation protocol'],
    summary:
        'PAgP is Cisco proprietary EtherChannel negotiation: it bundles '
        'parallel links into one logical port, and it only works between '
        'Cisco devices.',
    mechanism:
        'Ports exchange PAgP frames in desirable or auto mode; desirable '
        'actively asks, auto only answers, and auto-to-auto never forms a '
        'bundle. on mode skips negotiation entirely and is the usual cause '
        'of a bundle that comes up but passes no traffic. Members must match '
        'speed, duplex, MTU, allowed VLANs and trunk state.',
    whenToUse:
        'Only where both ends are Cisco and LACP is not available on the '
        'port you have.',
    tradeoffs:
        'Works reliably inside one vendor and stops at the vendor boundary. '
        'LACP is the standards-based equivalent and should be the default; '
        'the only reason to choose PAgP is a device that cannot speak LACP.',
    commands:
        'interface range gi0/1 - 2\n'
        ' channel-group 1 mode desirable\n'
        'show etherchannel summary',
    verify:
        'show etherchannel summary shows the bundle in use with every member '
        'flagged P for bundled. A member in stand-alone or suspended state '
        'means a mismatch, not a cable problem.',
    pitfalls:
        'auto-to-auto, which never negotiates. Mixing PAgP on one end and '
        'LACP on the other, which leaves both sides waiting. And bundling '
        'links across two switches without a stack or vPC.',
    facts: {
      'Owner': 'Cisco proprietary',
      'Modes': 'desirable / auto / on',
      'Standard': 'None',
      'Preferred': 'LACP (802.3ad)',
    },
  ),
  NetworkTech(
    id: 'wifi5',
    name: 'Wi-Fi 5 (802.11ac)',
    aliases: ['802.11ac', 'wifi 5', 'wi-fi 5', 'ac wave 2'],
    summary:
        'Wi-Fi 5 (802.11ac) is a 5 GHz-only standard that raised throughput '
        'with wider channels, 256-QAM and downlink MU-MIMO, but it still '
        'serves one client per channel at a time.',
    mechanism:
        '80 MHz channels (160 MHz on some hardware), 256-QAM, up to 8 spatial '
        'streams and downlink MU-MIMO: an AP can send to up to four clients '
        'at once on the downlink. There is no OFDMA and no uplink MU-MIMO, so '
        'the uplink still serialises clients, and 2.4 GHz runs legacy '
        '802.11n rates. A 4x4 AP at 80 MHz tops out near 1.7 Gbps of PHY '
        'rate, and real throughput is roughly half that.',
    whenToUse:
        'Existing deployments with 5 GHz-capable clients where the pain is '
        'coverage or airtime rather than client count, and where the uplink '
        'is already 1G or better.',
    tradeoffs:
        'Mature, cheap and well understood, but wide channels cut the number '
        'of non-overlapping channels (two 160 MHz channels in the whole '
        '5 GHz band), and without OFDMA a room full of light-usage clients '
        'still queues on airtime.',
    facts: {
      'Band': '5 GHz only',
      'Max width': '80 MHz (160 optional)',
      'Modulation': '256-QAM',
      'MU-MIMO': 'Downlink only',
      'OFDMA': 'No',
    },
  ),
  NetworkTech(
    id: 'packet-filter',
    name: 'Stateless packet filter',
    aliases: ['stateless firewall', 'packet filter', 'stateless filtering'],
    summary:
        'A stateless filter judges every packet on its own header fields, '
        'with no memory of the connection, so return traffic needs its own '
        'rule.',
    mechanism:
        'An ordered list of permit and deny entries matches on source, '
        'destination, protocol and port; the first match wins and an '
        'implicit deny sits at the end. Because no session table exists, a '
        'client opening an outbound connection to port 443 does not '
        'automatically get the reply back - the reply arrives on an '
        'ephemeral high port and must be permitted explicitly.',
    whenToUse:
        'Edge filtering where determinism and speed matter, protecting the '
        'router itself, and filtering traffic that never needs a session, '
        'such as DNS to a resolver, NTP, or ICMP echo from a monitoring range.',
    tradeoffs:
        'Fast, predictable and cheap to run, but the rule set grows with '
        'every application, asymmetric routing breaks it, and it cannot see '
        'application behaviour. A stateful firewall is the right tool '
        'anywhere users initiate connections.',
    facts: {
      'State': 'None',
      'Return traffic': 'Needs its own rule',
      'Strength': 'Speed and determinism',
      'Weakness': 'No session awareness',
    },
  ),
  // __END__
];
