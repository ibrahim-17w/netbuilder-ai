import 'casual_english.dart';
import 'network_math.dart';
import 'network_tools.dart';
import 'networking_language.dart';
import 'networking_calculators.dart';
import 'networking_catalog.dart';
import 'networking_consultant.dart';
import 'networking_design.dart';
import 'networking_fact_book.dart';
import 'networking_playbooks.dart';
import 'networking_triage.dart';

/// One answer from [NetworkingIntellect], with enough provenance for the chat
/// to route quick replies and for tests to name what was claimed.
class IntellectAnswer {
  final String text;

  /// Matches the `AssistantReply.intent` vocabulary: `howto` for everything
  /// this layer answers, because it answers questions rather than changing a
  /// plan.
  final String intent;

  /// The catalog id or calculator name that produced the answer.
  final String topic;

  const IntellectAnswer(this.text, {this.intent = 'howto', this.topic = ''});
}

/// The senior-engineer layer: deterministic networking reasoning that runs
/// with no model and no API key.
///
/// Three things make an answer feel like an engineer wrote it, and this class
/// does all three:
///
/// * it computes. Route selection, VLSM, subnet splitting, membership,
///   wildcards, BDP, MSS and summarization are arithmetic, so the numbers come
///   out of [NetworkMath]/[NetworkTools] instead of being described.
/// * it compares. Two named technologies get a dimension-by-dimension answer
///   from [networkCatalog], not two separate blurbs stapled together.
/// * it answers the shape that was asked. "What is", "why", "how do I
///   configure", "when should I use" and "it is broken" pull different fields
///   out of the same entry.
///
/// It stays out of the way on purpose: purchase and design advice belongs to
/// [AdvisorService], build requests belong to the planner, and a
/// `conceptOwned` entry only answers a named aspect so the existing concept
/// explainers keep their pinned answers.
class NetworkingIntellect {
  const NetworkingIntellect._();

  // --- entry point ---------------------------------------------------------

  static IntellectAnswer? answer(String rawText) {
    final raw = rawText.trim().toLowerCase();
    final canon = CasualEnglish.canonical(raw);
    // The third form is how a person speaks, not how a ticket title reads:
    // "our bgp keeps bouncing" gains "flapping", "neighbours" becomes
    // "neighbors", "keep alive" becomes "keepalive". Every corpus below is
    // indexed by the technical phrasing, so this is what makes the corpus
    // reachable from ordinary English - and it is a deterministic table, not
    // a model guess.
    final t = NetworkingLanguage.understand(canon);
    if (t.isEmpty) return null;
    // Fault and reference matching reads all three forms. Canonicalisation
    // helpfully rewrites phrases like "link down" and "broadcast storm" into
    // concept triggers, which is right for the concept layer and wrong for a
    // diagnosis: the symptom word is the evidence. The understood form adds
    // the canonical symptom without removing the words the user typed.
    final evidence = raw == t && canon == t ? t : '$raw\n$canon\n$t';

    // Calculations first: a subnet question is not advice, and the number is
    // the whole answer.
    final calc = _calculation(t);
    if (calc != null) return calc;

    // APP ACTIONS BELONG TO ChatCapabilities. "any duplicate ips?" is a check
    // on the open plan, not a lesson about intrusion prevention - and the
    // plural "ips" would otherwise match the IPS entry.
    if (RegExp(r'\b(?:export|improve|suggestions?)\b').hasMatch(t)) {
      return null;
    }
    // "Validate the plan" is the app action. "How do I validate a VLAN design
    // before rollout" is a design-review question, and the verb is the subject.
    if (RegExp(r'\bvalidate\b').hasMatch(t) &&
        !RegExp(
          r'\bhow\s+(?:do|can|would|should)\s+(?:i|we|you)\b',
        ).hasMatch(t)) {
      return null;
    }
    if (RegExp(r'\bduplicates?\b').hasMatch(t) &&
        RegExp(r'\b(?:any|find|check|show|list)\b').hasMatch(t) &&
        RegExp(r'\b(?:ips?|address(?:es)?)\b').hasMatch(t)) {
      return null;
    }

    // A pasted syslog line and a connected-but-no-internet report are named
    // states with a fixed order of checks. Both are decoded before the topic
    // corpus, so "%OSPF-5-ADJCHG" is not answered as an OSPF definition and
    // "connected but no internet" is not answered as a Wi-Fi join failure.
    final scenario = NetworkingTriage.scenario(evidence);
    if (scenario != null) {
      return IntellectAnswer(scenario.text, topic: scenario.topic);
    }
    final syslog = NetworkingTriage.syslog(evidence);
    if (syslog != null) {
      return IntellectAnswer(syslog.text, topic: syslog.topic);
    }

    // A head-to-head between two named technologies is a comparison, not a
    // fault to diagnose: "netflow vs sflow" must not be answered with the
    // NetFlow-missing playbook just because both words appear in it. It runs
    // before the fault corpus for exactly that reason, and its own gates keep
    // purchase questions out.
    final comparison = _comparison(t);
    if (comparison != null) return comparison;

    // A named fault state has a specific, testable answer, and it must come
    // before topic matching: "bgp neighbour stuck in active" is not a
    // definition question, and answering it with a BGP overview is exactly
    // the generic answer this layer exists to replace.
    //
    // Two independent symptoms are answered as one hypothesis first: a report
    // that names two different failures usually has one shared dependency, and
    // treating them as two tickets is how a fault gets half-fixed twice.
    final playbookMatches = NetworkingPlaybooks.matches(evidence, limit: 5);
    final compound = NetworkingTriage.compound(evidence, playbookMatches);
    if (compound != null) {
      return IntellectAnswer(compound.text, topic: compound.topic);
    }
    if (playbookMatches.isNotEmpty) {
      final playbook = playbookMatches.first.playbook;
      final rendered = NetworkingPlaybooks.render(playbook);
      // The playbook is the ladder; the triage notes are what the user's own
      // wording already proves - one host, everyone, wireless only, since the
      // change. They are appended, never allowed to replace the ladder.
      final notes = NetworkingTriage.annotate(evidence, playbook);
      return IntellectAnswer(
        notes.isEmpty ? rendered : '$rendered\n\n$notes',
        topic: playbook.id,
      );
    }

    // "Where do I start?" is a method question, and it is answered only after
    // a named fault has had its chance at a specific ladder.
    final method = NetworkingTriage.method(evidence);
    if (method != null) {
      return IntellectAnswer(method.text, topic: method.topic);
    }

    // No playbook fits but a change or a boundary was named: those are still
    // stronger than a definition. "Since we changed the MTU, HTTPS hangs" is
    // a change-correlation question even though no single fault state is
    // named, and "only my laptop cannot reach the file server" is answered by
    // what that scope rules out.
    final change = NetworkingTriage.change(evidence);
    if (change != null) {
      return IntellectAnswer(change.text, topic: change.topic);
    }
    final scope = NetworkingTriage.scopeAnswer(evidence);
    if (scope != null) {
      return IntellectAnswer(scope.text, topic: scope.topic);
    }

    // Capacity and architecture questions have arithmetic as their answer:
    // how many calls fit, what the uplink must be, how large the pool is, how
    // many routes a box holds, where L2 stops, how the address plan is carved,
    // which WAN pattern fits the stated sites, and how to migrate without an
    // outage. This layer runs before topic matching so a generic definition
    // cannot replace the number.
    // The design layer owns the number that follows from a stated scale
    // (headcount, area, block, number of ISPs), and it answers before the
    // selection gate because "what QoS markings should I trust" is a policy
    // question, not a product choice. Its own purchase gate keeps buying out.
    final design = NetworkingDesign.answer(evidence);
    if (design != null) {
      return IntellectAnswer(design.text, topic: design.topic);
    }

    // A selection question ("what VPN should I use for two offices") must not
    // be turned into an architecture lecture by the consultant: the advisor
    // owns the choice between products and standards, and it needs the
    // standing plan to answer it.
    if (_selectionAsk.hasMatch(t) &&
        !_judgementAsk.hasMatch(t) &&
        !_technicalBudget.hasMatch(t)) {
      return null;
    }

    final consulting = NetworkingConsultant.answer(evidence);
    if (consulting != null) {
      return IntellectAnswer(consulting.text, topic: consulting.topic);
    }

    final topic = _bestTopic(t);
    // "When should I use VXLAN" is a design question about a technology, not
    // a purchase: it survives the advice gate. So does a head-to-head between
    // two catalog technologies ("should I use OSPF or EIGRP") - that is a
    // technical comparison, and the advisor answers it with one line.
    // Everything else that asks what to buy, whether it is worth it, or how
    // many to order goes to the advisor.
    final designAsk = RegExp(
      r'^when\s+(?:should|do|would)\s+(?:i|we)\s+'
      r'(?:use|choose|pick|deploy|prefer)',
    ).hasMatch(t);
    // A "should I ..." about operating the network - run, enable, monitor,
    // harden - is a judgement call about infrastructure, not a purchase. The
    // advisor owns device and standard selection; the engineer owns whether
    // to run an IGP over the WAN, so a technology verb lets the topic answer.
    final judgementAsk =
        _judgementAsk.hasMatch(t) && !_acquisitionAsk.hasMatch(t);
    final adviceAsk = _adviceAsk.hasMatch(t) || _shouldLead.hasMatch(t);
    if (adviceAsk &&
        !_technicalBudget.hasMatch(t) &&
        !(designAsk && topic != null) &&
        !judgementAsk) {
      return null;
    }

    final questionShaped = _questionShaped(t);
    if (!questionShaped && _buildAsk.hasMatch(t)) return null;
    if (!questionShaped && !_teachAsk.hasMatch(t)) {
      // A complaint with no symptom ("the network is acting weird") used to
      // fall through as unknown. Three scope/layer/time questions are a more
      // honest answer than silence, and they cost nothing to run.
      final vague = NetworkingTriage.vague(evidence);
      if (vague != null) {
        return IntellectAnswer(vague.text, topic: vague.topic);
      }
      return null;
    }

    // Exact numbers, timers and port lists: a reference question deserves the
    // number, not a paragraph that contains it.
    final fact = NetworkingFactBook.answer(evidence);
    if (fact != null) return IntellectAnswer(fact, topic: 'fact');

    // A device count is a build brief. The planner owns it - but only after a
    // reference fact has had its chance, so "a loop between two switches" is
    // still a fact question and "2 routers and 4 switches" is still a brief.
    if (_deviceCount.hasMatch(t)) return null;

    if (topic == null) return null;
    // Some topics already have a concept answer that is pinned by tests and
    // shown by the concept layer. Those only answer a named aspect here -
    // except for an explicit design ask. "When should I use BGP" is not the
    // definition the concept layer pins; it is the when-and-what-it-costs
    // question, and that shape is exactly what the design render exists for.
    if (topic.conceptOwned && !_mentionsAspect(t, topic) && !designAsk) {
      return null;
    }
    return IntellectAnswer(_render(t, topic), topic: topic.id);
  }

  // --- gates ---------------------------------------------------------------

  static final RegExp _cidr = RegExp(
    r'\b\d{1,3}(?:\.\d{1,3}){3}\s*/\s*\d{1,2}\b',
  );
  static final RegExp _ip = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');
  // Allows "/24s" - the plural in "split it into /24s" is not a word
  // boundary, so a trailing \b would silently find no target prefix.
  static final RegExp _prefixOnly = RegExp(r'/\s*(\d{1,2})(?!\d)');

  static final RegExp _deviceCount = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
    r'printers?|phones?|firewalls?|tablets?|access\s+points?|aps?)\b',
  );

  static final RegExp _buildAsk = RegExp(
    r'\b(?:build|set\s+up|setup|create|design|plan|make\s+me|draw|deploy)\b',
  );

  /// Purchase and advice language. The advisor answers these with a
  /// recommendation grounded in the plan, which is a better answer than a
  /// definition.
  static final RegExp _adviceAsk = RegExp(
    r'\b(?:should\s+(?:i|we)|do\s+(?:i|we)\s+need|worth\s+it|'
    r'which\s+(?:is|one\s+is)\s+better|better\s+(?:choice|option|buy)|'
    r'recommend\w*|buy|purchase|price|pricing|budget)\b',
  );

  /// A leading "should" with any subject ("should patients get guest wifi")
  /// is the advisor's question just as much as "should I". "what percent
  /// should QoS give the queue" is not - it is a design number.
  static final RegExp _shouldLead = RegExp(r'^should\s+(?!i\b|we\b)');

  /// "what/which ... should I use/get" is a selection question: the advisor
  /// answers it, not the consultant.
  static final RegExp _selectionAsk = RegExp(
    r'\b(?:what|which)\b[^?]*\bshould\s+(?:i|we)\b',
  );

  /// Verbs that make a "should I" question about running the network rather
  /// than buying for it. Deliberately excludes "use" and "get": "should I use
  /// a 2960 or a 3560" and "which should I get" are advisor questions.
  static final RegExp _judgementAsk = RegExp(
    r'\b(?:run|enable|disable|block|allow|keep|monitor|harden|segment|'
    r'isolate|redistribute|troubleshoot|test|verify|configure|originate|'
    r'flood|advertise|summari[sz]e|check|prepare|audit|document)\b',
  );

  /// Words that make it a purchase or a device-selection decision even when a
  /// judgement verb is present.
  static final RegExp _acquisitionAsk = RegExp(
    r'\b(?:buy|purchase|price|pricing|budget|recommend\w*|worth\s+it|'
    r'get\s+for|which\s+(?:router|switch|firewall|ap|access\s+point|'
    r'model|standard|vendor)\b)',
  );

  /// A technical budget (latency, power, queue) is a specification, not a
  /// purchase: the reference fact owns it even though the word "budget"
  /// otherwise routes to the advisor.
  static final RegExp _technicalBudget = RegExp(
    r'\b(?:latency|delay|jitter|power|poe|queue|bandwidth|time|memory|'
    r'address)\s+budget\b',
  );

  /// Words that mean the message is asking to be taught something, even when
  /// it is not shaped like a question ("tell me about vxlan").
  static final RegExp _teachAsk = RegExp(
    r'\b(?:what|why|how|explain|describe|tell\s+me|difference|compare|'
    r'versus|vs|when\s+to|syntax|commands?|configure|configuration|'
    r'troubleshoot|debug|diagnose|work|works)\b',
  );

  static bool _questionShaped(String t) =>
      t.contains('?') ||
      RegExp(
        r'^(?:how|what|why|when|which|where|is|are|does|do|can|should|'
        r'would|could|will|shall|might|explain|describe|compare|tell)\b',
      ).hasMatch(t);

  // --- calculators ---------------------------------------------------------

  static IntellectAnswer? _calculation(String t) {
    return _routeChoice(t) ??
        _vlsm(t) ??
        _split(t) ??
        _aclMatch(t) ??
        _membership(t) ??
        _wildcard(t) ??
        _prefixForHosts(t) ??
        _hostsInPrefix(t) ??
        _maskForPrefix(t) ??
        _bandwidthDelay(t) ??
        _mss(t) ??
        _scope(t) ??
        _summarize(t) ??
        _rangeToCidrs(t) ??
        _seniorCalculation(t);
  }

  /// Arithmetic that belongs to its own module: subnet counts, block
  /// boundaries, IGP metrics, spanning-tree cost, tunnel MTU, PoE budget and
  /// transfer time. It runs after the calculators above so the answers that
  /// already exist keep their exact shape, and before every matcher because a
  /// computed number beats a remembered one.
  static IntellectAnswer? _seniorCalculation(String t) {
    final calc = NetworkingCalculators.answer(t);
    if (calc == null) return null;
    return IntellectAnswer(calc.text, topic: calc.topic);
  }

  /// Which of two routes the router installs. The answer is longest-prefix
  /// first, administrative distance only for the same prefix.
  static IntellectAnswer? _routeChoice(String t) {
    final cidrs = _cidrs(t);
    if (cidrs.length < 2) return null;
    final info0 = NetworkTools.subnet(cidrs[0]);
    final info1 = NetworkTools.subnet(cidrs[1]);
    if (info0 == null || info1 == null) return null;

    final routed =
        RegExp(
          r'\b(?:wins?|winning|preferred|prefer|chosen|select\w*|'
          r'installed|install|longest|which\s+route|route\s+selected)\b',
        ).hasMatch(t) ||
        (RegExp(r'\bwhich\b').hasMatch(t) && RegExp(r'\broute\b').hasMatch(t));
    if (!routed) return null;

    if (info0.prefix != info1.prefix) {
      final info0IsNarrower = info0.prefix > info1.prefix;
      final narrower = info0IsNarrower ? info0 : info1;
      final wider = info0IsNarrower ? info1 : info0;
      final narrowerCidr = '${narrower.network}/${narrower.prefix}';
      final widerCidr = '${wider.network}/${wider.prefix}';

      if (NetworkTools.contains(widerCidr, narrower.network)) {
        return IntellectAnswer(
          '$narrowerCidr wins, for every destination inside it.\n\n'
          '- Longest prefix match runs before administrative distance and '
          'before the metric: a /${narrower.prefix} always beats a '
          '/${wider.prefix} for an address that matches both, whichever '
          'protocol or distance produced each one.\n'
          '- $widerCidr is still used for destinations outside '
          '$narrowerCidr - a summary and a more specific route are supposed '
          'to coexist.\n'
          '- If the more specific route disappears, the router falls back to '
          '$widerCidr, which is exactly why the summary is there.\n\n'
          'For a destination address, the test is: mask the address with each '
          'mask and keep the longest match, then break a tie with distance, '
          'then with the protocol metric.',
          topic: 'route-choice',
        );
      }
      return IntellectAnswer(
        'These two are not competing: neither prefix contains the other, so '
        'each is used only for its own destinations.\n\n'
        '- $narrowerCidr is used inside $narrowerCidr.\n'
        '- $widerCidr is used inside $widerCidr.\n'
        '- The router only compares routes for the *same* destination '
        'prefix; for different prefixes the longest match wins by definition.\n\n'
        'If you expected one to override the other, check whether the two '
        'prefixes really overlap - if they do, the longer mask wins.',
        topic: 'route-choice',
      );
    }

    final prefix = info0.prefix;
    final cidr = '${info0.network}/$prefix';
    // Both routes are the same prefix, so the two protocol names in the
    // question (".../24 ospf or .../24 static") decide which distance each
    // one carries.
    final protocols = _protocolsInOrder(t);
    final p0 = protocols.isNotEmpty ? protocols[0] : null;
    final p1 = protocols.length > 1 ? protocols[1] : null;

    if (p0 != null && p1 != null && p0.$1 != p1.$1) {
      final lower = p0.$2 <= p1.$2 ? p0 : p1;
      final higher = p0.$2 <= p1.$2 ? p1 : p0;
      return IntellectAnswer(
        '$cidr from ${lower.$1} wins.\n\n'
        '- Both routes are for the same prefix length, so longest prefix '
        'match cannot separate them - administrative distance does.\n'
        '- ${lower.$1} has distance ${lower.$2}; ${higher.$1} has distance '
        '${higher.$2}. The lower number is installed.\n'
        '- If the distances tied, the protocol metric would decide, and equal '
        'metrics would install both for ECMP.\n\n'
        'Reference: connected 0, static 1, eBGP 20, EIGRP 90, OSPF 110, '
        'IS-IS 115, RIP 120, iBGP 200.',
        topic: 'route-choice',
      );
    }

    return IntellectAnswer(
      'For $cidr the distance list decides, because both routes have the same '
      'prefix length.\n\n'
      '- Connected 0, static 1, eBGP 20, EIGRP 90, OSPF 110, IS-IS 115, '
      'RIP 120, iBGP 200: the lowest distance is installed.\n'
      '- A tie on distance falls through to the protocol metric, and equal '
      'metrics install both routes for ECMP.\n'
      '- If one advertiser used a longer prefix it would win outright, before '
      'any of this.\n\n'
      'Check the result with `show ip route $cidr`, which prints the source '
      'and distance it actually chose.',
      topic: 'route-choice',
    );
  }

  static List<(String, int)> _protocolsInOrder(String t) {
    final found = <(int, String, int)>[];
    for (final entry in _distance.entries) {
      final m = RegExp(
        '(?:^|[^a-z0-9])${RegExp.escape(entry.key)}(?:[^a-z0-9]|\$)',
      ).firstMatch(t);
      if (m == null) continue;
      found.add((m.start, entry.key, entry.value));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final entry in found) (entry.$2, entry.$3)];
  }

  static const Map<String, int> _distance = {
    'connected': 0,
    'static': 1,
    'ebgp': 20,
    'bgp': 20,
    'eigrp': 90,
    'ospf': 110,
    'isis': 115,
    'rip': 120,
    'ibgp': 200,
  };

  /// Variable-length subnet design: largest requirement first, smallest block
  /// that fits, then the leftovers stated as leftovers.
  static IntellectAnswer? _vlsm(String t) {
    final cidr = _firstCidr(t);
    if (cidr == null) return null;
    if (!RegExp(
      r'\b(?:vlsm|subnets?|allocate|allocation|address\s+plan)\b',
    ).hasMatch(t)) {
      return null;
    }
    final numbers = _hostNumbers(t, cidr);
    if (numbers.length < 2) return null;

    final plan = NetworkMath.vlsm(cidr, [
      for (var i = 0; i < numbers.length; i++)
        (name: 'Subnet ${i + 1}', hosts: numbers[i]),
    ]);
    if (plan.isEmpty) return null;

    final b = StringBuffer();
    b.writeln(
      'VLSM plan for $cidr - allocate largest first so no block is wasted:',
    );
    for (final row in plan) {
      if (row.network.isEmpty) {
        b.writeln('- ${row.hostsRequested} hosts: ${row.note}');
        continue;
      }
      b.writeln(
        '- ${row.hostsRequested} hosts -> ${row.network}  '
        '(${row.usableHosts} usable, mask ${row.mask}, '
        '${row.firstHost}-${row.lastHost}, broadcast ${row.broadcast})',
      );
    }

    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed != null) {
      final total = 1 << (32 - parsed.$2);
      var used = 0;
      for (final row in plan) {
        if (row.network.isNotEmpty) used += 1 << (32 - row.prefix);
      }
      if (used < total) {
        b.writeln(
          '\n$total addresses in $cidr: $used allocated, '
          '${total - used} free for growth.',
        );
      }
    }
    b.writeln(
      'Give each block its gateway on the first usable address and keep one '
      'scheme across sites; a plan that changes convention per site is the '
      'one that gets a duplicate gateway.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'vlsm');
  }

  /// The host counts in "5 subnets with 100, 50, 20, 10 and 2 hosts from
  /// 192.168.1.0/24" - the numbers between the base block and the word hosts.
  static List<int> _hostNumbers(String t, String cidr) {
    final m = RegExp(r'\bhosts?\b').firstMatch(t);
    if (m == null) return const [];
    var head = t.substring(0, m.start).replaceAll(cidr, ' ');
    head = head.replaceAll(_prefixOnly, ' ');
    final withIndex = head.lastIndexOf(' with ');
    if (withIndex != -1) head = head.substring(withIndex + 6);
    final numbers = <int>[];
    for (final match in RegExp(r'\d+').allMatches(head)) {
      final value = int.tryParse(match.group(0)!);
      if (value != null && value > 0 && value <= 1000000) numbers.add(value);
    }
    return numbers;
  }

  /// Equal-sized split: "split 10.0.0.0/22 into /24s".
  static IntellectAnswer? _split(String t) {
    if (!RegExp(r'\b(?:split|carve|divide|break)\b').hasMatch(t)) return null;
    final cidr = _firstCidr(t);
    if (cidr == null) return null;
    final parsed = NetworkTools.parseCidr(cidr);
    if (parsed == null) return null;
    final basePrefix = parsed.$2;

    int? target;
    for (final match in _prefixOnly.allMatches(t)) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value == null || value <= basePrefix || value > 32) continue;
      target = value;
      break;
    }
    if (target == null) return null;

    final count = NetworkMath.splitCount(cidr, target);
    if (count == 0) return null;
    if (count > 4096) {
      return IntellectAnswer(
        'That is $count /$target subnets, which is past the point where a list '
        'is useful. Summarize instead: write the covering route, or split one '
        'level at a time (`$cidr` into /${basePrefix + 4}, then each block '
        'again).',
        topic: 'split',
      );
    }

    final list = NetworkMath.split(cidr, target);
    final b = StringBuffer();
    b.writeln('$cidr splits into $count /$target subnets:');
    final shown = list.length > 16 ? list.take(12).toList() : list;
    for (final block in shown) {
      b.writeln('- $block');
    }
    if (shown.length < list.length) {
      b.writeln('- ... and ${list.length - shown.length} more');
    }
    b.writeln(
      '\nEach block has ${(1 << (32 - target)) - 2} usable hosts; the '
      'first is the network and the last is the broadcast.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'split');
  }

  /// "Does 10.1.2.3 match permit 10.1.0.0 0.0.255.255" - the ACL test is a
  /// bitwise AND against the inverted wildcard, not a string compare.
  static IntellectAnswer? _aclMatch(String t) {
    if (!RegExp(r'\b(?:match|permit|deny|acl|access-list)\b').hasMatch(t)) {
      return null;
    }
    final ips = _ips(t);
    // host + network + wildcard. Two addresses with no wildcard is a
    // different question (membership), and the wildcard is what makes this
    // one an ACL test.
    if (ips.length != 3) return null;
    final address = ips[0];
    final network = ips[1];
    final wildcard = ips[2];
    if (!wildcard.startsWith('0.')) return null;
    final addressInt = NetworkTools.ipToInt(address);
    final wildcardInt = NetworkTools.ipToInt(wildcard);
    final networkInt = NetworkTools.ipToInt(network);
    if (addressInt == null || wildcardInt == null || networkInt == null) {
      return null;
    }
    final inverted = (~wildcardInt) & 0xFFFFFFFF;
    final matches = (addressInt & inverted) == (networkInt & inverted);
    return IntellectAnswer(
      matches
          ? 'Yes - $address matches `$network $wildcard`.\n\n'
                'The test is `(address AND NOT wildcard) == '
                '(network AND NOT wildcard)`. A wildcard bit of 0 means '
                '"must match" and 1 means "do not care", so with $wildcard '
                'only the first octet is actually compared.'
          : 'No - $address does not match `$network $wildcard`.\n\n'
                'The test is `(address AND NOT wildcard) == '
                '(network AND NOT wildcard)`. With wildcard $wildcard only the '
                'first octet is compared, and this address differs there.',
      topic: 'acl-match',
    );
  }

  /// Is an address inside a prefix.
  static IntellectAnswer? _membership(String t) {
    final cidr = _firstCidr(t);
    if (cidr == null) return null;
    final info = NetworkTools.subnet(cidr);
    if (info == null) return null;
    final base = cidr.split('/').first.trim();
    final candidates = _ips(t).where((ip) => ip != base).toList();
    if (candidates.length != 1) return null;
    if (!RegExp(
      r'\b(?:in|inside|part\s+of|belongs?|within|member|contains?)\b',
    ).hasMatch(t)) {
      return null;
    }
    final host = candidates.first;
    final inside = NetworkTools.contains(cidr, host);
    if (inside) {
      return IntellectAnswer(
        'Yes - $host is inside $cidr.\n\n'
        '- Network ${info.network}, mask ${info.mask}, '
        'broadcast ${info.broadcast}\n'
        '- Usable range ${info.firstHost} - ${info.lastHost} '
        '(${info.usableHosts} hosts)\n\n'
        'The test: the first ${info.prefix} bits of $host equal the first '
        '${info.prefix} bits of ${info.network}. A host answers directly when '
        'both sides use the same mask; a wrong mask on either side is the '
        'usual reason two hosts that look local cannot reach each other.',
        topic: 'membership',
      );
    }
    final hostInt = NetworkTools.ipToInt(host);
    final sameWidth = hostInt == null
        ? null
        : '${NetworkTools.intToIp(hostInt & _mask(info.prefix))}/${info.prefix}';
    return IntellectAnswer(
      'No - $host is not in $cidr.\n\n'
      '- $cidr covers ${info.firstHost} - ${info.lastHost}\n'
      '${sameWidth == null ? '' : '- At the same width, $host falls in '
                '$sameWidth\n\n'}'
      'The first ${info.prefix} bits differ. If you expected this to be local, '
      'one side has the wrong mask or the wrong gateway for this block.',
      topic: 'membership',
    );
  }

  /// Wildcard (inverse) mask, and the ACL line that uses it.
  static IntellectAnswer? _wildcard(String t) {
    if (!RegExp(r'\b(?:wildcard|inverse\s+mask)\b').hasMatch(t)) return null;
    final cidr = _firstCidr(t);
    final parsed = cidr == null ? null : NetworkTools.parseCidr(cidr);
    final prefix = parsed?.$2 ?? _firstPrefix(t);
    if (prefix == null) {
      return IntellectAnswer(
        'A wildcard mask is the bitwise inverse of a subnet mask, and it is '
        'written that way because an ACL asks "which bits must match?" rather '
        'than "which bits are the network?".\n\n'
        '- 0 means the bit must match; 1 means "do not care".\n'
        '- /24 mask 255.255.255.0 -> wildcard 0.0.0.255\n'
        '- /26 mask 255.255.255.192 -> wildcard 0.0.0.63\n'
        '- /27 mask 255.255.255.224 -> wildcard 0.0.0.31\n\n'
        'The common mistake is reading the wildcard as "the remaining bits" '
        'in the high octets - it is the complement of the mask, so it always '
        'sits in the low bits of the block.',
        topic: 'wildcard',
      );
    }
    final wildcard = NetworkMath.wildcardFromPrefix(prefix);
    final mask = NetworkTools.prefixToMask(prefix);
    final network = parsed == null
        ? null
        : NetworkTools.intToIp(parsed.$1 & _mask(parsed.$2));
    final b = StringBuffer();
    b.writeln(
      'For /$prefix the wildcard (inverse) mask is $wildcard '
      '(subnet mask $mask).',
    );
    b.writeln();
    b.writeln('- Bitwise NOT of $mask is $wildcard.');
    b.writeln(
      '- 0 means "must match", 1 means "do not care", so $wildcard fixes the '
      'first $prefix bits.',
    );
    if (network != null) {
      b.writeln(
        '- ACL line: `access-list 10 permit $network $wildcard` matches every '
        'address in $network/$prefix.',
      );
    }
    b.writeln(
      '- For a single host, use `host <address>`, which is the same as '
      'wildcard 0.0.0.0.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'wildcard');
  }

  /// "What prefix do I need for 500 hosts" and "how many IP addresses do I
  /// need for 500 users" - the reverse of the usual host-count question.
  static IntellectAnswer? _prefixForHosts(String t) {
    final asksBlock = RegExp(r'\b(?:prefix|subnet|mask|block)\b').hasMatch(t);
    // A capacity question is the same arithmetic even when it never says
    // "prefix": "how many IP addresses do I need for 500 users" has to be
    // answered with a block, not with a number range.
    final asksCount = RegExp(
      r'\bhow\s+many\s+(?:ip\s+)?(?:addresses?|ips?)\b',
    ).hasMatch(t);
    if (!asksBlock && !asksCount) return null;
    // "What switch do I need for a classroom block with 30 pcs" is a device
    // choice, not address maths: "block" there is a building, not a subnet.
    if (_firstCidr(t) == null &&
        RegExp(
          r'\b(?:what|which)\b.*\b(?:switch|router|firewall|access\s+point|'
          r'ap|model|vendor|brand)\b',
        ).hasMatch(t)) {
      return null;
    }
    if (_firstCidr(t) != null) return null;
    final m = RegExp(
      r'(\d+)\s*(hosts?|users?|devices?|clients?|staff|employees|seats?|'
      r'people|pcs?|phones?)\b',
    ).firstMatch(t);
    if (m == null) return null;
    final want = int.tryParse(m.group(1)!);
    if (want == null || want < 1 || want > 16000000) return null;
    final noun = m.group(2)!;
    // One address per person is not how a LAN sizes: a user is a laptop plus
    // a phone plus the printer and the camera next to them. Ask for the
    // block that holds the seats with the usual headroom.
    final people = RegExp(
      r'^(?:users?|staff|employees|seats?|people)$',
    ).hasMatch(noun);
    final seats = people ? (want * 1.5).ceil() : want;
    final prefix = NetworkMath.prefixForHosts(seats);
    final info = NetworkTools.subnet('0.0.0.0/$prefix');
    if (info == null) return null;
    return IntellectAnswer(
      'For $want $noun, plan a /$prefix.\n\n'
      '- Mask ${info.mask}, ${info.usableHosts} usable addresses '
      '(${info.totalAddresses} total).\n'
      '- /30 is the point-to-point choice: 2 usable, and ${want == 2 ? 'that '
                'is exactly what a link needs' : 'nothing wasted on a link'}.\n'
      '- Ask for growth: a block that is 80% full on day one is a redesign in '
      'a year, so size to the next power of two unless addresses are tight.',
      topic: 'prefix-for-hosts',
    );
  }

  /// "How many hosts does a /28 hold" - the count, the mask and the range.
  static IntellectAnswer? _hostsInPrefix(String t) {
    if (!RegExp(r'\bhow\s+many\b').hasMatch(t)) return null;
    if (!RegExp(r'\b(?:hosts?|usable|addresses|ips?|devices?)\b').hasMatch(t)) {
      return null;
    }
    final cidr = _firstCidr(t);
    final prefix = cidr != null
        ? NetworkTools.parseCidr(cidr)?.$2
        : _firstPrefix(t);
    if (prefix == null) return null;
    final info = NetworkTools.subnet('0.0.0.0/$prefix');
    if (info == null) return null;
    final bits = 32 - prefix;
    final pointToPoint = prefix == 31;
    final usable = pointToPoint ? 2 : info.usableHosts;
    final b = StringBuffer();
    b.writeln('${cidr ?? '/$prefix'} has $usable usable host addresses.');
    b.writeln();
    b.writeln(
      '- Mask ${info.mask}, ${info.totalAddresses} addresses in total '
      '(${bits == 0 ? 'one address' : '2^$bits'}).',
    );
    if (pointToPoint) {
      b.writeln(
        '- A /31 is the RFC 3021 point-to-point form: both addresses are '
        'usable, with no network or broadcast address, which is why it is '
        'preferred for router-to-router links.',
      );
    } else if (prefix == 32) {
      b.writeln(
        '- A /32 is a single host route: one address, used for a '
        'loopback or a host route, not for a LAN.',
      );
    } else {
      b.writeln(
        '- Network ${info.network}, first host ${info.firstHost}, last '
        'host ${info.lastHost}, broadcast ${info.broadcast}.',
      );
      b.writeln(
        '- The network and broadcast addresses are reserved, which is '
        'why the count is 2^n - 2, not 2^n.',
      );
    }
    b.writeln(
      '- Size to growth: a block at 80% on day one is a redesign in a '
      'year, so take the next power of two unless addresses are tight.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'hosts-in-prefix');
  }

  /// "What mask is a /29" - the dotted mask, the block size and the range.
  /// A mask is not a number to memorise; it is the first N bits, and knowing
  /// the block size it leaves is what makes a /29 answer useful on the spot.
  static IntellectAnswer? _maskForPrefix(String t) {
    if (!RegExp(r'\b(?:mask|netmask)\b').hasMatch(t)) return null;
    if (RegExp(r'\b(?:wildcard|inverse)\b').hasMatch(t)) return null;
    if (RegExp(r'\b(?:hosts?|usable|users?|addresses)\b').hasMatch(t)) {
      return null;
    }
    final cidr = _firstCidr(t);
    final prefix = cidr != null
        ? NetworkTools.parseCidr(cidr)?.$2
        : _firstPrefix(t);
    if (prefix == null) return null;
    final info = NetworkTools.subnet('0.0.0.0/$prefix');
    if (info == null) return null;
    final mask = info.mask;
    final wildcard = NetworkMath.wildcardFromPrefix(prefix);
    final b = StringBuffer();
    b.writeln('/$prefix is mask $mask (wildcard $wildcard).');
    b.writeln();
    b.writeln(
      '- Block size ${info.totalAddresses} addresses, so every network in '
      'this block starts on a multiple of it.',
    );
    if (prefix <= 30) {
      b.writeln(
        '- ${info.usableHosts} usable addresses '
        '(${info.firstHost} - ${info.lastHost}), broadcast '
        '${info.broadcast}.',
      );
    }
    if (prefix == 31) {
      b.writeln(
        '- A /31 has two addresses and no network or broadcast, which is why '
        'RFC 3021 prefers it on router-to-router links.',
      );
    }
    if (prefix == 32) {
      b.writeln(
        '- A /32 is one address: a host route or a loopback, never a LAN.',
      );
    }
    b.writeln(
      '- Masks are contiguous: the prefix bits are 1s, the rest are 0s. A '
      'non-contiguous mask such as 255.255.0.255 is not a prefix, and most '
      'platforms reject it.',
    );
    b.writeln();
    b.writeln(
      'Said the way a config says it: ip address ${info.network} $mask, or '
      'ip address ${info.network}/$prefix.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'mask-for-prefix');
  }

  /// Bandwidth-delay product: why a fast, long path still transfers slowly.
  static IntellectAnswer? _bandwidthDelay(String t) {
    if (!RegExp(
      r'\b(?:bdp|bandwidth[-\s]delay|window\s+size|throughput)\b',
    ).hasMatch(t)) {
      return null;
    }
    final rate = _rateBits(t);
    final rttMs = _millis(t);
    if (rate == null || rttMs == null) return null;
    final rttSeconds = rttMs / 1000;
    final bdpBytes = rate / 8 * rttSeconds;
    final window = 64 * 1024;
    final windowedMbps = window * 8 / rttSeconds / 1000000;
    return IntellectAnswer(
      'At ${_rateLabel(rate)} with a ${_num(rttMs)} ms RTT:\n\n'
      '- Bandwidth-delay product = ${_bytes(bdpBytes)}. That is how much data '
      'must be in flight to fill the path.\n'
      '- A single TCP flow with a 64 KB window tops out near '
      '${windowedMbps.toStringAsFixed(1)} Mbps, however fast the link is.\n'
      '- Fix it with window scaling (RFC 7323) and a receive window at least '
      'the BDP, or with several parallel flows; a bigger link alone does not '
      'raise a single flow\'s ceiling.\n\n'
      'Check it on the host, not the router: `ss -ti` on Linux shows the '
      'congestion window and RTT actually in use.',
      topic: 'bdp',
    );
  }

  /// MTU/MSS through a tunnel.
  static IntellectAnswer? _mss(String t) {
    if (!RegExp(r'\bmss\b').hasMatch(t)) return null;
    final mtuMatch = RegExp(r'\bmtu\s*(?:of|=|is)?\s*(\d{3,5})').firstMatch(t);
    final overhead = _overhead(t);
    if (mtuMatch == null && overhead == null) return null;

    final mtu = mtuMatch != null
        ? int.tryParse(mtuMatch.group(1)!)
        : 1500 - (overhead ?? 0);
    if (mtu == null || mtu < 576 || mtu > 9216) return null;
    final mss = mtu - 40;
    final b = StringBuffer();
    if (overhead != null && mtuMatch == null) {
      b.writeln(
        'A ${_overheadName(t)} tunnel costs $overhead bytes, so inside it:',
      );
    } else {
      b.writeln('With an MTU of $mtu:');
    }
    b.writeln();
    b.writeln('- MSS = MTU - 40 = $mss (20 bytes IPv4 + 20 bytes TCP).');
    b.writeln('- For IPv6 the headers are 60 bytes, so MSS is ${mtu - 60}.');
    b.writeln(
      '- Configure `ip tcp adjust-mss $mss` and `ip mtu $mtu` on the tunnel '
      'interface rather than trusting PMTUD alone.',
    );
    b.writeln(
      '- The failure it prevents: small pings pass, large transfers or '
      'logins hang, because ICMP fragmentation-needed never arrives.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'mss');
  }

  static int? _overhead(String t) {
    if (RegExp(r'\bgre\b').hasMatch(t)) return 24;
    if (RegExp(r'\bvxlan\b').hasMatch(t)) return 50;
    if (RegExp(r'\b(?:ipsec|esp)\b').hasMatch(t)) return 73;
    if (RegExp(r'\bpppoe\b').hasMatch(t)) return 8;
    if (RegExp(r'\bwireguard\b').hasMatch(t)) return 60;
    if (RegExp(r'\b(?:6in4|ipip)\b').hasMatch(t)) return 20;
    if (RegExp(r'\boverhead\b').hasMatch(t)) return null;
    return null;
  }

  static String _overheadName(String t) {
    if (RegExp(r'\bgre\b').hasMatch(t)) return 'GRE';
    if (RegExp(r'\bvxlan\b').hasMatch(t)) return 'VXLAN';
    if (RegExp(r'\b(?:ipsec|esp)\b').hasMatch(t)) return 'IPsec';
    if (RegExp(r'\bpppoe\b').hasMatch(t)) return 'PPPoE';
    if (RegExp(r'\bwireguard\b').hasMatch(t)) return 'WireGuard';
    return 'tunnel';
  }

  /// Where an address sits: private, public, CGNAT, documentation, and so on.
  static IntellectAnswer? _scope(String t) {
    if (!RegExp(
      r'\b(?:private|public|routable|reserved|rfc\s*1918|apipa|link[-\s]?local|'
      r'loopback|multicast|scope)\b',
    ).hasMatch(t)) {
      return null;
    }
    if (_firstCidr(t) != null) return null;
    final ips = _ips(t);
    if (ips.isEmpty) return null;
    final ip = ips.first;
    final scope = NetworkMath.scope(ip);
    final routable = scope == IpScope.publicAddress;
    return IntellectAnswer(
      '$ip is ${scope.label}.\n\n'
      '- ${routable ? 'It can be routed on the public internet if a provider announces it.' : 'It is not routable on the public internet; it needs NAT or a tunnel to reach it.'}\n'
      '- Classful class: ${NetworkMath.classfulClass(ip)} '
      '(default mask ${NetworkMath.classfulMask(ip)}).\n'
      '- RFC 1918 space is 10/8, 172.16/12 and 192.168/16; 100.64/10 is carrier '
      'NAT and is often mistaken for private space.\n\n'
      'In a lab, a documentation range (192.0.2.0/24, 198.51.100.0/24, '
      '203.0.113.0/24) keeps example configs from colliding with real '
      'addresses.',
      topic: 'scope',
    );
  }

  /// Route summarization.
  static IntellectAnswer? _summarize(String t) {
    if (!RegExp(
      r'\b(?:summari[sz]e|summary\s+route|supernet|aggregate)\b',
    ).hasMatch(t)) {
      return null;
    }
    final cidrs = _cidrs(t);
    if (cidrs.length < 2) return null;
    final result = NetworkMath.summarize(cidrs);
    if (result.isEmpty) return null;
    final b = StringBuffer();
    b.writeln('${cidrs.join(' + ')} summarizes to:');
    for (final cidr in result) {
      b.writeln('- $cidr');
    }
    b.writeln(
      '\nOnly summarize when every address in the shorter prefix is really '
      'reachable that way - a summary that covers blocks you do not own '
      'black-holes them.',
    );
    return IntellectAnswer(b.toString().trim(), topic: 'summarize');
  }

  /// Range to CIDR list, the translation a firewall rule needs.
  static IntellectAnswer? _rangeToCidrs(String t) {
    if (!RegExp(r'\b(?:range|cidrs?|prefix(?:es)?)\b').hasMatch(t)) {
      return null;
    }
    final ips = _ips(t);
    if (ips.length < 2) return null;
    final list = NetworkMath.rangeToCidrs(ips[0], ips[1]);
    if (list.isEmpty) return null;
    return IntellectAnswer(
      '${ips[0]} - ${ips[1]} is covered exactly by:\n\n'
      '${[for (final cidr in list) '- $cidr'].join('\n')}\n\n'
      'Shortest possible list: each entry is the largest aligned block that '
      'fits, which is why a range does not always collapse to one prefix.',
      topic: 'range',
    );
  }

  // --- comparison ----------------------------------------------------------

  static IntellectAnswer? _comparison(String t) {
    // A purchase is not a comparison. "Should I buy Cat6 or Cat6a" wants a
    // recommendation grounded in the job, and that is the advisor's answer.
    if (RegExp(
      r'\b(?:buy|purchase|price|pricing|budget|recommend\w*|worth\s+it)\b',
    ).hasMatch(t)) {
      return null;
    }
    final pair = _pair(t);
    if (pair == null) return null;
    final a = _topicFor(pair.$1);
    final b = _topicFor(pair.$2);
    if (a == null || b == null || a.id == b.id) return null;

    final out = StringBuffer();
    out.writeln('${a.name} vs ${b.name}');
    out.writeln();
    out.writeln('What each one is');
    out.writeln('- ${a.name}: ${a.summary}');
    out.writeln('- ${b.name}: ${b.summary}');
    out.writeln();
    out.writeln('How they actually work');
    out.writeln('- ${a.name}: ${a.mechanism}');
    out.writeln('- ${b.name}: ${b.mechanism}');
    out.writeln();
    out.writeln('Choose it when');
    out.writeln('- ${a.name}: ${a.whenToUse}');
    out.writeln('- ${b.name}: ${b.whenToUse}');
    out.writeln();
    out.writeln('The cost you accept');
    out.writeln('- ${a.name}: ${a.tradeoffs}');
    out.writeln('- ${b.name}: ${b.tradeoffs}');
    if (a.pitfalls.isNotEmpty || b.pitfalls.isNotEmpty) {
      out.writeln();
      out.writeln('Where each one bites');
      if (a.pitfalls.isNotEmpty) out.writeln('- ${a.name}: ${a.pitfalls}');
      if (b.pitfalls.isNotEmpty) out.writeln('- ${b.name}: ${b.pitfalls}');
    }
    out.writeln();
    out.writeln(
      'Rule of thumb: run the simpler of the two unless a named requirement '
      'in "choose it when" rules it out - complexity has to buy something '
      'you can point at.',
    );
    return IntellectAnswer(out.toString().trim(), topic: '${a.id}-vs-${b.id}');
  }

  static (String, String)? _pair(String t) {
    // A dot is not a sentence terminator here: it is the dot in 802.11ax, in
    // 10.0.0.1 and in 802.1Q, so ending a side on '.' truncated the very
    // names people compare. Trailing punctuation is stripped afterwards.
    final patterns = <RegExp>[
      RegExp(r'difference\s+between\s+(.+?)\s+and\s+(.+?)(?:[?!,]|$)'),
      RegExp(r'^(.+?)\s+(?:vs\.?|versus)\s+(.+?)(?:[?!,]|$)'),
      RegExp(r'compare\s+(.+?)\s+(?:and|to|with)\s+(.+?)(?:[?!,]|$)'),
    ];
    for (final pattern in patterns) {
      final m = pattern.firstMatch(t);
      if (m == null) continue;
      final a = _cleanSide(m.group(1)!);
      final b = _cleanSide(m.group(2)!);
      if (a.isEmpty || b.isEmpty) continue;
      return (a, b);
    }
    // "eigrp or ospf" is a comparison only when the whole message is short -
    // a long sentence with "or" in it is a design question for the advisor.
    final orMatch = RegExp(r'^(.+?)\s+or\s+(.+?)(?:[?!,]|$)').firstMatch(t);
    if (orMatch == null) return null;
    // "should i use ospf or eigrp" is six words and still a direct technical
    // either/or; "should i use a layer 3 switch or router-on-a-stick" is
    // longer and belongs to the advisor, which is what this length cap keeps.
    if (t.split(RegExp(r'\s+')).length > 8) return null;
    final a = _cleanSide(orMatch.group(1)!);
    final b = _cleanSide(orMatch.group(2)!);
    if (a.isEmpty || b.isEmpty) return null;
    return (a, b);
  }

  static String _cleanSide(String side) {
    var s = side.trim();
    const prefixes = [
      'what is the difference between ',
      'what is the difference ',
      'what is ',
      "what's ",
      'whats ',
      'which is better ',
      'which is better, ',
      'difference between ',
      'compare ',
      'explain ',
      'tell me about ',
      'the ',
      'a ',
      'an ',
      'is ',
      'are ',
      'between ',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in prefixes) {
        if (s.startsWith(prefix)) {
          s = s.substring(prefix.length).trim();
          changed = true;
        }
      }
    }
    for (final suffix in const [' fibre', ' fiber']) {
      if (s.endsWith(suffix) && s.length > suffix.length) {
        s = s.substring(0, s.length - suffix.length).trim();
      }
    }
    return s.replaceAll(RegExp(r'[?.!,]+$'), '').trim();
  }

  static NetworkTech? _topicFor(String side) {
    // "stateful vs stateless firewall" names the qualifier on one side and
    // the mechanism on the other; both halves have to resolve to compare.
    final bare = side.trim();
    if (bare == 'stateful') return _topicById('firewall');
    if (bare == 'stateless') return _topicById('packet-filter');
    NetworkTech? best;
    var bestLength = 0;
    for (final tech in networkCatalog) {
      for (final alias in [tech.name.toLowerCase(), ...tech.aliases]) {
        if (alias.length <= bestLength) continue;
        if (_hasPhrase(side, alias)) {
          best = tech;
          bestLength = alias.length;
        }
      }
    }
    return best;
  }

  static NetworkTech? _topicById(String id) {
    for (final tech in networkCatalog) {
      if (tech.id == id) return tech;
    }
    return null;
  }

  // --- single topic --------------------------------------------------------

  static NetworkTech? _bestTopic(String t) {
    NetworkTech? best;
    var bestLength = 0;
    for (final tech in networkCatalog) {
      for (final alias in [tech.name.toLowerCase(), ...tech.aliases]) {
        if (alias.length <= bestLength) continue;
        if (_hasPhrase(t, alias)) {
          best = tech;
          bestLength = alias.length;
        }
      }
    }
    return best;
  }

  static bool _mentionsAspect(String t, NetworkTech tech) =>
      tech.aspects.any((aspect) => _hasPhrase(t, aspect));

  static bool _hasPhrase(String t, String phrase) {
    final escaped = RegExp.escape(phrase);
    return RegExp('(?:^|[^a-z0-9])$escaped(?:[^a-z0-9]|\$)').hasMatch(t);
  }

  static String _render(String t, NetworkTech tech) {
    final shape = _shape(t);
    final b = StringBuffer();

    if (shape == 'how') {
      b.writeln(tech.summary);
      if (tech.commands.isNotEmpty) {
        b.writeln();
        b.writeln('Configuration:');
        b.writeln(tech.commands);
      }
      if (tech.verify.isNotEmpty) {
        b.writeln();
        b.writeln('Verify: ${tech.verify}');
      }
      if (tech.pitfalls.isNotEmpty) {
        b.writeln();
        b.writeln('Watch out: ${tech.pitfalls}');
      }
      return b.toString().trim();
    }

    if (shape == 'diagnose') {
      b.writeln(tech.summary);
      if (tech.pitfalls.isNotEmpty) {
        b.writeln();
        b.writeln('How it fails: ${tech.pitfalls}');
      }
      if (tech.verify.isNotEmpty) {
        b.writeln();
        b.writeln('Prove it first, read-only: ${tech.verify}');
      }
      b.writeln();
      b.writeln(
        'Change one thing at a time, and re-run the same check after each '
        'change - a second change before the first is verified is how two '
        'faults become one unexplained fault.',
      );
      return b.toString().trim();
    }

    if (shape == 'design') {
      b.writeln(tech.summary);
      b.writeln();
      b.writeln('Use it when: ${tech.whenToUse}');
      b.writeln();
      b.writeln('Trade-off: ${tech.tradeoffs}');
      if (tech.pitfalls.isNotEmpty) {
        b.writeln();
        b.writeln('Design risks: ${tech.pitfalls}');
      }
      _appendFacts(b, tech);
      return b.toString().trim();
    }

    if (shape == 'why') {
      b.writeln(tech.summary);
      b.writeln();
      b.writeln(tech.mechanism);
      b.writeln();
      b.writeln('The trade-off: ${tech.tradeoffs}');
      return b.toString().trim();
    }

    b.writeln(tech.summary);
    b.writeln();
    b.writeln(tech.mechanism);
    b.writeln();
    b.writeln('Use it when: ${tech.whenToUse}');
    b.writeln();
    b.writeln('Trade-off: ${tech.tradeoffs}');
    if (tech.pitfalls.isNotEmpty) {
      b.writeln();
      b.writeln('Watch out: ${tech.pitfalls}');
    }
    _appendFacts(b, tech);
    return b.toString().trim();
  }

  static void _appendFacts(StringBuffer b, NetworkTech tech) {
    if (tech.facts.isEmpty) return;
    b.writeln();
    b.writeln('Key facts:');
    tech.facts.forEach((key, value) => b.writeln('- $key: $value'));
  }

  static String _shape(String t) {
    if (RegExp(
      r'\b(?:troubleshoot\w*|not\s+working|fails?|failing|failure|broken|'
      r'debug|diagnose|issue|problem|stuck|down|cannot|can\x27t|keeps?)\b',
    ).hasMatch(t)) {
      return 'diagnose';
    }
    if (RegExp(
      r'\b(?:why\s+(?:is|does|do|are|would|should)|why)\b',
    ).hasMatch(t)) {
      return 'why';
    }
    if (RegExp(
      r'\bhow\s+(?:do|to|can|should|would)\b|\bconfigure\b|\bcommands?\b|'
      r'\bsyntax\b|\bset\s*up\b|\bimplement\b',
    ).hasMatch(t)) {
      return 'how';
    }
    if (RegExp(
      r'\bwhen\s+(?:should|to|do|would)\b|\bdesign\b|\barchitecture\b|'
      r'\bbest\s+practice\b|\bwhere\s+should\b',
    ).hasMatch(t)) {
      return 'design';
    }
    return 'what';
  }

  // --- small shared helpers ------------------------------------------------

  static List<String> _ips(String t) =>
      _ip.allMatches(t).map((m) => m.group(0)!).toList();

  static List<String> _cidrs(String t) =>
      _cidr.allMatches(t).map((m) => m.group(0)!.replaceAll(' ', '')).toList();

  static String? _firstCidr(String t) {
    final cidrs = _cidrs(t);
    if (cidrs.isEmpty) return null;
    return cidrs.first;
  }

  static int? _firstPrefix(String t) {
    final m = _prefixOnly.firstMatch(t);
    if (m == null) return null;
    final prefix = int.tryParse(m.group(1) ?? '');
    if (prefix == null || prefix < 0 || prefix > 32) return null;
    return prefix;
  }

  static int _mask(int prefix) =>
      prefix <= 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

  static int? _rateBits(String t) {
    final m = RegExp(
      r'(\d+(?:\.\d+)?)\s*(g(?:bit|bps|b/s)|m(?:bit|bps|b/s)|k(?:bit|bps|b/s))',
    ).firstMatch(t);
    if (m == null) return null;
    final value = double.tryParse(m.group(1)!);
    if (value == null) return null;
    final unit = m.group(2)!;
    if (unit.startsWith('g')) return (value * 1e9).round();
    if (unit.startsWith('m')) return (value * 1e6).round();
    return (value * 1e3).round();
  }

  static double? _millis(String t) {
    final m = RegExp(
      r'(\d+(?:\.\d+)?)\s*(?:ms|milliseconds?|msec)\b',
    ).firstMatch(t);
    if (m == null) return null;
    return double.tryParse(m.group(1)!);
  }

  static String _rateLabel(int bits) {
    if (bits >= 1000000000) return '${_num(bits / 1e9)} Gbps';
    if (bits >= 1000000) return '${_num(bits / 1e6)} Mbps';
    return '${_num(bits / 1e3)} kbps';
  }

  static String _num(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    final text = value.toStringAsFixed(2);
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }

  static String _bytes(double value) {
    if (value >= 1024 * 1024) {
      return '${_num(value / (1024 * 1024))} MB';
    }
    if (value >= 1024) {
      return '${_num(value / 1024)} KB (${value.round()} bytes)';
    }
    return '${value.round()} bytes';
  }
}
