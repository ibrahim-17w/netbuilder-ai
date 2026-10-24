/// What changed between two scanned .pkt files.
///
/// Both sides are the same bounded snapshots the scan follow-ups read, so a
/// diff never claims anything the scans themselves could not prove: devices
/// by name, addresses per device+interface, links as endpoint pairs, and
/// findings matched by their stable id text. Pure and offline - the caller
/// supplies two snapshots; this file never touches disk or the engine.
class ScanDiff {
  final List<String> devicesAdded;
  final List<String> devicesRemoved;
  final List<({String device, String iface, String before, String after})>
  addressChanges;
  final List<String> linksAdded;
  final List<String> linksRemoved;
  final List<String> findingsCleared;
  final List<String> findingsIntroduced;

  const ScanDiff({
    this.devicesAdded = const [],
    this.devicesRemoved = const [],
    this.addressChanges = const [],
    this.linksAdded = const [],
    this.linksRemoved = const [],
    this.findingsCleared = const [],
    this.findingsIntroduced = const [],
  });

  bool get isEmpty =>
      devicesAdded.isEmpty &&
      devicesRemoved.isEmpty &&
      addressChanges.isEmpty &&
      linksAdded.isEmpty &&
      linksRemoved.isEmpty &&
      findingsCleared.isEmpty &&
      findingsIntroduced.isEmpty;
}

class PktScanDiff {
  const PktScanDiff._();

  static ScanDiff diff(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    final beforeDevices = _deviceNames(before);
    final afterDevices = _deviceNames(after);
    final devicesAdded = afterDevices.difference(beforeDevices).toList()
      ..sort();
    final devicesRemoved = beforeDevices.difference(afterDevices).toList()
      ..sort();

    // Addresses are compared per device+interface, status ignored: a port
    // flapping up/down is state, an address moving is a design change.
    // Keys are lowercased for matching; the display names travel with them.
    final addressChanges =
        <({String device, String iface, String before, String after})>[];
    final beforeAddr = _addressMap(before);
    final afterAddr = _addressMap(after);
    final keys = {...beforeAddr.keys, ...afterAddr.keys}.toList()..sort();
    for (final key in keys) {
      final was = beforeAddr[key]?.ip ?? '';
      final now = afterAddr[key]?.ip ?? '';
      if (was == now) continue;
      final meta = afterAddr[key] ?? beforeAddr[key]!;
      addressChanges.add((
        device: meta.device,
        iface: meta.iface,
        before: was,
        after: now,
      ));
    }

    final beforeLinks = _linkSet(before);
    final afterLinks = _linkSet(after);
    final linksAdded = afterLinks.difference(beforeLinks).toList()..sort();
    final linksRemoved = beforeLinks.difference(afterLinks).toList()..sort();

    final beforeFindings = _findingTexts(before);
    final afterFindings = _findingTexts(after);
    final findingsCleared = beforeFindings.difference(afterFindings).toList()
      ..sort();
    final findingsIntroduced = afterFindings.difference(beforeFindings).toList()
      ..sort();

    return ScanDiff(
      devicesAdded: devicesAdded,
      devicesRemoved: devicesRemoved,
      addressChanges: addressChanges,
      linksAdded: linksAdded,
      linksRemoved: linksRemoved,
      findingsCleared: findingsCleared,
      findingsIntroduced: findingsIntroduced,
    );
  }

  /// Markdown for the chat: changed first, honest "no differences" when the
  /// two files read the same.
  static String toMarkdown(
    ScanDiff diff, {
    required String beforeName,
    required String afterName,
  }) {
    final b = StringBuffer()
      ..writeln('**$beforeName -> $afterName**')
      ..writeln();
    if (diff.isEmpty) {
      b.writeln(
        'No differences the scans can prove: same devices, addresses, '
        'cables and findings.',
      );
      return b.toString().trimRight();
    }
    if (diff.devicesAdded.isNotEmpty) {
      b.writeln('- Devices added: ${diff.devicesAdded.join(', ')}');
    }
    if (diff.devicesRemoved.isNotEmpty) {
      b.writeln('- Devices removed: ${diff.devicesRemoved.join(', ')}');
    }
    for (final c in diff.addressChanges) {
      final was = c.before.isEmpty ? '(no address)' : c.before;
      final now = c.after.isEmpty ? '(no address)' : c.after;
      b.writeln('- ${c.device} ${c.iface}: $was -> $now');
    }
    if (diff.linksAdded.isNotEmpty) {
      b.writeln('- Cables added: ${diff.linksAdded.join(', ')}');
    }
    if (diff.linksRemoved.isNotEmpty) {
      b.writeln('- Cables removed: ${diff.linksRemoved.join(', ')}');
    }
    if (diff.findingsCleared.isNotEmpty) {
      b
        ..writeln('- Findings cleared (${diff.findingsCleared.length}):')
        ..writeln('  ${_cap(diff.findingsCleared)}');
    }
    if (diff.findingsIntroduced.isNotEmpty) {
      b
        ..writeln('- Findings introduced (${diff.findingsIntroduced.length}):')
        ..writeln('  ${_cap(diff.findingsIntroduced)}');
    }
    return b.toString().trimRight();
  }

  // --- snapshot readers ----------------------------------------------------

  static Set<String> _deviceNames(Map<String, dynamic> snapshot) => {
    for (final d in (snapshot['devices'] as List?) ?? const [])
      if (d is Map && '${d['name'] ?? ''}'.trim().isNotEmpty)
        '${d['name']}'.trim(),
  };

  /// 'device|iface' (lowercased) -> the row's display names and ip;
  /// unassigned/empty collapses to ''.
  static Map<String, ({String device, String iface, String ip})> _addressMap(
    Map<String, dynamic> snapshot,
  ) {
    final out = <String, ({String device, String iface, String ip})>{};
    for (final row in (snapshot['interfaces'] as List?) ?? const []) {
      if (row is! Map) continue;
      final device = '${row['device'] ?? ''}'.trim();
      final iface = '${row['name'] ?? ''}'.trim();
      if (device.isEmpty || iface.isEmpty) continue;
      final ip = '${row['ip'] ?? ''}'.trim();
      out['${device.toLowerCase()}|$iface'] = (
        device: device,
        iface: iface,
        ip: ip.toLowerCase() == 'unassigned' ? '' : ip,
      );
    }
    return out;
  }

  static Set<String> _linkSet(Map<String, dynamic> snapshot) => {
    for (final row in (snapshot['links'] as List?) ?? const [])
      if (row is Map) '${row['a']}:${row['aIf']} <-> ${row['b']}:${row['bIf']}',
  };

  /// Findings by their text: ids carry per-scan counters, the text is the
  /// stable part worth comparing.
  static Set<String> _findingTexts(Map<String, dynamic> snapshot) => {
    for (final f in (snapshot['findings'] as List?) ?? const [])
      if (f is Map) '${f['text'] ?? ''}'.trim(),
  };

  static String _cap(List<String> items, [int n = 4]) => items.length <= n
      ? items.join('; ')
      : '${items.take(n).join('; ')}; (+${items.length - n} more)';
}

/// Reads "diff A and B" - the request to compare two scanned files.
///
/// Two .pkt paths in one message name both sides. One path plus the words
/// for the current capture ("this file", "the scan") pairs it with what is
/// already on the table. Anything else is not a diff request.
class PktScanDiffRequest {
  const PktScanDiffRequest._();

  /// Any non-space run; candidates are kept only when they end in .pkt.
  /// (Paths containing spaces must be the only text besides the verb -
  /// the two-candidate rule still applies.)
  static final _token = RegExp(r'\S+', caseSensitive: false);

  static ({String pathA, String pathB, String nameA, String nameB})? read(
    String raw, {
    required String? currentCapturePath,
    required String? currentCaptureName,
  }) {
    final t = raw.trim();
    if (!RegExp(
      r'\b(diff|compare|changes?\s+between)\b',
      caseSensitive: false,
    ).hasMatch(t)) {
      return null;
    }
    final paths = _token
        .allMatches(t)
        .map((m) => m.group(0)!)
        .where((p) => p.toLowerCase().endsWith('.pkt'))
        .toList();
    if (paths.length >= 2) {
      return (
        pathA: paths[0],
        pathB: paths[1],
        nameA: _stem(paths[0]),
        nameB: _stem(paths[1]),
      );
    }
    if (paths.length == 1 &&
        currentCapturePath != null &&
        currentCapturePath.trim().isNotEmpty &&
        RegExp(
          r'\b(this|current|the\s+scan|the\s+capture|open)\b',
          caseSensitive: false,
        ).hasMatch(t)) {
      final nameA = (currentCaptureName ?? '').trim().isEmpty
          ? _stem(currentCapturePath)
          : currentCaptureName!.trim();
      return (
        pathA: currentCapturePath,
        pathB: paths[0],
        nameA: nameA,
        nameB: _stem(paths[0]),
      );
    }
    return null;
  }

  static String _stem(String path) =>
      path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.pkt$'), '');
}
