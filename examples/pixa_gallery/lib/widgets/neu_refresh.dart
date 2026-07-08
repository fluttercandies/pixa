import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neu_palette.dart';
import 'neu_surface.dart';

/// A neumorphic replacement for Material's [RefreshIndicator].
///
/// Listens for overscroll at the top of the child scrollable and reveals a
/// raised neumorphic disc containing a [NeuSpinner]. The disc scales in as
/// the user pulls, snaps to a spin when the refresh threshold is reached,
/// and fades out when the refresh completes — matching the app's design
/// language instead of using the default Material circular indicator.
class NeuRefreshIndicator extends StatefulWidget {
  const NeuRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.refreshTriggerOffset = 80,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final double refreshTriggerOffset;

  @override
  State<NeuRefreshIndicator> createState() => _NeuRefreshIndicatorState();
}

class _NeuRefreshIndicatorState extends State<NeuRefreshIndicator> {
  double _dragOffset = 0;
  bool _refreshing = false;

  bool _onScroll(ScrollNotification n) {
    // Only react to overscroll at the very top.
    if (n is ScrollUpdateNotification && n.metrics.pixels <= 0) {
      final overscroll = (n.metrics.pixels).abs();
      if (overscroll > 0 && !_refreshing) {
        setState(() => _dragOffset = overscroll);
      } else if (overscroll == 0 && _dragOffset > 0) {
        setState(() => _dragOffset = 0);
      }
    } else if (n is ScrollEndNotification && _dragOffset > 0 && !_refreshing) {
      if (_dragOffset >= widget.refreshTriggerOffset) {
        _triggerRefresh();
      } else {
        setState(() => _dragOffset = 0);
      }
    }
    return false;
  }

  Future<void> _triggerRefresh() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _refreshing = true;
      _dragOffset = widget.refreshTriggerOffset;
    });
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _dragOffset = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    // Visibility fraction: 0 at rest, ramps to 1 at trigger offset.
    final frac = (_dragOffset / widget.refreshTriggerOffset).clamp(0.0, 1.0);
    final show = _dragOffset > 0 || _refreshing;

    return Stack(
      children: <Widget>[
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
        if (show)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedOpacity(
                opacity: frac.clamp(0.0, 1.0),
                duration: const Duration(milliseconds: 150),
                child: _NeuRefreshDisc(
                  refreshing: _refreshing,
                  progress: frac,
                  palette: palette,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NeuRefreshDisc extends StatelessWidget {
  const _NeuRefreshDisc({
    required this.refreshing,
    required this.progress,
    required this.palette,
  });

  final bool refreshing;
  final double progress;
  final NeuPalette palette;

  @override
  Widget build(BuildContext context) {
    final size = 44.0 * (0.6 + 0.4 * progress.clamp(0.0, 1.0));
    return NeuSurface(
      shape: NeuShape.convex,
      elevation: NeuElevation.medium,
      borderRadius: BorderRadius.circular(size / 2),
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: refreshing
              ? _SpinIcon(palette: palette)
              : TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 80),
                  builder: (context, v, child) {
                    return Transform.rotate(
                      angle: v * 4.5, // ~2.5 turns by full pull
                      child: child,
                    );
                  },
                  child: Icon(
                    Icons.refresh_rounded,
                    color: palette.accent,
                    size: size * 0.5,
                  ),
                ),
        ),
      ),
    );
  }
}

class _SpinIcon extends StatefulWidget {
  const _SpinIcon({required this.palette});
  final NeuPalette palette;

  @override
  State<_SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends State<_SpinIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return Transform.rotate(angle: _c.value * 6.283, child: child);
      },
      child: Icon(
        Icons.refresh_rounded,
        color: widget.palette.accent,
        size: 20,
      ),
    );
  }
}
