import 'package:flutter/material.dart';

import '../animation.dart';
import '../controller.dart';
import '../request.dart';
import '../source_set.dart';
import 'pixa_image.dart';

/// Layout-aware image widget backed by a [PixaSourceSet].
final class PixaResponsiveImage extends StatelessWidget {
  /// Creates a responsive Pixa image.
  const PixaResponsiveImage({
    super.key,
    required this.sourceSet,
    this.baseRequest,
    this.acceptedMimeTypes = const <String>[],
    this.controller,
    this.animationController,
    this.animationOptions = const PixaAnimationOptions(),
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.semanticLabel,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.placeholder,
    this.progressBuilder,
    this.errorBuilder,
    this.transitionDuration = Duration.zero,
    this.overlay,
    this.background,
    this.focusPoint,
    this.circle = false,
    this.borderRadius,
    this.pressOverlay,
    this.tapToRetry = true,
  });

  /// Candidate source set.
  final PixaSourceSet sourceSet;

  /// Base request whose policies are reused for the selected candidate.
  final PixaRequest? baseRequest;

  /// Preferred MIME types in descending order.
  final Iterable<String> acceptedMimeTypes;

  /// Optional lifecycle controller.
  final PixaController? controller;

  /// Optional animated image playback controller.
  final PixaAnimationController? animationController;

  /// Animated image playback options.
  final PixaAnimationOptions animationOptions;

  /// Width.
  final double? width;

  /// Height.
  final double? height;

  /// Fit.
  final BoxFit? fit;

  /// Alignment.
  final AlignmentGeometry alignment;

  /// Semantics label.
  final String? semanticLabel;

  /// Gapless playback.
  final bool gaplessPlayback;

  /// Filter quality.
  final FilterQuality filterQuality;

  /// Placeholder.
  final PixaPlaceholder? placeholder;

  /// Loading progress builder.
  final PixaProgressBuilder? progressBuilder;

  /// Error builder.
  final PixaErrorBuilder? errorBuilder;

  /// Cross-fade duration.
  final Duration transitionDuration;

  /// Overlay stacked above the image.
  final Widget? overlay;

  /// Background stacked below the image.
  final Widget? background;

  /// Optional focus point.
  final AlignmentGeometry? focusPoint;

  /// Clips image to a circle.
  final bool circle;

  /// Border radius.
  final BorderRadius? borderRadius;

  /// Press overlay.
  final Widget? pressOverlay;

  /// Whether tapping the default error UI retries.
  final bool tapToRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double logicalWidth = _resolvedExtent(
          width,
          constraints.maxWidth,
        );
        final double? logicalHeight =
            height ?? _finiteOrNull(constraints.maxHeight);
        final double devicePixelRatio =
            MediaQuery.maybeDevicePixelRatioOf(context) ??
            View.of(context).devicePixelRatio;
        final PixaRequest request = sourceSet.selectRequest(
          logicalWidth: logicalWidth,
          logicalHeight: logicalHeight,
          devicePixelRatio: devicePixelRatio,
          acceptedMimeTypes: acceptedMimeTypes,
          baseRequest: baseRequest,
          fit: fit,
        );
        return PixaImage(
          request: request,
          controller: controller,
          animationController: animationController,
          animationOptions: animationOptions,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          semanticLabel: semanticLabel,
          gaplessPlayback: gaplessPlayback,
          filterQuality: filterQuality,
          placeholder: placeholder,
          progressBuilder: progressBuilder,
          errorBuilder: errorBuilder,
          transitionDuration: transitionDuration,
          overlay: overlay,
          background: background,
          focusPoint: focusPoint,
          circle: circle,
          borderRadius: borderRadius,
          pressOverlay: pressOverlay,
          tapToRetry: tapToRetry,
        );
      },
    );
  }
}

double _resolvedExtent(double? explicit, double constraint) {
  if (explicit != null && explicit.isFinite && explicit > 0) {
    return explicit;
  }
  if (constraint.isFinite && constraint > 0) {
    return constraint;
  }
  return 1;
}

double? _finiteOrNull(double value) {
  return value.isFinite && value > 0 ? value : null;
}
