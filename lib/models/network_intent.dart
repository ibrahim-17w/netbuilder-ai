// Universal intent model: target-agnostic network description.
// Adapters compile this into GNS3 / Cisco / PT / Terraform.
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
}

/// One device kind the planner can put on the canvas.
///
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
const List<DeviceKind> deviceKinds = [
  DeviceKind(
    type: 'router',
    keywords: ['router'],
    models: ['4331', '2911', '1941', '4321', '2901', '829'],
    port: 'f0',
    cli: true,
  ),
  DeviceKind(
    type: 'wireless-router',
    // Packet Tracer's Wireless Router-PT: a router with a wireless AP inside.
    // Its own keyword, so 'wireless router' never reads as a plain AP (an AP
    // has no routing or NAT) - and no CLI either, because PT drives it from
    // the same GUI a home router has.
    keywords: ['wireless router'],
    models: ['Wireless Router-PT'],
    port: 'ethernet1',
  ),
  DeviceKind(
    type: 'switch',
    keywords: ['multilayer switch', 'layer 3 switch', 'switch'],
    models: ['2960', '2950', '3560'],
    port: 'f0',
    cli: true,
  ),
  DeviceKind(
    type: 'pc',
    keywords: ['pc', 'workstation', 'desktop computer'],
    models: ['PC-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'laptop',
    keywords: ['laptop', 'notebook'],
    models: ['Laptop-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'server',
    keywords: ['server'],
    models: ['Server-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'printer',
    keywords: ['printer'],
    models: ['Printer-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'firewall',
    // ASA-5506/5505 are Firewall-PT devices with ASA syntax, not IOS: they
    // are placed and cabled, and their config is deliberately left to the
    // user rather than filled with wrong `hostname`/`interface` lines.
    keywords: ['firewall', 'asa'],
    models: ['5506', '5505', 'ASA5505'],
    port: 'g1/1',
  ),
  DeviceKind(
    type: 'wireless',
    keywords: ['wireless access point', 'access point', 'wireless ap', 'ap'],
    models: ['AccessPoint-PT', 'AccessPoint-PT-A', 'AccessPoint-PT-N'],
    port: 'port1',
    wireless: true,
  ),
  DeviceKind(
    type: 'wlc',
    keywords: ['wireless controller', 'wireless lan controller', 'wlc'],
    models: ['2504', 'WLC-PT'],
    // Its PT port menu has no stable name across builds: placed, not wired.
  ),
  DeviceKind(
    type: 'phone',
    keywords: ['ip phone', 'voip phone', 'phone'],
    models: ['7960', '7961', '7962'],
    port: 'port1',
  ),
  DeviceKind(
    type: 'tablet',
    keywords: ['tablet'],
    models: ['Tablet-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'smartphone',
    keywords: ['smartphone', 'smart phone', 'mobile phone'],
    models: ['Smartphone-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'tv',
    keywords: ['smart tv', 'tv'],
    models: ['TV-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'cloud',
    keywords: ['cloud', 'isp', 'internet'],
    models: ['Cloud-PT'],
    port: 'ethernet1',
  ),
  DeviceKind(
    type: 'modem',
    keywords: ['cable modem', 'dsl modem', 'modem'],
    models: ['DSL Modem-PT', 'Cable Modem-PT', 'Modem-PT'],
    port: 'port1',
  ),
  DeviceKind(
    type: 'iot',
    keywords: ['iot', 'home gateway', 'mcu', 'iot server'],
    models: ['Home Gateway-PT', 'MCU-PT', 'IoT Server-PT'],
    // IoT devices join through the gateway/registration server, and the PT
    // port menu differs per model: placed with a wireless assumption instead
    // of a guessed cable.
    wireless: true,
  ),
];

/// Canonical node-name prefixes per device kind (FW1, AP1, ISP1, ...).
const Map<String, String> devicePrefixes = {
  'firewall': 'FW',
  'wireless': 'AP',
  'wireless-router': 'WR',
  'wlc': 'WLC',
  'phone': 'PH',
  'tablet': 'TAB',
  'smartphone': 'SP',
  'tv': 'TV',
  'cloud': 'CLOUD',
  'modem': 'MODEM',
  'iot': 'IOT',
  'laptop': 'LT',
  'printer': 'PRN',
};

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

  const InterfaceAddr({
    required this.node,
    required this.iface,
    required this.ipCidr,
  });

  Map<String, dynamic> toJson() => {
    'node': node,
    'iface': iface,
    'ipCidr': ipCidr,
  };

  factory InterfaceAddr.fromJson(Map<String, dynamic> j) => InterfaceAddr(
    node: j['node'] as String,
    iface: j['iface'] as String,
    ipCidr: j['ipCidr'] as String,
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
  final String? aaaPassword;
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
    this.tests = const [],
  });

  bool get requested =>
      portSecurity ||
      dhcpSnooping ||
      aaa ||
      telnet ||
      managerIp != null ||
      extendedAcl ||
      ipsecVpn;

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
    'notes': notes,
    'assumptions': assumptions,
    'questions': questions,
    'confidence': confidence,
    'planningSource': planningSource,
    'security': security.toJson(includeSecrets: includeSecrets),
  };

  /// Safe copy for third-party planners.  Credentials remain in the local
  /// intent used for execution, but are not sent in the Gemini prompt.
  Map<String, dynamic> toPlannerJson() => toJson(includeSecrets: false);

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
  );

  /// PT model catalog for best-fit selection.
  static const ptRouters = ['4331', '2911', '1941', '4321', '2901', '829'];
  static const ptSwitches = ['2960', '2950', '3560'];

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
    final securityWords =
        lower.contains('ipsec') ||
        lower.contains('site-to-site') ||
        lower.contains('tacacs') ||
        lower.contains('aaa') ||
        lower.contains('port security') ||
        lower.contains('dhcp snooping') ||
        lower.contains('time-based acl');
    return securityWords &&
        (lower.contains('branch') ||
            lower.contains('headquarters') ||
            lower.contains('hq_') ||
            lower.contains('br_') ||
            lower.contains('wan'));
  }

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
    final hoursMatch = RegExp(
      r'(\d{1,2}:\d{2})\s*(?:to|-)\s*(\d{1,2}:\d{2})',
      caseSensitive: false,
    ).firstMatch(text);
    final credentialMatch = RegExp(
      r'(?:username|user|login)\s+([A-Za-z0-9_.-]+)[^\n.]{0,80}?(?:password|pass)\s+([^\s,.]+)',
      caseSensitive: false,
    ).firstMatch(text);
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
    final key = firstMatch(
      RegExp(
        r'(?:pre[- ]shared|preshared)\s+key\s*[:=]?\s*([^\s,.]+)',
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

    final officeHours = hoursMatch == null
        ? 'weekdays 08:00-17:00'
        : 'weekdays ${hoursMatch.group(1)}-${hoursMatch.group(2)}';
    final hasTacacs = lower.contains('tacacs');
    final hasTelnet = lower.contains('telnet');
    final security = SecurityIntent(
      portSecurity:
          lower.contains('port security') || lower.contains('port-security'),
      dhcpSnooping: lower.contains('dhcp snooping'),
      dhcpTrustedInterface: 'f0/1',
      aaa: lower.contains('aaa') || hasTacacs,
      aaaProtocol: hasTacacs ? 'tacacs+' : 'tacacs+',
      aaaServer: 'AAA1',
      aaaRouter: 'HQ_Router',
      aaaUsername: credentialMatch?.group(1),
      aaaPassword: credentialMatch?.group(2),
      telnet: hasTelnet,
      managerIp: '192.168.1.50',
      officeHours: officeHours,
      extendedAcl:
          lower.contains('extended acl') ||
          lower.contains('block') && lower.contains('branch'),
      branchNetwork: '192.168.2.0/24',
      protectedServerIp: '192.168.1.100',
      allowedWebServerIp: '192.168.1.102',
      ipsecVpn: lower.contains('ipsec') || lower.contains('site-to-site'),
      vpnPeerA: '10.1.1.1',
      vpnPeerB: '10.1.1.2',
      vpnEncryption: lower.contains('aes') ? 'aes' : null,
      vpnHash: lower.contains('sha') ? 'sha' : null,
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
        'Provide the TACACS+ username and password; they were not supplied.',
      if (key == null) 'Provide the IPSec pre-shared key; it was not supplied.',
      if (hoursMatch == null)
        'Confirm office hours; the plan currently assumes weekdays 08:00-17:00.',
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
      routing: lower.contains('ospf') ? 'ospf' : 'static',
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

  /// Very small heuristic parser so the app works offline without Gemini.
  /// Handles: "2 routers 1 switch", "192.168.1.0/24", "ospf", vlan numbers,
  /// explicit models ("use 4331") or best-fit router choice.
  static NetworkIntent parseSimple(String projectName, String text) {
    final lower = text.toLowerCase();
    if (_looksLikeSecurityBranchLab(lower)) {
      return _parseSecurityBranchLab(projectName, text);
    }
    final nodes = <NetNode>[];
    final vlans = <int>[];
    var routing = 'static';

    int routerCount = 0;
    int switchCount = 0;
    int pcCount = 0;
    int serverCount = 0;

    // Do not interpret hardware model numbers as quantities:
    // "Cisco 2911 routers" means one or more named 2911 routers, not 2911
    // devices. Quantities are intentionally limited to three digits.
    final routerMatch = RegExp(r'\b(\d{1,3})\s*routers?\b').firstMatch(lower);
    if (routerMatch != null) routerCount = int.parse(routerMatch.group(1)!);
    if (lower.contains('router') && routerCount == 0) routerCount = 1;

    final switchMatch = RegExp(
      r'\b(\d{1,3})\s*switch(?:es)?\b',
    ).firstMatch(lower);
    if (switchMatch != null) switchCount = int.parse(switchMatch.group(1)!);
    if (lower.contains('switch') && switchCount == 0) switchCount = 1;

    final pcMatch = RegExp(r'(\d+)\s*pcs?').firstMatch(lower);
    if (pcMatch != null) pcCount = int.parse(pcMatch.group(1)!);

    final serverMatch = RegExp(r'(\d+)\s*servers?').firstMatch(lower);
    if (serverMatch != null) {
      serverCount = int.parse(serverMatch.group(1)!);
    }
    if (lower.contains('server') && serverCount == 0) serverCount = 1;

    // Every other device kind the catalog knows, counted the same way:
    // "2 firewalls", "3 IP phones", "1 wireless controller".  A bare mention
    // with no number means one, exactly like 'server' above.  The word-boundary
    // test matters: a plain `contains('ap')` would read 'lapTop' as an AP.
    final kindCounts = <String, int>{};
    for (final kind in deviceKinds) {
      if (const ['router', 'switch', 'pc', 'server'].contains(kind.type)) {
        continue; // counted above, with their model-number guards
      }
      for (final k in kind.keywords) {
        final m = RegExp('(\\d{1,3})\\s*${RegExp.escape(k)}s?\\b')
            .firstMatch(lower);
        if (m != null) {
          kindCounts[kind.type] = int.parse(m.group(1)!);
          break;
        }
      }
      if ((kindCounts[kind.type] ?? 0) == 0 &&
          kind.keywords.any(
            (k) => RegExp('\\b${RegExp.escape(k)}\\b').hasMatch(lower),
          )) {
        kindCounts[kind.type] = 1;
      }
    }
    final wirelessCount = kindCounts['wireless'] ?? 0;
    // 'wireless' alone (no AP wording) still means a wireless network: one AP.
    if (wirelessCount == 0 &&
        RegExp(r'\b(wifi|wi-fi|wireless|wlan)\b').hasMatch(lower)) {
      kindCounts['wireless'] = 1;
    }

    // Explicit labels are authoritative when the user names devices rather
    // than stating a quantity, e.g. "R1 and R2 ... Cisco 2911 routers".
    int highestLabel(String pattern) => RegExp(pattern)
        .allMatches(text)
        .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
        .fold(0, (max, value) => value > max ? value : max);

    routerCount = routerCount > highestLabel(r'\bR(\d+)\b')
        ? routerCount
        : highestLabel(r'\bR(\d+)\b');
    switchCount = switchCount > highestLabel(r'\bSW(\d+)\b')
        ? switchCount
        : highestLabel(r'\bSW(\d+)\b');
    pcCount = pcCount > highestLabel(r'\bPC(\d+)\b')
        ? pcCount
        : highestLabel(r'\bPC(\d+)\b');
    serverCount = serverCount > highestLabel(r'\bSRV(\d+)\b')
        ? serverCount
        : highestLabel(r'\bSRV(\d+)\b');

    if (routerCount == 0 &&
        switchCount == 0 &&
        pcCount == 0 &&
        serverCount == 0) {
      routerCount = 1;
      switchCount = 1;
    }

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
    for (var i = 1; i <= serverCount; i++) {
      nodes.add(NetNode(name: 'SRV$i', type: 'server', model: 'Server-PT'));
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
    // "R1 g0/0 connects to SW1 f0/1". Normalize long names to g/f so one
    // regex covers both spellings. (Bug: the old chain ignored requested
    // interfaces, so R1-R2 landed on g0/0 with the LAN subnet.)
    String norm(String s) => s
        .toLowerCase()
        .replaceAll('gigabitethernet', ' g ')
        .replaceAll('fastethernet', ' f ')
        .replaceAll(RegExp(r'\s+'), ' ');
    String? node(String w) {
      final w2 = w.toLowerCase().trim();
      // return the CANONICAL node name ('r1' typed in text -> 'R1')
      for (final n in nodes) {
        if (n.name.toLowerCase() == w2) return n.name;
      }
      return null;
    }

    final linksExplicit = <NetLink>[];
    final fullLink = RegExp(
      r'(\w+)\s*([gf])\s*(\d+/\d+)\s*(?:connects?\s*to|to)\s*(\w+)\s*([gf])\s*(\d+/\d+)',
    );
    final normText = norm(text);
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
      r'(\w+)\s+and\s+(\w+)\s+connect[^.]*?\b([gf])\s*(\d+/\d+)\s+on\s+both',
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
    // "PC1 connects to SW1 FastEthernet0/2" (end-device side has only
    // Fa0 - same for "SRV1 connects to SW1 FastEthernet0/4"), and
    // "PH1 Port 1 connects to SW1 FastEthernet0/5" for the kinds whose
    // interfaces are not named Fa0/Gi0 (IP phone, access point, modem).
    final pcLink = RegExp(
      r'(\w+)\s+connects?\s*to\s+(\w+)\s*([gf])\s*(\d+/\d+)',
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
    final portLink = RegExp(
      r'(\w+)\s*port\s*(\d+)\s+connects?\s*to\s+(\w+)\s*([gf])\s*(\d+/\d+)',
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
    for (final l in linksExplicit) {
      final key = l.a.compareTo(l.b) <= 0
          ? '${l.a}|${l.aIf}|${l.b}|${l.bIf}'
          : '${l.b}|${l.bIf}|${l.a}|${l.aIf}';
      if (seen.add(key)) links.add(l);
    }
    // A WAN between two routers is a DIFFERENT cable from a LAN link: when
    // the brief says serial / WAN / leased line / back-to-back the transit
    // link is Serial0/0/0, which is also what tells the executor to fit the
    // HWIC-2T and wire the cable with one clocking (DCE) end.
    final wantsSerialWan = RegExp(
      r'(serial|\bwan\b|leased[- ]line|back[- ]to[- ]back|frame relay|dsl)',
    ).hasMatch(lower);

    // Naive chain fallback only when the instruction specified nothing.
    if (links.isEmpty) {
      for (var i = 0; i + 1 < routers.length; i++) {
        final wanIf = wantsSerialWan ? 's0/0/0' : '${rIf}0/0';
        links.add(
          NetLink(
            a: routers[i].name,
            aIf: wanIf,
            b: routers[i + 1].name,
            bIf: wanIf,
            cable: wantsSerialWan ? 'serial' : null,
            dce: wantsSerialWan ? 'a' : null,
          ),
        );
      }
      if (routers.isNotEmpty && switches.isNotEmpty) {
        links.add(
          NetLink(
            a: routers.first.name,
            aIf: '${rIf}0/1',
            b: switches.first.name,
            bIf: 'f0/1',
          ),
        );
      }
      for (var i = 0; i < endpoints.length; i++) {
        if (switches.isEmpty && routers.isEmpty) break;
        final sw = switches.isNotEmpty
            ? switches.first.name
            : routers.first.name;
        links.add(
          NetLink(
            a: sw,
            aIf: 'f0/${i + 2}',
            b: endpoints[i].name,
            bIf: endpointPort(endpoints[i].name),
          ),
        );
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
    bool linkedTo(String name) => links.any((l) => l.a == name || l.b == name);
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
      final upstream = fwUp.isNotEmpty
          ? fwUp
          : routers.isNotEmpty
          ? routers.first.name
          : switches.first.name;
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

    // ADDRESSING: explicit CIDRs in the instruction are assigned in order
    // - transit (router-router) links first, then LAN (router-switch)
    // links. Router .1, second transit end .2. Unknown prefix handled.
    final cidrs = RegExp(
      r'(\d+\.\d+\.\d+\.\d+)\s*/\s*(\d+)',
    ).allMatches(text).map((m) => '${m.group(1)!}/${m.group(2)!}').toList();
    String nextSubnet(bool transit) {
      if (cidrs.isNotEmpty) return cidrs.removeAt(0);
      if (transit) {
        final k = transitPool++;
        return '10.0.0.${k * 4}/30';
      }
      final k = lanPool++;
      final b = base.split('/');
      final o = b[0].split('.');
      var third = int.parse(o[2]) + k;
      third = third.clamp(0, 254);
      return '${o[0]}.${o[1]}.$third.0/24';
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
    // Switches stay layer-2, but each PC/server hanging off that switch
    // gets .10, .11, ... of the same subnet - the sidecar types these
    // into the device's Desktop > IP Configuration.
    for (final l in links.where(routerToSwitch)) {
      final aNode = nodes.firstWhere((n) => n.name == l.a);
      final sub = nextSubnet(false);
      final routerName = aNode.type == 'router' ? l.a : l.b;
      final switchName = aNode.type == 'router' ? l.b : l.a;
      addressing.add(
        InterfaceAddr(
          node: routerName,
          iface: aNode.type == 'router' ? l.aIf : l.bIf,
          ipCidr: hostIn(sub, 1),
        ),
      );
      var hostIdx = 0;
      for (final pl in links) {
        final aN = nodes.firstWhere((n) => n.name == pl.a);
        final bN = nodes.firstWhere((n) => n.name == pl.b);
        final aIsEndpoint = aN.type == 'pc' || aN.type == 'server';
        final bIsEndpoint = bN.type == 'pc' || bN.type == 'server';
        if (!aIsEndpoint && !bIsEndpoint) continue;
        final epName = aIsEndpoint ? pl.a : pl.b;
        final otherName = aIsEndpoint ? pl.b : pl.a;
        if (otherName != switchName) continue;
        addressing.add(
          InterfaceAddr(
            node: epName,
            iface: aIsEndpoint ? pl.aIf : pl.bIf,
            ipCidr: hostIn(sub, 10 + hostIdx),
          ),
        );
        hostIdx++;
      }
    }

    final vlanMatches = RegExp(r'vlan\s*(\d+)').allMatches(lower);
    for (final m in vlanMatches) {
      vlans.add(int.parse(m.group(1)!));
    }

    if (lower.contains('ospf')) {
      routing = 'ospf';
    } else if (lower.contains('eigrp')) {
      routing = 'eigrp';
    } else if (lower.contains('bgp')) {
      routing = 'bgp';
    }

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
    };
    final roles = <String, List<String>>{};
    final serviceRules = <String, Map<String, dynamic>>{};
    Map<String, dynamic> rulesFor(String name) =>
        serviceRules.putIfAbsent(name, () => <String, dynamic>{});
    String ruleOwner(String fragment) {
      final named = servers
          .where((s) => fragment.contains(s.name.toLowerCase()))
          .map((s) => s.name)
          .toList();
      return named.isNotEmpty ? named.first : servers.first.name;
    }

    if (servers.isNotEmpty) {
      final fragments = text.toLowerCase().split(RegExp(r'[\n.]'));
      for (final frag in fragments) {
        final found = roleWords.entries
            .where((e) => frag.contains(e.key))
            .map((e) => e.value)
            .toSet()
            .toList();
        if (found.isEmpty) continue;
        var named = servers
            .where((s) => frag.contains(s.name.toLowerCase()))
            .map((s) => s.name)
            .toList();
        if (named.isEmpty) named = [servers.first.name];
        for (final n in named) {
          roles.putIfAbsent(n, () => []);
          for (final r in found) {
            if (!roles[n]!.contains(r)) roles[n]!.add(r);
          }
        }
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
          final owner = ruleOwner(match.group(0)!.toLowerCase());
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

      final credentialsByServer = <String, List<Map<String, String>>>{};
      final credentialPattern = RegExp(
        r'(?:aaa|ftp|email|mail)?\s*(?:user|username)\s+([a-z0-9_.-]+)\s+(?:with\s+)?(?:password|pass)\s*[:=]?\s*([^\s,;.]+)',
        caseSensitive: false,
      );
      for (final match in credentialPattern.allMatches(text)) {
        final owner = ruleOwner(match.group(0)!.toLowerCase());
        final user = match.group(1)!;
        final password = match.group(2)!;
        final rows = credentialsByServer.putIfAbsent(owner, () => []);
        if (!rows.any((row) => row['username'] == user)) {
          rows.add({'username': user, 'password': password});
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

    return NetworkIntent(
      projectName: projectName.isEmpty ? 'net1' : projectName,
      nodes: nodes,
      links: links,
      addressing: addressing,
      vlans: vlans,
      routing: routing,
      notes: [
        'parsed offline from: $text',
        'base $base',
        'router model $routerModel, switch model $switchModel (best-fit; say "use 4331" to override)',
      ],
      assumptions: [
        'Unspecified links use the deterministic local topology layout.',
        'Unspecified router and switch models use the best-fit Packet Tracer models.',
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
          'A Firewall-PT (ASA) device is placed and cabled, but its ASA-specific configuration is left to the user: ASA syntax is not IOS, so no IOS config is generated for it.',
        if ((kindCounts['wlc'] ?? 0) > 0)
          'The wireless LAN controller is placed but not cabled: its PT port name varies between builds, so the link is left to you rather than guessed.',
        if ((kindCounts['iot'] ?? 0) > 0)
          'IoT devices are placed and join through the home gateway / IoT registration server; their wireless association is not scripted.',
      ],
      confidence: 0.55,
      planningSource: 'local',
    );
  }
}
