import 'fuzzy_match.dart';

/// Turns the way a person actually types into text the planner and the
/// assistant can both use: lowercase, typos, shorthand and filler are all
/// normal here.
///
/// Two layers of typo handling: an exact table for the mistakes seen most
/// often (which can map a misspelling onto a word with a different first
/// letter, e.g. `acess` -> `access`), and [FuzzyMatch] underneath it for
/// everything the table has never seen. The table is tried first because a
/// human-authored mapping is more trustworthy than a distance calculation;
/// the fuzzy layer is what stops an unseen typo from silently dropping a
/// device from the plan.
///
/// It is deliberately conservative about data. Any token carrying a digit, a
/// slash or an "@" (addresses, CIDRs, emails, hostnames with numbers) is left
/// exactly as typed, and a token with mixed upper/lower case is never
/// rewritten - so "2 routers", "192.168.1.0/24" and a password like
/// "LabAdmin2026" or "SecretPass" all survive untouched.
class CasualEnglish {
  const CasualEnglish._();

  static const Map<String, String> _shorthand = {
    'u': 'you', 'ur': 'your', 'urs': 'yours', 'pls': 'please', 'plz': 'please',
    'wanna': 'want to', 'gonna': 'going to', 'gotta': 'got to',
    'lemme': 'let me', 'idk': 'i do not know', 'im': 'i am', 'ive': 'i have',
    'dont': 'do not', 'doesnt': 'does not', 'cant': 'cannot', 'wont': 'will not',
    'isnt': 'is not', 'arent': 'are not', 'teh': 'the', 'tpo': 'to',
    'waht': 'what', 'wat': 'what', 'wut': 'what', 'b4': 'before', 'wid': 'with',
    'cuz': 'because', 'coz': 'because', 'thx': 'thanks', 'ty': 'thanks',
    'r': 'are', 'n': 'and', 'nd': 'and', 'abt': 'about',
  };

  static const Map<String, String> _typos = {
    'routr': 'router', 'routrs': 'routers', 'rouer': 'router',
    'swtich': 'switch', 'swich': 'switch', 'swtch': 'switch', 'switc': 'switch',
    'swtiches': 'switches', 'sevrer': 'server', 'srvr': 'server',
    'servr': 'server', 'acess': 'access', 'accss': 'access',
    'wirless': 'wireless', 'wireles': 'wireless', 'lapop': 'laptop',
    'labtop': 'laptop', 'priner': 'printer', 'vlna': 'vlan', 'osfp': 'ospf',
    'osf': 'ospf', 'trunck': 'trunk', 'gatway': 'gateway', 'subnt': 'subnet',
    'intrface': 'interface', 'interfce': 'interface',
    // Three-letter slips are too close to fuzz safely (`pss`/`pc` is two
    // edits but `aaa`/`asa` is one, and they mean different things), so the
    // common ones are asserted here by hand instead.
    'pss': 'pc', 'pcc': 'pc',
  };

  static const List<String> _filler = [
    'and other stuff', 'or something', 'make it normal', 'kinda', 'sorta',
    'basically', 'you know', 'i mean', 'just', 'please', 'thanks',
    'thank you', 'so yeah', 'ok so',
  ];

  static final RegExp _dataToken = RegExp(r'[\d/@]');
  static final RegExp _edges = RegExp(r'^[^A-Za-z0-9]+|[^A-Za-z0-9]+$');
  static final RegExp _mixed = RegExp(r'^(?=.*[a-z])(?=.*[A-Z]).*$');

  /// ".1" and ".11" are a shorthand host part - "with .1 as each gateway",
  /// "PC1-PC5 addresses .11-.15 on the R1 LAN" - and the leading dot is what
  /// says the number belongs to the subnet just named. Trimming it as
  /// punctuation left a bare "1", which reads as a device count, and turned
  /// the range into "11-.15".
  static final RegExp _shortHost = RegExp(r'^\.\d');

  /// "web.lab.test -> 192.168.10.103": the arrow is what says the first
  /// token is a name and the second an address. Dropped as punctuation, the
  /// pair became "web.lab.test 192.168.10.103" and no record could be read.
  static final RegExp _relation = RegExp(r'(?:->|=>|<-|>=|→)');

  /// A typo'd word's PLURAL is the same typo with an ending on it, and the
  /// table only ever listed the singular: "2 swtichs" was not a word the
  /// normalizer knew, so the switch count fell back to one - the brief asked
  /// for two switches and got a plan with one. The ending is put back the way
  /// English spells it, so `swtichs` becomes `switches`, not `switchs`.
  static String? _pluralTypo(String word) {
    String? fix(String base) {
      final mapped = _typos[base];
      if (mapped == null) return null;
      // A real word is not a typo'd singular. Mapping 'wireles' -> 'wireless'
      // and then putting an s back on it produced 'wirelesses', which matches
      // nothing: "a wireless router" was read as a wired one, and the
      // Wireless Router-PT the brief asked for was replaced by a plain 2911.
      // The suffix only goes back on a singular that does not already end in
      // one.
      if (mapped.endsWith('s')) return null;
      return _pluralOf(mapped);
    }

    if (word.endsWith('es')) {
      final fixed = fix(word.substring(0, word.length - 2));
      if (fixed != null) return fixed;
    }
    if (word.endsWith('s')) return fix(word.substring(0, word.length - 1));
    return null;
  }

  static String _pluralOf(String singular) {
    for (final ending in const ['ch', 'sh', 'ss', 's', 'x', 'z']) {
      if (singular.endsWith(ending)) return '${singular}es';
    }
    return '${singular}s';
  }

  static String normalize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final s = trimmed
        .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e]'), ' ')
        .replaceAll(RegExp(r'[!?.,;:]{2,}'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final out = <String>[];
    for (final token in s.split(' ')) {
      if (_relation.hasMatch(token)) {
        out.add(token);
        continue;
      }
      final core = _shortHost.hasMatch(token) ? token : token.replaceAll(_edges, '');
      if (core.isEmpty) continue;
      // Data (addresses, CIDRs, emails, quantities, password with digits) is
      // kept verbatim so nothing numeric is ever damaged.
      if (_dataToken.hasMatch(core)) {
        out.add(core);
        continue;
      }
      // Mixed-case words are treated as deliberate (a password, a hostname)
      // and never rewritten.
      final mapped = _mixed.hasMatch(core)
          ? null
          : (_typos[core.toLowerCase()] ??
              _shorthand[core.toLowerCase()] ??
              _pluralTypo(core.toLowerCase()) ??
              // Nothing in the tables knows this word. Before giving up on it,
              // ask the fuzzy matcher: an unseen typo (`switsh`, `rotuer`,
              // `sevr`) would otherwise stay an unknown word and the device it
              // names would drop out of the plan entirely.
              FuzzyMatch.correct(core));
      out.add(mapped ?? core);
    }
    var joined = out.join(' ');
    for (final f in _filler) {
      joined = joined.replaceAll(
        RegExp('(^|\\s)${RegExp.escape(f)}(?=\\s|\$)', caseSensitive: false),
        ' ',
      );
    }
    return joined.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // --- canonicalization ----------------------------------------------------
  // The offline knowledge table triggers on short forms ("bgp", "dhcp
  // relay") and fixed fault phrases ("red link"), while people type "border
  // gateway protocol" and "my pc never gets an ip". These maps rewrite the
  // long or casual phrasing onto tokens an entry ALREADY matches: a phrase
  // is only listed when its target appears in some entry's trigger list,
  // because a rewrite into a token no matcher knows would just move the
  // miss. The exceptions are the concept-owned tokens (nat, pat, acl, qos,
  // tcp): no table entry triggers on the bare token (only compound phrases
  // like "tcp adjust mss"), so emitting it is a no-op at the table and is
  // what lets the concept chain route the full name. UDP and ICMP have no
  // hook anywhere, so their names stay untouched.

  /// Full protocol names -> the short form a table matcher triggers on.
  static const Map<String, String> _protocolNames = {
    'rapid spanning tree protocol': 'rstp',
    'spanning tree protocol': 'stp',
    'border gateway protocol': 'bgp',
    'open shortest path first': 'ospf',
    'enhanced interior gateway routing protocol': 'eigrp',
    'dynamic host configuration protocol': 'dhcp',
    'domain name system': 'dns',
    'domain name server': 'dns',
    'network address translation': 'nat',
    'port address translation': 'pat',
    'access control list': 'acl',
    'quality of service': 'qos',
    'transmission control protocol': 'tcp',
    'virtual local area network': 'vlan',
    'virtual lan': 'vlan',
    'address resolution protocol': 'arp',
    'trivial file transfer protocol': 'tftp',
    'file transfer protocol': 'ftp',
    'simple network management protocol': 'snmp',
    'hot standby router protocol': 'hsrp',
    'virtual router redundancy protocol': 'vrrp',
    'network time protocol': 'ntp',
    // Already a literal trigger of the SSH entry; kept so both spellings of
    // the name normalize onto the same token.
    'secure shell': 'ssh',
    // The wireless triggers carry both spellings; 'wifi' is the majority
    // ('laptop to wifi', 'pc to wifi', 'tablet to wifi'), so the hyphenated
    // and split forms fold onto it.
    'wi-fi': 'wifi',
    'wi fi': 'wifi',
  };

  /// Casual fault phrasings -> the trigger text of the entry that answers
  /// them. '169.254' is the APIPA marker the ipconfig entry explains: an
  /// address of that shape means DHCP never answered - which is exactly
  /// what "the pc does not get an ip" is describing.
  static const Map<String, String> _faultPhrases = {
    'broadcast storm': 'rapid spanning tree',
    'rogue dhcp': 'dhcp snooping',
    'mac flapping': 'mac address table',
    'no internet access': 'no connectivity',
    'no internet': 'no connectivity',
    'never gets an ip': '169.254',
    'not get an ip': '169.254',
    'no ip address': '169.254',
    'cable shows red': 'red link',
    'link shows red': 'red link',
    // The wireless triggers carry the article ('connect to the wifi');
    // re-adding it keeps both spellings routing after the fold above.
    'connect to wifi': 'connect to the wifi',
    'connect to wi-fi': 'connect to the wifi',
    'join wifi': 'join the wifi',
    'join wi-fi': 'join the wifi',
    'secure wifi': 'secure the wifi',
    'secure wi-fi': 'secure the wifi',
  };

  /// The rules compiled once: longest key first (so "rapid spanning tree
  /// protocol" is replaced whole and never cut into "rapid stp" by the
  /// shorter rule running first), each as a whole-phrase pattern with \s+
  /// between words so a double space still matches, and an optional plural
  /// on the last word so "access control lists" is rewritten whole. Word
  /// boundaries keep a rewrite from landing inside a word ('\bnot get an
  /// ip\b' cannot match inside "cannot get an ip"), and every key is
  /// letters, spaces and hyphens, so no address or CIDR can contain one -
  /// data passes through byte for byte.
  static final List<(RegExp, String)> _canonicalRules = () {
    final entries = {..._protocolNames, ..._faultPhrases}.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    return [
      for (final e in entries)
        (
          RegExp(
            '\\b${e.key.split(' ').map(RegExp.escape).join(r'\s+')}s?\\b',
          ),
          e.value,
        ),
    ];
  }();

  /// The canonical form of [text]: full protocol names become the short
  /// token the knowledge table triggers on, and casual fault complaints
  /// become the phrase its entry matches. Pure and idempotent - no output
  /// contains a key, so running it twice changes nothing - and case is
  /// preserved: the caller lowercases first, and a mixed-case token is data
  /// by the same rule [normalize] applies.
  static String canonical(String text) {
    var t = text;
    for (final (pattern, to) in _canonicalRules) {
      t = t.replaceAll(pattern, to);
    }
    return t;
  }
}
