// The layout gallery must actually render: every selectable drawing, the
// chosen one highlighted, and the choice returned to the caller. A preview you
// cannot see is the bug this screen exists to fix, so these pump the real
// widget rather than testing the engine behind it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/layout_gallery_screen.dart';
import 'package:net_builder/services/layout_engine.dart';
import 'package:net_builder/widgets/topology_thumbnail.dart';

void main() {
  final intent = NetworkIntent.parseSimple(
      'chat', '2 routers, 2 switches and 6 PCs with OSPF');

  Widget host(Widget child) => MaterialApp(home: child);

  /// The gallery is a lazy grid, so counting its cards needs a surface big
  /// enough to hold them all - otherwise the count is a viewport artefact and
  /// the test passes or fails for the wrong reason.
  void bigSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('shows one card per layout style', (tester) async {
    bigSurface(tester);
    await tester.pumpWidget(host(LayoutGalleryScreen(intent: intent)));
    await tester.pumpAndSettle();

    for (final style in kLayoutStyles) {
      expect(find.text(layoutStyleLabel(style)), findsOneWidget,
          reason: 'style $style has no card');
    }
    // One thumbnail per card, all painting.
    expect(find.byType(TopologyThumbnail), findsNWidgets(kLayoutStyles.length));
  });

  testWidgets('selecting a layout highlights it and returns it', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await LayoutGalleryScreen.show(
                  context,
                  intent: intent,
                  currentStyle: 'tree',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tap the "Straight rows" card, then confirm.
    await tester.tap(find.text(layoutStyleLabel('rows')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this layout'));
    await tester.pumpAndSettle();

    expect(result, 'rows');
  });

  testWidgets('the current style is marked', (tester) async {
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pumpWidget(host(
      LayoutGalleryScreen(intent: intent, currentStyle: 'compact'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('current'), findsOneWidget);
  });

  testWidgets('a thumbnail paints without overflowing a small card',
      (tester) async {
    await tester.pumpWidget(host(
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 180,
            height: 120,
            child: TopologyThumbnail(
              intent: intent,
              snapshot: computeLayoutSnapshot(intent, style: 'tree'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('enlarging opens a full interactive preview', (tester) async {
    await tester.pumpWidget(host(LayoutGalleryScreen(intent: intent)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.zoom_in).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('preview'), findsOneWidget);
    expect(find.text('Use this layout'), findsOneWidget);
  });

  testWidgets('an empty plan still renders the gallery', (tester) async {
    bigSurface(tester);
    final empty = NetworkIntent(projectName: 'empty');
    await tester.pumpWidget(host(LayoutGalleryScreen(intent: empty)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TopologyThumbnail), findsNWidgets(kLayoutStyles.length));
  });
}
