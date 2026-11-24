import '../../models/request_requirement.dart';

/// Hierarchical context at UTF-16 offsets in the already normalized brief.
/// The reader never bridges text again, so source-mapped readers share offsets.
class RequirementScopeContext {
  final String? siteId;
  final String? deviceId;
  final String? vlanId;
  final String? interfaceId;
  final String? serviceId;
  final String networkRole;
  final bool globalTotal;

  const RequirementScopeContext({
    this.siteId,
    this.deviceId,
    this.vlanId,
    this.interfaceId,
    this.serviceId,
    this.networkRole = '',
    this.globalTotal = false,
  });

  RequirementScope scope({String projectId = '', bool includeService = true}) {
    var result = RequirementScope.project(projectId);
    void child(RequirementScopeKind kind, String id) {
      result = RequirementScope(
        kind: kind,
        scopeId: id,
        parent: result.kind == RequirementScopeKind.project && projectId.isEmpty
            ? null
            : result,
        siteId: siteId ?? '',
        deviceId: deviceId ?? '',
        networkRole: networkRole,
      );
    }

    if (siteId != null) child(RequirementScopeKind.site, siteId!);
    if (deviceId != null) child(RequirementScopeKind.device, deviceId!);
    if (vlanId != null) child(RequirementScopeKind.vlan, vlanId!);
    if (interfaceId != null) {
      child(RequirementScopeKind.linkInterface, interfaceId!);
    }
    if (includeService && serviceId != null) {
      child(RequirementScopeKind.service, serviceId!);
    }
    if (result.kind == RequirementScopeKind.project && networkRole.isNotEmpty) {
      result = RequirementScope(
        kind: result.kind,
        scopeId: result.scopeId,
        networkRole: networkRole,
      );
    }
    return result;
  }
}

/// One deterministic scope reader shared by quantity, subnet, routing and
/// service extraction. Headings persist across newlines; ordinary site
/// qualifiers persist only within their sentence. Explicit global sections
/// clear all inherited site/device/VLAN context.
class RequirementScopeReader {
  final String normalizedText;
  late final String _lower = normalizedText.toLowerCase();
  late final List<_ScopeAnchor> _anchors = _readAnchors();
  late final Map<String, String> _aliases = _readAliases();

  RequirementScopeReader(this.normalizedText);

  static final _site = RegExp(
    r'\b(?:hq|headquarters)\b|'
    r'\b(?:(ground|first|second|third|fourth|fifth|sixth|seventh|eighth|'
    r'ninth|tenth|top|upper|lower|main|front|back|branch|left|right|north|'
    r'south|east|west)[ \t]+)?'
    r'(floor|office|branch|site|building|classroom|room|department|location)'
    r'(?:es|s)?(?:[ \t]+([a-z0-9][a-z0-9_-]*))?\b',
  );
  static const _notDesignators = {
    'a',
    'an',
    'the',
    'is',
    'are',
    'has',
    'have',
    'having',
    'needs',
    'need',
    'with',
    'and',
    'or',
    'of',
    'in',
    'on',
    'at',
    'to',
    'for',
    'each',
    'per',
    'will',
    'must',
    'should',
    'can',
    'gets',
    'get',
    'uses',
    'use',
    'connected',
    'network',
    'router',
    'routers',
    'switch',
    'switches',
    'server',
    'servers',
    'pc',
    'pcs',
    'office',
    'offices',
    'branch',
    'branches',
    'site',
    'sites',
    'inventory',
    'ospf',
    'eigrp',
    'bgp',
    'static',
    'routing',
    'dhcp',
    'dns',
    'aaa',
    'totals',
    'total',
    'allocation',
    'allocations',
    'devices',
  };
  static final _global = RegExp(
    r'\b(?:global(?:[ \t]+(?:totals?|inventory|requirements?|routing|services?|settings?))?|'
    r'overall(?:[ \t]+(?:totals?|inventory|requirements?))?|'
    r'project[- \t]+wide(?:[ \t]+(?:totals?|inventory|requirements?|routing))?|'
    r'network[- \t]+wide(?:[ \t]+(?:totals?|inventory|requirements?|routing))?|'
    r'total[ \t]+inventory|routing(?:[ \t]+(?:requirements?|protocol))?)'
    r'[ \t]*:',
  );
  static final _paragraphRouting = RegExp(
    r'\n[ \t]*\n[ \t]*(?=(?:(?:use|configure|enable|run|set[ \t]+up)[ \t]+)?'
    r'(?:ospf|eigrp|bgp|static[ \t]+routing|routing)\b)',
  );
  static final _globalInline = RegExp(
    r'\b(?:globally|overall|in[ \t]+total|across[ \t]+all[ \t]+sites|'
    r'for[ \t]+the[ \t]+(?:whole|entire)[ \t]+(?:project|network))\b',
  );
  static final _device = RegExp(
    r'\b(?:r|sw|srv|pc|ap|fw|wlc|router|switch|server|firewall)'
    r'(?:\d+|-[a-z0-9][a-z0-9_-]*)\b',
  );
  static final _vlan = RegExp(r'\bvlan[ \t]+(\d{1,4})\b');
  static final _interface = RegExp(
    r'\b(?:(?:interface[ \t]+)?(?:fastethernet|gigabitethernet|'
    r'tengigabitethernet|ethernet|serial|fa|gi|ge|eth|se|f|g|s)[ \t]*'
    r'\d+(?:/\d+){0,3}(?:\.\d+)?|interface[ \t]+vlan[ \t]*\d+)\b',
  );
  static final _service = RegExp(
    r'\b(?:dhcpv6|dhcp|dns|https?|web|aaa|radius|tacacs\+?|ftp|tftp|'
    r'ntp|syslog|email|mail|snmp)\b',
  );
  static final _networkRole = RegExp(
    r'\b(?:lan[ \t]*\d+|(?:management|guest|voice|staff|users?|servers?|'
    r'wan|lan)[ \t]+(?:vlan|lan|subnet|network))\b|'
    r'\bvlan[ \t]+\d+[ \t]+(management|guest|voice|staff|users?|servers?)\b',
  );
  static final _inventory = RegExp(
    r'\b(?:\d+|a|an)[ \t]+(?:(?:core|edge|access|distribution|web|dhcp|dns|'
    r'aaa|radius|http|https|ftp|mail|email|ntp|syslog)[ \t]+)*'
    r'(?:routers?|switch(?:es)?|servers?(?:-pt)?|pcs?|computers?|laptops?|'
    r'phones?|printers?|firewalls?|access[ \t]+points?|workstations?)\b',
  );
  static final _sentenceBreak = RegExp(r'[;\n]|\.(?=\s|$)');
  static final _complete = RegExp(
    r'\b(?:all[ \t]+(?:site[ \t]+)?(?:allocations?|inventories)[ \t]+'
    r'(?:are[ \t]+)?complete|(?:allocations?|site[ \t]+inventories)[ \t]+'
    r'(?:are[ \t]+)?(?:complete|exhaustive)|'
    r'(?:all|every)[ \t]+(?:devices?|inventory)[ \t]+(?:is[ \t]+|are[ \t]+)?'
    r'allocated|no[ \t]+(?:other|additional|unallocated)[ \t]+devices)\b',
  );

  String _canonical(String id) => _aliases[id] ?? id;

  List<_ScopeAnchor> _readAnchors() {
    final result = <_ScopeAnchor>[];
    for (final match in _site.allMatches(_lower)) {
      var end = match.end;
      String id;
      if (match.group(2) == null) {
        id = 'hq';
      } else {
        final adjective = match.group(1);
        final noun = match.group(2)!;
        final designator = match.group(3);
        final accepted =
            designator != null && !_notDesignators.contains(designator);
        if (designator != null && !accepted) {
          end -= designator.length;
          while (end > match.start && _lower[end - 1].trim().isEmpty) {
            end--;
          }
        }
        id =
            '${adjective == null ? '' : '$adjective '}$noun'
            '${accepted ? ' $designator' : ''}';
      }
      result.add(
        _ScopeAnchor(
          start: match.start,
          end: end,
          id: id,
          kind: RequirementScopeKind.site,
          heading: _headingAfter(end),
        ),
      );
    }
    for (final match in _global.allMatches(_lower)) {
      result.add(
        _ScopeAnchor(
          start: match.start,
          end: match.end,
          id: '',
          kind: RequirementScopeKind.project,
          heading: true,
          total: !match.group(0)!.startsWith('routing'),
        ),
      );
    }
    for (final match in _paragraphRouting.allMatches(_lower)) {
      result.add(
        _ScopeAnchor(
          start: match.start,
          end: match.end,
          id: '',
          kind: RequirementScopeKind.project,
          heading: true,
        ),
      );
    }
    void scan(
      RegExp pattern,
      RequirementScopeKind kind,
      String Function(RegExpMatch) id,
    ) {
      for (final match in pattern.allMatches(_lower)) {
        result.add(
          _ScopeAnchor(
            start: match.start,
            end: match.end,
            id: id(match),
            kind: kind,
            heading: _headingAfter(match.end),
          ),
        );
      }
    }

    scan(_device, RequirementScopeKind.device, (m) => m.group(0)!);
    scan(_vlan, RequirementScopeKind.vlan, (m) => 'vlan ${m.group(1)}');
    scan(
      _interface,
      RequirementScopeKind.linkInterface,
      (m) => m
          .group(0)!
          .replaceFirst(RegExp(r'^interface[ \t]+'), '')
          .replaceAll(RegExp(r'[ \t]+'), ''),
    );
    scan(
      _service,
      RequirementScopeKind.service,
      (m) => switch (m.group(0)!) {
        'web' || 'https' => 'http',
        'radius' || 'tacacs' || 'tacacs+' => 'aaa',
        'mail' => 'email',
        final id => id,
      },
    );
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  bool _headingAfter(int end) =>
      RegExp(r'^[ \t]*:').hasMatch(_lower.substring(end));

  Map<String, String> _readAliases() {
    final sites = _anchors
        .where((a) => a.kind == RequirementScopeKind.site)
        .toList();
    final choices = <String, Set<String>>{};
    for (var i = 1; i < sites.length; i++) {
      final left = sites[i - 1];
      final right = sites[i];
      final between = _lower.substring(left.end, right.start);
      if (!RegExp(
        r'^(?:[ \t]+|[ \t]+(?:is[ \t]+(?:the[ \t]+|a[ \t]+)?|'
        r'(?:also[ \t]+)?(?:called|known[ \t]+as)[ \t]+))$',
      ).hasMatch(between)) {
        continue;
      }
      final canonical = right.id == 'hq' ? right.id : left.id;
      final alias = canonical == left.id ? right.id : left.id;
      choices.putIfAbsent(alias, () => {}).add(canonical);
    }
    return {
      for (final entry in choices.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
  }

  /// All named sites, in text order, with HQ/headquarters aliases collapsed.
  List<String> get knownSites => List.unmodifiable({
    for (final anchor in _anchors)
      if (anchor.kind == RequirementScopeKind.site) _canonical(anchor.id),
  });

  /// Sites with inventory headings or an explicit inline device list.
  List<String> get inventorySites {
    final result = <String>{};
    for (final anchor in _anchors) {
      if (anchor.kind != RequirementScopeKind.site) continue;
      final stop = _siteSectionEnd(anchor);
      if (!_inventory.hasMatch(_lower.substring(anchor.end, stop))) continue;
      result.add(_canonical(anchor.id));
    }
    // The same stable anonymous IDs used by the per-site quantity expansion.
    final each = RegExp(r'\beach\b').firstMatch(_lower);
    if (each != null) {
      final preceding = RegExp(
        r'(\d+)[ \t]+(?:branch[ \t]+)?'
        r'(?:offices?|branches|sites?|floors?|buildings?)',
      ).allMatches(_lower.substring(0, each.start)).lastOrNull;
      final explicit = RegExp(
        r'^[ \t]+of[ \t]+(\d+)',
      ).firstMatch(_lower.substring(each.end));
      final repetitions = int.tryParse(
        explicit?.group(1) ?? preceding?.group(1) ?? '',
      );
      final site = siteAt(each.end);
      if (repetitions != null &&
          repetitions > 1 &&
          repetitions <= 25 &&
          site != null &&
          result.remove(site)) {
        result.addAll([for (var i = 1; i <= repetitions; i++) '$site#$i']);
      }
    }
    return List.unmodifiable(result);
  }

  /// Complete inventory sections make omitted device kinds explicit zeros.
  /// An ordinary prose mention alone is not evidence of completeness.
  List<String> get completeInventorySites {
    final inventory = inventorySites;
    if (allocationComplete) return inventory;
    return List.unmodifiable({
      for (final anchor in _anchors)
        if (anchor.kind == RequirementScopeKind.site &&
            anchor.heading &&
            inventory.contains(_canonical(anchor.id)))
          _canonical(anchor.id),
    });
  }

  bool get allocationComplete => _complete.hasMatch(_lower);

  int _siteSectionEnd(_ScopeAnchor anchor) {
    var stop = _lower.length;
    if (!anchor.heading) {
      final sentence = _sentenceBreak.firstMatch(_lower.substring(anchor.end));
      if (sentence != null) stop = anchor.end + sentence.start;
    }
    for (final other in _anchors) {
      if (other.start < anchor.end) continue;
      if (other.kind == RequirementScopeKind.project ||
          (other.kind == RequirementScopeKind.site &&
              _canonical(other.id) != _canonical(anchor.id))) {
        if (other.start < stop) stop = other.start;
        break;
      }
    }
    return stop;
  }

  String? siteAt(int start, {int? end}) => contextAt(start, end: end).siteId;

  RequirementScope scopeAt(
    int start, {
    int? end,
    String projectId = '',
    bool includeService = true,
  }) => contextAt(
    start,
    end: end,
  ).scope(projectId: projectId, includeService: includeService);

  RequirementScopeContext contextAt(int start, {int? end}) {
    if (start < 0 ||
        start > normalizedText.length ||
        (end != null && (end < start || end > normalizedText.length))) {
      throw RangeError('Scope offsets are outside normalized text.');
    }
    final limit = end ?? start;
    var sentenceStart = 0;
    for (final match in _sentenceBreak.allMatches(_lower.substring(0, start))) {
      sentenceStart = match.end;
    }
    String? site, device, vlan, interface, service;
    var globalTotal = false;
    var lastSiteStart = 0;
    // Persistent headings form a hierarchy, independent of line breaks.
    void apply(_ScopeAnchor anchor) {
      switch (anchor.kind) {
        case RequirementScopeKind.project:
          site = device = vlan = interface = service = null;
          globalTotal = anchor.total;
          lastSiteStart = anchor.start;
        case RequirementScopeKind.site:
          final next = _canonical(anchor.id);
          if (site != next) device = vlan = interface = service = null;
          site = next;
          globalTotal = false;
          lastSiteStart = anchor.start;
        case RequirementScopeKind.device:
          device = anchor.id;
          vlan = interface = service = null;
        case RequirementScopeKind.vlan:
          vlan = anchor.id;
          interface = service = null;
        case RequirementScopeKind.linkInterface:
          interface = anchor.id;
          service = null;
        case RequirementScopeKind.service:
          service = anchor.id;
        case RequirementScopeKind.output:
          break;
      }
    }

    for (final anchor in _anchors) {
      if (anchor.start >= limit && anchor.start > start) break;
      if (anchor.heading) apply(anchor);
    }
    for (final anchor in _anchors) {
      if (anchor.start >= limit && anchor.start > start) break;
      if (!anchor.heading &&
          anchor.start >= sentenceStart &&
          anchor.start >= lastSiteStart) {
        apply(anchor);
      }
    }
    // A trailing local qualifier overrides an inherited heading. Do not bind
    // arbitrary future site names or cross comma/newline/quantity boundaries.
    if (end != null) {
      for (final anchor in _anchors) {
        if (anchor.start < end) continue;
        if (anchor.start - end > 48) break;
        final connector = _lower.substring(end, anchor.start);
        if (RegExp(
          r'^[ \t]*(?:at|in|for|within|to|on)[ \t]+(?:the[ \t]+)?$',
        ).hasMatch(connector)) {
          apply(anchor);
          break;
        }
        if (RegExp(r'[,;\n]|\.(?=\s|$)').hasMatch(connector)) break;
      }
    }
    final lineStop = _sentenceBreak.firstMatch(_lower.substring(start));
    final sentenceEnd = lineStop == null
        ? _lower.length
        : start + lineStop.start;
    final sentence = _lower.substring(sentenceStart, sentenceEnd);
    if (_globalInline.hasMatch(sentence)) {
      site = device = vlan = interface = service = null;
      globalTotal = true;
    }
    final roleStart = lastSiteStart > sentenceStart
        ? lastSiteStart
        : sentenceStart;
    final roleText = _lower.substring(
      roleStart.clamp(0, sentenceEnd),
      sentenceEnd,
    );
    final roleMatch = _networkRole.allMatches(roleText).lastOrNull;
    final role = roleMatch == null
        ? ''
        : roleMatch.group(1) ??
              (RegExp(r'^lan[ \t]*\d+$').hasMatch(roleMatch.group(0)!)
                  ? roleMatch.group(0)!.replaceAll(RegExp(r'[ \t]+'), ' ')
                  : roleMatch.group(0)!.split(RegExp(r'[ \t]+')).first);
    return RequirementScopeContext(
      siteId: site,
      deviceId: device,
      vlanId: vlan,
      interfaceId: interface,
      serviceId: service,
      networkRole: role,
      globalTotal: globalTotal,
    );
  }
}

class _ScopeAnchor {
  final int start;
  final int end;
  final String id;
  final RequirementScopeKind kind;
  final bool heading;
  final bool total;

  const _ScopeAnchor({
    required this.start,
    required this.end,
    required this.id,
    required this.kind,
    this.heading = false,
    this.total = false,
  });
}
