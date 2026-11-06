import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'adapters/packet_tracer_adapter.dart';
import 'build_artifact_service.dart';
import 'memory_service.dart';
import 'plan_version_service.dart';
import 'project_checks.dart';
import 'stored_privacy.dart';
import 'pkt/pkt_codec.dart';
import 'pkt/pkt_engine_builder.dart';
import 'pkt/template_library.dart';

/// A bounded JSON container. Entries are inert data; imports never extract paths
/// or execute contents. The only writable destination is the local database.
class ProjectPackage {
  static const maxBytes = 20 * 1024 * 1024;
  static String artifactsKey(String project) => 'project-package:$project';

  static Future<Uint8List> export(
    BuildRecord record,
    MemoryService memory, {
    bool includePkt = false,
  }) async {
    final plan = NetworkIntent.fromJson(
      StoredPrivacy.row(
        Map<String, dynamic>.from(jsonDecode(record.intentJson)),
      ),
    );
    final checks = await ProjectChecks(
      memory,
      PlanVersionService.projectKeyOf(record),
    ).load();
    final artifacts = <String, Uint8List>{
      'configuration.txt': Uint8List.fromList(
        utf8.encode(
          NetworkIntent.redactSecrets(
            BuildArtifactService.renderLocal(plan, record.target),
          ),
        ),
      ),
      'report.txt': Uint8List.fromList(
        utf8.encode(
          'Source status: ${record.status}\nDesign revision: ${plan.revision}\nImported projects require fresh verification.\n${checks.map((c) => '${c.label}: ${c.statusFor(plan)}').join('\n')}',
        ),
      ),
    };
    if (includePkt) {
      final built = await buildPkt(
        plan: PacketTracerAdapter.autopilotPlan(plan),
        library: await PktTemplateLibrary.loadBundled(),
        project: plan.projectName,
      );
      final unresolved = built.warnings
          .where(
            (w) =>
                !w.contains('dropped exec-only line(s) from the saved config:'),
          )
          .toList();
      if (unresolved.isNotEmpty) {
        throw FormatException(
          'The optional .pkt has unresolved warnings: ${unresolved.join('; ')}',
        );
      }
      artifacts['design.pkt'] = encryptPkt(built.xml);
    }
    return encode(plan, checks: checks, artifacts: artifacts);
  }

  static Uint8List encode(
    NetworkIntent plan, {
    List<ProjectCheck> checks = const [],
    Map<String, Uint8List> artifacts = const {},
  }) {
    final payload = StoredPrivacy.row({
      'plan': plan.toPlannerJson(),
      'checks': checks.map((c) => c.toJson()).toList(),
    });
    payload['artifacts'] = [
      for (final entry in artifacts.entries)
        {
          'name': entry.key,
          'size': entry.value.length,
          'sha256': sha256.convert(entry.value).toString(),
          'data': base64Encode(entry.value),
        },
    ];
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'netbuilder-project',
          'version': 1,
          'sha256': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
          'payload': payload,
        }),
      ),
    );
    inspect(bytes);
    return bytes;
  }

  static ProjectPackagePreview inspect(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Project packages must be 20 MB or smaller.');
    }
    final root = jsonDecode(utf8.decode(bytes));
    if (root is! Map ||
        root['format'] != 'netbuilder-project' ||
        root['version'] != 1 ||
        root['payload'] is! Map) {
      throw const FormatException('Unsupported NetBuilder project package.');
    }
    final payload = Map<String, dynamic>.from(root['payload']);
    if (root['sha256'] !=
        sha256.convert(utf8.encode(jsonEncode(payload))).toString()) {
      throw const FormatException('The package checksum does not match.');
    }
    if (payload['plan'] is! Map ||
        payload['checks'] is! List ||
        payload['artifacts'] is! List) {
      throw const FormatException('Incomplete project package.');
    }
    final plan = NetworkIntent.fromJson(
      StoredPrivacy.row(Map<String, dynamic>.from(payload['plan'])),
    );
    if (plan.nodes.isEmpty ||
        plan.nodes.length > 500 ||
        plan.nodes.map((n) => n.name).toSet().length != plan.nodes.length) {
      throw const FormatException(
        'The package must contain 1–500 uniquely named devices.',
      );
    }
    final checks = <ProjectCheck>[];
    if ((payload['checks'] as List).length > 40) {
      throw const FormatException('Too many project checks.');
    }
    for (final row in payload['checks']) {
      final c = ProjectCheck.fromJson(Map<String, dynamic>.from(row));
      final fresh = ProjectChecks.create(
        plan,
        c.source,
        c.destination,
        allow: c.allow,
      );
      checks.add(fresh);
    }
    final artifacts = <String, Uint8List>{};
    if ((payload['artifacts'] as List).length > 12) {
      throw const FormatException('Too many attachments.');
    }
    var total = 0;
    for (final row in payload['artifacts']) {
      final name = row['name'];
      // No path separators, parent components, drive prefixes or hidden files.
      if (name is! String ||
          !RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9_-]{0,79}\.(?:txt|json|pkt)$',
          ).hasMatch(name) ||
          artifacts.containsKey(name)) {
        throw const FormatException('Unsafe or duplicate attachment name.');
      }
      final data = base64Decode(row['data'] as String);
      total += data.length;
      if (total > maxBytes ||
          row['size'] != data.length ||
          row['sha256'] != sha256.convert(data).toString()) {
        throw const FormatException(
          'Attachment checksum or size does not match.',
        );
      }
      // Packages are data, but legacy text exports can still carry credentials.
      artifacts[name] = name.endsWith('.pkt')
          ? data
          : Uint8List.fromList(
              utf8.encode(NetworkIntent.redactSecrets(utf8.decode(data))),
            );
    }
    return ProjectPackagePreview(plan, checks, artifacts);
  }

  static Future<BuildRecord> import(
    Uint8List bytes,
    MemoryService memory,
  ) async {
    final preview = inspect(bytes);
    final key = const Uuid().v4();
    final json = preview.plan.toPlannerJson();
    json['projectName'] =
        '${preview.plan.projectName}-import-${key.substring(0, 8)}';
    final plan = NetworkIntent.fromJson(json);
    final row = BuildRecord(
      projectName: plan.projectName,
      projectKey: key,
      instruction: 'Imported project package; review and verify',
      intentJson: jsonEncode(plan.toPlannerJson()),
      target: 'packet-tracer',
      success: false,
      status: 'planned',
      createdAt: DateTime.now(),
    );
    final id = await memory.saveProjectWithPrefs(row, {
      ProjectChecks.storageKey(key): jsonEncode(
        preview.checks.map((c) => c.toJson()).toList(),
      ),
      artifactsKey(key): jsonEncode({
        for (final e in preview.artifacts.entries) e.key: base64Encode(e.value),
      }),
    });
    return BuildRecord.fromMap({...row.toMap(), 'id': id});
  }

  static Future<Map<String, Uint8List>> savedArtifacts(
    MemoryService memory,
    String project,
  ) async {
    final raw = await memory.readPref(artifactsKey(project));
    if (raw == null) return {};
    final rows = Map<String, dynamic>.from(jsonDecode(raw));
    return {
      for (final entry in rows.entries) entry.key: base64Decode(entry.value),
    };
  }
}

class ProjectPackagePreview {
  final NetworkIntent plan;
  final List<ProjectCheck> checks;
  final Map<String, Uint8List> artifacts;
  const ProjectPackagePreview(this.plan, this.checks, this.artifacts);
}
