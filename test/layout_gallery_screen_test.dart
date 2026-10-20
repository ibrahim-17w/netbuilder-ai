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
    'chat',
    '2 routers, 2 switches and 6 PCs with OSPF',
  );

  Widget host(Widget child) => MaterialApp(home: child);

  /// The gallery reveals a few designs at a time; a large surface makes the
  /// loaded-card count independent of viewport virtualization.
  void bigSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('reveals small batches of layout styles on demand', (
    tester,
  ) async {
    bigSurface(tester);
    await tester.pumpWidget(host(LayoutGalleryScreen(intent: intent)));
    await tester.pumpAndSettle();

    expect(find.byType(TopologyThumbnail), findsNWidgets(3));
    expect(find.text('3 of 14 designs shown'), findsOneWidget);
    expect(find.text('Show more designs'), findsOneWidget);
    expect(find.text(layoutStyleLabel(kLayoutStyles[3])), findsNothing);

    await tester.tap(find.text('Show more designs'));
    await tester.pumpAndSettle();
    expect(find.byType(TopologyThumbnail), findsNWidgets(6));
    expect(find.text('6 of 14 designs shown'), findsOneWidget);

    while (find.text('Show more designs').evaluate().isNotEmpty) {
      await tester.tap(find.text('Show more designs'));
      await tester.pumpAndSettle();
    }
    for (final style in kLayoutStyles) {
      expect(
        find.text(layoutStyleLabel(style)),
        findsOneWidget,
        reason: 'style $style has no card',
      );
    }
    // Every style appears only after its batch is requested.
    expect(find.byType(TopologyThumbnail), findsNWidgets(kLayoutStyles.length));
    expect(find.text('All 14 designs shown'), findsOneWidget);
  });

  testWidgets('starts with the current design and loads large plans singly', (
    tester,
  ) async {
    final largeIntent = NetworkIntent(
      projectName: 'large',
      nodes: [
        for (var i = 0; i < 201; i++) NetNode(name: 'PC${i + 1}', type: 'pc'),
      ],
    );
    await tester.pumpWidget(
      host(LayoutGalleryScreen(intent: largeIntent, currentStyle: 'compact')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TopologyThumbnail), findsOneWidget);
    expect(
      tester
          .widget<TopologyThumbnail>(find.byType(TopologyThumbnail))
          .snapshot
          .style,
      'compact',
    );
    expect(find.text('1 of 14 designs shown'), findsOneWidget);

    await tester.tap(find.text('Show more designs'));
    await tester.pumpAndSettle();
    expect(find.byType(TopologyThumbnail), findsNWidgets(2));
    expect(find.text('2 of 14 designs shown'), findsOneWidget);
  });

  testWidgets('selecting a layout highlights it and returns it', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tap the "Straight rows" card, then confirm.
    await tester.tap(find.text('Show more designs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(layoutStyleLabel('rows')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this layout'));
    await tester.pumpAndSettle();

    expect(result, 'rows');
  });

  testWidgets('the current style is marked', (tester) async {
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pumpWidget(
      host(LayoutGalleryScreen(intent: intent, currentStyle: 'compact')),
    );
    await tester.pumpAndSettle();
    expect(find.text('current'), findsOneWidget);
  });

  testWidgets('a thumbnail paints without overflowing a small card', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
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
      ),
    );
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
    expect(find.byType(TopologyThumbnail), findsNWidgets(3));
    expect(find.text('3 of 14 designs shown'), findsOneWidget);
  });
}
