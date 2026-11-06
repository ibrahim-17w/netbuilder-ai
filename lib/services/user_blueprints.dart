import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import 'memory_service.dart';
import 'stored_privacy.dart';

/// User templates contain design data only. Each use starts independent history.
class UserBlueprints {
  static const storageKey = 'user-blueprints-v1';
  final MemoryService memory;
  UserBlueprints(this.memory);

  Future<List<Map<String, dynamic>>> all() async {
    final raw = await memory.readPref(storageKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _write(List<Map<String, dynamic>> rows) async {
    if (!memory.ready) throw StateError('Local history is unavailable.');
    await memory.setPref(storageKey, jsonEncode(StoredPrivacy.redact(rows)));
  }

  Future<void> save(
    NetworkIntent plan, {
    required String name,
    String description = '',
    String tags = '',
    String? id,
  }) async {
    if (name.trim().isEmpty) {
      throw const FormatException('Enter a blueprint name.');
    }
    final rows = await all();
    final key = id ?? const Uuid().v4();
    rows.removeWhere((r) => r['id'] == key);
    rows.add(
      StoredPrivacy.row({
        'id': key,
        'name': name.trim(),
        'description': description.trim(),
        'tags': tags.trim(),
        'plan': plan.toPlannerJson(),
      }),
    );
    await _write(rows);
  }

  Future<void> remove(String id) async =>
      _write((await all())..removeWhere((r) => r['id'] == id));

  Future<BuildRecord> instantiate(
    Map<String, dynamic> blueprint,
    String name,
  ) async {
    if (!memory.ready) throw StateError('Local history is unavailable.');
    if (name.trim().isEmpty) {
      throw const FormatException('Enter a project name.');
    }
    final key = const Uuid().v4();
    final json = StoredPrivacy.row(
      Map<String, dynamic>.from(blueprint['plan'] as Map),
    );
    // Distinct names also prevent the credential vault from reusing source keys.
    json['projectName'] = '${name.trim()}-${key.substring(0, 8)}';
    final plan = NetworkIntent.fromJson(json);
    final row = BuildRecord(
      projectName: plan.projectName,
      projectKey: key,
      instruction: 'From blueprint: ${blueprint['name']}',
      intentJson: jsonEncode(plan.toPlannerJson()),
      target: 'packet-tracer',
      success: false,
      status: 'planned',
      createdAt: DateTime.now(),
    );
    final id = await memory.logBuild(row);
    return BuildRecord.fromMap({...row.toMap(), 'id': id});
  }
}
