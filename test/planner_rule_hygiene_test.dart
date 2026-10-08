import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/planner_memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The Memory screen files the sidecar's journal advice (the `/suggest`
/// `suggestions` strings) as rules with an `autopilot` target. That text is
/// troubleshooting prose for a human, not a rule the user taught - and feeding
/// it to the planner silently rewrote later keyless plans, because a sentence
/// that merely *mentions* OSPF matched the free-text rule reader and flipped
/// routing to OSPF. These tests pin the separation: advice stays reviewable in
/// `allRules()` but never reaches a planner or a model prompt.
void main() {
  // Verbatim string produced by pt_autopilot.journal_suggestions() after a
  // failed ping test, the exact shape the Memory screen auto-saves.
  const journalAdvice =
      'Ping tests failed - check PC IPs '
      '(Desktop > IP Configuration) and that OSPF is advertised for both LANs.';

  const taughtRule = 'always use OSPF for the LANs';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-planner-rule-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/rules.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  NetworkIntent plan() =>
      NetworkIntent.parseSimple('Office', '10 PCs, 1 router, 1 switch');

  test('the advice string would mis-plan if it were fed as a rule', () {
    // The demonstration that motivates the filter: the raw advice sentence
    // matches PlannerMemoryService and rewrites routing all by itself.
    final contaminated = PlannerMemoryService.apply(
      plan(),
      rules: const [journalAdvice],
    );
    expect(contaminated.routing, 'ospf');
  });

  test('advice stored with an autopilot target never steers a plan', () async {
    final mem = await fresh();
    await mem.addRule(journalAdvice, targets: 'autopilot');

    expect(await mem.plannerRuleTexts(), isEmpty);

    final base = plan();
    final applied = PlannerMemoryService.apply(
      base,
      rules: await mem.plannerRuleTexts(),
    );
    expect(applied.routing, base.routing);
  });

  test('a user-taught rule still steers the keyless plan', () async {
    final mem = await fresh();
    await mem.addRule(journalAdvice, targets: 'autopilot');
    await mem.addRule(taughtRule, targets: 'all');
    await mem.addRule('use a 4331 router', targets: 'gns3,cisco');

    final rules = await mem.plannerRuleTexts();
    expect(rules, contains(taughtRule));
    expect(rules, contains('use a 4331 router'));
    expect(rules, isNot(contains(journalAdvice)));

    final applied = PlannerMemoryService.apply(plan(), rules: rules);
    expect(applied.routing, 'ospf');
  });

  test('legacy and multi-target advice rows are excluded too', () async {
    final mem = await fresh();
    // Older saves wrote the bare 'autopilot' target; a csv that mixes targets
    // or differs in case must not sneak advice back into the planner.
    await mem.addRule('advice one', targets: 'autopilot');
    await mem.addRule('advice two', targets: 'all,autopilot');
    await mem.addRule('advice three', targets: 'Autopilot');

    expect(await mem.plannerRuleTexts(), isEmpty);
  });

  test('journal advice stays listed for review and deletion', () async {
    final mem = await fresh();
    await mem.addRule(journalAdvice, targets: 'autopilot');
    await mem.addRule(taughtRule, targets: 'all');

    final all = (await mem.allRules()).map((r) => r.ruleText).toList();
    expect(all, contains(journalAdvice));
    expect(all, contains(taughtRule));
  });
}
