import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Material You themes: every colour comes from one tonal [ColorScheme] — seeded by the
/// wallpaper (Android 12+) or a preset accent — so surfaces, chips and bars all carry its hue.
abstract final class AppTheme {
  /// Scheme for [seed]. Wallpaper colours use Android's own tonal-spot recipe; presets keep
  /// their exact hue (fidelity) so «Янтарь» stays amber.
  static ColorScheme scheme(Color seed, Brightness brightness, {bool wallpaper = false}) => ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
        dynamicSchemeVariant: wallpaper ? DynamicSchemeVariant.tonalSpot : DynamicSchemeVariant.fidelity,
      ).copyWith(error: MfColors.danger);

  static ThemeData dark([ColorScheme? s]) => build(s ?? scheme(MfColors.palette.color, Brightness.dark));
  static ThemeData light([ColorScheme? s]) => build(s ?? scheme(MfColors.palette.color, Brightness.light));

  static ThemeData build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final brightness = scheme.brightness;
    final bg = scheme.surface;
    final raised = scheme.surfaceContainer;
    final high = scheme.surfaceContainerHighest;
    final border = scheme.outlineVariant;
    final primaryText = scheme.onSurface;
    final secondaryText = scheme.onSurfaceVariant;
    final tertiaryText = scheme.outline;

    final text = TextTheme(
      displaySmall: MfType.display.copyWith(color: primaryText),
      headlineSmall: MfType.headline.copyWith(color: primaryText),
      titleLarge: MfType.title.copyWith(color: primaryText),
      titleMedium: MfType.titleSmall.copyWith(color: primaryText),
      titleSmall: MfType.label.copyWith(color: primaryText),
      bodyLarge: MfType.body.copyWith(color: primaryText),
      bodyMedium: MfType.body.copyWith(color: primaryText),
      bodySmall: MfType.bodySmall.copyWith(color: secondaryText),
      labelLarge: MfType.label.copyWith(color: primaryText),
      labelMedium: MfType.caption.copyWith(color: secondaryText),
      labelSmall: MfType.overline.copyWith(color: tertiaryText),
    );

    const shape = StadiumBorder(); // expressive: pill buttons

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      fontFamily: MfType.family,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: MfType.title.copyWith(color: primaryText),
        iconTheme: IconThemeData(color: primaryText),
        systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        height: 76,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? scheme.onSecondaryContainer : secondaryText,
              size: MfSize.icon,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => MfType.caption.copyWith(
              color: s.contains(WidgetState.selected) ? primaryText : tertiaryText,
            )),
      ),
      cardTheme: CardThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: MfRadius.card,
          side: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: high,
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.xxl),
          textStyle: MfType.label,
          shape: shape,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.lg)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryText,
          minimumSize: const Size(64, 52),
          side: BorderSide(color: scheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.xl),
          textStyle: MfType.label,
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size(48, MfSize.tap),
          textStyle: MfType.label,
          shape: shape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(MfSize.tap, MfSize.tap), foregroundColor: primaryText),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        selectedColor: scheme.secondaryContainer,
        side: BorderSide.none,
        labelStyle: MfType.label.copyWith(color: primaryText),
        secondaryLabelStyle: MfType.label.copyWith(color: scheme.onSecondaryContainer),
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.sm, vertical: MfSpace.xs),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.sm)),
        checkmarkColor: scheme.onSecondaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hintStyle: MfType.body.copyWith(color: tertiaryText),
        labelStyle: MfType.body.copyWith(color: secondaryText),
        contentPadding: const EdgeInsets.symmetric(horizontal: MfSpace.lg, vertical: MfSpace.md + 2),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(MfRadius.md), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(MfRadius.md), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MfRadius.md),
            borderSide: BorderSide(color: scheme.primary, width: 2)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MfRadius.md), borderSide: const BorderSide(color: MfColors.danger)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: MfRadius.sheet),
        showDragHandle: true,
        dragHandleColor: scheme.outline,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.xl)),
        titleTextStyle: MfType.title.copyWith(color: primaryText),
        contentTextStyle: MfType.body.copyWith(color: secondaryText),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: MfType.body.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.md)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: high,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.16),
        trackHeight: 6,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: secondaryText,
          selectedBackgroundColor: scheme.secondaryContainer,
          selectedForegroundColor: scheme.onSecondaryContainer,
          side: BorderSide(color: scheme.outline),
          textStyle: MfType.label,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.outline),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.primary : high),
        trackOutlineColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Colors.transparent : scheme.outline),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: high,
        circularTrackColor: Colors.transparent,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primaryText,
        unselectedLabelColor: tertiaryText,
        labelStyle: MfType.label,
        unselectedLabelStyle: MfType.label,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          borderSide: BorderSide(color: scheme.primary, width: 3),
        ),
        dividerColor: Colors.transparent,
        tabAlignment: TabAlignment.start,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: secondaryText,
        titleTextStyle: MfType.bodyStrong.copyWith(color: primaryText),
        subtitleTextStyle: MfType.bodySmall.copyWith(color: secondaryText),
        contentPadding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
        minVerticalPadding: MfSpace.md,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

/// Convenience accessors for semantic colors that aren't part of [ColorScheme].
extension MfThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get textTertiary => Theme.of(this).colorScheme.outline;
}
