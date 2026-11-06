import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/request_interpretation.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/session_state.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PersistenceSettings extends SettingsService {
  _PersistenceSettings({required this.enabled});

  final bool enabled;

  @override
  Future<String?> getApiKey() async => enabled ? 'deterministic-test-key' : '';

  @override
  Future<String?> getOpenAiKey() async => '';
}

class _PersistenceProvider extends ProviderChatService {
  _PersistenceProvider({required this.fail})
    : super(
        config: const AiProviderConfig(
          kind: AiProviderKind.gemini,
          model: AiProviderConfig.defaultGeminiModel,
        ),
      );

  final bool fail;
  int calls = 0;

  @override
  Stream<String> stream({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async* {
    calls++;
    if (fail) throw StateError('synthetic provider failure');
    yield 'The persistence test provider answered.';
  }
}

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
      ChangeNotifierProvider<SettingsService>(create: (_) => SettingsService()),
      ChangeNotifierProvider<MemoryService>.value(value: memory),
    ],
    child: const NetBuilderApp(),
  );

  Widget chatApp(
    MemoryService memory, {
    required bool providerEnabled,
    _PersistenceProvider? provider,
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsService>.value(
        value: _PersistenceSettings(enabled: providerEnabled),
      ),
      ChangeNotifierProvider<MemoryService>.value(value: memory),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          initialProject: 'default',
          providerChatServiceOverride: provider,
        ),
      ),
    ),
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

  Future<RequestOutcome?> recordedOutcome(
    WidgetTester tester,
    MemoryService memory,
  ) async {
    RequestOutcome? out;
    await tester.runAsync(() async {
      final meta = await memory.conversationMeta('default');
      final raw = (meta?['stateJson'] ?? '').toString();
      if (raw.isEmpty) return;
      final state = jsonDecode(raw) as Map<dynamic, dynamic>;
      final outcomeJson = (state['requestOutcomeJson'] ?? '').toString();
      if (outcomeJson.isEmpty) return;
      out = RequestOutcome.fromJson(jsonDecode(outcomeJson));
    });
    return out;
  }

  Future<SessionState?> recordedState(
    WidgetTester tester,
    MemoryService memory,
  ) async {
    SessionState? out;
    await tester.runAsync(() async {
      final meta = await memory.conversationMeta('default');
      final raw = (meta?['stateJson'] ?? '').toString();
      if (raw.isNotEmpty) out = SessionState.decode(raw);
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

  testWidgets('the offline answer shows and records the same plan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(
      recorded,
      isNotNull,
      reason: 'a planned turn must leave a plan behind',
    );
    expect(
      recorded!.routing,
      'ospf',
      reason:
          'the plan the reply showed must be the plan that is kept - '
          'the first parse of the turn ran without the taught rule',
    );
    expect(recorded.nodes.where((n) => n.type == 'router').length, 2);
    expect(recorded.nodes.where((n) => n.type == 'switch').length, 4);
    final outcome = await recordedOutcome(tester, memory);
    expect(outcome, isNotNull);
    expect(outcome!.disposition, RequestDisposition.commit);
    expect(outcome.candidatePlan?.revision, recorded.revision);

    // Restart the actual chat widget over the same database. The inspector
    // reads ChatScreen's reopened SessionState, so this verifies the UI loaded
    // the persisted plan instead of merely finding it through a store query.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(app(memory));
    await settle(tester);
    await tester.tap(find.byTooltip('Show the network inspector'));
    await settle(tester);
    expect(find.text('Network inspector'), findsOneWidget);
    expect(find.text('DEVICES (6)'), findsOneWidget);
    expect(find.text('R1'), findsOneWidget);
    expect(find.text('SW4'), findsOneWidget);
    expect(find.text('ospf'), findsWidgets);
  });

  testWidgets('without a taught rule the record still matches the reply', (
    tester,
  ) async {
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
    final outcome = await recordedOutcome(tester, memory);
    expect(outcome, isNotNull);
    expect(outcome!.candidatePlan?.revision, recorded.revision);
  });

  testWidgets('A38 reopened pending state retains the OSPF answer only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final memory = await freshMemory(tester);
    await tester.pumpWidget(chatApp(memory, providerEnabled: false));
    await settle(tester);

    await send(tester, '2 routers and 4 switches');
    final beforeAnswer = await recordedState(tester, memory);
    expect(beforeAnswer, isNotNull);
    expect(beforeAnswer!.pendingQuestionIds, contains('routing'));
    expect(beforeAnswer.pendingQuestionIds, contains('scale'));
    final originalPlan = await recordedPlan(tester, memory);
    expect(originalPlan, isNotNull);
    await send(tester, 'OSPF');
    final afterAnswer = await recordedState(tester, memory);
    expect(afterAnswer, isNotNull);
    expect(afterAnswer!.pendingQuestionIds, contains('scale'));
    expect(afterAnswer.pendingQuestionIds, isNot(contains('routing')));
    final answeredPlan = await recordedPlan(tester, memory);
    final answeredOutcome = await recordedOutcome(tester, memory);
    expect(answeredPlan, isNotNull);
    expect(answeredPlan!.routing, 'ospf');
    expect(answeredOutcome, isNotNull);
    final answeredBrief = DesignBrief.fromJson(
      jsonDecode(afterAnswer.briefJson),
    );
    expect(answeredBrief.value(DesignBrief.routing), 'ospf');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(chatApp(memory, providerEnabled: false));
    await settle(tester);

    final reopenedState = await recordedState(tester, memory);
    final reopenedPlan = await recordedPlan(tester, memory);
    final reopenedOutcome = await recordedOutcome(tester, memory);
    expect(reopenedState, isNotNull);
    expect(reopenedState!.intentJson, afterAnswer.intentJson);
    expect(reopenedState.briefJson, afterAnswer.briefJson);
    expect(reopenedState.requestOutcomeJson, afterAnswer.requestOutcomeJson);
    expect(reopenedState.pendingQuestionIds, afterAnswer.pendingQuestionIds);
    expect(
      reopenedState.pendingQuestionContexts
          .map((context) => context.toJson())
          .toList(),
      afterAnswer.pendingQuestionContexts
          .map((context) => context.toJson())
          .toList(),
    );
    expect(reopenedPlan!.toPlannerJson(), answeredPlan.toPlannerJson());
    expect(reopenedPlan.routing, 'ospf');
    final reopenedBrief = DesignBrief.fromJson(
      jsonDecode(reopenedState.briefJson),
    );
    expect(reopenedBrief.toJson(), answeredBrief.toJson());
    expect(
      reopenedOutcome!.interpretation.toJson(),
      answeredOutcome!.interpretation.toJson(),
    );
    expect(
      await tester.runAsync(memory.clarificationAnswers),
      isEmpty,
      reason: 'one local answer must not become a global preference',
    );
  });

  testWidgets(
    'T08 offline, provider, and fallback snapshots persist and reopen identically',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 950);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final snapshots = <String>[];
      for (final mode in ['offline', 'provider', 'fallback']) {
        final memory = await freshMemory(tester);
        final provider = mode == 'offline'
            ? null
            : _PersistenceProvider(fail: mode == 'fallback');
        await tester.pumpWidget(
          chatApp(
            memory,
            providerEnabled: mode != 'offline',
            provider: provider,
          ),
        );
        await settle(tester);
        await send(tester, '2 routers and 4 switches');

        if (mode == 'offline') {
          expect(provider, isNull);
        } else {
          expect(provider!.calls, 1, reason: '$mode mode calls once');
        }
        final committed = await recordedPlan(tester, memory);
        final outcome = await recordedOutcome(tester, memory);
        expect(committed, isNotNull, reason: '$mode commits a plan');
        expect(outcome, isNotNull, reason: '$mode stores its request outcome');
        expect(outcome!.candidatePlan?.revision, committed!.revision);
        expect(outcome.disposition, RequestDisposition.commit);
        expect(
          committed.nodes.where((node) => node.type == 'router'),
          hasLength(2),
        );
        expect(
          committed.nodes.where((node) => node.type == 'switch'),
          hasLength(4),
        );
        snapshots.add(jsonEncode(committed.toPlannerJson()));

        // Mount a new ChatScreen over the same SQLite database and verify the
        // state consumed by the reopen path, not just the record queried above.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          chatApp(
            memory,
            providerEnabled: mode != 'offline',
            provider: provider,
          ),
        );
        await settle(tester);
        await tester.tap(find.byTooltip('Show the network inspector'));
        await settle(tester);
        expect(find.text('Network inspector'), findsOneWidget);
        expect(find.text('DEVICES (6)'), findsOneWidget);
        expect(find.text('R1'), findsOneWidget);
        expect(find.text('SW4'), findsOneWidget);
        expect(find.text('static'), findsWidgets);

        final reopened = await recordedPlan(tester, memory);
        final reopenedOutcome = await recordedOutcome(tester, memory);
        expect(reopened, isNotNull);
        expect(reopened!.toPlannerJson(), committed.toPlannerJson());
        expect(reopenedOutcome?.candidatePlan?.revision, reopened.revision);
        expect(reopenedOutcome?.disposition, RequestDisposition.commit);
        await tester.pumpWidget(const SizedBox.shrink());
      }

      expect(snapshots.toSet(), hasLength(1));
    },
  );
}
