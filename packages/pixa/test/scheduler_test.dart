import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';
import 'package:pixa/src/runtime/runtime_disk_cache.dart';
import 'package:pixa/src/runtime/runtime_memory_cache.dart';

void main() {
  test(
    'priority bucket scheduler starts immediate work before thousands of low requests',
    () async {
      final Completer<Uint8List> blockerBytes = Completer<Uint8List>();
      final Completer<String> secondStarted = Completer<String>();
      var startEvents = 0;
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        observers: <PixaObserver>[
          PixaCallbackObserver((PixaEvent event) {
            if (event.name != 'scheduler.start') {
              return;
            }
            startEvents++;
            if (startEvents == 2 && !secondStarted.isCompleted) {
              secondStarted.complete(event.request!.sourceLabel);
            }
          }),
        ],
      );

      final PixaPipelineHandle blockerHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('blocker', () => blockerBytes.future),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );
      final List<PixaPipelineHandle> lowHandles = <PixaPipelineHandle>[
        for (int index = 0; index < 1200; index++)
          pipeline.startLoad(
            PixaRequest(
              source: PixaSource.custom(
                'low-$index',
                () async => _minimalGif(),
              ),
              cachePolicy: const PixaCachePolicy.noStore(),
              priority: PixaPriority.low,
            ),
          ),
      ];
      final PixaPipelineHandle urgentHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('urgent', () async => _minimalGif()),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.immediate,
        ),
      );

      blockerBytes.complete(_minimalGif());
      final String started = await secondStarted.future.timeout(
        const Duration(seconds: 5),
      );

      expect(started, 'custom:urgent');

      urgentHandle.cancel();
      for (final PixaPipelineHandle handle in lowHandles) {
        handle.cancel();
      }
      await Future.wait<void>(
        <PixaPipelineHandle>[
          blockerHandle,
          urgentHandle,
          ...lowHandles,
        ].map(_drainHandle),
      );
    },
  );

  test('scheduler lazily skips thousands of cancelled queued loads', () async {
    final Completer<Uint8List> blockerBytes = Completer<Uint8List>();
    final Completer<String> secondStarted = Completer<String>();
    var startEvents = 0;
    var cancelledLoaderCalls = 0;
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[
        PixaCallbackObserver((PixaEvent event) {
          if (event.name != 'scheduler.start') {
            return;
          }
          startEvents++;
          if (startEvents == 2 && !secondStarted.isCompleted) {
            secondStarted.complete(event.request!.sourceLabel);
          }
        }),
      ],
    );

    final PixaPipelineHandle blockerHandle = pipeline.startLoad(
      PixaRequest(
        source: PixaSource.custom('blocker', () => blockerBytes.future),
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.low,
      ),
    );
    final List<PixaPipelineHandle> cancelledHandles = <PixaPipelineHandle>[
      for (int index = 0; index < 1200; index++)
        pipeline.startLoad(
          PixaRequest(
            source: PixaSource.custom('cancelled-$index', () async {
              cancelledLoaderCalls++;
              return _minimalGif();
            }),
            cachePolicy: const PixaCachePolicy.noStore(),
            priority: PixaPriority.low,
          ),
        ),
    ];
    final List<Future<void>> cancelledDrains = cancelledHandles
        .map(_drainHandle)
        .toList();
    for (final PixaPipelineHandle handle in cancelledHandles) {
      handle.cancel();
    }
    final PixaPipelineHandle urgentHandle = pipeline.startLoad(
      PixaRequest(
        source: PixaSource.custom('urgent', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.immediate,
      ),
    );

    blockerBytes.complete(_minimalGif());
    final String started = await secondStarted.future.timeout(
      const Duration(seconds: 5),
    );

    expect(started, 'custom:urgent');
    expect(cancelledLoaderCalls, 0);

    await Future.wait<void>(<Future<void>>[
      _drainHandle(blockerHandle),
      _drainHandle(urgentHandle),
      ...cancelledDrains,
    ]);
  });

  test(
    'scheduler rejects low priority work when queued load budget is full',
    () async {
      final Completer<Uint8List> blockerBytes = Completer<Uint8List>();
      final List<PixaEvent> events = <PixaEvent>[];
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        maxQueuedRuntimeLoads: 1,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      );

      final PixaPipelineHandle blockerHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('blocker', () => blockerBytes.future),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final PixaPipelineHandle queuedHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('queued', () async => _minimalGif()),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );
      final PixaPipelineHandle rejectedHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('rejected', () async => _minimalGif()),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );

      final Object rejected = await rejectedHandle.future.then<Object>(
        (_) =>
            fail('full low-priority queue should reject new low-priority work'),
        onError: (Object error) => error,
      );

      expect(rejected, isA<PixaFailure>());
      final PixaFailure failure = rejected as PixaFailure;
      expect(failure.stage, PixaStage.request);
      expect(failure.safeMessage, contains('queue is full'));
      expect(pipeline.schedulerStats().queueDepth, 1);
      expect(pipeline.schedulerStats().totalBackpressureDropped, 1);
      expect(
        events.any(
          (PixaEvent event) => event.name == 'scheduler.backpressureReject',
        ),
        isTrue,
      );

      blockerBytes.complete(_minimalGif());
      final PixaPipelineLoad blockerLoad = await blockerHandle.future;
      final PixaPipelineLoad queuedLoad = await queuedHandle.future;
      blockerLoad.dispose();
      queuedLoad.dispose();
    },
  );

  test(
    'scheduler sheds queued low priority work for urgent visible load',
    () async {
      final Completer<Uint8List> blockerBytes = Completer<Uint8List>();
      final Completer<String> secondStarted = Completer<String>();
      final List<PixaEvent> events = <PixaEvent>[];
      var startEvents = 0;
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        maxQueuedRuntimeLoads: 1,
        observers: <PixaObserver>[
          PixaCallbackObserver((PixaEvent event) {
            events.add(event);
            if (event.name != 'scheduler.start') {
              return;
            }
            startEvents++;
            if (startEvents == 2 && !secondStarted.isCompleted) {
              secondStarted.complete(event.request!.sourceLabel);
            }
          }),
        ],
      );

      final PixaPipelineHandle blockerHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('blocker', () => blockerBytes.future),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final PixaPipelineHandle droppedHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('prefetch', () async => _minimalGif()),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.low,
        ),
      );
      final PixaPipelineHandle urgentHandle = pipeline.startLoad(
        PixaRequest(
          source: PixaSource.custom('urgent', () async => _minimalGif()),
          cachePolicy: const PixaCachePolicy.noStore(),
          priority: PixaPriority.immediate,
        ),
      );

      final Object dropped = await droppedHandle.future.then<Object>(
        (_) => fail('low-priority queued work should be shed'),
        onError: (Object error) => error,
      );
      expect(dropped, isA<PixaFailure>());
      expect((dropped as PixaFailure).stage, PixaStage.cancel);
      expect(pipeline.schedulerStats().queueDepth, 1);
      expect(pipeline.schedulerStats().totalBackpressureDropped, 1);

      blockerBytes.complete(_minimalGif());
      final String started = await secondStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(started, 'custom:urgent');
      expect(
        events.any(
          (PixaEvent event) => event.name == 'scheduler.backpressureDrop',
        ),
        isTrue,
      );

      final PixaPipelineLoad blockerLoad = await blockerHandle.future;
      final PixaPipelineLoad urgentLoad = await urgentHandle.future;
      blockerLoad.dispose();
      urgentLoad.dispose();
    },
  );

  test(
    'queued coalesced load is promoted by a higher-priority listener',
    () async {
      final Completer<Uint8List> blockerBytes = Completer<Uint8List>();
      final Completer<String> secondStarted = Completer<String>();
      final List<PixaEvent> events = <PixaEvent>[];
      int startEvents = 0;

      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        observers: <PixaObserver>[
          PixaCallbackObserver((PixaEvent event) {
            events.add(event);
            if (event.name != 'scheduler.start') {
              return;
            }
            startEvents += 1;
            final String? sourceLabel = event.request?.sourceLabel;
            if (startEvents == 2 &&
                sourceLabel != null &&
                !secondStarted.isCompleted) {
              secondStarted.complete(sourceLabel);
            }
          }),
        ],
      );

      final PixaRequest blocker = PixaRequest(
        source: PixaSource.custom('blocker', () => blockerBytes.future),
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.low,
      );
      final PixaRequest visibleLow = PixaRequest(
        source: PixaSource.custom('visible', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.low,
      );
      final PixaRequest normal = PixaRequest(
        source: PixaSource.custom('normal', () async => _minimalGif()),
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.normal,
      );

      final PixaPipelineHandle blockerHandle = pipeline.startLoad(blocker);
      final PixaPipelineHandle visibleLowHandle = pipeline.startLoad(
        visibleLow,
      );
      final PixaPipelineHandle normalHandle = pipeline.startLoad(normal);
      final PixaPipelineHandle visibleHighHandle = pipeline.startLoad(
        visibleLow.copyWith(priority: PixaPriority.high),
      );

      blockerBytes.complete(_minimalGif());

      final String promotedStart = await secondStarted.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw StateError('Timed out waiting for the promoted load to start.');
        },
      );

      expect(promotedStart, 'custom:visible');
      expect(
        events.any(
          (PixaEvent event) =>
              event.name == 'scheduler.priorityPromoted' &&
              event.attributes['from'] == 'low' &&
              event.attributes['to'] == 'high',
        ),
        isTrue,
      );

      final List<PixaPipelineLoad> loads =
          await Future.wait(<Future<PixaPipelineLoad>>[
            blockerHandle.future,
            visibleLowHandle.future,
            normalHandle.future,
            visibleHighHandle.future,
          ]);
      for (final PixaPipelineLoad load in loads) {
        load.dispose();
      }
    },
  );

  test('inline source failure is reported at fetch stage', () async {
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('broken', () async {
        throw StateError('inline source unavailable');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final Object error = await pipeline
        .load(request)
        .then<Object>(
          (_) => fail('custom source failure should fail the load'),
          onError: (Object error) => error,
        );

    expect(error, isA<PixaFailure>());
    final PixaFailure failure = error as PixaFailure;
    expect(failure.stage, PixaStage.fetch);
    expect(failure.safeMessage, contains('custom:broken'));
    expect(failure.retryability, PixaRetryability.notRetryable);
    expect(
      events.any(
        (PixaEvent event) =>
            event.name == 'runtime.load.start' &&
            event.attributes['retryMode'] == 'none' &&
            event.attributes['maxAttempts'] == 1,
      ),
      isTrue,
    );
    final PixaEvent failureEvent = events.singleWhere(
      (PixaEvent event) => event.name == 'request.failure',
    );
    expect(failureEvent.stage, PixaStage.fetch);
    expect(failureEvent.failure?.stage, PixaStage.fetch);
    expect(failureEvent.durationMicros, isNotNull);
  });

  test(
    'video frame request fails typed unsupported when no backend is registered',
    () async {
      final List<PixaEvent> events = <PixaEvent>[];
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      );
      final PixaRequest request = PixaRequest.videoFrame(
        'file:///photos/private/movie.mp4',
        timestamp: const Duration(seconds: 2),
        targetSize: const PixaTargetSize(width: 160, height: 90),
      );

      final Object error = await pipeline
          .load(request)
          .then<Object>(
            (_) => fail('video frame without a backend should fail the load'),
            onError: (Object error) => error,
          );

      expect(error, isA<PixaFailure>());
      final PixaFailure failure = error as PixaFailure;
      expect(failure.stage, PixaStage.fetch);
      expect(failure.retryability, PixaRetryability.notRetryable);
      expect(failure.safeMessage, contains('video-frame'));
      final PixaEvent failureEvent = events.singleWhere(
        (PixaEvent event) => event.name == 'request.failure',
      );
      expect(failureEvent.stage, PixaStage.fetch);
      expect(failureEvent.failure, same(failure));
    },
  );

  test('cancelled listener emits observer cancellation span', () async {
    final Completer<Uint8List> pendingBytes = Completer<Uint8List>();
    final Completer<void> released = Completer<void>();
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[
        PixaCallbackObserver((PixaEvent event) {
          events.add(event);
          if (event.name == 'request.released' && !released.isCompleted) {
            released.complete();
          }
        }),
      ],
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('pending', () => pendingBytes.future),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaPipelineHandle handle = pipeline.startLoad(request);
    await Future<void>.delayed(Duration.zero);
    handle.cancel();
    pendingBytes.complete(_minimalGif());

    final Object error = await handle.future.then<Object>(
      (_) => fail('cancelled load should complete with a cancellation failure'),
      onError: (Object error) => error,
    );
    await released.future.timeout(const Duration(seconds: 5));

    expect(error, isA<PixaFailure>());
    final PixaFailure failure = error as PixaFailure;
    expect(failure.stage, PixaStage.cancel);
    final PixaEvent cancelEvent = events.singleWhere(
      (PixaEvent event) => event.name == 'request.cancel',
    );
    expect(cancelEvent.stage, PixaStage.cancel);
    expect(cancelEvent.attributes['remainingListeners'], 0);
    expect(cancelEvent.attributes['started'], isTrue);
    expect(cancelEvent.durationMicros, isNotNull);
  });

  test(
    'registered Dart fetcher handles explicit custom source with observer spans',
    () async {
      final List<PixaEvent> events = <PixaEvent>[];
      final List<PixaProgress> progressEvents = <PixaProgress>[];
      final PixaRegistry registry = PixaRegistry()
        ..registerFetcher(
          _DartFetcherDescriptor(
            id: 'plugin-fetcher',
            sourceKinds: const <String>{'plugin'},
            fetcher: _PluginFetcher(),
          ),
        );
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        registry: registry,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      );
      final PixaRequest request = PixaRequest(
        source: PixaSource.custom('plugin', () async {
          throw StateError('fallback loader must not run');
        }),
        cachePolicy: const PixaCachePolicy.noStore(),
      );

      final PixaPipelineHandle handle = pipeline.startLoad(
        request,
        onProgress: progressEvents.add,
      );
      final PixaPipelineLoad load = await handle.future;
      load.dispose();

      expect(
        progressEvents.any(
          (PixaProgress progress) =>
              progress.stage == PixaStage.fetch &&
              progress.receivedBytes == _minimalGif().length &&
              progress.expectedBytes == _minimalGif().length,
        ),
        isTrue,
      );
      final int pluginStart = events.indexWhere(
        (PixaEvent event) => event.name == 'plugin.fetch.start',
      );
      final int pluginProgress = events.indexWhere(
        (PixaEvent event) => event.name == 'plugin.fetch.progress',
      );
      final int pluginComplete = events.indexWhere(
        (PixaEvent event) => event.name == 'plugin.fetch.complete',
      );
      final int requestComplete = events.indexWhere(
        (PixaEvent event) => event.name == 'request.complete',
      );

      expect(pluginStart, isNonNegative);
      expect(pluginProgress, greaterThan(pluginStart));
      expect(pluginComplete, greaterThan(pluginProgress));
      expect(requestComplete, greaterThan(pluginComplete));
      expect(events[pluginComplete].attributes['fetcherId'], 'plugin-fetcher');
      expect(events[pluginComplete].attributes['sourceKind'], 'plugin');
      expect(events[pluginComplete].attributes['bytes'], _minimalGif().length);
    },
  );

  test(
    'registered Dart processor runs and reuses processed memory cache',
    () async {
      PixaRuntimeMemoryCache.clear();
      final List<PixaEvent> events = <PixaEvent>[];
      final _CountingProcessor processor = _CountingProcessor();
      final PixaRegistry registry = PixaRegistry()
        ..registerProcessor(
          _DartProcessorDescriptor(
            id: 'plugin-processor',
            operations: const <String>{'tag'},
            processor: processor,
          ),
        );
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        registry: registry,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      );
      var loaderCalls = 0;
      final PixaRequest request = PixaRequest(
        source: PixaSource.custom('processor-source', () async {
          loaderCalls++;
          return _minimalGif();
        }),
        processors: const <String>['tag(label=avatar)'],
        cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
      );

      final PixaPipelineLoad first = await pipeline.load(request);
      first.dispose();
      final PixaPipelineLoad second = await pipeline.load(request);
      second.dispose();

      expect(loaderCalls, 1);
      expect(processor.calls, 1);
      expect(processor.lastArguments, <String, Object?>{'label': 'avatar'});
      expect(
        events.map((PixaEvent event) => event.name),
        containsAllInOrder(<String>[
          'plugin.processor.start',
          'plugin.processor.complete',
          'cache.processed.memory.write',
          'cache.processed.memory.hit',
        ]),
      );
    },
  );

  test(
    'registered Dart decoder runs only with explicit opt-in and reuses cache',
    () async {
      PixaRuntimeMemoryCache.clear();
      final List<PixaEvent> events = <PixaEvent>[];
      final _CountingDecoder decoder = _CountingDecoder();
      final PixaRegistry registry = PixaRegistry()
        ..registerDecoder(
          _DartDecoderDescriptor(
            id: 'plugin-decoder',
            mimeTypes: const <String>{'image/gif'},
            priority: 10,
            decoder: decoder,
          ),
        );
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        registry: registry,
        observers: <PixaObserver>[PixaCallbackObserver(events.add)],
      );
      var loaderCalls = 0;
      final PixaRequest request = PixaRequest(
        source: PixaSource.custom('decoder-source', () async {
          loaderCalls++;
          return _minimalGif();
        }),
        pluginExecutionPolicy:
            const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
        decoderOptions: const <String, Object?>{'mimeType': 'image/gif'},
        cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
      );

      final PixaPipelineLoad first = await pipeline.load(request);
      first.dispose();
      final PixaPipelineLoad second = await pipeline.load(request);
      second.dispose();

      expect(loaderCalls, 1);
      expect(decoder.calls, 1);
      expect(decoder.lastMimeType, 'image/gif');
      expect(
        events.map((PixaEvent event) => event.name),
        containsAllInOrder(<String>[
          'plugin.decoder.start',
          'plugin.decoder.complete',
          'cache.decoder.memory.write',
          'cache.decoder.memory.hit',
        ]),
      );
    },
  );

  test('registered Dart decoder can route by explicit format id', () async {
    PixaRuntimeMemoryCache.clear();
    final _CountingDecoder decoder = _CountingDecoder();
    final PixaRegistry registry = PixaRegistry()
      ..registerDecoder(
        _DartDecoderDescriptor(
          id: 'plugin-decoder-format',
          mimeTypes: const <String>{},
          formatIds: const <String>{'gif'},
          priority: 10,
          decoder: decoder,
        ),
      );
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      registry: registry,
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('decoder-format-source', () async {
        return _minimalGif();
      }),
      pluginExecutionPolicy:
          const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
      decoderOptions: const <String, Object?>{'formatId': 'GIF'},
      cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
    );

    final PixaPipelineLoad first = await pipeline.load(request);
    first.dispose();
    final PixaPipelineLoad second = await pipeline.load(request);
    second.dispose();

    expect(decoder.calls, 1);
    expect(decoder.lastMimeType, 'image/gif');
  });

  test(
    'registered Dart decoder does not run without explicit opt-in',
    () async {
      final _CountingDecoder decoder = _CountingDecoder();
      final PixaRegistry registry = PixaRegistry()
        ..registerDecoder(
          _DartDecoderDescriptor(
            id: 'plugin-decoder',
            mimeTypes: const <String>{'image/gif'},
            priority: 10,
            decoder: decoder,
          ),
        );
      final PixaPipeline pipeline = PixaPipeline(
        cacheRootPath: '',
        maxConcurrentRuntimeLoads: 1,
        registry: registry,
      );
      final PixaRequest request = PixaRequest(
        source: PixaSource.custom('decoder-source', () async => _minimalGif()),
        decoderOptions: const <String, Object?>{'mimeType': 'image/gif'},
        cachePolicy: const PixaCachePolicy.noStore(),
      );

      final PixaPipelineLoad load = await pipeline.load(request);
      load.dispose();

      expect(decoder.calls, 0);
    },
  );

  test('runtime load emits complete timing span', () async {
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('timed-fetch', () async => _minimalGif()),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaPipelineLoad load = await pipeline.load(request);
    load.dispose();

    final int startIndex = events.indexWhere(
      (PixaEvent event) => event.name == 'runtime.load.start',
    );
    final int completeIndex = events.indexWhere(
      (PixaEvent event) => event.name == 'runtime.load.complete',
    );
    final int terminalIndex = events.indexWhere(
      (PixaEvent event) =>
          event.name == 'request.complete' && event.progress == null,
    );

    expect(startIndex, isNonNegative);
    expect(completeIndex, greaterThan(startIndex));
    expect(terminalIndex, greaterThan(completeIndex));
    final PixaEvent complete = events[completeIndex];
    expect(complete.durationMicros, isNotNull);
    expect(complete.durationMicros, greaterThanOrEqualTo(0));
    expect(complete.attributes['bytes'], _minimalGif().length);
  });

  test('runtime load exposes encoded bytes as read-only view', () async {
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('read-only-runtime-buffer', () async {
        return _minimalGif();
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaPipelineLoad load = await pipeline.load(request);
    try {
      expect(load.bytes.first, 0x47);
      expect(() => load.bytes[0] = 0, throwsUnsupportedError);
    } finally {
      load.dispose();
    }
  });

  test('runtime retry progress reaches terminal completion', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    var requestCount = 0;
    unawaited(
      server.forEach((HttpRequest request) {
        requestCount += 1;
        if (requestCount < 3) {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..headers.contentLength = 5
            ..write('error');
        } else {
          final Uint8List bytes = _minimalGif();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('image', 'gif')
            ..headers.contentLength = bytes.length
            ..add(bytes);
        }
        request.response.close();
      }),
    );
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );

    final PixaPipelineLoad load = await pipeline.load(
      PixaRequest.network(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/image.gif',
        cachePolicy: const PixaCachePolicy.noStore(),
        retryPolicy: const PixaRetryPolicy(
          mode: PixaRetryMode.fixed,
          maxAttempts: 3,
          delay: Duration.zero,
          jitter: Duration.zero,
        ),
      ),
    );
    load.dispose();

    expect(requestCount, 3);
    expect(
      events.where((PixaEvent event) => event.name == 'request.retry'),
      hasLength(2),
    );
    final PixaEvent terminalComplete = events.singleWhere(
      (PixaEvent event) =>
          event.name == 'request.complete' && event.progress == null,
    );
    expect(terminalComplete.durationMicros, isNotNull);
  });

  test('network progressive JPEG emits progressive preview progress', () async {
    final Uint8List bytes = _progressiveJpegWithScan();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    unawaited(
      server.forEach((HttpRequest request) async {
        final int split = bytes.length - 2;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'jpeg')
          ..headers.contentLength = bytes.length
          ..add(bytes.sublist(0, split));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.add(bytes.sublist(split));
        await request.response.close();
      }),
    );
    final List<PixaEvent> events = <PixaEvent>[];
    final List<PixaProgress> progress = <PixaProgress>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: '',
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );

    final PixaPipelineHandle handle = pipeline.startLoad(
      PixaRequest.network(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/image.jpg',
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
      onProgress: progress.add,
    );
    final PixaPipelineLoad load = await handle.future;
    try {
      expect(load.bytes, bytes);
    } finally {
      load.dispose();
    }

    final PixaProgress previewProgress = progress.singleWhere(
      (PixaProgress progress) => progress.progressivePreview != null,
    );
    final PixaProgressivePreview preview = previewProgress.progressivePreview!;
    expect(preview.mimeType, 'image/jpeg');
    expect(preview.bytes.take(2), <int>[0xff, 0xd8]);
    expect(preview.bytes.skip(preview.bytes.length - 2), <int>[0xff, 0xd9]);
    expect(
      events.any((PixaEvent event) => event.name == 'fetch.progressivePreview'),
      isTrue,
    );
  });

  test('inline source disk cache hit skips loader bytes', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-inline-hit-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    var loaderCalls = 0;
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: cacheRoot.path,
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('inline-hit', () async {
        loaderCalls++;
        return _minimalGif();
      }),
    );
    final bool seeded = PixaRuntimeDiskCache(rootPath: cacheRoot.path).write(
      namespace: request.cacheNamespace,
      key: request.encodedCacheKey,
      bytes: _minimalGif(),
    );
    expect(seeded, isTrue);

    final PixaPipelineLoad load = await pipeline.load(request);
    load.dispose();

    expect(loaderCalls, 0);
    expect(
      events.any(
        (PixaEvent event) => event.name == 'inline.bytes.skippedForCacheHit',
      ),
      isTrue,
    );
  });

  test('cache-first multi-source selects cached secondary source', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-multi-source-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    final List<PixaEvent> events = <PixaEvent>[];
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: cacheRoot.path,
      maxConcurrentRuntimeLoads: 1,
      observers: <PixaObserver>[PixaCallbackObserver(events.add)],
    );
    final PixaSource secondary = PixaSource.custom('secondary', () async {
      throw StateError('cached secondary loader must not run');
    });
    final PixaRequest secondaryRequest = PixaRequest(source: secondary);
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('primary', () async {
        throw StateError(
          'primary loader must not run when secondary is cached',
        );
      }),
      sources: <PixaSource>[secondary],
    );
    final bool seeded = PixaRuntimeDiskCache(rootPath: cacheRoot.path).write(
      namespace: request.cacheNamespace,
      key: secondaryRequest.encodedCacheKey,
      bytes: _minimalGif(),
    );
    expect(seeded, isTrue);

    final PixaPipelineLoad load = await pipeline.load(request);
    load.dispose();

    final PixaEvent selected = events.singleWhere(
      (PixaEvent event) => event.name == 'request.sourceSelectedFromCache',
    );
    expect(selected.attributes['candidateIndex'], 1);
    expect(selected.attributes['sourceLabel'], 'custom:secondary');
  });
}

final class _DartFetcherDescriptor implements PixaDartFetcherDescriptor {
  const _DartFetcherDescriptor({
    required this.id,
    required this.sourceKinds,
    required this.fetcher,
  });

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  final Set<String> sourceKinds;

  @override
  final PixaFetcher fetcher;
}

final class _DartProcessorDescriptor implements PixaDartProcessorDescriptor {
  const _DartProcessorDescriptor({
    required this.id,
    required this.operations,
    required this.processor,
  });

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  final Set<String> operations;

  @override
  final PixaProcessor processor;
}

final class _DartDecoderDescriptor implements PixaDartDecoderDescriptor {
  const _DartDecoderDescriptor({
    required this.id,
    required this.mimeTypes,
    this.formatIds = const <String>{},
    required this.priority,
    required this.decoder,
  });

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  final Set<String> mimeTypes;

  @override
  final Set<String> formatIds;

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  final int priority;

  @override
  final PixaDecoder decoder;
}

final class _PluginFetcher implements PixaFetcher {
  @override
  PixaBytePayload fetch(PixaSource source, PixaExecutionContext context) {
    context.cancellationSignal.throwIfCancellationRequested();
    final Uint8List bytes = _minimalGif();
    context.emit(
      PixaProgress(
        requestId: context.requestId,
        stage: PixaStage.fetch,
        receivedBytes: bytes.length,
        expectedBytes: bytes.length,
      ),
    );
    return PixaBytePayload(bytes: bytes, mimeType: 'image/gif');
  }
}

final class _CountingProcessor implements PixaProcessor {
  int calls = 0;
  Map<String, Object?> lastArguments = const <String, Object?>{};

  @override
  PixaBytePayload process(PixaBytePayload input, PixaProcessorContext context) {
    calls++;
    lastArguments = context.arguments;
    context.execution.emit(
      PixaProgress(
        requestId: context.execution.requestId,
        stage: PixaStage.process,
        receivedBytes: input.bytes.length,
        expectedBytes: input.bytes.length,
      ),
    );
    return input;
  }
}

final class _CountingDecoder implements PixaDecoder {
  int calls = 0;
  String? lastMimeType;

  @override
  PixaBytePayload decode(PixaBytePayload input, PixaExecutionContext context) {
    calls++;
    lastMimeType = input.mimeType;
    context.emit(
      PixaProgress(
        requestId: context.requestId,
        stage: PixaStage.decode,
        receivedBytes: input.bytes.length,
        expectedBytes: input.bytes.length,
      ),
    );
    return input;
  }
}

Uint8List _minimalGif() {
  return Uint8List.fromList(<int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xff,
    0xff,
    0xff,
    0x2c,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x4c,
    0x01,
    0x00,
    0x3b,
  ]);
}

Uint8List _progressiveJpegWithScan() {
  return base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQO'
    'DwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcH'
    'BwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo'
    'KCgoKCgoKCgoKCgoKCj/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAA'
    'AAAAAAAAAAb/xAAVAQEBAAAAAAAAAAAAAAAAAAAFBv/aAAwDAQACEAMQAAABrBDl'
    'f//EABcQAAMBAAAAAAAAAAAAAAAAAAECBAP/2gAIAQEAAQUCgzQw/wD/xAAXEQAD'
    'AQAAAAAAAAAAAAAAAAAAAQMy/9oACAEDAQE/Aa7Z/8QAGBEAAgMAAAAAAAAAAAAA'
    'AAAAAAIDM3H/2gAIAQIBAT8BntbT/8QAGhAAAgIDAAAAAAAAAAAAAAAAAQIABBNB'
    'Yf/aAAgBAQAGPwKsSik411yf/8QAFhABAQEAAAAAAAAAAAAAAAAAASEA/9oACAE'
    'BAAE/IWZBlRY3/9oADAMBAAIAAwAAABAL/8QAFxEAAwEAAAAAAAAAAAAAAAAAAA'
    'Ghsf/aAAgBAwEBPxCl6f/EABcRAAMBAAAAAAAAAAAAAAAAAAABobH/2gAIAQIBA'
    'T8Qtaz/xAAXEAEBAQEAAAAAAAAAAAAAAAABEQAh/9oACAEBAAE/EHqSlKbKzrv'
    '/2Q==',
  );
}

Future<void> _drainHandle(PixaPipelineHandle handle) async {
  try {
    final PixaPipelineLoad load = await handle.future;
    load.dispose();
  } on Object {
    // Cancellation failures are expected while draining stress-test handles.
  }
}
