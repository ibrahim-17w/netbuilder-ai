/// A plain-English review of a pasted device config - offline, no model.
///
/// The reader half ([ConfigPasteReader]) decides that a message IS a config
/// paste; this class says something useful about it. Two rules keep it
/// honest, in the spirit of the rest of the app:
///
/// * every explanation is derived from lines that are actually there; a
///   section that does not appear is simply absent from the review, never
///   described as "not configured" (an absent `ip route` block means static
///   routing was never claimed, which is not a finding);
/// * the classic mistakes are findings with their reason attached, not a
///   checklist recited. "prefer SSH" says why the line matters.
class ConfigSection {
  final String section;
  final int lines;
  final String explanation;

  const ConfigSection(this.section, this.lines, this.explanation);
}

class ConfigFinding {
  /// 'warning' | 'info'
  final String severity;
  final String message;

  const ConfigFinding(this.severity, this.message);
}

class ConfigReport {
  final String device;
  final int lines;
  final List<ConfigSection> sections;
  final List<ConfigFinding> findings;

  const ConfigReport({
    required this.device,
    required this.lines,
    required this.sections,
    required this.findings,
  });

  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('**Config review - $device** ($lines config line(s))')
      ..writeln();
    for (final s in sections) {
      b.writeln('- **${s.section}** (${s.lines} line(s)): ${s.explanation}');
    }
    if (findings.isEmpty) {
      b
        ..writeln()
        ..writeln(
          'No classic-mistake findings. Apply it and test with '
          '`show ip interface brief` and a ping.',
        );
      return b.toString().trimRight();
    }
    b
      ..writeln()
      ..writeln('**Findings**');
    for (final f in findings) {
      b.writeln(
        '- ${f.severity == 'warning' ? 'Warning' : 'Info'}: '
        '${f.message}',
      );
    }
    return b.toString().trimRight();
  }
}

class ConfigExplainer {
  const ConfigExplainer._();

  static ConfigReport explain(String config, {String? device}) {
    final rawLines = config.split('\n');
    final lines = [
      for (final l in rawLines) l.trim(),
    ].where((l) => l.isNotEmpty && l != '!').toList();

    final sections = <ConfigSection>[];
    void section(String name, RegExp pattern, String Function(int) explain) {
      final matched = lines.where(pattern.hasMatch).length;
      if (matched > 0) {
        sections.add(ConfigSection(name, matched, explain(matched)));
      }
    }

    final host =
        device ??
        RegExp(
          r'^hostname\s+(\S+)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(config)?.group(1) ??
        'device';

    section(
      'Hostname',
      RegExp(r'^hostname\s', caseSensitive: false),
      (_) => 'this device calls itself $host.',
    );
    section(
      'Interfaces',
      RegExp(r'^interface\s+\S', caseSensitive: false),
      (n) =>
          '$n interface block(s). Each `ip address` line gives the '
          'interface its IPv4; `switchport mode access|trunk` decides whether '
          'the port serves one VLAN or carries them all.',
    );
    section(
      'VLANs',
      RegExp(r'^vlan\s+\d', caseSensitive: false),
      (n) => '$n VLAN definition(s): broadcast domains separated at layer 2.',
    );
    section(
      'Static routes',
      RegExp(r'^ip\s+route\s', caseSensitive: false),
      (n) =>
          '$n static route(s): traffic for those networks is forwarded to '
          'the next hop by hand - fine for a small lab, a burden at scale '
          '(a routing protocol advertises them instead).',
    );
    section(
      'Routing protocols',
      RegExp(r'^router\s+(ospf|eigrp|rip|bgp)\b', caseSensitive: false),
      (n) =>
          '$n routing process(es): routes are learned from neighbors, so '
          'a new network needs no hand-written route on every device.',
    );
    section(
      'Lines (vty/console)',
      RegExp(r'^line\s+(vty|con|console|aux)\b', caseSensitive: false),
      (n) =>
          '$n line block(s): who may connect to this device and how '
          '(SSH, telnet, the console).',
    );
    section(
      'AAA',
      RegExp(r'^aaa\s+', caseSensitive: false),
      (_) =>
          'login is checked against a central list instead of per-device '
          'passwords.',
    );
    section(
      'Crypto / VPN',
      RegExp(r'^crypto\s+\S+', caseSensitive: false),
      (n) =>
          '$n crypto line(s): tunnel or keying configuration - on Packet '
          'Tracer ISR images the crypto block needs the security license '
          'before the device accepts it.',
    );
    section(
      'Access lists',
      RegExp(r'^(?:ip\s+)?access-list\s+\S+', caseSensitive: false),
      (n) => '$n ACL line(s): the permit/deny rules traffic is judged by.',
    );
    section(
      'Banners',
      RegExp(r'^banner\s+\S+', caseSensitive: false),
      (n) => '$n banner(s): the legal notice shown before login.',
    );

    // --- findings: the classic mistakes, each with its reason --------------
    final findings = <ConfigFinding>[];
    bool has(Pattern p) => lines.any((l) => l.contains(p));
    // The vty block: from `line vty ...` until the next `line ...` or end.
    final vtyBlock = _block(lines, RegExp(r'^line\s+vty\b'));
    if (vtyBlock != null) {
      if (vtyBlock.any((l) => l.startsWith('password'))) {
        findings.add(
          const ConfigFinding(
            'warning',
            'The vty lines set a shared `password` - everyone who learns it gets '
                'in, and it is the same password on every line. Prefer `login local` '
                '(or AAA) with per-user credentials.',
          ),
        );
      }
      if (vtyBlock.any((l) => l.contains('transport input telnet'))) {
        findings.add(
          const ConfigFinding(
            'warning',
            '`transport input telnet` accepts cleartext logins - credentials '
                'cross the wire readable. Allow `transport input ssh` instead.',
          ),
        );
      }
      if (!vtyBlock.any((l) => l.contains('transport input')) &&
          !vtyBlock.any((l) => l.contains('login'))) {
        findings.add(
          const ConfigFinding(
            'info',
            'The vty lines say neither `transport input` nor `login`: the '
                'device default decides who can connect. State it, so the config '
                'is the whole truth.',
          ),
        );
      }
    }
    final hasEnableSecret = has('enable secret');
    if (!hasEnableSecret && has('enable password')) {
      findings.add(
        const ConfigFinding(
          'warning',
          '`enable password` is stored reversibly; `enable secret` hashes it. '
              'Replace the one with the other - the command is '
              '`enable secret <value>`.',
        ),
      );
    }
    final plaintextPasswords = lines.any(
      (l) =>
          RegExp(
            r'^(?:username\s+\S+\s+password|ip\s+ftp\s+password|'
            r'ip\s+http\s+.*password)\b',
            caseSensitive: false,
          ).hasMatch(l) ||
          (l.startsWith('enable password')),
    );
    if (plaintextPasswords && !has('service password-encryption')) {
      findings.add(
        const ConfigFinding(
          'warning',
          'Plaintext passwords appear without `service password-encryption`: '
              'anyone reading the config reads the passwords. Add the command - it '
              'obscures every existing cleartext password.',
        ),
      );
    }
    if (lines.any(
      (l) => RegExp(
        r'^switchport\s+access\s+vlan\s+1\b',
        caseSensitive: false,
      ).hasMatch(l),
    )) {
      findings.add(
        const ConfigFinding(
          'warning',
          'An access port sits on VLAN 1 - the default VLAN every device '
              'shares, so its traffic mixes with management. Move it to a '
              'dedicated VLAN.',
        ),
      );
    }
    if (has('ip http server')) {
      findings.add(
        const ConfigFinding(
          'info',
          '`ip http server` runs the device web UI - unused, it is one more '
              'door to close: `no ip http server`.',
        ),
      );
    }

    return ConfigReport(
      device: host,
      lines: lines.length,
      sections: sections,
      findings: findings,
    );
  }

  /// The lines of one config block, from its opening line (for example
  /// `line vty 0 4`) until the next same-level opener - so a finding about
  /// vty never reads a password that belongs to the console.
  static List<String>? _block(List<String> lines, RegExp opener) {
    final start = lines.indexWhere(opener.hasMatch);
    if (start < 0) return null;
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (RegExp(
        r'^(?:interface|line|router|vlan|crypto)\b',
      ).hasMatch(lines[i])) {
        end = i;
        break;
      }
    }
    return lines.sublist(start, end);
  }
}
