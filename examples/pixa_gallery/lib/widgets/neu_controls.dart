import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neu_palette.dart';
import 'neu_focus.dart';
import 'neu_surface.dart';

/// A neumorphic button: raised surface that presses in on tap.
class NeuButton extends StatefulWidget {
  const NeuButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    this.elevation = NeuElevation.low,
    this.accent = false,
    this.disabled = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final Color? color;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final NeuElevation elevation;
  final bool accent;
  final bool disabled;

  @override
  State<NeuButton> createState() => _NeuButtonState();
}

class _NeuButtonState extends State<NeuButton> {
  bool _down = false;

  bool get _enabled => widget.onPressed != null && !widget.disabled;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final bool active = _enabled && _down;
    final Color surface = widget.accent
        ? palette.accent
        : (widget.color ?? palette.surface);
    final Color contentColor = widget.accent
        ? palette.onAccent
        : palette.textPrimary;

    return NeuFocusable(
      enabled: _enabled,
      onActivate: widget.onPressed,
      borderRadius: widget.borderRadius,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: _enabled ? () => setState(() => _down = false) : null,
        onTap: _enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onPressed?.call();
              }
            : null,
        child: AnimatedScale(
          scale: active ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: Opacity(
            opacity: _enabled ? 1.0 : 0.45,
            child: NeuSurface(
              shape: active ? NeuShape.concave : NeuShape.convex,
              elevation: active ? NeuElevation.low : widget.elevation,
              color: surface,
              borderRadius: widget.borderRadius,
              padding: widget.padding,
              clipBehavior: Clip.none,
              child: DefaultTextStyle.merge(
                style:
                    Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: contentColor,
                      fontWeight: FontWeight.w700,
                    ) ??
                    TextStyle(color: contentColor, fontWeight: FontWeight.w700),
                child: IconTheme.merge(
                  data: IconThemeData(color: contentColor, size: 20),
                  child: widget.icon == null
                      ? widget.child
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            widget.icon!,
                            const SizedBox(width: 8),
                            widget.child,
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A circular neumorphic icon button.
class NeuIconButton extends StatefulWidget {
  const NeuIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 52,
    this.iconSize = 22,
    this.accent = false,
    this.tooltip,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool accent;
  final String? tooltip;
  final bool selected;

  @override
  State<NeuIconButton> createState() => _NeuIconButtonState();
}

class _NeuIconButtonState extends State<NeuIconButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final bool enabled = widget.onPressed != null;
    final bool active = enabled && _down;
    final bool highlighted = widget.accent || widget.selected;

    final Widget core = NeuFocusable(
      enabled: enabled,
      onActivate: widget.onPressed,
      borderRadius: BorderRadius.circular(widget.size / 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: active ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: NeuSurface(
              shape: active
                  ? NeuShape.concave
                  : (widget.selected ? NeuShape.concave : NeuShape.convex),
              elevation: highlighted ? NeuElevation.medium : NeuElevation.low,
              color: highlighted ? palette.accent : null,
              borderRadius: BorderRadius.circular(widget.size / 2),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: highlighted ? palette.onAccent : palette.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip case final String tooltip) {
      return Tooltip(message: tooltip, child: core);
    }
    return core;
  }
}

/// A neumorphic card container.
class NeuCard extends StatelessWidget {
  const NeuCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.elevation = NeuElevation.low,
    this.shape = NeuShape.convex,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.onTap,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final NeuElevation elevation;
  final NeuShape shape;
  final Color? color;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    return NeuSurface(
      elevation: elevation,
      shape: shape,
      color: color,
      borderRadius: borderRadius,
      padding: padding,
      margin: margin,
      onTap: onTap,
      border: border,
      child: child,
    );
  }
}

/// A neumorphic choice chip. Selected state is rendered as an inset
/// accent cavity.
class NeuChip extends StatelessWidget {
  const NeuChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.icon,
    this.selectedIcon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? selectedIcon;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuFocusable(
      enabled: onTap != null,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(16),
      child: NeuSurface(
        onTap: onTap,
        shape: selected ? NeuShape.concave : NeuShape.convex,
        elevation: selected ? NeuElevation.low : NeuElevation.low,
        color: selected ? palette.accentSoft : null,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null || selectedIcon != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  selected ? (selectedIcon ?? icon) : icon,
                  size: 16,
                  color: selected ? palette.accent : palette.textMuted,
                ),
              ),
            Text(
              label,
              style: TextStyle(
                color: selected ? palette.accent : palette.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A neumorphic segmented control with curved separators.
class NeuSegmented<T> extends StatelessWidget {
  const NeuSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<NeuSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return NeuSurface(
      shape: NeuShape.concave,
      elevation: NeuElevation.low,
      borderRadius: BorderRadius.circular(18),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < segments.length; i++) ...<Widget>[
            _SegmentTile<T>(
              segment: segments[i],
              selected: segments[i].value == value,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(segments[i].value),
            ),
            if (i != segments.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class NeuSegment<T> {
  const NeuSegment({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

class _SegmentTile<T> extends StatefulWidget {
  const _SegmentTile({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final NeuSegment<T> segment;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_SegmentTile<T>> createState() => _SegmentTileState<T>();
}

class _SegmentTileState<T> extends State<_SegmentTile<T>> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuFocusable(
      enabled: widget.onTap != null,
      onActivate: widget.onTap,
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null
            ? null
            : (_) => setState(() => _down = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) => setState(() => _down = false),
        onTapCancel: widget.onTap == null
            ? null
            : () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: NeuSurface(
            shape: widget.selected ? NeuShape.convex : NeuShape.flat,
            elevation: widget.selected ? NeuElevation.low : NeuElevation.flat,
            color: widget.selected ? palette.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.segment.icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      widget.segment.icon,
                      size: 16,
                      color: widget.selected
                          ? palette.accent
                          : palette.textMuted,
                    ),
                  ),
                Text(
                  widget.segment.label,
                  style: TextStyle(
                    color: widget.selected
                        ? palette.accent
                        : palette.textSecondary,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A neumorphic toggle switch (round thumb in a cavity).
class NeuToggle extends StatelessWidget {
  const NeuToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuFocusable(
      enabled: onChanged != null,
      onActivate: () => onChanged!(!value),
      borderRadius: BorderRadius.circular(17),
      child: GestureDetector(
        onTap: onChanged == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onChanged!(!value);
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: 58,
          height: 34,
          decoration: ShapeDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: value
                  ? <Color>[
                      palette.accent,
                      Color.lerp(palette.accent, palette.darkShadow, 0.25)!,
                    ]
                  : <Color>[
                      Color.lerp(palette.surface, palette.darkShadow, 0.18)!,
                      palette.surface,
                      Color.lerp(palette.surface, palette.lightShadow, 0.14)!,
                    ],
            ),
            shadows: palette.inset(intensity: 0.85, blur: 5),
            shape: const RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(17)),
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.all(3),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: value ? palette.onAccent : palette.surface,
                shape: BoxShape.circle,
                boxShadow: value
                    ? null
                    : palette.convex(intensity: 0.7, blur: 4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A neumorphic progress indicator rendered inside a concave track.
class NeuProgress extends StatelessWidget {
  const NeuProgress({
    super.key,
    this.value,
    this.height = 12,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  /// `null` → indeterminate, otherwise a 0..1 fraction.
  final double? value;
  final double height;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final bool indeterminate = value == null;
    final double fraction = (value ?? 0).clamp(0.0, 1.0).toDouble();

    return SizedBox(
      height: height,
      child: NeuSurface(
        shape: NeuShape.concave,
        elevation: NeuElevation.low,
        borderRadius: borderRadius,
        padding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return Stack(
              alignment: Alignment.centerLeft,
              children: <Widget>[
                if (indeterminate)
                  _IndeterminateStrip(
                    color: palette.accent,
                    width: constraints.maxWidth,
                  )
                else
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    width: constraints.maxWidth * fraction,
                    decoration: ShapeDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          palette.accent,
                          Color.lerp(palette.accent, palette.lightShadow, 0.3)!,
                        ],
                      ),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: borderRadius,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IndeterminateStrip extends StatefulWidget {
  const _IndeterminateStrip({required this.color, required this.width});
  final Color color;
  final double width;

  @override
  State<_IndeterminateStrip> createState() => _IndeterminateStripState();
}

class _IndeterminateStripState extends State<_IndeterminateStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double w = (widget.width * 0.32).clamp(28, double.infinity);
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = _controller.value;
        return Transform.translate(
          offset: Offset(-w + (widget.width + w) * t, 0),
          child: child,
        );
      },
      child: Container(
        width: w,
        decoration: ShapeDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              widget.color.withValues(alpha: 0),
              widget.color,
              widget.color.withValues(alpha: 0),
            ],
          ),
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
    );
  }
}

/// A circular neumorphic spinner for image loading states.
class NeuSpinner extends StatelessWidget {
  const NeuSpinner({super.key, this.size = 28, this.value});
  final double size;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        value: value,
        strokeWidth: 2.6,
        strokeCap: StrokeCap.round,
        backgroundColor: palette.divider,
        valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
      ),
    );
  }
}

/// A neumorphic app bar with a raised back / action buttons.
class NeuAppBar extends StatelessWidget implements PreferredSizeWidget {
  const NeuAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions = const <Widget>[],
    this.height = 72,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget> actions;
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: NavigationToolbar(
            leading: leading,
            middle: title,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
            centerMiddle: false,
            middleSpacing: 8,
          ),
        ),
      ),
    );
  }
}
