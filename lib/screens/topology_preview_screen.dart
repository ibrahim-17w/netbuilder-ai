import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
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
          AppToolbar(
            // The strip flexes the leading itself; the hint ellipsizes inside
            // it so the counts always stay visible.
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTag(
                  label: '${intent.nodes.length} devices',
                  tone: AppTone.accent,
                  icon: Icons.devices_other_outlined,
                ),
                AppTag(
                  label: '${intent.links.length} cables',
                  tone: AppTone.info,
                  icon: Icons.cable_outlined,
                ),
                const SizedBox(width: AppTheme.s8),
                Flexible(
                  child: Text(
                    'drag to rearrange, tap for details',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
