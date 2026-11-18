import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Builds Material 3 themes from [MfColors]/[MfType] tokens.
abstract final class AppTheme {
  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: MfColors.bg,
        surface: MfColors.surface,
        raised: MfColors.surfaceRaised,
        high: MfColors.surfaceHigh,
        border: MfColors.border,
        primaryText: MfColors.textPrimary,
        secondaryText: MfColors.textSecondary,
        tertiaryText: MfColors.textTertiary,
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: MfColors.lightBg,
        surface: MfColors.lightSurface,
        raised: MfColors.lightSurfaceRaised,
        high: MfColors.lightBorder,
        border: MfColors.lightBorder,
        primaryText: MfColors.lightTextPrimary,
        secondaryText: MfColors.lightTextSecondary,
        tertiaryText: MfColors.lightTextTertiary,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color raised,
    required Color high,
    required Color border,
    required Color primaryText,
    required Color secondaryText,
    required Color tertiaryText,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: MfColors.accent,
      onPrimary: MfColors.onAccent,
      primaryContainer: MfColors.accentSoft,
      onPrimaryContainer: MfColors.accent,
      secondaryContainer: MfColors.accentSoft,
      onSecondaryContainer: MfColors.accent,
      secondary: secondaryText,
      onSecondary: bg,
      surface: surface,
      onSurface: primaryText,
      onSurfaceVariant: secondaryText,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: raised,
      surfaceContainerHigh: high,
      surfaceContainerHighest: high,
      outline: border,
      outlineVariant: isDark ? MfColors.borderSubtle : MfColors.lightBorder,
      error: MfColors.danger,
      onError: Colors.white,
      shadow: Colors.black,
      scrim: Colors.black,
    );

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

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.md));

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
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: MfColors.accentSoft,
        height: 68,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? MfColors.accent : secondaryText,
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
          side: BorderSide(color: isDark ? MfColors.borderSubtle : MfColors.lightBorder),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: MfColors.accent,
          foregroundColor: MfColors.onAccent,
          disabledBackgroundColor: high,
          minimumSize: const Size(64, MfSize.tap),
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.xl),
          textStyle: MfType.label,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryText,
          minimumSize: const Size(64, MfSize.tap),
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.xl),
          textStyle: MfType.label,
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: MfColors.accent,
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
        selectedColor: MfColors.accentSoft,
        side: BorderSide(color: border),
        labelStyle: MfType.label.copyWith(color: primaryText),
        secondaryLabelStyle: MfType.label.copyWith(color: MfColors.accent),
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.sm, vertical: MfSpace.xs),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.pill)),
        checkmarkColor: MfColors.accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        hintStyle: MfType.body.copyWith(color: tertiaryText),
        labelStyle: MfType.body.copyWith(color: secondaryText),
        contentPadding: const EdgeInsets.symmetric(horizontal: MfSpace.lg, vertical: MfSpace.md + 2),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(MfRadius.md), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MfRadius.md), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MfRadius.md),
            borderSide: BorderSide(color: MfColors.accent, width: 1.5)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MfRadius.md), borderSide: const BorderSide(color: MfColors.danger)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface,
        shape: const RoundedRectangleBorder(borderRadius: MfRadius.sheet),
        showDragHandle: true,
        dragHandleColor: border,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.lg)),
        titleTextStyle: MfType.title.copyWith(color: primaryText),
        contentTextStyle: MfType.body.copyWith(color: secondaryText),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: high,
        contentTextStyle: MfType.body.copyWith(color: primaryText),
        actionTextColor: MfColors.accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MfRadius.md)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: MfColors.accent,
        inactiveTrackColor: high,
        thumbColor: MfColors.accent,
        overlayColor: MfColors.accentSoft,
        trackHeight: 3,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: secondaryText,
          selectedBackgroundColor: MfColors.accentSoft,
          selectedForegroundColor: MfColors.accent,
          side: BorderSide(color: border),
          textStyle: MfType.label,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? MfColors.onAccent : secondaryText),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? MfColors.accent : high),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: MfColors.accent,
        linearTrackColor: high,
        circularTrackColor: Colors.transparent,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: primaryText,
        unselectedLabelColor: tertiaryText,
        labelStyle: MfType.label,
        unselectedLabelStyle: MfType.label,
        indicatorColor: MfColors.accent,
        indicatorSize: TabBarIndicatorSize.label,
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
  Color get textTertiary => isDark ? MfColors.textTertiary : MfColors.lightTextTertiary;
}
