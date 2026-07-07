import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'animation.dart';
import 'failure.dart';
import 'image_format_catalog.dart';
import 'observer.dart';
import 'pipeline.dart';
import 'progress.dart';
import 'request.dart';
import 'runtime/runtime_loader.dart';

/// Internal singleton used by [PixaProvider] to select a display decoder.
final PixaDisplayDecoder pixaDisplayDecoder = PixaDisplayDecoder._(
  defaultBackend: 'engine',
  backends: const <_DisplayDecoderBackend>[
    _RuntimeDisplayDecoderBackend(),
    _EngineDisplayDecoderBackend(),
  ],
);

/// Selects and executes the display decoder backend for Flutter image streams.
final class PixaDisplayDecoder {
  const PixaDisplayDecoder._({
    required String defaultBackend,
    required List<_DisplayDecoderBackend> backends,
  }) : _defaultBackend = defaultBackend,
       _backends = backends;

  final String _defaultBackend;
  final List<_DisplayDecoderBackend> _backends;

  /// Captures backend selection capabilities for debug tooling.
  PixaDisplayDecoderSnapshot snapshot() {
    final _ImageCompletionGateSnapshot completionGate = _completionGate
        .snapshot();
    return PixaDisplayDecoderSnapshot(
      selector: 'pixa-display-decoder-v1',
      defaultBackend: _defaultBackend,
      hasRuntimeDisplayBackend: _backends.any(
        (_DisplayDecoderBackend backend) => backend.execution == 'runtime',
      ),
      completionQueueDepth: completionGate.queueDepth,
      completionsReleasedThisFrame: completionGate.releasedThisFrame,
      completionFrameScheduled: completionGate.frameScheduled,
      backends: _backends
          .map(
            (_DisplayDecoderBackend backend) =>
                PixaDisplayDecoderBackendSnapshot(
                  id: backend.id,
                  execution: backend.execution,
                  streamKind: backend.streamKind,
                  usesFlutterEngine: backend.usesFlutterEngine,
                  ownsPipeline: backend.ownsPipeline,
                  supportsAnimatedImages: backend.supportsAnimatedImages,
                ),
          )
          .toList(growable: false),
    );
  }

  /// Creates the image stream completer for the selected display backend.
  ImageStreamCompleter loadImage({
    required PixaRequest request,
    required Future<PixaDisplayPipelineLoad> Function() startLoad,
    required ImageDecoderCallback engineDecode,
    required double scale,
    required String debugLabel,
    required InformationCollector informationCollector,
    required int maxConcurrent,
    required int maxQueued,
    required int maxCompletionsPerFrame,
    required Future<void> cancelled,
    required bool Function() isCancelled,
    required PixaAnimationController? animationController,
    required PixaAnimationOptions animationOptions,
  }) {
    final _DisplayDecoderBackend backend = _select(request);
    return backend.loadImage(
      decoder: this,
      request: request,
      startLoad: startLoad,
      engineDecode: engineDecode,
      scale: scale,
      debugLabel: debugLabel,
      informationCollector: informationCollector,
      maxConcurrent: maxConcurrent,
      maxQueued: maxQueued,
      maxCompletionsPerFrame: maxCompletionsPerFrame,
      cancelled: cancelled,
      isCancelled: isCancelled,
      animationController: animationController,
      animationOptions: animationOptions,
    );
  }

  Future<ui.Codec> _loadCodec({
    required _DisplayDecoderBackend backend,
    required PixaRequest request,
    required Future<PixaDisplayPipelineLoad> Function() startLoad,
    required ImageDecoderCallback engineDecode,
    required int maxConcurrent,
    required int maxQueued,
    required int maxCompletionsPerFrame,
    required Future<void> cancelled,
    required bool Function() isCancelled,
  }) async {
    PixaPipeline? pipeline;
    PixaPipelineLoad? load;
    var decodeBackend = backend;
    _DecodePermit? permit;
    Stopwatch? decodeClock;
    try {
      final PixaDisplayPipelineLoad pipelineLoad = await startLoad();
      pipeline = pipelineLoad.pipeline;
      load = pipelineLoad.load;
      final PixaImageFormatCatalog formatCatalog = PixaImageFormatCatalog(
        registry: pipeline.registry,
      );
      decodeBackend = _effectiveBackendForPayload(
        backend,
        request,
        load.bytes,
        outputMimeType: load.mimeType,
        requestId: load.requestId,
        formatCatalog: formatCatalog,
      );
      _emit(
        pipeline,
        PixaEvent(
          requestId: load.requestId,
          stage: PixaStage.decode,
          name: 'decode.queued',
          request: request,
          attributes: _attributes(decodeBackend, <String, Object?>{
            'maxConcurrent': maxConcurrent,
            'maxQueued': maxQueued,
          }),
        ),
      );
      permit = await _decodeLimiter.acquire(
        maxConcurrent: maxConcurrent,
        maxQueued: maxQueued,
        cancelled: cancelled,
      );
      if (isCancelled()) {
        throw PixaFailure(
          requestId: load.requestId,
          stage: PixaStage.cancel,
          safeMessage: 'Pixa decode was cancelled before start.',
          retryability: PixaRetryability.notRetryable,
        );
      }
      decodeClock = Stopwatch()..start();
      _emit(
        pipeline,
        PixaEvent(
          requestId: load.requestId,
          stage: PixaStage.decode,
          name: 'decode.start',
          request: request,
          attributes: _attributes(decodeBackend, <String, Object?>{
            'activeDecodes': _decodeLimiter.active,
            'queuedDecodes': _decodeLimiter.queued,
            'maxConcurrent': _decodeLimiter.maxConcurrent,
            'maxQueued': _decodeLimiter.maxQueued,
          }),
        ),
      );
      final ui.Codec codec = await decodeBackend.decode(
        request: request,
        load: load,
        engineDecode: engineDecode,
      );
      _emit(
        pipeline,
        PixaEvent(
          requestId: load.requestId,
          stage: PixaStage.decode,
          name: 'decode.complete',
          request: request,
          durationMicros: decodeClock.elapsedMicroseconds,
          attributes: _attributes(decodeBackend),
        ),
      );
      permit.release();
      permit = null;
      await _completionGate.wait(maxPerFrame: maxCompletionsPerFrame);
      return codec;
    } on _DecodeCancelled {
      final PixaPipeline? currentPipeline = pipeline;
      final PixaPipelineLoad? currentLoad = load;
      if (currentPipeline == null || currentLoad == null) {
        rethrow;
      }
      throw PixaFailure(
        requestId: currentLoad.requestId,
        stage: PixaStage.cancel,
        safeMessage: 'Pixa decode was cancelled before image delivery.',
        retryability: PixaRetryability.notRetryable,
      );
    } on _DecodeQueueFull {
      final PixaFailure failure = PixaFailure(
        requestId: load!.requestId,
        stage: PixaStage.decode,
        safeMessage:
            'Pixa decode queue is full. Increase maxQueuedDecodes or reduce simultaneous image loads.',
        retryability: PixaRetryability.notRetryable,
      );
      _emitFailure(
        pipeline!,
        request,
        load,
        decodeBackend,
        failure,
        decodeClock,
      );
      throw failure;
    } on PixaFailure catch (failure) {
      if (isCancelled() && failure.stage == PixaStage.cancel) {
        throw const _DecodeCancelled();
      }
      final PixaPipeline? currentPipeline = pipeline;
      final PixaPipelineLoad? currentLoad = load;
      if (currentPipeline != null && currentLoad != null) {
        _emitFailure(
          currentPipeline,
          request,
          currentLoad,
          decodeBackend,
          failure,
          decodeClock,
        );
      }
      rethrow;
    } on Object {
      final PixaPipeline? currentPipeline = pipeline;
      final PixaPipelineLoad? currentLoad = load;
      if (currentPipeline != null && currentLoad != null) {
        _emitFailure(
          currentPipeline,
          request,
          currentLoad,
          decodeBackend,
          null,
          decodeClock,
        );
      }
      rethrow;
    } finally {
      permit?.release();
      load?.dispose();
    }
  }

  _DisplayDecoderBackend _select(PixaRequest request) {
    for (final _DisplayDecoderBackend backend in _backends) {
      if (backend.supports(request)) {
        return backend;
      }
    }
    throw PixaFailure(
      requestId: 0,
      stage: PixaStage.decode,
      safeMessage: 'No supported Pixa display decoder backend is available.',
      retryability: PixaRetryability.notRetryable,
    );
  }
}

/// Pipeline output paired with the pipeline that should receive decode events.
final class PixaDisplayPipelineLoad {
  /// Creates a display pipeline load wrapper.
  const PixaDisplayPipelineLoad({required this.pipeline, required this.load});

  /// Pipeline that produced [load].
  final PixaPipeline pipeline;

  /// Encoded pipeline output.
  final PixaPipelineLoad load;
}

/// Debug snapshot describing display decoder backend selection.
final class PixaDisplayDecoderSnapshot {
  /// Creates a display decoder snapshot.
  const PixaDisplayDecoderSnapshot({
    required this.selector,
    required this.defaultBackend,
    required this.hasRuntimeDisplayBackend,
    required this.completionQueueDepth,
    required this.completionsReleasedThisFrame,
    required this.completionFrameScheduled,
    required this.backends,
  });

  /// Stable selector identifier.
  final String selector;

  /// Backend selected for the default request path.
  final String defaultBackend;

  /// Whether a runtime display backend is currently registered.
  final bool hasRuntimeDisplayBackend;

  /// Pending decoded image completions waiting for frame-paced delivery.
  final int completionQueueDepth;

  /// Number of image completions already released in the current frame.
  final int completionsReleasedThisFrame;

  /// Whether a frame callback is scheduled to drain pending completions.
  final bool completionFrameScheduled;

  /// Registered display backends.
  final List<PixaDisplayDecoderBackendSnapshot> backends;

  /// JSON-like representation for debug UIs.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'selector': selector,
      'defaultBackend': defaultBackend,
      'hasRuntimeDisplayBackend': hasRuntimeDisplayBackend,
      'completionQueueDepth': completionQueueDepth,
      'completionsReleasedThisFrame': completionsReleasedThisFrame,
      'completionFrameScheduled': completionFrameScheduled,
      'backends': backends
          .map((PixaDisplayDecoderBackendSnapshot backend) => backend.toJson())
          .toList(growable: false),
    };
  }
}

/// Debug snapshot for a registered display decoder backend.
final class PixaDisplayDecoderBackendSnapshot {
  /// Creates a backend snapshot.
  const PixaDisplayDecoderBackendSnapshot({
    required this.id,
    required this.execution,
    required this.streamKind,
    required this.usesFlutterEngine,
    required this.ownsPipeline,
    required this.supportsAnimatedImages,
  });

  /// Stable backend id.
  final String id;

  /// Execution boundary, for example `flutter` or `runtime`.
  final String execution;

  /// Stream shape produced by this backend.
  final String streamKind;

  /// Whether this backend ultimately uses Flutter engine image decode.
  final bool usesFlutterEngine;

  /// Whether this backend owns network/cache/scheduler pipeline work.
  final bool ownsPipeline;

  /// Whether this backend supports animated image streams.
  final bool supportsAnimatedImages;

  /// JSON-like representation for debug UIs.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'execution': execution,
      'streamKind': streamKind,
      'usesFlutterEngine': usesFlutterEngine,
      'ownsPipeline': ownsPipeline,
      'supportsAnimatedImages': supportsAnimatedImages,
    };
  }
}

abstract interface class _DisplayDecoderBackend {
  String get id;

  String get execution;

  String get streamKind;

  bool get usesFlutterEngine;

  bool get ownsPipeline;

  bool get supportsAnimatedImages;

  bool supports(PixaRequest request);

  ImageStreamCompleter loadImage({
    required PixaDisplayDecoder decoder,
    required PixaRequest request,
    required Future<PixaDisplayPipelineLoad> Function() startLoad,
    required ImageDecoderCallback engineDecode,
    required double scale,
    required String debugLabel,
    required InformationCollector informationCollector,
    required int maxConcurrent,
    required int maxQueued,
    required int maxCompletionsPerFrame,
    required Future<void> cancelled,
    required bool Function() isCancelled,
    required PixaAnimationController? animationController,
    required PixaAnimationOptions animationOptions,
  });

  Future<ui.Codec> decode({
    required PixaRequest request,
    required PixaPipelineLoad load,
    required ImageDecoderCallback engineDecode,
  });
}

_DisplayDecoderBackend _effectiveBackendForPayload(
  _DisplayDecoderBackend selected,
  PixaRequest request,
  Uint8List bytes, {
  required String? outputMimeType,
  required int requestId,
  required PixaImageFormatCatalog formatCatalog,
}) {
  if (!selected.usesFlutterEngine) {
    return selected;
  }
  final PixaImageFormatRoute? route =
      formatCatalog.routeForPayload(bytes, mimeType: outputMimeType) ??
      formatCatalog.routeForPayload(
        bytes,
        formatId: request.decoderOptions['formatId'],
        mimeType: request.decoderOptions['mimeType'],
      );
  if (route == null) {
    throw PixaFailure(
      requestId: requestId,
      stage: PixaStage.decode,
      safeMessage:
          'Unsupported image format. Pixa only sends declared engine-backed formats to Flutter engine decode.',
      retryability: PixaRetryability.notRetryable,
    );
  }
  if (route.defaultRuntimeDisplay && route.capabilities.runtimeDisplay) {
    return const _RuntimeDisplayDecoderBackend();
  }
  if (!route.capabilities.engineDisplay) {
    final String routeName =
        route.formatId ?? route.mimeType ?? route.source.name;
    throw PixaFailure(
      requestId: requestId,
      stage: PixaStage.decode,
      safeMessage:
          'Unsupported image format $routeName. No Pixa display backend is available for this route.',
      retryability: PixaRetryability.notRetryable,
    );
  }
  return selected;
}

final class _RuntimeDisplayDecoderBackend implements _DisplayDecoderBackend {
  const _RuntimeDisplayDecoderBackend();

  @override
  String get id => 'runtime-rgba';

  @override
  String get execution => 'runtime';

  @override
  String get streamKind => 'single-frame-rgba-codec';

  @override
  bool get usesFlutterEngine => false;

  @override
  bool get ownsPipeline => false;

  @override
  bool get supportsAnimatedImages => false;

  @override
  bool supports(PixaRequest request) {
    final Object? option = request.decoderOptions['displayBackend'];
    if (option is String) {
      final String normalized = option.trim().toLowerCase();
      if (normalized == 'runtime' || normalized == 'runtime-rgba') {
        return true;
      }
      if (normalized == 'engine' || normalized == 'flutter') {
        return false;
      }
    }
    final PixaImageFormatRoute? route = const PixaImageFormatCatalog()
        .routeForMimeType(request.decoderOptions['mimeType']);
    if (route?.defaultRuntimeDisplay == true) {
      return true;
    }
    return request.pluginExecutionPolicy.usesRuntimeOnly &&
        request.processors.isNotEmpty &&
        request.processors.every(_isRuntimeDisplayProcessor);
  }

  @override
  ImageStreamCompleter loadImage({
    required PixaDisplayDecoder decoder,
    required PixaRequest request,
    required Future<PixaDisplayPipelineLoad> Function() startLoad,
    required ImageDecoderCallback engineDecode,
    required double scale,
    required String debugLabel,
    required InformationCollector informationCollector,
    required int maxConcurrent,
    required int maxQueued,
    required int maxCompletionsPerFrame,
    required Future<void> cancelled,
    required bool Function() isCancelled,
    required PixaAnimationController? animationController,
    required PixaAnimationOptions animationOptions,
  }) {
    return MultiFrameImageStreamCompleter(
      codec: decoder._loadCodec(
        backend: this,
        request: request,
        startLoad: startLoad,
        engineDecode: engineDecode,
        maxConcurrent: maxConcurrent,
        maxQueued: maxQueued,
        maxCompletionsPerFrame: maxCompletionsPerFrame,
        cancelled: cancelled,
        isCancelled: isCancelled,
      ),
      scale: scale,
      debugLabel: debugLabel,
      informationCollector: informationCollector,
    );
  }

  @override
  Future<ui.Codec> decode({
    required PixaRequest request,
    required PixaPipelineLoad load,
    required ImageDecoderCallback engineDecode,
  }) async {
    PixaRuntimeRgbaImage? rgba = load.decodeRuntimeRgba(
      maxDecodedPixels: request.limits.maxDecodedPixels,
      maxOutputBytes: request.limits.maxProcessorOutputBytes,
    );
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rgba.bytes);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: rgba.width,
        height: rgba.height,
        rowBytes: rgba.rowBytes,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: request.targetSize?.width,
        targetHeight: request.targetSize?.height,
      );
      final _RetainedRuntimeCodec retained = _RetainedRuntimeCodec(
        codec: codec,
        descriptor: descriptor,
        buffer: buffer,
        rgba: rgba,
      );
      descriptor = null;
      buffer = null;
      rgba = null;
      return retained;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
      rgba?.dispose();
    }
  }
}

final class _RetainedRuntimeCodec implements ui.Codec {
  _RetainedRuntimeCodec({
    required ui.Codec codec,
    required ui.ImageDescriptor descriptor,
    required ui.ImmutableBuffer buffer,
    required PixaRuntimeRgbaImage rgba,
  }) : _codec = codec,
       _descriptor = descriptor,
       _buffer = buffer,
       _rgba = rgba;

  final ui.Codec _codec;
  final ui.ImageDescriptor _descriptor;
  final ui.ImmutableBuffer _buffer;
  final PixaRuntimeRgbaImage _rgba;
  bool _isDisposed = false;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() => _codec.getNextFrame();

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _codec.dispose();
    _descriptor.dispose();
    _buffer.dispose();
    _rgba.dispose();
  }
}

bool _isRuntimeDisplayProcessor(String descriptor) {
  final String operation = _normalizeRuntimeProcessorOperation(
    descriptor.split('(').first,
  );
  return switch (operation) {
    'resize' ||
    'resizeexact' ||
    'resizetofill' ||
    'centercrop' ||
    'crop' ||
    'tile' ||
    'tilecropresize' ||
    'rotate' ||
    'blur' ||
    'fastblur' ||
    'filter3x3' ||
    'fliphorizontal' ||
    'fliph' ||
    'flipvertical' ||
    'flipv' ||
    'grayscale' ||
    'greyscale' ||
    'invert' ||
    'brighten' ||
    'brightness' ||
    'contrast' ||
    'huerotate' ||
    'unsharpen' ||
    'unsharpmask' ||
    'watermark' => true,
    _ => false,
  };
}

String _normalizeRuntimeProcessorOperation(String operation) {
  final String lower = operation.trim().toLowerCase();
  final StringBuffer buffer = StringBuffer();
  for (final int codeUnit in lower.codeUnits) {
    final bool isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
    final bool isAsciiLower = codeUnit >= 0x61 && codeUnit <= 0x7a;
    if (isDigit || isAsciiLower) {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}

final class _EngineDisplayDecoderBackend implements _DisplayDecoderBackend {
  const _EngineDisplayDecoderBackend();

  @override
  String get id => 'engine';

  @override
  String get execution => 'flutter';

  @override
  String get streamKind => 'multi-frame-codec';

  @override
  bool get usesFlutterEngine => true;

  @override
  bool get ownsPipeline => false;

  @override
  bool get supportsAnimatedImages => true;

  @override
  bool supports(PixaRequest request) => true;

  @override
  ImageStreamCompleter loadImage({
    required PixaDisplayDecoder decoder,
    required PixaRequest request,
    required Future<PixaDisplayPipelineLoad> Function() startLoad,
    required ImageDecoderCallback engineDecode,
    required double scale,
    required String debugLabel,
    required InformationCollector informationCollector,
    required int maxConcurrent,
    required int maxQueued,
    required int maxCompletionsPerFrame,
    required Future<void> cancelled,
    required bool Function() isCancelled,
    required PixaAnimationController? animationController,
    required PixaAnimationOptions animationOptions,
  }) {
    final Future<ui.Codec> codec = decoder._loadCodec(
      backend: this,
      request: request,
      startLoad: startLoad,
      engineDecode: engineDecode,
      maxConcurrent: maxConcurrent,
      maxQueued: maxQueued,
      maxCompletionsPerFrame: maxCompletionsPerFrame,
      cancelled: cancelled,
      isCancelled: isCancelled,
    );
    final PixaAnimationController? controller = animationController;
    if (controller != null) {
      return PixaControlledAnimatedImageStreamCompleter(
        codec: codec,
        scale: scale,
        debugLabel: debugLabel,
        informationCollector: informationCollector,
        controller: controller,
        options: animationOptions,
      );
    }
    return _PixaMultiFrameImageStreamCompleter(
      codec: codec,
      scale: scale,
      debugLabel: debugLabel,
      informationCollector: informationCollector,
    );
  }

  @override
  Future<ui.Codec> decode({
    required PixaRequest request,
    required PixaPipelineLoad load,
    required ImageDecoderCallback engineDecode,
  }) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      load.bytes,
    );
    return engineDecode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        _validateDecodedPixels(
          requestId: load.requestId,
          intrinsicWidth: intrinsicWidth,
          intrinsicHeight: intrinsicHeight,
          target: request.targetSize,
          maxDecodedPixels: request.limits.maxDecodedPixels,
        );
        return ui.TargetImageSize(
          width: request.targetSize?.width,
          height: request.targetSize?.height,
        );
      },
    );
  }
}

final class _PixaMultiFrameImageStreamCompleter
    extends MultiFrameImageStreamCompleter {
  _PixaMultiFrameImageStreamCompleter({
    required super.codec,
    required super.scale,
    super.debugLabel,
    super.informationCollector,
  });

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    if (!hasListeners && _isPixaCancellation(exception)) {
      return;
    }
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }
}

bool _isPixaCancellation(Object exception) {
  return exception is _DecodeCancelled ||
      exception is PixaFailure && exception.stage == PixaStage.cancel;
}

/// Image stream completer that lets Pixa control animated frame scheduling.
final class PixaControlledAnimatedImageStreamCompleter
    extends ImageStreamCompleter {
  /// Creates a controlled animated image stream completer.
  PixaControlledAnimatedImageStreamCompleter({
    required Future<ui.Codec> codec,
    required double scale,
    required String debugLabel,
    required InformationCollector informationCollector,
    required PixaAnimationController controller,
    required PixaAnimationOptions options,
  }) : _scale = scale,
       _informationCollector = informationCollector,
       _controller = controller,
       _options = options {
    this.debugLabel = debugLabel;
    _controller.addListener(_handlePlaybackChanged);
    codec.then<void>(
      _handleCodecReady,
      onError: (Object error, StackTrace stack) {
        if (_isDisposed) {
          return;
        }
        reportError(
          context: ErrorDescription('resolving an image codec'),
          exception: error,
          stack: stack,
          informationCollector: _informationCollector,
          silent: true,
        );
      },
    );
  }

  final double _scale;
  final InformationCollector _informationCollector;
  final PixaAnimationController _controller;
  final PixaAnimationOptions _options;
  ui.Codec? _codec;
  ui.FrameInfo? _nextFrame;
  Duration? _frameDuration;
  late Duration _shownTimestamp;
  Timer? _timer;
  var _framesEmitted = 0;
  var _isDisposed = false;
  var _isDecoding = false;
  var _frameCallbackScheduled = false;

  @override
  void addListener(ImageStreamListener listener) {
    final bool hadListeners = hasListeners;
    super.addListener(listener);
    if (!hadListeners) {
      _startPlaybackIfNeeded();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _cancelTimer();
    }
  }

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    if (!hasListeners && _isPixaCancellation(exception)) {
      return;
    }
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }

  @override
  void onDisposed() {
    _isDisposed = true;
    _cancelTimer();
    _controller.removeListener(_handlePlaybackChanged);
    _disposeNextFrame();
    _codec?.dispose();
    _codec = null;
    super.onDisposed();
  }

  void _handleCodecReady(ui.Codec codec) {
    if (_isDisposed) {
      codec.dispose();
      return;
    }
    _codec = codec;
    _startPlaybackIfNeeded();
  }

  void _handlePlaybackChanged() {
    if (_controller.state == PixaAnimationPlaybackState.playing) {
      _startPlaybackIfNeeded();
      return;
    }
    _cancelTimer();
    if (_shouldDisposePendingFrame(_controller.state)) {
      _disposeNextFrame();
    }
  }

  void _startPlaybackIfNeeded() {
    if (!_canScheduleFrames) {
      return;
    }
    if (_nextFrame != null) {
      _scheduleAppFrame();
      return;
    }
    unawaited(_decodeNextFrameAndSchedule());
  }

  Future<void> _decodeNextFrameAndSchedule() async {
    final ui.Codec? codec = _codec;
    if (codec == null || _isDecoding || _isDisposed) {
      return;
    }
    _isDecoding = true;
    _disposeNextFrame();
    try {
      _nextFrame = await codec.getNextFrame();
    } on Object catch (error, stackTrace) {
      if (!_isDisposed) {
        reportError(
          context: ErrorDescription('resolving an image frame'),
          exception: error,
          stack: stackTrace,
          informationCollector: _informationCollector,
          silent: true,
        );
      }
      return;
    } finally {
      _isDecoding = false;
    }
    if (_isDisposed || _codec == null) {
      _disposeNextFrame();
      return;
    }
    if (!_canScheduleFrames) {
      if (_shouldDisposePendingFrame(_controller.state)) {
        _disposeNextFrame();
      }
      return;
    }
    if (_codec!.frameCount == 1) {
      _emitNextFrame();
      _codec?.dispose();
      _codec = null;
      return;
    }
    _scheduleAppFrame();
  }

  void _handleAppFrame(Duration timestamp) {
    _frameCallbackScheduled = false;
    if (!_canScheduleFrames) {
      return;
    }
    if (_nextFrame == null) {
      unawaited(_decodeNextFrameAndSchedule());
      return;
    }
    if (_frameDuration == null ||
        timestamp - _shownTimestamp >= _frameDuration!) {
      _emitNextFrame();
      final ui.Codec? codec = _codec;
      if (codec == null) {
        return;
      }
      final int completedCycles = _framesEmitted ~/ codec.frameCount;
      if (codec.repetitionCount == -1 ||
          completedCycles <= codec.repetitionCount) {
        unawaited(_decodeNextFrameAndSchedule());
        return;
      }
      codec.dispose();
      _codec = null;
      return;
    }
    final Duration delay = _frameDuration! - (timestamp - _shownTimestamp);
    _timer = Timer(delay * timeDilation, _scheduleAppFrame);
  }

  void _emitNextFrame() {
    final ui.FrameInfo? frame = _nextFrame;
    if (frame == null) {
      return;
    }
    setImage(
      ImageInfo(
        image: frame.image.clone(),
        scale: _scale,
        debugLabel: debugLabel,
      ),
    );
    _shownTimestamp = SchedulerBinding.instance.currentFrameTimeStamp;
    _frameDuration = frame.duration;
    _framesEmitted += 1;
    _disposeNextFrame();
  }

  void _scheduleAppFrame() {
    if (_frameCallbackScheduled || !_canScheduleFrames) {
      return;
    }
    _frameCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_handleAppFrame);
  }

  bool get _canScheduleFrames {
    return !_isDisposed &&
        hasListeners &&
        _controller.state == PixaAnimationPlaybackState.playing;
  }

  bool _shouldDisposePendingFrame(PixaAnimationPlaybackState state) {
    return switch (state) {
      PixaAnimationPlaybackState.playing => false,
      PixaAnimationPlaybackState.paused =>
        _options.frameCachePolicy ==
            PixaAnimationFrameCachePolicy.disposeNextFrameOnPause,
      PixaAnimationPlaybackState.stopped =>
        _options.disposalPolicy ==
            PixaAnimationDisposalPolicy.disposeDecodedFrames,
    };
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _disposeNextFrame() {
    _nextFrame?.image.dispose();
    _nextFrame = null;
  }
}

Map<String, Object?> _attributes(
  _DisplayDecoderBackend backend, [
  Map<String, Object?> extra = const <String, Object?>{},
]) {
  return <String, Object?>{
    'backend': backend.id,
    'execution': backend.execution,
    'selector': 'pixa-display-decoder-v1',
    ...extra,
  };
}

void _emitFailure(
  PixaPipeline pipeline,
  PixaRequest request,
  PixaPipelineLoad load,
  _DisplayDecoderBackend backend,
  PixaFailure? failure,
  Stopwatch? decodeClock,
) {
  _emit(
    pipeline,
    PixaEvent(
      requestId: load.requestId,
      stage: PixaStage.decode,
      name: 'decode.failure',
      request: request,
      failure: failure,
      durationMicros: decodeClock?.elapsedMicroseconds ?? 0,
      attributes: _attributes(backend),
    ),
  );
}

void _emit(PixaPipeline pipeline, PixaEvent event) {
  for (final PixaObserver observer in pipeline.observers) {
    try {
      observer.onPixaEvent(event);
    } on Object catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}

void _validateDecodedPixels({
  required int requestId,
  required int intrinsicWidth,
  required int intrinsicHeight,
  required PixaTargetSize? target,
  required int maxDecodedPixels,
}) {
  if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
    throw PixaFailure(
      requestId: requestId,
      stage: PixaStage.decode,
      safeMessage: 'Image decoder reported invalid intrinsic dimensions.',
      retryability: PixaRetryability.notRetryable,
    );
  }

  final int outputWidth;
  final int outputHeight;
  if (target?.width != null && target?.height != null) {
    outputWidth = target!.width!;
    outputHeight = target.height!;
  } else if (target?.width != null) {
    outputWidth = target!.width!;
    outputHeight = _clampDimension(
      (intrinsicHeight * (outputWidth / intrinsicWidth)).ceil(),
      intrinsicHeight,
    );
  } else if (target?.height != null) {
    outputHeight = target!.height!;
    outputWidth = _clampDimension(
      (intrinsicWidth * (outputHeight / intrinsicHeight)).ceil(),
      intrinsicWidth,
    );
  } else {
    outputWidth = intrinsicWidth;
    outputHeight = intrinsicHeight;
  }

  final int decodedPixels = outputWidth * outputHeight;
  if (decodedPixels > maxDecodedPixels) {
    throw PixaFailure(
      requestId: requestId,
      stage: PixaStage.decode,
      safeMessage:
          'Decoded image size ${outputWidth}x$outputHeight exceeds max decoded pixels $maxDecodedPixels.',
      retryability: PixaRetryability.notRetryable,
    );
  }
}

int _clampDimension(int value, int max) => value.clamp(1, max).toInt();

final _DecodeLimiter _decodeLimiter = _DecodeLimiter();
final _ImageCompletionGate _completionGate = _ImageCompletionGate();

final class _ImageCompletionGate {
  final ListQueue<_QueuedImageCompletion> _queue =
      ListQueue<_QueuedImageCompletion>();
  Timer? _frameFallbackTimer;
  int? _frameCallbackId;
  var _releasedThisFrame = 0;
  var _frameScheduled = false;

  _ImageCompletionGateSnapshot snapshot() {
    return _ImageCompletionGateSnapshot(
      queueDepth: _queue.length,
      releasedThisFrame: _releasedThisFrame,
      frameScheduled: _frameScheduled,
    );
  }

  Future<void> wait({required int maxPerFrame}) {
    final int frameBudget = maxPerFrame.clamp(1, 256).toInt();
    _scheduleFrameReset();
    if (_queue.isEmpty && _releasedThisFrame < frameBudget) {
      _releasedThisFrame++;
      return SynchronousFuture<void>(null);
    }
    final _QueuedImageCompletion queued = _QueuedImageCompletion(
      maxPerFrame: frameBudget,
    );
    _queue.add(queued);
    return queued.future;
  }

  void _scheduleFrameReset() {
    if (_frameScheduled) {
      return;
    }
    _frameScheduled = true;
    _frameFallbackTimer?.cancel();
    late final int frameCallbackId;
    frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (_frameCallbackId == frameCallbackId) {
        _frameCallbackId = null;
      }
      _handleFrameBoundary();
    });
    _frameCallbackId = frameCallbackId;
    _frameFallbackTimer = Timer(const Duration(milliseconds: 16), () {
      if (_frameScheduled) {
        _handleFrameBoundary();
      }
    });
  }

  void _handleFrameBoundary() {
    if (!_frameScheduled) {
      return;
    }
    _frameScheduled = false;
    final int? frameCallbackId = _frameCallbackId;
    if (frameCallbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frameCallbackId);
      _frameCallbackId = null;
    }
    _frameFallbackTimer?.cancel();
    _frameFallbackTimer = null;
    _releasedThisFrame = 0;
    _pump();
    if (_queue.isNotEmpty || _releasedThisFrame > 0) {
      _scheduleFrameReset();
    }
  }

  void _pump() {
    while (_queue.isNotEmpty) {
      final _QueuedImageCompletion queued = _queue.first;
      if (_releasedThisFrame >= queued.maxPerFrame) {
        return;
      }
      _queue.removeFirst();
      _releasedThisFrame++;
      queued.complete();
    }
  }
}

final class _ImageCompletionGateSnapshot {
  const _ImageCompletionGateSnapshot({
    required this.queueDepth,
    required this.releasedThisFrame,
    required this.frameScheduled,
  });

  final int queueDepth;
  final int releasedThisFrame;
  final bool frameScheduled;
}

final class _QueuedImageCompletion {
  _QueuedImageCompletion({required this.maxPerFrame});

  final int maxPerFrame;
  final Completer<void> _completer = Completer<void>.sync();

  Future<void> get future => _completer.future;

  void complete() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

final class _DecodeLimiter {
  final ListQueue<_QueuedDecodePermit> _queue =
      ListQueue<_QueuedDecodePermit>();
  int _active = 0;
  int _maxConcurrent = 1;
  int _maxQueued = 2048;

  int get active => _active;

  int get queued => _queue.length;

  int get maxConcurrent => _maxConcurrent;

  int get maxQueued => _maxQueued;

  Future<_DecodePermit> acquire({
    required int maxConcurrent,
    required int maxQueued,
    required Future<void> cancelled,
  }) {
    _maxConcurrent = maxConcurrent.clamp(1, 32).toInt();
    _maxQueued = maxQueued.clamp(0, 65536).toInt();
    if (_active < _maxConcurrent) {
      _active++;
      return SynchronousFuture<_DecodePermit>(_DecodePermit._(this));
    }
    if (_queue.length >= _maxQueued) {
      return Future<_DecodePermit>.error(const _DecodeQueueFull());
    }

    final _QueuedDecodePermit queued = _QueuedDecodePermit();
    _queue.add(queued);
    unawaited(
      cancelled.then((_) {
        if (queued.cancel()) {
          queued.completeError(const _DecodeCancelled());
          _pump();
        }
      }),
    );
    return queued.future;
  }

  void release() {
    if (_active == 0) {
      return;
    }
    _active--;
    _pump();
  }

  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      final _QueuedDecodePermit queued = _queue.removeFirst();
      if (queued.isCancelled) {
        continue;
      }
      _active++;
      queued.complete(_DecodePermit._(this));
    }
  }
}

final class _QueuedDecodePermit {
  final Completer<_DecodePermit> _completer = Completer<_DecodePermit>.sync();
  bool _isCancelled = false;

  Future<_DecodePermit> get future => _completer.future;

  bool get isCancelled => _isCancelled;

  bool cancel() {
    if (_isCancelled || _completer.isCompleted) {
      return false;
    }
    _isCancelled = true;
    return true;
  }

  void complete(_DecodePermit permit) {
    if (_completer.isCompleted) {
      permit.release();
      return;
    }
    _completer.complete(permit);
  }

  void completeError(Object error) {
    if (!_completer.isCompleted) {
      _completer.completeError(error);
    }
  }
}

final class _DecodePermit {
  _DecodePermit._(this._limiter);

  final _DecodeLimiter _limiter;
  bool _isReleased = false;

  void release() {
    if (_isReleased) {
      return;
    }
    _isReleased = true;
    _limiter.release();
  }
}

final class _DecodeCancelled {
  const _DecodeCancelled();
}

final class _DecodeQueueFull {
  const _DecodeQueueFull();
}
