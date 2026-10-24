import '../models/network_intent.dart';
import 'pkt_plan_import_service.dart';

/// Reads "use this file as my lab" - the request to make the scanned capture
/// the conversation's standing plan.
///
/// A scan today is a read-only report: findings, explanations, fixes. The
/// rest of the app's machinery - the guide, the build, "add a switch" -
/// only works on a plan, and the import service that converts a scanned
/// save into one already exists. This reader is deliberately narrow: the
/// message must be ABOUT adopting the file (the words file/capture/scan or
/// a bare "it", pointed at a lab/plan), so an ordinary build or edit request
/// never lands here by accident.
class PktImportRequest {
  const PktImportRequest._();

  static final _pattern = RegExp(
    r'^(?:please\s+)?'
    r'(?:use|make|set|take|import)\s+(?:this|that|the)\s+'
    r'(?:file|capture|scan|save|\.pkt|pkt)?\s*'
    r'(?:as\s+)?(?:my|the|our)?\s*'
    r'(?:standing\s+)?(?:lab|plan|network|project)\b'
    r'|^(?:please\s+)?import\s+(?:this|that|the)\s+(?:file|capture|scan)',
    caseSensitive: false,
  );

  /// True when [raw] asks to adopt the scanned file as the standing plan.
  static bool matches(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('\u2019', "'");
    if (t.isEmpty || t.contains('\n')) return false;
    return _pattern.hasMatch(t);
  }
}

/// The reply an import earns, composed away from the screen so the wording
/// is testable without a widget tree.
class PktImportReply {
  const PktImportReply._();

  static String text(
    ImportedPktPlan imported, {
    required String fileName,
    NetworkIntent? replaced,
  }) {
    final intent = imported.intent;
    final b = StringBuffer()
      ..writeln(
        '**$fileName is the lab now.** ${intent.nodes.length} device(s), '
        '${intent.links.length} link(s) read from the save and turned into '
        'the standing plan.',
      );
    final replacedStood = replaced != null && replaced.nodes.isNotEmpty;
    if (replacedStood) {
      b
        ..writeln()
        ..writeln(
          'This replaces the plan that was standing '
          '(${replaced.nodes.length} device(s)). Say "undo that" to think '
          'again - the change is in the log.',
        );
    }
    if (imported.preservedDetails.isNotEmpty) {
      b
        ..writeln()
        ..writeln('**Kept from the file:**');
      for (final detail in imported.preservedDetails.take(5)) {
        b.writeln('- $detail');
      }
    }
    if (imported.limitations.isNotEmpty) {
      b
        ..writeln()
        ..writeln('**Not carried across** (the save does not prove them):');
      for (final limitation in imported.limitations.take(5)) {
        b.writeln('- $limitation');
      }
    }
    b
      ..writeln()
      ..writeln(
        'From here it behaves like any plan: ask "how do I build this?" for '
        'the steps, "build the .pkt" to compile it, or just say what to '
        'change - "add a server", "use OSPF".',
      );
    return b.toString().trimRight();
  }
}
