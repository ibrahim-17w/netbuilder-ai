/// Fuzzy word matching: what a person meant, even when they typed it wrong.
///
/// The planner used a hand-written typo table (~30 entries), so `switsh`,
/// `rotuer`, `routas` or `sevr` were simply not words and the count quietly
/// fell back to one - a brief asking for two switches became a plan with a
/// single switch, and nothing told the user. A table cannot cover a language;
/// edit distance can, provided it is bounded so it never invents a device from
/// an unrelated word.
///
/// Rules that keep this honest:
///
/// * a match is only made when the candidate is a KNOWN term, and only within
///   a distance budget scaled to the word's length (so short words need to be
///   nearly exact and long ones may drift by a character or two);
/// * the FIRST letter must match. This is a cheap, powerful guard: it stops
///   `pc` matching `vc`, and stops `hat` matching `cat`, while still accepting
///   the overwhelming majority of real typos (which preserve the first letter
///   or swap adjacent ones);
/// * ambiguous results are rejected. If two different known terms are equally
///   close, the word is not guessed at;
/// * anything carrying a digit, slash or `@` is never touched - an address, a
///   model number or a password must survive byte-for-byte.
///
/// Pure and dependency-free, so it is trivially testable and cannot reach the
/// network.
class FuzzyMatch {
  const FuzzyMatch._();

  /// The vocabulary a typo may be corrected to. Deliberately the *planner's*
  /// words: device kinds, the design terms the brief uses, and the routing
  /// protocols. Nothing here is a value the user supplies.
  static const Map<String, String> terms = {
    // Device kinds (singular -> canonical, plurals are handled separately).
    'router': 'router',
    'switch': 'switch',
    'pc': 'pc',
    'server': 'server',
    'laptop': 'laptop',
    'printer': 'printer',
    'firewall': 'firewall',
    'cloud': 'cloud',
    'modem': 'modem',
    'phone': 'phone',
    'tablet': 'tablet',
    'smartphone': 'smartphone',
    'access point': 'access point',
    'wireless': 'wireless',
    'host': 'host',
    'workstation': 'pc',
    'notebook': 'laptop',
    'asa': 'asa',
    // Routing / design terms.
    'ospf': 'ospf',
    'eigrp': 'eigrp',
    'bgp': 'bgp',
    'static': 'static',
    'rip': 'rip',
    'vlan': 'vlan',
    'trunk': 'trunk',
    'subnet': 'subnet',
    'gateway': 'gateway',
    'dhcp': 'dhcp',
    'dns': 'dns',
    'nat': 'nat',
    'acl': 'acl',
    'ssh': 'ssh',
    'telnet': 'telnet',
    'ipv6': 'ipv6',
    'ospfv3': 'ospfv3',
    'hsrp': 'hsrp',
    'spanning': 'spanning',
    'serial': 'serial',
    'fiber': 'fiber',
    'crossover': 'crossover',
    'router-on-a-stick': 'router-on-a-stick',
  };

  /// The distance budget for a word of this length.
  ///
  /// Short words are dangerous to fuzz. `aaa`/`asa`, `nat`/`mat`, `pc`/`vc`
  /// are one edit apart and mean completely different things, so words of
  /// three letters or fewer are NEVER fuzzed by distance - they must match
  /// the table exactly. 4-5 letters get 1 edit, 6-7 get 2, 8+ get 3: roughly
  /// one per three characters, which is where typos actually live.
  static int budgetFor(int length) {
    if (length <= 3) return 0;
    if (length <= 5) return 1;
    if (length <= 7) return 2;
    return 3;
  }

  /// Levenshtein distance, iterative with two rows (O(min) memory).
  static int distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > 4) return 99;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = _min3(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
      }
      final swap = prev;
      prev = curr;
      curr = swap;
    }
    return prev[b.length];
  }

  static int _min3(int a, int b, int c) {
    var m = a < b ? a : b;
    return m < c ? m : c;
  }

  /// True when [word] must never be fuzzed: it carries data, or it is
  /// mixed-case and therefore deliberate (a password, a hostname).
  static bool isProtected(String word) {
    if (word.isEmpty) return true;
    if (RegExp(r'[\d/@]').hasMatch(word)) return true;
    if (RegExp(r'^(?=.*[a-z])(?=.*[A-Z]).*$').hasMatch(word)) return true;
    return false;
  }

  /// Ordinary English words that must NEVER be corrected, however close they
  /// sit to a known term. `model` is one edit from `modem`, `part` one from
  /// `nat`, `lost` one from `host` - correcting those would turn a sentence
  /// about something else into a device the user never asked for. A real word
  /// is treated as deliberate; only a word that is NOT in this list may be
  /// fuzzed.
  static const Set<String> _realWords = {
    'model',
    'mode',
    'modal',
    'part',
    'port',
    'post',
    'past',
    'lost',
    'list',
    'last',
    'host',
    'most',
    'much',
    'must',
    'just',
    'nest',
    'next',
    'test',
    'text',
    'rest',
    'best',
    'west',
    'east',
    'cost',
    'cast',
    'case',
    'care',
    'core',
    'more',
    'some',
    'same',
    'name',
    'game',
    'gate',
    'late',
    'rate',
    'date',
    'data',
    'made',
    'make',
    'take',
    'lake',
    'like',
    'life',
    'live',
    'line',
    'link',
    'ling',
    'long',
    'land',
    'hand',
    'hard',
    'head',
    'heat',
    'seat',
    'send',
    'sent',
    'went',
    'were',
    'well',
    'will',
    'wall',
    'walk',
    'talk',
    'tall',
    'call',
    'fall',
    'full',
    'pull',
    'push',
    'pass',
    'pick',
    'pack',
    'packet',
    'plan',
    'play',
    'place',
    'space',
    'spare',
    'share',
    'sharp',
    'ship',
    'shop',
    'show',
    'slow',
    'grow',
    'grew',
    'grey',
    'gray',
    'day',
    'way',
    'say',
    'may',
    'man',
    'men',
    'run',
    'ran',
    'sun',
    'son',
    'sin',
    'sit',
    'set',
    'sat',
    'saw',
    'see',
    'sew',
    'new',
    'now',
    'not',
    'nor',
    'for',
    'far',
    'fat',
    'fit',
    'fix',
    'six',
    'mix',
    'max',
    'box',
    'fox',
    'top',
    'tip',
    'tap',
    'map',
    'cap',
    'cup',
    'cut',
    'put',
    'out',
    'our',
    'own',
    'old',
    'odd',
    'add',
    'all',
    'air',
    'any',
    'and',
    'the',
    'this',
    'that',
    'then',
    'than',
    'they',
    'them',
    'with',
    'without',
    'from',
    'into',
    'onto',
    'over',
    'under',
    'about',
    'above',
    'below',
    'between',
    'through',
    'during',
    'before',
    'after',
    'again',
    'against',
    'because',
    'while',
    'where',
    'when',
    'what',
    'which',
    'who',
    'how',
    'why',
    'also',
    'only',
    'other',
    'another',
    'each',
    'both',
    'few',
    'many',
    'such',
    'no',
    'too',
    'very',
    'please',
    'help',
    'need',
    'build',
    'create',
    'setup',
    'small',
    'large',
    'little',
    'big',
    'simple',
    'basic',
    'normal',
    'sample',
    'whole',
    'total',
    'entire',
    'complete',
    'finished',
    'ready',
    'good',
    'great',
    'nice',
    'okay',
    'sure',
    'right',
    'left',
    'side',
    'sides',
    'using',
    'used',
    'plus',
    'minus',
    'times',
    'per',
    'via',
  };

  /// True when the word is a real English word (so not a typo to fix).
  static bool isRealWord(String word) => _realWords.contains(word);

  /// The canonical term [word] most likely meant, or null when nothing is
  /// close enough (or two things are equally close).
  ///
  /// [word] should be lowercase, punctuation-free. Digits/slashes/@ are
  /// refused up front, as is any real English word. The first letter must
  /// match, and the nearest candidate must be strictly nearer than the
  /// runner-up, so no coin-flip guesses.
  static String? correct(String word) {
    final w = word.trim().toLowerCase();
    if (w.isEmpty || isProtected(w)) return null;
    if (terms.containsKey(w)) return terms[w];
    // A real word is not a typo. This is what stops `model` -> `modem` and
    // `part` -> `nat`: they are one edit apart, but both are words a person
    // meant, and the app must not overwrite them.
    if (_realWords.contains(w)) return null;

    // GRAMMAR is not a typo. `trunking` is `trunk` with an `-ing` on it, and
    // `configured` is `configure` with `-ed`; fuzzing the whole word instead
    // of its stem turned "explain vlan trunking" into "explain vlan trunk",
    // which reads oddly and can miss a knowledge match. The stem is tried
    // first, and only its RESULT is returned (not the suffixed form).
    final stem = _stripSuffix(w);
    if (stem != null && stem != w) {
      if (terms.containsKey(stem)) return terms[stem];
      if (!_realWords.contains(stem)) {
        final fixed = _nearest(stem);
        if (fixed != null) return fixed;
      }
    }

    // A plural typo is corrected on its singular, then re-pluralized, so
    // `switshs` -> `switches` rather than the nonsense `switchs`. The same
    // re-pluralization must apply when the plain match lands on a singular
    // from a plural input (`pcs` -> `pc` would drop a device), which is why
    // the result is always passed through [_pluralize].
    final singular = _singularOf(w);
    final isPlural = singular != w;
    if (isPlural && !_realWords.contains(singular)) {
      final fixed = _nearest(singular);
      if (fixed != null) return _pluralize(fixed, w);
    }
    if (isPlural) {
      // Never de-pluralize: match the plural as-is and, if it lands on a
      // singular term, put the plural back.
      final fixed = _nearest(w);
      if (fixed != null) return _pluralize(fixed, w);
      return null;
    }
    return _nearest(w);
  }

  /// An English grammatical suffix, when the word is long enough that removing
  /// it still leaves a real stem. Returns null when there is no such suffix -
  /// only the endings that actually attach to these nouns and verbs.
  static String? _stripSuffix(String w) {
    for (final suffix in const ['ing', 'ed', 'ly', 'es', 's']) {
      if (!w.endsWith(suffix)) continue;
      final stem = w.substring(0, w.length - suffix.length);
      if (stem.length < 3) continue;
      // `-s`/`-es` are handled by the plural path; here we only want the
      // endings that are unambiguously a different word form.
      if (suffix == 's' || suffix == 'es') continue;
      return stem;
    }
    return null;
  }

  static String? _nearest(String w) {
    final budget = budgetFor(w.length);
    if (budget == 0) return null;
    final byDistance = _nearestByDistance(w, budget);
    if (byDistance != null) return byDistance;
    // VOWEL-DROP SHORTHAND: `srvr`, `swtch`, `rtr` are how people abbreviate
    // under time pressure, and pure edit distance counts each dropped vowel as
    // a separate error, so `srvr` (3 edits from `server`) misses a budget of
    // 2 even though it is unambiguous. Comparing the consonant skeletons
    // catches these without loosening the general budget.
    return _nearestBySkeleton(w);
  }

  static String? _nearestByDistance(String w, int budget) {
    String? best;
    var bestDist = budget + 1;
    var ties = 0;
    for (final term in terms.keys) {
      // The first letter guard: cheap and it kills most false positives.
      if (term[0] != w[0]) continue;
      final d = distance(w, term);
      if (d > budget) continue;
      if (d < bestDist) {
        bestDist = d;
        best = term;
        ties = 1;
      } else if (d == bestDist) {
        ties++;
      }
    }
    // Two equally close known terms is not a correction, it is a guess.
    if (best == null || ties > 1) return null;
    return terms[best];
  }

  /// The word's letters with the vowels removed (and doubled letters folded),
  /// e.g. `srvr` and `server` both give `srvr`.
  static String _skeleton(String w) {
    final out = StringBuffer();
    for (final ch in w.split('')) {
      if ('aeiou'.contains(ch)) continue;
      if (out.isNotEmpty && out.toString().endsWith(ch)) continue;
      out.write(ch);
    }
    return out.toString();
  }

  static String? _nearestBySkeleton(String w) {
    // Only words of a real length matter here, and only when the word has
    // FEWER vowels than the term it might be - that is what "dropped vowels"
    // means. `srvr` has none (so it may match `server`, whose skeleton is also
    // `srvr`); an ordinary word like `seat` keeps its vowels and is left
    // alone.
    if (w.length < 4) return null;
    final skel = _skeleton(w);
    if (skel.length < 3) return null;
    String? best;
    var ties = 0;
    for (final term in terms.keys) {
      if (term[0] != w[0]) continue;
      if (_skeleton(term) != skel) continue;
      if (best == null) {
        best = term;
        ties = 1;
      } else if (best != term) {
        ties++;
      }
    }
    if (best == null || ties > 1) return null;
    return terms[best];
  }

  /// A crude singular: strips a plural ending so the fuzzy match runs against
  /// the word the vocabulary actually stores.
  static String _singularOf(String w) {
    if (w.endsWith('ies') && w.length > 4) {
      return '${w.substring(0, w.length - 3)}y';
    }
    if (w.endsWith('es') && w.length > 3) return w.substring(0, w.length - 2);
    if (w.endsWith('s') && w.length > 2 && !w.endsWith('ss')) {
      return w.substring(0, w.length - 1);
    }
    return w;
  }

  /// Put the plural back the way English spells it, if the original was
  /// plural. Keeps `switch` -> `switches` correct.
  static String _pluralize(String canonical, String original) {
    final wasPlural = original != _singularOf(original);
    if (!wasPlural) return canonical;
    if (canonical.endsWith('s')) return canonical;
    for (final ending in const ['ch', 'sh', 'ss', 's', 'x', 'z']) {
      if (canonical.endsWith(ending)) return '${canonical}es';
    }
    // "access point" -> "access points"
    if (canonical.contains(' ')) {
      final parts = canonical.split(' ');
      parts[parts.length - 1] = '${parts.last}s';
      return parts.join(' ');
    }
    return '${canonical}s';
  }
}
