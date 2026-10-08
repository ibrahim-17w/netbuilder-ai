// The engine's own style list is the one source of truth for what a drawing
// is called: [LayoutRequest.allStyles] aliases it so a style the gallery
// offers is always a style the note reader accepts back.
import 'layout_engine.dart' show kLayoutStyles;

/// One group of devices sent to one edge.
///
/// "Put the servers on one side and the routers on the other" is two of these;
/// "move the servers to the side" is one. [edge] is a concrete side by the
/// time the request leaves [LayoutRequest.read].
class LayoutZoneRequest {
  final List<String> kinds;
  final List<String> names;
  String edge;

  LayoutZoneRequest({
    List<String> kinds = const <String>[],
    List<String> names = const <String>[],
    this.edge = '',
  }) : kinds = List<String>.of(kinds),
       names = List<String>.of(names);

  bool get isEmpty => kinds.isEmpty && names.isEmpty;

  @override
  String toString() => 'LayoutZoneRequest(${kinds.join('+')}|'
      '${names.join('+')}|$edge)';
}

/// What a person means when they talk about how the drawing looks.
///
/// The bug this exists to stop: "can you edit the layout of the devices to
/// make them better looking?" was read as an ordinary edit, so the app
/// recompiled the same plan and the deterministic layout produced the *same*
/// picture - byte-identical coordinates - and answered as if it had done
/// something. A request about the drawing has to change the drawing.
///
/// A second bug, found by watching the first one get "fixed": a request about
/// WHERE a device sits ("move the servers to the side") was dropped entirely,
/// because the reader only recognised a topic word like "layout" or "diagram"
/// and had no vocabulary for placement at all. Worse, the only four drawings
/// that existed differed by a global scale factor, so even a correctly
/// understood request had no drawing it could mean.
///
/// Deliberately a pure function over words, like [FileEditIntentReader]: the
/// decision is made before any model is consulted, so it behaves identically
/// online and offline, and a model cannot talk the app into re-drawing a
/// network the user did not ask about.
class LayoutRequest {
  /// The style that was chosen for this redraw: one of [styles] or `grouped`.
  final String style;

  /// True when the user actually named a drawing ("make it compact"); false
  /// when the turn only said the current one is not good enough, and the app
  /// picked the next different one so the request has a visible effect.
  final bool explicitStyle;

  /// Devices to a row, when the user asked for a count.
  final int? columns;

  /// The device kinds lifted out of the tree and parked in one column
  /// (`grouped`). Empty for every other style.
  ///
  /// Kinds, not device names: the plan is what knows which devices are
  /// servers, and the reader is a pure function over words. [resolveSideNames]
  /// turns these into the concrete names the engine positions.
  final List<String> sideKinds;

  /// Devices the request named outright ("move SRV1 to the side"). Kept apart
  /// from [sideKinds] because naming one server must move that server, not
  /// every server in the plan.
  final List<String> sideNames;

  /// Which edge the `grouped` column sits on.
  final String sideEdge;

  /// True when neither devices nor kinds were named, so the answer can say what
  /// it assumed instead of pretending it was told.
  final bool guessedSide;

  /// One group of devices sent to one edge: "the servers on one side and the
  /// routers on the other" is two of these.
  final List<LayoutZoneRequest> zones;

  const LayoutRequest({
    required this.style,
    this.explicitStyle = false,
    this.columns,
    this.sideKinds = const <String>[],
    this.sideNames = const <String>[],
    this.sideEdge = 'left',
    this.guessedSide = false,
    this.zones = const <LayoutZoneRequest>[],
  });

  /// The drawings a vague request cycles through: ONE PER ALGORITHM.
  ///
  /// `wide` and `compact` are the tree at two other sizes and `rows` is the
  /// tree's bands without nesting, so cycling between them handed back the
  /// picture the user was already looking at - which is what "all the layouts
  /// look the same" meant. Every entry here draws a different silhouette.
  ///
  /// `grid` stays LAST: the cycle reads `nextStyle('grid') == 'tree'`, so a
  /// full turn of the wheel lands back where it started.
  static const List<String> styles = <String>[
    'tree',
    'layered',
    'backbone',
    'campus',
    'split',
    'star',
    'ring',
    'radial',
    'circle',
    'grid',
  ];

  /// Every drawing the engine knows, gallery order - [kLayoutStyles] itself,
  /// so the reader and the gallery can never disagree about what exists. A
  /// style missing here would be stamped into a note and then unreadable by
  /// [styleFromNote], which is how a picked drawing silently reverted to the
  /// default on the next build.
  static const List<String> allStyles = kLayoutStyles;

  /// The kinds a placement request falls back to when it names no device. In a
  /// network diagram "move it to the side" means the servers far more often
  /// than anything else, and [guessedSide] makes the app admit it assumed.
  static const List<String> defaultSideKinds = <String>['server'];

  bool get isGrouped =>
      style == 'grouped' &&
      (sideKinds.isNotEmpty || sideNames.isNotEmpty || zones.isNotEmpty);

  /// The plan payload the engine reads (`build_pkt(plan['layout'])`).
  ///
  /// `sideKinds`/`sideNames` travel unresolved on purpose: [autopilotPlan] is
  /// the one place that holds both the plan and the engine payload, so it is
  /// the one place that can turn "the servers" into the four names that exist.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    'style': style,
    if (columns != null) 'columns': columns,
    if (zones.isNotEmpty)
      'zones': <Map<String, dynamic>>[
        for (final zone in zones)
          <String, dynamic>{
            if (zone.kinds.isNotEmpty) 'sideKinds': zone.kinds,
            if (zone.names.isNotEmpty) 'sideNames': zone.names,
            if (zone.edge.isNotEmpty) 'sideEdge': zone.edge,
          },
      ],
    if (zones.isEmpty) ...<String, dynamic>{
      if (sideKinds.isNotEmpty) 'sideKinds': sideKinds,
      if (sideNames.isNotEmpty) 'sideNames': sideNames,
      if (isGrouped) 'sideEdge': sideEdge,
    },
  };

  /// The style after [style] - what a vague "make it look better" asks for,
  /// because it is the one thing that is definitely not what they are looking
  /// at now.
  static String nextStyle(String style) {
    final index = styles.indexOf(style);
    // An unknown (or missing) previous drawing falls to the one AFTER the
    // default, not to the default itself: the user is asking for something
    // different from what they are looking at, and "tree" is most likely
    // exactly what they are looking at.
    return styles[(index < 0 ? 1 : index + 1) % styles.length];
  }

  /// How this particular drawing is described to the user: what changed, in
  /// their terms. An instance method because a grouped drawing is only
  /// meaningful once the devices and the edge are known.
  String describe() {
    if (isGrouped) {
      if (zones.isNotEmpty) {
        final parts = <String>[
          for (final zone in zones)
            '${_kindPhrase(zone.kinds, zone.names)} to '
                '${zone.edge == 'right' ? 'the right' : 'the left'}',
        ];
        return 'grouped - ${parts.join(', ')}';
      }
      return 'grouped - the ${sideKinds.join(' and ')} moved to '
          '${sideEdge == 'right' ? 'the right' : 'the left'}, '
          'in a column of their own';
    }
    return switch (style) {
      'wide' => 'wide - more room between devices',
      'compact' => 'compact - the whole lab closer together',
      'rows' => 'straight rows - one row per kind of device',
      'layered' => 'layered - the hierarchy drawn left to right',
      'split' => 'split - one vertical column per kind of device',
      'backbone' => 'backbone - one horizontal line, endpoints on drops below',
      'campus' => 'campus - core, distribution and access on aligned tiers',
      'star' => 'star - switches radiating from the router, PCs fanned outward',
      'ring' => 'ring - one ring, switches alternating with endpoints',
      'radial' => 'radial - the core in the middle, endpoints outside',
      'circle' => 'one circle - every device on a single ring',
      'grid' => 'an even grid - a box of devices, topology ignored',
      _ => 'site trees - every device under the one it connects to',
    };
  }

  static String _kindPhrase(List<String> kinds, List<String> names) {
    if (kinds.isNotEmpty) return 'the ${kinds.join(' and ')}';
    if (names.isNotEmpty) return names.join(' and ');
    return 'the devices';
  }

  /// How a style is described when no devices have been named for it.
  static String styleLabel(String style) => switch (style) {
    'wide' => 'wide - more room between devices',
    'compact' => 'compact - the whole lab closer together',
    'rows' => 'straight rows - one row per kind of device',
    'grouped' => 'grouped - one kind of device in its own column',
    'layered' => 'layered - the hierarchy drawn left to right',
    'split' => 'split - one vertical column per kind of device',
    'backbone' => 'backbone - one horizontal line, endpoints on drops below',
    'campus' => 'campus - core, distribution and access on aligned tiers',
    'star' => 'star - switches radiating from the router, PCs fanned outward',
    'ring' => 'ring - one ring, switches alternating with endpoints',
    'radial' => 'radial - the core in the middle, endpoints outside',
    'circle' => 'one circle - every device on a single ring',
    'grid' => 'an even grid - a box of devices, topology ignored',
    _ => 'site trees - every device under the one it connects to',
  };

  /// The one-tap reply that switches to [style].
  static String phraseFor(String style) => switch (style) {
    'wide' => 'Spread the devices out',
    'compact' => 'Make the layout compact',
    'rows' => 'Put each kind of device on its own row',
    'grouped' => 'Move the servers to the side',
    'layered' => 'Draw it left to right',
    'split' => 'Give each kind of device its own column',
    'backbone' => 'Draw it as one horizontal backbone',
    'campus' => 'Draw it as a two-tier campus',
    'star' => 'Draw it as a star around the core',
    'ring' => 'Put the devices on a single ring',
    'radial' => 'Draw it as rings around the core',
    'circle' => 'Put every device in one circle',
    'grid' => 'Lay it out as an even grid',
    _ => 'Draw it as site trees',
  };

  /// The other drawings, for the chips under a redraw answer.
  static List<String> optionsFor(String style) => <String>[
    for (final other in allStyles)
      if (other != style) phraseFor(other),
  ];

  /// Is this turn about the drawing at all?  Deliberately wide: it is only
  /// consulted for a request that named no drawing, so being generous costs a
  /// cycling answer at worst, while being narrow threw away real requests
  /// ("put the servers on one side", "make it wider") on the floor.
  static final RegExp _topic = RegExp(
    r'\b(layout|layouts|diagram|diagrams|drawing|drawings|draw|drawn|drew|'
    r'canvas|topology|picture|sketch|blueprint|'
    r'arrange|arranged|arranging|arrangement|rearrange|reposition|'
    r'position|positions|place|placed|placing|put|move|moving|shift|slide|'
    r'spacing|space|room|rooms|gap|gaps|'
    r'spread|overlap|overlapping|cramped|crowded|tidy|tidier|neat|neater|'
    r'cleaner|prettier|prettiest|nicer|'
    r'look|looks|looking|looked|better|ugly|uglier|messy|cluttered|'
    r'row|rows|column|columns|line\s*up|group|grouped|separate|'
    r'side|left|right|edge|corner)\b',
    caseSensitive: false,
  );

  /// A named drawing. Longest match first: "one row per kind" is not "compact".
  /// A bare "N ... a row" / "... on its own row" names the rows drawing too:
  /// that is the textbook picture a person is describing.
  static final RegExp _namedRows = RegExp(
    r'\b(row per kind|one row per|a row per|straight rows?|single rows?|'
    r'textbook|classic\s+(?:drawing|diagram|layout)|side by side|'
    r'its\s+own\s+row|own\s+rows?)\b',
    caseSensitive: false,
  );
  static final RegExp _namedCompact = RegExp(
    r'\b(compact|compacter|tighter|tighten|tight\s+spacing|'
    r'squash\w*|squeeze\w*|less\s+(?:room|space)|closer\s+together|'
    r'close\s+together|zoom(?:ed)?\s*out|bunch\w*\s+(?:them\s+)?together)\b',
    caseSensitive: false,
  );
  /// Note the absence of a bare "apart" or "bigger": both read as distance in
  /// ordinary sentences ("2 subnets apart", "a bigger subnet") and used to
  /// turn networking talk into a drawing request. The phrases a person uses
  /// when they mean the picture are spelled out instead.
  static final RegExp _namedWide = RegExp(
    r'\b(wide|wider|widest|roomier|more\s+room|more\s+space|'
    r'(?:spread|pull|stretch)\s*(?:them|it|out|the\s+devices)?\s*out|'
    r'farther\s+apart|further\s+apart|apart\s+from\s+each\s+other|'
    r'zoom(?:ed)?\s*in)\b',
    caseSensitive: false,
  );
  static final RegExp _namedTree = RegExp(
    r'\b(site\s+trees?|hierarch\w*|tree\s+(?:layout|drawing|diagram)|'
    r'back\s+to\s+(?:normal|the\s+default|the\s+original)|'
    r'(?:back\s+)?to\s+(?:normal|the\s+default|the\s+original)|'
    r'(?:as|like)\s+they\s+were|'
    r'(?:it|them|that|this)\s+(?:back\s+)?(?:to\s+)?'
    r'(?:normal|default|original|standard)|'
    r'(?:layout|drawing|diagram|picture)\s+back\s+to\s+(?:normal|default)|'
    r'(?:default|original)\s+(?:layout|drawing|diagram|picture)|'
    r'reset\s+(?:the\s+)?(?:layout|drawing|diagram|picture))\b',
    caseSensitive: false,
  );

  /// Words that only name a drawing when the sentence is already about one.
  /// Bare, they are ordinary English: "reset the router" is not a redraw.
  static final RegExp _namedTreeWeak = RegExp(
    r'\b(normal|default|original|reset|restore)\b',
    caseSensitive: false,
  );

  // The drawings that are a different ALGORITHM rather than another size
  // of the tree. Longest phrases first so "one column per kind" is `split` and
  // not `layered`, and "rings around" is `radial` and not `circle`.
  static final RegExp _namedSplit = RegExp(
    r'\b(one\s+columns?\s+per\s+(?:kind|type)|'
    r'(?:vertical|separate)\s+columns?|columns?\s+per\s+(?:kind|type)|'
    r'its\s+own\s+column|'
    r'split)\b',
    caseSensitive: false,
  );
  static final RegExp _namedLayered = RegExp(
    r'\b(layered|hierarch\w*|left\s+to\s+right|right\s+to\s+left|sideways|'
    r'top\s+to\s+bottom|bottom\s+to\s+top)\b',
    caseSensitive: false,
  );
  // The engineer's four. Deliberately narrow where they could cannibalise an
  // older drawing: `ring` never matches a bare plural "rings around" (that is
  // `radial`), and `star` matches the noun "star", not "start"/"restart".
  static final RegExp _namedBackbone = RegExp(
    r'\b(backbone|riser|horizontal\s+bus|bus\s+topology)\b',
    caseSensitive: false,
  );
  static final RegExp _namedCampus = RegExp(
    r'\b(campus|two-?\s?tier|three-?\s?tier|multi-?\s?tier|'
    r'distribution\s+(?:layer|switches?))\b',
    caseSensitive: false,
  );
  static final RegExp _namedStar = RegExp(
    r'\b(star|star-?shaped|spokes?|hub\s+and\s+spoke)\b',
    caseSensitive: false,
  );
  static final RegExp _namedRing = RegExp(
    r'\b((?:a|one|single|big|token)\s+ring|ring\s+(?:topology|network)|'
    r'token\s+ring)\b',
    caseSensitive: false,
  );
  static final RegExp _namedRadial = RegExp(
    r'\b(radial|concentric|rings?\s+(?:around|by\s+(?:role|kind))|'
    r'circles?\s+around|'
    r'(?:out|outward)\s+from\s+the\s+cent(?:re|er))\b',
    caseSensitive: false,
  );
  static final RegExp _namedCircle = RegExp(
    r'\b(one\s+circle|a\s+single\s+circle|in\s+a\s+circle|'
    r'(?:on|in)\s+(?:one\s+)?circle|circle\s+layout|ring\s+layout)\b',
    caseSensitive: false,
  );
  static final RegExp _namedGrid = RegExp(
    r'\b(grid|grid\s+layout|matrix|evenly\s+spaced|'
    r'equal(?:ly)?\s+spaced|table\s+layout)\b',
    caseSensitive: false,
  );

  /// "the layout is fine" is not a request. A drawing request has to want
  /// something changed.
  static final RegExp _asksChange = RegExp(
    r'\b(change|fix|improve|redraw|re-?draw|arrang\w*|re-?arrang\w*|'
    r're-?position\w*|move|put|place|shift|slide|push|group|cluster|align|'
    r'tidy|clean|make|spread|looks?|looking|better|nicer|prettier|'
    r'ugly|messy|cramped|overlap\w*|compact|wide|rows?|default|reset|'
    r'again|different|too|keep|separate|park)\b',
    caseSensitive: false,
  );

  /// A change to the network itself ("add a switch", "remove 2 PCs"), which is
  /// an edit, not a redraw - the normal path has to see it. Split in two
  /// because a bare count and a device noun read the same in "make it 2
  /// routers" (an edit) and "move 3 servers to the side" (a placement), and
  /// only the placement wording tells them apart.
  static final RegExp _deviceAddition = RegExp(
    r'\b(add|remove|delete|drop|insert|another|extra)\s+'
    r'(?:(?:a|an|the|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+)?'
    r'(?:more\s+|another\s+)?'
    r'(?:routers?|switches|switch|pcs?|servers?|firewalls?|aps?|'
    r'phones?|hosts?|devices?|laptops?|printers?)\b',
    caseSensitive: false,
  );

  /// A count of devices with no change verb. An edit, unless the sentence also
  /// asks for a placement.
  static final RegExp _deviceCount = RegExp(
    r'\b\d+\s+(?:more\s+)?(?:routers?|switches|pcs?|servers?)\b',
    caseSensitive: false,
  );

  /// Where the devices are being asked to go. Deliberately about DIRECTION,
  /// not about the word "layout": "put the servers on one side" says nothing
  /// about a layout and everything about a placement.
  static final RegExp _sideDirection = RegExp(
    r'\b(?:to|on|into|towards?)\s+(?:the\s+|one\s+|a\s+)?'
    r'(?:side|left|right|edge|corner|end|flank)\b|'
    r'\b(?:left|right)\s*(?:hand)?\s*(?:side|edge)\b|'
    r'\b(?:left|right)\s+of\s+(?:the\s+)?(?:diagram|drawing|picture|it)\b|'
    r'\baway\s+from\b|\baway\b|\bhere\b|\bthere\b|'
    r'\b(?:aside|separate\w*)\b',
    caseSensitive: false,
  );

  /// The verb that makes it a placement rather than a description.
  static final RegExp _moveVerb = RegExp(
    r'\b(move|moves|moved|moving|put|puts|place|places|placed|placing|'
    r'shift|shifts|shifting|slide|slides|push|pushes|pull|pulls|'
    r'group|groups|grouped|cluster|clusters|bunch|bunches|'
    r'collect|collects|align|aligns|line\s+up|park|parks|separate|separates|'
    r'take|keep|set)\b',
    caseSensitive: false,
  );

  /// Where a request stops talking about the devices being MOVED. In "put the
  /// servers on one side not near the PCs" the PCs are what the servers are
  /// being moved AWAY from, so everything from this word on is context, not
  /// instructions.
static final RegExp _separation = RegExp(
    r'\b(?:from|off|near)\b',
    caseSensitive: false,
  );

  /// The devices being moved. Normalised through [_canonicalKind]; the plan,
  /// not the sentence, decides which devices those are.
  static final RegExp _kindWord = RegExp(
    r'\b(server|pcs?|workstations?|desktops?|hosts?|clients?|'
    r'routers?|switches|firewalls?|'
    r'access\s*points?|wireless|wlc|phones?|laptops?|printers?|'
    r'cloud)s?\b',
    caseSensitive: false,
  );

  /// A device named outright ("move SRV1 to the side"). Numbered device names
  /// are not kinds, so they are read separately and resolved against the plan:
  /// treating "SRV1" as "server" would move every server in the lab.
  static final RegExp _deviceName = RegExp(r'\b[A-Za-z]{2,6}\d+\b');

  static const Map<String, String> _kindAliases = <String, String>{
    'server': 'server',
    'srv': 'server',
    'pc': 'host',
    'workstation': 'host',
    'desktop': 'host',
    'host': 'host',
    'client': 'host',
    'laptop': 'host',
    'router': 'router',
    'rtr': 'router',
    'switch': 'switch',
    'sw': 'switch',
    'firewall': 'firewall',
    'fw': 'firewall',
    'access point': 'wireless',
    'accesspoint': 'wireless',
    'ap': 'wireless',
    'wireless': 'wireless',
    'wlc': 'wireless',
    'phone': 'phone',
    'printer': 'printer',
    'cloud': 'cloud',
  };

  static const Map<String, int> _numberWords = <String, int>{
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
  };

  static final RegExp _columnsDigits = RegExp(
    r'\b(\d{1,2})\s*(?:devices?|hosts?|pcs?)?\s*(?:per|to\s+a|in\s+a|'
    r'to\s+each|in\s+each|a)\s+row\b',
    caseSensitive: false,
  );
  static final RegExp _columnsWords = RegExp(
    '\\b(${_numberWords.keys.join('|')})\\s*'
    r'(?:devices?|hosts?|pcs?)?\s*'
    r'(?:per|to\s+a|in\s+a|to\s+each|in\s+each|a)\s+row\b',
    caseSensitive: false,
  );

  /// Reads a drawing request out of one turn, or null when the turn is not
  /// about how the file looks.
  ///
  /// [currentStyle] is the drawing the file on the table already has, when the
  /// app knows it: a vague request then picks the *next* drawing instead of
  /// the same one again.
  ///
  /// The order matters. A placement ("move the servers to the side") is read
  /// first because it is the most specific thing a person can ask for. A named
  /// drawing is read next, and deliberately does NOT need a topic word: the
  /// old reader required one, which is why "make it wider" and "more space
  /// between devices" - the two most ordinary ways to ask for a redraw - were
  /// thrown away before anything looked at them. Only a vague turn falls
  /// through to the topic-and-change gate and the blind cycle.
  static LayoutRequest? read(
    String text, {
    String currentStyle = 'tree',
  }) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (_deviceAddition.hasMatch(t)) return null;

    // A placement is read before the bare device count, so "move 3 servers to
    // the side" is a placement while "make it 2 routers and 20 PCs" stays an
    // edit.
    final placement = _placementIn(t, text.trim());
    if (placement != null) return placement;

    if (_deviceCount.hasMatch(t)) return null;

    final columns = _columnsIn(t);
    String? named;
    if (_namedRows.hasMatch(t)) {
      named = 'rows';
    } else if (_namedSplit.hasMatch(t)) {
      named = 'split';
    } else if (_namedLayered.hasMatch(t)) {
      named = 'layered';
    } else if (_namedBackbone.hasMatch(t)) {
      named = 'backbone';
    } else if (_namedCampus.hasMatch(t)) {
      named = 'campus';
    } else if (_namedStar.hasMatch(t)) {
      named = 'star';
    } else if (_namedRing.hasMatch(t)) {
      named = 'ring';
    } else if (_namedRadial.hasMatch(t)) {
      named = 'radial';
    } else if (_namedCircle.hasMatch(t)) {
      named = 'circle';
    } else if (_namedGrid.hasMatch(t)) {
      named = 'grid';
    } else if (_namedCompact.hasMatch(t)) {
      named = 'compact';
    } else if (_namedWide.hasMatch(t)) {
      named = 'wide';
    } else if (_namedTree.hasMatch(t)) {
      named = 'tree';
    } else if (_namedTreeWeak.hasMatch(t) && _topic.hasMatch(t)) {
      named = 'tree';
    }
    // "put 4 devices per row" names the rows drawing without using the words:
    // a count per row is what a rows drawing is FOR, and cycling to whatever
    // came next there labelled the answer "compact - the whole lab closer
    // together" for a request about rows.
    if (named == null && columns != null) named = 'rows';
    if (named != null) {
      return LayoutRequest(
        style: named,
        explicitStyle: true,
        columns: columns,
      );
    }

    // Nothing named and nothing else to go on: the request is "not this one".
    if (!_topic.hasMatch(t)) return null;
    if (!_asksChange.hasMatch(t)) return null;
    return LayoutRequest(style: nextStyle(currentStyle));
  }

  /// "move the servers to the side", "put the routers on the right",
  /// "separate the servers from the PCs" - a request about WHERE devices sit.
  /// Where a clause asks for its devices to go.
  ///
  /// `first` means "a side, whichever one is free" and `other` means "the side
  /// I did not just use" - which is how "here and there" and "one side ... the
  /// other" are expressed without either word naming left or right.
  static final RegExp _edgeLeft = RegExp(r'\bleft\b', caseSensitive: false);
  static final RegExp _edgeRight = RegExp(r'\bright\b', caseSensitive: false);
  static final RegExp _edgeFirst = RegExp(
    r'\b(here|one\s+side|a\s+side|the\s+side|side|edge|corner|end|flank|'
    r'apart|aside|away)\b',
    caseSensitive: false,
  );
  static final RegExp _edgeOther = RegExp(
    r'\b(there|the\s+other|the\s+opposite|opposite)\b',
    caseSensitive: false,
  );

  /// The clauses a multi-group request is made of: "put the servers on one
  /// side AND the routers on the other".
  static final RegExp _clauseSplit = RegExp(
    r'\band\b|\bthen\b|,|;',
    caseSensitive: false,
  );

  static String _rawEdgeIn(String clause) {
    if (_edgeRight.hasMatch(clause)) return 'right';
    if (_edgeLeft.hasMatch(clause)) return 'left';
    if (_edgeOther.hasMatch(clause)) return 'other';
    if (_edgeFirst.hasMatch(clause)) return 'first';
    return '';
  }

  static LayoutRequest? _placementIn(String t, String original) {
    if (!_sideDirection.hasMatch(t)) return null;
    if (!_moveVerb.hasMatch(t)) return null;

    // One clause per destination. A clause that names no destination belongs
    // to the one beside it ("move the servers and the routers to the left"),
    // so the clause list is read, not the sentence.
    final clauses = t
        .split(_clauseSplit)
        .where((c) => c.trim().isNotEmpty)
        .toList();
    final parts = <({List<String> kinds, List<String> names, String edge})>[];
    var end = 0;
    for (final clause in clauses) {
      final start = t.indexOf(clause, end);
      end = start + clause.length;
      // `from`/`off`/`near` mark what the devices are moving AWAY from, so
      // everything after is context rather than instructions.
      final cut = _separation.firstMatch(clause);
      final scope = cut == null ? clause : clause.substring(0, cut.start);
      final limit = cut?.start ?? clause.length;
      final names = <String>[];
      for (final m in _deviceName.allMatches(original)) {
        // The same offsets: `t` is `original` lower-cased.
        if (m.start < start || m.start + m.group(0)!.length > start + limit) {
          continue;
        }
        final upper = m.group(0)!.toUpperCase();
        if (!names.contains(upper)) names.add(upper);
      }
      parts.add((kinds: _kindsIn(scope), names: names, edge: _rawEdgeIn(clause)));
    }
    if (parts.isEmpty) return null;

    final zoned = _assembleZones(parts);
    final guessed = zoned.every(
      (z) => z.kinds.isEmpty && z.names.isEmpty,
    );
    if (guessed) {
      return LayoutRequest(
        style: 'grouped',
        explicitStyle: false,
        // The servers are a fallback for "move it to the side", never a
        // stand-in for a device the sentence named: "move SRV1" must not also
        // drag SRV2 along.
        zones: <LayoutZoneRequest>[
          LayoutZoneRequest(kinds: defaultSideKinds, edge: 'left'),
        ],
        guessedSide: true,
      );
    }
    return LayoutRequest(
      style: 'grouped',
      explicitStyle: true,
      zones: zoned,
    );
  }

  /// Turn per-clause destinations into zones.
  ///
  /// Two or more clauses that each name a side are two groups, sent to
  /// different edges - "the servers here and the routers there". Exactly one
  /// clause naming a side means every clause is going to that same side, which
  /// is what "move the servers and the routers to the left" means. No clause
  /// naming a side is a single group whose edge is chosen for it.
  static List<LayoutZoneRequest> _assembleZones(
    List<({List<String> kinds, List<String> names, String edge})> parts,
  ) {
    final directed = parts.where((p) => p.edge.isNotEmpty).toList();
    final zones = <LayoutZoneRequest>[];

    void add(List<String> kinds, List<String> names, String edge) {
      if (zones.isEmpty) {
        zones.add(LayoutZoneRequest(kinds: kinds, names: names, edge: edge));
        return;
      }
      zones.last.kinds.addAll(kinds);
      zones.last.names.addAll(names);
    }

    if (directed.length >= 2) {
      for (final part in parts) {
        if (part.edge.isNotEmpty) {
          // A clause with its own destination is its own group: that is the
          // whole difference between "the servers here and the routers there"
          // and "the servers and the routers to the left".
          zones.add(
            LayoutZoneRequest(
              kinds: part.kinds,
              names: part.names,
              edge: part.edge,
            ),
          );
        } else {
          add(part.kinds, part.names, '');
        }
      }
    } else if (directed.length == 1) {
      add(
        <String>[for (final p in parts) ...p.kinds],
        <String>[for (final p in parts) ...p.names],
        directed.first.edge,
      );
    } else {
      add(
        <String>[for (final p in parts) ...p.kinds],
        <String>[for (final p in parts) ...p.names],
        '',
      );
    }

    // "here" and "the other side" become concrete edges, in the order asked
    // for, and never twice on the same side.
    final used = <String>{};
    for (final zone in zones) {
      if (zone.edge == 'left' || zone.edge == 'right') {
        used.add(zone.edge);
      }
    }
    for (final zone in zones) {
      if (zone.edge == 'left' || zone.edge == 'right') continue;
      final edge = zone.edge == 'other'
          ? (used.contains('right') ? 'left' : 'right')
          : (used.contains('left') ? 'right' : 'left');
      zone.edge = edge;
      used.add(edge);
    }
    return zones
        .where((z) => z.kinds.isNotEmpty || z.names.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _kindsIn(String t) {
    final out = <String>[];
    for (final m in _kindWord.allMatches(t)) {
      final kind = _canonicalKind(m.group(0) ?? '');
      if (kind != null && !out.contains(kind)) out.add(kind);
    }
    return out;
  }

  /// "servers" -> server, "switches" -> switch, "pcs" -> pc. Returns null
  /// for anything that is not a device kind, so an unknown word is dropped
  /// rather than guessed at.
  static String? _canonicalKind(String raw) {
    final word = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (word.isEmpty) return null;
    final direct = _kindAliases[word];
    if (direct != null) return direct;
    for (final suffix in const <String>['es', 's']) {
      if (word.length > suffix.length && word.endsWith(suffix)) {
        final hit = _kindAliases[word.substring(0, word.length - suffix.length)];
        if (hit != null) return hit;
      }
    }
    return null;
  }

  static int? _columnsIn(String t) {
    final digits = _columnsDigits.firstMatch(t);
    if (digits != null) {
      final value = int.tryParse(digits.group(1)!);
      if (value != null && value >= 2 && value <= 12) return value;
    }
    final words = _columnsWords.firstMatch(t);
    if (words != null) {
      final value = _numberWords[words.group(1)!];
      if (value != null && value >= 2 && value <= 12) return value;
    }
    return null;
  }

  /// The drawing a file's note says it was built with ("layout: wide"), so a
  /// vague request after a restart still changes something.
  static String styleFromNote(String note) {
    final match = RegExp(
      r'layout:\s*([a-z]+)',
      caseSensitive: false,
    ).firstMatch(note);
    final style = match?.group(1)?.toLowerCase() ?? '';
    return allStyles.contains(style) ? style : '';
  }

  /// The device kinds a note parked to one side ("side: server,switch").
  static List<String> sideKindsFromNote(String note) {
    final match = RegExp(
      r'side:\s*([a-z]+(?:\s*,\s*[a-z]+)*)',
      caseSensitive: false,
    ).firstMatch(note);
    if (match == null) return const <String>[];
    final out = <String>[];
    for (final part in (match.group(1) ?? '').split(',')) {
      final kind = _canonicalKind(part.trim());
      if (kind != null && !out.contains(kind)) out.add(kind);
    }
    return out;
  }

  /// The edge a note parked its column at ("edge: right").
  static String sideEdgeFromNote(String note) =>
      RegExp(r'edge:\s*(left|right)', caseSensitive: false)
              .firstMatch(note)
              ?.group(1)
              ?.toLowerCase() ??
      'left';

  /// The note a chosen drawing is stamped as, read back by all three readers
  /// above. One format, so the gallery, the chat redraw and the builder screen
  /// can never disagree about what drawing a plan is on.
  ///
  /// Zones are written `zones=kind:server@left|name:SRV1@right`, which is
  /// unambiguous: an item is either a device kind or a named device, never
  /// both, so a plan with a device called "SERVERS" cannot be misread.
  static String noteFor(
    String style, {
    List<String> sideKinds = const <String>[],
    List<String> sideNames = const <String>[],
    String sideEdge = 'left',
    List<LayoutZoneRequest> zones = const <LayoutZoneRequest>[],
  }) {
    final parts = <String>['layout: $style'];
    if (zones.isNotEmpty) {
      parts.add(
        'zones=${[
          for (final zone in zones)
            '${[
              for (final kind in zone.kinds) 'kind:$kind',
              for (final name in zone.names) 'name:$name',
            ].join(',')}@${zone.edge}',
        ].join('|')}',
      );
    } else if (sideKinds.isNotEmpty || sideNames.isNotEmpty) {
      parts.add('side: ${sideKinds.join(',')}');
      if (sideNames.isNotEmpty) parts.add('devices: ${sideNames.join(',')}');
      parts.add('edge: $sideEdge');
    }
    return parts.join(' ');
  }

  /// The device names a note parked to one side ("devices: SRV1,SRV2").
  static List<String> sideNamesFromNote(String note) {
    final match = RegExp(
      r'devices:\s*([A-Za-z0-9]+(?:\s*,\s*[A-Za-z0-9]+)*)',
    ).firstMatch(note);
    if (match == null) return const <String>[];
    return <String>[
      for (final part in (match.group(1) ?? '').split(','))
        if (part.trim().isNotEmpty) part.trim().toUpperCase(),
    ];
  }

  /// The zones a note recorded, in order.
  static List<LayoutZoneRequest> zonesFromNote(String note) {
    final match = RegExp(r'zones=([^\s]+)').firstMatch(note);
    if (match == null) return const <LayoutZoneRequest>[];
    final out = <LayoutZoneRequest>[];
    for (final chunk in (match.group(1) ?? '').split('|')) {
      final at = chunk.lastIndexOf('@');
      if (at <= 0) continue;
      final edge = chunk.substring(at + 1);
      if (edge != 'left' && edge != 'right') continue;
      final kinds = <String>[];
      final names = <String>[];
      for (final item in chunk.substring(0, at).split(',')) {
        final value = item.trim();
        if (value.startsWith('kind:')) {
          kinds.add(value.substring(5));
        } else if (value.startsWith('name:')) {
          names.add(value.substring(5).toUpperCase());
        }
      }
      if (kinds.isNotEmpty || names.isNotEmpty) {
        out.add(LayoutZoneRequest(kinds: kinds, names: names, edge: edge));
      }
    }
    return out;
  }
}
