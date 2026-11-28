import 'diagnostic_playbooks.dart';
import 'networking_playbooks.dart';

/// The triage layer: what a senior engineer does with a fault report before
/// naming a technology.
///
/// A ticket rarely arrives as "BGP neighbour in Active". It arrives as "since
/// we changed the MTU the VPN hangs", "only my laptop cannot reach the file
/// server", "wifi works but the wired ports are dead", "it works for five
/// minutes then drops", or as a pasted syslog line. The answer depends on the
/// *shape* of the report more than on the protocol:
///
/// * **Scope narrows the search.** One host, one VLAN, one site, everyone,
///   wireless only, one direction - each one rules out most of the path and
///   names the test that proves the boundary. This layer states what the
///   report already rules out instead of asking the user to start over.
/// * **A change is a prime suspect, not a coincidence.** The same change
///   fails in a characteristic way (an MTU change breaks large packets, a
///   VLAN change fails at a trunk boundary, a certificate change fails on
///   chain or name), so the first test is specific.
/// * **Two symptoms are usually one fault.** When two different playbook
///   domains appear in separate clauses, the shared dependency is named
///   before the two ladders are worked.
/// * **A syslog line is a named state.** The facility, severity and mnemonic
///   are decoded, and the message is tied to the check that proves it.
///
/// Everything here is deterministic and offline. It never guesses a cause it
/// cannot test, and it stays out of definitions, purchases and build briefs.
class TriageAnswer {
  final String text;
  final String topic;

  const TriageAnswer(this.text, this.topic);
}

class NetworkingTriage {
  const NetworkingTriage._();

  // --- entry points --------------------------------------------------------

  /// A scenario that is a ladder, not a technology: a client that says it is
  /// connected but has no internet, or a ping that works while the browser
  /// does not. Both are common enough that the first answer should be the
  /// order of checks, not a guess at the protocol.
  static TriageAnswer? scenario(String evidence) {
    if (_connectedNoInternet.hasMatch(evidence)) {
      return TriageAnswer(_connectedNoInternetAnswer, 'connected-no-internet');
    }
    if (_pingButNoBrowse.hasMatch(evidence)) {
      return TriageAnswer(_pingButNoBrowseAnswer, 'ping-no-browse');
    }
    if (_pingButService.hasMatch(evidence)) {
      return TriageAnswer(_pingButServiceAnswer, 'ping-but-service');
    }
    if (_guestPortal.hasMatch(evidence)) {
      return TriageAnswer(_guestPortalAnswer, 'guest-portal');
    }
    if (_oneVlan.hasMatch(evidence)) {
      return TriageAnswer(_oneVlanAnswer, 'one-vlan');
    }
    if (_linkUpNoTraffic.hasMatch(evidence)) {
      return TriageAnswer(_linkUpNoTrafficAnswer, 'link-up-no-traffic');
    }
    return null;
  }

  /// "Where do I start?" has an honest order even when the symptom is not
  /// named: scope, then layer, then time. It runs after the playbooks, so a
  /// named fault still gets its own ladder instead of a method lecture.
  static TriageAnswer? method(String evidence) {
    if (!_triageOrder.hasMatch(evidence)) return null;
    // "2 routers and 4 switches, where do I start?" is a build brief, not a
    // fault report. The planner/brief layer owns "where do I start" when the
    // sentence also asks for equipment, a lab or a design.
    if (_buildContext.hasMatch(evidence)) return null;
    return const TriageAnswer(_triageOrderAnswer, 'triage-order');
  }

  /// A pasted syslog or ASA message. The severity is decoded even when the
  /// mnemonic is not in the table, because the severity already says whether
  /// the device is reporting a failure or a state change.
  static TriageAnswer? syslog(String evidence) {
    final match = _syslogPattern.firstMatch(evidence);
    if (match == null) return null;
    final facility = match.group(1)!.toUpperCase();
    final severity = int.parse(match.group(2)!);
    final mnemonic = match.group(3)!.toUpperCase();
    final key = '$facility-$severity-$mnemonic';
    final fact = _syslogFacts[key];
    final b = StringBuffer()
      ..writeln(
        '`%$key` is a ${_severityName(severity)} (severity $severity) '
        'from ${_facilityName(facility)}.',
      )
      ..writeln();
    if (fact != null) {
      b.writeln('What it means: ${fact.meaning}');
      b.writeln();
      b.writeln('What I would run:');
      for (final check in fact.checks) {
        b.writeln('- $check');
      }
      if (fact.rule.isNotEmpty) {
        b.writeln();
        b.writeln('Rule: ${fact.rule}');
      }
    } else {
      b.writeln(
        'Severity $severity is ${_severityAdvice(severity)} The mnemonic '
        '$mnemonic is the vendor lookup key; the text after the colon is the '
        'specific instance (addresses, ports and the reason).',
      );
      b.writeln();
      b.writeln('What I would run:');
      b.writeln(
        '- `show logging | include $mnemonic` - whether this is a one-off '
        'or a repeating state change; the interval is the diagnosis.',
      );
      b.writeln(
        '- Put the first timestamp beside your change window and the '
        'interface/neighbour counters for the same period.',
      );
      b.writeln();
      b.writeln(
        'Do not act on the line alone: a severity 4 warning usually means the '
        'device protected itself, while a severity 3 error means something '
        'failed. Read the reason in the message before changing a config.',
      );
    }
    return TriageAnswer(
      b.toString().trim(),
      'syslog-${mnemonic.toLowerCase()}',
    );
  }

  /// Two symptoms in separate clauses. Returns null when the report is one
  /// fault, which is the common case, so the single playbook keeps its full
  /// ladder.
  static TriageAnswer? compound(
    String evidence,
    List<PlaybookMatch> wholeMatches,
  ) {
    if (wholeMatches.length < 2) return null;
    final known = {for (final match in wholeMatches) match.playbook.id};
    // The evidence is the raw, canonical and understood forms on separate
    // lines. Only the last line is analysed: it keeps the user's words and
    // adds the canonical phrases, so reading all three would count the same
    // sentence as several symptoms.
    final lines = evidence
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final text = lines.isEmpty ? evidence : lines.last;
    final chosen = <PlaybookMatch>[];
    for (final clause in _clauses(text)) {
      final matches = NetworkingPlaybooks.matches(clause, limit: 3);
      for (final match in matches) {
        if (match.signalLength < 4) continue;
        if (!known.contains(match.playbook.id)) continue;
        if (chosen.any((c) => c.playbook.id == match.playbook.id)) continue;
        if (chosen.isNotEmpty &&
            _family(chosen.first.playbook) == _family(match.playbook)) {
          continue;
        }
        chosen.add(match);
        break;
      }
      if (chosen.length == 2) break;
    }
    if (chosen.length < 2) return null;

    chosen.sort((a, b) {
      final radius = _radius(b.playbook).compareTo(_radius(a.playbook));
      if (radius != 0) return radius;
      return b.score.compareTo(a.score);
    });

    final key = [chosen[0].playbook.id, chosen[1].playbook.id]..sort();
    final shared = _sharedCause[key.join('|')];
    final b = StringBuffer()
      ..writeln(
        'Two symptoms at once - I would not open two tickets until I had '
        'tested whether one fault explains both.',
      )
      ..writeln()
      ..writeln(
        shared ??
            'They can share a dependency even when the technologies look '
                'unrelated: one path, one resolver, one queue, one power '
                'source or one change. Work the larger blast radius first; if '
                'the second symptom disappears with it, they were one fault.',
      )
      ..writeln();
    for (var i = 0; i < chosen.length; i++) {
      final playbook = chosen[i].playbook;
      b.writeln('${i + 1}. ${playbook.title}');
      b.writeln('   ${_firstSentence(playbook.meaning)}');
      if (playbook.checks.isNotEmpty) {
        final check = playbook.checks.first;
        b.writeln('   First check: `${check.command}` - ${check.proves}.');
      }
    }
    b
      ..writeln()
      ..writeln(
        'Fix the first one and re-test both symptoms with the same test. If '
        'the second survives, it is a separate fault - ask for it by name and '
        'work its full ladder.',
      );
    return TriageAnswer(
      b.toString().trim(),
      '${chosen[0].playbook.id}+${chosen[1].playbook.id}',
    );
  }

  /// Extra reasoning appended to one playbook answer: what the scope already
  /// rules out and whether a named change is the prime suspect. Empty when
  /// the report has neither, so the corpus answer keeps its exact shape.
  static String annotate(String evidence, DiagnosticPlaybook playbook) {
    final change = _change(evidence);
    final scopes = _scopes(evidence)
        .where((scope) => change == null || scope.id != 'after-change')
        .take(2)
        .toList();
    if (scopes.isEmpty && change == null) return '';
    final b = StringBuffer();
    if (scopes.isNotEmpty) {
      b.writeln('What your report already narrows:');
      for (final scope in scopes) {
        b.writeln('- ${scope.heading}. ${scope.narrows.join('; ')}.');
        b.writeln('  Test: ${scope.test}');
      }
    }
    if (change != null) {
      if (b.isNotEmpty) b.writeln();
      b.write(_renderChange(change));
    }
    return b.toString().trim();
  }

  /// A named change plus a fault symptom, answered on its own when no
  /// playbook matched. This is the "since we changed the MTU, HTTPS hangs"
  /// case, which is a change-correlation question before it is an MTU
  /// question.
  static TriageAnswer? change(String evidence) {
    if (!_changeMarker.hasMatch(evidence)) return null;
    if (!_faultWord.hasMatch(evidence)) return null;
    if (_purchase.hasMatch(evidence) || _designAsk.hasMatch(evidence)) {
      return null;
    }
    final found = _change(evidence);
    if (found != null) {
      return TriageAnswer(
        _renderChange(found, standalone: true),
        'change-${found.id}',
      );
    }
    // The change was mentioned but not named. That is still useful: naming
    // the object is the first step, because each one fails differently.
    return TriageAnswer(
      'You mentioned a change but not what changed. Name the object - MTU, '
          'VLAN, ACL/firewall rule, NAT, route, routing protocol, firmware, DNS, '
          'DHCP scope, certificate, QoS, ISP or circuit, wireless - because each '
          'one fails in a characteristic way and the first test is different for '
          'every one.',
      'change-unknown',
    );
  }

  /// A scope with a fault but no playbook match. The scope is the answer:
  /// it says what is already ruled out, what is left, and the one test that
  /// proves the boundary. This is what keeps "only my laptop cannot reach the
  /// file server" from falling through as an unknown question.
  static TriageAnswer? scopeAnswer(String evidence) {
    if (!_faultWord.hasMatch(evidence)) return null;
    if (_purchase.hasMatch(evidence) || _designAsk.hasMatch(evidence)) {
      return null;
    }
    final scopes = _scopes(
      evidence,
    ).where((scope) => scope.id != 'after-change').take(2).toList();
    if (scopes.isEmpty) return null;
    final b = StringBuffer()
      ..writeln(
        'The scope is the most useful fact here: '
        '${scopes.first.heading.toLowerCase()}.',
      )
      ..writeln()
      ..writeln('What that rules out, and what is left:');
    for (final scope in scopes) {
      for (final narrow in scope.narrows) {
        b.writeln('- $narrow');
      }
    }
    b
      ..writeln()
      ..writeln('Test that proves it: ${scopes.first.test}')
      ..writeln()
      ..writeln(
        'Then work the layers in order: link/port -> address (DHCP/ARP) -> '
        'route/gateway -> name resolution -> TCP port -> application. Stop at '
        'the first layer that fails; every layer above it is already proven '
        'good, and changing it cannot fix the fault below.',
      );
    return TriageAnswer(b.toString().trim(), 'scope-${scopes.first.id}');
  }

  /// A complaint with no symptom. Three questions cut it down faster than any
  /// guess, and the checks are read-only.
  static TriageAnswer? vague(String evidence) {
    if (!_vagueComplaint.hasMatch(evidence)) return null;
    return TriageAnswer(
      '"Something is wrong" is a starting point, not a symptom. Three answers '
          'narrow it faster than any guess, and each one changes the next step:\n\n'
          '1. Scope - one host, one VLAN, one site, or everyone? Compare a working '
          'device with a broken one on the same switch and VLAN. That single '
          'comparison decides whether the fault is at the edge or in shared '
          'infrastructure.\n'
          '2. Layer - does ping work, does the name resolve, does the TCP port '
          'open? Ping proves the path, `nslookup` proves DNS, and a TCP test '
          'proves policy and the listener. The first failure names the layer.\n'
          '3. Time - constant, intermittent, or since a change? A constant fault '
          'is a broken dependency; an intermittent one is a timer, RF or a '
          'physical link; a fault after a change is that change until proved '
          'otherwise.\n\n'
          'Read-only checks to run while you find out:\n'
          '- `show interfaces | include errors|drops|duplex|reset` - the physical '
          'layer and any output drops.\n'
          '- `ping <gateway>`, then `ping 8.8.8.8`, then `nslookup <name>` - the '
          'three boundaries in under a minute.\n'
          '- `show logging` around the first complaint - the device usually '
          'logged the cause before the user noticed.\n'
          '- `show ip route <prefix>` and `show ip arp` - the routed and '
          'same-subnet cases.\n\n'
          'Answer those three and the fault becomes a playbook, not a mystery.',
      'vague-triage',
    );
  }

  // --- scope reasoning -----------------------------------------------------

  static List<_Scope> _scopes(String text) => [
    for (final rule in _scopeRules)
      if (rule.pattern.hasMatch(text))
        _Scope(rule.id, rule.heading, rule.narrows, rule.test),
  ];

  /// True when the report describes an explicit boundary, used by tests and
  /// by callers that want to know whether triage will add anything.
  static bool hasScope(String text) => _scopes(text).isNotEmpty;

  // --- change reasoning ----------------------------------------------------

  static _Change? _change(String text) {
    if (!_changeMarker.hasMatch(text) && !_nothingChanged.hasMatch(text)) {
      return null;
    }
    for (final rule in _changeRules) {
      if (rule.pattern.hasMatch(text)) return rule.change;
    }
    return null;
  }

  static String _renderChange(_Change change, {bool standalone = false}) {
    final b = StringBuffer()
      ..writeln(
        '${change.label} is the prime suspect, not a coincidence to rule out '
        'later.',
      )
      ..writeln('- Why that change fits: ${change.why}')
      ..writeln('- Prove or clear it: ${change.check}')
      ..writeln('- Rollback: ${change.rollback}');
    if (standalone) {
      b
        ..writeln()
        ..writeln(
          'If the same flow works after the rollback, the change is the cause; '
          'reapply it with that check as the gate. If it still fails, the '
          'change is innocent - send me the exact symptom and I will work the '
          'fault itself.',
        );
    }
    return b.toString().trim();
  }

  // --- shared helpers ------------------------------------------------------

  static List<String> _clauses(String text) {
    final parts = text.toLowerCase().split(
      RegExp(r'(?:;|\.\s|\n|\bthen\b|,\s*(?:and|plus|also)\b|\band\b)'),
    );
    return [
      for (final part in parts)
        if (part.trim().length >= 6) part.trim(),
    ];
  }

  static String _family(DiagnosticPlaybook playbook) {
    final override = _familyOverrides[playbook.id];
    if (override != null) return override;
    return playbook.id.split('-').first;
  }

  static int _radius(DiagnosticPlaybook playbook) {
    if (_wideBlast.contains(playbook.id)) return 3;
    if (_narrowBlast.contains(playbook.id)) return 1;
    return 2;
  }

  static String _firstSentence(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final match = RegExp(r'^(.+?[.!?])(?:\s|$)').firstMatch(flat);
    return match?.group(1) ?? flat;
  }

  static const List<String> _severityNames = [
    'emergency',
    'alert',
    'critical',
    'error',
    'warning',
    'notification',
    'informational',
    'debugging',
  ];

  static String _severityName(int severity) =>
      _severityNames[severity < 0 ? 0 : (severity > 7 ? 7 : severity)];

  static String _severityAdvice(int severity) {
    if (severity <= 2) {
      return 'a paging severity: the device is reporting a real service '
          'failure, so treat it before anything cosmetic.';
    }
    if (severity == 3) {
      return 'an error: something failed, though forwarding may still be up.';
    }
    if (severity == 4) {
      return 'a warning: the device protected itself or detected a condition '
          'that needs a look.';
    }
    if (severity == 5) {
      return 'a notification: a state changed (a link, a neighbour, a config), '
          'which is the timeline you want, not the cause by itself.';
    }
    return 'informational/debug output: useful for a timeline, not a cause.';
  }

  static String _facilityName(String facility) {
    const names = {
      'SW_MATM': 'the MAC address table manager',
      'PM': 'the port manager',
      'SPANTREE': 'spanning tree',
      'PORT_SECURITY': 'port security',
      'LINEPROTO': 'the line protocol',
      'LINK': 'the link layer',
      'OSPF': 'OSPF',
      'BGP': 'BGP',
      'DUAL': 'EIGRP (DUAL)',
      'CDP': 'CDP',
      'DHCPD': 'the DHCP server',
      'IP': 'IP',
      'FIB': 'the forwarding information base',
      'ILPOWER': 'PoE',
      'CRYPTO': 'IPsec',
      'SYS': 'the system',
      'ASA': 'the ASA',
      'PARSER': 'the configuration parser',
      'CONFIG': 'the configuration subsystem',
    };
    return names[facility] ?? 'the $facility subsystem';
  }

  // --- patterns ------------------------------------------------------------

  static final RegExp _syslogPattern = RegExp(
    r'%([A-Za-z][A-Za-z0-9_]*)-([0-7])-([A-Za-z0-9_]+)',
  );

  static final RegExp _connectedNoInternet = RegExp(
    r'\b(?:connected|connect(?:s|ed)? to (?:the )?(?:wifi|wi-fi|network|lan|'
    r'ethernet)|shows connected)\b.{0,70}?\b(?:no internet|no connectivity|'
    r'not getting online|cannot get online|no access|no web)\b|'
    r'\b(?:no internet|no connectivity)\b.{0,40}?\b(?:but|yet|although)\b'
    r'.{0,30}?\b(?:connected|wifi works|ethernet works)\b',
  );

  static final RegExp _pingButNoBrowse = RegExp(
    r'\bping\b.{0,30}?\b(?:works|work|is fine|succeeds|passes|good)\b'
    r'.{0,80}?\b(?:cannot browse|cannot open|cannot load|will not load|'
    r'do not load|does not load|https? (?:fails|hangs|times out)|'
    r'browser (?:fails|hangs|times out)|website (?:fails|hangs))\b|'
    r'\b(?:cannot browse|cannot open websites?|websites? (?:do not|will not) '
    r'load)\b.{0,60}?\b(?:but )?ping\b.{0,20}?\b(?:works|is fine|succeeds)\b',
  );

  static final RegExp _pingButService = RegExp(
    r'\b(?:no image|no video|no stream|black screen|no picture)\b.{0,60}?'
    r'\b(?:but|yet)\b.{0,30}?\bping(?:s| works)?\b|'
    r'\bping(?:s| works| is fine)?\b.{0,70}?\b(?:no image|no video|'
    r'no stream|black screen|no picture|service (?:does not|will not) work|'
    r'app (?:does not|will not) work)\b',
  );

  static final RegExp _guestPortal = RegExp(
    r'\b(?:guest|captive) portal\b.{0,40}?\b(?:does not|doesn.t|will not|'
    r'won.t|fails? to|not) (?:load|open|appear|work)\b',
  );

  static final RegExp _oneVlan = RegExp(
    r'\b(?:works?|prints?|reachable|accessible|connects?)\b.{0,40}?'
    r'\bfrom (?:one|a) (?:vlan|subnet|network)\b.{0,40}?\b(?:not|but not)\b',
  );

  static final RegExp _linkUpNoTraffic = RegExp(
    r'\b(?:link|port|interface|uplink)\b.{0,20}?\bis up\b.{0,40}?'
    r'\b(?:but|yet)\b.{0,30}?\b(?:no traffic|no packets|nothing passes|'
    r'no data)\b',
  );

  static final RegExp _buildContext = RegExp(
    r'\b(?:build|building|design|designing|configure|configuring|set up|'
    r'setup|install|deploy|lab|packet tracer)\b|'
    r'\b\d+\s+(?:routers?|switches?|pcs?|hosts?|access points?|sites?)\b',
  );

  static final RegExp _triageOrder = RegExp(
    r'\bwhat (?:should|do) i (?:check|look at|verify) first\b|'
    r'\bwhere (?:do|should) i (?:start|begin)\b|'
    r"\bwhat(?:'s| is) the first (?:thing|step) to (?:check|do)\b|"
    r'\bhow do i (?:start|begin) troubleshoot\b|'
    r'\bwhich (?:one )?should i check first\b',
  );

  static final RegExp _vagueComplaint = RegExp(
    r'\b(?:acting (?:weird|strange|funny|up)|something is wrong|'
    r'something is broken|something is not right|users are complaining|'
    r'people are complaining|not right|flaky|unstable|on and off problems|'
    r'weird behavio(?:u)?r)\b',
  );

  static final RegExp _changeMarker = RegExp(
    r'\b(?:since|after|ever since|right after|following|because of)\b'
    r'[^.?!]{0,70}?\b(?:change|changed|changes|upgrade|upgraded|update|'
    r'updated|migration|migrated|move|moved|replace|replaced|swap|swapped|'
    r'install|installed|add|added|new)\b|'
    r'\b(?:we|they|i|someone|somebody|the team|ops|it)\s+(?:changed|'
    r'upgraded|updated|replaced|moved|added|installed|swapped|migrated|'
    r'deployed|patched|renumbered)\b|'
    r'\b(?:after|since)\s+(?:the|a|our)\s+(?:mtu|vlan|acl|nat|route|'
    r'firmware|ios|dns|dhcp|certificate|cert|qos|isp|wan|switch|firewall|'
    r'upgrade|update|migration)\b',
  );

  static final RegExp _nothingChanged = RegExp(
    r'\b(?:nothing (?:changed|was changed)|no changes? (?:were |was )?made|'
    r'we (?:did not|didnt|didn.t) change anything)\b',
  );

  static final RegExp _faultWord = RegExp(
    r'\b(?:hang|hangs|hanging|slow|slows|fails?|failing|down|drops?|flaps?|'
    r'dropping|cannot|can not|not working|stopped|stopping|times out|'
    r'timeout|flapping|unreachable|broken|errors?|dead|offline|disconnects?|'
    r'not forwarding|not reachable|not by name|printing|'
    r'lost (?:network|connectivity|connection)|'
    r'will not work|does not work|no connectivity|no internet)\b',
  );

  static final RegExp _purchase = RegExp(
    r'\b(?:buy|purchase|price|pricing|quote|budget|recommend|worth it|'
    r'which (?:one|router|switch|firewall|ap|model|vendor))\b',
  );

  static final RegExp _designAsk = RegExp(
    r'\b(?:design|architect|plan|how many|what (?:should|would) (?:the|our|a) '
    r'(?:design|architecture|layout))\b',
  );

  // --- scope rules ---------------------------------------------------------
  //
  // Order is priority: the first two findings are the ones rendered. A
  // specific boundary (one host, one VLAN, one site) comes before a pattern
  // (intermittent, periodic), because the boundary is what narrows the path.

  static final List<_ScopeRule> _scopeRules = [
    _ScopeRule(
      'one-host',
      RegExp(
        r'\b(?:only|just)\s+(?:my|this|one|a single|the same)\s+(?:one\s+)?'
        r'(?:pc|laptop|host|computer|machine|workstation|device|user)\b|'
        r'\b(?:one|a single)\s+(?:pc|laptop|host|computer|machine|'
        r'workstation|device|user)\s+(?:is|has|cannot|can not|keeps|will not|'
        r'does not)\b|'
        r'\bjust me\b|\bonly me\b|'
        r'\bmy (?:pc|laptop|computer)\b.{0,40}?\b(?:cannot|can not|will not|'
        r'does not|keeps)\b',
      ),
      'Only one host is affected',
      [
        'the uplink, WAN, DHCP server and DNS resolver are still serving '
            'everyone else, so a core, provider or server-wide outage is '
            'already unlikely',
        'the candidates are that host\'s stack, its access port, its '
            'VLAN/lease, a host-specific ACL, or a duplicate address',
      ],
      'run the same ping and name lookup from a second host on the same '
          'access switch and VLAN, then move the patch lead to a known-good '
          'port. If the second host works, stop debugging the network and '
          'compare `ipconfig /all` (mask, gateway, DNS) and the ARP entry on '
          'the broken one.',
    ),
    _ScopeRule(
      'everyone',
      RegExp(
        r'\b(?:everyone|everybody|all users|all of us|all devices|'
        r'every device|nobody|no one|the whole (?:office|floor|site|building|'
        r'company|network)|the entire (?:office|site|network|building))\b',
      ),
      'Everyone is affected',
      [
        'no single host is special, so this is a shared dependency: a '
            'gateway/FHRP pair, DHCP or DNS, a firewall, an uplink, a '
            'routing/STP event, or the shared service the report names (print '
            'server, file server, call manager)',
        'a host-level fix cannot explain it, and restarting clients will not '
            'fix it',
      ],
      'from one device, ping the local gateway; then a host in the same VLAN '
          'on another switch; then a host at another site. The first boundary '
          'that fails is the fault domain, and it costs three pings to find.',
    ),
    _ScopeRule(
      'wireless-only',
      RegExp(
        r'\b(?:only|just)\s+(?:on\s+)?(?:the\s+)?(?:wifi|wi-fi|wireless)\b|'
        r'\b(?:wired|ethernet|cable)\s+(?:works|is fine|is ok|is working)\b|'
        r'\bwifi\b.{0,40}?\b(?:fails|broken|bad|dead)\b.{0,40}?\b'
        r'(?:wired|ethernet)\b',
      ),
      'Only wireless clients fail',
      [
        'the wired path, the WAN and the servers are proven good by the wired '
            'clients, so RF (signal, channel, interference), the SSID-to-VLAN '
            'mapping, the AP uplink/PoE, the WLC join, 802.1X/RADIUS and DHCP '
            'for the wireless VLAN are the candidates',
        'a core routing or provider fault is already ruled out',
      ],
      'join the same SSID through a different AP, then put a laptop on a '
          'wired port in that SSID\'s VLAN and get an address. If wired works '
          'and two APs fail, the fault is upstream of the radio (VLAN, DHCP, '
          'RADIUS); if only one AP fails, it is that AP or its coverage.',
    ),
    _ScopeRule(
      'wired-only',
      RegExp(
        r'\b(?:only|just)\s+(?:on\s+)?(?:the\s+)?(?:wired|ethernet|lan|'
        r'cable)\b|'
        r'\b(?:wifi|wireless)\s+(?:works|is fine|is ok|is working)\b|'
        r'\bwired\b.{0,40}?\b(?:fails|broken|dead|down)\b.{0,40}?\b'
        r'(?:wifi|wireless)\b',
      ),
      'Only wired clients fail',
      [
        'RF, the SSID and wireless authentication are working, so look at the '
            'copper or optic, the access port, speed/duplex, PoE, port '
            'security/802.1X, and the access VLAN',
        'a WAN or DNS fault is already unlikely',
      ],
      'move the cable to a known-good port and compare `show interface` '
          'counters (CRC, late collisions, resets) on both ports. A clean port '
          'points at the cable or the far end; a dirty one points at the '
          'switchport configuration.',
    ),
    _ScopeRule(
      'remote-only',
      RegExp(
        r'\b(?:only|just)\s+(?:over|on|through|from)\s+(?:the\s+)?'
        r'(?:vpn|remote|home)\b|'
        r'\b(?:in the office|on site|on-site|locally)\s+(?:it\s+)?'
        r'(?:works|is fine|is ok)\b|'
        r'\bremote (?:users|workers)\b.{0,40}?\b(?:cannot|can not|fail|down)\b',
      ),
      'Only remote or VPN users fail',
      [
        'the LAN and the servers are reachable from inside, so the tunnel, '
            'the VPN pool, the return route, NAT-T, the pushed DNS and the '
            'tunnel MTU are the candidates',
        'an internal routing fault is already unlikely',
      ],
      'from the remote client, ping the VPN gateway\'s inside interface, then '
          'a server by IP, then by name, then run `ping -M do -s 1400` through '
          'the tunnel. That separates tunnel routing, DNS and MTU in four '
          'commands.',
    ),
    _ScopeRule(
      'one-segment',
      RegExp(
        r'\b(?:only|just)\s+(?:in|on|from|for)\s+(?:the\s+)?'
        r'(?:vlan|subnet|segment)\b|'
        r'\bvlan\s*\d*\b.{0,30}?\b(?:only|alone)\b|'
        r'\bonly\s+(?:the\s+)?(?:\w+\s+)?vlan\b|'
        r'\bonly (?:that|this) (?:vlan|subnet|segment)\b',
      ),
      'Only one VLAN or subnet fails',
      [
        'other VLANs are healthy, so inter-VLAN routing, the allowed VLAN '
            'list on the trunk, an ACL/VRF between segments, the SVI and the '
            'DHCP scope/relay for that subnet are the candidates',
        'a WAN or provider fault is already ruled out',
      ],
      'ping the SVI for that VLAN from inside it, then from another VLAN, then '
          'check `show ip route` for the connected subnet and `show interfaces '
          'trunk` for the allowed list. A local ping that works and a '
          'cross-VLAN ping that fails is an ACL or routing fault, not a '
          'switching fault.',
    ),
    _ScopeRule(
      'one-site',
      RegExp(
        r'\b(?:only|just)\s+(?:at|in)\s+(?:the\s+)?(?:branch|site|office|'
        r'building|floor|warehouse|store|campus)\b|'
        r'\b(?:other|all other)\s+(?:sites|branches|offices|buildings)\s+'
        r'(?:are\s+)?(?:fine|ok|working|up)\b',
      ),
      'Only one site is affected',
      [
        'the core, data centre and other sites are healthy, so the local '
            'WAN/uplink, power, local DHCP/DNS, FHRP state and the site\'s '
            'routing adjacency are the candidates',
        'a global DNS or provider fault is already unlikely',
      ],
      'from inside the site, ping the local gateway, then the WAN edge, then a '
          'core resource. If the gateway answers and the edge does not, the '
          'fault is the local uplink or provider; if the edge answers and the '
          'core does not, it is routing.',
    ),
    _ScopeRule(
      'one-application',
      RegExp(
        r'\b(?:only|just)\s+(?:one\s+)?(?:app|application|website|web app|'
        r'service)\b|'
        r'\b(?:internal|one)\s+(?:app|application|server|service)\b.{0,60}?\b'
        r'(?:times? out|fails?|slow|unreachable)\b|'
        r'\b(?:internet|network|everything else)\s+(?:works|work|is fine|'
        r'is ok)\b.{0,60}?\b(?:but|except)\b.{0,40}?\b(?:app|application|'
        r'server|service|website)\b|'
        r'\b(?:everything else|other apps|other applications|other websites|'
        r'other services)\s+(?:works|work|is fine|are fine)\b',
      ),
      'Only one application fails',
      [
        'the path, DNS and the browser are working for other applications, so '
            'the suspect is the server, the URL/virtual host, a proxy or PAC '
            'rule, SNI/TLS, or a CDN/DNS policy for that name',
        'a general network slowdown is already ruled out',
      ],
      'test the same application from a second client and by IP with the same '
          'Host/SNI, then `nslookup` the name against the client resolver and '
          'a public resolver. If both clients fail and the server responds by '
          'IP, the fault is the name or the virtual host, not the network.',
    ),
    _ScopeRule(
      'delay-onset',
      RegExp(
        r'\bworks? (?:for|for about) \d+ (?:seconds?|minutes?|hours?)\b|'
        r'\bafter (?:about )?\d+ (?:seconds?|minutes?|hours?) (?:it\s+)?'
        r'(?:stops|drops|disconnects|hangs|fails)\b|'
        r'\bfor a while (?:and )?then\b|'
        r'\b(?:drops?|disconnects?|stops?|fails?|times? out)\b.{0,30}?\b'
        r'after (?:about )?\d+ (?:seconds?|minutes?|hours?)\b|'
        r'\bthen (?:it )?(?:stops|drops|disconnects|hangs|fails)\b',
      ),
      'It works for a while, then fails',
      [
        'an immediate ACL or route failure would never work at all, so a fixed '
            'delay points at a timer: DHCP lease/renewal, 802.1X '
            'reauthentication, an idle/session timeout, IPsec SA lifetime, ARP '
            'timeout, STP forwarding delay, or a wireless roam',
        'the path itself is proven good for the first interval',
      ],
      'measure the interval from working to failing and compare it with those '
          'timers (`show ip dhcp binding`, `show authentication sessions`, '
          '`show crypto ipsec sa`, `show ip arp`). Then change one timer and '
          'see whether the interval moves - the timer that moves it is the '
          'cause.',
    ),
    _ScopeRule(
      'mtu-symptom',
      RegExp(
        r'\bsmall pings? (?:work|works|pass|passes)\b.{0,60}?\b(?:large|big)\b|'
        r'\blarge (?:pings?|packets?|transfers?|files?)\s+(?:fail|fails|hang|'
        r'hangs|drop|drops)\b|'
        r'\bpages? half load\b|'
        r'\bfile transfers? (?:stall|hang|fail)\b.{0,40}?\b(?:small|ping)\b',
      ),
      'Small packets work and large ones fail',
      [
        'small packets and name lookups working proves the path, ARP, routing '
            'and DNS; a failure at a particular packet size is MTU or PMTUD, '
            'usually a tunnel whose overhead was not subtracted or a provider '
            'that drops ICMP fragmentation-needed',
        'a routing or DNS fault is already ruled out',
      ],
      '`ping -M do -s 1472 <dst>` (Windows: `ping -f -l 1472 <dst>`), then '
          'lower the size until it passes. The largest passing size plus 28 is '
          'the real path MTU; set `ip mtu`/`ip tcp adjust-mss` on the tunnel to '
          'fit it.',
    ),
    _ScopeRule(
      'transport-only',
      RegExp(
        r'\bping\b.{0,30}?\b(?:works|is fine|succeeds|passes|good)\b.{0,90}?'
        r'\b(?:https?|ssh|rdp|tcp|port \d+|website|web|browser|login)\b'
        r'.{0,50}?\b(?:fails?|blocked|hangs?|times out|refused|cannot|'
        r'will not|does not)\b|'
        r'\b(?:website|https?|port 443|ssh)\b.{0,50}?\b(?:fails?|blocked|'
        r'hangs?)\b.{0,50}?\bping\b.{0,20}?\b(?:works|is fine|succeeds)\b',
      ),
      'Ping works and the TCP port does not',
      [
        'ping succeeding proves IP reachability, so a TCP port that will not '
            'open is policy or the listener: ACL/firewall/security group, NAT, '
            'a proxy, the wrong port, or nothing listening',
        'a routing or cable fault is already ruled out',
      ],
      '`Test-NetConnection <host> -Port <port>` or `nc -vz <host> <port>`. A '
          'refusal means the host is reachable and the port is closed; a '
          'timeout means a device in the path is dropping the SYN. Check ACL '
          'hit counters and `netstat -an` on the server.',
    ),
    _ScopeRule(
      'name-only',
      RegExp(
        r'\b(?:by ip|the ip|ping the ip)\s+(?:works|is fine|succeeds|'
        r'reachable)\b.{0,90}?\b(?:name|hostname|dns|website|domain)\b'
        r'.{0,50}?\b(?:fails?|not|does not|cannot|will not)\b|'
        r'\breachable by (?:the )?ip\b.{0,60}?\b(?:not|but not) by '
        r'(?:the )?name\b|'
        r'\bworks? by (?:the )?ip\b.{0,60}?\b(?:not|fails?) by (?:the )?name\b|'
        r'\bdns\b.{0,40}?\b(?:fails?|broken|not working)\b.{0,60}?\b'
        r'(?:ip|ping)\b.{0,20}?\b(?:works|is fine)\b',
      ),
      'IP works and the name does not',
      [
        'reaching the service by IP proves routing and the listener; a name '
            'that fails points at DNS, the search suffix, split-horizon, a '
            'proxy PAC, or SNI/TLS - not at the network path',
        'the server and the route are already proven good',
      ],
      '`nslookup <name>` against the client\'s configured resolver and '
          'against a public resolver, then connect by IP with the same Host '
          'header/SNI. Different answers from the two resolvers is a DNS '
          'policy fault; the same failure by IP is the service.',
    ),
    _ScopeRule(
      'one-direction',
      RegExp(
        r'\bone[- ]way\b|\bworks? in one direction\b|'
        r'\bgoes out but (?:does not|doesn.t) come back\b|'
        r'\breplies? (?:do not|don.t) (?:come back|return)\b|'
        r'\bcan send but (?:cannot|can not) receive\b',
      ),
      'Traffic works in one direction',
      [
        'one direction working rules out the cable and the interface; the '
            'return path is the suspect: a missing return route, asymmetric '
            'routing through a stateful firewall, NAT, uRPF, or an ACL applied '
            'in one direction',
        'the forward path and the application listener are already proven '
            'good',
      ],
      'capture at both ends at the same time and compare source and '
          'destination. On the return path run `show ip route <source>` and '
          'check the firewall session table for the flow. If the reply leaves '
          'the wrong interface it is routing; if it never leaves, it is policy.',
    ),
    _ScopeRule(
      'intermittent',
      RegExp(
        r'\b(?:intermittent(?:ly)?|random(?:ly)?|occasionally|now and then|'
        r'on and off|off and on|comes and goes|every few (?:minutes|hours|'
        r'seconds)|twice a day|sometimes|flaky)\b',
      ),
      'The fault is intermittent',
      [
        'a hard ACL, route or cable break would fail every time, so an '
            'intermittent fault points at a timer, a lease/renewal, RF roaming '
            'or interference, a flapping link/optic, an STP topology change, '
            'one ECMP member, a microburst, or a session idle timeout',
        'the configuration that is validated once is probably not wrong - the '
            'condition under which it runs is',
      ],
      'run a timestamped continuous ping (`ping -t` or `ping -D`) and '
          '`show log` on the path devices, then line the failure times up with '
          'the lease T1, 802.1X reauthentication, IPsec SA lifetime, STP '
          'changes and interface resets. The interval usually names the timer.',
    ),
    _ScopeRule(
      'periodic',
      RegExp(
        r'\b(?:every day at|same time (?:every|each) day|at the same time '
        r'every|in the morning|after lunch|at night|end of (?:the )?day|'
        r'start of (?:the )?day|every morning|every night)\b',
      ),
      'The fault keeps a schedule',
      [
        'a fault that keeps an appointment is almost always a scheduled '
            'process or a load pattern, not a random hardware failure: a '
            'backup/replication, a DHCP lease storm, a certificate/CRL '
            'refresh, a routing reconvergence, wireless busy hour, or provider '
            'maintenance',
        'the fault is unlikely to be a bad cable or a single broken config',
      ],
      'compare the first and last failure timestamps with the backup, '
          'replication and cron schedules, and with interface utilisation at '
          'the same minute. If the time moves when the schedule moves, you '
          'have found it.',
    ),
    _ScopeRule(
      'after-reboot',
      RegExp(
        r'\bafter (?:a )?(?:reboot|restart|power (?:cut|outage|failure|cycle)|'
        r'ups (?:event|failure)|came back up)\b|\bsince the power\b',
      ),
      'The fault started after a reboot or power event',
      [
        'a reboot does not change hardware, so the suspects are unsaved '
            'configuration, a different startup config, a changed STP root or '
            'FHRP active role, a licence/feature that did not come up, and a '
            'clock that reset',
        'the physical path is usually unchanged',
      ],
      '`show running-config` vs `show startup-config`, `show boot`, then '
          '`show spanning-tree root` and the FHRP active/standby state on every '
          'device that rebooted. Save the config and fix the election weights '
          'before the next reboot repeats it.',
    ),
    _ScopeRule(
      'steady-state',
      RegExp(
        r'\b(?:nothing (?:changed|was changed)|no changes? (?:were |was )?made|'
        r'we (?:did not|didnt|didn.t) change anything)\b',
      ),
      'Nothing was changed',
      [
        'with no change to blame, the usual causes are capacity that crossed '
            'a threshold, a hardware/optic degradation, an expiry (certificate, '
            'licence, DHCP lease, password), a duplicate address from a new '
            'device, or a dependency outside your network',
        'the configuration that worked yesterday is evidence, not the suspect',
      ],
      'find the first event, not the loudest one: `show logging` at the first '
          'complaint, interface error/reset counters, CPU and TCAM history, '
          'and the certificate/licence dates. A threshold crossing looks like '
          'a sudden fault and is really a trend.',
    ),
    _ScopeRule(
      'after-change',
      _changeMarker,
      'The fault started after a change',
      [
        'correlation is not proof, but the change is the prime suspect until a '
            'config diff or a rollback clears it',
        'a fault that begins at the change window is better explained by the '
            'change than by a simultaneous hardware failure',
      ],
      'diff the running config against the last known-good backup '
          '(`show archive config differences`), put the change window beside '
          'the first log event, and reproduce the fault in a lab or maintenance '
          'window before rolling back in production.',
    ),
  ];

  // --- change rules --------------------------------------------------------

  static final List<_ChangeRule> _changeRules = [
    _ChangeRule(
      RegExp(r'\bmtu\b|\bjumbo\b'),
      const _Change(
        'mtu',
        'The MTU or jumbo-frame change',
        'an MTU change breaks large packets first: pings and DNS still pass '
            'while TLS handshakes, logins and file transfers hang. A tunnel '
            'or a provider that drops ICMP fragmentation-needed turns it into '
            'a black hole.',
        '`ping -M do -s 1472 <dst>` (Windows: `ping -f -l 1472 <dst>`) and '
            'lower the size until it passes; the largest passing size plus 28 '
            'is the real path MTU. Check `show interfaces | include MTU` end '
            'to end and the tunnel\'s `ip mtu` / `ip tcp adjust-mss`.',
        'put the previous MTU back on both ends first, confirm the original '
            'flow, then reapply it with the path-MTU test as the gate.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bvlan\b|\btrunk\b|\bnative vlan\b'),
      const _Change(
        'vlan',
        'The VLAN or trunk change',
        'a VLAN change fails at a boundary: the VLAN missing from the trunk '
            'allowed list, a native-VLAN mismatch, an SVI without an address, '
            'or a DHCP relay for the wrong subnet.',
        '`show interfaces trunk`, `show vlan brief`, `show interfaces '
            'switchport`, and `show ip interface brief` for the SVI on both '
            'sides. A VLAN that exists locally but is not in the allowed list '
            'is the most common miss.',
        'restore the previous allowed list and native VLAN on both ends, then '
            're-add the VLAN to one link at a time.',
      ),
    ),
    _ChangeRule(
      // "policy" alone is too broad: a QoS policy change is a QoS change, and
      // "firewall policy" already matches on "firewall".
      RegExp(
        r'\bacl\b|\bfirewall\b|\brule\b|\bsecurity group\b|\baccess-list\b',
      ),
      const _Change(
        'policy',
        'The ACL or firewall change',
        'a policy change fails by order and direction: a new permit above a '
            'deny shadows it, a rule is applied inbound on one side only, or a '
            'stateful firewall sees an asymmetric return path.',
        '`show access-lists` / `show access-list <name>` hit counters, '
            '`packet-tracer` on the ASA, and a test from both directions. A '
            'rule with zero hits is not matching the flow you think it is.',
        'restore the previous rule order first; rules are order-dependent, so '
            '"adding a permit" is not a rollback.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bnat\b|\bpat\b|\bport forwarding\b'),
      const _Change(
        'nat',
        'The NAT or PAT change',
        'NAT changes fail on order or exhaustion: a translation above or below '
            'the one you meant, a missing return translation, or a pool too '
            'small for the flow rate.',
        '`show ip nat translations | include <ip>`, `show ip nat statistics`, '
            'and a test from the real source address. On ASA, `show nat` and '
            '`packet-tracer` show which rule actually matched.',
        'restore the previous NAT statement and clear only the translations '
            'for the test flow, not the whole table.',
      ),
    ),
    _ChangeRule(
      RegExp(
        r'\bstatic route\b|\bdefault route\b|\bdefault gateway\b|\broute\b|'
        r'\bredistribution\b',
      ),
      const _Change(
        'route',
        'The route change',
        'a route change can be overridden by a longer prefix, a lower '
            'administrative distance, or a summary that covers addresses it '
            'cannot reach.',
        '`show ip route <prefix>`, `show ip route <destination>`, and '
            '`traceroute` to the destination. Longest prefix always wins '
            'before distance, so compare the exact prefix, not the protocol.',
        'put the previous next hop and distance back and re-test the exact '
            'destination that failed; a floating static is the safe way to '
            'keep both.',
      ),
    ),
    _ChangeRule(
      RegExp(
        r'\bospf\b|\beigrp\b|\bbgp\b|\brouting protocol\b|\bisis\b|'
        r'\broute reflector\b',
      ),
      const _Change(
        'routing-protocol',
        'The routing-protocol change',
        'an IGP or BGP change usually breaks adjacency or policy: a '
            'timer/area/auth mismatch, a missing network statement, a '
            'distribute/prefix filter, or a next hop that is not reachable.',
        '`show ip ospf neighbor` / `show ip eigrp neighbors` / `show ip bgp '
            'summary`, then `show ip protocols` for the filters and `show ip '
            'route` for what actually installed.',
        'restore the previous protocol config on one router at a time and '
            'watch the adjacency recover; a routing change without a config '
            'backup is not a rollback plan.',
      ),
    ),
    _ChangeRule(
      // No bare "upgrade": "after the ISP upgrade" is a provider change, and
      // the provider rule below names the right suspect. A change with no
      // object falls through to the generic "what changed?" answer instead of
      // being guessed as firmware.
      RegExp(
        r'\bfirmware\b|\bios\b|\bsoftware upgrade\b|\bpatch\b|\bversion\b',
      ),
      const _Change(
        'firmware',
        'The firmware or software change',
        'a firmware change can alter defaults, licensing, feature behaviour or '
            'the startup config, and the fault often appears in a feature you '
            'did not touch.',
        'compare `show running-config` with the pre-upgrade backup, `show '
            'version`, `show license`, and the release notes for behaviour '
            'changes. Check `show boot` for the image actually loaded.',
        'boot the previous image and restore the saved config in a window; do '
            'not "fix forward" during an outage.',
      ),
    ),
    _ChangeRule(
      RegExp(
        r'\bnew switch\b|\breplaced the (?:switch|core|access switch)\b|'
        r'\bswitch replacement\b|\bcore refresh\b',
      ),
      const _Change(
        'switch',
        'The switch replacement',
        'a replaced switch changes the STP root, the trunk/VLAN database, port '
            'security bindings, PoE budget and the management address - any of '
            'which can produce a site-wide symptom.',
        '`show spanning-tree root`, `show interfaces trunk`, `show vlan '
            'brief`, `show power inline`, and a port-by-port comparison with '
            'the old config.',
        'put the old switch back or set the old bridge priority and trunk '
            'config before cutover; verify STP and the gateways first.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bdns\b|\bresolver\b|\bzone\b|\brecord\b'),
      const _Change(
        'dns',
        'The DNS change',
        'a DNS change fails by answer: the wrong record, a TTL that keeps the '
            'old answer alive, a forwarder that cannot recurse, or '
            'split-horizon returning the public address internally.',
        '`nslookup <name> <old-resolver>` and `<new-resolver>`, `dig +trace`, '
            'and a connection by IP with the same Host/SNI. Compare answers '
            'from a client and from the server.',
        'restore the previous record/forwarder and lower the TTL before the '
            'next change; a stale cache is not a propagation problem.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bdhcp\b|\bscope\b|\blease\b|\bip helper\b'),
      const _Change(
        'dhcp',
        'The DHCP change',
        'a DHCP change fails at the scope: a wrong mask, exclusions that cover '
            'the pool, a lease shorter than the churn, a missing relay, or '
            'option 82 rejected by the server.',
        '`show ip dhcp pool`, `show ip dhcp binding`, `show ip dhcp conflict`, '
            'and the relay `show ip interface <svi> | include helper`. Test '
            'with one client and read its `ipconfig /all`.',
        'restore the previous scope and exclusions and clear only the test '
            'lease; do not restart the DHCP service during business hours.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bcertificate\b|\bcert\b|\btls\b|\bssl\b'),
      const _Change(
        'certificate',
        'The certificate change',
        'a certificate change fails on chain, name or time: an intermediate '
            'missing, the CN/SAN not matching the URL, an expired/not-yet-valid '
            'window, or a client trust store that never got the new CA.',
        '`openssl s_client -connect <host>:443 -servername <name>` and '
            '`openssl x509 -noout -dates -subject -issuer`; check the client '
            'clock and the trust store.',
        'put the previous certificate and chain back, then re-issue with the '
            'same SAN list; a browser warning is not a network fault.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bqos\b|\bshaping\b|\bpolicing\b|\bpriority queue\b'),
      const _Change(
        'qos',
        'The QoS change',
        'a QoS change fails silently: the policy is applied in the wrong '
            'direction, the trust boundary rewrites the marking, or the class '
            'matches nothing.',
        '`show policy-map interface <intf>` for match/drop counters, `show '
            'class-map`, and a capture that shows the DSCP actually arriving. '
            'A class with zero matches is a classification bug.',
        'remove the service-policy from the interface first and re-measure; '
            'reapply one direction at a time.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bisp\b|\bprovider\b|\bcircuit\b|\bwan\b|\bcarrier\b'),
      const _Change(
        'provider',
        'The provider or WAN change',
        'a provider change fails on the return path first: asymmetric routing, '
            'a new MTU, a BGP policy that filters your prefix, or NAT that no '
            'longer matches the new address.',
        '`traceroute` from both directions, `show ip bgp summary` / `show ip '
            'bgp <prefix>`, and a test to the new address from outside. A '
            'looking glass on the provider side settles who is dropping.',
        'keep the old circuit and config until the new one passes a full test; '
            'do not cancel the old service on cutover day.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bwireless\b|\bssid\b|\baccess point\b|\bwlc\b|\bwi-?fi\b'),
      const _Change(
        'wireless',
        'The wireless change',
        'a wireless change fails at the join or the VLAN mapping: a new SSID '
            'mapped to the wrong VLAN, a channel/power change that creates a '
            'coverage hole, or a RADIUS/WPA change that only some clients '
            'support.',
        '`show wireless client summary`, `show ap summary`, the SSID-to-VLAN '
            'mapping, and a join test with two client types on two APs.',
        'restore the previous channel, power and SSID mapping and test the '
            'same client; RF changes should be one AP at a time.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\baaa\b|\bpassword\b|\bsecret\b|\bradius\b|\btacacs\b'),
      const _Change(
        'aaa',
        'The AAA or credential change',
        'an AAA change fails on the shared secret, reachability or fallback: a '
            'secret mismatch, a blocked port, or no local fallback when the '
            'server is down.',
        '`test aaa group radius <user> <pass> new-code`, `show tacacs`, and the '
            'server\'s live log. Test with a real login before logging out.',
        'restore `aaa ... local` fallback first so you cannot lock yourself '
            'out, then fix the server or the key.',
      ),
    ),
    _ChangeRule(
      RegExp(
        r'\bip address\b|\bsubnet\b|\bmask\b|\brenumber\b|\baddress plan\b',
      ),
      const _Change(
        'addressing',
        'The addressing change',
        'an addressing change fails on overlap or mask: an overlapping range, '
            'a wrong mask that splits a subnet, a gateway outside the new '
            'block, or a stale ARP/route.',
        '`show ip interface brief`, `show ip route`, `show ip arp` for the '
            'affected block, and a ping from both sides. A host with the right '
            'address and the wrong mask looks "local" to the wrong '
            'destinations.',
        'restore the previous address and mask on one device at a time; '
            'renumbering is a maintenance-window change, not a live fix.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bvmware\b|\bhypervisor\b|\bvm\b|\bport group\b|\bvswitch\b'),
      const _Change(
        'hypervisor',
        'The hypervisor or VM change',
        'a hypervisor change moves MACs and VLAN tags: a VM cloned with the '
            'same MAC, a port group with the wrong VLAN, promiscuous mode off, '
            'or teaming that defeats the physical switch hashing.',
        '`show mac address-table address <mac>`, the vSwitch/port-group VLAN, '
            'and a test VM on the same port group. Compare the VM\'s effective '
            'VLAN with the switchport.',
        'move the VM back to the previous port group first; do not change the '
            'physical switch to compensate for a virtual one.',
      ),
    ),
    _ChangeRule(
      RegExp(r'\bpower\b|\bups\b|\bbattery\b|\bgenerator\b'),
      const _Change(
        'power',
        'The power event',
        'a power event reboots devices and can leave an unsaved config, a '
            'changed STP root, a different FHRP active, or a clock that reset.',
        '`show version | include uptime`, `show running-config` vs `show '
            'startup-config`, `show spanning-tree root`, FHRP state, and NTP '
            'status.',
        'restore the saved config and election priorities; fix the UPS/power '
            'path before the next event.',
      ),
    ),
  ];

  // --- correlated pairs ----------------------------------------------------

  static const Map<String, String> _sharedCause = {
    'dhcp-client-no-ip|vlan-trunk':
        'One missing allowed VLAN explains both: the client\'s DHCP request '
        'never crosses the trunk and the segment looks dead. Fix the trunk '
        'list and re-test the client before opening a DHCP ticket.',
    'dhcp-client-no-ip|wifi-join':
        'This is one join problem, not two: the client associates and '
        'authenticates, then the WLAN maps to a VLAN with no DHCP path, so '
        'the address never arrives. Check the SSID-to-VLAN mapping and the '
        'relay before the wireless.',
    'bgp-flap|interface-flap':
        'BGP is resetting because the link under it is resetting; the BGP '
        'timer is a symptom. Fix the physical layer and leave the BGP '
        'timers alone.',
    'interface-flap|packet-loss':
        'The loss is the flapping link: every transition drops traffic while '
        'the interface re-converges. Prove the physical cause first.',
    'mac-flap|stp-root-flap':
        'A loop or a new bridge is moving the root and the MAC table at the '
        'same time. Suspect a loop or a switch with a better priority, and '
        'read the topology-change source before changing either.',
    'bgp-flap|ipsec-flap':
        'The overlay is tearing BGP down: an IPsec SA lifetime/DPD mismatch or '
        'a tunnel MTU problem resets the session. Check phase 2 and the '
        'tunnel MTU first.',
    'slow-network|voice-quality':
        'One congested queue explains both: the general slowness and the voice '
        'complaint are the same WAN/uplink saturation. Measure utilisation '
        'and QoS drops before touching either.',
    'dhcp-client-no-ip|dns-failing':
        'Both depend on the same gateway or uplink. If the client got a lease '
        'but no resolver, the DHCP option is wrong; if it got neither, the '
        'shared path is down.',
    'dns-failing|https-selective':
        'A DNS answer is steering HTTPS: split-horizon, a stale record or a '
        'policy resolver returns the wrong address for selected names. '
        'Compare the answer from two resolvers.',
    'bgp-not-establishing|ospf-adjacency':
        'Both protocols ride the same path, so check MTU and the ACL before '
        'either protocol: a DBD or OPEN that is dropped by size looks like '
        'two unrelated adjacency failures.',
    'interface-flap|ospf-adjacency':
        'OSPF resets every time the link does. The adjacency is the messenger; '
        'the link is the fault.',
    'dhcp-relay|vlan-trunk':
        'The relay cannot help a VLAN that never reaches it. Fix the trunk and '
        'the relay is likely fine.',
  };

  // --- blast radius and families -------------------------------------------

  static const Set<String> _wideBlast = {
    'total-outage',
    'internet-fails-lan-works',
    'default-route',
    'route-missing',
    'dns-failing',
    'dhcp-relay',
    'dhcp-client-no-ip',
    'asymmetric-routing',
    'firewall-ha-failover',
    'high-cpu',
    'tcam-exhaustion',
    'layer2-loop',
    'bgp-not-establishing',
    'bgp-idle',
    'ospf-adjacency',
  };

  static const Set<String> _narrowBlast = {
    'printer-offline',
    'single-host-latency',
    'single-stream-slow',
    'device-wont-boot',
    'amber-link',
    'poe-failing',
  };

  static const Map<String, String> _familyOverrides = {
    'interface-flap': 'physical',
    'interface-errors': 'physical',
    'duplex-mismatch': 'physical',
    'amber-link': 'physical',
    'incompatible-optic': 'physical',
    'poe-failing': 'physical',
    'poe-budget-overrun': 'physical',
    'microwave-interference': 'physical',
    'device-wont-boot': 'physical',
    'stack-member': 'physical',
    'stp-root-flap': 'l2',
    'stp-wrong-blocking': 'l2',
    'vlan-trunk': 'l2',
    'vlan-not-propagating': 'l2',
    'vlan-isolation-broken': 'l2',
    'mac-flap': 'l2',
    'layer2-loop': 'l2',
    'port-security': 'l2',
    'bpduguard-errdisable': 'l2',
    'trunk-native-mismatch': 'l2',
    'dai-failing': 'l2',
    'lacp-bundle': 'lacp',
    'lacp-hash-imbalance': 'lacp',
    'port-channel-imbalance': 'lacp',
    'ap-capwap-join': 'wireless',
    'ap-reboot': 'wireless',
    'gre-tunnel-drop': 'tunnel',
    'ipsec-flap': 'tunnel',
    'ipsec-phase1': 'tunnel',
    'ipsec-phase2': 'tunnel',
    'dmvpn-nhrp': 'tunnel',
    'sdwan-tunnel': 'tunnel',
    'k8s-dns-failing': 'dns',
  };

  // --- scenario answer text ------------------------------------------------

  static const String _connectedNoInternetAnswer =
      '"Connected but no internet" has five checkpoints, and the first one '
      'that fails is the answer - do not restart the access point before step '
      '1.\n\n'
      '1. Address - `ipconfig /all`. 169.254.x.x or no address: DHCP never '
      'answered, so the fault is the access VLAN, relay, scope or snooping. A '
      'real address: go to step 2.\n'
      '2. Gateway - ping the default gateway. Fails: the local VLAN, port or '
      'ACL, or the gateway itself. Works: go to step 3.\n'
      '3. Routing and DNS - ping 8.8.8.8, then `nslookup example.com`. The IP '
      'works and the name fails: DNS. Both fail: routing, NAT or the firewall.\n'
      '4. TCP - `Test-NetConnection example.com -Port 443`. Ping works and '
      '443 fails: an ACL, firewall, proxy or security group, not the link.\n'
      '5. Portal or policy - an HTTP request that redirects to a login page is '
      'a captive portal or content policy, not a broken link. A certificate '
      'warning is a certificate problem, not a reachability one.\n\n'
      '"Connected" only proves the radio or the cable. The address is the '
      'first fact worth having, and each checkpoint above removes a whole '
      'layer from the search.';

  static const String _pingButServiceAnswer =
      'Ping proves the path, not the service. The device is reachable at layer '
      '3, so stop checking cabling and routing and walk the service path:\n\n'
      '1. Port/listener - is the service listening on the expected TCP/UDP '
      'port? `nc -vz <ip> <port>` or `Test-NetConnection <ip> -Port <port>`. A '
      'refusal is the service or a rejecting rule; a timeout is a filter or '
      'the wrong port.\n'
      '2. Path/MTU - test a large packet (`ping -M do -s 1472`, Windows `ping '
      '-f -l 1472`). A stream that starts and stalls on large frames is MTU '
      'or MSS, not the camera.\n'
      '3. Application - stream URL/codec, NVR channel, TLS certificate/SNI, '
      'proxy. The device can ping while RTSP/HTTPS is blocked or the NVR is '
      'reading the wrong stream.\n'
      '4. Policy - ACL/firewall between the client and the service, and the '
      'return path. Test from the same subnet as the client to separate policy '
      'from routing.\n'
      '5. Resource - the service process, connection limit, disk or licence. '
      'A healthy ping says nothing about any of them.\n\n'
      'Do not reboot the device because ping works: it already proved the part '
      'you were about to test.';

  static const String _guestPortalAnswer =
      'A guest portal that never loads is usually DNS or the walled garden, '
      'not the Wi-Fi:\n\n'
      '1. DNS - the client must resolve the portal name before it is '
      'authorised. Query it from the guest VLAN; if it fails, fix the guest '
      'DNS/forwarder.\n'
      '2. Walled garden - the controller must allow the portal host and its '
      'redirect before login, over 80 and 443. A CDN-hosted portal needs every '
      'resolved address, not one.\n'
      '3. Redirect/HTTPS - an HTTPS-only portal needs a certificate the client '
      'trusts, and the initial HTTP redirect must not be blocked. Check the '
      'portal URL and certificate on the controller.\n'
      '4. Policy order - the pre-auth ACL must permit DHCP, DNS and the '
      'portal, then redirect everything else. A deny-all before the portal '
      'rule produces a blank page.\n'
      '5. Client - captive-portal detection, private DNS/DoH and a proxy can '
      'bypass the redirect; test with a clean client before changing the '
      'controller.\n\n'
      'The guest Wi-Fi association is already proven if the client got an '
      'address. The portal is a name, a policy and a certificate, in that '
      'order.';

  static const String _oneVlanAnswer =
      'A resource that works from one VLAN and not another puts the fault on '
      'the inter-VLAN path, not on the device or the user:\n\n'
      '1. Gateways/masks - the client in the failing VLAN needs the right mask '
      'and default gateway, and the server/printer needs a return route. A '
      'missing return route looks exactly like an ACL.\n'
      '2. SVI/routing - is the failing VLAN\'s SVI up/up, and does `show ip '
      'route` have both connected subnets? A VLAN allowed on the trunk but '
      'not created on the core is a common half-built path.\n'
      '3. Policy - the ACL/firewall zone pair between the two VLANs, in both '
      'directions. Check hit counters and logs, not just the config.\n'
      '4. NAT - if either side is NATed, the return path may not match the '
      'forward flow.\n'
      '5. Discovery - mDNS/NetBIOS does not cross VLANs without a reflector. '
      'Print or connect by IP to separate discovery from reachability.\n\n'
      'Prove the return route first, then the policy. Discovery protocols are '
      'not a reachability test.';

  static const String _linkUpNoTrafficAnswer =
      'Link up only proves carrier and negotiation. No traffic is a forwarding '
      'or policy question:\n\n'
      '1. Layer 2 - is the port in the right VLAN, allowed on the trunk, and '
      'forwarding in STP? `show interface switchport`, `show spanning-tree '
      'interface`, `show mac address-table`.\n'
      '2. ARP/L3 - does the device learn the peer\'s MAC and ARP? `show ip arp`, '
      '`show ip interface brief`. No ARP means VLAN/STP; ARP but no ping means '
      'ACL or route.\n'
      '3. Counters - `show interface` output/input rates and queue drops. Zero '
      'output means the switch is not forwarding, not that the link is dead.\n'
      '4. Policy - ACL/firewall/NAT on the path, and the return route. Test '
      'both directions, not just one.\n'
      '5. Asymmetry - a stateful firewall drops the return flow. Capture at '
      'both ends at the same time and compare source/destination.\n\n'
      'A link that is up with no traffic is never a cable fault. Find the '
      'first layer that stops forwarding.';

  static const String _triageOrderAnswer =
      'Without a symptom, "check first" has one honest order: find the scope, '
      'then the layer, then the time. It removes the most uncertainty per '
      'minute.\n\n'
      '1. Scope - compare a working device with a broken one on the same '
      'switch and VLAN. That decides edge versus shared infrastructure before '
      'you run a single command.\n'
      '2. Layer - ping the gateway, ping a public IP, `nslookup`, then test the '
      'TCP port. The first failure names the layer; everything above it is '
      'already proven good.\n'
      '3. Time - constant, intermittent, or since a change. Constant is a '
      'broken dependency; intermittent is a timer, RF or a physical link; after '
      'a change is that change until a rollback clears it.\n\n'
      'If the question is "switch or firewall": a switch fails at layer 2 '
      '(VLAN, trunk, STP, port, MAC), and a firewall fails at layer 3/4 policy '
      'or state (ACL, NAT, asymmetric return). Ping and TCP split them: ping '
      'fails with an incomplete ARP entry points at layer 2; ping works and '
      'TCP fails points at policy. Start at the layer the test already failed '
      'at, not at the device you suspect.';

  static const String _pingButNoBrowseAnswer =
      'Ping proves the path, so the fault is above it. Four checks, in order:\n\n'
      '1. Name - `nslookup example.com` from the client. If it fails, DNS is '
      'the fault; if it returns the wrong address, check split-horizon and the '
      'search suffix.\n'
      '2. Port - `Test-NetConnection example.com -Port 443` (or `nc -vz`). A '
      'refusal means the host is reachable and nothing is listening or a rule '
      'is rejecting; a timeout means a device is dropping the SYN.\n'
      '3. Proxy/TLS - check the PAC file and the browser proxy settings, then '
      'the certificate: an expired certificate, a missing intermediate or an '
      'SNI mismatch fails HTTPS while ping and DNS stay clean.\n'
      '4. MTU - if the page starts loading and stalls at the same point, a '
      'large response is being dropped. `ping -M do -s 1472 <dst>` and lower '
      'the size until it passes.\n\n'
      'A ping that works and a browser that fails is never a cable fault. Test '
      'by IP with the same Host header before you change any network config.';

  // --- syslog facts --------------------------------------------------------

  static const Map<String, _SyslogFact> _syslogFacts = {
    'SW_MATM-4-MACFLAP_NOTIF': _SyslogFact(
      'the switch learned the same MAC on two different ports in the same '
          'VLAN within the flap timer. Either a loop exists, the same MAC is '
          'really in two places (a cloned VM or a NIC-teaming driver), or a '
          'port-channel is not bundling and the switch sees one host on two '
          'links.',
      [
        '`show mac address-table address <mac>` - the ports and VLAN where it '
            'was learned, and how recently.',
        '`show spanning-tree vlan <id>` - topology changes and a port that '
            'keeps moving between roles.',
        '`show interfaces | include broadcasts|multicast|drops` - a broadcast '
            'rate near line rate is the signature of a loop.',
      ],
      'Treat it as a loop until spanning tree and the broadcast rate prove '
          'otherwise. A static MAC entry hides the symptom and lets a storm '
          'keep growing.',
    ),
    'PM-4-ERR_DISABLE': _SyslogFact(
      'a protection feature disabled the port - BPDU Guard, port security, '
          'link-flap detection, UDLD, DHCP snooping or storm control. The '
          'message names the reason, and the port stays down until it is '
          'recovered.',
      [
        '`show interfaces status err-disabled` - every disabled port and the '
            'reason in one line.',
        '`show errdisable recovery` - which causes auto-recover, and the '
            'timer.',
        '`show log | include ERR_DISABLE` - the cause and the exact time.',
      ],
      'Fix the cause before clearing the error. A shutdown/no shutdown without '
          'a fix simply repeats the disable.',
    ),
    'SPANTREE-2-BLOCK_BPDUGUARD': _SyslogFact(
      'a BPDU arrived on a port with BPDU Guard enabled. An access port should '
          'never receive one, so a switch, a virtual switch or a misconnected '
          'cable is on the other end.',
      [
        '`show interfaces status err-disabled` - which port and which guard.',
        '`show spanning-tree interface <intf>` - the port state before it was '
            'disabled.',
        'Trace the cable to the device that is sending BPDUs - that device is '
            'the fault, not the guard.',
      ],
      'Do not disable BPDU Guard to make the message stop; find the bridge that '
          'is sending BPDUs into an access port.',
    ),
    'SPANTREE-2-ROOTGUARD_BLOCK': _SyslogFact(
      'a superior BPDU arrived on a root-guard port, so the port went '
          'root-inconsistent. Another switch is trying to become root through a '
          'port that must not lead there.',
      [
        '`show spanning-tree inconsistentports` - the port and VLAN.',
        '`show spanning-tree vlan <id>` - the current root and the port role.',
        'The neighbouring switch\'s bridge priority - a new switch with the '
            'default priority is the usual source.',
      ],
      'Root guard is doing its job. Fix the other switch\'s priority or the '
          'cabling, not the guard.',
    ),
    'SPANTREE-2-LOOPGUARD_BLOCK': _SyslogFact(
      'a non-designated port stopped receiving BPDUs, so Loop Guard blocked it '
          'instead of letting it become designated and create a loop. Usually a '
          'unidirectional link or a stalled bridge.',
      [
        '`show spanning-tree inconsistentports` - the port that was blocked.',
        '`show interfaces <intf>` - drops, duplex and any one-way symptom.',
        '`show log` for the last BPDU received on that port.',
      ],
      'Check the physical link and the far-end bridge. Do not disable Loop '
          'Guard on a redundant topology.',
    ),
    'PORT_SECURITY-2-PSECURE_VIOLATION': _SyslogFact(
      'a frame with a MAC that is not allowed on the port arrived. Depending on '
          'the violation mode the port dropped the frame, dropped and logged, '
          'or shut down.',
      [
        '`show port-security interface <intf>` - violation mode, maximum and '
            'the last offending MAC.',
        '`show port-security address` - the allowed bindings.',
        '`show mac address-table interface <intf>` - what is actually on the '
            'port now.',
      ],
      'A violation is usually a replaced device, a dock or a VM with a random '
          'MAC. Update the binding deliberately; do not disable port security '
          'to silence it.',
    ),
    'LINEPROTO-5-UPDOWN': _SyslogFact(
      'the line protocol changed state. One transition is normal; a repeated '
          'pair means carrier is being lost, so treat it as a physical or link '
          'fault, not a routing one.',
      [
        '`show interfaces <intf> | include up|down|reset|CRC` - the transition '
            'count and the errors that came with it.',
        '`show log | include LINEPROTO` - the interval between transitions.',
        '`show interfaces transceiver detail` - Rx power against the optic '
            'specification when the port is optical.',
      ],
      'Count the transitions over an hour. More than a couple is a '
          'cable/optic/port investigation.',
    ),
    'LINK-3-UPDOWN': _SyslogFact(
      'the link protocol changed state - carrier was lost or restored. The '
          'interface name and the new state are in the message.',
      [
        '`show interfaces <intf> | include up|down|reset` - the full counter '
            'history.',
        '`show log | include <intf>` - the reason for each transition.',
        'The far end\'s log at the same timestamps - only one side may be '
            'flapping.',
      ],
      'A link that only drops under load is usually power, PoE or a bad optic, '
          'not a routing problem.',
    ),
    'OSPF-5-ADJCHG': _SyslogFact(
      'an OSPF neighbour changed state, and the message names the reason - '
          'Dead timer expired, Interface down, MTU mismatch, sequence mismatch. '
          'That reason is the diagnosis; the state change is only the alarm.',
      [
        '`show ip ospf neighbor` - state, uptime and dead time per neighbour.',
        '`show log | include OSPF` - the from/to states and the reason in the '
            'message.',
        '`show ip ospf interface <intf>` - area, timers, network type and MTU '
            'on both sides.',
      ],
      'Read the reason before changing timers. Most adjacency resets are '
          'physical, MTU or area mismatch, not a timer.',
    ),
    'BGP-5-ADJCHANGE': _SyslogFact(
      'a BGP neighbour went up or down. The message does not name the cause; '
          'the reset reason in `show ip bgp neighbors` does.',
      [
        '`show ip bgp summary` - state and Up/Down time for every peer.',
        '`show ip bgp neighbors <peer> | include reset|hold|last` - the last '
            'reset reason.',
        '`show log | include BGP` - the sequence of state changes.',
      ],
      'Established-then-down is transport, MTU or CPU. Never-established is '
          'TCP 179 or routing. Do not change policy for either.',
    ),
    'BGP-3-NOTIFICATION': _SyslogFact(
      'a BGP NOTIFICATION was sent or received. The error code and subcode name '
          'the reason, such as hold-timer expiry, bad peer AS, or max-prefix.',
      [
        '`show ip bgp neighbors <peer>` - the notification code, subcode and '
            'the last reset reason.',
        '`show ip bgp summary` - whether the peer is Established or cycling.',
        '`show ip bgp neighbors <peer> received-routes` - whether a policy is '
            'rejecting the prefix.',
      ],
      'Max-prefix and hold-timer are different fixes. Read the code before '
          'touching either.',
    ),
    'DUAL-5-NBRCHANGE': _SyslogFact(
      'an EIGRP neighbour changed state. The reason is in the message, and the '
          'neighbour table shows whether it recovered.',
      [
        '`show ip eigrp neighbors` - state, uptime and the interface.',
        '`show ip eigrp topology active` - whether a query is still '
            'outstanding (SIA).',
        '`show log | include DUAL` - the from/to states and reason.',
      ],
      'A neighbour that drops under load is usually a queue/CPU or K-value '
          'mismatch, not a routing loop.',
    ),
    'CDP-4-DUPLEX_MISMATCH': _SyslogFact(
      'one end of the link is half duplex and the other is full. The link still '
          'passes traffic, badly, with late collisions and retransmissions.',
      [
        '`show interfaces <intf> | include duplex|speed|late collision` on both '
            'ends.',
        '`show cdp neighbors detail` - what the far end reports.',
        'A throughput test on the link - a duplex mismatch looks like loss and '
            'latency, not a down port.',
      ],
      'Set both ends to auto or both to the same fixed speed/duplex. Never fix '
          'a mismatch on one side only.',
    ),
    'DHCPD-4-PING_CONFLICT': _SyslogFact(
      'the DHCP server checked an address with ICMP before offering it and got '
          'an answer, so it marked the address conflicted and did not lease it. '
          'A static host or a second DHCP server is using the range.',
      [
        '`show ip dhcp conflict` - every address the server is holding back.',
        '`show ip dhcp pool` - the range, exclusions and utilisation.',
        '`show ip arp <ip>` and the MAC table - find the device that answers.',
      ],
      'Clear the conflict only after the static address is moved or documented; '
          'otherwise it returns on the next check.',
    ),
    'IP-4-DUPADDR': _SyslogFact(
      'the router saw its own address used by another MAC (a gratuitous ARP), '
          'so two devices claim the same IP.',
      [
        '`show ip arp <ip>` - the MAC that currently answers.',
        '`show mac address-table address <mac>` - the port and VLAN.',
        'The switch port owner and the DHCP lease for that address.',
      ],
      'Fix the duplicate at the source. An ARP ACL or a static entry treats the '
          'symptom, not the cause.',
    ),
    'FIB-4-TCAM_THRESHOLD': _SyslogFact(
      'the forwarding table (TCAM) crossed its threshold, so new routes may not '
          'be installable even though the routing protocol still has them.',
      [
        '`show platform tcam utilization` - the current and maximum entries per '
            'table.',
        '`show ip route summary` and `show ip cef summary` - whether the RIB and '
            'FIB agree.',
        'The prefix count per peer and per VRF - one leak can fill the table.',
      ],
      'Summarise and filter before adding hardware. A full TCAM shows as routes '
          'present in BGP but missing from CEF.',
    ),
    'ILPOWER-3-CONTROLLER_PORT_ERR': _SyslogFact(
      'the PoE controller reported a port error, often a power-budget overrun, '
          'a failed PD detection, or a port drawing above its class.',
      [
        '`show power inline` - allocated and remaining budget, and the port '
            'state.',
        '`show power inline <intf> detail` - class, draw and any error.',
        '`show log | include ILPOWER` - whether the port is cycling.',
      ],
      'Check the total budget and the cable before replacing the AP. A long, '
          'thin run makes a PD reset and look like a PoE fault.',
    ),
    'CRYPTO-4-RECVD_PKT_INV_SPI': _SyslogFact(
      'an IPsec packet arrived with an SPI that matches no local SA. Usually the '
          'SAs are out of step, one side expired or rekeyed, or the peer is '
          'sending traffic for a tunnel that is down.',
      [
        '`show crypto ipsec sa` - inbound/outbound SAs, SPI and lifetimes on '
            'both peers.',
        '`show crypto isakmp sa` - whether phase 1 is still up.',
        'The selectors (interesting traffic ACLs) on both sides.',
      ],
      'If SAs exist on one side and not the other, fix the proposal/lifetime '
          'mismatch. Clearing SAs is a test, not a fix.',
    ),
    'CRYPTO-4-IKMP_NO_SA': _SyslogFact(
      'there is no IKE SA for a packet that needs one, so phase 1 is not up or '
          'the peer is not answering.',
      [
        '`show crypto isakmp sa` - the state of every peer.',
        '`show crypto ipsec sa` - whether any phase 2 exists.',
        'UDP 500/4500 reachability in both directions, and the proposal/PSK.',
      ],
      'A phase-1 mismatch fails before any interesting traffic. Confirm the '
          'proposal, PSK and peer address both ways.',
    ),
    'SYS-5-CONFIG_I': _SyslogFact(
      'someone changed the configuration - from the console, SSH or SNMP. This '
          'is the audit trail for "what changed", and the timestamp is the first '
          'thing to compare with the fault.',
      [
        '`show archive config differences` - the diff against the last saved '
            'config.',
        '`show users` and the AAA/TACACS logs - who made the change and from '
            'where.',
        'The change ticket or backup timestamps around the same minute.',
      ],
      'A config change is the prime suspect even when it looks unrelated. Diff '
          'before you debug.',
    ),
    'SYS-5-RELOAD': _SyslogFact(
      'the device reloaded. The reason - power, crash, reload command or '
          'watchdog - is in `show version`, `show reload` or the crashinfo.',
      [
        '`show version | include uptime|restarted` - the current boot time.',
        '`show reload` and `dir crashinfo:` - whether this was planned or a '
            'crash.',
        'The PSU, UPS and environmental log at the same time.',
      ],
      'A reload that repeats is a power or crash investigation, not a routing '
          'one. Check the PSU and crashinfo before replacing the box.',
    ),
    'ASA-4-106023': _SyslogFact(
      'the ASA denied a packet because no ACL rule permitted it. The line names '
          'the source, destination, port and access group.',
      [
        '`show access-list <name>` - the rule order and hit counters.',
        '`packet-tracer input <if> <proto> <src> <sport> <dst> <dport> detailed` '
            '- the exact rule the flow hits.',
        'The NAT rule for the same flow - a translation can change the address '
            'the ACL evaluates.',
      ],
      'Fix the rule that should permit the flow, not the default deny. Adding a '
          'permit above a deny is how a policy rots.',
    ),
    'ASA-4-106015': _SyslogFact(
      'the ASA denied a TCP packet that was not part of an existing connection '
          'and no rule allowed it.',
      [
        '`show conn` - whether the flow is stateful and in which direction.',
        '`packet-tracer` for the same five-tuple - the exact deny.',
        'The return route - an asymmetric path looks exactly like a deny.',
      ],
      'If the flow should be stateful, check that the return path is symmetric '
          'before adding a rule.',
    ),
    'ASA-4-313001': _SyslogFact(
      'the ASA denied an ICMP packet by policy.',
      [
        '`show access-list` - the ICMP rule and its hit count.',
        '`packet-tracer` with protocol icmp - the exact line.',
        'The ICMP inspection policy if the flow should be stateful.',
      ],
      'ICMP is often blocked deliberately. Do not open it just to make ping '
          'work unless monitoring needs it.',
    ),
    'ASA-4-419002': _SyslogFact(
      'the ASA saw a duplicate TCP SYN for an existing connection - a '
          'retransmission, a spoofed packet, or routing asymmetry.',
      [
        '`show conn address <ip>` - the existing connection and its state.',
        'A capture on both interfaces - whether the SYN arrives twice or only '
            'once.',
        'The return route on the inside - a second path makes the ASA see the '
            'same SYN twice.',
      ],
      'Duplicate SYN at scale is usually asymmetric routing or a load '
          'balancer. Fix the path, not the timeout.',
    ),
    'ASA-4-106100': _SyslogFact(
      'an ACL rule matched a flow and the ASA logged the hit. Unlike 106023 '
          'this is a rule with logging enabled, so the hit counter is the useful '
          'part.',
      [
        '`show access-list <name>` - the hit count that this message increments.',
        '`show conn` for the same flow - whether the connection was built.',
        'The rule order above the match - a more specific deny may be shadowing '
            'it.',
      ],
      'Logging is a sample, not a flow count. Use the hit counter to decide '
          'whether the rule is doing what you meant.',
    ),
  };
}

class _Scope {
  final String id;
  final String heading;
  final List<String> narrows;
  final String test;

  const _Scope(this.id, this.heading, this.narrows, this.test);
}

class _ScopeRule {
  final String id;
  final RegExp pattern;
  final String heading;
  final List<String> narrows;
  final String test;

  const _ScopeRule(
    this.id,
    this.pattern,
    this.heading,
    this.narrows,
    this.test,
  );
}

class _Change {
  final String id;
  final String label;
  final String why;
  final String check;
  final String rollback;

  const _Change(this.id, this.label, this.why, this.check, this.rollback);
}

class _ChangeRule {
  final RegExp pattern;
  final _Change change;

  const _ChangeRule(this.pattern, this.change);
}

class _SyslogFact {
  final String meaning;
  final List<String> checks;
  final String rule;

  const _SyslogFact(this.meaning, this.checks, this.rule);
}
