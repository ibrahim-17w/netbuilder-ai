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
class ReadinessPanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 310),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s12,
              AppTheme.s8,
              AppTheme.s4,
              AppTheme.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.checklist_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppTheme.s8),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Hide the setup checklist',
                      visualDensity: VisualDensity.compact,
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.s8),
                for (final item in items) _ReadinessRow(item: item),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadinessRow extends StatelessWidget {
  final ReadinessItem item;

  const _ReadinessRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (item.state) {
      ReadinessState.ready => (Icons.check_circle, scheme.primary),
      ReadinessState.checking => (Icons.hourglass_top, scheme.onSurfaceVariant),
      ReadinessState.optional => (Icons.info_outline, scheme.tertiary),
      ReadinessState.blocked => (Icons.warning_amber_rounded, scheme.error),
    };
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
