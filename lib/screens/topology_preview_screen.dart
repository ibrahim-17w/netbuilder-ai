import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../widgets/topology_canvas.dart';

/// Full-screen plan diagram: drag to rearrange, tap a node for details.
/// The arrangement is reported back through [onLayoutChanged] so the caller
/// can persist it into the plan.
class TopologyPreviewScreen extends StatefulWidget {
  final NetworkIntent intent;
  final ValueChanged<Map<String, Offset?>>? onLayoutChanged;

  const TopologyPreviewScreen({
    super.key,
    required this.intent,
    this.onLayoutChanged,
  });

  @override
  State<TopologyPreviewScreen> createState() => _TopologyPreviewScreenState();
}

class _TopologyPreviewScreenState extends State<TopologyPreviewScreen> {
  Map<String, Offset?>? _layout;

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    return Scaffold(
      appBar: AppBar(
        title: Text('${intent.projectName} - topology'),
        actions: [
          if (_layout != null)
            TextButton(
              onPressed: () {
                widget.onLayoutChanged?.call(Map.of(_layout!));
                Navigator.of(context).pop();
              },
              child: const Text('Save arrangement'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Text(
                  '${intent.nodes.length} devices, ${intent.links.length} '
                  'cables - drag boxes to rearrange, tap for details',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TopologyCanvas(
                intent: intent,
                layout: _layout?.cast<String, Offset?>(),
                onLayoutChanged: (positions) =>
                    setState(() => _layout = {
                          for (final e in positions.entries) e.key: e.value,
                        }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
