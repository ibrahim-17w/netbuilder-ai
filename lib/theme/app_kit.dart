import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'app_theme.dart';

/// The app's component kit.
///
/// Every screen is assembled from these pieces instead of from raw `Card` +
/// `Padding` + `Text` stacks. That is what makes "redesign the app" a task
/// that stays done: a panel, a banner, a metric and a list row have one
/// implementation each, so the spacing, the hairline and the type all move
/// together when the design language moves.
///
/// Nothing here talks to a service. These are pure presentation widgets.

// ---------------------------------------------------------------------------
// Page frame
// ---------------------------------------------------------------------------

/// A page's frame: gutter, measure and optional header, so every screen's
/// content starts at the same left edge and stops at the same width.
///
/// [children] are laid out in a column inside a scroll view (unless
/// [scroll] is false, for a screen that owns its own scrolling list).
class AppPage extends StatelessWidget {
  final List<Widget> children;
  final Widget? header;

  /// Pinned above the scrolling content (search fields, filter strips).
  final Widget? toolbar;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final bool scroll;
  final CrossAxisAlignment crossAxisAlignment;

  const AppPage({
    super.key,
    this.children = const [],
    this.header,
    this.toolbar,
    this.maxWidth = AppTheme.wideMeasure,
    this.padding,
    this.controller,
    this.scroll = true,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  @override
  Widget build(BuildContext context) {
    final gutter = AppTheme.gutter(context);
    final body = Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        if (header != null) ...[header!, const SizedBox(height: AppTheme.s18)],
        ...children,
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?toolbar,
        Expanded(
          child: scroll
              ? SingleChildScrollView(
                  controller: controller,
                  padding:
                      padding ??
                      EdgeInsets.fromLTRB(
                        gutter,
                        AppTheme.s20,
                        gutter,
                        AppTheme.s32,
                      ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: body,
                    ),
                  ),
                )
              : Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: body,
                ),
        ),
      ],
    );
  }
}

/// The first thing on a screen: what it is, and the controls that act on the
/// whole screen. The eyebrow is the section of the app ("Plan", "Inspect");
/// the title is the screen; the description is the promise it makes.
class AppPageHeader extends StatelessWidget {
  final String title;
  final String? description;
  final String? eyebrow;
  final IconData? icon;
  final List<Widget> actions;
  final Widget? trailing;

  const AppPageHeader({
    super.key,
    required this.title,
    this.description,
    this.eyebrow,
    this.icon,
    this.actions = const [],
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null && eyebrow!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s6),
            child: Text(
              eyebrow!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                letterSpacing: 1.2,
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              AppIconBubble(icon: icon!, tone: AppTone.accent, size: 38),
              const SizedBox(width: AppTheme.s12),
            ],
            Flexible(
              child: Text(
                title,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppTheme.s10),
              trailing!,
            ],
          ],
        ),
        if (description != null && description!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.readingMeasure,
              ),
              child: Text(
                description!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
    if (actions.isEmpty) return head;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The actions sit beside the title when there is room and below it
        // when there is not - a header that clips its own buttons is the
        // most common way a "responsive" screen is not one.
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: head),
              const SizedBox(width: AppTheme.s16),
              Wrap(
                spacing: AppTheme.s8,
                runSpacing: AppTheme.s8,
                alignment: WrapAlignment.end,
                children: actions,
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            head,
            const SizedBox(height: AppTheme.s14),
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: actions,
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------------

/// The standard surface: an optional header (icon, title, subtitle, trailing
/// controls) over a body. Everything that used to be a bare `Card` with a
/// hand-built column is one of these.
class AppPanel extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final Widget? child;
  final List<Widget> children;
  final AppTone tone;

  /// A tinted panel is for a *state* (a warning, a success), not for
  /// decoration: it is how the eye finds the one thing that is different.
  final bool filled;
  final bool dense;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool framed;

  const AppPanel({
    super.key,
    this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.actions = const [],
    this.child,
    this.children = const [],
    this.tone = AppTone.neutral,
    this.filled = false,
    this.dense = false,
    this.padding,
    this.onTap,
    this.framed = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppPalette.tone(scheme, tone);
    final hasHeader =
        title != null || leading != null || trailing != null || actions.isNotEmpty;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasHeader) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null)
                Padding(
                  padding: const EdgeInsets.only(right: AppTheme.s10),
                  child: leading,
                )
              else if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: AppTheme.s10),
                  child: AppIconBubble(
                    icon: icon!,
                    tone: tone == AppTone.neutral ? AppTone.accent : tone,
                    size: dense ? 28 : 32,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(
                        title!,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: tone == AppTone.neutral
                              ? scheme.onSurface
                              : colors.fg,
                        ),
                      ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (actions.isNotEmpty)
                Wrap(
                  spacing: AppTheme.s4,
                  runSpacing: AppTheme.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppTheme.s12),
        ],
        ?child,
        ...children,
      ],
    );
    final content = Padding(
      padding:
          padding ??
          EdgeInsets.all(dense ? AppTheme.s12 : AppTheme.s16),
      child: body,
    );
    // The panel is a Material, not a decorated Container: a ListTile inside a
    // coloured box paints its ink on the nearest Material ancestor, and when
    // that ancestor is *outside* the coloured box the splash is invisible (and
    // Flutter asserts about it).
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTheme.rLg),
      side: framed
          ? BorderSide(
              color: filled ? colors.border : AppPalette.hairline(scheme),
            )
          : BorderSide.none,
    );
    final surface = Material(
      color: filled ? colors.fill : AppPalette.panel(scheme),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, child: content),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s12),
      child: surface,
    );
  }
}

/// A row inside a panel: leading bubble, title, one line of support, and
/// whatever the row does. Used by the files list, the hub, the memory lists -
/// anywhere a person scans a column of similar things.
class AppRowTile extends StatelessWidget {
  final Widget? leading;
  final IconData? icon;
  final AppTone tone;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> badges;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;

  const AppRowTile({
    super.key,
    this.leading,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.badges = const [],
    this.onTap,
    this.tone = AppTone.accent,
    this.selected = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? AppTheme.s10 : AppTheme.s12,
        vertical: dense ? AppTheme.s8 : AppTheme.s10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null)
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.s10),
              child: leading,
            )
          else if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.s10),
              child: AppIconBubble(icon: icon!, tone: tone, size: dense ? 28 : 32),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppTheme.s6,
                  runSpacing: AppTheme.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    ...badges,
                  ],
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppTheme.s8),
            trailing!,
          ],
        ],
      ),
    );
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banners, badges, metrics
// ---------------------------------------------------------------------------

/// One message, with a meaning. Replaces the hand-rolled coloured boxes that
/// every screen used to build (and get subtly different).
class AppBanner extends StatelessWidget {
  final AppTone tone;
  final String? title;
  final String message;
  final IconData? icon;
  final List<Widget> actions;
  final Widget? trailing;
  final bool dense;

  const AppBanner({
    super.key,
    required this.message,
    this.tone = AppTone.info,
    this.title,
    this.icon,
    this.actions = const [],
    this.trailing,
    this.dense = false,
  });

  static IconData _fallbackIcon(AppTone tone) => switch (tone) {
    AppTone.success => Icons.check_circle_outline,
    AppTone.warning => Icons.warning_amber_rounded,
    AppTone.danger => Icons.error_outline,
    AppTone.accent => Icons.tips_and_updates_outlined,
    AppTone.info || AppTone.neutral => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppPalette.tone(scheme, tone);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s12),
      child: Container(
        padding: EdgeInsets.all(dense ? AppTheme.s10 : AppTheme.s12),
        decoration: BoxDecoration(
          color: colors.fill,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon ?? _fallbackIcon(tone), size: 18, color: colors.fg),
            const SizedBox(width: AppTheme.s10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null && title!.trim().isNotEmpty) ...[
                    Text(
                      title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      height: 1.5,
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: AppTheme.s10),
                    Wrap(
                      spacing: AppTheme.s8,
                      runSpacing: AppTheme.s8,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppTheme.s8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A small pill. Same shape for statuses, counts and targets, so a row of
/// them reads as one vocabulary rather than five.
class AppTag extends StatelessWidget {
  final String label;
  final AppTone tone;
  final IconData? icon;
  final bool mono;

  const AppTag({
    super.key,
    required this.label,
    this.tone = AppTone.neutral,
    this.icon,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppPalette.tone(theme.colorScheme, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colors.fg),
            const SizedBox(width: AppTheme.s4),
          ],
          // Flexible + ellipsis, so a long tag inside a squeezed header row
          // shortens instead of overflowing it.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.fg,
                letterSpacing: mono ? 0.2 : 0.5,
                fontFamily: mono ? AppTheme.monoFont : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded-square icon holder. The app's "bullet" - it makes a list of
/// anything scannable by shape and colour before a word is read.
class AppIconBubble extends StatelessWidget {
  final IconData icon;
  final AppTone tone;
  final double size;
  final bool outlined;

  const AppIconBubble({
    super.key,
    required this.icon,
    this.tone = AppTone.accent,
    this.size = 32,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.tone(Theme.of(context).colorScheme, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.fill,
        borderRadius: BorderRadius.circular(size * 0.34),
        border: outlined ? Border.all(color: colors.border) : null,
      ),
      child: Icon(icon, size: size * 0.55, color: colors.fg),
    );
  }
}

/// One number that matters, with its label. The building block of the
/// dashboard strips (history, engine, audit summaries).
class AppMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final AppTone tone;
  final String? hint;
  final VoidCallback? onTap;

  const AppMetric({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.tone = AppTone.accent,
    this.hint,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppPalette.tone(scheme, tone);
    return Material(
      color: AppPalette.panelAlt(scheme),
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s12,
            vertical: AppTheme.s10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: colors.fg),
                    const SizedBox(width: AppTheme.s6),
                  ],
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.s6),
              Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colors.fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (hint != null && hint!.trim().isNotEmpty)
                Text(
                  hint!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A responsive strip of [AppMetric]s: one row on a desktop, two columns on
/// a phone, never a clipped card.
class AppMetricGrid extends StatelessWidget {
  final List<AppMetric> metrics;
  final double minTileWidth;

  const AppMetricGrid({
    super.key,
    required this.metrics,
    this.minTileWidth = 150,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / minTileWidth).floor().clamp(1, 4);
        const gap = AppTheme.s8;
        final tileWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final metric in metrics)
              SizedBox(width: tileWidth, child: metric),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbars and inputs
// ---------------------------------------------------------------------------

/// A strip of controls at the top of a page: search on one side, filters and
/// actions on the other. Wraps instead of overflowing.
class AppToolbar extends StatelessWidget {
  final Widget? leading;
  final Widget? search;
  final List<Widget> filters;
  final List<Widget> actions;
  final String? count;

  const AppToolbar({
    super.key,
    this.leading,
    this.search,
    this.filters = const [],
    this.actions = const [],
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppTheme.gutter(context),
        vertical: AppTheme.s10,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppPalette.hairline(theme.colorScheme))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final searchField = search;
          final leadingField = leading;
          // AppToolbar does the flexing, never the caller: a `Flexible` passed
          // in here would sit inside another one and Flutter refuses two
          // ParentDataWidgets on one render object.
          final left = <Widget>[
            if (leadingField != null) Flexible(child: leadingField),
            if (searchField != null) Flexible(child: searchField),
          ];
          final narrowLeft = <Widget>[
            if (leadingField != null) Expanded(child: leadingField),
            if (searchField != null) Expanded(child: searchField),
          ];
          final right = <Widget>[
            ...filters,
            ...actions,
            if (count != null)
              Padding(
                padding: const EdgeInsets.only(left: AppTheme.s4),
                child: Text(
                  count!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ];
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < narrowLeft.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppTheme.s8),
                      narrowLeft[i],
                    ],
                  ],
                ),
                if (right.isNotEmpty) ...[
                  const SizedBox(height: AppTheme.s8),
                  Wrap(
                    spacing: AppTheme.s8,
                    runSpacing: AppTheme.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: right,
                  ),
                ],
              ],
            );
          }
          return Row(
            children: [
              ...left,
              if (left.isEmpty) const SizedBox.shrink() else const Spacer(),
              Wrap(
                spacing: AppTheme.s8,
                runSpacing: AppTheme.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: right,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The app's search input. One look everywhere: a magnifier, a clear button
/// when there is text, and no surprises.
class AppSearchField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final String? label;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? trailing;

  const AppSearchField({
    super.key,
    this.controller,
    this.hint = 'Search',
    this.label,
    this.onChanged,
    this.onClear,
    this.onSubmitted,
    this.autofocus = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final value = controller?.text ?? '';
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: trailing ??
            (value.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      controller?.clear();
                      onClear?.call();
                      onChanged?.call('');
                    },
                  )),
      ),
    );
  }
}

/// A labelled control block: one control per row, with its explanation
/// underneath where the user is looking.
class AppField extends StatelessWidget {
  final String label;
  final String? help;
  final Widget child;

  const AppField({
    super.key,
    required this.label,
    required this.child,
    this.help,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppTheme.s6),
          child,
          if (help != null && help!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.s6),
              child: Text(
                help!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Code & logs
// ---------------------------------------------------------------------------

/// A console surface for configs, JSON and logs: monospace on a dark inset
/// that stays dark in both themes, because that is what a terminal looks
/// like and because a wall of commands should not read as prose.
class AppCodeBlock extends StatelessWidget {
  final String text;
  final String? title;
  final double maxHeight;
  final String emptyText;
  final bool copyable;
  final bool compact;
  final Widget? trailing;

  const AppCodeBlock({
    super.key,
    required this.text,
    this.title,
    this.maxHeight = 320,
    this.emptyText = 'Nothing yet.',
    this.copyable = true,
    this.compact = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasText = text.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.console(scheme),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || copyable || trailing != null)
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s12,
                AppTheme.s6,
                AppTheme.s4,
                AppTheme.s6,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal_outlined,
                    size: 14,
                    color: AppPalette.consoleText(scheme).withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: AppTheme.s8),
                  Expanded(
                    child: Text(
                      title ?? 'Output',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppPalette.consoleText(scheme).withValues(alpha: 0.75),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  ?trailing,
                  if (copyable)
                    IconButton(
                      tooltip: 'Copy',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      color: AppPalette.consoleText(scheme).withValues(alpha: 0.75),
                      icon: const Icon(Icons.copy_all_outlined),
                      onPressed: hasText
                          ? () async {
                              await Clipboard.setData(ClipboardData(text: text));
                              if (!context.mounted) return;
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(content: Text('Copied')),
                              );
                            }
                          : null,
                    ),
                ],
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? AppTheme.s10 : AppTheme.s12),
              child: SelectableText(
                hasText ? text : emptyText,
                style: AppTheme.mono(context).copyWith(
                  color: hasText
                      ? AppPalette.consoleText(scheme)
                      : AppPalette.consoleText(scheme).withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// A stepper for the flows that really are a sequence (plan -> review ->
/// build). Steps already passed are tappable, later ones are not: the wizard
/// shows where you are without letting you skip it.
class AppSteps extends StatelessWidget {
  final List<AppStep> steps;
  final int current;
  final ValueChanged<int>? onSelect;

  const AppSteps({
    super.key,
    required this.steps,
    required this.current,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: AppTheme.s8,
      runSpacing: AppTheme.s8,
      children: [
        for (var i = 0; i < steps.length; i++)
          _StepChip(
            index: i,
            step: steps[i],
            state: i == current
                ? _StepState.current
                : (i < current ? _StepState.done : _StepState.todo),
            onTap: onSelect == null
                ? null
                : (i <= current ? () => onSelect!(i) : null),
            primary: scheme.primary,
            theme: theme,
          ),
      ],
    );
  }
}

enum _StepState { done, current, todo }

class AppStep {
  final String title;
  final String? subtitle;
  const AppStep(this.title, {this.subtitle});
}

class _StepChip extends StatelessWidget {
  final int index;
  final AppStep step;
  final _StepState state;
  final VoidCallback? onTap;
  final Color primary;
  final ThemeData theme;

  const _StepChip({
    required this.index,
    required this.step,
    required this.state,
    required this.onTap,
    required this.primary,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final active = state != _StepState.todo;
    final color = state == _StepState.current
        ? primary
        : (state == _StepState.done ? scheme.onSurface : scheme.onSurfaceVariant);
    return Material(
      color: state == _StepState.current
          ? primary.withValues(alpha: 0.12)
          : (state == _StepState.done
                ? AppPalette.panelAlt(scheme)
                : Colors.transparent),
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s12,
            vertical: AppTheme.s8,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            border: Border.all(
              color: state == _StepState.current
                  ? primary.withValues(alpha: 0.4)
                  : AppPalette.hairline(scheme),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? color.withValues(alpha: 0.16) : Colors.transparent,
                  border: Border.all(
                    color: active ? color.withValues(alpha: 0.5) : scheme.outlineVariant,
                  ),
                ),
                child: Center(
                  child: state == _StepState.done
                      ? Icon(Icons.check, size: 12, color: color)
                      : Text(
                          '${index + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: color,
                            letterSpacing: 0,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: AppTheme.s8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    step.title,
                    style: theme.textTheme.labelLarge?.copyWith(color: color),
                  ),
                  if (step.subtitle != null)
                    Text(
                      step.subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Brand
// ---------------------------------------------------------------------------

/// The logo mark: a gradient tile with the network glyph. One implementation,
/// used by the sidebar, the welcome screen and the first-run tour.
class AppBrandMark extends StatelessWidget {
  final double size;
  final bool showWordmark;
  final String wordmark;

  const AppBrandMark({
    super.key,
    this.size = 34,
    this.showWordmark = false,
    this.wordmark = 'NetBuilder',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          colors: AppPalette.brandGradient(scheme),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.28),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Icon(
        Icons.lan_outlined,
        size: size * 0.56,
        color: Colors.white,
      ),
    );
    if (!showWordmark) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: AppTheme.s10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                wordmark,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                'Network builder AI',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A hairline divider with optional centred label, for grouping inside a
/// panel without another card.
class AppDivider extends StatelessWidget {
  final String? label;
  final double space;

  const AppDivider({super.key, this.label, this.space = AppTheme.s12});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Expanded(
      child: Divider(color: AppPalette.hairline(theme.colorScheme), height: 1),
    );
    if (label == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: space),
        child: Divider(color: AppPalette.hairline(theme.colorScheme), height: 1),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: space),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8),
            child: Text(
              label!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          line,
        ],
      ),
    );
  }
}
