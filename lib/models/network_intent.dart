// Universal intent model: target-agnostic network description.
// Adapters compile this into GNS3 / Cisco / PT / Terraform.
import '../services/nlu/lexicon.dart';
import '../services/nlu/parser.dart' as brief_reader;
import 'dart:convert';
import 'dart:ui' show Offset;

import '../services/nlu/slots.dart';
import '../services/sizing_service.dart';

class NetNode {
  final String name;
  final String type; // router, switch, pc, server, firewall, cloud
  final String? model; // e.g. c3725, 2960
  final String? mgmtIp;

  /// Server roles for Services-tab automation: dhcp, dns, http, aaa,
  /// email, ftp, ntp, tftp, syslog. Empty for all other types.
  final List<String> services;

  /// Optional, target-neutral rules for the requested server services.
  /// Examples: {'dns': {'records': [...]}} or
  /// {'email': {'domain': 'lab.local', 'users': [...]}}.
  /// Password-like values are removed from planner/export context.
  final Map<String, dynamic> serviceRules;

  const NetNode({
    required this.name,
    required this.type,
    this.model,
    this.mgmtIp,
    this.services = const [],
    this.serviceRules = const {},
  });

  Map<String, dynamic> toJson({bool includeSecrets = true}) => {
    'name': name,
    'type': type,
    if (model != null) 'model': model,
    if (mgmtIp != null) 'mgmtIp': mgmtIp,
    if (services.isNotEmpty) 'services': services,
    if (serviceRules.isNotEmpty)
      'serviceRules': _copyServiceValue(serviceRules, includeSecrets),
  };

  factory NetNode.fromJson(Map<String, dynamic> j) => NetNode(
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    model: j['model'] as String?,
    mgmtIp: j['mgmtIp'] as String?,
    services: ((j['services'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(),
    serviceRules: Map<String, dynamic>.from(
      (j['serviceRules'] as Map?) ?? const {},
    ),
  );
}

dynamic _copyServiceValue(dynamic value, bool includeSecrets) {
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (!includeSecrets &&
          RegExp(
            r'(password|secret|psk|token)',
            caseSensitive: false,
          ).hasMatch(key)) {
        continue;
      }
      out[key] = _copyServiceValue(entry.value, includeSecrets);
    }
    return out;
  }
  if (value is List) {
    return value
        .map((item) => _copyServiceValue(item, includeSecrets))
        .toList();
  }
  return value;
}

class NetLink {
  final String a;
  final String aIf;
  final String b;
  final String bIf;

  /// Cable kind the executor must pick: 'copper' (default), 'copper-cross',
  /// 'serial', 'serial-dce', 'serial-dte', 'fiber', 'console'.  A link whose
  /// interfaces are Serial ports is wired as serial whatever this says - the
  /// field exists for the pairs the interface names cannot express.
  final String? cable;

  /// Which endpoint supplies the clock on a serial link: 'a', 'b', or a
  /// device name.  Null leaves the executor's deterministic default ('a'),
  /// and this same side is the one whose interface config gets `clock rate`.
  final String? dce;

  const NetLink({
    required this.a,
    required this.aIf,
    required this.b,
    required this.bIf,
    this.cable,
    this.dce,
  });

  /// True when either end sits on a Serial port.
  bool get isSerial =>
      aIf.toLowerCase().startsWith('s') || bIf.toLowerCase().startsWith('s');

  /// The endpoint that clocks this link ('a' unless stated otherwise).
  ///
  /// The hint may be the side ('a'/'b') or the device name the brief named
  /// as the clocking end ("R1 is the only DCE end"), and either end can be
  /// the one that was named - so both sides are compared, not just 'b'.
  String get dceEnd {
    final hint = (dce ?? '').trim().toLowerCase();
    if (hint == 'b' || hint == b.toLowerCase()) return 'b';
    return 'a';
  }

  Map<String, dynamic> toJson() => {
    'a': a,
    'aIf': aIf,
    'b': b,
    'bIf': bIf,
    if (cable != null) 'cable': cable,
    if (dce != null) 'dce': dce,
  };

  factory NetLink.fromJson(Map<String, dynamic> j) => NetLink(
    a: j['a'] as String,
    aIf: j['aIf'] as String,
    b: j['b'] as String,
    bIf: j['bIf'] as String,
    cable: j['cable'] as String?,
    dce: j['dce'] as String?,
  );

  /// Device kinds whose port is a SWITCH port - the port a straight-through
  /// copper cable exists for.
  ///
  /// A hub, a cloud and a modem are the same shape: several Ethernet ports
  /// bridged together. Everything else (a router, a firewall, a PC, a server,
  /// a phone, an access point) presents a host/DTE-style port.
  static const Set<String> _switchLike = {
    'switch',
    'hub',
    'bridge',
    'cloud',
    'modem',
    'wlc',
  };

  /// True when a copper link between these two device kinds needs a CROSSOVER
  /// cable rather than the default straight-through.
  ///
  /// The rule is "crossover when both ends are the same shape" - router to
  /// router, switch to switch, PC to PC, and a host plugged straight into a
  /// router all put transmit on the pin the other end transmits on, which is
  /// exactly what a straight-through cable cannot carry. A straight-through is
  /// only correct between a switch port and something that is not another
  /// switch port.
  ///
  /// This is not cosmetic. Packet Tracer holds such a link DOWN: both ports
  /// stay down, the cable is drawn red, and every packet that has to cross it
  /// is dropped in simulation - so a generated two-router lab's whole transit
  /// network was dead on arrival while the file itself looked perfect.
  static bool pairNeedsCrossover(String typeA, String typeB) {
    final a = typeA.trim().toLowerCase();
    final b = typeB.trim().toLowerCase();
    return _switchLike.contains(a) == _switchLike.contains(b);
  }
}

/// One device kind the planner can put on the canvas.
///
/// A single table instead of six scattered `if (type == ...)` ladders: the
/// planner reads the keywords, the adapters read `cli`/`ipConfig`/`wired`,
/// and the executor gets the interface name in `port`, so adding a device is
/// one entry rather than a change in five files.
/// One account a brief actually supplies, with where it was said.
///
/// [at] and [text] are what let a parser decide WHICH server the credential
/// belongs to: the account is found inside a sentence, and the node named
/// nearest in front of that sentence is the one it configures.
class Credential {
  final String username;
  final String password;

  /// Offset in the source text where the credential was written.
  final int at;

  /// The matched phrase, for the same ownership decision.
  final String text;

  const Credential(this.username, this.password, this.at, this.text);
}

/// A single table instead of six scattered `if (type == ...)` ladders: the
/// planner reads the keywords, the adapters read `cli`/`ipConfig`/`wired`,
/// and the executor gets the interface name in `port`, so adding a device is
/// one entry rather than a change in five files.
class DeviceKind {
  final String type;

  /// Words that request this kind.  Matched case-insensitively, longest
  /// phrase first, so 'wireless controller' never reads as 'wireless'.
  final List<String> keywords;

  /// Best-fit Packet Tracer models, preferred first.
  final List<String> models;

  /// The interface spec used when this device hangs off a switch.  Empty
  /// means the executor must not invent a cable for it.
  final String port;

  /// Has an IOS-style CLI in Packet Tracer (so it can be typed into).
  final bool cli;

  /// Configured through Desktop > IP Configuration.
  final bool ipConfig;

  /// Joins the network wirelessly (no cable; PT associates it with the AP).
  final bool wireless;

  const DeviceKind({
    required this.type,
    required this.keywords,
    required this.models,
    this.port = '',
    this.cli = false,
    this.ipConfig = false,
    this.wireless = false,
  });

  bool get wired => port.isNotEmpty;
}

/// Every device kind the offline planner understands.  Packet Tracer 9.x
/// names are used verbatim, because that is what the executor clicks.

/// Canonical node-name prefixes per device kind (FW1, AP1, ISP1, ...).

String devicePrefix(String type) =>
    devicePrefixes[type] ?? type.toUpperCase();

/// The kind with this canonical type, or null.
DeviceKind? deviceKindOf(String type) {
  final t = type.trim().toLowerCase();
  for (final kind in deviceKinds) {
    if (kind.type == t) return kind;
  }
  return null;
}

/// The kind whose keyword matches this text first (longest keyword wins).
DeviceKind? deviceKindFor(String word) {
  final w = word.trim().toLowerCase();
  DeviceKind? best;
  var bestLen = 0;
  for (final kind in deviceKinds) {
    for (final k in kind.keywords) {
      if (k == w && k.length > bestLen) {
        best = kind;
        bestLen = k.length;
      }
    }
  }
  return best;
}

class InterfaceAddr {
  final String node;
  final String iface;
  final String ipCidr; // e.g. 192.168.1.1/24

  /// Optional IPv6 address for this interface, e.g. 2001:db8:1::1/64.
  /// Router interfaces get it spelled out; endpoints are left null and use
  /// SLAAC/autoconfig against the router advertisement instead.
  final String? ip6Cidr;

  const InterfaceAddr({
    required this.node,
    required this.iface,
    required this.ipCidr,
    this.ip6Cidr,
  });

  Map<String, dynamic> toJson() => {
    'node': node,
    'iface': iface,
    'ipCidr': ipCidr,
    if (ip6Cidr != null) 'ip6Cidr': ip6Cidr,
  };

  factory InterfaceAddr.fromJson(Map<String, dynamic> j) => InterfaceAddr(
    node: j['node'] as String,
    iface: j['iface'] as String,
    ipCidr: j['ipCidr'] as String,
    ip6Cidr: j['ip6Cidr'] is String && (j['ip6Cidr'] as String).isNotEmpty
        ? j['ip6Cidr'] as String
        : null,
  );
}

/// Structured security requirements.  This is intentionally target-neutral:
/// adapters decide how to compile each requested control for IOS/Packet
/// Tracer, while the planner keeps the user's intent and open questions
/// visible before execution.
class SecurityIntent {
  final bool portSecurity;
  final bool dhcpSnooping;
  final String? dhcpTrustedInterface;
  final bool aaa;
  final String aaaProtocol;
  final String? aaaServer;
  final String? aaaRouter;
  final String? aaaUsername;

  /// The shared secret the AAA client and the AAA server both know (written
  /// as `tacacs-server key` on the router and as the client entry on the
  /// server).
  ///
  /// Deliberately NOT the account password: a brief that says "add user
  /// netadmin with password X ... using the same shared key on the server and
  /// router" has supplied the account and left the key unsaid, and the app must
  /// not invent one. See [aaaAccountPassword] for the other half.
  final String? aaaPassword;

  /// The password of [aaaUsername] ON THE ACCOUNT SERVER.
  ///
  /// This is what the router needs for its own local login line
  /// (`username <name> secret 0 <password>`), so the account matches what the
  /// server holds.  Keeping it apart from [aaaPassword] is what lets a plan
  /// carry a real account without claiming a shared key nobody supplied.
  final String? aaaAccountPassword;
  final bool telnet;
  final String? managerIp;
  final String? officeHours;
  final bool extendedAcl;
  final String? branchNetwork;
  final String? protectedServerIp;
  final String? allowedWebServerIp;
  final bool ipsecVpn;
  final String? vpnPeerA;
  final String? vpnPeerB;
  final String? vpnEncryption;
  final String? vpnHash;
  final String? vpnPreSharedKey;
  final String? vpnLocalNetwork;
  final String? vpnRemoteNetwork;

  /// Secure device access: SSH replaces Telnet on VTY lines (router AND
  /// switch), with the keys/certificate Packet Tracer can generate locally.
  final bool ssh;

  /// EtherChannel between the switches (or switch and router): LACP by
  /// default, PAgP when the brief says so.
  final bool etherChannel;
  final String etherChannelProtocol; // lacp | pagp

  /// Router-redundancy on the LAN gateways (HSRP; PT also accepts VRRP/GLBP
  /// wording but HSRP is what its images implement).
  final bool hsrp;
  final String? hsrpVirtualIp;

  /// Layer-2 hardening of the access layer: rapid STP root bridge pinned.
  final bool spanningTree;

  /// Router-on-a-stick: one router interface, one dot1Q sub-interface per
  /// VLAN. Turned on automatically when VLANs exist and a router is cabled
  /// to a switch, unless the brief asked for a plain flat LAN.
  final bool interVlanRouting;

  /// Enable-mode password policy the lab briefs keep asking for.
  final bool consolePassword;
  final String? enableSecret;

  final List<String> tests;

  const SecurityIntent({
    this.portSecurity = false,
    this.dhcpSnooping = false,
    this.dhcpTrustedInterface,
    this.aaa = false,
    this.aaaProtocol = 'tacacs+',
    this.aaaServer,
    this.aaaRouter,
    this.aaaUsername,
    this.aaaPassword,
    this.aaaAccountPassword,
    this.telnet = false,
    this.managerIp,
    this.officeHours,
    this.extendedAcl = false,
    this.branchNetwork,
    this.protectedServerIp,
    this.allowedWebServerIp,
    this.ipsecVpn = false,
    this.vpnPeerA,
    this.vpnPeerB,
    this.vpnEncryption,
    this.vpnHash,
    this.vpnPreSharedKey,
    this.vpnLocalNetwork,
    this.vpnRemoteNetwork,
    this.ssh = false,
    this.etherChannel = false,
    this.etherChannelProtocol = 'lacp',
    this.hsrp = false,
    this.hsrpVirtualIp,
    this.spanningTree = false,
    this.interVlanRouting = false,
    this.consolePassword = false,
    this.enableSecret,
    this.tests = const [],
  });

  /// The same intent with [count] fields replaced.
  ///
  /// Every field has a default, so a caller can name only what it changes and
  /// leave the rest standing - which is what keeps the repair pass from having
  /// to restate thirty fields to add one credential.
  SecurityIntent copyWith({
    bool? portSecurity,
    bool? dhcpSnooping,
    String? dhcpTrustedInterface,
    bool? aaa,
    String? aaaProtocol,
    String? aaaServer,
    String? aaaRouter,
    String? aaaUsername,
    String? aaaPassword,
    String? aaaAccountPassword,
    bool? telnet,
    String? managerIp,
    String? officeHours,
    bool? extendedAcl,
    String? branchNetwork,
    String? protectedServerIp,
    String? allowedWebServerIp,
    bool? ipsecVpn,
    String? vpnPeerA,
    String? vpnPeerB,
    String? vpnEncryption,
    String? vpnHash,
    String? vpnPreSharedKey,
    String? vpnLocalNetwork,
    String? vpnRemoteNetwork,
    bool? ssh,
    bool? etherChannel,
    String? etherChannelProtocol,
    bool? hsrp,
    String? hsrpVirtualIp,
    bool? spanningTree,
    bool? interVlanRouting,
    bool? consolePassword,
    String? enableSecret,
    List<String>? tests,
  }) => SecurityIntent(
    portSecurity: portSecurity ?? this.portSecurity,
    dhcpSnooping: dhcpSnooping ?? this.dhcpSnooping,
    dhcpTrustedInterface: dhcpTrustedInterface ?? this.dhcpTrustedInterface,
    aaa: aaa ?? this.aaa,
    aaaProtocol: aaaProtocol ?? this.aaaProtocol,
    aaaServer: aaaServer ?? this.aaaServer,
    aaaRouter: aaaRouter ?? this.aaaRouter,
    aaaUsername: aaaUsername ?? this.aaaUsername,
    aaaPassword: aaaPassword ?? this.aaaPassword,
    aaaAccountPassword: aaaAccountPassword ?? this.aaaAccountPassword,
    telnet: telnet ?? this.telnet,
    managerIp: managerIp ?? this.managerIp,
    officeHours: officeHours ?? this.officeHours,
    extendedAcl: extendedAcl ?? this.extendedAcl,
    branchNetwork: branchNetwork ?? this.branchNetwork,
    protectedServerIp: protectedServerIp ?? this.protectedServerIp,
    allowedWebServerIp: allowedWebServerIp ?? this.allowedWebServerIp,
    ipsecVpn: ipsecVpn ?? this.ipsecVpn,
    vpnPeerA: vpnPeerA ?? this.vpnPeerA,
    vpnPeerB: vpnPeerB ?? this.vpnPeerB,
    vpnEncryption: vpnEncryption ?? this.vpnEncryption,
    vpnHash: vpnHash ?? this.vpnHash,
    vpnPreSharedKey: vpnPreSharedKey ?? this.vpnPreSharedKey,
    vpnLocalNetwork: vpnLocalNetwork ?? this.vpnLocalNetwork,
    vpnRemoteNetwork: vpnRemoteNetwork ?? this.vpnRemoteNetwork,
    ssh: ssh ?? this.ssh,
    etherChannel: etherChannel ?? this.etherChannel,
    etherChannelProtocol: etherChannelProtocol ?? this.etherChannelProtocol,
    hsrp: hsrp ?? this.hsrp,
    hsrpVirtualIp: hsrpVirtualIp ?? this.hsrpVirtualIp,
    spanningTree: spanningTree ?? this.spanningTree,
    interVlanRouting: interVlanRouting ?? this.interVlanRouting,
    consolePassword: consolePassword ?? this.consolePassword,
    enableSecret: enableSecret ?? this.enableSecret,
    tests: tests ?? this.tests,
  );

  bool get requested =>
      portSecurity ||
      dhcpSnooping ||
      aaa ||
      telnet ||
      managerIp != null ||
      extendedAcl ||
      ipsecVpn ||
      ssh ||
      etherChannel ||
      hsrp ||
      spanningTree ||
      interVlanRouting ||
      consolePassword ||
      enableSecret != null;

  Map<String, dynamic> toJson({bool includeSecrets = true}) => {
    'portSecurity': portSecurity,
    'dhcpSnooping': dhcpSnooping,
    if (dhcpTrustedInterface != null)
      'dhcpTrustedInterface': dhcpTrustedInterface,
    'aaa': aaa,
    'aaaProtocol': aaaProtocol,
    if (aaaServer != null) 'aaaServer': aaaServer,
    if (aaaRouter != null) 'aaaRouter': aaaRouter,
    if (aaaUsername != null) 'aaaUsername': aaaUsername,
    // Passwords are needed by the executor, but are never included in
    // notes/search context by the UI.  Keep the intent export explicit.
    if (includeSecrets && aaaPassword != null) 'aaaPassword': aaaPassword,
    if (includeSecrets && aaaAccountPassword != null)
      'aaaAccountPassword': aaaAccountPassword,
    'telnet': telnet,
    if (managerIp != null) 'managerIp': managerIp,
    if (officeHours != null) 'officeHours': officeHours,
    'extendedAcl': extendedAcl,
    if (branchNetwork != null) 'branchNetwork': branchNetwork,
    if (protectedServerIp != null) 'protectedServerIp': protectedServerIp,
    if (allowedWebServerIp != null) 'allowedWebServerIp': allowedWebServerIp,
    'ipsecVpn': ipsecVpn,
    if (vpnPeerA != null) 'vpnPeerA': vpnPeerA,
    if (vpnPeerB != null) 'vpnPeerB': vpnPeerB,
    if (vpnEncryption != null) 'vpnEncryption': vpnEncryption,
    if (vpnHash != null) 'vpnHash': vpnHash,
    if (includeSecrets && vpnPreSharedKey != null)
      'vpnPreSharedKey': vpnPreSharedKey,
    if (vpnLocalNetwork != null) 'vpnLocalNetwork': vpnLocalNetwork,
    if (vpnRemoteNetwork != null) 'vpnRemoteNetwork': vpnRemoteNetwork,
    'ssh': ssh,
    'etherChannel': etherChannel,
    'etherChannelProtocol': etherChannelProtocol,
    'hsrp': hsrp,
    if (hsrpVirtualIp != null) 'hsrpVirtualIp': hsrpVirtualIp,
    'spanningTree': spanningTree,
    'interVlanRouting': interVlanRouting,
    'consolePassword': consolePassword,
    if (includeSecrets && enableSecret != null) 'enableSecret': enableSecret,
    if (tests.isNotEmpty) 'tests': tests,
  };

  factory SecurityIntent.fromJson(Map<String, dynamic> j) => SecurityIntent(
    portSecurity: j['portSecurity'] == true,
    dhcpSnooping: j['dhcpSnooping'] == true,
    dhcpTrustedInterface: j['dhcpTrustedInterface'] as String?,
    aaa: j['aaa'] == true,
    aaaProtocol: j['aaaProtocol'] as String? ?? 'tacacs+',
    aaaServer: _optionalText(j['aaaServer']),
    aaaRouter: _optionalText(j['aaaRouter']),
    aaaUsername: _optionalText(j['aaaUsername']),
    aaaPassword: _optionalText(j['aaaPassword']),
    aaaAccountPassword: _optionalText(j['aaaAccountPassword']),
    telnet: j['telnet'] == true,
    managerIp: _optionalText(j['managerIp']),
    officeHours: _optionalText(j['officeHours']),
    extendedAcl: j['extendedAcl'] == true,
    branchNetwork: _optionalText(j['branchNetwork']),
    protectedServerIp: _optionalText(j['protectedServerIp']),
    allowedWebServerIp: _optionalText(j['allowedWebServerIp']),
    ipsecVpn: j['ipsecVpn'] == true,
    vpnPeerA: _optionalText(j['vpnPeerA']),
    vpnPeerB: _optionalText(j['vpnPeerB']),
    vpnEncryption: _optionalText(j['vpnEncryption']),
    vpnHash: _optionalText(j['vpnHash']),
    vpnPreSharedKey: _optionalText(j['vpnPreSharedKey']),
    vpnLocalNetwork: _optionalText(j['vpnLocalNetwork']),
    vpnRemoteNetwork: _optionalText(j['vpnRemoteNetwork']),
    ssh: j['ssh'] == true,
    etherChannel: j['etherChannel'] == true,
    etherChannelProtocol: (j['etherChannelProtocol'] as String?) == 'pagp'
        ? 'pagp'
        : 'lacp',
    hsrp: j['hsrp'] == true,
    hsrpVirtualIp: _optionalText(j['hsrpVirtualIp']),
    spanningTree: j['spanningTree'] == true,
    interVlanRouting: j['interVlanRouting'] == true,
    consolePassword: j['consolePassword'] == true,
    enableSecret: _optionalText(j['enableSecret']),
    tests: ((j['tests'] as List?) ?? []).map((e) => e.toString()).toList(),
  );

  static String? _optionalText(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    const placeholders = {
      'only when supplied',
      'only when provided',
      'ip',
      'cidr',
      'string',
    };
    return placeholders.contains(text.toLowerCase()) ? null : text;
  }
}

/// One question the planner puts to the user BEFORE the plan is executed, as a
/// popup with buttons rather than a sentence buried in the answer.
///
/// It exists for briefs that contradict themselves: "a corporate network for 40
/// users ... 15 PCs ... 10 PCs" asks for 40 seats and then lists 25. Both
/// readings are defensible, so the app builds the list it was given and asks -
/// instead of choosing silently for the user. Silently is what happened: 35
/// devices were built, the audit said "nothing to fix", and the 15 missing PCs
/// were never mentioned in the answer or the file.
class PlanPrompt {
  /// Stable identity, so one disagreement is asked about once, not every turn.
  final String id;
  final String title;
  final String message;
  final List<PlanPromptOption> options;

  const PlanPrompt({
    required this.id,
    required this.title,
    required this.message,
    this.options = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'message': message,
    'options': options.map((o) => o.toJson()).toList(),
  };

  factory PlanPrompt.fromJson(Map<String, dynamic> j) => PlanPrompt(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    message: j['message'] as String? ?? '',
    options: ((j['options'] as List?) ?? const [])
        .map(
          (e) => PlanPromptOption.fromJson(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList(),
  );
}

/// One button in a [PlanPrompt].
///
/// [reply] is sent as the user's own next message when the button is pressed,
/// so the choice travels the same planning path a typed request does. An empty
/// reply only closes the popup ("keep what I listed"), so agreeing to nothing
/// can never change the plan by accident.
class PlanPromptOption {
  final String label;
  final String reply;

  /// The option the app would pick - shown first, and highlighted by the UI.
  final bool recommended;

  const PlanPromptOption({
    required this.label,
    this.reply = '',
    this.recommended = false,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'reply': reply,
    'recommended': recommended,
  };

  factory PlanPromptOption.fromJson(Map<String, dynamic> j) =>
      PlanPromptOption(
        label: j['label'] as String? ?? '',
        reply: j['reply'] as String? ?? '',
        recommended: j['recommended'] as bool? ?? false,
      );
}

/// What kind of ADVISORY turn a message is, if any.
///
/// Advice is a turn that asks for a CHOICE, a SIZE, a COMPARISON or a
/// REVIEW - the questions whose answer is a recommendation with its
/// trade-offs, not a configuration step and not a new topology. The reader
/// is deliberately narrow:
///
/// * a device COUNT makes it a build request ("recommend 2 routers" plans),
/// * a protocol configuration question stays how-to (the concept and
///   knowledge answers own those), and
/// * something merely shaped like a question ("what cable do I use between
///   two switches") stays with the knowledge table: only phrasings that
///   really ask to choose, size, compare or review become advice.
///
/// Nothing here may ever change the plan: [NetworkIntent.followUp] uses the
/// same reader so an advice turn is never read as a specification.
enum AdviceKind {
  none,

  /// "Which router should I use?", "What firewall do we need?"
  recommendation,

  /// "Fiber or copper?", "Is Wi-Fi 6 worth it over Wi-Fi 5?"
  comparison,

  /// "How many access points for 50 users?"
  sizing,

  /// "Review my design", "What would you improve?"
  review,

  /// "The wifi is slow in the back office - what should I do?"
  troubleshoot,
}

/// The public reading of a message as an advisory turn, for the assistant
/// and for the message-understanding card.
class AdviceIntentReader {
  const AdviceIntentReader._();

  /// Asking for a recommendation in so many words.
  static final RegExp _adviceWords = RegExp(
    r'\b(?:recommend(?:ation|ations|ed|s)?|advice|advise|'
    r'suggest(?:ion|ions|ed|s)?|your opinion|'
    r'what would you (?:do|use|pick|choose)|what should i (?:do|use|get|buy)|'
    r'best approach|best practices?|worth it|is it worth|pros and cons|'
    r'trade-?offs?)\b',
    caseSensitive: false,
  );

  /// Reviewing an existing design.
  static final RegExp _reviewWords = RegExp(
    r'\b(?:review|improve|evaluate|critique|look over|go over|'
    r'sanity[- ]check)\b',
    caseSensitive: false,
  );

  /// The object advice can be about. A phrase without one of these is too
  /// vague to answer as advice.
  static final RegExp _topicWords = RegExp(
    r'\b(?:routers?|switches|switch|firewalls?|aps?|access points?|'
    r'wifi|wi-fi|wireless|mesh|modem|gateway|poe|power over ethernet|'
    r'cables?|cabling|fiber|fibre|copper|cat ?[568]e?|isp|internet|wan|vpn|'
    r'networks?|design|infrastructure|bandwidth|vlans?|ports?|devices?|'
    r'labs?|packet tracer|gns3|models?|port forwarding|ptz|cameras?|cctv|'
    r'nvr|phones?|voip|servers?|rack|ups|guest|'
    // Lab model numbers are topics too: "which is better, 2911 or 4331?"
    // is a comparison, and without these the ask fell through to the
    // missing-coverage reply because no noun it named was a topic word.
    // The families are the ones the lab-models answer covers (the Packet
    // Tracer routers/switches/APs and the ASA/ISA firewalls); keep this
    // list in step with the model table in advisor_service.dart.
    r'2950|2960|3560|1841|1941|2811|2901|2911|4321|4331|'
    r'isr ?4321|isr ?4331|isr|catalyst|asa|isa-?3000)\b',
    caseSensitive: false,
  );

  /// The choice phrasings. "what" alone is NOT one: "what cable do I use
  /// between two switches" is a knowledge question. It only becomes a
  /// selection when it names the thing to choose, or asks a decision
  /// question ("should we separate...?", "do we need...?", "where should
  /// we put the server?") about a topic this reader recognizes.
  static final RegExp _selectionWords = RegExp(
    r'\b(?:which|best|pick|choose|should|do (?:i|we|you|they) need|'
    r'where should|how should|would you '
    r'(?:use|pick|choose|recommend|go with)|'
    r'what (?:router|routers|switch|switches|firewall|firewalls|ap|aps|'
    r'access point|access points|modem|gateway|brand|model|wifi|'
    r'wi-fi|wireless|vpn|isp|poe))\b',
    caseSensitive: false,
  );

  static final RegExp _sizingWords = RegExp(
    r'\b(?:how many|how much (?:bandwidth|throughput|speed)|'
    r'size (?:the|my)|sizing|enough (?:for|to))\b',
    caseSensitive: false,
  );

  static final RegExp _comparisonWords = RegExp(
    r'\b(?:vs\.?|versus|difference between|which is better|better than|'
    r'compared (?:to|with))\b',
    caseSensitive: false,
  );

  static final RegExp _troubleWords = RegExp(
    r'\b(?:slow|sluggish|dead ?spots?|unstable|'
    r'keeps? (?:dropping|disconnecting|cutting)|drops? out|buffering|'
    r'lag(?:gy)?|congested|overloaded|coverage)\b',
    caseSensitive: false,
  );

  /// "A or B?" with a subject on BOTH sides ("port forwarding or vpn?",
  /// "mesh or access points?") is a comparison, but only when it is a
  /// question: "add a router or switch" is an addition, not advice.
  static bool _orPair(String t) {
    if (!t.endsWith('?') &&
        !RegExp(r'^(?:which|what|should|is|are|do|does|can|could|would)\b')
            .hasMatch(t)) {
      return false;
    }
    final parts = t.split(RegExp(r'\bor\b'));
    if (parts.length < 2) return false;
    return parts.where((p) => _topicWords.hasMatch(p)).length >= 2;
  }

  /// The lab model numbers, for the one comparison shape a bare message can
  /// carry: two models joined by "or" ("2911 or 4331"). Keep in step with
  /// [_topicWords] and with the model table in advisor_service.dart.
  static final RegExp _modelWords = RegExp(
    r'\b(?:2950|2960|3560|1841|1941|2811|2901|2911|4321|4331|'
    r'isr ?4321|isr ?4331|asa|isa-?3000)\b',
    caseSensitive: false,
  );

  /// What turns a bare model pair into a REQUEST instead of a choice - the
  /// build/change verb family, plus the "2 x 2911" counted-spec shape. A
  /// counted build brief that happens to name models must never read as
  /// advice.
  static final RegExp _modelPairBuildGuard = RegExp(
    r'\b(?:add|adding|build|create|design|make|set ?up|setup|connect|'
    r'configure|use|deploy|install|remove|delete|replace|convert|include|'
    r'attach)\b|\b\d{1,3}\s*x\s*\d',
    caseSensitive: false,
  );

  /// "2911 or 4331", "2960 or 3560 for my lab" - two lab models joined by
  /// "or" are a comparison even without a question mark or question word,
  /// the same reading "fiber or copper?" gets. The guard keeps it from ever
  /// reading a build as advice: with a build verb ("add a 2911 or a 4331")
  /// or a counted spec ("2 x 2911") the message is a request, not a choice.
  static bool _modelPair(String t) {
    if (_modelPairBuildGuard.hasMatch(t)) return false;
    final parts = t.split(RegExp(r'\bor\b'));
    if (parts.length < 2) return false;
    return parts.where(_modelWords.hasMatch).length >= 2;
  }

  /// The advisory reading of [brief], or [AdviceKind.none].
  static AdviceKind read(String brief) {
    final t = brief.trim().toLowerCase();
    if (t.isEmpty) return AdviceKind.none;
    final topic = _topicWords.hasMatch(t);
    if ((_comparisonWords.hasMatch(t) || _orPair(t)) && topic) {
      return AdviceKind.comparison;
    }
    // The bare model pair - the one "A or B" that needs no question shape,
    // because a message made of two model numbers is never a build request.
    if (_modelPair(t)) return AdviceKind.comparison;
    if (_sizingWords.hasMatch(t) && topic) return AdviceKind.sizing;
    if (_reviewWords.hasMatch(t) && topic) return AdviceKind.review;
    if (_adviceWords.hasMatch(t)) {
      if (topic && _troubleWords.hasMatch(t)) return AdviceKind.troubleshoot;
      return AdviceKind.recommendation;
    }
    if (_troubleWords.hasMatch(t) && topic) return AdviceKind.troubleshoot;
    if (_selectionWords.hasMatch(t) && topic) return AdviceKind.recommendation;
    return AdviceKind.none;
  }
}

class NetworkIntent {
  final String projectName;
  final List<NetNode> nodes;
  final List<NetLink> links;
  final List<InterfaceAddr> addressing;
  final List<int> vlans;
  final String routing; // static, ospf, eigrp, bgp, none
  final List<String> notes;

  /// Explainability metadata. These are shown to the user before execution.
  final List<String> assumptions;
  final List<String> questions;
  final double confidence;
  final String planningSource;
  final SecurityIntent security;

  /// Drag positions for the topology canvas, keyed by node name.
  /// A null value means "auto-layout this node". Persisted with the plan.
  final Map<String, Offset?> layout;

  /// Contradictions in the brief the user still has to settle (see
  /// [PlanPrompt]). The UI asks them as popups, never as prose the user has to
  /// notice in a wall of text.
  final List<PlanPrompt> prompts;

  const NetworkIntent({
    required this.projectName,
    this.nodes = const [],
    this.links = const [],
    this.addressing = const [],
    this.vlans = const [],
    this.routing = 'static',
    this.notes = const [],
    this.assumptions = const [],
    this.questions = const [],
    this.confidence = 0.5,
    this.planningSource = 'local',
    this.security = const SecurityIntent(),
    this.layout = const {},
    this.prompts = const [],
  });

  Map<String, dynamic> toJson({bool includeSecrets = true}) => {
    'projectName': projectName,
    'nodes': nodes
        .map((e) => e.toJson(includeSecrets: includeSecrets))
        .toList(),
    'links': links.map((e) => e.toJson()).toList(),
    'addressing': addressing.map((e) => e.toJson()).toList(),
    'vlans': vlans,
    'routing': routing,
    // The notes quote the brief, and a brief carries credentials typed in
    // plain sight. The portable export redacts them again even though the
    // notes are already written redacted, because notes can also arrive from
    // a stored intent, a model reply or an older build.
    'notes': includeSecrets ? notes : notes.map(redactSecrets).toList(),
    'assumptions': assumptions,
    'questions': questions,
    'confidence': confidence,
    'planningSource': planningSource,
    'security': security.toJson(includeSecrets: includeSecrets),
    if (layout.isNotEmpty)
      'layout': layout.map((k, v) => MapEntry(
          k,
          v == null
              ? null
              : {'x': v.dx, 'y': v.dy})),
    if (prompts.isNotEmpty)
      'prompts': prompts.map((e) => e.toJson()).toList(),
  };

  /// Safe copy for third-party planners.  Credentials remain in the local
  /// intent used for execution, but are not sent in the Gemini prompt.
  Map<String, dynamic> toPlannerJson() => toJson(includeSecrets: false);

  /// A short, stable identity for THIS version of the plan.
  ///
  /// Two plans with the same devices, links, addressing, routing and requested
  /// services share a revision; any real edit changes it. Canvas drag
  /// positions and the parser's prose fields are deliberately left out, so
  /// nudging a box or re-reading the same brief never makes a build card look
  /// stale.
  ///
  /// The project name is left out for the same reason: the chat plans the same
  /// brief as `chat` on the model path and as `offline-chat` on the keyless
  /// path, and hashing the name gave one network two revisions. A build card
  /// written by the path that answered was then "stale" against the other
  /// path's copy of the identical plan - the button read "Fix the plan first"
  /// for a plan whose findings had not changed at all, and there was nothing
  /// the user could do about it.
  ///
  /// Every display and every action reads this, which is what stops a build
  /// card, the plan summary and the compiled file from describing three
  /// different networks.
  String get revision {
    final b = StringBuffer()
      ..write('|routing:')
      ..write(routing)
      ..write('|vlans:')
      ..write((vlans.toList()..sort()).join(','));
    for (final n in nodes) {
      final services = n.services.map((s) => s.toLowerCase()).toList()..sort();
      b
        ..write('|n:')
        ..write(n.name)
        ..write('/')
        ..write(n.type)
        ..write('/')
        ..write(n.model ?? '')
        ..write('/')
        ..write(services.join(','));
    }
    for (final l in links) {
      b
        ..write('|l:')
        ..write(l.a)
        ..write(':')
        ..write(l.aIf)
        ..write('-')
        ..write(l.b)
        ..write(':')
        ..write(l.bIf);
    }
    for (final a in addressing) {
      b
        ..write('|a:')
        ..write(a.node)
        ..write(':')
        ..write(a.iface)
        ..write('=')
        ..write(a.ipCidr);
    }
    b.write('|sec:${jsonEncode(security.toJson(includeSecrets: false))}');
    return _shortHash(b.toString());
  }

  /// A plan version a person can read: "17 device(s), 16 link(s), rev 3f9a1c02".
  /// The plan's links with a physically correct cable kind filled in.
  ///
  /// The executor's plan payload is written from this list, so the crossover
  /// decision is made once, in one place, for the offline compiler and the
  /// live run alike. A link that already names its cable - a serial WAN, a
  /// fibre uplink, a crossover asked for by name - is left exactly as it is,
  /// and so is anything whose interfaces are Serial ports (those are wired as
  /// serial whatever the field says).
  ///
  /// The revision does not hash the cable kind, so filling it in cannot
  /// invalidate a build card that is already on screen.
  List<NetLink> get wiredLinks {
    final types = <String, String>{
      for (final n in nodes) n.name.toLowerCase(): n.type.toLowerCase(),
    };
    return [
      for (final l in links)
        if (l.isSerial || !_isCopperCable(l.cable))
          l
        else
          NetLink(
            a: l.a,
            aIf: l.aIf,
            b: l.b,
            bIf: l.bIf,
            cable: NetLink.pairNeedsCrossover(
              types[l.a.toLowerCase()] ?? '',
              types[l.b.toLowerCase()] ?? '',
            )
                ? 'copper-cross'
                : (l.cable ?? 'copper'),
            dce: l.dce,
          ),
    ];
  }

  static bool _isCopperCable(String? cable) {
    final c = (cable ?? '').trim().toLowerCase();
    return c.isEmpty || c == 'copper' || c == 'straight' || c == 'copper-cross' ||
        c == 'cross' || c == 'crossover';
  }

  String get revisionLabel =>
      '${nodes.length} device(s), ${links.length} link(s), rev $revision';

  /// FNV-1a, 32-bit, rendered as 8 hex digits. Not a security hash - just a
  /// cheap, stable identity so two different plans cannot look like the same.
  static String _shortHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  factory NetworkIntent.fromJson(Map<String, dynamic> j) => NetworkIntent(
    projectName: j['projectName'] as String? ?? 'net',
    nodes: ((j['nodes'] as List?) ?? [])
        .map((e) => NetNode.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    links: ((j['links'] as List?) ?? [])
        .map((e) => NetLink.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    addressing: ((j['addressing'] as List?) ?? [])
        .map((e) => InterfaceAddr.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    vlans: ((j['vlans'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList(),
    routing: j['routing'] as String? ?? 'static',
    notes: ((j['notes'] as List?) ?? []).map((e) => e.toString()).toList(),
    assumptions: ((j['assumptions'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(),
    questions: ((j['questions'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(),
    confidence: ((j['confidence'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
    planningSource: j['planningSource'] as String? ?? 'local',
    security: SecurityIntent.fromJson(
      Map<String, dynamic>.from((j['security'] as Map?) ?? const {}),
    ),
    layout: ((j['layout'] as Map?) ?? const {}).map((k, v) => MapEntry(
      k.toString(),
      v == null
          ? null
          : Offset(((v as Map)['x'] as num?)?.toDouble() ?? 0,
              ((v)['y'] as num?)?.toDouble() ?? 0),
    )),
    prompts: ((j['prompts'] as List?) ?? const [])
        .map((e) => PlanPrompt.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );

  NetworkIntent copyWith({
    String? projectName,
    List<NetNode>? nodes,
    List<NetLink>? links,
    List<InterfaceAddr>? addressing,
    List<int>? vlans,
    String? routing,
    List<String>? notes,
    List<String>? assumptions,
    List<String>? questions,
    double? confidence,
    String? planningSource,
    SecurityIntent? security,
    Map<String, Offset?>? layout,
    List<PlanPrompt>? prompts,
  }) => NetworkIntent(
    projectName: projectName ?? this.projectName,
    nodes: nodes ?? this.nodes,
    links: links ?? this.links,
    addressing: addressing ?? this.addressing,
    vlans: vlans ?? this.vlans,
    routing: routing ?? this.routing,
    notes: notes ?? this.notes,
    assumptions: assumptions ?? this.assumptions,
    questions: questions ?? this.questions,
    confidence: confidence ?? this.confidence,
    planningSource: planningSource ?? this.planningSource,
    security: security ?? this.security,
    layout: layout ?? this.layout,
    prompts: prompts ?? this.prompts,
  );

  /// PT model catalog for best-fit selection.
  static const ptRouters = ['4331', '2911', '1941', '4321', '2901', '829'];
  static const ptSwitches = ['2960', '2950', '3560'];

  /// How many FastEthernet ports a Packet Tracer switch model actually has.
  ///
  /// A plan that hands a 24-port switch 32 cables produces a file whose cables
  /// point at interfaces the device does not have, and nothing in the build
  /// path notices.  The count is the "-24" of 2960-24TT, taken from the model
  /// name; a model this does not know is treated as 24, the smallest in the
  /// catalogue, so an unknown device is never assumed to have more.
  static int switchPortCapacity(String? model) {
    final m = (model ?? '').trim().toLowerCase();
    if (m.isEmpty) return 24;
    final match = RegExp(r'-(\d{1,3})\s*$').firstMatch(m);
    if (match == null) return 24;
    final n = int.tryParse(match.group(1)!);
    if (n == null || n <= 0) return 24;
    return n;
  }

  /// Pick the best PT model for the job from instruction text.
  /// Explicit mention wins ("use 4331"); else best-fit by workload.
  static String bestRouterModel(String lower) {
    for (final m in ptRouters) {
      if (lower.contains(m)) return m;
    }
    if (lower.contains('bgp') ||
        lower.contains('enterprise') ||
        lower.contains('4331')) {
      return '4331'; // ISR 4331: BGP/enterprise throughput
    }
    if (lower.contains('small') ||
        lower.contains('lab only') ||
        lower.contains('budget') ||
        lower.contains('1941')) {
      return '1941'; // small branch/lab
    }
    return '2911'; // default: 3x GE, IOS15, OSPF/EIGRP capable
  }

  static String bestSwitchModel(String lower) {
    for (final m in ptSwitches) {
      if (lower.contains(m)) return m;
    }
    return '2960';
  }

  static bool _looksLikeSecurityBranchLab(String lower) {
    // A brief that STATES DEVICE COUNTS is a specification of a lab, and it is
    // read as one. The profile is a fixed ten-device lab with its own
    // inventory, so letting it win threw the specification away: "Site A with
    // 2 routers, 2 switches, 3 servers and 15 PCs, Site B with 1 router, 1
    // switch, 1 server and 10 PCs" mentions "branch" and "AAA/TACACS+", matched
    // here, and came back as the profile's ten devices - 25 PCs lost. The same
    // hijack made "edit the file and give the branch its own AAA server" a
    // no-op, because the addition re-parsed to the profile and the merge
    // correctly refused to shrink a 33-device lab to ten.
    //
    // The profile briefs ask for CONTROLS ("harden the user ports", "rogue
    // DHCP") and let the app choose the inventory. A brief that counts its own
    // routers and servers has already chosen, and its numbers win.
    if (RegExp(
      r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
      r'printers?|firewalls?|phones?|tablets?|clouds?|modems?)\b',
    ).hasMatch(lower)) {
      return false;
    }
    final securityWords =
        lower.contains('ipsec') ||
        lower.contains('site-to-site') ||
        lower.contains('vpn') ||
        lower.contains('tunnel') ||
        lower.contains('tacacs') ||
        lower.contains('radius') ||
        lower.contains('aaa') ||
        lower.contains('centralized authentication') ||
        lower.contains('port security') ||
        lower.contains('user ports') ||
        lower.contains('dhcp snooping') ||
        lower.contains('rogue dhcp') ||
        lower.contains('time-based acl') ||
        lower.contains('extended acl') ||
        lower.contains('network security');
    // A brief that names CONTROLS and no device at all - "harden the network:
    // port security on the user ports, dhcp snooping, ssh instead of telnet
    // and aaa on the vty lines" - has left the inventory to the app, which is
    // what this profile is for. Without this it fell to the generic parser,
    // which built the one server its words named and nothing to attach it to:
    // a 1-device plan with four blocking findings that no reply could clear,
    // because "harden the network" says nothing a repair pass can read.
    return securityWords &&
        (_siteWording.hasMatch(lower) || _namesNoDevice(lower));
  }

  /// Does the brief name a device of its own?  When it does not, there is no
  /// inventory to honour and the app chooses one; when it does, the brief has
  /// already specified the lab and the counts win (see
  /// [_looksLikeSecurityBranchLab]).
  static final RegExp _deviceNoun = RegExp(
    r'\b(routers?|switches|switch|pcs?|computers?|workstations?|hosts?|'
    r'servers?|laptops?|printers?|firewalls?|aps?|access points?|phones?|'
    r'tablets?|smartphones?|clouds?|modems?|sites?|branches|headquarters|hq)\b',
  );

  static bool _namesNoDevice(String lower) => !_deviceNoun.hasMatch(lower);

  /// Where the brief says it is about sites.
  ///
  /// Word boundaries matter here, and not only for tidiness: this used to be
  /// `contains('wan')`, which matches the word **"want"**. So "I want 10 PCs"
  /// plus any one security word (AAA, VPN, tunnel, port security...) was read
  /// as a two-site WAN security lab, and the user's own lab was replaced by
  /// that profile's ten devices. A follow-up that only added AAA was enough to
  /// trigger it.
  static final RegExp _siteWording = RegExp(
    r'\bbranch|\bheadquarters|\bmain office|\bremote office|\bhq|\bbr_|'
    r'\bwans?\b',
  );

  /// Deterministic profile for the common two-site security-lab brief.  The
  /// normal lightweight parser remains unchanged for ordinary labs; this
  /// profile exists because the brief names roles (AAA/DHCP/web/manager)
  /// rather than giving device counts and explicit cables.
  static NetworkIntent _parseSecurityBranchLab(
    String projectName,
    String text,
  ) {
    final lower = text.toLowerCase();
    final routerModel = bestRouterModel(lower);
    final switchModel = bestSwitchModel(lower);
    // The original security profile predates the complete all-features brief
    // and intentionally described only three servers.  Keep that legacy
    // shape for older briefs, but select the full deterministic profile when
    // the request names SRV1 or all-features-lab.
    final isAllFeaturesLab =
        lower.contains('srv1') || lower.contains('all-features-lab');
    String? firstMatch(RegExp pattern) => pattern.firstMatch(text)?.group(1);
    // "08:00-17:00", "9:00 to 17:00", "from 8 until 16", "9 am to 5 pm" and
    // the Arabic connectors a translated brief arrives with.
    //
    // An ADDRESS RANGE is not a time range. "a pool of 192.168.10.100-
    // 192.168.10.200" matched the tail of the two addresses and produced
    // "weekdays 00-19", which the validator then reported as an unsupported
    // office-hours rule the user never asked for - and blocked the build on
    // it. Digits that are part of a dotted address are rejected.
    final hoursMatch = _timeRange(text);
    final wantsManager = lower.contains('manager') ||
        lower.contains('management access') ||
        lower.contains('office hours') ||
        lower.contains('office-hours') ||
        lower.contains('work hours') ||
        lower.contains('business hours') ||
        lower.contains('vty');
    // "username labadmin password X", "the username is labadmin and the
    // password is X", "اسم المستخدم labadmin كلمة المرور X" (bridged): all the
    // same request.  Credentials are read from the brief, never invented.
    //
    // Two guards keep a *description* out of this: a bare 'user'/'login' must
    // be followed by an explicit separator (so "user ports ... password" is
    // not a credential), and neither half may be one of the words itself (so
    // "the router asks for username and password" is not one either).
    const credentialStopWords = {
      'name',
      'user',
      'username',
      'password',
      'pass',
      'secret',
      'login',
      'account',
      'and',
      'or',
      'the',
      'with',
    };
    final credentialPattern = RegExp(
      r'(username|user|login|account|cli(?:ent)?\s?name|clinet\s?name)\s*'
      r'((?:is|:|=)\s*)?([A-Za-z0-9_.-]+)'
      r'[\s\S]{0,80}?(?:password|pass|secret)\s*(?:is|:|=)?\s*([^\s,.;:]+)',
      caseSensitive: false,
    );
    RegExpMatch? credentialMatch;
    // A rejected match must not consume the text it covered: 'the user ports
    // and the password policy' can swallow a real 'username labadmin with
    // password X' sitting inside it, so a rejection re-scans from one
    // character later instead of moving past the whole match.
    var cursor = 0;
    while (cursor < text.length) {
      final m = credentialPattern.firstMatch(text.substring(cursor));
      if (m == null) break;
      final keyword = m.group(1)!.toLowerCase();
      final separator = (m.group(2) ?? '').trim();
      final user = m.group(3)!;
      final pass = m.group(4)!;
      if (keyword == 'user' && separator.isEmpty) {
        cursor += m.start + 1;
        continue;
      }
      if (credentialStopWords.contains(user.toLowerCase()) ||
          credentialStopWords.contains(pass.toLowerCase()) ||
          RegExp(r'[\u0600-\u06ff]').hasMatch('$user$pass')) {
        cursor += m.start + 1;
        continue;
      }
      credentialMatch = m;
      break;
    }
    final ftpCredentialMatch = RegExp(
      r'\bftp\s+(?:user|username)\s+([A-Za-z0-9_.-]+)[^\n.]{0,80}?(?:password|pass)\s+([^\s,.]+)',
      caseSensitive: false,
    ).firstMatch(text);
    final emailDomainMatch = RegExp(
      r'\bemail\s+domain\s+([a-z0-9][a-z0-9.-]+)',
      caseSensitive: false,
    ).firstMatch(text);
    final emailDomain = emailDomainMatch
        ?.group(1)
        ?.replaceFirst(RegExp(r'[.,;]+$'), '');
    String? key = firstMatch(
      RegExp(
        r'(?:pre[- ]?shared|preshared|psk)\s*(?:key)?\s*(?:is|:|=)?\s*([^\s,.]+)',
        caseSensitive: false,
      ),
    );
    key ??= firstMatch(
      RegExp(
        r'\bkey\s*(?:is|:|=)\s*([^\s,.]+)',
        caseSensitive: false,
      ),
    );
    final nodes = <NetNode>[
      NetNode(name: 'HQ_Router', type: 'router', model: routerModel),
      NetNode(name: 'BR_Router', type: 'router', model: routerModel),
      NetNode(name: 'HQ_Switch', type: 'switch', model: switchModel),
      NetNode(name: 'BR_Switch', type: 'switch', model: switchModel),
      const NetNode(
        name: 'AAA1',
        type: 'server',
        model: 'Server-PT',
        services: ['aaa'],
      ),
      NetNode(
        name: 'DHCP1',
        type: 'server',
        model: 'Server-PT',
        services: isAllFeaturesLab ? const ['dhcp'] : const ['dhcp', 'dns'],
      ),
      NetNode(
        name: 'WEB1',
        type: 'server',
        model: 'Server-PT',
        services: ['http'],
        serviceRules: isAllFeaturesLab
            ? const {
                'http': {'https': true},
              }
            : const {},
      ),
      if (isAllFeaturesLab)
        NetNode(
          name: 'SRV1',
          type: 'server',
          model: 'Server-PT',
          services: const ['dns', 'ftp', 'email', 'ntp', 'tftp'],
          serviceRules: {
            'dns': {
              'records': const [
                {'name': 'hq-router.lab', 'address': '192.168.1.1'},
                {'name': 'br-router.lab', 'address': '192.168.2.1'},
                {'name': 'web.lab', 'address': '192.168.1.102'},
                {'name': 'srv.lab', 'address': '192.168.1.103'},
              ],
            },
            if (ftpCredentialMatch != null)
              'ftp': {
                'users': [
                  {
                    'username': ftpCredentialMatch.group(1),
                    'password': ftpCredentialMatch.group(2),
                  },
                ],
              },
            if (emailDomain != null) 'email': {'domain': emailDomain},
          },
        ),
      const NetNode(name: 'MGR1', type: 'pc', model: 'PC-PT'),
      const NetNode(name: 'HQ_PC1', type: 'pc', model: 'PC-PT'),
      const NetNode(name: 'BR_PC1', type: 'pc', model: 'PC-PT'),
    ];
    final links = <NetLink>[
      const NetLink(
        a: 'HQ_Router',
        aIf: 's0/0/0',
        b: 'BR_Router',
        bIf: 's0/0/0',
      ),
      const NetLink(a: 'HQ_Router', aIf: 'g0/0', b: 'HQ_Switch', bIf: 'f0/1'),
      const NetLink(a: 'BR_Router', aIf: 'g0/0', b: 'BR_Switch', bIf: 'f0/1'),
      const NetLink(a: 'HQ_Switch', aIf: 'f0/2', b: 'MGR1', bIf: 'f0'),
      const NetLink(a: 'HQ_Switch', aIf: 'f0/3', b: 'HQ_PC1', bIf: 'f0'),
      const NetLink(a: 'HQ_Switch', aIf: 'f0/4', b: 'AAA1', bIf: 'f0'),
      const NetLink(a: 'HQ_Switch', aIf: 'f0/5', b: 'DHCP1', bIf: 'f0'),
      const NetLink(a: 'HQ_Switch', aIf: 'f0/6', b: 'WEB1', bIf: 'f0'),
      if (isAllFeaturesLab)
        const NetLink(a: 'HQ_Switch', aIf: 'f0/7', b: 'SRV1', bIf: 'f0'),
      const NetLink(a: 'BR_Switch', aIf: 'f0/2', b: 'BR_PC1', bIf: 'f0'),
    ];
    final addressing = <InterfaceAddr>[
      const InterfaceAddr(
        node: 'HQ_Router',
        iface: 's0/0/0',
        ipCidr: '10.1.1.1/30',
      ),
      const InterfaceAddr(
        node: 'BR_Router',
        iface: 's0/0/0',
        ipCidr: '10.1.1.2/30',
      ),
      const InterfaceAddr(
        node: 'HQ_Router',
        iface: 'g0/0',
        ipCidr: '192.168.1.1/24',
      ),
      const InterfaceAddr(
        node: 'BR_Router',
        iface: 'g0/0',
        ipCidr: '192.168.2.1/24',
      ),
      const InterfaceAddr(
        node: 'AAA1',
        iface: 'f0',
        ipCidr: '192.168.1.100/24',
      ),
      const InterfaceAddr(
        node: 'DHCP1',
        iface: 'f0',
        ipCidr: '192.168.1.101/24',
      ),
      const InterfaceAddr(
        node: 'WEB1',
        iface: 'f0',
        ipCidr: '192.168.1.102/24',
      ),
      if (isAllFeaturesLab)
        const InterfaceAddr(
          node: 'SRV1',
          iface: 'f0',
          ipCidr: '192.168.1.103/24',
        ),
      const InterfaceAddr(node: 'MGR1', iface: 'f0', ipCidr: '192.168.1.50/24'),
      const InterfaceAddr(
        node: 'HQ_PC1',
        iface: 'f0',
        ipCidr: '192.168.1.10/24',
      ),
      const InterfaceAddr(
        node: 'BR_PC1',
        iface: 'f0',
        ipCidr: '192.168.2.10/24',
      ),
    ];

    // The hours are stated or they are nothing: a default window is a
    // control the user never asked for, and the validator rightly refuses to
    // enforce it in Packet Tracer, so inventing one only produced a build
    // that could never be unblocked.
    final officeHours = hoursMatch == null
        ? null
        : 'weekdays ${hoursMatch.group(1)!.trim()}-${hoursMatch.group(2)!.trim()}';
    final hasTacacs = lower.contains('tacacs');
    final hasRadius = lower.contains('radius');
    final hasTelnet =
        lower.contains('telnet') || lower.contains('vty');
    // Layer-2 security is what the brief asked for even when it names no
    // command: 'secure the access ports' is the same request as
    // 'enable port security on every user port'.
    final layer2Security = lower.contains('layer 2 security') ||
        lower.contains('layer-2 security') ||
        lower.contains('access ports') ||
        lower.contains('user ports');
    // Secrets are read from the brief or left open; the profile never invents
    // a password for a device it is about to configure.
    // Named once, because a tunnel the brief never asked for must not also
    // come with a demand for its pre-shared key.
    final wantsIpsec = lower.contains('ipsec') ||
        lower.contains('site-to-site') ||
        lower.contains('vpn') ||
        lower.contains('tunnel');
    final security = SecurityIntent(
      portSecurity:
          lower.contains('port security') ||
          lower.contains('port-security') ||
          lower.contains('sticky mac') ||
          lower.contains('mac address') ||
          layer2Security,
      dhcpSnooping:
          lower.contains('dhcp snooping') ||
          lower.contains('rogue dhcp') ||
          lower.contains('fake dhcp') ||
          lower.contains('untrusted dhcp') ||
          layer2Security,
      dhcpTrustedInterface: 'f0/1',
      aaa: lower.contains('aaa') || hasTacacs || hasRadius,
      aaaProtocol: 'tacacs+',
      aaaServer: 'AAA1',
      aaaRouter: 'HQ_Router',
      // Group 3/4 are the account the brief stated; that is the account
      // password, not the shared key (which this profile leaves to the
      // adapters' documented default unless the brief supplies one).
      aaaUsername: credentialMatch?.group(3),
      aaaAccountPassword: credentialMatch?.group(4),
      aaaPassword: resolveAaaKey(
        text,
        credentialMatch == null
            ? null
            : Credential(
                credentialMatch.group(3)!,
                credentialMatch.group(4)!,
                credentialMatch.start,
                credentialMatch.group(0)!,
              ),
      ),
      telnet: hasTelnet,
      // A manager-only VTY rule the brief never asked for is a control the
      // user cannot see, cannot change and cannot clear: the validator
      // reported its time window as unsupported and blocked the build on it.
      // It appears only when the brief actually asks for manager access or
      // states the hours, so every control in the plan is one they requested.
      managerIp: wantsManager ? '192.168.1.50' : null,
      officeHours: officeHours,
      extendedAcl:
          lower.contains('extended acl') ||
          lower.contains('block') && lower.contains('branch'),
      branchNetwork: '192.168.2.0/24',
      protectedServerIp: '192.168.1.100',
      allowedWebServerIp: '192.168.1.102',
      ipsecVpn: wantsIpsec,
      ssh: lower.contains('ssh'),
      spanningTree: lower.contains('spanning-tree') ||
          lower.contains('spanning tree') ||
          lower.contains('root bridge') ||
          lower.contains('rapid-pvst'),
      enableSecret: RegExp(
        r'enable\s+secret\s+([^\s,;.]+)',
        caseSensitive: false,
      ).firstMatch(text)?.group(1),
      vpnPeerA: '10.1.1.1',
      vpnPeerB: '10.1.1.2',
      // Both ends must agree, so the algorithms are explicit rather than
      // left to each side's fallback.
      vpnEncryption: lower.contains('3des') ? '3des' : 'aes',
      vpnHash: lower.contains('md5') ? 'md5' : 'sha',
      vpnPreSharedKey: key,
      vpnLocalNetwork: '192.168.1.0/24',
      vpnRemoteNetwork: '192.168.2.0/24',
      tests: const [
        'HQ manager can reach HQ and branch gateways',
        'Branch client can reach the HQ web server over HTTP',
        'Branch client cannot reach the AAA server',
        'HQ router accepts VTY login only from the manager during office hours',
        'IPSec security associations are established',
        'Port security and DHCP snooping are enabled on both switches',
      ],
    );

    final questions = <String>[
      if (credentialMatch == null)
        'Provide the TACACS+ username and password; they were not supplied, '
            'and the plan never invents a credential.',
      // Only a brief that asked for a tunnel is asked for its key. The old
      // condition fired for every secure brief, so a lab that never mentioned
      // a VPN was told to supply a pre-shared key for a tunnel it never asked
      // to have.
      if (wantsIpsec && key == null)
        'Provide the IPSec pre-shared key; it was not supplied, so the tunnel '
            'is staged but cannot establish.',
    ];
    final assumptions = <String>[
      'One manager PC and one employee PC are placed at HQ, plus one employee PC at the branch because employee counts were not specified.',
      'AAA1, DHCP1, and WEB1 are separate servers so each documented role is testable.',
      'HQ_Switch/BR_Switch user ports are FastEthernet0/2-24; FastEthernet0/1 is the router-facing trusted/uplink port.',
      'DHCP relay is enabled on both router LAN interfaces and DHCP1 serves both LAN pools.',
      'The exact WAN requires Serial0/0/0 on both routers; if a live 2911 lacks the required serial module, the executor may show a proven spare-port recovery, but the exact-interface validation will fail until the module is installed.',
    ];
    return NetworkIntent(
      projectName: projectName.isEmpty ? 'security-branch-lab' : projectName,
      nodes: nodes,
      links: links,
      addressing: addressing,
      routing: resolveRouting(lower) ?? 'static',
      security: security,
      notes: [
        'Security-lab profile parsed locally from the plain-English requirements.',
        'Execution is staged: topology, base config, services, security controls, then independent tests.',
      ],
      assumptions: assumptions,
      questions: questions,
      confidence: questions.length == 2 ? 0.86 : 0.76,
      planningSource: 'local',
    );
  }

  // --- Offline wording bridge -------------------------------------------
  //
  // The offline planner has no model to rephrase a brief for it, so wording
  // the parser does not literally expect used to produce an empty or wrong
  // plan.  `bridgeBrief` rewrites only the phrases the parser keys on:
  // Arabic words into their English equivalents, Arabic-Indic digits into
  // 0-9, "192.168.1.1 255.255.255.0" into "192.168.1.1/24" and
  // "two routers" into "2 routers".  Everything else passes through as-is,
  // and Latin case is preserved (a password's case must survive).

  /// Right-to-left marks, tashkeel, and the Arabic letters that have several
  /// spellings (أ/إ/آ -> ا, ى -> ي, ة -> ه), folded so one table entry
  /// matches every way a brief may be written.
  static final RegExp roleServerLabel = RegExp(
    r'\b(?:DHCP|DNS|WEB|HTTP|HTTPS|AAA|TACACS|RADIUS|FTP|MAIL|EMAIL|SMTP|'
    r'POP3|NTP|TFTP|SNMP|SYSLOG|PRP|VM|IOT|PRINTER)\d{1,2}\b',
    caseSensitive: false,
  );

  /// The servers a brief names instead of counting, in the order it listed
  /// them: "six Server-PT devices: DHCP1, DNS1, WEB1, AAA1, FTP1 and MAIL1".
  ///
  /// Generic SRV1..SRVn loses the only name the later steps have: the
  /// Services tab owner, the DHCP relay target, the AAA server, the address
  /// a DNS record points at. The user's own names are kept, and everything
  /// downstream reads them instead of a position.
  static List<String> namedServerLabels(String text) {
    final out = <String>[];
    for (final m in roleServerLabel.allMatches(text)) {
      final name = m.group(0)!;
      if (!out.any((n) => n.toLowerCase() == name.toLowerCase())) {
        out.add(name.toUpperCase());
      }
    }
    return out;
  }

  /// What the chat's standing plan becomes after one more turn.
  ///
  /// A follow-up that names no device ("ok build the packet tracer file",
  /// "now add port security") keeps [previous], the plan parsed from the
  /// user's real request: [parseSimple]'s empty-brief fallback would
  /// otherwise invent a fresh router+switch lab and silently replace it. A
  /// brief that DOES name devices is a new or extended request and re-plans.
  static NetworkIntent planAfterFollowUp({
    required NetworkIntent? previous,
    required NetworkIntent parsed,
    required String brief,
  }) {
    final namesDevices = namesAnyDeviceIn(brief.toLowerCase());
    if (previous != null &&
        previous.nodes.isNotEmpty &&
        !namesDevices &&
        parsed.nodes.length <= previous.nodes.length) {
      return previous;
    }
    return parsed;
  }

  /// A follow-up that asks to *change the standing plan* rather than for more
  /// devices: "use ospf instead", "switch to static routing".
  ///
  /// [planAfterFollowUp] keeps [previous] for any brief that names no device,
  /// which is right for "ok build the file" - but it also swallowed a protocol
  /// request, so the offline assistant's own advice ("say \"use ospf\" to
  /// switch") did nothing, and the user watched the same static plan come
  /// back. This applies the one change the plan can absorb without re-planning
  /// the topology.
  ///
  /// Returns null when the brief is not such a change, so the caller keeps its
  /// existing behaviour.
  static NetworkIntent? applyFollowUpChange({
    required NetworkIntent? previous,
    required String brief,
  }) {
    if (previous == null || previous.nodes.isEmpty) return null;
    final t = brief.toLowerCase();
    // Naming devices is a re-plan, not a tweak: leave it to the parser.
    if (namesAnyDeviceIn(t)) return null;
    final asksToChange = RegExp(
      r'\b(use|switch to|change to|change it to|set|go with|prefer|instead of|'
      r'rather than|make it)\b',
    ).hasMatch(t);
    if (!asksToChange) return null;
    final protocol = resolveRouting(t);
    if (protocol == null || protocol == previous.routing) return null;
    final json = previous.toJson();
    json['routing'] = protocol;
    json['notes'] = <String>[
      ...previous.notes,
      'Routing set to $protocol from the conversation.',
    ];
    try {
      return NetworkIntent.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// The routing protocol a brief asks for, with negation and replacement
  /// read correctly: "not OSPF; use EIGRP" is EIGRP, "use OSPF instead of
  /// EIGRP" is OSPF, and a protocol said only to reject it ("no ospf")
  /// selects nothing.
  ///
  /// Null when the brief said nothing positive about routing; callers keep
  /// their own default (static) in that case.
  static String? resolveRouting(String lower) {
    final negatedBefore = RegExp(
      r"\b(?:not|no|never|avoid|without|drop|remove|instead\s+of|"
      r"rather\s+than|don['’]?t|do\s+not)\b[^.;,!?]{0,18}$",
    );
    final instructedBefore = RegExp(
      r'\b(?:use|using|run|running|switch\s+to|change\s+(?:it\s+)?to|'
      r'go\s+with|set\s+(?:routing\s+)?to|prefer|enable|configure|'
      r'implement|adopt|choose|pick|make\s+it|go\s+for)\b[^.;,!?]{0,6}$',
    );
    final instructedAfter = RegExp(r'^\s*(?:instead|as\s+the\s+protocol)');
    final mentions =
        <({int at, String proto, bool negated, bool instructed})>[];
    for (final proto in const ['ospf', 'eigrp', 'bgp', 'static']) {
      final pattern =
          proto == 'static' ? RegExp(r'\bstatic\b') : RegExp('\\b$proto\\b');
      for (final m in pattern.allMatches(lower)) {
        final before =
            lower.substring(m.start > 40 ? m.start - 40 : 0, m.start);
        final end = m.end + 12 > lower.length ? lower.length : m.end + 12;
        mentions.add((
          at: m.start,
          proto: proto,
          negated: negatedBefore.hasMatch(before),
          instructed: instructedBefore.hasMatch(before) ||
              instructedAfter.hasMatch(lower.substring(m.end, end)),
        ));
      }
    }
    mentions.sort((a, b) => a.at.compareTo(b.at));
    final positive = [for (final m in mentions) if (!m.negated) m];
    if (positive.isEmpty) return null;
    final instructed = [for (final m in positive) if (m.instructed) m];
    final pool = instructed.isEmpty ? positive : instructed;
    return pool.last.proto;
  }

  /// What the chat's standing plan becomes after one more turn, plus the brief
  /// that produced it. One entry point, so the model path and the keyless path
  /// cannot disagree about what the user is building.
  ///
  /// In order:
  ///
  /// * **an addition** - "can we add an AAA server to it as well?", "add 2
  ///   routers and 20 PCs" - re-reads the original request together with the
  ///   new sentence, so the lab that exists survives and the addition lands on
  ///   it. Without this, naming any device in a follow-up handed the parser's
  ///   answer back as the whole plan: "add an AAA server" turned a 13-device
  ///   lab into one server with no links. A brief that also *specifies* the
  ///   lab (cables, addresses, services - see [specificationWording]) is not
  ///   a delta however many times the word "add" appears in it, so repeating
  ///   the same full brief re-plans it instead of doubling every count.
  /// * **a change that names no device** - "use OSPF instead" - is applied to
  ///   the standing plan (see [applyFollowUpChange]).
  /// * **a count correction** - "actually 8 pcs", "no wait, 8" - replaces the
  ///   corrected kinds' counts on the standing lab and keeps every device,
  ///   site, service and rule the correction did not name (see
  ///   [_mergeCountCorrection]).
  /// * **a new or extended request** that names devices - "make it 2 routers
  ///   and 4 PCs" - re-plans, because that is a new lab, not a nudge.
  /// * **anything else** - "ok build the file" - keeps the standing plan: the
  ///   parser's empty-brief fallback would otherwise invent a lab from a nudge.
  static ({NetworkIntent plan, String brief}) followUp({
    required NetworkIntent? previous,
    required String previousBrief,
    required String brief,
    required NetworkIntent parsed,
    String project = 'chat',
  }) {
    final hasStanding = previous != null && previous.nodes.isNotEmpty;
    // A greeting, an acknowledgement or a QUESTION about the lab is not a
    // new specification: "hello" must not seed a default pair into the
    // conversation, and "what about the routers and switches?" - asked to
    // understand - must not silently re-plan over what was discussed.
    if (_readsAsNonPlanning(brief)) {
      return (
        plan: hasStanding ? previous : NetworkIntent(projectName: project),
        brief: previousBrief,
      );
    }
    if (!hasStanding) {
      return (plan: parsed, brief: brief);
    }
    // "we will need more than 1 router and 1 switch and 1 server" states
    // FLOORS, not exact counts: the standing lab grows to meet them and is
    // never shrunk back to the stated minimums (a discussed 2-site network
    // once collapsed to "1 router, 1 switch, 1 server" this way).
    // A count correction ("actually 8 pcs", "no wait, 8") restates a number
    // the conversation already stated, so it is read against the standing
    // lab rather than on its own. It goes BEFORE the growth reading: "no
    // wait, actually more than 8 pcs" corrects an earlier floor instead of
    // being absorbed by one that can only grow.
    if (_readsAsCountCorrection(brief)) {
      final corrected = _mergeCountCorrection(
        previous: previous,
        previousBrief: previousBrief,
        brief: brief,
        project: project,
      );
      if (corrected != null) return corrected;
      // Not confidently a correction of this lab - fall through to the
      // growth and naming readings below rather than guess.
    }
    if (_readsAsGrowth(brief)) {
      final merged = _mergeFloor(
        previous: previous,
        previousBrief: previousBrief,
        brief: brief,
        addition: parsed,
        project: project,
      );
      if (merged != null) return merged;
    }
    if (namesAnyDeviceIn(brief.toLowerCase())) {
      if (_readsAsAddition(brief)) {
        final merged = _mergeAddition(
          previous: previous,
          previousBrief: previousBrief,
          brief: brief,
          addition: parsed,
          project: project,
        );
        if (merged != null) return merged;
        // The addition could not be applied without losing what stands, so
        // the lab is kept and the brief is left alone - nothing claims to
        // have changed.
        return (plan: previous, brief: previousBrief);
      }
      // Naming a device kind is not by itself a new lab. "make one server an
      // AAA server and another server as dhcp server" names a server and
      // states no counts, and re-planning it alone collapsed a 17-device lab
      // into that one server - the plan shrank under the user, and the build
      // card then described a network nobody asked for. A brief that names
      // devices but states no counts of its own is read ON TOP of the
      // standing counts, which can only preserve or grow them.
      if (!_briefStatesDeviceCounts(brief)) {
        final merged = _mergeFloor(
          previous: previous,
          previousBrief: previousBrief,
          brief: brief,
          addition: parsed,
          project: project,
        );
        if (merged != null) return merged;
        // The re-read could not be trusted to keep the lab, so the lab that
        // exists is kept and nothing claims to have changed.
        return (plan: previous, brief: previousBrief);
      }
      return (plan: parsed, brief: brief);
    }
    final changed = applyFollowUpChange(previous: previous, brief: brief);
    if (changed != null) {
      final base = previousBrief.trim();
      return (
        plan: changed,
        brief: base.isEmpty ? brief : '$base $brief',
      );
    }
    return (plan: previous, brief: previousBrief);
  }

  /// Wording that asks to ADD to what exists rather than to start again.
  /// Deliberately narrow: "with" and "and" appear in fresh requests too, and
  /// reading one of those as an addition would mix two labs together.
  static final RegExp additionWording = RegExp(
    // "its own" is the phrasing people reach for when they mean a SECOND one:
    // "give the branch its own AAA server" asks for a device the lab does not
    // have, and without this the whole request was read as a description and
    // silently dropped. Same for provision/deploy, which name the act of
    // standing something up rather than changing it.
    r'\b(add|adding|also|plus|as well|too|attach|include|along with|'
    r'as an addition|in addition)\b'
    r'|\bits\s+own\b'
    r'|\b(?:provision|deploy|stand\s+up)\b',
  );

  /// Wording that makes a brief a SPECIFICATION of the lab rather than a
  /// delta on top of one: cables, interfaces, addresses, protocols, pools
  /// and service settings.
  ///
  /// A full brief contains "add" inside it more often than not ("add user
  /// netadmin with password ...", "add DHCP relay on R2's LAN interface"),
  /// and the old test - the word 'add' appearing anywhere - merged that whole
  /// specification on top of the plan it already describes: every count was
  /// read twice and a 20-device lab became 40 devices. Such a brief is read
  /// as the request it is, and re-planning it is a no-op.
  static final RegExp specificationWording = RegExp(
    r'\bconnect|\bcabl|\bwir(?:e|ing|es)\b|\binterfac|\bport\s*\d|'
    r'\b\d{1,3}(?:\.\d{1,3}){3}|\baddress|\bassign|\bmask|\bgateway|'
    r'\bospf|\beigrp|\bbgp\b|\bpool|\brelay|\brecord|\bdomain|'
    r'\benable|\bconfigure|\bclock\b',
    caseSensitive: false,
  );

  static bool _readsAsAddition(String brief) {
    final lower = brief.toLowerCase();
    return additionWording.hasMatch(lower) &&
        !specificationWording.hasMatch(lower);
  }

  /// Turns that carry nothing to plan from: greetings, acknowledgements and
  /// questions. They keep the standing plan (or the absence of one) exactly
  /// as it was.
  static final RegExp _socialOnly = RegExp(
    r'^(?:hi|hello|hey|yo|sup|salam|salaam|hola|thanks|thank\s+you|thx|ty|'
    r'ok|okay|k|cool|nice|great|perfect|got\s+it|understood|sounds\s+good|'
    r'good|alright|awesome|will\s+do|continue|go\s+on|more)[.!]*$',
    caseSensitive: false,
  );

  static final RegExp _questionStart = RegExp(
    r'^(?:what|which|how|why|who|when|where|any|should|could|would|is|are|'
    r'do|does|can)\b',
    caseSensitive: false,
  );

  /// Words that mark a how-to / advice question: the assistant answers it
  /// (and the plan stays as it is), whatever other verbs the sentence has.
  static final RegExp _howtoWord = RegExp(
    r'\b(?:recommend|advice|how\s+do\s+i|how\s+can\s+i|'
    r'how\s+does|how\s+would|what\s+is\s+better|whats\s+better|'
    r'difference\s+between|explain)',
    caseSensitive: false,
  );

  /// Verbs that make a question an actionable request ("can we add an AAA
  /// server as well?", "can we use OSPF?") rather than a question about
  /// the lab.
  static final RegExp _changeVerb = RegExp(
    r'\b(?:add|adding|build|create|design|make|set\s?up|connect|configure|'
    r'use|switch\s+to|change|update|apply|enable|set|remove|delete|rename|'
    r'replace|convert|include|attach|edit|revise|update)\b',
    caseSensitive: false,
  );

  /// True when [brief] states device COUNTS ("2 routers", "50 pcs") - the
  /// signal that a message is a specification rather than a question about
  /// the lab.
  static final RegExp _deviceCountWording = RegExp(
    // "layer 3 switch" is a term, not a stated count: without the lookbehind
    // the parser read "3 switch" as one switch and treated the design
    // question as a specification.
    r'(?<!layer\s)\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|'
    r'laptops?|printers?|firewalls?|phones?|tablets?|clouds?|modems?|'
    r'access\s+points?|aps?)\b',
    caseSensitive: false,
  );

  static bool _briefStatesDeviceCounts(String lower) =>
      _deviceCountWording.hasMatch(lower);

  /// True when the message is a greeting/acknowledgement, or a question
  /// that proposes nothing to do: neither is a new lab specification.
  ///
  /// A how-to / advice question ("how do I configure a trunk port?") is
  /// answered and leaves the plan alone. A question that DOES propose an
  /// action ("can we add an AAA server as well?", "can we use OSPF?") or
  /// names counts ("can you build me 2 routers and 4 pcs?") plans as
  /// normal - the first version of this guard swallowed exactly those
  /// follow-ups.
  static bool _readsAsNonPlanning(String brief) {
    final lower = brief.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if (_socialOnly.hasMatch(lower)) return true;
    // An advisory turn (a choice, a size, a comparison or a review) keeps
    // the plan exactly as it is - see [_readsAsAdvice].
    if (_readsAsAdvice(lower)) return true;
    final questionShaped =
        lower.endsWith('?') || _questionStart.hasMatch(lower);
    if (!questionShaped) return false;
    if (_howtoWord.hasMatch(lower)) return true;
    if (_briefStatesDeviceCounts(lower)) return false;
    if (additionWording.hasMatch(lower)) return false;
    if (_changeVerb.hasMatch(lower)) return false;
    return true;
  }

  /// True when [lower] is an advisory turn whose answer must not touch the
  /// plan.
  ///
  /// A stated count normally makes a request a build - "recommend 2 routers
  /// and 4 pcs" plans - but only when the sentence asks to build. A count
  /// inside a pure question ("what switch do I need for 30 PCs?") is the
  /// SUBJECT of the advice, and answering it must not replace the lab on
  /// the table. Without this, the advice question re-planned the lab it was
  /// asking about, because verbs like "use" read as changes.
  static bool _readsAsAdvice(String lower) {
    if (AdviceIntentReader.read(lower) == AdviceKind.none) return false;
    if (!_briefStatesDeviceCounts(lower)) return true;
    final questionShaped =
        lower.endsWith('?') || _questionStart.hasMatch(lower);
    if (!questionShaped) return false;
    return !_changeVerb.hasMatch(lower) && !additionWording.hasMatch(lower);
  }

  /// True when the brief asks for MORE of something ("more than 1 router",
  /// "over 2 switches") - a floor to grow toward, not a spec to rebuild.
  static bool _readsAsGrowth(String brief) {
    final lower = brief.toLowerCase();
    return RegExp(r'\b(?:more\s+than|over)\b').hasMatch(lower) &&
        _briefStatesDeviceCounts(lower);
  }

  /// A coarse, PUBLIC classification of one brief, for the
  /// message-understanding card. The rules are the same ones the planner
  /// uses to decide whether a turn may touch the plan - one implementation,
  /// not a second opinion.
  ///
  /// Returns one of: empty, social, advice, howto, question, confirm,
  /// growth, addition, build, change, statement.
  static String classifyBrief(String brief) {
    final lower = brief.trim().toLowerCase();
    if (lower.isEmpty) return 'empty';
    if (_socialOnly.hasMatch(lower)) return 'social';
    // An advisory turn is its own kind: it is answered with a recommendation
    // and leaves the plan alone. A stated count still wins when the sentence
    // asks to build - "recommend 2 routers" is a build request - but not
    // when the count is the subject of a question ("what switch do I need
    // for 30 PCs?").
    if (_readsAsAdvice(lower)) return 'advice';
    final questionShaped =
        lower.endsWith('?') || _questionStart.hasMatch(lower);
    if (questionShaped) {
      if (_howtoWord.hasMatch(lower)) return 'howto';
      if (!_briefStatesDeviceCounts(lower) &&
          !additionWording.hasMatch(lower) &&
          !_changeVerb.hasMatch(lower)) {
        return 'question';
      }
    }
    // "ok build it" / "go ahead, build the file" - agreement with the plan
    // on the table, mirrored from the reply layer's yes-detection.
    if (RegExp(
      r'^(?:ok|okay|yes|yeah|sure|alright|go\s+ahead|do\s+it)\b[^.]{0,30}'
      r'\b(?:build|make|run|start|do|compile|go)\b',
    ).hasMatch(lower)) {
      return 'confirm';
    }
    if (_readsAsGrowth(brief)) return 'growth';
    if (additionWording.hasMatch(lower)) return 'addition';
    if (_briefStatesDeviceCounts(lower)) return 'build';
    if (_changeVerb.hasMatch(lower)) return 'change';
    return 'statement';
  }

  /// The original request and the new sentence, read as one brief.
  ///
  /// "Add" means plus, for every kind the new sentence names: "add 2 switches"
  /// on a one-switch lab is three switches, "add a server" is one more server.
  /// A kind the new sentence does not mention keeps the count it had. The
  /// numbers are written out in front (the parser reads the FIRST count it
  /// sees) while the words of both sentences stay in the brief, because the
  /// roles, VLANs, routing and security come from the text, not from the
  /// counts.
  static ({NetworkIntent plan, String brief})? _mergeAddition({
    required NetworkIntent previous,
    required String previousBrief,
    required String brief,
    required NetworkIntent addition,
    required String project,
  }) {
    final base = previousBrief.trim();
    if (base.isEmpty) return null;
    int countOf(NetworkIntent p, String type) =>
        p.nodes.where((n) => n.type == type).length;

    // How many of each kind THIS sentence adds, read from the sentence rather
    // than from the plan it parses into. The parse of an addition can be a
    // whole different lab - "give the branch its own AAA server" mentions
    // "branch" and "AAA" and used to be read as the ten-device security
    // profile - and adding that profile's three servers to a four-server lab
    // grew it to eleven. What the user asked for is one more server.
    final additionLower = brief.toLowerCase();
    final stated =
        BriefSlotPipeline.extractCounts(additionLower, brief);
    int mergedCount(String type) {
      final added = stated[type] ?? 0;
      return added == 0 ? countOf(previous, type) : countOf(previous, type) + added;
    }

    final kinds = <String, String>{
      'router': 'routers',
      'switch': 'switches',
      'pc': 'pcs',
      'server': 'servers',
    };
    final counts = <String>[];
    for (final kind in kinds.entries) {
      final n = mergedCount(kind.key);
      // A zero is left out on purpose: writing "0 servers" into the brief
      // would itself look like a mention of a server to the parser.
      if (n > 0) counts.add('$n ${kind.value}');
    }
    // The totals are stated twice, and the second statement is a correction.
    // The merge reads one brief that still contains the ORIGINAL wording, and
    // that wording carries its own numbers - "Site A with 2 routers ... 3
    // Server-PT devices" - which are per-site and therefore ADD to the totals
    // rather than restate them. That grew a four-server lab to nine. A
    // trailing correction discards the per-site tallies and pins each kind to
    // the number this merge decided, while the roles, addressing, routing and
    // security in the original words are all still there to be read.
    final tally = counts.join(' ');
    final combined = '$tally $brief $base actually $tally'.trim();
    final NetworkIntent merged;
    try {
      merged = parseSimple(
        project.trim().isEmpty ? previous.projectName : project,
        combined,
      );
    } catch (_) {
      return null;
    }
    // An addition may change nothing about the topology (AAA is configuration),
    // but it must never shrink the lab: that is the bug this whole path exists
    // to prevent.
    if (merged.nodes.length < previous.nodes.length) return null;
    return (plan: merged, brief: combined);
  }

  /// The original request and the new "we need more than ..." sentence, read
  /// as one brief with FLOOR counts: every kind keeps at least what the
  /// standing lab already had, raised to the new sentence's minimum where it
  /// asks for more. The lab can only grow.
  static ({NetworkIntent plan, String brief})? _mergeFloor({
    required NetworkIntent previous,
    required String previousBrief,
    required String brief,
    required NetworkIntent addition,
    required String project,
  }) {
    final base = previousBrief.trim();
    if (base.isEmpty) return null;
    int countOf(NetworkIntent p, String type) =>
        p.nodes.where((n) => n.type == type).length;
    int floor(String type) {
      final added = countOf(addition, type);
      final had = countOf(previous, type);
      return added > had ? added : had;
    }

    final kinds = <String, String>{
      'router': 'routers',
      'switch': 'switches',
      'pc': 'pcs',
      'server': 'servers',
    };
    final counts = <String>[];
    for (final kind in kinds.entries) {
      final n = floor(kind.key);
      // A zero is left out on purpose: writing "0 servers" into the brief
      // would itself look like a mention of a server to the parser.
      if (n > 0) counts.add('$n ${kind.value}');
    }
    final combined = '${counts.join(' ')} $brief $base'.trim();
    final NetworkIntent merged;
    try {
      merged = parseSimple(
        project.trim().isEmpty ? previous.projectName : project,
        combined,
      );
    } catch (_) {
      return null;
    }
    // The floor may change configuration (security, routing) but it must
    // never make the lab smaller than it already was.
    if (merged.nodes.length < previous.nodes.length) return null;
    return (plan: merged, brief: combined);
  }

  /// Wording that marks a number as a CORRECTION of something the
  /// conversation already counted: "actually 8 pcs", "no wait, 8", "rather
  /// 12 PCs". "rather than" is left out on purpose - "8 PCs rather than 6"
  /// is a comparison whose SECOND number is the rejected one, and reading
  /// the cue there would correct the lab to the count the user just
  /// withdrew.
  static final RegExp _countCorrectionCue = RegExp(
    r'\b(?:actually|rather(?!\s+than)|no\s+wait|i\s+mean|correction)\b',
    caseSensitive: false,
  );

  /// A correction cue followed directly by a bare count - "actually 8",
  /// "no wait, 8" - with no device word of its own. An address must not
  /// read as one ("actually 192.168.1.0/24"), so a number that continues
  /// into dotted or slashed form is refused.
  static final RegExp _bareCountCorrection = RegExp(
    r'\b(?:actually|rather(?!\s+than)|no\s+wait|i\s+mean|correction)'
    r'\s*,?\s*(\d{1,3})\b(?!\s*[./]\d)',
    caseSensitive: false,
  );

  /// "2 more PCs" is an addition, not a correction - but "more than 8 PCs"
  /// restates a bound, and a cue in front of it ("no wait, actually more
  /// than 8 pcs") makes the new bound a correction of the old one.
  static final RegExp _additiveCountWording = RegExp(
    r'\b(?:extra|additional|further)\b|\bmore\b(?!\s+than)',
    caseSensitive: false,
  );

  /// True when [brief] is a count correction of the standing lab: a
  /// correction cue plus either a bare count or a counted device kind, and
  /// neither addition wording (which has its own reading) nor an additive
  /// count ("2 more PCs", which adds rather than replaces).
  ///
  /// A counted kind is only corrected by a cue IN FRONT of it: "more than 8
  /// pcs, actually" trails its count as an afterthought about the bound,
  /// and correcting the lab down to the count the cue follows would shrink
  /// the lab on a sentence that never asked for that.
  static bool _readsAsCountCorrection(String brief) {
    final lower = brief.toLowerCase();
    final cue = _countCorrectionCue.firstMatch(lower);
    if (cue == null) return false;
    if (_readsAsAddition(brief)) return false;
    if (_additiveCountWording.hasMatch(lower)) return false;
    if (_bareCountCorrection.hasMatch(lower)) return true;
    return _deviceCountWording
        .allMatches(lower)
        .any((m) => m.start > cue.start);
  }

  /// The original request and a CORRECTION of one of its counts ("actually
  /// 8 pcs", "no wait, 8"), read as one brief whose corrected kinds land on
  /// the new numbers while everything the correction did not name - devices,
  /// sites, services, addressing, security - is re-read from the original
  /// words exactly as it stands.
  ///
  /// Without this branch both natural correction shapes failed on a
  /// standing lab. A bare count ("actually 8") named no device, so no
  /// reading claimed it and the turn was dropped in silence while the
  /// understood card still reported a correction. A count with a device
  /// word ("actually 8 pcs") re-planned from the fragment alone, which
  /// replaced the whole lab with the fragment's devices: a 13-device
  /// network became eight orphan PCs with no router to hang them on.
  ///
  /// The correction is instead appended to the standing brief as a cued
  /// tally ("..., actually 8 pcs"), the same trailing pin [_mergeAddition]
  /// uses: the parser's own correction rule replaces what the corrected
  /// kind counted before and touches no other kind, and the re-read keeps
  /// the roles, sites, addressing, routing and security written in the
  /// original words.
  ///
  /// The re-read is checked before it is returned: every kind must land on
  /// its expected count - the corrected kinds on the new numbers, every
  /// other kind on the count the standing lab already had - and the re-read
  /// must invent no kind of its own. A re-read that loses or invents a
  /// device (a site structure, a kind the tally cannot name) is discarded
  /// and the historical reading is kept, so this branch can only change the
  /// plan the user asked for, never silently reshape it.
  static ({NetworkIntent plan, String brief})? _mergeCountCorrection({
    required NetworkIntent previous,
    required String previousBrief,
    required String brief,
    required String project,
  }) {
    final base = previousBrief.trim();
    if (base.isEmpty) return null;
    final lower = brief.toLowerCase();
    final stated = BriefSlotPipeline.extractCounts(
      lower,
      brief,
      // The tiny-office default would grow a router and a switch out of a
      // correction that names none - the standing lab already has its own.
      tinyOfficeDefault: false,
    );
    final corrected = <String, int>{
      for (final entry in stated.entries)
        if (entry.value > 0) entry.key: entry.value,
    };
    // A bare count ("actually 8") names no kind of its own: it corrects the
    // kind the conversation counted last - the same recency rule the
    // elliptical in-brief correction ("..., actually 8") resolves by.
    if (corrected.isEmpty) {
      final kind = BriefSlotPipeline.lastCountedKind(base.toLowerCase());
      final bare = _bareCountCorrection.firstMatch(lower);
      if (kind == null || bare == null) return null;
      corrected[kind] = int.parse(bare.group(1)!);
    }
    final tally = <String>[];
    final order = [
      ..._correctionTallyKinds,
      ...corrected.keys.where(
        (kind) => !_correctionTallyKinds.contains(kind),
      ),
    ];
    for (final kind in order) {
      final n = corrected[kind];
      if (n == null || n <= 0) continue;
      tally.add('$n ${_correctionKindNoun(kind)}');
    }
    if (tally.isEmpty) return null;
    // The fragment itself rides along (a correction may carry services or
    // addressing of its own - "actually 8 pcs with a web server"), and the
    // tally is written after it so the corrected counts are the LAST cued
    // numbers the re-read sees. The tally joins its kinds without "and":
    // "and" is a clause boundary, and a kind listed in a new clause would
    // lose the correction cue sitting in front of the tally.
    final stripTail = RegExp(r'[\s,.;:]+$');
    final baseClean = base.replaceAll(stripTail, '');
    final briefClean = brief.trim().replaceAll(stripTail, '');
    final combined =
        '$baseClean, $briefClean, actually ${tally.join(' ')}'.trim();
    final NetworkIntent merged;
    try {
      merged = parseSimple(
        project.trim().isEmpty ? previous.projectName : project,
        combined,
      );
    } catch (_) {
      return null;
    }
    final expected = <String, int>{};
    for (final node in previous.nodes) {
      expected[node.type] = (expected[node.type] ?? 0) + 1;
    }
    expected.addAll(corrected);
    int countOf(NetworkIntent p, String type) =>
        p.nodes.where((n) => n.type == type).length;
    for (final entry in expected.entries) {
      if (countOf(merged, entry.key) != entry.value) return null;
    }
    for (final node in merged.nodes) {
      if (!expected.containsKey(node.type)) return null;
    }
    return (plan: merged, brief: combined);
  }

  /// The kind order the correction tally is written in, so the same
  /// correction always produces the same brief.
  static const List<String> _correctionTallyKinds = [
    'router',
    'switch',
    'pc',
    'server',
    'laptop',
    'phone',
    'printer',
    'tablet',
    'firewall',
    'wireless',
    'wireless-router',
    'cloud',
    'modem',
  ];

  /// The plural noun a correction tally writes for a device kind, taken
  /// from the kind's own keyword table where possible so the tally says a
  /// phrase the parser counts back ("8 wireless access points" is eight
  /// [DeviceKind]s of type `wireless`).
  static String _correctionKindNoun(String type) {
    const core = <String, String>{
      'router': 'routers',
      'switch': 'switches',
      'pc': 'pcs',
      'server': 'servers',
    };
    final known = core[type];
    if (known != null) return known;
    for (final kind in deviceKinds) {
      if (kind.type != type || kind.keywords.isEmpty) continue;
      final parts = kind.keywords.first.split(' ');
      final last = parts.last;
      const esEndings = ['ch', 'sh', 'ss', 's', 'x', 'z'];
      parts[parts.length - 1] =
          esEndings.any(last.endsWith) ? '${last}es' : '${last}s';
      return parts.join(' ');
    }
    return type.endsWith('s') ? type : '${type}s';
  }

  /// What changed between two plans, in the user's own terms - "+1 switch,
  /// routing is now ospf (was static), AAA added". Empty when nothing did.
  ///
  /// The keyless assistant has no model to notice a change, and a person who
  /// asked for one needs to know whether it landed.
  static String planChangeSummary(NetworkIntent? before, NetworkIntent after) {
    if (before == null || before.nodes.isEmpty) return '';
    int count(NetworkIntent p, String type) =>
        p.nodes.where((n) => n.type == type).length;
    final bits = <String>[];
    for (final type in const ['router', 'switch', 'pc', 'server']) {
      final d = count(after, type) - count(before, type);
      if (d > 0) bits.add('+$d $type(s)');
      if (d < 0) bits.add('$d $type(s)');
    }
    if (before.routing != after.routing) {
      bits.add('routing is now ${after.routing} (was ${before.routing})');
    }
    final addedVlans =
        after.vlans.where((v) => !before.vlans.contains(v)).toList();
    if (addedVlans.isNotEmpty) {
      bits.add('VLAN(s) ${addedVlans.join(', ')} added');
    }
    final removedVlans =
        before.vlans.where((v) => !after.vlans.contains(v)).toList();
    if (removedVlans.isNotEmpty) {
      bits.add('VLAN(s) ${removedVlans.join(', ')} removed');
    }
    final wasOn = enabledControls(before.security).toSet();
    final nowOn = enabledControls(after.security).toSet();
    for (final control in nowOn.difference(wasOn)) {
      bits.add('$control added');
    }
    for (final control in wasOn.difference(nowOn)) {
      bits.add('$control removed');
    }
    return bits.join(', ');
  }

  /// The security features a plan actually turns on, named the way a person
  /// would say them. Public so a change can be described without reading the
  /// whole [SecurityIntent].
  static List<String> enabledControls(SecurityIntent s) => [
    if (s.portSecurity) 'port security',
    if (s.dhcpSnooping) 'DHCP snooping',
    if (s.aaa) 'AAA',
    if (s.ssh) 'SSH access',
    // `telnet` is also how the parser marks the VTY lines that AAA
    // authenticates, so it is not listed as a second control when AAA is what
    // turned it on: "AAA added, Telnet access added" read like two decisions
    // when the user made one.
    if (s.telnet && !s.aaa) 'Telnet access',
    if (s.extendedAcl) 'an extended ACL',
    if (s.ipsecVpn) 'an IPsec VPN',
    if (s.etherChannel) 'EtherChannel',
    if (s.hsrp) 'HSRP',
    if (s.spanningTree) 'spanning-tree hardening',
    if (s.interVlanRouting) 'inter-VLAN routing',
    if (s.consolePassword) 'a console password',
    if (s.enableSecret != null && s.enableSecret!.isNotEmpty) 'an enable secret',
  ];

  /// "PC7" -> ('pc', 7); a word that is not a numbered label -> null.
  static (String, int)? labelRun(String word) {
    final m = RegExp(r'^([a-z]+?)(\d{1,3})$').firstMatch(
      word.toLowerCase().trim(),
    );
    if (m == null) return null;
    final number = int.tryParse(m.group(2)!);
    return number == null ? null : (m.group(1)!, number);
  }

  /// The end devices named in one cabling clause, in the order they were
  /// written: "PC1-PC5" is the run PC1..PC5, "DHCP1, DNS1, WEB1, AAA1, FTP1
  /// and MAIL1" is those six in that order.  Only names the plan really has
  /// are returned - anything else in the clause ("connect", "also", "to") is
  /// not a device.
  static List<String> deviceSpan(String clause, Set<String> known) {
    final words = clause
        .split(RegExp(r'[\s,;&|-]+'))
        .map((w) => w.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .where((w) => w.isNotEmpty)
        .toList();
    final out = <String>[];
    for (var i = 0; i < words.length; i++) {
      final here = labelRun(words[i]);
      final next = i + 1 < words.length ? labelRun(words[i + 1]) : null;
      if (here != null &&
          next != null &&
          next.$1 == here.$1 &&
          next.$2 > here.$2 &&
          next.$2 - here.$2 < 128) {
        for (var n = here.$2; n <= next.$2; n++) {
          if (known.contains('${here.$1}$n')) out.add('${here.$1}$n');
        }
        i++;
        continue;
      }
      if (known.contains(words[i])) out.add(words[i]);
    }
    return out;
  }

  /// Expand range cabling into explicit per-device clauses:
  /// "PC1-PC5 to SW1 FastEthernet0/2-0/6" becomes
  /// "PC1 to SW1 f0/2, PC2 to SW1 f0/3, ... PC5 to SW1 f0/6", and the
  /// list form "DHCP1, DNS1, ... to SW1 FastEthernet0/7-0/12" pairs its six
  /// names with six ports in the order both were written.
  ///
  /// Without this the link regexes saw ONE device (the last name of the
  /// range) against ONE port (the first of the range), so a ten-PC and
  /// six-server request became two cables.
  static String expandCablingRanges(
    String text, {
    required List<NetNode> endpoints,
    required List<NetNode> switches,
    required String? Function(String) node,
  }) {
    final known = {for (final n in endpoints) n.name.toLowerCase()};
    final switchNames = {for (final n in switches) n.name.toLowerCase()};
    if (known.isEmpty || switchNames.isEmpty) return text;
    // The port range and its switch; the device list is the clause in front
    // of it, up to the previous sentence or range.
    final range = RegExp(
      r'\b([a-z0-9]+)\s+([sfg])\s+(\d+)\/(\d+)\s*'
      r'(?:-|–|to|through|thru)\s*(\d+)(?:\/(\d+))?',
      caseSensitive: false,
    );
    var clauseFrom = 0;
    return text.replaceAllMapped(range, (m) {
      final sw = node(m.group(1)!);
      if (sw == null || !switchNames.contains(sw.toLowerCase())) {
        return m.group(0)!;
      }
      final head = text.substring(clauseFrom, m.start);
      final breaks = [
        head.lastIndexOf('.'),
        head.lastIndexOf(';'),
        head.lastIndexOf('\n'),
      ].reduce((a, b) => a > b ? a : b);
      final clause = head.substring(breaks + 1);
      final devices = deviceSpan(clause, known);
      // "f0/2-0/6" ends on slot 6; "f0/2-6" is the same range written short.
      final firstSlot = int.tryParse(m.group(4)!) ?? 0;
      final lastSlot = int.tryParse(m.group(6) ?? m.group(5)!) ?? 0;
      final portPrefix = '${m.group(2)!}${m.group(3)!}';
      final ports = <String>[];
      for (var slot = firstSlot;
          slot <= lastSlot && ports.length < devices.length;
          slot++) {
        ports.add('$portPrefix/$slot');
      }
      if (ports.isEmpty) return m.group(0)!;
      clauseFrom = m.end;
      final pairs = devices.length < ports.length
          ? devices.length
          : ports.length;
      return [
        for (var i = 0; i < pairs; i++)
          '${node(devices[i]) ?? devices[i]} to $sw ${ports[i]}',
      ].join(', ');
    });
  }

  /// The shared secret the brief actually supplies, or null.
  ///
  /// A KEY WORD is only a key when a value follows it.  "using the same
  /// shared key on the server and router" says the two ends agree and never
  /// says what it is: reading the next word produced `tacacs-server key on`
  /// on the router and a client entry keyed "on" on the server.  Words that
  /// are never a secret are skipped instead, and the brief's own key wins.
  static final RegExp _keyValue = RegExp(
    r'\b(?:pre[- ]?shared|shared|psk|secret)?\s*keys?\s*'
    r'(?:is|are|=|:)?\s*([^\s,;.]+)',
    caseSensitive: false,
  );

  static const Set<String> keyStopWords = {
    'a', 'an', 'and', 'are', 'as', 'at', 'across', 'b', 'be', 'between',
    'both', 'by', 'do', 'does', 'each', 'for', 'from', 'i', 'in', 'is', 'it',
    'its', 'key', 'keys', 'must', 'no', 'not', 'of', 'on', 'or', 'same',
    'server', 'shared', 'should', 'that', 'the', 'their', 'they', 'this',
    'to', 'use', 'used', 'using', 'value', 'we', 'will', 'with', 'you',
  };

  static String? readSharedKey(String text) {
    for (final m in _keyValue.allMatches(text)) {
      final value = m.group(1)!.replaceAll(RegExp(r'[.,;]+$'), '');
      if (value.isEmpty || keyStopWords.contains(value.toLowerCase())) {
        continue;
      }
      return value;
    }
    return null;
  }

  /// The label a brief puts in front of a user name.
  ///
  /// Users write the label, not the schema: "for the AAA server clinet name
  /// admin password 123" states the same three facts as "aaa username admin
  /// password 123", so every spelling of the noun is accepted, including the
  /// very common "clinet" and the two-word "client name".  The two-word forms
  /// come first so they win over the bare noun.
  ///
  /// The guard against reading ordinary prose as a login is ADJACENCY, not a
  /// separator: between the user name and the word "password" this pattern
  /// allows only punctuation and a small set of connectives.  "the user ports
  /// and the password policy" is rejected because "policy" is a
  /// [secretStopWords] entry, and a phrase with real words in between never
  /// reaches the password half at all.
  static const String _credentialLabel =
      r'\b(?:'
      r'username|user\s+name|user\s+id|login|account'
      r'|client\s+name|clinet\s+name|cli(?:ent)?\s+name|client\s+id'
      r'|user|client|clinet|cli'
      r')';

  /// "username admin password 123", "clinet name admin with password 123".
  static final RegExp credentialPattern = RegExp(
    '$_credentialLabel'
    r'\s*[:=]?\s*'
    r'([A-Za-z0-9_.-]{1,32})'
    r'\s*[,;]?\s*(?:(?:with|and|its|their|is|of)\s+)?'
    r'\b(?:password|pass|pwd|passwd|secret)\b\s*(?:is\s+|[:=]\s*)?'
    r'([^\s,;.]+)',
    caseSensitive: false,
  );

  /// The same pair written the other way round, which briefs use when the
  /// password is stated first ("password 123 for the admin account").
  static final RegExp credentialPatternReversed = RegExp(
    r'\b(?:password|pass|pwd|passwd)\b\s*[:=]?\s*([^\s,;.]+)\s*'
    r'(?:for|with|of|as|and)?\s*'
    '($_credentialLabel)'
    r'\s*[:=]?\s*([A-Za-z0-9_.-]{1,32})',
    caseSensitive: false,
  );

  /// Every login the brief states, in the order it says them.
  ///
  /// Both orders are scanned and the earliest match of a given user name
  /// wins, so a brief that writes one of each does not end up with the second
  /// one doubled onto the first server.  Values that are only a keyword in
  /// disguise are skipped, on the same [secretStopWords] rule the rest of the
  /// parser already uses for secrets.
  static List<Credential> readCredentials(String text) {
    final found = <Credential>[];
    // A brief wraps its clauses: "password 123)" and "password 123." put the
    // punctuation of the sentence inside the value, and "123" is what the
    // server is actually told.
    final trimValue = RegExp("[.,;:)\\]}\"']+\$");
    void take(String user, String pass, int at, String whole) {
      final u = user.replaceAll(trimValue, '');
      final p = pass.replaceAll(trimValue, '');
      if (u.isEmpty || p.isEmpty) return;
      if (secretStopWords.contains(u.toLowerCase())) return;
      if (secretStopWords.contains(p.toLowerCase())) return;
      if (found.any((c) => c.username.toLowerCase() == u.toLowerCase())) return;
      found.add(Credential(u, p, at, whole));
    }

    for (final m in credentialPattern.allMatches(text)) {
      take(m.group(1)!, m.group(2)!, m.start, m.group(0)!);
    }
    // Reversed: the password comes first, so the label is group 2 and the
    // user name group 3.
    for (final m in credentialPatternReversed.allMatches(text)) {
      take(m.group(3)!, m.group(1)!, m.start, m.group(0)!);
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    return found;
  }

  /// A "KEY WORD value" phrase with the keyword captured, so the caller can
  /// tell whose secret it is.  `pre-shared key X` and `psk X` belong to the
  /// VPN; a bare `key X` in the same brief is the AAA or routing one.
  static final RegExp _keyPhrase = RegExp(
    r'\b(pre[- ]?shared|shared|psk)?\s*keys?\s*(?:is|are|=|:)?\s*([^\s,;.]+)',
    caseSensitive: false,
  );

  /// The shared key to write on BOTH ends, or null when the brief leaves it
  /// unsaid.
  ///
  /// A brief that names a key but gives no value - "using the same shared key
  /// on the server and router" - has left it unsaid, and the app must not fill
  /// that silence in from the account password: the two are different secrets
  /// and the adapters' documented lab default stands.  A brief that never
  /// mentions a key at all is the ordinary single-secret lab case, where the
  /// account password IS the secret the router and the server share.
  ///
  /// A PRE-SHARED key belongs to the VPN, so it is skipped here: one brief
  /// naming both an IPsec PSK and a TACACS+ account was handing the VPN's
  /// secret to the AAA server, and the two ends then disagreed. An explicitly
  /// stated AAA key keeps this parser's long-standing lower-casing, which the
  /// router and server renderings both read from this one field and so stay
  /// identical; the account fallback keeps the case the user typed.
  static String? resolveAaaKey(String text, Credential? account) {
    var mentionsAaaKey = false;
    for (final m in _keyPhrase.allMatches(text)) {
      final keyword = (m.group(1) ?? '').toLowerCase();
      if (keyword.startsWith('pre') || keyword == 'psk') continue;
      mentionsAaaKey = true;
      final value = m.group(2)!.replaceAll(RegExp(r'[.,;)\]}]+$'), '');
      if (value.isEmpty || keyStopWords.contains(value.toLowerCase())) {
        continue;
      }
      return value.toLowerCase();
    }
    if (account == null || mentionsAaaKey) return null;
    return account.password.isEmpty ? null : account.password;
  }

  /// A time-of-day range, ignoring anything that is part of an address.
  ///
  /// The connector between the two numbers is the same character a network
  /// uses to join a range ("192.168.10.100-192.168.10.200"), so a bare digit
  /// pattern reads a subnet pool as office hours. A candidate is dropped when
  /// either end continues into a NUMBER - a digit, or a dot that has a digit
  /// on its far side. A sentence-ending period is not part of a number, so
  /// "business hours 09:00 to 17:00." still reads as a time; and because the
  /// trailing period always follows the match's own last digit, only the
  /// FAR side of it can say whether an address continues.
  static RegExpMatch? _timeRange(String text) {
    final pattern = RegExp(
      r'(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*'
      r'(?:to|-|until|through|till|الى|الي|حتي)\s*'
      r'(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)',
      caseSensitive: false,
    );
    final digit = RegExp(r'[0-9]');
    String? at(int index) =>
        index < 0 || index >= text.length ? null : text[index];

    for (final m in pattern.allMatches(text)) {
      // Left of the match: a digit, or a dot whose own left side is a digit.
      final b = at(m.start - 1);
      if (b != null && digit.hasMatch(b)) continue;
      if (b == '.' && digit.hasMatch(at(m.start - 2) ?? '')) continue;
      // Right of the match: a digit, or a dot whose own right side is a digit.
      final a = at(m.end);
      if (a != null && digit.hasMatch(a)) continue;
      if (a == '.' && digit.hasMatch(at(m.end + 1) ?? '')) continue;
      return m;
    }
    return null;
  }

  /// What stands in for a value that was redacted.
  static const redacted = '[redacted]';

  /// Words that follow a secret keyword without being one: "the password
  /// policy", "the enable secret must differ", "the same key on both ends".
  /// [keyStopWords] is the list this parser already uses to tell a key value
  /// from the next ordinary word; these are the same decision for a brief that
  /// talks about a password instead of supplying one.
  static const Set<String> secretStopWords = {
    ...keyStopWords,
    'policy',
    'policies',
    'differ',
    'differs',
    'different',
    'per',
  };

  /// A password-like value in free text: `password X`, `secret X`,
  /// `shared key X` / `pre-shared key X`, `psk X`, and `enable secret X` (the
  /// plain `secret` covers the last one).  A quoted value is taken whole, so
  /// `password "S3cret!"` is replaced as one thing, and the trailing
  /// punctuation of a brief ("password x.") is left outside the match.
  ///
  /// A bare `key` IS matched, because "key is cisco123" is a credential and the
  /// next word decides which of the two readings it is (see
  /// [secretStopWords]).  A bare `pass` is NOT: in a sentence "a pass route
  /// through the top" is English, and there the word after it says so.
  ///
  /// Group 1 is the keyword, group 2 the separator the user wrote and group 3
  /// the value, so the redaction keeps the brief's own punctuation.
  static final RegExp _secretValue = RegExp(
    r"""\b((?:pre[\s-]?shared|shared)?[\s-]?key|psk|password|passwd|secret)\b"""
    r"""(\s*(?:(?:is|are|of)\b\s*)?[:=]?\s*)"""
    r"""("[^"\n]+"|'[^'\n]+'|[^\s,;]+)""",
    caseSensitive: false,
  );

  /// [text] with every password-like value replaced by [redacted].
  ///
  /// The plan notes quote the user's own brief back ("parsed offline from:
  /// ..."), and a brief is where people type credentials.  The notes are
  /// persisted, exported and shown next to the plan, so a password written
  /// there would sit in clear text in the database and in every export - which
  /// is exactly what `includeSecrets: false` promises not to do.  Redacting
  /// where the note is written keeps the stored value safe as well as the
  /// exported one; the credential itself still reaches the executor through
  /// [SecurityIntent], which is where it belongs.
  static String redactSecrets(String text) =>
      text.replaceAllMapped(_secretValue, (m) {
        final value = m.group(3)!;
        final bare = value
            .replaceAll(RegExp(r'''^["']|["']$'''), '')
            .replaceAll(RegExp(r'[.,;:]+$'), '');
        if (bare.isEmpty || secretStopWords.contains(bare.toLowerCase())) {
          return m.group(0)!;
        }
        final tail = _trailingPunctuation(value);
        return '${m.group(1)}${m.group(2)}$redacted$tail';
      });

  /// The ";" and "." a brief puts after a value, which belong to the sentence
  /// rather than to the secret.
  static String _trailingPunctuation(String value) =>
      RegExp(r'[.,;:]+$').firstMatch(value)?.group(0) ?? '';

  /// Put back the secrets a redacted copy of [plan] dropped, using the app's
  /// own record of what the user said - [transcript].
  ///
  /// A plan written with `includeSecrets: false` has every `password`/`secret`
  /// key removed, which leaves an account row that still names its user but no
  /// longer holds the password. Restoring that shape and then validating it
  /// reported "an account missing username or password" for a credential the
  /// user HAD supplied, and the build stayed withheld for good: the plan could
  /// not be repaired, because inventing a password is exactly what the app
  /// must never do. The transcript is the other half of the same record, so the
  /// value is recovered from there instead: every value put back here is one
  /// the user typed.
  ///
  /// Only empty slots are filled, so a plan that genuinely has no credential
  /// still reports the gap and still asks the user for it.
  static NetworkIntent recoverRedactedSecrets(
    NetworkIntent plan,
    String transcript,
  ) {
    final text = transcript.trim();
    if (text.isEmpty) return plan;
    final passwords = <String, String>{
      for (final c in readCredentials(text))
        if (c.password.isNotEmpty) c.username.toLowerCase(): c.password,
    };
    final enableSecret = RegExp(
      r'enable\s+secret\s+([^\s,;.]+)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    if (passwords.isEmpty && enableSecret == null) return plan;

    // --- the account rows the plan itself carries --------------------------
    var nodesChanged = false;
    final nodes = <NetNode>[];
    for (final node in plan.nodes) {
      Map<String, dynamic>? rebuilt;
      for (final entry in node.serviceRules.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final users = raw['users'];
        if (users is! List) continue;
        List<dynamic>? filled;
        for (var i = 0; i < users.length; i++) {
          final item = users[i];
          if (item is! Map) continue;
          final row = Map<String, dynamic>.from(item);
          final name = (row['username'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          if ((row['password'] ?? '').toString().trim().isNotEmpty) continue;
          final found = passwords[name.toLowerCase()];
          if (found == null) continue;
          row['password'] = found;
          (filled ??= List<dynamic>.from(users))[i] = row;
        }
        if (filled != null) {
          rebuilt ??= Map<String, dynamic>.from(node.serviceRules);
          rebuilt[entry.key] = {
            ...Map<String, dynamic>.from(raw),
            'users': filled,
          };
        }
      }
      if (rebuilt == null) {
        nodes.add(node);
        continue;
      }
      nodesChanged = true;
      nodes.add(
        NetNode(
          name: node.name,
          type: node.type,
          model: node.model,
          mgmtIp: node.mgmtIp,
          services: node.services,
          serviceRules: rebuilt,
        ),
      );
    }

    // --- the security fields ------------------------------------------------
    var security = plan.security;
    if (security.requested) {
      final rows = nodes
          .where((n) => n.name == security.aaaServer)
          .expand(
            (n) =>
                (n.serviceRules['aaa'] as Map?)?['users'] as List? ??
                const <dynamic>[],
          );
      String? accountUser = security.aaaUsername;
      String? accountPass = security.aaaAccountPassword;
      for (final row in rows) {
        if (row is! Map) continue;
        final name = (row['username'] ?? '').toString().trim();
        final pass = (row['password'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        if ((accountUser ?? '').isEmpty) accountUser = name;
        if ((accountPass ?? '').isEmpty && pass.isNotEmpty) accountPass = pass;
      }
      if ((accountPass ?? '').isEmpty && (accountUser ?? '').isNotEmpty) {
        accountPass = passwords[accountUser!.toLowerCase()];
      }
      final account = (accountUser ?? '').isEmpty || (accountPass ?? '').isEmpty
          ? null
          : Credential(accountUser!, accountPass!, 0, 'aaa $accountUser');
      final secJson = security.toJson(includeSecrets: true);
      var secTouched = false;
      void fill(String key, String? value) {
        final current = (secJson[key] ?? '').toString().trim();
        if (current.isNotEmpty || (value ?? '').isEmpty) return;
        secJson[key] = value!;
        secTouched = true;
      }

      fill('aaaUsername', accountUser);
      fill('aaaAccountPassword', accountPass);
      fill('aaaPassword', resolveAaaKey(text, account));
      fill('enableSecret', enableSecret);
      fill('vpnPreSharedKey', _preSharedKeyIn(text));
      if (secTouched) security = SecurityIntent.fromJson(secJson);
    }

    if (!nodesChanged && security == plan.security) return plan;
    return plan.copyWith(nodes: nodes, security: security);
  }

  /// A PRE-SHARED key the brief states ("pre-shared key LabKey1", "psk X"),
  /// skipped when the brief only talks about a key and supplies none.
  static String? _preSharedKeyIn(String text) {
    for (final m in _keyPhrase.allMatches(text)) {
      final keyword = (m.group(1) ?? '').toLowerCase();
      if (!keyword.startsWith('pre') && keyword != 'psk') continue;
      final value = m.group(2)!.replaceAll(RegExp(r'[.,;)\]}]+$'), '');
      if (value.isEmpty || keyStopWords.contains(value.toLowerCase())) continue;
      return value;
    }
    return null;
  }

  /// Dotted mask for a prefix length ("24" -> "255.255.255.0").
  static String prefixToMask(String prefix) {
    final bits = int.tryParse(prefix) ?? 24;
    final clamped = bits.clamp(0, 32);
    final mask = clamped == 0 ? 0 : (0xFFFFFFFF << (32 - clamped)) & 0xFFFFFFFF;
    return [
      (mask >> 24) & 255,
      (mask >> 16) & 255,
      (mask >> 8) & 255,
      mask & 255,
    ].join('.');
  }

  /// True when [ip] sits inside the subnet [network]/[prefix].
  static bool sameNetwork(String ip, String network, int prefix) {
    final a = ip.trim().split('.');
    final b = network.trim().split('.');
    if (a.length != 4 || b.length != 4) return false;
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final x = int.tryParse(a[i]);
      final y = int.tryParse(b[i]);
      if (x == null || y == null) return false;
      value |= (x & 255) << (8 * (3 - i));
    }
    final base = int.tryParse(b.join('.'));
    if (base == null) return false;
    final width = prefix.clamp(0, 32);
    final mask = width == 0 ? 0 : (0xFFFFFFFF << (32 - width)) & 0xFFFFFFFF;
    return (value & mask) == (base & mask);
  }

  /// Which VLAN the wording pinned each device kind to: "pcs in vlan 10",
  /// "vlan 20 for the guest access points". Keys are [DeviceKind.type]
  /// values ('pc', 'server', 'wireless', ...); a kind the wording did not
  /// pin is absent and keeps the round-robin spread the planner has always
  /// used.
  static Map<String, int> _vlanRolesFrom(String lower) {
    final roles = <String, int>{};

    // Words that carry no device meaning inside a pinned-VLAN phrase:
    // "the guest ACCESS POINTS" names the same kind as "access points".
    const filler = {
      'the', 'a', 'an', 'our', 'their', 'all', 'guest', 'staff', 'wired',
      'fixed', 'for', 'in', 'on', 'to', 'of', 'and', 'or', 'with',
      'devices', 'device', 'kind', 'ones',
    };
    String single(String w) =>
        w.length > 2 && w.endsWith('s') && !w.endsWith('ss')
            ? w.substring(0, w.length - 1)
            : w;

    // The longest device-kind phrase inside [phrase], if any: n-grams are
    // tried longest first, so "access points" beats a stray inner word.
    String? kindIn(String phrase) {
      final words = phrase
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9+#-]+'))
          .where((w) => w.isNotEmpty && !filler.contains(w))
          .toList();
      for (var start = 0; start < words.length; start++) {
        for (var end = words.length; end > start; end--) {
          final wordsIn = words.sublist(start, end);
          final kind = deviceKindFor(wordsIn.join(' ')) ??
              deviceKindFor(wordsIn.map(single).join(' '));
          if (kind != null) return kind.type;
        }
      }
      return null;
    }

    bool valid(int v) => v > 0 && v <= 4094;
    // "pcs in vlan 10", "servers in vlan 10", "access points in vlan 20".
    for (final m
        in RegExp(r'\b([\w-]+(?:\s+[\w-]+){0,3}?)\s+in\s+vlan\s*(\d{1,4})\b')
            .allMatches(lower)) {
      final v = int.parse(m.group(2)!);
      if (!valid(v)) continue;
      final kind = kindIn(m.group(1)!);
      if (kind != null) roles[kind] = v;
    }
    // "vlan 20 for the guest access points" - the phrase runs to the next
    // clause boundary.
    for (final m in RegExp(r'\bvlan\s*(\d{1,4})\s+for\s+([^,.;:!?]*)')
        .allMatches(lower)) {
      final v = int.parse(m.group(1)!);
      if (!valid(v)) continue;
      final kind = kindIn(m.group(2)!);
      if (kind != null) roles[kind] = v;
    }
    return roles;
  }

  /// Very small heuristic parser so the app works offline without Gemini.
  /// Handles: "2 routers 1 switch", "192.168.1.0/24", "ospf", vlan numbers,
  /// explicit models ("use 4331") or best-fit router choice - and, through
  /// [bridgeBrief], the same request written in Arabic, with Arabic-Indic
  /// digits, with a dotted mask or with the numbers spelled out.
  /// How many people the brief says the network is for - "a corporate network
  /// for 40 users" is 40 - or null when it names no headcount.
  ///
  /// Deliberately narrow: a number immediately followed by a head word. This
  /// is the figure the design has to SUPPORT, not the device list ("15 PCs"),
  /// which is what the plan is actually built from. A subnet question ("how
  /// many hosts does a /28 hold"), a credential ("password 123") and a server
  /// role ("1 DHCP server") are none of them a headcount.
  static int? statedUserCount(String text) {
    final match = RegExp(
      r'\b(\d{1,4})\s*(?:users?|employees?|people|staff|students?|seats?|'
      r'desks?|heads?)\b',
      caseSensitive: false,
    ).firstMatch(text);
    final value = int.tryParse(match?.group(1) ?? '');
    if (value == null || value <= 0 || value > 5000) return null;
    return value;
  }

  /// How many desks a plan actually seats: PCs and laptops, the two kinds a
  /// person sits at. Phones, tablets and printers are not seats.
  static int deskSeats(List<NetNode> nodes) =>
      nodes.where((n) => n.type == 'pc' || n.type == 'laptop').length;

  /// The popup a self-contradicting brief earns - "for 40 users ... 15 PCs ...
  /// 10 PCs" - or null when there is nothing to ask.
  ///
  /// The plan keeps the devices the brief listed; the question is whether the
  /// headcount it also stated should grow them. The answer travels as a normal
  /// follow-up message ([PlanPromptOption.reply]), so "add 15 more PCs" is
  /// planned by the same code path a typed request uses.
  static PlanPrompt? headcountPrompt({
    required String brief,
    required List<NetNode> nodes,
  }) {
    final stated = statedUserCount(brief);
    if (stated == null) return null;
    final seats = deskSeats(nodes);
    if (seats == 0 || seats == stated) return null;
    final missing = (stated - seats).abs();
    final grow = stated > seats;
    final plural = seats == 1 ? 'PC' : 'PCs';
    return PlanPrompt(
      id: 'headcount:$stated:$seats',
      title: 'Heads up: $stated users, $seats $plural',
      message: grow
          ? 'Your brief is for $stated users, but its device list names $seats '
                '$plural. Nothing was invented: the plan has the $seats you '
                'listed, and the LANs and DHCP scope are sized for $stated.\n\n'
                'Add the missing $missing?'
          : 'Your brief is for $stated users, but its device list names $seats '
                '$plural. The plan has the $seats you listed.\n\n'
                'Keep them, or say "make it $stated PCs" and I will trim it.',
      options: [
        if (grow)
          PlanPromptOption(
            label: 'Add $missing $plural (make it $stated)',
            reply: 'add $missing more PCs',
            recommended: true,
          ),
        PlanPromptOption(
          label: 'Keep the $seats $plural I listed',
          recommended: !grow,
        ),
      ],
    );
  }

  /// Record a headcount disagreement on the plan itself: the popup the user
  /// answers, and one assumption in the plan's own words - so the answer and
  /// the built file can never tell two different stories about the count.
  static NetworkIntent _withHeadcountCheck(
    String brief,
    NetworkIntent intent,
  ) {
    final prompt = headcountPrompt(brief: brief, nodes: intent.nodes);
    if (prompt == null) return intent;
    return intent.copyWith(
      prompts: [...intent.prompts, prompt],
      assumptions: [
        ...intent.assumptions,
        'The brief asks for ${statedUserCount(brief)} users but names '
            '${deskSeats(intent.nodes)} PCs: the plan builds the PCs it was '
            'given, and the subnets and DHCP scope are sized for the headcount.',
      ],
    );
  }


  // Thin delegates to the extracted reader. Every caller in the app says
  // `NetworkIntent.bridgeBrief(...)`; Dart has no way to re-export a static
  // member, so these one-liners are what keep the extraction invisible. They
  // are the second half of the seam: the behaviour is in parser.dart.
  static String bridgeBrief(String raw) => brief_reader.bridgeBrief(raw);
  static int? siteCount(String text) => brief_reader.siteCount(text);
  static Map<String, int>? perSiteCounts(String text) =>
      brief_reader.perSiteCounts(text);
  static bool namesAnyDeviceIn(String lower) =>
      brief_reader.namesAnyDeviceIn(lower);

  /// The brief reader lives in services/nlu/parser.dart. This stays as the
  /// name every caller already uses, so the extraction moved code without
  /// moving a single call site.
  static NetworkIntent parseSimple(String projectName, String rawText) =>
      brief_reader.parseBrief(projectName, rawText);

  /// Sizing pass + parse over an already-bridged brief. The phrasing index
  /// is consulted once, at the top of [parseSimple] - never here - so a
  /// replayed rewrite cannot replay itself.
  static NetworkIntent parseBridged(
    String projectName,
    String bridged,
    String rawText,
  ) {
    final lower = bridged.toLowerCase();
    // The sizing pack answers business briefs - "10 employees and two floors"
    // - before the parser proper runs. It is skipped for the two-site
    // security profile, which is its own deterministic lab, and for any brief
    // that states device counts: those are read exactly as written.
    //
    // The count exclusion used to exist only in the comment. Without it a
    // brief that already named its 25 PCs and 4 servers was still EXPANDED by
    // the sizing pack before parsing, and the expansion is a different
    // sentence: the role words and the credential moved apart, so "set up AAA
    // with the client name admin and password 123" was read as an account for
    // a server that no longer ran AAA.
    final statesCounts = RegExp(
      r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
      r'printers?|firewalls?|phones?|tablets?|clouds?|modems?)\b',
    ).hasMatch(lower);
    final sized = (_looksLikeSecurityBranchLab(lower) || statesCounts)
        ? null
        : SizingService.forBrief(bridged);
    if (sized == null) {
      return _withHeadcountCheck(
        bridged,
        _parseBridgedBrief(projectName, bridged, rawText),
      );
    }
    final intent = _parseBridgedBrief(projectName, sized.expandedBrief, rawText);
    return _withHeadcountCheck(
      bridged,
      intent.copyWith(
        // The sizing reasons read first, then its assumptions, then whatever
        // the parser itself assumed: the user reads them in that order.
        assumptions: [
          ...sized.reasons,
          ...sized.assumptions,
          ...intent.assumptions,
        ],
        questions: [...sized.questions, ...intent.questions],
        confidence: sized.confidence,
      ),
    );
  }

  /// The parser itself, over an already-bridged brief.
  static NetworkIntent _parseBridgedBrief(
    String projectName,
    String text,
    String rawText,
  ) {
    final lower = text.toLowerCase();
    if (_looksLikeSecurityBranchLab(lower)) {
      return _parseSecurityBranchLab(projectName, text);
    }
    final nodes = <NetNode>[];
    final vlans = <int>[];
    var routing = 'static';

    // Device counts are ONE pipeline's job: BriefSlotPipeline owns the
    // extraction rules (quantities, bare mentions, roles, per-site, labels,
    // the tiny-office default) and this parser consumes its map, so two
    // readers of the same brief can never drift apart. The facts still
    // needed by hand below - site counts, named servers, per-kind label
    // raises - are recomputed here exactly as before.
    final slots = BriefSlotPipeline.extractCounts(lower, text);
    final routerCount = slots['router'] ?? 0;
    final switchCount = slots['switch'] ?? 0;
    final pcCount = slots['pc'] ?? 0;
    final serverCount = slots['server'] ?? 0;
    final kindCounts = <String, int>{
      for (final e in slots.entries)
        if (!const ['router', 'switch', 'pc', 'server'].contains(e.key))
          e.key: e.value,
    };
    // The site facts still reach the built intent below (a multi-site plan
    // carries them); per-site multiplication itself happened in the
    // pipeline.
    final sites = siteCount(text);
    final perSite = sites == null ? null : perSiteCounts(text);
    // How many routers each named site asked for, in site order ("Site A ...
    // 2 routers ... Site B ... 1 router" reads as [2, 1]). The addressing step
    // uses it to place a subnet the brief tied to a site on the LAN that site
    // owns.
    final siteRouters = BriefSlotPipeline.siteRouterCounts(text);
    // Servers the brief names one by one keep their names, so the label
    // list is needed by the node loop below.
    final namedServers = namedServerLabels(text);

    // What the brief actually stated, for the confidence below: a plan is
    // only as trustworthy as the details it was built from.
    final statedRouting = resolveRouting(lower) != null;
    final statedAddresses =
        RegExp(r'\d{1,3}(?:\.\d{1,3}){3}').hasMatch(text);
    final statedCounts = deviceKinds.any(
      (kind) => RegExp(
        '(\\d{1,3})\\s*(?:${kind.keywords.map(RegExp.escape).join('|')})'
        '(?:es|s)?\\b',
      ).hasMatch(lower),
    );
    // The small-office fallback fired and the brief named no devices at
    // all: the plan is a guess, and the assumption and question below say
    // so instead of dressing it as a normal parse.
    final defaulted =
        routerCount == 1 &&
        switchCount == 1 &&
        pcCount == 0 &&
        serverCount == 0 &&
        !namesAnyDeviceIn(lower);
    final localConfidence = _localConfidence(
      statedCounts: statedCounts,
      statedRouting: statedRouting,
      statedAddresses: statedAddresses,
      defaulted: defaulted,
    );

    // Explicit labels are authoritative when the user names devices rather
    // than stating a quantity, e.g. "R1 and R2 ... Cisco 2911 routers".
    // The four kinds are raised inside the pipeline; every OTHER kind is
    // raised here, next to the nodes it creates.
    int highestLabel(String pattern) => RegExp(pattern)
        .allMatches(text)
        .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
        .fold(0, (max, value) => value > max ? value : max);

    final routerModel = bestRouterModel(lower);
    final switchModel = bestSwitchModel(lower);
    for (var i = 1; i <= routerCount; i++) {
      nodes.add(NetNode(name: 'R$i', type: 'router', model: routerModel));
    }
    for (var i = 1; i <= switchCount; i++) {
      nodes.add(NetNode(name: 'SW$i', type: 'switch', model: switchModel));
    }
    for (var i = 1; i <= pcCount; i++) {
      nodes.add(NetNode(name: 'PC$i', type: 'pc', model: 'PC-PT'));
    }
    // The named servers keep their names, in the order the brief listed them;
    // anything beyond them is numbered as before, skipping a name already
    // taken so two servers can never collide.
    for (var i = 1; i <= serverCount; i++) {
      var name = i <= namedServers.length ? namedServers[i - 1] : 'SRV$i';
      var bump = 1;
      while (nodes.any((n) => n.name == name)) {
        name = 'SRV$i${++bump}';
      }
      nodes.add(NetNode(name: name, type: 'server', model: 'Server-PT'));
    }
    for (final entry in kindCounts.entries) {
      if (entry.value <= 0) continue;
      final kind = deviceKindOf(entry.key)!;
      final prefix = devicePrefix(kind.type);
      // "2 IP phones" next to an explicit 'PH1' must not create PH1, PH2 and
      // PH3: the highest label the brief already used is subtracted first.
      final labelled = highestLabel('\\b$prefix(\\d+)\\b');
      final total = entry.value > labelled ? entry.value : labelled;
      for (var i = 1; i <= total; i++) {
        nodes.add(
          NetNode(name: '$prefix$i', type: kind.type, model: kind.models.first),
        );
      }
    }

    // Interface naming matches real PT models: ISR routers (2911/4331/
    // 1941...) have GigabitEthernet ports, 2960 switches FastEthernet.
    // (Old code used f0/x everywhere - invalid on 2911 CLI.)
    const gigRouters = ['4331', '4321', '2911', '2901', '1941', '829'];
    final rIf = gigRouters.contains(routerModel) ? 'g' : 'f';
    final routers = nodes.where((n) => n.type == 'router').toList();
    final switches = nodes.where((n) => n.type == 'switch').toList();
    final pcs = nodes.where((n) => n.type == 'pc').toList();
    final servers = nodes.where((n) => n.type == 'server').toList();
    // PCs and servers are both single-port end devices hanging off
    // switches (PC-PT / Server-PT have only FastEthernet0).  Every other
    // wired, non-CLI kind (IP phones, access points, printers, laptops)
    // hangs off a switch the same way, on the port its catalog entry names;
    // wireless-only devices are deliberately NOT endpoints - a cable cannot
    // be invented for a tablet, and PT associates those with the AP itself.
    // ...but the firewall/cloud/modem are NOT access devices: an ASA on a
    // user switch is not the topology that was asked for, so they are wired
    // to the WAN side of the router further down instead.
    const wanSideKinds = {'firewall', 'cloud', 'modem'};
    final wiredExtras = nodes.where((n) {
      final kind = deviceKindOf(n.type);
      return kind != null &&
          kind.wired &&
          !kind.cli &&
          !wanSideKinds.contains(n.type) &&
          !const ['pc', 'server'].contains(n.type);
    }).toList();
    final endpoints = [...pcs, ...servers, ...wiredExtras];
    String endpointPort(String name) {
      final node = nodes.firstWhere((n) => n.name == name);
      final kind = deviceKindOf(node.type);
      return (kind != null && kind.port.isNotEmpty) ? kind.port : 'f0';
    }

    // Base subnet: first CIDR in the instruction, else 192.168.1.0/24.
    final baseCidr = RegExp(
      r'(\d+\.\d+\.\d+\.\d+)\s*/\s*(\d+)',
    ).firstMatch(text);
    final base = baseCidr != null
        ? '${baseCidr.group(1)!}/${baseCidr.group(2)!}'
        : '192.168.1.0/24';
    var transitPool = 0;
    var lanPool = 0;

    // EXPLICIT CABLING WINS: "R1 GigabitEthernet0/1 connects to R2 ...",
    // "R1 g0/0 connects to SW1 f0/1", "Connect R1 Serial0/0/0 to R2
    // Serial0/0/0". Normalize long names to g/f/s so one regex covers every
    // spelling and every port depth (a serial port is 0/0/0, not 0/0).
    // (Bug: the old chain ignored requested interfaces, so R1-R2 landed on
    // g0/0 with the LAN subnet, and a router-to-router Serial0/0/0 sentence
    // matched nothing at all because the interface class was g/f only.)
    String norm(String s) => s
        .toLowerCase()
        .replaceAll('gigabitethernet', ' g ')
        .replaceAll('fastethernet', ' f ')
        .replaceAll('serial', ' s ')
        .replaceAll(RegExp(r'\s+'), ' ');
    String? node(String w) {
      final w2 = w.toLowerCase().trim();
      // return the CANONICAL node name ('r1' typed in text -> 'R1')
      for (final n in nodes) {
        if (n.name.toLowerCase() == w2) return n.name;
      }
      return null;
    }

    // A serial WAN is a DIFFERENT cable from a LAN link: when the brief says
    // serial / WAN / leased line / back-to-back the transit link is
    // Serial0/0/0, which is also what tells the executor to fit the HWIC-2T
    // and wire the cable with one clocking (DCE) end.
    final wantsSerialWan = RegExp(
      r'(serial|\bwan\b|leased[- ]line|back[- ]to[- ]back|frame relay|dsl)',
    ).hasMatch(lower);

    // "PC1-PC5 to SW1 FastEthernet0/2-0/6" and "DHCP1, DNS1, WEB1, AAA1,
    // FTP1 and MAIL1 to SW1 FastEthernet0/7-0/12" are six cables each, not
    // one. The wording is expanded into explicit per-device clauses before
    // the link regexes read it, so the device order and the port order stay
    // paired - reading the range's last name against its first port is how
    // five PCs and six servers collapsed into two cables.
    final normText = expandCablingRanges(
      norm(text),
      endpoints: endpoints,
      switches: switches,
      node: node,
    );

    final linksExplicit = <NetLink>[];
    final fullLink = RegExp(
      r'(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})\s*(?:connects?\s*to|to)\s*(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})',
    );
    for (final m in fullLink.allMatches(normText)) {
      final a = node(m.group(1)!);
      final b = node(m.group(4)!);
      if (a == null || b == null || a == b) continue;
      linksExplicit.add(
        NetLink(
          a: a,
          aIf: '${m.group(2)!}${m.group(3)!}',
          b: b,
          bIf: '${m.group(5)!}${m.group(6)!}',
        ),
      );
    }
    // "R1 and R2 connect ... using g0/1 on both sides"
    final pairLink = RegExp(
      r'(\w+)\s+and\s+(\w+)\s+connect[^.]*?\b([sfg])\s*(\d+(?:/\d+){0,2})\s+on\s+both',
    );
    for (final m in pairLink.allMatches(normText)) {
      final a = node(m.group(1)!);
      final b = node(m.group(2)!);
      if (a == null || b == null || a == b) continue;
      linksExplicit.add(
        NetLink(
          a: a,
          aIf: '${m.group(3)!}${m.group(4)!}',
          b: b,
          bIf: '${m.group(3)!}${m.group(4)!}',
        ),
      );
    }
    // Also understand plain English descriptions that omit router names:
    // "Connect the routers to each other using GigabitEthernet0/1 on both
    // sides." This is unambiguous only for a two-router plan.
    final unnamedRouterPair = RegExp(
      r'\bconnects?\s+(?:the\s+)?routers?\s+to\s+each\s+other[^.]*?\b([sfg])\s*(\d+(?:/\d+){0,2})\s+on\s+both(?:\s+sides)?\b',
    ).firstMatch(normText);
    if (unnamedRouterPair != null && routers.length == 2) {
      final iface = '${unnamedRouterPair.group(1)!}${unnamedRouterPair.group(2)!}';
      linksExplicit.add(
        NetLink(
          a: routers[0].name,
          aIf: iface,
          b: routers[1].name,
          bIf: iface,
          cable: lower.contains('crossover') ? 'copper-cross' : null,
        ),
      );
    }
    // "PC1 connects to SW1 FastEthernet0/2" (end-device side has only
    // Fa0 - same for "SRV1 connects to SW1 FastEthernet0/4"), and
    // "PH1 Port 1 connects to SW1 FastEthernet0/5" for the kinds whose
    // interfaces are not named Fa0/Gi0 (IP phone, access point, modem).
    final pcLink = RegExp(
      r'(\w+)\s+connects?\s*to\s+(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})',
    );
    for (final m in pcLink.allMatches(normText)) {
      final pc = node(m.group(1)!);
      final other = node(m.group(2)!);
      if (pc == null || other == null) continue;
      if (!endpoints.any((p) => p.name.toLowerCase() == pc.toLowerCase())) {
        continue;
      }
      linksExplicit.add(
        NetLink(
          a: other,
          aIf: '${m.group(3)!}${m.group(4)!}',
          b: pc,
          bIf: endpointPort(pc), // PC-PT: one port; phone/AP: Port 1
        ),
      );
    }
    // Accept both ordinary imperative and abbreviated endpoint-first forms:
    // "Connect PC1 to SW1 FastEthernet0/2" and
    // "PC2 to SW1 FastEthernet0/3". The older parser only accepted
    // "PC1 connects to SW1 FastEthernet0/2".
    final endpointFirstLink = RegExp(
      r'\b(\w+)\s+(?:connects?\s+)?to\s+(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})',
    );
    for (final m in endpointFirstLink.allMatches(normText)) {
      final ep = node(m.group(1)!);
      final sw = node(m.group(2)!);
      if (ep == null || sw == null) continue;
      if (!endpoints.any((p) => p.name.toLowerCase() == ep.toLowerCase()) ||
          !switches.any((s) => s.name.toLowerCase() == sw.toLowerCase())) {
        continue;
      }
      linksExplicit.add(
        NetLink(
          a: sw,
          aIf: '${m.group(3)!}${m.group(4)!}',
          b: ep,
          bIf: endpointPort(ep),
        ),
      );
    }
    // Some natural descriptions put the switch port first:
    // "SW1 FastEthernet0/2 to PC1". Accept that direction too.
    final switchFirstLink = RegExp(
      r'\b(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})\s*(?:connects?\s+to|to)\s+(\w+)\b',
    );
    for (final m in switchFirstLink.allMatches(normText)) {
      final sw = node(m.group(1)!);
      final ep = node(m.group(4)!);
      if (sw == null || ep == null) continue;
      if (!switches.any((s) => s.name.toLowerCase() == sw.toLowerCase()) ||
          !endpoints.any((p) => p.name.toLowerCase() == ep.toLowerCase())) {
        continue;
      }
      linksExplicit.add(
        NetLink(
          a: sw,
          aIf: '${m.group(2)!}${m.group(3)!}',
          b: ep,
          bIf: endpointPort(ep),
        ),
      );
    }
    final portLink = RegExp(
      r'(\w+)\s*port\s*(\d+)\s+connects?\s*to\s+(\w+)\s*([sfg])\s*(\d+(?:/\d+){0,2})',
    );
    for (final m in portLink.allMatches(normText)) {
      final ep = node(m.group(1)!);
      final other = node(m.group(3)!);
      if (ep == null || other == null) continue;
      if (!endpoints.any((p) => p.name.toLowerCase() == ep.toLowerCase())) {
        continue;
      }
      linksExplicit.add(
        NetLink(
          a: other,
          aIf: '${m.group(4)!}${m.group(5)!}',
          b: ep,
          bIf: 'port${m.group(2)!}',
        ),
      );
    }
    final links = <NetLink>[];
    final seen = <String>{};
    void addLink(NetLink link) {
      final key = link.a.compareTo(link.b) <= 0
          ? '${link.a}|${link.aIf}|${link.b}|${link.bIf}'
          : '${link.b}|${link.bIf}|${link.a}|${link.aIf}';
      if (seen.add(key)) links.add(link);
    }

    for (final l in linksExplicit) {
      addLink(l);
    }
    // A link whose interfaces are Serial ports IS a serial cable, whichever
    // sentence produced it, and exactly one end clocks.  The brief may name
    // that end ("R1 is the only DCE end"); when it does not, the first end
    // does, so the plan, the cable and the generated `clock rate` can never
    // disagree about which side is the DCE one.
    final namedDce = RegExp(
      r'\b([A-Za-z][A-Za-z0-9_]*)\s+is\s+the\s+(?:only\s+)?'
      r'(?:dce|clocking|clock source|clock|time source|provider)\b',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    for (var i = 0; i < links.length; i++) {
      final l = links[i];
      if (!l.isSerial) continue;
      final clocksB = namedDce != null &&
          namedDce.toLowerCase() == l.b.toLowerCase();
      links[i] = NetLink(
        a: l.a,
        aIf: l.aIf,
        b: l.b,
        bIf: l.bIf,
        cable: l.cable ?? 'serial',
        dce: l.dce ?? (clocksB ? 'b' : 'a'),
      );
    }

    bool linkedTo(String name) => links.any((l) => l.a == name || l.b == name);
    bool cabledToRouter(String name) => links.any(
      (l) =>
          (l.a == name && routers.any((r) => r.name == l.b)) ||
          (l.b == name && routers.any((r) => r.name == l.a)),
    );
    bool cabledTogether(String a, String b) => links.any(
      (l) => (l.a == a && l.b == b) || (l.a == b && l.b == a),
    );
    // The routers the BRIEF cabled to each other. Only these stop the layout
    // from adding a transit link: a router the layout itself chained earlier
    // must still get its next link, or a three-router plan loses one.
    final briefRouters = <String>{
      for (final r in routers)
        if (cabledToRouter(r.name)) r.name,
    };

    // VLAN extraction runs BEFORE the layout: a multi-VLAN plan is addressed
    // per VLAN (see below) and its switches are trunked, so the slot list has
    // to exist before either the cabling or the LAN pass runs.
    for (final m in RegExp(r'vlan\s*(\d+)').allMatches(lower)) {
      final v = int.parse(m.group(1)!);
      // "pcs in vlan 10 servers in vlan 10" names the same VLAN twice:
      // the list is a SET of slots, not a tally of mentions.
      if (!vlans.contains(v)) vlans.add(v);
    }
    // "VLAN 10 and 20", "vlans 10, 20, 30" - a list after one keyword.  A bare
    // SPACE separates the numbers too: the casual-English normalizer trims
    // punctuation off each word, so "VLANs 10, 20, 30 and 40" reaches this
    // parser as "vlans 10 20 30 and 40" and a comma-only list matched none of
    // it - the four VLANs became none, and a router-on-a-stick lab was planned
    // as one flat LAN with two PCs.
    for (final m in RegExp(
      r'\bvlans?\s*(\d{1,4}(?:\s*(?:,|and|&|\+|\/)\s*\d{1,4}|\s+\d{1,4})+)',
    ).allMatches(lower)) {
      for (final d in RegExp(r'\d{1,4}').allMatches(m.group(1)!)) {
        final v = int.parse(d.group(0)!);
        if (v > 0 && v <= 4094 && !vlans.contains(v)) vlans.add(v);
      }
    }
    // Router-on-a-stick is the default meaning of VLANs + a router-switch
    // link: one trunk, one dot1Q sub-interface per VLAN. The flag drives
    // the adapter, the addressing, the DHCP pools - and the layout below,
    // which trunks the switches together instead of giving each one its own
    // router uplink (two uplinks would mean the same VLAN subnet twice).
    final wantsInterVlan = vlans.isNotEmpty &&
        nodes.any((n) => n.type == 'router') &&
        nodes.any((n) => n.type == 'switch') &&
        !lower.contains('flat network');
    // Which VLAN the wording pinned each device kind to: "pcs in vlan 10",
    // "vlan 20 for the guest access points". Unpinned VLANs keep the
    // round-robin spread the planner has always used.
    final vlanRoles = _vlanRolesFrom(lower);

    // Deterministic layout for whatever the brief left out.  The rules exist
    // so that a brief written as a device list - "2 routers 2 switches 1
    // server and 4 pcs" - produces the topology that list describes: every
    // switch is uplinked to a router (the LAN side), never left floating,
    // and the end devices are spread across the switches instead of piling
    // onto the first one.
    //
    // It used to run only when the brief cabled NOTHING, so a single
    // explicit cable ("Connect R1 GigabitEthernet0/0 to SW1 FastEthernet0/1")
    // silently dropped the serial link, the PCs and the servers. Each rule
    // below now only adds what is missing, on the first free port.
    //
    // Routers chain through their transit links first, so the LAN
    // interfaces handed out below never collide with the WAN pair.
    for (var i = 0; i + 1 < routers.length; i++) {
      final left = routers[i].name;
      final right = routers[i + 1].name;
      if (cabledTogether(left, right)) continue;
      if (briefRouters.contains(left) || briefRouters.contains(right)) {
        continue;
      }
      final wanIf = wantsSerialWan ? 's0/0/0' : '${rIf}0/0';
      // A router in the middle of the chain needs a DIFFERENT port for each
      // WAN link. Handing every link s0/0/0 gave R2 two cables on one
      // interface - the validator reported it as an interface used by 2 links
      // with a duplicate IP, and a physical router has one port there.
      String freeIface(String router, String want) {
        final used = <String>{
          for (final l in links)
            for (final e in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)])
              if (e.key == router) e.value.toLowerCase(),
        };
        if (!used.contains(want.toLowerCase())) return want;
        for (var unit = 0; unit < 4; unit++) {
          for (var slot = 0; slot < 4; slot++) {
            final candidate = want.toLowerCase().startsWith('s')
                ? 's$slot/$unit'
                : '$rIf$slot/$unit';
            if (!used.contains(candidate)) return candidate;
          }
        }
        return want;
      }

      addLink(
        NetLink(
          a: left,
          aIf: freeIface(left, wanIf),
          b: right,
          bIf: freeIface(right, wanIf),
          cable: wantsSerialWan ? 'serial' : null,
          dce: wantsSerialWan ? (namedDce ?? 'a') : null,
        ),
      );
    }
    // One LAN uplink per switch, spread over the routers in order:
    // SW1 -> R1, SW2 -> R2, SW3 -> R1, ...  A two-site brief therefore
    // gets a LAN on each side of the WAN, and each router-switch link is
    // its own subnet further down.  The port is the first one the router is
    // not already using, so an uplink the brief cabled itself never has its
    // interface handed out twice.
    final routerUplinks = <String, int>{};
    String nextRouterIface(String router) {
      final used = <String>{
        for (final l in links)
          for (final e in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)])
            if (e.key == router) e.value.toLowerCase(),
      };
      var n = (routerUplinks[router] ?? 0) + 1;
      while (used.contains('${rIf}0/$n')) {
        n++;
      }
      routerUplinks[router] = n;
      return '${rIf}0/$n';
    }

    for (var i = 0; i < switches.length; i++) {
      final r = routers.isEmpty ? null : routers[i % routers.length];
      if (r == null) {
        // A plan with switches and no router at all - "two switches and
        // three pcs" - is one layer-2 network: SW1 feeds the others on its
        // last ports, so the access ports stay free for the devices.
        if (i == 0) continue;
        if (cabledTogether(switches.first.name, switches[i].name)) continue;
        addLink(
          NetLink(
            a: switches.first.name,
            aIf: 'f0/${25 - i}',
            b: switches[i].name,
            bIf: 'f0/24',
          ),
        );
        continue;
      }
      // A switch the brief already cabled keeps exactly the cable it was
      // given.
      if (linkedTo(switches[i].name)) continue;
      addLink(
        NetLink(
          a: r.name,
          aIf: nextRouterIface(r.name),
          b: switches[i].name,
          bIf: 'f0/1',
        ),
      );
    }
    // End devices: user devices split evenly across the switches (SW1
    // first, so the first LAN is the busier one), and the servers stay on
    // the first switch's LAN - a brief that names servers and switches but
    // not their location means "the server room", not "one per switch".
    // A device the brief already cabled keeps its cable, and the ports it
    // used are not handed out a second time.
    final userDevices = endpoints
        .where((n) => n.type != 'server' && !linkedTo(n.name))
        .toList();
    final serverDevices = endpoints
        .where((n) => n.type == 'server' && !linkedTo(n.name))
        .toList();
    final usedPorts = <String, Set<int>>{};
    for (final l in links) {
      for (final e in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)]) {
        final port = RegExp(r'^f0/(\d+)$').firstMatch(e.value.toLowerCase());
        if (port == null) continue;
        (usedPorts[e.key] ??= <int>{}).add(int.parse(port.group(1)!));
      }
    }
    void attach(String host, List<NetNode> devices, {String? prefix}) {
      for (final device in devices) {
        if (prefix == null) {
          final used = usedPorts.putIfAbsent(host, () => <int>{});
          var port = used.isEmpty ? 2 : used.reduce((a, b) => a > b ? a : b) + 1;
          while (used.contains(port)) {
            port++;
          }
          used.add(port);
          addLink(
            NetLink(
              a: host,
              aIf: 'f0/$port',
              b: device.name,
              bIf: endpointPort(device.name),
            ),
          );
        } else {
          final port = (usedPorts[host] = usedPorts[host] ?? <int>{}).length;
          addLink(
            NetLink(
              a: host,
              aIf: '$prefix$port',
              b: device.name,
              bIf: endpointPort(device.name),
            ),
          );
        }
      }
    }

    if (switches.isNotEmpty) {
      final per = userDevices.length ~/ switches.length;
      final extra = userDevices.length % switches.length;
      var taken = 0;
      for (var s = 0; s < switches.length; s++) {
        final count = per + (s < extra ? 1 : 0);
        attach(
          switches[s].name,
          userDevices.sublist(taken, taken + count),
        );
        taken += count;
      }
      attach(switches.first.name, serverDevices);
    } else if (routers.isNotEmpty) {
      // No switch to hang them off: the routers themselves are the LAN.
      //
      // One router interface takes ONE cable, so every endpoint gets its own
      // interface, spread over the routers in order. Handing them all to
      // g0/0 (what this did) put a cable per PC on a single port - a port a
      // physical router does not have - and left the addressing pass with no
      // LAN to put them on, so the plan shipped with every PC at 0.0.0.0 and
      // one blocking finding per device: "1 router and 3 pcs" could not be
      // built and no reply could clear it.
      final lan = <NetNode>[...userDevices, ...serverDevices];
      /// The LAN interfaces a router is modelled with, the same four
      /// [PlanRepairService] hands out.
      const routerLanPorts = 4;
      Set<String> usedRouterPorts(String router) => <String>{
        for (final l in links)
          for (final e in [MapEntry(l.a, l.aIf), MapEntry(l.b, l.bIf)])
            if (e.key == router) e.value.toLowerCase(),
      };
      String? freeLanPort(String router) {
        final used = usedRouterPorts(router);
        for (var port = 0; port < routerLanPorts; port++) {
          final candidate = '${rIf}0/$port';
          if (!used.contains(candidate)) return candidate;
        }
        return null;
      }

      // How many interfaces are actually free: the WAN chain has already
      // spent some of them, so counting four per router would promise a cable
      // the router has no port for - and the loop below then dropped the
      // devices it could not cable, one silent gap per device.
      var room = 0;
      for (final router in routers) {
        final used = usedRouterPorts(router.name);
        for (var port = 0; port < routerLanPorts; port++) {
          if (!used.contains('${rIf}0/$port')) room++;
        }
      }

      // An uplink to put a new switch on: the first router interface still
      // free. When there is none, the lab has more endpoints than its routers
      // can hold and no route to a switch either - the loop below cables what
      // it can and the validator reports the rest, which is the truth.
      String? uplinkHost;
      String? uplinkPort;
      for (final router in routers) {
        final candidate = freeLanPort(router.name);
        if (candidate == null) continue;
        uplinkHost = router.name;
        uplinkPort = candidate;
        break;
      }

      if (lan.length > room && uplinkHost != null && uplinkPort != null) {
        // More endpoints than the routers have interfaces: that lab needs the
        // switch a person would draw, so it gets one rather than an interface
        // that does not exist.
        final sw = NetNode(
          name: 'SW${switches.length + 1}',
          type: 'switch',
          model: bestSwitchModel(lower),
        );
        nodes.add(sw);
        switches.add(sw);
        addLink(
          NetLink(
            a: uplinkHost,
            aIf: uplinkPort,
            b: sw.name,
            bIf: 'f0/1',
          ),
        );
        attach(sw.name, lan);
      } else {
        for (final device in lan) {
          String? host;
          String? port;
          for (final router in routers) {
            final candidate = freeLanPort(router.name);
            if (candidate == null) continue;
            host = router.name;
            port = candidate;
            break;
          }
          if (host == null || port == null) break;
          addLink(
            NetLink(
              a: host,
              aIf: port,
              b: device.name,
              bIf: endpointPort(device.name),
            ),
          );
        }
      }
    }

    // EtherChannel takes two interfaces that face each other. The layout
    // above gives each switch its own router uplink, so a brief that asks
    // for a bundle between the switches without cabling one still needs the
    // cable to exist: the first two switches get a two-member bundle on
    // their last ports (f0/23, f0/24 - the classic uplink pair). Hoisted
    // here because the security block below reads the same flag, and the
    // channel-group lines only make sense once the links are real.
    final wantsEtherChannel = lower.contains('etherchannel') ||
        lower.contains('ether channel') ||
        lower.contains('port-channel') ||
        lower.contains('port channel') ||
        lower.contains('lacp') ||
        lower.contains('pagp') ||
        lower.contains('channel group');
    if (wantsEtherChannel && switches.length >= 2) {
      final bundleA = switches[0].name;
      final bundleB = switches[1].name;
      final cabled = links.any(
        (l) =>
            (l.a == bundleA && l.b == bundleB) ||
            (l.a == bundleB && l.b == bundleA),
      );
      if (!cabled) {
        for (var i = 0; i < 2; i++) {
          links.add(
            NetLink(
              a: bundleA,
              aIf: 'f0/${23 + i}',
              b: bundleB,
              bIf: 'f0/${23 + i}',
            ),
          );
        }
      }
    }

    // Firewall / cloud / modem chain onto the WAN side of the first router.
    // This runs whether or not the brief cabled anything explicitly: a
    // firewall belongs between the LAN and the internet, and a cloud that
    // hangs off nothing is not the device that was asked for.  A device the
    // brief already cabled is left exactly where the brief put it.
    final fwNodes = nodes.where((n) => n.type == 'firewall').toList();
    final edgeNodes = nodes
        .where((n) => n.type == 'cloud' || n.type == 'modem')
        .toList();
    if (routers.isNotEmpty &&
        fwNodes.isNotEmpty &&
        !linkedTo(fwNodes.first.name)) {
      links.add(
        NetLink(
          a: routers.first.name,
          aIf: '${rIf}0/2',
          b: fwNodes.first.name,
          bIf: 'g1/1',
        ),
      );
    }
    if (edgeNodes.isNotEmpty && !linkedTo(edgeNodes.first.name)) {
      final fwUp = fwNodes.isNotEmpty ? fwNodes.first.name : '';
      // A brief that names ONLY an edge device ("should i use ... cloud
      // services?" parses to a Cloud-PT) has nothing to hang it off: this
      // used to call switches.first on an empty list and throw, which the
      // chat swallowed into "no plan". A device the brief never cabled is
      // handled by the uncabled-device pass below, so the link is skipped
      // rather than invented.
      final upstream = fwUp.isNotEmpty
          ? fwUp
          : routers.isNotEmpty
          ? routers.first.name
          : switches.isNotEmpty
          ? switches.first.name
          : '';
      if (upstream.isNotEmpty) {
        final upstreamIf = fwUp.isNotEmpty
            ? 'g1/2'
            : routers.isNotEmpty
            ? '${rIf}0/2'
            : 'f0/24';
        final kind = deviceKindOf(edgeNodes.first.type);
        links.add(
          NetLink(
            a: upstream,
            aIf: upstreamIf,
            b: edgeNodes.first.name,
            bIf: (kind != null && kind.port.isNotEmpty) ? kind.port : 'port1',
          ),
        );
      }
    }

    /// The interface an address belongs on for a device the plan never
    /// cabled: its first cable, else the port its kind names.
    String ifaceOfNode(String name) {
      for (final l in links) {
        if (l.a == name) return l.aIf;
        if (l.b == name) return l.bIf;
      }
      return endpointPort(name);
    }

    // ADDRESSING: explicit CIDRs in the instruction are placed where they
    // belong. A stated /30 or /31 is a point-to-point link; anything wider is
    // a LAN. Handing a stated /24 to the router-to-router link is what made a
    // two-site brief unbuildable: the transit link claimed the HQ LAN block,
    // the LAN below it was then derived from that same /24, and the plan left
    // the gate with "Duplicate IP 192.168.10.1 on R1 and R1 g0/0" - a finding
    // the user could not clear by any phrasing, because every stated subnet
    // was consumed the same way.
    final stated = RegExp(
      r'(\d+\.\d+\.\d+\.\d+)\s*/\s*(\d+)',
    ).allMatches(text).map((m) => '${m.group(1)!}/${m.group(2)!}').toList();
    final statedTransit = <String>[];
    final statedLan = <String>[];
    for (final c in stated) {
      final prefix = int.tryParse(c.split('/').last) ?? 24;
      (prefix >= 30 ? statedTransit : statedLan).add(c);
    }
    // Every subnet the brief claims or an earlier LAN already holds, so a
    // derived block never lands on a taken one.
    final usedSubnets = <String>{...stated};
    final lanQueue = <String>[...statedLan];
    // A stated LAN subnet that the brief tied to a site ("192.168.20.0/24 at
    // the branch") belongs to that site's LANs. The sites are matched in the
    // order they were named, because the qualifier a brief uses here ("HQ") is
    // not always the label its site list uses ("Site A"). Anything left over
    // goes to the remaining LANs in order, exactly as before.
    final siteLanBlock = <int, String>{};
    final siteLanLast = <int, String>{};
    if (siteRouters.isNotEmpty) {
      final qualified = [
        for (final c in statedLan)
          if (brief_reader.subnetSitsAtASite(text, c)) c,
      ];
      for (var i = 0; i < qualified.length && i < siteRouters.length; i++) {
        siteLanBlock[i] = qualified[i];
        lanQueue.remove(qualified[i]);
      }
    }
    final lanBase = statedLan.isNotEmpty ? statedLan.first : base;

    String derivedLanSubnet() {
      final b = lanBase.split('/');
      final o = b[0].split('.');
      for (var guard = 0; guard < 254; guard++) {
        final k = lanPool++;
        var third = (int.tryParse(o[2]) ?? 0) + k;
        third = third.clamp(0, 254);
        final candidate = '${o[0]}.${o[1]}.$third.0/24';
        if (usedSubnets.add(candidate)) return candidate;
      }
      return '192.168.250.0/24';
    }

    /// The next free /24 in a block: "192.168.10.0/24" -> "192.168.11.0/24".
    String blockAfter(String block) {
      final o = block.split('/').first.split('.');
      var third = int.tryParse(o[2]) ?? 0;
      for (var i = 1; i < 254; i++) {
        third += 1;
        if (third > 254) break;
        final candidate = '${o[0]}.${o[1]}.$third.0/24';
        if (usedSubnets.add(candidate)) return candidate;
      }
      return derivedLanSubnet();
    }

    String nextSubnet(bool transit) {
      if (transit) {
        if (statedTransit.isNotEmpty) return statedTransit.removeAt(0);
        final k = transitPool++;
        return '10.0.0.${k * 4}/30';
      }
      if (lanQueue.isNotEmpty) return lanQueue.removeAt(0);
      return derivedLanSubnet();
    }

    // Which site each router belongs to: the nodes are created in the order
    // the brief listed the sites, so the per-site router counts name them
    // ("Site A ... 2 routers ... Site B ... 1 router" -> R1, R2 and R3).
    final routerSite = <String, int>{};
    if (siteRouters.fold<int>(0, (a, b) => a + b) == routers.length) {
      var i = 0;
      for (var s = 0; s < siteRouters.length; s++) {
        for (var k = 0; k < siteRouters[s]; k++, i++) {
          routerSite[routers[i].name] = s;
        }
      }
    }

    /// The subnet a LAN link gets: the block its site was given, the next /24
    /// of that block for a further LAN at the same site, then whatever the
    /// brief still has, then a derived one.
    String lanSubnetFor(String routerName) {
      final site = routerSite[routerName];
      if (site != null) {
        final last = siteLanLast[site];
        if (last != null) {
          final next = blockAfter(last);
          siteLanLast[site] = next;
          return next;
        }
        final block = siteLanBlock[site];
        if (block != null) {
          siteLanLast[site] = block;
          return block;
        }
      }
      return nextSubnet(false);
    }

    String hostIn(String cidr, int host) {
      final p = cidr.split('/');
      final prefixLen = int.tryParse(p[1]) ?? 24;
      final parts = p[0].split('.').map((s) => int.parse(s)).toList();
      final ip32 =
          (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
      final mask = prefixLen == 0 ? 0 : (0xFFFFFFFF << (32 - prefixLen));
      final net = ip32 & mask;
      final h = net + host;
      return '${(h >> 24) & 255}.${(h >> 16) & 255}.${(h >> 8) & 255}.${h & 255}/$prefixLen';
    }

    final addressing = <InterfaceAddr>[];
    bool bothRouters(NetLink l) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final bNode = nodes.firstWhere((n) => n.name == l.b);
      return aNode.type == 'router' && bNode.type == 'router';
    }

    bool routerToSwitch(NetLink l) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final bNode = nodes.firstWhere((n) => n.name == l.b);
      return (aNode.type == 'router' && bNode.type == 'switch') ||
          (aNode.type == 'switch' && bNode.type == 'router');
    }

    // Transit (router-router) subnets are claimed FIRST so the explicit
    // CIDR order (transit /30s first, then LAN /24s) lands correctly.
    for (final l in links.where(bothRouters)) {
      final sub = nextSubnet(true);
      addressing.add(
        InterfaceAddr(node: l.a, iface: l.aIf, ipCidr: hostIn(sub, 1)),
      );
      addressing.add(
        InterfaceAddr(node: l.b, iface: l.bIf, ipCidr: hostIn(sub, 2)),
      );
    }
    // LAN links: the ROUTER side gets .1 (the PC default gateway).
    // Switches stay layer-2, but every Desktop > IP Configuration device
    // hanging off that switch (pc, server, laptop, printer) gets .10,
    // .11, ... of the same subnet - the sidecar types these into the
    // device's Desktop > IP Configuration. The kind check must match
    // PacketTracerAdapter.autopilotPlan's config_pcs filter
    // (deviceKindOf(type)?.ipConfig), otherwise the plan carries a device
    // with ip 0.0.0.0 and the executor leaves its IPv4 row empty while
    // still typing mask/gateway.
    //
    // Multi-VLAN (router-on-a-stick) plans are addressed per VLAN instead
    // of per link: the router's physical uplink stays unaddressed (it is a
    // trunk), each VLAN gets its own subnet via a sub-interface
    // `<uplink>.<vlan>`, and the endpoints are spread round-robin over the
    // VLANs so every VLAN is populated and testable. VLAN N lives in
    // 192.168.<N>.0/24 (documentation-space, human-explainable).
    for (final l in links.where(routerToSwitch)) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final routerName = aNode.type == 'router' ? l.a : l.b;
      final routerIface = aNode.type == 'router' ? l.aIf : l.bIf;
      final switchName = aNode.type == 'router' ? l.b : l.a;
      final endpointsOnSwitch = <(String, String)>[];
      for (final pl in links) {
        final aN = nodes.firstWhere((n) => n.name == pl.a);
        final bN = nodes.firstWhere((n) => n.name == pl.b);
        final aIsEndpoint = deviceKindOf(aN.type)?.ipConfig ?? false;
        final bIsEndpoint = deviceKindOf(bN.type)?.ipConfig ?? false;
        if (!aIsEndpoint && !bIsEndpoint) continue;
        final epName = aIsEndpoint ? pl.a : pl.b;
        final epIf = aIsEndpoint ? pl.aIf : pl.bIf;
        final otherName = aIsEndpoint ? pl.b : pl.a;
        if (otherName != switchName) continue;
        endpointsOnSwitch.add((epName, epIf));
      }
      if (wantsInterVlan) {
        // Sub-interface addressing: the plan's own InterfaceAddr rows are
        // the single source of truth - the adapter renders the dot1Q block
        // from them and endpointIpConfig finds each PC's gateway here.
        // Which VLAN each endpoint joins: a kind the wording pinned lands
        // in that VLAN's subnet; every other endpoint keeps the round-robin
        // spread (e % vlans.length) so no VLAN is left empty.
        final endpointVlan = List<int>.filled(endpointsOnSwitch.length, -1);
        for (var e = 0; e < endpointsOnSwitch.length; e++) {
          final type = nodes
              .firstWhere((n) => n.name == endpointsOnSwitch[e].$1)
              .type;
          final pinned = vlanRoles[type];
          endpointVlan[e] =
              pinned != null && vlans.contains(pinned)
                  ? pinned
                  : vlans[e % vlans.length];
        }
        for (var i = 0; i < vlans.length; i++) {
          final v = vlans[i];
          final subnet = _vlanSubnet(v);
          addressing.add(
            InterfaceAddr(
              node: routerName,
              iface: '$routerIface.$v',
              ipCidr: hostIn(subnet, 1),
            ),
          );
          final inThisVlan = <int>[
            for (var e = 0; e < endpointsOnSwitch.length; e++)
              if (endpointVlan[e] == v) e,
          ];
          for (var hostIdx = 0; hostIdx < inThisVlan.length; hostIdx++) {
            final (epName, epIf) = endpointsOnSwitch[inThisVlan[hostIdx]];
            addressing.add(
              InterfaceAddr(
                node: epName,
                iface: epIf,
                ipCidr: hostIn(subnet, 10 + hostIdx),
              ),
            );
          }
        }
      } else {
        final sub = lanSubnetFor(routerName);
        addressing.add(
          InterfaceAddr(
            node: routerName,
            iface: routerIface,
            ipCidr: hostIn(sub, 1),
          ),
        );
        var hostIdx = 0;
        for (final (epName, epIf) in endpointsOnSwitch) {
          addressing.add(
            InterfaceAddr(
              node: epName,
              iface: epIf,
              ipCidr: hostIn(sub, 10 + hostIdx),
            ),
          );
          hostIdx++;
        }
      }
    }    // A router cabled STRAIGHT to an endpoint - a lab with no switch at all -
    // is a LAN of its own: the router interface takes .1 (the endpoint's
    // default gateway) and the endpoint .10 of that interface's subnet. This
    // is the case the switch-less layout above creates, and without it those
    // endpoints had no address at all, so the build was refused for a reading
    // the plan never wrote down.
    for (final l in links) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final bNode = nodes.firstWhere((n) => n.name == l.b);
      final aIsEndpoint = deviceKindOf(aNode.type)?.ipConfig ?? false;
      final bIsEndpoint = deviceKindOf(bNode.type)?.ipConfig ?? false;
      final routerIsA = aNode.type == 'router' && bIsEndpoint;
      final routerIsB = bNode.type == 'router' && aIsEndpoint;
      if (!routerIsA && !routerIsB) continue;
      final routerName = routerIsA ? l.a : l.b;
      final sub = lanSubnetFor(routerName);
      addressing.add(
        InterfaceAddr(
          node: routerName,
          iface: routerIsA ? l.aIf : l.bIf,
          ipCidr: hostIn(sub, 1),
        ),
      );
      addressing.add(
        InterfaceAddr(
          node: routerIsA ? l.b : l.a,
          iface: routerIsA ? l.bIf : l.aIf,
          ipCidr: hostIn(sub, 10),
        ),
      );
    }

    // A router hanging off a firewall is a routed transit, not a LAN: both
    // ends need addresses or the ASA has no inside interface and the router
    // has no path out.  Addressed from the transit pool AFTER the links
    // above, so explicit CIDRs still land on router-router/LAN links first.
    for (final l in links) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final bNode = nodes.firstWhere((n) => n.name == l.b);
      final routerIsA = aNode.type == 'router' && bNode.type == 'firewall';
      final routerIsB = aNode.type == 'firewall' && bNode.type == 'router';
      if (!routerIsA && !routerIsB) continue;
      final k = transitPool++;
      final sub = '10.0.0.${k * 4}/30';
      addressing.add(
        InterfaceAddr(
          node: routerIsA ? l.a : l.b,
          iface: routerIsA ? l.aIf : l.bIf,
          ipCidr: hostIn(sub, 1),
        ),
      );
      addressing.add(
        InterfaceAddr(
          node: routerIsA ? l.b : l.a,
          iface: routerIsA ? l.bIf : l.aIf,
          ipCidr: hostIn(sub, 2),
        ),
      );
    }

    // A plan with no router at all is still a network: one layer-2 segment
    // (the switches are cabled to each other), so every device on it is
    // addressed in the base subnet.  There is no gateway to point at - the
    // devices reach each other without one - and none is invented.
    if (routers.isEmpty) {
      var hostIdx = 0;
      for (final ep in endpoints) {
        if (!(deviceKindOf(ep.type)?.ipConfig ?? false)) continue;
        addressing.add(
          InterfaceAddr(
            node: ep.name,
            iface: endpointPort(ep.name),
            ipCidr: hostIn(base, 10 + hostIdx),
          ),
        );
        hostIdx++;
      }
    }

    // EXPLICIT PER-DEVICE ADDRESSES win over the derived ones: "R1 is
    // 10.255.0.1 and R2 is 10.255.0.2", "PC1-PC5 addresses .11-.15 on the R1
    // LAN", "DHCP1-MAIL1 addresses 192.168.10.101-192.168.10.106 in the order
    // listed".  The prefix always comes from a subnet the plan really has -
    // the LAN the named router serves for a shorthand host part - so ".11"
    // becomes 192.168.10.11/24 rather than a /32 of nothing.
    final cidrHits = RegExp(
      r'(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})',
    ).allMatches(text).toList();
    String prefixForIp(String ip, int at) {
      for (final a in addressing) {
        final parts = a.ipCidr.split('/');
        if (parts.length < 2) continue;
        if (sameNetwork(ip, parts[0], int.tryParse(parts[1]) ?? 24)) {
          return parts[1];
        }
      }
      for (var i = cidrHits.length - 1; i >= 0; i--) {
        if (cidrHits[i].start > at) continue;
        return cidrHits[i].group(2)!;
      }
      return '24';
    }

    /// The address a device has on a LAN (never its transit one), so
    /// "the R1 LAN" and "on the R2 LAN" resolve to real subnets.  The
    /// argument may be the label itself or a clause that contains one.
    String? lanAddressOf(String label) {
      final inClause = RegExp(
        r'\b([a-z]+\d{1,3})\b',
        caseSensitive: false,
      ).firstMatch(label)?.group(1);
      final router = node(inClause ?? label);
      if (router == null) return null;
      for (final a in addressing) {
        if (a.node != router) continue;
        if (a.iface.toLowerCase().startsWith('s')) continue;
        return a.ipCidr;
      }
      return null;
    }

    String? completeHost(String short, String? lanCidr) {
      if (!short.startsWith('.')) return short;
      if (lanCidr == null) return null;
      final head = lanCidr.split('/').first;
      final octets = head.split('.');
      if (octets.length != 4) return null;
      return '${octets[0]}.${octets[1]}.${octets[2]}$short';
    }

    /// The run of hosts a shorthand or absolute range describes:
    /// ".11-.15" is five values, "192.168.10.101-192.168.10.106" is six.
    /// A shorthand value has no prefix of its own, so the last octet is the
    /// only thing that can step.
    List<String> hostRange(String first, String last) {
      final absolute = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');
      final a = int.tryParse(first.split('.').last);
      final b = int.tryParse(last.split('.').last);
      if (a == null || b == null || b < a || b - a > 256) return [last];
      final headA = absolute.hasMatch(first)
          ? first.split('.').take(3).join('.')
          : '';
      final headB = absolute.hasMatch(last)
          ? last.split('.').take(3).join('.')
          : '';
      if (headA.isNotEmpty && headB.isNotEmpty && headA != headB) return [last];
      return [
        for (var n = a; n <= b; n++) headA.isEmpty ? '.$n' : '$headA.$n',
      ];
    }

    /// The devices "PC1-PC5" (a numbered run) or "DHCP1-MAIL1" (the servers
    /// in the order the brief listed them) covers.
    List<String> assignmentTargets(String fromLabel, String toLabel) {
      final from = node(fromLabel);
      final to = node(toLabel);
      if (from == null || to == null) return const [];
      final a = labelRun(from);
      final b = labelRun(to);
      if (a != null && b != null && a.$1 == b.$1 && b.$2 > a.$2) {
        return [
          for (var n = a.$2; n <= b.$2; n++)
            if (node('${a.$1}$n') != null) node('${a.$1}$n')!,
        ];
      }
      final first = nodes.indexWhere((n) => n.name == from);
      final last = nodes.indexWhere((n) => n.name == to);
      if (first < 0 || last < first) return [from];
      return [for (var i = first; i <= last; i++) nodes[i].name];
    }

    final explicitAddrs = <String, String>{};
    void setAddress(String label, String ip, int at, {String? prefix}) {
      final name = node(label) ?? label;
      if (!nodes.any((n) => n.name == name)) return;
      explicitAddrs[name] = '$ip/${prefix ?? prefixForIp(ip, at)}';
    }

    final rangeAssign = RegExp(
      r'([a-z]+\d{1,3})\s*(?:-|to|through|thru)\s*([a-z]+\d{1,3})\b'
      r'[^.]{0,40}?\b(?:addresses?|ips?)\b\s*[:=]?\s*'
      r'(\.\d{1,3}|\d{1,3}(?:\.\d{1,3}){3})\s*(?:-|to|through|thru)\s*'
      r'(\.\d{1,3}|\d{1,3}(?:\.\d{1,3}){3})'
      // The tail is only the LAN the range sits on, so it stops at the next
      // clause: a brief that writes two ranges in one sentence ("... on the
      // R2 LAN Assign DHCP1-MAIL1 addresses ...") must not have the second
      // range swallowed as part of the first one's hint.
      r'([^.;]*?(?=\band\s+[a-z]+\d|[a-z]+\d{1,3}\s*-|addresses|[.;]|$))',
      caseSensitive: false,
    );
    for (final m in rangeAssign.allMatches(text)) {
      final targets = assignmentTargets(m.group(1)!, m.group(2)!);
      if (targets.isEmpty) continue;
      final hint = m.group(5) ?? '';
      final hintCidr = RegExp(
        r'(\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2})',
      ).firstMatch(hint)?.group(1);
      final lanCidr = hintCidr ?? lanAddressOf(hint);
      final hosts = hostRange(m.group(3)!, m.group(4)!);
      for (var i = 0; i < targets.length; i++) {
        final host = hosts[i < hosts.length ? i : hosts.length - 1];
        final ip = completeHost(host, lanCidr);
        if (ip == null) continue;
        setAddress(targets[i], ip, m.start, prefix: hintCidr?.split('/')[1]);
      }
    }
    final nameIsIp = RegExp(
      r'\b([a-z][a-z0-9_]*\d{1,3})\s+(?:is|are|has|have|get|gets|use|uses|'
      r'will be|becomes|reserves?)\s+(?:the\s+(?:ip|address)\s+)?'
      r'(\d{1,3}(?:\.\d{1,3}){3})',
      caseSensitive: false,
    );
    for (final m in nameIsIp.allMatches(text)) {
      if (node(m.group(1)!) == null) continue;
      setAddress(m.group(1)!, m.group(2)!, m.start);
    }
    for (final entry in explicitAddrs.entries) {
      final ip = entry.value.split('/').first;
      final rows = <MapEntry<int, InterfaceAddr>>[
        for (var i = 0; i < addressing.length; i++)
          if (addressing[i].node == entry.key) MapEntry(i, addressing[i]),
      ];
      if (rows.isEmpty) {
        addressing.add(
          InterfaceAddr(
            node: entry.key,
            iface: ifaceOfNode(entry.key),
            ipCidr: entry.value,
          ),
        );
        continue;
      }
      // A router has a row per interface: put the address on the interface
      // whose own subnet it belongs to, so a WAN address never lands on the
      // LAN interface (and the other way round).
      var row = rows.first;
      for (final candidate in rows) {
        final parts = candidate.value.ipCidr.split('/');
        if (parts.length > 1 &&
            sameNetwork(ip, parts[0], int.tryParse(parts[1]) ?? 24)) {
          row = candidate;
          break;
        }
      }
      addressing[row.key] = InterfaceAddr(
        node: row.value.node,
        iface: row.value.iface,
        ipCidr: entry.value,
        ip6Cidr: row.value.ip6Cidr,
      );
    }

    final chosenRouting = resolveRouting(lower);
    if (chosenRouting != null) routing = chosenRouting;

    // SERVER ROLES for the Services tab: "SRV1 is the DHCP and DNS
    // server", "SRV1: dhcp, dns, http". Role words in a sentence with
    // no server name attach to the first server.
    const roleWords = {
      'dhcp': 'dhcp',
      'dhcpv6': 'dhcpv6',
      'dns': 'dns',
      'http': 'http',
      'https': 'http',
      'web': 'http',
      'aaa': 'aaa',
      'radius': 'aaa',
      'email': 'email',
      'mail server': 'email',
      'ftp': 'ftp',
      'ntp': 'ntp',
      'tftp': 'tftp',
      'syslog': 'syslog',
      'iot': 'iot',
      'prp': 'prp',
      'snmp': 'snmp',
      'vm management': 'vm',
      'vm': 'vm',
      'cme': 'cme',
      'callmanager': 'cme',
      'call manager': 'cme',
      'voice': 'cme',
      'tacacs': 'aaa',
      'tacacs+': 'aaa',
    };
    final roles = <String, List<String>>{};
    final serviceRules = <String, Map<String, dynamic>>{};
    Map<String, dynamic> rulesFor(String name) =>
        serviceRules.putIfAbsent(name, () => <String, dynamic>{});

    /// Every device's address, for the requests that name a node that way:
    /// "DNS server 192.168.10.102" is a statement about DNS1.
    final addressOwner = <String, String>{
      for (final a in addressing)
        if (a.ipCidr.split('/').first != '0.0.0.0')
          a.ipCidr.split('/').first: a.node,
    };

    /// The server a request is about: the last one named before it.  A brief
    /// that lists its servers by name writes one service sentence per
    /// server ("DNS1: web.lab.test -> 192.168.10.103"), and ownership has to
    /// follow the sentence - matching only the matched words sent every
    /// record and every account to whichever server came first.
    String? ownerBefore(int at) {
      var end = -1;
      String? name;
      for (final s in servers) {
        for (final m in RegExp(
          '\\b${RegExp.escape(s.name)}\\b',
          caseSensitive: false,
        ).allMatches(text.substring(0, at))) {
          if (m.end > end) {
            end = m.end;
            name = s.name;
          }
        }
      }
      return name;
    }

    String ruleOwner(String fragment, [int? at]) {
      final before = at == null ? null : ownerBefore(at);
      if (before != null) return before;
      final named = servers
          .where((s) => fragment.contains(s.name.toLowerCase()))
          .map((s) => s.name)
          .toList();
      return named.isNotEmpty ? named.first : servers.first.name;
    }

    /// The server a LOGIN belongs to.
    ///
    /// A credential names no device, so [ruleOwner] would hand it to whichever
    /// server came first - and once roles are spread across servers that is
    /// the wrong one: "for the AAA server clinet name admin password 123"
    /// would configure the account on the DHCP server and leave AAA with an
    /// empty Services tab.  The service word nearest in front of the
    /// credential decides, exactly like a record or a pool does.
    ///
    /// [whole] is the text the credential was found in and [at] its offset,
    /// because the deciding words sit OUTSIDE the matched phrase.
    String credentialOwner(String whole, int at) {
      final before = ownerBefore(at);
      if (before != null) return before;
      // Only the words next to the credential count as naming it, so a server
      // named somewhere else in the brief does not steal the account.
      final from = at - 60 < 0 ? 0 : at - 60;
      final to = at + 60 > whole.length ? whole.length : at + 60;
      final window = whole.substring(from, to);
      final named = servers
          .where((s) => window.contains(s.name.toLowerCase()))
          .map((s) => s.name)
          .toList();
      if (named.isNotEmpty) return named.first;
      // The service word NEAREST in front of the credential is the one it
      // configures, so "…for the AAA server … password 123" is AAA's account
      // even when DHCP was mentioned earlier in the same sentence.
      final lead = whole.substring(0, at < 0 ? 0 : at);
      var bestAt = -1;
      String? wanted;
      for (final entry in roleWords.entries) {
        final atWord = lead.lastIndexOf(entry.key);
        if (atWord > bestAt) {
          bestAt = atWord;
          wanted = entry.value;
        }
      }
      if (wanted != null) {
        final owner = servers
            .map((s) => s.name)
            .where((name) => roles[name]?.contains(wanted) ?? false)
            .firstOrNull;
        if (owner != null) return owner;
      }
      return servers.first.name;
    }

    /// A service a named node already owns, so a bare mention of the word
    /// elsewhere cannot hand it to whichever server happens to be first.
    ///
    /// Two ways a node claims one: by its own NAME ("DNS1" in the device
    /// list is the DNS server) and by its ADDRESS ("DNS server
    /// 192.168.10.102" is a statement about DNS1).  The first also stops a
    /// role word being read out of a device label: in "...six Server-PT
    /// devices: DHCP1, DNS1, WEB1, AAA1, FTP1 and MAIL1" the words DHCP, DNS,
    /// WEB, AAA and FTP are part of the names, not six requests - which is
    /// how every server ended up with every role and DHCP1 also ran DNS.
    final roleByName = <String, String>{
      'DHCP': 'dhcp',
      'DHCPV6': 'dhcpv6',
      'DNS': 'dns',
      'WEB': 'http',
      'HTTP': 'http',
      'AAA': 'aaa',
      'TACACS': 'aaa',
      'RADIUS': 'aaa',
      'FTP': 'ftp',
      'MAIL': 'email',
      'EMAIL': 'email',
      'SMTP': 'email',
      'NTP': 'ntp',
      'TFTP': 'tftp',
      'SNMP': 'snmp',
      'SYSLOG': 'syslog',
    };
    final claimedElsewhere = <String, String>{};
    for (final s in servers) {
      final role = roleByName[
        s.name.replaceAll(RegExp(r'\d+$'), '').toUpperCase()
      ];
      if (role != null) claimedElsewhere[role] ??= s.name;
    }
    for (final m in RegExp(
      r'\b(dhcp|dns|https?|web|aaa|tacacs\+?|radius|ftp|email|ntp|tftp|'
      r'syslog)\b[^.;]{0,24}?(\d{1,3}(?:\.\d{1,3}){3})',
      caseSensitive: false,
    ).allMatches(text)) {
      final owner = addressOwner[m.group(2)!];
      if (owner == null) continue;
      if (!servers.any((s) => s.name == owner)) continue;
      for (final entry in roleWords.entries) {
        if (!m.group(0)!.toLowerCase().contains(entry.key)) continue;
        claimedElsewhere[entry.value] = owner;
        final owned = roles.putIfAbsent(owner, () => []);
        if (!owned.contains(entry.value)) owned.add(entry.value);
      }
    }

    if (servers.isNotEmpty) {
      final fragments = text.toLowerCase().split(RegExp(r'[\n.]'));
      for (final frag in fragments) {
        // Collect the roles in the order they were *said*, not in map order:
        // "1 server is dhcp and the other is AAA" must give dhcp the first
        // server and AAA the second.
        final hits = <(int, String, String)>[]; // position, word, role
        roleWords.forEach((word, role) {
          final at = frag.indexOf(word);
          if (at >= 0) hits.add((at, word, role));
        });
        if (hits.isEmpty) continue;
        hits.sort((a, b) => a.$1.compareTo(b.$1));
        final nameAt = <int, String>{}; // position -> server
        for (final s in servers) {
          for (final m in RegExp(
            '\\b${RegExp.escape(s.name)}\\b',
            caseSensitive: false,
          ).allMatches(frag)) {
            nameAt[m.start] = s.name;
          }
        }
        if (nameAt.isEmpty) {
          // No server was named, so the wording decides. "the other",
          // "one ... the other", "server 2" all mean the roles are spread
          // across servers. Without this, every role landed on the first
          // server and the rest were left with an empty Services tab - the
          // reported bug: "both servers has the AAA service tab empty".
          // Does a number sit immediately in front of one of these role
          // words? "1 dhcp server" is one server running DHCP; "a dhcp server"
          // names a role without saying how many boxes there are.
          final numbered = hits.any(
            (hit) => RegExp(
              r'(?:\b\d{1,2}|\bone|\btwo|\bthree|\bfour|\bfive|\bsix)\s*$',
              caseSensitive: false,
            ).hasMatch(frag.substring(0, hit.$1)),
          );
          final found = <String>[];
          for (final hit in hits) {
            if (!found.contains(hit.$3)) found.add(hit.$3);
          }
          final distributes = RegExp(
            r'\bthe other\b|\banother\b|\bone\b[^.]{0,30}\bother\b|'
            r'\bserver\s*\d\b|\beach\b',
            caseSensitive: false,
          ).hasMatch(frag) ||
              // A number in front of a role IS the number of servers that run
              // it, so "3 servers (1 dhcp server and 1 AAA server)" asks for
              // exactly what "the other is AAA" asks for - it just counts it.
              // Without this every role landed on the first server and the
              // second one stayed with an empty Services tab.
              numbered;
          final free = servers
              .map((s) => s.name)
              .where((name) => !(roles[name]?.isNotEmpty ?? false))
              .toList();
          if (distributes && found.length > 1 &&
              free.length >= found.length) {
            // One role per server, in the order they were said.
            for (var i = 0; i < found.length; i++) {
              final target = free[i];
              roles.putIfAbsent(target, () => []);
              if (!roles[target]!.contains(found[i])) {
                roles[target]!.add(found[i]);
              }
            }
            continue;
          }
          for (final role in found) {
            // A role a node already owns by name or address keeps that node
            // even when the sentence names nobody: "…and the DNS address on
            // every endpoint" is not a request for the DHCP server to serve
            // DNS.
            //
            // A NUMBERED role that reached this branch took the next free
            // server instead of the first. A role list is comma-separated, so
            // "3 servers (1 DHCP server, 1 AAA server, 1 DNS+HTTP server)"
            // arrives as three fragments of one role each: there was nothing
            // to spread INSIDE a fragment, and all three fell through to
            // servers.first - which put DHCP and AAA on the same box and left
            // the brief's "1 AAA server" unfulfilled. The number in front of
            // the role is the statement that these are DIFFERENT servers, so
            // each numbered fragment takes its own.
            final claimed = claimedElsewhere[role];
            String target;
            if (claimed != null) {
              target = claimed;
            } else if (numbered && free.isNotEmpty) {
              // A NUMBERED role that reached this branch takes the next free
              // server instead of the first. A role list is comma-separated,
              // so "3 servers (1 DHCP server, 1 AAA server, 1 DNS+HTTP
              // server)" arrives as three fragments of one role each: there
              // was nothing to spread INSIDE a fragment, and all three fell
              // through to servers.first - which put DHCP and AAA on the same
              // box and left the brief's "1 AAA server" unfulfilled. The
              // number is the statement that these are DIFFERENT servers.
              target = free.removeAt(0);
            } else {
              // A role that some server ALREADY runs stays there. A brief
              // names the role once to spread it and again to configure it -
              // "1 AAA server ... and set up AAA with the client name admin" -
              // and the second mention, in a fragment of its own, used to land
              // on servers.first and put AAA on the DHCP box as well.
              final holder = servers
                  .map((s) => s.name)
                  .where((name) => roles[name]?.contains(role) ?? false)
                  .firstOrNull;
              target = holder ?? servers.first.name;
            }
            final owned = roles.putIfAbsent(target, () => []);
            if (!owned.contains(role)) owned.add(role);
          }
          continue;        }
        // A named server owns the role words nearest to its own name, which
        // is what makes one service sentence per server work ("DNS1: a
        // record; WEB1: enable HTTP and HTTPS") even when the brief runs the
        // sentences together without a sentence break.
        final names = nameAt.keys.toList()..sort();
        for (final hit in hits) {
          // A role word that is part of a device label is not a request:
          // "DHCP1" in the device list does not ask six servers for DHCP.
          final insideLabel = names.any(
            (n) => n <= hit.$1 && n + nameAt[n]!.length > hit.$1,
          );
          if (insideLabel) continue;
          // The server nearest in front of the word is the one it is about.
          var closest = '';
          for (final n in names) {
            if (n <= hit.$1) closest = nameAt[n]!;
          }
          // A role another node owns by name or by address does not also
          // belong to the server nearest this word.
          final owner = claimedElsewhere[hit.$3];
          if (owner != null && closest.isNotEmpty && owner != closest) {
            continue;
          }
          final target = owner ?? (closest.isNotEmpty
              ? closest
              : nameAt[names.first]!);
          final owned = roles.putIfAbsent(target, () => []);
          if (!owned.contains(hit.$3)) owned.add(hit.$3);
        }
      }

      // A server whose NAME says what it runs owns that service even when
      // the brief never repeats it: a plan that lists "DNS1, WEB1" and says
      // nothing else still has to configure DNS on DNS1 and HTTP on WEB1,
      // or those devices are placed with an empty Services tab.
      for (final s in servers) {
        final role = roleByName[
          s.name.replaceAll(RegExp(r'\d+$'), '').toUpperCase()
        ];
        if (role == null) continue;
        final owned = roles.putIfAbsent(s.name, () => []);
        if (!owned.contains(role)) owned.add(role);
      }


      // Common service rules are intentionally small and deterministic. They
      // are only extracted when the request supplies the value; the adapter
      // still derives safe defaults for a service that only says "enable".
      final recordsByServer = <String, List<Map<String, String>>>{};
      final recordPatterns = [
        RegExp(
          r'(?:dns\s+)?(?:a\s+)?records?\s*[:=-]?\s*(?:for\s+)?([a-z0-9][a-z0-9_.-]*)\s*(?:->|=>|to|=|:)\s*(\d{1,3}(?:\.\d{1,3}){3})',
          caseSensitive: false,
        ),
        RegExp(
          r'([a-z0-9][a-z0-9_.-]*)\s*(?:->|=>|=)\s*(\d{1,3}(?:\.\d{1,3}){3})',
          caseSensitive: false,
        ),
      ];
      for (final pattern in recordPatterns) {
        for (final match in pattern.allMatches(text)) {
          final owner = ruleOwner(match.group(0)!.toLowerCase(), match.start);
          final name = match.group(1)!;
          final address = match.group(2)!;
          final rows = recordsByServer.putIfAbsent(owner, () => []);
          if (!rows.any((row) => row['name'] == name)) {
            rows.add({'name': name, 'address': address});
          }
        }
      }
      for (final entry in recordsByServer.entries) {
        rulesFor(entry.key)['dns'] = {'records': entry.value};
      }

      // "WEB1: enable HTTP and HTTPS" - PT's HTTP panel is the only place an
      // HTTPS requirement can live, so the word becomes that panel's flag
      // instead of being dropped as an unknown parameter.
      if (RegExp(r'\bhttps\b', caseSensitive: false).hasMatch(text)) {
        for (final name in servers
            .where((s) => roles[s.name]?.contains('http') ?? false)
            .map((s) => s.name)) {
          rulesFor(name)['http'] = {
            ...((rulesFor(name)['http'] as Map?) ?? const {}),
            'https': true,
          };
        }
      }

      // "Configure DHCP1 with named pools for both LANs, using each LAN's .1
      // gateway and DNS server 192.168.10.102. Start the R1 LAN pool at
      // 192.168.10.150 and the R2 LAN pool at 192.168.20.100, with 40 leases
      // each."  The builder reads pools out of serviceRules and nothing
      // else, so a pool that is only implied never reaches the DHCP tab. The
      // gateway and the mask come from the LAN the named router really
      // serves, not from a guess.
      final dhcpOwners = servers
          .where((s) => roles[s.name]?.contains('dhcp') ?? false)
          .map((s) => s.name)
          .toList();
      if (dhcpOwners.isNotEmpty) {
        final statedDns = RegExp(
          r'\bdns\s+(?:server\s+)?(\d{1,3}(?:\.\d{1,3}){3})',
          caseSensitive: false,
        ).firstMatch(text)?.group(1);
        String? dnsNode;
        for (final s in servers) {
          if (!(roles[s.name]?.contains('dns') ?? false)) continue;
          for (final entry in addressOwner.entries) {
            if (entry.value != s.name) continue;
            dnsNode = entry.key;
            break;
          }
          if (dnsNode != null) break;
        }
        final leases = RegExp(
          r'\b(\d{1,4})\s+(?:leases?|clients?)\b',
          caseSensitive: false,
        ).firstMatch(text)?.group(1);
        final pools = <Map<String, String>>[];
        for (final m in RegExp(
          r'\b([a-z]+\d{1,3})\s+(?:lan|network|subnet)\s+pool\s+'
          r'(?:starting\s+at|start(?:ing)?\s+at|at|from)\s+'
          r'(\d{1,3}(?:\.\d{1,3}){3})',
          caseSensitive: false,
        ).allMatches(text)) {
          final lan = lanAddressOf(m.group(1)!);
          if (lan == null) continue;
          final parts = lan.split('/');
          pools.add({
            'poolName': '${m.group(1)!.toUpperCase()}_LAN',
            'gateway': parts.first,
            'dnsServer': statedDns ?? dnsNode ?? parts.first,
            'startIp': m.group(2)!,
            'mask': prefixToMask(parts.length > 1 ? parts[1] : '24'),
            'maxUsers': leases ?? '50',
          });
        }
        if (pools.isNotEmpty) {
          final owner = dhcpOwners.first;
          rulesFor(owner)['dhcp'] = {
            ...((rulesFor(owner)['dhcp'] as Map?) ?? const {}),
            'pools': pools,
          };
        }
      }

      final credentialsByServer = <String, List<Map<String, String>>>{};
      for (final match in readCredentials(text)) {
        final owner = credentialOwner(text.toLowerCase(), match.at);
        final rows = credentialsByServer.putIfAbsent(owner, () => []);
        if (!rows.any((row) => row['username'] == match.username)) {
          rows.add({'username': match.username, 'password': match.password});
        }
      }
      final domainMatch = RegExp(
        r'(?:email|mail|ftp|aaa)?\s*domain\s+([a-z0-9][a-z0-9.-]+)',
        caseSensitive: false,
      ).firstMatch(text);
      for (final entry in credentialsByServer.entries) {
        final rules = rulesFor(entry.key);
        final users = entry.value;
        for (final role in const ['aaa', 'email', 'ftp']) {
          if (roles[entry.key]?.contains(role) ?? false) {
            rules[role] = {
              ...((rules[role] as Map?) ?? const {}),
              'users': users,
              if (domainMatch != null && role == 'email')
                'domain': domainMatch.group(1),
            };
          }
        }
      }
      // attach roles to the server nodes (NetNode is immutable)
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        if (n.type == 'server' && (roles[n.name]?.isNotEmpty ?? false)) {
          nodes[i] = NetNode(
            name: n.name,
            type: n.type,
            model: n.model,
            mgmtIp: n.mgmtIp,
            services: roles[n.name]!,
            serviceRules: serviceRules[n.name] ?? const {},
          );
        }
      }
    }

    // WIRELESS RULES: "an AP with SSID CORP and WEP key 1234567890" -
    // attach the SSID/WEP/WPA phrase to the first AP or wireless router so
    // the builder can write the wireless ENGINE blocks (pkt_builder's
    // _wireless_elements).
    final wirelessDevices = nodes
        .where((n) =>
            n.type == 'wireless' ||
            n.type == 'wireless-router' ||
            n.type == 'ap')
        .toList();
    if (wirelessDevices.isNotEmpty) {
      final ssidMatch = RegExp(
        'ssid\\s*(?:name\\s*)?(["\']?)([a-z0-9_. -]{2,32}?)\\1(?=[\\s,.,]|\\s*(?:with|using|and|key|wep|wpa|hidden|\$))',
        caseSensitive: false,
      ).firstMatch(text);
      final ssid = ssidMatch == null
          ? null
          : (ssidMatch.group(2) ?? '').trim();
      final wepMatch = RegExp(
        'wep(?:\\s+key)?\\s*["\']?([0-9a-f]{5,26})["\']?',
        caseSensitive: false,
      ).firstMatch(text);
      final wantsWpa2 = lower.contains('wpa2') ||
          lower.contains('wpa') ||
          lower.contains('wpa3');
      if (ssidMatch != null || wepMatch != null || wantsWpa2) {
        final rule = <String, dynamic>{
          if (ssidMatch != null)
            'ssid': ssid,
          if (wepMatch != null) 'wep': wepMatch.group(1),
          if (wantsWpa2) 'wpa2': true,
          if (lower.contains('hidden') || lower.contains('hide ssid'))
            'broadcast': false,
        };
        if (rule.isNotEmpty) {
          final idx = nodes.indexOf(wirelessDevices.first);
          final n = nodes[idx];
          nodes[idx] = NetNode(
            name: n.name,
            type: n.type,
            model: n.model,
            mgmtIp: n.mgmtIp,
            services: n.services,
            serviceRules: {
              ...n.serviceRules,
              'wireless': rule,
            },
          );
        }
      }
    }

    // IPv6 dual-stack: when the brief mentions IPv6, every router
    // interface gets an address derived from its IPv4 subnet octet inside
    // 2001:db8:<vlan>::/64 (documentation space), with SLAAC serving the
    // endpoints - the same shape the adapter renders into IOS.
    //
    // This runs ABOVE the security return below, not after it. It used to sit
    // at the end of the plain path, so a brief that asked for IPv6 and any
    // control at all ("2 routers and 4 pcs with ipv6 and ipsec vpn
    // pre-shared key Key9", "ipv6 with ssh") returned from the security block
    // first and silently lost every IPv6 address. One pass, above both.
    final wantsV6 = lower.contains('ipv6') || lower.contains('dual stack');
    if (wantsV6) {
      final v6Addressing = <InterfaceAddr>[];
      var v6Net = 1;
      for (final a in addressing) {
        final owner = nodes.firstWhere(
          (n) => n.name == a.node,
          orElse: () => const NetNode(name: '', type: ''),
        );
        String? v6;
        if (owner.type == 'router' || owner.type == 'firewall') {
          v6 =
              '2001:db8:$v6Net::${hostIn(a.ipCidr, 1).split('/').first.split('.').last}/64';
          v6Net++;
        }
        v6Addressing.add(
          InterfaceAddr(
            node: a.node,
            iface: a.iface,
            ipCidr: a.ipCidr,
            ip6Cidr: v6,
          ),
        );
      }
      addressing
        ..clear()
        ..addAll(v6Addressing);
    }

    // SECURITY INTENT for the generic path: the security-lab profile above
    // fills SecurityIntent, but a plain brief ("build this network with an
    // AAA server (radius) and a firewall") also asked for controls - and
    // without this block its AAA stopped at the server tab while the router
    // was never pointed at the server.
    final hasAaaWord = lower.contains('aaa') ||
        RegExp(r'\btacacs\+?\b').hasMatch(lower) ||
        RegExp(r'\bradius\b').hasMatch(lower);
    final aaaServers = nodes
        .where((n) => n.type == 'server' && n.services.contains('aaa'))
        .toList();
    String? aaaServerName;
    if (aaaServers.isNotEmpty) {
      aaaServerName = aaaServers.first.name;
    } else if (hasAaaWord && servers.isNotEmpty) {
      // The role parser above only binds 'aaa' to a server when the wording
      // let it; a brief that names AAA without a server role wins a role on
      // the first server so the control is actually buildable.
      final first = servers.first;
      final idx = nodes.indexOf(first);
      final newServices = [...first.services, if (!first.services.contains('aaa')) 'aaa'];
      nodes[idx] = NetNode(
        name: first.name,
        type: first.type,
        model: first.model,
        mgmtIp: first.mgmtIp,
        services: newServices,
        serviceRules: first.serviceRules,
      );
      aaaServerName = first.name;
    }
    final wantsPortSecurity = lower.contains('port security') ||
        lower.contains('port-security') ||
        lower.contains('sticky mac');
    final wantsSnooping = lower.contains('dhcp snooping') ||
        lower.contains('rogue dhcp') ||
        lower.contains('fake dhcp');
    final wantsTelnet = lower.contains('telnet') || lower.contains('vty') ||
        hasAaaWord; // AAA without a named purpose is vty/login control
    // "use SSH instead of telnet", "ssh access", "configure ssh" - the
    // secure variant of remote access.
    final wantsSsh = lower.contains('ssh');
    final etherProto = lower.contains('pagp') && !lower.contains('lacp')
        ? 'pagp'
        : 'lacp';
    final wantsHsrp = lower.contains('hsrp') ||
        lower.contains('vrrp') ||
        lower.contains('glbp') ||
        lower.contains('redundant gateways') ||
        lower.contains('gateway redundancy');
    final hsrpIp = RegExp(
      r'hsrp[^\n.]{0,40}?((?:\d{1,3}\.){3}\d{1,3})',
      caseSensitive: false,
    ).firstMatch(lower)?.group(1);
    final wantsSpanningTree = lower.contains('spanning-tree') ||
        lower.contains('spanning tree') ||
        lower.contains('rapid-pvst') ||
        lower.contains('root bridge') ||
        lower.contains('primary root');
    // Read from the original text: a secret's case must survive.
    final wantsEnableSecret = RegExp(
      r'enable\s+secret\s+([^\s,;.]+)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    final protocol = RegExp(r'\bradius\b').hasMatch(lower) ? 'radius' : 'tacacs+';
    // A tunnel the brief asked for belongs IN the plan even when the brief
    // counted its own devices. "two sites, 2 routers, 2 switches and 8 pcs
    // each, site-to-site ipsec vpn with pre-shared key LabKey1 and ospf"
    // states its own counts, so it is not the security-lab profile and came
    // through this path - and this path never set ipsecVpn at all: the user
    // asked for a VPN and the plan, the config and the checklist said nothing
    // about one.
    final wantsIpsec = lower.contains('ipsec') ||
        lower.contains('site-to-site') ||
        lower.contains('site to site') ||
        lower.contains('vpn') ||
        lower.contains('tunnel');
    // The tunnel's two ends and the networks it protects are read off the
    // plan that was just built: the routers sharing the WAN link are the
    // peers, and the LAN behind each of them is what it protects. A brief
    // that names the tunnel but not its addresses ("ipsec vpn with
    // pre-shared key LabKey1") still describes a real one.
    final tunnel = _tunnelEnds(
      nodes: nodes,
      links: links,
      addressing: addressing,
    );
    // The shared secret is resolved by [resolveAaaKey] below, once the account
    // it may fall back to is known.
    if (hasAaaWord ||
        wantsPortSecurity ||
        wantsSnooping ||
        wantsSsh ||
        wantsEtherChannel ||
        wantsHsrp ||
        wantsSpanningTree ||
        wantsInterVlan ||
        wantsIpsec ||
        wantsEnableSecret != null) {
      // The account the brief supplies for AAA, taken off the server it was
      // written against.  Without this the server's Services tab carried the
      // account while the router kept `aaaUsername == null`, so the plan both
      // configured a login it could not name and was reported as missing
      // credentials it actually had.
      Credential? aaaAccount;
      if (aaaServerName != null) {
        final users = ((serviceRules[aaaServerName]?['aaa'] as Map?)?['users']);
        if (users is List && users.isNotEmpty) {
          final first = users.first;
          if (first is Map && first['username'] is String) {
            final name = (first['username']! as String).trim();
            if (name.isNotEmpty) {
              final secret = (first['password'] ?? '').toString().trim();
              aaaAccount = Credential(name, secret, 0, 'aaa $name');
            }
          }
        }
      }
      final security = SecurityIntent(
        portSecurity: wantsPortSecurity,
        dhcpSnooping: wantsSnooping,
        aaa: hasAaaWord,
        aaaProtocol: protocol,
        aaaServer: aaaServerName,
        // The first router is the authenticating device; a single-router
        // plan makes this unambiguous, and multi-router briefs that care
        // name the router in the security-lab profile instead.  A routerless
        // brief ("a TACACS+ server for authentication") keeps the server
        // side buildable and leaves the client router for later.
        aaaRouter: routers.isNotEmpty ? routers.first.name : null,
        // The account and the shared key are different secrets.  The key is
        // only what the brief states: "using the same shared key on the
        // server and router" says the two ends agree and never says what it
        // is, and the adapters' documented default (cisco) is used for that
        // rather than typing a value the user did not give.
        aaaUsername: aaaAccount?.username,
        aaaAccountPassword:
            (aaaAccount?.password.isEmpty ?? true) ? null : aaaAccount!.password,
        // The account and the shared key are different secrets. A brief that
        // names a key but gives no value has left it unsaid - the adapters'
        // documented lab default stands rather than a value the user never
        // gave. A brief that never mentions a key is the ordinary
        // single-secret lab case, where the account password is the secret.
        aaaPassword: resolveAaaKey(text, aaaAccount),
        telnet: wantsTelnet && !wantsSsh,
        extendedAcl: lower.contains('extended acl') ||
            lower.contains('acl') ||
            lower.contains('access-list') ||
            (lower.contains('block') && lower.contains('branch')),
        ssh: wantsSsh,
        etherChannel: wantsEtherChannel,
        etherChannelProtocol: etherProto,
        hsrp: wantsHsrp,
        hsrpVirtualIp: hsrpIp,
        spanningTree: wantsSpanningTree,
        interVlanRouting: wantsInterVlan,
        ipsecVpn: wantsIpsec,
        vpnPeerA: tunnel.peerA,
        vpnPeerB: tunnel.peerB,
        // Both ends must agree, so the algorithms are explicit here rather
        // than left to each side's fallback; the brief overrides them when it
        // names 3des or md5.
        vpnEncryption: lower.contains('3des') ? '3des' : 'aes',
        vpnHash: lower.contains('md5') ? 'md5' : 'sha',
        // Only what the brief states: a tunnel asked for without a key is
        // staged and reported, never keyed with a value nobody gave.
        vpnPreSharedKey: wantsIpsec ? _preSharedKeyIn(text) : null,
        vpnLocalNetwork: tunnel.local,
        vpnRemoteNetwork: tunnel.remote,
        enableSecret: wantsEnableSecret,
      );
      return NetworkIntent(
        projectName: projectName.isEmpty ? 'net1' : projectName,
        nodes: nodes,
        links: links,
        addressing: addressing,
        vlans: vlans,
        routing: routing,
        notes: [
          'parsed offline from: ${redactSecrets(rawText)}',
          'base $base',
          'router model $routerModel, switch model $switchModel (best-fit; say "use 4331" to override)',
        ],
        assumptions: [
          ..._structureAssumptions(lower, text),
          ..._genericAssumptions(
            switches: switches,
            perSite: perSite,
            sites: sites,
            wantsSerialWan: wantsSerialWan,
            kindCounts: kindCounts,
          ),
          if (hasAaaWord)
            'AAA runs $protocol: ${aaaServerName ?? 'the first server'} holds the accounts${routers.isNotEmpty ? ' and ${routers.first.name} authenticates logins against it' : ''}. Supply the shared key in the request to pin it on both ends (default: cisco).',
          if (wantsInterVlan)
            'Inter-VLAN routing: ${routers.first.name} routes between the VLANs through one dot1Q trunk interface (router-on-a-stick); PC gateways point at the matching sub-interface address.',
          if (wantsIpsec && tunnel.peerA != null)
            'Site-to-site IPsec between ${tunnel.peerA} and ${tunnel.peerB}, '
            'protecting ${tunnel.local} and ${tunnel.remote}; '
            '${_preSharedKeyIn(text) == null ? 'no pre-shared key was stated, so the tunnel is staged and cannot establish until one is given' : 'the stated pre-shared key is used on both ends'}.',
          if (wantsEtherChannel && switches.length >= 2)
            'EtherChannel: ${switches[0].name} and ${switches[1].name} bundle two ports facing each other with $etherProto (channel-group 1); give them matching member ports so the bundle forms.',
          if (wantsHsrp && hsrpIp == null)
            'HSRP was requested without a virtual gateway IP; the plan uses .254 of the LAN subnet - say "HSRP 192.168.1.254" to override.',
        ],
        questions: _briefQuestions(lower),
        confidence: localConfidence,
        planningSource: 'local',
        security: security,
      );
    }

    return NetworkIntent(
      projectName: projectName.isEmpty ? 'net1' : projectName,
      nodes: nodes,
      links: links,
      addressing: addressing,
      vlans: vlans,
      routing: routing,
      notes: [
        'parsed offline from: ${redactSecrets(rawText)}',
        'base $base',
        'router model $routerModel, switch model $switchModel (best-fit; say "use 4331" to override)',
      ],
      assumptions: [
        if (defaulted)
          'No devices were named, so a small-office pair was assumed '
              '(1 router + 1 switch) - say the devices you want ("2 routers, '
              '1 switch, 4 pcs") to replace it.',
        ..._structureAssumptions(lower, text),
        ..._genericAssumptions(
          switches: switches,
          perSite: perSite,
          sites: sites,
          wantsSerialWan: wantsSerialWan,
          kindCounts: kindCounts,
        ),
      ],
      questions: [
        if (defaulted)
          'Which devices should this lab have? The plan currently assumes '
              '1 router + 1 switch - naming the counts pins it down.',
        ..._briefQuestions(lower),
      ],
      confidence: localConfidence,
      planningSource: 'local',
    );
  }

  /// VLAN N's LAN subnet: 192.168.[N].0/24 in documentation space.
  /// Deterministic and human-explainable - "VLAN 20 lives in 192.168.20.0/24".
  static String _vlanSubnet(int vlan) => '192.168.$vlan.0/24';

  /// The two ends of a site-to-site tunnel, read off the plan itself.
  ///
  /// The routers that share a WAN link are the tunnel's ends, and the network
  /// behind each of them is what the tunnel protects. A brief that asks for a
  /// VPN without naming peers or protected subnets ("2 routers, 2 switches
  /// and 8 pcs each, site-to-site ipsec vpn with pre-shared key LabKey1")
  /// still describes a real tunnel, and the adapters' crypto block is keyed
  /// on exactly these four values - left null, the validator reported missing
  /// peers for a plan that plainly had both routers and both LANs.
  static ({
    String? peerA,
    String? peerB,
    String? local,
    String? remote,
  })
  _tunnelEnds({
    required List<NetNode> nodes,
    required List<NetLink> links,
    required List<InterfaceAddr> addressing,
  }) {
    String typeOf(String name) {
      for (final n in nodes) {
        if (n.name == name) return n.type;
      }
      return '';
    }

    // A WAN port is an interface on a router-to-router link; anything else a
    // router owns is a LAN.
    bool onWan(String node, String iface) {
      for (final l in links) {
        final mine = (l.a == node && l.aIf == iface) ||
            (l.b == node && l.bIf == iface);
        if (!mine) continue;
        if (typeOf(l.a) == 'router' && typeOf(l.b) == 'router') return true;
      }
      return false;
    }

    String? wanIp(String node, String iface) {
      for (final a in addressing) {
        if (a.node == node && a.iface == iface) {
          return a.ipCidr.split('/').first;
        }
      }
      return null;
    }

    String? lan(String node) {
      for (final a in addressing) {
        if (a.node != node) continue;
        if (onWan(node, a.iface)) continue;
        return _networkOf(a.ipCidr);
      }
      return null;
    }

    for (final l in links) {
      if (typeOf(l.a) != 'router' || typeOf(l.b) != 'router') continue;
      final peerA = wanIp(l.a, l.aIf);
      final peerB = wanIp(l.b, l.bIf);
      final local = lan(l.a);
      final remote = lan(l.b);
      if (peerA == null || peerB == null || local == null || remote == null) {
        continue;
      }
      return (peerA: peerA, peerB: peerB, local: local, remote: remote);
    }
    return (peerA: null, peerB: null, local: null, remote: null);
  }

  /// The network an interface address belongs to, in CIDR form:
  /// "192.168.1.1/24" -> "192.168.1.0/24".
  static String _networkOf(String cidr) {
    final parts = cidr.split('/');
    final prefix = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 24;
    final octets = parts.first
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    if (octets.length != 4) return cidr;
    var ip = (octets[0] << 24) |
        (octets[1] << 16) |
        (octets[2] << 8) |
        octets[3];
    final mask = prefix == 0
        ? 0
        : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    ip = ip & mask;
    return '${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.'
        '${ip & 255}/$prefix';
  }

  /// The assumption strings of the generic layout, shared by the plain
  /// return path and the security-aware one so the two never drift.
  static List<String> _genericAssumptions({
    required List<NetNode> switches,
    required dynamic perSite,
    required int? sites,
    required bool wantsSerialWan,
    required Map<String, int> kindCounts,
  }) {
    return [
      'Unspecified links use the deterministic local topology layout.',
      'Unspecified router and switch models use the best-fit Packet Tracer models.',
      if (switches.length > 1)
        'Layout: each switch is uplinked to a router in order (SW1 to R1, SW2 to R2, ...) and the PCs are split evenly across the switches; servers stay on the first switch LAN.',
      if (perSite != null)
        'The brief describes $sites sites, so the devices named after "each" were multiplied by $sites.',
      if (wantsSerialWan)
        'The router-to-router WAN is Serial0/0/0 with the first router as the clocking (DCE) end; the executor fits the serial module and reports the port it actually receives.',
      if ((kindCounts['wireless'] ?? 0) > 0 ||
          (kindCounts['tablet'] ?? 0) > 0 ||
          (kindCounts['smartphone'] ?? 0) > 0 ||
          (kindCounts['tv'] ?? 0) > 0)
        'Wireless clients are placed and associate with the access point; no cable is created for them (Packet Tracer pairs them over the wireless link).',
      if ((kindCounts['cloud'] ?? 0) > 0 || (kindCounts['modem'] ?? 0) > 0)
        'The internet edge is a Cloud-PT / Modem-PT device cabled to the first router, or to the firewall when one was requested.',
      if ((kindCounts['firewall'] ?? 0) > 0)
        'A Firewall-PT (ASA) device is placed, cabled and given a generated ASA base config (inside/outside interfaces, stateful inspection, and a default route); adjust security levels or ACLs in Packet Tracer for anything beyond that.',
      if ((kindCounts['wlc'] ?? 0) > 0)
        'The wireless LAN controller is placed but not cabled: its PT port name varies between builds, so the link is left to you rather than guessed.',
      if ((kindCounts['iot'] ?? 0) > 0)
        'IoT devices are placed and join through the home gateway / IoT registration server; their wireless association is not scripted.',
    ];
  }

  /// How well the parser understood a brief: the score reflects what the
  /// brief actually stated (device counts, routing, addresses) and drops
  /// when the small-office fallback had to supply the devices, so a vague
  /// request never wears the same confidence as a detailed one.
  static double _localConfidence({
    required bool statedCounts,
    required bool statedRouting,
    required bool statedAddresses,
    required bool defaulted,
  }) {
    var score = 0.55;
    if (statedCounts) score += 0.15;
    if (statedRouting) score += 0.05;
    if (statedAddresses) score += 0.05;
    if (defaulted) score -= 0.2;
    return score.clamp(0.35, 0.85).toDouble();
  }

  /// Assumption strings for structures the parser had to complete on its
  /// own: multi-site completion and "more than N" lower bounds. Shared by
  /// the plain and the security-aware return so the two never drift.
  static List<String> _structureAssumptions(String lower, String text) => [
    if (BriefSlotPipeline.completesMultiSite(lower, text))
      'The brief describes ${siteCount(text)} sites with no per-site '
          'breakdown: each site was given its own router and access '
          'switch(es), the routers are joined by a WAN link, and the devices '
          'were split across the sites. Say the counts per site to pin the '
          'layout.',
    ..._quantityCaveats(lower),
  ];

  /// The plural each device kind is spoken with in notes and questions.

  /// The singular each device kind is spoken with when the count is one.
  static String _kindSingular(String kind) {
    switch (kind) {
      case 'pc':
        return 'PC';
      case 'ap':
        return 'access point';
      default:
        return kind;
    }
  }

  /// The kind a word names ("switches" -> switch, "aps" -> ap), or null.
  static String? kindForWord(String word) {
    final w = word.trim().toLowerCase().replaceAll(RegExp(r'[.,;!?]+$'), '');
    for (final e in kindPlurals.entries) {
      if (w == e.key || w == e.value.toLowerCase()) return e.key;
    }
    return w == 'aps' ? 'ap' : null;
  }

  /// The kind named right after a "how many"/"more than" cue: the word
  /// itself, a second word for compounds ("ip phones"), or "access points".
  static String? _kindAfterCueWord(String lower, int from, String word) {
    final direct = kindForWord(word);
    if (direct != null) return direct;
    final rest = lower.substring(from);
    if (word.toLowerCase() == 'access' &&
        RegExp(r'\s+points?\b').hasMatch(rest)) {
      return 'access point';
    }
    final next = RegExp(r'^\s+([a-z]+)').firstMatch(rest);
    return next == null ? null : kindForWord(next.group(1)!);
  }

  /// Questions for counts the brief says it does not know ("i don't know
  /// how many phones").
  static List<String> _howManyQuestions(String lower) {
    final out = <String>[];
    for (final m in RegExp(
      r'\bhow\s+many\s+([a-z]+)',
      caseSensitive: false,
    ).allMatches(lower)) {
      final kind = _kindAfterCueWord(lower, m.end, m.group(1)!);
      if (kind == null) continue;
      final label = kindPlurals[kind] ?? kind;
      final question = 'How many $label do you want? Give a number (or a '
          'count per site) and I will plan them in.';
      if (!out.contains(question)) out.add(question);
    }
    return out;
  }

  /// A vague "it should be secure" is a real requirement without a control:
  /// ask which control is wanted instead of guessing one.
  static final RegExp _vagueSecure = RegExp(
    r'\b(?:should|must|needs?\s+to|need\s+to|has\s+to|have\s+to|will)\s+be\s+'
    r'secure\b|\bmake\s+it\s+secure\b|\bkeep\s+it\s+secure\b',
    caseSensitive: false,
  );
  static final RegExp _concreteSecurityWord = RegExp(
    r'\b(?:port\s+security|sticky\s+mac|dhcp\s+snooping|aaa|tacacs\+?|'
    r'radius|ssh|ipsec|vpn|acl|access-list|telnet|hsrp|spanning[- ]tree|'
    r'etherchannel)\b',
    caseSensitive: false,
  );

  static List<String> _vagueSecurityQuestions(String lower) {
    if (!_vagueSecure.hasMatch(lower)) return const [];
    if (_concreteSecurityWord.hasMatch(lower)) return const [];
    return const [
      'What should "secure" cover - port security on the access ports, '
      'SSH-only management, an ACL between the sites, or a VPN?',
    ];
  }

  /// The plan's own questions about this brief, beyond the defaulted-plan
  /// one: unknown counts and vague security asks.
  static List<String> _briefQuestions(String lower) => [
    ..._howManyQuestions(lower),
    ..._vagueSecurityQuestions(lower),
  ].take(4).toList();

  /// Notes for counts stated as lower bounds ("more than 2 switches").
  static List<String> _quantityCaveats(String lower) {
    final out = <String>[];
    for (final m in RegExp(
      r'\b(?:more\s+than|over)\s+(\d{1,3})\s+([a-z]+)',
      caseSensitive: false,
    ).allMatches(lower)) {
      final n = int.parse(m.group(1)!);
      final kind = _kindAfterCueWord(lower, m.end, m.group(2)!);
      if (kind == null) continue;
      final label = n == 1 ? _kindSingular(kind) : (kindPlurals[kind] ?? kind);
      final note = 'You said "more than $n $label" - the plan uses '
          '${n + 1} as the minimum that satisfies it. Give the exact count '
          'to pin it.';
      if (!out.contains(note)) out.add(note);
    }
    return out;
  }
}
