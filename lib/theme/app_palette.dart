import 'package:flutter/material.dart';

/// The app's palette in one place.
///
/// The reason this exists is a real bug: containers painted with
/// `Colors.grey.shade100` (a near-white) while the text on them stayed
/// `Colors.grey.shade700` looked correct in the light theme and became
/// unreadable in the dark one - a box that appears to hold no words. Every
/// colour here is derived from the active [ColorScheme], so the container
/// and the text on it always flip together when the theme flips.
///
/// ## The tone system
///
/// Screens stopped inventing colour pairs by hand: [AppTone] names the
/// meaning (info, success, warning, danger, accent) and [tone] returns the
/// three colours that always belong together - foreground, fill and border.
/// A badge, a banner and a status pill that mean the same thing therefore
/// look the same, in both themes, without any screen repeating the recipe.
abstract final class AppPalette {
  // --- legacy helpers (kept: screens and tests use them) -------------------

  /// Info surfaces: quiet, neutral, used for asides and hints.
  static Color infoFill(ColorScheme s) =>
      s.surfaceContainerHighest.withValues(alpha: 0.45);

  /// Text on [infoFill] - the pair the two methods exist to enforce.
  static Color infoText(ColorScheme s) => s.onSurfaceVariant;

  /// Muted text that must stay readable on the scaffold background.
  static Color mutedText(ColorScheme s) => s.onSurfaceVariant;

  static Color success(ColorScheme s) => s.brightness == Brightness.dark
      ? const Color(0xFF81C995)
      : const Color(0xFF2E7D32);
  static Color successFill(ColorScheme s) =>
      success(s).withValues(alpha: 0.12);
  static Color successBorder(ColorScheme s) =>
      success(s).withValues(alpha: 0.35);

  static Color warning(ColorScheme s) => s.brightness == Brightness.dark
      ? const Color(0xFFF5B759)
      : const Color(0xFFB26A00);
  static Color warningFill(ColorScheme s) =>
      warning(s).withValues(alpha: 0.12);
  static Color warningBorder(ColorScheme s) =>
      warning(s).withValues(alpha: 0.35);

  static Color danger(ColorScheme s) => s.brightness == Brightness.dark
      ? const Color(0xFFF28B82)
      : const Color(0xFFC62828);
  static Color dangerFill(ColorScheme s) => danger(s).withValues(alpha: 0.12);
  static Color dangerBorder(ColorScheme s) =>
      danger(s).withValues(alpha: 0.35);

  static Color accent(ColorScheme s) => s.primary;
  static Color accentFill(ColorScheme s) => s.primary.withValues(alpha: 0.10);
  static Color accentBorder(ColorScheme s) =>
      s.primary.withValues(alpha: 0.30);

  /// A "plain text on this colour always reads" surface, for containers
  /// that just want to be a box: card-like, theme-aware, no opinions.
  static Color neutralFill(ColorScheme s) =>
      s.surfaceContainerHighest.withValues(alpha: 0.55);

  /// The raised surface: one step above the scaffold. White on light (the
  /// cleanest reading surface there is), one container step up on dark.
  static Color raised(ColorScheme s) => s.brightness == Brightness.dark
      ? s.surfaceContainerLow
      : Colors.white;

  // --- tone system ---------------------------------------------------------

  /// What a piece of colour *means*. The enum exists so a banner, a badge and
  /// a metric tile cannot pick three different greens for the same success.
  static AppToneColors tone(ColorScheme s, AppTone tone) =>
      AppToneColors.resolve(s, tone);

  /// The two-step brand wash used by the logo mark and hero blocks: a deep
  /// indigo into a cyan. Derived from the live scheme so a user theme that
  /// changes the seed still produces a coherent pair rather than a fixed
  /// gradient fighting the rest of the screen.
  static List<Color> brandGradient(ColorScheme s) => [
    s.primary,
    Color.lerp(s.primary, s.tertiary, 0.85) ?? s.tertiary,
  ];

  /// Backgrounds, from the page up. Named by depth rather than by Material
  /// role, because that is how they are chosen: "the panel sits one step
  /// above the page".
  static Color canvas(ColorScheme s) =>
      s.brightness == Brightness.dark ? s.surfaceContainerLowest : s.surface;
  static Color panel(ColorScheme s) =>
      s.brightness == Brightness.dark ? s.surfaceContainerLow : s.surface;
  static Color panelAlt(ColorScheme s) => s.surfaceContainerHighest
      .withValues(alpha: s.brightness == Brightness.dark ? 0.45 : 0.5);
  static Color hairline(ColorScheme s) =>
      s.outlineVariant.withValues(alpha: s.brightness == Brightness.dark ? 0.75 : 0.65);

  /// The console surface for logs and configs: darker than a panel in both
  /// themes, so a wall of monospace reads as an instrument rather than as
  /// another paragraph.
  static Color console(ColorScheme s) => s.brightness == Brightness.dark
      ? const Color(0xFF0A0C10)
      : const Color(0xFF12161D);
  static Color consoleText(ColorScheme s) => const Color(0xFFD7DEEA);
}

/// The meanings a colour can carry.
enum AppTone { neutral, accent, info, success, warning, danger }

/// The three colours of one tone: the foreground for text and icons, the fill
/// behind it, and the border around it. Always produced together.
class AppToneColors {
  final Color fg;
  final Color fill;
  final Color border;

  const AppToneColors({
    required this.fg,
    required this.fill,
    required this.border,
  });

  static AppToneColors resolve(ColorScheme s, AppTone tone) {
    final (fg, alpha) = switch (tone) {
      AppTone.success => (AppPalette.success(s), 0.12),
      AppTone.warning => (AppPalette.warning(s), 0.12),
      AppTone.danger => (AppPalette.danger(s), 0.12),
      AppTone.accent => (s.primary, 0.10),
      AppTone.info => (s.onSurfaceVariant, 0.08),
      AppTone.neutral => (s.onSurfaceVariant, 0.06),
    };
    return AppToneColors(
      fg: fg,
      fill: fg.withValues(alpha: alpha),
      border: fg.withValues(alpha: 0.32),
    );
  }

  /// The information tone's fill: a surface, not a tint, so an aside does not
  /// compete with a real warning.
  static AppToneColors infoSurface(ColorScheme s) => AppToneColors(
    fg: s.onSurfaceVariant,
    fill: s.surfaceContainerHighest.withValues(alpha: 0.45),
    border: s.outlineVariant.withValues(alpha: 0.6),
  );
}
