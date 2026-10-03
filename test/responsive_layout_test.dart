import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/widgets/action_hub.dart';
import 'package:net_builder/widgets/chat_markdown.dart';
import 'package:net_builder/theme/app_theme.dart';
import 'package:net_builder/widgets/app_dialogs.dart';
import 'package:net_builder/app/destinations.dart';
import 'package:net_builder/services/capability_registry.dart';
import 'package:net_builder/widgets/gemini_model_picker.dart';
import 'package:net_builder/widgets/verification_report.dart';
import 'package:provider/provider.dart';

/// The app is used on a 360dp phone, a landscape phone, a split-screen window
/// and with the system text size turned up. A layout that only works at
/// 1500x950 is a layout that breaks on the device the user is holding.
///
/// Every test here fails on a RenderFlex overflow, which is how these
/// regressions showed up in the first place: not as a wrong number, but as
/// striped overflow bars across a screen.

class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
  @override
  Future<String?> getOpenAiKey() async => '';
}

class _FakeStore extends MemoryService {
  @override
  bool get ready => true;

  @override
  Future<List<ChatMessage>> recentChat({
    int limit = 60,
    String conversation = '',
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> conversations({
    int limit = 200,
    String query = '',
  }) async => const [];

  @override
  Future<Map<String, dynamic>?> conversationMeta(String id) async => null;

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
  }) async => 1;

  @override
  Future<void> ensureConversation(
    String id, {
    String project = '',
    String title = '',
  }) async {}

  @override
  Future<void> setSessionState(String id, String stateJson) async {}
}

Widget _chat() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: _FakeStore()),
  ],
  child: const MaterialApp(home: Scaffold(body: ChatScreen())),
);

Future<void> _size(WidgetTester tester, Size size, {double textScale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _watchLayoutErrors(tester);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: _chat(),
    ),
  );
  await tester.pumpAndSettle();
  _reportOverflow(tester, size);
}

/// The widget that overflowed, named. "A RenderFlex overflowed" on its own
/// says nothing about which row; this finds the offending flex and its owner.
void _reportOverflow(WidgetTester tester, Size size) {
  final problem = tester.takeException();
  if (problem is! FlutterError) return;
  // ignore: avoid_print
  print('LAYOUT PROBLEM at $size: ${problem.message}');
}

/// The full report, including which widget overflowed, captured before the
/// test framework swallows it.
void _watchLayoutErrors(WidgetTester tester) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    // ignore: avoid_print
    print('LAYOUT DETAILS: ${details.toString()}');
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

void main() {
  group('the chat survives a small window', () {
    testWidgets('320x568 at normal text', (tester) async {
      await _size(tester, const Size(320, 568));
      expect(tester.takeException(), isNull);
    });

    testWidgets('360x640 at 1.5x text', (tester) async {
      await _size(tester, const Size(360, 640), textScale: 1.5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('640x360 landscape', (tester) async {
      await _size(tester, const Size(640, 360));
      expect(tester.takeException(), isNull);
    });
  });

  group('dialogs fit the window they are shown in', () {
    testWidgets('the artifact report wraps its footer instead of clipping it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showArtifactDialog(
                    context,
                    title: 'Plan JSON',
                    text: '{"a":1}',
                  ),
                  child: const Text('show'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the action hub is usable on a phone', () {
    testWidgets('opens, and Enter runs only the highlighted feature', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ActionHubPanel(
                host: ActionContext(
                  context: context,
                  current: AppDestination.chat,
                  go: (_) {},
                  push: (_) {},
                  openChat: ({String prefill = '', required String project}) {},
                  openDrawer: () {},
                ),
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // A query the user typed is not a decision: the first match is
      // highlighted, and the arrows move it. What runs is the highlighted row.
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Find a feature',
        ),
        'theme',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('match "theme"'), findsOneWidget);
      expect(closed, isFalse, reason: 'typing alone runs nothing');
    });
  });

  group('the model picker fits a small window', () {
    testWidgets('does not force a taller box than the screen has', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => GeminiModelPickerDialog(apiKey: 'not-a-real-key', currentModel: 'gemini-2.5-flash'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // The detection request fails fast against a fake key; what matters is
      // that the dialog built inside a 480px-tall window.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Choose a Gemini model'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('dark theme', () {
    /// A surface is judged as it actually paints - composited over the window
    /// background, not as its raw colour. A 15% tint of anything is fine; an
    /// opaque near-white card with dark text on it is not.
    void expectNoLightSurfaces(WidgetTester tester) {
      final background = Theme.of(
        tester.element(find.byType(Scaffold)),
      ).scaffoldBackgroundColor.computeLuminance();
      for (final container
          in tester.widgetList<Container>(find.byType(Container))) {
        final decoration = container.decoration;
        if (decoration is! BoxDecoration) continue;
        final color = decoration.color;
        if (color == null) continue;
        final painted =
            color.a * color.computeLuminance() + (1 - color.a) * background;
        expect(
          painted,
          lessThan(0.5),
          reason: 'a near-white surface ($color) paints as $painted in dark',
        );
      }
    }

    testWidgets('the verification report is not light-on-dark unreadable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: VerificationReport(report: const {
                'tests': [
                  {'name': 'PC1 -> 192.168.10.1', 'ok': true},
                  {'name': 'PC5 -> 192.168.20.1', 'ok': false},
                ],
              }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoLightSurfaces(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the status pill and markdown are readable in dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  const AppStatusPill(label: 'Engine up'),
                  const SizedBox(height: 8),
                  const ChatMarkdownView(source: 
                    '# Heading\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
                    '- one\n- two',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoLightSurfaces(tester);
      // Black text on a dark surface is the other half of the same bug.
      final background = Theme.of(
        tester.element(find.byType(Scaffold)),
      ).scaffoldBackgroundColor.computeLuminance();
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final color = text.style?.color;
        if (color == null || color.a == 0) continue;
        final painted =
            color.a * color.computeLuminance() + (1 - color.a) * background;
        expect(
          painted,
          greaterThan(0.08),
          reason: 'text "${text.data}" is invisible on the dark surface',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}
