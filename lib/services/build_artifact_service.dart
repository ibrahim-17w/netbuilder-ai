import 'dart:convert';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'adapters/cisco_adapter.dart';
import 'adapters/gns3_adapter.dart';
import 'adapters/packet_tracer_adapter.dart';
import 'adapters/terraform_adapter.dart';
import 'secret_vault.dart';

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
  ///
  /// Secrets are NOT in the stored intent (the database never holds them);
  /// [restoreAsync] pulls them back out of the OS keychain.  The sync
  /// [restore] stays for legacy callers and records saved before the vault
  /// existed - those records may still carry secrets inline.
  static RestoredBuild restore(BuildRecord record) {
    return _restoreFromJson(record, jsonDecode(record.intentJson.trim()));
  }

  /// Same as [restore], but re-injects AAA/VPN secrets from the OS keychain
  /// so reopened builds recompile with the exact credentials they had.
  static Future<RestoredBuild> restoreAsync(BuildRecord record) async {
    final raw = record.intentJson.trim();
    if (raw.isEmpty) {
      throw const FormatException('Saved project has no plan data.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Saved project plan must be a JSON object.');
    }
    final secrets = await SecretVault.load(record.projectName);
    final merged = SecretVault.inject(
      Map<String, dynamic>.from(decoded),
      secrets,
    );
    return _restoreFromJson(record, merged);
  }

  static RestoredBuild _restoreFromJson(BuildRecord record, dynamic decoded) {
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

  /// A human-meaningful .pkt file name for [plan]: content words from the
  /// brief ("small office with OSPF" saves as `small-office-ospf.pkt`),
  /// because in chat builds [plan]'s projectName is the CONVERSATION key
  /// ("chat"), not the network's name. The topology signature is the last
  /// resort for a lab nobody described. A timestamp hides a lab from the
  /// person who built it; a name does not.
  ///
  /// [taken] holds names already written (session artifacts, the output
  /// directory); a collision gets -2, -3 ... because a newer build must
  /// never silently clobber an older lab with the same name.
  static String networkFileName({
    required NetworkIntent plan,
    String brief = '',
    required Set<String> taken,
  }) {
    var source = _briefWords(brief);
    if (source.isEmpty) {
      source = plan.projectName.trim();
      if (_isGenericName(source)) {
        // The topology itself names the file: the device mix plus the
        // routing is the shortest honest description of a lab nobody named.
        final routers = plan.nodes.where((n) => n.type == 'router').length;
        final switches = plan.nodes.where((n) => n.type == 'switch').length;
        final pcs = plan.nodes.where((n) => n.type == 'pc').length;
        final servers = plan.nodes.where((n) => n.type == 'server').length;
        final routing = plan.routing.trim().toLowerCase();
        source = [
          if (routers > 0) '$routers-routers',
          if (switches > 0) '$switches-switches',
          if (pcs > 0) '$pcs-pcs',
          if (servers > 0) '$servers-servers',
          if (routing.isNotEmpty) routing,
        ].join('-');
      }
    }
    var base = _slug(source);
    if (base.isEmpty || base == 'net') base = 'network';
    var name = '$base.pkt';
    var n = 2;
    while (taken.contains(name)) {
      name = '$base-$n.pkt';
      n += 1;
    }
    return name;
  }

  /// Parser fallback names that say nothing about the network.
  static bool _isGenericName(String name) {
    final t = name.trim().toLowerCase();
    return t.isEmpty || t == 'net' || t == 'network';
  }

  /// Content words of [brief]: stopwords and bare numbers dropped, capped
  /// at four, so a brief becomes at most four dashes of name.
  static String _briefWords(String brief) {
    const stopwords = {
      'the', 'a', 'an', 'and', 'or', 'with', 'for', 'of', 'in', 'on', 'at',
      'to', 'from', 'plus', 'also', 'that', 'this', 'lab', 'network',
      'build', 'make', 'create', 'plan', 'set', 'up', 'please', 'give',
      'me', 'i', 'want', 'need', 'have', 'has', 'use', 'using', 'some',
    };
    final words = brief
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where(
          (w) =>
              w.length > 1 &&
              !stopwords.contains(w) &&
              !RegExp(r'^\d+$').hasMatch(w),
        )
        .take(4)
        .toList();
    return words.join('-');
  }

  static String _slug(String s) {
    var t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    t = t.replaceAll(RegExp(r'-+'), '-');
    t = t.replaceAll(RegExp(r'^-+|-+$'), '');
    if (t.length > 48) {
      t = t.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
    }
    return t;
  }
}
