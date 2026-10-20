import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/screens/layout_gallery_screen.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/layout_engine.dart';
import 'package:net_builder/services/layout_intent.dart';
import 'package:net_builder/services/pkt/pkt_engine_builder.dart';
import 'package:net_builder/services/pkt/template_library.dart';
import 'package:net_builder/widgets/topology_canvas.dart';
import 'package:net_builder/widgets/topology_thumbnail.dart';
import 'package:xml/xml.dart';

NetworkIntent sample() => NetworkIntent.parseSimple(
  'preview',
  '2 routers, 2 switches, 2 servers and 6 PCs',
);

Map<String, Offset> snapshotPositions(LayoutSnapshot snapshot) => {
  for (final spot in snapshot.spots) spot.name: Offset(spot.x, spot.y),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty plan can retain a selected design', () {
    const empty = NetworkIntent(
      projectName: 'empty',
      notes: ['layout: circle'],
    );
    expect(layoutPlan(empty, const Size(360, 600)), isEmpty);
  });

  test(
    'each selected design keeps the gallery geometry on every screen size',
    () {
      final plan = sample();
      for (final style in kLayoutStyles) {
        final selected = NetworkIntent.fromJson(
          plan
              .copyWith(
                notes: [
                  LayoutRequest.noteFor(
                    style,
                    sideKinds: style == 'grouped' ? ['server'] : [],
                  ),
                ],
              )
              .toJson(),
        );
        final expected = snapshotPositions(
          computeLayoutSnapshot(
            plan,
            style: style,
            side: style == 'grouped'
                ? resolveSideNames(plan, kinds: ['server'])
                : [],
          ),
        );
        expect(
          layoutPlan(selected, const Size(360, 600)),
          expected,
          reason: style,
        );
        expect(
          layoutPlan(selected, const Size(1600, 1000)),
          expected,
          reason: style,
        );
      }
    },
  );

  test('resolved grouped names and both edges survive repeated builds', () {
    final plan = sample();
    final zones = [
      LayoutZone(resolveSideNames(plan, kinds: ['server']), edge: 'right'),
      LayoutZone(resolveSideNames(plan, kinds: ['router']), edge: 'left'),
    ];
    final request = <String, dynamic>{
      'style': 'grouped',
      'zones': [
        for (final zone in zones) {'side': zone.side, 'edge': zone.edge},
      ],
    };
    final once = PacketTracerAdapter.resolveLayoutForEngine(plan, request);
    final twice = PacketTracerAdapter.resolveLayoutForEngine(plan, once);
    expect(twice, once);
    final expected = computeLayoutSnapshot(
      plan,
      style: 'grouped',
      zones: zones,
    );
    expect(once['positions'], {
      for (final spot in expected.spots)
        spot.name: [spot.x.toInt(), spot.y.toInt()],
    });
    final single = PacketTracerAdapter.resolveLayoutForEngine(plan, {
      'style': 'grouped',
      'side': zones.first.side,
      'sideEdge': 'right',
    });
    expect(single['side'], zones.first.side);
    expect(single['positions'], {
      for (final spot in computeLayoutSnapshot(
        plan,
        style: 'grouped',
        side: zones.first.side,
        sideEdge: 'right',
      ).spots)
        spot.name: [spot.x.toInt(), spot.y.toInt()],
    });
  });

  test(
    'saved dragged coordinates reach the file even without a layout note',
    () {
      final plan = sample().copyWith(layout: const {'R1': Offset(777, 333)});
      final payload = PacketTracerAdapter.autopilotPlan(plan);
      expect((payload['layout'] as Map)['positions']['R1'], [777, 333]);
      final positions = layoutPlan(plan, const Size(360, 600));
      expect(positions['R1'], const Offset(777, 333));
      expect(positions.keys.toSet(), plan.nodes.map((n) => n.name).toSet());
    },
  );

  test(
    'Android compiler writes every selected design into actual device coordinates',
    () async {
      final library = await PktTemplateLibrary.loadBundled();
      final plan = sample();
      for (final style in kLayoutStyles) {
        final selected = plan.copyWith(notes: [LayoutRequest.noteFor(style)]);
        final expected = layoutPlan(selected, const Size(360, 600));
        final built = await buildPkt(
          plan: PacketTracerAdapter.autopilotPlan(selected),
          library: library,
        );
        expect(built.deviceCount, plan.nodes.length, reason: style);
        final doc = XmlDocument.parse(built.xml);
        var checked = 0;
        for (final device in doc.findAllElements('DEVICE')) {
          final name = device
              .getElement('ENGINE')
              ?.getElement('NAME')
              ?.innerText;
          if (name == null || !expected.containsKey(name)) continue;
          checked++;
          final workspace = device.getElement('WORKSPACE')!;
          final logical = workspace.getElement('LOGICAL')!;
          expect(
            double.parse(logical.getElement('X')!.innerText),
            expected[name]!.dx,
            reason: '$style $name X',
          );
          expect(
            double.parse(logical.getElement('Y')!.innerText),
            expected[name]!.dy,
            reason: '$style $name Y',
          );
        }
        expect(
          checked,
          expected.length,
          reason: '$style must verify every device',
        );
      }
    },
  );

  testWidgets(
    'phone preview fits every design without distorting relative positions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      for (final style in kLayoutStyles) {
        final intent = sample().copyWith(notes: [LayoutRequest.noteFor(style)]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TopologyCanvas(key: ValueKey(style), intent: intent),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        final scale = viewer.transformationController!.value
            .getMaxScaleOnAxis();
        final spots = layoutPlan(intent, const Size(360, 700));
        Offset? origin;
        for (final node in intent.nodes) {
          final target = find.bySemanticsLabel(
            RegExp('^[^ ]+ ${node.name}\\.'),
          );
          final rect = tester.getRect(target);
          expect(
            rect.left,
            greaterThanOrEqualTo(0),
            reason: '$style ${node.name}',
          );
          expect(rect.right, lessThanOrEqualTo(360));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(740));
          final translation = rect.center - spots[node.name]! * scale;
          origin ??= translation;
          expect(
            (translation - origin).distance,
            lessThan(0.001),
            reason: style,
          );
        }
        expect(tester.takeException(), isNull, reason: style);
      }
      semantics.dispose();
    },
  );

  testWidgets('zoom, fit, drag and inspect work on a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    Map<String, Offset>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopologyCanvas(
            intent: sample().copyWith(notes: ['layout: campus']),
            onLayoutChanged: (value) => saved = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final target = find.bySemanticsLabel(RegExp(r'^router R1\.'));
    final before = tester.getCenter(target);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(target), isNot(before));
    await tester.tap(find.byTooltip('Fit network'));
    await tester.pumpAndSettle();
    expect((tester.getCenter(target) - before).distance, lessThan(0.001));
    final gesture = await tester.startGesture(tester.getCenter(target));
    await gesture.moveBy(const Offset(15, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 18));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(
      saved!['R1'],
      isNot(
        layoutPlan(
          sample().copyWith(notes: ['layout: campus']),
          const Size(360, 600),
        )['R1'],
      ),
    );
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.text('R1'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('grouped gallery resolves server types to the real devices', (
    tester,
  ) async {
    final intent = sample();
    await tester.pumpWidget(
      MaterialApp(home: LayoutGalleryScreen(intent: intent)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show more designs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show more designs'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Grouped to one side'), 220);
    final thumb = tester
        .widgetList<TopologyThumbnail>(find.byType(TopologyThumbnail))
        .firstWhere((t) => t.snapshot.style == 'grouped');
    final expected = computeLayoutSnapshot(
      intent,
      style: 'grouped',
      side: resolveSideNames(intent, kinds: ['server']),
    );
    expect(snapshotPositions(thumb.snapshot), snapshotPositions(expected));
    expect(
      snapshotPositions(thumb.snapshot),
      isNot(snapshotPositions(computeLayoutSnapshot(intent, style: 'tree'))),
    );
  });
}
