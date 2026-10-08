import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/topology_canvas.dart';

/// A Packet Tracer-style look at a built lab, shown on machines where Packet
/// Tracer itself was not found.
///
/// The chat's built-file path is tappable: with Packet Tracer installed the
/// tap hands the file to the operating system and the real application opens
/// it. Without one, the same tap lands here - the same canvas the layout
/// gallery and the topology preview draw with (the Packet Tracer-style
/// glyphs), over the plan the conversation actually built, at the positions
/// the engine wrote into the file. It is a viewer, not an editor: nothing
/// here writes to the .pkt.
class PktViewerScreen extends StatefulWidget {
  /// The built file this viewer is looking at - named in the header so a
  /// viewer opened for `office-lab.pkt` can be told apart from one opened
  /// for an earlier build.
  final String filePath;

  /// The plan the conversation holds (restored with the session, so a
  /// reopened chat still has it).
  final NetworkIntent? intent;

  /// The as-built canvas positions the engine echoed back
  /// (`layout.positions`, `[x, y]` per device name). Null or partial is
  /// fine: the canvas lays out whatever is missing.
  final Map<String, Offset>? positions;

  const PktViewerScreen({
    super.key,
    required this.filePath,
    required this.intent,
    this.positions,
  });

  @override
  State<PktViewerScreen> createState() => _PktViewerScreenState();
}

class _PktViewerScreenState extends State<PktViewerScreen> {
  Map<String, Offset?>? _layout;

  @override
  void initState() {
    super.initState();
    _layout = widget.positions == null
        ? null
        : {for (final e in widget.positions!.entries) e.key: e.value};
  }

  String get _fileName => widget.filePath.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    final hasPlan = intent != null && intent.nodes.isNotEmpty;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName.isEmpty ? 'Network viewer' : _fileName),
      ),
      body: hasPlan
          ? Column(
              children: [
                AppToolbar(
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
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.s12,
                    AppTheme.s6,
                    AppTheme.s12,
                    0,
                  ),
                  child: Text(
                    // Say what this is, once, where the user just arrived:
                    // Packet Tracer was not found, so this is the app's own
                    // drawing of the same file - not Packet Tracer itself.
                    'Packet Tracer was not found on this device, so this is '
                    'the built-in viewer: the same network the file '
                    'contains, drawn Packet Tracer-style. Drag to explore; '
                    'tap a device for details. Install Packet Tracer and '
                    'the same file will open there.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TopologyCanvas(
                      intent: intent,
                      layout: _layout,
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: AppTheme.s12),
                    Text(
                      'Nothing to draw yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppTheme.s8),
                    Text(
                      // The plan travels with the conversation; a viewer
                      // opened with neither plan nor positions has nothing
                      // honest to show. Saying so beats drawing a guess.
                      'The viewer draws the plan the conversation built, but '
                      'this chat does not currently hold one for '
                      '$_fileName. Reopen the conversation that produced the '
                      'file, or rebuild it from the plan.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
