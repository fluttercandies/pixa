import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../large_image/tile_plan.dart';
import '../large_image/transform_scale.dart';
import '../pixa.dart';
import '../request.dart';
import '../source.dart';
import 'pixa_image.dart';

part 'pixa_large_image_controller.dart';
part 'pixa_large_image_state.dart';

/// Selects, positions, and renders visible tiles for very large images.
final class PixaLargeImage extends StatefulWidget {
  /// Creates a tiled image viewer from a base request and source dimensions.
  const PixaLargeImage({
    super.key,
    required this.request,
    required this.imageWidth,
    required this.imageHeight,
    this.controller,
    this.tileSize = 512,
    this.cacheExtentScreens = 1.0,
    this.maxVisibleTiles = 96,
    this.minScale,
    this.maxScale = 4.0,
    this.initialScale,
    this.doubleTapZoomEnabled = true,
    this.doubleTapZoomScale = 1.0,
    this.doubleTapZoomDuration = const Duration(milliseconds: 220),
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.medium,
    this.placeholder,
    this.progressBuilder,
    this.errorBuilder,
    this.tileErrorBuilder,
    this.backgroundColor = const Color(0xFF111318),
    this.overviewTargetPixels = 1024,
    this.showOverview = true,
    this.prefetchTiles = true,
    this.prefetchTarget = PixaPrefetchTarget.diskOnly,
    this.maxPrefetchTiles = 64,
    this.evictDecodedTilesOnExit = true,
    this.clipBehavior = Clip.hardEdge,
  }) : assert(imageWidth > 0),
       assert(imageHeight > 0),
       assert(tileSize > 0),
       assert(cacheExtentScreens >= 0),
       assert(maxVisibleTiles > 0),
       assert(maxScale > 0),
       assert(doubleTapZoomScale > 0),
       assert(overviewTargetPixels > 0),
       assert(maxPrefetchTiles >= 0),
       assert(prefetchTarget != PixaPrefetchTarget.decodedPrewarm);

  /// Creates a tiled network image viewer.
  factory PixaLargeImage.network(
    String url, {
    Key? key,
    required int imageWidth,
    required int imageHeight,
    PixaLargeImageController? controller,
    int tileSize = 512,
    double cacheExtentScreens = 1.0,
    int maxVisibleTiles = 96,
    double? minScale,
    double maxScale = 4.0,
    double? initialScale,
    bool doubleTapZoomEnabled = true,
    double doubleTapZoomScale = 1.0,
    Duration doubleTapZoomDuration = const Duration(milliseconds: 220),
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    PixaErrorBuilder? tileErrorBuilder,
    Color backgroundColor = const Color(0xFF111318),
    int overviewTargetPixels = 1024,
    bool showOverview = true,
    bool prefetchTiles = true,
    PixaPrefetchTarget prefetchTarget = PixaPrefetchTarget.diskOnly,
    int maxPrefetchTiles = 64,
    bool evictDecodedTilesOnExit = true,
    Clip clipBehavior = Clip.hardEdge,
    Map<String, String> headers = const <String, String>{},
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
  }) {
    return PixaLargeImage(
      key: key,
      request: PixaRequest(
        source: PixaSource.network(Uri.parse(url)),
        headers: headers,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      controller: controller,
      tileSize: tileSize,
      cacheExtentScreens: cacheExtentScreens,
      maxVisibleTiles: maxVisibleTiles,
      minScale: minScale,
      maxScale: maxScale,
      initialScale: initialScale,
      doubleTapZoomEnabled: doubleTapZoomEnabled,
      doubleTapZoomScale: doubleTapZoomScale,
      doubleTapZoomDuration: doubleTapZoomDuration,
      fit: fit,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      tileErrorBuilder: tileErrorBuilder,
      backgroundColor: backgroundColor,
      overviewTargetPixels: overviewTargetPixels,
      showOverview: showOverview,
      prefetchTiles: prefetchTiles,
      prefetchTarget: prefetchTarget,
      maxPrefetchTiles: maxPrefetchTiles,
      evictDecodedTilesOnExit: evictDecodedTilesOnExit,
      clipBehavior: clipBehavior,
    );
  }

  /// Base image request. Tile requests are derived from this request.
  final PixaRequest request;

  /// Source image width in pixels.
  final int imageWidth;

  /// Source image height in pixels.
  final int imageHeight;

  /// Optional controller for zoom, pan, and reset operations.
  final PixaLargeImageController? controller;

  /// Base tile edge length in source pixels before sampling.
  final int tileSize;

  /// Extra viewport-sized margin used to keep near-future tiles warm.
  final double cacheExtentScreens;

  /// Maximum number of tile widgets kept alive for one frame.
  final int maxVisibleTiles;

  /// Absolute minimum scene scale. Defaults to fit-to-viewport scale.
  final double? minScale;

  /// Absolute maximum scene scale.
  final double maxScale;

  /// Initial scene scale. Defaults to fit-to-viewport scale.
  final double? initialScale;

  /// Whether a double tap toggles between fit scale and [doubleTapZoomScale].
  final bool doubleTapZoomEnabled;

  /// Scene scale used when zooming in from a double tap.
  final double doubleTapZoomScale;

  /// Duration for double-tap zoom animation.
  final Duration doubleTapZoomDuration;

  /// Initial fit behavior.
  final BoxFit fit;

  /// Filter quality used by overview and tile widgets.
  final FilterQuality filterQuality;

  /// Placeholder used for overview loading.
  final PixaPlaceholder? placeholder;

  /// Progress builder used for overview loading.
  final PixaProgressBuilder? progressBuilder;

  /// Error builder used for overview loading and tile failures.
  final PixaErrorBuilder? errorBuilder;

  /// Optional error builder used for individual tile failures.
  ///
  /// Defaults to [errorBuilder] so existing callers keep the same behavior.
  final PixaErrorBuilder? tileErrorBuilder;

  /// Background color behind the image.
  final Color backgroundColor;

  /// Longest decoded edge for the low-resolution overview.
  final int overviewTargetPixels;

  /// Whether to render a full-image low-resolution overview under tiles.
  final bool showOverview;

  /// Whether near-viewport tiles should be prefetched through Pixa.
  final bool prefetchTiles;

  /// Cache target used for near-viewport tile prefetch.
  ///
  /// The default is disk-only to avoid retaining decoded or processed tile
  /// bytes for off-screen content.
  final PixaPrefetchTarget prefetchTarget;

  /// Maximum number of near-viewport tiles scheduled for prefetch per plan.
  final int maxPrefetchTiles;

  /// Whether decoded Flutter tile cache entries are evicted after leaving view.
  final bool evictDecodedTilesOnExit;

  /// Clip behavior for the viewer.
  final Clip clipBehavior;

  @override
  State<PixaLargeImage> createState() => _PixaLargeImageState();
}
