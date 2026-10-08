import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The plan the chat shows must be the plan the conversation keeps.
///
/// The no-key path parses every turn twice: once in the send flow, and once
/// more inside the offline assistant, which is where the user's learned
/// rules are applied. The reply and the build card describe the second
/// parse - and the recorded plan stayed the FIRST one, so a reopened
/// conversation restored a different network than the one on screen: a
/// taught "always use OSPF" answered with an OSPF plan and then, after a
/// restart, rebuilt a static one. These tests drive the real screen over a
/// real store, and read the exact record the reopen path reads.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// main() is what installs the providers, and a widget test does not call
  /// it - so the providers are installed here, with the store the test owns.
  Widget app(MemoryService memory) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>(
            create: (_) => SettingsService(),
          ),
          ChangeNotifierProvider<MemoryService>.value(value: memory),
        ],
        child: const NetBuilderApp(),
      );

  /// Bounded pumping, never pumpAndSettle: with a real store behind it the
  /// screen always has one more scheduled frame (status chips, sidebar
  /// refreshes), and a settle that never ends is a timed-out test.
  ///
  /// Real async work (the store writes, the engine probe) only progresses
  /// when time is given back between pumps - and each store write needs its
  /// own window, in order, because every one of them is a round trip to the
  /// ffi isolate. A loaded machine makes each round trip slower, not
  /// optional, so the budget is generous: the property under test is the
  /// plan, never how fast the disk happened to be.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 32; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  /// Every direct store call in a widget test runs inside the test's fake
  /// async zone, where the ffi isolate's messages never arrive on their own
  /// - each one is given real time explicitly.
  Future<MemoryService> freshMemory(WidgetTester tester) async {
    MemoryService? memory;
    await tester.runAsync(() async {
      // A temp file, not ":memory:": sqflite returns the same cached
      // database for a repeated in-memory path, so a second test would try
      // to create the schema on a database that already has it.
      final dir = await Directory.systemTemp.createTemp('nb-plan-persist');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // A leftover temp directory is not worth failing a test over.
        }
      });
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/chat.db');
      await MemoryService.createSchema(db);
      memory = MemoryService(injected: db);
    });
    return memory!;
  }

  Future<NetworkIntent?> recordedPlan(
    WidgetTester tester,
    MemoryService memory,
  ) async {
    NetworkIntent? out;
    await tester.runAsync(() async {
      final meta = await memory.conversationMeta('default');
      final raw = (meta?['stateJson'] ?? '').toString();
      if (raw.isEmpty) return;
      final state = jsonDecode(raw) as Map<dynamic, dynamic>;
      final intentJson = (state['intentJson'] ?? '').toString();
      if (intentJson.isEmpty) return;
        out = NetworkIntent.fromJson(
          Map<String, dynamic>.from(jsonDecode(intentJson) as Map),
        );
    });
    return out;
  }

  Future<void> send(WidgetTester tester, String text) async {
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    await tester.enterText(composer, text);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester);
  }

  testWidgets('the offline answer shows and records the same plan',
      (tester) async {
    final memory = await freshMemory(tester);
    // A rule the user taught the app. The offline planner applies it to the
    // plan it answers with, so the recorded plan must carry it too.
    await tester.runAsync(() => memory.addRule('always use ospf'));
    await tester.pumpWidget(app(memory));
    await settle(tester);

    await send(tester, '2 routers and 4 switches');

    // The reply names the routing it planned: the taught rule applied to
    // the plan the user is looking at.
    expect(find.textContaining('routing: ospf'), findsWidgets);

    // The record the reopen path restores from (conversationMeta ->
    // stateJson -> intentJson -> NetworkIntent) is the SAME plan.
    final recorded = await recordedPlan(tester, memory);
    expect(recorded, isNotNull,
        reason: 'a planned turn must leave a plan behind');
    expect(recorded!.routing, 'ospf',
        reason: 'the plan the reply showed must be the plan that is kept - '
            'the first parse of the turn ran without the taught rule');
    expect(recorded.nodes.where((n) => n.type == 'router').length, 2);
    expect(recorded.nodes.where((n) => n.type == 'switch').length, 4);
  });

  testWidgets('without a taught rule the record still matches the reply',
      (tester) async {
    final memory = await freshMemory(tester);
    await tester.pumpWidget(app(memory));
    await settle(tester);

    await send(tester, '2 routers and 4 switches');

    final recorded = await recordedPlan(tester, memory);
    expect(recorded, isNotNull);
    // The control case: nothing learned, so the offline plan IS the first
    // parse and the record must not have drifted from it either way.
    expect(recorded!.routing, 'static');
    expect(recorded.nodes.where((n) => n.type == 'router').length, 2);
    expect(recorded.nodes.where((n) => n.type == 'switch').length, 4);
  });
}
