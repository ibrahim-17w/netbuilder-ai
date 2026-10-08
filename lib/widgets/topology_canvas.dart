import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// A node's resolved position on the canvas.
@immutable
class TopoNode {
  final String name;
  final String type;
  final Offset pos;
  final int vlan;
  final List<String> services;

  const TopoNode({
    required this.name,
    required this.type,
    required this.pos,
    required this.vlan,
    this.services = const [],
  });
}

/// Layered auto-layout for a plan: internet -> edge router -> firewall ->
/// core switch -> access switches -> end devices, servers to the side.
/// Plan-supplied positions (intent.layout[name]) win over computed ones.
Map<String, Offset> layoutPlan(NetworkIntent intent, Size canvasSize) {
  final layout = intent.layout;
  if (layout.isNotEmpty) {
    final supplied = <String, Offset>{
      for (final e in layout.entries)
        if (e.value != null) e.key: e.value!,
    };
    // every planned node must have a spot; lay out the missing ones
    final missing = intent.nodes
        .where((n) => !supplied.containsKey(n.name))
        .toList();
    if (missing.isEmpty) return supplied;
    final extra = computeAutoLayout(missing, intent, canvasSize,
        occupied: supplied.values.toList());
    return {...supplied, ...extra};
  }
  return computeAutoLayout(intent.nodes, intent, canvasSize);
}

/// Layer assignment per device type (higher = lower on screen).
int _layerOf(String type) => switch (type) {
      'cloud' => 0,
      'modem' => 0,
      'router' => 1,
      'wireless-router' => 1,
      'firewall' => 2,
      'switch' => 3,
      'wlc' => 3,
      'wireless' => 4,
      'server' => 4,
      'printer' => 4,
      'phone' => 4,
      _ => 5, // pcs, laptops, tablets, smartphones, tvs
    };

/// The painted node box. The layout has to know it, because a node is a
/// *centre* point: clamping the centre to 24px from an edge on a canvas whose
/// boxes are 88px wide pushes half of one off the canvas, and two nodes
/// clamped to the same 24px land exactly on top of each other.
const double kNodeWidth = 88;
const double kNodeHeight = 34;

/// Minimum clear space between two node boxes on the same row.
const double kNodeGap = 24;

/// The narrowest row share a layer is given. A server row is pushed to the
/// right and only gets this fraction of the width, so the minimum canvas has
/// to be sized against it or a server row cannot fit its own boxes.
const double _serverRowShare = 0.55;

/// The smallest canvas that can hold [nodes] with no two boxes touching.
///
/// This is a real floor, not a hint: the caller may hand a phone-sized canvas
/// to a plan with two dozen devices, and laying that out in the space given
/// produces a pile of overlapping rectangles that reads as one smeared blob.
Size topologyMinSize(List<NetNode> nodes) {
  final perLayer = <int, int>{};
  for (final n in nodes) {
    perLayer.update(_layerOf(n.type), (c) => c + 1, ifAbsent: () => 1);
  }
  if (perLayer.isEmpty) return Size.zero;
  final widest = perLayer.values.fold<int>(1, (a, b) => a > b ? a : b);
  final rows = perLayer.length;
  final wide = widest * kNodeWidth + (widest - 1) * kNodeGap;
  return Size(
    wide / _serverRowShare,
    rows * (kNodeHeight + kNodeGap),
  );
}

Map<String, Offset> computeAutoLayout(
  List<NetNode> nodes,
  NetworkIntent intent,
  Size size, {
  List<Offset> occupied = const [],
}) {
  if (nodes.isEmpty) return {};
  // group by layer, keep plan order within a layer
  final layers = <int, List<NetNode>>{};
  for (final n in nodes) {
    layers.putIfAbsent(_layerOf(n.type), () => []).add(n);
  }
  final sortedKeys = layers.keys.toList()..sort();

  // Never lay out into less room than the boxes need.
  final min = topologyMinSize(nodes);
  final w = math.max(size.width, min.width);
  final h = math.max(size.height, min.height);
  final halfW = kNodeWidth / 2;
  final halfH = kNodeHeight / 2;

  // horizontal centers per layer, servers keep to the right side
  final out = <String, Offset>{};
  final rowH = h / math.max(sortedKeys.length, 1);
  for (var li = 0; li < sortedKeys.length; li++) {
    final layerNodes = layers[sortedKeys[li]]!;
    final y = rowH * (li + 0.5);
    final isServerRow = sortedKeys[li] >= 4;
    // The width this row's boxes actually need. Widening to it is what stops
    // two boxes in one layer from overlapping when the canvas is narrow.
    final need = layerNodes.length * kNodeWidth +
        (layerNodes.length - 1) * kNodeGap;
    final rowW = math.max(isServerRow ? w * _serverRowShare : w * 0.9, need);
    final left =
        isServerRow ? math.max(0.0, w - rowW) : (w - rowW) / 2;
    for (var i = 0; i < layerNodes.length; i++) {
      final x = left + rowW * ((i + 0.5) / math.max(layerNodes.length, 1));
      out[layerNodes[i].name] = Offset(
        x.clamp(halfW, math.max(halfW, w - halfW)),
        y.clamp(halfH, math.max(halfH, h - halfH)),
      );
    }
  }
  // nudge away from occupied spots (drag layout may already sit there)
  for (final entry in out.entries.toList()) {
    var pos = entry.value;
    for (final other in occupied) {
      if ((other - pos).distance < 8) {
        pos += const Offset(12, 12);
      }
    }
    out[entry.key] = pos;
  }
  return out;
}

/// Color per VLAN (stable within a session; distinct hues per id).
///
/// The colour is a *secondary* cue: every node also carries its VLAN id as
/// text, so a plan still reads for a user who cannot tell blue from green, or
/// on a screen that renders them alike.
Color vlanColor(int vlan) {
  if (vlan <= 0) return const Color(0xFF78909C);
  final hue = (vlan * 47) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.45).toColor();
}

/// The workspace palette. Packet Tracer's canvas is a pale green-cream sheet
/// with a dot grid, dark-ink devices and dark cables - and it looks the same
/// whatever theme the app around it uses, because it is a picture of a
/// desktop tool's workspace, not app chrome. Every canvas colour is therefore
/// fixed, never derived from [ColorScheme].
const Color kWorkspaceBackground = Color(0xFFF5F2E9);
const Color kWorkspaceDot = Color(0xFFDCD6C2);
const Color kWorkspaceInk = Color(0xFF37474F);
const Color kWorkspaceGlyphFill = Color(0xFFFDFCF8);
const Color kWorkspaceSerial = Color(0xFFC62828);
const Color kWorkspaceLabel = Color(0xFF263238);

/// The Packet Tracer-style glyph a device type renders as. One kind per
/// classic shape: the Cisco router circle, the switch rectangle, the CRT
/// monitor, the server tower, the brick wall, the cloud, the antennas.
enum PtGlyphKind {
  router,
  switchGlyph,
  pc,
  server,
  firewall,
  cloud,
  wirelessAp,
  wirelessRouter,
  box,
}

/// Maps a plan's device type onto its workspace glyph. Unknown types fall
/// back to a plain labelled box, the same shape they always drew.
PtGlyphKind ptGlyphKind(String type) => switch (type) {
      'router' => PtGlyphKind.router,
      'switch' => PtGlyphKind.switchGlyph,
      'pc' || 'laptop' => PtGlyphKind.pc,
      'server' => PtGlyphKind.server,
      'firewall' => PtGlyphKind.firewall,
      'cloud' => PtGlyphKind.cloud,
      'wireless' => PtGlyphKind.wirelessAp,
      'wireless-router' => PtGlyphKind.wirelessRouter,
      _ => PtGlyphKind.box,
    };

/// Paints one Packet Tracer-style device glyph inside a box.
///
/// The glyphs are drawn parametrically from the box they are given, so the
/// same painter serves the full-size canvas, the zoomed view and the
/// scaled-down thumbnail.
class PtGlyphPainter extends CustomPainter {
  final PtGlyphKind kind;
  final Color stroke;
  final Color fill;
  final double strokeWidth;

  const PtGlyphPainter({
    required this.kind,
    this.stroke = kWorkspaceInk,
    this.fill = kWorkspaceGlyphFill,
    this.strokeWidth = 1.4,
  });

  static void paintGlyph(
    Canvas canvas,
    PtGlyphKind kind,
    Rect box, {
    required Color stroke,
    required Color fill,
    double strokeWidth = 1.4,
  }) {
    if (box.width <= 2 || box.height <= 2) return;
    final ink = _GlyphInk(stroke, fill, strokeWidth);
    switch (kind) {
      case PtGlyphKind.router:
        _router(canvas, box, ink);
      case PtGlyphKind.switchGlyph:
        _switch(canvas, box, ink);
      case PtGlyphKind.pc:
        _pc(canvas, box, ink);
      case PtGlyphKind.server:
        _server(canvas, box, ink);
      case PtGlyphKind.firewall:
        _firewall(canvas, box, ink);
      case PtGlyphKind.cloud:
        _cloud(canvas, box, ink);
      case PtGlyphKind.wirelessAp:
        _wirelessAp(canvas, box, ink);
      case PtGlyphKind.wirelessRouter:
        _wirelessRouter(canvas, box, ink);
      case PtGlyphKind.box:
        _box(canvas, box, ink);
    }
  }

  @override
  void paint(Canvas canvas, Size size) => paintGlyph(
        canvas,
        kind,
        Offset.zero & size,
        stroke: stroke,
        fill: fill,
        strokeWidth: strokeWidth,
      );

  @override
  bool shouldRepaint(covariant PtGlyphPainter old) =>
      old.kind != kind ||
      old.stroke != stroke ||
      old.fill != fill ||
      old.strokeWidth != strokeWidth;

  // -- the glyphs ----------------------------------------------------------

  /// Router: the iconic Cisco symbol - a circle with four arrowheads
  /// pointing N/E/S/W.
  static void _router(Canvas canvas, Rect box, _GlyphInk ink) {
    final c = box.center;
    final r = math.min(box.width, box.height) / 2 - ink.width;
    canvas.drawCircle(c, r, ink.fill);
    canvas.drawCircle(c, r, ink.stroke);
    for (final dir in const [
      Offset(0, -1),
      Offset(1, 0),
      Offset(0, 1),
      Offset(-1, 0),
    ]) {
      _arrow(canvas, c + dir * (r * 0.15), c + dir * (r * 0.58), ink.stroke,
          ink.mark, head: r * 0.36);
    }
  }

  /// Switch: a rounded rectangle, smaller and wider than the router, with
  /// two opposing horizontal arrows.
  static void _switch(Canvas canvas, Rect box, _GlyphInk ink) {
    final rrect = RRect.fromRectAndRadius(
        box, Radius.circular(box.height * 0.28));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    final x0 = box.left + box.width * 0.18;
    final x1 = box.right - box.width * 0.18;
    final head = box.height * 0.24;
    _arrow(
      canvas,
      Offset(x0, box.center.dy - box.height * 0.16),
      Offset(x1, box.center.dy - box.height * 0.16),
      ink.stroke,
      ink.mark,
      head: head,
    );
    _arrow(
      canvas,
      Offset(x1, box.center.dy + box.height * 0.16),
      Offset(x0, box.center.dy + box.height * 0.16),
      ink.stroke,
      ink.mark,
      head: head,
    );
  }

  /// PC and laptop: a small CRT monitor - screen, stand, base.
  static void _pc(Canvas canvas, Rect box, _GlyphInk ink) {
    final screen = Rect.fromLTWH(
      box.left + box.width * 0.10,
      box.top,
      box.width * 0.80,
      box.height * 0.60,
    );
    final rrect = RRect.fromRectAndRadius(
        screen, Radius.circular(screen.height * 0.12));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    final cx = box.center.dx;
    final neck = Rect.fromLTWH(
      cx - box.width * 0.07,
      screen.bottom,
      box.width * 0.14,
      box.height * 0.26,
    );
    canvas.drawRect(neck, ink.fill);
    canvas.drawRect(neck, ink.stroke);
    final base = Rect.fromLTWH(
      cx - box.width * 0.24,
      box.bottom - box.height * 0.14,
      box.width * 0.48,
      box.height * 0.14,
    );
    final baseRrect = RRect.fromRectAndRadius(
        base, Radius.circular(base.height * 0.4));
    canvas.drawRRect(baseRrect, ink.fill);
    canvas.drawRRect(baseRrect, ink.stroke);
  }

  /// Server: a tower of stacked units with vent slots and an LED.
  static void _server(Canvas canvas, Rect box, _GlyphInk ink) {
    final tower = Rect.fromLTWH(
      box.center.dx - box.width * 0.28,
      box.top,
      box.width * 0.56,
      box.height,
    );
    final rrect = RRect.fromRectAndRadius(tower, const Radius.circular(2));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    final unit = tower.height / 3;
    for (var i = 1; i < 3; i++) {
      final y = tower.top + unit * i;
      canvas.drawLine(Offset(tower.left, y), Offset(tower.right, y), ink.stroke);
    }
    for (var i = 0; i < 3; i++) {
      final y = tower.top + unit * i + unit * 0.55;
      canvas.drawLine(
        Offset(tower.left + tower.width * 0.18, y),
        Offset(tower.left + tower.width * 0.66, y),
        ink.stroke,
      );
    }
    canvas.drawCircle(
      Offset(tower.right - tower.width * 0.16, tower.top + unit * 0.5),
      math.min(1.4, unit * 0.16),
      ink.mark,
    );
  }

  /// Firewall: a brick wall - courses with offset joints.
  static void _firewall(Canvas canvas, Rect box, _GlyphInk ink) {
    canvas.drawRect(box, ink.fill);
    canvas.drawRect(box, ink.stroke);
    final course = box.height / 3;
    for (var i = 1; i < 3; i++) {
      final y = box.top + course * i;
      canvas.drawLine(Offset(box.left, y), Offset(box.right, y), ink.stroke);
    }
    for (var i = 0; i < 3; i++) {
      final y0 = box.top + course * i;
      for (final f in i.isOdd ? const [0.25, 0.75] : const [0.5]) {
        final x = box.left + box.width * f;
        canvas.drawLine(Offset(x, y0), Offset(x, y0 + course), ink.stroke);
      }
    }
  }

  /// Cloud: a puffy three-lobed outline.
  static void _cloud(Canvas canvas, Rect box, _GlyphInk ink) {
    final l = box.left;
    final t = box.top;
    final w = box.width;
    final h = box.height;
    final path = Path()
      ..moveTo(l + w * 0.08, t + h * 0.88)
      ..cubicTo(l - w * 0.02, t + h * 0.52, l + w * 0.16, t + h * 0.26,
          l + w * 0.34, t + h * 0.38)
      ..cubicTo(l + w * 0.38, t + h * 0.06, l + w * 0.72, t + h * 0.06,
          l + w * 0.76, t + h * 0.34)
      ..cubicTo(l + w * 0.94, t + h * 0.30, l + w * 1.00, t + h * 0.58,
          l + w * 0.90, t + h * 0.88)
      ..close();
    canvas.drawPath(path, ink.fill);
    canvas.drawPath(path, ink.stroke);
  }

  /// Wireless AP: a small unit with two arcs radiating upward.
  static void _wirelessAp(Canvas canvas, Rect box, _GlyphInk ink) {
    final unit = Rect.fromLTWH(
      box.center.dx - box.width * 0.26,
      box.bottom - box.height * 0.34,
      box.width * 0.52,
      box.height * 0.34,
    );
    final rrect = RRect.fromRectAndRadius(
        unit, Radius.circular(unit.height * 0.3));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    final cx = box.center.dx;
    canvas.drawCircle(
      Offset(cx, unit.center.dy),
      math.min(1.6, unit.height * 0.16),
      ink.mark,
    );
    // Arcs open upward: angles run clockwise from +x, and +y points DOWN.
    for (final f in const [0.30, 0.56]) {
      final arcRect = Rect.fromCircle(
          center: Offset(cx, unit.top),
          radius: math.min(box.width, box.height) * f);
      canvas.drawArc(arcRect, math.pi, math.pi, false, ink.stroke);
    }
  }

  /// Wireless router: a wider unit with two antennas and a signal arc.
  static void _wirelessRouter(Canvas canvas, Rect box, _GlyphInk ink) {
    final body = Rect.fromLTWH(
      box.left + box.width * 0.14,
      box.top + box.height * 0.42,
      box.width * 0.72,
      box.height * 0.46,
    );
    final rrect = RRect.fromRectAndRadius(
        body, Radius.circular(body.height * 0.28));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    for (final f in const [0.28, 0.72]) {
      final x = box.left + box.width * f;
      canvas.drawLine(
          Offset(x, body.top), Offset(x, box.top + box.height * 0.10), ink.stroke);
    }
    final arcRect = Rect.fromCircle(
        center: Offset(box.center.dx, body.top), radius: body.width * 0.26);
    canvas.drawArc(arcRect, math.pi * 1.25, math.pi * 0.5, false, ink.stroke);
  }

  /// Fallback for unknown types: a plain rounded box (the name under it does
  /// the labelling).
  static void _box(Canvas canvas, Rect box, _GlyphInk ink) {
    final rrect = RRect.fromRectAndRadius(
        box, Radius.circular(box.height * 0.22));
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
  }

  /// A shaft with a filled triangular arrowhead, the recurring mark inside
  /// the router and switch glyphs.
  static void _arrow(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint linePaint,
    Paint headPaint, {
    required double head,
  }) {
    final d = to - from;
    final length = d.distance;
    if (length < 0.5 || head < 0.5) return;
    canvas.drawLine(from, to, linePaint);
    final dir = d / length;
    final side = Offset(-dir.dy, dir.dx) * (head * 0.55);
    final base = to - dir * head;
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(base.dx + side.dx, base.dy + side.dy)
        ..lineTo(base.dx - side.dx, base.dy - side.dy)
        ..close(),
      headPaint,
    );
  }
}

/// The three paints a glyph needs: shape outlines, shape fills, and small
/// solid marks (arrowheads, LEDs) drawn in the outline colour.
class _GlyphInk {
  final Paint stroke;
  final Paint fill;
  final Paint mark;
  final double width;

  _GlyphInk(Color strokeColor, Color fillColor, this.width)
      : stroke = Paint()
          ..color = strokeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
        fill = Paint()..color = fillColor,
        mark = Paint()..color = strokeColor;
}

/// Paints [value] centred at [centre]: a white stroke pass underneath and the
/// coloured fill on top. The halo is what keeps a label readable where a link
/// or the workspace dot grid runs beneath it.
void drawHaloText(
  Canvas canvas,
  String value,
  Offset centre,
  double fontSize,
  Color color, {
  required double maxWidth,
  FontWeight fontWeight = FontWeight.w400,
  double haloWidth = 2.0,
}) {
  final base = TextStyle(fontSize: fontSize, fontWeight: fontWeight);
  final fill = TextPainter(
    text: TextSpan(text: value, style: base.copyWith(color: color)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '...',
  )..layout(maxWidth: maxWidth);
  final halo = TextPainter(
    text: TextSpan(
      text: value,
      style: base.copyWith(
        foreground: Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = haloWidth,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '...',
  )..layout(maxWidth: maxWidth);
  final at = centre - Offset(fill.width / 2, fill.height / 2);
  halo.paint(canvas, at);
  fill.paint(canvas, at);
}

class _PaintedEdge {
  final String a;
  final String b;
  final bool serial;

  /// Whether the clocking (DCE) end of a serial run is [a] - the red zigzag
  /// is drawn at that end, the way Packet Tracer marks the cable.
  final bool dceIsA;
  const _PaintedEdge(this.a, this.b, this.serial, {this.dceIsA = true});
}

/// Compute a deterministic VLAN id per node from its subnet (1..n by first
/// appearance in the addressing list; 0 = unassigned).
Map<String, int> vlanAssignments(NetworkIntent intent) {
  final subnets = <String>[];
  for (final a in intent.addressing) {
    if (!a.ipCidr.contains('/')) continue;
    final p = a.ipCidr.split('.').take(3).join('.');
    if (!subnets.contains(p)) subnets.add(p);
  }
  final out = <String, int>{};
  for (final n in intent.nodes) {
    final addr = intent.addressing
        .where((a) => a.node == n.name)
        .map((a) => a.ipCidr)
        .firstWhere((_) => true, orElse: () => '');
    if (addr.isEmpty) {
      out[n.name] = 0;
      continue;
    }
    final p = addr.split('.').take(3).join('.');
    final idx = subnets.indexOf(p);
    out[n.name] = idx < 0 ? 0 : idx + 1;
  }
  return out;
}

/// Interactive plan canvas: drag nodes, tap for a detail sheet.
class TopologyCanvas extends StatefulWidget {
  final NetworkIntent intent;
  final Map<String, Offset?>? layout;
  final ValueChanged<Map<String, Offset>>? onLayoutChanged;
  final Map<String, List<String>>? nodeIssues;

  const TopologyCanvas({
    super.key,
    required this.intent,
    this.layout,
    this.onLayoutChanged,
    this.nodeIssues,
  });

  @override
  State<TopologyCanvas> createState() => _TopologyCanvasState();
}

class _TopologyCanvasState extends State<TopologyCanvas> {
  Map<String, Offset> _positions = {};
  String? _dragging;
  Offset _dragStart = Offset.zero;
  Offset _dragDelta = Offset.zero;
  Size _lastSize = Size.zero;

  @override
  void didUpdateWidget(covariant TopologyCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intent != widget.intent) {
      _positions = {};
      _lastSize = Size.zero;
    }
  }

  Map<String, Offset> _resolve(Size size) {
    if (_positions.isNotEmpty && _lastSize == size) return _positions;
    _lastSize = size;
    final intent = widget.intent;
    final supplied = widget.layout ?? intent.layout;
    _positions = layoutPlan(
      supplied.isEmpty
          ? intent
          : _intentWithLayout(intent, {
              for (final e in supplied.entries) e.key: e.value,
            }),
      size,
    );
    return _positions;
  }

  NetworkIntent _intentWithLayout(NetworkIntent base, Map<String, Offset?> l) {
    // layoutPlan reads intent.layout; build a lightweight clone
    return NetworkIntent(
      projectName: base.projectName,
      nodes: base.nodes,
      links: base.links,
      addressing: base.addressing,
      vlans: base.vlans,
      routing: base.routing,
      notes: base.notes,
      assumptions: base.assumptions,
      questions: base.questions,
      confidence: base.confidence,
      planningSource: base.planningSource,
      security: base.security,
      layout: l,
    );
  }

  void _emitLayout() {
    if (widget.onLayoutChanged == null) return;
    widget.onLayoutChanged!(Map.of(_positions));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: LayoutBuilder(builder: _canvas)),
        TopologyLegend(
          vlans: vlanAssignments(widget.intent),
          issues: widget.nodeIssues ?? const {},
          links: widget.intent.links,
        ),
      ],
    );
  }

  Widget _canvas(BuildContext context, BoxConstraints constraints) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final positions = _resolve(size);
    final intent = widget.intent;
    final byName = {for (final n in intent.nodes) n.name: n};
    final vlans = vlanAssignments(intent);
    final issues = widget.nodeIssues ?? const {};
    final edges = [
      for (final l in intent.links)
        if (positions.containsKey(l.a) && positions.containsKey(l.b))
          _PaintedEdge(
            l.a,
            l.b,
            l.isSerial,
            // The clocking end carries the red zigzag, the way Packet
            // Tracer marks a DCE cable; null defaults to end A.
            dceIsA: l.dce != 'b',
          ),
    ];

    return Semantics(
      // A CustomPaint contributes nothing to the semantics tree on its own, so
      // without this the whole diagram is one unlabelled box: a screen reader
      // announces "graphic" and stops. The summary is the one node that says
      // what the plan is before the user walks into it.
      label: _summaryLabel(positions, vlans, issues),
      container: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          final hit = _hitTest(positions, d.localPosition, size);
          if (hit != null) {
            setState(() {
              _dragging = hit;
              _dragStart = positions[hit]!;
              _dragDelta = Offset.zero;
            });
          }
        },
        onPanUpdate: (d) {
          if (_dragging == null) return;
          setState(() {
            _dragDelta += d.delta;
            _positions[_dragging!] = Offset(
              (_dragStart + _dragDelta).dx.clamp(20.0, size.width - 20.0),
              (_dragStart + _dragDelta).dy.clamp(20.0, size.height - 20.0),
            );
          });
        },
        onPanEnd: (_) {
          if (_dragging != null) _emitLayout();
          setState(() => _dragging = null);
        },
        onTapUp: (d) {
          final hit = _hitTest(positions, d.localPosition, size);
          if (hit != null) _showInspector(context, hit, byName[hit]);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                size: size,
                painter: _TopoPainter(
                  intent: intent,
                  positions: positions,
                  edges: edges,
                  issues: issues,
                  dragging: _dragging,
                  scheme: Theme.of(context).colorScheme,
                  vlans: vlans,
                ),
              ),
            ),
            // One real, focusable, tappable target per device, laid over the
            // painted box. The painting stays in the painter; the interaction
            // and the a11y live in widgets, where the framework can reach them.
            for (final entry in positions.entries)
              Positioned(
                left: entry.value.dx - kNodeWidth / 2,
                top: entry.value.dy - kNodeHeight / 2,
                width: kNodeWidth,
                height: kNodeHeight,
                child: _NodeTarget(
                  label: _nodeLabel(
                    entry.key,
                    byName[entry.key],
                    vlans[entry.key] ?? 0,
                    intent.links
                        .where((l) => l.a == entry.key || l.b == entry.key)
                        .map((l) => l.a == entry.key ? l.b : l.a),
                    issues[entry.key] ?? const [],
                  ),
                  onOpen: () =>
                      _showInspector(context, entry.key, byName[entry.key]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The one node that describes the plan, in words.
  String _summaryLabel(
    Map<String, Offset> positions,
    Map<String, int> vlans,
    Map<String, List<String>> issues,
  ) {
    final intent = widget.intent;
    final bad = positions.keys.where((n) => (issues[n] ?? const []).isNotEmpty);
    final serial = intent.links.where((l) => l.isSerial).length;
    return 'Topology of ${intent.projectName}: '
        '${positions.length} device(s), '
        '${intent.links.length} cable(s)'
        '${serial == 0 ? '' : ', $serial serial'}${serial == 1 ? '' : 's'}, '
        '${vlans.values.toSet().where((v) => v > 0).length} VLAN(s), '
        '${bad.length} device(s) with issues. '
        'Each device is a separate stop; activate one for its details.';
  }

  /// One device, said the way a person would say it: what it is, where it
  /// sits on the VLAN, what it runs, what it is cabled to, what is wrong.
  String _nodeLabel(
    String name,
    NetNode? node,
    int vlan,
    Iterable<String> peers,
    List<String> issues,
  ) {
    final nodePeers = peers.where((p) => p.isNotEmpty).toSet().toList()..sort();
    final peerText = nodePeers.isEmpty
        ? 'no cables'
        : 'cabled to ${nodePeers.join(", ")}';
    final serviceText = node == null || node.services.isEmpty
        ? null
        : 'runs ${node.services.join(", ")}';
    final issueText = issues.isEmpty
        ? 'no issues'
        : '${issues.length} issue(s): ${issues.join("; ")}';
    return [
      '${node?.type ?? 'device'} $name',
      vlan > 0 ? 'VLAN $vlan' : 'no VLAN assigned',
      if (node != null && node.model != null && node.model!.isNotEmpty)
        'model ${node.model}',
      ?serviceText,
      peerText,
      issueText,
    ].join('. ');
  }

  String? _hitTest(Map<String, Offset> positions, Offset local, Size size) {
    double best = 28;
    String? hit;
    for (final e in positions.entries) {
      final dist = (e.value - local).distance;
      if (dist < best) {
        best = dist;
        hit = e.key;
      }
    }
    return hit;
  }

  void _showInspector(BuildContext context, String name, NetNode? node) {
    if (node == null) return;
    final intent = widget.intent;
    final addrs =
        intent.addressing.where((a) => a.node == name).toList();
    final issues = widget.nodeIssues?[name] ?? const [];
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: ConstrainedBox(
          // Bounded, because a busy device - eight services, four interfaces
          // and six findings - is taller than half a phone screen.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s16,
              0,
              AppTheme.s16,
              AppTheme.s24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(_iconFor(node.type), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(node.name,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ]),
                const SizedBox(height: 4),
                Text('${node.type}${node.model == null ? '' : ' - ${node.model}'}',
                    style: Theme.of(context).textTheme.bodySmall),
                if (node.services.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Services: ${node.services.join(', ')}'),
                ],
                if (addrs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final a in addrs)
                    Text('${a.iface}:  ${a.ipCidr}'),
                ],
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final i in issues)
                    Row(children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 16, color: AppPalette.warning(scheme)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(i, style: const TextStyle(fontSize: 12))),
                    ]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String type) => switch (type) {
        'router' => Icons.router,
        'switch' => Icons.settings_ethernet,
        'firewall' => Icons.security,
        'server' => Icons.dns_outlined,
        'cloud' => Icons.cloud_outlined,
        'pc' => Icons.computer,
        'laptop' => Icons.laptop_mac,
        'printer' => Icons.print_outlined,
        'phone' => Icons.phone_iphone,
        'wireless' => Icons.wifi,
        _ => Icons.circle_outlined,
      };
}

/// One device's hit target and semantics, sitting invisibly over its painted
/// box.
///
/// [Semantics] with a tap action is what a screen reader activates; the
/// [FocusableActionDetector] under it is what a keyboard traverses, so the
/// diagram is never mouse-only. Both open the same inspector.
class _NodeTarget extends StatelessWidget {
  final String label;
  final VoidCallback onOpen;

  const _NodeTarget({required this.label, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: label,
      button: true,
      onTap: onOpen,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onOpen();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The key to the canvas, in the open.
///
/// Without it the diagram says "which VLAN" and "serial or not" in colour and
/// stroke alone, and a plan unreadable to a colourblind user or on a
/// washed-out screen is a plan unreadable.
class TopologyLegend extends StatelessWidget {
  final Map<String, int> vlans;
  final Map<String, List<String>> issues;
  final List<NetLink> links;

  const TopologyLegend({
    super.key,
    required this.vlans,
    this.issues = const {},
    this.links = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = vlans.values.toSet().where((v) => v > 0).toList()..sort();
    final withIssues =
        issues.keys.where((name) => (issues[name] ?? const []).isNotEmpty);
    final hasSerial = links.any((l) => l.isSerial);
    final style = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s12,
        AppTheme.s8,
        AppTheme.s12,
        AppTheme.s8,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Wrap(
        spacing: AppTheme.s12,
        runSpacing: AppTheme.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Key', style: style),
          for (final v in used)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: vlanColor(v).withValues(alpha: 0.13),
                    border: Border.all(color: vlanColor(v), width: 1.1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: AppTheme.s4),
                Text('V$v', style: style),
              ],
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 8,
                child: CustomPaint(
                  painter: _KeyPainter(dashed: false, color: vlanColor(0)),
                ),
              ),
              const SizedBox(width: AppTheme.s4),
              Text('cable', style: style),
            ],
          ),
          if (hasSerial)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 8,
                  child: CustomPaint(
                    painter: _KeyPainter(
                      dashed: true,
                      color: AppPalette.warning(theme.colorScheme),
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s4),
                Text('serial', style: style),
              ],
            ),
          if (withIssues.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: AppPalette.warning(theme.colorScheme),
                ),
                const SizedBox(width: AppTheme.s4),
                Text('! ${withIssues.length} with issues', style: style),
              ],
            ),
        ],
      ),
    );
  }
}

/// The legend's line samples: solid for a cable, dashed for a serial run, so
/// the two read differently without relying on their colour.
class _KeyPainter extends CustomPainter {
  final bool dashed;
  final Color color;

  const _KeyPainter({required this.dashed, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 2
      ..color = color;
    if (!dashed) {
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
      return;
    }
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + 3, size.width), size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _KeyPainter old) =>
      old.dashed != dashed || old.color != color;
}

class _TopoPainter extends CustomPainter {
  final NetworkIntent intent;
  final Map<String, Offset> positions;
  final List<_PaintedEdge> edges;
  final Map<String, List<String>> issues;
  final String? dragging;
  final ColorScheme scheme;
  final Map<String, int> vlans;

  _TopoPainter({
    required this.intent,
    required this.positions,
    required this.edges,
    required this.issues,
    required this.dragging,
    required this.scheme,
    required this.vlans,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final serial = AppPalette.warning(scheme);
    // edges first
    for (final e in edges) {
      final a = positions[e.a]!;
      final b = positions[e.b]!;
      final paint = Paint()
        ..strokeWidth = e.serial ? 1.5 : 2
        ..color = e.serial ? serial : scheme.outlineVariant
        ..style = PaintingStyle.stroke;
      // A serial run is DASHED, not just orange: the dash is the cue that
      // survives a greyscale print and a colourblind reader.
      if (e.serial) {
        _dashedLine(canvas, a, b, paint);
      } else {
        canvas.drawLine(a, b, paint);
      }
    }
    // nodes
    for (final entry in positions.entries) {
      final node = entry.key;
      final pos = entry.value;
      final vlan = vlans[node] ?? 0;
      final color = vlanColor(vlan);
      final hasIssues = issues[node]?.isNotEmpty ?? false;

      final box = Rect.fromCenter(
          center: pos, width: kNodeWidth, height: kNodeHeight);
      final rrect = RRect.fromRectAndRadius(
          box, const Radius.circular(8));
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = dragging == node
              ? color.withValues(alpha: 0.25)
              : color.withValues(alpha: 0.13),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = dragging == node ? 2.2 : 1.1
          ..color = color,
      );
      // The VLAN id is written on the box, so "which VLAN" is never carried by
      // the fill colour alone.
      final tag = vlan > 0 ? 'V$vlan' : 'V-';
      _text(
        canvas,
        tag,
        Offset(box.left + 4, box.top + 2),
        9,
        scheme.onSurfaceVariant,
        maxWidth: box.width - 8,
      );
      final tp = TextPainter(
        text: TextSpan(
          // The trailing "!" is the issue marker written out, not just a
          // coloured dot in the corner.
          text: hasIssues ? '$node !' : node,
          style: TextStyle(
            fontSize: 11,
            color: hasIssues ? serial : scheme.onSurface,
            fontWeight: hasIssues ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: box.width - 8);
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));

      if (hasIssues) {
        canvas.drawCircle(
          box.topRight + const Offset(2, -2),
          5,
          Paint()..color = serial,
        );
      }
    }
  }

  static void _text(
    Canvas canvas,
    String value,
    Offset at,
    double fontSize,
    Color color, {
    required double maxWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: fontSize, color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, at);
  }

  static void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final delta = b - a;
    final length = delta.distance;
    if (length == 0) return;
    final step = delta / length;
    for (var d = 0.0; d < length; d += 6) {
      canvas.drawLine(a + step * d, a + step * math.min(d + 3, length), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TopoPainter old) =>
      old.positions != positions ||
      old.dragging != dragging ||
      old.issues != issues ||
      old.intent != intent ||
      old.scheme != scheme ||
      old.vlans != vlans;
}
