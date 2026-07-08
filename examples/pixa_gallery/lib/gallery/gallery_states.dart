import 'package:flexbox_layout/flexbox_layout.dart';
import 'package:flutter/material.dart';

import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_surface.dart';
import 'gallery_slivers.dart';

/// Skeleton loading sliver with shimmering neumorphic placeholders.
///
/// The skeleton mirrors the active feed layout so the first frame already
/// reserves the same geometry the real tiles will occupy, avoiding layout
/// jumps when the feed arrives. Aspect ratios come from [aspectRatios]; when
/// none are known (cold start) a representative sample is used so the
/// placeholder still reads as a believable gallery.
class GalleryLoadingSliver extends StatelessWidget {
  const GalleryLoadingSliver({
    super.key,
    this.count = 10,
    this.layout = GalleryLayout.flexRows,
    this.targetRowHeight = 180,
    this.aspectRatios,
  });

  final int count;
  final GalleryLayout layout;
  final double targetRowHeight;

  /// Optional real aspect ratios (e.g. from cached posts). Falls back to a
  /// representative gallery sample when null or too short.
  final List<double>? aspectRatios;

  List<double> get _ratios {
    final src = aspectRatios;
    if (src != null && src.length >= count) {
      return src.sublist(0, count);
    }
    // A believable mix of landscape, square and portrait tiles.
    const sample = <double>[
      1.5,
      1.0,
      1.33,
      0.75,
      1.2,
      0.8,
      1.5,
      1.0,
      0.67,
      1.25,
    ];
    return List<double>.generate(count, (i) => sample[i % sample.length]);
  }

  @override
  Widget build(BuildContext context) {
    final ratios = _ratios;
    switch (layout) {
      case GalleryLayout.flexRows:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          sliver: SliverFlexbox(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => _SkeletonTile(
                key: ValueKey<String>('skel-flex-$index'),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
              ),
              childCount: count,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
            ),
            flexboxDelegate: SliverFlexboxDelegateWithAspectRatios(
              aspectRatios: ratios,
              targetRowHeight: targetRowHeight,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
          ),
        );
      case GalleryLayout.masonry:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          sliver: SliverMasonryFlexbox(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => _SkeletonTile(
                key: ValueKey<String>('skel-mas-$index'),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
              ),
              childCount: count,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
            ),
            masonryDelegate: SliverMasonryFlexboxDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: (targetRowHeight * 1.28).clamp(150, 360),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childMainAxisExtentBuilder: (int index, double cross) {
                final r = ratios[index % ratios.length];
                return (cross / (r > 0 ? r : 1)).clamp(120, 360);
              },
            ),
          ),
        );
      case GalleryLayout.denseGrid:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: (targetRowHeight * 1.1).clamp(128, 300),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => _SkeletonTile(
                key: ValueKey<String>('skel-grid-$index'),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
              ),
              childCount: count,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
            ),
          ),
        );
    }
  }
}

class _SkeletonTile extends StatefulWidget {
  const _SkeletonTile({super.key, this.borderRadius});

  final BorderRadius? borderRadius;

  @override
  State<_SkeletonTile> createState() => _SkeletonTileState();
}

class _SkeletonTileState extends State<_SkeletonTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final BorderRadius radius =
        widget.borderRadius ?? BorderRadius.circular(18);
    return NeuSurface(
      shape: NeuShape.convex,
      elevation: NeuElevation.low,
      borderRadius: radius,
      padding: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          // Ease the sweep so the highlight breathes instead of strobing.
          final double t = Curves.easeInOut.transform(_controller.value);
          return DecoratedBox(
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Alignment(-1.2 + t * 2.4, 0),
                end: Alignment(-0.2 + t * 2.4, 0),
                colors: <Color>[
                  palette.base,
                  palette.lightShadow.withValues(alpha: 0.32),
                  palette.darkShadow.withValues(alpha: 0.18),
                  palette.base,
                ],
                stops: <double>[0.0, 0.45, 0.55, 1.0],
              ),
              shape: RoundedSuperellipseBorder(borderRadius: radius),
            ),
            child: child,
          );
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Full-screen error / empty state for the gallery feed.
class GalleryErrorState extends StatelessWidget {
  const GalleryErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Semantics(
          label: 'Gallery feed failed to load. $message. Double tap to retry.',
          button: false,
          child: NeuCard(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: palette.error.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.cloud_off_rounded,
                    color: palette.error,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Could not load feed',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Pull down to refresh, or tap retry. The image source may be '
                  'offline or rate-limited.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                // Raw error detail in a compact monospace-ish well, so the
                // actionable copy above stays readable while the technical
                // cause remains available for diagnosis.
                Container(
                  constraints: const BoxConstraints(maxHeight: 90),
                  decoration: ShapeDecoration(
                    color: palette.base.withValues(alpha: 0.5),
                    shape: const RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      message,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 11.5,
                        height: 1.35,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                NeuButton(
                  onPressed: onRetry,
                  accent: true,
                  icon: const Icon(Icons.refresh_rounded),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Infinite-scroll footer shown while paging the next page.
class GalleryLoadMoreBar extends StatelessWidget {
  const GalleryLoadMoreBar({super.key, required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (loading) ...<Widget>[
                NeuSpinner(size: 18),
                const SizedBox(width: 10),
              ],
              Text(
                loading ? 'Loading more' : 'End of feed',
                style: TextStyle(
                  color: palette.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
