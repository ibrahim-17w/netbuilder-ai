import '../models/network_intent.dart';
import 'plan_repair_service.dart';

/// What a repair pass is allowed to teach, and how a later build proves it.
///
/// The repair pass knows something the planner did not: it found a finding in
/// a real plan and resolved it deterministically. That is worth learning - but
/// only once the repaired plan has actually BUILT. A repair that "worked" on
/// paper teaches nothing, and a repair whose build failed must teach nothing
/// at all, because the rule it suggests may be exactly what broke it.
///
/// So the loop has two halves and no shortcut between them:
///
/// * [note] parks the candidate rules next to a fingerprint of the repaired
///   plan, with no power of its own;
/// * [confirm] is the only thing that promotes them, and only for a plan that
///   came back verified.
///
/// The rules themselves are positive and self-contained (see [RepairFix]) so
/// that promoting one teaches every later plan to do the thing properly,
/// instead of copying one network's addresses.
class RepairLearning {
  const RepairLearning._();

  /// How many plans may have parked candidates at once. Oldest are dropped:
  /// a candidate nobody ever built is not a lesson, it is litter.
  static const maxCandidates = 8;

  /// How many rules one repair may contribute. The pass is ordered by finding
  /// severity, so the first ones are the ones worth remembering.
  static const maxRules = 5;

  /// A stable id for one plan's SHAPE.
  ///
  /// Two plans are "the same repaired plan" when they would produce the same
  /// topology: same project, same devices, same cabling, same addressing.
  /// Everything else (revision numbers, notes, confidence, layout, questions)
  /// is deliberately excluded, because those differ between the copy that was
  /// repaired and the copy that was finally built without meaning the
  /// learning no longer applies.
  static String fingerprint(NetworkIntent plan) {
    final nodes = [
      for (final n in plan.nodes)
        '${n.name.toLowerCase()}:${n.type.toLowerCase()}:${n.model}',
    ]..sort();
    final links = [
      for (final l in plan.links)
        '${l.a.toLowerCase()}:${l.aIf.toLowerCase()}-'
            '${l.b.toLowerCase()}:${l.bIf.toLowerCase()}',
    ]..sort();
    final addresses = [
      for (final a in plan.addressing)
        '${a.node.toLowerCase()}:${a.iface.toLowerCase()}:${a.ipCidr}',
    ]..sort();
    return [
      plan.projectName.trim().toLowerCase(),
      plan.routing,
      nodes.join(','),
      links.join(','),
      addresses.join(','),
    ].join('|');
  }

  /// The rules a repair is allowed to offer, in order, de-duplicated by text
  /// and bounded by [maxRules].
  static List<String> rulesFrom(List<RepairFix> fixes) {
    final out = <String>[];
    for (final fix in fixes) {
      final rule = fix.rule.trim();
      if (rule.isEmpty) continue;
      if (out.any((r) => r.toLowerCase() == rule.toLowerCase())) continue;
      out.add(rule);
      if (out.length >= maxRules) break;
    }
    return out;
  }
}