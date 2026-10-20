import 'dart:convert';

import 'offline_knowledge.dart';

/// A bounded, serializable snapshot of what the offline .pkt audit actually
/// read. Follow-up questions use this same evidence after a restart.
class PktAnalysisChat {
  const PktAnalysisChat._();

  static Map<String, dynamic> snapshot(
    Map<String, dynamic> report, {
    required String path,
    required String name,
  }) {
    final devices = <Map<String, dynamic>>[];
    final findings = <Map<String, dynamic>>[];
    final interfaces = <Map<String, dynamic>>[];
    for (final raw in (report['devices'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final d = Map<String, dynamic>.from(raw);
      final device = '${d['name'] ?? ''}'.trim();
      if (device.isEmpty) continue;
      devices.add({'name': device, 'type': '${d['type'] ?? ''}'});
      for (final rawIf in (d['interfaces'] as List?) ?? const []) {
        if (rawIf is! Map) continue;
        final row = Map<String, dynamic>.from(rawIf);
        interfaces.add({
          'device': device,
          'name': '${row['name'] ?? ''}',
          'status': '${row['status'] ?? ''}',
          'ip': '${row['ip'] ?? ''}',
        });
      }
      for (final rawFinding in (d['findings'] as List?) ?? const []) {
        if (rawFinding is! Map) continue;
        final f = Map<String, dynamic>.from(rawFinding);
        final repairs =
            (f['repairs'] as List?)
                ?.whereType<Map>()
                .map((r) => Map<String, dynamic>.from(r))
                .toList() ??
            const <Map<String, dynamic>>[];
        findings.add({
          'id': '${f['id'] ?? ''}',
          'device': '${f['device'] ?? device}',
          'severity': '${f['severity'] ?? 'info'}',
          'kind': '${f['kind'] ?? ''}',
          'text': '${f['text'] ?? ''}',
          'fix_cli':
              (f['fix_cli'] as List?)
                  ?.map((line) => line.toString())
                  .toList() ??
              const <String>[],
          'repairs': repairs,
          'evidence': f['evidence'] is Map
              ? Map<String, dynamic>.from(f['evidence'] as Map)
              : const <String, dynamic>{},
        });
      }
    }
    final summary = report['summary'] is Map
        ? Map<String, dynamic>.from(report['summary'] as Map)
        : <String, dynamic>{};
    final links =
        (report['links'] as List?)
            ?.whereType<Map>()
            .take(120)
            .map((row) => Map<String, dynamic>.from(row))
            .toList() ??
        <Map<String, dynamic>>[];
    return {
      'version': 1,
      'name': name,
      // The local path is retained for a user-requested repair, but omitted
      // from the model context below.
      'path': path,
      'deviceCount': summary['device_count'] ?? devices.length,
      'linkCount': report['linkCount'] ?? summary['links'] ?? links.length,
      'devices': devices.take(80).toList(),
      'findings': findings.take(50).toList(),
      'interfaces': interfaces.take(160).toList(),
      'links': links,
      'note': '${report['note'] ?? ''}',
    };
  }

  static Map<String, dynamic>? decode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) return null;
      return Map<String, dynamic>.from(value);
    } catch (_) {
      return null;
    }
  }

  static String reportText(Map<String, dynamic> analysis) {
    final findings = _findings(analysis);
    final high = findings.where((f) => _severity(f) == 'high').length;
    final conditional = findings.where(_isConditional).length;
    final b = StringBuffer()
      ..writeln('**Offline review of `${analysis['name'] ?? 'capture'}`**')
      ..writeln()
      ..writeln(
        'The saved file contains ${_number(analysis['deviceCount'])} devices '
        'and ${_number(analysis['linkCount'])} links. I found '
        '${findings.length} potential issue(s): $high high priority'
        '${conditional == 0 ? '' : ', $conditional conditional'}.',
      );
    if (findings.isEmpty) {
      b
        ..writeln()
        ..writeln(
          'No saved-configuration or topology issues were detected by the '
          'checks available in this scan.',
        );
    } else {
      b.writeln();
      for (var i = 0; i < findings.length && i < 12; i++) {
        final f = findings[i];
        final label = _isConditional(f)
            ? 'Check intent'
            : _severity(f).toUpperCase();
        b.writeln('${i + 1}. **$label** — ${f['device']}: ${f['text']}');
      }
      if (findings.length > 12) {
        b.writeln('- ${findings.length - 12} more finding(s) are in the scan.');
      }
    }
    b
      ..writeln()
      ..writeln(
        'I only read the saved file; nothing has been changed and Packet '
        'Tracer was not opened. This cannot confirm live pings, service '
        'behavior, or what you intended each link to do. Ask me to explain '
        'a finding, or name the specific change you want prepared.',
      );
    return b.toString().trimRight();
  }

  /// Answer scan-related questions locally. Unrelated questions continue
  /// through the usual chat path with this snapshot included as context.
  static PktAnalysisReply? answer(
    String question,
    Map<String, dynamic> analysis,
  ) {
    final q = question.trim().toLowerCase();
    if (q.isEmpty) return null;
    if (q.startsWith('what if ')) return null;
    final findings = _findings(analysis);
    final explanatory = _isExplanatory(q);
    if (_asksForOverview(q)) {
      return PktAnalysisReply(reportText(analysis));
    }
    if (!explanatory && _isExplicitFix(q)) {
      return _prepareRepair(q, analysis, findings);
    }
    if (_mentionsVlanOne(q) && _mentionsShutdown(q)) {
      return PktAnalysisReply(
        'VLAN 1 is the switch\'s default management SVI; it is separate from '
        'the physical switch ports that carry user traffic. In this saved '
        'file it has no management IP, so leaving it shutdown is normal and '
        'avoids exposing unused management access. If you intend to manage '
        'the switch remotely, use a dedicated management VLAN where possible, '
        'assign its address and enable that SVI. The scan does not count an '
        'unaddressed VLAN 1 SVI as a fault.',
      );
    }
    if (_mentionsShutdown(q)) {
      return PktAnalysisReply(_shutdownExplanation(analysis, findings));
    }
    if (_containsAny(q, const ['first finding', 'first issue', 'first one']) &&
        findings.isNotEmpty) {
      return PktAnalysisReply(_explainFinding(findings.first));
    }
    final matching = _matchingFindings(q, findings);
    if (matching.isNotEmpty &&
        (_isQuestion(q) || _mentionsFinding(q, matching.first))) {
      return PktAnalysisReply(_explainFinding(matching.first));
    }
    if (_asksForExplanation(q)) {
      if (findings.length == 1) {
        return PktAnalysisReply(_explainFinding(findings.first));
      }
      return PktAnalysisReply(
        'I can explain it. This scan has ${findings.length} findings, so '
        'please name the device or interface (for example, “Router0 '
        'Serial0/2/1”) or paste the finding text you mean.',
      );
    }
    if (_isQuestion(q)) {
      final general = OfflineKnowledge.answerFor(question);
      if (general != null) return PktAnalysisReply(general);
    }
    return null;
  }

  static PktAnalysisReply _prepareRepair(
    String q,
    Map<String, dynamic> analysis,
    List<Map<String, dynamic>> findings,
  ) {
    final all = _containsAny(q, const ['all', 'every', 'them', 'these']);
    var candidates = findings.where(_hasSafeRepair).toList();
    if (!all) candidates = _matchingFindings(q, candidates);
    if (candidates.isEmpty) {
      final named = _matchingFindings(q, findings);
      if (named.isNotEmpty) {
        return PktAnalysisReply(
          'I found the item you named, but the saved file does not provide a '
          'safe, complete repair for it. ${_explainFinding(named.first)} Tell '
          'me the intended addressing or link behavior and I can narrow down '
          'a change.',
        );
      }
      return PktAnalysisReply(
        'I can prepare a repair, but I need the device or interface name so '
        'I do not change the wrong part of `${analysis['name'] ?? 'the file'}`. '
        'Ask “what should I fix first?” to review the findings.',
      );
    }
    if (!all && candidates.length > 1) {
      return PktAnalysisReply(
        'I found ${candidates.length} repairable matches. Please name one '
        'device and interface (for example, “fix Router0 Serial0/2/1”), or '
        'say “fix all supported findings” to prepare them together.',
      );
    }
    final selected = all ? candidates : [candidates.first];
    final fixes = <Map<String, dynamic>>[];
    for (final finding in selected) {
      final related =
          (finding['repairs'] as List?)
              ?.whereType<Map>()
              .map((r) => Map<String, dynamic>.from(r))
              .where((r) => _commands(r).isNotEmpty)
              .toList() ??
          [];
      if (related.isNotEmpty) {
        fixes.addAll(
          related.map(
            (r) => {
              ...r,
              'id': '${finding['id'] ?? r['id'] ?? ''}',
              'severity': '${finding['severity'] ?? 'medium'}',
              'text': '${finding['text'] ?? r['text'] ?? ''}',
            },
          ),
        );
      } else {
        fixes.add({
          'id': '${finding['id'] ?? ''}',
          'device': '${finding['device'] ?? ''}',
          'severity': '${finding['severity'] ?? 'medium'}',
          'text': '${finding['text'] ?? ''}',
          'fix_cli': _commands(finding),
        });
      }
    }
    final commands = fixes
        .map((f) => '${f['device']}: ${_commands(f).join(' ; ')}')
        .join('\n');
    final summary = all
        ? 'Prepare ${fixes.length} supported change(s) in one new copy'
        : 'Prepare the requested change in a new copy';
    return PktAnalysisReply(
      'I can prepare this change from your request:\n$commands\n\n'
      'This changes only the named saved configuration. It does not configure '
      'missing IP addressing or prove end-to-end connectivity. Review the '
      'commands, then choose **Create fixed copy** to apply them. The original '
      'file stays untouched.',
      actionSummary: summary,
      fixes: fixes,
      path: '${analysis['path'] ?? ''}',
      name: '${analysis['name'] ?? 'capture.pkt'}',
    );
  }

  static String _shutdownExplanation(
    Map<String, dynamic> analysis,
    List<Map<String, dynamic>> findings,
  ) {
    final down = findings.where(_isConditional).toList();
    final b = StringBuffer()
      ..writeln(
        '`shutdown` administratively disables an interface, so it '
        'cannot pass traffic. `no shutdown` enables it.',
      )
      ..writeln()
      ..writeln(
        'That does not mean every shut interface needs changing. An unused '
        'spare port should usually stay shut, and VLAN 1 with no management '
        'address is commonly left disabled. Enabling unused ports can expose '
        'unneeded access.',
      );
    if (down.isNotEmpty) {
      b
        ..writeln()
        ..writeln(
          'In `${analysis['name'] ?? 'this file'}`, the scan found '
          '${down.length} cabled link(s) with a saved-down endpoint:',
        );
      for (final f in down.take(8)) {
        b.writeln('- ${f['text']}');
      }
      b.writeln(
        'If those links should carry traffic, enable the cabled endpoints '
        'and check their IP addressing; for serial, confirm which end is DCE '
        'and has a clock rate. If a link is intentionally unused, leave it '
        'shut. The offline file cannot determine intent or prove live state.',
      );
    } else {
      b
        ..writeln()
        ..writeln(
          'This scan did not find a cabled interface saved down. It does not '
          'flag unused ports just because they are shutdown.',
        );
    }
    return b.toString().trimRight();
  }

  static String _explainFinding(Map<String, dynamic> f) {
    final text = '${f['text'] ?? ''}';
    final kind = '${f['kind'] ?? ''}';
    final low = text.toLowerCase();
    if (kind == 'connected_interface_down') {
      return 'The audit found this cabled link saved down: $text\n\n'
          'An enabled physical link still needs correct interface settings. '
          'For serial, one end may need a clock rate; routing also requires '
          'addresses and routes. This file alone cannot prove what you intended.';
    }
    if (low.contains('ip address') && low.contains('saved port')) {
      return '$text\n\nThe CLI config and saved interface record disagree. '
          'Packet Tracer may reopen with the interface missing its address, '
          'so hosts or routes that depend on it can fail. Confirm the intended '
          'address and mask before changing it.';
    }
    if (low.contains('cable')) {
      return '$text\n\nCable type affects the physical link before IP or '
          'routing settings matter. A wrong cable can keep the connected '
          'ports down and prevent traffic from crossing.';
    }
    if (low.contains('gateway') || low.contains('route')) {
      return '$text\n\nWithout the expected next hop, devices may communicate '
          'on their local subnet but fail to reach remote networks. Confirm '
          'the intended subnet and routing design before applying a route.';
    }
    if (low.contains('dns')) {
      return '$text\n\nDNS translates names into IP addresses. If a needed '
          'record or server is missing, name-based access can fail even when '
          'a direct IP connection works.';
    }
    if (low.contains('dhcp')) {
      return '$text\n\nDHCP supplies a client address and network settings. '
          'A saved pool warning does not prove a client obtained a lease; that '
          'needs a runtime test in Packet Tracer.';
    }
    return '$text\n\nThis is evidence from the saved `.pkt` file. It can matter '
        'if another device, route, or service depends on this setting. The '
        'offline scan cannot establish live connectivity; tell me the intended '
        'behavior if you want me to check whether a change is needed.';
  }

  static List<Map<String, dynamic>> _matchingFindings(
    String q,
    List<Map<String, dynamic>> findings,
  ) {
    final query = _words(q);
    final scored = <({int score, Map<String, dynamic> finding})>[];
    for (final f in findings) {
      final evidence = f['evidence'] is Map
          ? (f['evidence'] as Map).values.join(' ')
          : '';
      final repairText =
          (f['repairs'] as List?)
              ?.whereType<Map>()
              .map(
                (r) => '${r['device']} ${(r['fix_cli'] as List?)?.join(' ')}',
              )
              .join(' ') ??
          '';
      final words = _words('${f['device']} ${f['text']} $evidence $repairText');
      final score = query
          .intersection(words)
          .fold<int>(0, (sum, word) => sum + (word.length >= 5 ? 2 : 1));
      if (score > 0) scored.add((score: score, finding: f));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return const [];
    final best = scored.first.score;
    return scored
        .where((row) => row.score == best)
        .map((r) => r.finding)
        .toList();
  }

  static List<Map<String, dynamic>> _findings(Map<String, dynamic> a) =>
      ((a['findings'] as List?) ?? const [])
          .whereType<Map>()
          .map((f) => Map<String, dynamic>.from(f))
          .toList();

  static List<String> _commands(Map<String, dynamic> f) =>
      ((f['fix_cli'] as List?) ?? const [])
          .map((line) => line.toString().trim())
          .where((line) => line.isNotEmpty)
          .toList();

  static bool _hasSafeRepair(Map<String, dynamic> f) =>
      _commands(f).isNotEmpty ||
      ((f['repairs'] as List?) ?? const []).any(
        (r) => r is Map && _commands(Map<String, dynamic>.from(r)).isNotEmpty,
      );

  static bool _isConditional(Map<String, dynamic> f) =>
      '${f['kind'] ?? ''}' == 'connected_interface_down';

  static String _severity(Map<String, dynamic> f) =>
      '${f['severity'] ?? 'info'}'.toLowerCase();

  static int _number(dynamic n) =>
      n is num ? n.toInt() : int.tryParse('$n') ?? 0;

  static Set<String> _words(String text) {
    var normalized = text.toLowerCase();
    for (final p in const [
      '?',
      '.',
      ',',
      ':',
      ';',
      '(',
      ')',
      '[',
      ']',
      '{',
      '}',
      '!',
      '"',
      "'",
    ]) {
      normalized = normalized.replaceAll(p, ' ');
    }
    const stop = {
      'the',
      'and',
      'for',
      'with',
      'from',
      'this',
      'that',
      'what',
      'when',
      'where',
      'which',
      'why',
      'how',
      'does',
      'did',
      'can',
      'could',
      'should',
      'would',
      'will',
      'are',
      'was',
      'were',
      'have',
      'has',
      'had',
      'about',
      'fix',
      'repair',
      'please',
      'tell',
      'explain',
      'important',
      'issue',
      'problem',
      'finding',
      'findings',
      'report',
      'scan',
      'file',
      'capture',
    };
    return normalized
        .split(' ')
        .map((w) => w.trim())
        .where(
          (w) =>
              (w.length > 2 ||
                  (w.length == 2 &&
                      w.codeUnits.any((c) => c >= 48 && c <= 57))) &&
              !stop.contains(w),
        )
        .toSet();
  }

  static bool _containsAny(String text, List<String> values) =>
      values.any((v) => text.contains(v));

  static bool _mentionsShutdown(String q) =>
      q.contains('shutdown') ||
      q.contains('shut down') ||
      q.contains('no shut');

  static bool _mentionsVlanOne(String q) =>
      q.contains('vlan 1') || q.contains('vlan1');

  static bool _isQuestion(String q) =>
      q.contains('?') ||
      _containsAny(q, const [
        'why ',
        'what ',
        'how ',
        'when ',
        'where ',
        'which ',
        'explain ',
        'tell me ',
        'should i ',
        'does it ',
        'is this ',
      ]);

  static bool _isExplanatory(String q) => _containsAny(q, const [
    'why ',
    'what does ',
    'what is ',
    'how ',
    'explain ',
    'tell me why ',
    'should i ',
    'is it ',
    'does it ',
    'what should i ',
    'what do i ',
    'what to ',
  ]);

  static bool _isExplicitFix(String q) =>
      _startsWithAny(q, const [
        'fix ',
        'repair ',
        'correct ',
        'apply ',
        'change ',
        'enable ',
        'disable ',
        'configure ',
      ]) ||
      _startsWithAny(q, const [
        'can you fix',
        'could you fix',
        'would you fix',
        'can you repair',
        'could you repair',
        'i want you to fix',
        'go ahead and fix',
      ]) ||
      q.contains(', fix ') ||
      q.contains(' and fix ');

  static bool _startsWithAny(String text, List<String> values) =>
      values.any(text.startsWith);

  static bool _asksForOverview(String q) => _containsAny(q, const [
    'what is wrong',
    'what should i fix',
    'what do i fix',
    'what to fix',
    'fix first',
    'priority',
    'priorities',
    'summarize',
    'summarise',
    'overview',
    'list the issues',
    'show the findings',
  ]);

  static bool _asksForExplanation(String q) => _containsAny(q, const [
    'explain more',
    'explain this',
    'tell me more',
    'what does this mean',
    'what does it mean',
    'what does that mean',
    'why is this an issue',
    'why is this a problem',
    'why does this matter',
  ]);

  static bool _mentionsFinding(String q, Map<String, dynamic> f) =>
      _words(q).intersection(_words('${f['device']} ${f['text']}')).isNotEmpty;
}

class PktAnalysisReply {
  final String text;
  final String actionSummary;
  final List<Map<String, dynamic>> fixes;
  final String path;
  final String name;

  const PktAnalysisReply(
    this.text, {
    this.actionSummary = '',
    this.fixes = const [],
    this.path = '',
    this.name = '',
  });
}
