import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:net_builder/main.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The offline workflow, end to end, in the REAL app on the REAL platform.
///
/// This file is compiled into the actual Windows runner (the same binary
/// `flutter build windows` produces) and executed inside it, so the platform
/// channels, the asset bundle, dart:io and the window are the app's own.
/// The widget suite in test/ drives the identical journey against a
/// fake-async harness; this test exists because a green harness is not the
/// same evidence as a green app.
///
/// What stays MANUAL, on purpose:
/// - The native save/share hand-off. The built file lands in a folder this
///   test owns; moving it the rest of the way goes through the OS save
///   dialog (Windows) or the system share sheet (Android), which no
///   automated driver can operate and which the test must not pop over a
///   developer's desktop.
/// - Packet Tracer live checks. The app is verified here with no engine
///   running. Opening the built .pkt in Packet Tracer, probing the
///   simulated network and watching a capture are human steps against the
///   real simulator.
///
/// Real IO inside fake-async: the integration binding still runs the test
/// body in fake time, so a real write only progresses when `runAsync` hands
/// control back to the platform. Every wait that follows a control which
/// starts work uses the same drain-pump the widget suite uses - keep
/// pumping frames, giving real time back between pumps, until the answer
/// lands - and never `pumpAndSettle`, which would time out on a busy turn
/// instead of letting the test assert.

/// An on-device build writes into the app's documents directory, which in
/// the real app is the user's Documents folder. Point the platform
/// interface at a throwaway directory instead: everything past this seam is
/// still real IO on the real filesystem - real files, really written and
/// read back - in a place a test may own and delete.
class _TempDocsPathProvider extends PathProviderPlatform {
  _TempDocsPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

final _toolsButton = find.byTooltip('Tools: run, capture, and integrations');

/// An app-controlled sheet has entrance animations that settle; a busy turn
/// does not, so only the sheet opens through this helper.
Future<void> _openTools(WidgetTester tester) async {
  await tester.ensureVisible(_toolsButton);
  await tester.tap(_toolsButton);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The status line that names where this ran: a CI result for this job
  // says which platform's app binary actually executed the workflow. The
  // runner prints test names verbatim but swallows the app's own output on
  // a passing run, so the platform rides in the description and the stderr
  // line is the copy that failure logs still show.
  final where = 'platform=${Platform.operatingSystem} '
      '(${Platform.operatingSystemVersion})';
  stderr.writeln(
    'net_builder offline workflow integration test on $where',
  );

  testWidgets('a described network builds a real .pkt file on this device '
      '($where)', (tester) async {
    final docs = Directory.systemTemp.createTempSync('netbuilder-integration-');
    final realPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempDocsPathProvider(docs.path);
    addTearDown(() {
      PathProviderPlatform.instance = realPathProvider;
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    // Settings has text fields too, so the composer is addressed by its
    // label rather than by position.
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Message',
    );
    expect(composer, findsOneWidget);

    // Describe a network the offline planner can parse. This is the no-key,
    // no-engine path: nothing below depends on a model, a network or a PC.
    await tester.enterText(composer, '2 routers and 4 switches');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.textContaining('2 routers and 4 switches'), findsWidgets);

    // Building asks for an explicit design first. Confirm the preview, then
    // use the build action created for that selected plan revision.
    await _openTools(tester);
    await tester.tap(find.text('Build a .pkt from the current plan'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a layout'), findsOneWidget);
    await tester.tap(find.text('Use this layout'));
    await tester.pumpAndSettle();
    expect(find.text('Build .pkt'), findsOneWidget);

    // The build is real CPU work on a spawned isolate (the template library,
    // the save XML, the physical workspace) plus real file IO, so the pumps
    // keep going, handing real time back between them, until the answer
    // lands in the transcript.
    await tester.tap(find.text('Build .pkt'));
    for (
      var i = 0;
      i < 240 &&
          find.textContaining('Built a .pkt on this device').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }

    expect(find.textContaining('Built a .pkt on this device'), findsOneWidget);
    // THE FILE IS NAMED FOR THE NETWORK: the brief's own words, not a
    // timestamp - "2 routers and 4 switches" saves as routers-switches.pkt.
    expect(find.textContaining('routers-switches.pkt'), findsWidgets);
    expect(find.textContaining('Devices:'), findsOneWidget);
    expect(find.textContaining('Cables:'), findsOneWidget);

    // The claim is checked against the disk this app runs on: with no output
    // folder chosen, the builder writes into the documents directory's own
    // pkt folder, and the file is really there.
    final pktDir = Directory('${docs.path}${Platform.pathSeparator}pkt');
    final built = pktDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pkt'))
        .toList();
    expect(built, hasLength(1), reason: 'the built .pkt is on disk');
    expect(built.single.lengthSync(), greaterThan(0));
  });
}
