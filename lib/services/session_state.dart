import 'dart:convert';

import '../models/chat_message.dart';
import '../models/network_intent.dart';

/// Layer 2 of the memory: what this conversation is ABOUT, kept as data.
///
/// The point is that conversational continuity must not depend on the model
/// remembering anything. "What about its gateway?" needs the app to know that
/// "its" is PC1 right now - and the app can know that exactly, because it saw
/// the user write PC1. So that fact is stored as structure, re-injected in a
/// compact form, and the model only has to read it.
///
/// Every field here is DERIVED FROM REAL DATA:
///
///  * device focus / source / destination - from the user's own words and the
///    plan that was actually compiled from them;
///  * findings - from the validator and the tool results the app really ran;
///  * changes - from the structured change log in SQLite, never from prose.
///
/// Nothing is ever set because a model said so, which is what keeps the
/// assistant from "remembering" something that never happened.
class SessionState {
  /// The network/project being discussed (`office-network.pkt`).
  String project;

  /// Devices in the current focus, most recent first.
  List<String> focus;

  /// The endpoints of the current question, when it named them.
  String? source;
  String? destination;

  /// The problem being worked on, in the user's words (bounded).
  String problem;

  /// Findings the app itself established (validator output, tool results).
  List<String> confirmedFindings;

  /// Things the app saw but has not proven.
  List<String> openFindings;

  /// Changes the app actually made, newest last: {device, interface, field,
  /// oldValue, newValue, actionId}.
  List<Map<String, dynamic>> changesMade;

  /// Changes proposed and not yet applied.
  List<Map<String, dynamic>> proposedChanges;

  /// The subject of the conversation, one short phrase.
  String topic;

  /// The id of the last message folded into this state, so a reopen does not
  /// re-observe the whole transcript.
  int lastMessageId;

  /// The .pkt this conversation actually produced, and the file it landed in.
  ///
  /// This is what makes "edit it" mean something: the app knows which file the
  /// user is talking about, instead of building a second one and leaving the
  /// first behind.
  String artifactPath;
  String artifactName;
  String artifactUpdatedAt;

  /// Every .pkt this conversation produced, most recent first. Each entry:
  /// path, name, written-at, and the build's own verification note
  /// ("build verified against the file" / "verification found differences").
  /// The single [artifactPath] above stays the latest pointer for older
  /// readers; old conversations decode with an empty list and still work.
  List<Map<String, String>> artifacts;

  /// The standing plan, as redacted JSON. A reopened conversation inherits the
  /// plan it was about, so "add two PCs to it" edits the same lab rather than
  /// starting a new one.
  String intentJson;

  SessionState({
    this.project = '',
    List<String>? focus,
    this.source,
    this.destination,
    this.problem = '',
    List<String>? confirmedFindings,
    List<String>? openFindings,
    List<Map<String, dynamic>>? changesMade,
    List<Map<String, dynamic>>? proposedChanges,
    this.topic = '',
    this.lastMessageId = 0,
    this.artifactPath = '',
    this.artifactName = '',
    this.artifactUpdatedAt = '',
    List<Map<String, String>>? artifacts,
    this.intentJson = '',
  })  : focus = focus ?? <String>[],
        confirmedFindings = confirmedFindings ?? <String>[],
        openFindings = openFindings ?? <String>[],
        changesMade = changesMade ?? <Map<String, dynamic>>[],
        proposedChanges = proposedChanges ?? <Map<String, dynamic>>[],
        artifacts = artifacts ?? <Map<String, String>>[];

  static const int maxFocus = 6;
  static const int maxFindings = 8;
  static const int maxChanges = 6;
  static const int maxProblemChars = 200;

  bool get isEmpty =>
      project.isEmpty &&
      focus.isEmpty &&
      problem.isEmpty &&
      confirmedFindings.isEmpty &&
      changesMade.isEmpty &&
      !hasArtifact;

  // --- observation ---------------------------------------------------------

  /// Fold one turn into the state. Deterministic, cheap, and safe to call on
  /// every turn and on every reopen.
  SessionState observe(ChatMessage message) {
    lastMessageId = message.id ?? lastMessageId;
    if (message.isError || message.text.trim().isEmpty) return this;
    final text = message.text;

    if (message.isUser) {
      // A "what about PC3?" style follow-up replaces the focus but keeps the
      // rest of the question intact - that is the whole trick behind
      // "What about PC3?" meaning "can PC3 reach Server0 too?".
      final devices = devicesIn(text);
      if (devices.isNotEmpty) {
        _pushFocus(devices);
        final pair = _endpointPair(text, devices);
        if (pair != null) {
          source = pair.$1;
          destination = pair.$2;
        } else if (_isFollowUp(text) && devices.length == 1) {
          // Keep the previous destination; the new device becomes the subject.
          source = devices.first;
        }
      }
      final problem = _problemSentence(text);
      if (problem.isNotEmpty) {
        // A new problem statement replaces the standing one when it names its
        // own device ("PC4 cannot reach the server" is a new question); an
        // anonymous "it still doesn't work" continues the old one rather than
        // erasing what the conversation was about.
        if (this.problem.isEmpty || devices.isNotEmpty) {
          this.problem = problem;
        } else if (problem != this.problem) {
          addFinding(problem, confirmed: false);
        }
      }
      if (topic.isEmpty && devices.isEmpty && text.trim().length <= 60) {
        topic = text.trim();
      }
    } else {
      // The assistant's own turns only contribute device names it referred to
      // (so a follow-up like "check those" has something to attach to). No
      // claim from a model turn ever becomes a finding.
      final devices = devicesIn(text);
      if (devices.isNotEmpty && focus.isEmpty) _pushFocus(devices);
    }
    return this;
  }

  /// The devices the plan actually contains become the focus when the user has
  /// not named any yet - real data, not an inference.
  SessionState withIntent(NetworkIntent? intent) {
    if (intent == null) return this;
    if (intent.projectName.trim().isNotEmpty &&
        intent.projectName.trim() != 'chat' &&
        intent.projectName.trim() != 'default') {
      project = intent.projectName.trim();
    }
    if (focus.isEmpty) {
      _pushFocus(
        intent.nodes
            .where((n) => n.type == 'router' || n.type == 'switch')
            .map((n) => n.name)
            .take(maxFocus)
            .toList(),
      );
    }
    if (project.isNotEmpty && topic.isEmpty) {
      topic = '${intent.nodes.length}-device plan (${intent.routing})';
    }
    return this;
  }

  /// Findings the engine established. Called with validator issues and with
  /// tool results - never with model prose.
  SessionState addFinding(String finding, {bool confirmed = true}) {
    final text = finding.trim();
    if (text.isEmpty) return this;
    final list = confirmed ? confirmedFindings : openFindings;
    if (list.contains(text)) return this;
    list.add(text);
    while (list.length > maxFindings) {
      list.removeAt(0);
    }
    return this;
  }

  SessionState clearFindings() {
    confirmedFindings.clear();
    openFindings.clear();
    return this;
  }

  /// The structured change log, straight from SQLite (newest first in the
  /// database; stored oldest-last here).
  SessionState withChanges(List<Map<String, dynamic>> changes) {
    changesMade = changes
        .where((c) => (c['undoneAt'] ?? '').toString().isEmpty)
        .take(maxChanges)
        .toList()
        .reversed
        .toList();
    return this;
  }

  SessionState withProposed(List<Map<String, dynamic>> proposed) {
    proposedChanges = proposed.take(maxChanges).toList();
    return this;
  }

  /// Reset everything that belonged to one network, keeping the project.
  ///
  /// Called when the user switches the network in the middle of a chat: the
  /// old devices and findings are about a different .pkt, and letting them
  /// leak into the new one is how a chat answers about the wrong topology.
  SessionState forNewProject(String project) => SessionState(
        project: project,
        topic: topic,
        lastMessageId: lastMessageId,
      );

  /// Record the file a build landed in. Called by the app, never by a model.
  ///
  /// Also upserts into [artifacts] so a conversation that produced several
  /// files can tell them apart later - each keeps its own name, write time
  /// and verification note.
  SessionState withArtifact(
    String path, {
    String? name,
    String? updatedAt,
    String? note,
  }) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return this;
    artifactPath = trimmed;
    artifactName = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : trimmed.split(RegExp(r'[/\\]')).last;
    artifactUpdatedAt = updatedAt?.trim() ?? artifactUpdatedAt;
    final existing = artifacts.firstWhere(
      (a) => a['path'] == trimmed,
      orElse: () => const <String, String>{},
    );
    final entry = <String, String>{
      'path': trimmed,
      'name': artifactName,
      'at': artifactUpdatedAt,
      'note': note?.trim() ?? (existing['note'] ?? ''),
    };
    artifacts = [
      entry,
      ...artifacts.where((a) => a['path'] != trimmed),
    ];
    if (artifacts.length > 12) {
      artifacts = artifacts.sublist(0, 12);
    }
    return this;
  }

  /// The files this conversation produced, newest first, with the newest
  /// pointer folded in for conversations saved before the list existed.
  List<({String path, String name, String at, String note})>
      get knownArtifacts {
    final list = <({String path, String name, String at, String note})>[
      for (final a in artifacts)
        if ((a['path'] ?? '').trim().isNotEmpty)
          (
            path: a['path']!.trim(),
            name: (a['name'] ?? '').trim(),
            at: (a['at'] ?? '').trim(),
            note: (a['note'] ?? '').trim(),
          ),
    ];
    if (list.isEmpty && hasArtifact) {
      list.add((
        path: artifactPath,
        name: artifactName,
        at: artifactUpdatedAt,
        note: '',
      ));
    }
    return list;
  }

  SessionState withIntentJson(String json) {
    intentJson = json;
    return this;
  }

  /// One compact line naming what the previous turns were about, for the
  /// message the user just sent.
  String get subjectLine {
    final parts = <String>[];
    if (focus.isNotEmpty) parts.add('devices in focus: ${focus.join(', ')}');
    if (source != null && destination != null) {
      parts.add('$source -> $destination');
    }
    if (problem.isNotEmpty) parts.add('problem: $problem');
    return parts.join(' | ');
  }

  /// True when this conversation has a real file to edit rather than only a
  /// plan to build from.
  bool get hasArtifact => artifactPath.trim().isNotEmpty;

  // --- prompt injection ----------------------------------------------------

  /// The block for the model, carrying ONLY what is relevant to [userText].
  ///
  /// Relevance is a keyword test against the current message plus the standing
  /// problem: a question about VLANs does not need the change log, and a
  /// "thanks" does not need the topology. Always included: the project, the
  /// problem, and the LAST change (because "undo that" has no other clue).
  String promptBlock({required String userText}) {
    if (isEmpty) return '';
    final want = userText.toLowerCase();
    final words = want
        .split(RegExp(r'[^a-z0-9./]+'))
        .where((w) => w.length > 2)
        .toSet();

    // "Relevant" means: the message names the device in it, or shares a
    // meaningful word with it. A finding with nothing in common with the
    // question is about a different part of the network and stays out.
    bool mentions(String value) {
      final v = value.toLowerCase();
      if (v.isEmpty) return false;
      if (want.contains(v)) return true;
      for (final device in devicesIn(value)) {
        if (want.contains(device.toLowerCase())) return true;
      }
      final tokens = v
          .split(RegExp(r'[^a-z0-9./-]+'))
          .where((t) => t.length > 3);
      return tokens.any(words.contains);
    }

    final b = StringBuffer()
      ..writeln('## Session state (structured, from this app - not a summary)')
      ..writeln(
        'This is the app\'s own record of the conversation so far. It is '
        'exact. Use it to resolve "it", "that", "those" and "the same"; do '
        'not ask the user to restate it.',
      );
    if (project.isNotEmpty) b.writeln('- Network in this conversation: $project');
    if (problem.isNotEmpty) b.writeln('- Current problem: $problem');
    if (focus.isNotEmpty) {
      b.writeln(
        '- Devices in focus: ${focus.join(', ')}'
        '${source != null ? ' (current subject: $source)' : ''}',
      );
    }
    if (source != null && destination != null) {
      b.writeln('- The current question is about $source -> $destination');
    }
    if (hasArtifact) {
      b.writeln(
        '- File this conversation already produced: $artifactName'
        '${artifactUpdatedAt.isEmpty ? '' : ' (written $artifactUpdatedAt)'}'
        ' at $artifactPath',
      );
      b.writeln(
        '  "it", "the file", "the project" and "the .pkt" mean THAT file. '
        'When the user asks to change it, change this project in place (a '
        'backup copy is kept). Only propose a brand-new file when they ask '
        'for a new one, a copy, or a differently named project.',
      );
    }

    final findings = confirmedFindings.where(mentions).toList();
    if (findings.isNotEmpty) {
      b.writeln('- Findings this app established (facts, not guesses):');
      for (final f in findings) {
        b.writeln('  - $f');
      }
    }
    final open = openFindings.where(mentions).toList();
    if (open.isNotEmpty) {
      b.writeln('- Observed but not proven yet: ${open.join('; ')}');
    }

    if (changesMade.isNotEmpty) {
      // The newest change always rides along: it is what "undo that" means.
      final last = changesMade.last;
      b.writeln('- Last change the app made (exact): ${_changeLine(last)}');
      final relevant = changesMade
          .where((c) => mentions((c['device'] ?? '').toString()))
          .toList();
      for (final c in relevant) {
        if (identical(c, last)) continue;
        b.writeln('  - earlier: ${_changeLine(c)}');
      }
      b.writeln(
        '- The app can undo the last change exactly (it has the old value); '
        'you do not have to remember it.',
      );
    }
    if (proposedChanges.isNotEmpty) {
      b.writeln(
        '- Proposed but NOT applied: '
        '${proposedChanges.map(_changeLine).join('; ')}',
      );
    }
    if (b.toString().trim().split('\n').length <= 2) return '';
    return b.toString().trimRight();
  }

  static String _changeLine(Map<String, dynamic> c) {
    final where = [
      (c['device'] ?? '').toString(),
      if ((c['interface'] ?? '').toString().isNotEmpty)
        (c['interface'] ?? '').toString(),
    ].join(' ');
    final field = (c['field'] ?? '').toString();
    final oldV = (c['oldValue'] ?? '').toString();
    final newV = (c['newValue'] ?? '').toString();
    return '$where $field: "$oldV" -> "$newV"';
  }

  // --- persistence ---------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'project': project,
    'focus': focus,
    'source': source,
    'destination': destination,
    'problem': problem,
    'confirmedFindings': confirmedFindings,
    'openFindings': openFindings,
    'changesMade': changesMade,
    'proposedChanges': proposedChanges,
    'topic': topic,
    'lastMessageId': lastMessageId,
    'artifactPath': artifactPath,
    'artifactName': artifactName,
    'artifactUpdatedAt': artifactUpdatedAt,
    'artifacts': artifacts,
    'intentJson': intentJson,
  };

  String encode() => jsonEncode(toJson());

  factory SessionState.decode(String raw) {
    if (raw.trim().isEmpty || raw.trim() == '{}') return SessionState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return SessionState();
      return SessionState.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return SessionState();
    }
  }

  factory SessionState.fromJson(Map<String, dynamic> j) => SessionState(
    project: (j['project'] ?? '').toString(),
    focus: _strings(j['focus']),
    source: _textOrNull(j['source']),
    destination: _textOrNull(j['destination']),
    problem: (j['problem'] ?? '').toString(),
    confirmedFindings: _strings(j['confirmedFindings']),
    openFindings: _strings(j['openFindings']),
    changesMade: _maps(j['changesMade']),
    proposedChanges: _maps(j['proposedChanges']),
    topic: (j['topic'] ?? '').toString(),
    lastMessageId: (j['lastMessageId'] as num?)?.toInt() ?? 0,
    artifactPath: (j['artifactPath'] ?? '').toString(),
    artifactName: (j['artifactName'] ?? '').toString(),
    artifactUpdatedAt: (j['artifactUpdatedAt'] ?? '').toString(),
    artifacts: _stringMaps(j['artifacts']),
    intentJson: (j['intentJson'] ?? '').toString(),
  );

  // --- deterministic extraction -------------------------------------------

  /// Device names a person actually writes: R1/SW1/PC1/SRV1, and the long
  /// forms Packet Tracer puts on the canvas (Router0, Switch1, Server0, PC2).
  static List<String> devicesIn(String text, {int limit = maxFocus}) {
    final found = <String>[];
    void add(String? name) {
      if (name == null) return;
      final upper = name;
      if (found.any((f) => f.toLowerCase() == upper.toLowerCase())) return;
      found.add(upper);
    }

    for (final m in RegExp(
      r'\b(Router\s?\d{1,2}|Switch\s?\d{1,2}|Server\s?\d{1,2}|PC\s?\d{1,2}|'
      r'Laptop\s?\d{1,2}|Printer\s?\d{1,2}|AP\s?\d{1,2})\b',
      caseSensitive: false,
    ).allMatches(text)) {
      add(m.group(1)!.replaceAll(' ', ''));
    }
    for (final m in RegExp(
      r'\b(R\d{1,2}|SW\d{1,2}|PC\d{1,2}|SRV\d{1,2}|FW\d{1,2})\b',
    ).allMatches(text)) {
      add(m.group(1)!);
    }
    return found.take(limit).toList();
  }

  /// The endpoints in "can PC1 reach Server0?" / "ping PC1 to Server0" /
  /// "PC1 -> Server0" / "PC1 can't get to the web server".
  ///
  /// The verb list is what makes the pair readable out of a question rather
  /// than only out of an arrow diagram: a person writes "reach", not "->".
  static (String, String)? _endpointPair(String text, List<String> devices) {
    if (devices.length < 2) return null;
    final pair = RegExp(
      r'(\w[\w ]{0,14})\s*'
      r'(?:->|-->|=>|reach(?:es)?|ping(?:s)?|connect(?:s)?\s+to|'
      r'talk(?:s)?\s+to|get(?:s)?\s+to|access(?:es)?|communicate(?:s)?\s+with|'
      r'to|from)\s*'
      r'(\w[\w ]{0,14})',
      caseSensitive: false,
    ).firstMatch(text);
    if (pair == null) return null;
    final a = devices.firstWhere(
      (d) => pair.group(1)!.toLowerCase().contains(d.toLowerCase()),
      orElse: () => '',
    );
    final b = devices.firstWhere(
      (d) => pair.group(2)!.toLowerCase().contains(d.toLowerCase()),
      orElse: () => '',
    );
    if (a.isEmpty || b.isEmpty || a == b) return null;
    // "Server0 cannot be reached from PC5" reads backwards, so the sentence
    // order decides: whichever device came first is the source.
    final aAt = text.toLowerCase().indexOf(a.toLowerCase());
    final bAt = text.toLowerCase().indexOf(b.toLowerCase());
    return aAt <= bAt ? (a, b) : (b, a);
  }

  /// A follow-up names one device and nothing else: "what about PC3?",
  /// "check the router too", "and R2?".
  static bool _isFollowUp(String text) {
    final t = text.trim().toLowerCase();
    if (t.length > 120) return false;
    return RegExp(
      r'^(what about|and |how about|check|also|now |then |what if|same for|'
      r'try )',
    ).hasMatch(t) ||
        RegExp(r'\btoo\b\s*\?*$').hasMatch(t);
  }

  /// The sentence that states the problem, if the user stated one.
  static String _problemSentence(String text) {
    final sentences = text
        .split(RegExp(r'(?<=[.?!])\s+|\n'))
        .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((s) => s.isNotEmpty);
    for (final s in sentences) {
      if (RegExp(
        r"(cannot|can't|can not|unable to|not reach|doesn't work|does not work|"
        r'fails?|failing|unreachable|wrong|incorrect|broken|no internet|'
        r'troubleshoot|problem|issue)',
        caseSensitive: false,
      ).hasMatch(s)) {
        return s.length <= maxProblemChars
            ? s
            : '${s.substring(0, maxProblemChars)}...';
      }
    }
    return '';
  }

  void _pushFocus(List<String> devices) {
    for (final device in devices) {
      focus.removeWhere((f) => f.toLowerCase() == device.toLowerCase());
      focus.insert(0, device);
    }
    while (focus.length > maxFocus) {
      focus.removeLast();
    }
  }

  static List<String> _strings(Object? raw) => raw is List
      ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
      : <String>[];

  static String? _textOrNull(Object? raw) {
    final text = (raw ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  static List<Map<String, dynamic>> _maps(Object? raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static List<Map<String, String>> _stringMaps(Object? raw) {
    if (raw is! List) return <Map<String, String>>[];
    return raw
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry('$k', '${v ?? ''}')))
        .toList();
  }
}
