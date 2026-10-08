import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/services/plan_repair_service.dart';
import 'package:net_builder/services/repair_learning_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the repair pass is allowed to teach, and when.
///
/// The repair pass fixes real defects, so it is the app's best source of
/// rules about its own output. It is also the easiest place to teach itself
/// something wrong: a fix that looks right on paper and then fails to build
/// would, if promoted on the strength of having run, become a rule that steers
/// every later plan into the same failure.
///
/// These tests pin the half that matters: parking teaches nothing, a verified
/// build promotes, a failed build promotes nothing and leaves no trace, and
/// what gets promoted is a positive rule rather than one network's numbers.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-repair-learn');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/m.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  /// A plan with two interfaces claiming one address - the finding the
  /// deterministic pass actually fixes.
  NetworkIntent clashing() => NetworkIntent(
        projectName: 'office',
        routing: 'ospf',
        nodes: [
          NetNode(name: 'R1', type: 'router', model: '4331'),
          NetNode(name: 'SW1', type: 'switch', model: '2960'),
          NetNode(name: 'PC1', type: 'pc', model: 'pc'),
        ],
        links: [
          NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
          NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
        ],
        addressing: [
          InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
          InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.1.1/24'),
        ],
      );

  /// Park the rules a repair of [plan] would teach, the way the chat does,
  /// and return the plan that would actually be built afterwards.
  Future<NetworkIntent> park(MemoryService mem, NetworkIntent plan) async {
    final reply = OfflineAssistantService.fixPlan(
      plan: plan,
      target: 'packet-tracer',
    );
    final repaired = reply.repairedPlan;
    expect(repaired, isNotNull);
    await mem.noteRepairedPlan(
      plan: repaired!,
      fixes: reply.repairedFixes,
      target: 'packet-tracer',
    );
    return repaired;
  }

  Future<int> logAndSettle(
    MemoryService mem,
    NetworkIntent plan, {
    required bool verified,
  }) async {
    final id = await mem.logBuild(
      BuildRecord(
        projectName: plan.projectName,
        instruction: 'office network',
        intentJson:
            // Exactly what a build card stores, so the round trip through the
            // database is part of what is under test.
            jsonEncode(plan.toJson(includeSecrets: false)),
        target: 'packet-tracer',
        status: verified ? 'verified' : 'failed',
        success: verified,
        createdAt: DateTime.now(),
      ),
    );
    await mem.updateBuildOutcome(
      id: id,
      success: verified,
      status: verified ? 'verified' : 'failed',
      error: verified ? null : 'device never came up',
    );
    return id;
  }

  test('the repair pass states what it fixed, in rules a plan can use', () {
    final repair = PlanRepairService.repair(clashing(), target: 'packet-tracer');
    expect(repair.changed, isTrue);
    // Every change can say its own rule: a change the app cannot generalise
    // is a change it must not learn from.
    expect(repair.fixes, isNotEmpty);
    for (final fix in repair.fixes) {
      expect(fix.kind, isNotEmpty);
      expect(fix.rule, isNotEmpty);
      // A rule names the class of problem, never this plan's own values -
      // otherwise it teaches the next network to copy this one's addresses.
      expect(fix.rule, isNot(contains('192.168.1.1')));
      expect(fix.rule, isNot(contains('office')));
      expect(fix.rule, isNot(contains('PC1')));
    }
  });

  test('a parked repair teaches nothing until a build verifies', () async {
    final mem = await fresh();
    await park(mem, clashing());
    expect(await mem.allRules(), isEmpty,
        reason: 'parking is not promotion');
    expect(await mem.plannerRuleTexts(), isEmpty,
        reason: 'and nothing a planner reads may exist yet');
  });

  test('a verified build promotes the repair into rules a planner reads',
      () async {
    final mem = await fresh();
    final repaired = await park(mem, clashing());
    await logAndSettle(mem, repaired, verified: true);
    final rules = await mem.plannerRuleTexts();
    expect(rules, isNotEmpty);
    for (final rule in rules) {
      expect(rule, isNot(contains('192.168.1.1')));
      expect(rule.toLowerCase(), isNot(contains('failed')));
    }
    // Scoped to the target it was learned for, like every other rule.
    for (final row in await mem.allRules()) {
      expect(row.targets, 'packet-tracer');
    }
  });

  test('a failed build promotes nothing and leaves no trace', () async {
    final mem = await fresh();
    final repaired = await park(mem, clashing());
    await logAndSettle(mem, repaired, verified: false);
    expect(await mem.allRules(), isEmpty);
    // The candidate is spent, not retried: a build that failed must not leave
    // a rule waiting for the next build to promote it on the strength of the
    // same repair.
    final id = await logAndSettle(mem, repaired, verified: true);
    expect(id, greaterThan(0));
    expect(await mem.allRules(), isEmpty);
  });

  test('only the build of the repaired plan promotes its rules', () async {
    final mem = await fresh();
    final repaired = await park(mem, clashing());
    // A different network, built and verified: proof about another plan is not
    // proof about this one.
    final other = NetworkIntent(
      projectName: 'branch',
      routing: 'static',
      nodes: [NetNode(name: 'R9', type: 'router', model: '4331')],
    );
    await logAndSettle(mem, other, verified: true);
    expect(await mem.allRules(), isEmpty);
    await logAndSettle(mem, repaired, verified: true);
    expect(await mem.plannerRuleTexts(), isNotEmpty);
  });

  test('one rule is taught once, however many builds prove it', () async {
    final mem = await fresh();
    final repaired = await park(mem, clashing());
    await logAndSettle(mem, repaired, verified: true);
    final first = (await mem.allRules()).length;
    expect(first, greaterThan(0));
    await park(mem, clashing());
    await logAndSettle(mem, repaired, verified: true);
    expect((await mem.allRules()).length, first,
        reason: 'the same lesson repeated is not a second lesson');
  });

  test('a plan is identified by its shape, not by its bookkeeping', () {
    final plan = clashing();
    final stored = plan.toJson(includeSecrets: false);
    final rebuilt = NetworkIntent.fromJson(
      // The same topology re-read from storage with bookkeeping the first
      // copy did not carry.
      Map<String, dynamic>.from(stored)
        ..['revision'] = 9
        ..['confidence'] = 0.1
        ..['notes'] = ['later'],
    );
    expect(RepairLearning.fingerprint(rebuilt),
        RepairLearning.fingerprint(plan));
    // A real change of shape is a different plan.
    final moved = NetworkIntent(
      projectName: plan.projectName,
      routing: plan.routing,
      nodes: plan.nodes,
      links: [
        NetLink(a: 'R1', aIf: 'g0/1', b: 'SW1', bIf: 'f0/1'),
        plan.links[1],
      ],
      addressing: plan.addressing,
    );
    expect(RepairLearning.fingerprint(moved),
        isNot(RepairLearning.fingerprint(plan)));
  });

  test('candidate rules are bounded and de-duplicated', () {
    final many = [
      for (var i = 0; i < 20; i++) RepairFix('k$i', 'rule $i'),
      const RepairFix('k1', 'rule 1'),
    ];
    final rules = RepairLearning.rulesFrom(many);
    expect(rules.length, RepairLearning.maxRules);
    expect(rules.toSet().length, rules.length);
  });
}