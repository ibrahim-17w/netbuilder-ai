import 'package:flutter/material.dart';

import 'app_palette.dart';

/// The app's design language in one place.
///
/// Before this existed the look was assembled per screen: each `Card` chose
/// its own margin, each button its own padding, and the result read as a
/// prototype. Everything visual now comes from here, so a change to the
/// spacing scale or the corner radius moves the whole app together.
///
/// The character is deliberate: calm surfaces, one accent, generous line
/// height, and no decoration competing with the text. This is an app that is
/// read for long stretches - a config, a fault list, a conversation - so the
/// typography and the measure matter more than the chrome.
///
/// ## The second pass
///
/// The palette was re-tuned to a cooler, layered set of surfaces: a canvas,
/// a panel, an inset and a console, each a real step apart in both themes, so
/// a screen reads as a stack of panels instead of one flat sheet of cards.
/// The type scale was tightened (fewer, better-differentiated steps), the
/// corner radii aligned to one scale, and every component theme was given a
/// consistent geometry: 40px controls, 10-14px radii, hairline borders and
/// focus rings that are visible from across the room.
class AppTheme {
  const AppTheme._();

  // --- the scales ---------------------------------------------------------

  /// 4-point spacing scale. Named sizes rather than naked numbers, so two
  /// screens that mean "the same gap" cannot drift apart.
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s18 = 18;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;

  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 22;

  /// The reading measure for prose: ~66 characters at 14px. Long answers are
  /// the main thing this app displays, and a full-width line of text on a
  /// desktop is genuinely harder to read.
  static const double readingMeasure = 680;

  /// Widest the app's content column is allowed to grow.
  static const double wideMeasure = 1160;

  /// The standard page gutter: 20 on a desktop, less on a phone. Every
  /// screen's `AppPage` uses this, so the left edge of the header, the
  /// panels and the footer line up in every screen of the app.
  static double gutter(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 640 ? s16 : s24;

  /// One accent, chosen so it is readable on light and dark surfaces.
  static const Color seed = Color(0xFF3B5BDB);

  /// The monospace face every config, log and identifier uses. Named once so
  /// a console block in the toolkit and one in the chat cannot differ.
  static const String monoFont = 'monospace';

  static TextStyle mono(BuildContext context, {double size = 12.5}) =>
      TextStyle(
        fontFamily: monoFont,
        fontSize: size,
        height: 1.5,
        color: Theme.of(context).colorScheme.onSurface,
      );

  // --- the themes ---------------------------------------------------------

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = _scheme(brightness);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    final text = base.textTheme
        .apply(
          bodyColor: dark ? const Color(0xFFDDE3EC) : const Color(0xFF1A1D26),
          displayColor: dark ? const Color(0xFFF3F6FA) : const Color(0xFF0F1219),
        )
        .copyWith(
          // Fewer sizes, further apart: an eyebrow, a section, a panel title
          // and body text must be tellable apart at a glance.
          displaySmall: TextStyle(
            fontSize: 30,
            height: 1.18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
          headlineSmall: TextStyle(
            fontSize: 23,
            height: 1.22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          titleLarge: TextStyle(
            fontSize: 18.5,
            height: 1.3,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
          titleMedium: TextStyle(
            fontSize: 15.5,
            height: 1.35,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          titleSmall: TextStyle(
            fontSize: 13.5,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: TextStyle(fontSize: 14.5, height: 1.55),
          bodyMedium: TextStyle(fontSize: 13.5, height: 1.5),
          bodySmall: TextStyle(fontSize: 12, height: 1.45),
          labelLarge: TextStyle(
            fontSize: 13,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
          labelMedium: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          labelSmall: TextStyle(
            fontSize: 10.5,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        );

    final hairline = scheme.outlineVariant.withValues(alpha: dark ? 0.8 : 0.7);

    return base.copyWith(
      scaffoldBackgroundColor: AppPalette.canvas(scheme),
      canvasColor: AppPalette.canvas(scheme),
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      textTheme: text,
      extensions: const <ThemeExtension<dynamic>>[],
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: AppPalette.canvas(scheme),
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: s16,
        titleTextStyle: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
        ),
        // A single hairline instead of a shadow: the bar is a boundary, not
        // a floating thing.
        shape: Border(bottom: BorderSide(color: hairline)),
        toolbarHeight: 60,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: AppPalette.panel(scheme),
        // A whisper of depth on light surfaces only: shadows on dark read as
        // smudges, so the dark theme separates with borders alone.
        elevation: dark ? 0 : 1,
        shadowColor: dark ? Colors.transparent : const Color(0x14303A55),
        margin: const EdgeInsets.symmetric(vertical: s6),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLg),
          side: BorderSide(color: hairline),
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        space: 1,
        thickness: 1,
        color: hairline,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: true,
        filled: true,
        fillColor: dark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.32)
            : scheme.surfaceContainerLow,
        hintStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: text.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        helperStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: s12,
          vertical: s12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: hairline),
        ),
        // A visible focus ring, required for keyboard-only use.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: s18, vertical: s12),
          minimumSize: const Size(0, 40),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMd),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: s16, vertical: s12),
          minimumSize: const Size(0, 40),
          side: BorderSide(color: hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMd),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: s10, vertical: s8),
          minimumSize: const Size(0, 34),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rSm),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rSm),
          ),
        ),
      ),
      iconTheme: base.iconTheme.copyWith(
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: hairline),
        backgroundColor: dark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.28)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
        labelStyle: text.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: s8, vertical: s4),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: s16,
          vertical: s2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
        minVerticalPadding: s10,
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        subtitleTextStyle: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: AppPalette.panel(scheme),
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rXl),
          side: BorderSide(color: hairline),
        ),
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: AppPalette.panel(scheme),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.30),
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rXl)),
        ),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        insetPadding: const EdgeInsets.all(s16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLg),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primary.withValues(alpha: 0.14),
          selectedForegroundColor: scheme.primary,
          foregroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMd),
          ),
          textStyle: text.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: s12, vertical: s10),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(5),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 4,
        showValueIndicator: ShowValueIndicator.never,
      ),
      tabBarTheme: base.tabBarTheme.copyWith(
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        dividerColor: hairline,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 2),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(2),
          ),
        ),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        backgroundColor: AppPalette.panel(scheme),
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelType: NavigationRailLabelType.all,
        useIndicator: true,
      ),
      tooltipTheme: base.tooltipTheme.copyWith(
        waitDuration: const Duration(milliseconds: 450),
        showDuration: const Duration(seconds: 6),
        textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(rSm),
        ),
      ),
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
        color: scheme.primary,
        linearMinHeight: 3,
        borderRadius: BorderRadius.circular(999),
      ),
      scrollbarTheme: base.scrollbarTheme.copyWith(
        thickness: const WidgetStatePropertyAll(9),
        radius: const Radius.circular(999),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurface.withValues(alpha: 0.18),
        ),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        color: AppPalette.panel(scheme),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
          side: BorderSide(color: hairline),
        ),
        textStyle: text.bodyMedium,
      ),
      dropdownMenuTheme: base.dropdownMenuTheme.copyWith(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppPalette.panel(scheme)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rMd),
              side: BorderSide(color: hairline),
            ),
          ),
        ),
      ),
      expansionTileTheme: base.expansionTileTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
        textColor: scheme.onSurface,
        collapsedTextColor: scheme.onSurface,
        iconColor: scheme.onSurfaceVariant,
        collapsedIconColor: scheme.onSurfaceVariant,
      ),
      badgeTheme: base.badgeTheme.copyWith(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        textStyle: text.labelSmall,
      ),
      bannerTheme: base.bannerTheme.copyWith(
        backgroundColor: AppPalette.tone(scheme, AppTone.info).fill,
        contentTextStyle: text.bodyMedium,
      ),
    );
  }

  /// The colour scheme. Built from [seed] so the brand hue stays the source
  /// of truth, then given explicit surface tiers: a canvas, a panel, an inset
  /// and an outline. Material's generated greys are close enough to each other
  /// that a card on a card looked like one card; these steps are visible.
  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    if (!dark) {
      return base.copyWith(
        surface: const Color(0xFFF5F7FB),
        onSurface: const Color(0xFF161A22),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFFBFCFE),
        surfaceContainer: const Color(0xFFF1F3F8),
        surfaceContainerHigh: const Color(0xFFE9ECF4),
        surfaceContainerHighest: const Color(0xFFE0E4EF),
        onSurfaceVariant: const Color(0xFF5A6273),
        outline: const Color(0xFF8C94A6),
        outlineVariant: const Color(0xFFDCE0EB),
        primary: const Color(0xFF3452CC),
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFDEE5FF),
        onPrimaryContainer: const Color(0xFF17265E),
        tertiary: const Color(0xFF0E7490),
        tertiaryContainer: const Color(0xFFCDEDF6),
        onTertiaryContainer: const Color(0xFF07333F),
      );
    }
    return base.copyWith(
      surface: const Color(0xFF11141A),
      onSurface: const Color(0xFFE2E7EF),
      surfaceContainerLowest: const Color(0xFF0D1015),
      surfaceContainerLow: const Color(0xFF151922),
      surfaceContainer: const Color(0xFF1A1F29),
      surfaceContainerHigh: const Color(0xFF20262F),
      surfaceContainerHighest: const Color(0xFF28303B),
      onSurfaceVariant: const Color(0xFFA4AEBF),
      outline: const Color(0xFF6B7486),
      outlineVariant: const Color(0xFF2C3441),
      primary: const Color(0xFF9DB4FF),
      onPrimary: const Color(0xFF10204F),
      primaryContainer: const Color(0xFF24356F),
      onPrimaryContainer: const Color(0xFFDCE4FF),
      tertiary: const Color(0xFF6FD3E8),
      tertiaryContainer: const Color(0xFF16414D),
      onTertiaryContainer: const Color(0xFFC9F0F9),
      error: const Color(0xFFFFB4AB),
      onError: const Color(0xFF690005),
    );
  }
}

/// A titled section, so screens do not each invent their own heading style.
///
/// The eyebrow treatment (small, letterspaced, accent-coloured) is what makes
/// a long screen scannable: it reads as a label *above* the content rather
/// than as another paragraph in it.
class AppSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  const AppSection({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        letterSpacing: 1.0,
                      ),
                    ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppTheme.s10),
          ...children,
        ],
      ),
    );
  }
}

/// A one-line status strip: dot, label, detail. Used for engine health, run
/// state and probe results so they all read the same way.
class AppStatusPill extends StatelessWidget {
  final String label;
  final String detail;
  final bool ok;
  final bool warn;
  final Widget? trailing;

  /// An explicit meaning, when the caller has one (a run that was corrected
  /// is "warning", not merely "not ok"). [ok]/[warn] still work so no caller
  /// had to change.
  final AppTone? tone;

  const AppStatusPill({
    super.key,
    required this.label,
    this.detail = '',
    this.ok = true,
    this.warn = false,
    this.tone,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppPalette.tone(
      scheme,
      tone ?? (warn ? AppTone.danger : (ok ? AppTone.success : AppTone.info)),
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s10,
        vertical: AppTheme.s6,
      ),
      decoration: BoxDecoration(
        color: colors.fill,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: colors.fg,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: colors.fg.withValues(alpha: 0.5),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.s8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.fg,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: AppTheme.s6),
            Flexible(
              child: Text(
                detail,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppTheme.s6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// The explainer block that opens a screen: what this screen does, and the
/// promise it makes. The fill comes from [AppPalette] rather than a picked
/// pastel, because a hand-written light fill carries the theme's text colour
/// with it and becomes an empty box the moment the theme flips.
class AppNoticeCard extends StatelessWidget {
  final String text;
  final Color? fill;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;

  const AppNoticeCard({
    super.key,
    required this.text,
    this.fill,
    this.style,
    this.padding = const EdgeInsets.all(AppTheme.s12),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: fill ?? AppPalette.tone(scheme, AppTone.info).fill,
      child: Padding(
        padding: padding,
        child: Text(text, style: style),
      ),
    );
  }
}

/// A status line that changes on its own while the user is looking
/// somewhere else - a run in progress, an analysis, a long log.
///
/// Without [Semantics.liveRegion] that text is only read when the user
/// happens to move focus onto it, which for a line that updates every two
/// seconds is the same as never being read.
class AppLiveText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const AppLiveText({super.key, required this.text, this.style});

  @override
  Widget build(BuildContext context) {
    return Semantics(liveRegion: true, child: Text(text, style: style));
  }
}

/// The empty state every screen uses: an icon, a headline, a sentence and
/// the buttons that get the user out of the empty state.
///
/// [danger] is for the state that is NOT empty: a read that failed. It is the
/// same layout in the error colour, because "there is nothing here" and "I
/// could not look" are different facts and must not look the same.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;
  final bool danger;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body = '',
    this.actions = const [],
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = danger ? AppTone.danger : AppTone.accent;
    final colors = AppPalette.tone(theme.colorScheme, tone);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.readingMeasure),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(AppTheme.s16),
                decoration: BoxDecoration(
                  color: colors.fill,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.border),
                ),
                child: Icon(icon, size: 30, color: colors.fg),
              ),
              const SizedBox(height: AppTheme.s16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (body.trim().isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s20),
                Wrap(
                  spacing: AppTheme.s10,
                  runSpacing: AppTheme.s10,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A key/value row for the "here is exactly what I understood" panels, which
/// appear in the analysis, the toolkit and the plan review.
class AppKeyValue extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;

  const AppKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.s8),
          Expanded(
            child: SelectableText(
              value,
              style:
                  (mono
                          ? theme.textTheme.bodySmall?.copyWith(
                              fontFamily: AppTheme.monoFont,
                            )
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
