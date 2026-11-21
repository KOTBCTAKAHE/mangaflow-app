import 'package:flutter/material.dart';

/// MangaFlow design tokens.
///
/// Palette: deep graphite neutrals + a single "ember" accent. Everything in the
/// UI derives from these values — widgets must not hard-code colors or sizes.
abstract final class MfColors {
  // Graphite (dark theme, default)
  static const bg = Color(0xFF0D0E11);
  static const surface = Color(0xFF15171B);
  static const surfaceRaised = Color(0xFF1C1F25);
  static const surfaceHigh = Color(0xFF242830);
  static const border = Color(0xFF2B2F38);
  static const borderSubtle = Color(0xFF20232A);

  static const textPrimary = Color(0xFFEDEEF0);
  static const textSecondary = Color(0xFFA2A7B0);
  static const textTertiary = Color(0xFF6E737D);

  // The one accent — from the wallpaper (Material You) or a preset [AccentPalette].
  static AccentPalette palette = AccentPalette.wallpaper;

  /// The scheme in use (set by the app before every build): accents follow it.
  static ColorScheme? scheme;

  /// The wallpaper's colour when the phone offers one (Android 12+), for the settings swatch.
  static Color? wallpaperSeed;
  static Color get accent => scheme?.primary ?? palette.color;
  static Color get onAccent => scheme?.onPrimary ?? palette.on;
  static Color get accentSoft => accent.withValues(alpha: 0.16);

  // Semantic (used sparingly, desaturated to sit on graphite)
  static const success = Color(0xFF5FC48C);
  static const warning = Color(0xFFE8B45C);
  static const danger = Color(0xFFEF6A6A);

  // Light theme neutrals
  static const lightBg = Color(0xFFF6F5F3);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFF0EFEC);
  static const lightBorder = Color(0xFFE3E1DC);
  static const lightTextPrimary = Color(0xFF16171A);
  static const lightTextSecondary = Color(0xFF5D616A);
  static const lightTextTertiary = Color(0xFF8E929A);

  // Reader backdrops
  static const readerBlack = Color(0xFF000000);
  static const readerGray = Color(0xFF1A1A1A);
  static const readerWhite = Color(0xFFF4F2EE);
}

/// Accent presets tuned to sit on the graphite neutrals.
enum AccentPalette {
  /// Material You: the phone's wallpaper colours (Android 12+), violet elsewhere.
  wallpaper('wallpaper', 'Обои', Color(0xFF7D6BD8), Color(0xFFFFFFFF)),
  ember('ember', 'Янтарь', Color(0xFFFF7A5C), Color(0xFF1A0D09)),
  sakura('sakura', 'Сакура', Color(0xFFFF6F9C), Color(0xFF2A0A16)),
  violet('violet', 'Фиалка', Color(0xFF9B8CFF), Color(0xFF140E2E)),
  mint('mint', 'Мята', Color(0xFF3DD6A0), Color(0xFF052117)),
  sky('sky', 'Небо', Color(0xFF55B6FF), Color(0xFF041A2C));

  const AccentPalette(this.api, this.label, this.color, this.on);
  final String api;
  final String label;
  final Color color;
  final Color on;

  static AccentPalette parse(String? v) => values.firstWhere((p) => p.api == v, orElse: () => AccentPalette.wallpaper);
}

abstract final class MfSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// Horizontal page gutter.
  static const double gutter = 20;
}

abstract final class MfRadius {
  static const double xs = 6;
  static const double sm = 12;
  static const double md = 18;
  static const double lg = 26;
  static const double xl = 32;
  static const double pill = 999;

  static const cover = BorderRadius.all(Radius.circular(md));
  static const card = BorderRadius.all(Radius.circular(lg));
  static const sheet = BorderRadius.vertical(top: Radius.circular(xl));
}

abstract final class MfSize {
  /// Minimum touch target (Material recommends 48dp).
  static const double tap = 48;
  static const double iconSm = 18;
  static const double icon = 22;
  static const double coverAspect = 0.7; // width / height
  static const double carouselCover = 128;
  static const double gridMaxCover = 160;
}

abstract final class MfMotion {
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const standard = Cubic(0.4, 0.0, 0.2, 1.0);
}

/// Type scale. Manrope is a variable font whose default instance is weight 200,
/// so every style sets an explicit `wght` variation alongside [FontWeight].
abstract final class MfType {
  static const family = 'Manrope';

  /// Expressive display face for big headings (variable, Cyrillic).
  static const displayFamily = 'Unbounded';

  static TextStyle _s(double size, double height, int weight, {double spacing = 0, String font = family}) => TextStyle(
        fontFamily: font,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: [FontVariation('wght', weight.toDouble())],
        letterSpacing: spacing,
      );

  static final display = _s(30, 36, 700, spacing: -0.8, font: displayFamily);
  static final headline = _s(22, 28, 650, spacing: -0.5, font: displayFamily);
  // titles in the text face: the display face is kept for big headings only
  static final title = _s(19, 25, 750, spacing: -0.2);
  static final titleSmall = _s(16, 22, 700);
  static final body = _s(15, 22, 500);
  static final bodyStrong = _s(15, 22, 650);
  static final bodySmall = _s(13, 18, 500);
  static final label = _s(13, 16, 650, spacing: 0.1);
  static final caption = _s(11.5, 15, 600, spacing: 0.2);
  static final overline = _s(11, 14, 750, spacing: 1.0);
}
