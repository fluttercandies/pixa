import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'animation.dart';
import 'cache/decoded_cache_registry.dart';
import 'display_decoder.dart';
import 'pixa.dart';
import 'pipeline.dart';
import 'progress.dart';
import 'request.dart';
import 'source.dart';

/// Flutter ImageProvider backed by the Rust Pixa pipeline.
@immutable
final class PixaProvider extends ImageProvider<PixaProvider> {
  /// Creates a provider from a request.
  const PixaProvider({
    required this.request,
    this.generation = 0,
    this.onProgress,
    this.animationController,
    this.animationOptions = const PixaAnimationOptions(),
  });

  /// Creates a network provider.
  factory PixaProvider.network(
    String url, {
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    Map<String, String> headers = const <String, String>{},
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest(
        source: PixaSource.network(Uri.parse(url)),
        headers: headers,
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a file provider.
  factory PixaProvider.file(
    String path, {
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest.file(
        path,
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates an asset provider.
  factory PixaProvider.asset(
    String name, {
    String? package,
    AssetBundle? bundle,
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest(
        source: PixaSource.asset(name, package: package, bundle: bundle),
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a memory provider.
  factory PixaProvider.memory(
    String id,
    Uint8List bytes, {
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest(
        source: PixaSource.memory(id, bytes),
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a bytes provider.
  factory PixaProvider.bytes(
    Uint8List bytes, {
    String? id,
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest(
        source: PixaSource.bytes(bytes, id: id),
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a custom-source provider.
  factory PixaProvider.custom(
    String id,
    PixaCustomSourceLoader loader, {
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest.custom(
        id,
        loader,
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a provider routed through a runtime fetcher source kind.
  factory PixaProvider.runtimePlugin({
    required String sourceKind,
    required String locator,
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    Map<String, String> headers = const <String, String>{},
    PixaHeadersPolicy headersPolicy = const PixaHeadersPolicy(),
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest.runtimePlugin(
        sourceKind: sourceKind,
        locator: locator,
        headers: headers,
        headersPolicy: headersPolicy,
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// Creates a provider for a still frame extracted from a video.
  factory PixaProvider.videoFrame(
    String locator, {
    required Duration timestamp,
    PixaVideoFrameSelection frameSelection = PixaVideoFrameSelection.nearest,
    String? backend,
    int? targetWidth,
    int? targetHeight,
    double scale = 1.0,
    Map<String, String> headers = const <String, String>{},
    PixaHeadersPolicy headersPolicy = const PixaHeadersPolicy(),
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    ValueChanged<PixaProgress>? onProgress,
  }) {
    return PixaProvider(
      request: PixaRequest.videoFrame(
        locator,
        timestamp: timestamp,
        frameSelection: frameSelection,
        backend: backend,
        headers: headers,
        headersPolicy: headersPolicy,
        targetSize: PixaTargetSize(width: targetWidth, height: targetHeight),
        scale: scale,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
      ),
      onProgress: onProgress,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  /// runtime request.
  final PixaRequest request;

  /// Reload generation.
  final int generation;

  /// Listener-level progress callback.
  final ValueChanged<PixaProgress>? onProgress;

  /// Optional animated image playback controller.
  final PixaAnimationController? animationController;

  /// Animated image playback options.
  final PixaAnimationOptions animationOptions;

  @override
  Future<PixaProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<PixaProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    PixaProvider key,
    ImageDecoderCallback decode,
  ) {
    pixaDecodedCacheRegistry.track(
      namespace: key.request.cacheNamespace,
      cacheKey: key.request.cacheKey.value,
      key: key,
    );
    final _ProviderLoadTicket ticket = _ProviderLoadTicket();
    final ImageStreamCompleter completer = pixaDisplayDecoder.loadImage(
      request: key.request,
      startLoad: () => _startPipelineLoad(key, ticket),
      engineDecode: decode,
      scale: key.request.scale,
      debugLabel: key.request.cacheKey.debugLabel,
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Pixa source: ${key.request.source.safeLabel}'),
      ],
      maxConcurrent: Pixa.config.decodeConcurrency,
      maxQueued: Pixa.config.maxQueuedDecodes,
      maxCompletionsPerFrame: Pixa.config.maxImageCompletionsPerFrame,
      cancelled: ticket.whenCancelled,
      isCancelled: () => ticket.isCancelled,
      animationController: key.animationController,
      animationOptions: key.animationOptions,
    );
    completer.addOnLastListenerRemovedCallback(ticket.cancel);
    return completer;
  }

  Future<PixaDisplayPipelineLoad> _startPipelineLoad(
    PixaProvider key,
    _ProviderLoadTicket ticket,
  ) async {
    assert(key == this);
    await Pixa.ensureConfigured();
    final PixaPipeline pipeline = Pixa.pipeline;
    final PixaPipelineHandle handle = pipeline.startLoad(
      key.request,
      onProgress: key.onProgress,
    );
    ticket.attach(handle);
    final PixaPipelineLoad load = await handle.future;
    return PixaDisplayPipelineLoad(pipeline: pipeline, load: load);
  }

  @override
  bool operator ==(Object other) {
    return other is PixaProvider &&
        other.request.cacheKey == request.cacheKey &&
        other.generation == generation &&
        other._animationKey == _animationKey;
  }

  @override
  int get hashCode => Object.hash(request.cacheKey, generation, _animationKey);

  Object? get _animationKey {
    final PixaAnimationController? controller = animationController;
    if (controller == null) {
      return null;
    }
    return Object.hash(identityHashCode(controller), animationOptions);
  }

  @override
  String toString() => 'PixaProvider(${request.source.safeLabel})';
}

final class _ProviderLoadTicket {
  PixaPipelineHandle? _handle;
  Completer<void>? _cancelled;
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Future<void> get whenCancelled {
    if (_isCancelled) {
      return Future<void>.value();
    }
    return (_cancelled ??= Completer<void>.sync()).future;
  }

  void attach(PixaPipelineHandle handle) {
    if (_isCancelled) {
      handle.cancel();
      return;
    }
    _handle = handle;
  }

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _handle?.cancel();
    final Completer<void>? cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) {
      cancelled.complete();
    }
  }
}
