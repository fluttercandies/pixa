import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'neu_palette.dart';

/// Builds the [ThemeData] for the Pixa gallery.
///
/// Material 3 is kept on for accessibility plumbing (semantics, text
/// scaling, focus), but the visual language is overridden everywhere the
/// neumorphic palette needs to win: backgrounds, app bars, navigation,
/// sliders, switches and dividers.
class NeuTheme {
  NeuTheme._();

  /// Light workbench theme.
  static ThemeData light() => _build(NeuPalette.light, Brightness.light, false);

  /// Dark workbench theme.
  static ThemeData dark() => _build(NeuPalette.dark, Brightness.dark, true);

  static ThemeData _build(
    NeuPalette palette,
    Brightness brightness,
    bool isDark,
  ) {
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: palette.accent,
      onPrimary: palette.onAccent,
      secondary: palette.accent,
      onSecondary: palette.onAccent,
      error: palette.error,
      onError: palette.onAccent,
      surface: palette.surface,
      onSurface: palette.textPrimary,
      // Material 3 M3 role aliases.
      primaryContainer: palette.accentSoft,
      onPrimaryContainer: palette.textPrimary,
      secondaryContainer: palette.accentSoft,
      onSecondaryContainer: palette.textPrimary,
      tertiary: palette.success,
      onTertiary: palette.onAccent,
      tertiaryContainer: palette.success.withValues(alpha: 0.18),
      onTertiaryContainer: palette.textPrimary,
      errorContainer: palette.error.withValues(alpha: 0.16),
      onErrorContainer: palette.textPrimary,
      surfaceContainerHighest: palette.base,
      surfaceContainerHigh: palette.base,
      surfaceContainerLow: palette.surface,
      surfaceContainerLowest: palette.surface,
      surfaceContainer: palette.surface,
      onSurfaceVariant: palette.textSecondary,
      outline: palette.divider,
      outlineVariant: palette.divider,
      scrim: palette.overlayScrim,
      shadow: palette.darkShadow,
      inverseSurface: palette.textPrimary,
      onInverseSurface: palette.surface,
      inversePrimary: palette.accent,
    );

    final TextTheme text = _textTheme(palette, isDark);
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: palette.divider, width: 1),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.base,
      canvasColor: palette.base,
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: text,
      primaryTextTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          color: palette.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 0.6,
        space: 0.6,
      ),
      iconTheme: IconThemeData(color: palette.textSecondary, size: 22),
      primaryIconTheme: IconThemeData(color: palette.accent, size: 22),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        height: 84,
        indicatorColor: palette.accentSoft,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll<TextStyle?>(
          text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? palette.accent
                : palette.textMuted,
            size: 24,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        indicatorColor: palette.accentSoft,
        selectedIconTheme: IconThemeData(color: palette.accent, size: 26),
        unselectedIconTheme: IconThemeData(color: palette.textMuted, size: 24),
        selectedLabelTextStyle: text.labelLarge?.copyWith(
          color: palette.accent,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: text.labelLarge?.copyWith(
          color: palette.textMuted,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.divider,
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.14),
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
        rangeThumbShape: const RoundRangeSliderThumbShape(
          enabledThumbRadius: 9,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? palette.onAccent
              : palette.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.divider,
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.surface,
        selectedColor: palette.accentSoft,
        checkmarkColor: palette.accent,
        labelStyle: text.labelLarge?.copyWith(
          color: palette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        hintStyle: text.bodyMedium?.copyWith(color: palette.textMuted),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.divider, width: 1),
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accent,
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.textPrimary,
        contentTextStyle: TextStyle(color: palette.surface),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        titleTextStyle: text.titleMedium?.copyWith(
          color: palette.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: palette.textSecondary,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        dragHandleColor: palette.divider,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: ShapeDecoration(
          color: palette.textPrimary,
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
        textStyle: text.labelSmall?.copyWith(color: palette.surface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accent,
        circularTrackColor: palette.divider,
        linearTrackColor: palette.divider,
      ),
    );
  }

  static TextTheme _textTheme(NeuPalette palette, bool isDark) {
    final Color primary = palette.textPrimary;
    final Color secondary = palette.textSecondary;
    final String? fontFamily = null;
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        color: primary,
        letterSpacing: -1.0,
        fontFamily: fontFamily,
      ),
      displayMedium: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: primary,
        letterSpacing: -0.8,
        fontFamily: fontFamily,
      ),
      displaySmall: TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.5,
        fontFamily: fontFamily,
      ),
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.4,
        fontFamily: fontFamily,
      ),
      headlineMedium: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.3,
        fontFamily: fontFamily,
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.2,
        fontFamily: fontFamily,
      ),
      titleLarge: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: -0.1,
        fontFamily: fontFamily,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: primary,
        fontFamily: fontFamily,
      ),
      titleSmall: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: secondary,
        fontFamily: fontFamily,
      ),
      bodyLarge: TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w400,
        color: primary,
        height: 1.4,
        fontFamily: fontFamily,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: secondary,
        height: 1.4,
        fontFamily: fontFamily,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: palette.textMuted,
        height: 1.35,
        fontFamily: fontFamily,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: primary,
        letterSpacing: 0.1,
        fontFamily: fontFamily,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: secondary,
        letterSpacing: 0.2,
        fontFamily: fontFamily,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: palette.textMuted,
        letterSpacing: 0.3,
        fontFamily: fontFamily,
      ),
    ).apply(
      displayColor: primary,
      bodyColor: secondary,
      decorationColor: palette.accent,
    );
  }
}
