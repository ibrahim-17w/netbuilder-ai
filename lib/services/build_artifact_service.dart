import 'dart:convert';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'adapters/cisco_adapter.dart';
import 'adapters/gns3_adapter.dart';
import 'adapters/packet_tracer_adapter.dart';
import 'adapters/terraform_adapter.dart';

/// The in-memory representation needed to reopen a saved build.
///
/// Build history stores the portable intent rather than a rendered export, so
/// reopening a project always recompiles the output with the same local
/// adapters used by the Build screen.
class RestoredBuild {
  final BuildRecord record;
  final NetworkIntent intent;
  final String configText;

  const RestoredBuild({
    required this.record,
    required this.intent,
    required this.configText,
  });
}

class BuildArtifactService {
  const BuildArtifactService._();

  /// Restores a history record into the same detail inputs produced by a new
  /// build. Invalid or legacy data fails clearly instead of opening an empty
  /// editor that looks like a successful load.
  static RestoredBuild restore(BuildRecord record) {
    final raw = record.intentJson.trim();
    if (raw.isEmpty) {
      throw const FormatException('Saved project has no plan data.');
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Saved project plan must be a JSON object.');
    }

    final json = Map<String, dynamic>.from(decoded);
    final intent = NetworkIntent.fromJson(json);
    final storedProject = json['projectName'];
    final projectName = record.projectName.trim();
    final restoredIntent =
        storedProject is String && storedProject.trim().isNotEmpty
        ? intent
        : projectName.isEmpty
        ? intent
        : intent.copyWith(projectName: projectName);

    return RestoredBuild(
      record: record,
      intent: restoredIntent,
      configText: renderLocal(restoredIntent, record.target),
    );
  }

  /// Compiles the validated intent into the target-specific artifact shown in
  /// the Detail screen. This is shared by new builds and reopened builds so
  /// the two paths cannot drift.
  static String renderLocal(NetworkIntent intent, String target) {
    switch (target.trim().toLowerCase()) {
      case 'aws-vpc':
        return TerraformAdapter.renderAwsVpc(intent);
      case 'gns3':
        return Gns3Adapter.exportJson(intent);
      case 'packet-tracer':
        final configs = PacketTracerAdapter.deviceConfigs(intent);
        return configs.entries
            .map((entry) => '=== ${entry.key} ===\n${entry.value}')
            .join('\n');
      case 'cisco-ssh':
      default:
        return CiscoAdapter.render(intent).entries
            .map((entry) => '=== ${entry.key} ===\n${entry.value}')
            .join('\n');
    }
  }
}
