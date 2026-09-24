import 'package:flutter/material.dart';

/// The app's palette in one place.
///
/// The reason this exists is a real bug: containers painted with
/// `Colors.grey.shade100` (a near-white) while the text on them stayed
/// `Colors.grey.shade700` looked correct in the light theme and became
/// unreadable in the dark one - a box that appears to hold no words. Every
/// colour here is derived from the active [ColorScheme], so the container
/// and the text on it always flip together when the theme flips.
abstract final class AppPalette {
  /// Info surfaces: quiet, neutral, used for asides and hints.
  static Color infoFill(ColorScheme s) =>
      s.surfaceContainerHighest.withValues(alpha: 0.45);

  /// Text on [infoFill] - the pair the two methods exist to enforce.
  static Color infoText(ColorScheme s) => s.onSurfaceVariant;

  /// Muted text that must stay readable on the scaffold background.
  static Color mutedText(ColorScheme s) => s.onSurfaceVariant;

  static Color success(ColorScheme s) =>
      s.brightness == Brightness.dark ? const Color(0xFF81C995) : const Color(0xFF2E7D32);
  static Color successFill(ColorScheme s) => success(s).withValues(alpha: 0.12);
  static Color successBorder(ColorScheme s) => success(s).withValues(alpha: 0.35);

  static Color warning(ColorScheme s) =>
      s.brightness == Brightness.dark ? const Color(0xFFF5B759) : const Color(0xFFB26A00);
  static Color warningFill(ColorScheme s) => warning(s).withValues(alpha: 0.12);
  static Color warningBorder(ColorScheme s) => warning(s).withValues(alpha: 0.35);

  static Color danger(ColorScheme s) =>
      s.brightness == Brightness.dark ? const Color(0xFFF28B82) : const Color(0xFFC62828);
  static Color dangerFill(ColorScheme s) => danger(s).withValues(alpha: 0.12);
  static Color dangerBorder(ColorScheme s) => danger(s).withValues(alpha: 0.35);

  static Color accent(ColorScheme s) => s.primary;
  static Color accentFill(ColorScheme s) => s.primary.withValues(alpha: 0.10);
  static Color accentBorder(ColorScheme s) => s.primary.withValues(alpha: 0.30);

  /// A "plain text on this colour always reads" surface, for containers
  /// that just want to be a box: card-like, theme-aware, no opinions.
  static Color neutralFill(ColorScheme s) =>
      s.surfaceContainerHighest.withValues(alpha: 0.55);

  /// The raised surface: one step above the scaffold. White on light (the
  /// cleanest reading surface there is), one container step up on dark.
  static Color raised(ColorScheme s) => s.brightness == Brightness.dark
      ? s.surfaceContainerLow
      : Colors.white;
}
