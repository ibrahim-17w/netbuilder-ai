import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../models/network_intent.dart';
import 'memory_service.dart';
import 'topology_reasoner.dart';

class ProjectCheck {
  final String id, source, destination, kind, evidence, testedRevision, status;
  final bool allow;
  const ProjectCheck({
    required this.id,
    required this.source,
    required this.destination,
    this.kind = 'ping',
    this.allow = true,
    this.evidence = '',
    this.testedRevision = '',
    this.status = 'unverified',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'destination': destination,
    'kind': kind,
    'allow': allow,
    'evidence': evidence,
    'testedRevision': testedRevision,
    'status': status,
  };
  factory ProjectCheck.fromJson(Map<String, dynamic> j) => ProjectCheck(
    id: j['id'] as String,
    source: j['source'] as String,
    destination: j['destination'] as String,
    kind: j['kind'] as String? ?? 'ping',
    allow: j['allow'] as bool? ?? true,
    evidence: j['evidence'] as String? ?? '',
    testedRevision: j['testedRevision'] as String? ?? '',
    status: j['status'] as String? ?? 'unverified',
  );
  String statusFor(NetworkIntent plan) =>
      testedRevision.isNotEmpty && testedRevision != plan.revision
      ? 'stale'
      : status;
  String get label =>
      '$source → $destination: ${allow ? 'must respond' : 'must be blocked'}';
}

class ProjectChecks {
  final MemoryService memory;
  final String project;
  ProjectChecks(this.memory, this.project);
  static String storageKey(String project) =>
      'project-checks:${sha256.convert(utf8.encode(project))}';
  String get _key => storageKey(project);
  Future<List<ProjectCheck>> load() async {
    final raw = await memory.readPref(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((j) => ProjectCheck.fromJson(Map<String, dynamic>.from(j)))
        .toList();
  }

  Future<void> save(List<ProjectCheck> checks) async {
    if (!memory.ready) throw StateError('Local history is unavailable.');
    if (checks.length > 40) {
      throw ArgumentError('Use at most 40 checks per project.');
    }
    await memory.setPref(
      _key,
      jsonEncode(checks.map((c) => c.toJson()).toList()),
    );
  }

  static ProjectCheck create(
    NetworkIntent plan,
    String source,
    String destination, {
    bool allow = true,
  }) {
    if (source == destination ||
        !plan.nodes.any((n) => n.name == source) ||
        !plan.nodes.any((n) => n.name == destination)) {
      throw ArgumentError('Choose two different devices in this plan.');
    }
    return ProjectCheck(
      id: const Uuid().v4(),
      source: source,
      destination: destination,
      allow: allow,
    );
  }

  static String preview(ProjectCheck check, NetworkIntent plan) =>
      'Offline design assessment only; live result remains unverified.\n${TopologyReasoner.explain(plan: plan, from: check.source, to: check.destination, target: check.label).toText()}';
  static Map<String, dynamic> request(
    NetworkIntent plan,
    List<ProjectCheck> checks,
  ) => {
    ...plan.toPlannerJson(),
    'customChecks': checks.map((c) => c.toJson()).toList(),
  };
  static ProjectCheck applyReport(
    ProjectCheck check,
    NetworkIntent plan,
    Map<String, dynamic> report,
  ) {
    final rows = (report['tests'] as List? ?? []).whereType<Map>();
    final row = rows.where((r) => r['checkId'] == check.id).firstOrNull;
    var status = row == null || !check.allow
        ? 'manual'
        : '${row['status'] ?? 'unverified'}';
    final evidence = '${row?['evidence'] ?? row?['detail'] ?? ''}'.trim();
    if (status == 'passed' && evidence.isEmpty) status = 'unverified';
    return ProjectCheck(
      id: check.id,
      source: check.source,
      destination: check.destination,
      kind: check.kind,
      allow: check.allow,
      testedRevision: plan.revision,
      status: ['passed', 'failed', 'skipped', 'manual'].contains(status)
          ? status
          : 'unverified',
      evidence: !check.allow
          ? 'Confirm the policy with allowed and denied flows; a timeout alone proves no policy.'
          : evidence.isEmpty
          ? 'No matching live evidence was collected.'
          : evidence,
    );
  }
}
