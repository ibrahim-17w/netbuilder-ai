import '../../models/network_intent.dart';

/// One extracted slot: what was found and where it was said.
class Slot<T> {
  final String name;
  final T value;
  final int position;

  const Slot(this.name, this.value, this.position);
}

/// The composed result of the slot pipeline over one brief.
class BriefSlots {
  /// Device counts by type, merged from quantity phrases, bare mentions,
  /// explicit labels (R1/SW2/...), per-site clauses and defaults.
  final Map<String, int> counts;

  /// Server roles found, in the order the brief said them.
  final List<String> roles;

  /// True when an AAA/TACACS+/RADIUS ask should provision a server even
  /// though no server count was stated.
  final bool impliesServer;

  /// Per-site counts when the brief names multiple sites (null otherwise).
  final Map<String, int>? perSite;

  /// Number of sites the brief names (null when not a multi-site brief).
  final int? sites;

  /// Routing protocol slot: static/ospf/eigrp/bgp.
  final String routing;

  const BriefSlots({
    required this.counts,
    required this.roles,
    required this.impliesServer,
    this.perSite,
    this.sites,
    this.routing = 'static',
  });

  int count(String type) => counts[type] ?? 0;
}

/// Slot pipeline: composed extractors instead of a pile of competing regexes.
///
/// Each extractor reads the normalized lower-case text and contributes slots;
/// later merge rules (labels raise counts, per-site clauses multiply, defaults
/// fill) are applied here so `parseSimple` consumes one coherent result.
///
/// Behavior-preserving: `parseSimple` delegates to this pipeline and the
/// existing parser suite must pass unmodified.
class BriefSlotPipeline {
  static final _quantity = <String, List<RegExp>>{
    'router': [RegExp(r'\b(\d{1,3})\s*routers?\b')],
    'switch': [RegExp(r'\b(\d{1,3})\s*switch(?:es)?\b')],
    'pc': [RegExp(r'(\d+)\s*pcs?\b')],
    'server': [RegExp(r'(\d+)\s*servers?\b')],
  };

  static const _roleWords = <String, String>{
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
    'tacacs': 'aaa',
    'tacacs+': 'aaa',
  };

  static final _aaaWord =
      RegExp(r'\baaa\b|\btacacs\+?\b|\bradius\b', caseSensitive: false);

  /// Run the full pipeline over a raw brief.
  static BriefSlots extract(String projectName, String rawText) {
    final text = NetworkIntent.bridgeBrief(rawText);
    final lower = text.toLowerCase();

    final counts = extractCounts(lower, text);
    final roles = extractRoles(text);
    final routing = extractRouting(lower);
    final sites = NetworkIntent.siteCount(text);
    final perSite =
        sites == null ? null : NetworkIntent.perSiteCounts(text);

    return BriefSlots(
      counts: counts,
      roles: roles,
      impliesServer: _aaaWord.hasMatch(lower),
      perSite: perSite,
      sites: sites,
      routing: routing,
    );
  }

  /// Device counts: quantity phrases first, then bare mentions (one), then
  /// explicit labels raising the count, then per-site multiplication, then
  /// the everyone-else catalog kinds, then the all-empty default.
  static Map<String, int> extractCounts(String lower, String normText) {
    final counts = <String, int>{};

    // model numbers are not quantities: "Cisco 2911 routers" means 2911 model
    int quantity(String type, List<RegExp> patterns) {
      for (final re in patterns) {
        final m = re.firstMatch(lower);
        if (m != null) return int.parse(m.group(1)!);
      }
      // bare mention means one
      final bare = type == 'pc'
          ? RegExp(r'\bpcs?\b').hasMatch(lower)
          : RegExp('\\b${type}s?\\b').hasMatch(lower);
      return bare ? 1 : 0;
    }

    counts['router'] = quantity('router', _quantity['router']!);
    counts['switch'] = quantity('switch', _quantity['switch']!);
    counts['pc'] = quantity('pc', _quantity['pc']!);
    counts['server'] = quantity('server', _quantity['server']!);

    // every other catalog kind, counted the same way (word-boundary test so
    // a plain contains('ap') never reads 'laptop' as an AP)
    for (final kind in deviceKinds) {
      if (const ['router', 'switch', 'pc', 'server'].contains(kind.type)) {
        continue;
      }
      var n = 0;
      for (final k in kind.keywords) {
        final m = RegExp('(\\d{1,3})\\s*${RegExp.escape(k)}s?\\b')
            .firstMatch(lower);
        if (m != null) {
          n = int.parse(m.group(1)!);
          break;
        }
      }
      if (n == 0 &&
          kind.keywords.any(
            (k) => RegExp('\\b${RegExp.escape(k)}\\b').hasMatch(lower),
          )) {
        n = 1;
      }
      if (n > 0) counts[kind.type] = n;
    }

    // 'wireless' alone still means a wireless network: one AP
    if ((counts['wireless'] ?? 0) == 0 &&
        RegExp(r'\b(wifi|wi-fi|wireless|wlan)\b').hasMatch(lower)) {
      counts['wireless'] = 1;
    }

    // explicit labels are authoritative when the user names devices
    void raiseByLabel(String type, String pattern) {
      final highest = RegExp(pattern)
          .allMatches(normText)
          .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
          .fold(0, (max, v) => v > max ? v : max);
      if (highest > (counts[type] ?? 0)) counts[type] = highest;
    }

    raiseByLabel('router', r'\bR(\d+)\b');
    raiseByLabel('switch', r'\bSW(\d+)\b');
    raiseByLabel('pc', r'\bPC(\d+)\b');
    raiseByLabel('server', r'\bSRV(\d+)\b');

    // per-site clauses can only raise a count, never shrink the plan
    final sites = NetworkIntent.siteCount(normText);
    final perSite =
        sites == null ? null : NetworkIntent.perSiteCounts(normText);
    if (perSite != null) {
      int perSiteTotal(String type) {
        final per = perSite[type] ?? 0;
        if (per <= 0) return counts[type] ?? 0;
        final total = per * sites!;
        return total > (counts[type] ?? 0) ? total : counts[type] ?? 0;
      }

      for (final type in ['router', 'switch', 'pc', 'server']) {
        counts[type] = perSiteTotal(type);
      }
      for (final type in counts.keys.toList()) {
        counts[type] = perSiteTotal(type);
      }
    }

    // all-empty default: a tiny office
    if (!counts.values.any((v) => v > 0)) {
      counts['router'] = 1;
      counts['switch'] = 1;
    }
    return counts;
  }

  /// Server roles in the order the brief said them, sentence by sentence,
  /// with the same distribute-to-"the other" rule the parser applies.
  static List<String> extractRoles(String normText) {
    final found = <String>[];
    final fragments = normText.toLowerCase().split(RegExp(r'[\n.]'));
    for (final frag in fragments) {
      final hits = <MapEntry<int, String>>[];
      _roleWords.forEach((word, role) {
        final at = frag.indexOf(word);
        if (at >= 0) hits.add(MapEntry(at, role));
      });
      hits.sort((a, b) => a.key.compareTo(b.key));
      for (final hit in hits) {
        if (!found.contains(hit.value)) found.add(hit.value);
      }
    }
    return found;
  }

  static String extractRouting(String lower) {
    if (lower.contains('ospf')) return 'ospf';
    if (lower.contains('eigrp')) return 'eigrp';
    if (lower.contains('bgp')) return 'bgp';
    return 'static';
  }
}
