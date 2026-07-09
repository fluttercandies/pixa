library;

import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';

/// Stable plugin id for the official MJPEG video-frame backend.
const String pixaMjpegVideoFramePluginId = 'pixa.video_frame.mjpeg';

/// Fetcher descriptor id registered by [PixaMjpegVideoFramePlugin].
const String pixaMjpegVideoFrameDescriptorId = 'pixa.video_frame.mjpeg';

/// Runtime module id linked into the Pixa host when the manifest is enabled.
const String pixaMjpegVideoFrameModuleId = 'pixa.video_frame.mjpeg';

/// Backend route used by Pixa video-frame requests.
const String pixaMjpegVideoFrameBackendId = 'mjpeg';

/// Runtime ABI entrypoint exported by the Pixa runtime implementation.
const String pixaMjpegVideoFrameEntrypointSymbol =
    'pixa_mjpeg_video_frame_plugin_init';

/// Source kind claimed by the MJPEG video-frame backend.
const Set<String> pixaMjpegVideoFrameSourceKinds = <String>{
  'video-frame:mjpeg',
};

/// Encoded image MIME types produced by this backend.
const Set<String> pixaMjpegVideoFrameOutputMimeTypes = <String>{'image/jpeg'};

/// Descriptor registered by [PixaMjpegVideoFramePlugin].
const PixaRuntimeVideoFrameBackendDescriptor pixaMjpegVideoFrameDescriptor =
    PixaRuntimeVideoFrameBackendDescriptor(
      id: pixaMjpegVideoFrameDescriptorId,
      backendId: pixaMjpegVideoFrameBackendId,
      runtime: PixaRuntimeContract.hostLinkedPluginModule(
        moduleId: pixaMjpegVideoFrameModuleId,
        packageName: 'pixa_video_frame_mjpeg',
        implementationLanguage: 'rust',
        entrypointSymbol: pixaMjpegVideoFrameEntrypointSymbol,
      ),
      capabilities: PixaVideoFrameBackendCapabilities.encodedImage(
        outputMimeTypes: pixaMjpegVideoFrameOutputMimeTypes,
        nearestFrame: true,
        exactFrame: false,
        fileLocator: true,
        networkLocator: false,
        contentLocator: false,
        stable: true,
      ),
    );

/// Convenience API for the official MJPEG video-frame backend.
abstract final class PixaMjpegVideoFrame {
  /// Creates a video-frame source routed to the MJPEG backend.
  static PixaSource source(
    String locator, {
    required Duration timestamp,
    PixaVideoFrameSelection frameSelection = PixaVideoFrameSelection.nearest,
  }) {
    return PixaSource.videoFrame(
      locator,
      timestamp: timestamp,
      frameSelection: frameSelection,
      backend: pixaMjpegVideoFrameBackendId,
    );
  }

  /// Creates a Pixa request routed to the MJPEG backend.
  ///
  /// This is the `PixaMjpegVideoFrame.request` helper.
  static PixaRequest request(
    String locator, {
    required Duration timestamp,
    PixaVideoFrameSelection frameSelection = PixaVideoFrameSelection.nearest,
    Map<String, String> headers = const <String, String>{},
    PixaHeadersPolicy headersPolicy = const PixaHeadersPolicy(),
    String cacheNamespace = 'default',
    PixaTargetSize? targetSize,
    double scale = 1.0,
    BoxFit? fit,
    List<String> processors = const <String>[],
    Map<String, Object?> decoderOptions = const <String, Object?>{},
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRequestLimits limits = const PixaRequestLimits(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return PixaRequest.videoFrame(
      locator,
      timestamp: timestamp,
      frameSelection: frameSelection,
      backend: pixaMjpegVideoFrameBackendId,
      headers: headers,
      headersPolicy: headersPolicy,
      cacheNamespace: cacheNamespace,
      targetSize: targetSize,
      scale: scale,
      fit: fit,
      processors: processors,
      decoderOptions: decoderOptions,
      cachePolicy: cachePolicy,
      priority: priority,
      retryPolicy: retryPolicy,
      limits: limits,
      redirectPolicy: redirectPolicy,
      metadata: metadata,
    );
  }

  /// Creates a [PixaImage] routed to the MJPEG backend.
  ///
  /// This is the `PixaMjpegVideoFrame.image` helper.
  static PixaImage image(
    String locator, {
    required Duration timestamp,
    PixaVideoFrameSelection frameSelection = PixaVideoFrameSelection.nearest,
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    Map<String, String> headers = const <String, String>{},
    PixaHeadersPolicy headersPolicy = const PixaHeadersPolicy(),
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
  }) {
    return PixaImage(
      key: key,
      request: request(
        locator,
        timestamp: timestamp,
        frameSelection: frameSelection,
        headers: headers,
        headersPolicy: headersPolicy,
        targetSize: PixaTargetSize(
          width: width?.round(),
          height: height?.round(),
        ),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
      ),
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
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }
}

/// Registers the official MJPEG video-frame backend descriptor.
///
/// The package provides only descriptor/helpers and a runtime manifest. It does
/// not add Dart video decoding, FFmpeg/libav, or a second scheduler/cache path.
final class PixaMjpegVideoFramePlugin implements PixaPlugin {
  /// Creates the MJPEG video-frame plugin descriptor.
  const PixaMjpegVideoFramePlugin({this.hostRuntimeAvailable = false});

  /// Whether the root app enabled this package's `pixa_plugin.json`.
  ///
  /// Keep the default false for pub packages: the dependency itself cannot
  /// auto-link code into Pixa's runtime host.
  final bool hostRuntimeAvailable;

  @override
  String get id => pixaMjpegVideoFramePluginId;

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint(
        minimumInclusive: '1.0.0',
        maximumExclusive: '2.0.0',
      );

  @override
  void register(PixaRegistry registry) {
    registry.registerAdaptiveIntegration(
      pluginId: id,
      candidates: <PixaPluginIntegrationCandidate>[
        PixaPluginIntegrationCandidate.runtimeHost(
          id: 'runtime-host',
          packageName: 'pixa_video_frame_mjpeg',
          hostRuntimeAvailable: hostRuntimeAvailable,
          requiredIntegration: true,
          unavailableMessage:
              'Root app must enable plugin_manifest or '
              'plugin_manifest_directory for pixa_video_frame_mjpeg.',
          register: _registerMjpegVideoFrameBackend,
        ),
      ],
    );
  }
}

void _registerMjpegVideoFrameBackend(PixaRegistry registry) {
  registry.registerFetcher(pixaMjpegVideoFrameDescriptor);
}
