import 'dart:convert';
import '../models/network_intent.dart';
import 'lab_catalog.dart';
import 'memory_service.dart';

class LabProgressService {
  final MemoryService memory;
  LabProgressService(this.memory);
  Future<Map<String, dynamic>?> load(String id) async {
    final lab = LabCatalog.byId(id);
    if (lab == null) return null;
    final raw = await memory.readPref('lab-progress:${lab.id}');
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw));
  }

  Future<void> record(
    GuidedLab lab,
    NetworkIntent plan, {
    int? buildId,
    bool hintUsed = false,
  }) async {
    if (!memory.ready) throw StateError('Local history is unavailable.');
    final previous = await load(lab.id) ?? {};
    final grade = LabGrader.grade(lab, plan);
    final attempts = [
      ...(previous['attempts'] as List? ?? []),
      {
        'revision': plan.revision,
        'passed': grade.passed,
        'total': grade.results.length,
        'at': DateTime.now().toUtc().toIso8601String(),
      },
    ];
    await memory.setPref(
      'lab-progress:${lab.id}',
      jsonEncode({
        'lab': lab.id,
        'project': plan.projectName,
        'plan': plan.toPlannerJson(),
        'buildId': ?buildId,
        'passed': grade.passed,
        'total': grade.results.length,
        'completedObjectives': [
          for (final r in grade.results)
            if (r.ok) r.step.title,
        ],
        'hintsUsed': (previous['hintsUsed'] as num? ?? 0) + (hintUsed ? 1 : 0),
        'attempts': attempts
            .skip(attempts.length > 20 ? attempts.length - 20 : 0)
            .toList(),
      }),
    );
  }
}
