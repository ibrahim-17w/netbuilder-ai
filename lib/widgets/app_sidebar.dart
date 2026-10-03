import 'package:flutter/material.dart';

import '../app/destinations.dart';
import '../services/engine_status.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// The app's navigation, as a real sidebar.
///
/// The strip this replaces was a narrow column of icons whose labels were set
/// in 10px type - technically "every screen, reachable by name", practically
/// a guessing game. The sidebar keeps the name (a screen is reachable BY
/// NAME) but promotes it to a list of labelled rows grouped by what the user
/// is doing: talk, plan, inspect, remember, configure.
///
/// The open plan gets its own card at the foot: which network is on the
/// table, how big it is, and the one button that opens its workspace. That
/// fact used to be visible only after switching screens.
class AppSidebar extends StatelessWidget {
  final AppDestination current;
  final ValueChanged<AppDestination> onSelect;
  final VoidCallback onHub;
  final VoidCallback onToolkit;
  final String planProject;
  final String planSummary;
  final String planTarget;
  final VoidCallback? onOpenWorkspace;

  const AppSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onHub,
    required this.onToolkit,
    this.planProject = '',
    this.planSummary = '',
    this.planTarget = '',
    this.onOpenWorkspace,
  });

  /// Which screens sit under which heading. The groups are the workflow:
  /// conversation, the plan, the files, the record - then the app itself.
  static const groups = <(String, List<AppDestination>)>[
    ('Assistant', [AppDestination.chat]),
    ('Plan and build', [
      AppDestination.newBuild,
      AppDestination.analyze,
      AppDestination.execution,
    ]),
    ('Files', [AppDestination.files, AppDestination.importPkts]),
    ('Record', [AppDestination.history, AppDestination.memory]),
    ('App', [AppDestination.settings]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 232,
      child: Material(
        color: AppPalette.panel(scheme),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s16,
                AppTheme.s16,
                AppTheme.s12,
                AppTheme.s12,
              ),
              child: const AppBrandMark(showWordmark: true),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.s12),
              child: _HubButton(onTap: onHub),
            ),
            const SizedBox(height: AppTheme.s10),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s10,
                  0,
                  AppTheme.s10,
                  AppTheme.s10,
                ),
                children: [
                  for (final (label, destinations) in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.s8,
                        AppTheme.s12,
                        AppTheme.s8,
                        AppTheme.s4,
                      ),
                      child: Text(
                        label.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    for (final destination in destinations)
                      _SidebarTile(
                        destination: destination,
                        selected: destination == current,
                        // The workspace needs a build to open, and says so
                        // instead of pretending to be available.
                        enabled: destination != AppDestination.execution ||
                            onOpenWorkspace != null,
                        onTap: () => onSelect(destination),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppTheme.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PlanCard(
                    project: planProject,
                    summary: planSummary,
                    target: planTarget,
                    onOpen: onOpenWorkspace,
                  ),
                  const SizedBox(height: AppTheme.s10),
                  Row(
                    children: [
                      Expanded(
                        child: _SidebarAction(
                          icon: Icons.calculate_outlined,
                          label: 'Network toolkit',
                          tooltip: 'Network toolkit',
                          onTap: onToolkit,
                        ),
                      ),
                      const SizedBox(width: AppTheme.s6),
                      const _EngineDot(),
                    ],
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

/// "All features": the one button that reaches everything not on this list.
/// It looks like a search field because that is how it behaves (Ctrl+K).
class _HubButton extends StatelessWidget {
  final VoidCallback onTap;

  const _HubButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.35)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s10,
            vertical: AppTheme.s10,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            border: Border.all(color: AppPalette.hairline(scheme)),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppTheme.s8),
              Expanded(
                child: Text(
                  'All features',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                'Ctrl K',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One destination: icon, name, and (when it is the open screen) an accent
/// bar so the current place is unmistakable.
class _SidebarTile extends StatelessWidget {
  final AppDestination destination;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : (selected ? scheme.primary : scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s10,
              vertical: AppTheme.s8,
            ),
            child: Row(
              children: [
                Icon(destination.icon, size: 17, color: color),
                const SizedBox(width: AppTheme.s10),
                Expanded(
                  child: Text(
                    destination.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Container(
                    width: 3,
                    height: 16,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The open plan: the one piece of state that changes what the app can do.
class _PlanCard extends StatelessWidget {
  final String project;
  final String summary;
  final String target;
  final VoidCallback? onOpen;

  const _PlanCard({
    required this.project,
    required this.summary,
    required this.target,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPlan = project.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(AppTheme.s10),
      decoration: BoxDecoration(
        color: hasPlan
            ? AppPalette.tone(scheme, AppTone.accent).fill
            : AppPalette.panelAlt(scheme),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(
          color: hasPlan
              ? AppPalette.tone(scheme, AppTone.accent).border
              : AppPalette.hairline(scheme),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasPlan ? Icons.account_tree_outlined : Icons.inbox_outlined,
                size: 14,
                color: hasPlan ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppTheme.s6),
              Expanded(
                child: Text(
                  hasPlan ? project : 'No open plan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: hasPlan ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.s4),
          Text(
            hasPlan
                ? [summary, if (target.trim().isNotEmpty) target]
                      .where((s) => s.trim().isNotEmpty)
                      .join(' - ')
                : 'Describe a network in the chat and it appears here.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (hasPlan && onOpen != null) ...[
            const SizedBox(height: AppTheme.s8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onOpen,
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('Open workspace'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s10,
                  ),
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A labelled action for the sidebar's footer.
class _SidebarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  const _SidebarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s8,
              vertical: AppTheme.s8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppTheme.s6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The engine's state as a single dot, with the name in the tooltip: the
/// sidebar has no room for a sentence, and the app bar already carries one.
class _EngineDot extends StatelessWidget {
  const _EngineDot();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: EngineStatus.instance,
      builder: (context, _) {
        final phase = EngineStatus.instance.phase;
        final (color, label) = switch (phase) {
          EngineState.up => (AppPalette.success(scheme), 'Engine up'),
          EngineState.down => (scheme.error, 'Engine down'),
          EngineState.checking ||
          EngineState.starting => (AppPalette.warning(scheme), 'Engine starting'),
          EngineState.unknown => (scheme.onSurfaceVariant, 'Engine not checked'),
        };
        return Tooltip(
          message: label,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s8),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 5),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The compact rail for medium windows: the same destinations with their
/// names under the icons, so "reachable by name" survives a narrower screen.
class AppRail extends StatelessWidget {
  final AppDestination current;
  final ValueChanged<AppDestination> onSelect;
  final VoidCallback onHub;
  final VoidCallback onToolkit;
  final bool hasPlan;

  const AppRail({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onHub,
    required this.onToolkit,
    this.hasPlan = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 92,
      child: Material(
        color: AppPalette.panel(scheme),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s12,
                AppTheme.s16,
                AppTheme.s12,
                AppTheme.s8,
              ),
              child: Column(
                children: [
                  const AppBrandMark(size: 32),
                  const SizedBox(height: AppTheme.s8),
                  _RailAction(
                    icon: Icons.search,
                    label: 'All features',
                    onTap: onHub,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  vertical: AppTheme.s8,
                  horizontal: AppTheme.s6,
                ),
                child: Column(
                  children: [
                    for (final destination in AppDestination.alwaysAvailable)
                      _RailAction(
                        icon: destination.icon,
                        label: destination.title,
                        selected: destination == current,
                        onTap: () => onSelect(destination),
                      ),
                    if (hasPlan)
                      _RailAction(
                        icon: AppDestination.execution.icon,
                        label: AppDestination.execution.title,
                        selected: current == AppDestination.execution,
                        onTap: () => onSelect(AppDestination.execution),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.s6,
                vertical: AppTheme.s8,
              ),
              child: _RailAction(
                icon: Icons.calculate_outlined,
                label: 'Network toolkit',
                onTap: onToolkit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  const _RailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s4,
              vertical: AppTheme.s8,
            ),
            child: Column(
              children: [
                Icon(icon, size: 19, color: color),
                const SizedBox(height: AppTheme.s4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
