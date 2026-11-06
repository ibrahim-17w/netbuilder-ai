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

  test(
    'pasted diagnostics saved with target all never steer a plan',
    () async {
      final mem = await fresh();
      // Verbatim shapes found steering a real brief: a failure narrative
      // whose "base 2-device topology" set every later brief's scale to 2,
      // a preflight dump, and a definitions paragraph.
      await mem.addRule(
        'The built file only generated a base 2-device topology (R1 and '
        'SW1), missing SW2, the end-user PCs, and the subinterfaces for '
        'VLAN routing. To complete the topology to match the full design, '
        'perform these steps in Packet Tracer: 1.',
        targets: 'all',
      );
      await mem.addRule(
        '**Preflight (checked before compiling)** - Target: Packet Tracer '
        '- offline compile; no Packet Tracer window is opened and nothing '
        'is typed anywhere. - Plan: 50 device(s) (3 routers, 3 switches, '
        '40 PCs, 4 servers); routing ospf; 49 link(s).',
        targets: 'all',
      );
      await mem.addRule(
        'An IP address (Internet Protocol address) is a unique numerical '
        'label assigned to every device on a network to identify it and '
        'allow data to be routed to and from it. Here is how IP addressing '
        'works in practice.',
        targets: 'all',
      );
      // A short directive the user actually taught still passes.
      await mem.addRule('always add a DNS server', targets: 'all');

      final rules = await mem.plannerRuleTexts();
      expect(rules, ['always add a DNS server']);
    },
  );
}
