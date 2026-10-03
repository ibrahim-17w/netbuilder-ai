import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/layout_engine.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/topology_canvas.dart' show TopologyCanvas;
import '../widgets/topology_thumbnail.dart';

/// Pick a drawing for a plan BEFORE it is built.
///
/// The plan card said "12 devices, 11 cables" and the user had to imagine the
/// picture; a wrong drawing only became visible after a `.pkt` was written and
/// opened. This screen renders every drawing the engine can produce, side by
/// side, from the plan itself, so the choice is made against the real thing -
/// and the chosen style is carried into the build unchanged (the same
/// geometry, see [computeLayoutSnapshot]).
///
/// Returns the chosen style, or null when the user backs out without choosing.
class LayoutGalleryScreen extends StatefulWidget {
  final NetworkIntent intent;

  /// The style the plan already has, marked as "current".
  final String currentStyle;

  /// The devices the plan parks to one side, so the `grouped` tile shows the
  /// servers actually moved instead of a grouped tree with nothing in it.
  final List<String> side;

  /// Every group the plan sends to an edge, in order. Preferred over [side]
  /// when set, because "servers left, routers right" is two columns.
  final List<LayoutZone> zones;

  const LayoutGalleryScreen({
    super.key,
    required this.intent,
    this.currentStyle = 'tree',
    this.side = const <String>[],
    this.zones = const <LayoutZone>[],
  });

  /// Opens the gallery and resolves to the chosen style (null = cancelled).
  static Future<String?> show(
    BuildContext context, {
    required NetworkIntent intent,
    String currentStyle = 'tree',
    List<String> side = const <String>[],
    List<LayoutZone> zones = const <LayoutZone>[],
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => LayoutGalleryScreen(
          intent: intent,
          currentStyle: currentStyle,
          side: side,
          zones: zones,
        ),
      ),
    );
  }

  @override
  State<LayoutGalleryScreen> createState() => _LayoutGalleryScreenState();
}

class _LayoutGalleryScreenState extends State<LayoutGalleryScreen> {
  late Map<String, LayoutSnapshot> _layouts;
  late String _selected;
  String? _zoomed;

  @override
  void initState() {
    super.initState();
    _layouts = computeAllLayouts(
      widget.intent,
      side: widget.side.isEmpty ? const <String>['server'] : widget.side,
      zones: _zones(),
    );
    _selected = kLayoutStyles.contains(widget.currentStyle)
        ? widget.currentStyle
        : kLayoutStyles.first;
  }

  /// The zones the grouped tile draws with, falling back to a single column of
  /// servers so the tile is never a grouped tree with nothing in it.
  List<LayoutZone> _zones() {
    if (widget.zones.isNotEmpty) return widget.zones;
    final names = widget.side.isEmpty
        ? const <String>['server']
        : widget.side;
    return <LayoutZone>[LayoutZone(names, edge: 'left')];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final intent = widget.intent;
    final zoomed = _zoomed;
    if (zoomed != null) {
      return _zoomedView(context, theme, intent, zoomed);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a layout'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('Use this layout'),
          ),
        ],
      ),
      body: Column(
        children: [
          AppToolbar(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                  AppTag(
                    label: intent.projectName,
                    tone: AppTone.accent,
                    icon: Icons.folder_outlined,
                  ),
                  const SizedBox(width: AppTheme.s6),
                  AppTag(
                    label: '${intent.nodes.length} devices',
                    tone: AppTone.neutral,
                  ),
                  const SizedBox(width: AppTheme.s6),
                  AppTag(
                    label: '${intent.links.length} cables',
                    tone: AppTone.neutral,
                  ),
                  const SizedBox(width: AppTheme.s8),
                Flexible(
                  child: Text(
                    'Pick how it should be drawn - the build uses exactly '
                    'this picture.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.all(AppTheme.gutter(context)),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 360,
                mainAxisSpacing: AppTheme.s12,
                crossAxisSpacing: AppTheme.s12,
                childAspectRatio: 1.25,
              ),
              itemCount: kLayoutStyles.length,
              itemBuilder: (context, index) {
                final style = kLayoutStyles[index];
                return _LayoutCard(
                  style: style,
                  snapshot: _layouts[style]!,
                  intent: intent,
                  selected: style == _selected,
                  isCurrent: style == widget.currentStyle,
                  onTap: () => setState(() => _selected = style),
                  onZoom: () => setState(() => _zoomed = style),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Full-screen, draggable view of one drawing, so a busy lab can be read
  /// before it is built. The interactive canvas lays out from the plan's own
  /// layout field, which is set to this style's snapshot.
  Widget _zoomedView(
    BuildContext context,
    ThemeData theme,
    NetworkIntent intent,
    String style,
  ) {
    final snapshot = _layouts[style]!;
    final laidOut = _intentWithSnapshot(intent, snapshot);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _zoomed = null),
        ),
        title: Text('${layoutStyleLabel(style)} - preview'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _selected = style;
                _zoomed = null;
              });
            },
            child: const Text('Use this layout'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppTheme.s8),
        child: TopologyCanvas(intent: laidOut),
      ),
    );
  }

  /// A copy of [base] whose layout field carries [snapshot]'s positions, so
  /// the interactive canvas draws the gallery's picture rather than its own.
  NetworkIntent _intentWithSnapshot(
    NetworkIntent base,
    LayoutSnapshot snapshot,
  ) {
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
      layout: {for (final s in snapshot.spots) s.name: Offset(s.x, s.y)},
    );
  }
}

class _LayoutCard extends StatelessWidget {
  final String style;
  final LayoutSnapshot snapshot;
  final NetworkIntent intent;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onZoom;

  const _LayoutCard({
    required this.style,
    required this.snapshot,
    required this.intent,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
    required this.onZoom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2.2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.35,
                      ),
                      child: TopologyThumbnail(
                        intent: intent,
                        snapshot: snapshot,
                        showLabels: true,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Row(
                      children: [
                        if (isCurrent)
                          _Pill(
                            text: 'current',
                            color: scheme.onSurfaceVariant,
                          ),
                        if (selected) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.check_circle,
                            size: 20,
                            color: scheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: IconButton(
                      tooltip: 'Enlarge',
                      iconSize: 18,
                      onPressed: onZoom,
                      icon: const Icon(Icons.zoom_in),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s12,
                AppTheme.s8,
                AppTheme.s12,
                AppTheme.s8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    layoutStyleLabel(style),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    layoutStyleBlurb(style),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}
