import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../request.dart';
import 'transform_scale.dart';

/// Immutable source image dimensions for tile planning.
@immutable
final class PixaLargeImageSize {
  /// Creates source image dimensions.
  const PixaLargeImageSize({required this.width, required this.height})
      : assert(width > 0),
        assert(height > 0);

  /// Source width in pixels.
  final int width;

  /// Source height in pixels.
  final int height;

  @override
  bool operator ==(Object other) {
    return other is PixaLargeImageSize &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);
}

/// One visible or prefetched tile.
@immutable
final class PixaLargeImageTile {
  const PixaLargeImageTile._({
    required this.sampleSize,
    required this.row,
    required this.column,
    required this.sourceRect,
    required this.decodedWidth,
    required this.decodedHeight,
  });

  /// Power-of-two source subsampling factor.
  final int sampleSize;

  /// Tile row at this sample size.
  final int row;

  /// Tile column at this sample size.
  final int column;

  /// Source pixel rectangle covered by this tile.
  final Rect sourceRect;

  /// Target decoded tile width.
  final int decodedWidth;

  /// Target decoded tile height.
  final int decodedHeight;

  /// Stable key for Flutter widget identity.
  String get key => 's$sampleSize-r$row-c$column-${sourceRect.width.round()}x'
      '${sourceRect.height.round()}';

  /// Builds the Pixa request for this tile.
  PixaRequest requestFor(PixaRequest base) {
    final int x = sourceRect.left.round();
    final int y = sourceRect.top.round();
    final int width = sourceRect.width.round();
    final int height = sourceRect.height.round();
    final List<String> processors = <String>[
      ...base.processors,
      'tile(x=$x,y=$y,width=$width,height=$height,'
          'decodedWidth=$decodedWidth,decodedHeight=$decodedHeight,'
          'sampleSize=$sampleSize,filter=triangle)',
    ];
    return base.copyWith(
      targetSize: PixaTargetSize(width: decodedWidth, height: decodedHeight),
      processors: processors,
      priority: PixaPriority.high,
      metadata: <String, Object?>{
        ...base.metadata,
        'largeImageTile': true,
        'tileSampleSize': sampleSize,
        'tileRow': row,
        'tileColumn': column,
      },
    );
  }
}

/// A tile plan for the current viewport and zoom.
@immutable
final class PixaLargeImageTilePlan {
  const PixaLargeImageTilePlan._({
    required this.visibleRect,
    required this.cacheRect,
    required this.sampleSize,
    required this.visibleTiles,
    required this.prefetchTiles,
  });

  /// Current visible source rectangle.
  final Rect visibleRect;

  /// Inflated source rectangle used for preloading near-future tiles.
  final Rect cacheRect;

  /// Selected power-of-two source subsampling factor.
  final int sampleSize;

  /// Ordered tiles intersecting the current viewport.
  final List<PixaLargeImageTile> visibleTiles;

  /// Ordered near-viewport tiles that should be prefetched but not rendered.
  final List<PixaLargeImageTile> prefetchTiles;

  /// Ordered visible and near-visible tiles.
  ///
  /// This is primarily useful for diagnostics and tests. Renderers should use
  /// [visibleTiles], then prefetch [prefetchTiles] through the pipeline.
  List<PixaLargeImageTile> get tiles => <PixaLargeImageTile>[
        ...visibleTiles,
        ...prefetchTiles,
      ];

  /// Number of visible and prefetch tiles in this plan.
  int get tileCount => visibleTiles.length + prefetchTiles.length;
}

final class _RawTilePlan {
  const _RawTilePlan({
    required this.visibleTiles,
    required this.prefetchTiles,
  });

  final List<PixaLargeImageTile> visibleTiles;

  final List<PixaLargeImageTile> prefetchTiles;
}

/// Computes tile coverage independently from widget rendering.
final class PixaLargeImageTilePlanner {
  /// Creates a tile planner.
  const PixaLargeImageTilePlanner({
    required this.imageSize,
    this.tileSize = 512,
    this.cacheExtentScreens = 1.0,
    this.maxVisibleTiles = 96,
  })  : assert(tileSize > 0),
        assert(cacheExtentScreens >= 0),
        assert(maxVisibleTiles > 0);

  /// Source image dimensions.
  final PixaLargeImageSize imageSize;

  /// Base tile edge length in source pixels before sampling.
  final int tileSize;

  /// Extra viewport-sized margin used to warm adjacent tiles.
  final double cacheExtentScreens;

  /// Maximum number of tiles returned.
  final int maxVisibleTiles;

  /// Returns the tile plan for the current transform.
  PixaLargeImageTilePlan plan({
    required Matrix4 transform,
    required Size viewportSize,
    required double devicePixelRatio,
  }) {
    if (viewportSize.isEmpty) {
      return PixaLargeImageTilePlan._(
        visibleRect: Rect.zero,
        cacheRect: Rect.zero,
        sampleSize: 1,
        visibleTiles: const <PixaLargeImageTile>[],
        prefetchTiles: const <PixaLargeImageTile>[],
      );
    }
    final Rect imageBounds = Rect.fromLTWH(
      0,
      0,
      imageSize.width.toDouble(),
      imageSize.height.toDouble(),
    );
    final Rect visibleRect =
        _visibleSourceRect(transform, viewportSize).intersect(imageBounds);
    if (visibleRect.isEmpty) {
      return PixaLargeImageTilePlan._(
        visibleRect: visibleRect,
        cacheRect: visibleRect,
        sampleSize: 1,
        visibleTiles: const <PixaLargeImageTile>[],
        prefetchTiles: const <PixaLargeImageTile>[],
      );
    }

    final double scale = math.max(
      pixaLargeImageTransformScale(transform),
      0.000001,
    );
    int sampleSize = _chooseSampleSize(scale, devicePixelRatio);
    Rect cacheRect = _inflateForCache(visibleRect, viewportSize, scale)
        .intersect(imageBounds);
    _RawTilePlan raw = _rawPlan(visibleRect, cacheRect, sampleSize);
    while (raw.visibleTiles.length > maxVisibleTiles) {
      final int nextSample = sampleSize * 2;
      if (nextSample > _maxSampleSize()) {
        break;
      }
      sampleSize = nextSample;
      raw = _rawPlan(visibleRect, cacheRect, sampleSize);
    }
    List<PixaLargeImageTile> visibleTiles = raw.visibleTiles;
    List<PixaLargeImageTile> prefetchTiles = raw.prefetchTiles;
    if (visibleTiles.length > maxVisibleTiles) {
      visibleTiles = visibleTiles.take(maxVisibleTiles).toList(growable: false);
      cacheRect = _boundsForTiles(visibleTiles);
      prefetchTiles = const <PixaLargeImageTile>[];
    }
    return PixaLargeImageTilePlan._(
      visibleRect: visibleRect,
      cacheRect: cacheRect,
      sampleSize: sampleSize,
      visibleTiles: List<PixaLargeImageTile>.unmodifiable(visibleTiles),
      prefetchTiles: List<PixaLargeImageTile>.unmodifiable(prefetchTiles),
    );
  }

  _RawTilePlan _rawPlan(Rect visibleRect, Rect cacheRect, int sampleSize) {
    final List<PixaLargeImageTile> visibleTiles =
        _sortByDistance(_tilesFor(visibleRect, sampleSize), visibleRect.center);
    final Set<String> visibleKeys = <String>{
      for (final PixaLargeImageTile tile in visibleTiles) tile.key,
    };
    final List<PixaLargeImageTile> prefetchTiles = _sortByDistance(
      _tilesFor(cacheRect, sampleSize)
          .where((PixaLargeImageTile tile) => !visibleKeys.contains(tile.key))
          .toList(growable: false),
      visibleRect.center,
    );
    return _RawTilePlan(
      visibleTiles: visibleTiles,
      prefetchTiles: prefetchTiles,
    );
  }

  List<PixaLargeImageTile> _sortByDistance(
    List<PixaLargeImageTile> tiles,
    Offset center,
  ) {
    tiles.sort((PixaLargeImageTile a, PixaLargeImageTile b) {
      final double ad = (a.sourceRect.center - center).distanceSquared;
      final double bd = (b.sourceRect.center - center).distanceSquared;
      return ad.compareTo(bd);
    });
    return tiles;
  }

  Rect _visibleSourceRect(Matrix4 transform, Size viewportSize) {
    final Matrix4 inverse = Matrix4.inverted(transform);
    final Offset a = MatrixUtils.transformPoint(inverse, Offset.zero);
    final Offset b = MatrixUtils.transformPoint(
      inverse,
      Offset(viewportSize.width, 0),
    );
    final Offset c = MatrixUtils.transformPoint(
      inverse,
      Offset(0, viewportSize.height),
    );
    final Offset d = MatrixUtils.transformPoint(
      inverse,
      Offset(viewportSize.width, viewportSize.height),
    );
    return Rect.fromLTRB(
      math.min(math.min(a.dx, b.dx), math.min(c.dx, d.dx)),
      math.min(math.min(a.dy, b.dy), math.min(c.dy, d.dy)),
      math.max(math.max(a.dx, b.dx), math.max(c.dx, d.dx)),
      math.max(math.max(a.dy, b.dy), math.max(c.dy, d.dy)),
    );
  }

  Rect _inflateForCache(Rect visible, Size viewportSize, double scale) {
    final double sourceViewportWidth = viewportSize.width / scale;
    final double sourceViewportHeight = viewportSize.height / scale;
    return Rect.fromLTRB(
      visible.left - sourceViewportWidth * cacheExtentScreens,
      visible.top - sourceViewportHeight * cacheExtentScreens,
      visible.right + sourceViewportWidth * cacheExtentScreens,
      visible.bottom + sourceViewportHeight * cacheExtentScreens,
    );
  }

  int _chooseSampleSize(double scale, double devicePixelRatio) {
    final double physicalScale = scale * math.max(devicePixelRatio, 1.0);
    final int maxSample = _maxSampleSize();
    var sample = 1;
    while (sample < maxSample && physicalScale * sample * 2 <= 1.15) {
      sample *= 2;
    }
    return sample;
  }

  int _maxSampleSize() {
    final int largestEdge = math.max(imageSize.width, imageSize.height);
    var sample = 1;
    while (largestEdge / (sample * 2) >= tileSize / 2) {
      sample *= 2;
    }
    return sample;
  }

  List<PixaLargeImageTile> _tilesFor(Rect rect, int sampleSize) {
    final int tileSpan = tileSize * sampleSize;
    final int maxColumn =
        math.max(0, ((imageSize.width - 1) / tileSpan).floor());
    final int maxRow = math.max(0, ((imageSize.height - 1) / tileSpan).floor());
    final int firstColumn = (rect.left / tileSpan).floor().clamp(0, maxColumn);
    final int lastColumn =
        ((rect.right - 0.001) / tileSpan).floor().clamp(firstColumn, maxColumn);
    final int firstRow = (rect.top / tileSpan).floor().clamp(0, maxRow);
    final int lastRow =
        ((rect.bottom - 0.001) / tileSpan).floor().clamp(firstRow, maxRow);
    final List<PixaLargeImageTile> tiles = <PixaLargeImageTile>[];
    for (int row = firstRow; row <= lastRow; row++) {
      for (int column = firstColumn; column <= lastColumn; column++) {
        final double left = column * tileSpan.toDouble();
        final double top = row * tileSpan.toDouble();
        final double right =
            math.min(left + tileSpan, imageSize.width.toDouble());
        final double bottom =
            math.min(top + tileSpan, imageSize.height.toDouble());
        final int decodedWidth =
            math.max(1, ((right - left) / sampleSize).ceil());
        final int decodedHeight =
            math.max(1, ((bottom - top) / sampleSize).ceil());
        tiles.add(PixaLargeImageTile._(
          sampleSize: sampleSize,
          row: row,
          column: column,
          sourceRect: Rect.fromLTRB(left, top, right, bottom),
          decodedWidth: decodedWidth,
          decodedHeight: decodedHeight,
        ));
      }
    }
    return tiles;
  }

  Rect _boundsForTiles(List<PixaLargeImageTile> tiles) {
    if (tiles.isEmpty) {
      return Rect.zero;
    }
    Rect bounds = tiles.first.sourceRect;
    for (final PixaLargeImageTile tile in tiles.skip(1)) {
      bounds = bounds.expandToInclude(tile.sourceRect);
    }
    return bounds;
  }
}
