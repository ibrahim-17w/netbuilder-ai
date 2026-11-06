import 'package:net_builder/services/phrasing_memory_service.dart';

import '../../models/network_intent.dart';
import '../../models/normalized_message.dart';
import 'lexicon.dart';
import '../packet_tracer/brief_reader.dart';
import 'package:flutter/foundation.dart' show compute;

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
String _asciiDigits(String s) => s.replaceAllMapped(_arabicIndicDigits, (m) {
  final c = m.group(0)!.codeUnitAt(0);
  return '${c >= 0x06f0 ? c - 0x06f0 : c - 0x0660}';
});

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

String _bridgeMasks(String s) => s.replaceAllMapped(_maskPair, (m) {
  final prefix = _maskToPrefix(m.group(2)!);
  if (prefix == null || prefix == 0) return m.group(0)!;
  return '${m.group(1)!}/$prefix';
});

/// Arabic phrases -> the English words the rest of this parser already
/// keys on.  Keys are written in folded form (see [_foldArabic]) and the
/// table is applied longest-first, so 'جهاز التوجيه' (router) wins before
/// the bare 'جهاز' (pc) underneath it.
const List<List<String>> _phraseBridge = [
  // Multi-word names must survive the spelled-out-number bridge: "single" is
  // also the number one, so "single board computer" became "1 1 board
  // computer" and lost its SBC meaning before the lexicon saw it.
  ['single board computer', 'SBC'],
  ['single-board computer', 'SBC'],
  // devices
  ['عالفرع التاني', 'at the second branch'],
  ['عالفرع الثاني', 'at the second branch'],
  ['على الفرع التاني', 'at the second branch'],
  ['على الفرع الثاني', 'at the second branch'],
  ['الفرع التاني', 'the second branch'],
  ['الفرع الثاني', 'the second branch'],
  ['ضيف', 'add'],
  ['شيل', 'remove'],
  ['احذف', 'remove'],
  ['بس', 'only'],
  ['خلي', 'keep'],
  ['متل ما هو', 'as it is'],
  ['بدون', 'without'],
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
  // One role adjective may sit between the count and the noun - enterprise
  // briefs say "2 core routers", not just "2 routers".
  for (final w in _perSiteKeywords)
    w: RegExp(
      '(\\d{1,3})\\s*(?:(?:core|edge|distribution|backbone|wan|hq|branch|'
      'main|central)\\s+)?${RegExp.escape(w)}s?\\b',
    ),
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
      final pattern = _countPatternByWord[w]!;
      for (final m in pattern.allMatches(lower)) {
        // "VLAN 20 servers" names the VLAN - the 20 is an ID, not a count.
        // Taking it inflated every later lab: "4 switches with VLAN 20
        // servers" built twenty servers where the brief named none.
        if (RegExp(r'vlan\s*$').hasMatch(lower.substring(0, m.start))) {
          continue;
        }
        return int.parse(m.group(1)!);
      }
    }
    for (final w in words) {
      if (_barePatternByWord[w]!.hasMatch(lower)) return 1;
    }
    return 0;
  }

  final counts = <String, int>{
    'router': countOf(['router', 'gateway']),
  };
  counts['switch'] = countOf(['switch']);
  counts['pc'] = countOf(['pc', 'workstation', 'desktop']);
  counts['server'] = countOf([
    'server',
    'nas',
    'network attached storage',
  ]);
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
  for (final e in [
    ..._phraseBridge,
  ]..sort((a, b) => b[0].length.compareTo(a[0].length)))
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

/// The same bridge pass as [bridgeBrief], retaining UTF-16 source offsets.
/// Kept beside the legacy bridge so both readers use the same phrase table,
/// masks, digit rules and number vocabulary.
NormalizedMessage bridgeBriefWithMapping(String raw) {
  final tracked = _TrackedText(raw);
  tracked.replaceAll(_bidiControls, (_) => ' ');
  tracked.replaceAll(_arabicDiacritics, (_) => '');
  tracked.replaceAll(_hamzaForms, (_) => 'ا');
  tracked.replaceAll(RegExp('ى'), (_) => 'ي');
  tracked.replaceAll(RegExp('ة'), (_) => 'ه');
  tracked.replaceAll(RegExp('،'), (_) => ',');
  tracked.replaceAll(_arabicIndicDigits, (match) {
    final code = match.group(0)!.codeUnitAt(0);
    return '${code >= 0x06f0 ? code - 0x06f0 : code - 0x0660}';
  });
  tracked.replaceAll(_maskPair, (match) {
    final prefix = _maskToPrefix(match.group(2)!);
    if (prefix == null || prefix == 0) return match.group(0)!;
    return '${match.group(1)!}/$prefix';
  });
  for (final entry in _phraseBridgeTable) {
    final pattern = entry.pattern;
    if (pattern != null) {
      tracked.replaceAll(pattern, (_) => entry.to);
    } else if (tracked.text.contains(entry.from)) {
      tracked.replaceAll(RegExp(RegExp.escape(entry.from)), (_) => entry.to);
    }
  }
  tracked.replaceAll(RegExp(r'[^ ]+'), (match) {
    final token = match.group(0)!;
    final bare = token.replaceAll(_nonWordChars, '').toLowerCase();
    return numberWords[bare]?.toString() ?? token;
  });
  tracked.replaceAll(_extraSpaces, (_) => ' ');
  return tracked.finish();
}

/// Applies whole-string bridge edits while keeping the source range of each
/// UTF-16 code unit. A phrase replacement maps to its complete original
/// phrase; removed text is retained as a zero-width deletion segment.
class _TrackedText {
  final String _original;
  final List<(int, int)> _protected;
  final List<(int, int)> _opaque;
  String text;
  List<int> _starts;
  List<int> _ends;
  List<({int at, int start, int end})> _deletions = [];

  _TrackedText(this.text)
    : _original = text,
      _protected = _literalRanges(text),
      _opaque = _opaqueValueRanges(text),
      _starts = [for (var i = 0; i < text.length; i++) i],
      _ends = [for (var i = 0; i < text.length; i++) i + 1];

  void replaceAll(RegExp pattern, String Function(RegExpMatch) replacement) {
    final matches = pattern.allMatches(text).toList(growable: false);
    if (matches.isEmpty) return;
    final oldText = text;
    final oldStarts = _starts;
    final oldEnds = _ends;
    final oldDeletions = _deletions;
    final buffer = StringBuffer();
    final starts = <int>[];
    final ends = <int>[];
    final deletions = <({int at, int start, int end})>[];
    final skipped = <RegExpMatch>{};
    var cursor = 0;
    var outputLength = 0;

    void copyRange(int from, int to) {
      if (from >= to) return;
      buffer.write(oldText.substring(from, to));
      starts.addAll(oldStarts.getRange(from, to));
      ends.addAll(oldEnds.getRange(from, to));
      outputLength += to - from;
    }

    for (final match in matches) {
      copyRange(cursor, match.start);
      if (_isProtected(match.start, match.end)) {
        skipped.add(match);
        copyRange(match.start, match.end);
        cursor = match.end;
        continue;
      }
      final outputStart = outputLength;
      var sourceStart = oldText.length;
      var sourceEnd = 0;
      for (var i = match.start; i < match.end; i++) {
        if (oldStarts[i] < sourceStart) sourceStart = oldStarts[i];
        if (oldEnds[i] > sourceEnd) sourceEnd = oldEnds[i];
      }
      for (final removed in oldDeletions) {
        if (removed.at < match.start || removed.at > match.end) continue;
        if (removed.start < sourceStart) sourceStart = removed.start;
        if (removed.end > sourceEnd) sourceEnd = removed.end;
      }
      final value = replacement(match);
      buffer.write(value);
      if (value.isNotEmpty) {
        if (sourceStart == oldText.length && sourceEnd == 0) {
          sourceStart = match.start;
          sourceEnd = match.end;
        }
        for (var i = 0; i < value.length; i++) {
          starts.add(sourceStart);
          ends.add(sourceEnd);
        }
      } else if (sourceEnd > sourceStart) {
        deletions.add((at: outputStart, start: sourceStart, end: sourceEnd));
      }
      outputLength += value.length;
      cursor = match.end;
    }
    copyRange(cursor, oldText.length);

    int moveBoundary(int boundary) {
      var delta = 0;
      for (final match in matches) {
        if (skipped.contains(match)) continue;
        if (boundary < match.start) break;
        final nextValue = replacement(match);
        if (boundary <= match.end) {
          return match.start + delta + nextValue.length;
        }
        delta += nextValue.length - (match.end - match.start);
      }
      return boundary + delta;
    }

    for (final removed in oldDeletions) {
      if (matches.any(
        (m) =>
            !skipped.contains(m) &&
            removed.at >= m.start &&
            removed.at <= m.end,
      )) {
        continue;
      }
      deletions.add((
        at: moveBoundary(removed.at),
        start: removed.start,
        end: removed.end,
      ));
    }
    text = buffer.toString();
    _starts = starts;
    _ends = ends;
    _deletions = deletions;
  }

  bool _isProtected(int start, int end) {
    var sourceStart = _original.length;
    var sourceEnd = 0;
    for (var i = start; i < end; i++) {
      if (_starts[i] < sourceStart) sourceStart = _starts[i];
      if (_ends[i] > sourceEnd) sourceEnd = _ends[i];
    }
    return _protected.any(
      (range) => range.$1 < sourceEnd && range.$2 > sourceStart,
    );
  }

  static List<(int, int)> _literalRanges(String text) {
    final ranges = <(int, int)>[];
    final patterns = <RegExp>[
      RegExp(r'`[^`\n]*`'),
      RegExp(r'"[^"\n]*[\\/][^"\n]*"|\x27[^\x27\n]*[\\/][^\x27\n]*\x27'),
      RegExp(r'(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/]|\\\\|/)[^\s,;]+'),
      RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,3})?\b'),
      RegExp(r'\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', caseSensitive: false),
      RegExp(
        r'(?<![A-Za-z0-9])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:/\d{1,3})?(?![A-Za-z0-9])',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:R|SW|PC|SRV)\d{1,3}\b', caseSensitive: false),
      RegExp(
        r'\b(?:FastEthernet|GigabitEthernet|TenGigabitEthernet|TwentyFiveGigE|HundredGigE|Ethernet|Serial|Async|Fa|Gi|Te|Eth|Se|F|G|S|Vlan|Console|Aux(?:iliary)?|USB|Coax(?:ial)?|Port)\s*\d+(?:/\d+){0,3}\b',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:GPIO|D|A)\d+\b', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        ranges.add((match.start, match.end));
      }
    }
    final valuePatterns = <RegExp>[
      RegExp(
        r'\b(?:ssid|network\s+name)\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\r\n,;`"\x27]+)',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:password|passphrase|psk|pre-shared\s+key)\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\s,;`"\x27]+)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in valuePatterns) {
      for (final match in pattern.allMatches(text)) {
        final rawGroup = match.group(1);
        if (rawGroup == null || rawGroup.trim().isEmpty) continue;
        final group = rawGroup.trim();
        final start = match.start + match[0]!.lastIndexOf(group);
        ranges.add((start, start + group.length));
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    return ranges;
  }

  static List<(int, int)> _opaqueValueRanges(String text) {
    final ranges = <(int, int)>[];
    final patterns = <RegExp>[
      RegExp(
        r'\b(?:ssid|network\s+name)\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\r\n,;`"\x27]+)',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(?:password|passphrase|psk|pre-shared\s+key)\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\s,;`"\x27]+)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        final rawValue = match.group(1);
        if (rawValue == null || rawValue.trim().isEmpty) continue;
        final value = rawValue.trim();
        final start = match.start + match[0]!.lastIndexOf(value);
        ranges.add((start, start + value.length));
      }
    }
    return ranges;
  }

  NormalizedMessage finish() {
    final segments = <NormalizationSegment>[];
    var i = 0;
    while (i < text.length) {
      final begin = i;
      final sourceStart = _starts[i];
      var sourceEnd = _ends[i];
      final copied = sourceEnd == sourceStart + 1;
      i++;
      while (i < text.length) {
        final previousStart = _starts[i - 1];
        final currentStart = _starts[i];
        final currentEnd = _ends[i];
        final joinsCopy =
            copied &&
            currentEnd == currentStart + 1 &&
            currentStart == previousStart + 1;
        final joinsReplacement =
            !copied && currentStart == sourceStart && currentEnd == sourceEnd;
        if (!joinsCopy && !joinsReplacement) break;
        if (joinsCopy) sourceEnd = currentEnd;
        i++;
      }
      final normalizedLength = i - begin;
      final sourceLength = sourceEnd - sourceStart;
      final kind = copied && normalizedLength == sourceLength
          ? NormalizationSegmentKind.copied
          : normalizedLength > sourceLength
          ? NormalizationSegmentKind.expansion
          : NormalizationSegmentKind.replacement;
      segments.add(
        NormalizationSegment(
          normalizedStart: begin,
          normalizedEnd: i,
          originalStart: sourceStart,
          originalEnd: sourceEnd,
          kind: kind,
        ),
      );
    }
    segments.addAll(
      _deletions.map(
        (item) => NormalizationSegment(
          normalizedStart: item.at,
          normalizedEnd: item.at,
          originalStart: item.start,
          originalEnd: item.end,
          kind: NormalizationSegmentKind.deletion,
        ),
      ),
    );
    segments.sort((a, b) {
      final offset = a.normalizedStart.compareTo(b.normalizedStart);
      return offset != 0 ? offset : a.originalStart.compareTo(b.originalStart);
    });
    return NormalizedMessage(
      originalText: _original,
      normalizedText: text,
      segments: segments,
      opaqueSourceRanges: _opaque,
    );
  }
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
  '${deviceKinds.expand((k) => k.keywords)
  // Plural-tolerant: "2 routers" must count, and \brouter\b alone
  // would not match it.
  .map((k) => '${RegExp.escape(k)}(?:es|s)?').join('|')}'
  ')\\b)',
);

final RegExp _deviceLabel = RegExp(
  r'\b(?:R|SW|PC|SRV)\d{1,2}\b',
  caseSensitive: false,
);

/// True when [lower] mentions a device kind or a label like R1 / SW2 /
/// PC3 / SRV1. Pure; see [namesAnyDevice].
bool namesAnyDeviceIn(String lower) =>
    namesAnyDevice.hasMatch(lower) || _deviceLabel.hasMatch(lower);

/// A server label whose name says which service it runs: DHCP1, DNS1,
/// WEB1, AAA1, FTP1, MAIL1, NTP1 ...

/// The learned-phrasing hop, run once at the top of every parse.
NetworkIntent parseBrief(String projectName, String rawText) {
  final request = PtBriefRequest.read(rawText);
  return request.apply(
    _parseGeneralBrief(
      projectName,
      request.plannerText,
      request.routerModelHint,
    ),
  );
}

Map<String, dynamic> _parseInBackground(List<String> request) =>
    parseBrief(request[0], request[1]).toJson();

Future<NetworkIntent> parseBriefAsync(
  String projectName,
  String rawText,
) async {
  if (rawText.length < 1200) return parseBrief(projectName, rawText);
  // Learned phrasing belongs to the main session's index. Preserve its
  // existing one-hop behavior when a stored correction applies.
  if (PhrasingMemoryService.lookupMatch(bridgeBrief(rawText)) != null) {
    return parseBrief(projectName, rawText);
  }
  return NetworkIntent.fromJson(
    await compute(_parseInBackground, [projectName, rawText]),
  );
}

NetworkIntent _parseGeneralBrief(
  String projectName,
  String rawText,
  String? routerModelHint,
) {
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
      return NetworkIntent.parseBridged(
        projectName,
        bridgeBrief(replay.rewrite),
        rawText,
      );
    }
    // A NEAR TWIN is not the same request: the wording differs exactly
    // where the user said something new. The remembered resolution is
    // read FIRST (the parser reads the first count per kind), and the
    // user's own words stay whole after it, so any device, service, site,
    // address, model or constraint named in this message survives the
    // match instead of being replaced by what was learned earlier.
    final merged = '${replay.rewrite} $bridged';
    final intent = NetworkIntent.parseBridged(
      projectName,
      bridgeBrief(merged),
      rawText,
    );
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
  return NetworkIntent.parseBridged(
    projectName,
    bridged,
    rawText,
    routerModelHint,
  );
}
