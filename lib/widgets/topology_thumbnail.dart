import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/layout_engine.dart';
import 'topology_canvas.dart';

/// A scaled copy of the same devices, cables and coordinates as the full view.
class TopologyThumbnail extends StatelessWidget {
  final NetworkIntent intent;
  final LayoutSnapshot snapshot;
  final bool showLabels;

  const TopologyThumbnail({
    super.key,
    required this.intent,
    required this.snapshot,
    this.showLabels = false,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ThumbPainter(intent, snapshot, showLabels),
    child: const SizedBox.expand(),
  );
}

class _ThumbPainter extends CustomPainter {
  final NetworkIntent intent;
  final LayoutSnapshot snapshot;
  final bool showLabels;
  const _ThumbPainter(this.intent, this.snapshot, this.showLabels);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kWorkspaceBackground);
    if (size.isEmpty || snapshot.isEmpty) return;
    final positions = {
      for (final spot in snapshot.spots) spot.name: Offset(spot.x, spot.y),
    };
    final frame = TopologyFrame.fromPositions(positions);
    final scale = math.min(
      size.width / frame.size.width,
      size.height / frame.size.height,
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(
      (size.width - frame.size.width * scale) / 2,
      (size.height - frame.size.height * scale) / 2,
    );
    canvas.scale(scale);
    TopologyDiagramPainter(
      intent: intent,
      positions: {
        for (final e in positions.entries) e.key: e.value - frame.origin,
      },
      showLabels: showLabels,
    ).paint(canvas, frame.size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) =>
      old.snapshot != snapshot ||
      old.intent != intent ||
      old.showLabels != showLabels;
}
