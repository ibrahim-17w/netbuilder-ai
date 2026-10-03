/// Reads a request to compile the standing plan into a `.pkt` file.
///
/// The keyless chat and the key-backed chat must read "build the .pkt" the
/// same way: whether a Gemini key happens to be set decides which engine
/// ANSWERS a message, never whether the app can ACT on one. This reader runs
/// before any model is consulted, so a pure build request compiles a file
/// either way.
///
/// It is deliberately strict. The message must be *only* the build request
/// (plus politeness), because a question about building ("how do I build the
/// .pkt?"), a deferral ("don't build it yet"), or a request that adds
/// devices ("build the .pkt for 2 routers") must be answered - not executed
/// against a plan they are trying to change.
class BuildRequestReader {
  /// Words a pure build request may contain. Anything else - a question
  /// word ("how", "why"), a refusal ("don't", "never"), or new devices
  /// ("2 routers") - fails the match on purpose: those messages are meant
  /// to be answered, not compiled.
  static const _allowed = <String>{
    // Verbs (every form a person would type).
    'build', 'builds', 'building', 'built',
    'compile', 'compiles', 'compiling', 'compiled',
    'generate', 'generates', 'generating', 'generated',
    'make', 'makes', 'making', 'made',
    'create', 'creates', 'creating', 'created',
    'write', 'writes', 'writing', 'written',
    'save', 'saves', 'saving', 'saved',
    'export', 'exports', 'exporting', 'exported',
    // The object being built.
    'pkt', '.pkt', 'packet', 'tracer', 'lab', 'project', 'projects',
    'file', 'files', 'topology',
    // Glue: articles, emphasis, politeness.
    'the', 'a', 'an', 'my', 'our', 'this', 'that', 'it', 'current',
    'standing', 'new', 'offline', 'now', 'please', 'pls', 'kindly',
    'just', 'for', 'me', 'up', 'and', 'hey',
    'can', 'could', 'will', 'would', 'you', 'we', "let's", 'lets',
    'go', 'ahead',
  };

  static const _verbs = <String>{
    'build', 'builds', 'building', 'built',
    'compile', 'compiles', 'compiling', 'compiled',
    'generate', 'generates', 'generating', 'generated',
    'make', 'makes', 'making', 'made',
    'create', 'creates', 'creating', 'created',
    'write', 'writes', 'writing', 'written',
    'save', 'saves', 'saving', 'saved',
    'export', 'exports', 'exporting', 'exported',
  };

  static const _nouns = <String>{
    'pkt', '.pkt', 'packet', 'tracer', 'lab', 'project', 'projects',
    'file', 'files', 'topology',
  };

  /// Leading politeness, stripped in a loop so "please can you build" works.
  static const _prefixes = <String>[
    'please ', 'pls ', 'kindly ', 'just ', 'go ahead and ',
    'can you ', 'could you ', 'will you ', 'would you ',
    'can we ', 'could we ', "let's ", 'lets ', 'hey ',
  ];

  /// Surrounding punctuation a typed word may carry - quotes, brackets,
  /// sentence punctuation - stripped before the vocabulary check.
  static const _wrapPunct = '''"'`([{,;:)]}''';

  /// True when [raw] asks, plainly, for the current plan to become a .pkt.
  static bool matches(String raw) {
    var t = raw.trim().toLowerCase().replaceAll('\u2019', "'");
    if (t.isEmpty || t.contains('\n')) return false;
    // A trailing "?" makes the sentence a question: "build the .pkt?" is
    // "is it built?", not an order, so it is answered rather than run.
    if (t.endsWith('?')) return false;
    while (t.isNotEmpty &&
        (t.endsWith('.') || t.endsWith('!') || t.endsWith(','))) {
      t = t.substring(0, t.length - 1).trimRight();
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final p in _prefixes) {
        if (t.startsWith(p)) {
          t = t.substring(p.length).trimLeft();
          changed = true;
        }
      }
    }
    if (t.isEmpty) return false;
    final words = t
        .split(RegExp(r'\s+'))
        .map(_clean)
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return false;
    var verb = false;
    var noun = false;
    for (final w in words) {
      if (!_allowed.contains(w)) return false;
      if (_verbs.contains(w)) verb = true;
      if (_nouns.contains(w)) noun = true;
    }
    return verb && noun;
  }

  /// One word, without the quotes or brackets people wrap it in
  /// (`"build"` -> `build`, `(the pkt)` -> `the pkt`).
  static String _clean(String w) {
    var s = w;
    while (s.isNotEmpty && _wrapPunct.contains(s[0])) {
      s = s.substring(1);
    }
    while (s.isNotEmpty && _wrapPunct.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
