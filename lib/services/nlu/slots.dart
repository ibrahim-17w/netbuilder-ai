import '../../models/network_intent.dart';
import 'lexicon.dart';
import '../domain_vocabulary.dart';

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

  static final _tacacsOrRadius = RegExp(r'\btacacs\+?\b|\bradius\b');

  static final _wifiWord = RegExp(r'\b(wifi|wi-fi|wireless|wlan)\b');

  static final _routerLabel = RegExp(r'\bR(\d+)\b');
  static final _switchLabel = RegExp(r'\bSW(\d+)\b');
  static final _pcLabel = RegExp(r'\bPC(\d+)\b');
  static final _serverLabel = RegExp(r'\bSRV(\d+)\b');

  /// Device counts - the offline parser's own rules, in the parser's own
  /// order, so the app has ONE implementation of "what did this brief ask
  /// for": [NetworkIntent.parseSimple] consumes this map instead of keeping
  /// a second copy that could drift away from it.
  ///
  /// Order matters and mirrors the parser exactly: quantity phrases, bare
  /// mentions, AAA and service roles provisioning a server, the rest of the
  /// catalog, wifi, per-site multiplication, explicit labels, named server
  /// labels, and the tiny-office default.
  static Map<String, int> extractCounts(
    String lower,
    String normText, {
    bool tinyOfficeDefault = true,
  }) {
    final counts = <String, int>{};

    // Every quantity the brief states, clause by clause, so a count split
    // across clauses adds up instead of being read once: see
    // [quantityTotal].
    final records = _quantityRecords(lower);

    // Model numbers are not quantities: "Cisco 2911 routers" means named
    // 2911 routers, not 2911 devices. Router/switch quantities are capped
    // at three digits, exactly as the parser reads them.
    var routerCount = _quantityTotal(records, 'router') ?? 0;
    if (routerCount == 0 && _mentionedBeyondHowMany(lower, const ['router'])) {
      routerCount = 1;
    }
    var switchCount = _quantityTotal(records, 'switch') ?? 0;
    if (switchCount == 0 && _mentionedBeyondHowMany(lower, const ['switch'])) {
      switchCount = 1;
    }
    // A bare "pc" means one, like every other kind: "one PC for testing"
    // asks for a PC whether or not it spells a digit.
    var pcCount = _quantityTotal(records, 'pc') ?? 0;
    if (pcCount == 0 &&
        _mentionedBeyondHowMany(lower, const ['pc', 'computer', 'workstation'])) {
      pcCount = 1;
    }
    var serverCount = _quantityTotal(records, 'server') ?? 0;
    if (serverCount == 0 && _mentionedBeyondHowMany(lower, const ['server'])) {
      serverCount = 1;
    }
    // An AAA/TACACS+/RADIUS ask with no server named still means an AAA
    // server exists to configure - without it the role had no owner.
    if (serverCount == 0 &&
        (lower.contains('aaa') || _tacacsOrRadius.hasMatch(lower))) {
      serverCount = 1;
    }
    // Any service role named with no server count still provisions one -
    // "1 router with dns and http" must not silently drop the services.
    if (serverCount == 0 && _roleWords.keys.any(lower.contains)) {
      serverCount = 1;
    }
    counts['router'] = routerCount;
    counts['switch'] = switchCount;
    counts['pc'] = pcCount;
    counts['server'] = serverCount;

    // every other catalog kind, counted the same way (word-boundary test so
    // a plain contains('ap') never reads 'laptop' as an AP)
    for (final kind in deviceKinds) {
      if (const ['router', 'switch', 'pc', 'server'].contains(kind.type)) {
        continue;
      }
      var n = _quantityTotal(records, kind.type) ?? 0;
      if (n == 0 && _mentionedBeyondHowMany(lower, kind.keywords)) {
        n = 1;
      }
      if (n > 0) counts[kind.type] = n;
    }

    // 'wireless' alone still means a wireless network: one AP
    if ((counts['wireless'] ?? 0) == 0 && _wifiWord.hasMatch(lower)) {
      counts['wireless'] = 1;
    }

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

    // MULTI-SITE COMPLETION: "two physical sites and 50 PCs" describes a
    // network, not a PC farm. When the brief names several sites, states no
    // per-site breakdown ("each with ...") and carries no infrastructure
    // of its own, each site gets a router and its share of access switches
    // so the plan matches the multi-site network that was described. The
    // parser adds the matching assumption and question to the plan.
    if (completesMultiSite(lower, normText)) {
      final sites = NetworkIntent.siteCount(normText)!;
      var endpoints = 0;
      for (final t in const ['pc', 'server', 'phone', 'printer', 'laptop']) {
        endpoints += counts[t] ?? 0;
      }
      final perSiteEndpoints = (endpoints + sites - 1) ~/ sites;
      final switchesPerSite =
          perSiteEndpoints <= 22 ? 1 : (perSiteEndpoints + 21) ~/ 22;
      counts['router'] = sites;
      counts['switch'] = sites * switchesPerSite;
    }

    // explicit labels are authoritative when the user names devices
    void raiseByLabel(String type, RegExp pattern) {
      final highest = pattern
          .allMatches(normText)
          .map((m) => int.tryParse(m.group(1) ?? '') ?? 0)
          .fold(0, (max, v) => v > max ? v : max);
      if (highest > (counts[type] ?? 0)) counts[type] = highest;
    }

    raiseByLabel('router', _routerLabel);
    raiseByLabel('switch', _switchLabel);
    raiseByLabel('pc', _pcLabel);
    raiseByLabel('server', _serverLabel);

    // Servers the brief names one by one ("DHCP1, DNS1, WEB1, AAA1, FTP1
    // and MAIL1") are the authoritative count as well as the names.
    final namedServers = NetworkIntent.namedServerLabels(normText);
    if (namedServers.length > (counts['server'] ?? 0)) {
      counts['server'] = namedServers.length;
    }

    // all-empty default: a tiny office. Only the four kinds count here,
    // exactly as the parser applies it: "2 firewalls" with no router still
    // gets its router and switch. A caller counting a CORRECTION fragment
    // ("actually 8 pcs") opts out: the kinds the correction did not name
    // must stay with the standing lab, not grow an office out of nothing.
    if (tinyOfficeDefault &&
        (counts['router'] ?? 0) == 0 &&
        (counts['switch'] ?? 0) == 0 &&
        (counts['pc'] ?? 0) == 0 &&
        (counts['server'] ?? 0) == 0) {
      counts['router'] = 1;
      counts['switch'] = 1;
    }
    return counts;
  }

  /// The kind the brief counted LAST, or null when it counted nothing.
  ///
  /// A bare correction ("actually 8") names no kind of its own; it corrects
  /// the kind the conversation was last talking about - the same recency the
  /// elliptical quantities ("... and the ground floor 4") already resolve
  /// by. "2 routers, 2 switches and 50 PCs, actually 8" is eight PCs.
  static String? lastCountedKind(String lower) {
    final records = _quantityRecords(lower);
    for (var i = records.length - 1; i >= 0; i--) {
      if (records[i].value > 0) return records[i].kind;
    }
    return null;
  }

  static final _fragmentSplit = RegExp(r'[\n.]');

  /// Server roles in the order the brief said them, sentence by sentence,
  /// with the same distribute-to-"the other" rule the parser applies.
  static List<String> extractRoles(String normText) {
    final found = <String>[];
    final fragments = normText.toLowerCase().split(_fragmentSplit);
    for (final frag in fragments) {
      final hits = <MapEntry<int, String>>[];
      _roleWords.forEach((word, role) {
        final at = frag.indexOf(word);
        if (at >= 0) hits.add(MapEntry(at, role));
      });
      // Everyday words for the same services: "a website" is http, "login
      // accounts" is aaa, "shared folders" is ftp. Longest first, so "web
      // server" is not read as the bare word "web" standing in for http.
      final everyday = <String, List<String>>{
        for (final entry in DomainVocabulary.everydayServiceWords().entries)
          entry.key: entry.value,
      };
      everyday.forEach((role, words) {
        for (final word in words) {
          final at = frag.indexOf(word);
          if (at >= 0) hits.add(MapEntry(at, role));
        }
      });
      hits.sort((a, b) => a.key.compareTo(b.key));
      for (final hit in hits) {
        if (!found.contains(hit.value)) found.add(hit.value);
      }
    }
    return found;
  }

  static String extractRouting(String lower) =>
      NetworkIntent.resolveRouting(lower) ?? 'static';

  /// How many routers each site of a multi-site brief asked for, in the order
  /// the brief named the sites.
  ///
  /// "Site A ... with 2 routers ... Site B is a branch with 1 router" reads as
  /// `[2, 1]`. Nodes are created in that same order (R1 and R2 are Site A's,
  /// R3 is the branch's), so this is what lets the addressing step place a
  /// subnet the brief qualified with a site word - "192.168.20.0/24 at the
  /// branch" - on the LAN that site actually owns, instead of handing it to
  /// whichever LAN link happened to come second.
  ///
  /// An empty list means the brief did not split its routers by site (a
  /// single-site brief, or one that names no site at all).
  static List<int> siteRouterCounts(String normText) {
    final lower = NetworkIntent.bridgeBrief(normText).toLowerCase();
    final records = _quantityRecords(lower);
    final order = <String>[];
    for (final r in records) {
      if (r.kind == 'router' && r.site != null && !order.contains(r.site)) {
        order.add(r.site!);
      }
    }
    final out = <int>[];
    for (final label in order) {
      var total = 0;
      for (final r in records) {
        if (r.kind != 'router' || r.site != label) continue;
        // Same rule [quantityTotal] applies inside one site: a repeat
        // restates the count rather than adding to it.
        total = r.correction ? r.value : (r.add ? total + r.value : (r.value > total ? r.value : total));
      }
      if (total > 0) out.add(total);
    }
    return out;
  }

  // --- quantities across clauses ------------------------------------------

  static final _routerQty = RegExp(
    r'\b(\d{1,3})\s*(?:(?:more|extra|additional|further)\s+)?'
    r'routers?\b',
  );

  static final _switchQty = RegExp(
    r'\b(\d{1,3})\s*(?:(?:more|extra|additional|further)\s+)?'
    r'switch(?:es)?\b',
  );

  static final _pcQty = RegExp(
    r'(\d+)\s*(?:(?:more|extra|additional|further)\s+)?'
    r'(?:pcs?|computers?|workstations?)',
  );

  static final _serverQty = RegExp(
    r'(\d+)\s*(?:(?:more|extra|additional|further)\s+)?servers?',
  );

  static final Map<String, RegExp> _keywordQty = {
    for (final kind in deviceKinds)
      for (final k in kind.keywords)
        k: RegExp(
          '(\\d{1,3})\\s*(?:(?:more|extra|additional|further)\\s+)?'
          '${RegExp.escape(k)}s?\\b',
        ),
  };

  /// One quantity the brief stated for a device kind: the number, the kind
  /// it names, where it was said, and how it relates to the kind's other
  /// amounts (which site it belongs to, whether it corrects an earlier
  /// number, whether it is announced as an addition).
  static List<_Qty> _quantityRecords(String lower) {
    final clauses = _clauses(lower);
    final anchors = _siteAnchors(lower);
    final records = <_Qty>[];

    void scan(String type, RegExp pattern) {
      for (final m in pattern.allMatches(lower)) {
        final at = m.start;
        final clause = _clauseOf(clauses, at);
        final local = at - clause.start;
        // "not 6 access points" states a number to REJECT, not a count.
        if (_negationBefore(clause.text, local)) continue;
        // "more than 2 switches" asks for at least three: planning the
        // stated number would make the lab SMALLER than what was asked for.
        final moreThan = _moreThanBefore(clause.text, local);
        records.add(
          _Qty(
            kind: type,
            value: int.parse(m.group(1)!) + (moreThan ? 1 : 0),
            at: at,
            site: _siteAt(lower, anchors, at),
            correction: _correctionBefore(clause.text, local),
          ),
        );
      }
    }

    // The kind's own quantity phrases, in the parser's own patterns: the
    // first phrase of a kind is read exactly as the parser always read it,
    // and every further phrase is weighed by [quantityTotal]'s merge rules.
    for (final kind in deviceKinds) {
      switch (kind.type) {
        case 'router':
          scan(kind.type, _routerQty);
          break;
        case 'switch':
          scan(kind.type, _switchQty);
          break;
        case 'pc':
          scan(kind.type, _pcQty);
          break;
        case 'server':
          scan(kind.type, _serverQty);
          break;
        default:
          for (final k in kind.keywords) {
            scan(kind.type, _keywordQty[k]!);
          }
      }
    }
    records.sort((a, b) => a.at.compareTo(b.at));
    _dedupeAt(records);

    // Everyday words that name a device: "15 staff", "8 guest laptops",
    // "3 websites". Without this those counts were simply dropped, so the
    // devices a person actually talked about never reached the plan.
    //
    // Deliberately ADDITIVE: a word the technical patterns already read is
    // skipped, so every brief phrased in network terms resolves exactly as it
    // always did. Only words the pipeline had never heard of are picked up
    // here, and they go through the same quantity, negation, correction and
    // per-site rules as everything else - "not 8 staff" is a number to reject,
    // not a count.
    _scanEverydayDeviceWords(records, lower, clauses);

    // Elliptical quantities: "the ground floor 4", "4 on the ground floor",
    // "and 4 more" state a number without a device word of their own. They
    // finish the count of the kind the brief was just talking about, which
    // is what makes "the second floor needs 6 access points and the ground
    // floor 4" add up to 10 instead of stopping at 6.
    for (final clause in clauses) {
      final text = clause.text.trim();
      if (text.isEmpty) continue;
      final lowerClause = clause.text.toLowerCase();
      if (NetworkIntent.namesAnyDeviceIn(lowerClause)) continue;
      final shape = _ellipse(text);
      if (shape == null) continue;
      _Qty? last;
      for (final r in records) {
        if (r.at < clause.start) last = r;
      }
      if (last == null) continue;
      records.add(
        _Qty(
          kind: last.kind,
          value: shape.value,
          at: clause.start,
          site: shape.site,
          correction: shape.correction,
          add: shape.add,
        ),
      );
    }
    return records;
  }

  static final _pluralSuffix = RegExp(r'(s|x|z|ch|sh)$');

  /// Quantity patterns for the everyday device words. The vocabulary can
  /// learn new words mid-session, so each is compiled on first sight and
  /// kept for every parse after that.
  ///
  /// The `RegExp` below is the ONE construction left inside a function body,
  /// and it is not a per-call one: it is the `putIfAbsent` initializer for a
  /// map that is itself `static final`, so it runs once in the app's lifetime
  /// per word and the compiled pattern is handed to every parse after that.
  /// It cannot be hoisted to a `static final` the way the fixed patterns are,
  /// because the pattern is built from a word the vocabulary learned at
  /// runtime - the very case the fixed patterns above cannot cover.
  static final Map<String, RegExp> _everydayQty = {};

  static RegExp _everydayPattern(String word) => _everydayQty.putIfAbsent(
        word,
        () => RegExp(
          // The head is raw so \b and \s stay regex escapes; the tail is a
          // NORMAL string because that is the only kind that interpolates
          // (Dart raw strings do not), so its backslash is doubled. Writing
          // '\b' there instead would put a backspace character in the pattern
          // and the word would silently never match.
          //
          // The plural is optional because a brief counts the plural far more
          // often than the singular - "6 kiosks", "15 staff" - and a pattern
          // that only knew the singular dropped every one of them.
          r'\b(\d{1,3})\s*(?:(?:more|extra|additional|further)\s+)?'
          '${RegExp.escape(word)}'
          '${_pluralSuffix.hasMatch(word) ? '(?:es)?' : 's?'}'
          '\\b',
        ),
      );

  /// Records a quantity for every everyday word in the brief that names a
  /// device the technical patterns never had a phrase for.
  ///
  /// A word is skipped when the technical catalog already reads it - `pc`,
  /// `server`, `laptop` all have their own patterns, and counting them twice
  /// would make the merge rules do arithmetic nobody asked for. What is left
  /// is only the everyday phrasing, and it resolves through exactly the same
  /// clause, negation and correction rules as everything else.
  ///
  /// Overlapping readings are resolved BEFORE anything is recorded. "4 guest
  /// laptops" is read twice - once as the group word `guest` (which implies a
  /// computer) and once as the real noun `laptops` - and recording both
  /// planned 4 laptops AND 4 PCs for the same four people. The longer reading
  /// is the specific one and the shorter is the fallback, so the shorter is
  /// the one dropped.
  static void _scanEverydayDeviceWords(
    List<_Qty> records,
    String lower,
    List<({int start, String text})> clauses,
  ) {
    final technical = <String>{
      for (final kind in deviceKinds)
        for (final word in kind.keywords) word.toLowerCase(),
    };

    final candidates =
        <({int from, int to, String kind, int value, int at, String? site,
            bool correction})>[];
    for (final entry in DomainVocabulary.everydayDeviceWords().entries) {
      if (!deviceKinds.any((k) => k.type == entry.key)) continue;
      for (final word in entry.value) {
        if (technical.contains(word)) continue;
        final pattern = _everydayPattern(word);
        for (final m in pattern.allMatches(lower)) {
          final at = m.start;
          final clause = _clauseOf(clauses, at);
          final local = at - clause.start;
          if (_negationBefore(clause.text, local)) continue;
          final moreThan = _moreThanBefore(clause.text, local);
          candidates.add((
            from: at,
            to: m.end,
            kind: entry.key,
            value: int.parse(m.group(1)!) + (moreThan ? 1 : 0),
            at: at,
            site: _siteAt(lower, _siteAnchors(lower), at),
            correction: _correctionBefore(clause.text, local),
          ));
        }
      }
    }

    // Longest reading first, so a specific word claims its span before the
    // general one gets a chance to. Two readings of the SAME quantity both
    // start at the same digit, so the longer phrase is always the one that
    // names the real device.
    candidates.sort((a, b) {
      final byLength = (b.to - b.from).compareTo(a.to - a.from);
      if (byLength != 0) return byLength;
      return a.from.compareTo(b.from);
    });
    final claimed = <int>{};
    for (final c in candidates) {
      var overlaps = false;
      for (var i = c.from; i < c.to; i++) {
        if (claimed.contains(i)) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) continue;
      for (var i = c.from; i < c.to; i++) {
        claimed.add(i);
      }
      records.add(
        _Qty(
          kind: c.kind,
          value: c.value,
          at: c.at,
          site: c.site,
          correction: c.correction,
        ),
      );
    }
  }

  /// The count a kind adds up to across the brief, or null when no quantity
  /// named it.
  ///
  /// Merge rules, in the order they are applied:
  ///
  /// * a correction ("actually 8") replaces everything counted before it;
  /// * a quantity for the SAME site the kind was already counted for is a
  ///   restatement (or a correction of that site) and replaces that site's
  ///   number rather than adding to it;
  /// * a quantity announced as an addition ("and 4 more") adds;
  /// * a quantity naming a DIFFERENT site adds - each site needs its own
  ///   count - unless the whole total was restated unlabeled first and the
  ///   sites distribute it exactly ("6 access points: 3 upstairs and 3
  ///   downstairs" is still 6);
  /// * an unlabeled repeat is a restatement and adds nothing.
  static int? _quantityTotal(List<_Qty> records, String type) {
    final own = [for (final r in records) if (r.kind == type) r];
    if (own.isEmpty) return null;
    var base = own.first.value;
    String? baseLabel = own.first.site;
    final sites = <String, int>{};
    var extra = 0;
    for (final r in own.skip(1)) {
      if (r.correction) {
        base = r.value;
        if (r.site != null) baseLabel = r.site;
        sites.clear();
        extra = 0;
        continue;
      }
      if (baseLabel != null && r.site == baseLabel) {
        // A repeat inside the SAME site is a restatement, so it replaces the
        // number - but it may never make the lab smaller. A parenthetical role
        // list ("3 Server-PT devices (1 DHCP server, 1 AAA server, 1 DNS
        // server)") states how many devices there are and then which roles
        // they run; reading the "1"s as restatements replaced 3 with 1 and
        // threw two requested servers away. Shrinking on purpose is still
        // possible - it is what a correction says, and that is handled above.
        base = r.add ? base + r.value : (r.value > base ? r.value : base);
        continue;
      }
      if (r.add) {
        final site = r.site;
        if (site != null) {
          sites[site] = (sites[site] ?? 0) + r.value;
        } else {
          extra += r.value;
        }
        continue;
      }
      final site = r.site;
      if (site != null) {
        // An unlabeled total restated as a site count of the same number is
        // a restatement, not a new site.
        if (baseLabel == null && r.value == base) continue;
        sites[site] = r.value;
        continue;
      }
      // Unlabeled repeat: a restatement, deliberately not counted twice.
    }
    if (baseLabel == null && extra == 0 && sites.isNotEmpty) {
      var sum = 0;
      for (final v in sites.values) {
        sum += v;
      }
      // The sites exactly distribute the stated total ("6 access points: 3
      // upstairs, 3 downstairs") - the total stands, nothing is added.
      if (sum == base) return base;
    }
    var total = base + extra;
    for (final v in sites.values) {
      total += v;
    }
    return total;
  }

  static void _dedupeAt(List<_Qty> records) {
    final seen = <int>{};
    records.removeWhere((r) => !seen.add(r.at));
  }

  static final _clauseSegment = RegExp(r'[^,;.\n]+');
  static final _clauseCoordinator = RegExp(r'\b(?:and|but)\b');

  /// Clause runs with positions. Sentence breaks, commas and the
  /// coordinators "and"/"but" are boundaries, because a quantity stated in
  /// a second coordinated clause ("... and the ground floor 4") belongs to
  /// that clause's site rather than to the first phrase.
  static List<({int start, String text})> _clauses(String lower) {
    final out = <({int start, String text})>[];
    for (final seg in _clauseSegment.allMatches(lower)) {
      final s = seg.group(0)!;
      var from = 0;
      for (final m in _clauseCoordinator.allMatches(s)) {
        out.add((start: seg.start + from, text: s.substring(from, m.start)));
        from = m.end;
      }
      out.add((start: seg.start + from, text: s.substring(from)));
    }
    return out;
  }

  static ({int start, String text}) _clauseOf(
    List<({int start, String text})> clauses,
    int at,
  ) {
    var best = clauses.first;
    for (final c in clauses) {
      if (c.start <= at) best = c;
    }
    return best;
  }

  /// A site/space phrase: "second floor", "ground floor", "branch
  /// offices", "Site A". The leading word keeps two sites of the same kind
  /// distinct, and a short trailing designator keeps "Site A" and "Site B"
  /// apart - without it two labelled sites collapsed onto one label and the
  /// second site's count replaced the first instead of adding to it.
  static final RegExp _siteWord = RegExp(
    r'\b(?:(ground|first|second|third|fourth|fifth|sixth|seventh|eighth|'
    r'ninth|tenth|top|upper|lower|main|front|back|branch|left|right|north|'
    r'south|east|west)\s+)?'
    r'(floor|office|branch|site|building|classroom|room|department|location)'
    r'(?:es|s)?(?:\s+([a-z0-9]{1,2})\b)?',
    caseSensitive: false,
  );

  /// Every place the brief named a site, with the label it named.
  static List<({int at, String label})> _siteAnchors(String lower) {
    final out = <({int at, String label})>[];
    for (final m in _siteWord.allMatches(lower)) {
      final adj = m.group(1);
      final site = m.group(2)!;
      final designator = m.group(3);
      out.add((
        at: m.end,
        label: designator == null
            ? (adj == null ? site : '$adj $site')
            : '${adj == null ? site : '$adj $site'} $designator',
      ));
    }
    return out;
  }

  static final _sentenceBreak = RegExp(r'[.;\n]');

  /// The site a quantity at [at] belongs to, or null when it names none.
  ///
  /// A site's device list is split across clauses by the commas and the "and"
  /// ("Site A has 2 routers, 2 switches, 3 servers and 15 PCs"), and only the
  /// fragment that happens to contain the site word kept its label.  Every
  /// later fragment was read as an unlabeled repeat - a restatement - and
  /// dropped, so 15 of 25 PCs silently vanished.  The label therefore travels
  /// FORWARD through the fragments of one sentence, and a full stop ends it:
  /// "…at HQ. The branch has 2 PCs" is a second site, not a restatement of
  /// the first, and that distinction is what keeps them from being merged.
  static String? _siteAt(
    String lower,
    List<({int at, String label})> anchors,
    int at,
  ) {
    for (var i = anchors.length - 1; i >= 0; i--) {
      final anchor = anchors[i];
      if (anchor.at > at) continue;
      if (_sentenceBreak.hasMatch(lower.substring(anchor.at, at))) return null;
      return anchor.label;
    }
    return null;
  }

  /// "actually", "make it", "use" - the number that follows restates or
  /// replaces what was counted before instead of adding to it.
  static final RegExp _correctionCue = RegExp(
    r'\b(actually|rather|no\s+wait|i\s+mean|correction|use|set\s+it\s+to|'
    r'make\s+it)\b',
  );

  /// True when a correction cue stands IN FRONT of the number, in the same
  /// clause: "actually 8", "make it 16 PCs", "use 2 routers".
  ///
  /// The cue was matched against the whole clause, so a cue that followed the
  /// number fired too - and one of those cues is "use". A brief ending
  /// "... and 10 PCs. Use 192.168.10.0/24 at HQ" then read its LAST PC count
  /// as a correction and replaced the four earlier site counts with it: "40
  /// users across 2 sites ... 15 PCs ... 10 PCs" planned 10 PCs instead of
  /// 25, and the summary the user read described a network they never asked
  /// for. A cue that comes after a quantity is describing something else
  /// ("use 192.168..." is addressing, not a count), so only the text before
  /// the number can make it a correction.
  static bool _correctionBefore(String clause, int at) =>
      _correctionCue.hasMatch(clause.substring(0, at.clamp(0, clause.length)));

  static final RegExp _infraWords = RegExp(r'\brouters?\b|\bswitch(?:es)?\b');
  static final RegExp _anyBulkEndpoints = RegExp(
    r'\b(?:[2-9]|\d{2,})\s*(?:pcs?|servers?|phones?|printers?|laptops?)\b',
  );
  static const List<String> _wiredKindWords = [
    'pc',
    'server',
    'phone',
    'printer',
    'laptop',
  ];
  static final List<RegExp> _wiredKindPatterns = [
    for (final k in _wiredKindWords) RegExp('\\b$k(?:es|s)?\\b'),
  ];

  /// True when the brief describes several sites with wired devices but
  /// neither a per-site breakdown ("each with ...") nor any router or
  /// switch of its own: the stated counts are totals and each site is given
  /// a router and its share of access switches (see [extractCounts]).
  static bool completesMultiSite(String lower, String normText) {
    final sites = NetworkIntent.siteCount(normText);
    if (sites == null || sites < 2) return false;
    // "each with a router" is a per-site SPEC the parser already multiplies.
    if (NetworkIntent.perSiteCounts(normText) != null) return false;
    // Routers or switches of its own: whatever the brief described is kept.
    if (_infraWords.hasMatch(lower)) return false;
    if (_anyBulkEndpoints.hasMatch(lower)) return true;
    // Two or more wired kinds named is a network worth splitting.
    var kinds = 0;
    for (final pattern in _wiredKindPatterns) {
      if (pattern.hasMatch(lower)) kinds++;
    }
    return kinds >= 2;
  }

  static final RegExp _moreThanTail = RegExp(r'\b(?:more\s+than|over)\s*$');

  /// "more than 2", "over 2" directly in front of a number: the stated
  /// value is a lower bound, so the count is read as one more than stated.
  static bool _moreThanBefore(String clause, int at) {
    final head = clause.substring(0, at.clamp(0, clause.length));
    return _moreThanTail.hasMatch(head);
  }

  static final RegExp _howManyWord =
      RegExp(r'how\s+many', caseSensitive: false);

  static final Map<String, RegExp> _mentionByWord = {
    for (final w in const [
      'router',
      'switch',
      'pc',
      'computer',
      'workstation',
      'server',
    ])
      w: RegExp('\\b${RegExp.escape(w)}(?:es|s)?\\b'),
    for (final kind in deviceKinds)
      for (final w in kind.keywords)
        w: RegExp('\\b${RegExp.escape(w)}(?:es|s)?\\b'),
  };

  /// True when at least one mention of this kind is NOT part of a "how
  /// many ..." question. "i don't know how many phones" asks ABOUT phones
  /// instead of asking FOR them, so the bare mention must not become a
  /// device - the parser answers with a question instead (see
  /// `NetworkIntent._howManyQuestions`).
  static bool _mentionedBeyondHowMany(String lower, List<String> keywords) {
    for (final k in keywords) {
      for (final m in _mentionByWord[k]!.allMatches(lower)) {
        final from = m.start - 40 < 0 ? 0 : m.start - 40;
        if (!_howManyWord.hasMatch(lower.substring(from, m.start))) {
          return true;
        }
      }
    }
    return false;
  }

  static final RegExp _negationTail = RegExp(
    r'\b(?:not|no|never|instead\s+of|rather\s+than|without)\b'
    r'[^,;.]{0,14}$',
  );

  /// "not 6 access points" writes a number to reject. Negation binds to the
  /// nearest few words, not across a clause break.
  static bool _negationBefore(String clause, int at) {
    final head = clause.substring(0, at.clamp(0, clause.length));
    return _negationTail.hasMatch(head);
  }

  /// The elliptical shapes' own pieces, hoisted out of [_ellipse] so the
  /// pattern is compiled once instead of on every call.
  static final String _ellipseAdjacent = r'(?:ground|first|second|third|'
      r'fourth|fifth|sixth|top|upper|'
      r'lower|main|front|back|branch|left|right|north|south|east|west)';
  static const String _ellipseSiteWord = r'(?:floor|office|branch|site|'
      r'building|classroom|room|'
      'department|location)(?:es|s)?';
  static final RegExp _ellipseNumberFirst = RegExp(
    '^\\s*(?:and\\s+)?(\\d{1,3})\\s*(?:(more|extra|additional|further)\\s*)?'
    '(?:on|in|at|for|to)\\s+(?:(?:the|our|its)\\s+)?(?:($_ellipseAdjacent)\\s+)?'
    '($_ellipseSiteWord)\\s*\$',
    caseSensitive: false,
  );
  static final RegExp _ellipseSiteFirst = RegExp(
    '^\\s*(?:and\\s+)?(?:(?:the|our|its)\\s+)(?:($_ellipseAdjacent)\\s+)?'
    '($_ellipseSiteWord)\\s*'
    '(?:(?:also|then|still|needs?|has|having|gets?|takes?|wants?|with|'
    'holds?|will\\s+have)\\s+)*(\\d{1,3})\\s*(?:(more|extra|additional|'
    'further)\\s*)?\$',
    caseSensitive: false,
  );
  static final RegExp _ellipseMoreOnly = RegExp(
    r'^\s*(?:and\s+)?(\d{1,3})\s+(more|extra|additional|further)\s*$',
    caseSensitive: false,
  );
  static final RegExp _ellipseCorrection = RegExp(
    r'^\s*(?:and\s+)?(actually|rather|no\s+wait|i\s+mean|correction)\s*,?\s*(\d{1,3})\s*$',
    caseSensitive: false,
  );
  static final RegExp _pluralTail = RegExp(r'(es|s)$');

  /// One elliptical quantity shape, or null. The shapes are deliberately
  /// strict - they only accept a clause that is a number plus a site phrase
  /// (or a bare "... and 2 more") - so random numbers elsewhere in a brief
  /// are never folded into a device count.
  static ({int value, String? site, bool add, bool correction})? _ellipse(
    String text,
  ) {
    String? label(String? adj, String site) =>
        adj == null ? site : '${adj.toLowerCase()} $site';
    // "4 on the ground floor", "4 for the second floor"
    final numberFirst = _ellipseNumberFirst.firstMatch(text);
    if (numberFirst != null) {
      return (
        value: int.parse(numberFirst.group(1)!),
        site: label(
          numberFirst.group(3),
          numberFirst.group(4)!.replaceAll(_pluralTail, ''),
        ),
        add: numberFirst.group(2) != null,
        correction: false,
      );
    }

    // "the ground floor 4", "the second floor needs 4"
    final siteFirst = _ellipseSiteFirst.firstMatch(text);
    if (siteFirst != null) {
      return (
        value: int.parse(siteFirst.group(3)!),
        site: label(
          siteFirst.group(1),
          siteFirst.group(2)!.replaceAll(_pluralTail, ''),
        ),
        add: siteFirst.group(4) != null,
        correction: false,
      );
    }

    // "and 4 more"
    final moreOnly = _ellipseMoreOnly.firstMatch(text);
    if (moreOnly != null) {
      return (
        value: int.parse(moreOnly.group(1)!),
        site: null,
        add: true,
        correction: false,
      );
    }

    // "actually 8" (a correction with no device word of its own)
    final correction = _ellipseCorrection.firstMatch(text);
    if (correction != null) {
      return (
        value: int.parse(correction.group(2)!),
        site: null,
        add: false,
        correction: true,
      );
    }
    return null;
  }
}

/// One quantity record (see [BriefSlotPipeline._quantityRecords]).
class _Qty {
  final String kind;
  final int value;
  final int at;
  final String? site;
  final bool correction;
  final bool add;
  const _Qty({
    required this.kind,
    required this.value,
    required this.at,
    this.site,
    this.correction = false,
    this.add = false,
  });
}
