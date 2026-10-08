import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/session_state.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_platform_interface/src/method_channel_path_provider.dart';
import 'package:provider/provider.dart';

/// An on-device build writes into the app's documents directory, which no
/// test platform provides: answer the plugin with a scratch path.
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => 'build/test-docs';
}

/// The conversation-level half of "edit it": once a .pkt exists, saying
/// "edit it" must offer a choice instead of quietly building a second file.
///
/// The store is a stand-in (the schema itself is covered against real SQLite
/// in conversation_store_test.dart); what matters here is which turns the
/// screen produces and what it offers.
class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
  @override
  Future<String?> getOpenAiKey() async => '';
}

class _FakeStore extends MemoryService {
  final Map<String, List<ChatMessage>> transcripts = {};
  final Map<String, String> state = {};
  final List<ChatMessage> logged = [];

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
  }) async => const [];

  @override
  Future<Map<String, dynamic>?> conversationMeta(String id) async => {
        'id': id,
        'title': 'Lab',
        'project': 'lab',
        'summary': '',
        'stateJson': state[id] ?? '{}',
      };

  @override
  Future<List<Map<String, dynamic>>> recentChanges({
    String conversation = '',
    String device = '',
    int limit = 50,
  }) async => const [];

  @override
  Future<int> logChat(
    ChatMessage message, {
    String conversation = 'default',
  }) async {
    logged.add(message);
    transcripts.putIfAbsent(conversation, () => []).add(message);
    return logged.length;
  }

  @override
  Future<void> ensureConversation(
    String id, {
    String project = '',
    String title = '',
  }) async {}

  @override
  Future<void> setSessionState(String id, String stateJson) async {
    state[id] = stateJson;
  }

  @override
  Future<void> setConversationSummary(
    String id,
    String summary, {
    int upToId = 0,
  }) async {}
}

Finder _composer() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );

Future<void> _wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1500, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A conversation that already produced a file: the state says so, exactly as
/// it would after the build that wrote it.
_FakeStore _withArtifact({String path = 'C:/out/serial-lab.pkt'}) {
  final store = _FakeStore();
  final name = path.split(RegExp(r'[/\\]')).last;
  final state = SessionState()
      .withArtifact(path, name: name, updatedAt: '2026-09-26T10:00:00')
      .withIntentJson(
        '{"projectName":"serial-lab","routing":"ospf","nodes":[],'
        '"links":[],"notes":[],"vlans":[],"addressing":[],"security":{}}',
      );
  store.state['default'] = state.encode();
  return store;
}

Widget _chat(MemoryService mem) => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: mem),
  ],
  child: const MaterialApp(home: Scaffold(body: ChatScreen())),
);

/// A turn that ends in an on-device build loads bundled assets through the
/// platform asset channel, which inside a fake-async test only progresses
/// when real time is given back between pumps. Pumps with drains reach the
/// same settled state pumpAndSettle would, while letting that channel run.
Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_composer(), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

void main() {
  setUp(() {
    // An in-place edit on this device rebuilds the file with the bundled
    // template library, which writes into the documents directory.
    PathProviderPlatform.instance = _FakePathProvider();
  });
  tearDown(() => PathProviderPlatform.instance = MethodChannelPathProvider());

  testWidgets('"edit it" edits the one file instead of asking or rebuilding', (
    tester,
  ) async {
    await _wide(tester);
    final store = _withArtifact();
    await tester.pumpWidget(_chat(store));
    await tester.pumpAndSettle();

    await _send(tester, 'edit it');

    // One file exists and the user pointed at it, so the app edits it. No
    // question is asked: the answer to "edit the file" is not "which file?".
    expect(find.textContaining('not going to quietly build a'), findsNothing);
    expect(
      find.textContaining('Create a new .pkt from the same plan'),
      findsNothing,
    );
    // The in-place edit path is what ran, and it names the file it rewrites.
    expect(find.textContaining('Editing the file in place'), findsOneWidget);
    expect(find.textContaining('serial-lab.pkt'), findsWidgets);
    // A second .pkt was never generated on its own.
    expect(find.textContaining('Built a .pkt from your plan'), findsNothing);
  });

  testWidgets('a named file is edited even when the conversation has several', (
    tester,
  ) async {
    await _wide(tester);
    final store = _withArtifact();
    // A second build in the same conversation: now the target really could be
    // either file, and the named one decides.
    final state = SessionState.decode(store.state['default']!)
        .withArtifact(
          'C:/out/two-router-lab.pkt',
          name: 'two-router-lab.pkt',
          updatedAt: '2026-09-27T10:00:00',
        );
    store.state['default'] = state.encode();
    await tester.pumpWidget(_chat(store));
    await tester.pumpAndSettle();

    await _send(tester, 'edit serial-lab.pkt and make it 3 routers');

    expect(find.textContaining('not going to quietly build a'), findsNothing);
    expect(find.textContaining('Editing the file in place'), findsOneWidget);
    expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
  });

  testWidgets('several files and no name is the one case that asks', (
    tester,
  ) async {
    await _wide(tester);
    final store = _withArtifact();
    final state = SessionState.decode(store.state['default']!)
        .withArtifact(
          'C:/out/two-router-lab.pkt',
          name: 'two-router-lab.pkt',
          updatedAt: '2026-09-27T10:00:00',
        );
    store.state['default'] = state.encode();
    await tester.pumpWidget(_chat(store));
    await tester.pumpAndSettle();

    await _send(tester, 'edit it');

    expect(find.textContaining('which'), findsWidgets);
    expect(find.text('Create a new file instead'), findsOneWidget);
    expect(find.textContaining('Built a .pkt from your plan'), findsNothing);
  });

  testWidgets('"a new file instead" is not a request to edit', (
    tester,
  ) async {
    await _wide(tester);
    await tester.pumpWidget(_chat(_withArtifact()));
    await tester.pumpAndSettle();

    // A clear "new one" is not a question, so no choice is offered: the plan is
    // planned and the ordinary build card is what appears.
    await _send(tester, 'make a new file with 3 routers');

    expect(find.textContaining('not going to quietly build a'), findsNothing);
    expect(
      find.textContaining('Edit serial-lab.pkt in place'),
      findsNothing,
    );
  });

  testWidgets('a file with no saved plan is named, and not overwritten', (
    tester,
  ) async {
    await _wide(tester);
    // An artifact from an older conversation: the file is remembered, the plan
    // it was built from is not. Editing it would mean writing a network nobody
    // can see, so the app says which file it means and stops.
    final store = _FakeStore();
    store.state['default'] = SessionState()
        .withArtifact(
          'C:/out/serial-lab.pkt',
          name: 'serial-lab.pkt',
          updatedAt: '2026-09-26T10:00:00',
        )
        .encode();
    await tester.pumpWidget(_chat(store));
    await tester.pumpAndSettle();

    await _send(tester, 'edit it and make one server an AAA server');

    // The file is named, and the edit words are NOT compiled over it: what
    // this turn parsed is one server, and writing that would replace the lab.
    expect(find.textContaining('will not rewrite a file'), findsOneWidget);
    expect(find.textContaining('serial-lab.pkt'), findsWidgets);
    expect(find.textContaining('Built a .pkt from your plan'), findsNothing);
    expect(find.textContaining('Editing the file in place'), findsNothing);
    // Nothing was parsed into the standing plan either, so the next turn does
    // not build on a fragment nobody asked for.
    expect(find.textContaining('1 server'), findsNothing);
  });

  testWidgets('with no file yet, "edit it" is not a file instruction', (
    tester,
  ) async {
    await _wide(tester);
    final store = _FakeStore();
    await tester.pumpWidget(_chat(store));
    await tester.pumpAndSettle();

    await _send(tester, 'edit it');

    expect(find.textContaining('not going to quietly build a'), findsNothing);
    // The offline assistant still answers, in its own words.
    expect(store.logged.where((m) => m.role == 'user'), hasLength(1));
  });
}
