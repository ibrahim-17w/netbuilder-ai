/// One turn's reading: exploration or request.
///
/// [cues] carries the matched phrases that DROVE the verdict - the definite
/// signals for a definite reading, the exploration cues for a tentative one -
/// for logging, debugging and the future "why did my lab change" explanation.
/// Empty means the turn carried no signal either way and the chat proceeds
/// exactly as it did before this gate existed.
class TentativeVerdict {
  final bool tentative;

  /// The matched phrases behind [tentative]; empty when the turn said
  /// nothing this gate recognizes.
  final List<String> cues;

  const TentativeVerdict({required this.tentative, this.cues = const []});
}

/// The tentative-language gate: is this turn EXPLORING the design, or
/// REQUESTING a change to it?
///
/// The chat used to mutate the standing lab on any sentence that carries
/// device counts: "could we do it with 40 PCs?" - pure wondering about
/// scale - re-planned the lab around 40 PCs. This service reads a turn
/// BEFORE the planner sees it and answers one question, deterministically
/// and offline: does this sentence float an idea, or give an order?
///
/// A tentative verdict means the chat answers conversationally and nothing
/// about the plan may change. A definite verdict means "proceed exactly as
/// before". The bias is one-directional on purpose: a missed request costs
/// one extra turn ("then add it"), while a wrong mutation silently rebuilds
/// the user's lab - the bug this gate exists to stop. So a definite signal
/// must be unambiguous, and exploration wins ties.
///
/// Input is the CasualEnglish-normalized text the chat already produces:
/// typos fixed, filler ("just", "please") stripped, and punctuation gone
/// from word edges - which also means sentence boundaries are gone, so
/// nothing here may rely on "?" or "." to split a turn. The text is
/// trimmed and lowercased again anyway, and empty input is answered,
/// never thrown on.
///
/// The chat calls [analyze] BEFORE `NetworkIntent.followUp` (and before the
/// brief and planner paths): tentative turns must never reach them.
class TentativeLanguageService {
  const TentativeLanguageService._();

  /// A turn with no word characters said nothing: "", "???", "...". Not
  /// tentative - there is nothing to hold back - and equally nothing to
  /// mutate, so the caller's own empty-input handling applies unchanged.
  static final RegExp _hasWords = RegExp(r'[a-z0-9]');

  // --- CasualEnglish repair ------------------------------------------------
  //
  // CasualEnglish's fuzzy matcher rewrites the modal "could" onto the device
  // "cloud" (same consonant skeleton, one vowel shifted), so "could we do it
  // with 40 pcs?" - the flagship exploration sentence - arrives here as
  // "cloud we do it with 40 pcs". The gate reads exactly those modal shapes,
  // so they are un-mangled before anything else runs. The repair is
  // deliberately one-sided: it only fires where a device cloud cannot sit
  // ("cloud" followed by a subject pronoun or a bare "be"; "we/you/i cloud"),
  // and nothing below matches the word "cloud" itself, so even a wrong
  // repair can only corrupt a word no pattern reads - it cannot flip a
  // verdict. The device cloud ("add a cloud", "2 clouds", "the cloud") is
  // never touched.

  /// "cloud we / cloud you / cloud this / cloud be ..." -> "could ...".
  static final RegExp _mangledCould = RegExp(
    r'\bcloud\s+(we|you|it|this|that|these|those|they|be)\b',
  );

  /// "we cloud / you cloud / i cloud ..." -> "we could ...".
  static final RegExp _mangledCouldAfterSubject = RegExp(
    r'\b(we|you|i)\s+cloud\b',
  );

  // --- definite signals ----------------------------------------------------
  //
  // Checked FIRST in [analyze]: one definite signal anywhere in the turn
  // ends the reading, however exploratory the rest of the sentence sounds
  // ("what if we added a dmz? can you add it" is a request).

  /// The edit-verb vocabulary the planner itself acts on - the same family
  /// `NetworkIntent.applyFollowUpChange` and the addition reader key on.
  /// Whole words only: "add" must not fire inside "address", "use" not
  /// inside "user", and the past tense "used"/"added" is left alone (a
  /// past tense sits inside hypotheticals: "what if we used ospf").
  static const String _editVerbs =
      'adds?|adding|removes?|removing|deletes?|deleting|changes?|changing|'
      'sets?|setting|switch(?:ing)?\\s+to|switching|replaces?|replacing|'
      'uses?|using|makes?|making|builds?|building|creates?|creating|'
      'updates?|updating|rebuilds?|rebuilding|gives?|giving|'
      'plan(?:ning)?(?:\\s+for)?|applies?|applying|installs?|installing|'
      'connects?|connecting|attaches?|attaching|configures?|configuring|'
      'provisions?|provisioning|deploys?|deploying|puts?|putting|'
      'places?|placing|fix(?:es)?|correct(?:ing)?';

  /// Small words an imperative can hide behind once normalization has eaten
  /// the punctuation: "no wait, make it 8", "ok then add a switch", "maybe
  /// add a server" (a soft order - unlike "maybe we add...", where the "we"
  /// is what makes it wondering).
  static const String _imperativeLeads =
      '(?:and|then|also|now|so|first|next|ok|okay|well|just|please|no|wait|'
      'but|yes|yeah|yep|sure|alright|maybe|perhaps|let\\s+me)\\s+';

  /// The bare imperative: the turn OPENS with the edit verb, optionally
  /// behind lead words. "add 2 aps", "make it 8", "build it anyway". Verb
  /// position is what makes this definite - "could we add a dmz" buries the
  /// verb under a modal subject and stays exploration (see [_tentativeCues]).
  static final RegExp _imperative = RegExp(
    '^(?:$_imperativeLeads)*(?:$_editVerbs)\\b',
  );

  /// A request wearing a question: the edit verb governed by "you".
  /// "can you add 2 aps", "could you make it 8", "would you add a server" -
  /// the person is asking the assistant to DO it, so the interrogative
  /// frame does not make it exploration. "would you recommend..." and
  /// "can you explain..." name no edit verb here, so advice and knowledge
  /// questions stay what they are.
  static final RegExp _politeImperative = RegExp(
    '\\b(?:can|could|would)\\s+you\\s+'
    '(?:(?:please|kindly|now|also|then|just|maybe)\\s+)?'
    '(?:go\\s+ahead\\s+and\\s+)?'
    '(?:$_editVerbs)\\b',
  );

  /// "can we build it (now)" asks to RUN the build, not to wonder about the
  /// design. The lookahead keeps the hypothetical reading hypothetical:
  /// "could we build it with 2 routers instead" builds it WITH a spec -
  /// that is a what-if, and stays tentative.
  static final RegExp _executionAsk = RegExp(
    r'\bc(?:an|ould)\s+we\s+'
    r'(?:just\s+|go\s+ahead\s+and\s+)?'
    r'build\s+it\b(?!\s+with\b)',
  );

  /// A request wearing a "we": "can we add a dmz", "could we switch to OSPF".
  ///
  /// The plan's rule is that a definite verb stays a definite edit whatever
  /// frame it sits in - a person who says "can we add AAA to it?" is asking
  /// for the AAA, and answering "that was a what-if" is how a chat stops
  /// being useful. What stays exploration is the we-modal with NO edit verb
  /// behind it ("could we do it with 40 PCs" - [_tentativeCues] owns that
  /// one) and the build family, whose what-if shape ("could we build it with
  /// 2 routers instead") is [_executionAsk]'s to decide.
  ///
  /// Guarded by [_frameOpeners] like the markers, so "what if we could add a
  /// dmz" is still the wondering it looks like.
  static final RegExp _weRequest = RegExp(
    '\\b(?:can|could|would)\\s+we\\s+'
    '(?:(?:just|please|then|also|now|go\\s+ahead\\s+and)\\s+)?'
    '(?:$_weEditVerbs)\\b',
  );

  /// [_editVerbs] minus the build family (see [_weRequest]). Derived rather
  /// than re-spelled so a verb added to the planner's vocabulary is picked up
  /// by both readings at once.
  static final String _weEditVerbs = _editVerbs
      .replaceAll('builds?|building|', '')
      .replaceAll('rebuilds?|rebuilding|', '');

  /// The declarative "use X instead": "static is slow, use ospf instead".
  /// The imperative check above only sees a leading verb; this catches the
  /// same request arriving mid-turn. Guarded by [_frameOpeners], so the
  /// hypothetical form ("what if we use ospf instead") stays exploration
  /// exactly like its past-tense twin.
  static final RegExp _useInstead = RegExp(
    r"\buses?\s+[a-z0-9' ,.-]{1,40}?\binstead\b",
  );

  /// Strong exploration frames. When one appears EARLIER in the turn than a
  /// correction marker, the marker is part of the wondering, not an order:
  /// "what if we need 40 pcs?" wonders about capacity, while "i need 40
  /// pcs" states a requirement.
  static final RegExp _frameOpeners = RegExp(
    r'\b(?:what\s+if|suppos(?:e|ing)|hypothetically|imagine|'
    r"let'?s\s+say|what\s+about|how\s+about)\b",
  );

  /// Correction and need markers. Not imperatives - there is no verb
  /// position to check - so they stand on their own words ("actually 8 pcs"
  /// restates a count, "i need 3 switches" states a requirement, "i want"
  /// states a desire) and are only guarded by [_frameOpeners].
  static final RegExp _markers = RegExp(
    r"\bactually\b|\b(?:i|we)\s*(?:will|'?ll)?\s*(?:need|want)\b",
  );

  /// The green light: "go ahead" - alone, or buried in a polite frame
  /// ("you can go ahead and build it"). Guarded like the markers, so
  /// "what if we go ahead with 40" stays a what-if.
  static final RegExp _greenLight = RegExp(r'\bgo\s+ahead\b');

  // --- tentative cues ------------------------------------------------------

  /// Exploration cues. Checked only when nothing definite fired; ANY match
  /// holds the lab. The we-framed modals are here on purpose: "could we
  /// add a dmz" floats the idea, and the order drops the frame ("add a
  /// dmz", "can you add a dmz"). "should we" / "would you recommend" are
  /// advice questions - exactly the turns that must never re-plan even
  /// when counts appear in them.
  static final List<RegExp> _tentativeCues = [
    // Explicit exploration frames.
    RegExp(r'\bwhat\s+if\b'),
    RegExp(r'\bsuppos(?:e|ing)\b'),
    RegExp(r'\bhypothetically\b'),
    RegExp(r"\blet'?s\s+say\b"),
    RegExp(r'\bimagine\b'),
    // Hedges and design musing.
    RegExp(r'\bmaybe\b'),
    RegExp(r'\bperhaps\b'),
    RegExp(r'\bthinking\s+about\b'),
    RegExp(r'\bconsidering\b'),
    // Topic-floating questions: the question is the point, not a change.
    RegExp(r'\bwhat\s+about\b'),
    RegExp(r'\bhow\s+about\b'),
    RegExp(r'\bis\s+it\s+possible\b'),
    RegExp(r'\bwould\s+it\s+be\s+possible\b'),
    RegExp(r'\bwhat\s+would\s+happen\b'),
    // Deliberation about a choice ("or should we", "or would ... ?").
    RegExp(r'\bshould\s+we\b'),
    RegExp(r'\bshall\s+we\b'),
    RegExp(r'\bor\s+would\b'),
    RegExp(r'\b(?:would|could)\s+you\s+recommend\b'),
    RegExp(r'\b(?:can|could|would)\s+(?:we|you)\s+do\b'),
    RegExp(r'\bwe\s+could\b'),
    // Feasibility and comparison wondering: "would/could X work", "would/
    // could X be better". The gap stays inside one clause of normalized
    // text.
    RegExp(r"\b(?:would|could)\b[a-z0-9' ,.-]{0,40}?\bwork\b"),
    RegExp(r"\b(?:would|could)\b[a-z0-9' ,.-]{0,40}?\bbe\s+better\b"),
    // The we-framed modal question, whatever verb follows.
    RegExp(r'\b(?:can|could)\s+we\b'),
    RegExp(r'\bcould\s+(?:this|that|it|these|those)\b'),
  ];

  /// The verdict for one chat turn.
  ///
  /// Decision order, enforced here:
  ///
  /// 1. nothing said (empty or punctuation only) -> not tentative, no cues;
  /// 2. any DEFINITE signal -> not tentative, with the definite signals as
  ///    cues. Definite wins ALWAYS, even over tentative cues in the same
  ///    turn - "what if we added a dmz? can you add it" is a request. The
  ///    definite checks are: polite imperative ("can you add..."), the
  ///    run-the-build ask ("can we build it now"), the bare imperative in
  ///    leading position ("add...", "no wait, make it 8"), the declarative
  ///    "use X instead", and the correction/need markers plus the green
  ///    light ("actually", "i need", "go ahead") - the last two suppressed
  ///    when an exploration frame opens earlier in the turn;
  /// 3. otherwise any tentative cue -> tentative, with the cues that fired;
  /// 4. otherwise not tentative with NO cues - the gate is a tripwire, not
  ///    a general classifier. A turn it does not recognize keeps the chat
  ///    behaviour that existed before this gate.
  static TentativeVerdict analyze(String normalizedText) {
    var t = normalizedText.trim().toLowerCase();
    if (!_hasWords.hasMatch(t)) {
      return const TentativeVerdict(tentative: false);
    }
    // Un-mangle CasualEnglish's could->cloud rewrite before reading (see
    // the repair block above for why this is safe).
    t = t
        .replaceAllMapped(_mangledCould, (m) => 'could ${m.group(1)}')
        .replaceAllMapped(_mangledCouldAfterSubject, (m) => '${m.group(1)} could');

    final definite = [
      ..._matches(_politeImperative, t),
      ..._matches(_executionAsk, t),
      ..._matches(_weRequest, t, guarded: true),
      ..._matches(_imperative, t),
      ..._matches(_useInstead, t, guarded: true),
      ..._matches(_markers, t, guarded: true),
      ..._matches(_greenLight, t, guarded: true),
    ];
    if (definite.isNotEmpty) {
      return TentativeVerdict(tentative: false, cues: definite);
    }

    final tentative = <String>[];
    for (final cue in _tentativeCues) {
      final m = cue.firstMatch(t);
      if (m != null) tentative.add(m.group(0)!);
    }
    if (tentative.isNotEmpty) {
      return TentativeVerdict(tentative: true, cues: tentative);
    }
    return const TentativeVerdict(tentative: false);
  }

  /// Every match of [pattern] in [t], as the matched text. With [guarded],
  /// a match is skipped when an exploration frame opens earlier in the
  /// turn - the marker then sits inside the wondering, not on its own.
  static List<String> _matches(
    RegExp pattern,
    String t, {
    bool guarded = false,
  }) {
    final out = <String>[];
    for (final m in pattern.allMatches(t)) {
      if (guarded && _frameOpeners.hasMatch(t.substring(0, m.start))) {
        continue;
      }
      out.add(m.group(0)!);
    }
    return out;
  }
}
