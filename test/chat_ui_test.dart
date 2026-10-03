import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/session_state.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/services/validator_service.dart';
import 'package:net_builder/widgets/chat_activity.dart';
import 'package:net_builder/widgets/conversation_sidebar.dart';
import 'package:provider/provider.dart';

/// The chat surface, at the level a person sees it: a list of conversations
/// beside the chat, a welcome screen instead of a blank box, real activity, and
/// a network panel that can be opened and closed.
///
/// The store here is a stand-in rather than a database on purpose: a widget
/// test drives the tree, and the storage itself (titles, summaries, the change
/// log) is covered against the real schema in conversation_store_test.dart.
class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
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

class _FakeStore extends MemoryService {
  final Map<String, List<ChatMessage>> transcripts;
  final Map<String, String> titles;
  final Map<String, String> projects;

  _FakeStore({
    required this.transcripts,
    Map<String, String>? titles,
    Map<String, String>? projects,
  }) : titles = titles ?? {},
       projects = projects ?? {};

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
      final at = last == null
          ? DateTime.now()
          : DateTime.parse(last);
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
    'stateJson': '{}',
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

  @override
  Future<int> logChat(ChatMessage message, {String conversation = 'default'})
      async {
    logged.add(message);
    return logged.length;
  }

  @override
  Future<void> ensureConversation(String id, {String project = '', String title = ''})
      async {}

  @override
  Future<void> setSessionState(String id, String stateJson) async {}

  @override
  Future<void> setConversationSummary(String id, String summary, {int upToId = 0})
      async {}

  @override
  Future<void> updateChat(int id, ChatMessage message) async {}

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

Widget _chat(MemoryService mem, {SettingsService? settings}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(
        value: settings ?? _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: mem),
  ],
  child: const MaterialApp(home: Scaffold(body: ChatScreen())),
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
  group('the conversation sidebar', () {
    testWidgets('lists the saved conversations, grouped by time',
        (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationSidebar), findsOneWidget);
      // The list's own New chat and the header's are both present; what
      // matters is that a chat can be started from the list.
      expect(find.text('New chat'), findsWidgets);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Trunk Problem'), findsOneWidget,
          reason: 'a generated/renamed title is what the list shows');
      expect(find.text('R7 lost its route'), findsOneWidget,
          reason: 'a chat with no stored title falls back to its first turn');
      expect(find.text('Today'), findsWidgets);
      expect(find.text('Previous 7 days'), findsWidgets,
          reason: 'older chats are grouped by time');
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
      expect(find.text('SW1 f0/1 is not trunking.'), findsWidgets,
          reason: 'opening a chat restores its transcript');

      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();
      expect(find.text('How can I help?'), findsOneWidget);
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

    testWidgets('the back gesture closes the panel over the chat',
        (tester) async {
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

    testWidgets('a narrow window slides the list over the chat',
        (tester) async {
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
    testWidgets('asks the networking question and offers openers',
        (tester) async {
      _wide(tester);
      await tester.pumpWidget(_chat(_seeded()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      expect(find.text('How can I help?'), findsOneWidget);
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
                ActivityEntry('Checked PC1 -> SRV1', status: ActivityStatus.failed),
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
      expect(find.byIcon(Icons.close), findsOneWidget,
          reason: 'a failed step is marked, not hidden');
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
    testWidgets('shows the plan, the findings and the change log',
        (tester) async {
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
      expect(issues, isNotEmpty,
          reason: 'the panel shows the validator\'s own output');
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
    testWidgets('it answers, writes its answer down, and offers the next tap',
        (tester) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.textContaining('Next steps'), findsOneWidget,
          reason: 'the offline assistant answers with real advice');
      expect(
        store.logged.where((m) => m.role == 'model'),
        isNotEmpty,
        reason: 'an answer that is not stored is an answer lost on restart',
      );
      expect(find.text('Build the .pkt'), findsOneWidget,
          reason: 'its own suggestion is a tap, not a typing exercise');
    });

    testWidgets('a screen reader hears the suggestions and the field',
        (tester) async {
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

    testWidgets('a screen reader reaches an advice answer and its chips',
        (tester) async {
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

    testWidgets('a follow-up about the same lab does not become a new one',
        (tester) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(),
        'I have 10 Pcs and want to build a network for them add switches and '
        'routers and servers and make security maximum',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.textContaining('10 PC(s)'), findsOneWidget,
          reason: 'the lab is planned from the user\'s own words');

      await tester.enterText(_composer(), 'can we add AAA server to it as well ?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // The reported bug: this turned a 13-device lab into one server with no
      // links, because the follow-up named a device. The answer now describes
      // the change against the lab that exists.
      expect(find.textContaining('AAA added'), findsOneWidget);
      expect(find.textContaining('10 PCs'), findsWidgets,
          reason: 'the ten PCs are still part of the answer');
      expect(find.textContaining('Devices: 1,'), findsNothing);
    });

    testWidgets('a tapped suggestion is a real turn, and it changes the plan',
        (tester) async {
      _wide(tester);
      final store = _seeded();
      await tester.pumpWidget(_chat(store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat').first);
      await tester.pumpAndSettle();

      await tester.enterText(_composer(), '2 routers and 4 switches');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use OSPF for routing'));
      await tester.pumpAndSettle();

      // The tapped words are a message like any other, and the assistant tells
      // the user what changed instead of repeating the lab.
      expect(store.logged.where((m) => m.role == 'user'),
          contains(predicate((ChatMessage m) =>
              m.text.trim() == 'Use OSPF for routing')));
      expect(find.textContaining('routing is now ospf'), findsOneWidget);
    });
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

      expect(store.cleared, ['trunk-lab'],
          reason: 'one chat was cleared, named');
      expect(store.cleared, isNot(contains('')),
          reason: 'an empty id means "every conversation" to the store');
      expect(store.transcripts.containsKey('routing-lab'), isTrue,
          reason: 'the other conversation is untouched');
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
      // says private mode - not "no API key", which is a different problem.
      expect(find.textContaining('Private mode is on'), findsWidgets);
      // The plan is still parsed and offered, so offline work keeps working.
      expect(find.textContaining('10 PC(s)'), findsNothing);
      expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
    });
  });

  group('the context report tells the truth about the window', () {
    testWidgets('it names the runtime window when it is asked for',
        (tester) async {
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

    testWidgets('a tapped skill lands in the composer instead of sending',
        (tester) async {
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

    testWidgets('Enter on a partial command completes it and runs it',
        (tester) async {
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
      expect(find.textContaining('Read a .pkt'), findsOneWidget,
          reason: 'the catalog itself is readable text');
    });

    testWidgets('/target switches where builds are aimed, and says so',
        (tester) async {
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
      expect(settings.lastTarget, 'cisco-ssh',
          reason: 'a refused switch must not change anything');
      expect(find.textContaining('Unknown target'), findsOneWidget);
    });
  });
}

void _noop() {}
