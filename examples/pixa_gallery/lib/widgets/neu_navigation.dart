import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neu_palette.dart';
import 'neu_focus.dart';
import 'neu_surface.dart';

/// A destination in the gallery navigation.
class PixaDestination {
  const PixaDestination({
    required this.value,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final Object value;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// A floating neumorphic bottom navigation bar.
///
/// Sits above the content with margin, raised from the base material,
/// and renders each destination as a pressable pill that presses in when
/// selected.
class NeuBottomNav extends StatelessWidget {
  const NeuBottomNav({
    super.key,
    required this.destinations,
    required this.value,
    required this.onChanged,
  });

  final List<PixaDestination> destinations;
  final Object value;
  final ValueChanged<Object>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: SafeArea(
        top: false,
        child: NeuSurface(
          elevation: NeuElevation.high,
          shape: NeuShape.convex,
          borderRadius: BorderRadius.circular(28),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: <Widget>[
              for (final PixaDestination dest in destinations)
                Expanded(
                  child: _NavPill(
                    destination: dest,
                    selected: dest.value == value,
                    onTap: onChanged == null
                        ? null
                        : () => onChanged!(dest.value),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatefulWidget {
  const _NavPill({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final PixaDestination destination;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_NavPill> createState() => _NavPillState();
}

class _NavPillState extends State<_NavPill> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      container: true,
      excludeSemantics: true,
      child: NeuFocusable(
        enabled: widget.onTap != null,
        onActivate: widget.onTap,
        borderRadius: BorderRadius.circular(18),
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
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap?.call();
          },
          child: AnimatedScale(
            scale: _down ? 0.95 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: ShapeDecoration(
                color: widget.selected
                    ? palette.accentSoft
                    : Colors.transparent,
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    widget.selected
                        ? widget.destination.selectedIcon
                        : widget.destination.icon,
                    size: 24,
                    color: widget.selected ? palette.accent : palette.textMuted,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.destination.label,
                    style: TextStyle(
                      color: widget.selected
                          ? palette.accent
                          : palette.textMuted,
                      fontWeight: widget.selected
                          ? FontWeight.w700
                          : FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A neumorphic navigation rail for wide layouts.
class NeuRail extends StatelessWidget {
  const NeuRail({
    super.key,
    required this.destinations,
    required this.value,
    required this.onChanged,
    required this.header,
  });

  final List<PixaDestination> destinations;
  final Object value;
  final ValueChanged<Object>? onChanged;
  final Widget header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 0, 18),
      child: NeuSurface(
        elevation: NeuElevation.low,
        shape: NeuShape.convex,
        borderRadius: BorderRadius.circular(28),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: header,
            ),
            const SizedBox(height: 12),
            for (final PixaDestination dest in destinations)
              _RailPill(
                destination: dest,
                selected: dest.value == value,
                onTap: onChanged == null ? null : () => onChanged!(dest.value),
              ),
          ],
        ),
      ),
    );
  }
}

class _RailPill extends StatefulWidget {
  const _RailPill({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final PixaDestination destination;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_RailPill> createState() => _RailPillState();
}

class _RailPillState extends State<_RailPill> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.destination.label,
        container: true,
        excludeSemantics: true,
        child: NeuFocusable(
          enabled: widget.onTap != null,
          onActivate: widget.onTap,
          borderRadius: BorderRadius.circular(18),
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
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap?.call();
            },
            child: AnimatedScale(
              scale: _down ? 0.94 : 1.0,
              duration: const Duration(milliseconds: 100),
              child: Tooltip(
                message: widget.destination.label,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.selected ? 18 : 12,
                    vertical: 14,
                  ),
                  decoration: ShapeDecoration(
                    color: widget.selected
                        ? palette.accentSoft
                        : Colors.transparent,
                    shape: const RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.all(Radius.circular(18)),
                    ),
                  ),
                  child: Icon(
                    widget.selected
                        ? widget.destination.selectedIcon
                        : widget.destination.icon,
                    size: 24,
                    color: widget.selected ? palette.accent : palette.textMuted,
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

/// A neumorphic badge / stat pill used in headers and diagnostics.
class NeuStat extends StatelessWidget {
  const NeuStat({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.tone = NeuStatTone.neutral,
  });

  final String label;
  final String value;
  final IconData? icon;
  final NeuStatTone tone;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final Color toneColor = switch (tone) {
      NeuStatTone.neutral => palette.textSecondary,
      NeuStatTone.accent => palette.accent,
      NeuStatTone.success => palette.success,
      NeuStatTone.warning => palette.warning,
      NeuStatTone.error => palette.error,
    };
    return Semantics(
      // Read as a single phrase, e.g. "Cache hit, 42.0 percent".
      label: '$label $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(icon, size: 14, color: toneColor),
                ),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    letterSpacing: 0.4,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: toneColor,
              fontWeight: FontWeight.w800,
              fontSize: 22,
              letterSpacing: -0.4,
            ),
          ),
        ],
      ),
    );
  }
}

enum NeuStatTone { neutral, accent, success, warning, error }
