import 'dart:ui';

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

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

  // The one accent
  static const accent = Color(0xFFFF7A5C);
  static const accentPressed = Color(0xFFE8664A);
  static const onAccent = Color(0xFF1A0D09);
  static const accentSoft = Color(0x29FF7A5C); // 16%

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
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
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
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 360);
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const standard = Cubic(0.4, 0.0, 0.2, 1.0);
}

/// Type scale. Manrope is a variable font whose default instance is weight 200,
/// so every style sets an explicit `wght` variation alongside [FontWeight].
abstract final class MfType {
  static const family = 'Manrope';

  static TextStyle _s(double size, double height, int weight, {double spacing = 0}) => TextStyle(
        fontFamily: family,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: [FontVariation('wght', weight.toDouble())],
        letterSpacing: spacing,
      );

  static final display = _s(32, 38, 800, spacing: -0.6);
  static final headline = _s(24, 30, 750, spacing: -0.3);
  static final title = _s(19, 25, 700, spacing: -0.2);
  static final titleSmall = _s(16, 22, 700);
  static final body = _s(15, 22, 500);
  static final bodyStrong = _s(15, 22, 650);
  static final bodySmall = _s(13, 18, 500);
  static final label = _s(13, 16, 650, spacing: 0.1);
  static final caption = _s(11.5, 15, 600, spacing: 0.2);
  static final overline = _s(11, 14, 750, spacing: 1.0);
}
