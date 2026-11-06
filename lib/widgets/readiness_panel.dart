import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// How one setup check is doing.
enum ReadinessState {
  /// The check passed and the related feature is usable.
  ready,

  /// The check is still running; the user should not act yet.
  checking,

  /// The feature is optional and the app still works without it.
  optional,

  /// A required live feature is unavailable, but offline work continues.
  blocked,
}

/// One line in the first-run readiness panel.
class ReadinessItem {
  final String label;
  final String detail;
  final ReadinessState state;
  final String? actionLabel;
  final VoidCallback? onAction;

  const ReadinessItem({
    required this.label,
    required this.detail,
    required this.state,
    this.actionLabel,
    this.onAction,
  });
}

/// A compact, dismissible answer to "what do I still need to set up?".
///
/// This is deliberately shown in the chat instead of behind Settings: the
/// first useful thing a tester does is type a request, and a missing engine
/// or Packet Tracer install should be understandable before that request
/// fails or quietly falls back. Offline planning is always presented as a
/// working path, never as a failure.
///
/// The panel used to render every check with its full description up front,
/// which covered half the conversation before the first message was typed.
/// It is now a one-line status bar: a dot per check, and the full rows (with
/// their per-check actions) behind a Details toggle the user asks for.
class ReadinessPanel extends StatefulWidget {
  final List<ReadinessItem> items;
  final VoidCallback onDismiss;
  final String title;
  final String subtitle;

  const ReadinessPanel({
    super.key,
    required this.items,
    required this.onDismiss,
    this.title = 'First-run readiness',
    this.subtitle =
        'Offline planning works now. Finish these optional checks for live '
        'Packet Tracer work.',
  });

  @override
  State<ReadinessPanel> createState() => _ReadinessPanelState();
}

class _ReadinessPanelState extends State<ReadinessPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocked = widget.items.any(
      (item) => item.state == ReadinessState.blocked,
    );
    final checking = widget.items.any(
      (item) => item.state == ReadinessState.checking,
    );
    final (statusIcon, statusColor) = blocked
        ? (Icons.warning_amber_rounded, scheme.error)
        : checking
        ? (Icons.hourglass_top, scheme.onSurfaceVariant)
        : (Icons.checklist_rounded, scheme.primary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s10,
        AppTheme.s6,
        AppTheme.s10,
        0,
      ),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The collapsed bar is the panel for as long as the user wants
            // it to be: one line that names every check and its state, and
            // opens the detail rows only when asked.
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s12,
                  AppTheme.s8,
                  AppTheme.s4,
                  AppTheme.s8,
                ),
                child: Row(
                  children: [
                    Icon(statusIcon, size: 18, color: statusColor),
                    const SizedBox(width: AppTheme.s8),
                    Text(
                      widget.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: AppTheme.s10),
                    Expanded(
                      child: Wrap(
                        spacing: AppTheme.s6,
                        runSpacing: 4,
                        children: [
                          for (final item in widget.items)
                            _ReadinessDot(item: item),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppTheme.s4),
                    // The chevron carries the toggle's meaning; the whole bar
                    // is the hit target, and the InkWell under it gives the
                    // pointer cursor on hover.
                    Padding(
                      padding: const EdgeInsets.only(right: AppTheme.s6),
                      child: Tooltip(
                        message: _expanded
                            ? 'Hide the setup checklist details'
                            : 'Show the setup checklist details',
                        child: Icon(
                          _expanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Hide the setup checklist',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onDismiss,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              // A conditional child, not an opacity fade: the detail rows
              // must leave the tree entirely when collapsed, so finders,
              // screen readers and focus order agree that they are gone.
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.s12,
                        AppTheme.s4,
                        AppTheme.s4,
                        AppTheme.s8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppTheme.s8),
                          for (final item in widget.items)
                            _ReadinessRow(item: item),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one-line state pill for a single check: a colored dot, the label.
/// It is the collapsed panel's whole summary - four of these read in a
/// glance where the old full rows took a quarter of the screen.
class _ReadinessDot extends StatelessWidget {
  final ReadinessItem item;

  const _ReadinessDot({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = _stateVisuals(item.state, scheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            item.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

(IconData, Color) _stateVisuals(
  ReadinessState state,
  ColorScheme scheme,
) => switch (state) {
  ReadinessState.ready => (Icons.check_circle, scheme.primary),
  ReadinessState.checking => (Icons.hourglass_top, scheme.onSurfaceVariant),
  ReadinessState.optional => (Icons.info_outline, scheme.tertiary),
  ReadinessState.blocked => (Icons.warning_amber_rounded, scheme.error),
};

class _ReadinessRow extends StatelessWidget {
  final ReadinessItem item;

  const _ReadinessRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = _stateVisuals(item.state, scheme);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: AppTheme.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  item.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (item.actionLabel != null && item.onAction != null)
            TextButton(
              onPressed: item.onAction,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8),
              ),
              child: Text(item.actionLabel!),
            ),
        ],
      ),
    );
  }
}
