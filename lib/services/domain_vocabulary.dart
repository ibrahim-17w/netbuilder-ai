import '../models/network_intent.dart';

/// Everyday English words, resolved to what a network plan means by them.
///
/// The parser already knows the technical vocabulary - `router`, `switch`,
/// `ospf`, `dhcp`. What it does not know is the words a person actually says
/// out loud: "an office with 15 staff", "a few guest laptops", "a branch
/// site", "a classroom lab". Those words were dropped on the floor, so the
/// device they named never reached the plan.
///
/// Everything here is deterministic and conservative, in the same spirit as
/// [CasualEnglish]: a word is only mapped when it means one thing in this
/// domain. Nothing rewrites the user's text - [NetworkIntent.bridgeBrief] is
/// left exactly as typed, because the brief is shown back to the user and
/// quietly editing it is how a plan stops being the plan that was asked for.
/// This only answers "what does this word stand for", and the caller decides
/// whether to act on it.
///
/// The table is also LEARNABLE. [learn] records a word a user taught the app,
/// and a learned word is consulted before the built-in one, so correcting the
/// app once fixes every later brief. That is the whole point: the vocabulary
/// grows from corrections instead of from a list someone guessed at.
class DomainVocabulary {
  const DomainVocabulary._();

  // --- everyday words that mean a device ------------------------------------

  /// Words that stand for a device kind, keyed by the kind they stand for.
  /// Only one-directional aliases live here - `pc` is a device, but the word
  /// `staff` is not a device, it is a group of them (see [_groupWords]).
  static const Map<String, List<String>> _deviceWords = <String, List<String>>{
    'pc': <String>[
      'desktop',
      'workstation',
      'computer',
      'pc',
      'tower',
      'imac',
    ],
    'laptop': <String>[
      'laptop',
      'notebook',
      'macbook',
      'thinkpad',
    ],
    'tablet': <String>['tablet', 'ipad'],
    'phone': <String>[
      'phone',
      'ip phone',
      'ipphone',
      'voip phone',
      'voip',
      'handset',
      'softphone',
    ],
    'printer': <String>['printer', 'print', 'printout', 'scanner'],
    'server': <String>[
      'server',
      'host',
      'file server',
      'app server',
      'application server',
      'web server',
      'database server',
      'db server',
      'mail server',
      'exchange',
    ],
    'switch': <String>['switch', 'switchbox'],
    'router': <String>['router', 'gateway', 'gateway router'],
    'firewall': <String>['firewall', 'fw', 'asa'],
    'wireless': <String>[
      'access point',
      'accesspoint',
      'wifi',
      'wi-fi',
      'wireless',
      'ap',
      'hotspot',
    ],
    'wireless-router': <String>['wireless router', 'home router'],
    'cloud': <String>['cloud', 'internet', 'isp', 'wan'],
    'camera': <String>['camera', 'cctv', 'ip camera'],
    'iot': <String>['sensor', 'sensors', 'thermostat', 'smart light'],
  };

  /// Words that stand for a GROUP of users, and the device each usually means.
  ///
  /// "15 staff" is 15 computers; "8 guest laptops" is 8 laptops. The group
  /// word carries the quantity and the noun beside it carries the device,
  /// which is why these resolve through [deviceTypeForWord] rather than
  /// counting as devices themselves.
  static const Map<String, String> _groupWords = <String, String>{
    'staff': 'pc',
    'employee': 'pc',
    'employees': 'pc',
    'worker': 'pc',
    'workers': 'pc',
    'user': 'pc',
    'users': 'pc',
    'staff member': 'pc',
    'office worker': 'pc',
    'guest': 'pc',
    'guests': 'pc',
    'visitor': 'pc',
    'visitors': 'pc',
    'customer': 'pc',
    'customers': 'pc',
    'student': 'pc',
    'students': 'pc',
    'pupil': 'pc',
    'teacher': 'pc',
    'staff laptop': 'laptop',
    'staff laptops': 'laptop',
    'guest laptop': 'laptop',
    'guest laptops': 'laptop',
    'user laptop': 'laptop',
    'user laptops': 'laptop',
  };

  // --- everyday words that mean a service ----------------------------------

  /// Words that mean a server service, keyed by the service role the rest of
  /// the app already speaks.
  static const Map<String, String> _serviceWords = <String, String>{
    'addressing': 'dhcp',
    'ip address': 'dhcp',
    'ip addresses': 'dhcp',
    'addresses': 'dhcp',
    'address assignment': 'dhcp',
    'automatic addressing': 'dhcp',
    'name resolution': 'dns',
    'nameserver': 'dns',
    'name server': 'dns',
    'domain name': 'dns',
    'web': 'http',
    'website': 'http',
    'webserver': 'http',
    'web page': 'http',
    'web pages': 'http',
    'intranet': 'http',
    'portal': 'http',
    'login': 'aaa',
    'log in': 'aaa',
    'authentication': 'aaa',
    'authorization': 'aaa',
    'authorisation': 'aaa',
    'single sign on': 'aaa',
    'sso': 'aaa',
    'central authentication': 'aaa',
    'accounting': 'aaa',
    'email': 'email',
    'e-mail': 'email',
    'mail': 'email',
    'mailbox': 'email',
    'exchange server': 'email',
    'file transfer': 'ftp',
    'files': 'ftp',
    'shared folder': 'ftp',
    'share': 'ftp',
    'shared drive': 'ftp',
    'time sync': 'ntp',
    'time server': 'ntp',
    'clock': 'ntp',
    'logging': 'syslog',
    'log server': 'syslog',
    'audit trail': 'syslog',
    'monitoring': 'snmp',
    'network management': 'snmp',
    'automation': 'iot',
    'sensors': 'iot',
    'smart building': 'iot',
  };

  // --- everyday words that mean a place ------------------------------------

  /// Words that describe what a site IS, which is what a design cares about:
  /// a branch and a warehouse want different things from a datacenter.
  static const Map<String, String> _siteWords = <String, String>{
    'hq': 'headquarters',
    'headquarters': 'headquarters',
    'head office': 'headquarters',
    'main office': 'headquarters',
    'central office': 'headquarters',
    'corporate office': 'headquarters',
    'head end': 'headquarters',
    'branch': 'branch',
    'branch office': 'branch',
    'remote office': 'branch',
    'satellite office': 'branch',
    'small office': 'branch',
    'soho': 'soho',
    'home office': 'soho',
    'work from home': 'soho',
    'campus': 'campus',
    'university': 'campus',
    'college': 'campus',
    'school': 'campus',
    'lab': 'lab',
    'laboratory': 'lab',
    'classroom': 'classroom',
    'lecture hall': 'classroom',
    'training room': 'classroom',
    'server room': 'datacenter',
    'data center': 'datacenter',
    'datacentre': 'datacenter',
    'warehouse': 'warehouse',
    'store': 'retail',
    'shop': 'retail',
    'retail': 'retail',
    'supermarket': 'retail',
    'factory': 'industrial',
    'plant': 'industrial',
    'workshop': 'industrial',
    'hospital': 'healthcare',
    'clinic': 'healthcare',
  };

  /// Words that describe the SIZE of what was asked for. Not a device and not
  /// a site: it is how a design should be sized and how much redundancy it
  /// should carry.
  static const Map<String, String> _sizeWords = <String, String>{
    'tiny': 'tiny',
    'micro': 'tiny',
    'minimal': 'tiny',
    'starter': 'small',
    'small': 'small',
    'little': 'small',
    'modest': 'small',
    'basic': 'small',
    'simple': 'small',
    'medium': 'medium',
    'normal': 'medium',
    'mid size': 'medium',
    'standard': 'medium',
    'average': 'medium',
    'large': 'large',
    'big': 'large',
    'huge': 'large',
    'enterprise': 'large',
    'corporate': 'large',
    'campus wide': 'large',
    'production': 'large',
  };

  // --- learned words --------------------------------------------------------

  /// Words the user taught the app, newest last. A learned word is consulted
  /// BEFORE the built-in tables, so a correction the user made once outranks
  /// whatever the table guessed.
  static final Map<String, String> _learned = <String, String>{};

  /// Concepts a learned word may point at. A correction that names a concept
  /// nobody understands is ignored rather than stored, so the vocabulary can
  /// never be taught into a state where every brief resolves to nothing.
  static final Set<String> knownConcepts = <String>{
    ..._deviceWords.keys,
    ..._serviceWords.values,
    ..._siteWords.values,
    ..._sizeWords.values,
    'host',
    'unknown',
  };

  /// Record that [word] means [concept].
  ///
  /// Returns false - and changes nothing - when the word is empty, the
  /// concept is not one the app understands, or the word is one of the
  /// load-bearing technical terms ([_protectedWords]) where a "correction"
  /// would silently break every brief that uses the term correctly.
  static bool learn(String word, String concept) {
    final key = _key(word);
    final target = concept.trim().toLowerCase();
    if (key.isEmpty || target.isEmpty) return false;
    if (!knownConcepts.contains(target)) return false;
    if (_protectedWords.contains(key)) return false;
    _learned[key] = target;
    return true;
  }

  /// Forget everything the app was taught. The built-in table is untouched.
  static void reset() => _learned.clear();

  /// Every learned word, for the screen that shows and clears them.
  static Map<String, String> get learned => Map<String, String>.unmodifiable(_learned);

  /// The learned table as one JSON-ready map, for persistence.
  static Map<String, String> snapshot() => Map<String, String>.from(_learned);

  /// Put learned words back, dropping anything that no longer makes sense.
///
/// Takes a raw map because it comes straight out of storage: a non-string key
/// or a non-string value is skipped, never coerced.
  static void restore(Map<dynamic, dynamic>? raw) {
    _learned.clear();
    if (raw == null) return;
    raw.forEach((key, value) {
      if (key is String && value is String) learn(key, value);
    });
  }

  /// Words that must never be remapped: the technical terms the whole
  /// pipeline is built on. "server" means a Server-PT here even when someone
  /// says "web server", and "switch" means a switch even in a sentence that
  /// also mentions power.
  static const Set<String> _protectedWords = <String>{
    'server', 'router', 'switch', 'firewall', 'cloud', 'printer', 'tablet',
    'phone', 'camera', 'pc', 'laptop', 'ap', 'gateway', 'host',
  };

  static String _key(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9+\- ]'), '');

  // --- resolution -----------------------------------------------------------

  /// The device kind [word] stands for, or empty.
  ///
  /// Learned first, then the group words (which carry a device), then the
  /// device words. Multi-word phrases are tried before single words, because
  /// "access point" must not be read as the word "point".
  static String deviceTypeForWord(String raw) {
    final key = _key(raw);
    if (key.isEmpty) return '';
    final learned = _learned[key];
    if (learned != null && _deviceWords.containsKey(learned)) return learned;

    for (final phrase in _phrasesFor(key)) {
      final group = _groupWords[phrase];
      if (group != null) return group;
    }
    for (final phrase in _phrasesFor(key)) {
      for (final entry in _deviceWords.entries) {
        if (entry.value.contains(phrase)) return entry.key;
      }
    }
    return '';
  }

  /// The service role [word] stands for, or empty.
  static String serviceRoleForWord(String raw) {
    final key = _key(raw);
    if (key.isEmpty) return '';
    final learned = _learned[key];
    if (learned != null && _serviceWords.containsValue(learned)) return learned;

    // Longest first: "web server" must not be read as "web" when the whole
    // phrase means something more specific.
    final phrases = _phrasesFor(key).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final phrase in phrases) {
      final role = _serviceWords[phrase];
      if (role != null) return role;
    }
    return '';
  }

  /// What kind of place [word] names, or empty.
  static String siteKindForWord(String raw) {
    final key = _key(raw);
    if (key.isEmpty) return '';
    final learned = _learned[key];
    if (learned != null && _siteWords.containsValue(learned)) return learned;
    final phrases = _phrasesFor(key).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final phrase in phrases) {
      final kind = _siteWords[phrase];
      if (kind != null) return kind;
    }
    return '';
  }

  /// How big a thing [word] says this is, or empty.
  static String sizeForWord(String raw) {
    final key = _key(raw);
    if (key.isEmpty) return '';
    final learned = _learned[key];
    if (learned != null && _sizeWords.containsValue(learned)) return learned;
    for (final phrase in _phrasesFor(key)) {
      final size = _sizeWords[phrase];
      if (size != null) return size;
    }
    return '';
  }

  /// Every device word the brief contains, mapped to its kind - including the
  /// learned ones, which is how a taught word starts counting devices.
  ///
  /// This is the seam the count extractor uses: it asks for the everyday words
  /// that mean a device and then counts them with the same quantity rules it
  /// already applies to the technical ones.
  static Map<String, List<String>> everydayDeviceWords() {
    final out = <String, List<String>>{};
    void add(String type, String word) {
      if (word.isEmpty) return;
      (out[type] ??= <String>[]).add(word);
    }

    for (final entry in _deviceWords.entries) {
      for (final word in entry.value) {
        add(entry.key, word);
      }
    }
    for (final entry in _groupWords.entries) {
      // A group word implies a device, but only when the brief does not name
      // one beside it ("8 guest laptops" is laptops, not pcs), so the implied
      // kind is offered as a WEAKER alias and loses to a real noun.
      add(entry.value, entry.key);
    }
    for (final entry in _learned.entries) {
      if (_deviceWords.containsKey(entry.value)) add(entry.value, entry.key);
    }
    for (final list in out.values) {
      list.sort((a, b) => b.length.compareTo(a.length));
    }
    return out;
  }

  /// Every service word the brief can mean, learned ones included.
  static Map<String, List<String>> everydayServiceWords() {
    final out = <String, List<String>>{};
    for (final entry in _serviceWords.entries) {
      (out[entry.value] ??= <String>[]).add(entry.key);
    }
    for (final entry in _learned.entries) {
      if (_serviceWords.containsValue(entry.value)) {
        (out[entry.value] ??= <String>[]).add(entry.key);
      }
    }
    for (final list in out.values) {
      list.sort((a, b) => b.length.compareTo(a.length));
    }
    return out;
  }

  /// The site kinds named anywhere in [text], in the order they appear.
  static List<({String word, String kind, int offset})> siteKindsIn(String text) {
    final lower = text.toLowerCase();
    final found = <({String word, String kind, int offset})>[];
    for (final entry in _siteWords.entries) {
      final at = lower.indexOf(entry.key);
      if (at >= 0) {
        found.add((word: entry.key, kind: entry.value, offset: at));
      }
    }
    for (final entry in _learned.entries) {
      final kind = _siteWords.values.contains(entry.value) ||
              _groupWords.containsKey(entry.key)
          ? entry.value
          : '';
      if (kind.isEmpty) continue;
      final at = lower.indexOf(entry.key);
      if (at >= 0) {
        found.add((word: entry.key, kind: kind, offset: at));
      }
    }
    found.sort((a, b) => a.offset.compareTo(b.offset));
    return found;
  }

  /// The word's own multi-word phrases first, then the word itself, so a
  /// phrase never gets shredded into a shorter match.
  static Iterable<String> _phrasesFor(String key) sync* {
    final words = key.split(' ').where((w) => w.isNotEmpty).toList();
    for (var take = words.length; take >= 1; take--) {
      for (var start = 0; start + take <= words.length; start++) {
        yield words.sublist(start, start + take).join(' ');
      }
    }
  }
}