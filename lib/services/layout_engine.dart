import 'dart:math' as math;

import '../models/network_intent.dart';

/// The four drawings the engine can produce, mirrored from the sidecar's
/// `pkt_builder.LAYOUT_STYLES`.
///
/// This is a deliberate re-implementation, not an approximation: the preview a
/// user picks from has to be the drawing the `.pkt` is built with, or the
/// choice is a lie. The geometry constants below are copied from
/// `pkt_builder.py` and a test pins them against the same inputs, so the two
/// stay in step.
const List<String> kLayoutStyles = <String>[
  'tree',
  'wide',
  'compact',
  'rows',
  'grouped',
  'layered',
  'backbone',
  'campus',
  'star',
  'radial',
  'circle',
  'ring',
  'grid',
  'split',
];

/// The drawings that place every device from the plan's own shape - its
/// links, or each device's role - and never nest anything under an uplink.
///
/// These are the ones that read differently at a glance. `tree`, `wide` and
/// `compact` are the same tree at three sizes, which is why offering them side
/// by side looked like three near-identical pictures.
///
/// `ring`, `star`, `backbone` and `campus` are flat in the same sense - a
/// device's spot comes from its role and (for star/backbone/campus) from the
/// neighbour it hangs off, never from being nested under an uplink - so they
/// live here too. They have their own placement functions, dispatched in
/// [computeLayoutSnapshot]; the sidecar's `LAYOUT_FLAT_STYLES` mirror does not
/// know them yet, which is safe only because every build carries the resolved
/// `positions` map the sidecar honours spot for spot.
const List<String> kFlatLayoutStyles = <String>[
  'radial',
  'circle',
  'grid',
  'split',
  'ring',
  'star',
  'backbone',
  'campus',
];

/// One group of devices parked at one edge, as the engine reads it.
class LayoutZone {
  final List<String> side;
  final String edge;

  const LayoutZone(this.side, {this.edge = ''});
}

/// Per-style geometry, mirrored from `LAYOUT_STYLE_SHAPES`.
class LayoutShape {
  final double spacing;
  final int columns;
  const LayoutShape(this.spacing, this.columns);
}

const Map<String, LayoutShape> kLayoutStyleShapes = <String, LayoutShape>{
  'tree': LayoutShape(1.0, 4),
  'wide': LayoutShape(1.3, 6),
  'compact': LayoutShape(0.75, 4),
  'rows': LayoutShape(1.0, 4),
  'grouped': LayoutShape(1.0, 4),
  'layered': LayoutShape(1.0, 4),
  'backbone': LayoutShape(1.0, 4),
  'campus': LayoutShape(1.0, 4),
  'star': LayoutShape(1.0, 4),
  'radial': LayoutShape(1.0, 4),
  'circle': LayoutShape(1.0, 4),
  'ring': LayoutShape(1.0, 4),
  'grid': LayoutShape(1.0, 4),
  'split': LayoutShape(1.0, 4),
};

/// Geometry constants copied from `pkt_builder.py`.
const double kRowTop = 60;
const double kBandStep = 190;
const double kRowStep = 130;
const double kDevicePitch = 120;
const double kBlockGap = 150;
const int kGridColumns = 4;
const double kCanvasWidth = 1400;
const double kXStart = 140;
const int kRowsPerRow = 8;

/// How far out each ring of the `radial` drawing sits, as a multiple of the
/// device pitch. A ring has to clear the one inside it, so the step is a
/// little over one pitch rather than exactly one.
const double kRadialFirstRing = 1.4;
const double kRadialRingStep = 1.6;

/// Drawing bands, top to bottom: core, aggregation, access, services, hosts.
const int kTierCore = 0;
const int kTierAggregation = 1;
const int kTierAccess = 2;
const int kTierServices = 3;
const int kTierHosts = 4;

int layoutTierOf(String type) {
  final kind = type.trim().toLowerCase();
  const core = {'router', 'firewall', 'cloud', 'modem', 'wireless-router'};
  const aggregation = {'multilayer switch', 'wlc'};
  const access = {'switch', 'wireless', 'accesspoint', 'wireless access point'};
  const services = {'server'};
  if (core.contains(kind)) return kTierCore;
  if (aggregation.contains(kind)) return kTierAggregation;
  if (access.contains(kind)) return kTierAccess;
  if (services.contains(kind)) return kTierServices;
  return kTierHosts;
}

/// A human label for a style, for the gallery.
String layoutStyleLabel(String style) => switch (style) {
  'wide' => 'Wide',
  'compact' => 'Compact',
  'rows' => 'Straight rows',
  'grouped' => 'Grouped to one side',
  'layered' => 'Layered left to right',
  'backbone' => 'Backbone riser',
  'campus' => 'Campus tiers',
  'star' => 'Star',
  'radial' => 'Radial rings',
  'circle' => 'One circle',
  'ring' => 'Ring',
  'grid' => 'Even grid',
  'split' => 'One column per kind',
  _ => 'Site trees',
};

/// The sentence under a style's thumbnail: what the drawing is for.
String layoutStyleBlurb(String style) => switch (style) {
  'wide' => 'Roomier - bigger gaps, easier to read a busy lab',
  'compact' => 'Everything closer together on one screen',
  'rows' => 'One band per device kind, left to right',
  'grouped' => 'Servers in their own column, clear of the hosts',
  'layered' => 'Ranks become columns - the classic hierarchy, sideways',
  'backbone' => 'One horizontal backbone - PCs drop below, servers sit above',
  'campus' => 'Core on top, switches in the middle, endpoints in columns',
  'star' => 'Switches radiate from the router, their PCs fanned outward',
  'radial' => 'Core in the middle, endpoints on the outside',
  'circle' => 'Every device on one ring - a quick overview',
  'ring' => 'Switches alternate with endpoints on one ring, core in the middle',
  'grid' => 'An evenly spaced box, ignoring the topology',
  'split' => 'A vertical column per kind of device',
  _ => 'Each site a tree, hosts under the switch they use',
};

/// One device's resolved spot in a [LayoutSnapshot].
class LayoutSpot {
  final String name;
  final String type;
  final double x;
  final double y;
  final int tier;

  const LayoutSpot(this.name, this.type, this.x, this.y, this.tier);
}

/// A fully-resolved drawing: where every device sits, and the drawing settings
/// it was produced with.
class LayoutSnapshot {
  final String style;
  final double spacing;
  final int columns;
  final List<LayoutSpot> spots;

  /// The bounding box of the drawing, so a thumbnail can fit it to any canvas.
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  const LayoutSnapshot({
    required this.style,
    required this.spacing,
    required this.columns,
    required this.spots,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  double get width => math.max(1, maxX - minX);
  double get height => math.max(1, maxY - minY);

  bool get isEmpty => spots.isEmpty;
}

/// Python's `round()`: ties go to the EVEN neighbour (banker's rounding).
///
/// The sidecar builds its `.pkt` coordinates with `int(round(x))`, so the
/// preview must round the same way or a device lands one pixel off the file
/// the user agreed to. Dart's `roundToDouble` breaks ties away from zero, so
/// `202.5` would preview at 203 where the file says 202.
double _pyRound(double value) {
  final floor = value.floorToDouble();
  final diff = value - floor;
  if (diff < 0.5) return floor;
  if (diff > 0.5) return floor + 1;
  // Exactly .5: pick the even neighbour.
  return (floor % 2 == 0) ? floor : floor + 1;
}

/// Compute a drawing for [intent], mirroring the sidecar's `layout_positions`.
///
/// The plan's links are read as a topology: a device's parent is the neighbour
/// one band closer to the core. Devices with no links keep their own spot by
/// band. Equal-tier neighbours (two routers on a WAN) stay side by side.
LayoutSnapshot computeLayoutSnapshot(
  NetworkIntent intent, {
  String style = 'tree',
  Iterable<String> side = const <String>[],
  String sideEdge = 'left',
  Iterable<LayoutZone> zones = const <LayoutZone>[],
}) {
  final shape = kLayoutStyleShapes[style] ?? kLayoutStyleShapes['tree']!;
  final scale = shape.spacing;
  final pitch = kDevicePitch * scale;
  final gap = kBlockGap * scale;
  final bandStep = kBandStep * scale;
  final rowStep = kRowStep * scale;
  final gridColumns = shape.columns.clamp(1, 12);
  final treeAware = style != 'rows' && !kFlatLayoutStyles.contains(style);

  // Ordered, de-duplicated entries (plan order).
  final entries = <List<String>>[];
  final seen = <String>{};
  for (final n in intent.nodes) {
    if (n.name.isEmpty || seen.contains(n.name)) continue;
    seen.add(n.name);
    entries.add([n.name, n.type.trim().toLowerCase()]);
  }
  if (entries.isEmpty) {
    return LayoutSnapshot(
      style: style,
      spacing: scale,
      columns: gridColumns,
      spots: const [],
      minX: 0,
      maxX: 1,
      minY: 0,
      maxY: 1,
    );
  }
  final order = <String, int>{
    for (var i = 0; i < entries.length; i++) entries[i][0]: i,
  };
  final tier = <String, int>{for (final e in entries) e[0]: layoutTierOf(e[1])};

  final neighbours = <String, List<String>>{
    for (final e in entries) e[0]: <String>[],
  };
  for (final l in intent.links) {
    if (neighbours.containsKey(l.a) &&
        neighbours.containsKey(l.b) &&
        l.a != l.b) {
      neighbours[l.a]!.add(l.b);
      neighbours[l.b]!.add(l.a);
    }
  }

  final children = <String, List<String>>{
    for (final e in entries) e[0]: <String>[],
  };
  final roots = <String>[];
  for (final e in entries) {
    final name = e[0];
    final uphill = neighbours[name]!
        .where((o) => (tier[o] ?? kTierHosts) < (tier[name] ?? kTierHosts))
        .toList();
    if (uphill.isNotEmpty) {
      uphill.sort((a, b) {
        final t = (tier[a] ?? 0).compareTo(tier[b] ?? 0);
        return t != 0 ? t : (order[a] ?? 0).compareTo(order[b] ?? 0);
      });
      children[uphill.first]!.add(name);
    } else {
      roots.add(name);
    }
  }

  final width = <String, double>{};
  List<String> byTierGroup(List<String> names, int want) =>
      names.where((n) => (tier[n] ?? kTierHosts) == want).toList();

  double span(String name) {
    if (width.containsKey(name)) return width[name]!;
    final kids = children[name]!;
    final branches = kids.where((k) => children[k]!.isNotEmpty).toList();
    final leaves = kids.where((k) => children[k]!.isEmpty).toList();
    var need = pitch;
    if (branches.isNotEmpty) {
      var sum = 0.0;
      for (final k in branches) {
        sum += span(k);
      }
      need = math.max(need, sum + gap * (branches.length - 1));
    }
    for (var t = 0; t < 5; t++) {
      final group = byTierGroup(leaves, t);
      if (group.isEmpty) continue;
      need = math.max(need, math.min(group.length, gridColumns) * pitch);
    }
    width[name] = need;
    return need;
  }

  final bands = <int, double>{};
  final usedTiers = tier.values.toSet().toList()..sort();
  for (var i = 0; i < usedTiers.length; i++) {
    bands[usedTiers[i]] = kRowTop + i * bandStep;
  }

  var spots = <String, List<double>>{};
  void place(String name, double left) {
    final need = span(name);
    spots[name] = [left + need / 2, bands[tier[name]] ?? kRowTop];
    if (!treeAware) return;
    final kids = children[name]!;
    final branches = kids.where((k) => children[k]!.isNotEmpty).toList();
    if (branches.isNotEmpty) {
      var block = 0.0;
      for (final k in branches) {
        block += span(k);
      }
      block += gap * (branches.length - 1);
      var cursor = left + (need - block) / 2;
      for (final k in branches) {
        place(k, cursor);
        cursor += span(k) + gap;
      }
    }
    final leaves = kids.where((k) => children[k]!.isEmpty).toList();
    for (var t = 0; t < 5; t++) {
      final group = byTierGroup(leaves, t);
      if (group.isEmpty) continue;
      final columns = math.min(group.length, gridColumns);
      final grid = columns * pitch;
      final gridLeft = left + (need - grid) / 2;
      for (var index = 0; index < group.length; index++) {
        final row = index ~/ columns;
        final column = index % columns;
        final inRow = math.min(columns, group.length - row * columns);
        final rowLeft = gridLeft + (grid - inRow * pitch) / 2;
        spots[group[index]] = [
          rowLeft + column * pitch + pitch / 2,
          bands[t]! + row * rowStep,
        ];
      }
    }
  }

  if (style == 'rows') {
    for (var t = 0; t < 5; t++) {
      final group = entries
          .map((e) => e[0])
          .where((n) => (tier[n] ?? kTierHosts) == t)
          .toList();
      if (group.isEmpty) continue;
      final columns = math.min(
        group.length,
        math.max(gridColumns, kRowsPerRow),
      );
      for (var index = 0; index < group.length; index++) {
        final row = index ~/ columns;
        final column = index % columns;
        final inRow = math.min(columns, group.length - row * columns);
        final rowLeft =
            kXStart +
            math.max((kCanvasWidth - 2 * kXStart - inRow * pitch) / 2, 0);
        spots[group[index]] = [
          rowLeft + column * pitch + pitch / 2,
          bands[t]! + row * rowStep,
        ];
      }
    }
  }

  var total = 0.0;
  for (final r in roots) {
    total += span(r);
  }
  total += gap * math.max(roots.length - 1, 0);
  var cursor = kXStart + math.max((kCanvasWidth - 2 * kXStart - total) / 2, 0);
  for (final r in roots) {
    place(r, cursor);
    cursor += span(r) + gap;
  }

  // Whole-pixel spots, and never two devices on the same point.
  if (kFlatLayoutStyles.contains(style)) {
    spots = switch (style) {
      'ring' => _ringPositions(entries, tier, pitch),
      'star' => _starPositions(entries, tier, children, pitch),
      'backbone' => _backbonePositions(
        entries,
        tier,
        children,
        pitch,
        gap,
        rowStep,
        gridColumns,
      ),
      'campus' => _campusPositions(
        entries,
        tier,
        children,
        pitch,
        gap,
        rowStep,
        bandStep,
        gridColumns,
      ),
      _ => _flatPositions(style, entries, tier, pitch, gap, rowStep),
    };
  } else if (style == 'layered') {
    spots = _layeredPositions(
      entries,
      tier,
      children,
      roots,
      bandStep,
      rowStep,
    );
  } else if (style == 'grouped') {
    spots = _groupedPositions(
      entries,
      tier,
      bands,
      spots,
      zones.isEmpty
          ? <LayoutZone>[
              if (side.isNotEmpty)
                LayoutZone(
                  <String>[
                    for (final name in side)
                      if (spots.containsKey(name.trim())) name.trim(),
                  ],
                  edge: sideEdge,
                ),
            ]
          : zones.toList(),
      pitch,
      gap,
      rowStep,
    );
  }

  final taken = <String>{};
  final resolved = <LayoutSpot>[];
  // In the order the spots were placed, which is the order the engine resolves
  // them in: two devices that would land on one point are pushed apart in that
  // order, so walking the plan instead would move a different device.
  for (final name in spots.keys) {
    final raw = spots[name];
    if (raw == null) continue;
    var px = _pyRound(raw[0]);
    final py = _pyRound(raw[1]);
    var guard = 0;
    while (taken.contains('${px.toInt()},${py.toInt()}') && guard < 64) {
      px += pitch;
      guard++;
    }
    taken.add('${px.toInt()},${py.toInt()}');
    resolved.add(
      LayoutSpot(name, _kindOf(entries, name), px, py, tier[name] ?? kTierHosts),
    );
  }

  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final s in resolved) {
    minX = math.min(minX, s.x);
    maxX = math.max(maxX, s.x);
    minY = math.min(minY, s.y);
    maxY = math.max(maxY, s.y);
  }
  if (resolved.isEmpty) {
    minX = 0;
    maxX = 1;
    minY = 0;
    maxY = 1;
  }
  return LayoutSnapshot(
    style: style,
    spacing: scale,
    columns: gridColumns,
    spots: resolved,
    minX: minX,
    maxX: maxX,
    minY: minY,
    maxY: maxY,
  );
}

/// Every device name, core first then outward, plan order inside a role.
List<String> _byRole(List<List<String>> entries, Map<String, int> tier) {
  final ordered = <({int role, int index, String name})>[
    for (var i = 0; i < entries.length; i++)
      (role: tier[entries[i][0]] ?? kTierHosts, index: i, name: entries[i][0]),
  ];
  ordered.sort((a, b) {
    final byRole = a.role.compareTo(b.role);
    return byRole != 0 ? byRole : a.index.compareTo(b.index);
  });
  return <String>[for (final e in ordered) e.name];
}

String _kindOf(List<List<String>> entries, String name) {
  for (final e in entries) {
    if (e[0] == name) return e[1];
  }
  return '';
}

/// The drawings that place every device from its role, not its uplink.
///
/// Each of these ignores the tree the other styles build, which is the whole
/// point: the same lab has to be readable in more than one silhouette.
Map<String, List<double>> _flatPositions(
  String style,
  List<List<String>> entries,
  Map<String, int> tier,
  double pitch,
  double gap,
  double rowStep,
) {
  final byRole = <int, List<String>>{};
  for (final e in entries) {
    byRole.putIfAbsent(tier[e[0]] ?? kTierHosts, () => <String>[]).add(e[0]);
  }
  final roles = byRole.keys.toList()..sort();
  final spots = <String, List<double>>{};

  if (style == 'grid') {
    // An evenly spaced box, core first. Reads top-to-bottom like a table of
    // contents and stays inside the visible canvas no matter how many hosts a
    // plan has.
    final columns = math.max(
      1,
      math.min(_ceilSqrt(entries.length), 12),
    );
    final step = pitch + gap;
    final ordered = _byRole(entries, tier);
    for (var index = 0; index < ordered.length; index++) {
      final row = index ~/ columns;
      final column = index % columns;
      spots[ordered[index]] = [
        kXStart + column * step,
        kRowTop + row * step,
      ];
    }
    return spots;
  }

  if (style == 'split') {
    // One vertical column per kind of device, so a lab reads left to right as
    // core -> access -> services -> endpoints. This is the drawing that makes
    // "servers on one side, routers on the other" true by default.
    var widest = 0;
    for (final group in byRole.values) {
      widest = math.max(widest, group.length);
    }
    final columns = math.max(1, math.min(widest, kRowsPerRow));
    final columnWidth = columns * pitch + gap;
    for (var index = 0; index < roles.length; index++) {
      final group = byRole[roles[index]]!;
      final left = kXStart + index * columnWidth;
      final centre = left + math.min(group.length, columns) * pitch / 2;
      for (var row = 0; row < group.length; row++) {
        spots[group[row]] = [centre, kRowTop + row * rowStep];
      }
    }
    return spots;
  }

  if (style == 'circle') {
    // One ring for the whole lab, ordered so the core is together and the
    // hosts follow. An overview, not a place to read a config off.
    final count = entries.length;
    final radius = math.max(
      pitch * (count / (2 * math.pi)) + pitch,
      pitch * 1.5,
    );
    final centreX = kCanvasWidth / 2;
    final centreY = kRowTop + radius;
    final ordered = _byRole(entries, tier);
    for (var index = 0; index < ordered.length; index++) {
      final angle = -math.pi / 2 + 2 * math.pi * index / count;
      spots[ordered[index]] = [
        centreX + radius * math.cos(angle),
        centreY + radius * math.sin(angle),
      ];
    }
    return _keepOnCanvas(spots);
  }

  // radial: concentric rings by role, the core in the middle and the endpoints
  // on the outside, so the drawing has the shape of the lab.
  final base = pitch * kRadialFirstRing;
  final centreX = kCanvasWidth / 2;
  for (var index = 0; index < roles.length; index++) {
    final group = byRole[roles[index]]!;
    final ring = pitch * (kRadialFirstRing + kRadialRingStep * index);
    // Every ring is drawn around the same centre, which sits far enough down
    // the page that the outermost ring still starts on the canvas.
    final centreY = kRowTop + base + ring;
    for (var position = 0; position < group.length; position++) {
      final angle = -math.pi / 2 + 2 * math.pi * position / group.length;
      spots[group[position]] = [
        centreX + ring * math.cos(angle),
        centreY + ring * math.sin(angle),
      ];
    }
  }
  return _keepOnCanvas(spots);
}

/// A drawing centred on the canvas can reach past its left edge.
///
/// The ring layouts put devices all the way round a centre, so with enough
/// roles the leftmost one lands at a negative x - which is off the visible
/// workspace in Packet Tracer. Nudging the whole drawing right is the same
/// picture on the canvas rather than one device lost off the side.
Map<String, List<double>> _keepOnCanvas(Map<String, List<double>> spots) {
  if (spots.isEmpty) return spots;
  var minX = double.infinity;
  for (final spot in spots.values) {
    minX = math.min(minX, spot[0]);
  }
  if (minX >= kXStart) return spots;
  final shift = kXStart - minX;
  for (final spot in spots.values) {
    spot[0] = spot[0] + shift;
  }
  return spots;
}

int _ceilSqrt(int value) {
  if (value <= 1) return 1;
  return math.sqrt(value).ceil();
}

/// One device (or a small cluster of them) exactly on a drawing's centre.
///
/// Two routers cannot share a point, so a group spreads on a tiny circle just
/// big enough to keep one pitch between neighbours - the same guarantee the
/// ring drawings use for their own circumference.
void _parkAtCentre(
  List<String> names,
  Map<String, List<double>> spots,
  double centreX,
  double centreY,
  double pitch,
) {
  if (names.isEmpty) return;
  if (names.length == 1) {
    spots[names.first] = [centreX, centreY];
    return;
  }
  final radius = math.max(
    pitch * 0.75,
    pitch / (2 * math.sin(math.pi / names.length)),
  );
  for (var i = 0; i < names.length; i++) {
    final angle = -math.pi / 2 + 2 * math.pi * i / names.length;
    spots[names[i]] = [
      centreX + radius * math.cos(angle),
      centreY + radius * math.sin(angle),
    ];
  }
}

/// The `ring` drawing: one circle, the core in the middle of it.
///
/// Switches alternate with the machines they serve as you walk round the
/// ring - the textbook token/ring-network picture - and the routers sit at
/// the centre rather than on the ring, because a ring lab's core is what
/// everything on the ring hangs off.
Map<String, List<double>> _ringPositions(
  List<List<String>> entries,
  Map<String, int> tier,
  double pitch,
) {
  final core = <String>[];
  final switches = <String>[];
  final rest = <String>[];
  for (final e in entries) {
    final t = tier[e[0]] ?? kTierHosts;
    if (t == kTierCore) {
      core.add(e[0]);
    } else if (t == kTierAggregation || t == kTierAccess) {
      switches.add(e[0]);
    } else {
      rest.add(e[0]);
    }
  }

  // Interleave: switch, endpoint, switch, endpoint ... When one side runs
  // out the remainder follows consecutively, so every count still closes the
  // ring. Plan order inside each half keeps the drawing deterministic.
  final ring = <String>[];
  final rounds = math.max(switches.length, rest.length);
  for (var i = 0; i < rounds; i++) {
    if (i < switches.length) ring.add(switches[i]);
    if (i < rest.length) ring.add(rest[i]);
  }

  final spots = <String, List<double>>{};
  final centreX = kCanvasWidth / 2;
  if (ring.isEmpty) {
    // A lab of nothing but core devices: they take the centre together.
    _parkAtCentre(core, spots, centreX, kRowTop, pitch);
    return spots;
  }
  // The circumference has to hold one pitch per device, like `circle`'s.
  final radius = math.max(
    pitch * (ring.length / (2 * math.pi)) + pitch,
    pitch * 1.8,
  );
  final centreY = kRowTop + radius;
  for (var i = 0; i < ring.length; i++) {
    final angle = -math.pi / 2 + 2 * math.pi * i / ring.length;
    spots[ring[i]] = [
      centreX + radius * math.cos(angle),
      centreY + radius * math.sin(angle),
    ];
  }
  _parkAtCentre(core, spots, centreX, centreY, pitch);
  return _keepOnCanvas(spots);
}

/// The `star` drawing: routers at the centre, access switches radiating at
/// even angles, each switch's endpoints fanned between its switch and the
/// canvas edge.
///
/// The fans follow the plan's links (`children`), so a PC sits on its own
/// switch's spoke - this is the drawing that makes "every PC hangs off the
/// switch it is cabled to" visible. Endpoints no switch claims (unlinked, or
/// hung off a router or a server) share the fans round-robin in plan order
/// rather than disappearing; a lab with no switches at all draws its
/// endpoints as one-device spokes, which is the same ring of rays a star
/// with empty switches degenerates to.
Map<String, List<double>> _starPositions(
  List<List<String>> entries,
  Map<String, int> tier,
  Map<String, List<String>> children,
  double pitch,
) {
  final core = <String>[];
  final switches = <String>[];
  for (final e in entries) {
    final t = tier[e[0]] ?? kTierHosts;
    if (t == kTierCore) {
      core.add(e[0]);
    } else if (t == kTierAggregation || t == kTierAccess) {
      switches.add(e[0]);
    }
  }

  final spots = <String, List<double>>{};
  final centreX = kCanvasWidth / 2;
  final count = math.max(switches.length, 1);
  // Adjacent spokes have to clear one pitch where the switches sit, so the
  // ring grows with the switch count; the floor keeps two or three switches
  // from crowding the centre.
  final firstRing = math.max(
    pitch * 1.8,
    count >= 2 ? pitch / (2 * math.sin(math.pi / count)) : 0.0,
  );
  final centreY = kRowTop + firstRing + pitch;
  _parkAtCentre(core, spots, centreX, centreY, pitch);

  if (switches.isEmpty) {
    // No switches to radiate: every endpoint becomes its own one-device
    // spoke, evenly spread round the centre. Still the star silhouette -
    // rays from the core - and no device is dropped or quietly redrawn as
    // some other style.
    final spokes = <String>[
      for (final e in entries)
        if ((tier[e[0]] ?? kTierHosts) >= kTierServices) e[0],
    ];
    final radius = math.max(
      pitch * (spokes.length / (2 * math.pi)) + pitch,
      pitch * 1.8,
    );
    for (var i = 0; i < spokes.length; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / spokes.length;
      spots[spokes[i]] = [
        centreX + radius * math.cos(angle),
        centreY + radius * math.sin(angle),
      ];
    }
    return _keepOnCanvas(spots);
  }

  // Each switch's fan: the machines that hang off it, plan order. A fan
  // takes endpoints only - another switch hanging off a multi-layer device
  // is itself on the radiating ring, never a machine at the end of a spoke.
  final fans = <List<String>>[
    for (final name in switches)
      <String>[
        for (final kid in children[name] ?? const <String>[])
          if ((tier[kid] ?? kTierHosts) >= kTierServices) kid,
      ],
  ];
  // Endpoints no switch claims join the fans round-robin so no drawing ever
  // drops a device.
  final claimed = <String>{for (final fan in fans) ...fan};
  var fanIndex = 0;
  for (final e in entries) {
    final name = e[0];
    if ((tier[name] ?? kTierHosts) < kTierServices) continue;
    if (claimed.contains(name)) continue;
    fans[fanIndex % fans.length].add(name);
    fanIndex++;
  }

  for (var i = 0; i < switches.length; i++) {
    final angle = -math.pi / 2 + 2 * math.pi * i / switches.length;
    spots[switches[i]] = [
      centreX + firstRing * math.cos(angle),
      centreY + firstRing * math.sin(angle),
    ];
    final fan = fans[i];
    // The fan spreads across the arc this spoke owns. One ring of the spoke
    // holds as many endpoints as fit with an arc-length pitch between them,
    // keeping a margin so neighbouring switches' fans never touch; the rest
    // wrap onto a further ring, a little way out.
    var placed = 0;
    for (var ring = 0; placed < fan.length; ring++) {
      final radius = firstRing + pitch * (ring + 1);
      final cap = _fanCapacity(radius, switches.length, pitch);
      final inRing = math.min(cap, fan.length - placed);
      for (var slot = 0; slot < inRing; slot++) {
        final spread = angle + (slot - (inRing - 1) / 2) * (pitch / radius);
        spots[fan[placed]] = [
          centreX + radius * math.cos(spread),
          centreY + radius * math.sin(spread),
        ];
        placed++;
      }
    }
  }
  return _keepOnCanvas(spots);
}

/// How many endpoints one ring of a star spoke holds at [radius]: the arc
/// that spoke owns there (a fair share of the circle), at an arc-length
/// [pitch] between neighbours, with a margin so adjacent switches' fans keep
/// a visible gap. At least one - a spoke never refuses its machine.
int _fanCapacity(double radius, int switchCount, double pitch) {
  final count = math.max(switchCount, 1);
  final owned = 2 * math.pi * radius / count;
  return math.max(1, (owned * 0.8 / pitch).floor());
}

/// The `backbone` drawing - the classic ISP/campus riser.
///
/// One horizontal line of routers and switches across the middle, core at
/// the left and access at the right; PCs hang below the device they are
/// cabled to on short drops, and servers sit above it, so traffic literally
/// reads top-to-bottom. Each line device owns a horizontal block wide enough
/// for its own drops (wrapped when a switch serves more endpoints than fit
/// in one row), so neighbours' machines never land on each other.
Map<String, List<double>> _backbonePositions(
  List<List<String>> entries,
  Map<String, int> tier,
  Map<String, List<String>> children,
  double pitch,
  double gap,
  double rowStep,
  int gridColumns,
) {
  final spots = <String, List<double>>{};
  // The line, core first: routers, then aggregation, then access, plan
  // order inside a tier.
  final line = <String>[
    for (var t = kTierCore; t <= kTierAccess; t++)
      for (final e in entries)
        if ((tier[e[0]] ?? kTierHosts) == t) e[0],
  ];

  // Drops: servers above the line, hosts below, grouped by the line device
  // they hang off. Endpoints nothing on the line claims (unlinked, or hung
  // off a server) share one block at the far end rather than disappearing.
  final serverFan = <String, List<String>>{};
  final hostFan = <String, List<String>>{};
  final claimed = <String>{};
  for (final name in line) {
    for (final kid in children[name] ?? const <String>[]) {
      final t = tier[kid] ?? kTierHosts;
      if (t == kTierServices) {
        serverFan.putIfAbsent(name, () => <String>[]).add(kid);
        claimed.add(kid);
      } else if (t == kTierHosts) {
        hostFan.putIfAbsent(name, () => <String>[]).add(kid);
        claimed.add(kid);
      }
    }
  }
  final looseServers = <String>[];
  final looseHosts = <String>[];
  for (final e in entries) {
    final name = e[0];
    final t = tier[name] ?? kTierHosts;
    if (claimed.contains(name) || t <= kTierAccess) continue;
    if (t == kTierServices) {
      looseServers.add(name);
    } else {
      looseHosts.add(name);
    }
  }

  double fanWidth(int count) => math.min(count, gridColumns) * pitch;

  // How many rows a fan wraps into at its own width.
  int rowsFor(int count) {
    if (count == 0) return 0;
    final columns = math.min(count, gridColumns);
    return (count + columns - 1) ~/ columns;
  }

  var maxServerRows = rowsFor(looseServers.length);
  for (final name in line) {
    maxServerRows = math.max(
      maxServerRows,
      rowsFor((serverFan[name] ?? const <String>[]).length),
    );
  }
  // The line sits far enough down that the tallest stack of servers still
  // starts on the canvas.
  final backboneY = kRowTop + maxServerRows * rowStep;

  final hasLoose = looseServers.isNotEmpty || looseHosts.isNotEmpty;
  final looseWidth = math.max(
    pitch,
    math.max(fanWidth(looseServers.length), fanWidth(looseHosts.length)),
  );
  var total = hasLoose ? looseWidth : 0.0;
  for (final name in line) {
    total += math.max(
      pitch,
      math.max(
        fanWidth((serverFan[name] ?? const <String>[]).length),
        fanWidth((hostFan[name] ?? const <String>[]).length),
      ),
    );
  }
  total += gap * math.max(line.length + (hasLoose ? 1 : 0) - 1, 0);
  var cursor = kXStart + math.max((kCanvasWidth - 2 * kXStart - total) / 2, 0);

  // One fan around a centre x: rows wrap, each row centred, [direction]
  // above (-1) or below (+1) the line. The first row is one rowStep off the
  // line - a short drop, not a device on the line itself.
  void parkFan(List<String> fan, double centreX, int direction) {
    if (fan.isEmpty) return;
    final columns = math.min(fan.length, gridColumns);
    for (var index = 0; index < fan.length; index++) {
      final row = index ~/ columns;
      final column = index % columns;
      final inRow = math.min(columns, fan.length - row * columns);
      final gridWidth = columns * pitch;
      final rowLeft = centreX - gridWidth / 2 + (gridWidth - inRow * pitch) / 2;
      spots[fan[index]] = [
        rowLeft + column * pitch + pitch / 2,
        backboneY + direction * (row + 1) * rowStep,
      ];
    }
  }

  for (final name in line) {
    final width = math.max(
      pitch,
      math.max(
        fanWidth((serverFan[name] ?? const <String>[]).length),
        fanWidth((hostFan[name] ?? const <String>[]).length),
      ),
    );
    final centreX = cursor + width / 2;
    spots[name] = [centreX, backboneY];
    parkFan(serverFan[name] ?? const <String>[], centreX, -1);
    parkFan(hostFan[name] ?? const <String>[], centreX, 1);
    cursor += width + gap;
  }
  if (hasLoose) {
    final centreX = cursor + looseWidth / 2;
    parkFan(looseServers, centreX, -1);
    parkFan(looseHosts, centreX, 1);
  }
  return spots;
}

/// The `campus` drawing: two strict tiers over an aligned endpoint field.
///
/// Core routers centred on the top tier, distribution/access switches on the
/// middle tier directly under the core they hang off, and PCs and servers on
/// the bottom tier in columns aligned under their own switch - the standard
/// three-layer campus picture read from any direction. Endpoints no switch
/// claims take a column of their own at the end; a switch serving more
/// machines than fit in one row wraps them within its column block.
Map<String, List<double>> _campusPositions(
  List<List<String>> entries,
  Map<String, int> tier,
  Map<String, List<String>> children,
  double pitch,
  double gap,
  double rowStep,
  double bandStep,
  int gridColumns,
) {
  final spots = <String, List<double>>{};
  final cores = <String>[];
  final mids = <String>[];
  for (final e in entries) {
    final t = tier[e[0]] ?? kTierHosts;
    if (t == kTierCore) {
      cores.add(e[0]);
    } else if (t == kTierAggregation || t == kTierAccess) {
      mids.add(e[0]);
    }
  }

  // One column block per switch; endpoints nothing on the middle tier
  // claims take their own block at the end.
  final endpointFan = <String, List<String>>{};
  final claimed = <String>{};
  for (final name in mids) {
    for (final kid in children[name] ?? const <String>[]) {
      if ((tier[kid] ?? kTierHosts) >= kTierServices) {
        endpointFan.putIfAbsent(name, () => <String>[]).add(kid);
        claimed.add(kid);
      }
    }
  }
  final loose = <String>[
    for (final e in entries)
      if ((tier[e[0]] ?? kTierHosts) >= kTierServices &&
          !claimed.contains(e[0]))
        e[0],
  ];

  double fanWidth(int count) => math.min(count, gridColumns) * pitch;
  final widths = <double>[
    for (final name in mids)
      math.max(pitch, fanWidth((endpointFan[name] ?? const <String>[]).length)),
    if (loose.isNotEmpty) math.max(pitch, fanWidth(loose.length)),
  ];
  var total = 0.0;
  for (final width in widths) {
    total += width;
  }
  total += gap * math.max(widths.length - 1, 0);
  var cursor = kXStart + math.max((kCanvasWidth - 2 * kXStart - total) / 2, 0);

  final yTop = kRowTop;
  final yMid = kRowTop + bandStep;
  final yBase = kRowTop + 2 * bandStep;

  // Cores centred over the whole drawing. They share the top tier only with
  // each other, so a wide column field below never pushes them around.
  final centreX = cursor + total / 2;
  for (var i = 0; i < cores.length; i++) {
    spots[cores[i]] = [
      centreX + (i - (cores.length - 1) / 2) * pitch,
      yTop,
    ];
  }

  var block = 0;
  for (final name in mids) {
    final width = widths[block];
    final midX = cursor + width / 2;
    spots[name] = [midX, yMid];
    final fan = endpointFan[name] ?? const <String>[];
    final columns = math.min(fan.length, gridColumns);
    for (var index = 0; index < fan.length; index++) {
      final row = index ~/ columns;
      final column = index % columns;
      final inRow = math.min(columns, fan.length - row * columns);
      final gridWidth = columns * pitch;
      final rowLeft = midX - gridWidth / 2 + (gridWidth - inRow * pitch) / 2;
      spots[fan[index]] = [
        rowLeft + column * pitch + pitch / 2,
        yBase + row * rowStep,
      ];
    }
    cursor += width + gap;
    block++;
  }
  if (loose.isNotEmpty) {
    final width = widths[block];
    final columns = math.min(loose.length, gridColumns);
    final looseX = cursor + width / 2;
    for (var index = 0; index < loose.length; index++) {
      final row = index ~/ columns;
      final column = index % columns;
      final inRow = math.min(columns, loose.length - row * columns);
      final gridWidth = columns * pitch;
      final rowLeft = looseX - gridWidth / 2 + (gridWidth - inRow * pitch) / 2;
      spots[loose[index]] = [
        rowLeft + column * pitch + pitch / 2,
        yBase + row * rowStep,
      ];
    }
  }
  return spots;
}

/// The industry hierarchical drawing, read left to right.
///
/// Ranks come from the links, so a device sits in the column of how far it is
/// from a root; devices inside a rank are ordered by a breadth-first walk so
/// a child stays beside the parent it hangs from and the cables stop crossing.
/// This is `rows` turned on its side, and it follows the topology where
/// `split` follows the role - the two disagree exactly when a lab has more
/// than one layer of the same kind of device.
Map<String, List<double>> _layeredPositions(
  List<List<String>> entries,
  Map<String, int> tier,
  Map<String, List<String>> children,
  List<String> roots,
  double bandStep,
  double rowStep,
) {
  final depth = <String, int>{};
  // Rank is computed DOWN from the roots, because a leaf cannot know how far it
  // is from the top: ranking from the leaves gives every leaf rank 0, the same
  // column as the router it hangs from. Each device takes one column more than
  // its furthest parent, so a node reached twice by two paths keeps the deeper
  // of the two.
  final queue = <String>[];
  for (final name in roots) {
    if (!depth.containsKey(name)) {
      depth[name] = 0;
      queue.add(name);
    }
  }
  while (queue.isNotEmpty) {
    final name = queue.removeAt(0);
    depth.putIfAbsent(name, () => 0);
    final next = depth[name]! + 1;
    for (final kid in children[name] ?? const <String>[]) {
      if ((depth[kid] ?? -1) < next) {
        depth[kid] = next;
        if (!queue.contains(kid)) queue.add(kid);
      }
    }
  }

  final order = <String>[];
  final seen = <String>{};
  final walk = <String>[...roots];
  while (walk.isNotEmpty) {
    final name = walk.removeAt(0);
    if (!seen.add(name) || !depth.containsKey(name)) continue;
    order.add(name);
    walk.addAll(children[name] ?? const <String>[]);
  }
  for (final e in entries) {
    if (seen.add(e[0])) order.add(e[0]);
  }

  final ranks = <int, List<String>>{};
  for (final name in order) {
    ranks.putIfAbsent(depth[name] ?? 0, () => <String>[]).add(name);
  }

  final spots = <String, List<double>>{};
  final levels = ranks.keys.toList()..sort();
  for (var index = 0; index < levels.length; index++) {
    final group = ranks[levels[index]]!;
    for (var row = 0; row < group.length; row++) {
      spots[group[row]] = [
        kXStart + index * bandStep,
        kRowTop + row * rowStep,
      ];
    }
  }
  return spots;
}

/// Park the named devices in columns at the edges they were sent to.
///
/// A multi-zone list is the form the app sends for "the servers on one side
/// and the routers on the other": one column per zone, in the order the request
/// listed them, each at its own edge. One zone with no edge is the single-side
/// form and behaves exactly as it always did.
Map<String, List<double>> _groupedPositions(
  List<List<String>> entries,
  Map<String, int> tier,
  Map<int, double> bands,
  Map<String, List<double>> spots,
  List<LayoutZone> zones,
  double pitch,
  double gap,
  double rowStep,
) {
  final claimed = <String>{};
  final parked = <_ZoneColumn>[];
  for (final zone in zones) {
    final names = <String>[
      for (final name in zone.side)
        if (spots.containsKey(name) && !claimed.contains(name)) name,
    ];
    if (names.isEmpty || names.length == spots.length) continue;
    claimed.addAll(names);
    parked.add(_ZoneColumn(names, zone.edge));
  }
  if (parked.isEmpty) return spots;

  final shift = gap + pitch;
  final left = <_ZoneColumn>[];
  final right = <_ZoneColumn>[];
  for (final zone in parked) {
    (zone.edge == 'right' ? right : left).add(zone);
  }
  final rest = <String>[
    for (final name in spots.keys)
      if (!claimed.contains(name)) name,
  ];

  // The left columns start at the canvas edge and the rest of the lab moves
  // right to clear them, so nothing is ever placed off-canvas.
  for (var index = 0; index < left.length; index++) {
    left[index].x = kXStart + index * shift;
  }
  if (left.isNotEmpty) {
    for (final name in rest) {
      final spot = spots[name]!;
      spot[0] = spot[0] + shift * left.length;
    }
  }

  var edge = kXStart;
  if (rest.isNotEmpty) {
    edge = spots[rest.first]![0];
    for (final name in rest) {
      edge = math.max(edge, spots[name]![0]);
    }
  }
  for (var index = 0; index < right.length; index++) {
    right[index].x = edge + (index + 1) * shift;
  }

  for (final zone in <_ZoneColumn>[...left, ...right]) {
    final rowInBand = <int, int>{};
    for (final name in zone.names) {
      final band = tier[name] ?? kTierHosts;
      final row = rowInBand[band] ?? 0;
      rowInBand[band] = row + 1;
      spots[name] = [zone.x, (bands[band] ?? kRowTop) + row * rowStep];
    }
  }
  return spots;
}

class _ZoneColumn {
  final List<String> names;
  final String edge;
  double x = 0;

  _ZoneColumn(this.names, this.edge);
}

/// One drawing per style, in gallery order.
Map<String, LayoutSnapshot> computeAllLayouts(
  NetworkIntent intent, {
  Iterable<String> side = const <String>[],
  String sideEdge = 'left',
  Iterable<LayoutZone> zones = const <LayoutZone>[],
}) => {
  for (final style in kLayoutStyles)
    style: computeLayoutSnapshot(
      intent,
      style: style,
      side: style == 'grouped' ? side : const <String>[],
      sideEdge: sideEdge,
      zones: style == 'grouped' ? zones : const <LayoutZone>[],
    ),
};

/// The device types each placement kind stands for, so "the servers" resolves
/// against the plan rather than against a hard-coded list of plan names.
const Map<String, List<String>> kSideKindTypes = <String, List<String>>{
  'server': <String>['server', 'servers'],
  'host': <String>[
    'pc',
    'pcs',
    'host',
    'hosts',
    'workstation',
    'desktop',
    'client',
    'laptop',
  ],
  'router': <String>['router', 'routers'],
  'switch': <String>['switch', 'switches'],
  'firewall': <String>['firewall', 'firewalls'],
  'wireless': <String>[
    'wireless',
    'accesspoint',
    'access point',
    'ap',
    'aps',
    'wlc',
  ],
  'phone': <String>['phone', 'phones'],
  'printer': <String>['printer', 'printers'],
  'cloud': <String>['cloud', 'clouds'],
};

/// The concrete device names a placement request is about.
///
/// [names] wins over [kinds] when any of them is really in the plan: "move
/// SRV1 to the side" must move SRV1, and reading it as the kind "server"
/// would move every server in the lab. [kinds] are the fallback, and an empty
/// result means the request named devices this plan does not have - the
/// caller is expected to say so rather than draw something arbitrary.
List<String> resolveSideNames(
  NetworkIntent intent, {
  Iterable<String> kinds = const <String>[],
  Iterable<String> names = const <String>[],
}) {
  final known = <String>{for (final n in intent.nodes) n.name.toUpperCase()};
  final out = <String>[];
  for (final raw in names) {
    final name = raw.trim().toUpperCase();
    if (name.isNotEmpty && known.contains(name) && !out.contains(name)) {
      out.add(name);
    }
  }
  if (out.isNotEmpty) return out;
  for (final raw in kinds) {
    final wanted = kSideKindTypes[raw.trim().toLowerCase()];
    if (wanted == null) continue;
    for (final n in intent.nodes) {
      if (wanted.contains(n.type.trim().toLowerCase()) && !out.contains(n.name)) {
        out.add(n.name);
      }
    }
  }
  return out;
}
