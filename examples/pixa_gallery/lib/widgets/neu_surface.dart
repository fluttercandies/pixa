import 'package:flutter/material.dart';

import '../theme/neu_palette.dart';

/// How a [NeuSurface] interacts with light.
enum NeuElevation {
  /// Flat neutral surface (no shadow) — used for stacked layers.
  flat,

  /// Gently raised tile, the workhorse for cards and tiles.
  low,

  /// Confidently raised surface for prominent containers.
  medium,

  /// Strongly raised hero surface for dialogs / floating panels.
  high,
}

/// How the surface is lit around its edges.
enum NeuShape {
  /// Convex raised material — default neumorphic look.
  convex,

  /// Concave cavity — used for wells, progress tracks, image wells.
  concave,

  /// Flat pressed surface — used transiently during interaction.
  flat,
}

/// A neumorphic surface: the single primitive every other widget in the
/// gallery builds on.
///
/// It paints a base [color] (defaults to the palette surface) and either
/// raised shadows ([NeuShape.convex]), an inset cavity
/// ([NeuShape.concave]), or nothing ([NeuShape.flat]). All neumorphic
/// widgets route their visual through this widget so the shadow language
/// stays consistent.
class NeuSurface extends StatelessWidget {
  const NeuSurface({
    super.key,
    required this.child,
    this.elevation = NeuElevation.low,
    this.shape = NeuShape.convex,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.color,
    this.padding,
    this.margin,
    this.onTap,
    this.onLongPress,
    this.border,
    this.clipBehavior = Clip.antiAlias,
  });

  /// Surface with explicit [shadows]; advanced use only.
  const NeuSurface.raw({
    super.key,
    required this.child,
    this.elevation = NeuElevation.low,
    this.shape = NeuShape.convex,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.color,
    this.padding,
    this.margin,
    this.onTap,
    this.onLongPress,
    this.border,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final NeuElevation elevation;
  final NeuShape shape;
  final BorderRadius borderRadius;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Border? border;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final Color fill = color ?? palette.surface;
    final bool interactive = onTap != null || onLongPress != null;
    // Superellipse shape shared by the decoration, the clip and the inset
    // rim painter so the whole surface reads as one continuous material.
    final RoundedSuperellipseBorder superShape = RoundedSuperellipseBorder(
      borderRadius: borderRadius,
      side: _borderSide(),
    );

    Widget content = DecoratedBox(
      decoration: ShapeDecoration(
        gradient: shape == NeuShape.concave
            ? _insetGradient(palette, fill)
            : _convexGradient(palette, fill),
        shadows: switch (shape) {
          NeuShape.convex => _convexShadows(palette),
          NeuShape.concave => null,
          NeuShape.flat => null,
        },
        shape: superShape,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    if (clipBehavior != Clip.none) {
      content = ClipPath(
        clipper: ShapeBorderClipper(shape: superShape),
        clipBehavior: clipBehavior,
        child: content,
      );
    }

    if (shape == NeuShape.concave) {
      // Draw an inset shadow ring over the gradient so the cavity reads
      // with a believable rim.
      content = CustomPaint(
        painter: _InsetRimPainter(
          palette: palette,
          radius: borderRadius,
          intensity: _intensity(),
        ),
        child: content,
      );
    }

    if (interactive) {
      content = _NeuPressable(
        borderRadius: borderRadius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      );
    }

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    return content;
  }

  double _intensity() => switch (elevation) {
    NeuElevation.flat => 0.0,
    NeuElevation.low => 0.85,
    NeuElevation.medium => 1.25,
    NeuElevation.high => 1.7,
  };

  /// Maps the legacy [Border] API to a single [BorderSide] for the
  /// superellipse shape. Only the uniform case is supported; a non-uniform
  /// border falls back to the bottom side so behaviour stays explicit.
  BorderSide _borderSide() {
    if (border == null) {
      return BorderSide.none;
    }
    final Border b = border!;
    if (b.top == b.right && b.right == b.bottom && b.bottom == b.left) {
      return b.top;
    }
    return b.bottom;
  }

  List<BoxShadow> _convexShadows(NeuPalette palette) {
    return palette.convex(
      intensity: _intensity(),
      blur: switch (elevation) {
        NeuElevation.flat => 0,
        NeuElevation.low => 14,
        NeuElevation.medium => 20,
        NeuElevation.high => 30,
      },
    );
  }

  LinearGradient _convexGradient(NeuPalette palette, Color fill) {
    // Subtle top-left sheen so the convex surface doesn't read as flat
    // paint. Intensity follows elevation.
    final double i = _intensity();
    final Color top = Color.lerp(fill, palette.lightShadow, 0.06 * i)!;
    final Color bottom = Color.lerp(fill, palette.darkShadow, 0.05 * i)!;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[top, fill, bottom],
      stops: const <double>[0.0, 0.55, 1.0],
    );
  }

  LinearGradient _insetGradient(NeuPalette palette, Color fill) {
    final double i = _intensity();
    final Color dark = Color.lerp(fill, palette.darkShadow, 0.18 * i)!;
    final Color light = Color.lerp(fill, palette.lightShadow, 0.12 * i)!;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[dark, fill, light],
      stops: const <double>[0.0, 0.5, 1.0],
    );
  }
}

class _InsetRimPainter extends CustomPainter {
  _InsetRimPainter({
    required this.palette,
    required this.radius,
    required this.intensity,
  });

  final NeuPalette palette;
  final BorderRadius radius;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final RSuperellipse base = radius.toRSuperellipse(Offset.zero & size);
    // Inner dark wall (bottom-right).
    final Paint dark = Paint()
      ..color = palette.darkShadow.withValues(alpha: 0.5 * intensity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath((Path()..addRSuperellipse(base.deflate(1.5))), dark);
    // Inner light wall (top-left).
    final Paint light = Paint()
      ..color = palette.lightShadow.withValues(alpha: 0.6 * intensity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath((Path()..addRSuperellipse(base.inflate(0.5))), light);
  }

  @override
  bool shouldRepaint(covariant _InsetRimPainter oldDelegate) =>
      oldDelegate.intensity != intensity ||
      oldDelegate.palette != palette ||
      oldDelegate.radius != radius;
}

/// Wraps a child with a press animation that swaps the convex shadows for
/// pressed ones, giving the characteristic "pushed in" feel.
class _NeuPressable extends StatefulWidget {
  const _NeuPressable({
    required this.child,
    required this.borderRadius,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<_NeuPressable> createState() => _NeuPressableState();
}

class _NeuPressableState extends State<_NeuPressable> {
  bool _down = false;

  void _setDown(bool value) {
    if (_down != value) {
      setState(() => _down = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setDown(true),
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
