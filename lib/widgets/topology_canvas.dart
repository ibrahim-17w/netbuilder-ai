import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;

import '../models/network_intent.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/packet_tracer/catalog.dart';
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
  final drawing = PacketTracerAdapter.intentLayoutFromNotes(intent);
  if (drawing.isNotEmpty || intent.layout.isNotEmpty) {
    final resolved = PacketTracerAdapter.resolveLayoutForEngine(
      intent,
      drawing,
    );
    final spots = resolved['positions'] as Map? ?? const {};
    return {
      for (final entry in spots.entries)
        '${entry.key}': Offset(
          (entry.value[0] as num).toDouble(),
          (entry.value[1] as num).toDouble(),
        ),
    };
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
  return Size(wide / _serverRowShare, rows * (kNodeHeight + kNodeGap));
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
    final need =
        layerNodes.length * kNodeWidth + (layerNodes.length - 1) * kNodeGap;
    final rowW = math.max(isServerRow ? w * _serverRowShare : w * 0.9, need);
    final left = isServerRow ? math.max(0.0, w - rowW) : (w - rowW) / 2;
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

Color ptCableColor(String? cable) => switch (PacketTracerCatalog.instance.cable(cable)?.id) {
  'console' => const Color(0xFF168BAD),
  'fiber' || 'fiber-single' => const Color(0xFFD68016),
  'fiber-multi' => const Color(0xFFAE6E16),
  'serial' || 'serial-dce' || 'serial-dte' => kWorkspaceSerial,
  'phone' => const Color(0xFF4B7D3A),
  'coaxial' => const Color(0xFF395CB2),
  'octal' => const Color(0xFF9463A7),
  'ioe' => const Color(0xFF90653F),
  _ => kWorkspaceInk,
};

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
PtGlyphKind ptGlyphKind(String type) => switch (type.trim().toLowerCase()) {
  'router' => PtGlyphKind.router,
  'switch' ||
  'multilayer switch' ||
  'hub' ||
  'bridge' => PtGlyphKind.switchGlyph,
  'pc' || 'laptop' => PtGlyphKind.pc,
  'server' => PtGlyphKind.server,
  'firewall' => PtGlyphKind.firewall,
  'cloud' => PtGlyphKind.cloud,
  'wireless' ||
  'accesspoint' ||
  'wireless access point' ||
  'wlc' => PtGlyphKind.wirelessAp,
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
    final top = Rect.fromLTWH(box.left, box.top, box.width, box.height * 0.70);
    final body = Path()
      ..moveTo(box.left, top.center.dy)
      ..lineTo(box.left, box.bottom - top.height / 2)
      ..arcTo(
        Rect.fromLTWH(box.left, box.bottom - top.height, box.width, top.height),
        math.pi,
        -math.pi,
        false,
      )
      ..lineTo(box.right, top.center.dy)
      ..close();
    canvas.drawPath(body, Paint()..color = const Color(0xFF538AA9));
    canvas.drawPath(body, ink.stroke);
    canvas.drawOval(top, ink.fill);
    canvas.drawOval(top, ink.stroke);
    final centre = top.center;
    final white = Paint()..color = const Color(0xFFF8FCFF);
    final line = Paint()
      ..color = white.color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (final direction in const [
      Offset(-1, -0.5),
      Offset(1, -0.5),
      Offset(-1, 0.5),
      Offset(1, 0.5),
    ]) {
      _arrow(
        canvas,
        centre + direction * 2,
        centre + direction * 14,
        line,
        white,
        head: 4,
      );
    }
  }

  /// A shallow switch chassis with a front row of Ethernet ports.
  static void _switch(Canvas canvas, Rect box, _GlyphInk ink) {
    final top = Path()
      ..moveTo(box.left + 5, box.top + 4)
      ..lineTo(box.right, box.top + 4)
      ..lineTo(box.right - 5, box.bottom - 10)
      ..lineTo(box.left, box.bottom - 10)
      ..close();
    canvas.drawPath(top, ink.fill);
    canvas.drawPath(top, ink.stroke);
    final front = Rect.fromLTRB(
      box.left,
      box.bottom - 10,
      box.right - 5,
      box.bottom - 2,
    );
    canvas.drawRect(front, Paint()..color = const Color(0xFF538AA9));
    canvas.drawRect(front, ink.stroke);
    for (var i = 0; i < 8; i++) {
      canvas.drawRect(
        Rect.fromLTWH(front.left + 4 + i * 4.3, front.top + 2.5, 2.8, 3),
        ink.mark,
      );
    }
    final white = Paint()..color = Colors.white;
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.4;
    _arrow(
      canvas,
      box.center + const Offset(-12, -5),
      box.center + const Offset(10, -5),
      line,
      white,
      head: 3,
    );
    _arrow(
      canvas,
      box.center + const Offset(10, 1),
      box.center + const Offset(-12, 1),
      line,
      white,
      head: 3,
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
      screen,
      Radius.circular(screen.height * 0.12),
    );
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    canvas.drawRect(
      screen.deflate(3),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F84AD), Color(0xFFB9E2EF)],
        ).createShader(screen),
    );
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
      base,
      Radius.circular(base.height * 0.4),
    );
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
      canvas.drawLine(
        Offset(tower.left, y),
        Offset(tower.right, y),
        ink.stroke,
      );
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
      ..cubicTo(
        l - w * 0.02,
        t + h * 0.52,
        l + w * 0.16,
        t + h * 0.26,
        l + w * 0.34,
        t + h * 0.38,
      )
      ..cubicTo(
        l + w * 0.38,
        t + h * 0.06,
        l + w * 0.72,
        t + h * 0.06,
        l + w * 0.76,
        t + h * 0.34,
      )
      ..cubicTo(
        l + w * 0.94,
        t + h * 0.30,
        l + w * 1.00,
        t + h * 0.58,
        l + w * 0.90,
        t + h * 0.88,
      )
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
      unit,
      Radius.circular(unit.height * 0.3),
    );
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
        radius: math.min(box.width, box.height) * f,
      );
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
      body,
      Radius.circular(body.height * 0.28),
    );
    canvas.drawRRect(rrect, ink.fill);
    canvas.drawRRect(rrect, ink.stroke);
    for (final f in const [0.28, 0.72]) {
      final x = box.left + box.width * f;
      canvas.drawLine(
        Offset(x, body.top),
        Offset(x, box.top + box.height * 0.10),
        ink.stroke,
      );
    }
    final arcRect = Rect.fromCircle(
      center: Offset(box.center.dx, body.top),
      radius: body.width * 0.26,
    );
    canvas.drawArc(arcRect, math.pi * 1.25, math.pi * 0.5, false, ink.stroke);
  }

  /// Fallback for unknown types: a plain rounded box (the name under it does
  /// the labelling).
  static void _box(Canvas canvas, Rect box, _GlyphInk ink) {
    final rrect = RRect.fromRectAndRadius(
      box,
      Radius.circular(box.height * 0.22),
    );
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
  final base = TextStyle(
    fontFamily: 'Roboto', fontSize: fontSize, fontWeight: fontWeight,
  );
  final fill = TextPainter(
    text: TextSpan(
      text: value,
      style: base.copyWith(color: color),
    ),
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

/// Compute a deterministic VLAN id per node from its subnet (1..n by first
/// appearance in the addressing list; 0 = unassigned).
Map<String, int> vlanAssignments(NetworkIntent intent) {
  final subnets = <String, int>{};
  final firstAddress = <String, InterfaceAddr>{};
  for (final a in intent.addressing) {
    firstAddress.putIfAbsent(a.node, () => a);
    if (!a.ipCidr.contains('/')) continue;
    final p = a.ipCidr.split('.').take(3).join('.');
    subnets.putIfAbsent(p, () => subnets.length + 1);
  }
  final out = <String, int>{};
  for (final n in intent.nodes) {
    final addr = firstAddress[n.name]?.ipCidr ?? '';
    if (addr.isEmpty) {
      out[n.name] = 0;
      continue;
    }
    final p = addr.split('.').take(3).join('.');
    out[n.name] = subnets[p] ?? 0;
  }
  return out;
}

/// Interactive plan canvas: drag nodes, tap for a detail sheet.
class TopologyCanvas extends StatefulWidget {
  final NetworkIntent intent;
  final Map<String, Offset?>? layout;
  final ValueChanged<Map<String, Offset>>? onLayoutChanged;
  final ValueChanged<String>? onNodeTap;
  final Map<String, List<String>>? nodeIssues;
  final bool allowNodeDrag;
  final String? selectedNode;
  final Set<String> selectedNodes;

  const TopologyCanvas({
    super.key,
    required this.intent,
    this.layout,
    this.onLayoutChanged,
    this.onNodeTap,
    this.nodeIssues,
    this.allowNodeDrag = true,
    this.selectedNode,
    this.selectedNodes = const <String>{},
  });

  @override
  State<TopologyCanvas> createState() => _TopologyCanvasState();
}

class _TopologyCanvasState extends State<TopologyCanvas> {
  final _view = TransformationController();
  Map<String, Offset> _positions = {};
  TopologyFrame? _frame;
  Size _lastSize = Size.zero;
  String? _dragging;
  Offset _dragPointer = Offset.zero;
  NetworkIntent? _vlanIntent;
  Map<String, int> _cachedVlans = const {};

  Map<String, int> _vlansFor(NetworkIntent intent) {
    if (!identical(intent, _vlanIntent)) {
      _vlanIntent = intent;
      _cachedVlans = vlanAssignments(intent);
    }
    return _cachedVlans;
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TopologyCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intent != widget.intent ||
        oldWidget.layout != widget.layout) {
      // A parent echoing a drag must not reset the user's pan or zoom.
      final supplied = widget.layout ?? widget.intent.layout;
      final isDragEcho =
          supplied.length == _positions.length &&
          supplied.entries.every((e) => _positions[e.key] == e.value);
      if (!isDragEcho || oldWidget.intent != widget.intent) {
        _frame = null;
      }
    }
  }

  void _fit(Size viewport) {
    final frame = _frame!;
    final scale = math
        .min(
          viewport.width / frame.size.width,
          viewport.height / frame.size.height,
        )
        .clamp(0.01, 1.5);
    _view.value = Matrix4.diagonal3Values(scale, scale, scale)
      ..setTranslationRaw(
        (viewport.width - frame.size.width * scale) / 2,
        (viewport.height - frame.size.height * scale) / 2,
        0,
      );
  }

  void _zoom(double factor, Size viewport) {
    final centre = viewport.center(Offset.zero);
    final scene = _view.toScene(centre);
    final scale = (_view.value.getMaxScaleOnAxis() * factor).clamp(0.01, 8.0);
    _view.value = Matrix4.diagonal3Values(scale, scale, scale)
      ..setTranslationRaw(
        centre.dx - scene.dx * scale,
        centre.dy - scene.dy * scale,
        0,
      );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: LayoutBuilder(builder: _canvas)),
        TopologyLegend(
          vlans: _vlansFor(widget.intent),
          issues: widget.nodeIssues ?? const {},
          links: widget.intent.links,
        ),
      ],
    );
  }

  Widget _canvas(BuildContext context, BoxConstraints constraints) {
    final viewport = Size(constraints.maxWidth, constraints.maxHeight);
    if (viewport.isEmpty) return const SizedBox.shrink();
    if (_frame == null || _lastSize != viewport) {
      _positions = layoutPlan(
        widget.intent.copyWith(layout: widget.layout ?? widget.intent.layout),
        viewport,
      );
      _frame = TopologyFrame.fromPositions(_positions);
      _lastSize = viewport;
      _fit(viewport);
    }
    final frame = _frame!;
    final intent = widget.intent;
    final byName = {for (final n in intent.nodes) n.name: n};
    final vlans = _vlansFor(intent);
    final issues = widget.nodeIssues ?? const <String, List<String>>{};
    final peers = <String, Set<String>>{};
    for (final link in intent.links) {
      peers.putIfAbsent(link.a, () => <String>{}).add(link.b);
      peers.putIfAbsent(link.b, () => <String>{}).add(link.a);
    }
    final displayed = {
      for (final e in _positions.entries) e.key: e.value - frame.origin,
    };

    return Semantics(
      label: _summaryLabel(_positions, vlans, issues),
      container: true,
      child: ClipRect(
        child: ColoredBox(
          color: kWorkspaceBackground,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _view,
                  constrained: false,
                  minScale: 0.01,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(600),
                  child: SizedBox(
                    width: frame.size.width,
                    height: frame.size.height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ValueListenableBuilder<Matrix4>(
                            valueListenable: _view,
                            builder: (context, _, _) {
                              final visible = Rect.fromPoints(
                                _view.toScene(Offset.zero),
                                _view.toScene(viewport.bottomRight(Offset.zero)),
                              ).inflate(90);
                              return RepaintBoundary(
                                child: CustomPaint(
                                  painter: TopologyDiagramPainter(
                                    intent: intent,
                                    positions: displayed,
                                    issues: issues,
                                    dragging: _dragging,
                                    selected: widget.selectedNode,
                                    selectedNodes: widget.selectedNodes,
                                    vlanIds: vlans,
                                    visibleRect: visible,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Positioned.fill(
                          child: ValueListenableBuilder<Matrix4>(
                            valueListenable: _view,
                            builder: (context, _, _) {
                              final visible = Rect.fromPoints(
                                _view.toScene(Offset.zero),
                                _view.toScene(viewport.bottomRight(Offset.zero)),
                              ).inflate(90);
                              return Stack(
                                children: [
                                  for (final entry in displayed.entries)
                                    if (Rect.fromCenter(
                                      center: entry.value,
                                      width: kNodeWidth + 24,
                                      height: kNodeHeight + 44,
                                    ).overlaps(visible))
                                      Positioned(
                            left: entry.value.dx - kNodeWidth / 2,
                            top: entry.value.dy - kNodeHeight / 2,
                            width: kNodeWidth,
                            height: kNodeHeight + 28,
                            child: _NodeTarget(
                              label: _nodeLabel(
                                entry.key,
                                byName[entry.key],
                                vlans[entry.key] ?? 0,
                                peers[entry.key] ?? const <String>{},
                                issues[entry.key] ?? const [],
                              ),
                              onOpen: () {
                                final callback = widget.onNodeTap;
                                if (callback != null) {
                                  callback(entry.key);
                                } else {
                                  _showInspector(
                                    context,
                                    entry.key,
                                    byName[entry.key],
                                  );
                                }
                              },
                              onPanStart: !widget.allowNodeDrag
                                  ? null
                                  : (d) {
                                      _dragPointer = d.globalPosition;
                                      setState(() => _dragging = entry.key);
                                    },
                              onPanUpdate: !widget.allowNodeDrag
                                  ? null
                                  : (d) {
                                      final delta =
                                          (d.globalPosition - _dragPointer) /
                                          _view.value.getMaxScaleOnAxis();
                                      _dragPointer = d.globalPosition;
                                      final moving = widget.selectedNodes
                                              .contains(entry.key)
                                          ? widget.selectedNodes
                                          : <String>{entry.key};
                                      setState(() {
                                        for (final name in moving) {
                                          final current = _positions[name];
                                          if (current == null) continue;
                                          final point = current + delta;
                                          _positions[name] = Offset(
                                            point.dx.clamp(
                                              frame.origin.dx + 44,
                                              frame.origin.dx + frame.size.width - 44,
                                            ),
                                            point.dy.clamp(
                                              frame.origin.dy + 24,
                                              frame.origin.dy + frame.size.height - 48,
                                            ),
                                          );
                                        }
                                      });
                                    },
                              onPanEnd: !widget.allowNodeDrag
                                  ? null
                                  : (_) {
                                      setState(() => _dragging = null);
                                      widget.onLayoutChanged?.call(
                                        Map.of(_positions),
                                      );
                                    },
                              onPanCancel: !widget.allowNodeDrag
                                  ? null
                                  : () => setState(() => _dragging = null),
                            ),
                                      ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: kWorkspaceBackground.withValues(alpha: 0.92),
                      border: Border.all(color: kWorkspaceDot),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      child: Text(
                        'Logical',
                        style: TextStyle(
                          color: kWorkspaceLabel,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: kWorkspaceBackground,
                  elevation: 1,
                  borderRadius: BorderRadius.circular(6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Zoom out',
                        visualDensity: VisualDensity.compact,
                        color: kWorkspaceInk,
                        icon: const Icon(Icons.remove, size: 20),
                        onPressed: () => _zoom(1 / 1.3, viewport),
                      ),
                      IconButton(
                        tooltip: 'Fit network',
                        visualDensity: VisualDensity.compact,
                        color: kWorkspaceInk,
                        icon: const Icon(Icons.fit_screen, size: 20),
                        onPressed: () => _fit(viewport),
                      ),
                      IconButton(
                        tooltip: 'Zoom in',
                        visualDensity: VisualDensity.compact,
                        color: kWorkspaceInk,
                        icon: const Icon(Icons.add, size: 20),
                        onPressed: () => _zoom(1.3, viewport),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
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

  void _showInspector(BuildContext context, String name, NetNode? node) {
    if (node == null) return;
    final intent = widget.intent;
    final addrs = intent.addressing.where((a) => a.node == name).toList();
    final issues = widget.nodeIssues?[name] ?? const [];
    final vlan = _vlansFor(intent)[name] ?? 0;
    final generatedConfig = PacketTracerAdapter.deviceConfigs(intent)[name] ?? '';
    final device = PacketTracerCatalog.instance.device(node.model ?? node.type);
    final variants = device?.variants.where(
      (variant) =>
          node.modules.isEmpty || node.modules.every(variant.modules.contains),
    );
    final ports = <String, PtPort>{};
    for (final variant in variants ?? const <PtHardwareVariant>[]) {
      for (final port in variant.ports) {
        ports.putIfAbsent(ptPortName(port.name), () => port);
      }
    }
    final usedPorts = <String, NetLink>{};
    for (final link in intent.links) {
      if (link.a == name) usedPorts[ptPortName(link.aIf)] = link;
      if (link.b == name) usedPorts[ptPortName(link.bIf)] = link;
    }
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
                Row(
                  children: [
                    Icon(_iconFor(node.type), size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${node.type}${node.model == null ? '' : ' - ${node.model}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Text(vlan == 0 ? 'No VLAN assigned' : 'VLAN $vlan'),
                if (node.modules.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Installed modules: ${node.modules.join(', ')}'),
                ],
                if (node.services.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Services: ${node.services.join(', ')}'),
                ],
                if (addrs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final a in addrs) Text('${a.iface}:  ${a.ipCidr}'),
                ],
                if (device?.variants.isNotEmpty == true) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${ports.length} known ports · '
                    '${usedPorts.length} connected · '
                    '${(ports.keys.toSet()..removeAll(usedPorts.keys)).length} free',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final port in ports.entries.take(16))
                    Builder(
                      builder: (context) {
                        final link = usedPorts[port.key];
                        final peer = link == null
                            ? null
                            : link.a == name
                            ? '${link.b} ${link.bIf}'
                            : '${link.a} ${link.aIf}';
                        final cable = link == null
                            ? null
                            : PacketTracerCatalog.instance.cable(link.cable)?.label ??
                                  link.cable ??
                                  'cable';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.cable_outlined,
                            size: 18,
                            color: link == null
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                          ),
                          title: Text(port.value.name),
                          subtitle: Text(
                            peer == null
                                ? '${port.value.type} · free'
                                : '$peer · $cable',
                          ),
                        );
                      },
                    ),
                  if (ports.length > 16)
                    Text('Showing 16 of ${ports.length} ports'),
                ] else
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('This model is recognized; its port template is not available yet.'),
                  ),
                const SizedBox(height: 6),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Generated configuration'),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectionArea(
                        child: SelectableText(
                          generatedConfig.isEmpty
                              ? 'No generated commands for this device yet.'
                              : generatedConfig,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final i in issues)
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: AppPalette.warning(scheme),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(i, style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
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
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final GestureDragCancelCallback? onPanCancel;

  const _NodeTarget({
    required this.label,
    required this.onOpen,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
  });

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
          dragStartBehavior: DragStartBehavior.down,
          onTap: onOpen,
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          onPanCancel: onPanCancel,
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
    final withIssues = issues.keys.where(
      (name) => (issues[name] ?? const []).isNotEmpty,
    );
    final hasSerial = links.any((l) => l.isSerial);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
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
          for (final id in {
            for(final link in links) PacketTracerCatalog.instance.cable(link.cable)?.id ?? 'unknown',
          }.where((id)=>id!='copper' && !id.startsWith('serial')))
            Row(mainAxisSize:MainAxisSize.min,children:[
              SizedBox(width:18,height:8,child:CustomPaint(painter:_KeyPainter(
                dashed:id=='copper-cross',color:ptCableColor(id)))),
              const SizedBox(width:4),
              Text(PacketTracerCatalog.instance.cable(id)?.label ?? 'Unknown cable',style:style),
            ]),
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
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
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

/// Bounds in network coordinates. Only uniform scaling and translation are
/// used to fit a design; its relative positions never depend on screen size.
class TopologyFrame {
  final Offset origin;
  final Size size;
  const TopologyFrame(this.origin, this.size);

  factory TopologyFrame.fromPositions(Map<String, Offset> positions) {
    if (positions.isEmpty) {
      return const TopologyFrame(Offset.zero, Size(320, 240));
    }
    final points = positions.values;
    final minX = points.map((p) => p.dx).reduce(math.min);
    final maxX = points.map((p) => p.dx).reduce(math.max);
    final minY = points.map((p) => p.dy).reduce(math.min);
    final maxY = points.map((p) => p.dy).reduce(math.max);
    const padX = 64.0;
    const padY = 72.0;
    return TopologyFrame(
      Offset(minX - padX, minY - padY),
      Size(maxX - minX + padX * 2, maxY - minY + padY * 2),
    );
  }
}

/// The same workspace renderer is used by gallery cards and interactive views.
class TopologyDiagramPainter extends CustomPainter {
  final NetworkIntent intent;
  final Map<String, Offset> positions;
  final Map<String, List<String>> issues;
  final String? dragging;
  final String? selected;
  final Set<String> selectedNodes;
  final Map<String, int>? vlanIds;
  final Rect? visibleRect;
  final bool showLabels;
  final bool showGrid;

  const TopologyDiagramPainter({
    required this.intent,
    required this.positions,
    this.issues = const {},
    this.dragging,
    this.selected,
    this.selectedNodes = const <String>{},
    this.vlanIds,
    this.visibleRect,
    this.showLabels = true,
    this.showGrid = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kWorkspaceBackground);
    if (showGrid) {
      final dot = Paint()..color = kWorkspaceDot;
      final bounds = visibleRect ?? (Offset.zero & size);
      final startX = math.max(0, (bounds.left / 24).floor() * 24).toDouble();
      final startY = math.max(0, (bounds.top / 24).floor() * 24).toDouble();
      final endX = math.min(size.width, bounds.right + 24);
      final endY = math.min(size.height, bounds.bottom + 24);
      for (var x = startX; x < endX; x += 24) {
        for (var y = startY; y < endY; y += 24) {
          canvas.drawCircle(Offset(x, y), 0.65, dot);
        }
      }
    }
    for (final link in intent.wiredLinks) {
      final a = positions[link.a];
      final b = positions[link.b];
      if (a == null || b == null) continue;
      if (visibleRect != null &&
          !Rect.fromPoints(a, b).inflate(48).overlaps(visibleRect!)) {
        continue;
      }
      final delta = b - a;
      final length = delta.distance;
      if (length < 1) continue;
      final unit = delta / length;
      final start = a + unit * 23;
      final end = b - unit * 23;
      final ink = Paint()
        ..color = ptCableColor(link.cable)
        ..strokeWidth = link.isSerial ? 1.6 : 1.4
        ..style = PaintingStyle.stroke;
      if (link.isSerial) {
        final normal = Offset(-unit.dy, unit.dx);
        final path = Path()..moveTo(start.dx, start.dy);
        final span = (end - start).distance;
        for (var d = 8.0, i = 0; d < span; d += 8, i++) {
          final point = start + unit * d + normal * (i.isEven ? 3 : -3);
          path.lineTo(point.dx, point.dy);
        }
        path.lineTo(end.dx, end.dy);
        canvas.drawPath(path, ink);
      } else if (PacketTracerCatalog.instance.cable(link.cable)?.id == 'copper-cross') {
        final length=(end-start).distance;
        for(var distance=0.0;distance<length;distance+=7) {
          canvas.drawLine(start+unit*distance,start+unit*math.min(distance+4,length),ink);
        }
      } else {
        canvas.drawLine(start, end, ink);
      }
      // These mark physical cable ends, not simulated link status.
      final mark = Paint()..color = ink.color;
      canvas.drawCircle(start, 2.2, mark);
      canvas.drawCircle(end, 2.2, mark);
      if (showLabels && length > 125) {
        final side = Offset(-unit.dy, unit.dx) * 8;
        drawHaloText(
          canvas,
          link.aIf,
          a + delta * 0.23 + side,
          8,
          kWorkspaceLabel,
          maxWidth: 64,
        );
        drawHaloText(
          canvas,
          link.bIf,
          b - delta * 0.23 + side,
          8,
          kWorkspaceLabel,
          maxWidth: 64,
        );
      }
    }

    final vlans = vlanIds ?? vlanAssignments(intent);
    for (final node in intent.nodes) {
      final pos = positions[node.name];
      if (pos == null) continue;
      if (visibleRect != null &&
          !Rect.fromCenter(
            center: pos,
            width: kNodeWidth + 24,
            height: kNodeHeight + 44,
          ).overlaps(visibleRect!)) {
        continue;
      }
      final kind = ptGlyphKind(node.type);
      final hasIssues = issues[node.name]?.isNotEmpty ?? false;
      final glyph = Rect.fromCenter(center: pos, width: 48, height: 34);
      if (dragging == node.name ||
          selected == node.name ||
          selectedNodes.contains(node.name)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(glyph.inflate(7), const Radius.circular(6)),
          Paint()..color = const Color(0x332178B0),
        );
      }
      final fill = switch (kind) {
        PtGlyphKind.router ||
        PtGlyphKind.switchGlyph ||
        PtGlyphKind.wirelessAp ||
        PtGlyphKind.wirelessRouter => const Color(0xFF9AC8DF),
        PtGlyphKind.firewall => const Color(0xFFE4B18E),
        PtGlyphKind.pc || PtGlyphKind.server => const Color(0xFFD1DCE2),
        _ => kWorkspaceGlyphFill,
      };
      PtGlyphPainter.paintGlyph(
        canvas,
        kind,
        glyph,
        stroke: kWorkspaceInk,
        fill: fill,
        strokeWidth: 1.25,
      );
      if (showLabels) {
        drawHaloText(
          canvas,
          hasIssues ? '${node.name} !' : node.name,
          pos + const Offset(0, 27),
          11,
          hasIssues ? kWorkspaceSerial : kWorkspaceLabel,
          maxWidth: kNodeWidth,
          fontWeight: FontWeight.w600,
        );
        drawHaloText(
          canvas,
          node.model ?? node.type,
          pos + const Offset(0, 40),
          8,
          kWorkspaceInk,
          maxWidth: kNodeWidth,
        );
        final vlan = vlans[node.name] ?? 0;
        if (vlan > 0) {
          drawHaloText(
            canvas,
            'V$vlan',
            pos + const Offset(34, -14),
            8,
            vlanColor(vlan),
            maxWidth: 32,
            fontWeight: FontWeight.w600,
          );
        }
      }
      if (hasIssues) {
        canvas.drawCircle(glyph.topRight, 4, Paint()..color = kWorkspaceSerial);
      }
    }
  }

  @override
  bool shouldRepaint(covariant TopologyDiagramPainter old) =>
      old.positions != positions ||
      old.intent != intent ||
      old.dragging != dragging ||
      old.selected != selected ||
      old.selectedNodes != selectedNodes ||
      old.vlanIds != vlanIds ||
      old.visibleRect != visibleRect ||
      old.issues != issues ||
      old.showLabels != showLabels ||
      old.showGrid != showGrid;
}
