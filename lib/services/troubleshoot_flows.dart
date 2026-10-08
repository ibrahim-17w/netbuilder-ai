import 'casual_english.dart';

/// Interactive troubleshooting flows: deterministic, multi-turn diagnostic
/// dialogues driven entirely by quick-reply taps. The assistant asks what a
/// verification command shows, the user taps the answer, the flow branches
/// and ends in a fix. No model, no plan needed - the ladder IS the
/// intelligence, and every branch ends in a fix so nothing dead-ends.
///
/// State is a JSON-serializable map of primitives ({'flow', 'step',
/// 'data'}) because it persists inside [SessionState.flowState] and must
/// survive a conversation reopen.
///
/// The parent wires these into the offline assistant: [matchStart] opens a
/// flow on a symptom, [TroubleshootFlowEngine.advance] continues one, and
/// the assistant renders [FlowTurn.options] as the turn's quick replies.
class FlowOption {
  /// What the chip shows - also what the user's message looks like when
  /// they tap it.
  final String label;

  /// What the step machine switches on.
  final String value;

  const FlowOption(this.label, this.value);
}

class FlowTurn {
  /// What the assistant asks now (or says, when [done]).
  final String prompt;

  /// The tappable answers; empty on the final turn.
  final List<FlowOption> options;

  /// True on the final turn - the parent ends (and clears) the flow.
  final bool done;

  /// The final, self-contained fix text (commands + one-line why). Set
  /// only when [done].
  final String? fix;

  /// The state to persist after this turn.
  final Map<String, dynamic> state;

  const FlowTurn({
    required this.prompt,
    this.options = const [],
    this.done = false,
    this.fix,
    required this.state,
  });
}

class TroubleshootFlows {
  const TroubleshootFlows._();

  /// The flow this symptom opens, or null. Canonicalization runs first so
  /// the full-name and paraphrase layer feeds the match ("no internet
  /// access" arrives as 'no connectivity'), but the RAW words decide WHICH
  /// flow: 'no internet' and 'no connectivity' both canonicalize to the
  /// same string, and they are different diagnoses.
  ///
  /// A symptom that NAMES ITS TARGET ("cannot ping the gateway", an IP
  /// address, "PC1 cannot ping PC2") returns null on purpose: a specific
  /// question gets the specific corpus ladder (or the plan reasoner when a
  /// plan stands), and the interactive flow is reserved for OPEN symptoms
  /// where the next question is genuinely "what do you see?".
  static String? matchStart(String text) {
    final raw = text.toLowerCase();
    final t = CasualEnglish.canonical(raw);
    if (_namesTarget.hasMatch(t)) return null;
    if (raw.contains('internet') && _troubleWord.hasMatch(raw)) {
      return 'no-internet';
    }
    if (_any(t, const [
      'cannot ping',
      "can't ping",
      'cant ping',
      'no connectivity',
      'cannot reach',
      "can't reach",
      'cannot connect',
      'not connecting',
      'troubleshoot my connection',
      'troubleshoot my network',
      'troubleshoot connectivity',
      'debug my network',
      'help me debug my network',
      'diagnose my network',
    ])) {
      return 'pc-unreachable';
    }
    if (_any(t, const [
      'no internet',
      'internet is down',
      'internet not working',
      'no wan',
      'wan is down',
    ])) {
      return 'no-internet';
    }
    if (_any(t, const [
      'keeps dropping',
      'keeps disconnecting',
      'keep disconnecting',
      'intermittent',
      'drops out',
      'connection drops',
      'keeps cutting out',
      'flapping',
    ])) {
      return 'intermittent';
    }
    return null;
  }

  static final RegExp _troubleWord = RegExp(
    r"\b(no|not|cannot|can'?t|cant|fail|fails|broken|down|issue|problem|"
    r'trouble|slow|nothing)\b',
  );

  /// A symptom that already names where the ping dies: the word gateway,
  /// an IPv4 address, or a numbered device (PC1, R2, switch 3). Those are
  /// specific questions - the corpus ladder and the topology reasoner own
  /// them; the flows ask the questions only an open symptom needs.
  static final RegExp _namesTarget = RegExp(
    r'\bgateway\b|\b\d{1,3}(?:\.\d{1,3}){3}\b|\b(?:pc|router|switch|'
    r'server|laptop)\s*\d+\b',
  );

  static bool _any(String t, List<String> phrases) =>
      phrases.any(t.contains);

  /// Initial state for a flow, or null for an unknown id.
  static Map<String, dynamic>? start(String flowId) {
    final flow = _flows[flowId];
    if (flow == null) return null;
    return {'flow': flowId, 'step': flow.first, 'data': <String, dynamic>{}};
  }

  /// The first turn of a flow - its opening question and options - or null
  /// for an unknown id. This is what the assistant renders when a symptom
  /// opens a flow, so the first turn needs no synthetic user answer.
  static FlowTurn? open(String flowId) {
    final flow = _flows[flowId];
    if (flow == null) return null;
    final step = flow.steps[flow.first]!;
    return FlowTurn(
      prompt: step.prompt,
      options: step.options,
      done: step.fix != null,
      fix: step.fix,
      state: {'flow': flowId, 'step': flow.first, 'data': <String, dynamic>{}},
    );
  }
}

class TroubleshootFlowEngine {
  const TroubleshootFlowEngine._();

  /// Advance a flow with the user's answer - the tapped chip label or free
  /// text. An unrecognized answer re-asks the same step with a hint rather
  /// than guessing; a corrupt state starts the conversation over honestly.
  static FlowTurn advance(Map<String, dynamic> state, String userText) {
    final flowId = '${state['flow'] ?? ''}';
    final flow = _flows[flowId];
    final stepId = '${state['step'] ?? ''}';
    final step = flow?.steps[stepId];
    if (flow == null || step == null) {
      return FlowTurn(
        prompt: 'I lost the thread of that diagnosis - say the symptom '
            'again (for example "PC1 cannot ping PC2") and I will start '
            'it fresh.',
        done: true,
        state: const <String, dynamic>{},
      );
    }
    final data = Map<String, dynamic>.from(
      state['data'] as Map? ?? <String, dynamic>{},
    );
    final value = _matchOption(step.options, userText);
    if (value == null) {
      return FlowTurn(
        prompt: '${step.prompt}\n\n'
            '(Tap one of the options, or say what you see in your own '
            'words.)',
        options: step.options,
        state: {'flow': flowId, 'step': stepId, 'data': data},
      );
    }
    data[step.id] = value;
    final nextId = step.next[value];
    if (step.fix != null) {
      // A terminal step's fix is the answer; it should have been returned
      // when reached, but a persisted done-state must still reply sanely.
      return FlowTurn(
        prompt: step.fix ?? '',
        done: true,
        fix: step.fix,
        state: {'flow': flowId, 'step': stepId, 'data': data},
      );
    }
    final next = nextId == null ? null : flow.steps[nextId];
    if (next == null) {
      // A flow-definition bug (a value with no hop): fail closed to an
      // honest dead-end rather than an empty message.
      return FlowTurn(
        prompt: 'That branch of the diagnosis ran out of road - tell me '
            'what you are seeing and I will pick the ladder up from '
            'there.',
        done: true,
        state: {'flow': flowId, 'step': stepId, 'data': data},
      );
    }
    return FlowTurn(
      prompt: next.prompt,
      options: next.options,
      done: next.fix != null,
      fix: next.fix,
      state: {'flow': flowId, 'step': next.id, 'data': data},
    );
  }

  /// The option value a user's text answers with, or null. Exact label and
  /// value first (chips send their label verbatim), then containment for
  /// multi-word labels, then a word-boundary match so a single-word label
  /// like 'no' cannot ride inside 'not working'. Both sides run through
  /// the same cleaner - a label with dots or punctuation ('a 169.254.x.x
  /// address') must compare equal to the same words typed back.
  static String? _matchOption(List<FlowOption> options, String userText) {
    String clean(String s) => CasualEnglish.canonical(
      s.trim().toLowerCase().replaceAll(RegExp(r'[.!?,;:]'), ''),
    );
    final text = clean(userText);
    for (final o in options) {
      if (text == clean(o.label) || text == clean(o.value)) return o.value;
    }
    for (final o in options) {
      final label = clean(o.label);
      if (label.contains(' ') && text.contains(label)) return o.value;
      final value = clean(o.value);
      if (value.contains(' ') && text.contains(value)) return o.value;
    }
    for (final o in options) {
      final word = o.value.split(' ').last;
      if (word.length >= 2 &&
          RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(text)) {
        return o.value;
      }
    }
    return null;
  }
}

// --- the flow definitions --------------------------------------------------

class _Step {
  final String id;
  final String prompt;
  final List<FlowOption> options;

  /// value -> next step id. Absent for terminal values.
  final Map<String, String> next;

  /// Set on terminal steps: the self-contained fix (commands + why).
  final String? fix;

  const _Step(
    this.id,
    this.prompt,
    this.options, {
    this.next = const {},
    this.fix,
  });
}

class _Flow {
  final String first;
  final Map<String, _Step> steps;
  const _Flow(this.first, this.steps);
}

const String _updown = 'The port shows up/down - the switch sees the cable '
    'but the line protocol is down. That is a speed/duplex mismatch or a '
    'dead neighbor side, not addressing:\n'
    '1. `show run interface <port>` - if it is hard-set (for example '
    '`speed 10` / `duplex half`), set BOTH ends to auto, or both to the '
    'same fixed speed.\n'
    '2. Swap the cable - a marginal cable negotiates up and dies.\n'
    '3. `show interfaces <port>` - the port should reach up/up.\n'
    'Verify with `show ip interface brief` - the port must read up/up '
    'before addressing matters.';

const String _downdown = 'The port shows down/down - layer 1 is dead, so '
    'nothing above it can work. No IP change will fix this:\n'
    '1. Reseat both cable ends; try a known-good cable.\n'
    '2. `show cdp neighbors` - if the neighbor is not listed at all, the '
    'cable or the port is dead, not the config.\n'
    '3. Move the cable to a spare switch port and re-check.\n'
    'Verify with `show ip interface brief` - the port must read up/up.';

const String _admindown = 'The port reads administratively down - someone '
    '(or a port-security err-disable) shut it:\n'
    '1. `show run interface <port>` - look for `shutdown`.\n'
    '2. In the interface config: `no shutdown`.\n'
    '3. If it err-disables again, `show port-security interface <port>` - '
    'a security violation shut it; clear with `errdisable recovery` or '
    '`shutdown` + `no shutdown` after fixing the violation.\n'
    'Verify with `show ip interface brief` - up/up.';

const String _apipa = 'The PC self-assigned a 169.254.x.x address - that is '
    'APIPA, and it means DHCP never answered:\n'
    '1. On the DHCP server (or router pool): `show ip dhcp binding` - is '
    'the pool handing out leases at all?\n'
    '2. If the server sits behind a router, the LAN interface needs '
    '`ip helper-address <server-ip>` - DHCP broadcasts do not cross '
    'routers alone.\n'
    '3. Check the pool network matches the PC subnet, and that the server '
    'service is on (Services > DHCP in Packet Tracer).\n'
    'Verify with `ipconfig` on the PC after `ipconfig /renew` - a real '
    'address in the pool range, with the right gateway.';

const String _gatewayTimeout = 'The PC cannot ping its own gateway, so the '
    'fault is still local - do not chase routing yet:\n'
    '1. `ipconfig` - is the default gateway in the SAME subnet as the PC '
    '(a 192.168.2.x PC needs a 192.168.2.x gateway, not .1.x)?\n'
    '2. Does the gateway address exist? `show ip interface brief` on the '
    'router - the LAN interface must be up/up with that exact address.\n'
    '3. Wrong mask on the PC puts the gateway "outside" the subnet - fix '
    'the mask first.\n'
    'Verify with `ping <gateway>` from the PC - it must answer before any '
    'further test means anything.';

const String _routingUnreachable = 'The reply is "destination host '
    'unreachable" - that is a ROUTER saying it has no route. Local '
    'addressing is fine; routing is the fault:\n'
    '1. On the last router in the path: `show ip route` - the far subnet '
    'must be listed.\n'
    '2. If it is not: add the route (`ip route <far-subnet> <mask> '
    '<next-hop>`) or bring up the routing protocol between the routers '
    '(`router ospf 1` + `network` statements per subnet).\n'
    '3. Remember routes are needed BOTH ways - the return path too.\n'
    'Verify with `show ip route` (far subnet listed) and then the original '
    'ping.';

const String _aclTimeout = 'The ping times out silently with addressing and '
    'routes in place - that shape is filtering, not routing:\n'
    '1. `show access-lists` on every router in the path - look for a '
    'permit/deny that matches this traffic.\n'
    '2. Remember the implicit "deny any": an ACL that permits only some '
    'traffic silently drops the rest.\n'
    '3. Check the FAR host is actually up and its firewall off (a PC that '
    'never answers looks exactly like a filtered route).\n'
    'Verify by re-running the ping after each ACL removal - the one that '
    'changes the result is the guilty one.';

const String _allGood = 'Every rung checked out: link up/up, real address, '
    'gateway answers, far end replies. The path works NOW - re-run your '
    'original test. If the fault comes back intermittently, say '
    '"the network keeps dropping" and I will run the intermittent-drop '
    'ladder instead.';

const String _noGateway = 'The PC cannot even reach its own gateway, so the '
    'internet is not the problem yet - the local LAN is. Run the local '
    'ladder first: check the switch port (`show ip interface brief`), then '
    '`ipconfig` on the PC (a 169.254.x.x address means DHCP never '
    'answered), then `ping <gateway>`. Say "PC cannot ping anything" and I '
    'will walk it with you step by step.';

const String _wanDown = 'The router itself cannot reach the ISP edge, so '
    'nothing downstream matters yet:\n'
    '1. `show ip interface brief` - the WAN interface must be up/up with '
    'the right address.\n'
    '2. `show ip route` - is there a default route (`0.0.0.0/0`)? Without '
    'one: `ip route 0.0.0.0 0.0.0.0 <isp-next-hop>`.\n'
    '3. Ping the ISP next hop FROM the router - if that works but PCs '
    'still fail, NAT is next, not the WAN.\n'
    'Verify with `ping <isp-ip>` from the router itself.';

const String _noNat = 'No translations in `show ip nat translations` - the '
    'PCs\' private addresses are reaching the router but never leave as a '
    'public one. Configure PAT overload:\n'
    '1. On the LAN interfaces: `ip nat inside`.\n'
    '2. On the WAN interface: `ip nat outside`.\n'
    '3. `access-list 1 permit <lan-subnet> <wildcard>`.\n'
    '4. `ip nat inside source list 1 interface <wan> overload`.\n'
    'Verify with a PC browsing while you run `show ip nat translations` - '
    'entries must appear.';

const String _natOkDns = 'NAT is translating, so routing and address '
    'translation work - DNS is the usual last suspect:\n'
    '1. From the PC: `nslookup cisco.com` - if names fail but '
    '`ping 8.8.8.8` works, DNS is the fault.\n'
    '2. Hand out a DNS server: in the DHCP pool add `dns-server <ip>` (or '
    'on the router `ip name-server <ip>` + `ip dns server`).\n'
    '3. In Packet Tracer, the server\'s DNS service must be ON with the '
    'records you expect.\n'
    'Verify with `nslookup cisco.com` from the PC - a resolved address, '
    'then the original browse.';

const String _wifiDrops = 'Wifi drops are usually RF, not config:\n'
    '1. Same SSID on all APs with roaming in mind - check channels do not '
    'overlap (1/6/11 on 2.4 GHz).\n'
    '2. Signal strength at the drop spot - a client clinging to a far AP '
    'at -80 dBm drops exactly like this; add an AP instead of fighting '
    'it.\n'
    '3. In Packet Tracer, check the AP\'s Port 1 channel and the SSID '
    'settings match across APs.\n'
    'Verify by watching the client - it should roam between APs without '
    'losing the association.';

const String _crcErrors = 'Climbing input errors / CRCs on a switch port is '
    'a physical-layer fault dressed as an intermittent one:\n'
    '1. Replace the cable first - marginal cables CRC exactly like this.\n'
    '2. Match speed/duplex: auto on BOTH ends, or the same fixed value on '
    'both - a half/full mismatch runs "fine" until load exposes it.\n'
    '3. If the port keeps erroring on a known-good cable, the port itself '
    'is failing - move to a spare.\n'
    'Verify with `show interfaces <port>` after the swap - counters stay '
    'flat under load.';

const String _duplicateIp = 'It drops when another device joins - that is '
    'the classic duplicate-address signature: two hosts answer ARP for one '
    'address, and which one wins changes per reply:\n'
    '1. `show arp` on the switch/router - look for one MAC flapping '
    'between ports for the same IP.\n'
    '2. `show ip dhcp conflict` if DHCP hands addresses out statically '
    'too.\n'
    '3. Fix the static host: move it into the DHCP pool\'s excluded range '
    'or give it a reserved lease.\n'
    'Verify with `show arp` - one IP, one MAC, stable.';

const String _tcnLoop = 'Topology changes in the logs mean a link is '
    'flapping or a loop is being pruned - STP is doing its job, badly for '
    'you:\n'
    '1. `show spanning-tree` - which port keeps going through listening/'
    'learning? That is the flapping link.\n'
    '2. `spanning-tree portfast` on ACCESS ports only (never trunks) so '
    'end devices stop causing TCNs on link bounce.\n'
    '3. Hunt the physical cause: the flapping port\'s cable, or two '
    'cables accidentally forming a loop.\n'
    'Verify with `show spanning-tree` over a few minutes - one stable '
    'root, no repeated topology changes.';

const String _idleDrops = 'Random idle drops with clean counters and no '
    'topology changes point away from the LAN itself:\n'
    '1. Power saving: NIC power management and PoE budget '
    '(`show power inline`) - a port that brownouts drops exactly like '
    'this.\n'
    '2. `terminal monitor` + watch the logs while it drops - the log line '
    'at the moment of the drop names the cause.\n'
    '3. Swap the patch cable and port as a control experiment - cheap and '
    'rules out the last physical suspect.\n'
    'Verify: correlation - the drop time in the client\'s log matches one '
    'named cause in the switch log.';

final Map<String, _Flow> _flows = {
  'pc-unreachable': _Flow('s1', {
    's1': _Step(
      's1',
      'Start at the switch port the PC uses: run `show ip interface '
      'brief` (or read the port lights). What does that port show?',
      const [
        FlowOption('up/up', 'upup'),
        FlowOption('up/down', 'updown'),
        FlowOption('down/down', 'downdown'),
        FlowOption('administratively down', 'admindown'),
      ],
      next: {
        'upup': 's2',
        'updown': 'fix_updown',
        'downdown': 'fix_downdown',
        'admindown': 'fix_admindown',
      },
    ),
    'fix_updown': _Step('fix_updown', '', const [], fix: _updown),
    'fix_downdown': _Step('fix_downdown', '', const [], fix: _downdown),
    'fix_admindown': _Step('fix_admindown', '', const [], fix: _admindown),
    's2': _Step(
      's2',
      'Layer 1 is good. On the PC run `ipconfig`: does it hold a real '
      'address in its LAN, or a 169.254.x.x one?',
      const [
        FlowOption('a 169.254.x.x address', 'apipa'),
        FlowOption('a real address', 'realip'),
      ],
      next: {'apipa': 'fix_apipa', 'realip': 's3'},
    ),
    'fix_apipa': _Step('fix_apipa', '', const [], fix: _apipa),
    's3': _Step(
      's3',
      'Addressing looks right. Can the PC ping its own gateway '
      '(`ping <gateway>`)?',
      const [
        FlowOption('it replies', 'yes'),
        FlowOption('timed out', 'timeout'),
      ],
      next: {'yes': 's4', 'timeout': 'fix_gwtimeout'},
    ),
    'fix_gwtimeout': _Step(
      'fix_gwtimeout',
      '',
      const [],
      fix: _gatewayTimeout,
    ),
    's4': _Step(
      's4',
      'The local LAN is healthy - the PC reaches its gateway. Now ping '
      'the far device from the PC. What comes back?',
      const [
        FlowOption('it replies', 'replies'),
        FlowOption('destination host unreachable', 'unreachable'),
        FlowOption('request timed out', 'timedout'),
      ],
      next: {
        'replies': 'fix_allgood',
        'unreachable': 'fix_routing',
        'timedout': 'fix_acl',
      },
    ),
    'fix_allgood': _Step('fix_allgood', '', const [], fix: _allGood),
    'fix_routing': _Step('fix_routing', '', const [], fix: _routingUnreachable),
    'fix_acl': _Step('fix_acl', '', const [], fix: _aclTimeout),
  }),
  'no-internet': _Flow('s1', {
    's1': _Step(
      's1',
      'First, can the PC ping its own LAN gateway (for example '
      '`ping 192.168.1.1`)?',
      const [
        FlowOption('yes', 'yes'),
        FlowOption('no', 'no'),
      ],
      next: {'yes': 's2', 'no': 'fix_local'},
    ),
    'fix_local': _Step('fix_local', '', const [], fix: _noGateway),
    's2': _Step(
      's2',
      'The LAN is fine. On the edge router, can it reach the ISP side '
      '(`ping <isp-next-hop>` from the router)?',
      const [
        FlowOption('yes', 'yes'),
        FlowOption('timed out', 'timeout'),
      ],
      next: {'yes': 's3', 'timeout': 'fix_wan'},
    ),
    'fix_wan': _Step('fix_wan', '', const [], fix: _wanDown),
    's3': _Step(
      's3',
      'Routing reaches the ISP. Is NAT actually translating? Run '
      '`show ip nat translations` while a PC tries to browse.',
      const [
        FlowOption('it shows translations', 'entries'),
        FlowOption('it is empty', 'empty'),
      ],
      next: {'entries': 's4', 'empty': 'fix_nat'},
    ),
    'fix_nat': _Step('fix_nat', '', const [], fix: _noNat),
    's4': _Step(
      's4',
      'NAT works. Last rung: does DNS resolve? `nslookup cisco.com` on '
      'the PC.',
      const [
        FlowOption('it resolves', 'yes'),
        FlowOption('it fails', 'no'),
      ],
      next: {'yes': 'fix_done', 'no': 'fix_dns'},
    ),
    'fix_done': _Step('fix_done', '', const [], fix: _allGood),
    'fix_dns': _Step('fix_dns', '', const [], fix: _natOkDns),
  }),
  'intermittent': _Flow('s1', {
    's1': _Step(
      's1',
      'Is the device that drops wired, or on wifi?',
      const [
        FlowOption('wired', 'wired'),
        FlowOption('wifi', 'wifi'),
      ],
      next: {'wired': 's2', 'wifi': 'fix_wifi'},
    ),
    'fix_wifi': _Step('fix_wifi', '', const [], fix: _wifiDrops),
    's2': _Step(
      's2',
      'On its switch port: do the error counters climb? '
      '(`show interfaces <port>` - watch input errors and CRCs.)',
      const [
        FlowOption('errors climbing', 'errors'),
        FlowOption('counters clean', 'clean'),
      ],
      next: {'errors': 'fix_crc', 'clean': 's3'},
    ),
    'fix_crc': _Step('fix_crc', '', const [], fix: _crcErrors),
    's3': _Step(
      's3',
      'Counters are clean. When exactly does it drop?',
      const [
        FlowOption('under load (file copy)', 'load'),
        FlowOption('at random idle moments', 'idle'),
        FlowOption('when another device joins', 'joins'),
      ],
      next: {
        'load': 'fix_crc',
        'idle': 's4',
        'joins': 'fix_dupip',
      },
    ),
    'fix_idle': _Step('fix_idle', '', const [], fix: _idleDrops),
    'fix_dupip': _Step('fix_dupip', '', const [], fix: _duplicateIp),
    's4': _Step(
      's4',
      'One more check before the physical hunt: do the logs show '
      'spanning-tree topology changes? (`show spanning-tree`, and watch '
      'for "topology changed" lines.)',
      const [
        FlowOption('yes, topology changes', 'tcn'),
        FlowOption('no changes', 'clean'),
      ],
      next: {'tcn': 'fix_tcn', 'clean': 'fix_idle'},
    ),
    'fix_tcn': _Step('fix_tcn', '', const [], fix: _tcnLoop),
  }),
};
