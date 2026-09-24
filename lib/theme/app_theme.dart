import 'package:flutter/material.dart';

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

  /// One accent, chosen so it is readable on light and dark surfaces.
  static const Color seed = Color(0xFF3B5BDB);

  // --- the themes ---------------------------------------------------------

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    // Surfaces: the light theme is a hair cooler than the M3 default, which
    // stops a full screen of cards from looking yellow next to a screenshot
    // of Packet Tracer.
    final surface = dark ? const Color(0xFF14161A) : const Color(0xFFFBFBFD);
    final surfaceRaised = dark
        ? const Color(0xFF1B1E24)
        : Colors.white;

    final text = base.textTheme.apply(
      bodyColor: dark ? const Color(0xFFE6E8EC) : const Color(0xFF1B1F24),
      displayColor: dark ? const Color(0xFFF2F4F8) : const Color(0xFF12161B),
    );

    return base.copyWith(
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      textTheme: text.copyWith(
        displaySmall: text.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          height: 1.2,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
          height: 1.25,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.5),
        bodySmall: text.bodySmall?.copyWith(height: 1.45),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        titleSpacing: s16,
        titleTextStyle: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
        ),
        toolbarHeight: 58,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: surfaceRaised,
        // A whisper of depth on light surfaces only: shadows on dark read as
        // smudges, so the dark theme separates with borders alone.
        elevation: dark ? 0 : 1.5,
        margin: const EdgeInsets.symmetric(vertical: s6),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLg),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: dark ? 0.7 : 0.5),
          ),
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: true,
        filled: true,
        fillColor: dark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
        hintStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: s12,
          vertical: s12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
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
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMd),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: s10, vertical: s8),
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
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
        labelStyle: text.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: s8, vertical: s4),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: s16, vertical: s2),
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
        backgroundColor: surfaceRaised,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rXl),
        ),
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: surfaceRaised,
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMd),
          ),
          textStyle: text.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: s12, vertical: s10),
        ),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        backgroundColor: surfaceRaised,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelType: NavigationRailLabelType.all,
        useIndicator: true,
      ),
      tooltipTheme: base.tooltipTheme.copyWith(
        waitDuration: const Duration(milliseconds: 500),
        showDuration: const Duration(seconds: 6),
        textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(rSm),
        ),
      ),
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
        color: scheme.primary,
        linearMinHeight: 2,
      ),
      scrollbarTheme: base.scrollbarTheme.copyWith(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(999),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
      ),
      expansionTileTheme: base.expansionTileTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMd),
        ),
      ),
    );
  }
}

/// A titled section, so screens do not each invent their own heading style.
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
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
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

  const AppStatusPill({
    super.key,
    required this.label,
    this.detail = '',
    this.ok = true,
    this.warn = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = warn
        ? scheme.error
        : ok
        ? const Color(0xFF2E7D32)
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s10,
        vertical: AppTheme.s6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppTheme.s8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
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

/// The empty state every screen uses: an icon, a headline, a sentence and
/// the buttons that get the user out of the empty state.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body = '',
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: theme.colorScheme.primary),
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

  const AppKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: (mono
                      ? theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        )
                      : theme.textTheme.bodyMedium)
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
