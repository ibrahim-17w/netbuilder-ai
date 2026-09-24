import '../models/chat_message.dart';
import '../models/network_intent.dart';
import 'conversation_memory.dart';

/// A conversational reply produced without any model.
class AssistantReply {
  final String text;
  final List<String> questions;

  /// build | howto | change | vague | greeting
  final String intent;

  const AssistantReply(this.text, {this.questions = const [], this.intent = 'build'});
}

/// The keyless assistant: a normal, advisory answer instead of a plan dump or
/// a "could not reach the model" error.
///
/// It is deterministic on purpose. It recognises what the user is asking for,
/// answers questions from a small Cisco/Packet-Tracer knowledge base, plans a
/// build request, and - when the request is too vague - asks for what it
/// needs. It never invents credentials and never claims anything was built or
/// verified.
class OfflineAssistantService {
  const OfflineAssistantService._();

  static AssistantReply reply({
    required String rawText,
    required String normalized,
    required String target,
    NetworkIntent? plan,
    List<String> suggestions = const [],
    String modelError = '',
    List<ChatMessage> history = const [],
  }) {
    // MEMORY: the earlier turns of this conversation are the difference
    // between a useful answer and a generic one. The offline path has no
    // model, so it reads them directly.
    final asks = ConversationMemory.userAsks(history);
    final originalAsk = asks.isEmpty ? '' : asks.first;
    final t = normalized.trim().toLowerCase();

    if (t.isEmpty) {
      return AssistantReply(_vagueAnswer(originalAsk),
          questions: _vagueQuestions, intent: 'vague');
    }
    if (_isRecall(t)) {
      return AssistantReply(_recallAnswer(asks, normalized, plan),
          intent: 'recall');
    }
    if (_isGreeting(t)) {
      return AssistantReply(
        'Hi! I am the NetBuilder assistant and I am running offline - no API '
        'key needed. Tell me what to build (for example "2 routers, 1 switch '
        'and 4 PCs with OSPF"), or ask me a networking question and I will '
        'answer with advice.',
        intent: 'greeting',
      );
    }
    // A one- or two-word opener with no device in it ("help", "hmm",
    // "what") must not be planned as if it were a brief: the parser would
    // invent a router and a switch. Ask instead.
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final hasDeviceWord = RegExp(
      r'\b(router|routers|switch|switches|pc|pcs|server|servers|laptop|'
      r'laptops|printer|firewall|ap|wifi|wireless|vlan|ospf|eigrp|bgp|'
      r'subnet|network|lab|office|site|sites|dhcp|dns|aaa|vpn|acl)\b',
    ).hasMatch(t);
    if (words.length <= 2 && !hasDeviceWord) {
      return AssistantReply(_vagueAnswer(originalAsk),
          questions: _vagueQuestions, intent: 'vague');
    }
    if (_isChange(t)) {
      return AssistantReply(
        '${_openLine(modelError)}\n\n${_describeChange(t)}\n\n'
        'To make it stick for future plans, save it as a rule (Memory, or the '
        '"Teach a correction" box) - for example "always use a 4331 router" or '
        '"LANs in 10.20.0.0/24". I apply saved rules on the next plan '
        'automatically.',
        intent: 'change',
      );
    }
    final concept = _concept(t);
    if (concept != null) {
      return AssistantReply(
        '${_openLine(modelError)}\n\n${_conceptAnswer(concept)}\n\n'
        'If you tell me the lab you are building I will turn this into a plan '
        'and give you the exact steps.',
        intent: 'howto',
      );
    }
    if (plan != null && plan.nodes.isNotEmpty) {
      return AssistantReply(
        _buildAnswer(plan, suggestions, modelError, originalAsk),
        intent: 'build',
      );
    }
    return AssistantReply(_vagueAnswer(originalAsk),
        questions: _vagueQuestions, intent: 'vague');
  }

  // --- intent detection ---------------------------------------------------

  static const Set<String> _greetings = {
    'hi', 'hello', 'hey', 'yo', 'sup', 'salam', 'salaam', 'hola',
    'thanks', 'thank you', 'ty', 'ok', 'okay', 'good morning', 'good evening',
  };

  static bool _isGreeting(String t) =>
      _greetings.contains(t) ||
      t.startsWith('hi ') ||
      t.startsWith('hello ') ||
      t.startsWith('hey ');

  /// "what did I ask you to build?", "remind me", "as I said" - a
  /// question about the conversation itself, answered from memory.
  static final RegExp _recallPattern = RegExp(
    r'\b(what (did|was|were) (i|my|we)|remind me|what did i (ask|say|tell)|'
    r'my (first|original) (ask|request|message|idea)|as i (asked|said)|'
    r'what was the (original|first)|do you remember)\b',
  );

  static bool _isRecall(String t) => _recallPattern.hasMatch(t);

  /// Answer a recall question with the user's own words, oldest first.
  static String _recallAnswer(
    List<String> asks,
    String normalized,
    NetworkIntent? plan,
  ) {
    final current = normalized.trim().toLowerCase();
    final prior = <String>[
      for (final ask in asks)
        if (current.isEmpty ||
            !current.contains(
              ask.toLowerCase().substring(0, ask.length < 24 ? ask.length : 24),
            ))
          ask,
    ];
    if (prior.isEmpty) {
      return 'This is the start of our conversation - you have not asked me '
          'for anything yet. Tell me what you want to build and I will plan '
          'it, or ask me a networking question.';
    }
    final b = StringBuffer()
      ..writeln('Here is what you have asked me, oldest first:')
      ..writeln();
    for (var i = 0; i < prior.length; i++) {
      b.writeln('${i + 1}. ${prior[i]}');
    }
    b.writeln();
    b.writeln('Your ORIGINAL request was: "${prior.first}".');
    if (plan != null && plan.nodes.isNotEmpty) {
      b.writeln(
        'I still hold the plan for it: '
        '${plan.nodes.map((n) => n.name).join(', ')}.',
      );
    }
    return b.toString().trimRight();
  }

  static final RegExp _changeVerb = RegExp(
    r'\b(add|adding|change|changing|set|update|remove|delete|rename|convert|replace|switch it|make it|turn it|modify)\b',
  );
  static final RegExp _deviceCount = RegExp(
    r'\d+\s*(routers?|switches|switch|pcs?|servers?|laptops?|printers?|firewalls?)',
  );

  static bool _isChange(String t) {
    if (t.isEmpty) return false;
    // "add 2 routers" is a build request, not a change to an existing plan.
    if (_deviceCount.hasMatch(t)) return false;
    return _changeVerb.hasMatch(t);
  }

  static String _describeChange(String t) {
    final bits = <String>[];
    final model =
        RegExp(r'\b(4331|4321|2911|2901|1941|2960|2950|3560|829)\b').firstMatch(t);
    if (model != null && t.contains('router')) {
      bits.add('use the ${model.group(1)} model for the routers');
    } else if (model != null && t.contains('switch')) {
      bits.add('use the ${model.group(1)} model for the switches');
    } else if (model != null) {
      bits.add('use model ${model.group(1)}');
    }
    final cidr = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b').firstMatch(t);
    if (cidr != null) bits.add('move the LANs onto ${cidr.group(1)}');
    if (t.contains('vlan')) {
      bits.add('create the VLAN on the switches and put its ports in it');
    }
    for (final p in const ['ospf', 'eigrp', 'bgp', 'static']) {
      if (RegExp('\\b$p\\b').hasMatch(t)) {
        bits.add('use $p for routing');
        break;
      }
    }
    if (bits.isEmpty) bits.add('apply the change you described to the current plan');
    return 'Got it - I would ${bits.join(', and ')}.';
  }

  static String? _concept(String t) {
    // A device count means a build request, not a concept question.
    if (_deviceCount.hasMatch(t)) return null;
    bool has(String w) => RegExp('\\b$w\\b').hasMatch(t);
    if ((has('ospf') || has('eigrp') || has('bgp')) &&
        (has('static') ||
            has('vs') ||
            has('difference') ||
            has('which') ||
            t.contains('better') ||
            t.contains(' or '))) {
      return 'routing';
    }
    if (has('trunk') || t.contains('access port')) return 'trunk';
    if (has('dhcp')) return 'dhcp';
    if (has('dns')) return 'dns';
    if (has('vlan')) return 'vlan';
    if ((t.contains('connect') || t.contains('link') || t.contains('between')) &&
        (has('router') || has('routers'))) {
      return 'two_routers';
    }
    if (has('nat') || t.contains('internet')) return 'internet';
    if (has('acl') || t.contains('access list')) return 'acl';
    if (t.contains('subnet') || t.contains('mask')) return 'subnet';
    // The wider expert set: routing, switching, services, transport,
    // security, wireless and IPv6.
    if (t.contains('stp') || t.contains('spanning') ||
        t.contains('loop')) {
      return 'stp';
    }
    if (t.contains('etherchannel') || t.contains('port-channel') ||
        t.contains('lag')) {
      return 'etherchannel';
    }
    if (t.contains('mtu') || t.contains('mss') || t.contains('fragment')) {
      return 'mtu';
    }
    if (t.contains('retransmit') || t.contains('tcp') ||
        t.contains('window') || t.contains('handshake')) {
      return 'tcp';
    }
    if (t.contains('nat') || t.contains('pat')) return 'internet';
    if (t.contains('qos') || t.contains('priority queue') ||
        t.contains('dscp')) {
      return 'qos';
    }
    if (t.contains('roam') || t.contains('channel') ||
        t.contains('802.11') || t.contains('rssi')) {
      return 'wireless';
    }
    if (t.contains('ipv6') || t.contains('slaac') || t.contains('nd ')) {
      return 'ipv6';
    }
    if (t.contains('ospf area') || t.contains('dr') ||
        t.contains('lsa')) {
      return 'ospf_internals';
    }
    if (t.contains('eigrp')) return 'eigrp';
    if (t.contains('bgp')) return 'bgp';
    if (t.contains('default route') || t.contains('gateway of last')) {
      return 'default_route';
    }
    return null;
  }

  static String _conceptAnswer(String key) {
    switch (key) {
      case 'routing':
        return 'Static routes are fine for one router or a single path - simple '
            'and predictable. OSPF is better once you have two or more routers: '
            'it learns the paths, converges around a failed link, and you stop '
            'hand-writing every network. For a graded lab with 2+ routers I '
            'would pick OSPF (single area 0).';
      case 'trunk':
        return 'An access port belongs to a single VLAN and faces an end device '
            '(PC, printer). A trunk carries several VLANs at once and faces '
            'another switch or a router. So: access ports for the PCs, a trunk '
            'between the switches.';
      case 'dhcp':
        return 'If DHCP is not handing out addresses, check three things: the '
            'pool network/mask matches the interface, the pool default gateway '
            'is the router LAN IP, and for a remote LAN you need "ip '
            'helper-address <server>" on that router interface.';
      case 'dns':
        return 'Point every client at the DNS server IP (set it on the DHCP pool '
            'or statically on the PC), then add A records on the server for the '
            'names you want to resolve.';
      case 'vlan':
        return 'Create the VLAN on the switch, put the user ports in it as access '
            'ports, and trunk the uplink so the VLAN reaches the rest of the '
            'network. Hosts in different VLANs need a router or an L3 switch to '
            'talk to each other.';
      case 'two_routers':
        return 'Connect two routers either with a serial link (s0/0/0 on both '
            'ends, clock rate on the DCE side) or with an Ethernet /30 transit '
            'link. Give each LAN its own subnet, then either add static routes '
            'or run OSPF.';
      case 'internet':
        return 'For internet access put a Cloud-PT or a firewall at the edge, '
            'give the router a default route toward it, and NAT the inside '
            'traffic (overload on the WAN interface).';
      case 'acl':
        return 'Standard ACLs filter by source only - place them near the '
            'destination. Extended ACLs filter by source, destination, protocol '
            'and port - place them near the source. Remember the implicit "deny '
            'any" at the end.';
      case 'subnet':
        return 'Give each LAN its own subnet with the router holding the first '
            'usable address (.1) as the gateway. A /24 gives 254 hosts; a /30 is '
            'the usual choice for a point-to-point link between two routers.';
      case 'stp':
        return 'Spanning tree breaks Layer-2 loops by blocking redundant '
            'ports. One root bridge is elected (lowest bridge ID), then every '
            'other switch keeps one root port and each segment one designated '
            'port. Check with `show spanning-tree` and find the blocked port by '
            'walking the topology towards the root.';
      case 'etherchannel':
        return 'EtherChannel bundles up to 8 same-speed links into one logical '
            'link. Match the settings on both ends (mode, allowed VLANs, speed) '
            'or the bundle stays down: `channel-group 1 mode active` with LACP '
            'on both sides, then verify with `show etherchannel summary` (flag '
            'SU = in use).';
      case 'mtu':
        return 'TCP MSS is the payload size that fits the path MTU minus the '
            'IP+TCP headers. A tunnel adds overhead, so set the inside MSS with '
            '`ip tcp adjust-mss 1360` on the tunnel interface when MTU 1500 '
            'breaks. Symptoms of an MSS/MTU problem: small pings work, large '
            'pings and logins hang.';
      case 'tcp':
        return 'A TCP session is SYN, SYN-ACK, ACK. Retransmissions mean an '
            'unacknowledged segment was resent (loss, congestion or a broken '
            'return path); duplicate ACKs hint at one dropped segment, while a '
            'zero-window says the receiver is full. Check RTT and window '
            'scaling before blaming the application.';
      case 'qos':
        return 'Classify first, then queue: mark at the edge (DSCP EF for '
            'voice, AF41 for video), trust DSCP on the uplinks, and give the '
            'latency-sensitive classes a priority queue while everything else '
            'shares a weighted queue. Policing drops, shaping delays - choose '
            'per direction.';
      case 'wireless':
        return 'Roaming is the client\'s decision: it moves when the new AP is '
            'better by about 10-15 dBm. Make sure the same SSID and security '
            'exist on every AP, keep 2.4 GHz on channels 1/6/11 and use 5 GHz '
            'for throughput. Sticky clients usually mean the coverage overlap is '
            'too small.';
      case 'ipv6':
        return 'IPv6 has no broadcast and no NAT. A router advertises prefixes '
            'with RA, and hosts can self-configure with SLAAC; if you want a '
            'managed DHCPv6 address, set the RA flags M/O. Verify with `show '
            'ipv6 interface brief` and `show ipv6 route`.';
      case 'ospf_internals':
        return 'In a broadcast segment OSPF elects a DR and BDR to cut the '
            'number of adjacencies; everyone else stays in 2-WAY with them. Set '
            'the router-id and interface priorities deliberately. `show ip ospf '
            'neighbor` shows the state, `show ip ospf database` the LSAs.';
      case 'eigrp':
        return 'EIGRP picks routes by composite metric (bandwidth and delay by '
            'default) and keeps a feasible successor for instant failover. '
            'Classic EIGRP must match the AS number and K-values; named mode '
            'lets you keep them in the address family.';
      case 'bgp':
        return 'BGP chooses by weight, then local preference, then AS-path '
            'length, then origin, then MED. Between two eBGP peers everything is '
            'typo-sensitive: the AS number, the neighbour address and the '
            'advertised prefixes. Start with `show ip bgp summary`.';
      case 'default_route':
        return 'A default route (0.0.0.0/0) is the gateway of last resort. '
            'Static: `ip route 0.0.0.0 0.0.0.0 <next-hop>`. In OSPF inject it '
            'with `default-information originate`; in EIGRP or BGP redistribute '
            'it. Nothing more specific may exist, or that wins instead.';
      default:
        return 'Tell me the platform and the symptom and I will pin it '
            'down. Useful shape for any networking problem: (1) what changed '
            'last, (2) what is the exact symptom and scope (one host, one '
            'VLAN, one direction?), (3) work up the stack - link, addressing, '
            'routing, then service - and check each with one command before '
            'moving on.';
    }
  }

  // --- answers ------------------------------------------------------------

  static String _buildAnswer(
    NetworkIntent plan,
    List<String> suggestions,
    String modelError,
    String originalAsk,
  ) {
    final routers = plan.nodes.where((n) => n.type == 'router').length;
    final switches = plan.nodes.where((n) => n.type == 'switch').length;
    final pcs = plan.nodes.where((n) => n.type == 'pc').length;
    final servers = plan.nodes.where((n) => n.type == 'server').length;
    final others = plan.nodes.length - routers - switches - pcs - servers;

    final sb = StringBuffer();
    sb.writeln(_openLine(modelError));
    sb.writeln();
    final parts = <String>[
      if (routers > 0) '$routers router(s)',
      if (switches > 0) '$switches switch(es)',
      if (pcs > 0) '$pcs PC(s)',
      if (servers > 0) '$servers server(s)',
      if (others > 0) '$others other device(s)',
    ];
    sb.writeln('Here is the lab I understand: ${parts.join(', ')}.');
    if (originalAsk.isNotEmpty) {
      sb.writeln(
        'This follows what you asked earlier: "$originalAsk".',
      );
    }
    sb.writeln('Devices: ${plan.nodes.map((n) => n.name).join(', ')}.');
    sb.writeln('Links: ${plan.links.length}, routing: ${plan.routing}.');
    if (plan.addressing.isNotEmpty) {
      sb.writeln(
        'Addressing: ${plan.addressing.take(6).map((a) => '${a.node} ${a.iface}=${a.ipCidr}').join(', ')}'
        '${plan.addressing.length > 6 ? ' ...' : ''}',
      );
    }
    sb.writeln();
    sb.writeln('Advice:');
    if (plan.routing == 'static' && routers > 1) {
      sb.writeln('- With more than one router, OSPF is usually easier than '
          'hand-written static routes - say "use ospf" to switch.');
    }
    if (switches > 1) {
      sb.writeln('- Trunk the link between the switches, and leave the device '
          'ports as access ports.');
    }
    final noRole =
        plan.nodes.where((n) => n.type == 'server' && n.services.isEmpty).length;
    if (noRole > 0) {
      sb.writeln('- Give each server a role (DHCP, DNS, HTTP, AAA, ...) so its '
          'service tab is actually configured.');
    }
    if (!plan.security.requested) {
      sb.writeln('- If this is a secure/graded lab, add port security on the '
          'user ports plus an ACL or VPN - I can plan those too.');
    }
    if (suggestions.isNotEmpty) {
      sb.writeln();
      sb.writeln('Fix these first:');
      for (final s in suggestions.take(6)) {
        sb.writeln('- $s');
      }
    }
    sb.writeln();
    sb.writeln('Next steps:');
    sb.writeln('1. Open the Build tab and paste the same request with "Plan '
        'offline only" on.');
    sb.writeln('2. Check the plan and the validator notes (warnings do not '
        'block a run).');
    sb.writeln('3. Press "Review plan + save", then run PT Autopilot or export '
        'the .pkt.');
    sb.writeln();
    sb.writeln('Nothing is typed into Packet Tracer until you approve it.');
    return sb.toString();
  }

  static String _vagueAnswer(String originalAsk) =>
      'I am here - I just need a bit more to go on.\n\n'
      '${originalAsk.isEmpty ? '' : 'Earlier in this conversation you asked: '
          '"$originalAsk". Do you want me to build on that, or is this '
          'something new?\n\n'}'
      'Tell me what you want in plain words, for example:\n'
      '- "2 routers, 2 switches, 1 server and 4 PCs with OSPF"\n'
      '- "a small office with guest wifi and port security"\n'
      '- "connect two routers over a serial WAN and add a DNS server"\n\n'
      'You can also just ask a question, like "what is better, OSPF or static '
      'routing?".';

  static const List<String> _vagueQuestions = [
    'How many routers, switches, PCs and servers do you want?',
    'Should routing be static or OSPF?',
    'Do you need security (port security, an ACL, or a VPN)?',
  ];

  static String _openLine(String modelError) => modelError.isEmpty
      ? 'Answering offline - no API key needed.'
      : 'The AI model is unavailable (${_short(modelError)}), so I am '
            'answering offline.';

  static String _short(String s) {
    final first = s.split('\n').first.trim();
    return first.length <= 100 ? first : '${first.substring(0, 100)}...';
  }
}
