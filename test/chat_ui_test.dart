import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/environment_profile.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/request_interpretation.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/screens/layout_gallery_screen.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/layout_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/request_understanding/request_route_selector.dart';
import 'package:net_builder/services/session_state.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/services/validator_service.dart';
import 'package:net_builder/widgets/chat_activity.dart';
import 'package:net_builder/widgets/conversation_sidebar.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'request_understanding/fixtures.dart';

/// The chat surface, at the level a person sees it: a list of conversations
/// beside the chat, a welcome screen instead of a blank box, real activity, and
/// a network panel that can be opened and closed.
///
/// The store here is a stand-in rather than a database on purpose: a widget
/// test drives the tree, and the storage itself (titles, summaries, the change
/// log) is covered against the real schema in conversation_store_test.dart.
class _FakeSettings extends SettingsService {
  _FakeSettings({this.geminiKey = ''});

  final String geminiKey;

  @override
  Future<String?> getApiKey() async => geminiKey;
  @override
  Future<String?> getOpenAiKey() async => '';

  /// Targets are stored in SharedPreferences, which a widget test does not
  /// have; the command's behaviour is that it ASKS to switch and says so.
  String? lastTarget;
  @override
  Future<void> setDefaultTarget(String v) async {
    lastTarget = v;
  }

  /// A widget test cannot reach the private field behind `privateMode`, and
  /// it must not need a real key: the point is the branch, not the storage.
  @visibleForTesting
  void setPrivateForTest(bool value) => _privateModeOverride = value;

  bool? _privateModeOverride;

  @override
  bool get privateMode => _privateModeOverride ?? super.privateMode;
}

class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this.documentsDirectory);

  final String documentsDirectory;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsDirectory;
}

class _DeterministicProviderChatService extends ProviderChatService {
  _DeterministicProviderChatService({
    this.fail = false,
    this.failure,
    this.started = const [],
    this.release = const [],
  }) : super(
         config: const AiProviderConfig(
           kind: AiProviderKind.gemini,
           model: AiProviderConfig.defaultGeminiModel,
         ),
       );

  final bool fail;
  final Object? failure;
  final List<Completer<void>> started;
  final List<Completer<void>> release;
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
    final callIndex = calls++;
    if (callIndex < started.length && !started[callIndex].isCompleted) {
      started[callIndex].complete();
    }
    if (callIndex < release.length) await release[callIndex].future;
    if (fail || failure != null) {
      throw failure ?? StateError('synthetic provider failure');
    }
    yield callIndex == 0
        ? 'The deterministic provider answered.'
        : 'The deterministic provider answered call ${callIndex + 1}.';
  }
}

class _FakeStore extends MemoryService {
  final Map<String, List<ChatMessage>> transcripts;
  final Map<String, String> titles;
  final Map<String, String> projects;

  _FakeStore({
    required this.transcripts,
    Map<String, String>? titles,
    Map<String, String>? projects,
    this.stateJson = '{}',
  }) : titles = titles ?? {},
       projects = projects ?? {};

  final String stateJson;

  @override
  bool get ready => true;

  @override
  Future<List<ChatMessage>> recentChat({
    int limit = 60,
    String conversation = '',
  }) async => transcripts[conversation] ?? const [];

  @override
  Future<List<Map<String, dynamic>>> conversations({
    int limit = 200,
    String query = '',
  }) async {
    final q = query.trim().toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final entry in transcripts.entries) {
      final title = (titles[entry.key] ?? '').toLowerCase();
      final body = entry.value.map((m) => m.text.toLowerCase()).join(' ');
      if (q.isNotEmpty && !title.contains(q) && !body.contains(q)) continue;
      // The store stamps a conversation with the time of its last turn; the
      // sidebar groups on that, so the fake derives it from the transcript.
      final last = entry.value.isEmpty ? null : entry.value.last.createdAt;
      final at = last == null ? DateTime.now() : DateTime.parse(last);
      out.add({
        'id': entry.key,
        'title': titles[entry.key] ?? entry.value.first.text,
        'messages': entry.value.length,
        'project': projects[entry.key] ?? '',
        'summary': '',
        'updatedAt': at.toIso8601String(),
        'at': at.millisecondsSinceEpoch,
      });
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>?> conversationMeta(String id) async => {
    'id': id,
    'title': titles[id] ?? '',
    'project': projects[id] ?? '',
    'summary': '',
    'stateJson': stateJson,
  };

  @override
  Future<void> renameConversation(String id, String title) async {
    titles[id] = title;
  }

  @override
  Future<void> clearChat({String conversation = ''}) async {
    // Real semantics, deliberately: an empty id means EVERY conversation. A fake
    // that only dropped the one key hid the bug where clearing a single chat
    // wiped the whole app.
    cleared.add(conversation);
    if (conversation.isEmpty) {
      transcripts.clear();
      titles.clear();
      return;
    }
    transcripts.remove(conversation);
    titles.remove(conversation);
  }

  /// Every conversation id that was cleared, in order.
  final List<String> cleared = <String>[];

  /// Everything the screen has written down. The offline path used to keep its
  /// answers on screen only, so this is what catches that coming back.
  final List<ChatMessage> logged = <ChatMessage>[];
  Completer<void>? userLogStarted;
  Completer<int>? delayedUserLog;
  bool failNextUserLogSave = false;
  bool failNextModelLogSave = false;

  @override
  Future<int> logChat(
    ChatMessage message, {
    String conversation = 'default',
  }) async {
    if (message.role == 'user' && failNextUserLogSave) {
      failNextUserLogSave = false;
      throw StateError('synthetic user transcript failure');
    }
    if (message.role == 'model' && failNextModelLogSave) {
      failNextModelLogSave = false;
      throw StateError('synthetic model transcript failure');
    }
    final gate = delayedUserLog;
    if (message.role == 'user' && gate != null) {
      delayedUserLog = null;
      final started = userLogStarted;
      if (started != null && !started.isCompleted) started.complete();
      final id = await gate.future;
      logged.add(message);
      return id;
    }
    logged.add(message);
    return logged.length;
  }

  @override
  Future<void> ensureConversation(
    String id, {
    String project = '',
    String title = '',
  }) async {}

  @override
  Future<BuildRecord?> latestBuildNamed(String name) async => null;

  @override
  Future<int> logBuild(BuildRecord record) async => 1;

  String? savedState;
  bool failNextSessionStateSave = false;
  int? failSessionStateOnAttempt;
  int sessionStateSaveAttempts = 0;
  bool failRoutingOspfTransitionSave = false;
  Completer<void>? sessionStateSaveStarted;
  Completer<void>? delayedSessionStateSave;
  int sessionStateWrites = 0;
  int rememberedClarificationWrites = 0;
  final rememberedClarifications =
      <({String questionId, String answer, String venue, int scale})>[];
  EnvironmentProfile? rememberedProfile;

  @override
  Future<void> setSessionState(String id, String stateJson) async {
    sessionStateSaveAttempts++;
    if (failNextSessionStateSave) {
      failNextSessionStateSave = false;
      throw StateError('synthetic state save failure');
    }
    if (failSessionStateOnAttempt == sessionStateSaveAttempts) {
      failSessionStateOnAttempt = null;
      throw StateError('synthetic state save failure on selected attempt');
    }
    if (failRoutingOspfTransitionSave) {
      final candidate = SessionState.decode(stateJson);
      final candidatePlan = NetworkIntent.fromJson(
        jsonDecode(candidate.intentJson),
      );
      if (candidatePlan.routing.toLowerCase() == 'ospf' &&
          !candidate.pendingQuestionIds.contains('routing')) {
        failRoutingOspfTransitionSave = false;
        throw StateError('synthetic candidate state save failure');
      }
    }
    sessionStateWrites++;
    final gate = delayedSessionStateSave;
    if (gate != null) {
      delayedSessionStateSave = null;
      final started = sessionStateSaveStarted;
      if (started != null && !started.isCompleted) started.complete();
      await gate.future;
    }
    savedState = stateJson;
  }

  @override
  Future<void> rememberClarification(
    String questionId,
    String answer, {
    String venue = '',
    int scale = 0,
  }) async {
    rememberedClarificationWrites++;
    rememberedClarifications.add((
      questionId: questionId,
      answer: answer,
      venue: venue,
      scale: scale,
    ));
  }

  @override
  Future<EnvironmentProfile?> environmentProfile() async => rememberedProfile;

  @override
  Future<List<Map<String, dynamic>>> clarificationAnswers() async => [
    for (final answer in rememberedClarifications)
      {
        'question_id': answer.questionId,
        'answer': answer.answer,
        'venue': answer.venue,
        'scale': answer.scale,
      },
  ];

  @override
  Future<String?> answerForClarification(
    String questionId,
    EnvironmentProfile? profile,
  ) async {
    final venue = profile?.venue ?? '';
    String? global;
    for (final answer in rememberedClarifications.reversed) {
      if (answer.questionId != questionId) continue;
      if (venue.isNotEmpty && answer.venue == venue) return answer.answer;
      if (answer.venue.isEmpty) global ??= answer.answer;
    }
    return global;
  }

  @override
  Future<void> setConversationSummary(
    String id,
    String summary, {
    int upToId = 0,
  }) async {}

  @override
  Future<void> updateChat(int id, ChatMessage message) async {}

  /// Every history rewrite the screen asked for, in order: the store side of
  /// "Answer again" and "Edit and resend".
  final List<
    ({String conversation, int? fromId, String fromRole, String fromText})
  >
  truncations =
      <
        ({String conversation, int? fromId, String fromRole, String fromText})
      >[];

  @override
  Future<int> deleteChatFrom(
    String conversation, {
    int? fromId,
    String fromCreatedAt = '',
    String fromRole = '',
    String fromText = '',
  }) async {
    truncations.add((
      conversation: conversation,
      fromId: fromId,
      fromRole: fromRole,
      fromText: fromText,
    ));
    // The real store's semantics, mirrored on the fake: everything FROM the
    // anchor onward goes, so a test can see the screen and the store agree.
    final transcript = transcripts[conversation];
    if (transcript == null) return 0;
    var anchor = -1;
    for (var i = 0; i < transcript.length; i++) {
      final m = transcript[i];
      final matched =
          (fromId != null && m.id == fromId) ||
          (fromId == null &&
              m.createdAt == fromCreatedAt &&
              m.role == fromRole &&
              m.text == fromText);
      if (matched) {
        anchor = i;
        break;
      }
    }
    if (anchor < 0) return 0;
    final removed = transcript.length - anchor;
    transcripts[conversation] = transcript.sublist(0, anchor);
    return removed;
  }

  @override
  Future<int?> replaceChatMessage({
    required String conversation,
    required ChatMessage previous,
    required ChatMessage replacement,
  }) async {
    final transcript = transcripts[conversation];
    if (transcript == null) return null;
    final index = transcript.indexWhere(
      (message) =>
          (previous.id != null && message.id == previous.id) ||
          (previous.id == null &&
              message.createdAt == previous.createdAt &&
              message.role == previous.role &&
              message.text == previous.text),
    );
    if (index < 0) return null;
    final id = previous.id ?? index + 1;
    transcript[index] = replacement.copyWith(id: id);
    logged.add(replacement);
    return id;
  }

  @override
  Future<List<Map<String, dynamic>>> recentChanges({
    String conversation = '',
    String device = '',
    int limit = 50,
  }) async => const [];
}

ChatMessage _turn(String role, String text, {DateTime? at}) => ChatMessage(
  role: role,
  text: text,
  createdAt: (at ?? DateTime.now()).toIso8601String(),
);

String _baseOutcomeWithExplicitStaticRouting(NetworkIntent plan) {
  final requirement = Requirement(
    id: 'req-static-routing',
    subject: 'routing',
    property: 'protocol',
    value: 'static',
    scope: RequirementScope.project(plan.projectName),
    origin: RequirementOrigin.currentExplicit,
    sourceTurnId: 'base-fixture',
    strength: RequirementStrength.explicit,
  );
  return jsonEncode(
    RequestOutcome(
      interpretation: RequestInterpretation(
        turnId: 'base-fixture',
        conversationId: plan.projectName,
        projectId: plan.projectName,
        basePlanRevision: plan.revision,
        mode: RequestMode.create,
        requirements: [requirement],
        mutationPolicy: MutationPolicy.none,
        reliability: const {ReliabilityLabel.exactExtraction},
      ),
      candidatePlan: plan,
      disposition: RequestDisposition.commit,
    ).toJson(),
  );
}

_FakeStore _seeded() => _FakeStore(
  transcripts: {
    'trunk-lab': [
      _turn('user', 'why is the trunk down?'),
      _turn('model', 'SW1 f0/1 is not trunking.'),
    ],
    // Older than today, so the list has to group it away from "Today".
    'routing-lab': [
      _turn(
        'user',
        'R7 lost its route',
        at: DateTime.now().subtract(const Duration(days: 3)),
      ),
    ],
  },
  titles: {'trunk-lab': 'Trunk Problem'},
);

Widget _chat(
  MemoryService mem, {
  SettingsService? settings,
  ProviderChatService? providerChatServiceOverride,
  ConfigurationExportPathChooser? configurationExportPathChooserOverride,
  String initialProject = '',
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(
      value: settings ?? _FakeSettings(),
    ),
    ChangeNotifierProvider<MemoryService>.value(value: mem),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        initialProject: initialProject,
        providerChatServiceOverride: providerChatServiceOverride,
        configurationExportPathChooserOverride:
            configurationExportPathChooserOverride,
      ),
    ),
  ),
);

/// The message field, found by its label rather than by position: the composer
/// is the one field a person always means when they say "the message box".
Finder _composer() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Message',
);

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'a gallery selection replaces old positions and survives reopening',
    (tester) async {
      _wide(tester);
      final plan = NetworkIntent.parseSimple(
        'office',
        '1 router, 2 switches and 6 PCs',
      ).copyWith(layout: const {'R1': Offset(999, 999)});
      final initial = SessionState()..withIntentJson(jsonEncode(plan.toJson()));
      final store = _FakeStore(
        transcripts: {
          'default': [_turn('model', 'Network ready')],
        },
        stateJson: initial.encode(),
      );
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.enterText(_composer(), 'Preview this drawing');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.byType(LayoutGalleryScreen), findsOneWidget);
      // Even confirming the default must persist it: otherwise a first build
      // silently uses the compiler's independent fallback arrangement.
      await tester.tap(find.text('Use this layout'));
      await tester.pumpAndSettle();
      expect(store.savedState, isNotNull);
      final saved = SessionState.decode(store.savedState!);
      final selected = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
      expect(selected.notes.map(LayoutRequest.styleFromNote), contains('tree'));
      expect(selected.layout, isEmpty);

      final reopened = _FakeStore(
        transcripts: {
          'default': [_turn('model', 'Network ready')],
        },
        stateJson: store.savedState!,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_chat(reopened));
      await tester.pumpAndSettle();
      await tester.enterText(_composer(), 'Preview this drawing');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LayoutGalleryScreen>(find.byType(LayoutGalleryScreen))
            .currentStyle,
        'tree',
      );
      await tester.tap(find.text('Show more designs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Straight rows'));
      await tester.tap(find.text('Use this layout'));
      await tester.pumpAndSettle();
      final changed = NetworkIntent.fromJson(
        jsonDecode(SessionState.decode(reopened.savedState!).intentJson),
      );
      expect(changed.notes.map(LayoutRequest.styleFromNote), contains('rows'));
    },
  );

  testWidgets('A26 show me the layout previews the current drawing only', (
    tester,
  ) async {
    _wide(tester);
    final base = basePlan(project: 'P1');
    final plan = base.copyWith(
      notes: [...base.notes, LayoutRequest.noteFor('rows')],
    );
    final state = SessionState(
      project: 'P1',
      intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
      lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
      requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
    );
    final store = _FakeStore(
      transcripts: const {'P1': []},
      stateJson: state.encode(),
    );
    await tester.pumpWidget(_chat(store, initialProject: 'P1'));
    await tester.pumpAndSettle();

    await tester.enterText(_composer(), 'show me the layout');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.byType(LayoutGalleryScreen), findsOneWidget);
    final preview = tester.widget<LayoutGalleryScreen>(
      find.byType(LayoutGalleryScreen),
    );
    expect(preview.currentStyle, 'rows');
    expect(preview.intent.toPlannerJson(), plan.toPlannerJson());
    expect(store.savedState, isNull);
    expect(store.sessionStateWrites, 0);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(store.savedState, isNull);
    expect(store.sessionStateWrites, 0);
  });

  testWidgets('A30 build it with no plan asks what network to build', (
    tester,
  ) async {
    _wide(tester);
    final initial = SessionState(project: 'P1');
    final store = _FakeStore(
      transcripts: const {'P1': []},
      stateJson: initial.encode(),
    );
    await tester.pumpWidget(_chat(store, initialProject: 'P1'));
    await tester.pumpAndSettle();

    await tester.enterText(_composer(), 'build it');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.textContaining('Describe the network first'), findsOneWidget);
    expect(find.text('Build .pkt'), findsNothing);
    final saved = SessionState.decode(store.savedState ?? '{}');
    expect(saved.intentJson, isEmpty, reason: 'no default lab was invented');
    final outcome = RequestOutcome.fromJson(
      jsonDecode(saved.requestOutcomeJson),
    );
    expect(outcome.disposition, RequestDisposition.ask);
    expect(outcome.candidatePlan, isNull);
    expect(
      outcome.interpretation.issues.map((issue) => issue.code),
      contains('no_plan_for_requested_output'),
    );
  });

  group('the conversation sidebar', () {
    testWidgets('lists the saved conversations, grouped by time', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationSidebar), findsOneWidget);
      // The list's own New chat and the header's are both present; what
      // matters is that a chat can be started from the list.
      expect(find.text('New chat'), findsWidgets);
      expect(find.text('Search'), findsOneWidget);
      expect(
        find.text('Trunk Problem'),
        findsOneWidget,
        reason: 'a generated/renamed title is what the list shows',
      );
      expect(
        find.text('R7 lost its route'),
        findsOneWidget,
        reason: 'a chat with no stored title falls back to its first turn',
      );
      expect(find.text('Today'), findsWidgets);
      expect(
        find.text('Previous 7 days'),
        findsWidgets,
        reason: 'older chats are grouped by time',
      );
    });

    testWidgets('searches by message text, not just by title', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      // The composer is also a TextField, so aim at the sidebar's own field.
      await tester.enterText(
        find.descendant(
          of: find.byType(ConversationSidebar),
          matching: find.byType(TextField),
        ),
        'R7',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('R7 lost its route'), findsOneWidget);
      expect(find.text('Trunk Problem'), findsNothing);
    });

    testWidgets('opens a conversation and starts a new one', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trunk Problem'));
      await tester.pumpAndSettle();
      expect(
        find.text('SW1 f0/1 is not trunking.'),
        findsWidgets,
        reason: 'opening a chat restores its transcript',
      );

      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();
      expect(find.text("What are we building today?"), findsOneWidget);
    });

    testWidgets('collapses to a rail and comes back', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Hide the conversation list'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationSidebar), findsNothing);
      expect(find.byType(CollapsedConversationRail), findsOneWidget);

      // The header carries a toggle with the same tooltip, so click the rail's.
      await tester.tap(
        find.descendant(
          of: find.byType(CollapsedConversationRail),
          matching: find.byTooltip('Show the conversation list'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConversationSidebar), findsOneWidget);
    });

    testWidgets('the back gesture closes the panel over the chat', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show the conversation list').first);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationSidebar), findsOneWidget);

      // Android's back gesture: it closes the panel instead of leaving the
      // screen with the panel still open.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ConversationSidebar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow window slides the list over the chat', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      // Closed by default: the conversation keeps the whole width.
      expect(find.byType(ConversationSidebar), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Show the conversation list').first);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationSidebar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the welcome screen', () {
    testWidgets('asks the networking question and offers openers', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      expect(find.text("What are we building today?"), findsOneWidget);
      for (final label in const [
        'Analyze a network',
        'Troubleshoot connectivity',
        'Open a .pkt project',
        'Check a configuration',
        'Create a network',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  });

  group('the activity panel shows real work only', () {
    testWidgets('nothing happened, nothing is drawn', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActivityPanel(entries: [], expanded: true, onToggle: _noop),
          ),
        ),
      );
      expect(find.textContaining('Checked the network'), findsNothing);
    });

    testWidgets('entries, counts and the failure marker', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityPanel(
              entries: const [
                ActivityEntry('Loaded office-network.pkt'),
                ActivityEntry('Validated the plan', detail: '12 devices'),
                ActivityEntry(
                  'Checked PC1 -> SRV1',
                  status: ActivityStatus.failed,
                ),
              ],
              expanded: true,
              onToggle: _noop,
              problemCount: 2,
            ),
          ),
        ),
      );
      expect(find.text('Loaded office-network.pkt'), findsOneWidget);
      expect(find.textContaining('3 step(s)'), findsOneWidget);
      expect(find.textContaining('found 2 issue(s)'), findsOneWidget);
      expect(
        find.byIcon(Icons.close),
        findsOneWidget,
        reason: 'a failed step is marked, not hidden',
      );
    });

    testWidgets('collapses', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityPanel(
              entries: const [ActivityEntry('Ran a tool')],
              expanded: false,
              onToggle: () => toggled = true,
            ),
          ),
        ),
      );
      expect(find.text('Ran a tool'), findsNothing);
      await tester.tap(find.textContaining('Checked the network'));
      expect(toggled, isTrue);
    });
  });

  group('the network inspector', () {
    testWidgets('shows the plan, the findings and the change log', (
      tester,
    ) async {
      // A plan the validator really flags, so the findings section carries
      // the checker's own words rather than a decorative list.
      final intent = NetworkIntent(
        projectName: 'office-network',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'SW1', type: 'switch'),
        ],
        routing: 'ospf',
      );
      final issues = ValidatorService.validate(intent);
      // Tall enough that the inspector's ListView builds every section; a
      // lazy list would leave the lower ones unrendered.
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NetworkInspector(
              project: 'office-network.pkt',
              intent: intent,
              state: SessionState()
                ..observe(const ChatMessage(role: 'user', text: 'check PC1')),
              changes: const [
                {
                  'device': 'R1',
                  'interface': 'g0/1',
                  'field': 'ipAddress',
                  'oldValue': '192.168.1.1/24',
                  'newValue': '192.168.1.254/24',
                  'undoneAt': '',
                },
              ],
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Network inspector'), findsOneWidget);
      expect(find.text('office-network.pkt'), findsOneWidget);
      expect(find.textContaining('R1'), findsWidgets);
      expect(
        find.textContaining('-> "192.168.1.254/24"'),
        findsOneWidget,
        reason: 'the change log shows the exact old and new value',
      );
      expect(
        find.textContaining('Detected problems'.toUpperCase()),
        findsOneWidget,
      );
      expect(
        issues,
        isNotEmpty,
        reason: 'the panel shows the validator\'s own output',
      );
      expect(find.textContaining('Duplicate device names.'), findsOneWidget);
    });

    testWidgets('says so when there is no plan yet', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NetworkInspector(
              project: 'default',
              state: SessionState(),
              onClose: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('No plan yet'), findsOneWidget);
    });
  });

  group('a keyless conversation is a conversation', () {
    testWidgets('it answers, writes its answer down, and offers the next tap', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // THE BRIEF CONVERSATION: a brief with critical gaps (scale, routing)
      // asks instead of dumping a plan with a build button. The way out is
      // still a tap: answer the questions, or take the defaults.
      expect(
        find.textContaining('before I plan this'),
        findsOneWidget,
        reason: 'a brief with critical gaps asks before it plans',
      );
      expect(
        store.logged.where((m) => m.role == 'model'),
        isNotEmpty,
        reason: 'an answer that is not stored is an answer lost on restart',
      );
      expect(
        find.text('Just build it with defaults'),
        findsOneWidget,
        reason: 'its own way out is a tap, not a typing exercise',
      );
      expect(
        find.textContaining('Still open'),
        findsNothing,
        reason: 'the questions ARE the still-open list',
      );
    });

    testWidgets('a screen reader hears the suggestions and the field', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // Every chip names itself as a next MESSAGE, not as a label: a screen
      // reader user hears what tapping it will send.
      expect(
        find.bySemanticsLabel(RegExp('^Suggested next step: .+')),
        findsWidgets,
      );
      semantics.dispose();
    });

    testWidgets('a screen reader reaches an advice answer and its chips', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      // The advice flow must be as reachable as the build flow: the
      // recommendation reads as an assistant turn, the table survives
      // rendering, and every suggested follow-up announces the message it
      // will send.
      await tester.enterText(
        _composer(),
        'what router should I use in this case?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Assistant said'), findsWidgets);
      expect(
        find.textContaining('What I would do'),
        findsOneWidget,
        reason: 'the recommendation itself is readable text, not an image',
      );
      expect(
        find.bySemanticsLabel(RegExp('^Suggested next step: .+')),
        findsWidgets,
        reason: 'the advice chips are buttons a screen reader can activate',
      );
      semantics.dispose();
    });

    testWidgets('a follow-up about the same lab does not become a new one', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        'I have 10 Pcs and want to build a network for them add switches and '
        'routers and servers and make security maximum',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      // The brief conversation: the lab parsed (10 PCs, a server), but the
      // segmentation gap asks before a plan is committed.
      expect(
        find.textContaining('before I plan this'),
        findsOneWidget,
        reason: 'the lab parsed, but the ask comes before the plan dump',
      );

      // Answer the one gap this lab has (one router: no routing question).
      await tester.enterText(_composer(), 'one flat network');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('VLANs: one flat network'), findsWidgets);

      await tester.enterText(
        _composer(),
        'can we add AAA server to it as well ?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // The reported bug: this turned a 13-device lab into one server with no
      // links, because the follow-up named a device. The answer now describes
      // the change against the lab that exists.
      expect(find.textContaining('AAA added'), findsOneWidget);
      expect(
        find.textContaining('10 PCs'),
        findsWidgets,
        reason: 'the ten PCs are still part of the answer',
      );
      expect(find.textContaining('Devices: 1,'), findsNothing);
    });

    testWidgets('a polite direct action question adds the requested devices', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved = SessionState(
        project: 'P1',
        intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'can you add 2 PCs?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final committed = SessionState.decode(store.savedState!);
      final after = NetworkIntent.fromJson(jsonDecode(committed.intentJson));
      expect(after.nodes.where((node) => node.type == 'pc').length, 12);
      expect(after.nodes.map((node) => node.name), contains('PC10'));
      expect(after.routing, 'static');
    });

    testWidgets(
      'A29 build it compiles the exact committed plan and requirements',
      (tester) async {
        _wide(tester);
        final documentPath = Directory('build/requested-action-a29');
        if (documentPath.existsSync()) {
          documentPath.deleteSync(recursive: true);
        }
        documentPath.createSync(recursive: true);
        SharedPreferences.setMockInitialValues({});
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FixedPathProvider(documentPath.path);
        addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
        addTearDown(() {
          if (documentPath.existsSync()) {
            documentPath.deleteSync(recursive: true);
          }
        });

        final base = basePlan(project: 'P1').copyWith(
          notes: [
            ...basePlan(project: 'P1').notes,
            'layout: tree',
          ],
        );
        final initial = SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(base),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: initial.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), 'build it');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (
          var i = 0;
          i < 300 &&
              find
                  .textContaining('Packet Tracer file: built')
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }

        expect(
          find.textContaining('Packet Tracer file: built'),
          findsOneWidget,
          reason: store.logged
              .map((message) => '${message.role}: ${message.text}')
              .join('\n'),
        );
        final committed = SessionState.decode(store.savedState!);
        final savedPlan = NetworkIntent.fromJson(
          jsonDecode(committed.intentJson),
        );
        expect(savedPlan.toPlannerJson(), base.toPlannerJson());
        expect(committed.artifactPath, isNotEmpty);
        expect(File(committed.artifactPath).existsSync(), isTrue);
        final outcome = RequestOutcome.fromJson(
          jsonDecode(committed.requestOutcomeJson),
        );
        expect(outcome.disposition, RequestDisposition.answerOnly);
        expect(outcome.candidatePlan?.revision, base.revision);
        expect(outcome.changeSet, isNull);
        expect(
          outcome.interpretation.requirements.any(
            (requirement) =>
                requirement.property == 'protocol' &&
                requirement.value == 'static',
          ),
          isTrue,
          reason: 'build it keeps the established explicit routing choice',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'A31 commits one routing edit before building that exact revision',
      (tester) async {
        _wide(tester);
        final documentPath = Directory('build/requested-action-a31');
        if (documentPath.existsSync()) {
          documentPath.deleteSync(recursive: true);
        }
        documentPath.createSync(recursive: true);
        SharedPreferences.setMockInitialValues({});
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FixedPathProvider(documentPath.path);
        addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
        addTearDown(() {
          if (documentPath.existsSync()) {
            documentPath.deleteSync(recursive: true);
          }
        });

        final base = basePlan(project: 'P1').copyWith(
          notes: [
            ...basePlan(project: 'P1').notes,
            'layout: tree',
          ],
        );
        final initial = SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(base),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: initial.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        await tester.enterText(
          _composer(),
          'change routing to OSPF and build it',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (
          var i = 0;
          i < 300 &&
              find
                  .textContaining('Packet Tracer file: built')
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }

        expect(
          find.textContaining('Packet Tracer file: built'),
          findsOneWidget,
          reason: store.logged
              .map((message) => '${message.role}: ${message.text}')
              .join('\n'),
        );
        expect(
          find.text('Choose network design'),
          findsNothing,
          reason: store.logged
              .map((message) => '${message.role}: ${message.text}')
              .join('\n'),
        );
        final committed = SessionState.decode(store.savedState!);
        final savedPlan = NetworkIntent.fromJson(
          jsonDecode(committed.intentJson),
        );
        final outcome = RequestOutcome.fromJson(
          jsonDecode(committed.requestOutcomeJson),
        );
        expect(savedPlan.routing, 'ospf');
        expect(outcome.disposition, RequestDisposition.commit);
        expect(outcome.candidatePlan?.revision, savedPlan.revision);
        expect(outcome.changeSet?.operations, hasLength(1));
        expect(outcome.changeSet?.operations.single.kind.name, 'setRouting');
        expect(outcome.interpretation.requestedActions, hasLength(1));
        expect(
          outcome.interpretation.requestedActions.single.kind.name,
          'build',
        );
        expect(File(committed.artifactPath).existsSync(), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('A15 lowers the saved PC total using the stable removal order', (
      tester,
    ) async {
      _wide(tester);
      const brief = '2 routers, 2 switches, 10 PCs, 2 servers';
      final base = NetworkIntent.parseSimple('P1', brief);
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: brief,
        ).encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'make it 5 PCs');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final saved = SessionState.decode(store.savedState!);
      final plan = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
      final outcome = RequestOutcome.fromJson(
        jsonDecode(saved.requestOutcomeJson),
      );
      expect(
        plan.nodes.where((node) => node.type == 'pc').map((node) => node.name),
        ['PC1', 'PC2', 'PC3', 'PC4', 'PC5'],
        reason:
            '${outcome.disposition}: ${outcome.interpretation.issues.map((issue) => issue.code)}',
      );
      expect(outcome.disposition, RequestDisposition.commit);
      expect(outcome.changeSet?.operations.single.kind.name, 'setDeviceCount');
      expect(
        plan.links.every(
          (link) =>
              plan.nodes.any((node) => node.name == link.a) &&
              plan.nodes.any((node) => node.name == link.b),
        ),
        isTrue,
      );
    });

    testWidgets('A41 exact service assignments use two existing servers', (
      tester,
    ) async {
      _wide(tester);
      const brief = '2 routers, 2 switches, 10 PCs, 2 servers';
      final parsed = NetworkIntent.parseSimple('P1', brief);
      final base = parsed.copyWith(
        nodes: [
          for (final node in parsed.nodes)
            if (node.type == 'server')
              NetNode(
                name: node.name,
                type: node.type,
                model: node.model,
                exactModel: node.exactModel,
                modules: node.modules,
              )
            else
              node,
        ],
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: brief,
        ).encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        'make SRV1 DHCP and another server DNS',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final saved = SessionState.decode(store.savedState!);
      final plan = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
      expect(plan.nodes.where((node) => node.type == 'server'), hasLength(2));
      expect(plan.nodes.singleWhere((node) => node.name == 'SRV1').services, [
        'dhcp',
      ]);
      expect(plan.nodes.singleWhere((node) => node.name == 'SRV2').services, [
        'dns',
      ]);
      expect(
        RequestOutcome.fromJson(
          jsonDecode(saved.requestOutcomeJson),
        ).disposition,
        RequestDisposition.commit,
      );
    });

    testWidgets('A42 a named rename updates references through chat', (
      tester,
    ) async {
      _wide(tester);
      const brief = '2 routers, 2 switches, 10 PCs, 2 servers';
      final base = NetworkIntent.parseSimple('P1', brief);
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: brief,
        ).encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'rename R1 to Edge1');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final saved = SessionState.decode(store.savedState!);
      final plan = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
      expect(plan.nodes.any((node) => node.name == 'Edge1'), isTrue);
      expect(plan.nodes.any((node) => node.name == 'R1'), isFalse);
      expect(
        plan.links.any((link) => link.a == 'Edge1' || link.b == 'Edge1'),
        isTrue,
      );
      expect(plan.addressing.any((row) => row.node == 'Edge1'), isTrue);
      expect(
        RequestOutcome.fromJson(
          jsonDecode(saved.requestOutcomeJson),
        ).disposition,
        RequestDisposition.commit,
      );
    });

    testWidgets('A50 a missing named server holds the whole mixed edit', (
      tester,
    ) async {
      _wide(tester);
      const brief = '2 routers, 2 switches, 10 PCs, 2 servers';
      final base = NetworkIntent.parseSimple('P1', brief);
      final initial = SessionState(
        project: 'P1',
        intentJson: jsonEncode(base.toJson(includeSecrets: false)),
        lastBrief: brief,
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: initial.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        'add a printer and change only SRV9 to DNS',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No device named'),
        findsOneWidget,
        reason: store.logged
            .map((message) => '${message.role}: ${message.text}')
            .join('\n'),
      );
      final saved = SessionState.decode(store.savedState!);
      expect(saved.intentJson, initial.intentJson);
      expect(
        NetworkIntent.fromJson(
          jsonDecode(saved.intentJson),
        ).nodes.where((node) => node.type == 'printer'),
        isEmpty,
      );
      final outcome = RequestOutcome.fromJson(
        jsonDecode(saved.requestOutcomeJson),
      );
      expect(outcome.disposition, RequestDisposition.ask);
      expect(outcome.candidatePlan, isNull);
      expect(outcome.changeSet, isNull);
    });

    testWidgets('A32 an old build card stays inert after the plan changes', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved = SessionState(
        project: 'P1',
        intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
      );
      final oldUserTurn = _turn('user', '2 routers, 2 switches, 10 PCs');
      final oldBuildCard = ChatMessage(
        role: 'model',
        text: 'Plan ready.',
        actions: [
          ChatAction(
            kind: 'pkt_generate',
            payload: {
              'revision': plan.revision,
              'buildRevision': plan.buildRevision,
              'devices': plan.nodes.length,
              'links': plan.links.length,
              'target': 'packet-tracer',
            },
          ),
        ],
      );
      final store = _FakeStore(
        transcripts: {
          'P1': [oldUserTurn, oldBuildCard],
        },
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();
      expect(find.text('Plan ready.'), findsOneWidget);

      await tester.enterText(_composer(), 'can you add 2 PCs?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final changedState = SessionState.decode(store.savedState!);
      final changedPlan = NetworkIntent.fromJson(
        jsonDecode(changedState.intentJson),
      );
      expect(changedPlan.revision, isNot(plan.revision));
      expect(
        changedPlan.nodes.where((node) => node.type == 'pc'),
        hasLength(12),
      );
      // The transcript pins the newest turn to the bottom. Scroll the old
      // action into view so ListView.builder constructs its stale warning.
      final scrollables = find.byType(Scrollable);
      final chatScrollable =
          List.generate(
            scrollables.evaluate().length,
            scrollables.at,
          ).firstWhere(
            (finder) =>
                tester.state<ScrollableState>(finder).position.maxScrollExtent >
                0,
          );
      await tester.drag(chatScrollable, const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(find.text('Plan ready.'), findsOneWidget);
      expect(find.text('Expired build card'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('Choose network design'), findsNothing);
      expect(
        find.textContaining('this card was written for plan rev'),
        findsOneWidget,
      );

      final beforeStaleTap = SessionState.decode(store.savedState!);
      final modelRepliesBeforeTap = store.logged
          .where((message) => message.role == 'model')
          .length;
      await tester.tap(find.text('Expired build card'));
      await tester.pumpAndSettle();

      final afterStaleTap = SessionState.decode(store.savedState!);
      expect(afterStaleTap.intentJson, beforeStaleTap.intentJson);
      expect(afterStaleTap.artifactPath, isEmpty);
      expect(
        store.logged.where((message) => message.role == 'model'),
        hasLength(modelRepliesBeforeTap),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('A32 a layout-only edit expires an older build card', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved = SessionState(
        project: 'P1',
        intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
        requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
      );
      final oldUserTurn = _turn('user', '2 routers, 2 switches, 10 PCs');
      final oldBuildCard = ChatMessage(
        role: 'model',
        text: 'Plan ready.',
        actions: [
          ChatAction(
            kind: 'pkt_generate',
            payload: {
              'revision': plan.revision,
              'buildRevision': plan.buildRevision,
              'devices': plan.nodes.length,
              'links': plan.links.length,
              'target': 'packet-tracer',
            },
          ),
        ],
      );
      final store = _FakeStore(
        transcripts: {
          'P1': [oldUserTurn, oldBuildCard],
        },
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        'only rearrange the layout; keep all IPs and cables',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final afterLayoutEdit = SessionState.decode(store.savedState!);
      final changedPlan = NetworkIntent.fromJson(
        jsonDecode(afterLayoutEdit.intentJson),
      );
      expect(changedPlan.revision, plan.revision);
      expect(changedPlan.buildRevision, isNot(plan.buildRevision));
      expect(afterLayoutEdit.artifactPath, isEmpty);

      final scrollables = find.byType(Scrollable);
      final chatScrollable =
          List.generate(
            scrollables.evaluate().length,
            scrollables.at,
          ).firstWhere(
            (finder) =>
                tester.state<ScrollableState>(finder).position.maxScrollExtent >
                0,
          );
      await tester.drag(chatScrollable, const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(find.text('Expired build card'), findsOneWidget);
      expect(
        find.textContaining('drawing or device positions have since changed'),
        findsOneWidget,
      );

      final beforeStaleTap = SessionState.decode(store.savedState!);
      final modelRepliesBeforeTap = store.logged
          .where((message) => message.role == 'model')
          .length;
      await tester.tap(find.text('Expired build card'));
      await tester.pumpAndSettle();
      final afterStaleTap = SessionState.decode(store.savedState!);
      expect(afterStaleTap.intentJson, beforeStaleTap.intentJson);
      expect(afterStaleTap.artifactPath, isEmpty);
      expect(
        store.logged.where((message) => message.role == 'model'),
        hasLength(modelRepliesBeforeTap),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a plan change reports build success when the later config export fails',
      (tester) async {
        _wide(tester);
        final documentPath = Directory('build/requested-action-documents');
        if (documentPath.existsSync()) {
          documentPath.deleteSync(recursive: true);
        }
        documentPath.createSync(recursive: true);
        SharedPreferences.setMockInitialValues({});
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FixedPathProvider(documentPath.path);
        addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
        addTearDown(() {
          if (documentPath.existsSync()) {
            documentPath.deleteSync(recursive: true);
          }
        });

        final base = NetworkIntent.parseSimple(
          'P1',
          '2 routers and 4 switches',
        );
        final plan = base.copyWith(notes: [...base.notes, 'layout: tree']);
        final saved = SessionState(
          project: 'P1',
          intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use OSPF routing',
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: saved.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        await tester.enterText(
          _composer(),
          'change to OSPF, build the .pkt, and export the configurations',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (
          var i = 0;
          i < 240 &&
              find.textContaining('Configurations: export').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }

        expect(
          find.textContaining('Packet Tracer file: built'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Configurations: export failed'),
          findsOneWidget,
        );
        final report = store.logged.lastWhere(
          (message) => message.role == 'model',
        );
        final buildStatus = report.text.indexOf('Packet Tracer file: built');
        final exportStatus = report.text.indexOf(
          'Configurations: export failed',
        );
        expect(buildStatus, greaterThanOrEqualTo(0));
        expect(exportStatus, greaterThan(buildStatus));

        final committed = SessionState.decode(store.savedState!);
        final committedPlan = NetworkIntent.fromJson(
          jsonDecode(committed.intentJson),
        );
        expect(committedPlan.routing, 'ospf');
        expect(committed.artifactPath, isNotEmpty);
        expect(File(committed.artifactPath).existsSync(), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a cancelled build still exports configurations and reports both outcomes in order',
      (tester) async {
        _wide(tester);
        final documentPath = Directory(
          'build/requested-action-cancelled-build',
        );
        if (documentPath.existsSync()) {
          documentPath.deleteSync(recursive: true);
        }
        documentPath.createSync(recursive: true);
        SharedPreferences.setMockInitialValues({});
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FixedPathProvider(documentPath.path);
        addTearDown(() => PathProviderPlatform.instance = previousPathProvider);
        addTearDown(() {
          if (documentPath.existsSync()) {
            documentPath.deleteSync(recursive: true);
          }
        });

        String? exportedPath;
        Future<String?> chooseConfigurationPath({
          required String fileName,
        }) async {
          exportedPath = '${documentPath.path}/$fileName';
          return exportedPath;
        }

        final plan = NetworkIntent.parseSimple(
          'P1',
          '2 routers and 4 switches',
        );
        final saved = SessionState(
          project: 'P1',
          intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
          lastBrief: '2 routers and 4 switches; use static routing',
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: saved.encode(),
        );
        await tester.pumpWidget(
          _chat(
            store,
            initialProject: 'P1',
            configurationExportPathChooserOverride: chooseConfigurationPath,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          _composer(),
          'change to OSPF, build the .pkt, and export the configurations',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (
          var i = 0;
          i < 120 && find.text('Choose a layout').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Choose a layout'), findsOneWidget);

        // Backing out of the layout choice cancels only the build output.
        // The ordered configuration export must still run against the saved
        // OSPF candidate.
        await tester.pageBack();
        for (
          var i = 0;
          i < 120 &&
              find
                  .textContaining('Configurations: saved to')
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }

        expect(
          find.textContaining('Packet Tracer file: not completed'),
          findsOneWidget,
        );
        expect(find.textContaining('Configurations: saved to'), findsOneWidget);
        expect(exportedPath, isNotNull);
        final configurationFile = File(exportedPath!);
        expect(configurationFile.existsSync(), isTrue);
        expect(configurationFile.readAsStringSync(), contains('hostname R1'));

        final report = store.logged.lastWhere(
          (message) => message.role == 'model',
        );
        final buildStatus = report.text.indexOf(
          'Packet Tracer file: not completed',
        );
        final exportStatus = report.text.indexOf('Configurations: saved to');
        expect(buildStatus, greaterThanOrEqualTo(0));
        expect(exportStatus, greaterThan(buildStatus));

        final committed = SessionState.decode(store.savedState!);
        final committedPlan = NetworkIntent.fromJson(
          jsonDecode(committed.intentJson),
        );
        expect(committedPlan.routing, 'ospf');
        expect(committed.artifactPath, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an explicit remembered routing choice is venue scoped', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P2');
      final saved =
          SessionState(
            project: 'P2',
            intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
            lastBrief: '2 routers, 2 switches, 10 PCs',
          )..setPendingQuestions([
            PendingQuestionContext(
              questionId: 'routing',
              project: 'P2',
              baseRevision: plan.revision,
              property: 'routing',
            ),
          ]);
      final store = _FakeStore(
        transcripts: const {'P2': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P2'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'OSPF');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final afterLocalAnswer = SessionState.decode(store.savedState!);
      expect(
        NetworkIntent.fromJson(jsonDecode(afterLocalAnswer.intentJson)).routing,
        'ospf',
      );
      expect(store.rememberedClarificationWrites, 0);

      await tester.enterText(
        _composer(),
        'remember OSPF for future office labs',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, afterLocalAnswer.intentJson);
      expect(store.rememberedClarifications, [
        (questionId: 'routing', answer: 'ospf', venue: 'office', scale: 0),
      ]);
      expect(
        find.textContaining('Saved OSPF for future office labs'),
        findsOneWidget,
      );
    });

    testWidgets('an office memory fills a new lab with visible provenance', (
      tester,
    ) async {
      _wide(tester);
      final store =
          _FakeStore(
              transcripts: const {'P2': []},
              stateJson: SessionState(project: 'P2').encode(),
            )
            ..rememberedProfile = const EnvironmentProfile(venue: 'office')
            ..rememberedClarifications.add((
              questionId: 'routing',
              answer: 'ospf',
              venue: 'office',
              scale: 0,
            ));
      await tester.pumpWidget(_chat(store, initialProject: 'P2'));
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        '2 routers, 2 switches, 4 PCs for the office',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final saved = SessionState.decode(store.savedState!);
      final plan = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
      final brief = DesignBrief.fromJson(jsonDecode(saved.briefJson));
      expect(plan.routing, 'ospf');
      expect(brief.fact(DesignBrief.routing)?.origin, BriefSource.remembered);
      expect(
        brief.fact(DesignBrief.routing)?.source,
        'remembered from an earlier answer',
      );
      expect(
        find.textContaining('remembered from an earlier answer'),
        findsOneWidget,
      );
    });

    testWidgets('an answer is a real turn, and it fills the brief', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // The ask offered answers as taps; an answer sent as a message (typed
      // or tapped - same path) is confirmed and recorded in this chat, and the scale
      // answer sets the requested device total.
      await tester.enterText(_composer(), '25');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        store.logged.where((m) => m.role == 'user'),
        contains(predicate((ChatMessage m) => m.text.trim() == '25')),
      );
      expect(find.textContaining('Scale: 25 devices'), findsWidgets);
      expect(find.byKey(const ValueKey('brief-card')), findsWidgets);
      final savedAfterScale = SessionState.decode(store.savedState!);
      final scaledPlan = NetworkIntent.fromJson(
        jsonDecode(savedAfterScale.intentJson),
      );
      expect(scaledPlan.nodes.where((node) => node.type == 'pc').length, 25);
      // Routing is still open: the conversation continues with the next
      // question rather than a plan.
      expect(find.textContaining('How should the routers route'), findsWidgets);

      // Answering the last question readies the brief - the way out is a
      // tap, and the ack says so.
      await tester.enterText(_composer(), 'OSPF');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('Routing: OSPF'), findsWidgets);
      expect(find.textContaining('everything I need'), findsWidgets);
      expect(find.text('Build the .pkt'), findsOneWidget);
      final savedAfterRouting = SessionState.decode(store.savedState!);
      final finalPlan = NetworkIntent.fromJson(
        jsonDecode(savedAfterRouting.intentJson),
      );
      expect(finalPlan.nodes.where((node) => node.type == 'pc').length, 25);
      expect(finalPlan.routing, 'ospf');
      expect(savedAfterRouting.pendingQuestionIds, isEmpty);
    });

    testWidgets('a failed answer save commits neither brief nor plan', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final before = SessionState.decode(store.savedState!);
      expect(before.pendingQuestionIds, contains('routing'));
      final routingContext = before.pendingQuestionContexts.singleWhere(
        (context) => context.questionId == 'routing',
      );
      expect(routingContext.baseRevision, isNotEmpty);
      expect(
        routingContext.baseRevision,
        NetworkIntent.fromJson(jsonDecode(before.intentJson)).revision,
      );

      store.failRoutingOspfTransitionSave = true;
      await tester.enterText(_composer(), 'OSPF');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.textContaining('could not save it'), findsOneWidget);
      expect(store.failRoutingOspfTransitionSave, isFalse);
      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, before.intentJson);
      expect(after.briefJson, before.briefJson);
      expect(after.pendingQuestionIds, before.pendingQuestionIds);
      expect(store.rememberedClarificationWrites, 0);
    });

    testWidgets('a failed plan snapshot save keeps the prior plan', (
      tester,
    ) async {
      _wide(tester);
      final priorPlan = basePlan(project: 'P1');
      final priorState = SessionState(
        project: 'P1',
        intentJson: jsonEncode(priorPlan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: priorState.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();
      expect(store.sessionStateWrites, 0);

      store.failNextSessionStateSave = true;
      await tester.enterText(_composer(), 'can you add 2 PCs?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('I could not save this change'),
        findsOneWidget,
      );
      expect(store.sessionStateWrites, 0);
      final persisted = SessionState.decode(
        store.savedState ?? priorState.encode(),
      );
      expect(persisted.intentJson, priorState.intentJson);
      expect(persisted.lastBrief, priorState.lastBrief);
      expect(persisted.briefJson, priorState.briefJson);
      expect(persisted.requestOutcomeJson, priorState.requestOutcomeJson);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an unsaved user turn does not reach planning or the provider',
      (tester) async {
        _wide(tester);
        final priorPlan = basePlan(project: 'P1');
        final priorState = SessionState(
          project: 'P1',
          intentJson: jsonEncode(priorPlan.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: priorState.encode(),
        )..failNextUserLogSave = true;
        final provider = _DeterministicProviderChatService();
        await tester.pumpWidget(
          _chat(
            store,
            initialProject: 'P1',
            settings: _FakeSettings(geminiKey: 'test-key'),
            providerChatServiceOverride: provider,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), 'can you add 2 PCs?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        expect(provider.calls, 0);
        expect(store.sessionStateWrites, 0);
        expect(
          find.textContaining('I could not save your message'),
          findsOneWidget,
        );
        expect(
          SessionState.decode(
            store.savedState ?? priorState.encode(),
          ).intentJson,
          priorState.intentJson,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a user-load answer keeps the saved device inventory', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final before = SessionState.decode(store.savedState!);
      final beforePlan = NetworkIntent.fromJson(jsonDecode(before.intentJson));
      final beforePcs = beforePlan.nodes
          .where((node) => node.type == 'pc')
          .length;
      expect(before.pendingQuestionIds, contains('scale'));

      await tester.enterText(_composer(), '40 users');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final after = SessionState.decode(store.savedState!);
      final afterPlan = NetworkIntent.fromJson(jsonDecode(after.intentJson));
      final brief = DesignBrief.fromJson(jsonDecode(after.briefJson));
      expect(
        afterPlan.nodes.where((node) => node.type == 'pc').length,
        beforePcs,
      );
      expect(
        brief.fact(DesignBrief.scale)?.quantityKind,
        QuantityKind.userLoad,
      );
      expect(brief.fact(DesignBrief.scale)?.value, '40');
      expect(after.pendingQuestionIds, contains('scale'));
      expect(store.rememberedClarificationWrites, 0);
      expect(
        find.textContaining('physical device inventory is unchanged'),
        findsOneWidget,
      );
      expect(
        find.textContaining('I have not verified capacity for 40 users'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Should I keep this inventory fixed or resize it?'),
        findsOneWidget,
      );
    });

    testWidgets('one reply applies all matching pending answers together', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved =
          SessionState(
            project: 'P1',
            intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
            lastBrief: '2 routers, 2 switches, 10 PCs',
          )..setPendingQuestions([
            for (final id in ['scale', 'routing', 'segmentation'])
              PendingQuestionContext(
                questionId: id,
                project: 'P1',
                baseRevision: plan.revision,
                property: id,
              ),
          ]);
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '40 devices, OSPF, one flat LAN');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final reopened = SessionState.decode(store.savedState!);
      final committed = NetworkIntent.fromJson(jsonDecode(reopened.intentJson));
      final brief = DesignBrief.fromJson(jsonDecode(reopened.briefJson));
      expect(committed.nodes.where((node) => node.type == 'pc').length, 40);
      expect(committed.routing, 'ospf');
      expect(reopened.pendingQuestionIds, isEmpty);
      expect(brief.value(DesignBrief.scale), '40');
      expect(brief.value(DesignBrief.routing), 'ospf');
      expect(brief.value(DesignBrief.segmentation), 'none');
      expect(store.rememberedClarificationWrites, 0);
      expect(find.textContaining('one flat network'), findsWidgets);
    });

    testWidgets('an unsupported answer holds the whole clarification turn', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved =
          SessionState(
            project: 'P1',
            intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
            lastBrief: '2 routers, 2 switches, 10 PCs',
          )..setPendingQuestions([
            for (final id in ['scale', 'routing', 'segmentation'])
              PendingQuestionContext(
                questionId: id,
                project: 'P1',
                baseRevision: plan.revision,
                property: id,
              ),
          ]);
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '40 devices, OSPF, VLANs');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No answers from that message were committed'),
        findsOneWidget,
      );
      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, saved.intentJson);
      expect(after.briefJson, saved.briefJson);
      expect(after.pendingQuestionIds, saved.pendingQuestionIds);
      expect(store.rememberedClarificationWrites, 0);
      expect(
        store.logged.any(
          (message) =>
              message.role == 'model' &&
              message.text.contains(
                'No answers from that message were committed',
              ),
        ),
        isTrue,
      );
    });

    testWidgets('reopening resumes unanswered pending clarification', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final saved =
          SessionState(
            project: 'P1',
            intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
            lastBrief: '2 routers, 2 switches, 10 PCs',
          )..setPendingQuestions([
            for (final id in ['scale', 'routing'])
              PendingQuestionContext(
                questionId: id,
                project: 'P1',
                baseRevision: plan.revision,
                property: id,
              ),
          ]);
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'OSPF');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final afterRouting = SessionState.decode(store.savedState!);
      expect(
        afterRouting.pendingQuestionIds,
        containsAll(['scale', 'segmentation']),
      );
      expect(
        NetworkIntent.fromJson(jsonDecode(afterRouting.intentJson)).routing,
        'ospf',
      );
      expect(
        afterRouting.pendingQuestionContexts.every(
          (context) =>
              context.baseRevision ==
              NetworkIntent.fromJson(
                jsonDecode(afterRouting.intentJson),
              ).revision,
        ),
        isTrue,
      );

      final reopenedStore = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: afterRouting.encode(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_chat(reopenedStore, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '40 devices, one flat LAN');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final finalState = SessionState.decode(reopenedStore.savedState!);
      final finalPlan = NetworkIntent.fromJson(
        jsonDecode(finalState.intentJson),
      );
      expect(finalPlan.nodes.where((node) => node.type == 'pc').length, 40);
      expect(finalPlan.routing, 'ospf');
      expect(finalState.pendingQuestionIds, isEmpty);
    });

    testWidgets('a pending answer cannot cross project or plan revision', (
      tester,
    ) async {
      _wide(tester);
      final originalPlan = basePlan(project: 'P1');
      final activePlan = originalPlan.copyWith(routing: 'eigrp');
      final saved =
          SessionState(
            project: 'P2',
            intentJson: jsonEncode(activePlan.toJson(includeSecrets: false)),
            lastBrief: '2 routers, 2 switches, 10 PCs, 2 servers; use EIGRP',
          )..setPendingQuestions([
            PendingQuestionContext(
              questionId: 'routing',
              project: 'P1',
              baseRevision: originalPlan.revision,
              property: 'routing',
            ),
          ]);
      final store = _FakeStore(
        transcripts: const {'P2': []},
        stateJson: saved.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P2'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'OSPF');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('I did not apply that answer'),
        findsOneWidget,
      );
      expect(store.rememberedClarificationWrites, 0);
      final reopened = SessionState.decode(store.savedState!);
      expect(reopened.pendingQuestionIds, isEmpty);
      expect(
        NetworkIntent.fromJson(jsonDecode(reopened.intentJson)).routing,
        'eigrp',
      );
    });

    testWidgets('a what-if about the lab does not change the lab', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('before I plan this'),
        findsOneWidget,
        reason: 'the brief is open, with scale and routing unanswered',
      );

      // The wondering turn. It is answered like any other - it lands in the
      // transcript and it is written down - but nothing about the lab moves.
      await tester.enterText(_composer(), 'what if we had 40 pcs instead?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        store.logged.where((m) => m.role == 'model'),
        isNotEmpty,
        reason: 'a what-if that is not written down is lost on restart',
      );
      expect(
        find.textContaining('Scale: 40'),
        findsNothing,
        reason: 'wondering about 40 PCs must not plan 40 PCs',
      );
      expect(
        find.textContaining('Build a .pkt from this plan'),
        findsNothing,
        reason: 'nothing was built by wondering',
      );
      expect(
        find.textContaining('Nothing in your lab changed'),
        findsWidgets,
        reason: 'the gate says out loud that it changed nothing',
      );

      // And the question it did not answer is still there to be answered -
      // the gate neither resolved nor dismissed it.
      await tester.enterText(_composer(), '25');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('Scale: 25 devices'), findsWidgets);
    });

    testWidgets('A25 could we do it with 40 PCs stays exploratory', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final state = SessionState(
        project: 'P1',
        intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
        requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: state.encode(),
      );
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'could we do it with 40 PCs?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing in your lab changed'), findsWidgets);
      expect(find.textContaining('Scale: 40'), findsNothing);
      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, state.intentJson);
      expect(after.requestOutcomeJson, state.requestOutcomeJson);
      expect(after.knownArtifacts, isEmpty);
    });

    testWidgets('a what-if does not answer the open question either', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('before I plan this'), findsOneWidget);

      // The routing question is open, and this names a protocol - so the
      // tempting reading is "answer: OSPF". It is a wondering about the
      // protocol, not the answer, and it must leave the question open.
      await tester.enterText(_composer(), 'what if we used OSPF instead?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Routing: OSPF'),
        findsNothing,
        reason: 'a what-if must not fill in the open question',
      );
      expect(
        find.textContaining('Nothing in your lab changed'),
        findsWidgets,
        reason: 'the gate says out loud that it changed nothing',
      );

      // The question is still there to be answered properly.
      await tester.enterText(_composer(), '25');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('Scale: 25 devices'), findsWidgets);
      expect(
        find.textContaining('How should the routers route'),
        findsWidgets,
        reason: 'routing is still open - the what-if did not answer it',
      );
    });

    testWidgets('an explanation question does not consume a pending answer', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final before = SessionState.decode(store.savedState!);

      await tester.enterText(
        _composer(),
        'why is OSPF better than static routing?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, before.intentJson);
      expect(after.briefJson, before.briefJson);
      expect(after.pendingQuestionIds, before.pendingQuestionIds);
      expect(store.rememberedClarificationWrites, 0);
    });

    testWidgets(
      'A24 OSPF advice leaves the BASE plan and requirements intact',
      (tester) async {
        _wide(tester);
        final plan = basePlan(project: 'P1');
        final state = SessionState(
          project: 'P1',
          intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: state.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        await tester.enterText(
          _composer(),
          'why is OSPF better than static routing?',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        final answer = store.logged.lastWhere(
          (message) => message.role == 'model',
        );
        expect(answer.text.toLowerCase(), contains('ospf'));
        expect(answer.text.toLowerCase(), contains('static'));
        final after = SessionState.decode(store.savedState!);
        expect(after.intentJson, state.intentJson);
        expect(after.requestOutcomeJson, state.requestOutcomeJson);
        expect(after.knownArtifacts, isEmpty);
      },
    );

    testWidgets(
      'A27 rearranging the layout preserves IPs and cable endpoints',
      (tester) async {
        _wide(tester);
        final plan = basePlan(project: 'P1');
        final state = SessionState(
          project: 'P1',
          intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: state.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        const request = 'only rearrange the layout; keep all IPs and cables';
        expect(LayoutRequest.read(request), isNotNull);
        expect(RequestRouteSelector.isHelpOnly(request), isFalse);
        await tester.enterText(_composer(), request);
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        final after = SessionState.decode(store.savedState!);
        final changed = NetworkIntent.fromJson(jsonDecode(after.intentJson));
        expect(
          changed.nodes.map((node) => node.toJson(includeSecrets: false)),
          plan.nodes.map((node) => node.toJson(includeSecrets: false)),
        );
        expect(
          changed.links.map((link) => link.toJson()),
          plan.links.map((link) => link.toJson()),
        );
        expect(
          changed.addressing.map((address) => address.toJson()),
          plan.addressing.map((address) => address.toJson()),
        );
        expect(changed.routing, plan.routing);
        expect(changed.vlans, plan.vlans);
        expect(
          changed.security.toJson(includeSecrets: false),
          plan.security.toJson(includeSecrets: false),
        );
        expect(
          changed.notes
              .map(LayoutRequest.styleFromNote)
              .where((style) => style.isNotEmpty),
          isNotEmpty,
        );
        expect(find.textContaining('There is no .pkt yet'), findsOneWidget);
        expect(
          find.textContaining('Build a .pkt from this plan'),
          findsNothing,
        );
        expect(after.knownArtifacts, isEmpty);
      },
    );

    testWidgets('A27 a failed layout save keeps the previous plan', (
      tester,
    ) async {
      _wide(tester);
      final plan = basePlan(project: 'P1');
      final state = SessionState(
        project: 'P1',
        intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
        lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
        requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
      );
      final store = _FakeStore(
        transcripts: const {'P1': []},
        stateJson: state.encode(),
      )..failNextSessionStateSave = true;
      await tester.pumpWidget(_chat(store, initialProject: 'P1'));
      await tester.pumpAndSettle();

      await tester.enterText(
        _composer(),
        'only rearrange the layout; keep all IPs and cables',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('I could not save that drawing choice'),
        findsOneWidget,
      );
      final after = SessionState.decode(store.savedState!);
      expect(after.intentJson, state.intentJson);
      expect(after.requestOutcomeJson, state.requestOutcomeJson);
      expect(after.knownArtifacts, isEmpty);
      final restored = NetworkIntent.fromJson(jsonDecode(after.intentJson));
      expect(
        restored.notes
            .map(LayoutRequest.styleFromNote)
            .where((style) => style.isNotEmpty),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('offline reply persistence failures', () {
    testWidgets('a failed final state save is reported and keeps the plan', (
      tester,
    ) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {})..failSessionStateOnAttempt = 2;
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('final conversation state could not be saved'),
        findsOneWidget,
      );
      expect(store.sessionStateWrites, 1);
      expect(
        store.logged.where((message) => message.role == 'model'),
        hasLength(1),
      );
      final state = SessionState.decode(store.savedState ?? '{}');
      final plan = NetworkIntent.fromJson(jsonDecode(state.intentJson));
      final outcome = RequestOutcome.fromJson(
        jsonDecode(state.requestOutcomeJson),
      );
      expect(outcome.candidatePlan?.revision, plan.revision);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed offline transcript save is reported', (tester) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {})..failNextModelLogSave = true;
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('could not be saved in the transcript'),
        findsOneWidget,
      );
      expect(store.sessionStateWrites, 2);
      expect(store.logged.where((message) => message.role == 'model'), isEmpty);
      final state = SessionState.decode(store.savedState ?? '{}');
      final plan = NetworkIntent.fromJson(jsonDecode(state.intentJson));
      final outcome = RequestOutcome.fromJson(
        jsonDecode(state.requestOutcomeJson),
      );
      expect(outcome.candidatePlan?.revision, plan.revision);
      expect(tester.takeException(), isNull);
    });
  });

  group('offline Packet Tracer analysis follow-ups', () {
    Map<String, dynamic> analysis() => {
      'version': 1,
      'name': 'serial.pkt',
      'path': '/labs/serial.pkt',
      'deviceCount': 2,
      'linkCount': 1,
      'devices': const [],
      'interfaces': const [],
      'links': const [],
      'findings': [
        {
          'id': 'Router0:offline:link:1',
          'kind': 'connected_interface_down',
          'severity': 'medium',
          'device': 'Router0 <-> Router1',
          'text':
              'Cabled link Router0 Serial0/2/0 <-> Router1 '
              'Serial0/2/0 has a saved-down endpoint. If active, check both '
              'interfaces and serial clocking. If unused, leaving it down '
              'is normal.',
          'fix_cli': const [],
          'repairs': [
            {
              'id': 'Router0:offline:link:1',
              'device': 'Router0',
              'fix_cli': ['interface Serial0/2/0', 'no shutdown'],
            },
            {
              'id': 'Router0:offline:link:1',
              'device': 'Router1',
              'fix_cli': ['interface Serial0/2/0', 'no shutdown'],
            },
          ],
        },
      ],
    };

    _FakeStore seededStore() {
      final scan = analysis();
      final state = SessionState().withCaptureAnalysis(
        path: '/labs/serial.pkt',
        name: 'serial.pkt',
        analysisJson: jsonEncode(scan),
      );
      return _FakeStore(
        transcripts: {
          'default': [_turn('model', 'Offline review of serial.pkt')],
        },
        stateJson: state.encode(),
      );
    }

    testWidgets('why questions explain the scan without a repair card', (
      tester,
    ) async {
      _wide(tester);
      final store = seededStore();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'why no shutdown is important?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('unused spare port should usually stay shut'),
        findsOneWidget,
      );
      expect(find.text('Create fixed copy'), findsNothing);
      expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
    });

    testWidgets(
      'a specific fix request shows commands and waits for approval',
      (tester) async {
        _wide(tester);
        final store = seededStore();
        await tester.pumpWidget(_chat(store));
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), 'fix Router0 Serial0/2/0');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        expect(find.text('Create fixed copy'), findsOneWidget);
        expect(find.textContaining('no shutdown'), findsWidgets);
        expect(
          find.textContaining('original file stays untouched'),
          findsOneWidget,
        );
        expect(store.logged.where((m) => m.role == 'model'), hasLength(1));
      },
    );
  });

  group('clearing a conversation', () {
    testWidgets('clears this conversation only, and says what goes', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trunk Problem'));
      await tester.pumpAndSettle();

      // Clear lives in the tools sheet now, not as a permanent header icon:
      // it is a destructive action and did not need to sit under the user's
      // thumb through every conversation.
      await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear this conversation'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      // The confirmation now says what is removed: the transcript, its saved
      // summary, its structured state and its change log.
      expect(find.textContaining('summary'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();

      expect(store.cleared, [
        'trunk-lab',
      ], reason: 'one chat was cleared, named');
      expect(
        store.cleared,
        isNot(contains('')),
        reason: 'an empty id means "every conversation" to the store',
      );
      expect(
        store.transcripts.containsKey('routing-lab'),
        isTrue,
        reason: 'the other conversation is untouched',
      );
    });
  });

  group('private mode', () {
    testWidgets('answers without a model and says so', (tester) async {
      _wide(tester);
      final settings = _FakeSettings()..setPrivateForTest(true);
      final store = _seeded();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MemoryService>.value(value: store),
          ],
          child: const MaterialApp(home: Scaffold(body: ChatScreen())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();
      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // Private mode is a promise that nothing leaves the device, so the answer
      // says private mode - which is now the top bar's AI pill, not a line
      // in the chat. The transcript itself stays free of mode labels.
      expect(find.textContaining('Private mode is on'), findsNothing);
      // The plan is still parsed and offered, so offline work keeps working.
      expect(find.textContaining('10 PC(s)'), findsNothing);
      expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
    });
  });

  group('provider and offline turns share the coordinated outcome', () {
    testWidgets('provider success keeps the exact coordinated candidate', (
      tester,
    ) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {});
      final provider = _DeterministicProviderChatService();
      await tester.pumpWidget(
        _chat(
          store,
          settings: _FakeSettings(geminiKey: 'test-key'),
          providerChatServiceOverride: provider,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(provider.calls, 1);
      expect(find.text('The deterministic provider answered.'), findsOneWidget);
      final state = SessionState.decode(store.savedState ?? '{}');
      final plan = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(state.intentJson) as Map),
      );
      final outcome = RequestOutcome.fromJson(
        jsonDecode(state.requestOutcomeJson),
      );
      expect(outcome.disposition, RequestDisposition.commit);
      expect(outcome.candidatePlan?.revision, plan.revision);
      expect(plan.nodes.where((node) => node.type == 'router'), hasLength(2));
      expect(plan.nodes.where((node) => node.type == 'switch'), hasLength(4));
    });

    testWidgets('provider failure falls back without changing the candidate', (
      tester,
    ) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {});
      final provider = _DeterministicProviderChatService(fail: true);
      await tester.pumpWidget(
        _chat(
          store,
          settings: _FakeSettings(geminiKey: 'test-key'),
          providerChatServiceOverride: provider,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(provider.calls, 1);
      expect(
        store.logged.where((message) => message.role == 'model'),
        isNotEmpty,
      );
      final state = SessionState.decode(store.savedState ?? '{}');
      final plan = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(state.intentJson) as Map),
      );
      final outcome = RequestOutcome.fromJson(
        jsonDecode(state.requestOutcomeJson),
      );
      expect(outcome.disposition, RequestDisposition.commit);
      expect(outcome.candidatePlan?.revision, plan.revision);
      expect(plan.nodes.where((node) => node.type == 'router'), hasLength(2));
      expect(plan.nodes.where((node) => node.type == 'switch'), hasLength(4));
    });

    testWidgets(
      'T08 one edit has identical offline, provider, and fallback plans',
      (tester) async {
        _wide(tester);
        final base = basePlan(project: 'P1');
        final initial = SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(base),
        );

        Future<({NetworkIntent plan, RequestOutcome outcome})> runTurn({
          bool providerEnabled = false,
          bool providerFails = false,
        }) async {
          final store = _FakeStore(
            transcripts: const {'P1': []},
            stateJson: initial.encode(),
          );
          final provider = providerEnabled
              ? _DeterministicProviderChatService(fail: providerFails)
              : null;
          await tester.pumpWidget(
            _chat(
              store,
              initialProject: 'P1',
              settings: _FakeSettings(
                geminiKey: providerEnabled ? 'test-key' : '',
              ),
              providerChatServiceOverride: provider,
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(_composer(), 'can you add 2 PCs?');
          await tester.testTextInput.receiveAction(TextInputAction.send);
          await tester.pumpAndSettle();

          if (providerEnabled) expect(provider!.calls, 1);
          final saved = SessionState.decode(store.savedState ?? '{}');
          final plan = NetworkIntent.fromJson(jsonDecode(saved.intentJson));
          final outcome = RequestOutcome.fromJson(
            jsonDecode(saved.requestOutcomeJson),
          );
          expect(outcome.disposition, RequestDisposition.commit);
          expect(outcome.candidatePlan?.revision, plan.revision);
          expect(
            outcome.changeSet?.operations,
            hasLength(1),
            reason: 'one user edit is committed once in every mode',
          );
          expect(
            outcome.interpretation.requirements.any(
              (requirement) =>
                  requirement.property == 'protocol' &&
                  requirement.value == 'static',
            ),
            isTrue,
            reason: 'the original explicit requirement survives the edit',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          return (plan: plan, outcome: outcome);
        }

        final offline = await runTurn();
        final providerSuccess = await runTurn(providerEnabled: true);
        final providerFallback = await runTurn(
          providerEnabled: true,
          providerFails: true,
        );

        expect(
          providerSuccess.plan.toPlannerJson(),
          offline.plan.toPlannerJson(),
        );
        expect(
          providerFallback.plan.toPlannerJson(),
          offline.plan.toPlannerJson(),
        );
        expect(
          offline.plan.nodes.where((node) => node.type == 'pc'),
          hasLength(12),
        );
        expect(offline.plan.routing, 'static');
      },
    );

    testWidgets(
      'A43 provider timeout on an edit applies the supported change once',
      (tester) async {
        _wide(tester);
        final plan = basePlan(project: 'P1');
        final originalState = SessionState(
          project: 'P1',
          intentJson: jsonEncode(plan.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(plan),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: originalState.encode(),
        );
        final provider = _DeterministicProviderChatService(
          failure: TimeoutException('synthetic provider timeout'),
        );
        await tester.pumpWidget(
          _chat(
            store,
            initialProject: 'P1',
            settings: _FakeSettings(geminiKey: 'test-key'),
            providerChatServiceOverride: provider,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), 'can you add 2 PCs?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        expect(provider.calls, 1);
        expect(find.text('The deterministic provider answered.'), findsNothing);
        final persisted = SessionState.decode(store.savedState ?? '{}');
        final committed = NetworkIntent.fromJson(
          jsonDecode(persisted.intentJson),
        );
        final outcome = RequestOutcome.fromJson(
          jsonDecode(persisted.requestOutcomeJson),
        );
        expect(outcome.disposition, RequestDisposition.commit);
        expect(outcome.candidatePlan?.revision, committed.revision);
        expect(
          committed.nodes.where((node) => node.type == 'pc'),
          hasLength(12),
        );
        expect(
          committed.nodes.where((node) => node.type == 'router'),
          hasLength(2),
        );
        expect(
          committed.nodes.where((node) => node.type == 'switch'),
          hasLength(2),
        );
        expect(committed.routing, 'static');
        expect(
          outcome.changeSet?.operations,
          hasLength(1),
          reason: 'the provider failure must not cause a second plan edit',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('memory unavailable labels a plan outcome as temporary', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: _FakeSettings(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ChatScreen(initialProject: 'P1')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      const request = '2 routers and 4 switches';
      await tester.enterText(_composer(), request);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.textContaining('2 routers and 4 switches'), findsWidgets);
      expect(
        find.textContaining('temporary because local storage is unavailable'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data)
            .whereType<String>()
            .join(' | '),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a failed final session save is reported after provider success',
      (tester) async {
        _wide(tester);
        final store = _FakeStore(transcripts: {});
        final providerStarted = Completer<void>();
        final releaseProvider = Completer<void>();
        final provider = _DeterministicProviderChatService(
          started: [providerStarted],
          release: [releaseProvider],
        );
        await tester.pumpWidget(
          _chat(
            store,
            settings: _FakeSettings(geminiKey: 'test-key'),
            providerChatServiceOverride: provider,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), '2 routers and 4 switches');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (var i = 0; i < 120 && !providerStarted.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(providerStarted.isCompleted, isTrue);
        expect(store.sessionStateWrites, 1);

        store.failNextSessionStateSave = true;
        releaseProvider.complete();
        await tester.pumpAndSettle();

        expect(
          find.text('The deterministic provider answered.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('final conversation state could not be saved'),
          findsOneWidget,
        );
        expect(
          store.logged.where((message) => message.role == 'model'),
          hasLength(1),
        );
        expect(store.sessionStateWrites, 1);
        final state = SessionState.decode(store.savedState ?? '{}');
        final plan = NetworkIntent.fromJson(jsonDecode(state.intentJson));
        final outcome = RequestOutcome.fromJson(
          jsonDecode(state.requestOutcomeJson),
        );
        expect(outcome.candidatePlan?.revision, plan.revision);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a failed model transcript save is reported and state is saved',
      (tester) async {
        _wide(tester);
        final store = _FakeStore(transcripts: {});
        final providerStarted = Completer<void>();
        final releaseProvider = Completer<void>();
        final provider = _DeterministicProviderChatService(
          started: [providerStarted],
          release: [releaseProvider],
        );
        await tester.pumpWidget(
          _chat(
            store,
            settings: _FakeSettings(geminiKey: 'test-key'),
            providerChatServiceOverride: provider,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), '2 routers and 4 switches');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (var i = 0; i < 120 && !providerStarted.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(providerStarted.isCompleted, isTrue);
        store.failNextModelLogSave = true;
        releaseProvider.complete();
        await tester.pumpAndSettle();

        expect(
          find.text('The deterministic provider answered.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('could not be saved in the transcript'),
          findsOneWidget,
        );
        expect(
          store.logged.where((message) => message.role == 'model'),
          isEmpty,
        );
        expect(store.sessionStateWrites, 2);
        final state = SessionState.decode(store.savedState ?? '{}');
        final plan = NetworkIntent.fromJson(jsonDecode(state.intentJson));
        final outcome = RequestOutcome.fromJson(
          jsonDecode(state.requestOutcomeJson),
        );
        expect(outcome.candidatePlan?.revision, plan.revision);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('stopping before the plan snapshot commits rolls it back', (
      tester,
    ) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {});
      final userLogStarted = Completer<void>();
      final releaseUserLog = Completer<int>();
      store
        ..userLogStarted = userLogStarted
        ..delayedUserLog = releaseUserLog;
      final provider = _DeterministicProviderChatService();
      await tester.pumpWidget(
        _chat(
          store,
          settings: _FakeSettings(geminiKey: 'test-key'),
          providerChatServiceOverride: provider,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      for (var i = 0; i < 120 && !userLogStarted.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(userLogStarted.isCompleted, isTrue);
      expect(provider.calls, 0);
      expect(store.sessionStateWrites, 0);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      releaseUserLog.complete(1);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(provider.calls, 0);
      expect(store.savedState, isNull);
      expect(store.sessionStateWrites, 0);
      expect(store.logged.where((message) => message.role == 'model'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a stopped turn holds the composer until its plan save settles',
      (tester) async {
        _wide(tester);
        final store = _FakeStore(transcripts: {});
        final sessionSaveStarted = Completer<void>();
        final releaseSessionSave = Completer<void>();
        store
          ..sessionStateSaveStarted = sessionSaveStarted
          ..delayedSessionStateSave = releaseSessionSave;
        final provider = _DeterministicProviderChatService();
        await tester.pumpWidget(
          _chat(
            store,
            settings: _FakeSettings(geminiKey: 'test-key'),
            providerChatServiceOverride: provider,
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), '2 routers and 4 switches');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        for (var i = 0; i < 120 && !sessionSaveStarted.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(sessionSaveStarted.isCompleted, isTrue);
        expect(provider.calls, 0);
        expect(store.sessionStateWrites, 1);

        await tester.tap(find.byIcon(Icons.stop));
        await tester.pump();
        expect(find.byTooltip('Saving requested change'), findsOneWidget);

        // A second request can be typed, but cannot enter persistence while the
        // first turn's snapshot is unresolved.
        await tester.enterText(_composer(), '2 routers and 4 switches');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        expect(store.sessionStateWrites, 1);
        expect(provider.calls, 0);

        releaseSessionSave.complete();
        await tester.pumpAndSettle();
        expect(provider.calls, 0);
        expect(store.sessionStateWrites, 1);
        final firstState = SessionState.decode(store.savedState ?? '{}');
        final firstPlan = NetworkIntent.fromJson(
          Map<String, dynamic>.from(jsonDecode(firstState.intentJson) as Map),
        );
        expect(
          firstPlan.nodes.where((node) => node.type == 'router'),
          hasLength(2),
        );
        expect(
          firstPlan.nodes.where((node) => node.type == 'switch'),
          hasLength(4),
        );
        expect(
          store.logged.where((message) => message.role == 'model'),
          isEmpty,
        );

        // The second request stayed in the composer and can be sent after the
        // first snapshot has settled.
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          '2 routers and 4 switches',
        );
        expect(find.byTooltip('Send'), findsOneWidget);
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(provider.calls, 1);
        expect(store.sessionStateWrites, 3);
        expect(
          find.text('The deterministic provider answered.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a late stopped stream cannot finish or reset a newer turn', (
      tester,
    ) async {
      _wide(tester);
      final store = _FakeStore(transcripts: {});
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final releaseSecond = Completer<void>();
      final provider = _DeterministicProviderChatService(
        started: [firstStarted, secondStarted],
        release: [releaseFirst, releaseSecond],
      );
      await tester.pumpWidget(
        _chat(
          store,
          settings: _FakeSettings(geminiKey: 'test-key'),
          providerChatServiceOverride: provider,
        ),
      );
      await tester.pumpAndSettle();

      const firstRequest = '2 routers and 4 switches';
      const secondRequest = '2 routers and 6 switches';
      await tester.enterText(_composer(), firstRequest);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      for (var i = 0; i < 120 && !firstStarted.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(firstStarted.isCompleted, isTrue);
      expect(store.sessionStateWrites, 1);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();

      // Start a different edit while the old transport is still parked. The
      // old result must not apply its inventory to the new request.
      await tester.enterText(_composer(), secondRequest);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      for (var i = 0; i < 120 && !secondStarted.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(secondStarted.isCompleted, isTrue);
      expect(store.sessionStateWrites, 2);

      releaseFirst.complete();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        find.byIcon(Icons.stop),
        findsOneWidget,
        reason: 'the stale turn must not clear the newer turn\'s busy state',
      );
      expect(store.sessionStateWrites, 2);
      expect(
        store.logged.where((message) => message.role == 'model'),
        isEmpty,
        reason: 'the stopped provider result must not be finalized or saved',
      );

      releaseSecond.complete();
      await tester.pumpAndSettle();

      expect(
        find.text('The deterministic provider answered call 2.'),
        findsOneWidget,
      );
      expect(
        store.logged.where((message) => message.role == 'model'),
        hasLength(1),
      );
      expect(store.sessionStateWrites, 3);
      final state = SessionState.decode(store.savedState ?? '{}');
      final plan = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(state.intentJson) as Map),
      );
      final outcome = RequestOutcome.fromJson(
        jsonDecode(state.requestOutcomeJson),
      );
      expect(outcome.candidatePlan?.revision, plan.revision);
      expect(plan.nodes.where((node) => node.type == 'router'), hasLength(2));
      expect(plan.nodes.where((node) => node.type == 'switch'), hasLength(6));
      expect(find.textContaining('Packet Tracer file:'), findsNothing);
    });
  });

  group('fast offline conversation', () {
    testWidgets(
      'a plain hello is answered immediately without a thinking turn',
      (tester) async {
        _wide(tester);
        final store = _FakeStore(transcripts: {});
        await tester.pumpWidget(_chat(store));
        await tester.pumpAndSettle();

        await tester.enterText(_composer(), 'hello');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        expect(find.text('hello'), findsOneWidget);
        expect(find.text('Thinking...'), findsNothing);
        expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
        expect(store.logged.where((m) => m.role == 'model'), hasLength(1));
        expect(
          store.logged.singleWhere((m) => m.role == 'model').text.toLowerCase(),
          contains('offline'),
        );
      },
    );

    testWidgets('a greeting stays fast when this chat already has a lab', (
      tester,
    ) async {
      _wide(tester);
      final plan = NetworkIntent.parseSimple(
        'office',
        '2 routers and 1 switch',
      );
      final state = SessionState()..withIntentJson(jsonEncode(plan.toJson()));
      final store = _FakeStore(transcripts: {}, stateJson: state.encode());
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.text('Thinking...'), findsNothing);
      expect(find.textContaining('Read as: a greeting'), findsNothing);
      expect(
        store.logged.singleWhere((m) => m.role == 'model').text.toLowerCase(),
        contains('offline'),
      );
    });
  });

  group('the context report tells the truth about the window', () {
    testWidgets('it names the runtime window when it is asked for', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      // Nothing is painted under the transcript any more. The same report is
      // in the tools sheet, which is where a report belongs: asked for, not
      // always on.
      expect(find.textContaining('Context '), findsNothing);

      await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Context report'));
      await tester.pumpAndSettle();

      // The inspector says what the request carried. With no request sent yet
      // it says that too - rather than showing a stale number.
      expect(find.textContaining('tokens'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('the "/" skills menu', () {
    testWidgets('opens while a command is typed, and steps aside for '
        'arguments', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '/');
      await tester.pumpAndSettle();
      expect(find.textContaining('Skills - tap one'), findsOneWidget);
      expect(find.text('Write a .pkt'), findsOneWidget);
      expect(find.text('Read a .pkt'), findsOneWidget);

      // A space means an argument has started: the menu steps aside.
      await tester.enterText(_composer(), '/scan ');
      await tester.pumpAndSettle();
      expect(find.textContaining('Skills - tap one'), findsNothing);

      // Ordinary text never opens it.
      await tester.enterText(_composer(), 'hello');
      await tester.pumpAndSettle();
      expect(find.textContaining('Skills - tap one'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tapped skill lands in the composer instead of sending', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo the last change'));
      await tester.pumpAndSettle();

      // Inserted, not sent: the user still decides when it goes.
      final field = tester.widget<TextField>(_composer());
      expect(field.controller?.text, 'undo that');
      expect(find.textContaining('Skills - tap one'), findsNothing);
      // Nothing left the composer as a message.
      expect(store.logged.where((m) => m.role == 'user'), isEmpty);
    });

    testWidgets('Enter on a partial command completes it and runs it', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '/sk');
      await tester.pumpAndSettle();
      expect(find.text('List every skill'), findsOneWidget);
      // No re-tap: the composer must still hold the connection after the
      // menu opened, or the keyboard flickers shut for a real user.
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // "/sk" completed to "/skills", which answered in the chat itself.
      expect(find.textContaining('What this app can do'), findsOneWidget);
      expect(
        find.textContaining('Read a .pkt'),
        findsOneWidget,
        reason: 'the catalog itself is readable text',
      );
    });

    testWidgets('/target switches where builds are aimed, and says so', (
      tester,
    ) async {
      _wide(tester);
      final settings = _FakeSettings();
      await tester.pumpWidget(_chat(_seeded(), settings: settings));
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '/target cisco-ssh');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(settings.lastTarget, 'cisco-ssh');
      expect(find.textContaining('Target set to'), findsOneWidget);

      // An unknown target is refused by name, with the real list.
      await tester.enterText(_composer(), '/target banana');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        settings.lastTarget,
        'cisco-ssh',
        reason: 'a refused switch must not change anything',
      );
      expect(find.textContaining('Unknown target'), findsOneWidget);
    });
  });

  group('rewriting history in place', () {
    testWidgets('"Answer again" replaces the last answer instead of stacking '
        'a duplicate', (tester) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trunk Problem'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More message actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer again'));
      await tester.pumpAndSettle();

      // The store was asked to cut from the last user turn, and from no
      // other conversation than the one that is open.
      expect(store.truncations, hasLength(1));
      final cut = store.truncations.single;
      expect(cut.conversation, 'trunk-lab');
      expect(cut.fromRole, 'user');
      expect(cut.fromText, 'why is the trunk down?');
      expect(
        store.transcripts['trunk-lab'],
        isEmpty,
        reason: 'the old turn is gone from the store, not just the screen',
      );

      // The old answer does not survive under the new one...
      expect(find.text('SW1 f0/1 is not trunking.'), findsNothing);
      // ...and the same question went out again as a fresh turn, stored.
      expect(
        store.logged.where((m) => m.role == 'user').map((m) => m.text),
        contains('why is the trunk down?'),
      );
      // One user bubble on screen: the resent turn, not the resent turn plus
      // a leftover copy.
      expect(find.text('why is the trunk down?'), findsOneWidget);
    });

    testWidgets('editing a user message rewinds the answer and replaces the '
        'same turn on send', (tester) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trunk Problem'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      // The answer branch is removed from the store and screen immediately;
      // the original user turn stays in place until the edit is sent.
      expect(store.truncations, hasLength(1));
      expect(store.truncations.single.conversation, 'trunk-lab');
      expect(store.truncations.single.fromText, 'SW1 f0/1 is not trunking.');
      expect(store.transcripts['trunk-lab'], hasLength(1));
      expect(
        store.transcripts['trunk-lab']!.single.text,
        'why is the trunk down?',
      );
      expect(find.text('SW1 f0/1 is not trunking.'), findsNothing);

      // The original words are back in the composer for editing, and the
      // inline status makes clear that sending replaces this turn.
      final composer = tester.widget<TextField>(_composer());
      expect(composer.controller?.text, 'why is the trunk down?');
      expect(
        find.text('Editing your message. Sending replaces this turn.'),
        findsOneWidget,
      );
      // Nothing was sent by choosing to edit.
      expect(store.logged.where((m) => m.role == 'user'), isEmpty);

      // Sending the edit goes out as a fresh turn.
      await tester.enterText(_composer(), 'why is the trunk down on SW1?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        store.logged.where((m) => m.role == 'user').map((m) => m.text).last,
        'why is the trunk down on SW1?',
      );
      expect(
        store.transcripts['trunk-lab']!
            .where((message) => message.isUser)
            .map((message) => message.text),
        ['why is the trunk down on SW1?'],
        reason: 'editing replaces the prior turn instead of adding a copy',
      );
      expect(
        find.text('why is the trunk down on SW1?'),
        findsOneWidget,
        reason: 'the edited turn took the old one\'s place',
      );
    });
  });

  group('the in-conversation search', () {
    testWidgets('finds the turn, says where it is, and jumps to it', (
      tester,
    ) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trunk Problem'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search in this conversation'));
      await tester.pumpAndSettle();

      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Search this conversation',
      );
      // A hit from another conversation must not leak in: this search reads
      // the open transcript only.
      await tester.enterText(field, 'R7');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.textContaining(
            'No messages in this conversation match that.',
          ),
        ),
        findsOneWidget,
      );

      await tester.enterText(field, 'trunk');
      await tester.pumpAndSettle();
      final hit = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('why is the trunk down?'),
      );
      expect(
        hit,
        findsOneWidget,
        reason: 'the hit shows the line it was found on',
      );

      await tester.tap(hit);
      await tester.pumpAndSettle();
      // The sheet closed to take the reader to the turn, and nothing threw
      // on the way (the jump is allowed to no-op on a message that is not
      // staged - it is never allowed to crash).
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the transcript export', () {
    test('the shared document is markdown a ticket can quote', () {
      final doc = ChatScreen.transcriptMarkdown(
        const [
          ChatMessage(
            role: 'user',
            text: 'fix this:\n```\nip route 0.0.0.0 0.0.0.0 10.0.0.1\n```',
            createdAt: '2026-01-01T10:30:00',
          ),
          ChatMessage(
            role: 'model',
            text: 'The gateway is on the wrong side.',
            createdAt: '2026-01-01T10:31:00',
          ),
          ChatMessage(
            role: 'system',
            text: 'Saved.',
            createdAt: '2026-01-01T10:32:00',
          ),
          ChatMessage(role: 'user', text: '   '),
        ],
        conversation: 'trunk-lab',
        exportedAt: DateTime.parse('2026-01-02T08:00:00'),
      );
      expect(doc, startsWith('# NetBuilder chat - trunk-lab\n'));
      expect(doc, contains('Exported 2026-01-02T08:00:00.000 - 4 messages.'));
      expect(doc, contains('**You** (10:30):'));
      // Fenced code goes out verbatim, still fenced and runnable.
      expect(doc, contains('```\nip route 0.0.0.0 0.0.0.0 10.0.0.1\n```'));
      expect(doc, contains('**Assistant** (10:31):'));
      expect(doc, contains('**App** (10:32):'));
      expect(doc, contains('**You**:\n'), reason: 'a blank turn says so');
      expect(doc, contains('_(no text)_'));
    });

    testWidgets('"Share the transcript" lives in the tools sheet and an '
        'empty conversation is said out loud', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tools: run, capture, and integrations'));
      await tester.pumpAndSettle();
      expect(find.text('Share the transcript'), findsOneWidget);
      await tester.tap(find.text('Share the transcript'));
      await tester.pumpAndSettle();

      // Nothing to share is an answer in the chat, not a silent no-op - and
      // the share sheet is never asked for an empty document.
      expect(find.textContaining('Nothing to share yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the parse can be argued with', () {
    testWidgets('a count chip fixes the plan where the user can see it', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.text('Understood'), findsOneWidget);
      expect(find.text('2 routers'), findsOneWidget);

      // The chip is not only a label. Tapping it asks for the number that
      // was actually meant, and the plan on screen is the thing that
      // changes - no re-typed English, no "maybe I said it differently".
      await tester.tap(find.text('2 routers'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget, reason: 'the fix asks for a value');
      await tester.enterText(field, '5');
      await tester.tap(find.text('Fix it'));
      await tester.pumpAndSettle();

      expect(find.text('5 routers'), findsOneWidget);
      expect(
        find.text('2 routers'),
        findsNothing,
        reason: 'the wrong parse must not still be on screen',
      );
      // A correction is never silent: the card says what it became.
      expect(find.textContaining('Fixed: 5 routers'), findsOneWidget);
      expect(find.text('Understood'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fix the user backs out of changes nothing', (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      await tester.tap(find.text('2 routers'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '9',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('2 routers'), findsOneWidget);
      expect(find.text('9 routers'), findsNothing);
      expect(find.textContaining('Fixed:'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the routing protocol is a slot too, and it is always shown', (
      tester,
    ) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      // A default nobody chose is exactly what a user wants to argue with,
      // so the routing chip is on the card even when it says STATIC.
      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('STATIC'), findsOneWidget);

      await tester.tap(find.text('STATIC'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'ospf',
      );
      await tester.tap(find.text('Fix it'));
      await tester.pumpAndSettle();

      expect(find.text('OSPF'), findsAtLeastNWidgets(1));
      expect(find.textContaining('Fixed: ospf'), findsOneWidget);
    });
  });

  group('A52 a configuration review does not change the project', () {
    const paste = '''
Building configuration...

Current configuration : 980 bytes
!
hostname R1
!
interface GigabitEthernet0/0
 ip address 10.0.0.1 255.255.255.0
 no shutdown
!
line vty 0 4
 password letmein
 login
 transport input telnet
!
end
''';

    testWidgets(
      'the pasted config is explained and the saved lab is retained',
      (tester) async {
        _wide(tester);
        final base = basePlan(project: 'P1');
        final initial = SessionState(
          project: 'P1',
          intentJson: jsonEncode(base.toJson(includeSecrets: false)),
          lastBrief: '2 routers, 2 switches, 10 PCs; use static routing',
          requestOutcomeJson: _baseOutcomeWithExplicitStaticRouting(base),
        );
        final store = _FakeStore(
          transcripts: const {'P1': []},
          stateJson: initial.encode(),
        );
        await tester.pumpWidget(_chat(store, initialProject: 'P1'));
        await tester.pumpAndSettle();

        await tester.enterText(
          _composer(),
          'explain this, do not change my project\n\n$paste',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();

        // The review is the answer: device named, the telnet finding present.
        expect(find.textContaining('Config review - R1'), findsOneWidget);
        expect(find.textContaining('cleartext'), findsOneWidget);
        final persisted = SessionState.decode(
          store.savedState ?? initial.encode(),
        );
        final retained = NetworkIntent.fromJson(
          jsonDecode(persisted.intentJson),
        );
        expect(semanticSnapshot(retained), semanticSnapshot(base));
        expect(persisted.requestOutcomeJson, initial.requestOutcomeJson);
        expect(find.text('Build .pkt'), findsNothing);
      },
    );
  });
}

void _noop() {}
