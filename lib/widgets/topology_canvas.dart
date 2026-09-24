import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
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

  // horizontal centers per layer, servers keep to the right side
  final out = <String, Offset>{};
  final w = math.max(size.width, 80.0);
  final h = math.max(size.height, 80.0);
  final rowH = h / math.max(sortedKeys.length, 1);
  for (var li = 0; li < sortedKeys.length; li++) {
    final layerNodes = layers[sortedKeys[li]]!;
    final y = rowH * (li + 0.5);
    final isServerRow = sortedKeys[li] >= 4;
    final rowW = isServerRow ? w * 0.55 : w * 0.9;
    final left = isServerRow ? w * 0.45 : w * 0.05;
    for (var i = 0; i < layerNodes.length; i++) {
      final x = left + rowW * ((i + 0.5) / math.max(layerNodes.length, 1));
      out[layerNodes[i].name] = Offset(
        x.clamp(24.0, w - 24.0),
        y.clamp(24.0, h - 24.0),
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
Color vlanColor(int vlan) {
  if (vlan <= 0) return const Color(0xFF78909C);
  final hue = (vlan * 47) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.45).toColor();
}

class _PaintedEdge {
  final String a;
  final String b;
  final bool serial;
  const _PaintedEdge(this.a, this.b, this.serial);
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final positions = _resolve(size);
        final intent = widget.intent;
        final byName = {for (final n in intent.nodes) n.name: n};
        final edges = [
          for (final l in intent.links)
            if (positions.containsKey(l.a) && positions.containsKey(l.b))
              _PaintedEdge(l.a, l.b, l.isSerial),
        ];

        return GestureDetector(
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
          child: CustomPaint(
            size: size,
            painter: _TopoPainter(
              intent: intent,
              positions: positions,
              edges: edges,
              issues: widget.nodeIssues ?? const {},
              dragging: _dragging,
              scheme: Theme.of(context).colorScheme,
              vlans: vlanAssignments(intent),
            ),
          ),
        );
      },
    );
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
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.s16, 0, AppTheme.s16,
            AppTheme.s24),
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
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Color(0xFFEF6C00)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(i, style: const TextStyle(fontSize: 12))),
                ]),
            ],
          ],
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
    // edges first
    for (final e in edges) {
      final a = positions[e.a]!;
      final b = positions[e.b]!;
      final paint = Paint()
        ..strokeWidth = e.serial ? 1.5 : 2
        ..color = e.serial
            ? const Color(0xFFEF6C00)
            : scheme.outlineVariant
        ..style = PaintingStyle.stroke;
      canvas.drawLine(a, b, paint);
    }
    // nodes
    for (final entry in positions.entries) {
      final node = entry.key;
      final pos = entry.value;
      final vlan = vlans[node] ?? 0;
      final color = vlanColor(vlan);
      final hasIssues = issues[node]?.isNotEmpty ?? false;

      final box = Rect.fromCenter(center: pos, width: 88, height: 34);
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
      final tp = TextPainter(
        text: TextSpan(
          text: node,
          style: TextStyle(fontSize: 11, color: scheme.onSurface),
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
          Paint()..color = const Color(0xFFEF6C00),
        );
      }
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
