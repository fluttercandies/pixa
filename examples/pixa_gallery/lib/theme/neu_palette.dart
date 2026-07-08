import 'package:flutter/material.dart';

/// Neumorphism color and shadow tokens for the Pixa gallery.
///
/// Surfaces share a single base hue so the signature raised / pressed
/// / inset shadows read as one continuous material. Accent colors are
/// deliberately muted so photography stays the visual hero of the app.
@immutable
class NeuPalette extends ThemeExtension<NeuPalette> {
  const NeuPalette({
    required this.brightness,
    required this.base,
    required this.surface,
    required this.lightShadow,
    required this.darkShadow,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.success,
    required this.warning,
    required this.error,
    required this.divider,
    required this.overlayScrim,
  });

  /// Light workbench palette: cool soft-grey material.
  static const NeuPalette light = NeuPalette(
    brightness: Brightness.light,
    base: Color(0xFFE4E9F2),
    surface: Color(0xFFEAEEF7),
    lightShadow: Color(0xFFFFFFFF),
    darkShadow: Color(0xFFB6BFD2),
    accent: Color(0xFF4252E8),
    accentSoft: Color(0xFFD9DFFF),
    onAccent: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF2A2F45),
    textSecondary: Color(0xFF5A6280),
    textMuted: Color(0xFF5E6679),
    success: Color(0xFF37B681),
    warning: Color(0xFFE3A13C),
    error: Color(0xFFE5607A),
    divider: Color(0xFFD2D8E6),
    overlayScrim: Color(0x42000000),
  );

  /// Dark workbench palette: deep blue-grey material.
  static const NeuPalette dark = NeuPalette(
    brightness: Brightness.dark,
    base: Color(0xFF23272E),
    surface: Color(0xFF272C34),
    lightShadow: Color(0xFF313742),
    darkShadow: Color(0xFF181B21),
    accent: Color(0xFF8A9BFF),
    accentSoft: Color(0xFF33405F),
    onAccent: Color(0xFF1A1D24),
    textPrimary: Color(0xFFE9ECF5),
    textSecondary: Color(0xFFAEB6CC),
    textMuted: Color(0xFF969FB5),
    success: Color(0xFF5BD3A0),
    warning: Color(0xFFF1BD63),
    error: Color(0xFFF08297),
    divider: Color(0xFF39404E),
    overlayScrim: Color(0x99000000),
  );

  final Brightness brightness;
  final Color base;
  final Color surface;
  final Color lightShadow;
  final Color darkShadow;
  final Color accent;
  final Color accentSoft;
  final Color onAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color success;
  final Color warning;
  final Color error;
  final Color divider;
  final Color overlayScrim;

  /// Convex (raised) shadow pair: light falls from top-left.
  List<BoxShadow> convex({double intensity = 1.0, double blur = 14}) {
    final double i = intensity.clamp(0.0, 2.0);
    return <BoxShadow>[
      BoxShadow(
        color: darkShadow.withValues(alpha: 0.55 * i),
        offset: Offset(3.5 * i, 4.5 * i),
        blurRadius: blur * i,
      ),
      BoxShadow(
        color: lightShadow.withValues(alpha: 0.85 * i),
        offset: Offset(-3.5 * i, -3.5 * i),
        blurRadius: blur * i,
      ),
    ];
  }

  /// Pressed (lower raised) shadow pair used while tapping.
  List<BoxShadow> pressed({double blur = 9}) {
    return <BoxShadow>[
      BoxShadow(
        color: darkShadow.withValues(alpha: 0.4),
        offset: const Offset(2, 2),
        blurRadius: blur,
      ),
      BoxShadow(
        color: lightShadow.withValues(alpha: 0.55),
        offset: const Offset(-2, -2),
        blurRadius: blur,
      ),
    ];
  }

  /// Outer ring drawn for inset surfaces (the cavity wall).
  List<BoxShadow> inset({double intensity = 1.0, double blur = 9}) {
    final double i = intensity.clamp(0.0, 2.0);
    return <BoxShadow>[
      BoxShadow(
        color: darkShadow.withValues(alpha: 0.55 * i),
        offset: Offset(2.5 * i, 2.5 * i),
        blurRadius: blur * i,
      ),
      BoxShadow(
        color: lightShadow.withValues(alpha: 0.65 * i),
        offset: Offset(-2.5 * i, -2.5 * i),
        blurRadius: blur * i,
      ),
    ];
  }

  @override
  NeuPalette copyWith({
    Brightness? brightness,
    Color? base,
    Color? surface,
    Color? lightShadow,
    Color? darkShadow,
    Color? accent,
    Color? accentSoft,
    Color? onAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? success,
    Color? warning,
    Color? error,
    Color? divider,
    Color? overlayScrim,
  }) {
    return NeuPalette(
      brightness: brightness ?? this.brightness,
      base: base ?? this.base,
      surface: surface ?? this.surface,
      lightShadow: lightShadow ?? this.lightShadow,
      darkShadow: darkShadow ?? this.darkShadow,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      divider: divider ?? this.divider,
      overlayScrim: overlayScrim ?? this.overlayScrim,
    );
  }

  @override
  NeuPalette lerp(ThemeExtension<NeuPalette>? other, double t) {
    if (other is! NeuPalette) {
      return this;
    }
    return NeuPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      base: Color.lerp(base, other.base, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      lightShadow: Color.lerp(lightShadow, other.lightShadow, t)!,
      darkShadow: Color.lerp(darkShadow, other.darkShadow, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      overlayScrim: Color.lerp(overlayScrim, other.overlayScrim, t)!,
    );
  }
}

/// Convenience access on [BuildContext].
extension NeuPaletteContext on BuildContext {
  /// The active neumorphic palette for the surrounding theme.
  ///
  /// Falls back to the matching brightness palette when the host theme
  /// (e.g. a bare `MaterialApp` in a unit test) did not install the
  /// `NeuPalette` extension, so neumorphic widgets stay usable everywhere.
  NeuPalette get neu =>
      Theme.of(this).extension<NeuPalette>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? NeuPalette.dark
          : NeuPalette.light);
}
