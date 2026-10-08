import 'package:net_builder/services/phrasing_memory_service.dart';

import '../../models/network_intent.dart';
import 'lexicon.dart';

/// THE BRIEF READER: English in, a NetworkIntent out.
///
/// This is the front door of the planner, and it used to be the first 2,400
/// lines of models/network_intent.dart - the data model and the English
/// reader in one file, so neither could be changed without fear of the
/// other. It is separated here.
///
/// WHAT IS IN THIS FILE: reading the words. Normalising them (Arabic digits,
/// spelled-out numbers, dotted masks), bridging the phrasings the lexicon
/// cannot match, finding the sites, and replaying a phrasing the user has
/// already clarified.
///
/// WHAT IS STILL IN network_intent.dart: building the topology out of the
/// normalised brief, in [NetworkIntent.parseBridged]. That is the next
/// extraction, and it is the larger half.
///
/// `NetworkIntent.parseSimple` still exists and still delegates here, so no
/// call site in the app moved when this file was created.

final RegExp _bidiControls = RegExp(r'[‎‏\u202a-\u202e؜]');
final RegExp _arabicDiacritics = RegExp(r'[ً-ِٰـ]');
final RegExp _hamzaForms = RegExp(r'[آإٱا]');

String _foldArabic(String s) => s
    .replaceAll(_bidiControls, ' ')
    .replaceAll(_arabicDiacritics, '')
    .replaceAll(_hamzaForms, 'ا')
    .replaceAll('ى', 'ي')
    .replaceAll('ة', 'ه')
    .replaceAll('،', ',');

final RegExp _arabicIndicDigits = RegExp(r'[٠-٩۰-۹]');

/// ٢٣ (Arabic-Indic) and ۲۳ (Extended Arabic-Indic) are the same numbers.
String _asciiDigits(String s) => s.replaceAllMapped(
  _arabicIndicDigits,
  (m) {
    final c = m.group(0)!.codeUnitAt(0);
    return '${c >= 0x06f0 ? c - 0x06f0 : c - 0x0660}';
  },
);

/// The prefix length of a dotted mask, or null when it is not a mask.
int? _maskToPrefix(String mask) {
  final parts = mask.split('.').map(int.parse).toList();
  if (parts.length != 4) return null;
  var bits = 0;
  var seenZero = false;
  for (final p in parts) {
    if (p > 255) return null;
    for (var b = 7; b >= 0; b--) {
      final one = (p >> b) & 1 == 1;
      if (one && seenZero) return null;
      if (one) {
        bits++;
      } else {
        seenZero = true;
      }
    }
  }
  return bits;
}

/// "10.1.1.0 255.255.255.252", "10.1.1.0 subnet mask 255.255.255.252" and
/// their Arabic spellings become one CIDR, so a single regex serves every
/// brief - including the address tables course briefs are written as.
final RegExp _maskPair = RegExp(
  r'(\d{1,3}(?:\.\d{1,3}){3})[\s,;:]*(?:/|subnet\s+mask|netmask|mask|prefix|qina3|قناع(?:\s+الشبكه)?)?[\s,;:]*(\d{1,3}(?:\.\d{1,3}){3})',
);

String _bridgeMasks(String s) => s.replaceAllMapped(
  _maskPair,
  (m) {
    final prefix = _maskToPrefix(m.group(2)!);
    if (prefix == null || prefix == 0) return m.group(0)!;
    return '${m.group(1)!}/$prefix';
  },
);

/// Arabic phrases -> the English words the rest of this parser already
/// keys on.  Keys are written in folded form (see [_foldArabic]) and the
/// table is applied longest-first, so 'جهاز التوجيه' (router) wins before
/// the bare 'جهاز' (pc) underneath it.
const List<List<String>> _phraseBridge = [
  // devices
  ['اجهزه التوجيه', 'routers'],
  ['جهاز التوجيه', 'router'],
  ['الموجه الرئيسي', 'core router'],
  ['الموجهات', 'routers'],
  ['موجهات', 'routers'],
  ['الموجه', 'router'],
  ['موجه', 'router'],
  ['الراوتر', 'router'],
  ['راوتر', 'router'],
  ['المبدلات', 'switches'],
  ['مبدلات', 'switches'],
  ['المبدله', 'switch'],
  ['مبدله', 'switch'],
  ['المبدل', 'switch'],
  ['مبدل', 'switch'],
  ['السويتش', 'switch'],
  ['سويتش', 'switch'],
  ['الخوادم', 'servers'],
  ['خوادم', 'servers'],
  ['الخادم', 'server'],
  ['خادم', 'server'],
  ['سيرفر', 'server'],
  ['اجهزه الموظفين', 'pcs'],
  ['الاجهزه', 'pcs'],
  ['اجهزه', 'pcs'],
  ['جهاز', 'pc'],
  ['حاسوب محمول', 'laptop'],
  ['لابتوب', 'laptop'],
  ['حاسوب', 'pc'],
  ['كمبيوتر', 'pc'],
  ['جدار ناري', 'firewall'],
  ['الفايروول', 'firewall'],
  ['نقطه وصول', 'access point'],
  ['اكسس بوينت', 'access point'],
  ['هاتف ip', 'ip phone'],
  ['هاتف', 'ip phone'],
  ['طابعه', 'printer'],
  ['سحابه', 'cloud'],
  ['مودم', 'modem'],
  ['واي فاي', 'wireless'],
  ['لاسلكي', 'wireless'],
  ['تابلت', 'tablet'],
  ['جوال', 'smartphone'],
  // security, services and the words that decide the security profile
  ['خادم aaa', 'aaa server'],
  ['خادم dhcp', 'dhcp server'],
  ['خادم الويب', 'web server'],
  ['خادم ويب', 'web server'],
  ['خادم dns', 'dns server'],
  ['خادم البريد', 'mail server'],
  ['خادم ftp', 'ftp server'],
  ['امن المنافذ', 'port security'],
  ['تامين المنافذ', 'port security'],
  ['امن الشبكه', 'network security'],
  ['امن الشبكات', 'network security'],
  ['حمايه الشبكه', 'network security'],
  ['التنصت علي dhcp', 'dhcp snooping'],
  ['تنصت dhcp', 'dhcp snooping'],
  ['خوادم وهميه', 'rogue dhcp servers'],
  ['خادم وهمي', 'rogue dhcp server'],
  ['منفذ موثوق', 'trusted port'],
  ['منافذ المستخدمين', 'user ports'],
  ['قائمه التحكم بالوصول', 'access list'],
  ['التحكم بالوصول', 'access control'],
  ['تحكم بالوصول', 'access control'],
  ['المصادقه المركزيه', 'centralized authentication'],
  ['مصادقه مركزيه', 'centralized authentication'],
  ['مصادقه', 'authentication'],
  ['تاكاكس', 'tacacs'],
  ['نفق ipsec', 'ipsec vpn'],
  ['نفق', 'vpn tunnel'],
  ['موقع الي موقع', 'site-to-site'],
  ['بين الفرعين', 'site-to-site'],
  ['مفتاح مشترك', 'pre-shared key'],
  ['مفتاح اولي', 'pre-shared key'],
  ['اسم المستخدم', 'username'],
  ['كلمه المرور', 'password'],
  ['كلمه السر', 'password'],
  ['كلمه مرور', 'password'],
  ['تشفير', 'encryption'],
  ['اوقات الدوام', 'office hours'],
  ['وقت الدوام', 'office hours'],
  ['ساعات العمل', 'office hours'],
  ['الدوام الرسمي', 'office hours'],
  ['الفرع الرئيسي', 'headquarters'],
  ['الفرع الفرعي', 'branch'],
  ['فرع رئيسي', 'headquarters'],
  ['فرع فرعي', 'branch'],
  ['الشبكه العامه', 'wan'],
  ['شبكه عامه', 'wan'],
  ['وصله تسلسليه', 'serial link'],
  ['تسلسليه', 'serial'],
  ['تسلسلي', 'serial'],
  ['قناع الشبكه', 'subnet mask'],
  ['العنونه', 'addressing'],
  ['بوابه افتراضيه', 'default gateway'],
  ['بوابه', 'gateway'],
  ['توجيه ديناميكي', 'dynamic routing'],
  ['توجيه ثابت', 'static route'],
  ['اوسبف', 'ospf'],
  // English spellings the parser should accept as the same request
  ['business hours', 'office hours'],
  ['working hours', 'office hours'],
  ['work hours', 'office hours'],
  ['site to site', 'site-to-site'],
  ['site2site', 'site-to-site'],
  ['centralised authentication', 'centralized authentication'],
  // Plain-English wordings that used to fall through the parser.
  ['half a dozen', '6'],
  ['half dozen', '6'],
  ['a pair of', '2'],
  ['a couple of', '2'],
  ['point-to-point', 'serial link'],
  ['point to point', 'serial link'],
  // "guest" is kept in the bridge: the parser only needs the wireless
  // keyword, while the sizing pack and the VLAN wording need to know the
  // network is for guests (guest wifi → guest wireless).
  ['guest wi-fi', 'guest wireless'],
  ['guest wifi', 'guest wireless'],
  ['guest wlan', 'guest wireless'],
  ['trunk between the switches', 'switch trunk'],
  ['trunk between switches', 'switch trunk'],
  ['tacacs+', 'tacacs'],
  // How people actually open a request. These are stripped rather than
  // translated: what follows them is the lab, and the parser only ever read
  // the numbers and device words.
  ['can you make me', ''],
  ['can you make', ''],
  ['can you create', ''],
  ['can you build me', ''],
  ['can you build', ''],
  ['could you make', ''],
  ['could you build', ''],
  ['please make', ''],
  ['please build', ''],
  ['please create', ''],
  ['please set up', ''],
  ['i want to make', ''],
  ['i want to build', ''],
  ['i want to create', ''],
  ['i want a', ''],
  ['i want', ''],
  ['i need to make', ''],
  ['i need to build', ''],
  ['i need a', ''],
  ['i need', ''],
  ['i.d like to build', ''],
  ['i.d like a', ''],
  ['i would like to build', ''],
  ['we need a', ''],
  ['we need', ''],
  ['give me a', ''],
  ['give me', ''],
  ['set me up', ''],
  ['set up a', ''],
  ['help me build', ''],
  ['help me set up', ''],
  ['make me a', ''],
  ['build me a', ''],
  ['create a', ''],
  ['design a', ''],
  ['plan a', ''],
  ['plan me a', ''],
  ['draw up a', ''],
  ['i have a', ''],
  ['we have a', ''],
  ['there is a', ''],
  ['there.s a', ''],
  ['my lab', ''],
  ['my network', ''],
  ['the lab', ''],
];

/// Numbers a brief may spell out instead of typing - English and Arabic.

bool _isAscii(String s) => s.codeUnits.every((c) => c < 128);

final RegExp _nonWordChars = RegExp(r'[^A-Za-z0-9\u0600-\u06ff]');

/// "two switches" -> "2 switches", "اثنين موجه" -> "2 router".
String _bridgeNumberWords(String s) => s
    .split(' ')
    .map((token) {
      final bare = token.replaceAll(_nonWordChars, '').toLowerCase();
      final n = numberWords[bare];
      return n == null ? token : '$n';
    })
    .join(' ');

/// True when the brief ties this subnet to a site: "192.168.20.0/24 at the
/// branch", "... for HQ".
///
/// Deliberately narrow: the site word has to follow the subnet within a
/// couple of words and sit in the same clause, so a subnet mentioned inside
/// a sentence about something else ("the 10.0.0.0/30 transit link between
/// the sites") is never claimed by a site it did not name.
final RegExp _siteCue = RegExp(
  r'^\s*(?:is\s+)?(?:at|for|in|on|to)\s+(?:the\s+|our\s+|its\s+)?'
  r'(?:headquarters|hq|main|site|branch|office|building|floor|school|'
  r'campus|department|location|store|shop)\b',
);

bool subnetSitsAtASite(String text, String cidr) {
  final at = text.indexOf(cidr);
  if (at < 0) return false;
  final from = at + cidr.length;
  final tail = text
      .substring(from, from + 40 > text.length ? text.length : from + 40)
      .toLowerCase();
  return _siteCue.hasMatch(tail);
}

/// How many identical sites a brief describes - "2 branch offices",
/// "three floors", "2 sites" - or null when it describes one.  The digits
/// must sit directly on the site word ("2 offices", not "2 routers in the
/// office"), and a count of one is not an expansion.
final RegExp _siteCountPhrase = RegExp(
  r'(\d{1,3})\s*(?:separate\s+|identical\s+|different\s+|remote\s+|branch\s+|physical\s+)?'
  r'(?:offices?|branches|sites?|floors?|buildings?|classrooms?|departments?|locations?)\b',
  caseSensitive: false,
);

int? siteCount(String text) {
  final m = _siteCountPhrase.firstMatch(text);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return (n < 2 || n > 25) ? null : n;
}

final RegExp _perSiteCue = RegExp(
  r'\b(?:each|per\s+(?:site|office|branch|floor|building|location|classroom|department))\b',
  caseSensitive: false,
);

final RegExp _perSiteAside = RegExp(
  r'[,;]?\s*(?:plus|as well as|in addition|additionally|also|and an additional)\b',
  caseSensitive: false,
);

final RegExp _sentenceBreak = RegExp(r'[.;\n]');

const List<String> _perSiteWords = [
  'router',
  'gateway',
  'switch',
  'pc',
  'workstation',
  'desktop',
  'server',
];

final Set<String> _perSiteKeywords = {
  ..._perSiteWords,
  for (final kind in deviceKinds) ...kind.keywords,
};

final Map<String, RegExp> _countPatternByWord = {
  for (final w in _perSiteKeywords)
    w: RegExp('(\\d{1,3})\\s*${RegExp.escape(w)}s?\\b'),
};

final Map<String, RegExp> _barePatternByWord = {
  for (final w in _perSiteKeywords) w: RegExp('\\b${RegExp.escape(w)}\\b'),
};

/// The device counts that belong to ONE site of a brief worded as
/// "... each with a router, a switch and 3 pcs".
///
/// The clause runs from the cue to the end of the sentence or to a
/// 'plus/also' aside, so "plus one server at headquarters" keeps its own
/// global count instead of being multiplied with everything else.
/// Returns null when the brief has no per-site cue at all.
Map<String, int>? perSiteCounts(String text) {
  final cue = _perSiteCue.firstMatch(text);
  if (cue == null) return null;
  var clause = text.substring(cue.end);
  final aside = _perSiteAside.firstMatch(clause);
  if (aside != null) clause = clause.substring(0, aside.start);
  final stop = clause.indexOf(_sentenceBreak);
  if (stop >= 0) clause = clause.substring(0, stop);
  final lower = clause.toLowerCase();

  /// "3 pcs" and a bare "a switch" both mean something per site.
  int countOf(List<String> words) {
    for (final w in words) {
      final m = _countPatternByWord[w]!.firstMatch(lower);
      if (m != null) return int.parse(m.group(1)!);
    }
    for (final w in words) {
      if (_barePatternByWord[w]!.hasMatch(lower)) return 1;
    }
    return 0;
  }

  final counts = <String, int>{'router': countOf(['router', 'gateway'])};
  counts['switch'] = countOf(['switch']);
  counts['pc'] = countOf(['pc', 'workstation', 'desktop']);
  counts['server'] = countOf(['server']);
  for (final kind in deviceKinds) {
    if (const ['router', 'switch', 'pc', 'server'].contains(kind.type)) {
      continue;
    }
    counts[kind.type] = countOf(kind.keywords);
  }
  return counts;
}

final RegExp _extraSpaces = RegExp(r'[ \t]+');

/// The phrase bridge, longest key first, with the pattern each ASCII key is
/// matched by already compiled.
///
/// Whole words only. These keys are matched case-insensitively without
/// boundaries, so a filler phrase for the standalone article "a" -
/// 'set up a' - also matched the first eight characters of any word
/// starting with a: "set up AAA" became "AA", and the AAA role word
/// vanished from the brief before the roles were read. A key that
/// starts and ends on a word character must not match inside one.
final List<({RegExp? pattern, String from, String to})> _phraseBridgeTable = [
  for (final e in [..._phraseBridge]
    ..sort((a, b) => b[0].length.compareTo(a[0].length)))
    if (_isAscii(e[0]))
      (
        pattern: RegExp(
          '${RegExp.escape(e[0][0]) == e[0][0] ? r'\b' : ''}'
          '${RegExp.escape(e[0])}'
          '${RegExp.escape(e[0][e[0].length - 1]) == e[0][e[0].length - 1] ? r'\b' : ''}',
          caseSensitive: false,
        ),
        from: e[0],
        to: e[1],
      )
    else
      (pattern: null, from: e[0], to: e[1]),
];

/// Rewrite a brief into the wording this parser understands.
String bridgeBrief(String raw) {
  var s = _bridgeMasks(_asciiDigits(_foldArabic(raw)));
  for (final e in _phraseBridgeTable) {
    final pattern = e.pattern;
    if (pattern != null) {
      s = s.replaceAll(pattern, e.to);
    } else if (s.contains(e.from)) {
      s = s.replaceAll(e.from, e.to);
    }
  }
  return _bridgeNumberWords(s).replaceAll(_extraSpaces, ' ');
}

/// Does this brief name a device kind (or an explicit device label like
/// R1/PC3) anywhere? Derived from [deviceKinds] so it cannot drift from the
/// parser's own vocabulary.
///
/// Used to tell "a new lab that names no devices" (where the parser's
/// router+switch fallback is right) apart from "a short follow-up like
/// 'ok build the packet tracer file'" - where inventing a default lab would
/// silently REPLACE the plan built from the user's real request.
final RegExp namesAnyDevice = RegExp(
  '(?:\\b(?:'
      '${deviceKinds
          .expand((k) => k.keywords)
          // Plural-tolerant: "2 routers" must count, and \brouter\b alone
          // would not match it.
          .map((k) => '${RegExp.escape(k)}(?:es|s)?')
          .join('|')}'
      ')\\b)',
);

final RegExp _deviceLabel = RegExp(r'\b(?:R|SW|PC|SRV)\d{1,2}\b');

/// True when [lower] mentions a device kind or a label like R1 / SW2 /
/// PC3 / SRV1. Pure; see [namesAnyDevice].
bool namesAnyDeviceIn(String lower) =>
    namesAnyDevice.hasMatch(lower) || _deviceLabel.hasMatch(lower);

/// A server label whose name says which service it runs: DHCP1, DNS1,
/// WEB1, AAA1, FTP1, MAIL1, NTP1 ...

/// The learned-phrasing hop, run once at the top of every parse.
NetworkIntent parseBrief(String projectName, String rawText) {
  final bridged = bridgeBrief(rawText);
  // Learned phrasing: when this exact wording was clarified before, the
  // resolved brief replays - the parser reads it as if the user had typed
  // it. Exactly one hop: a replay is never looked up again, so the index
  // can never loop. A brief that already states device counts is skipped
  // inside lookupMatch() and stays as written.
  final replay = PhrasingMemoryService.lookupMatch(bridged);
  if (replay != null &&
      replay.rewrite.trim().isNotEmpty &&
      replay.rewrite != bridged) {
    if (replay.exact) {
      return NetworkIntent.parseBridged(projectName, bridgeBrief(replay.rewrite), rawText);
    }
    // A NEAR TWIN is not the same request: the wording differs exactly
    // where the user said something new. The remembered resolution is
    // read FIRST (the parser reads the first count per kind), and the
    // user's own words stay whole after it, so any device, service, site,
    // address, model or constraint named in this message survives the
    // match instead of being replaced by what was learned earlier.
    final merged = '${replay.rewrite} $bridged';
    final intent = NetworkIntent.parseBridged(projectName, bridgeBrief(merged), rawText);
    final assumptions = [
      ...intent.assumptions,
      'Matched the phrasing "${replay.key}" remembered from an earlier '
          'conversation; it filled the details this message did not '
          'name. Everything stated here is kept as written.',
    ];
    if (replay.score >= 0.85) {
      return intent.copyWith(assumptions: assumptions);
    }
    // The match is close but not certain: say so and ask, rather than
    // letting a fuzzy memory quietly decide the plan. The merged plan is
    // still offered so the user is not left waiting.
    return intent.copyWith(
      assumptions: assumptions,
      questions: [
        ...intent.questions,
        'I matched this to an earlier phrasing ("${replay.key}"), but not '
            'with certainty - confirm it, or give the full wording once, '
            'and I will re-plan it exactly.',
      ],
      confidence: (intent.confidence - 0.1).clamp(0.0, 1.0),
    );
  }
  return NetworkIntent.parseBridged(projectName, bridged, rawText);
}
