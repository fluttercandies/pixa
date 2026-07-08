import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../models/image_post.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';

/// Central place where every Pixa request / failure / format decision is
/// made for the gallery. Keeping these here means the UI layer never
/// rebuilds the same rule twice and the recipe surface stays auditable.

/// Build a network request for a post, sized for the current tile layout.
PixaRequest postRequest(ImagePost post, {required int targetPixels}) {
  return PixaRequest.network(
    post.imageUrl,
    targetSize: _targetSize(post, targetPixels),
    cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
    priority: PixaPriority.normal,
    retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
  );
}

/// Build a network request for an arbitrary URL with an explicit target
/// size and optional processor chain. Used by the Learn previews.
PixaRequest networkRequest(
  String url, {
  int? targetWidth,
  int? targetHeight,
  List<String>? processors,
  PixaCachePolicy? cachePolicy,
  PixaPriority priority = PixaPriority.normal,
}) {
  return PixaRequest.network(
    url,
    targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
    cachePolicy: cachePolicy ?? const PixaCachePolicy(),
    priority: priority,
  ).copyWith(processors: processors ?? const <String>[]);
}

/// Low-res chain request used for placeholder-to-full swaps.
PixaRequest? lowResRequest(ImagePost post, {int pixels = 32}) {
  final String? thumb = post.thumbnailUrl;
  if (thumb == null || thumb.isEmpty) {
    return null;
  }
  return PixaRequest.network(
    thumb,
    targetSize: _targetSize(post, pixels),
    cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 1)),
    priority: PixaPriority.high,
  );
}

PixaTargetSize _targetSize(ImagePost post, int pixels) {
  if (post.width <= 0 || post.height <= 0) {
    return PixaTargetSize(width: pixels, height: pixels);
  }
  final double ratio = post.width / post.height;
  if (ratio >= 1) {
    final int w = pixels;
    final int h = math.max(1, (pixels / ratio).round());
    return PixaTargetSize(width: w, height: h);
  }
  final int h = pixels;
  final int w = math.max(1, (pixels * ratio).round());
  return PixaTargetSize(width: w, height: h);
}

/// Default image-frame error builder reused across the app.
///
/// Surfaces the typed [PixaFailure] — stage + safe message + retryability —
/// inside a neumorphic, accessibility-labelled surface with a smooth fade-in
/// so failure states reveal consistently with the unified image transition.
///
/// Shows the failure stage, a human-readable message, and whether the error
/// is retryable. If the [PixaFailure] carries retryability info, the button
/// label reflects whether automatic retry is still possible.
Widget pixaErrorBuilder(
  BuildContext context,
  PixaFailure failure,
  VoidCallback retry,
) {
  final NeuPalette palette = context.neu;
  final bool canRetry = failure.retryability != PixaRetryability.notRetryable;
  final String stageLabel = _stageLabel(failure.stage);
  return Semantics(
    label:
        'Image failed to load. ${failure.safeMessage}. '
        '${canRetry ? 'Double tap to retry.' : 'Not retryable.'}',
    button: canRetry,
    container: true,
    excludeSemantics: true,
    child: _FadeInSurface(
      color: palette.error.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_rounded, color: palette.error, size: 22),
            const SizedBox(height: 4),
            // Stage badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: ShapeDecoration(
                color: palette.error.withValues(alpha: 0.15),
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
              ),
              child: Text(
                stageLabel,
                style: TextStyle(
                  color: palette.error,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              failure.safeMessage.isEmpty
                  ? 'Failed during $stageLabel'
                  : failure.safeMessage,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            NeuButton(
              onPressed: canRetry ? retry : null,
              disabled: !canRetry,
              icon: const Icon(Icons.refresh_rounded),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(canRetry ? 'Retry' : 'Failed'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Maps a [PixaStage] to a short uppercase label for the error badge.
String _stageLabel(PixaStage stage) {
  switch (stage) {
    case PixaStage.fetch:
      return 'NETWORK';
    case PixaStage.decode:
      return 'DECODE';
    case PixaStage.process:
      return 'PROCESS';
    case PixaStage.cacheLookup:
      return 'CACHE';
    case PixaStage.cacheWrite:
      return 'CACHE WRITE';
    case PixaStage.request:
      return 'REQUEST';
    case PixaStage.cancel:
      return 'CANCELLED';
    case PixaStage.complete:
      return 'COMPLETE';
  }
}

/// A fade-in wrapper used by failure states so they reveal with the same
/// rhythm as the unified image transition, not a hard pop-in.
class _FadeInSurface extends StatefulWidget {
  const _FadeInSurface({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<_FadeInSurface> createState() => _FadeInSurfaceState();
}

class _FadeInSurfaceState extends State<_FadeInSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kLearnTransitionDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: ColoredBox(
        color: widget.color,
        child: Center(child: widget.child),
      ),
    );
  }
}

/// Transparent tile error builder for large-image tiles so a single failed
/// tile never erases the overview.
Widget pixaTileErrorBuilder(
  BuildContext context,
  PixaFailure failure,
  VoidCallback retry,
) {
  return const SizedBox.expand();
}

/// Default loading progress builder.
Widget pixaProgressBuilder(BuildContext context, PixaProgress? progress) {
  final NeuPalette palette = context.neu;
  final int? received = progress?.receivedBytes;
  final int? expected = progress?.expectedBytes;
  final double? value = received != null && expected != null && expected > 0
      ? (received / expected).clamp(0.0, 1.0).toDouble()
      : null;
  return ColoredBox(
    color: palette.base,
    child: Center(child: NeuSpinner(value: value)),
  );
}

/// The single fade-in duration used by every Learn scenario image, so the
/// recipe catalog has one consistent reveal rhythm instead of a patchwork of
/// per-card durations (which read as visual jumps when scrolling the page).
const Duration kLearnTransitionDuration = Duration(milliseconds: 260);

/// The shared Learn-scenario placeholder: a flat surface-colored fill. Every
/// recipe uses this so the loading surface is identical across cards.
PixaPlaceholder learnPlaceholder(BuildContext context) =>
    PixaPlaceholder.color(context.neu.surface);

/// Scroll-safe progress builder for dense gallery tiles.
///
/// Unlike [pixaProgressBuilder], this deliberately avoids an animated spinner:
/// during fast scrolling every tile briefly shows its loading state, and a
/// per-tile spinner produces a flickering "twinkle" field. Instead this paints
/// a static surface-colored placeholder with an optional thin linear progress
/// bar pinned to the bottom — no continuous animation, so it composes cheaply
/// under a per-tile [RepaintBoundary] and stays visually calm while bytes
/// arrive. The gallery hot path keeps the focus on the photos, not on
/// indeterminate spinners.
Widget pixaTileProgressBuilder(BuildContext context, PixaProgress? progress) {
  final NeuPalette palette = context.neu;
  final int? received = progress?.receivedBytes;
  final int? expected = progress?.expectedBytes;
  final double? value = received != null && expected != null && expected > 0
      ? (received / expected).clamp(0.0, 1.0).toDouble()
      : null;
  return ColoredBox(
    color: palette.base,
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (value != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: TicklessLinearProgress(
              value: value,
              color: palette.accent,
              trackColor: palette.divider,
            ),
          ),
      ],
    ),
  );
}

/// A linear progress bar that never self-animates: it only paints the current
/// fraction, so it adds zero ongoing animation load during scrolling.
class TicklessLinearProgress extends StatelessWidget {
  const TicklessLinearProgress({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    this.height = 2,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _LinearProgressPainter(
          value: value.clamp(0.0, 1.0),
          color: color,
          trackColor: trackColor,
        ),
      ),
    );
  }
}

class _LinearProgressPainter extends CustomPainter {
  _LinearProgressPainter({
    required this.value,
    required this.color,
    required this.trackColor,
  });

  final double value;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint track = Paint()..color = trackColor;
    canvas.drawRect(Offset.zero & size, track);
    final Paint fill = Paint()..color = color;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * value, size.height), fill);
  }

  @override
  bool shouldRepaint(covariant _LinearProgressPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor;
}

/// Plain loading surface used by skeletons.
Widget pixaLoadingSurface(BuildContext context) {
  final NeuPalette palette = context.neu;
  return ColoredBox(
    color: palette.base,
    child: Center(child: NeuSpinner(size: 22)),
  );
}

/// Formats an integer byte count for diagnostics display.
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  return '$bytes B';
}

/// Formats a duration for diagnostics.
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) {
    return '${d.inMilliseconds} ms';
  }
  return '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
}

/// True if the runtime has a region decoder for [post]'s format.
bool postHasRegionDecode(ImagePost post) {
  final PixaImageMetadataFormat? format = formatFromImageUrl(post.imageUrl);
  if (format == null) {
    return false;
  }
  return PixaDebugInspector.snapshot().capabilities.imageFormats.any(
    (PixaRuntimeImageFormatCapability c) =>
        c.format == format && c.regionDecode,
  );
}

/// True if [post] is large enough to deserve the tiled large-image viewer.
bool postNeedsTiledViewer(ImagePost post) {
  return post.width * post.height >= 12 * 1024 * 1024 &&
      postHasRegionDecode(post);
}

/// True if [post] is large but has no region decode (overview only).
bool postNeedsOverviewOnly(ImagePost post) {
  return post.width * post.height >= 12 * 1024 * 1024 &&
      !postHasRegionDecode(post);
}

/// Detects an image metadata format from a URL suffix.
PixaImageMetadataFormat? formatFromImageUrl(String imageUrl) {
  final String path = Uri.tryParse(imageUrl)?.path.toLowerCase() ?? '';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
    return PixaImageMetadataFormat.jpeg;
  }
  if (path.endsWith('.png')) {
    return PixaImageMetadataFormat.png;
  }
  if (path.endsWith('.gif')) {
    return PixaImageMetadataFormat.gif;
  }
  if (path.endsWith('.webp')) {
    return PixaImageMetadataFormat.webp;
  }
  if (path.endsWith('.bmp')) {
    return PixaImageMetadataFormat.bmp;
  }
  if (path.endsWith('.wbmp')) {
    return PixaImageMetadataFormat.wbmp;
  }
  if (path.endsWith('.ico')) {
    return PixaImageMetadataFormat.ico;
  }
  if (path.endsWith('.tif') || path.endsWith('.tiff')) {
    return PixaImageMetadataFormat.tiff;
  }
  if (path.endsWith('.pnm') ||
      path.endsWith('.pbm') ||
      path.endsWith('.pgm') ||
      path.endsWith('.ppm') ||
      path.endsWith('.pam')) {
    return PixaImageMetadataFormat.pnm;
  }
  if (path.endsWith('.qoi')) {
    return PixaImageMetadataFormat.qoi;
  }
  if (path.endsWith('.tga')) {
    return PixaImageMetadataFormat.tga;
  }
  if (path.endsWith('.dds')) {
    return PixaImageMetadataFormat.dds;
  }
  if (path.endsWith('.hdr')) {
    return PixaImageMetadataFormat.hdr;
  }
  if (path.endsWith('.ff')) {
    return PixaImageMetadataFormat.farbfeld;
  }
  if (path.endsWith('.pcx')) {
    return PixaImageMetadataFormat.pcx;
  }
  if (path.endsWith('.sgi') ||
      path.endsWith('.rgb') ||
      path.endsWith('.rgba') ||
      path.endsWith('.bw')) {
    return PixaImageMetadataFormat.sgi;
  }
  if (path.endsWith('.xbm')) {
    return PixaImageMetadataFormat.xbm;
  }
  if (path.endsWith('.xpm')) {
    return PixaImageMetadataFormat.xpm;
  }
  return null;
}

/// A processor demo record used by the Learn page lab.
typedef ProcessorDemo = ({String label, List<String> processors});

/// Catalogue of every public Rust processor helper, for the Learn page.
List<ProcessorDemo> processorDemos() {
  return <ProcessorDemo>[
    (
      label: 'Resize fit',
      processors: <String>[PixaProcessors.resize(width: 280)],
    ),
    (
      label: 'Resize exact',
      processors: <String>[PixaProcessors.resizeExact(280, 200)],
    ),
    (
      label: 'Resize to fill',
      processors: <String>[PixaProcessors.resizeToFill(280, 200)],
    ),
    (
      label: 'Thumbnail',
      processors: <String>[PixaProcessors.thumbnail(280, 200)],
    ),
    (
      label: 'Thumbnail exact',
      processors: <String>[PixaProcessors.thumbnailExact(280, 200)],
    ),
    (
      label: 'Center crop',
      processors: <String>[
        PixaProcessors.crop(x: 40, y: 30, width: 240, height: 200),
      ],
    ),
    (label: 'Rotate 90°', processors: <String>[PixaProcessors.rotate(90)]),
    (label: 'Blur σ6', processors: <String>[PixaProcessors.blur(6)]),
    (label: 'Fast blur σ4', processors: <String>[PixaProcessors.fastBlur(4)]),
    (label: 'Grayscale', processors: <String>[PixaProcessors.grayscale()]),
    (label: 'Invert', processors: <String>[PixaProcessors.invert()]),
    (label: 'Flip H', processors: <String>[PixaProcessors.flipHorizontal()]),
    (label: 'Flip V', processors: <String>[PixaProcessors.flipVertical()]),
    (label: 'Brighten +40', processors: <String>[PixaProcessors.brighten(40)]),
    (label: 'Contrast 1.3', processors: <String>[PixaProcessors.contrast(1.3)]),
    (label: 'Hue 90°', processors: <String>[PixaProcessors.hueRotate(90)]),
    (
      label: 'Unsharpen',
      processors: <String>[PixaProcessors.unsharpen(sigma: 3, threshold: 40)],
    ),
    (
      label: 'Filter3×3 edge',
      processors: <String>[
        PixaProcessors.filter3x3(<double>[-1, -1, -1, -1, 8, -1, -1, -1, -1]),
      ],
    ),
  ];
}
