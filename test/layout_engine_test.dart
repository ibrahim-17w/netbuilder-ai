// The layout engine must produce the SAME drawing the sidecar builds, or a
// preview the user picks from would be a lie. These pin the geometry constants
// and the shape of each style, and the end-to-end test below feeds the same
// plan through the sidecar's own `layout_positions` to prove the two agree.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/layout_engine.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

void main() {
  group('layout styles', () {
    test('every style is a known name', () {
      expect(kLayoutStyles, containsAll(['tree', 'wide', 'compact', 'rows']));
      for (final s in kLayoutStyles) {
        expect(kLayoutStyleShapes.containsKey(s), isTrue);
        expect(layoutStyleLabel(s), isNotEmpty);
        expect(layoutStyleBlurb(s), isNotEmpty);
      }
    });

    test('geometry constants match the sidecar', () {
      // Copied from pkt_builder.py; a change there must change here too.
      expect(kRowTop, 60);
      expect(kBandStep, 190);
      expect(kRowStep, 130);
      expect(kDevicePitch, 120);
      expect(kBlockGap, 150);
      expect(kGridColumns, 4);
      expect(kCanvasWidth, 1400);
      expect(kXStart, 140);
      expect(kRowsPerRow, 8);
      expect(kLayoutStyleShapes['wide']!.spacing, 1.3);
      expect(kLayoutStyleShapes['compact']!.spacing, 0.75);
      expect(kLayoutStyleShapes['rows']!.columns, 4);
    });

    test('tiers follow role, not just type', () {
      expect(layoutTierOf('router'), kTierCore);
      expect(layoutTierOf('firewall'), kTierCore);
      expect(layoutTierOf('switch'), kTierAccess);
      expect(layoutTierOf('server'), kTierServices);
      expect(layoutTierOf('pc'), kTierHosts);
      expect(layoutTierOf('laptop'), kTierHosts);
    });
  });

  group('computeLayoutSnapshot', () {
    test('places every device, once, with no two on one point', () {
      final intent = _plan('2 routers, 2 switches and 8 PCs with OSPF');
      for (final style in kLayoutStyles) {
        final snap = computeLayoutSnapshot(intent, style: style);
        expect(
          snap.spots.length,
          intent.nodes.length,
          reason: 'style $style dropped a device',
        );
        final points = {for (final s in snap.spots) '${s.x},${s.y}'};
        expect(
          points.length,
          snap.spots.length,
          reason: 'style $style piled two devices on one point',
        );
      }
    });

    test('the styles are actually different drawings', () {
      // Servers matter here: `grouped` with nothing to park is a tree, and a
      // style that draws the same picture as another one is a lie in the
      // gallery.
      final intent = _plan(
        '2 routers, 2 switches, 8 PCs and 2 servers with OSPF',
      );
      final parked = resolveSideNames(intent, kinds: const ['server']);
      expect(parked, isNotEmpty, reason: 'the fixture needs servers');
      final layouts = computeAllLayouts(intent, side: parked);
      final fingerprints = <String>{};
      for (final entry in layouts.entries) {
        fingerprints.add(
          entry.value.spots.map((s) => '${s.name}@${s.x},${s.y}').join('|'),
        );
      }
      // `tree` and `rows` differ in nesting; `wide` and `compact` in scale;
      // `grouped` moves the parked devices out of their sub-tree. Every style
      // must be distinguishable from every other, or the gallery is offering
      // the same picture under different names.
      expect(fingerprints.length, kLayoutStyles.length);
    });

    test('compact is tighter than wide on the same plan', () {
      final intent = _plan('1 router, 2 switches and 10 PCs');
      final compact = computeLayoutSnapshot(intent, style: 'compact');
      final wide = computeLayoutSnapshot(intent, style: 'wide');
      expect(compact.width, lessThan(wide.width));
    });

    test('a plan with no nodes yields an empty snapshot, not a crash', () {
      final empty = NetworkIntent(projectName: 'empty');
      final snap = computeLayoutSnapshot(empty);
      expect(snap.isEmpty, isTrue);
      expect(snap.spots, isEmpty);
    });

    test('an unknown style falls back to the default shape', () {
      final intent = _plan('1 router and 2 PCs');
      final snap = computeLayoutSnapshot(intent, style: 'not-a-style');
      expect(snap.spots.length, intent.nodes.length);
    });

    test('devices without links still get a place, by band', () {
      final intent = NetworkIntent(
        projectName: 'islands',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'PC1', type: 'pc'),
        ],
      );
      final snap = computeLayoutSnapshot(intent);
      expect(snap.spots.length, 2);
      final r1 = snap.spots.firstWhere((s) => s.name == 'R1');
      final pc1 = snap.spots.firstWhere((s) => s.name == 'PC1');
      expect(r1.y, lessThan(pc1.y), reason: 'the router band is above the PCs');
    });
  });

  group('the chosen layout reaches the engine', () {
    test('a layout note becomes the engine layout payload', () {
      final base = _plan('1 router and 2 PCs');
      final withNote = base.copyWith(notes: ['layout: wide']);
      final payload = PacketTracerAdapter.intentLayoutFromNotes(withNote);
      expect(payload['style'], 'wide');
    });

    test('an unknown note is ignored (engine keeps its default)', () {
      final base = _plan('1 router and 2 PCs');
      final withNote = base.copyWith(notes: ['layout: banana']);
      expect(PacketTracerAdapter.intentLayoutFromNotes(withNote), isEmpty);
    });

    test('autopilotPlan carries the note style when no layout is passed', () {
      final plan = _plan('2 routers with OSPF');
      final withNote = plan.copyWith(notes: ['layout: rows']);
      final payload = PacketTracerAdapter.autopilotPlan(withNote);
      expect(payload['layout'], isNotNull);
      expect((payload['layout'] as Map)['style'], 'rows');
    });

    test('an explicit layout argument still wins over the note', () {
      final plan = _plan('2 routers with OSPF');
      final withNote = plan.copyWith(notes: ['layout: rows']);
      final payload = PacketTracerAdapter.autopilotPlan(
        withNote,
        layout: const {'style': 'compact'},
      );
      expect((payload['layout'] as Map)['style'], 'compact');
    });
  });

  group('snapshot geometry is finite and sane', () {
    test('a big lab stays within a plausible canvas', () {
      final intent = _plan('4 routers, 4 switches and 40 PCs');
      final snap = computeLayoutSnapshot(intent, style: 'tree');
      expect(snap.minX.isFinite && snap.maxX.isFinite, isTrue);
      expect(snap.minY.isFinite && snap.maxY.isFinite, isTrue);
      expect(snap.width, greaterThan(0));
      expect(snap.height, greaterThan(0));
    });
  });

  // PARITY WITH THE ENGINE. These coordinates were produced by the sidecar's
  // own `pkt_builder.layout_positions` for this exact plan (same nodes, same
  // links, same order) and recorded. If the Dart engine ever drifts, the
  // preview a user picks from stops being the file they get - so this fails
  // loudly rather than shipping a lie.
  group('coordinates match the sidecar byte-for-byte', () {
    final intent = NetworkIntent(
      projectName: 'parity',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
        NetNode(name: 'PC3', type: 'pc'),
      ],
      links: const [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'R2', bIf: 'g0/0', cable: 'serial'),
        NetLink(a: 'R1', aIf: 'g0/1', b: 'SW1', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/1', b: 'PC1', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC2', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/3', b: 'PC3', bIf: 'f0'),
      ],
    );

    const reference = <String, Map<String, List<int>>>{
      'tree': {
        'R1': [565, 60],
        'R2': [955, 60],
        'SW1': [565, 250],
        'PC1': [445, 440],
        'PC2': [565, 440],
        'PC3': [685, 440],
      },
      'wide': {
        'R1': [524, 60],
        'R2': [1032, 60],
        'SW1': [524, 307],
        'PC1': [368, 554],
        'PC2': [524, 554],
        'PC3': [680, 554],
      },
      'compact': {
        'R1': [599, 60],
        'R2': [891, 60],
        'SW1': [599, 202],
        'PC1': [509, 345],
        'PC2': [599, 345],
        'PC3': [689, 345],
      },
      'rows': {
        'R1': [565, 60],
        'R2': [955, 60],
        'SW1': [700, 250],
        'PC1': [580, 440],
        'PC2': [700, 440],
        'PC3': [820, 440],
      },
      // PC2 parked to the left: it moves to the left edge on its own, and
      // everything else shifts right to make room for the column.
      'grouped': {
        'R1': [835, 60],
        'R2': [1225, 60],
        'SW1': [835, 250],
        'PC1': [715, 440],
        'PC2': [140, 440],
        'PC3': [955, 440],
      },
    };

    for (final style in <String>[
      'tree',
      'wide',
      'compact',
      'rows',
      'grouped',
    ]) {
      test(style, () {
        final snap = computeLayoutSnapshot(
          intent,
          style: style,
          side: style == 'grouped' ? const ['PC2'] : const [],
        );
        final got = <String, List<int>>{
          for (final s in snap.spots) s.name: [s.x.toInt(), s.y.toInt()],
        };
        expect(got, reference[style]);
      });
    }
  });

  // PARITY FOR EVERY DRAWING, ON A PLAN WITH EVERY TIER. `radial` and `circle`
  // use trigonometry, so this is the test that would catch the Dart engine and
  // the sidecar disagreeing by a pixel - which would make the preview a
  // different picture from the file.
  group('all ten drawings match the sidecar byte-for-byte', () {
    final intent = NetworkIntent(
      projectName: 'all-styles',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
        NetNode(name: 'FW1', type: 'firewall'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'SW2', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
        NetNode(name: 'PC3', type: 'pc'),
        NetNode(name: 'SRV1', type: 'server'),
        NetNode(name: 'SRV2', type: 'server'),
      ],
      links: const [
        NetLink(a: 'FW1', aIf: 'g0/0', b: 'R1', bIf: 'g0/0'),
        NetLink(
          a: 'R1',
          aIf: 'g0/1',
          b: 'R2',
          bIf: 'g0/0',
          cable: 'serial',
        ),
        NetLink(a: 'R1', aIf: 'g0/2', b: 'SW1', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/1', b: 'PC1', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC2', bIf: 'f0'),
        NetLink(a: 'SW2', aIf: 'f0/3', b: 'PC3', bIf: 'f0'),
        NetLink(a: 'R2', aIf: 'g0/2', b: 'SW2', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/3', b: 'SRV1', bIf: 'f0'),
        NetLink(a: 'SW2', aIf: 'f0/4', b: 'SRV2', bIf: 'f0'),
      ],
    );

    const reference = <String, Map<String, List<int>>>{
      'tree': {
        'R1': [430, 60],
        'SW1': [430, 250],
        'SRV1': [430, 440],
        'PC1': [370, 630],
        'PC2': [490, 630],
        'R2': [760, 60],
        'SW2': [760, 250],
        'SRV2': [760, 440],
        'PC3': [760, 630],
        'FW1': [1030, 60],
      },
      'wide': {
        'R1': [349, 60],
        'SW1': [349, 307],
        'SRV1': [349, 554],
        'PC1': [271, 801],
        'PC2': [427, 801],
        'R2': [778, 60],
        'SW2': [778, 307],
        'SRV2': [778, 554],
        'PC3': [778, 801],
        'FW1': [1129, 60],
      },
      'compact': {
        'R1': [498, 60],
        'SW1': [498, 202],
        'SRV1': [498, 345],
        'PC1': [452, 488],
        'PC2': [542, 488],
        'R2': [745, 60],
        'SW2': [745, 202],
        'SRV2': [745, 345],
        'PC3': [745, 488],
        'FW1': [948, 60],
      },
      'rows': {
        'R1': [430, 60],
        'R2': [760, 60],
        'FW1': [1030, 60],
        'SW1': [640, 250],
        'SW2': [760, 250],
        'SRV1': [640, 440],
        'SRV2': [760, 440],
        'PC1': [580, 630],
        'PC2': [700, 630],
        'PC3': [820, 630],
      },
      // Servers parked left, one router parked right: two zones, two edges.
      'grouped': {
        'R1': [1570, 60],
        'SW1': [700, 250],
        'SRV1': [140, 440],
        'PC1': [640, 630],
        'PC2': [760, 630],
        'R2': [1030, 60],
        'SW2': [1030, 250],
        'SRV2': [140, 570],
        'PC3': [1030, 630],
        'FW1': [1300, 60],
      },
      'layered': {
        'R1': [140, 60],
        'R2': [140, 190],
        'FW1': [140, 320],
        'SW1': [330, 60],
        'SW2': [330, 190],
        'PC1': [520, 60],
        'PC2': [520, 190],
        'SRV1': [520, 320],
        'PC3': [520, 450],
        'SRV2': [520, 580],
      },
      'radial': {
        'R1': [784, 228],
        'R2': [930, 480],
        'FW1': [639, 480],
        'SW1': [904, 228],
        'SW2': [784, 948],
        'SRV1': [1024, 228],
        'SRV2': [784, 1332],
        'PC1': [1144, 228],
        'PC2': [1429, 1344],
        'PC3': [140, 1344],
      },
      'circle': {
        'R1': [700, 60],
        'R2': [883, 119],
        'FW1': [996, 275],
        'SW1': [996, 467],
        'SW2': [883, 623],
        'SRV1': [700, 682],
        'SRV2': [517, 623],
        'PC1': [404, 467],
        'PC2': [404, 275],
        'PC3': [517, 119],
      },
      'grid': {
        'R1': [140, 60],
        'R2': [410, 60],
        'FW1': [680, 60],
        'SW1': [950, 60],
        'SW2': [140, 330],
        'SRV1': [410, 330],
        'SRV2': [680, 330],
        'PC1': [950, 330],
        'PC2': [140, 600],
        'PC3': [410, 600],
      },
      'split': {
        'R1': [320, 60],
        'R2': [320, 190],
        'FW1': [320, 320],
        'SW1': [770, 60],
        'SW2': [770, 190],
        'SRV1': [1280, 60],
        'SRV2': [1280, 190],
        'PC1': [1850, 60],
        'PC2': [1850, 190],
        'PC3': [1850, 320],
      },
    };

    // The four engineer drawings (`backbone`, `campus`, `star`, `ring`) have
    // no byte-parity reference here yet: the sidecar's `layout_positions`
    // mirror does not implement them, so there is no second implementation to
    // copy from. They are pinned by the property group below and by the
    // payload round-trip in preview_parity_test, which covers every style in
    // kLayoutStyles.
    for (final style in reference.keys) {
      test(style, () {
        final snap = computeLayoutSnapshot(
          intent,
          style: style,
          zones: style == 'grouped'
              ? const [
                  LayoutZone(['SRV1', 'SRV2'], edge: 'left'),
                  LayoutZone(['R1'], edge: 'right'),
                ]
              : const [],
        );
        final got = <String, List<int>>{
          for (final s in snap.spots) s.name: [s.x.toInt(), s.y.toInt()],
        };
        expect(got, reference[style]);
      });
    }
  });

  // The four engineer drawings. Places-every-device and no-pile-ups are
  // already asserted for every style in kLayoutStyles above; these pin what
  // makes each silhouette THE silhouette an engineer asked for.
  group('the engineer drawings: backbone, campus, star, ring', () {
    final intent = NetworkIntent(
      projectName: 'engineer',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
        NetNode(name: 'FW1', type: 'firewall'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'SW2', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
        NetNode(name: 'PC3', type: 'pc'),
        NetNode(name: 'SRV1', type: 'server'),
        NetNode(name: 'SRV2', type: 'server'),
      ],
      links: const [
        NetLink(a: 'FW1', aIf: 'g0/0', b: 'R1', bIf: 'g0/0'),
        NetLink(
          a: 'R1',
          aIf: 'g0/1',
          b: 'R2',
          bIf: 'g0/0',
          cable: 'serial',
        ),
        NetLink(a: 'R1', aIf: 'g0/2', b: 'SW1', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/1', b: 'PC1', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC2', bIf: 'f0'),
        NetLink(a: 'SW2', aIf: 'f0/3', b: 'PC3', bIf: 'f0'),
        NetLink(a: 'R2', aIf: 'g0/2', b: 'SW2', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/3', b: 'SRV1', bIf: 'f0'),
        NetLink(a: 'SW2', aIf: 'f0/4', b: 'SRV2', bIf: 'f0'),
      ],
    );

    double xOf(LayoutSnapshot snap, String name) =>
        snap.spots.firstWhere((s) => s.name == name).x;
    double yOf(LayoutSnapshot snap, String name) =>
        snap.spots.firstWhere((s) => s.name == name).y;

    test('backbone: one line, servers above it, PCs below it', () {
      final snap = computeLayoutSnapshot(intent, style: 'backbone');
      expect(
        snap.spots.length,
        intent.nodes.length,
        reason: 'backbone dropped a device',
      );
      // Routers and switches share the backbone row, in core-first order.
      final lineY = yOf(snap, 'R1');
      for (final name in ['R2', 'FW1', 'SW1', 'SW2']) {
        expect(yOf(snap, name), lineY, reason: '$name is not on the line');
      }
      // Left to right the line reads core then access.
      expect(xOf(snap, 'R1'), lessThan(xOf(snap, 'SW1')));
      expect(xOf(snap, 'SW1'), lessThan(xOf(snap, 'SW2')));
      // Servers sit above the line, PCs below - the riser look.
      expect(yOf(snap, 'SRV1'), lessThan(lineY));
      expect(yOf(snap, 'SRV2'), lessThan(lineY));
      for (final name in ['PC1', 'PC2', 'PC3']) {
        expect(yOf(snap, name), greaterThan(lineY), reason: name);
      }
      // Drops stay under the device they hang off: SW1's block holds
      // PC1, PC2 and SRV1; PC3 and SRV2 hang off SW2.
      final sw1x = xOf(snap, 'SW1');
      expect((xOf(snap, 'PC1') - sw1x).abs(), lessThanOrEqualTo(240));
      expect((xOf(snap, 'PC2') - sw1x).abs(), lessThanOrEqualTo(240));
      expect(xOf(snap, 'SRV1'), xOf(snap, 'SW1'));
      expect(xOf(snap, 'PC3'), xOf(snap, 'SW2'));
      expect(xOf(snap, 'SRV2'), xOf(snap, 'SW2'));
    });

    test('backbone: pinned coordinates for the riser plan', () {
      final snap = computeLayoutSnapshot(intent, style: 'backbone');
      final got = <String, List<int>>{
        for (final s in snap.spots) s.name: [s.x.toInt(), s.y.toInt()],
      };
      // Drift here changes the riser a user was shown; fail loudly.
      expect(got, {
        'R1': [200, 190],
        'R2': [470, 190],
        'FW1': [740, 190],
        'SW1': [1070, 190],
        'SW2': [1400, 190],
        'SRV1': [1070, 60],
        'SRV2': [1400, 60],
        'PC1': [1010, 320],
        'PC2': [1130, 320],
        'PC3': [1400, 320],
      });
    });

    test('campus: three tiers, endpoints aligned under their switch', () {
      final snap = computeLayoutSnapshot(intent, style: 'campus');
      expect(
        snap.spots.length,
        intent.nodes.length,
        reason: 'campus dropped a device',
      );
      final coreY = yOf(snap, 'R1');
      for (final name in ['R2', 'FW1']) {
        expect(yOf(snap, name), coreY, reason: '$name is not on the top tier');
      }
      final midY = yOf(snap, 'SW1');
      expect(yOf(snap, 'SW2'), midY, reason: 'switches share the middle tier');
      expect(midY, greaterThan(coreY));
      for (final name in ['PC1', 'PC2', 'PC3', 'SRV1', 'SRV2']) {
        expect(yOf(snap, name), greaterThan(midY), reason: name);
      }
      // Columns aligned per switch: each endpoint sits inside its own
      // switch's column block, and no endpoint drifts to another column.
      // (The fan order is the cabling order, so the exact slot varies -
      // staying inside the switch's block is the promise.)
      expect(
        (xOf(snap, 'SRV1') - xOf(snap, 'SW1')).abs(),
        lessThanOrEqualTo(180),
        reason: 'SRV1 left SW1 column',
      );
      expect(
        (xOf(snap, 'PC1') - xOf(snap, 'SW1')).abs(),
        lessThanOrEqualTo(180),
        reason: 'PC1 left SW1 column',
      );
      expect(
        (xOf(snap, 'PC2') - xOf(snap, 'SW1')).abs(),
        lessThanOrEqualTo(180),
        reason: 'PC2 left SW1 column',
      );
      expect(xOf(snap, 'PC3'), lessThan(xOf(snap, 'SW2')));
      expect(xOf(snap, 'SRV2'), greaterThan(xOf(snap, 'SW2')));
    });

    test('campus: pinned coordinates for the tiered plan', () {
      final snap = computeLayoutSnapshot(intent, style: 'campus');
      final got = <String, List<int>>{
        for (final s in snap.spots) s.name: [s.x.toInt(), s.y.toInt()],
      };
      expect(got, {
        'R1': [580, 60],
        'R2': [700, 60],
        'FW1': [820, 60],
        'SW1': [505, 250],
        'SW2': [955, 250],
        'PC1': [385, 440],
        'PC2': [505, 440],
        'SRV1': [625, 440],
        'PC3': [895, 440],
        'SRV2': [1015, 440],
      });
    });

    test('star: switches radiate, their own PCs fan outward', () {
      final snap = computeLayoutSnapshot(intent, style: 'star');
      expect(
        snap.spots.length,
        intent.nodes.length,
        reason: 'star dropped a device',
      );
      // Two switches sit at even angles (here: straight up and straight
      // down) on a ring of radius 1.8 pitches round the centre at
      // (700, 60 + 216 + 120).
      const cx = 700.0;
      const cy = 396.0;
      expect(xOf(snap, 'SW1'), closeTo(cx, 1));
      expect(yOf(snap, 'SW1'), closeTo(cy - 216, 1));
      expect(xOf(snap, 'SW2'), closeTo(cx, 1));
      expect(yOf(snap, 'SW2'), closeTo(cy + 216, 1));
      // Every endpoint sits further out than the switch it hangs off.
      double radius2(String name) {
        final dx = xOf(snap, name) - cx;
        final dy = yOf(snap, name) - cy;
        return dx * dx + dy * dy;
      }

      for (final pair in [
        ['SW1', 'PC1'],
        ['SW1', 'PC2'],
        ['SW1', 'SRV1'],
        ['SW2', 'PC3'],
        ['SW2', 'SRV2'],
      ]) {
        expect(
          radius2(pair[1]),
          greaterThan(radius2(pair[0])),
          reason: '${pair[1]} is not outside its switch ${pair[0]}',
        );
      }
      // The middle endpoint of SW1's fan lies exactly on its spoke, one
      // pitch beyond the switch ring - outward, which for the top switch is
      // straight up.
      expect(xOf(snap, 'PC2'), closeTo(cx, 1));
      expect(yOf(snap, 'PC2'), closeTo(cy - 336, 1));
    });

    test('ring: core inside, ring devices equidistant, kinds alternating', () {
      final snap = computeLayoutSnapshot(intent, style: 'ring');
      expect(
        snap.spots.length,
        intent.nodes.length,
        reason: 'ring dropped a device',
      );
      const cx = 700.0;
      final sw1 = snap.spots.firstWhere((s) => s.name == 'SW1');
      // The first ring slot is straight up from the centre.
      expect(sw1.x, closeTo(cx, 1));
      expect(sw1.y, closeTo(60, 1));
      final centreY = 60 + 253.6902;
      double dist2(LayoutSpot s) =>
          (s.x - cx) * (s.x - cx) + (s.y - centreY) * (s.y - centreY);
      // Ring devices all sit on the ring; routers sit well inside it.
      final ringNames = ['SW1', 'PC1', 'SW2', 'PC2', 'PC3', 'SRV1', 'SRV2'];
      final ringDist = dist2(
        snap.spots.firstWhere((s) => s.name == ringNames.first),
      );
      for (final name in ringNames) {
        final d = dist2(snap.spots.firstWhere((s) => s.name == name));
        expect(d, closeTo(ringDist, 2 * 253 * 1 + 2), reason: name);
      }
      for (final name in ['R1', 'R2', 'FW1']) {
        final d = dist2(snap.spots.firstWhere((s) => s.name == name));
        expect(d, lessThan(ringDist / 4), reason: '$name is not inside');
      }
      // Walking the ring by angle, no two switches stand side by side: the
      // interleave separates them with the machines they serve. (Perfect
      // alternation is impossible when one side outnumbers the other - two
      // switches, five endpoints here - so the remainder may bunch, the
      // switches may not.)
      final byAngle = [
        for (final name in ringNames)
          (
            name,
            math.atan2(
              yOf(snap, name) - centreY,
              xOf(snap, name) - cx,
            ),
          ),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      const switches = {'SW1', 'SW2'};
      for (var i = 0; i < byAngle.length; i++) {
        final name = byAngle[i].$1;
        final prev = byAngle[(i - 1) % byAngle.length].$1;
        expect(
          switches.contains(name) && switches.contains(prev),
          isFalse,
          reason: '$name and $prev stand together on the ring',
        );
      }
    });

    test('edge cases: one router, no switches, no crash and no fallback', () {
      final lone = NetworkIntent(
        projectName: 'lone',
        nodes: const [NetNode(name: 'R1', type: 'router')],
      );
      final islands = NetworkIntent(
        projectName: 'islands',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'PC1', type: 'pc'),
          NetNode(name: 'PC2', type: 'pc'),
          NetNode(name: 'PC3', type: 'pc'),
        ],
      );
      for (final style in const ['ring', 'star', 'backbone', 'campus']) {
        final one = computeLayoutSnapshot(lone, style: style);
        expect(one.spots.length, 1, reason: style);
        final many = computeLayoutSnapshot(islands, style: style);
        expect(many.spots.length, islands.nodes.length, reason: style);
        expect(
          {for (final s in many.spots) '${s.x},${s.y}'}.length,
          islands.nodes.length,
          reason: '$style piled devices up with no switches present',
        );
      }
      // A star with no switches is still a star: the core sits at the
      // centre and the endpoints spread on one ring round it - one-device
      // spokes - not some other drawing.
      final star = computeLayoutSnapshot(islands, style: 'star');
      final r1 = star.spots.firstWhere((s) => s.name == 'R1');
      double dist2(LayoutSpot s) =>
          (s.x - r1.x) * (s.x - r1.x) + (s.y - r1.y) * (s.y - r1.y);
      final pc1 = star.spots.firstWhere((s) => s.name == 'PC1');
      final pc2 = star.spots.firstWhere((s) => s.name == 'PC2');
      final pc3 = star.spots.firstWhere((s) => s.name == 'PC3');
      final ring2 = dist2(pc1);
      expect(dist2(pc2), closeTo(ring2, 2 * 300 + 2), reason: 'PC2');
      expect(dist2(pc3), closeTo(ring2, 2 * 300 + 2), reason: 'PC3');
      expect(ring2, greaterThan(0), reason: 'PCs do not sit on the core');
    });

    test('a large lab (36 devices) still places every device, once', () {
      final big = _plan('2 routers, 4 switches and 30 PCs with OSPF');
      for (final style in const ['ring', 'star', 'backbone', 'campus']) {
        final snap = computeLayoutSnapshot(big, style: style);
        expect(
          snap.spots.length,
          big.nodes.length,
          reason: '$style dropped a device on a large lab',
        );
        expect(
          {for (final s in snap.spots) '${s.x},${s.y}'}.length,
          big.nodes.length,
          reason: '$style piled devices up on a large lab',
        );
        expect(
          snap.spots.every((s) => s.x >= 0),
          isTrue,
          reason: '$style placed a device off the canvas on a large lab',
        );
      }
    });

    test('the new drawings are not silent fallbacks of the old ones', () {
      for (final style in const ['ring', 'star', 'backbone', 'campus']) {
        final snap = computeLayoutSnapshot(intent, style: style);
        final drawing = snap.spots
            .map((s) => '${s.name}@${s.x.toInt()},${s.y.toInt()}')
            .join('|');
        for (final other in const ['tree', 'radial', 'circle', 'rows']) {
          final otherSnap = computeLayoutSnapshot(intent, style: other);
          final otherPrint = otherSnap.spots
              .map((s) => '${s.name}@${s.x.toInt()},${s.y.toInt()}')
              .join('|');
          expect(
            drawing,
            isNot(otherPrint),
            reason: '$style drew exactly what $other draws',
          );
        }
      }
    });

    test('the chosen style reaches the build payload with its positions', () {
      // The gallery pick travels as a bare style string; the payload must
      // carry the style through AND the exact spots the gallery drew, so the
      // file is parked on the picture the user agreed to.
      for (final style in const ['ring', 'star', 'backbone', 'campus']) {
        final snapshot = computeLayoutSnapshot(intent, style: style);
        final payload = PacketTracerAdapter.autopilotPlan(
          intent,
          layout: {'style': style},
        );
        final layout = payload['layout'] as Map;
        expect(layout['style'], style, reason: style);
        final positions = (layout['positions'] as Map).cast<String, List>();
        for (final spot in snapshot.spots) {
          expect(
            positions[spot.name],
            <int>[spot.x.toInt(), spot.y.toInt()],
            reason: '$style moved ${spot.name} between preview and payload',
          );
        }
      }
    });
  });

  group('the drawings are genuinely different from each other', () {
    test('no two styles draw the same picture', () {
      // The complaint that started this: tree/wide/compact are one algorithm at
      // three sizes, so the gallery offered near-identical pictures.
      final intent = _plan(
        '2 routers, 2 switches, 8 PCs and 2 servers with OSPF',
      );
      final parked = resolveSideNames(intent, kinds: const ['server']);
      expect(parked, isNotEmpty);
      final prints = computeAllLayouts(intent, side: parked)
          .values
          .map(
            (s) => s.spots.map((spot) => '${spot.name}@${spot.x},${spot.y}').join('|'),
          )
          .toSet();
      expect(prints.length, kLayoutStyles.length);
    });

    test('every style places every device, once, on the canvas', () {
      final intent = _plan('3 routers, 3 switches, 20 PCs and 3 servers');
      final parked = resolveSideNames(intent, kinds: const ['server']);
      for (final style in kLayoutStyles) {
        final snap = computeLayoutSnapshot(
          intent,
          style: style,
          side: parked,
        );
        expect(
          snap.spots.length,
          intent.nodes.length,
          reason: '$style dropped a device',
        );
        expect(
          {for (final s in snap.spots) '${s.x},${s.y}'}.length,
          snap.spots.length,
          reason: '$style piled two devices on one point',
        );
        expect(
          snap.spots.every((s) => s.x >= 0),
          isTrue,
          reason: '$style put a device off the left of the canvas',
        );
      }
    });

    test('the drawings do not all look alike in silhouette', () {
      // A scale-only variant shares its aspect ratio with its parent; a
      // different algorithm does not. This is what "all the layouts look the
      // same" means in practice.
      final intent = _plan('2 routers, 2 switches, 10 PCs and 2 servers');
      final shapes = <String, List<double>>{};
      for (final style in kLayoutStyles) {
        final snap = computeLayoutSnapshot(intent, style: style);
        shapes[style] = [
          snap.width / snap.height,
          snap.maxY,
        ];
      }
      final wideRatios = shapes.entries
          .map((e) => e.value[0] / (e.value[1] / 1000))
          .toSet();
      // At least four distinct proportions across ten drawings.
      expect(wideRatios.length, greaterThanOrEqualTo(4));
    });
  });

  group('zones: "servers one side, routers the other"', () {
    final intent = _plan('2 routers, 1 switch, 6 PCs and 3 servers');
    final servers = resolveSideNames(intent, kinds: const ['server']);
    final routers = resolveSideNames(intent, kinds: const ['router']);

    test('one zone per edge, and the two groups really are opposite', () {
      final snap = computeLayoutSnapshot(
        intent,
        style: 'grouped',
        zones: [
          LayoutZone(servers, edge: 'left'),
          LayoutZone(routers, edge: 'right'),
        ],
      );
      final x = <String, double>{for (final s in snap.spots) s.name: s.x};
      expect(<double?>{for (final s in servers) x[s]}.length, 1);
      expect(<double?>{for (final r in routers) x[r]}.length, 1);
      final switchX = x[intent.nodes.firstWhere((n) => n.type == 'switch').name]!;
      expect(servers.every((s) => x[s]! < switchX), isTrue);
      expect(routers.every((r) => x[r]! > switchX), isTrue);
    });

    test('two zones are a different drawing from one zone', () {
      final one = computeLayoutSnapshot(
        intent,
        style: 'grouped',
        zones: [LayoutZone(servers, edge: 'left')],
      );
      final two = computeLayoutSnapshot(
        intent,
        style: 'grouped',
        zones: [
          LayoutZone(servers, edge: 'left'),
          LayoutZone(routers, edge: 'right'),
        ],
      );
      expect(
        one.spots.map((s) => '${s.name}@${s.x},${s.y}').join('|'),
        isNot(two.spots.map((s) => '${s.name}@${s.x},${s.y}').join('|')),
      );
    });

    test('a zone naming devices the plan lacks is ignored', () {
      final snap = computeLayoutSnapshot(
        intent,
        style: 'grouped',
        zones: const [LayoutZone(['NOPE1', 'NOPE2'])],
      );
      expect(snap.spots.length, intent.nodes.length);
    });
  });
}
