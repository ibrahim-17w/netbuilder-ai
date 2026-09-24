import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/capability_registry.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import 'whats_new.dart';

/// Every feature in the app, as buttons, searchable, from anywhere.
///
/// This is the answer to "I can see the app can do this, where is the
/// button?": the registry lists the capabilities, and this renders all of
/// them, grouped, with the ones that need a plan disabled and explained
/// rather than hidden. A capability that needs a plan is still *visible*,
/// because knowing the app can audit a .pkt is usefulness even before you
/// have one open.
Future<void> showActionHub(BuildContext context, ActionContext host) {
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= 760;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(AppTheme.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
          child: ActionHubPanel(host: host, onClose: () => Navigator.of(dialogContext).pop()),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.92,
      child: ActionHubPanel(
        host: host,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

/// The hub's content, separated from how it is presented so a test (or a
/// future full-screen page) can render it directly.
class ActionHubPanel extends StatefulWidget {
  final ActionContext host;
  final VoidCallback onClose;

  const ActionHubPanel({super.key, required this.host, this.onClose = _noop});

  static void _noop() {}

  @override
  State<ActionHubPanel> createState() => _ActionHubPanelState();
}

class _ActionHubPanelState extends State<ActionHubPanel> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Ctrl+K opens this, so the keyboard should already be in the field:
    // the fastest path through the hub is three letters and Enter.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _enabled(AppAction action) => !action.needsPlan || widget.host.hasPlan;

  /// The hub has to render without a SettingsService (a widget test mounts it
  /// bare), so the changelog card is optional rather than required.
  SettingsService? _settingsOrNull(BuildContext context) {
    try {
      return context.read<SettingsService>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _run(AppAction action) async {
    if (!_enabled(action)) return;
    widget.onClose();
    await action.run(widget.host);
  }

  Future<void> _runFirst() async {
    final matches = [
      for (final action in CapabilityRegistry.search(_query))
        if (_enabled(action)) action,
    ];
    if (matches.isEmpty) return;
    await _run(matches.first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = CapabilityRegistry.search(_query);
    final searching = _query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.s16,
            AppTheme.s16,
            AppTheme.s8,
            AppTheme.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  onChanged: (value) => setState(() => _query = value),
                  onSubmitted: (_) => _runFirst(),
                  decoration: InputDecoration(
                    labelText: 'Find a feature',
                    hintText: 'subnet, vlsm, terraform, ledger, diagnose',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: searching
                        ? IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          )
                        : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.s16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  searching
                      ? '${matches.length} feature(s) match "$_query"'
                      : '${CapabilityRegistry.all.length} features, grouped. '
                            'Enter runs the top match.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.host.intent != null)
                AppStatusPill(
                  label: 'Plan open',
                  detail: widget.host.project,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.s8),
        const Divider(height: 1),
        Expanded(
          child: matches.isEmpty
              ? AppEmptyState(
                  icon: Icons.search_off,
                  title: 'Nothing matches that',
                  body: 'Try a plainer word: "subnet", "pkt", "gns3", '
                      '"export", "diagnose", "theme".',
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppTheme.s8,
                    horizontal: AppTheme.s8,
                  ),
                  children: [
                    if (!searching && _settingsOrNull(context) != null)
                      ChangelogCard(settings: _settingsOrNull(context)!),
                    for (final group in CapabilityRegistry.groupOrder)
                      if (matches.any((a) => a.group == group))
                        _group(context, group, [
                          for (final action in matches)
                            if (action.group == group) action,
                        ]),
                  ],
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.s16,
            AppTheme.s8,
            AppTheme.s16,
            AppTheme.s12,
          ),
          child: Row(
            children: [
              Icon(
                Icons.keyboard_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppTheme.s6),
              Expanded(
                child: Text(
                  'Ctrl+K opens this anywhere. Esc closes it. '
                  'Closest to your goal: open the Network toolkit.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _group(BuildContext context, String group, List<AppAction> actions) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.s8,
            AppTheme.s12,
            AppTheme.s8,
            AppTheme.s4,
          ),
          child: Text(
            group.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final action in actions) _actionTile(context, action),
      ],
    );
  }

  Widget _actionTile(BuildContext context, AppAction action) {
    final theme = Theme.of(context);
    final enabled = _enabled(action);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s6),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: enabled ? 0.25 : 0.12,
        ),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: enabled ? () => _run(action) : null,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppTheme.s8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(
                      alpha: enabled ? 0.12 : 0.06,
                    ),
                    borderRadius: BorderRadius.circular(AppTheme.rSm),
                  ),
                  child: Icon(
                    action.icon,
                    size: 18,
                    color: enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                  ),
                ),
                const SizedBox(width: AppTheme.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? null
                              : theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (!enabled || action.touchesDevices) ...[
                        const SizedBox(height: AppTheme.s6),
                        Wrap(
                          spacing: AppTheme.s6,
                          runSpacing: AppTheme.s4,
                          children: [
                            if (!enabled)
                              const _Tag(
                                label: 'Open a plan first',
                                icon: Icons.lock_outline,
                              ),
                            if (action.touchesDevices)
                              const _Tag(
                                label: 'Changes something outside the app',
                                icon: Icons.warning_amber_rounded,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  enabled ? Icons.chevron_right : Icons.block,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final IconData icon;

  const _Tag({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.s4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
