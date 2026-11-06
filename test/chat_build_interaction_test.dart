import 'dart:io';

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

final _toolsButton = find.byTooltip('Tools: run, capture, and integrations');
final _buildTile = find.text('Build a .pkt from the current plan');

/// Open the tools sheet, where the capture actions now live.
Future<void> _openTools(WidgetTester tester) async {
  await tester.ensureVisible(_toolsButton);
  await tester.tap(_toolsButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the build action is reachable from the chat screen', (
    tester,
  ) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // The reported problem was that the generator had no control at all from
    // this screen. It has one now, named, one tap away.
    expect(_toolsButton, findsOneWidget);
    await _openTools(tester);
    expect(_buildTile, findsOneWidget);
  });

  testWidgets('pressing it with no plan explains how to make one', (
    tester,
  ) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    await _openTools(tester);
    await tester.tap(_buildTile);
    await _settle(tester);

    // The empty path, through the UI: no exception, no blank bubble.
    expect(
      find.textContaining('There is no plan to compile yet'),
      findsOneWidget,
    );
    expect(find.textContaining('No API key is needed'), findsOneWidget);
  });

  testWidgets(
    'A33 one double-click build runs once and later rebuild stays available',
    (tester) async {
      PathProviderPlatform.instance = _FakePathProvider();
      addTearDown(
        () => PathProviderPlatform.instance = MethodChannelPathProvider(),
      );
      await tester.pumpWidget(const NetBuilderApp());
      await tester.pumpAndSettle();

      // Settings has text fields too, so the composer is addressed
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

      // Building now asks for an explicit design first. Confirm the preview
      // without writing a file, then use the build action created for that
      // selected plan revision.
      await _openTools(tester);
      await tester.tap(_buildTile);
      await tester.pumpAndSettle();
      expect(find.text('Choose a layout'), findsOneWidget);
      await tester.tap(find.text('Use this layout'));
      await tester.pumpAndSettle();
      expect(find.text('Build .pkt'), findsOneWidget);

      // Now the action has something to compile. Deliver two callbacks before
      // Flutter gets a chance to repaint the disabled button, matching the
      // fastest possible double-click. The second callback must be rejected by
      // the action's busy guard, not merely hidden by the next frame.
      final buildButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Build .pkt'),
      );
      final startBuild = buildButton.onPressed!;
      startBuild();
      startBuild();

      // The sidecar is not running in a test, and it does not need to be: the
      // build runs on this device from the bundled template library, and says
      // so. The build is real CPU work (the library, the save XML, the physical
      // workspace), so the pumps keep going until the answer lands. The build
      // loads its library over the asset channel, which inside a fake-async test
      // only progresses when real time is given back between pumps.
      for (
        var i = 0;
        i < 120 &&
            find
                .textContaining('Built a .pkt on this device')
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }

      expect(
        find.textContaining('Built a .pkt on this device'),
        findsOneWidget,
      );
      // THE FILE IS NAMED FOR THE NETWORK: the brief's own words, not a
      // timestamp - "2 routers and 4 switches" saves as routers-switches.pkt.
      expect(find.textContaining('routers-switches.pkt'), findsWidgets);
      expect(find.textContaining('Devices:'), findsOneWidget);
      expect(find.textContaining('Cables:'), findsOneWidget);
      expect(
        find.textContaining('Built a .pkt on this device'),
        findsOneWidget,
        reason: 'one active request creates exactly one build result',
      );
      await _settle(tester);
      await _openTools(tester);
      expect(_buildTile, findsOneWidget);
      final rebuild = tester.widget<ListTile>(
        find.ancestor(of: _buildTile, matching: find.byType(ListTile)),
      );
      expect(
        rebuild.onTap,
        isNotNull,
        reason: 'the tools sheet still offers a later explicit rebuild',
      );
    },
  );

  testWidgets(
    'an unreachable engine is stated up front, with a way to fix it',
    (tester) async {
      await tester.pumpWidget(const NetBuilderApp());
      // No engine is listening in a test, so the banner is expected once the
      // reachability check has run.
      await _settle(tester);

      expect(find.textContaining('No .pkt engine at'), findsOneWidget);
      expect(find.text('Set address'), findsOneWidget);
    },
  );

  testWidgets('the build guide exports to a Markdown file', (tester) async {
    PathProviderPlatform.instance = _FakePathProvider();
    addTearDown(
      () => PathProviderPlatform.instance = MethodChannelPathProvider(),
    );
    // A stale export from an earlier run would push this write to -2: the
    // uniqueness loop is real, so the folder starts empty.
    final outDir = Directory('build/test-docs/output');
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);

    // Ask for the guide the way a user does, then save it from the dialog.
    await tester.enterText(composer, 'how do I build this?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);
    expect(find.textContaining('Build guide'), findsWidgets);

    await tester.tap(find.text('Save to file'));
    for (
      var i = 0;
      i < 40 && find.textContaining('Guide saved as').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
      // The write is real IO on this fake docs folder; fake-async time only
      // lets it progress when real time is handed back between pumps.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(find.textContaining('Guide saved as'), findsOneWidget);
    // Named for the network, beside the .pkt files, and really on disk.
    expect(find.textContaining('guide-routers-switches.md'), findsOneWidget);
    final written = File('build/test-docs/output/guide-routers-switches.md');
    expect(written.existsSync(), isTrue);
    expect(written.readAsStringSync(), contains('# Build guide - '));
  });

  testWidgets('export a lab report writes one document from real evidence', (
    tester,
  ) async {
    PathProviderPlatform.instance = _FakePathProvider();
    addTearDown(
      () => PathProviderPlatform.instance = MethodChannelPathProvider(),
    );
    final outDir = Directory('build/test-docs/output');
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);

    await tester.enterText(composer, 'export a lab report');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    // The report is composed and written with real IO on this fake docs
    // folder; fake-async time only lets it progress when real time is
    // handed back between pumps.
    for (
      var i = 0;
      i < 60 && find.textContaining('Lab report saved').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }

    expect(find.textContaining('Lab report saved'), findsOneWidget);
    final reports = outDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.md') && f.path.contains('report-'))
        .toList();
    expect(reports, hasLength(1));
    final text = reports.single.readAsStringSync();
    // Every section is there, composed from what this conversation made.
    expect(text, contains('# Lab report - '));
    expect(text, contains('## The plan'));
    expect(text, contains('## Design review'));
    expect(text, contains('No .pkt was built in this conversation yet'));
    expect(text, contains('No .pkt was analyzed'));
    expect(text, contains('## How to build it'));
  });

  testWidgets('guide checklist ticks persist across reopen', (tester) async {
    PathProviderPlatform.instance = _FakePathProvider();
    addTearDown(
      () => PathProviderPlatform.instance = MethodChannelPathProvider(),
    );
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);

    // Open the guide the way a user does.
    await tester.enterText(composer, 'how do I build this?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);
    expect(find.textContaining('Build guide'), findsWidgets);

    // Tick the first checklist step and close. The checklist sits below a
    // long guide, so it is brought into view before the tap.
    final box = find.byType(CheckboxListTile).first;
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    await tester.tap(box);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Reopen: the tick is still there, and the rendered text carries it.
    await tester.enterText(composer, 'how do I build this?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester);
    expect(find.byType(CheckboxListTile).first, findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile).first,
    );
    expect(checkbox.value, isTrue, reason: 'the tick survived the reopen');
    expect(find.textContaining('- [x] Every device'), findsOneWidget);
  });
}
