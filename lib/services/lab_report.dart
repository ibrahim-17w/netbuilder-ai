import '../models/network_intent.dart';
import 'build_guide.dart';
import 'build_preflight.dart';
import 'design_review.dart';

/// Reads "export a lab report" - the request to assemble one document.
class LabReportRequest {
  const LabReportRequest._();

  static bool matches(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('\u2019', "'");
    if (t.isEmpty || t.contains('\n')) return false;
    return RegExp(
      r'^(?:please\s+)?'
      r'(?:/report|'
      r'(?:export|write|generate|create|make)\s+(?:me\s+)?(?:a\s+|the\s+)?'
      r'lab\s+report|'
      r'lab\s+report)$',
    ).hasMatch(t);
  }
}

/// One Markdown document assembling what this conversation already proved:
/// the plan, its design review, the build record with each file's
/// verification note, the offline scan findings, and the full build guide.
///
/// Every section is composed from an existing generator - the report invents
/// nothing. Where evidence is missing (no build yet, no scan), the section
/// says so in those words instead of implying it.
class LabReport {
  const LabReport._();

  static String markdown({
    required NetworkIntent intent,
    required String target,
    required List<({String name, String note})> artifacts,
    Map<String, dynamic>? scanAnalysis,
  }) {
    final project = intent.projectName.trim().isEmpty
        ? 'network'
        : intent.projectName.trim();
    final b = StringBuffer()
      ..writeln('# Lab report - $project')
      ..writeln()
      ..writeln(
        'Generated ${DateTime.now().toIso8601String().substring(0, 10)} '
        'with NetBuilder AI. Everything below was produced and verified '
        'on this device; nothing is claimed beyond what the app checked.',
      )
      ..writeln();

    // --- the plan ---------------------------------------------------------
    b
      ..writeln('## The plan')
      ..writeln()
      ..writeln(
        '${BuildPreflight.describeDevices(intent)}; routing '
        '${intent.routing.isEmpty ? 'none' : intent.routing}.',
      )
      ..writeln();
    final vlans = intent.vlans.toList()..sort();
    if (vlans.isNotEmpty) {
      b.writeln('VLANs: ${vlans.join(', ')}');
      b.writeln();
    }
    if (intent.addressing.isNotEmpty) {
      b
        ..writeln('| Device | Interface | Address |')
        ..writeln('| --- | --- | --- |');
      for (final a in intent.addressing) {
        b.writeln('| ${a.node} | ${a.iface} | ${a.ipCidr} |');
      }
      b.writeln();
    }

    // --- design review ----------------------------------------------------
    final review = DesignReviewer.review(intent);
    b
      ..writeln('## Design review')
      ..writeln()
      ..writeln('${review.score}/100 - ${review.verdict}. ${review.headline}')
      ..writeln();
    if (review.strengths.isNotEmpty) {
      b.writeln('Holds up: ${review.strengths.join('; ')}.');
      b.writeln();
    }
    for (final f in review.findings.take(6)) {
      b.writeln('- ${f.severity.name} (${f.area}): ${f.message}');
    }
    if (review.findings.length > 6) {
      b.writeln('- ...and ${review.findings.length - 6} more.');
    }
    if (review.findings.isNotEmpty) b.writeln();

    // --- builds and verification -----------------------------------------
    b
      ..writeln('## Builds')
      ..writeln();
    if (artifacts.isEmpty) {
      b
        ..writeln(
          'No .pkt was built in this conversation yet - say "build '
          'the .pkt" and the report gains this section\'s evidence.',
        )
        ..writeln();
    } else {
      for (final a in artifacts) {
        b
          ..writeln(
            '- **${a.name}**'
            '${a.note.trim().isEmpty ? '' : ' - ${a.note}'}',
          )
          ..writeln();
      }
    }

    // --- offline scan -----------------------------------------------------
    b
      ..writeln('## Offline scan')
      ..writeln();
    if (scanAnalysis == null) {
      b
        ..writeln(
          'No .pkt was analyzed in this conversation. Scan a file '
          '("/scan <path>" or the router button) for findings here.',
        )
        ..writeln();
    } else {
      final findings = [
        for (final f in (scanAnalysis['findings'] as List?) ?? const [])
          if (f is Map)
            (
              severity: '${f['severity'] ?? 'info'}',
              text: '${f['text'] ?? ''}'.trim(),
            ),
      ];
      final high = findings.where((f) => f.severity == 'high').length;
      b
        ..writeln(
          '${scanAnalysis['name'] ?? 'the scanned file'}: '
          '${scanAnalysis['deviceCount'] ?? '?'} device(s), '
          '${scanAnalysis['linkCount'] ?? '?'} link(s), '
          '${findings.length} finding(s) ($high high).',
        )
        ..writeln();
      for (final f in findings.take(8)) {
        b.writeln('- [${f.severity}] ${f.text}');
      }
      if (findings.length > 8) {
        b.writeln('- ...and ${findings.length - 8} more.');
      }
      if (findings.isNotEmpty) b.writeln();
      final note = '${scanAnalysis['note'] ?? ''}'.trim();
      if (note.isNotEmpty) {
        b
          ..writeln(note)
          ..writeln();
      }
    }

    // --- the build guide --------------------------------------------------
    b
      ..writeln('## How to build it')
      ..writeln()
      ..writeln(BuildGuide.markdown(intent, target: target));
    return b.toString().trimRight();
  }
}
