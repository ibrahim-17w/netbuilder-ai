/// Turns the way a person actually types into text the planner and the
/// assistant can both use: lowercase, typos, shorthand and filler are all
/// normal here.
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
  };

  static const List<String> _filler = [
    'and other stuff', 'or something', 'make it normal', 'kinda', 'sorta',
    'basically', 'you know', 'i mean', 'just', 'please', 'thanks',
    'thank you', 'so yeah', 'ok so',
  ];

  static final RegExp _dataToken = RegExp(r'[\d/@]');
  static final RegExp _edges = RegExp(r'^[^A-Za-z0-9]+|[^A-Za-z0-9]+$');
  static final RegExp _mixed = RegExp(r'^(?=.*[a-z])(?=.*[A-Z]).*$');

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
      final core = token.replaceAll(_edges, '');
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
          : (_typos[core.toLowerCase()] ?? _shorthand[core.toLowerCase()]);
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
}
