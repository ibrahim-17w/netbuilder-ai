import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/layout_engine.dart';
import '../widgets/topology_canvas.dart' show vlanAssignments, vlanColor;

/// A small, non-interactive rendering of one layout snapshot.
///
/// It draws the same boxes and cables the full canvas does, scaled to fit the
/// space given, so a person can compare drawings at a glance. It exists so the
/// preview and the built `.pkt` cannot drift: both come from
/// [computeLayoutSnapshot].
class TopologyThumbnail extends StatelessWidget {
  final NetworkIntent intent;
  final LayoutSnapshot snapshot;

  /// Small previews draw bare boxes; larger cards can afford the labels.
  final bool showLabels;

  const TopologyThumbnail({
    super.key,
    required this.intent,
    required this.snapshot,
    this.showLabels = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _ThumbPainter(
        intent: intent,
        snapshot: snapshot,
        scheme: scheme,
        showLabels: showLabels,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  final NetworkIntent intent;
  final LayoutSnapshot snapshot;
  final ColorScheme scheme;
  final bool showLabels;

  _ThumbPainter({
    required this.intent,
    required this.snapshot,
    required this.scheme,
    required this.showLabels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (snapshot.isEmpty || size.width <= 4 || size.height <= 4) return;
    final vlans = vlanAssignments(intent);
    final positions = <String, Offset>{};

    // Fit the drawing's bounding box (plus a margin for the boxes) into the
    // thumbnail, keeping aspect ratio. A wide-but-short drawing must not be
    // stretched to fill a square card.
    const margin = 18.0;
    final srcW = snapshot.width + margin * 2;
    final srcH = snapshot.height + margin * 2;
    final scale = math.min(size.width / srcW, size.height / srcH);
    final drawW = srcW * scale;
    final drawH = srcH * scale;
    final offX = (size.width - drawW) / 2;
    final offY = (size.height - drawH) / 2;

    Offset toCanvas(LayoutSpot s) => Offset(
      offX + (s.x - snapshot.minX + margin) * scale,
      offY + (s.y - snapshot.minY + margin) * scale,
    );

    for (final s in snapshot.spots) {
      positions[s.name] = toCanvas(s);
    }

    final nodeW = math.max(3.0, 88 * scale * 0.55);
    final nodeH = math.max(2.5, 34 * scale * 0.55);

    // Cables first.
    final cablePaint = Paint()
      ..strokeWidth = math.max(0.7, 1.6 * scale)
      ..color = scheme.outlineVariant
      ..style = PaintingStyle.stroke;
    final serialPaint = Paint()
      ..strokeWidth = math.max(0.7, 1.4 * scale)
      ..color = scheme.error
      ..style = PaintingStyle.stroke;
    for (final l in intent.links) {
      final a = positions[l.a];
      final b = positions[l.b];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, l.isSerial ? serialPaint : cablePaint);
    }

    // Nodes.
    for (final s in snapshot.spots) {
      final pos = positions[s.name]!;
      final color = vlanColor(vlans[s.name] ?? 0);
      final box = Rect.fromCenter(center: pos, width: nodeW, height: nodeH);
      final rrect = RRect.fromRectAndRadius(box, Radius.circular(nodeH / 3));
      canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: 0.22));
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.6, 1.0 * scale)
          ..color = color,
      );
      if (showLabels && nodeW > 26) {
        final tp = TextPainter(
          text: TextSpan(
            text: s.name,
            style: TextStyle(
              fontSize: math.max(7, 10 * scale),
              color: scheme.onSurface,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '...',
        )..layout(maxWidth: nodeW - 4);
        tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) =>
      old.snapshot != snapshot ||
      old.intent != intent ||
      old.scheme != scheme ||
      old.showLabels != showLabels;
}
