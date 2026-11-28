/// The numeric reference behind [NetworkingIntellect].
///
/// A senior engineer answers "what is the OSPF hello timer" with the number
/// AND the network-type table, because the number alone is how people
/// misconfigure NBMA. Every entry here follows that shape: the fact, the
/// conditions that change it, and the command that proves it.
///
/// This file is data only; matching and rendering live in
/// `networking_facts.dart`.
library;

class NetworkingFact {
  final String id;

  /// Every group must match at least one phrase. Groups are ANDed, phrases
  /// inside a group are ORed, so [['ospf'], ['hello', 'dead', 'timer']]
  /// answers "ospf hello" and "what are the ospf timers" but not "bgp
  /// timer".
  final List<List<String>> requires;

  /// Phrases that mean this fact is the wrong one.
  final List<String> excludes;

  /// Tie-break for broad reference tables: a specialised fact wins a tie
  /// against a table that happens to contain the same words.
  final int priority;

  final String answer;

  const NetworkingFact({
    required this.id,
    required this.requires,
    this.excludes = const [],
    this.priority = 0,
    required this.answer,
  });
}

const List<NetworkingFact> networkingFacts = [
  NetworkingFact(
    id: 'dns-ttl',
    requires: [
      ['dns', 'soa', 'a record', 'zone'],
      ['ttl', 'time to live', 'caching', 'cache', 'default', 'negative'],
    ],
    excludes: ['record types', 'record type'],
    priority: 4,
    answer:
        'There is no standard default TTL. The TTL is a property of the zone, '
        'not of DNS: a \$TTL directive at the top of the zone file, or a TTL '
        'on each record, and if neither is set the SOA MINIMUM field applies. '
        'In practice you will see:'
        '\n- 300-3600 s for normal corporate records.'
        '\n- 60-300 s for anything a CDN or a failover service moves.'
        '\n- 86400 s for records that never change, which is also why the old '
        'answer survives a migration for a day.'
        '\nNegative answers are cached separately, for the SOA MINIMUM value '
        '(RFC 2308), capped by the resolver. That is why a new record can look '
        'broken for minutes after it is created - the NXDOMAIN is cached, not '
        'the record.'
        '\nBefore a migration, lower the TTL a day or two ahead, wait at least '
        'the old TTL, then change. Verify with dig +ttlunits <name> and dig SOA '
        '<zone>; a dig answer shows the remaining TTL, not the configured one, '
        'so the number counts down as resolvers cache it.'
        '\nRule: the TTL is a cache contract. Lower it before you need to move, '
        'never at the moment you move.',
  ),
  NetworkingFact(
    id: 'vlan-tag-size',
    requires: [
      ['802.1q', '8021q', 'dot1q', 'vlan tag', 'q-tag', 'tag'],
      [
        'size',
        'bytes',
        'byte',
        'long',
        'length',
        'overhead',
        'big',
        'what',
        'explain',
        'mean',
      ],
    ],
    excludes: ['ethertype'],
    priority: 6,
    answer:
        'An 802.1Q tag is 4 bytes: 2 bytes of TPID (0x8100) and 2 bytes of '
        'TCI. The TCI carries the 3-bit PCP priority, the 1-bit DEI, and the '
        '12-bit VLAN ID (so 4094 usable VLANs, 0 and 4095 reserved).'
        '\nFrame sizes: a normal Ethernet frame is 1518 bytes without the FCS '
        'and 1524 with it; tagged it is 1522 without the FCS and 1528 with it. '
        'QinQ with two tags is 1526/1532. The 1500-byte payload MTU does not '
        'change - the tag is L2 header, not payload.'
        '\nWhy it matters: some platforms and most WAN handoffs need to be told '
        'to accept frames above 1518 (a baby giant), and a port that drops '
        'tagged frames above 1518 shows no error - it just silently drops the '
        'larger ones. A capture shows 0x8100 at offset 12 of the frame.'
        '\nVerify: show interface <intf> | include MTU, and a capture that '
        'shows the tag where you expect it. On a trunk, show interfaces trunk '
        'confirms the allowed and active VLAN list, not the tag size.',
  ),
  NetworkingFact(
    id: 'ipsec-overhead',
    requires: [
      ['ipsec', 'esp'],
      ['overhead', 'bytes', 'byte', 'mtu', 'size', 'add'],
    ],
    excludes: ['suites', 'profiles'],
    priority: 5,
    answer:
        'ESP overhead is not one number, it is the sum of the fields the '
        'algorithm adds. For tunnel mode:'
        '\n- Outer IP header: 20 bytes (IPv4) or 40 (IPv6). Transport mode '
        'reuses the original header, so it saves those 20.'
        '\n- ESP header: 8 bytes (SPI 4, sequence 4).'
        '\n- IV: 8-16 bytes depending on the cipher (AES-CBC 16, GCM 8).'
        '\n- Padding plus pad length and next header: 1-2 bytes minimum, up to '
        'a full cipher block (16) more to align.'
        '\n- ICV: 12 bytes for SHA-1, 16 for SHA-256, 16 for GCM.'
        '\nA typical AES-256-CBC/SHA-256 tunnel therefore adds about 62-73 '
        'bytes; AES-GCM about 50-60. Add 8 bytes of UDP if NAT-T is in play.'
        '\nSizing: on a 1500-byte path, clamp TCP to 1360-1400 (ip tcp adjust-mss '
        '1360 is the common safe value) and prove the real limit with ping '
        '<peer> size 1400 df-bit. Voice and other UDP do not honour the '
        'clamp, so an underlay that cannot carry the encapsulated packet '
        'still loses them.'
        '\nVerify: show crypto ipsec sa shows the encapsulating and '
        'decapsulating packet counts - a mismatch means one direction is '
        'being dropped, usually by MTU or an ACL.',
  ),
  NetworkingFact(
    id: 'longest-prefix-match',
    requires: [
      ['longest prefix', 'longest-prefix', 'longest match', 'most specific'],
      ['work', 'forward', 'choose', 'route', 'lookup', 'match', 'why'],
    ],
    excludes: ['administrative distance'],
    priority: 5,
    answer:
        'Longest prefix match is the first and strongest rule in forwarding: '
        'the router picks the route with the most specific mask that still '
        'contains the destination. For 10.1.1.5, a /24 (10.1.1.0/24) beats a '
        '/16 (10.1.0.0/16) every time, whatever protocol each came from. A '
        'default route is /0 - the least specific match, so it is used only '
        'when nothing longer matches.'
        '\nThe order of decisions: longest prefix first, then - only between '
        'routes for the same prefix - administrative distance, then metric, '
        'then ECMP if the metrics tie. Distance is not a global preference; '
        'it breaks ties between identical prefixes only.'
        '\nConsequences worth remembering:'
        '\n- A BGP /25 always beats an IGP /24 for an address inside it, even '
        'though iBGP distance is 200. That is how a leaked more-specific '
        'blackholes traffic.'
        '\n- A summary route never overrides a more specific route, which is '
        'why summarisation is safe until you also filter the specifics.'
        '\n- Host routes (/32) are the most specific of all, which is why a '
        'static /32 is a surgical tool and why a stray one is hard to find.'
        '\nVerify: show ip route <destination> shows the chosen route, and '
        'show ip cef <destination> shows the prefix the FIB actually matched. '
        'When the two disagree, the FIB is the one forwarding.',
  ),
  NetworkingFact(
    id: 'dhcp-options',
    requires: [
      ['dhcp'],
      ['option', 'options', 'field', 'fields'],
    ],
    excludes: ['dora', 'relay', 'snooping'],
    priority: 4,
    answer:
        'The DHCP options worth knowing by number:'
        '\n- 1 subnet mask, 3 default gateway (a list; clients use the first), '
        '6 DNS servers, 15 domain name, 42 NTP servers.'
        '\n- 43 vendor-specific (and 60 vendor class, which the client sends), '
        '66/67 TFTP server and bootfile for phones and PXE.'
        '\n- 51 lease time, 52-54 overload/server identifier/requested address, '
        '58/59 renewal and rebinding timers.'
        '\n- 81 client FQDN (what registers the name in DNS), 82 relay agent '
        'information (the circuit ID and remote ID the relay inserts), 119 '
        'domain search list, 121 classless static routes, 249 the Microsoft '
        'equivalent, 252 WPAD.'
        '\nWhat goes wrong: option 3 with several routers makes the client take '
        'the first and ignore the rest - it is not a gateway redundancy '
        'mechanism, use FHRP for that. Option 121 is what a VPN client needs '
        'for split tunnelling; option 119 is what stops a laptop appending the '
        'wrong suffix. Option 82 is inserted by the relay, and a server that '
        'does not expect it can silently drop the request.'
        '\nVerify: show ip dhcp pool, show ip dhcp binding, and on the client '
        'ipconfig /all (Windows) or the lease file on Linux. If a scope is '
        'right and the client still gets no DNS, compare the options the '
        'server sends with what the client prints - the option numbers are '
        'the only common language.',
  ),
  NetworkingFact(
    id: 'ntp-for-logs',
    requires: [
      ['ntp', 'time sync', 'clock sync', 'clock'],
      ['log', 'logs', 'logging', 'syslog', 'timestamp', 'forensic', 'correlat'],
    ],
    excludes: ['stratum'],
    priority: 4,
    answer:
        'Time is the join key of every investigation. A log entry without a '
        'trustworthy timestamp cannot be placed against a packet capture, a '
        'firewall event or another device, so the first thing a senior '
        'engineer checks in an incident is whether the clocks agree.'
        '\nWhat drift actually costs: a few seconds is enough to put the '
        'login before the firewall deny, or to make a flow look like it '
        'started after the outage. When two devices disagree, the '
        'investigation starts with a false sequence of events.'
        '\nThe configuration that matters:'
        '\n- Every device points at the same internal NTP servers, and those '
        'point outward; do not let each device pick a public pool.'
        '\n- Authenticate NTP where the platform supports it, and never '
        'accept time from an untrusted source.'
        '\n- Log with milliseconds and a consistent zone: service timestamps '
        'log datetime msec localtime, or UTC everywhere - but pick one.'
        '\n- Switches, routers, firewalls, the hypervisor and the domain '
        'controller all matter, not just the servers.'
        '\nVerify: show ntp status (look for synchronized and the stratum), '
        'show ntp associations (the * marks the selected peer), and compare '
        'the clock on two devices with the same second. A device that is '
        'syncing but wrong is usually pointed at a source with a bad stratum.',
  ),
  NetworkingFact(
    id: 'mtu-vs-mss',
    requires: [
      ['mtu', 'maximum transmission unit'],
      ['mss', 'maximum segment size'],
    ],
    priority: 5,
    answer:
        'MTU and MSS are different layers and different numbers. MTU is the '
        'largest L2 payload an interface will forward - 1500 bytes on '
        'Ethernet. MSS is the largest TCP payload a host will put in one '
        'segment, and it is negotiated in the SYN: MSS = MTU - 40 for IPv4 '
        '(20 IP + 20 TCP), so 1460 on a 1500-byte MTU.'
        '\nConsequences:'
        '\n- MSS only applies to TCP. UDP, GRE, ESP and VXLAN are unaffected '
        'by an MSS clamp, which is why voice and tunnels still break when '
        'only the clamp is fixed.'
        '\n- Raising the MTU on a link does nothing unless every device on '
        'the path agrees, and the hosts still negotiate their own MSS.'
        '\n- A tunnel or PPPoE path needs a smaller MTU and a matching clamp '
        '(ip tcp adjust-mss) on the routers, or PMTUD does the work - and '
        'PMTUD fails wherever ICMP is blocked, which is the classic black '
        'hole: ping works, small pages load, large transfers hang.'
        '\nVerify: ping <host> size 1472 df-bit succeeds on a clean 1500 '
        'path (1472 + 28 headers = 1500); size 1473 fails with a '
        'fragmentation-needed message. On the router, show ip interface '
        'shows the MTU, and a capture shows the SYN MSS option.',
  ),
  NetworkingFact(
    id: 'bgp-dampening',
    requires: [
      ['bgp'],
      ['dampen', 'dampening'],
    ],
    priority: 4,
    answer:
        'BGP dampening is a penalty system: every withdrawal or flap adds '
        '1000 to a route, the penalty halves every 15 minutes, and a route is '
        'suppressed at 2000, then reusable at 750 (defaults). Maximum '
        'suppression is 60 minutes. It exists to stop a flapping prefix from '
        'churning every router in the AS.'
        '\nWhy it is usually off now: it punishes the route, not the cause, '
        'and a transient provider problem can hide a working path for an '
        'hour after the provider is fine. It also breaks fast failover, '
        'because the backup path is suppressed while the primary is down- '
        'and then the primary comes back and the route is still penalised.'
        '\nWhat to use instead: maximum-prefix with a warning threshold, a '
        'route-map that filters what you should never have accepted, BFD for '
        'fast failure detection, and graceful restart so a control-plane '
        'restart does not look like a withdrawal. If you must dampen, '
        'dampen selectively on eBGP customer routes only, never on iBGP or '
        'on a provider you depend on.'
        '\nVerify: show ip bgp dampening parameters shows the timers, show '
        'ip bgp dampened-paths shows what is currently suppressed, and show '
        'ip bgp flap-statistics shows the routes being penalised.',
  ),
  NetworkingFact(
    id: 'graceful-restart-nsf',
    requires: [
      ['graceful restart', 'graceful-restart', 'nsf', 'non-stop forwarding', 'nonstop forwarding'],
      ['restart', 'switchover', 'failover', 'difference', 'vs', 'versus', 'what'],
    ],
    priority: 4,
    answer:
        'Graceful restart (GR) and non-stop forwarding (NSF) are two halves '
        'of the same idea: keep forwarding while the control plane restarts, '
        'so a routing-process restart does not become an outage.'
        '\n- NSF is the forwarding half on the local device: the data plane '
        'keeps using the existing paths while the supervisor or the routing '
        'process restarts. On many platforms it is a hardware and image '
        'capability, not a command.'
        '\n- GR is the protocol half: the restarting router tells its '
        'neighbours it is going away briefly and asks them to keep the '
        'adjacency and the routes, then re-learns state when it returns. The '
        'neighbour must support the helper role.'
        '\n- Both hide a restart, not a bad path. If the forwarding table was '
        'wrong before the restart, it is still wrong after it.'
        '\nTimers that matter: restart-time (how long the neighbour waits, '
        'default 120 s for BGP) and stale-path-time (how long stale routes '
        'are kept, default 360 s). Set them deliberately; a restart that '
        'takes longer than restart-time is a full outage anyway.'
        '\nVerify: show ip bgp neighbors <peer> | include Graceful shows '
        'whether the session negotiated it, and show ip protocols shows the '
        'restart state. Test with a planned process restart and watch a '
        'long-lived ping - if it drops, the feature is off or the neighbour '
        'did not help.',
  ),
  NetworkingFact(
    id: 'private-vlan',
    requires: [
      ['private vlan', 'private-vlan', 'pvlan', 'isolated vlan', 'community vlan'],
      ['used', 'use', 'why', 'what', 'how', 'work'],
    ],
    priority: 4,
    answer:
        'A private VLAN splits one subnet into three roles without giving '
        'each segment its own address block:'
        '\n- Isolated ports talk only to the promiscuous port, never to each '
        'other. That is the hosting pattern: many customers, one gateway, no '
        'lateral movement.'
        '\n- Community ports talk to each other and to the promiscuous port, '
        'but not to other communities. That is the department-on-one-floor '
        'pattern.'
        '\n- The promiscuous port is the gateway or firewall interface and '
        'reaches everything in the primary VLAN.'
        '\nAll three share one primary VLAN and its subnet, so the addressing '
        'does not change - only the L2 reachability does. That is why it fits '
        'DMZ and multi-tenant hosting where a /24 is already allocated.'
        '\nWhat people get wrong: spanning a PVLAN across switches needs the '
        'secondary VLANs and the association configured identically on every '
        'switch (VTPv3 can carry it), and a trunk must allow both the primary '
        'and the secondaries. Verify with show vlan private-vlan and by '
        'pinging from one isolated port to another - it must fail while both '
        'can reach the gateway.',
  ),
  NetworkingFact(
    id: 'channel-width',
    requires: [
      ['channel width', 'channel-width', '80 mhz', '160 mhz', '40 mhz', '20 mhz'],
      ['difference', 'vs', 'versus', 'which', 'better', 'use', 'wide', 'width'],
    ],
    priority: 4,
    answer:
        'Channel width is a trade of peak rate for spectrum. Doubling the '
        'width roughly doubles the PHY rate for one client and halves the '
        'number of channels available for everyone else.'
        '\nIn 5 GHz there are about 25 non-overlapping 20 MHz channels, so '
        'that becomes roughly 12 at 40 MHz, 6 at 80 MHz and 2 at 160 MHz '
        '(fewer where DFS is restricted). In a dense office the wider channel '
        'is the wrong choice: fewer channels means co-channel interference, '
        'and a 160 MHz channel is also more likely to overlap radar and force '
        'a DFS channel change.'
        '\nThe rule: 20 MHz in dense areas, 40 MHz in sparse areas, 80 or 160 '
        'MHz only where there are few APs and few clients per cell. The '
        'client decides in the end - a 2x2 phone cannot use 160 MHz, so the '
        'width mostly buys airtime efficiency, not phone speed.'
        '\n6 GHz changes the arithmetic (7 x 160 MHz), which is why it is the '
        'density band of choice when the clients support it.'
        '\nVerify: show ap dot11 5ghz channel (or the controller equivalent) '
        'and a spectrum or survey tool. If neighbouring APs share a channel '
        'at 80 MHz, the width is the problem, not the signal strength.',
  ),
  NetworkingFact(
    id: 'vlan-pruning',
    requires: [
      ['vlan pruning', 'pruning', 'prune vlans'],
      ['what', 'how', 'work', 'use', 'why', 'stop', 'flood'],
    ],
    priority: 4,
    answer:
        'Pruning stops a trunk from carrying (and flooding) VLANs that have '
        'no ports on the far switch. Without it, broadcast, unknown unicast '
        'and multicast for every VLAN in the domain crosses every trunk, and '
        'a broadcast storm has more places to go.'
        '\nHow it is done today: explicit allowed lists on each trunk '
        '(switchport trunk allowed vlan ...) are the reliable method. '
        'Dynamic pruning through VTP is legacy and should not be trusted in '
        'a modern design - VTP is a configuration-sharing protocol, not a '
        'security control, and one wrong revision can erase a VLAN database.'
        '\nThe senior rule: the allowed list is the contract. Build it '
        'explicitly, in both directions, and keep it in the template so a new '
        'VLAN is added deliberately rather than leaking everywhere by '
        'default. Trunking all VLANs because it is easier is how a guest '
        'VLAN ends up on the management trunk.'
        '\nVerify: show interfaces trunk shows the allowed and active lists '
        'side by side (a VLAN allowed but not active has no ports), show '
        'vlan brief shows where each VLAN actually lives, and show '
        'spanning-tree vlan <id> shows whether that VLAN even reaches the '
        'far switch.',
  ),
  NetworkingFact(
    id: 'routed-port-vs-svi',
    requires: [
      ['routed port', 'routed interface', 'no switchport', 'svi', 'switch virtual interface'],
      ['difference', 'vs', 'versus', 'which', 'use', 'better', 'what'],
    ],
    priority: 4,
    answer:
        'Both are layer-3 interfaces on a switch, and they differ in what they '
        'are attached to:'
        '\n- A routed port (no switchport, then ip address) turns a physical '
        'port into a router interface. It has no VLAN, no access port, and '
        'exactly one subnet. It goes down when the cable goes down.'
        '\n- An SVI (interface vlan 10) is a virtual interface for a VLAN. It '
        'is up when at least one port in that VLAN is up and the VLAN exists '
        'in the database - which is why an SVI can be administratively up but '
        'protocol down, and why a switch with no access ports in the VLAN has '
        'no working gateway.'
        '\nWhen to use which: an SVI is the normal campus gateway for a user '
        'VLAN; a routed port is the normal choice for a point-to-point uplink '
        'to another router, a firewall or a WAN edge, because it removes the '
        'VLAN failure mode and gives a clean /30 or /31.'
        '\nTwo gotchas: a routed port cannot carry an 802.1Q trunk, and an '
        'SVI needs ip routing enabled - otherwise the switch is a bridge with '
        'an address, not a router. Verify with show ip interface brief (look '
        'at status and protocol) and show interfaces status for the port.',
  ),
  NetworkingFact(
    id: 'stp-loop-prevention',
    requires: [
      ['spanning tree', 'spanning-tree', 'stp', 'bpdu'],
      ['loop', 'loops'],
      ['prevent', 'avoid', 'stop', 'between', 'design'],
    ],
    priority: 3,
    answer:
        'Spanning tree already prevents the loop - the question is whether it '
        'is configured so the loop it builds is the one you want, and so an '
        'edge port cannot create a new one.'
        '\nThe design, in order:'
        '\n- Pick the root deliberately: spanning-tree vlan <id> root primary '
        'on the core, root secondary on the backup. Never leave the root to '
        'the lowest MAC address, which is the default and is usually a '
        'forgotten access switch in a closet.'
        '\n- PortFast on every end-user port, and BPDU guard with it: an edge '
        'port that receives a BPDU is err-disabled instead of joining the '
        'topology. That stops the classic unmanaged switch or a mis-cabled '
        'wall port from becoming a loop.'
        '\n- Loop guard on non-designated (blocking) ports and root guard on '
        'the ports facing away from the root. Loop guard stops a unidirectional '
        'link from turning a blocked port into a forwarding one; root guard '
        'stops a superior BPDU from moving the root.'
        '\n- Keep the topology shallow and the VLANs pruned: more blocked '
        'ports and more VLANs mean more state, and every STP problem is a '
        'one-second outage multiplied by the number of VLANs affected.'
        '\nVerify: show spanning-tree vlan <id> root (who is root and the '
        'path cost), show spanning-tree summary (port states and the guards '
        'enabled), show spanning-tree inconsistentports, and for a real loop '
        'watch the CPU and the MAC address table move - a MAC flapping '
        'between two ports is the signature.',
  ),
  NetworkingFact(
    id: 'switching-modes',
    requires: [
      ['store and forward', 'store-and-forward', 'cut through', 'cut-through', 'fragment free', 'fragment-free', 'switching mode'],
      ['difference', 'vs', 'versus', 'what', 'which', 'use', 'better'],
    ],
    priority: 4,
    answer:
        'The forwarding mode decides when a switch starts transmitting a frame, '
        'and that decides both latency and what it can check:'
        '\n- Store and forward buffers the whole frame, checks the FCS, then '
        'forwards. Latency scales with frame size (about 1.2 ms for 1500 bytes '
        'at 10 Mbps, microseconds at 1 Gbps) and bad frames are dropped at the '
        'ingress port instead of being spread.'
        '\n- Cut-through forwards after the first 6 bytes (the destination '
        'MAC), so latency is fixed and tiny - and CRC errors, runts and '
        'fragments pass straight through, because the switch never reads the '
        'tail. That is the trade: latency for integrity.'
        '\n- Fragment-free is the middle ground: it reads the first 64 bytes, '
        'which covers the collision window, and forwards. It still does not '
        'check the FCS.'
        '\nUse store and forward for general enterprise traffic - QoS, ACLs, '
        'SPAN and most inspection features require the whole frame anyway. '
        'Cut-through belongs where microseconds matter (trading, HPC, some '
        'storage fabrics) and the endpoints are trusted. '
        '\nVerify: show interface counters on the upstream port - a '
        'cut-through switch forwards the CRC errors and runts that a '
        'store-and-forward switch would have dropped at the source.',
  ),
  NetworkingFact(
    id: 'flow-control',
    requires: [
      ['flow control', 'pause frame', 'pause frames', '802.3x', 'pfc'],
      ['work', 'what', 'how', 'use', 'why', 'cause', 'problem', 'enable'],
    ],
    priority: 4,
    answer:
        'Ethernet flow control is a PAUSE frame (802.3x, opcode 0x8808): a '
        'receiver whose buffer is full asks the sender to stop for a number of '
        '512-bit times. It is backpressure at layer 2, and it works, but the '
        'side effects are why it is usually off.'
        '\n- A PAUSE stops the whole link, not one priority or one flow. '
        'Without priority flow control (802.1Qbb, PFC) a burst of storage '
        'traffic can pause the voice packet behind it - head-of-line blocking.'
        '\n- Pause frames can propagate and, in a loop or a badly designed '
        'fabric, cause a pause storm that looks like a dead link.'
        '\n- PFC is the lossless-Ethernet mechanism (RoCE, FCoE) and needs '
        'matching configuration end to end; mismatched PFC is worse than none.'
        '\n- TCP has its own flow control and congestion control; adding '
        'PAUSE to a TCP path mostly hides the problem and grows buffers.'
        '\nThe normal enterprise setting: flow control off on server and '
        'uplink ports (or rx-only where the platform defaults to it), off on '
        'the WAN, and PFC only on a purpose-built lossless fabric.'
        '\nVerify: show interface <intf> | include pause (or the platform '
        'counter for pause frames received and transmitted). A climbing '
        'receive counter means somebody upstream is asking this port to stop.',
  ),
  NetworkingFact(
    id: 'trunk-vs-access',
    requires: [
      ['trunk', 'access port', 'access mode'],
      ['difference', 'vs', 'versus', 'what', 'which', 'between'],
    ],
    priority: 3,
    answer:
        'An access port belongs to one VLAN and sends frames untagged - the '
        'endpoint never sees a tag. A trunk port carries multiple VLANs and '
        'tags them with 802.1Q, with one native VLAN sent untagged.'
        '\nWhat that means in practice:'
        '\n- The access port is the user, printer, AP or camera port. The '
        'device has no idea which VLAN it is in.'
        '\n- The trunk is the switch-to-switch, switch-to-router or '
        'switch-to-hypervisor link. Both ends must agree on the allowed list, '
        'the native VLAN and the tagging, or traffic silently lands in the '
        'wrong VLAN.'
        '\n- A voice port is an access port with a voice VLAN: the phone tags '
        'its own traffic and the PC behind it stays untagged on the data VLAN.'
        '\n- Turn off negotiation (switchport nonegotiate, DTP off) on trunks '
        'you did not intend to negotiate; a port that becomes a trunk by '
        'accident is a VLAN leak.'
        '\nVerify: show interfaces switchport shows the administrative and '
        'operational mode, the access VLAN, the native VLAN and the allowed '
        'list; show interfaces trunk shows which VLANs are actually active. '
        'A native VLAN mismatch is invisible in the config and shows up as '
        'two VLANs bridged together in the MAC table.',
  ),
  NetworkingFact(
    id: 'ntp-dst',
    requires: [
      ['ntp', 'clock', 'time'],
      ['daylight', 'dst', 'summer time', 'an hour off', 'one hour off', 'timezone'],
    ],
    priority: 4,
    answer:
        'NTP always carries UTC. The hour that appears on the device comes from '
        'the local timezone and the summer-time rule applied to it, so an hour '
        'of drift is almost never an NTP fault.\n'
        '- In Cisco IOS the zone and the rule are separate: clock timezone '
        'EST -5 sets the offset, and clock summer-time EDT recurring sets the '
        'rule. A device with the offset and no rule sits an hour behind for '
        'half the year.\n'
        '- syslog timestamps are stamped with the local clock; if the rule '
        'is missing, a log entry will look one hour old even though NTP is '
        'perfect.\n'
        '- A large offset at once means the clock is not synchronised at '
        'all (stratum 16, .INIT.) - check ntp status, not the wall clock.\n'
        'Verify: show clock detail (shows the time source), show ntp status '
        '(synchronised to ...), show ntp associations. Compare UTC, not local '
        'time, when you test against a reference.',
  ),
  NetworkingFact(
    id: 'prove-mtu',
    requires: [
      ['mtu', 'mss', 'fragmentation'],
      ['prove', 'test', 'check', 'verify', 'is the problem', 'suspect', 'diagnose'],
    ],
    priority: 4,
    answer:
        'Prove an MTU problem with size, not with opinion: send the same probe at increasing sizes with the don\'t-fragment bit set and watch where it stops.\n- Windows: ping -f -l 1472 10.0.0.1 (1472 + 28 bytes of IP/ICMP = 1500). Linux: ping -M do -s 1472 10.0.0.1.\n- If 1472 works and 1473 fails with a fragmentation-needed message, the path MTU is exactly that size and something in the middle is smaller. If 1473 fails silently, a device is dropping ICMP instead of answering - that is the black hole variant.\n- traceroute with the same payload size on Linux (traceroute -M do -s 1472) names the hop where it breaks.\n- A TCP handshake succeeds and the large transfer stalls after the first full-size segment; a capture shows the server retransmitting full-size segments that never arrive. That is the classic signature.\n- MSS = MTU - 40 for IPv4 TCP and MTU - 60 for IPv6. A 1400 tunnel needs mss 1360, not 1460.\nVerify after the fix with the same ping ladder and a single iperf3 stream at 1400 bytes; both should pass end to end.'
  ),
  NetworkingFact(
    id: 'switchport-capture',
    requires: [
      ['capture', 'span', 'mirror', 'wireshark', 'tcpdump'],
      ['switch', 'switchport', 'port', 'switched', 'how', 'set up'],
    ],
    priority: 4,
    answer:
        'A switch only sends a frame to the port it is destined for, so a laptop plugged into another port sees broadcast and flooding only. You need a mirror.\n- Local SPAN on Cisco: monitor session 1 source interface Gi1/0/5 both, monitor session 1 destination interface Gi1/0/24. Then capture on Gi1/0/24.\n- The destination port stops being a normal user port while it is a SPAN destination, and it must be at least as fast as the source or the switch drops the overflow.\n- Capture both directions on a duplex link, or you will see only half the conversation and misread every acknowledgement.\n- Remote SPAN (RSPAN) carries the mirrored traffic in a dedicated VLAN to another switch; ERSPAN tunnels it in GRE when the capture host is off-platform.\n- On a virtual switch or hypervisor, the equivalent is port mirroring on the vSwitch, not SPAN.\nVerify: ping the captured host and confirm both the request and the reply appear; seeing only one direction means you mirrored rx or tx rather than both. Then check the switch SPAN session counters for drops before you trust a zero-loss conclusion.'
  ),
  NetworkingFact(
    id: 'change-rollback',
    requires: [
      ['rollback', 'roll back', 'revert', 'undo'],
      ['change', 'failed', 'how', 'plan', 'window'],
    ],
    priority: 4,
    answer:
        'A rollback is a tested artefact, not an intention. Four things make one real:\n- A saved copy of the running config taken immediately before the change (copy run start, then archive or TFTP/USB), with the timestamp and the device named.\n- A commit-confirm or timed reload: on Cisco, reload in 10 with a console session open; on Junos, commit confirmed 10. If the change cuts your access, the device returns to the old state by itself.\n- An out-of-band path (console server, cellular, a management network that does not depend on what you are changing) so rollback does not require the thing you broke.\n- A written revert sequence with the exact commands, not the word revert. The person at 2 a.m. is not going to reconstruct it from memory.\nRoll back if the verification fails, not after an hour of hoping. A change that is 80% working is a change that has failed; the old state was better than a partially-applied new state.\nVerify the rollback the same way you verified the change: the same pings, the same route table, the same two test hosts. A rollback nobody tested is a second change.'
  ),
  NetworkingFact(
    id: 'pre-window-checklist',
    requires: [
      ['before', 'pre', 'prior'],
      ['maintenance', 'window', 'change', 'cutover'],
    ],
    priority: 3,
    answer:
        'The ten minutes before a window decide how the window goes. Check these in order:\n- The brief: what exactly changes, what must not change, and how you will know each one succeeded.\n- The baseline: ping, traceroute, interface counters, CPU and the routes you expect, captured now so the comparison after the change is possible at all.\n- The backup: running config saved and copied off the device, with a restore path that does not need the network you are changing.\n- The access: console or out-of-band verified, credentials tested, a second person available.\n- The rollback: written, with a timer set, and the verify commands for it.\n- The blast radius: who and what uses this device now, and the notification that they know.\n- The stops: the conditions that end the change (loss above X, a route missing, a neighbour down) agreed before anyone is tired.\nA change window without a baseline and a rollback is an outage with a calendar entry.'
  ),
  NetworkingFact(
    id: 'ip-plan-doc',
    requires: [
      ['ip plan', 'ip addressing plan', 'addressing plan', 'ipam', 'document the ip'],
      ['document', 'write', 'how', 'structure', 'keep', 'plan'],
    ],
    priority: 3,
    answer:
        'An IP plan that survives its author has three tables and one rule:\n- The site table: site, code, supernet, gateway convention, next free block. One row per site, and the block is contiguous so summarisation stays possible.\n- The VLAN table: VLAN id, name, subnet, mask, gateway, DHCP scope, purpose, owner. This is the table people actually look things up in.\n- The reservation and special table: infrastructure block, loopbacks, point-to-point links, VIPs, out-of-band, printers, servers - each with a documented reason.\n- The rule: allocation is top-down from the site supernet, and no allocation is made outside the plan. Ad-hoc ranges are how a plan dies.\nKeep it in version control, not in a spreadsheet emailed around, and give every row a last-changed date. Record the intent (why /26 here) as well as the value; the next engineer needs the reasoning to change it safely.\nVerify the plan against reality quarterly: arp and route tables on the core, DHCP leases, and a discovery scan for anything outside the documented blocks.'
  ),
  NetworkingFact(
    id: 'config-audit',
    requires: [
      ['audit', 'harden', 'hardening', 'security review'],
      ['config', 'configuration', 'switch', 'router', 'network'],
    ],
    priority: 3,
    answer:
        'A config audit is a checklist with evidence, not a feeling. Start with the ten that actually cause incidents:\n- Local accounts: no default or shared passwords, AAA in use, enable secret not enable password, and every account attributable to a person.\n- VTY lines: transport input ssh only, an access-class, exec-timeout set, and no telnet.\n- SNMP: v3 with auth and priv, v2c communities changed from public/private and restricted by ACL, traps limited to what you monitor.\n- Unused ports: shut them down, put them in a parking VLAN, enable port security or 802.1X on access ports.\n- Management plane: an out-of-band path, a management VRF or ACL on the SVI, and no management reachable from guest or user VLANs.\n- L2 protections: DHCP snooping, dynamic ARP inspection, storm control, BPDU guard on access ports.\n- Routing: no unauthenticated routing protocol on an untrusted interface, passive interfaces default, no redistribution without filtering.\n- Logging: a syslog server, accurate NTP (logs without time are decoration), and log levels that will not drown the disk.\n- Services: CDP/LLDP only where needed, no HTTP server and no bootp/small servers, unused features off.\n- Backups: config archived off-device and a restore tested at least once.\nVerify by diffing the running config against a golden template - the finding is the diff - and re-run the audit on a schedule, because configs drift back.'
  ),
  NetworkingFact(
    id: 'design-review',
    requires: [
      ['review', 'validate', 'sanity check', 'before rollout', 'design review'],
      ['design', 'vlan', 'addressing', 'subnet', 'topology'],
    ],
    excludes: ['validate the plan', 'review the plan'],
    priority: 3,
    answer:
        'A design review is five questions with a number or a name for each:\n- Addressing: does every VLAN and link have a documented block, is the plan summarisable at the site boundary, and does every block have room to grow by 2x without renumbering?\n- Failure: for each link, device and uplink, what happens when it fails, how long does the traffic take to move, and does the remaining capacity carry the load? State the number, not the word redundant.\n- Spanning tree: one deterministic root in the core, the root placement matches the traffic flow, and access ports cannot become root (root guard, BPDU guard).\n- Gateways: where is the first hop for each VLAN, is it on the shortest path, and is it paired?\n- Traffic policy: which VLANs may talk to which, where is that enforced, and is the guest and IoT path isolated at the gateway rather than by hope?\nThen the same five against the failure you think is unlikely: a full core switch, a WAN circuit, a site link, an entire rack. If the answer to any of them is we would fix it live, the design is not finished.\nVerify by walking a packet from an access port to the internet and back on paper, naming the device and the table at each hop.'
  ),
  // __END__
  NetworkingFact(
    id: 'ospf-timers',
    requires: [
      ['ospf', 'ospfv3'],
      ['hello', 'dead', 'timer', 'interval'],
    ],
    answer:
        'OSPF timers depend on the interface network type, and both ends must '
        'match exactly:\n'
        '- Broadcast and point-to-point: hello 10 s, dead 40 s.\n'
        '- NBMA and point-to-multipoint: hello 30 s, dead 120 s.\n'
        'The dead interval is four hellos by convention. A mismatch keeps the '
        'neighbour in INIT and is invisible in the routing table. '
        'show ip ospf interface prints both timers per interface. For '
        'sub-second failure detection use BFD rather than shrinking OSPF '
        'timers - BFD does not require every router in the area to agree.',
  ),
  NetworkingFact(
    id: 'ospf-lsa-types',
    requires: [
      ['ospf'],
      ['lsa', 'lsa type', 'lsa types', 'link state advertisement'],
    ],
    answer:
        'OSPF LSA types and who originates them:\n'
        '- Type 1 router: every router, one per area.\n'
        '- Type 2 network: the DR on a broadcast segment.\n'
        '- Type 3 summary: the ABR, one per prefix between areas.\n'
        '- Type 4 ASBR summary: the ABR, telling the area where the ASBR is.\n'
        '- Type 5 external: the ASBR, for redistributed routes.\n'
        '- Type 7 NSSA external: the ASBR inside a not-so-stubby area; the '
        'ABR translates it to type 5 on the way out.\n'
        '- Type 6 group membership is unused (MOSPF); types 9-11 are opaque '
        'and carry traffic engineering or segment routing information.\n'
        'show ip ospf database lists them by type, and a missing type 3 is '
        'why a prefix is in one area and not another.',
  ),
  NetworkingFact(
    id: 'ospf-cost',
    requires: [
      ['ospf'],
      ['cost', 'metric', 'reference bandwidth', 'auto-cost'],
    ],
    answer:
        'OSPF cost = reference bandwidth / interface bandwidth, as an integer, '
        'minimum 1. The default reference is 100 Mbps, so a 100 Mbps link, a '
        '1 Gbps link and a 10 Gbps link all cost 1 - which is why fast links '
        'look identical and traffic takes the wrong path. Raise it with '
        'auto-cost reference-bandwidth 100000 (100 Gbps) on EVERY router in '
        'the domain, or set the cost explicitly with ip ospf cost. A mismatch '
        'in reference bandwidth produces asymmetric costs and a path nobody '
        'can explain. Verify with show ip ospf interface.',
  ),
  NetworkingFact(
    id: 'eigrp-timers-metric',
    requires: [
      ['eigrp'],
      ['timer', 'hello', 'hold', 'metric', 'formula', 'k value', 'k-value'],
    ],
    answer:
        'EIGRP defaults:\n'
        '- Hello 5 s, hold 15 s on links faster than T1; hello 60 s, hold '
        '180 s on T1 or slower and on NBMA.\n'
        '- Administrative distance 90 internal, 170 external, 5 for a summary '
        'route.\n'
        '- Classic metric = 256 x (10^7 / bandwidth in kbps + delay in tens of '
        'microseconds). Only bandwidth and delay are used by default (K1 and '
        'K3); changing K values requires them to match on every neighbour.\n'
        '- A feasible successor must satisfy the feasibility condition: its '
        'reported distance is lower than the current feasible distance. '
        'variance enables unequal-cost load sharing only across feasible '
        'successors.\n'
        'show ip eigrp topology shows P (primary) and A (active) routes.',
  ),
  NetworkingFact(
    id: 'bgp-timers-asn',
    requires: [
      ['bgp'],
      [
        'timer',
        'keepalive',
        'hold',
        'port',
        'as number',
        'asn',
        'autonomous system',
      ],
    ],
    answer:
        'BGP basics an engineer is expected to know cold:\n'
        '- TCP 179. Keepalive 60 s, hold time 180 s by default; the negotiated '
        'hold is the lower of the two, and the keepalive is one third of it.\n'
        '- Administrative distance: eBGP 20, iBGP 200.\n'
        '- Public AS numbers are 1-64511 and 131072-4294967294; private are '
        '64512-65534 and 4200000000-4294967294. Four-byte ASNs are encoded as '
        'AS_TRANS (23456) for old peers.\n'
        '- A session resets if the hold timer expires, so three keepalives can '
        'be lost before the peer is declared dead. BFD is the fast '
        'alternative.\n'
        'show ip bgp summary prints the negotiated timers, the state and the '
        'prefix count.',
  ),
  NetworkingFact(
    id: 'bgp-best-path',
    requires: [
      ['bgp'],
      [
        'best path',
        'bestpath',
        'path selection',
        'select',
        'prefer',
        'decision',
      ],
    ],
    answer:
        'BGP installs one best path by this order, stopping at the first '
        'difference:\n'
        '1. Highest weight (Cisco local to the router).\n'
        '2. Highest local preference (AS-wide).\n'
        '3. Locally originated (network, aggregate, redistribute).\n'
        '4. Shortest AS_PATH.\n'
        '5. Lowest origin: IGP < EGP < incomplete.\n'
        '6. Lowest MED (only between paths from the same neighbouring AS '
        'unless always-compare-med).\n'
        '7. eBGP over iBGP.\n'
        '8. Lowest IGP metric to the next hop.\n'
        '9. Oldest route for eBGP (unless bestpath compare-routerid).\n'
        '10. Lowest router ID, then shortest cluster list, then lowest '
        'neighbour address.\n'
        'Multipath is a separate decision after best path: equal attributes '
        'and maximum-paths allow ECMP. show ip bgp <prefix> prints the reason '
        'per path.',
  ),
  NetworkingFact(
    id: 'admin-distance',
    requires: [
      ['administrative distance', 'admin distance', 'distance', 'ad value'],
      ['ospf', 'eigrp', 'bgp', 'static', 'connected', 'rip', 'isis', 'route'],
    ],
    answer:
        'Administrative distance is the trust ranking used when two protocols '
        'offer the same prefix:\n'
        '- Connected 0, static 1, eBGP 20, EIGRP 90, OSPF 110, IS-IS 115, '
        'RIP 120, EIGRP external 170, iBGP 200, unreachable 255.\n'
        'Distance only decides between equal-length prefixes. A longer prefix '
        'always wins first, no matter the distance. Within one protocol the '
        'metric decides. A floating static is a static route with a distance '
        'above the dynamic protocol (for example 130 over OSPF) so it is '
        'installed only when the dynamic route disappears. Verify with '
        'show ip route <prefix>, which prints distance/metric.',
  ),
  NetworkingFact(
    id: 'vlan-range',
    requires: [
      ['vlan', '802.1q', 'dot1q', 'vlan id'],
      [
        'how many',
        'maximum',
        'max',
        'range',
        'limit',
        '4094',
        'id range',
        'number of',
      ],
    ],
    answer:
        '802.1Q carries a 12-bit VLAN ID, so the usable range is 1-4094: 4094 '
        'VLANs, not 4096. VLAN 1 is the default and the default native VLAN; '
        '1002-1005 are reserved for legacy Token Ring and FDDI and should not '
        'be used. VLAN 0 and 4095 are reserved by the standard.\n'
        'The tag adds 4 bytes (QinQ adds 8), and the native VLAN is sent '
        'untagged, which is exactly why a native VLAN mismatch silently joins '
        'two different VLANs. Extended-range VLANs 1006-4094 require VTP '
        'transparent or off on many platforms. show vlan brief and '
        'show interfaces trunk are the verification pair.',
  ),
  NetworkingFact(
    id: 'stp-timers',
    requires: [
      ['spanning tree', 'stp', 'rstp', 'mst', 'pvst'],
      [
        'timer',
        'hello',
        'max age',
        'forward delay',
        'convergence',
        'priority',
        'root',
      ],
    ],
    answer:
        'STP numbers, 802.1D defaults:\n'
        '- Hello 2 s, max age 20 s, forward delay 15 s (listening 15 s, then '
        'learning 15 s). Classic convergence is therefore about 30-50 s.\n'
        '- Bridge priority 32768, in steps of 4096, with the extended system ID '
        'carrying the VLAN. The root is the lowest bridge ID (priority then '
        'MAC).\n'
        '- root primary sets 24576, root secondary 28672 on Cisco.\n'
        '- Path cost with the long (802.1t) method: 100 Mbps 200000, 1 Gbps '
        '20000, 10 Gbps 2000. The short (802.1D) method uses 19, 4 and 2.\n'
        'RSTP (802.1w) and MSTP (802.1s) converge in well under a second by '
        'replacing the timer-based transitions with explicit proposal and '
        'agreement. Timers only matter on legacy 802.1D; on RSTP, fixing the '
        'topology is what fixes convergence.',
  ),
  NetworkingFact(
    id: 'fhrp-values',
    requires: [
      ['hsrp', 'vrrp', 'glbp', 'fhrp'],
      ['timer', 'hello', 'hold', 'priority', 'mac', 'group', 'virtual'],
    ],
    answer:
        'First-hop redundancy numbers:\n'
        '- HSRP version 1: group 0-255, virtual MAC 0000.0c07.acXX (XX is the '
        'group in hex), hello 3 s, hold 10 s, default priority 100.\n'
        '- HSRP version 2: group 0-4095, virtual MAC 0000.0c9f.fXXX, same '
        'timers.\n'
        '- VRRP: IP protocol 112, virtual MAC 0000.5e00.01XX, advertisement '
        '1 s, master-down interval 3 x advert plus skew, priority 100. '
        'Priority 255 is the address owner and preempts unconditionally.\n'
        '- GLBP: up to four forwarders per group, virtual MAC 0007.b400.XXYY.\n'
        'Higher priority wins; preempt is off by default on HSRP and on by '
        'default on VRRP, which is the most common surprise when a router '
        'comes back and does not take the role.',
  ),
  NetworkingFact(
    id: 'dscp-values',
    requires: [
      ['dscp', 'qos', 'cos', 'tos', 'marking'],
      ['ef', 'af', 'cs', 'value', 'voice', 'class', '46', '34', 'priority'],
    ],
    answer:
        'DSCP is the top 6 bits of the ToS byte, so DSCP 46 is ToS 0xB8. The '
        'values worth memorising:\n'
        '- EF 46: voice bearer. The only class that should get a strict '
        'priority queue.\n'
        '- AF41 34, AF42 36, AF43 38: interactive video.\n'
        '- AF31 26, AF32 28, AF33 30: call signalling and streaming video.\n'
        '- AF21 18 / AF22 20 / AF23 22: transactional data.\n'
        '- AF11 10 / AF12 12 / AF13 14: bulk data.\n'
        '- CS1 8: scavenger. CS0 0: default. CS6 48 and CS7 56: network '
        'control, reserved for the control plane.\n'
        '802.1p CoS maps 5 to voice, 4 to video, 3 to call signalling, 6 to '
        'network control. Within an AF class the last digit is the drop '
        'precedence: 1 low, 2 medium, 3 high - WRED drops the 3s first.',
  ),
  NetworkingFact(
    id: 'well-known-ports',
    requires: [
      ['port', 'ports', 'tcp', 'udp'],
      [
        'number',
        'numbers',
        'what port',
        'which port',
        'use',
        'uses',
        'used',
        'well known',
      ],
    ],
    excludes: [
      'portfast',
      'bpduguard',
      'spanning tree',
      'switchport',
      'trunk',
      'access port',
    ],
    priority: -1,
    answer:
        'The ports that come up in real troubleshooting:\n'
        '- 22 SSH, 23 Telnet, 53 DNS (UDP and TCP), 67/68 DHCP, 69 TFTP, '
        '80/443 HTTP/S, 123 NTP, 161/162 SNMP, 179 BGP, 389/636 LDAP/S, '
        '514 syslog, 1812/1813 RADIUS (1645/1646 legacy), 49 TACACS+, 830 '
        'NETCONF over SSH, 6514 syslog over TLS.\n'
        '- 500/4500 IKE and NAT-T, 50/51 ESP and AH (IP protocol numbers, not '
        'ports), 4789 VXLAN, 6081 Geneve, 3784/3785 BFD single-hop and echo, '
        '4784 BFD multihop.\n'
        '- 1985/2029 HSRP, 112 VRRP (IP protocol, not a port), 5246/5247 '
        'CAPWAP control and data, 2055 NetFlow, 4739 IPFIX, 6343 sFlow, '
        '546/547 DHCPv6.\n'
        'A blocked 4500 breaks IPsec through NAT even though 500 works; that '
        'one catches people repeatedly.',
  ),
  NetworkingFact(
    id: 'ip-protocol-numbers',
    requires: [
      ['protocol number', 'ip protocol', 'protocol field'],
      ['number', 'numbers', 'what', 'which', 'list'],
    ],
    priority: -1,
    answer:
        'IP protocol numbers (the header field, distinct from TCP/UDP ports): '
        '1 ICMP, 2 IGMP, 6 TCP, 17 UDP, 41 IPv6 encapsulation, 47 GRE, 50 '
        'ESP, 51 AH, 58 ICMPv6, 88 EIGRP, 89 OSPF, 103 PIM, 112 VRRP, 115 '
        'L2TP, 132 SCTP.\n'
        'This matters because an ACL that permits TCP and UDP does not permit '
        'OSPF, EIGRP, GRE or ESP. On Cisco, permit ospf or permit gre names the '
        'protocol; permit 89 does the same thing numerically. A firewall that '
        'drops ESP because it only permits UDP 500 is a classic IPsec fault.',
  ),
  NetworkingFact(
    id: 'ipv6-ranges',
    requires: [
      ['ipv6'],
      [
        'range',
        'prefix',
        'ula',
        'link local',
        'link-local',
        'multicast',
        'global',
        'address',
      ],
    ],
    answer:
        'IPv6 address plan you should be able to recite:\n'
        '- 2000::/3 is global unicast (everything routable today).\n'
        '- fe80::/10 is link-local, automatically present on every interface, '
        'never routed, and the next hop for most static routes.\n'
        '- fc00::/7 is unique local; fd00::/8 is the locally assigned half '
        '(the eighth bit set). Use it like RFC 1918 space.\n'
        '- ff00::/8 is multicast: ff02::1 all nodes, ff02::2 all routers, '
        'ff02::5 and ff02::6 OSPFv3, ff02::1:2 DHCP relay agents.\n'
        '- ::1 loopback, :: unspecified. /64 is the standard subnet size for '
        'SLAAC.\n'
        'SLAAC relies on ND: 133 router solicitation, 134 router '
        'advertisement, 135 neighbour solicitation, 136 neighbour '
        'advertisement, 137 redirect. ND packets use hop limit 255 so they '
        'cannot cross a router - which is also how RA Guard works.',
  ),
  NetworkingFact(
    id: 'mtu-overhead',
    requires: [
      ['mtu', 'mss', 'overhead', 'encapsulation', 'jumbo'],
      [
        'value',
        'size',
        'how much',
        '1500',
        '9000',
        'bytes',
        'calculate',
        'vxlan',
        'gre',
        'ipsec',
        'tunnel',
      ],
    ],
    answer:
        'MTU and the overhead that breaks tunnels:\n'
        '- Ethernet 1500, jumbo 9000 (all devices in the path must agree). '
        'IPv4 minimum 576, IPv6 minimum 1280 - an IPv6 link below 1280 is not '
        'legal.\n'
        '- Encapsulation cost: GRE 24, VXLAN 50, IPsec tunnel mode roughly '
        '50-73 depending on algorithms, PPPoE 8, MPLS 4 per label, 6in4 20, '
        'WireGuard 60.\n'
        '- MSS = MTU - 40 for IPv4 (20 IP + 20 TCP), MTU - 60 for IPv6. So a '
        '1500 path gives 1460; a 1400 IPsec tunnel gives 1360.\n'
        '- If the underlay is 1500 and VXLAN needs 1550, either raise the '
        'underlay MTU or clamp MSS. Blocking ICMP type 3 code 4 turns a '
        'working path into a black hole without any counter moving.',
  ),
  NetworkingFact(
    id: 'poe-classes',
    requires: [
      ['poe', 'power over ethernet', '802.3af', '802.3at', '802.3bt'],
      ['class', 'watt', 'watts', 'power', 'budget', 'type'],
    ],
    answer:
        'PoE power by standard (PSE output at the port / PD minimum at the '
        'device):\n'
        '- 802.3af: 15.4 W / 12.95 W, classes 0-3.\n'
        '- 802.3at (PoE+): 30 W / 25.5 W, class 4.\n'
        '- 802.3bt Type 3: 60 W / 51 W, classes 5-6. Type 4: 90 W / 71.3 W, '
        'classes 7-8.\n'
        'Class 0 is default and reserved up to 15.4 W, which is why an '
        'undetected device gets the lowest tier. The PD must receive its '
        'minimum after cable loss: 100 m of Cat5e can lose several watts at '
        'high class, and that is why a long run with a marginal cable causes '
        'reboot loops rather than a clean failure. Cat5e is enough for af/at; '
        'bt wants Cat6A. Verify with show power inline.',
  ),
  NetworkingFact(
    id: 'vxlan-evpn-values',
    requires: [
      ['vxlan', 'evpn', 'vni', 'vtep'],
      [
        'vni',
        'vtep',
        'header',
        'overhead',
        'route type',
        '4789',
        '24-bit',
        'gateway',
      ],
    ],
    answer:
        'VXLAN and EVPN numbers:\n'
        '- VNI is 24 bits, so about 16 million segments; the VLAN-to-VNI map is '
        'local to each VTEP.\n'
        '- UDP destination 4789 (8472 on some older implementations), 8-byte '
        'VXLAN header plus outer UDP/IP/Ethernet = 50 bytes of overhead.\n'
        '- EVPN route types: 1 Ethernet auto-discovery (multihoming), 2 MAC/IP '
        'advertisement (the workhorse), 3 inclusive multicast (BUM traffic), '
        '4 Ethernet segment, 5 IP prefix (symmetric routing).\n'
        '- RD makes a prefix unique per VRF; route targets decide import and '
        'export. A VNI that is up with no MACs usually has a route-target '
        'mismatch, and a tunnel that pings but cannot pass large frames is the '
        'MTU.',
  ),
  NetworkingFact(
    id: 'mpls-label',
    requires: [
      ['mpls', 'ldp', 'label stack'],
      ['label', '20-bit', 'exp', 'ttl', '646', 'stack', 'php', 'overhead'],
    ],
    answer:
        'An MPLS label is 32 bits: 20 bits label, 3 bits EXP (now TC, used for '
        'QoS), 1 bit bottom-of-stack, 8 bits TTL. Each label adds 4 bytes, so a '
        'two-label stack costs 8 bytes of MTU.\n'
        'LDP uses TCP/UDP 646; RSVP-TE uses IP protocol 46; BGP carries VPNv4 '
        'over 179. PHP (penultimate hop popping) removes the last label before '
        'the egress so the egress router does not need to look it up twice.\n'
        'The common fault: an LSP that is up but the VPN route is missing, '
        'which is a route-target or RD problem, not an LDP problem. Check the '
        'label binding first, then the VPNv4 table.',
  ),
  NetworkingFact(
    id: 'multicast-addresses',
    requires: [
      ['multicast', 'pim', 'igmp'],
      ['address', '224', '239', 'range', 'ssm', 'rp', 'ttl', 'scope'],
    ],
    answer:
        'Multicast addressing and control:\n'
        '- 224.0.0.0/4 is the multicast range. 224.0.0.0/24 is link-local and '
        'never forwarded: 224.0.0.1 all hosts, 224.0.0.2 all routers, '
        '224.0.0.5/6 OSPF, 224.0.0.9 RIPv2, 224.0.0.10 EIGRP, 224.0.0.22 IGMPv3.\n'
        '- 232.0.0.0/8 is SSM (source-specific), 239.0.0.0/8 is administratively '
        'scoped, 233.0.0.0/8 is GLOP.\n'
        '- PIM sparse mode needs a rendezvous point; PIM dense floods and '
        'prunes; SSM needs no RP at all. MSDP (TCP 639) connects RPs between '
        'domains.\n'
        '- TTL scoping keeps a stream inside a site: a threshold on an '
        'interface drops packets with a lower TTL. IGMP snooping is what stops '
        'a switch flooding the group to every port.',
  ),
  NetworkingFact(
    id: 'tcp-parameters',
    requires: [
      ['tcp'],
      [
        'mss',
        'window',
        'handshake',
        'state',
        'retransmit',
        'port',
        'sequence',
        'throughput',
      ],
    ],
    answer:
        'TCP parameters that explain real performance:\n'
        '- MSS 1460 on a 1500 MTU. Window scaling is a 14-bit shift, so the '
        'maximum receive window is about 1 GB; without scaling it is 64 KB, '
        'which caps throughput on a long fat path.\n'
        '- Throughput ceiling = window / RTT. A 64 KB window at 100 ms RTT is '
        'about 5 Mbps no matter how much bandwidth exists.\n'
        '- Retransmissions and duplicate ACKs mean loss; out-of-order means '
        'multipath. TIME_WAIT is 2 x MSL (60 s on Linux) and port exhaustion '
        'looks like random connection failures under load.\n'
        'A firewall that drops the handshake but permits the data, or a state '
        'timeout shorter than the application idle time, produces exactly the '
        'same symptoms as a slow network.',
  ),
  NetworkingFact(
    id: 'dhcp-process',
    requires: [
      ['dhcp'],
      ['dora', 'process', 'port', 'lease', 'relay', 'option', 'renew'],
    ],
    answer:
        'DHCP in one paragraph: the client broadcasts DISCOVER from 0.0.0.0 to '
        '255.255.255.255, servers OFFER, the client REQUESTs one, the server '
        'ACKs - DORA. Client port 68, server port 67.\n'
        '- A relay sets giaddr to the receiving interface so the server can '
        'pick a scope; without a helper on the SVI, the broadcast dies at the '
        'router.\n'
        '- Lease renewal starts at T1 (50% of the lease) as unicast to the '
        'server, then T2 (87.5%) broadcasts to any server. Default lease is '
        'often 1 day.\n'
        '- Option 82 carries the relay port and VLAN; a server that does not '
        'understand it may drop the request. DHCPv6 uses UDP 546/547 and is '
        'separate from SLAAC.',
  ),
  NetworkingFact(
    id: 'dns-records',
    requires: [
      ['dns'],
      ['record', 'type', 'a record', 'mx', 'ttl', 'soa', 'srv', 'cname', 'ptr'],
    ],
    answer:
        'DNS record types you will actually look at: A (IPv4), AAAA (IPv6), '
        'CNAME (alias, and it cannot coexist with other records at the same '
        'name), MX (mail), TXT (SPF/DKIM/verification), NS (delegation), SOA '
        '(zone authority and negative TTL), SRV (service location, used by '
        'Active Directory and SIP), PTR (reverse).\n'
        'TTL controls caching: a long TTL makes a migration slow because the '
        'old answer stays cached; a short TTL raises query load. Port 53 UDP '
        'for normal queries, TCP for large answers and zone transfers, and '
        'EDNS0 raised the practical UDP payload to about 1232 bytes to avoid '
        'fragmentation.',
  ),
  NetworkingFact(
    id: 'syslog-severity',
    requires: [
      ['syslog', 'logging', 'log level'],
      ['level', 'severity', '0', '7', 'facility', 'debug'],
    ],
    answer:
        'Syslog severity is a 0-7 scale, lower is more severe: 0 emergency '
        '(system unusable), 1 alert (immediate action), 2 critical, 3 error, '
        '4 warning, 5 notice, 6 informational, 7 debug. logging trap 4 means '
        'send 0-4 and drop the rest, which is why a debug you enabled never '
        'appears in the collector.\n'
        'Facilities (local0-local7) let you sort device classes at the '
        'collector. Transport is UDP 514 by default, TCP 514 or TLS 6514 when '
        'you cannot lose messages, and RFC 5424 replaced the old BSD header '
        'with structured data. Time matters: send logs to NTP first or the '
        'sequence in the collector is fiction.',
  ),
  NetworkingFact(
    id: 'snmp-versions',
    requires: [
      ['snmp'],
      ['version', 'v2c', 'v3', 'port', '161', '162', 'trap', 'community'],
    ],
    answer:
        'SNMP versions and ports: v1 and v2c use a plaintext community string '
        '(read-only and read-write are different strings), v3 adds user-based '
        'authentication and optional encryption (auth MD5/SHA, priv DES/AES). '
        'Polling is UDP 161; traps and informs are UDP 162, and an inform is '
        'acknowledged while a trap is not.\n'
        'v2c adds 64-bit counters and bulk retrieval, which is why it still '
        'exists everywhere despite being insecure. Use v3 with authPriv on any '
        'network you would not shout the password across, and rate-limit '
        'polling: a 5-minute walk of a large table costs more CPU than most '
        'people expect.',
  ),
  NetworkingFact(
    id: 'radius-vs-tacacs',
    requires: [
      ['radius', 'tacacs'],
      [
        'difference',
        'vs',
        'versus',
        'port',
        'encrypt',
        'compare',
        'udp',
        'tcp',
      ],
    ],
    answer:
        'RADIUS and TACACS+ are not interchangeable:\n'
        '- RADIUS: UDP 1812 (authentication) and 1813 (accounting), legacy '
        '1645/1646. Encrypts only the password, combines authentication and '
        'authorization in one exchange, and is the standard for 802.1X and VPN '
        'users.\n'
        '- TACACS+: TCP 49. Encrypts the entire payload, separates '
        'authentication, authorization and accounting, and supports '
        'per-command authorization - which is why it is preferred for network '
        'device administration.\n'
        'If a switch must decide whether user X may run show run, that is '
        'TACACS+. If a laptop must prove its identity to join the wireless, '
        'that is RADIUS.',
  ),
  NetworkingFact(
    id: 'bfd-values',
    requires: [
      ['bfd'],
      [
        'timer',
        'interval',
        'multiplier',
        '3784',
        'echo',
        '50ms',
        'milliseconds',
      ],
    ],
    answer:
        'BFD is a lightweight hello protocol that detects path failure in '
        'milliseconds, independent of the routing protocol. Single-hop uses '
        'UDP 3784, multihop 4784, and echo 3785. The default transmit interval '
        'is often 50 ms with a multiplier of 3, so failure is declared in about '
        '150 ms; the multiplier is the number of missed packets tolerated.\n'
        'BFD must be configured on both ends with matching timers and the same '
        'session type. Asynchronous mode sends hellos; echo mode loops packets '
        'back through the forwarding path, which catches one-way failures that '
        'hellos miss. Do not set 50 ms across a WAN that jitters - BFD will '
        'flap the adjacency more often than the link actually fails.',
  ),
  NetworkingFact(
    id: 'wifi-standards',
    requires: [
      ['wifi', 'wi-fi', 'wireless', '802.11'],
      [
        'ax',
        'ac',
        'be',
        '6e',
        'n',
        'speed',
        'channel',
        'frequency',
        'standard',
      ],
    ],
    answer:
        'Wi-Fi generations and what actually matters:\n'
        '- 802.11n (Wi-Fi 4): 2.4 and 5 GHz, 40 MHz, 4x4 MIMO, 600 Mbps.\n'
        '- 802.11ac (Wi-Fi 5): 5 GHz only, 160 MHz, 8x8 downlink MU-MIMO, 6.9 '
        'Gbps.\n'
        '- 802.11ax (Wi-Fi 6): 2.4/5/6 GHz, OFDMA, 1024-QAM, 9.6 Gbps; 6E adds '
        'the 6 GHz band with 59 clean 20 MHz channels.\n'
        '- 802.11be (Wi-Fi 7): 320 MHz, 4096-QAM, multi-link operation, 46 '
        'Gbps.\n'
        'Non-overlapping 2.4 GHz channels are 1, 6 and 11; 5 GHz uses UNII '
        'bands with DFS in the middle; 6 GHz has no legacy clients at all. A '
        'wider channel raises peak rate and lowers reuse - in a dense '
        'deployment 20 or 40 MHz beats 80 MHz almost every time.',
  ),
  NetworkingFact(
    id: 'cable-distances',
    requires: [
      [
        'cat5e',
        'cat6',
        'cat6a',
        'cat7',
        'cat8',
        'fiber',
        'fibre',
        'om3',
        'om4',
        'os2',
        'cable',
      ],
      ['distance', 'length', 'meters', '100m', '10g', 'speed', 'reach'],
    ],
    answer:
        'Copper and fiber reach, the numbers that decide a design:\n'
        '- Cat5e: 100 m for 1 Gbps (2.5G also 100 m). Cat6: 100 m for 1 Gbps, '
        '55 m for 10G. Cat6a: 100 m for 10G. Cat7: 100 m shielded. Cat8: 30 m '
        'for 25/40G.\n'
        '- OM3: 300 m at 10G. OM4: 400 m at 10G, 150 m at 40G. OM5: 400 m at '
        '10G and designed for shortwave multiplexing. OS2 single-mode: 10 km at '
        '10G with LR, 40 km with ER, 80 km with ZR.\n'
        '- 1000BASE-SX 550 m on OM2, LX 10 km on SM; 10GBASE-SR 300 m on OM3, '
        'LR 10 km, ER 40 km.\n'
        'Copper distance is a electrical limit, not a protocol limit. A 120 m '
        'run may link at 1G and drop frames under load - always test the run, '
        'not just the link light.',
  ),
  NetworkingFact(
    id: 'nat-ranges',
    requires: [
      ['nat', 'pat', 'private address', 'rfc1918', 'cgnat'],
      [
        'range',
        'private',
        'how many',
        'timeout',
        'port',
        'overlap',
        'reserved',
      ],
    ],
    answer:
        'NAT address facts:\n'
        '- RFC 1918: 10.0.0.0/8, 172.16.0.0/12 (172.16-172.31), 192.168.0.0/16. '
        'Link-local 169.254.0.0/16 is not routable and is what a failed DHCP '
        'looks like. CGNAT is 100.64.0.0/10.\n'
        '- PAT multiplexes on source port: one public address can carry roughly '
        '64K minus reserved ports of concurrent flows, and port exhaustion '
        'shows up as intermittent connection failures under load.\n'
        '- Cisco default translation timeouts are 86400 s TCP, 300 s UDP, 60 s '
        'ICMP and DNS. If the application idles longer than the timeout, the '
        'next packet creates a new translation and the old flow is gone.\n'
        '- Overlapping RFC 1918 space on both sides of a VPN is the classic '
        'reason a tunnel comes up and nothing works: NAT cannot translate a '
        'subnet it also believes is local.',
  ),
  NetworkingFact(
    id: 'convergence-times',
    requires: [
      ['convergence', 'failover', 'failure detection', 'fast reroute'],
      [
        'time',
        'fast',
        '50ms',
        'sub-second',
        'how long',
        'milliseconds',
        'target',
      ],
    ],
    answer:
        'Convergence is four phases: detect, propagate, compute, install. Each '
        'has a different lever:\n'
        '- Detection: IGP hello/dead (OSPF 40 s, EIGRP 15 s) or BFD (about '
        '150 ms at 50 ms x 3).\n'
        '- Propagation and compute: flooding plus SPF, which is why area size '
        'and the number of prefixes matter.\n'
        '- Installation: RIB to FIB, the step people forget when they tune '
        'timers and see no change.\n'
        'Enterprise designs target sub-second; data centers target 200 ms; '
        'carrier and financial networks target 50 ms with fast reroute or '
        'TI-LFA. Tuning hellos alone cannot reach 50 ms - you need a '
        'pre-computed backup path.',
  ),
  NetworkingFact(
    id: 'port-channel-limits',
    requires: [
      [
        'lacp',
        'etherchannel',
        'port-channel',
        'port channel',
        'vpc',
        'mlag',
        'lag',
      ],
      ['how many', 'maximum', 'max', 'limit', '16', '8', 'member', 'active'],
    ],
    answer:
        'Link aggregation limits and behaviour:\n'
        '- LACP allows up to 16 links in a bundle, with at most 8 active and '
        'the rest hot standby; Cisco EtherChannel is commonly 8 active.\n'
        '- LACP short timeout is 1 s with 3 s before declaring a member down; '
        'long is 30 s with 90 s. System priority 32768 by default, lower wins.\n'
        '- Hashing is per flow, not per packet, so one TCP flow never exceeds '
        'one member. Twenty flows do not divide evenly across eight links.\n'
        '- All members must match speed, duplex, MTU, allowed VLANs and '
        'spanning-tree state. vPC/MLAG is two peers, not more, and the peer-link '
        'is the control path that must never carry the orphan traffic.',
  ),
  NetworkingFact(
    id: 'table-sizes',
    requires: [
      [
        'mac table',
        'arp table',
        'cam table',
        'mac address table',
        'adjacency',
        'tcam',
      ],
      ['how many', 'size', 'limit', 'maximum', 'entries', 'full'],
    ],
    answer:
        'Forwarding table sizes vary by platform and are a real design limit:\n'
        '- MAC tables are typically 8K-32K per switch; a campus access closet '
        'sized for 48 ports uses a tiny fraction, a data center with virtual '
        'machines can exhaust one.\n'
        '- ARP/ND tables are typically 1.5K-4K per line card; a /16 flat subnet '
        'with thousands of hosts can hit this before it hits bandwidth.\n'
        '- IPv4/IPv6 routes and ACL entries live in TCAM, which is shared and '
        'installed as a compiled image; "show tcam" or the platform equivalent '
        'is the only truth.\n'
        'When a table fills, the failure is usually silent: new MACs are not '
        'learned and traffic is flooded, or new routes are not installed and '
        'prefixes vanish. Size the table, not just the port count.',
  ),
  NetworkingFact(
    id: 'cloud-limits',
    requires: [
      ['vpc', 'subnet', 'security group', 'nacl', 'aws', 'azure', 'gcp'],
      [
        'how many',
        'limit',
        'size',
        '16',
        '28',
        'stateful',
        'reserved',
        'quota',
      ],
    ],
    answer:
        'Cloud network facts that cause real outages:\n'
        '- A VPC CIDR is /16 to /28, and every subnet reserves five addresses '
        '(network, router, DNS, future, broadcast) - a /28 gives 11 usable, not '
        '16.\n'
        '- Security groups are stateful and allow-only; network ACLs are '
        'stateless, numbered, and must permit the ephemeral return range '
        '1024-65535 (or the platform equivalent).\n'
        '- Route tables are per subnet; a route in the main table does not '
        'apply to a subnet with its own table.\n'
        '- Peering requires non-overlapping CIDRs and is not transitive; a '
        'transit gateway is what makes many VPCs routable. Endpoints (gateway '
        'or interface) replace NAT for service traffic and are a common '
        'missing route when an instance cannot reach S3 or a managed database.',
  ),
  NetworkingFact(
    id: 'ipsec-lifetimes',
    requires: [
      ['ipsec', 'ike', 'ikev2', 'vpn tunnel'],
      ['lifetime', 'rekey', 'sa', 'expire', 'timeout', 'phase 1', 'phase 2'],
    ],
    answer:
        'IPsec lifetimes and what actually breaks when they drift:\n'
        '- IKE (phase 1) SA: 24 hours is the common default (86400 s).\n'
        '- IPsec (phase 2) SA: 8 hours or 4,608,000 KB, whichever comes first '
        '(28800 s). The KB lifetime forces a rekey on a busy tunnel before the '
        'time expires.\n'
        '- The responder usually wins the lifetime proposal, so both ends do '
        'not have to match exactly, but a large mismatch causes a rekey storm.\n'
        '- Rekey happens before expiry; PFS makes the new key independent. '
        'Without PFS, a compromised long-term key exposes every SA derived from '
        'it.\n'
        '- A tunnel that drops every 8 hours on the minute is not a link '
        'fault; it is a rekey failing because one side lost the peer or the '
        'policy changed.\n'
        'Verify: show crypto ikev2 sa, show crypto ipsec sa (the remaining '
        'lifetime and the packet counters), and the log around the rekey time.',
  ),
  NetworkingFact(
    id: 'nat-timeouts',
    requires: [
      ['nat', 'pat', 'translation'],
      ['timeout', 'timer', 'how long', 'expire', 'table', 'idle'],
    ],
    answer:
        'NAT translation timeouts, which decide how long a quiet flow keeps '
        'working:\n'
        '- TCP established: 24 hours (86400 s) on many platforms.\n'
        '- TCP half-open (no handshake completion): often 1 minute or less.\n'
        '- UDP: 5 minutes (300 s). DNS is often 1 minute.\n'
        '- ICMP: 1 minute.\n'
        '- GRE and other protocols: platform specific, often 5 minutes.\n'
        'A firewall state timeout shorter than the NAT timeout is what kills a '
        'long-idle session even though the translation still exists. Match '
        'both, and make the application keepalive shorter than the smaller of '
        'the two. A full table is not a timeout problem: it means the scan or '
        'the churn exceeded the platform limit.\n'
        'Verify: show ip nat translations, show ip nat statistics, and the '
        'firewall connection table with ages.',
  ),
  NetworkingFact(
    id: 'lacp-timers',
    requires: [
      ['lacp', 'port-channel', 'etherchannel', 'lag', 'bond'],
      ['timer', 'fast', 'slow', 'timeout', 'rate', 'min-links'],
    ],
    answer:
        'LACP timers and the settings that decide whether a bundle survives:\n'
        '- Slow: LACPDU every 30 s, timeout 90 s. Fast: every 1 s, timeout 3 s.\n'
        '- Fast detects a dead member in about 3 s; slow takes up to 90 s. '
        'For a server or a stack member, fast is usually worth the extra '
        'packets.\n'
        '- LACP is a control protocol, not a data-plane check. It detects a '
        'dead link, not a link that is up and dropping frames. BFD or a higher '
        'layer check covers that.\n'
        '- The hashing is per flow, not per packet, so one elephant flow uses '
        'one member. A 2 x 10G bundle does not give a single flow 20G.\n'
        '- min-links prevents the bundle from coming up with too few members; '
        'without it, a two-member bundle that loses one member silently halves '
        'capacity instead of failing over.\n'
        'Verify: show etherchannel summary (members and flags), show lacp '
        'neighbor, and show etherchannel load-balance. A member in "s" is '
        'suspended, not standby.',
  ),
  NetworkingFact(
    id: 'bgp-table-size',
    requires: [
      ['bgp', 'border gateway protocol'],
      ['table', 'full table', 'how many routes', 'memory', 'prefix', 'scale'],
    ],
    answer:
        'BGP table scale and what it costs:\n'
        '- Global IPv4: roughly 1 million prefixes and still growing; IPv6 is a '
        'few hundred thousand and growing faster.\n'
        '- Memory per path: roughly 0.5 to 1 KB depending on attributes, so a '
        'full IPv4 table is about 0.5 to 1 GB of RIB. The FIB copy and the '
        'platform TCAM are separate limits.\n'
        '- A route reflector removes the full-mesh session count but not the '
        'path memory on the reflector: it holds every path it reflects.\n'
        '- maximum-prefix should be set above the current count with warning '
        'at 80 percent; without it, one leaked full table can take the router '
        'down.\n'
        '- Add-path and RPKI validation both increase memory and CPU. Size for '
        'the features enabled, not for a bare session.\n'
        'Verify: show ip bgp summary, show ip bgp memory, show ip route '
        'summary, and show processes memory sorted during a session reset.',
  ),
  NetworkingFact(
    id: 'ospf-lsa-aging',
    requires: [
      ['ospf', 'ospfv3'],
      ['age', 'aging', 'refresh', 'max-age', 'lsa', 'retransmit'],
    ],
    answer:
        'OSPF LSA aging and the timers that make a database look stale:\n'
        '- LS age counts up from 0; at 3600 s (MaxAge) the LSA is flooded and '
        'removed.\n'
        '- Every 1800 s (LSRefreshTime) the originator re-floods a fresh copy, '
        'so a healthy database never reaches MaxAge.\n'
        '- Retransmit is 5 s, transmit delay 1 s, and the pacing interval '
        'groups updates. A retransmit list that does not drain points at a '
        'one-way adjacency, not at a slow CPU.\n'
        '- A DoNotAge bit is used in demand circuits; it stops the refresh and '
        'is why the age stays flat there.\n'
        '- Sequence numbers increase on every change; a router that keeps '
        'receiving an older sequence is fighting a duplicate router ID or a '
        'stale neighbor.\n'
        'Verify: show ip ospf database (age and sequence per LSA), show ip '
        'ospf neighbor (retransmit and queue counts), and show ip ospf '
        'statistics.',
  ),
  NetworkingFact(
    id: 'wifi-capacity',
    requires: [
      ['wifi', 'wi-fi', 'wireless', 'access point', 'ap'],
      ['capacity', 'clients', 'users per ap', 'how many clients', 'airtime'],
    ],
    answer:
        'Wi-Fi capacity is airtime, not a client count:\n'
        '- 2.4 GHz has three non-overlapping channels (1, 6, 11); 5 GHz has '
        'about 25 in most regulatory domains; 6 GHz adds about seven 160 MHz '
        'or fourteen 80 MHz channels.\n'
        '- A practical planning figure is 30 to 50 active clients per radio, '
        'but the real limit is the busiest client and the airtime it consumes. '
        'One client at a low rate can starve a whole cell.\n'
        '- A 20 MHz channel at 2 spatial streams gives roughly 200 to 300 Mbps '
        'of PHY rate; real throughput is about half after overhead and '
        'contention.\n'
        '- High density is a channel-plan and AP-placement problem: more APs '
        'at lower power beat fewer APs at high power.\n'
        '- Video and voice need call admission control and a guaranteed '
        'airtime share, not just a DSCP mark.\n'
        'Verify: a site survey on the real client mix, channel utilization per '
        'radio, retry rate and the top talkers. A clean signal survey says '
        'nothing about airtime.',
  ),
  NetworkingFact(
    id: 'qos-queue-budget',
    requires: [
      ['qos', 'quality of service', 'queue', 'llq', 'priority queue'],
      ['budget', 'percent', 'bandwidth', 'how much', 'queue', 'priority'],
    ],
    answer:
        'A sane QoS queue budget on a WAN link:\n'
        '- Priority (LLQ) for voice: 10 to 20 percent of link bandwidth, '
        'policed. Unpoliced priority traffic starves everything else during a '
        'signalling storm.\n'
        '- Video: 20 to 30 percent in a bandwidth queue with a minimum.\n'
        '- Business data: the remaining bandwidth, with fair queueing so one '
        'flow cannot take the class.\n'
        '- Scavenger: 1 to 5 percent for backups and guest, so they cannot '
        'crowd out interactive traffic.\n'
        '- Control plane and routing: a small class with a guaranteed minimum; '
        'BGP and OSPF hellos must survive congestion.\n'
        '- The sum of the class guarantees must not exceed about 75 to 80 '
        'percent of the link; the rest is headroom and overhead.\n'
        '- Egress shaping is where QoS actually works. Ingress QoS needs a '
        'policer, because you cannot queue what has already arrived.\n'
        'Verify: show policy-map interface (per-class offered, dropped and '
        'queued), and a busy-hour test with voice plus a saturation flow.',
  ),
  NetworkingFact(
    id: 'mac-aging',
    requires: [
      ['mac', 'arp', 'neighbor'],
      [
        'aging',
        'age',
        'timeout',
        'cache',
        'table',
        'expire',
        'learn',
        'entries',
        'capacity',
        'how many',
      ],
    ],
    answer:
        'Aging timers that explain stale entries and flooding:\n'
        '- MAC address table: 300 s default on most switches (range 15 s to '
        '1 hour). A shorter age means more unknown-unicast flooding.\n'
        '- ARP cache: often 4 hours on routers, minutes on hosts. A stale ARP '
        'entry after a failover is why traffic goes to the old MAC.\n'
        '- IPv6 neighbor cache: reachable time is typically 30 s, stale entry '
        'is kept until traffic needs it, and the cache is finite.\n'
        '- A MAC that moves between ports repeatedly is a loop, a dual-homed '
        'device that is not using LACP, or a virtual machine that migrated. '
        'MAC flaps fill the log and destabilize the table.\n'
        '- On a failover, a gratuitous ARP updates the caches; without it, the '
        'old entry persists until the timer expires.\n'
        '- Table capacity is shared silicon, not a protocol constant: access '
        'switches often learn 8k to 32k MACs, larger chassis far more, and the '
        'same TCAM may be shared with routes and ACLs. A full table floods '
        'unknown unicast instead of dropping, which looks like a broadcast '
        'problem.\n'
        'Verify: show mac address-table aging-time, show mac address-table '
        'count, show ip arp, show ipv6 '
        'neighbors, and the MAC flap log during the event.',
  ),
  NetworkingFact(
    id: 'route-capacity',
    requires: [
      ['route', 'routes', 'routing table'],
      ['how many', 'hold', 'capacity', 'table size', 'fit', 'memory'],
    ],
    answer:
        'Route capacity is three separate limits, not one number:\n'
        '- RIB memory: roughly 0.5 to 1 KB per path with attributes. A '
        'million-path table is about 0.5 to 1 GB before the FIB copy.\n'
        '- FIB and TCAM: the forwarding copy is often the binding limit, and '
        'it may be shared with ACLs, MAC entries and NetFlow. The RIB can hold '
        'a prefix the FIB cannot install.\n'
        '- Platform and protocol limits: maximum routes per VRF, per protocol, '
        'and per prefix length; a default-only edge needs almost none, while a '
        'full-table edge needs about a million IPv4 paths plus IPv6.\n'
        'The question only has an answer with the profile: default only, '
        'partial routes, or full table. Size for next year and for both '
        'address families, then verify with show ip route summary, show cef '
        'summary, show platform resources and the vendor scale guide.\n'
        'A datasheet route count measured with 24-bit prefixes is not your '
        'profile; test with the real prefix mix and the features enabled.',
  ),
  NetworkingFact(
    id: 'routing-protocol-choice',
    requires: [
      ['routing protocol', 'igp', 'interior gateway'],
      ['best', 'which', 'choose', 'when to use', 'difference'],
    ],
    answer:
        'No routing protocol is best in the abstract; the choice follows the '
        'boundary and the operations team:\n'
        '- Inside one autonomous system: OSPF or IS-IS. OSPF is ubiquitous and '
        'easy to hire for; IS-IS scales cleanly and runs natively over IPv6, '
        'which is why service providers prefer it. Both are link-state and '
        'both need a designed hierarchy.\n'
        '- EIGRP is a strong choice in an all-Cisco estate: simple, fast, and '
        'easy to operate, at the cost of vendor lock-in.\n'
        '- Between autonomous systems: BGP, because policy, not shortest path, '
        'is the point. Do not run an IGP across an administrative boundary.\n'
        '- Choose by vendor mix, scale, convergence requirement and the skills '
        'you can actually staff. A protocol your team cannot troubleshoot at '
        '3 a.m. is the wrong protocol, however good the benchmark.\n'
        '- Run one IGP, summarize at area or domain boundaries, and redistribute '
        'only at explicit points with filtering. Two IGPs everywhere is how '
        'routing loops and mutual redistribution start.\n'
        'Verify before choosing: a lab with the real topology, a convergence '
        'test with a link failure, and a look at the daily operational commands '
        'your team would use.',
  ),
  NetworkingFact(
    id: 't1-throughput',
    requires: [
      ['t1', 'ds1', 't1 line'],
      ['throughput', 'bandwidth', 'speed', 'mbps', 'how much', 'capacity'],
    ],
    answer:
        'T1/DS1 capacity and the arithmetic behind it:\n'
        '- Line rate is 1.544 Mbps: 24 DS0 channels x 64 kbps = 1.536 Mbps, '
        'plus 8 kbps of framing and overhead. The payload is 1.536 Mbps, '
        'which is why a T1 is called 1.5 Mbps in practice.\n'
        '- A T3/DS3 is 44.736 Mbps, or 28 T1s. An E1 is 2.048 Mbps (32 x 64 '
        'kbps), and an E3 is 34.368 Mbps.\n'
        '- A T1 is full duplex: 1.544 Mbps each way, not 1.544 shared. It is '
        'symmetric, which is why it still appears as a voice or private-line '
        'tail even when broadband is faster.\n'
        '- Latency is low and predictable, but the rate is tiny by modern '
        'standards: one 1080p video call can consume most of it.\n'
        'Verify: show controllers t1 (line state, errors, clocking) and show '
        'interface serial (input/output rate and errors). A clean line with '
        'errors is usually clocking or a loopback, not the carrier.',
  ),
  NetworkingFact(
    id: 'voice-latency-budget',
    requires: [
      ['voice', 'voip', 'rtp'],
      ['latency', 'jitter', 'budget', 'one-way', 'delay', 'how much'],
    ],
    answer:
        'Voice quality budget, end to end (ITU-T G.114 and common practice):\n'
        '- One-way latency: 150 ms or less is preferred; up to 200 ms is '
        'acceptable; beyond 400 ms conversation breaks down. Measure '
        'mouth-to-ear, not just the WAN ping.\n'
        '- Jitter: 30 ms or less, absorbed by the jitter buffer. More buffer '
        'fixes jitter and adds latency, so the two budgets trade against each '
        'other.\n'
        '- Loss: under 1%, and ideally under 0.5%. A single lost packet is 20 '
        'ms of audio at G.711; concealment hides a little, not a burst.\n'
        '- Packetization: 20 ms payload at 50 packets per second. G.711 is 64 '
        'kbps payload, about 87.2 kbps on the wire with IP/UDP/RTP headers.\n'
        '- Mark EF (DSCP 46), give it a strict priority queue, and keep the '
        'queue shallow. A deep priority queue turns a burst into latency.\n'
        'Verify: a passive call-quality probe or RTP statistics (jitter, loss, '
        'MOS), plus a WAN QoS policy that counts EF. Ping alone does not prove '
        'voice quality.',
  ),
  NetworkingFact(
    id: 'rack-power',
    requires: [
      ['rack', 'cabinet', 'pdu'],
      ['power', 'outlet', 'circuit', 'ups', 'how many', 'redundant'],
    ],
    answer:
        'Rack power is a circuit design, not a count of outlets:\n'
        '- Two independent circuits, A and B, from different panels or UPS '
        'outputs, each sized to carry the full rack load. Dual-corded devices '
        'then lose only one feed.\n'
        '- A 20 A 120 V circuit is 2,400 VA; at 80% derating that is 1,920 W. '
        'A 30 A 208 V circuit is 6,240 VA; at 80% that is about 4,992 W. Do '
        'not plan to the breaker face value.\n'
        '- Use two PDUs (A/B) with enough C13 outlets, and C19 for high-power '
        'gear. Do not daisy-chain PDUs or extension strips in a rack.\n'
        '- PoE switches are the hidden load: a 48-port PoE switch can add '
        '1,000-1,500 W at the PDU even before the servers. Include the switch '
        'budget in the rack total.\n'
        '- UPS load should stay at or below 80% of rating, and runtime must be '
        'measured at the real load, not the datasheet half-load figure.\n'
        'Verify: the PDU ammeter per circuit under real load, the UPS load '
        'percentage, and a labeled breaker map. A rack that only has one feed '
        'is not redundant, however many outlets it has.',
  ),
  NetworkingFact(
    id: 'ntp-server-count',
    requires: [
      ['ntp'],
      ['how many', 'servers', 'server count', 'redundan', 'resilien'],
    ],
    answer:
        'NTP server count: four is the design number, three is the minimum.\n'
        '- With three servers, one falseticker can be outvoted; with two you '
        'cannot tell which one is wrong; with one there is no redundancy at '
        'all. Four gives you majority and one failure without losing '
        'falseticker detection.\n'
        '- Spread them across different hosts, racks or sites and different '
        'upstream sources. Four copies on one hypervisor is one server with '
        'four names.\n'
        '- Keep the stratum sane: internal servers at stratum 2 or 3, '
        'disciplined from diverse stratum 1 sources. Do not chain servers '
        'more than a few strata deep, and do not mix a local clock into the '
        'same selection set unless you mean it.\n'
        '- Clients should receive three or four servers (DHCP option 42 or '
        'the OS configuration), not one. More than four adds little and '
        'makes the selection set harder to reason about.\n'
        'Verify: ntpq -p or chronyc sources shows every server reachable, '
        'the offset is small, and the stratum is what you designed. Then '
        'block one server and confirm the remaining set still disciplines '
        'the clock.',
  ),
  NetworkingFact(
    id: 'vpn-scale',
    requires: [
      ['vpn', 'ipsec', 'remote access', 'ssl vpn', 'anyconnect'],
      [
        'how many',
        'simultaneous',
        'concurrent',
        'users',
        'tunnels',
        'sessions',
        'scale',
        'capacity',
      ],
    ],
    excludes: ['lifetime', 'phase', 'rekey', 'bandwidth-delay'],
    priority: 1,
    answer:
        'No router has a single "VPN users" number: three limits bind, and '
        'whichever is lowest is the answer.\n'
        '- IPsec SA count: branch routers in the 200-2000 tunnel range, '
        'depending on the platform and the license (a midrange ISR holds a few '
        'hundred; an ASR1k or a firewall-class box holds thousands).\n'
        '- Throughput: tunnels are encrypted in software on many routers, so '
        'the aggregate through the box caps the count before the SA table '
        'does.\n'
        '- Remote-access sessions: SSL or IKEv2 client hubs are licensed per '
        'concurrent user and per platform, not per interface.\n'
        'The honest answer is the platform datasheet number divided by the '
        'real per-tunnel rate, then verified with a load test. show crypto '
        'ipsec sa | count and show crypto ikev2 sa | count prove the ceiling '
        'you actually hit.',
  ),
  NetworkingFact(
    id: 'firewall-scale',
    requires: [
      ['firewall', 'asa', 'ftd', 'fortigate', 'palo alto', 'checkpoint'],
      [
        'concurrent',
        'connections',
        'session',
        'sessions',
        'throughput',
        'new connections',
        'how many',
        'scale',
      ],
    ],
    excludes: ['nat', 'timeout'],
    answer:
        'A firewall is sized on four numbers, and vendors quote the friendliest '
        'one:\n'
        '- Concurrent sessions: the state table (hundreds of thousands to '
        'tens of millions).\n'
        '- New connections per second: the CPU path, the number that actually '
        'decides a SYN flood or a busy web tier.\n'
        '- Throughput with the features you will run: L7 inspection and TLS '
        'decryption cut the datasheet number by a large factor, often 5-10x.\n'
        '- VPN tunnels and interfaces: licensed separately.\n'
        'Size to the peak new-connection rate and the inspected throughput, '
        'not the bare "firewall throughput" on the brochure. In production, '
        'show conn count and the session-utilisation graph are the real '
        'check.',
  ),
  NetworkingFact(
    id: 'dhcp-lease',
    requires: [
      ['dhcp'],
      ['lease', 't1', 't2', 'renew', 'renewal', 'how long', 'timers'],
    ],
    excludes: ['snooping', 'relay', 'option'],
    priority: 2,
    answer:
        'A Cisco DHCP lease defaults to one day, with T1 at 50 percent and T2 '
        'at 87.5 percent of the lease:\n'
        '- Lease 86400 s default; the client renews at T1 (12 h) by unicast to '
        'the server, and rebinds at T2 (21 h) by broadcast.\n'
        '- Short leases (hours) suit guest and hotspot pools where churn is '
        'high; long leases suit stable offices.\n'
        '- A lease shorter than the DHCP server failover convergence time is '
        'how a failover event turns into an address outage.\n'
        'show ip dhcp binding and show ip dhcp pool confirm the lease time in '
        'effect; the client side is ipconfig /all or the dhclient lease file.',
  ),
  NetworkingFact(
    id: 'stp-cost',
    requires: [
      ['spanning tree', 'stp', 'rstp', 'pvst', 'mst'],
      ['cost', 'path cost', 'port cost', 'priority', 'port priority'],
    ],
    excludes: ['hello', 'max age', 'forward delay', 'convergence'],
    priority: 2,
    answer:
        'STP path cost is derived from link speed, and the four tie-breakers '
        'are applied in this order: lowest root path cost, lowest sender '
        'bridge ID, lowest sender port priority, lowest sender port number.\n'
        '- Short method (default on most switches): 10 Mbps 100, 100 Mbps 19, '
        '1 Gbps 4, 10 Gbps 2, 100 Gbps 1.\n'
        '- Long method (802.1t, some platforms): 100 Mbps 200000, 1 Gbps '
        '20000, 10 Gbps 2000.\n'
        '- Port priority is 0-255, lower wins, default 128.\n'
        'Tune cost (spanning-tree cost) or priority to choose the primary '
        'path; never leave a production path to a tie-break. Verify with show '
        'spanning-tree interface detail - it prints the cost and the role it '
        'produced.',
  ),
  NetworkingFact(
    id: 'ethertypes',
    requires: [
      ['ethertype', 'ether type', 'encapsulation type', '802.1q tag'],
      ['value', 'values', 'type', 'what', 'which', 'number'],
    ],
    answer:
        'The EtherType tells the receiver what is inside the frame:\n'
        '- 0x0800 IPv4, 0x86DD IPv6, 0x0806 ARP.\n'
        '- 0x8100 802.1Q VLAN tag (0x88A8 is the outer tag for QinQ).\n'
        '- 0x8847 MPLS unicast, 0x8848 MPLS multicast.\n'
        '- 0x8863/0x8864 PPPoE discovery and session.\n'
        '- 0x888E EAPOL (802.1X), 0x88CC LLDP, 0x8809 LACP/slow protocols.\n'
        'A capture shows the EtherType two bytes after the source MAC; a '
        'mismatch between what the port expects (a tag or no tag) is a '
        'silent drop, not an error.',
  ),
  NetworkingFact(
    id: 'ethernet-frame',
    requires: [
      ['ethernet frame', 'frame size', 'fcs', 'preamble', 'minimum frame'],
      ['size', 'bytes', 'what', 'how big', 'minimum', 'maximum'],
    ],
    excludes: ['jumbo'],
    answer:
        'An Ethernet frame, in order:\n'
        '- Preamble 7 bytes plus SFD 1 byte (not counted in the frame).\n'
        '- Destination MAC 6, source MAC 6, EtherType 2, payload 46-1500, FCS '
        '4 - so 64 bytes minimum and 1518 maximum untagged, 1522 with one '
        'VLAN tag and 1526 with two.\n'
        '- A frame smaller than 64 bytes is a runt; larger than the MTU is a '
        'giant, and both are counted on the interface.\n'
        'The 64-byte minimum exists to make collision detection work on a '
        'shared segment. show interface counters report runts and giants '
        'separately - runts usually mean a duplex mismatch or a bad cable.',
  ),
  NetworkingFact(
    id: 'ipv6-subnet-sizes',
    requires: [
      ['ipv6'],
      ['prefix', 'subnet', 'slaac', 'lan', 'how many addresses', 'site'],
    ],
    excludes: ['ula', 'link local', 'multicast', 'transition'],
    priority: 2,
    answer:
        'The IPv6 allocation rule of thumb:\n'
        '- /48 per site or per customer: 65,536 /64s, enough for every VLAN and '
        'then some.\n'
        '- /56 per small site when a /48 is too generous: 256 /64s.\n'
        '- /64 per LAN, always - SLAAC needs exactly 64 bits of interface ID, '
        'and a /72 or a /126 breaks stateless autoconfiguration.\n'
        '- /127 for point-to-point links (RFC 6164), /128 for loopbacks.\n'
        'Never subnet a /64 further for hosts; if you need more than one '
        'VLAN, take another /64 from the site block. show ipv6 interface '
        'brief prints the prefix and whether SLAAC is on.',
  ),
  NetworkingFact(
    id: 'aaa-timers',
    requires: [
      ['radius', 'tacacs', 'aaa', 'ise'],
      ['timeout', 'retransmit', 'timer', 'how long', 'failover', 'dead'],
    ],
    excludes: ['port', 'encrypt'],
    answer:
        'AAA timeouts decide how fast a dead server becomes an outage:\n'
        '- Cisco default: radius-server timeout 5 s, retransmit 3, so one '
        'unreachable server can hold a login for 15 s before the next one is '
        'tried.\n'
        '- TACACS+ uses the same 5 s / 3 retry pattern.\n'
        '- Cisco ISE and many RADIUS servers mark a node dead after a few '
        'consecutive failures and stop trying it for a quiet period.\n'
        '- Auth-fail VLAN or a local fallback is what keeps the port usable '
        'when the server set is down.\n'
        'Tune the timeout down (2 s) and keep the fallback: a user waiting 15 '
        's at every login is a symptom, not the design.',
  ),
  NetworkingFact(
    id: 'dot1x-timers',
    requires: [
      ['dot1x', '802.1x', '8021x', 'eap'],
      ['timer', 'timeout', 'reauth', 'quiet', 'how long', 'interval'],
    ],
    answer:
        'The 802.1X timers that matter on a Cisco switch:\n'
        '- reauthentication 3600 s (off by default on many platforms).\n'
        '- quiet period 60 s after a failed attempt, so a bad password does '
        'not hammer the server.\n'
        '- tx-period 30 s for the supplicant to answer (5 s is common when '
        'fast onboarding matters).\n'
        '- server timeout 30 s waiting for RADIUS, then the port falls back '
        'to the auth-fail VLAN if one is configured.\n'
        '- supplicant timeout 30 s per attempt.\n'
        'show authentication sessions and show dot1x interface print the '
        'effective timers per port; a quiet period longer than the user\'s '
        'patience is how a help-desk ticket is born.',
  ),
  NetworkingFact(
    id: 'port-security-defaults',
    requires: [
      ['port security', 'port-security'],
      ['default', 'maximum', 'max', 'aging', 'violation', 'how many', 'mac'],
    ],
    answer:
        'Cisco port security defaults:\n'
        '- Maximum one secure MAC address per port.\n'
        '- Violation mode shutdown: the port goes err-disabled and stays down '
        'until it is cleared.\n'
        '- Aging disabled, so a learned MAC never expires.\n'
        '- Sticky learning off.\n'
        'Set the maximum to the number of devices that legitimately share the '
        'port (one for a workstation, two or three for a phone plus a PC), '
        'choose restrict or protect where a shutdown is unacceptable, and '
        'enable aging so a moved device does not lock the port. Verify with '
        'show port-security interface and show port-security address.',
  ),
  NetworkingFact(
    id: 'errdisable-recovery',
    requires: [
      ['errdisable', 'err-disable', 'err disabled', 'error disabled'],
      ['time', 'recovery', 'how long', 'interval', 'default', 'timer'],
    ],
    answer:
        'An err-disabled port stays down for 300 s (5 minutes) after the '
        'cause is removed, and only if recovery is enabled for that cause:\n'
        '- errdisable recovery cause bpduguard (and psecure-violation, '
        'link-flap, dhcp-rate-limit, and the rest) must be set per cause; the '
        'global interval alone does nothing.\n'
        '- Default interval 300 s; the range is 30-86400 s.\n'
        '- Without a recovery cause, only shutdown / no shutdown (or a reload) '
        'clears it.\n'
        'show interfaces status err-disabled prints the reason and whether '
        'the port is waiting for recovery. If the same port err-disables '
        'again, the cause is still present - recovery is not the fix.',
  ),
  NetworkingFact(
    id: 'netflow-timeouts',
    requires: [
      ['netflow', 'ipfix', 'flow export', 'flexible netflow', 'sflow'],
      ['timeout', 'active', 'inactive', 'how long', 'interval', 'cache'],
    ],
    answer:
        'Flow cache timers decide what a collector sees:\n'
        '- Active timeout 1800 s: a long flow is exported every 30 minutes '
        'and continues under a new record.\n'
        '- Inactive timeout 15 s: a flow that goes quiet is exported after 15 '
        's.\n'
        '- Both are configurable per cache; shorter active timeouts give '
        'finer resolution at the cost of more records.\n'
        'A flow shorter than the sampling interval may never be counted at '
        'all, and cache timeout values below the collector\'s aggregation '
        'window produce double counting. show flow monitor cache and the '
        'exporter statistics confirm what is actually leaving the device.',
  ),
  NetworkingFact(
    id: 'ntp-values',
    requires: [
      ['ntp'],
      ['stratum', 'port', 'version', 'poll', 'how often', 'interval', '123'],
    ],
    excludes: ['how many servers', 'server count'],
    answer:
        'NTP numbers worth knowing:\n'
        '- UDP 123, NTPv4 (RFC 5905).\n'
        '- Stratum 0 is the reference clock, stratum 1 is directly attached, '
        'and every hop adds one; stratum 16 means unsynchronised.\n'
        '- Default poll interval starts at 64 s and doubles as the clock '
        'stabilises, up to 1024 s.\n'
        '- Four sources is the usual minimum for a reliable majority vote; '
        'two is the minimum that can vote at all.\n'
        '- Cisco IOS does not serve time by default: ntp master is required '
        'to be a server, and the stratum you advertise is the configured one '
        'plus one.\n'
        'ntpq -p or chronyc sources shows the offset and the stratum in use.',
  ),
  NetworkingFact(
    id: 'bgp-communities',
    requires: [
      ['bgp', 'community'],
      [
        'well known',
        'well-known',
        'no-export',
        'no-advertise',
        '65535',
        '0:0',
        'no-peer',
      ],
    ],
    answer:
        'The well-known BGP communities every engineer should recognise:\n'
        '- 65535:65281 (NO_EXPORT): do not advertise outside the AS (or the '
        'confederation).\n'
        '- 65535:65282 (NO_ADVERTISE): do not advertise to any peer.\n'
        '- 65535:65283 (NO_EXPORT_SUBCONFED / LOCAL_AS): do not advertise '
        'outside the local AS.\n'
        '- 65535:65284 (NO_PEER): do not advertise to eBGP peers (RFC 3765).\n'
        '- 0:0 is the internet community, and a route without it has no '
        'transitive community.\n'
        'Your own communities are arbitrary 32-bit values, usually '
        'AS:function; the point is that they are a policy language and must be '
        'documented, or the next engineer cannot read the route map.',
  ),
  NetworkingFact(
    id: 'icmp-types',
    requires: [
      ['icmp'],
      ['type', 'code', 'unreachable', 'ttl exceeded', 'fragmentation', 'what'],
    ],
    excludes: ['icmpv6'],
    answer:
        'ICMP types that explain a failed path:\n'
        '- Type 3 destination unreachable: code 0 network, code 1 host, code '
        '3 port, code 4 fragmentation needed and DF set (the PMTUD signal), '
        'code 13 communication administratively prohibited (a firewall).\n'
        '- Type 11 time exceeded: code 0 TTL exceeded in transit, which is '
        'what traceroute prints as a hop.\n'
        '- Type 5 redirect, type 8/0 echo request/reply.\n'
        'If pings fail but TCP works, ICMP is being filtered somewhere - do '
        'not read that as reachability. If large packets fail while small '
        'ones pass, look for type 3 code 4 being dropped on the way back, '
        'which breaks PMTUD and stalls the transfer.',
  ),
  NetworkingFact(
    id: 'wifi-channels',
    requires: [
      ['wifi', 'wi-fi', 'wireless', '802.11', 'access point'],
      [
        'channel',
        'channels',
        'non-overlapping',
        'channel width',
        '5 ghz',
        '6 ghz',
        '2.4',
      ],
    ],
    excludes: ['speed', 'standard', 'ax', 'be'],
    priority: 2,
    answer:
        'Channel plan per band:\n'
        '- 2.4 GHz: 1, 6, 11 are the only non-overlapping 20 MHz channels in '
        'the Americas (1, 5, 9, 13 in ETSI). Use 20 MHz only - a 40 MHz 2.4 '
        'channel is a self-inflicted interference source.\n'
        '- 5 GHz: many non-overlapping 20/40/80 MHz channels; 80 MHz is for '
        'high-density video, 20/40 for coverage and reuse.\n'
        '- 6 GHz: 1200 MHz of spectrum, 14 extra 80 MHz channels, 160 MHz '
        'possible, no legacy interference - the cleanest band for Wi-Fi 6E/7.\n'
        'Leave auto-RF to pick channels only after the survey sets the design; '
        'show ap auto-rf and the controller channel plan prove what was '
        'chosen.',
  ),
  NetworkingFact(
    id: 'evpn-route-types',
    requires: [
      ['evpn', 'vxlan evpn'],
      ['route type', 'route types', 'type 1', 'type 2', 'type 5', 'types'],
    ],
    answer:
        'EVPN route types and what each one carries:\n'
        '- Type 1 Ethernet auto-discovery: multihoming and fast convergence.\n'
        '- Type 2 MAC/IP advertisement: the MAC and optionally the IP of a '
        'host, with the ESI and the label - the workhorse.\n'
        '- Type 3 inclusive multicast: the VTEP tunnel endpoints for a VNI, '
        'so head-end replication knows where to send Broadcast, Unknown '
        'unicast and Multicast traffic.\n'
        '- Type 4 Ethernet segment: the DF election for a multihomed segment.\n'
        '- Type 5 IP prefix: summarizes a subnet (inter-subnet routing without '
        'a MAC per host).\n'
        'show bgp l2vpn evpn prints them by type; a VNI with type 3 but no '
        'type 2 is a VNI where nobody has spoken yet.',
  ),
  NetworkingFact(
    id: 'isis-timers',
    requires: [
      ['isis', 'is-is', 'intermediate system'],
      ['timer', 'hello', 'lsp', 'lifetime', 'refresh', 'how long', 'interval'],
    ],
    answer:
        'IS-IS timers and lifetimes:\n'
        '- Hello: 10 s with a 30 s hold on broadcast and point-to-point; 3.3 s '
        'hello (10 s hold) with the faster profile.\n'
        '- LSP lifetime 1200 s with a refresh every 900 s, so a router '
        'refreshes well before expiry.\n'
        '- Zero-age lifetime 60 s is what a purge sets, and it is why a purge '
        'propagates further than a normal LSP.\n'
        '- CSNP every 10 s on a broadcast segment, which is how LSDB '
        'synchronisation is verified.\n'
        'show isis database detail prints each LSP with its remaining '
        'lifetime; a lifetime that keeps falling to zero without a refresh is '
        'a router that cannot flood.',
  ),
  NetworkingFact(
    id: 'dhcpv6-ports',
    requires: [
      ['dhcpv6', 'dhcp v6', 'ipv6 dhcp'],
      ['port', 'ports', '546', '547', 'udp'],
    ],
    answer:
        'DHCPv6 uses UDP 546 (client) and 547 (server and relay):\n'
        '- Solicit (client to server, multicast ff02::1:2), Advertise, Request, '
        'Reply - the four-message exchange (two if Rapid Commit is used).\n'
        '- Relay-forward and relay-reply carry the client message to a server '
        'that is not on the link, which is the equivalent of a DHCP relay.\n'
        '- Stateful DHCPv6 hands out addresses; stateless (SLAAC plus DHCPv6) '
        'hands out only options such as DNS.\n'
        'A firewall that permits DHCPv4 but not 546/547 is why IPv6 clients '
        'get an address from RA and still cannot resolve names.',
  ),
  NetworkingFact(
    id: 'ipv4-header',
    requires: [
      ['ipv4 header', 'ip header', 'header size', 'ip ttl'],
      ['size', 'bytes', 'ttl', 'what', 'how many', 'fields'],
    ],
    excludes: ['ipv6', 'tunnel'],
    answer:
        'The IPv4 header is 20 bytes with no options, 60 bytes maximum:\n'
        '- Version/IHL, DSCP/ECN, total length, identification, flags and '
        'fragment offset, TTL, protocol, header checksum, source, destination '
        '- then options.\n'
        '- TTL is a hop counter, not a timer: it is decremented at every '
        'router and the packet is dropped at zero (ICMP type 11 back).\n'
        '- The header checksum covers the header only, which is why NAT must '
        'recompute it.\n'
        'That 20 bytes is the constant in every MTU and MSS calculation: MSS = '
        'MTU - 40 for TCP over IPv4, and - 60 over IPv6.',
  ),
  NetworkingFact(
    id: 'bgp-convergence',
    requires: [
      ['bgp'],
      ['convergence', 'how long', 'time to converge', 'failover time', 'slow'],
    ],
    excludes: ['timer', 'keepalive'],
    priority: 1,
    answer:
        'BGP convergence is deliberately slow and the numbers are structural:\n'
        '- Default hold time 180 s, keepalive 60 s: a dead peer is detected in '
        'up to three keepalive intervals (180 s) unless BFD is used.\n'
        '- BFD with 300 ms x 3 brings detection to under a second.\n'
        '- MRAI (minimum route advertisement interval) defaults to 30 s for '
        'eBGP, 5 s for iBGP on some platforms, which spaces updates out.\n'
        '- Best-path selection runs per prefix; with a full table the SPF and '
        'the update generation dominate.\n'
        'Target sub-second failover with BFD plus precomputed backup paths '
        '(TI-LFA or a floating static), not by shrinking the hold timer to '
        'values the control plane cannot keep up with.',
  ),
  NetworkingFact(
    id: 'optics-reach',
    requires: [
      ['optics', 'sfp', 'qsfp', 'transceiver', 'fiber', 'fibre', 'dac'],
      ['how far', 'distance', 'reach', 'km', 'meters', 'metres', 'length'],
    ],
    excludes: ['cat5', 'cat6', 'cable category'],
    answer:
        'Reach by media, at the speed you actually run:\n'
        '- Passive DAC: about 3 m at 25G, 1-2 m at 100G, 5 m at 10G.\n'
        '- AOC: up to about 100 m depending on the module.\n'
        '- Multimode OM3/OM4 with 850 nm optics: 300/400 m at 10G, 100/150 m '
        'at 40G, 70/100 m at 100G (SR4).\n'
        '- Single-mode with 1310/1550 nm optics: 10 km (LR) to 40/80 km (ER/ZR '
        'and coherent).\n'
        'The optic, the fibre type, the connector and the FEC setting must all '
        'match; a link that trains but shows CRC errors is usually a reach or '
        'a dirty-connector problem, not a port failure.',
  ),
  NetworkingFact(
    id: 'wifi-roaming-times',
    requires: [
      ['roaming', 'roam', 'fast transition', '802.11r', 'okc'],
      ['time', 'how long', 'milliseconds', 'ms', 'fast', 'seamless', 'handoff'],
    ],
    answer:
        'Roaming times decide whether a call survives:\n'
        '- Full 802.1X reauthentication on roam: 300-800 ms, enough to drop a '
        'voice packet burst.\n'
        '- 802.11r fast transition: 50 ms or less, because the key is '
        'derived before the roam.\n'
        '- OKC (opportunistic key caching): 100-200 ms, vendor dependent.\n'
        '- CCKM on older Cisco gear: 50-100 ms.\n'
        'Voice needs under 150 ms of interruption to be tolerable. Design '
        'client roaming by cell overlap (15-20 percent) and then verify with '
        'the controller roam log, not with a ping.',
  ),
  NetworkingFact(
    id: 'ipv6-special-addresses',
    requires: [
      ['ipv6'],
      [
        'loopback',
        'unspecified',
        'link local',
        'link-local',
        'all routers',
        'all nodes',
        'special',
        '::1',
      ],
    ],
    excludes: ['subnet', 'plan', 'transition', 'nat'],
    answer:
        'The IPv6 addresses every engineer should be able to say from memory:\n'
        '- ::1/128 is the loopback (one address, not a whole /8).\n'
        '- ::/128 is the unspecified address, which is what a host uses as a '
        'source before it has one.\n'
        '- fe80::/10 is link local, automatically present on every interface '
        'and never routed.\n'
        '- ff02::1 all nodes on the link, ff02::2 all routers, ff02::1:2 all '
        'DHCPv6 servers and relays.\n'
        '- 2001:db8::/32 is documentation space, the IPv6 equivalent of RFC '
        '1918 that you use in examples.\n'
        '- fc00::/7 unique local (fc00::/8 and fd00::/8).\n'
        'There is no broadcast in IPv6: the all-nodes multicast is the '
        'replacement, which is why ARP is gone and ND does the work.',
  ),
  // __END__
];
