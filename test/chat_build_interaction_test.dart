import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_platform_interface/src/method_channel_path_provider.dart';

/// Drives the real chat screen rather than calling the logic directly: press
/// the control a user presses, and read what the user would read.
///
/// `pumpAndSettle` is deliberately avoided after a control that starts work -
/// a busy turn can carry an animation that never settles, which would time the
/// test out rather than let it assert.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// An on-device build writes into the app's documents directory, which no
/// test platform provides: answer the plugin with a scratch path.
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => 'build/test-docs';
}

final _toolsButton =
    find.byTooltip('Tools: run, capture, and integrations');
final _buildTile = find.text('Build a .pkt from the current plan');

/// Open the tools sheet, where the capture actions now live.
Future<void> _openTools(WidgetTester tester) async {
  await tester.ensureVisible(_toolsButton);
  await tester.tap(_toolsButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the build action is reachable from the chat screen',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The reported problem was that the generator had no control at all from
    // this screen. It has one now, named, one tap away.
    expect(_toolsButton, findsOneWidget);
    await _openTools(tester);
    expect(_buildTile, findsOneWidget);
  });

  testWidgets('pressing it with no plan explains how to make one',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await _openTools(tester);
    await tester.tap(_buildTile);
    await _settle(tester);

    // The empty path, through the UI: no exception, no blank bubble.
    expect(find.textContaining('There is no plan to compile yet'),
        findsOneWidget);
    expect(find.textContaining('No API key is needed'), findsOneWidget);
  });

  testWidgets('a described network builds a .pkt with no engine and no key',
      (tester) async {
    PathProviderPlatform.instance = _FakePathProvider();
    addTearDown(() => PathProviderPlatform.instance = MethodChannelPathProvider());
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The settings sidebar has text fields too, so the composer is addressed
    // by its label rather than by position.
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    expect(composer, findsOneWidget);

    // Describe a network the offline planner can parse - this is the no-key,
    // no-engine path, so nothing here depends on a model, a network or a PC.
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);
    expect(find.textContaining('2 routers and 4 switches'), findsWidgets);

    // Now the action has something to compile. The sidecar is not running in
    // a test, and it does not need to be: the build runs on this device from
    // the bundled template library, and says so. The build is real CPU work
    // (the library, the save XML, the physical workspace), so the pumps keep
    // going until the answer lands. The build loads its library over the
    // asset channel, which inside a fake-async test only progresses when
    // real time is given back between pumps.
    await _openTools(tester);
    await tester.tap(_buildTile);
    for (var i = 0;
        i < 120 &&
            find.textContaining('Built a .pkt on this device').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }

    expect(find.textContaining('Built a .pkt on this device'), findsOneWidget);
    // THE FILE IS NAMED FOR THE NETWORK: the brief's own words, not a
    // timestamp - "2 routers and 4 switches" saves as routers-switches.pkt.
expect(find.textContaining('routers-switches.pkt'), findsWidgets);
    // The verification step ran against the file it wrote, not skipped.
    expect(find.textContaining('Verification:'), findsWidgets);
  });

  testWidgets('an unreachable engine is stated up front, with a way to fix it',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    // No engine is listening in a test, so the banner is expected once the
    // reachability check has run.
    await _settle(tester);

    expect(find.textContaining('No .pkt engine at'), findsOneWidget);
    expect(find.text('Set address'), findsOneWidget);
  });
}
