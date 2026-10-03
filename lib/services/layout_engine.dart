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
  'radial',
  'circle',
  'grid',
  'split',
];

/// The drawings that place every device from the plan's own shape - its
/// links, or each device's role - and never nest anything under an uplink.
///
/// These are the ones that read differently at a glance. `tree`, `wide` and
/// `compact` are the same tree at three sizes, which is why offering them side
/// by side looked like three near-identical pictures.
const List<String> kFlatLayoutStyles = <String>[
  'radial',
  'circle',
  'grid',
  'split',
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
  'radial': LayoutShape(1.0, 4),
  'circle': LayoutShape(1.0, 4),
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
  'radial' => 'Radial rings',
  'circle' => 'One circle',
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
  'radial' => 'Core in the middle, endpoints on the outside',
  'circle' => 'Every device on one ring - a quick overview',
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
    spots = _flatPositions(
      style,
      entries,
      tier,
      pitch,
      gap,
      rowStep,
    );
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
