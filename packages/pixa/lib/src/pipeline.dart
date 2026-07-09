import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cache/cache_stats.dart';
import 'cache_key.dart';
import 'contracts.dart';
import 'failure.dart';
import 'image_format_catalog.dart';
import 'runtime/runtime_disk_cache.dart';
import 'runtime/runtime_loader.dart';
import 'runtime/runtime_memory_cache.dart';
import 'observer.dart';
import 'progress.dart';
import 'redaction.dart';
import 'request.dart';
import 'registry.dart';
import 'scheduler_stats.dart';
import 'source.dart';

/// runtime-backed Pixa image pipeline.
final class PixaPipeline {
  /// Creates a pipeline.
  PixaPipeline({
    required this.cacheRootPath,
    this.observers = const <PixaObserver>[],
    this.observerSamplingPolicy = PixaObserverSamplingPolicy.none,
    PixaRegistry? registry,
    int maxConcurrentRuntimeLoads = 6,
    int maxQueuedRuntimeLoads = 2048,
  }) : registry = registry ?? PixaRegistry(),
       assert(maxConcurrentRuntimeLoads > 0),
       assert(maxQueuedRuntimeLoads >= 0),
       maxConcurrentRuntimeLoads = maxConcurrentRuntimeLoads.clamp(1, 32),
       maxQueuedRuntimeLoads = maxQueuedRuntimeLoads.clamp(0, 65536).toInt() {
    routePlan = this.registry.compileRoutePlan();
  }

  /// Platform cache root path.
  final String cacheRootPath;

  /// Structured observers.
  final List<PixaObserver> observers;

  /// Sampling applied before observer callbacks.
  final PixaObserverSamplingPolicy observerSamplingPolicy;

  /// Plugin registry used for non-core extension routes.
  final PixaRegistry registry;

  /// Compiled route plan used by hot-path plugin lookups.
  late final PixaCompiledRoutePlan routePlan;

  /// Maximum concurrent Dart isolate entries into the runtime pipeline.
  final int maxConcurrentRuntimeLoads;

  /// Maximum root runtime loads allowed to wait behind active work.
  final int maxQueuedRuntimeLoads;

  int _requestCounter = 0;
  int _sequenceCounter = 0;
  int _activeRuntimeLoads = 0;
  int _queuedRuntimeLoads = 0;
  int _totalQueued = 0;
  int _totalStarted = 0;
  int _totalCoalesced = 0;
  int _totalCompleted = 0;
  int _totalFailed = 0;
  int _totalCancelled = 0;
  int _totalBackpressureDropped = 0;
  int _runtimeProgressEvents = 0;
  int _runtimeProgressEventsDropped = 0;
  int _observerEventsDroppedBySampling = 0;
  int _dartToRuntimeInputCopies = 0;
  int _dartToRuntimeInputBytesCopied = 0;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, int> _lastProgressEventMicros = <int, int>{};
  final Map<int, int> _progressEventCounters = <int, int>{};
  final Map<_InflightRuntimeLoadKey, _InflightRuntimeLoad> _inflight =
      <_InflightRuntimeLoadKey, _InflightRuntimeLoad>{};
  final _PriorityInflightQueue _queue = _PriorityInflightQueue();
  final Map<String, int> _activePlatformCalls = <String, int>{};
  final Map<String, ListQueue<Completer<void>>> _queuedPlatformCalls =
      <String, ListQueue<Completer<void>>>{};

  /// Loads encoded image bytes through Rust.
  Future<PixaPipelineLoad> load(PixaRequest request) {
    return startLoad(request).future;
  }

  /// Starts a load and returns a handle that can release this listener.
  PixaPipelineHandle startLoad(
    PixaRequest request, {
    ValueChanged<PixaProgress>? onProgress,
  }) {
    final int requestId = ++_requestCounter;
    final PixaRequest scheduledRequest = _resolveCacheFirstRequest(
      request,
      requestId,
    );
    final PixaCacheKey cacheKey = scheduledRequest.cacheKey;
    final _InflightRuntimeLoadKey inflightKey =
        _InflightRuntimeLoadKey.fromRequest(scheduledRequest);
    final _PipelineListener listener = _PipelineListener(
      requestId,
      onProgress: onProgress,
    );
    final _InflightRuntimeLoad? existing = _inflight[inflightKey];
    if (existing != null) {
      _totalCoalesced++;
      existing.listeners.add(listener);
      listener.inflight = existing;
      _promoteQueuedInflight(existing, request);
      _emit(
        PixaEvent(
          requestId: requestId,
          stage: PixaStage.request,
          name: 'scheduler.coalesced',
          request: scheduledRequest,
          attributes: <String, Object?>{
            'rootRequestId': existing.rootRequestId,
            'listenerCount': existing.listeners.length,
            'effectivePriority': existing.effectivePriority.name,
          },
        ),
      );
      return PixaPipelineHandle._(requestId, listener.future, () {
        _cancelListener(listener);
      });
    }

    final PixaFailure? backpressureFailure = _applyBackpressure(
      scheduledRequest,
      requestId,
    );
    if (backpressureFailure != null) {
      listener.completeError(backpressureFailure);
      _forgetProgressState(requestId);
      return PixaPipelineHandle._(requestId, listener.future, () {});
    }

    final _InflightRuntimeLoad inflight = _InflightRuntimeLoad(
      request: scheduledRequest,
      inflightKey: inflightKey,
      cacheKey: cacheKey,
      rootRequestId: requestId,
      sequence: ++_sequenceCounter,
      startedAtMicros: _clock.elapsedMicroseconds,
    );
    inflight.listeners.add(listener);
    listener.inflight = inflight;
    _inflight[inflightKey] = inflight;
    _queue.add(inflight);
    _markQueued(inflight);
    _totalQueued++;
    _emit(
      PixaEvent(
        requestId: requestId,
        stage: PixaStage.request,
        name: 'request.start',
        request: scheduledRequest,
      ),
    );
    _emit(
      PixaEvent(
        requestId: requestId,
        stage: PixaStage.request,
        name: 'scheduler.queued',
        request: scheduledRequest,
        attributes: <String, Object?>{
          'priority': scheduledRequest.priority.name,
          'queueDepth': _queuedRuntimeLoads,
          'maxQueuedRuntimeLoads': maxQueuedRuntimeLoads,
        },
      ),
    );
    _pumpScheduler();
    return PixaPipelineHandle._(requestId, listener.future, () {
      _cancelListener(listener);
    });
  }

  /// Prefetches encoded bytes without creating a Flutter decoded image.
  Future<void> prefetch(
    PixaRequest request, {
    PixaPrefetchTarget target = PixaPrefetchTarget.encodedMemory,
  }) async {
    final PixaPipelineLoad loaded = await load(
      pixaEncodedPrefetchRequest(request, target),
    );
    loaded.dispose();
  }

  /// Returns a scheduler stats snapshot.
  PixaSchedulerStats schedulerStats() {
    return PixaSchedulerStats(
      maxConcurrentRuntimeLoads: maxConcurrentRuntimeLoads,
      maxQueuedRuntimeLoads: maxQueuedRuntimeLoads,
      activeRuntimeLoads: _activeRuntimeLoads,
      queueDepth: _queuedRuntimeLoads,
      inflightRequests: _inflight.length,
      listeners: _inflight.values.fold<int>(
        0,
        (int total, _InflightRuntimeLoad inflight) =>
            total + inflight.listeners.length,
      ),
      totalQueued: _totalQueued,
      totalStarted: _totalStarted,
      totalCoalesced: _totalCoalesced,
      totalCompleted: _totalCompleted,
      totalFailed: _totalFailed,
      totalCancelled: _totalCancelled,
      totalBackpressureDropped: _totalBackpressureDropped,
      runtimeProgressEvents: _runtimeProgressEvents,
      runtimeProgressEventsDropped: _runtimeProgressEventsDropped,
      observerEventsDroppedBySampling: _observerEventsDroppedBySampling,
      dartToRuntimeInputCopies: _dartToRuntimeInputCopies,
      dartToRuntimeInputBytesCopied: _dartToRuntimeInputBytesCopied,
    );
  }

  void _pumpScheduler() {
    while (_activeRuntimeLoads < maxConcurrentRuntimeLoads &&
        _queuedRuntimeLoads > 0 &&
        _queue.isNotEmpty) {
      final _InflightRuntimeLoad? next = _queue.removeHighest();
      if (next == null) {
        break;
      }
      final _InflightRuntimeLoad inflight = next;
      _markDequeued(inflight);
      if (inflight.isCancelled || inflight.listeners.isEmpty) {
        _inflight.remove(inflight.inflightKey);
        continue;
      }
      inflight.isStarted = true;
      _activeRuntimeLoads++;
      _totalStarted++;
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.request,
          name: 'scheduler.start',
          request: inflight.request,
          attributes: <String, Object?>{
            'priority': inflight.effectivePriority.name,
            'activeRuntimeLoads': _activeRuntimeLoads,
            'queueDepth': _queuedRuntimeLoads,
            'maxQueuedRuntimeLoads': maxQueuedRuntimeLoads,
          },
        ),
      );
      unawaited(_runInflight(inflight));
    }
  }

  PixaFailure? _applyBackpressure(PixaRequest request, int requestId) {
    if (!_wouldWaitBehindActiveWork()) {
      return null;
    }
    if (_queuedRuntimeLoads < maxQueuedRuntimeLoads) {
      return null;
    }
    final _InflightRuntimeLoad? dropped = _queue.firstActiveBelowRank(
      _priorityRank(request.priority),
    );
    if (dropped != null) {
      _dropQueuedInflightForBackpressure(
        dropped,
        incomingPriority: request.priority,
      );
      return null;
    }
    _totalBackpressureDropped++;
    final PixaFailure failure = PixaFailure(
      requestId: requestId,
      stage: PixaStage.request,
      safeMessage:
          'Pixa runtime scheduler queue is full. Increase maxQueuedRuntimeLoads or reduce prefetch fan-out.',
      retryability: PixaRetryability.notRetryable,
    );
    _emit(
      PixaEvent(
        requestId: requestId,
        stage: PixaStage.request,
        name: 'scheduler.backpressureReject',
        request: request,
        failure: failure,
        attributes: <String, Object?>{
          'priority': request.priority.name,
          'queueDepth': _queuedRuntimeLoads,
          'maxQueuedRuntimeLoads': maxQueuedRuntimeLoads,
        },
      ),
    );
    _emit(
      PixaEvent(
        requestId: requestId,
        stage: PixaStage.request,
        name: 'request.failure',
        request: request,
        failure: failure,
      ),
    );
    return failure;
  }

  bool _wouldWaitBehindActiveWork() {
    return _activeRuntimeLoads >= maxConcurrentRuntimeLoads ||
        _queuedRuntimeLoads > 0;
  }

  void _dropQueuedInflightForBackpressure(
    _InflightRuntimeLoad inflight, {
    required PixaPriority incomingPriority,
  }) {
    if (inflight.isStarted || inflight.isCancelled || !inflight.isQueued) {
      return;
    }
    inflight.isCancelled = true;
    inflight.notifyCancelled();
    _markDequeued(inflight);
    _inflight.remove(inflight.inflightKey);
    _totalBackpressureDropped++;
    final List<_PipelineListener> listeners = List<_PipelineListener>.of(
      inflight.listeners,
    );
    inflight.listeners.clear();
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.cancel,
        name: 'scheduler.backpressureDrop',
        request: inflight.request,
        durationMicros: _elapsedSince(inflight.startedAtMicros),
        attributes: <String, Object?>{
          'droppedPriority': inflight.effectivePriority.name,
          'incomingPriority': incomingPriority.name,
          'listenerCount': listeners.length,
          'queueDepth': _queuedRuntimeLoads,
          'maxQueuedRuntimeLoads': maxQueuedRuntimeLoads,
        },
      ),
    );
    for (final _PipelineListener listener in listeners) {
      if (listener.isCompleted) {
        continue;
      }
      final PixaFailure failure = PixaFailure(
        requestId: listener.requestId,
        stage: PixaStage.cancel,
        safeMessage:
            'Pixa dropped queued low-priority work to admit a higher-priority image request.',
        retryability: PixaRetryability.notRetryable,
      );
      listener.completeError(failure);
      _forgetProgressState(listener.requestId);
      _totalCancelled++;
      _emit(
        PixaEvent(
          requestId: listener.requestId,
          stage: PixaStage.cancel,
          name: 'request.cancel',
          request: inflight.request,
          failure: failure,
          durationMicros: _elapsedSince(inflight.startedAtMicros),
          attributes: <String, Object?>{
            'remainingListeners': 0,
            'started': false,
            'reason': 'backpressure',
          },
        ),
      );
    }
  }

  void _markQueued(_InflightRuntimeLoad inflight) {
    if (inflight.isQueued) {
      return;
    }
    inflight.isQueued = true;
    _queuedRuntimeLoads++;
  }

  void _markDequeued(_InflightRuntimeLoad inflight) {
    if (!inflight.isQueued) {
      return;
    }
    inflight.isQueued = false;
    if (_queuedRuntimeLoads > 0) {
      _queuedRuntimeLoads--;
    }
    _compactQueueIfNeeded();
  }

  void _compactQueueIfNeeded() {
    final int threshold = maxQueuedRuntimeLoads <= 32
        ? 64
        : maxQueuedRuntimeLoads * 2;
    if (_queue.length <= threshold) {
      return;
    }
    if (_queue.length <= _queuedRuntimeLoads * 2) {
      return;
    }
    _queue.compact();
  }

  Future<void> _runInflight(_InflightRuntimeLoad inflight) async {
    try {
      final _PipelineOutput result = await _runPipelineLoad(inflight);
      final _SharedByteBuffer sharedBuffer = _SharedByteBuffer(result.owner);
      try {
        for (final _PipelineListener listener in List<_PipelineListener>.of(
          inflight.listeners,
        )) {
          if (listener.isCompleted) {
            continue;
          }
          listener.complete(
            PixaPipelineLoad._(
              _ByteBufferLease(sharedBuffer),
              requestId: listener.requestId,
              mimeType: result.mimeType,
              memoryPin: _EncodedMemoryPin.tryPin(
                inflight.memoryPinKey ?? _pinKeyFor(inflight.request),
              ),
            ),
          );
          _forgetProgressState(listener.requestId);
          _totalCompleted++;
          _emit(
            PixaEvent(
              requestId: listener.requestId,
              stage: PixaStage.complete,
              name: 'request.complete',
              request: inflight.request,
              durationMicros: _elapsedSince(inflight.startedAtMicros),
            ),
          );
        }
      } finally {
        sharedBuffer.close();
      }
    } on _RuntimeLoadReleased {
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cancel,
          name: 'request.released',
          request: inflight.request,
          durationMicros: _elapsedSince(inflight.startedAtMicros),
        ),
      );
    } on Object catch (error, stackTrace) {
      final PixaFailure failure = _failureFor(
        requestId: inflight.rootRequestId,
        error: error,
        stackTrace: stackTrace,
      );
      for (final _PipelineListener listener in List<_PipelineListener>.of(
        inflight.listeners,
      )) {
        if (listener.isCompleted) {
          continue;
        }
        final PixaFailure scoped = _scopeFailure(failure, listener.requestId);
        listener.completeError(scoped);
        _forgetProgressState(listener.requestId);
        _totalFailed++;
        _emit(
          PixaEvent(
            requestId: listener.requestId,
            stage: scoped.stage,
            name: 'request.failure',
            request: inflight.request,
            failure: scoped,
            durationMicros: _elapsedSince(inflight.startedAtMicros),
          ),
        );
      }
    } finally {
      _activeRuntimeLoads--;
      _inflight.remove(inflight.inflightKey);
      _pumpScheduler();
    }
  }

  Future<_PipelineOutput> _runPipelineLoad(
    _InflightRuntimeLoad inflight,
  ) async {
    final PixaRequest request = inflight.request;
    final _PluginProcessorPlan? pluginPlan = _pluginProcessorPlanFor(
      request,
      registry,
      inflight.rootRequestId,
    );
    final bool hasDecoderHint = _dartDecoderForMimeHint(request) != null;
    if (pluginPlan != null || hasDecoderHint) {
      final _ByteOwner? cached = _readPluginFinalCache(
        inflight,
        eventPrefix: pluginPlan == null ? 'decoder' : 'processed',
      );
      if (cached != null) {
        return _PipelineOutput(cached);
      }
    }

    final PixaRequest runtimeRequest = pluginPlan == null
        ? request
        : request.copyWith(processors: pluginPlan.runtimePrefix);
    final PixaRuntimeLoadResult runtimeResult = await _runRuntimeLoad(
      inflight,
      runtimeRequest: runtimeRequest,
    );
    final _RuntimeByteOwner retainedRuntime = _RuntimeByteOwner(
      runtimeResult.buffer,
    );
    try {
      PixaBytePayload payload = PixaBytePayload(
        bytes: retainedRuntime.bytes,
        mimeType: _effectiveDecoderMimeType(request, retainedRuntime.bytes),
      );
      bool transformed = false;
      final PixaDartDecoderDescriptor? decoder = _dartDecoderForPayload(
        request,
        payload,
      );
      if (decoder != null) {
        final _ByteOwner? cached = _readPluginFinalCache(
          inflight,
          eventPrefix: pluginPlan == null ? 'decoder' : 'processed',
        );
        if (cached != null) {
          retainedRuntime.dispose();
          return _PipelineOutput(cached);
        }
        payload = await _runPluginDecoder(inflight, request, decoder, payload);
        transformed = true;
      }
      for (final _PluginProcessorStep step
          in pluginPlan?.pluginSteps ?? const <_PluginProcessorStep>[]) {
        payload = await _runPluginProcessorStep(
          inflight,
          request,
          step,
          payload,
        );
        transformed = true;
      }
      if (!transformed) {
        return _PipelineOutput(retainedRuntime);
      }
      _validatePluginOutput(inflight, request, payload);
      _writePluginFinalCache(
        inflight,
        payload,
        eventPrefix: pluginPlan == null ? 'decoder' : 'processed',
      );
      inflight.memoryPinKey = request.cacheKey;
      return _PipelineOutput(
        _DartByteOwner(payload.bytes, retainedOwner: retainedRuntime),
        mimeType: payload.mimeType,
      );
    } on Object {
      retainedRuntime.dispose();
      rethrow;
    }
  }

  PixaDartDecoderDescriptor? _dartDecoderForMimeHint(PixaRequest request) {
    if (!_allowsDartPluginExecution(request)) {
      return null;
    }
    final String? formatId = _explicitDecoderFormatId(request);
    if (formatId != null) {
      final PixaDecoderDescriptor? descriptor = registry.decoderForFormatId(
        formatId,
      );
      return descriptor is PixaDartDecoderDescriptor ? descriptor : null;
    }
    final String? mimeType = _explicitDecoderMimeType(request);
    if (mimeType == null) {
      return null;
    }
    final PixaDecoderDescriptor? descriptor = registry.decoderForMimeType(
      mimeType,
    );
    return descriptor is PixaDartDecoderDescriptor ? descriptor : null;
  }

  PixaDartDecoderDescriptor? _dartDecoderForPayload(
    PixaRequest request,
    PixaBytePayload payload,
  ) {
    if (!_allowsDartPluginExecution(request)) {
      return null;
    }
    final String? formatId = _explicitDecoderFormatId(request);
    final String? mimeType = _explicitDecoderMimeType(request);
    if (mimeType != null && mimeType != payload.mimeType) {
      return null;
    }
    final PixaDecoderDescriptor? descriptor = registry.decoderForPayload(
      payload.bytes,
      formatId: formatId,
      mimeType: mimeType ?? payload.mimeType,
    );
    return descriptor is PixaDartDecoderDescriptor ? descriptor : null;
  }

  bool _allowsDartPluginExecution(PixaRequest request) {
    return request.pluginExecutionPolicy.dart;
  }

  String? _explicitDecoderMimeType(PixaRequest request) {
    final Object? value = request.decoderOptions['mimeType'];
    if (value is! String) {
      return null;
    }
    final String mimeType = value.split(';').first.trim().toLowerCase();
    return mimeType.isEmpty ? null : mimeType;
  }

  String? _explicitDecoderFormatId(PixaRequest request) {
    final Object? value = request.decoderOptions['formatId'];
    if (value is! String) {
      return null;
    }
    final String formatId = value.trim().toLowerCase();
    return formatId.isEmpty ? null : formatId;
  }

  String? _effectiveDecoderMimeType(PixaRequest request, Uint8List bytes) {
    return PixaImageFormatCatalog(registry: registry)
        .routeForPayload(
          bytes,
          formatId: _explicitDecoderFormatId(request),
          mimeType: _explicitDecoderMimeType(request),
        )
        ?.mimeType;
  }

  _ByteOwner? _readPluginFinalCache(
    _InflightRuntimeLoad inflight, {
    required String eventPrefix,
  }) {
    final PixaRequest request = inflight.request;
    if (request.cachePolicy.readMemory) {
      final PixaRuntimeOwnedBuffer? memoryBuffer =
          PixaRuntimeMemoryCache.readProcessed(request.cacheKey);
      if (memoryBuffer != null) {
        _emit(
          PixaEvent(
            requestId: inflight.rootRequestId,
            stage: PixaStage.cacheLookup,
            name: 'cache.$eventPrefix.memory.hit',
            request: request,
            attributes: <String, Object?>{'bytes': memoryBuffer.length},
          ),
        );
        inflight.memoryPinKey = request.cacheKey;
        return _RuntimeByteOwner(memoryBuffer);
      }
    }
    if (request.cachePolicy.readDisk) {
      final PixaRuntimeOwnedBuffer? diskBuffer = PixaRuntimeDiskCache(
        rootPath: cacheRootPath,
      ).read(namespace: request.cacheNamespace, key: request.cacheKey);
      if (diskBuffer != null) {
        if (request.cachePolicy.writeMemory) {
          final bool wroteMemory = PixaRuntimeMemoryCache.writeProcessed(
            namespace: request.cacheNamespace,
            key: request.cacheKey,
            bytes: diskBuffer.bytes,
            ttl: request.cachePolicy.maxAge,
          );
          if (!wroteMemory) {
            throw PixaFailure(
              requestId: inflight.rootRequestId,
              stage: PixaStage.cacheWrite,
              safeMessage: 'Failed to promote processed image to memory cache.',
              retryability: PixaRetryability.unknown,
            );
          }
        }
        _emit(
          PixaEvent(
            requestId: inflight.rootRequestId,
            stage: PixaStage.cacheLookup,
            name: 'cache.$eventPrefix.disk.hit',
            request: request,
            attributes: <String, Object?>{'bytes': diskBuffer.length},
          ),
        );
        inflight.memoryPinKey = request.cacheKey;
        return _RuntimeByteOwner(diskBuffer);
      }
    }
    return null;
  }

  Future<PixaBytePayload> _runPluginDecoder(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    PixaDartDecoderDescriptor descriptor,
    PixaBytePayload input,
  ) async {
    _InflightCancellationSignal(inflight).throwIfCancellationRequested();
    final int startedAtMicros = _clock.elapsedMicroseconds;
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.decode,
        name: 'plugin.decoder.start',
        request: request,
        attributes: <String, Object?>{
          'decoderId': descriptor.id,
          'mimeType': input.mimeType,
        },
      ),
    );
    try {
      final PixaExecutionContext execution = PixaExecutionContext(
        requestId: inflight.rootRequestId,
        request: request,
        cancellationSignal: _InflightCancellationSignal(inflight),
        onProgress: (PixaProgress progress) {
          for (final _PipelineListener listener in List<_PipelineListener>.of(
            inflight.listeners,
          )) {
            if (listener.isCompleted) {
              continue;
            }
            final PixaProgress scoped = PixaProgress(
              requestId: listener.requestId,
              stage: progress.stage,
              receivedBytes: progress.receivedBytes,
              expectedBytes: progress.expectedBytes,
              message: progress.message,
            );
            listener.emitProgress(scoped);
            _emit(
              PixaEvent(
                requestId: listener.requestId,
                stage: scoped.stage,
                name: 'plugin.decoder.progress',
                request: request,
                progress: scoped,
                attributes: <String, Object?>{
                  'decoderId': descriptor.id,
                  'mimeType': input.mimeType,
                },
              ),
            );
          }
        },
      );
      final PixaBytePayload output = await descriptor.decoder.decode(
        input,
        execution,
      );
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.decode,
          name: 'plugin.decoder.complete',
          request: request,
          durationMicros: _elapsedSince(startedAtMicros),
          attributes: <String, Object?>{
            'decoderId': descriptor.id,
            'inputMimeType': input.mimeType,
            'outputMimeType': output.mimeType,
            'bytes': output.bytes.length,
          },
        ),
      );
      return output;
    } on PixaFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.decode,
        safeMessage: 'Pixa plugin decoder ${descriptor.id} failed: $error',
        retryability: PixaRetryability.notRetryable,
        originalError: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<PixaBytePayload> _runPluginProcessorStep(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    _PluginProcessorStep step,
    PixaBytePayload input,
  ) async {
    _InflightCancellationSignal(inflight).throwIfCancellationRequested();
    final int startedAtMicros = _clock.elapsedMicroseconds;
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.process,
        name: 'plugin.processor.start',
        request: request,
        attributes: <String, Object?>{
          'processorId': step.descriptor.id,
          'operation': step.operation,
        },
      ),
    );
    try {
      final PixaExecutionContext execution = PixaExecutionContext(
        requestId: inflight.rootRequestId,
        request: request,
        cancellationSignal: _InflightCancellationSignal(inflight),
        onProgress: (PixaProgress progress) {
          for (final _PipelineListener listener in List<_PipelineListener>.of(
            inflight.listeners,
          )) {
            if (listener.isCompleted) {
              continue;
            }
            final PixaProgress scoped = PixaProgress(
              requestId: listener.requestId,
              stage: progress.stage,
              receivedBytes: progress.receivedBytes,
              expectedBytes: progress.expectedBytes,
              message: progress.message,
            );
            listener.emitProgress(scoped);
            _emit(
              PixaEvent(
                requestId: listener.requestId,
                stage: scoped.stage,
                name: 'plugin.processor.progress',
                request: request,
                progress: scoped,
                attributes: <String, Object?>{
                  'processorId': step.descriptor.id,
                  'operation': step.operation,
                },
              ),
            );
          }
        },
      );
      final PixaBytePayload output = await step.descriptor.processor.process(
        input,
        PixaProcessorContext(
          execution: execution,
          operation: step.operation,
          arguments: step.arguments,
        ),
      );
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.process,
          name: 'plugin.processor.complete',
          request: request,
          durationMicros: _elapsedSince(startedAtMicros),
          attributes: <String, Object?>{
            'processorId': step.descriptor.id,
            'operation': step.operation,
            'bytes': output.bytes.length,
            'mimeType': output.mimeType,
          },
        ),
      );
      return output;
    } on PixaFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.process,
        safeMessage:
            'Pixa plugin processor ${step.descriptor.id} failed: $error',
        retryability: PixaRetryability.notRetryable,
        originalError: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _validatePluginOutput(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    PixaBytePayload payload,
  ) {
    if (payload.bytes.length > request.limits.maxProcessorOutputBytes) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.process,
        safeMessage: 'Pixa plugin output exceeded byte limit.',
        retryability: PixaRetryability.notRetryable,
      );
    }
  }

  void _writePluginFinalCache(
    _InflightRuntimeLoad inflight,
    PixaBytePayload payload, {
    required String eventPrefix,
  }) {
    final PixaRequest request = inflight.request;
    if (request.cachePolicy.writeMemory) {
      final bool wroteMemory = PixaRuntimeMemoryCache.writeProcessed(
        namespace: request.cacheNamespace,
        key: request.cacheKey,
        bytes: payload.bytes,
        ttl: request.cachePolicy.maxAge,
      );
      if (!wroteMemory) {
        throw PixaFailure(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cacheWrite,
          safeMessage: 'Failed to write processed image to memory cache.',
          retryability: PixaRetryability.unknown,
        );
      }
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cacheWrite,
          name: 'cache.$eventPrefix.memory.write',
          request: request,
          attributes: <String, Object?>{'bytes': payload.bytes.length},
        ),
      );
    }
    if (_canWritePluginProcessedDisk(request)) {
      final bool wroteDisk = PixaRuntimeDiskCache(rootPath: cacheRootPath)
          .write(
            namespace: request.cacheNamespace,
            key: request.cacheKey,
            bytes: payload.bytes,
            ttl: request.cachePolicy.maxAge,
          );
      if (!wroteDisk) {
        throw PixaFailure(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cacheWrite,
          safeMessage: 'Failed to write processed image to disk cache.',
          retryability: PixaRetryability.unknown,
        );
      }
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cacheWrite,
          name: 'cache.$eventPrefix.disk.write',
          request: request,
          attributes: <String, Object?>{'bytes': payload.bytes.length},
        ),
      );
    }
  }

  bool _canWritePluginProcessedDisk(PixaRequest request) {
    if (!request.cachePolicy.writeDisk) {
      return false;
    }
    if (request.cachePolicy.privateDiskCache) {
      return true;
    }
    final PixaSource source = request.source;
    if (source is! PixaNetworkSource) {
      return true;
    }
    if (request.headers.keys.any(PixaRedactor.isSensitiveHeader)) {
      return false;
    }
    return !source.uri.queryParametersAll.keys.any(
      PixaRedactor.isSensitiveQuery,
    );
  }

  Future<PixaRuntimeLoadResult> _runRuntimeLoad(
    _InflightRuntimeLoad inflight, {
    PixaRequest? runtimeRequest,
  }) async {
    if (inflight.listeners.isEmpty) {
      throw const _RuntimeLoadReleased();
    }
    final PixaRequest request = runtimeRequest ?? inflight.request;
    final int runtimeStartedAtMicros = _clock.elapsedMicroseconds;
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.fetch,
        name: 'runtime.load.start',
        request: inflight.request,
        attributes: <String, Object?>{
          'retryMode': request.retryPolicy.mode.name,
          'maxAttempts': request.retryPolicy.maxAttempts,
          'runtimeProcessorCount': request.processors.length,
        },
      ),
    );
    final bool skippedInlineBytes = _shouldSkipInlineBytes(request);
    if (skippedInlineBytes) {
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cacheLookup,
          name: 'inline.bytes.skippedForCacheHit',
          request: request,
        ),
      );
    }
    Uint8List? inlineBytes = skippedInlineBytes
        ? null
        : await _inlineBytes(request, inflight);
    if (inflight.listeners.isEmpty) {
      throw const _RuntimeLoadReleased();
    }
    final Uint8List requestPayload = PixaRuntimeLoader.encodeRequest(request);
    try {
      final PixaRuntimeLoadResult result = await _runRuntimeLoadOnce(
        inflight,
        requestPayload: requestPayload,
        inlineBytes: inlineBytes,
      );
      _emitRuntimeLoadComplete(inflight, result, runtimeStartedAtMicros);
      return result;
    } on PixaFailure catch (failure) {
      if (!skippedInlineBytes || !_isMissingInlineBytesFailure(failure)) {
        rethrow;
      }
      inlineBytes = await _inlineBytes(request, inflight);
      if (inflight.listeners.isEmpty) {
        throw const _RuntimeLoadReleased();
      }
      final PixaRuntimeLoadResult result = await _runRuntimeLoadOnce(
        inflight,
        requestPayload: requestPayload,
        inlineBytes: inlineBytes,
      );
      _emitRuntimeLoadComplete(inflight, result, runtimeStartedAtMicros);
      return result;
    }
  }

  void _emitRuntimeLoadComplete(
    _InflightRuntimeLoad inflight,
    PixaRuntimeLoadResult result,
    int startedAtMicros,
  ) {
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.complete,
        name: 'runtime.load.complete',
        request: inflight.request,
        durationMicros: _elapsedSince(startedAtMicros),
        attributes: <String, Object?>{'bytes': result.buffer.length},
      ),
    );
  }

  Future<PixaRuntimeLoadResult> _runRuntimeLoadOnce(
    _InflightRuntimeLoad inflight, {
    required Uint8List requestPayload,
    required Uint8List? inlineBytes,
  }) async {
    final String cacheRootPath = this.cacheRootPath;
    final PixaRuntimeCancelToken cancelToken = PixaRuntimeCancelToken.create();
    final PixaRuntimeProgressSession progressSession =
        PixaRuntimeProgressSession.create();
    Timer? progressTimer;
    inflight.runtimeCancelToken = cancelToken;
    try {
      final int cancelTokenId = cancelToken.id;
      final int progressSessionId = progressSession.id;
      progressTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        _drainRuntimeProgress(inflight, progressSession);
      });
      final _RuntimeLoadIsolateJob job = _RuntimeLoadIsolateJob(
        cacheRootPath: cacheRootPath,
        requestPayload: requestPayload,
        inlineBytes: inlineBytes,
        cancelTokenId: cancelTokenId,
        progressSessionId: progressSessionId,
      );
      final PixaRuntimeLoadMessage message = await Isolate.run(job.run);
      _dartToRuntimeInputCopies += message.dartToRuntimeInputCopies;
      _dartToRuntimeInputBytesCopied += message.dartToRuntimeInputBytesCopied;
      _drainRuntimeProgress(inflight, progressSession);
      return PixaRuntimeLoadResult.fromMessage(message);
    } finally {
      progressTimer?.cancel();
      _drainRuntimeProgress(inflight, progressSession);
      progressSession.dispose();
      if (identical(inflight.runtimeCancelToken, cancelToken)) {
        inflight.runtimeCancelToken = null;
      }
      cancelToken.dispose();
    }
  }

  void _drainRuntimeProgress(
    _InflightRuntimeLoad inflight,
    PixaRuntimeProgressSession progressSession,
  ) {
    final PixaRuntimeProgressDrain drain = progressSession.drain();
    if (drain.droppedEvents > 0) {
      _runtimeProgressEventsDropped += drain.droppedEvents;
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.fetch,
          name: 'runtime.progress.dropped',
          request: inflight.request,
          attributes: <String, Object?>{'droppedEvents': drain.droppedEvents},
        ),
      );
    }
    if (drain.events.isEmpty) {
      return;
    }
    for (final PixaRuntimeProgressEvent event in drain.events) {
      final PixaStage stage = _runtimeProgressStage(event.stage);
      for (final _PipelineListener listener in List<_PipelineListener>.of(
        inflight.listeners,
      )) {
        if (listener.isCompleted) {
          continue;
        }
        final PixaProgress progress = PixaProgress(
          requestId: listener.requestId,
          stage: stage,
          receivedBytes: event.receivedBytes,
          expectedBytes: event.expectedBytes,
          message: event.message,
          progressivePreview: _progressivePreviewFor(event),
        );
        listener.emitProgress(progress);
        _runtimeProgressEvents++;
        _emit(
          PixaEvent(
            requestId: listener.requestId,
            stage: stage,
            name: event.name,
            request: inflight.request,
            progress: progress,
            attributes: <String, Object?>{
              'runtimeTimestampMs': event.timestampMs,
            },
          ),
        );
      }
    }
  }

  PixaProgressivePreview? _progressivePreviewFor(
    PixaRuntimeProgressEvent event,
  ) {
    final PixaRuntimeOwnedBuffer? buffer = event.previewBuffer;
    if (buffer == null) {
      return null;
    }
    return PixaProgressivePreview(
      bytes: buffer.bytes,
      mimeType: event.message ?? 'image/jpeg',
      sequence: event.receivedBytes ?? event.timestampMs,
      retainedOwner: buffer,
    );
  }

  PixaStage _runtimeProgressStage(String stage) {
    return switch (stage) {
      'cache_lookup' => PixaStage.cacheLookup,
      'fetch' => PixaStage.fetch,
      'decode' => PixaStage.decode,
      'process' => PixaStage.process,
      'cache_write' => PixaStage.cacheWrite,
      'complete' => PixaStage.complete,
      'cancel' => PixaStage.cancel,
      _ => PixaStage.request,
    };
  }

  void _cancelListener(_PipelineListener listener) {
    if (listener.isCompleted) {
      return;
    }
    final _InflightRuntimeLoad? inflight = listener.inflight;
    listener.completeError(
      PixaFailure(
        requestId: listener.requestId,
        stage: PixaStage.cancel,
        safeMessage: 'Pixa load listener was cancelled.',
        retryability: PixaRetryability.notRetryable,
      ),
    );
    _forgetProgressState(listener.requestId);
    _totalCancelled++;
    if (inflight == null) {
      return;
    }
    inflight.listeners.remove(listener);
    _emit(
      PixaEvent(
        requestId: listener.requestId,
        stage: PixaStage.cancel,
        name: 'request.cancel',
        request: inflight.request,
        durationMicros: _elapsedSince(inflight.startedAtMicros),
        attributes: <String, Object?>{
          'remainingListeners': inflight.listeners.length,
          'started': inflight.isStarted,
        },
      ),
    );
    if (inflight.listeners.isEmpty && !inflight.isStarted) {
      inflight.isCancelled = true;
      inflight.notifyCancelled();
      _markDequeued(inflight);
      _inflight.remove(inflight.inflightKey);
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cancel,
          name: 'scheduler.cancelQueued',
          request: inflight.request,
          durationMicros: _elapsedSince(inflight.startedAtMicros),
        ),
      );
      _pumpScheduler();
    } else if (inflight.listeners.isEmpty && inflight.isStarted) {
      inflight.notifyCancelled();
      inflight.runtimeCancelToken?.cancel();
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.cancel,
          name: 'runtime.cancel',
          request: inflight.request,
          durationMicros: _elapsedSince(inflight.startedAtMicros),
        ),
      );
    }
  }

  void _promoteQueuedInflight(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
  ) {
    if (inflight.isStarted) {
      return;
    }
    final int currentRank = _priorityRank(inflight.effectivePriority);
    final int incomingRank = _priorityRank(request.priority);
    if (incomingRank <= currentRank) {
      return;
    }
    final PixaPriority previous = inflight.effectivePriority;
    inflight.effectivePriority = request.priority;
    _queue.updatePriority(inflight, request.priority);
    _emit(
      PixaEvent(
        requestId: inflight.rootRequestId,
        stage: PixaStage.request,
        name: 'scheduler.priorityPromoted',
        request: inflight.request,
        attributes: <String, Object?>{
          'from': previous.name,
          'to': request.priority.name,
          'promotedByRequestPriority': request.priority.name,
          'listenerCount': inflight.listeners.length,
        },
      ),
    );
  }

  int _priorityRank(PixaPriority priority) {
    return _priorityRankValue(priority);
  }

  PixaFailure _failureFor({
    required int requestId,
    required Object error,
    required StackTrace stackTrace,
  }) {
    if (error is PixaFailure) {
      return _scopeFailure(error, requestId);
    }
    return PixaFailure(
      requestId: requestId,
      stage: PixaStage.request,
      safeMessage: error.toString(),
      retryability: PixaRetryability.unknown,
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  PixaFailure _scopeFailure(PixaFailure failure, int requestId) {
    return PixaFailure(
      requestId: requestId,
      stage: failure.stage,
      safeMessage: failure.safeMessage,
      retryability: failure.retryability,
      originalError: failure.originalError,
      stackTrace: failure.stackTrace,
    );
  }

  /// Clears a runtime cache namespace.
  void clearNamespace(String namespace) {
    final bool memoryCleared = PixaRuntimeMemoryCache.clearNamespace(namespace);
    final bool diskCleared = PixaRuntimeDiskCache(
      rootPath: cacheRootPath,
    ).clearNamespace(namespace);
    if (!memoryCleared || !diskCleared) {
      throw StateError('Failed to clear Pixa cache namespace "$namespace".');
    }
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.namespace.clear',
        attributes: <String, Object?>{'namespace': namespace},
      ),
    );
  }

  /// Clears all encoded cache entries.
  void clearEncodedCache() {
    final bool memoryCleared = PixaRuntimeMemoryCache.clear();
    final bool diskCleared = PixaRuntimeDiskCache(
      rootPath: cacheRootPath,
    ).clearAll();
    if (!memoryCleared || !diskCleared) {
      throw StateError('Failed to clear Pixa encoded cache.');
    }
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.clear',
      ),
    );
  }

  /// Evicts encoded cache entries for one request.
  void evictEncoded(PixaRequest request) {
    final PixaCacheKey encodedKey = request.encodedCacheKey;
    final bool memoryRemoved = PixaRuntimeMemoryCache.remove(encodedKey);
    final bool diskRemoved = PixaRuntimeDiskCache(
      rootPath: cacheRootPath,
    ).remove(namespace: request.cacheNamespace, key: encodedKey);
    if (!memoryRemoved || !diskRemoved) {
      throw StateError(
        'Failed to evict encoded cache entry ${encodedKey.value}.',
      );
    }
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.entry.evict',
        request: request,
        attributes: <String, Object?>{
          'namespace': request.cacheNamespace,
          'cacheKey': request.cacheKey.value,
          'encodedCacheKey': encodedKey.value,
        },
      ),
    );
  }

  /// Clears all encoded memory entries.
  void clearEncodedMemory() {
    if (!PixaRuntimeMemoryCache.clear()) {
      throw StateError('Failed to clear Pixa encoded memory cache.');
    }
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.memory.clear',
      ),
    );
  }

  /// Trims encoded memory entries to a target byte budget.
  void trimEncodedMemoryToBytes(int targetBytes) {
    if (!PixaRuntimeMemoryCache.trimToBytes(targetBytes)) {
      throw StateError('Failed to trim Pixa encoded memory cache.');
    }
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.memory.trim',
        attributes: <String, Object?>{'targetBytes': targetBytes},
      ),
    );
  }

  /// Returns runtime cache stats.
  PixaCacheStats cacheStats() {
    final PixaCacheStats stats = PixaRuntimeMemoryCache.stats();
    _emit(
      PixaEvent(
        requestId: 0,
        stage: PixaStage.cacheLookup,
        name: 'cache.stats',
        cacheStats: stats,
      ),
    );
    return stats;
  }

  PixaRequest _resolveCacheFirstRequest(PixaRequest request, int requestId) {
    if (request.sources.isEmpty) {
      return request;
    }
    final List<PixaSource> candidates = <PixaSource>[
      request.source,
      ...request.sources,
    ];
    for (int index = 0; index < candidates.length; index++) {
      final PixaRequest candidate = _sourceCandidateRequest(
        request,
        candidates[index],
      );
      if (!_canUseEncodedCache(candidate)) {
        continue;
      }
      _emit(
        PixaEvent(
          requestId: requestId,
          stage: PixaStage.cacheLookup,
          name: 'request.sourceSelectedFromCache',
          request: candidate,
          attributes: <String, Object?>{
            'candidateIndex': index,
            'candidateCount': candidates.length,
            'sourceLabel': candidate.source.safeLabel,
          },
        ),
      );
      return candidate;
    }
    return request;
  }

  PixaRequest _sourceCandidateRequest(PixaRequest request, PixaSource source) {
    return request.copyWith(source: source, sources: const <PixaSource>[]);
  }

  bool _shouldSkipInlineBytes(PixaRequest request) {
    return _requiresInlineBytes(request.source) && _canUseEncodedCache(request);
  }

  bool _canUseEncodedCache(PixaRequest request) {
    if (!request.cachePolicy.readMemory && !request.cachePolicy.readDisk) {
      return false;
    }
    final Iterable<PixaCacheKey> keys = _probeKeysFor(request);
    for (final PixaCacheKey key in keys) {
      if (request.cachePolicy.readMemory &&
          PixaRuntimeMemoryCache.contains(key)) {
        return true;
      }
      if (request.cachePolicy.readDisk &&
          PixaRuntimeDiskCache(rootPath: cacheRootPath).contains(
            namespace: request.cacheNamespace,
            key: key,
            allowStale:
                request.cachePolicy.mode == PixaCacheMode.staleWhileRevalidate,
          )) {
        return true;
      }
    }
    return false;
  }

  Iterable<PixaCacheKey> _probeKeysFor(PixaRequest request) sync* {
    if (request.processors.isNotEmpty) {
      yield request.cacheKey;
    }
    yield request.encodedCacheKey;
  }

  bool _requiresInlineBytes(PixaSource source) {
    return switch (source) {
      PixaMemorySource() ||
      PixaBytesSource() ||
      PixaAssetSource() ||
      PixaCustomSource() => true,
      PixaNetworkSource() ||
      PixaFileSource() ||
      PixaExifThumbnailSource() ||
      PixaVideoFrameSource() ||
      PixaRuntimePluginSource() => false,
    };
  }

  bool _isMissingInlineBytesFailure(PixaFailure failure) {
    return failure.stage == PixaStage.fetch &&
        failure.safeMessage.contains('inline source requires bytes');
  }

  Future<Uint8List?> _inlineBytes(
    PixaRequest request,
    _InflightRuntimeLoad inflight,
  ) async {
    try {
      final PixaSource source = request.source;
      switch (source) {
        case PixaMemorySource(:final bytes):
          return bytes;
        case PixaBytesSource(:final bytes):
          return bytes;
        case PixaAssetSource(:final name, :final package, :final bundle):
          final String key = package == null ? name : 'packages/$package/$name';
          final ByteData data = await (bundle ?? rootBundle).load(key);
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        case PixaCustomSource(:final id, :final loader):
          final PixaFetcherDescriptor? descriptor = routePlan
              .fetcherForSourceKind(id);
          if (descriptor != null) {
            final PixaBytePayload payload = await _runPluginFetcher(
              inflight,
              request,
              source,
              descriptor,
              id,
            );
            return payload.bytes;
          }
          return await loader();
        default:
          return null;
      }
    } on PixaFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.fetch,
        safeMessage:
            'Failed to load inline image source ${request.source.safeLabel}: $error',
        retryability: PixaRetryability.notRetryable,
        originalError: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<PixaBytePayload> _runPluginFetcher(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    PixaSource source,
    PixaFetcherDescriptor descriptor,
    String sourceKind,
  ) async {
    _ensurePluginFetcherPolicy(inflight, request, descriptor, sourceKind);
    final PixaFetcher fetcher = _pluginFetcherImplementation(
      inflight,
      descriptor,
    );
    _validatePlatformFetcherHost(inflight, descriptor);
    final int pluginStartedAtMicros = _clock.elapsedMicroseconds;
    final Map<String, Object?> baseAttributes = _pluginFetcherAttributes(
      descriptor,
      sourceKind,
    );
    return _withPlatformCallSlot(descriptor, () async {
      _InflightCancellationSignal(inflight).throwIfCancellationRequested();
      _emit(
        PixaEvent(
          requestId: inflight.rootRequestId,
          stage: PixaStage.fetch,
          name: 'plugin.fetch.start',
          request: request,
          attributes: baseAttributes,
        ),
      );
      try {
        final PixaExecutionContext context = PixaExecutionContext(
          requestId: inflight.rootRequestId,
          request: request,
          cancellationSignal: _InflightCancellationSignal(inflight),
          onProgress: (PixaProgress progress) {
            for (final _PipelineListener listener in List<_PipelineListener>.of(
              inflight.listeners,
            )) {
              final PixaProgress scoped = PixaProgress(
                requestId: listener.requestId,
                stage: progress.stage,
                receivedBytes: progress.receivedBytes,
                expectedBytes: progress.expectedBytes,
                message: progress.message,
              );
              listener.emitProgress(scoped);
              _emit(
                PixaEvent(
                  requestId: listener.requestId,
                  stage: scoped.stage,
                  name: 'plugin.fetch.progress',
                  request: request,
                  progress: scoped,
                  attributes: baseAttributes,
                ),
              );
            }
          },
        );
        final PixaBytePayload payload =
            await Future<PixaBytePayload>.value(
              fetcher.fetch(source, context),
            ).timeout(
              request.limits.timeout,
              onTimeout: () {
                inflight.notifyCancelled();
                throw PixaFailure(
                  requestId: inflight.rootRequestId,
                  stage: PixaStage.fetch,
                  safeMessage:
                      'Pixa plugin fetcher ${descriptor.id} timed out after '
                      '${request.limits.timeout.inMilliseconds}ms.',
                  retryability: PixaRetryability.retryable,
                );
              },
            );
        _validatePluginFetcherPayload(inflight, request, descriptor, payload);
        _emit(
          PixaEvent(
            requestId: inflight.rootRequestId,
            stage: PixaStage.fetch,
            name: 'plugin.fetch.complete',
            request: request,
            durationMicros: _elapsedSince(pluginStartedAtMicros),
            attributes: <String, Object?>{
              ...baseAttributes,
              'payloadKind': payload.kind.name,
              'mimeType': payload.mimeType,
              'bytes': payload.bytes.length,
            },
          ),
        );
        return payload;
      } on PixaFailure {
        rethrow;
      } on Object catch (error, stackTrace) {
        throw PixaFailure(
          requestId: inflight.rootRequestId,
          stage: PixaStage.fetch,
          safeMessage: 'Pixa plugin fetcher ${descriptor.id} failed: $error',
          retryability: PixaRetryability.notRetryable,
          originalError: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<T> _withPlatformCallSlot<T>(
    PixaFetcherDescriptor descriptor,
    Future<T> Function() body,
  ) async {
    if (descriptor is! PixaPlatformDescriptor) {
      return body();
    }
    final PixaPlatformDescriptor platformDescriptor =
        descriptor as PixaPlatformDescriptor;
    final String key = descriptor.id;
    final int maxConcurrent = platformDescriptor.platform.maxConcurrentCalls;
    if ((_activePlatformCalls[key] ?? 0) >= maxConcurrent) {
      final Completer<void> waiter = Completer<void>();
      (_queuedPlatformCalls[key] ??= ListQueue<Completer<void>>()).add(waiter);
      await waiter.future;
    }
    _activePlatformCalls[key] = (_activePlatformCalls[key] ?? 0) + 1;
    try {
      return await body();
    } finally {
      final int remaining = (_activePlatformCalls[key] ?? 1) - 1;
      if (remaining <= 0) {
        _activePlatformCalls.remove(key);
      } else {
        _activePlatformCalls[key] = remaining;
      }
      final ListQueue<Completer<void>>? queue = _queuedPlatformCalls[key];
      final Completer<void>? next = queue == null || queue.isEmpty
          ? null
          : queue.removeFirst();
      if (queue != null && queue.isEmpty) {
        _queuedPlatformCalls.remove(key);
      }
      if (next != null && !next.isCompleted) {
        next.complete();
      }
    }
  }

  void _ensurePluginFetcherPolicy(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    PixaFetcherDescriptor descriptor,
    String sourceKind,
  ) {
    final PixaPluginExecutionPolicy policy = request.pluginExecutionPolicy;
    final bool allowed = switch (descriptor.executionKind) {
      PixaPluginExecutionKind.runtime => policy.runtime,
      PixaPluginExecutionKind.dart => policy.dart,
      PixaPluginExecutionKind.platform => policy.platform,
      PixaPluginExecutionKind.external => policy.external,
    };
    if (allowed) {
      return;
    }
    throw PixaFailure(
      requestId: inflight.rootRequestId,
      stage: PixaStage.fetch,
      safeMessage:
          'Pixa fetcher "${descriptor.id}" for source kind "$sourceKind" '
          'requires plugin execution policy permission for '
          '${descriptor.executionKind.name}.',
      retryability: PixaRetryability.notRetryable,
    );
  }

  PixaFetcher _pluginFetcherImplementation(
    _InflightRuntimeLoad inflight,
    PixaFetcherDescriptor descriptor,
  ) {
    return switch (descriptor) {
      PixaDartFetcherDescriptor(:final fetcher) => fetcher,
      PixaPlatformFetcherDescriptor(:final fetcher) => fetcher,
      _ => throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.fetch,
        safeMessage:
            'Pixa fetcher "${descriptor.id}" cannot execute on the Dart '
            'inline source boundary.',
        retryability: PixaRetryability.notRetryable,
      ),
    };
  }

  void _validatePlatformFetcherHost(
    _InflightRuntimeLoad inflight,
    PixaFetcherDescriptor descriptor,
  ) {
    if (descriptor is! PixaPlatformDescriptor) {
      return;
    }
    final PixaPlatformDescriptor platformDescriptor =
        descriptor as PixaPlatformDescriptor;
    final PixaHostPlatform? host = _currentHostPlatform();
    if (host != null &&
        platformDescriptor.platform.supportedPlatforms.contains(host)) {
      return;
    }
    throw PixaFailure(
      requestId: inflight.rootRequestId,
      stage: PixaStage.fetch,
      safeMessage:
          'Pixa platform fetcher "${descriptor.id}" has unsupported host '
          'platform ${host?.name ?? defaultTargetPlatform.name}.',
      retryability: PixaRetryability.notRetryable,
    );
  }

  void _validatePluginFetcherPayload(
    _InflightRuntimeLoad inflight,
    PixaRequest request,
    PixaFetcherDescriptor descriptor,
    PixaBytePayload payload,
  ) {
    if (payload.bytes.length > request.limits.maxEncodedBytes) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.fetch,
        safeMessage: 'Pixa plugin fetcher output exceeded byte limit.',
        retryability: PixaRetryability.notRetryable,
      );
    }
    if (descriptor is PixaPlatformDescriptor) {
      final PixaPlatformDescriptor platformDescriptor =
          descriptor as PixaPlatformDescriptor;
      if (payload.kind != PixaPayloadKind.encodedImage) {
        throw PixaFailure(
          requestId: inflight.rootRequestId,
          stage: PixaStage.fetch,
          safeMessage:
              'Pixa platform fetcher "${descriptor.id}" returned unsupported '
              'payload kind ${payload.kind.name}.',
          retryability: PixaRetryability.notRetryable,
        );
      }
      final int? maxOutputBytes = platformDescriptor.platform.maxOutputBytes;
      if (maxOutputBytes != null && payload.bytes.length > maxOutputBytes) {
        throw PixaFailure(
          requestId: inflight.rootRequestId,
          stage: PixaStage.fetch,
          safeMessage:
              'Pixa platform output exceeded byte limit for fetcher '
              '"${descriptor.id}".',
          retryability: PixaRetryability.notRetryable,
        );
      }
    }
    final String? declaredMime = _normalizeOptionalMimeType(payload.mimeType);
    if (declaredMime == null) {
      return;
    }
    final String? detectedMime = PixaImageFormatCatalog(
      registry: registry,
    ).routeForPayload(payload.bytes)?.mimeType;
    if (detectedMime != null && detectedMime != declaredMime) {
      throw PixaFailure(
        requestId: inflight.rootRequestId,
        stage: PixaStage.fetch,
        safeMessage:
            'Pixa plugin fetcher "${descriptor.id}" MIME/signature mismatch.',
        retryability: PixaRetryability.notRetryable,
      );
    }
  }

  Map<String, Object?> _pluginFetcherAttributes(
    PixaFetcherDescriptor descriptor,
    String sourceKind,
  ) {
    final Map<String, Object?> attributes = <String, Object?>{
      'fetcherId': descriptor.id,
      'sourceKind': sourceKind,
      'executionKind': descriptor.executionKind.name,
    };
    if (descriptor is PixaPlatformDescriptor) {
      final PixaPlatformDescriptor platformDescriptor =
          descriptor as PixaPlatformDescriptor;
      attributes.addAll(<String, Object?>{
        'platformChannel': platformDescriptor.platform.channel,
        'platformHotPathSafe': platformDescriptor.platform.hotPathSafe,
        'platformSupportsCancellation':
            platformDescriptor.platform.supportsCancellation,
        'platformBackgroundQueue': platformDescriptor.platform.backgroundQueue,
      });
    }
    return attributes;
  }

  void _emit(PixaEvent event) {
    if (!_shouldEmit(event)) {
      _observerEventsDroppedBySampling++;
      return;
    }
    for (final PixaObserver observer in observers) {
      try {
        observer.onPixaEvent(event);
      } on Object catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  bool _shouldEmit(PixaEvent event) {
    if (observers.isEmpty || !observerSamplingPolicy.samplesProgress) {
      return true;
    }
    if (event.progress == null) {
      return true;
    }
    final int requestId = event.requestId;
    final int count = (_progressEventCounters[requestId] ?? 0) + 1;
    _progressEventCounters[requestId] = count;
    if (count % observerSamplingPolicy.progressSampleRate != 0) {
      return false;
    }
    final int intervalMicros =
        observerSamplingPolicy.progressInterval.inMicroseconds;
    if (intervalMicros <= 0) {
      return true;
    }
    final int now = _clock.elapsedMicroseconds;
    final int? previous = _lastProgressEventMicros[requestId];
    if (previous != null && now - previous < intervalMicros) {
      return false;
    }
    _lastProgressEventMicros[requestId] = now;
    return true;
  }

  int _elapsedSince(int startedAtMicros) {
    return (_clock.elapsedMicroseconds - startedAtMicros)
        .clamp(0, 1 << 62)
        .toInt();
  }

  void _forgetProgressState(int requestId) {
    _lastProgressEventMicros.remove(requestId);
    _progressEventCounters.remove(requestId);
  }
}

/// Cancellable listener handle for a scheduled pipeline load.
final class PixaPipelineHandle {
  PixaPipelineHandle._(this.requestId, this.future, this._cancel);

  /// Listener request id.
  final int requestId;

  /// Future for this listener.
  final Future<PixaPipelineLoad> future;

  final VoidCallback _cancel;
  bool _isCancelled = false;

  /// Releases this listener from the in-flight runtime load.
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _cancel();
  }
}

/// Encoded load result.
final class PixaPipelineLoad {
  const PixaPipelineLoad._(
    this._buffer, {
    required this.requestId,
    required this.mimeType,
    required _EncodedMemoryPin? memoryPin,
  }) : _memoryPin = memoryPin;

  final _ByteBufferLease _buffer;
  final _EncodedMemoryPin? _memoryPin;

  /// Encoded image bytes.
  Uint8List get bytes => _buffer.bytes;

  /// Request id.
  final int requestId;

  /// Best-known MIME type for the actual encoded bytes returned by pipeline.
  final String? mimeType;

  /// Decodes runtime-owned encoded bytes into a runtime-owned RGBA buffer.
  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    return _buffer.decodeRuntimeRgba(
      requestId: requestId,
      maxDecodedPixels: maxDecodedPixels,
      maxOutputBytes: maxOutputBytes,
    );
  }

  /// Releases this load's runtime byte lease.
  void dispose() {
    _memoryPin?.dispose();
    _buffer.dispose();
  }
}

final class _PipelineOutput {
  const _PipelineOutput(this.owner, {this.mimeType});

  final _ByteOwner owner;
  final String? mimeType;
}

abstract interface class _ByteOwner {
  Uint8List get bytes;

  int get length;

  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int requestId,
    required int maxDecodedPixels,
    required int maxOutputBytes,
  });

  void dispose();
}

final class _RuntimeByteOwner implements _ByteOwner {
  _RuntimeByteOwner(this._buffer);

  final PixaRuntimeOwnedBuffer _buffer;

  @override
  Uint8List get bytes => _buffer.bytes;

  @override
  int get length => _buffer.length;

  @override
  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int requestId,
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    try {
      return _buffer.decodeRgba(
        maxDecodedPixels: maxDecodedPixels,
        maxOutputBytes: maxOutputBytes,
      );
    } on PixaFailure catch (failure) {
      throw PixaFailure(
        requestId: requestId,
        stage: failure.stage,
        safeMessage: failure.safeMessage,
        retryability: failure.retryability,
        originalError: failure.originalError,
        stackTrace: failure.stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _buffer.dispose();
  }
}

final class _DartByteOwner implements _ByteOwner {
  _DartByteOwner(this._bytes, {_ByteOwner? retainedOwner})
    : _retainedOwner = retainedOwner;

  final Uint8List _bytes;
  final _ByteOwner? _retainedOwner;
  Uint8List? _view;
  bool _isDisposed = false;

  @override
  Uint8List get bytes {
    if (_isDisposed) {
      throw StateError('Dart byte owner has already been released.');
    }
    return _view ??= _bytes.asUnmodifiableView();
  }

  @override
  int get length => _bytes.length;

  @override
  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int requestId,
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    throw PixaFailure(
      requestId: requestId,
      stage: PixaStage.decode,
      safeMessage:
          'Runtime display decode requires a runtime-owned encoded buffer.',
      retryability: PixaRetryability.notRetryable,
    );
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _view = null;
    _retainedOwner?.dispose();
  }
}

final class _SharedByteBuffer {
  _SharedByteBuffer(this._owner);

  final _ByteOwner _owner;
  int _leases = 0;
  bool _isClosed = false;

  Uint8List get bytes => _owner.bytes;

  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int requestId,
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    return _owner.decodeRuntimeRgba(
      requestId: requestId,
      maxDecodedPixels: maxDecodedPixels,
      maxOutputBytes: maxOutputBytes,
    );
  }

  void retain() {
    if (_isClosed) {
      throw StateError('Pixa byte buffer has already been closed.');
    }
    _leases++;
  }

  void release() {
    if (_leases <= 0) {
      return;
    }
    _leases--;
    if (_isClosed && _leases == 0) {
      _owner.dispose();
    }
  }

  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    if (_leases == 0) {
      _owner.dispose();
    }
  }
}

final class _ByteBufferLease {
  _ByteBufferLease(this._shared) {
    _shared.retain();
  }

  final _SharedByteBuffer _shared;
  bool _isDisposed = false;

  Uint8List get bytes {
    if (_isDisposed) {
      throw StateError('runtime buffer lease has already been released.');
    }
    return _shared.bytes;
  }

  PixaRuntimeRgbaImage decodeRuntimeRgba({
    required int requestId,
    required int maxDecodedPixels,
    required int maxOutputBytes,
  }) {
    if (_isDisposed) {
      throw StateError('runtime buffer lease has already been released.');
    }
    return _shared.decodeRuntimeRgba(
      requestId: requestId,
      maxDecodedPixels: maxDecodedPixels,
      maxOutputBytes: maxOutputBytes,
    );
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _shared.release();
  }
}

final class _EncodedMemoryPin {
  _EncodedMemoryPin._(this._key);

  static _EncodedMemoryPin? tryPin(PixaCacheKey key) {
    if (!PixaRuntimeMemoryCache.pin(key)) {
      return null;
    }
    return _EncodedMemoryPin._(key);
  }

  final PixaCacheKey _key;
  bool _isDisposed = false;

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    PixaRuntimeMemoryCache.unpin(_key);
  }
}

final class _PluginProcessorPlan {
  const _PluginProcessorPlan({
    required this.runtimePrefix,
    required this.pluginSteps,
  });

  final List<String> runtimePrefix;
  final List<_PluginProcessorStep> pluginSteps;
}

final class _PluginProcessorStep {
  const _PluginProcessorStep({
    required this.descriptor,
    required this.operation,
    required this.arguments,
  });

  final PixaDartProcessorDescriptor descriptor;
  final String operation;
  final Map<String, Object?> arguments;
}

/// Returns the request used for encoded prefetch targets.
PixaRequest pixaEncodedPrefetchRequest(
  PixaRequest request,
  PixaPrefetchTarget target,
) {
  final PixaCacheMode mode = switch (target) {
    PixaPrefetchTarget.diskOnly => PixaCacheMode.diskOnly,
    PixaPrefetchTarget.encodedMemory => PixaCacheMode.memoryOnly,
    PixaPrefetchTarget.decodedPrewarm => throw ArgumentError.value(
      target,
      'target',
      'decoded prewarm must use Pixa.precache or Pixa.prefetch with context',
    ),
  };
  return request.copyWith(
    priority: PixaPriority.low,
    cachePolicy: request.cachePolicy.copyWith(mode: mode),
  );
}

/// Returns the request used for Flutter decoded prewarm.
PixaRequest pixaDecodedPrewarmRequest(PixaRequest request) {
  final PixaCacheMode mode = switch (request.cachePolicy.mode) {
    PixaCacheMode.noStore => PixaCacheMode.noStore,
    PixaCacheMode.memoryOnly => PixaCacheMode.noStore,
    PixaCacheMode.cacheOnly => PixaCacheMode.cacheOnly,
    PixaCacheMode.networkOnly => PixaCacheMode.noStore,
    PixaCacheMode.refresh => PixaCacheMode.noStore,
    PixaCacheMode.diskOnly ||
    PixaCacheMode.memoryAndDisk ||
    PixaCacheMode.staleWhileRevalidate => PixaCacheMode.diskOnly,
  };
  return request.copyWith(
    priority: PixaPriority.low,
    cachePolicy: request.cachePolicy.copyWith(mode: mode),
  );
}

PixaCacheKey _pinKeyFor(PixaRequest request) {
  return request.processors.isEmpty
      ? request.encodedCacheKey
      : request.cacheKey;
}

_PluginProcessorPlan? _pluginProcessorPlanFor(
  PixaRequest request,
  PixaRegistry registry,
  int requestId,
) {
  if (request.processors.isEmpty) {
    return null;
  }

  final List<String> runtimePrefix = <String>[];
  final List<_PluginProcessorStep> pluginSteps = <_PluginProcessorStep>[];
  bool pluginStarted = false;
  for (final String descriptor in request.processors) {
    final String operation = _processorOperationLabel(descriptor);
    final PixaProcessorDescriptor? registered = registry.processorForOperation(
      operation,
    );
    if (registered is PixaDartProcessorDescriptor) {
      pluginStarted = true;
      pluginSteps.add(
        _PluginProcessorStep(
          descriptor: registered,
          operation: operation,
          arguments: _processorArguments(descriptor),
        ),
      );
      continue;
    }
    if (pluginStarted) {
      throw PixaFailure(
        requestId: requestId,
        stage: PixaStage.process,
        safeMessage:
            'runtime processor "$operation" cannot run after a Dart plugin processor.',
        retryability: PixaRetryability.notRetryable,
      );
    }
    runtimePrefix.add(descriptor);
  }
  if (pluginSteps.isEmpty) {
    return null;
  }
  return _PluginProcessorPlan(
    runtimePrefix: List<String>.unmodifiable(runtimePrefix),
    pluginSteps: List<_PluginProcessorStep>.unmodifiable(pluginSteps),
  );
}

String _processorOperationLabel(String descriptor) {
  final String raw = descriptor.split(RegExp(r'[\s(:{]')).first.trim();
  final String label = raw
      .split('')
      .where((String char) => RegExp(r'[A-Za-z0-9_-]').hasMatch(char))
      .take(48)
      .join();
  return label.isEmpty ? 'processor' : label;
}

Map<String, Object?> _processorArguments(String descriptor) {
  final int start = descriptor.indexOf('(');
  final int end = descriptor.lastIndexOf(')');
  if (start < 0 || end <= start) {
    return const <String, Object?>{};
  }
  final Map<String, Object?> arguments = <String, Object?>{};
  for (final String rawPart
      in descriptor.substring(start + 1, end).split(',')) {
    final String part = rawPart.trim();
    if (part.isEmpty) {
      continue;
    }
    final int equals = part.indexOf('=');
    if (equals <= 0) {
      continue;
    }
    final String key = part.substring(0, equals).trim().toLowerCase();
    if (key.isEmpty) {
      continue;
    }
    String value = part.substring(equals + 1).trim();
    if (value.length >= 2) {
      final String first = value[0];
      final String last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        value = value.substring(1, value.length - 1);
      }
    }
    arguments[key] = value;
  }
  return Map<String, Object?>.unmodifiable(arguments);
}

String? _normalizeOptionalMimeType(String? mimeType) {
  final String? normalized = mimeType?.split(';').first.trim().toLowerCase();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

PixaHostPlatform? _currentHostPlatform() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => PixaHostPlatform.android,
    TargetPlatform.iOS => PixaHostPlatform.ios,
    TargetPlatform.macOS => PixaHostPlatform.macos,
    TargetPlatform.windows => PixaHostPlatform.windows,
    TargetPlatform.linux => PixaHostPlatform.linux,
    TargetPlatform.fuchsia => null,
  };
}

int _priorityRankValue(PixaPriority priority) {
  return switch (priority) {
    PixaPriority.low => 0,
    PixaPriority.normal => 1,
    PixaPriority.high => 2,
    PixaPriority.immediate => 3,
  };
}

final class _PriorityInflightQueue {
  _PriorityInflightQueue()
    : _buckets = List<ListQueue<_QueuedInflightEntry>>.generate(
        4,
        (_) => ListQueue<_QueuedInflightEntry>(),
        growable: false,
      );

  final List<ListQueue<_QueuedInflightEntry>> _buckets;
  int _length = 0;

  int get length => _length;

  bool get isNotEmpty => _length > 0;

  void add(_InflightRuntimeLoad inflight) {
    inflight.queueVersion++;
    _buckets[_priorityRankValue(inflight.effectivePriority)].add(
      _QueuedInflightEntry(inflight, inflight.queueVersion),
    );
    _length++;
  }

  void updatePriority(_InflightRuntimeLoad inflight, PixaPriority next) {
    if (inflight.isStarted || inflight.isCancelled) {
      return;
    }
    inflight.queueVersion++;
    _buckets[_priorityRankValue(next)].add(
      _QueuedInflightEntry(inflight, inflight.queueVersion),
    );
    _length++;
  }

  _InflightRuntimeLoad? removeHighest() {
    for (int bucket = _buckets.length - 1; bucket >= 0; bucket--) {
      final ListQueue<_QueuedInflightEntry> queue = _buckets[bucket];
      while (queue.isNotEmpty) {
        final _QueuedInflightEntry entry = queue.removeFirst();
        _length--;
        final _InflightRuntimeLoad inflight = entry.inflight;
        if (entry.version != inflight.queueVersion ||
            inflight.isStarted ||
            inflight.isCancelled ||
            inflight.listeners.isEmpty) {
          continue;
        }
        return inflight;
      }
    }
    return null;
  }

  _InflightRuntimeLoad? firstActiveBelowRank(int rank) {
    for (int bucket = 0; bucket < rank && bucket < _buckets.length; bucket++) {
      for (final _QueuedInflightEntry entry in _buckets[bucket]) {
        final _InflightRuntimeLoad inflight = entry.inflight;
        if (entry.version == inflight.queueVersion &&
            !inflight.isStarted &&
            !inflight.isCancelled &&
            inflight.isQueued &&
            inflight.listeners.isNotEmpty) {
          return inflight;
        }
      }
    }
    return null;
  }

  void compact() {
    final List<ListQueue<_QueuedInflightEntry>> compacted =
        List<ListQueue<_QueuedInflightEntry>>.generate(
          _buckets.length,
          (_) => ListQueue<_QueuedInflightEntry>(),
          growable: false,
        );
    var nextLength = 0;
    for (var bucket = 0; bucket < _buckets.length; bucket++) {
      for (final _QueuedInflightEntry entry in _buckets[bucket]) {
        final _InflightRuntimeLoad inflight = entry.inflight;
        if (entry.version != inflight.queueVersion ||
            inflight.isStarted ||
            inflight.isCancelled ||
            !inflight.isQueued ||
            inflight.listeners.isEmpty) {
          continue;
        }
        compacted[bucket].add(entry);
        nextLength++;
      }
    }
    for (var bucket = 0; bucket < _buckets.length; bucket++) {
      _buckets[bucket] = compacted[bucket];
    }
    _length = nextLength;
  }
}

final class _QueuedInflightEntry {
  const _QueuedInflightEntry(this.inflight, this.version);

  final _InflightRuntimeLoad inflight;
  final int version;
}

final class _InflightRuntimeLoadKey {
  _InflightRuntimeLoadKey._({
    required this.cacheKey,
    required this.encodedCacheKey,
    required this.cacheMode,
    required this.maxAge,
    required this.privateDiskCache,
    required this.limits,
    required this.redirectPolicy,
    required this.retryMode,
    required this.retryMaxAttempts,
    required this.retryDelay,
    required this.retryJitter,
  });

  factory _InflightRuntimeLoadKey.fromRequest(PixaRequest request) {
    return _InflightRuntimeLoadKey._(
      cacheKey: request.cacheKey,
      encodedCacheKey: request.encodedCacheKey,
      cacheMode: request.cachePolicy.mode,
      maxAge: request.cachePolicy.maxAge,
      privateDiskCache: request.cachePolicy.privateDiskCache,
      limits: request.limits,
      redirectPolicy: request.redirectPolicy,
      retryMode: request.retryPolicy.mode,
      retryMaxAttempts: request.retryPolicy.maxAttempts,
      retryDelay: request.retryPolicy.delay,
      retryJitter: request.retryPolicy.jitter,
    );
  }

  final PixaCacheKey cacheKey;
  final PixaCacheKey encodedCacheKey;
  final PixaCacheMode cacheMode;
  final Duration? maxAge;
  final bool privateDiskCache;
  final PixaRequestLimits limits;
  final PixaRedirectPolicy redirectPolicy;
  final PixaRetryMode retryMode;
  final int retryMaxAttempts;
  final Duration retryDelay;
  final Duration retryJitter;

  @override
  bool operator ==(Object other) {
    return other is _InflightRuntimeLoadKey &&
        other.cacheKey == cacheKey &&
        other.encodedCacheKey == encodedCacheKey &&
        other.cacheMode == cacheMode &&
        other.maxAge == maxAge &&
        other.privateDiskCache == privateDiskCache &&
        other.limits == limits &&
        other.redirectPolicy == redirectPolicy &&
        other.retryMode == retryMode &&
        other.retryMaxAttempts == retryMaxAttempts &&
        other.retryDelay == retryDelay &&
        other.retryJitter == retryJitter;
  }

  @override
  int get hashCode {
    return Object.hash(
      cacheKey,
      encodedCacheKey,
      cacheMode,
      maxAge,
      privateDiskCache,
      limits,
      redirectPolicy,
      retryMode,
      retryMaxAttempts,
      Object.hash(retryDelay, retryJitter),
    );
  }
}

final class _RuntimeLoadIsolateJob {
  const _RuntimeLoadIsolateJob({
    required this.cacheRootPath,
    required this.requestPayload,
    required this.inlineBytes,
    required this.cancelTokenId,
    required this.progressSessionId,
  });

  final String cacheRootPath;
  final Uint8List requestPayload;
  final Uint8List? inlineBytes;
  final int cancelTokenId;
  final int progressSessionId;

  PixaRuntimeLoadMessage run() {
    return PixaRuntimeLoader(rootPath: cacheRootPath).loadPreparedMessage(
      requestPayload,
      inlineBytes: inlineBytes,
      cancelTokenId: cancelTokenId,
      progressSessionId: progressSessionId,
    );
  }
}

final class _InflightRuntimeLoad {
  _InflightRuntimeLoad({
    required this.request,
    required this.inflightKey,
    required this.cacheKey,
    required this.rootRequestId,
    required this.sequence,
    required this.startedAtMicros,
  }) : effectivePriority = request.priority;

  final PixaRequest request;
  final _InflightRuntimeLoadKey inflightKey;
  final PixaCacheKey cacheKey;
  final int rootRequestId;
  final int sequence;
  final int startedAtMicros;
  final List<_PipelineListener> listeners = <_PipelineListener>[];
  PixaPriority effectivePriority;
  PixaRuntimeCancelToken? runtimeCancelToken;
  PixaCacheKey? memoryPinKey;
  Completer<void>? _cancellationCompleter;
  int queueVersion = 0;
  bool isStarted = false;
  bool isCancelled = false;
  bool isQueued = false;

  Future<void> get whenCancelled {
    if (isCancelled || listeners.isEmpty) {
      return Future<void>.value();
    }
    return (_cancellationCompleter ??= Completer<void>()).future;
  }

  void notifyCancelled() {
    final Completer<void> completer = _cancellationCompleter ??=
        Completer<void>();
    if (!completer.isCompleted) {
      completer.complete();
    }
  }
}

final class _InflightCancellationSignal implements PixaCancellationSignal {
  const _InflightCancellationSignal(this.inflight);

  final _InflightRuntimeLoad inflight;

  @override
  bool get isCancellationRequested =>
      inflight.isCancelled || inflight.listeners.isEmpty;

  @override
  Future<void> get whenCancelled => inflight.whenCancelled;

  @override
  void throwIfCancellationRequested() {
    if (!isCancellationRequested) {
      return;
    }
    throw PixaFailure(
      requestId: inflight.rootRequestId,
      stage: PixaStage.cancel,
      safeMessage: 'Pixa plugin fetch was cancelled.',
      retryability: PixaRetryability.notRetryable,
    );
  }
}

final class _PipelineListener {
  _PipelineListener(this.requestId, {this.onProgress});

  final int requestId;
  final ValueChanged<PixaProgress>? onProgress;
  final Completer<PixaPipelineLoad> _completer = Completer<PixaPipelineLoad>();
  _InflightRuntimeLoad? inflight;
  bool isCompleted = false;

  Future<PixaPipelineLoad> get future => _completer.future;

  void emitProgress(PixaProgress progress) {
    if (isCompleted) {
      return;
    }
    final ValueChanged<PixaProgress>? callback = onProgress;
    if (callback == null) {
      return;
    }
    try {
      callback(progress);
    } on Object catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  void complete(PixaPipelineLoad load) {
    if (isCompleted) {
      return;
    }
    isCompleted = true;
    _completer.complete(load);
  }

  void completeError(PixaFailure failure) {
    if (isCompleted) {
      return;
    }
    isCompleted = true;
    _completer.completeError(failure, failure.stackTrace);
  }
}

final class _RuntimeLoadReleased {
  const _RuntimeLoadReleased();
}
