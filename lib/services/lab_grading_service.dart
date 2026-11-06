import '../models/network_intent.dart';
import 'lab_catalog.dart';
import 'lab_objectives.dart';
export 'lab_objectives.dart' show LabCheckResult;

class LabGradingService {
  const LabGradingService._();
  static List<LabCheckResult> grade(String id, NetworkIntent plan) {
    final lab = LabCatalog.byId(id);
    if (lab == null) return const [];
    return [
      for (final r in LabGrader.grade(lab, plan).results)
        LabCheckResult(label: r.step.title, hint: r.remedy ?? '', passed: r.ok),
    ];
  }
}
