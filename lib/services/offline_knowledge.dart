import 'network_math.dart';
import 'network_tools.dart';

/// The offline brain: what this app can answer with NO model and NO API key.
///
/// The keyless chat used to cover only the planner plus a short concept list.
/// This table is the other half: the networking corpus people actually ask
/// about - concepts, configuration steps, verification, and the classic
/// faults - answered deterministically, with real IOS commands.
///
/// Two rules keep it honest:
///
/// * computed answers are really computed. Subnet facts, wildcard masks,
///   route summaries and reverse DNS come out of the same
///   [NetworkTools]/[NetworkMath] services the rest of the app trusts, so
///   the keyless answer and the offline tools can never disagree.
/// * a build request is never swallowed. Anything with device counts or a
///   build/setup ask is left to the planner ([answerFor] returns null).
///
/// Every topic is walked by `test/offline_intelligence_test.dart`, so
/// "answers everything offline" stays a measured claim: one entry in the
/// table plus its battery line.
class OfflineKnowledge {
  const OfflineKnowledge._();

  /// The answer for a question, or null when this table does not know it.
  static String? answerFor(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    // A build request is the planner's job, not a knowledge answer.
    if (_deviceCount.hasMatch(t)) return null;
    if (_buildAsk.hasMatch(t)) return null;
    for (final topic in _topics) {
      if (topic.match(t)) {
        final answer = topic.answer(t);
        if (answer != null && answer.trim().isNotEmpty) {
          return answer.trim();
        }
      }
    }
    return null;
  }

  // --- helpers -------------------------------------------------------------

  static bool _w(String t, String word) =>
      RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(t);

  static bool _has(String t, String phrase) => t.contains(phrase);

  static bool _any(String t, List<String> phrases) =>
      phrases.any((p) => t.contains(p));

  static bool _anyw(String t, List<String> words) =>
      words.any((w) => _w(t, w));

  static final RegExp _deviceCount = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
    r'printers?|phones?|firewalls?|tablets?)\b',
  );

  static final RegExp _buildAsk = RegExp(
    r'\b(?:build|set\s+up|setup|create|design|plan|make\s+me)\b',
  );

  static final RegExp _cidr = RegExp(
    r'\b\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2}\b',
  );

  static final RegExp _ip = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');

  static final RegExp _mask = RegExp(
    r'\b(?:255|254|252|248|240|224|192|128|0)(?:\.(?:255|254|252|248|240|224|'
    r'192|128|0)){3}\b',
  );

  static final RegExp _prefixOnly = RegExp(r'/\s*\d{1,2}\b');

  static List<String> _cidrs(String t) =>
      _cidr.allMatches(t).map((m) => m.group(0)!).toList();

  /// An IPv6 address with a prefix (contains colons - the v4 matchers above
  /// cannot produce a false positive here).
  static final RegExp _ipv6Cidr = RegExp(
    r'[0-9a-fA-F:]{3,45}\s*/\s*\d{1,3}\b',
  );

  /// The first "address/prefix" in the text, tightened to plain form.
  static String? _firstCidr(String t) {
    final m = _cidr.firstMatch(t);
    if (m == null) return null;
    final parts = m.group(0)!.split('/');
    return '${parts[0].trim()}/${parts[1].trim()}';
  }

  static int? _firstPrefix(String t) {
    final m = _prefixOnly.firstMatch(t);
    if (m == null) return null;
    final p = int.tryParse(m.group(0)!.substring(1).trim());
    return p == null || p < 0 || p > 32 ? null : p;
  }

  static String _maskFor(int prefix) => NetworkTools.prefixToMask(prefix);

  // --- topics --------------------------------------------------------------

  /// Narrow topics first: a message that mentions both a switchport mode and
  /// a VLAN should get the switchport answer, and so on.
  static final List<({bool Function(String) match, String? Function(String) answer})>
      _topics = [
    // IPv6 address facts - computed on the same deterministic pattern as the
    // IPv4 side: "what is the network of 2001:db8::1/64".
    (
      match: (t) => _ipv6Cidr.hasMatch(t),
      answer: (t) {
        final m = _ipv6Cidr.firstMatch(t);
        if (m == null || !m.group(0)!.contains(':')) return null;
        final facts = NetworkMath.ipv6Facts(m.group(0)!);
        if (facts == null) return null;
        return 'For ${m.group(0)}:\n'
            '- Network: ${facts.$1}\n'
            '- First address: ${facts.$2}\n'
            '- Last address: ${facts.$3}\n'
            '- Addresses: ${facts.$4}';
      },
    ),
    // Computed subnet facts: "broadcast address of 192.168.10.5/26".
    (
      match: (t) =>
          _cidr.hasMatch(t) &&
          _anyw(t, const [
            'broadcast',
            'subnet',
            'mask',
            'network',
            'first',
            'last',
            'usable',
            'hosts',
            'range',
            'gateway',
            'belong',
            'addresses',
          ]) &&
          !_any(t, const ['add ', 'assign', 'configure', 'create']),
      answer: (t) {
        final cidr = _firstCidr(t);
        if (cidr == null) return null;
        final info = NetworkTools.subnet(cidr);
        if (info == null) return null;
        final b = StringBuffer('For $cidr:');
        b.write('\n- Network address: ${info.network}/${info.prefix}');
        b.write(
          '\n- Subnet mask: ${_maskFor(info.prefix)}'
          '${info.prefix >= 31 ? '' : ''}',
        );
        b.write('\n- Broadcast address: ${info.broadcast}');
        if (info.prefix >= 31) {
          b.write(
            '\n- Both addresses are usable on a /${info.prefix} '
            'point-to-point link.',
          );
        } else {
          b.write(
            '\n- First usable: ${info.firstHost}  -  last usable: '
            '${info.lastHost}',
          );
          b.write('\n- Usable hosts: ${info.usableHosts} '
              '(of ${info.totalAddresses} addresses)');
        }
        return b.toString();
      },
    ),
    // "how many hosts does a /28 have" - count only.
    (
      match: (t) =>
          RegExp(r'\bhow\s+many\b').hasMatch(t) &&
          _prefixOnly.hasMatch(t) &&
          _anyw(t, const ['hosts', 'addresses', 'usable', 'ips']),
      answer: (t) {
        final p = _firstPrefix(t);
        if (p == null) return null;
        final total = p >= 31 ? 1 << (32 - p) : 1 << (32 - p);
        final usable = p >= 31 ? total : total - 2;
        return 'A /$p has $total addresses and $usable usable host(s) '
            '(network and broadcast are reserved${p >= 31 ? ' - not on a /$p' : ''}). '
            'Mask: ${_maskFor(p)}.';
      },
    ),
    // "wildcard mask for 255.255.255.224" / "wildcard for /27".
    (
      match: (t) => _has(t, 'wildcard'),
      answer: (t) {
        var prefix = _firstPrefix(t);
        if (prefix == null) {
          final m = _mask.firstMatch(t);
          if (m != null) prefix = NetworkMath.prefixFromMask(m.group(0)!);
        }
        if (prefix == null) {
          return 'A wildcard mask is an inverted subnet mask: where the '
              'subnet mask has 1s, the wildcard has 0s and must match, and '
              'where it has 0s the wildcard can be anything. 0.0.0.255 means '
              '"any host in this /24" - the classic ACL line '
              '`permit 192.168.10.0 0.0.0.255`. Ask me for "wildcard for '
              '/27" or "wildcard for 255.255.255.224" and I will compute it.';
        }
        final wildcard = NetworkMath.wildcardFromPrefix(prefix);
        return 'For /$prefix (mask ${_maskFor(prefix)}) the wildcard mask is '
            '$wildcard - e.g. `permit any host ... $wildcard` in an ACL.';
      },
    ),
    // "summarize 10.10.0.0/25 and 10.10.0.128/25".
    (
      match: (t) =>
          _any(t, const ['summari', 'aggregat', 'supernet', 'summary route']),
      answer: (t) {
        final cidrs = _cidrs(t);
        if (cidrs.length >= 2) {
          final summary = NetworkMath.summarize(cidrs);
          return 'Summarized: ${summary.join(', ')}\n'
              'Check it covers every original network before you use it in a '
              '`network` statement or a static summary route.';
        }
        return 'Route summarization replaces several contiguous networks with '
            'one that covers them all: 10.10.0.0/25 + 10.10.0.128/25 can be '
            'advertised as 10.10.0.0/24. Size it by finding the number of '
            'matching leading bits. Give me two networks ("summarize '
            '10.10.0.0/25 and 10.10.0.128/25") and I will compute it.';
      },
    ),
    // "reverse dns for 192.168.1.10".
    (
      match: (t) =>
          _any(t, const ['reverse dns', 'in-addr', 'ptr record', 'ptr ']),
      answer: (t) {
        final m = _ip.firstMatch(t);
        if (m == null) {
          return 'Reverse DNS maps an address back to a name through the '
              'in-addr.arpa zone: 192.168.1.10 becomes '
              '10.1.168.192.in-addr.arpa (octets reversed). Give me an '
              'address and I will build the name.';
        }
        final ip = m.group(0)!;
        return '${NetworkMath.reverseDnsName(ip)} - that is the PTR name for '
            '$ip. In Packet Tracer, add it on the DNS server as a record of '
            'type A with the host\'s name so lookups resolve.';
      },
    ),
    // Connectivity faults: "cannot ping", "request timed out".
    (
      match: (t) =>
          _any(t, const [
            'cannot ping',
            "can't ping",
            'cant ping',
            'cannot reach',
            "can't reach",
            'ping fails',
            'ping failed',
            'not pinging',
            'request timed out',
            'destination host unreachable',
            'no connectivity',
            'unreachable',
            'connection timed out',
            'not connecting',
            'does not connect',
            'cannot connect',
          ]),
      answer: (t) => 'Work up the stack, one check per layer:\n'
          '1. Link: interface up and up (`show ip interface brief`), correct '
          'cable (straight to switch, crossover between like devices), both '
          'ends in the same VLAN.\n'
          '2. Addressing: IP, mask and gateway on both ends - a wrong mask '
          'sends echo requests to the wrong place. Ping your own gateway '
          'first, then the far host.\n'
          '3. Routing: if the ping crosses a router, both sides need routes '
          '(`show ip route`). No route = "destination host unreachable" from '
          'the last router.\n'
          '4. Filtering: an ACL in the path drops silently ("request timed '
          'out") unless it is set to log. Check both directions.\n'
          '5. NAT/edge: inside addresses do not cross a WAN without NAT.\n'
          'Tell me the exact command, the error text and where you ran it and '
          'I will narrow it down.',
    ),
    // "how do I ping" / "test connectivity".
    (
      match: (t) => _any(t, const [
        'how do i ping',
        'how to ping',
        'ping test',
        'test connectivity',
        'check connectivity',
        'use ping',
      ]),
      answer: (t) => 'On a PC in Packet Tracer: Desktop > Command Prompt, then '
          '`ping <address>`. Ping your own address (proves the stack), then '
          'the default gateway (proves the LAN), then the far side (proves '
          'routing). On a router: `ping 192.168.10.10` and use the extended '
          'form (source interface) when testing a specific path. First ping '
          'may time out while ARP resolves - run it twice.',
    ),
    // traceroute.
    (
      match: (t) => _any(t, const ['traceroute', 'tracert', 'trace route']),
      answer: (t) => '`traceroute` (tracert on Windows) lists every router a '
          'packet crosses: each line is one hop with three round-trip times. '
          'Read it as a map: where replies start failing is where the path '
          'breaks - the last responding router is usually the one that has no '
          'route back. `* * *` alone can just mean that router does not reply '
          'to probes while still forwarding traffic.',
    ),
    // ARP.
    (
      match: (t) => _w(t, 'arp') || _has(t, 'show arp'),
      answer: (t) => 'ARP maps an IP to the MAC on the local segment: the '
          'sender broadcasts "who has 192.168.1.1?" and the owner answers. If '
          'ARP fails, nothing on the LAN can talk - check `show arp` for the '
          'entry, that both devices share a VLAN, and clear a stale entry with '
          '`clear arp-cache`. A MAC that keeps flapping is a loop or a '
          'duplicate address; check with `show mac address-table`.',
    ),
    // Serial / clocking.
    (
      match: (t) => _any(t, const [
        'clock rate',
        'dce',
        'dte',
        'back-to-back',
        'back to back',
        'serial link',
        'serial cable',
        'lease line',
        'leased line',
      ]),
      answer: (t) => 'A serial link needs the cable\'s DCE end to supply '
          'clocking: on that side the interface gets `clock rate 64000` '
          '(DTE side gets none). Check the end with `show controllers '
          'serial0/0/0` - it names DCE or DTE. If both ends are right but the '
          'line stays down, the cable must be serial DCE-to-DTE, not '
          'DCE-to-DCE. In this app, say "serial WAN" in the request and the '
          'plan fits the module and sets the clocking end itself.',
    ),
    // Cabling.
    (
      match: (t) => _any(t, const [
        'which cable',
        'what cable',
        'crossover',
        'straight-through',
        'straight through',
        'rollover',
        'roll-over',
        'console cable',
        'cable type',
      ]),
      answer: (t) => 'Cable cheat sheet: **straight-through** between unlike '
          'devices (PC/switch, switch/router). **Crossover** between like '
          'devices (switch-switch, PC-PC, router-router). **Console '
          '(rollover)** from a PC to the console port for out-of-band CLI. '
          'Automatic MDI/MDIX on modern switches hides a wrong choice, but '
          'Packet Tracer will show the link red if you pick badly - use '
          'crossover between switches.',
    ),
    // SSH.
    (
      match: (t) => _w(t, 'ssh') || _has(t, 'secure shell'),
      answer: (t) => 'SSH on a Cisco device, in order:\n'
          '1. `hostname R1` and `ip domain-name lab.local`\n'
          '2. `crypto key generate rsa` (1024 or 2048 bits)\n'
          '3. `username admin secret <password>`\n'
          '4. `line vty 0 4` > `transport input ssh` > `login local`\n'
          '5. Verify: `show ip ssh`. SSH beats Telnet because the whole '
          'session is encrypted - keep Telnet off unless a lab requires it.',
    ),
    // Port security.
    (
      match: (t) =>
          _has(t, 'port security') || _has(t, 'port-security') || _has(t, 'sticky mac'),
      answer: (t) => 'Port security on an access port:\n'
          '1. `interface f0/2` > `switchport mode access`\n'
          '2. `switchport port-security`\n'
          '3. `switchport port-security maximum 1`\n'
          '4. `switchport port-security mac-address sticky`\n'
          '5. `switchport port-security violation shutdown` (or restrict)\n'
          'Verify with `show port-security interface f0/2`. Once the port is '
          'down from a violation, `shutdown` + `no shutdown` brings it back.',
    ),
    // DHCP snooping.
    (
      match: (t) => _has(t, 'snooping'),
      answer: (t) => 'DHCP snooping blocks rogue DHCP servers:\n'
          '1. `ip dhcp snooping` (global)\n'
          '2. `ip dhcp snooping vlan 10`\n'
          '3. On all UPLINK/trusted ports: `ip dhcp snooping trust`\n'
          'User ports stay untrusted and drop server replies. Verify with '
          '`show ip dhcp snooping`. The trust goes on the port toward the '
          'real DHCP server or router - put it on user ports and the '
          'protection is gone.',
    ),
    // HSRP / VRRP.
    (
      match: (t) =>
          _anyw(t, const ['hsrp', 'vrrp', 'glbp']) ||
          _has(t, 'gateway redundancy') ||
          _has(t, 'first hop redundancy'),
      answer: (t) => 'HSRP gives hosts one virtual gateway held by two '
          'routers: `interface g0/1` > `standby 10 ip 192.168.10.254` on both '
          'routers, `standby 10 priority 150` + `standby 10 preempt` on the '
          'preferred one. Hosts point at .254 and never see the failover. '
          'VRRP is the same idea with `vrrp 10 ip` and is multi-vendor.',
    ),
    // Static routes.
    (
      match: (t) => _has(t, 'static route') || _has(t, 'ip route'),
      answer: (t) => 'Static route syntax: `ip route <network> <mask> '
          '<next-hop|exit-interface>`. Example: `ip route 192.168.20.0 '
          '255.255.255.0 10.0.0.2`. The default route is `ip route 0.0.0.0 '
          '0.0.0.0 <next-hop>`. Verify with `show ip route` (S = static, '
          '* = candidate default); ping the far network to prove it works.',
    ),
    // Gateway basics.
    (
      match: (t) =>
          (_w(t, 'gateway') || _has(t, 'default gateway')) &&
          !_has(t, 'last resort') &&
          !_has(t, 'gateway of last'),
      answer: (t) => 'The default gateway is the router address a host sends '
          'non-local traffic to. On a PC it is set with the IP (Desktop > IP '
          'Configuration in Packet Tracer, or DHCP hands it out); on the '
          'router it is the default route `ip route 0.0.0.0 0.0.0.0 '
          '<next-hop>`. If a host can ping its own subnet but nothing else, '
          'the gateway is the first thing to check.',
    ),
    // Saving config.
    (
      match: (t) =>
          _any(t, const [
            'write memory',
            'copy running',
            'copy run',
            'startup-config',
            'save configuration',
            'save the config',
            'save my config',
          ]) ||
          (_w(t, 'save') && _w(t, 'config')),
      answer: (t) => 'Make the config survive a reload: `copy running-config '
          'startup-config` (older IOS: `write memory`). Short form on exams: '
          '`copy run start`. Check with `show startup-config`. In the app, '
          'the executor performs the analogous save of the .pkt file - and a '
          'saved file beats a running-only one every time.',
    ),
    // PT file saving.
    (
      match: (t) =>
          _w(t, 'save') &&
          (_has(t, 'my work') || _has(t, 'my file') || _has(t, 'packet tracer') || _has(t, 'the file')),
      answer: (t) => 'To keep your Packet Tracer work: Ctrl+S (or File > '
          'Save As) writes the .pkt - save it with a name you will recognise. '
          'In this app you can also press "Build the .pkt": it compiles the '
          'plan you discussed into a real file offline, and you can reopen or '
          'audit it later.',
    ),
    // Show / verify commands.
    (
      match: (t) => _any(t, const [
        'show commands',
        'which command',
        'what command',
        'commands to check',
        'commands to verify',
        'how do i verify',
        'how to verify',
        'check the config',
        'verify the config',
        'commands list',
      ]),
      answer: (t) => 'Verification cheat sheet:\n'
          '- Interfaces: `show ip interface brief` (`up/up` is the goal)\n'
          '- MAC/VLAN: `show mac address-table`, `show vlan brief`\n'
          '- Routing: `show ip route`, `show ip protocols`\n'
          '- OSPF: `show ip ospf neighbor` (want FULL)\n'
          '- Switch security: `show port-security`, `show ip dhcp snooping`\n'
          '- Save state: `show startup-config`\n'
          'Run one command per layer and move up only when the layer below '
          'is proven.',
    ),
    // Duplex / speed.
    (
      match: (t) =>
          _anyw(t, const ['duplex', 'half-duplex']) ||
          _has(t, 'speed mismatch') ||
          _has(t, 'auto-negotiat'),
      answer: (t) => 'A duplex mismatch looks like bad ping numbers: some '
          'pings fine, throughput terrible, late collisions on one side '
          '(`show interfaces` - FCS/CRC and late collision counters climb). '
          'Fix: leave both ends on auto, or set both ends to the same fixed '
          'speed and duplex - never one fixed, one auto.',
    ),
    // Red link in Packet Tracer.
    (
      match: (t) => _any(t, const [
        'red link',
        'red triangle',
        'link is red',
        'link light',
        'no link',
        'link down',
        'link is down',
        'circle is red',
      ]),
      answer: (t) => 'A red link in Packet Tracer means the physical layer '
          'never came up:\n'
          '1. Wrong cable - crossover for like devices (switch-switch, '
          'router-router), straight for unlike.\n'
          '2. Right port type - Serial needs serial ports (fit the HWIC-2T '
          'with the router powered off first).\n'
          '3. Port shut or line protocol down - `no shutdown` on both ends; '
          'serial also needs clocking on the DCE end.\n'
          '4. Speed/duplex fixed on one side only.\n'
          'Right-click the link to check what it is, and hover the red '
          'marker - it names the reason.',
    ),
    // Switchport modes / DTP.
    (
      match: (t) => _any(t, const [
        'switchport mode',
        'dtp',
        'dynamic auto',
        'dynamic desirable',
        'switchport access',
      ]),
      answer: (t) => 'Port modes: `switchport mode access` pins a port to one '
          'VLAN (use `switchport access vlan 10` to choose it); `switchport '
          'mode trunk` carries many. Leaving ports on dynamic (DTP) lets '
          'switch-to-switch links negotiate and is the root of many lab '
          'surprises - set both ends explicitly, and `switchport nonegotiate` '
          'disables DTP on a trunk.',
    ),
    // MAC table.
    (
      match: (t) => _any(t, const [
        'mac address-table',
        'mac address table',
        'mac table',
        'mac learning',
        'show mac',
      ]),
      answer: (t) => 'Switches learn source MACs per port: `show mac '
          'address-table` lists MAC -> port -> VLAN. Use it to find where a '
          'device hangs, to spot a MAC appearing on two ports (loop or '
          'duplicate), and - with port security - to see a violated port. A '
          'stale entry ages out in 300 seconds by default.',
    ),
    // Wireless security.
    (
      match: (t) =>
          _anyw(t, const ['wpa', 'wpa2', 'wep']) ||
          _has(t, 'wireless security') ||
          _has(t, 'secure the wifi') ||
          _has(t, 'secure wi-fi'),
      answer: (t) => 'On the AP in Packet Tracer: Config tab > Port 1 > set '
          'the SSID, then Wireless Security: WPA2-Personal with a passphrase '
          'is the normal choice (WEP is what old labs ask for but it is '
          'broken by design). Clients then pick the SSID and type the same '
          'passphrase. If the client will not associate, the passphrase and '
          'the security mode must match exactly on both sides.',
    ),
    // WLC.
    (
      match: (t) =>
          _has(t, 'wireless controller') ||
          _has(t, 'wireless lan controller') ||
          _w(t, 'wlc'),
      answer: (t) => 'A WLC centralises the wireless: APs join it (lightweight '
          'mode) and every SSID/WLAN lives on the controller. In Packet '
          'Tracer: give the WLC its management address, create the WLAN with '
          'the SSID and security, then let APs register. If an AP shows '
          'standalone, it never joined - check the management VLAN and the '
          'link between AP and controller.',
    ),
    // Server panels.
    (
      match: (t) =>
          _anyw(t, const [
            'http',
            'https',
            'ftp',
            'email',
            'smtp',
            'ntp',
            'tftp',
            'syslog',
            'iot',
          ]) &&
          _w(t, 'server'),
      answer: (t) => 'Server services live on the Server-PT Services tab - '
          'enable the service, then fill its panel:\n'
          '- HTTP/HTTPS: enable, edit the index page to your text.\n'
          '- FTP: add users (user/password) and permissions.\n'
          '- Email: set the domain, add users; mail clients then use that '
          'server as both SMTP and POP3.\n'
          '- NTP/TFTP/Syslog: enable, then point clients/devices at this '
          'server\'s address.\n'
          'Remember to give the server a static address on the right VLAN '
          'first - services with a 0.0.0.0 address never answer.',
    ),
    // Packet Tracer basics.
    (
      match: (t) => _any(t, const [
        'add a device',
        'place a device',
        'add devices',
        'place devices',
        'connect two devices',
        'how do i connect devices',
        'start in packet tracer',
        'new to packet tracer',
        'how do i add',
      ]),
      answer: (t) => 'Packet Tracer in five moves: pick the device group at '
          'the bottom-left (Routers/Switches/End Devices), drag the model to '
          'the canvas, choose Connections for the cable (straight for '
          'unlike, crossover for like, console for CLI-from-PC), click the '
          'two ends, then click the device and use the CLI or Desktop tabs. '
          'Hover any red marker for the failure reason. Or just tell me the '
          'lab - I plan and compile all of this into a .pkt offline.',
    ),
    // Wireless client.
    (
      match: (t) => _any(t, const [
        'join the wifi',
        'join wi-fi',
        'connect to the wifi',
        'connect to wi-fi',
        'wireless client',
        'laptop to wifi',
        'pc to wifi',
        'tablet to wifi',
      ]),
      answer: (t) => 'To join a wireless client in Packet Tracer: click the '
          'device > Desktop > PC Wireless > Connect tab, pick the SSID, enter '
          'the passphrase for WPA2 (or the WEP key). The AP must be powered '
          'and its wireless port configured first; a client that never '
          'appears in the AP\'s association list is out of range or using '
          'the wrong security mode.',
    ),
    // ipconfig / finding a PC's IP.
    (
      match: (t) => _any(t, const [
        'ipconfig',
        'check my ip',
        'what is my ip',
        'find my ip',
        'ip address of',
        'mac address of',
        'find the mac',
        '169.254',
      ]),
      answer: (t) => 'On a PC in Packet Tracer: Desktop > Command Prompt > '
          '`ipconfig` (or `ipconfig /all` for the MAC and DNS). The same '
          'values are editable under Desktop > IP Configuration - static '
          'address + mask + gateway, or switch it to DHCP and let the pool '
          'answer. A 169.254.x.x address means DHCP never answered.',
    ),
    // Loopback.
    (
      match: (t) =>
          _w(t, 'loopback') || _has(t, 'loopback0') || _has(t, 'loopback 0'),
      answer: (t) => 'A loopback is a virtual interface that never goes '
          'down: `interface loopback0` > `ip address 10.255.255.1 '
          '255.255.255.255`. Routers use one as the OSPF/BGP router-id, for '
          'management reachability, and to keep a stable anchor when physical '
          'links flap.',
    ),
    // VPN / IPsec.
    (
      match: (t) =>
          _w(t, 'vpn') || _has(t, 'ipsec') || _has(t, 'site-to-site'),
      answer: (t) => 'A site-to-site IPsec VPN joins two LANs across an '
          'untrusted link: interesting traffic triggers IKE (isakmp policy + '
          'pre-shared key), then IPsec (transform-set aes/sha) protects it, '
          'and a crypto map applies it to the WAN interface. Both routers '
          'need mirror settings and each other\'s subnets. One Packet Tracer '
          'caveat: a stock ISR image rejects crypto commands until the '
          'Security Technology package is licensed - the app\'s validator '
          'reports that block as skipped instead of pretending it worked.',
    ),
    // VLSM.
    (
      match: (t) => _has(t, 'vlsm'),
      answer: (t) => 'VLSM sizes each subnet to its need instead of forcing '
          'all /24s: sort requirements largest-first, allocate from the top '
          'of the block, and each next subnet starts where the last one '
          'ends. Example in 192.168.10.0/24: 100 hosts -> /25 (.0-.127), 50 '
          '-> /26 (.128-.191), 20 -> /27 (.192-.223), point-to-point -> /30. '
          'The tool in this app (Network toolkit > VLSM) does the allocation '
          'for you.',
    ),
    // Subnetting method.
    (
      match: (t) =>
          _w(t, 'subnetting') ||
          _has(t, 'how to subnet') ||
          _has(t, 'split a /24') ||
          _has(t, 'split a /16'),
      answer: (t) => 'Subnetting is borrowing host bits: each borrowed bit '
          'doubles the subnets and halves the hosts. From /24: /25 = 2 '
          'subnets of 126 hosts, /26 = 4 of 62, /27 = 8 of 30, /28 = 16 of '
          '14, /30 = 64 point-to-point links of 2. The block size of the '
          'interesting octet is 256 minus the mask value (mask 192 -> blocks '
          'of 64), and subnets step by that number. Ask me "broadcast of '
          '192.168.10.5/26" or "wildcard for /27" and I will compute it.',
    ),
    // Router-on-a-stick.
    (
      match: (t) => _any(t, const [
        'router-on-a-stick',
        'router on a stick',
        'subinterface',
        'sub-interface',
      ]),
      answer: (t) => 'Router-on-a-stick: one router uplink carries all VLANs '
          'as a trunk; the router uses a sub-interface per VLAN: `interface '
          'g0/1.10` > `encapsulation dot1q 10` > `ip address 192.168.10.1 '
          '255.255.255.0`. The switch port toward the router is `switchport '
          'mode trunk`. Each VLAN\'s PCs use their sub-interface address as '
          'the gateway.',
    ),
    // Inter-VLAN routing.
    (
      match: (t) =>
          _has(t, 'inter-vlan') || _has(t, 'intervlan') || _has(t, 'vlan routing'),
      answer: (t) => 'Two ways to route between VLANs: router-on-a-stick (a '
          'trunk to a router with a dot1Q sub-interface per VLAN) or a '
          'layer-3 switch (SVIs: create `interface vlan 10`, give it an '
          '`ip address`, then enable `ip routing`). Router-on-a-stick is the '
          'classic Packet Tracer answer; an L3 switch is the campus answer. '
          'Either way every VLAN needs its own subnet, and each host\'s '
          'gateway is the router or SVI address on its own VLAN.',
    ),
    // OSPF authentication.
    (
      match: (t) => _any(t, const [
        'ospf authentication',
        'ospf auth',
        'message-digest',
        'md5 auth',
      ]),
      answer: (t) => 'OSPF MD5 authentication: `interface g0/0` > `ip ospf '
          'message-digest-key 1 md5 <key>`, then under `router ospf 1` > '
          '`area 0 authentication message-digest`. Both neighbors must use '
          'the same key id and key or the adjacency never leaves INIT. '
          'Verify with `show ip ospf interface g0/0`.',
    ),
    // OSPF adjacency faults.
    (
      match: (t) => _any(t, const [
        'ospf neighbor',
        'adjacency',
        'stuck in',
        'two-way state',
        'exstart',
        'ospf not forming',
        'ospf is not forming',
        'neighbor state',
      ]),
      answer: (t) => 'OSPF adjacency states and what they mean: DOWN/INIT = '
          'hellos not heard or one-way (area/Hello/authentication mismatch, '
          'ACL, NBMA); 2-WAY = normal on broadcast between non-DRs, a fault '
          'on point-to-point; EXSTART/EXCHANGE stuck = MTU mismatch; '
          'LOADING = dropped LSAs. `show ip ospf neighbor` shows the state '
          'and the dead timer - a dead timer climbing to 40s with no FULL '
          'means hellos are lost, not that OSPF dislikes you.',
    ),
    // Access security basics.
    (
      match: (t) => _any(t, const [
        'enable secret',
        'enable password',
        'console password',
        'vty password',
        'set a password',
        'set passwords',
        'telnet password',
        'secure the router',
        'secure the switch',
      ]),
      answer: (t) => 'Locking down device access:\n'
          '1. `enable secret <password>` (hashed; prefer over `enable '
          'password`)\n'
          '2. `line console 0` > `password <password>` > `login`\n'
          '3. `line vty 0 4` > `password <password>` > `login` - or better, '
          '`transport input ssh` + `login local` with a `username`.\n'
          '4. `service password-encryption` hides the plaintext lines.\n'
          'And a banner: `banner motd #Authorised access only#`.',
    ),
    // Hostname.
    (
      match: (t) => _any(t, const [
        'change the hostname',
        'set the hostname',
        'rename the router',
        'rename the switch',
      ]),
      answer: (t) => 'From privileged mode: `configure terminal`, then '
          '`hostname R1` (applies immediately), then `end`. The prompt '
          'changes with it. For domain-dependent features (SSH), also set '
          '`ip domain-name lab.local`.',
    ),
    // STP root selection.
    (
      match: (t) =>
          _any(t, const ['root bridge', 'root primary', 'root secondary']) ||
          _has(t, 'stp root'),
      answer: (t) => 'Spanning tree picks the root by lowest priority then '
          'lowest MAC. To choose it yourself: `spanning-tree vlan 10 root '
          'primary` on the intended core switch (and `root secondary` on the '
          'backup). Verify with `show spanning-tree vlan 10` - "This bridge '
          'is the root" should appear exactly where you want it.',
    ),
    // DHCP relay.
    (
      match: (t) =>
          _has(t, 'ip helper-address') ||
          _has(t, 'dhcp relay') ||
          _has(t, 'relay agent'),
      answer: (t) => 'A router does not forward broadcasts, so a DHCP server '
          'on another subnet is reached with a relay: on the LAN interface '
          'facing the clients, `ip helper-address <server-address>`. The '
          'request is unicast to the server, which replies to the giaddr. '
          'Verify with `show ip interface` (helper listed) and the pool\'s '
          'scope - the pool must match the interface\'s subnet.',
    ),
    // --- design judgment: why, not just how -----------------------------
    // A seasoned engineer gives a recommendation WITH its trade-off.  These
    // answers are opinions grounded in how the protocols actually behave, so
    // they stay honest: each names when the choice is wrong, not only when it
    // is right.
    (
      match: (t) =>
          (_has(t, 'ospf') && _any(t, ['or ', 'versus', ' vs ', 'instead']) &&
              _has(t, 'eigrp')) ||
          _has(t, 'ospf or eigrp') ||
          _has(t, 'eigrp or ospf'),
      answer: (t) => 'OSPF or EIGRP - both are link-state-ish, both converge '
          'fast, so neither is "better" in the abstract. Choose OSPF when you '
          'need standards-based, multi-vendor, hierarchical areas, or an '
          'open protocol some auditor will ask about. Choose EIGRP when the '
          'whole network is Cisco and you want simpler summarisation and '
          'unequal-cost load balancing, and you accept the vendor lock-in. '
          'For a Packet Tracer lab: OSPF area 0 is the safer teaching choice '
          'because it transcribes to almost any vendor you meet later.',
    ),
    (
      match: (t) =>
          _anyw(t, ['transit', 'wan']) &&
          (_has(t, '/30') || _has(t, '/31') ||
              _anyw(t, ['point-to-point', 'p2p'])),
      answer: (t) => 'Point-to-point transit links: use a /31 rather than a /30 '
          'when both ends support it (RFC 3021, IOS 12.2+). A /31 wastes zero '
          'addresses - both addresses are usable - where a /30 burns two of '
          'its four on network and broadcast. The catch: a /31 only works on '
          'a true point-to-point link, so on an Ethernet segment with more '
          'than two devices you must fall back to a /30 or larger. Many '
          'judges and old blueprints still expect /30, so know both.',
    ),
    (
      match: (t) =>
          _has(t, 'management') &&
          (_has(t, 'vlan') || _has(t, 'vlans')) &&
          _anyw(t, ['why', 'should', 'best', 'separate', 'dedicated', 'own']),
      answer: (t) => 'Put management in its own VLAN, never VLAN 1 and never '
          'a user VLAN. Three concrete reasons: (1) VLAN 1 carries CDP, '
          'VTP, DTP and STP for the whole switch - putting SVI management '
          'traffic there mixes control-plane and management-plane traffic; '
          '(2) a user VLAN means a user can become the management gateway, '
          'so an ACL that protects one VLAN cannot protect the other; '
          '(3) an out-of-band or dedicated management VLAN lets you shut a '
          'user VLAN entirely without losing the ability to reach the device '
          'and fix it. Use a high, unused VLAN (e.g. 99) and an ACL that '
          'permits only the management hosts.',
    ),
    (
      match: (t) =>
          _has(t, 'vlan 1') &&
          _anyw(t, ['why', 'not', 'avoid', 'bad', 'shouldn']),
      answer: (t) => 'Avoid carrying user traffic on VLAN 1 because it is the '
          'default and cannot be deleted: a new, unconfigured port lands in '
          'it automatically, so an unnoticed patch can bridge a user into '
          'it; it is the default native VLAN, so untagged frames leak across '
          'a trunk; and it carries control protocols (CDP/VTP/DTP/STP). '
          'Best practice: move user traffic to a real VLAN, set a dedicated '
          'native VLAN (e.g. 999), and shut any unused ports into it.',
    ),
    (
      match: (t) =>
          _has(t, 'adjust-mss') || _has(t, 'tcp adjust mss') ||
          (_has(t, 'gre') && _has(t, 'mss')) ||
          _has(t, 'packet too big'),
      answer: (t) => 'Tunnel overhead breaks TCP: a GRE tunnel adds 24 bytes '
          '(IP+GRE) so a 1500-byte frame no longer fits the underlying MTU, '
          'and a host that cannot fragment a large TCP segment hangs on big '
          'transfers (small pings work, the web page does not). The fix is on '
          'the LAN interface or the tunnel: `ip tcp adjust-mss 1400`, which '
          'rewrites the MSS in the SYN so both ends size their segments to '
          'fit. Use 1400 for GRE+IPsec, 1436 for plain GRE, always padding '
          'for the tunnel header you actually use.',
    ),
    (
      match: (t) =>
          _anyw(t, ['eigrp', 'ospf', 'bgp', 'static']) &&
          _anyw(t, ['when', 'which', 'choose', 'pick', 'recommend', 'best']),
      answer: (t) => 'Routing protocol, in one line each: STATIC when the '
          'topology is small and stable and you want zero protocol overhead '
          '(but every change is manual and a typo black-holes a subnet); OSPF '
          'when you want open, standards-based, hierarchical scaling with '
          'areas and fast convergence; EIGRP when it is all Cisco and you '
          'want the simplest large-network convergence; BGP only where you '
          'must - between autonomous systems or where policy, not just '
          'reachability, is the point. For labs, static for two routers and '
          'OSPF the moment a third path appears.',
    ),
  ];
}
