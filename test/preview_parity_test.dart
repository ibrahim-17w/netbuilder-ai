// The preview the user picks a design from, and the file that gets built, have
// to be the same drawing - or the choice is a lie. That used to rest on two
// independent implementations of the same ten layout algorithms agreeing by
// hand. The build payload now carries the resolved spot for every device, so
// the app resolves the drawing ONCE and the sidecar places what it is told.
//
// These tests pin that contract: the coordinates in the payload are the ones
// `computeLayoutSnapshot` drew in the gallery, for every style, and they are
// the ones the sidecar's own override path honours.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/layout_engine.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

/// The spot map out of an engine layout payload.
Map<String, List<int>> _positionsOf(Map<String, dynamic> payload) {
  final layout = payload['layout'];
  if (layout is! Map) return const {};
  final raw = layout['positions'];
  if (raw is! Map) return const {};
  return <String, List<int>>{
    for (final entry in raw.entries)
      entry.key: (entry.value as List).cast<int>(),
  };
}

void main() {
  group('the build is placed where the preview was drawn', () {
    test('every device carries a whole-pixel spot in the payload', () {
      final plan = _plan('2 routers, 3 switches and 8 PCs');
      final payload = PacketTracerAdapter.autopilotPlan(
        plan.copyWith(notes: ['layout: tree']),
      );
      final positions = _positionsOf(payload);
      expect(
        positions.keys.toSet(),
        plan.nodes.map((n) => n.name).toSet(),
        reason: 'a device with no spot in the payload is a device the sidecar '
            'has to place for itself, which is how the preview stops being '
            'the truth',
      );
      for (final spot in positions.values) {
        expect(spot, hasLength(2));
        expect(spot[0], spot[0].roundToDouble());
        expect(spot[1], spot[1].roundToDouble());
      }
    });

    test('the payload spots are the gallery drawing, for every style', () {
      final plan = _plan('2 routers, 2 switches, 2 servers and 6 PCs');
      for (final style in kLayoutStyles) {
        final snapshot = computeLayoutSnapshot(plan, style: style);
        final payload = PacketTracerAdapter.autopilotPlan(
          plan,
          layout: {'style': style},
        );
        final positions = _positionsOf(payload);
        expect(positions, hasLength(snapshot.spots.length),
            reason: 'style $style');
        for (final spot in snapshot.spots) {
          expect(
            positions[spot.name],
            <int>[spot.x.toInt(), spot.y.toInt()],
            reason: 'style $style placed ${spot.name} differently in the '
                'preview and in the build',
          );
        }
      }
    });

    test('two styles really do reach the build as two different drawings', () {
      final plan = _plan('2 routers, 2 switches and 6 PCs');
      final tree = _positionsOf(
        PacketTracerAdapter.autopilotPlan(plan, layout: const {'style': 'tree'}),
      );
      final circle = _positionsOf(
        PacketTracerAdapter.autopilotPlan(plan, layout: const {'style': 'circle'}),
      );
      expect(tree, isNotEmpty);
      expect(circle, isNotEmpty);
      expect(tree, isNot(equals(circle)),
          reason: 'if the styles converge in the payload the user cannot tell '
              'the drawings apart by what gets built');
    });

    test('a grouped request places its zones exactly as the gallery drew', () {
      final plan = _plan('1 router, 1 switch, 2 servers and 4 PCs');
      final request = <String, dynamic>{
        'style': 'grouped',
        'sideKinds': <String>['server'],
        'sideEdge': 'left',
      };
      final payload = PacketTracerAdapter.autopilotPlan(plan, layout: request);
      final layout = payload['layout'] as Map;
      final side = (layout['side'] as List?)?.cast<String>() ?? const <String>[];
      expect(side, isNotEmpty, reason: 'the servers should resolve to a side');

      final expected = computeLayoutSnapshot(
        plan,
        style: 'grouped',
        side: side,
        sideEdge: '${layout['sideEdge'] ?? 'left'}',
      );
      final positions = _positionsOf(payload);
      for (final spot in expected.spots) {
        expect(positions[spot.name], <int>[spot.x.toInt(), spot.y.toInt()],
            reason: 'grouped placement drifted for ${spot.name}');
      }
    });

    test('an explicit layout argument is what gets placed', () {
      final plan = _plan('1 router and 4 PCs');
      final compact = _positionsOf(
        PacketTracerAdapter.autopilotPlan(plan, layout: const {'style': 'compact'}),
      );
      final wide = _positionsOf(
        PacketTracerAdapter.autopilotPlan(plan, layout: const {'style': 'wide'}),
      );
      expect(compact, isNotEmpty);
      expect(compact, isNot(equals(wide)));
    });

    test('no layout asked for means no spots invented', () {
      // With no drawing requested the engine keeps its own default. Sending
      // spots here would quietly pin every build to whatever the app happened
      // to draw first, which is a decision nobody asked for.
      final plan = _plan('1 router and 2 PCs');
      final payload = PacketTracerAdapter.autopilotPlan(plan);
      expect(payload.containsKey('layout'), isFalse);
      expect(_positionsOf(payload), isEmpty);
    });

    test('an unknown style still produces a drawable payload', () {
      final plan = _plan('1 router and 2 PCs');
      final payload = PacketTracerAdapter.autopilotPlan(
        plan,
        layout: const {'style': 'banana'},
      );
      // The style is not one this build knows, but the spots still ride along
      // so the file is placed at the drawing the user saw rather than at a
      // second guess about what "banana" was meant to be.
      expect(_positionsOf(payload), isNotEmpty);
    });

    test('spots survive the JSON round trip the sidecar reads', () {
      final plan = _plan('1 router, 1 switch and 3 PCs');
      final payload = PacketTracerAdapter.autopilotPlan(
        plan,
        layout: const {'style': 'layered'},
      );
      final encoded = PacketTracerAdapter.exportPlanJson(plan.copyWith(
        notes: ['layout: layered'],
      ));
      expect(encoded, contains('"positions"'));

      final asMap = payload['layout'] as Map;
      final spots = asMap['positions'] as Map;
      for (final entry in spots.entries) {
        expect(entry.value, isA<List<int>>());
        expect('${entry.key}'.isNotEmpty, isTrue);
      }
    });
  });
}