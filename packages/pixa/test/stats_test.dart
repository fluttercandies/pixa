import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart'
    show
        PixaDebugSnapshot,
        PixaDisplayDecoderBackendSnapshot,
        PixaDisplayDecoderSnapshot,
        PixaRuntimeCapabilities,
        PixaRuntimeImageFormatCapability,
        PixaRuntimePlatformSelfCheck,
        PixaRuntimePluginRegistryStats,
        PixaRuntimePlatformContract,
        PixaRuntimePlatformStatus,
        PixaSchedulerStats;
import 'package:pixa/src/cache_key.dart';
import 'package:pixa/src/runtime/runtime_loader.dart';
import 'package:pixa/src/runtime/runtime_memory_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PixaCacheStats computes live runtime handles and sessions', () {
    const PixaCacheStats stats = PixaCacheStats(
      memoryEntries: 1,
      memoryBytes: 128,
      memoryHits: 2,
      memoryMisses: 1,
      diskHits: 3,
      diskMisses: 4,
      diskWrites: 5,
      diskCorruptionRecoveries: 6,
      evictions: 7,
      ownedBufferHandlesCreated: 10,
      ownedBufferHandlesFreed: 7,
      progressSessionsCreated: 8,
      progressSessionsFreed: 6,
    );

    expect(stats.liveOwnedBufferHandles, 3);
    expect(stats.liveProgressSessions, 2);
    expect(stats.hitRate, 0.5);
  });

  test('PixaSchedulerStats exposes debug json', () {
    const PixaSchedulerStats stats = PixaSchedulerStats(
      maxConcurrentRuntimeLoads: 6,
      maxQueuedRuntimeLoads: 2048,
      activeRuntimeLoads: 2,
      queueDepth: 3,
      inflightRequests: 4,
      listeners: 5,
      totalQueued: 7,
      totalStarted: 8,
      totalCoalesced: 9,
      totalCompleted: 10,
      totalFailed: 11,
      totalCancelled: 12,
      totalBackpressureDropped: 13,
      runtimeProgressEvents: 13,
      runtimeProgressEventsDropped: 14,
      observerEventsDroppedBySampling: 15,
      dartToRuntimeInputCopies: 16,
      dartToRuntimeInputBytesCopied: 17,
    );

    expect(stats.toJson(), <String, Object?>{
      'maxConcurrentRuntimeLoads': 6,
      'maxQueuedRuntimeLoads': 2048,
      'activeRuntimeLoads': 2,
      'queueDepth': 3,
      'inflightRequests': 4,
      'listeners': 5,
      'totalQueued': 7,
      'totalStarted': 8,
      'totalCoalesced': 9,
      'totalCompleted': 10,
      'totalFailed': 11,
      'totalCancelled': 12,
      'totalBackpressureDropped': 13,
      'runtimeProgressEvents': 13,
      'runtimeProgressEventsDropped': 14,
      'observerEventsDroppedBySampling': 15,
      'dartToRuntimeInputCopies': 16,
      'dartToRuntimeInputBytesCopied': 17,
    });
  });

  test('PixaDebugSnapshot aggregates observability stats as json', () {
    final PixaDebugSnapshot snapshot = PixaDebugSnapshot(
      isConfigured: true,
      config: PixaConfig(
        memoryCacheBytes: 1024,
        diskCacheBytes: 4096,
        networkConcurrency: 3,
        decodeConcurrency: 2,
        maxImageCompletionsPerFrame: 7,
        maxQueuedRuntimeLoads: 1024,
        maxQueuedDecodes: 256,
        decodedCacheMaximumSize: 23,
        decodedCacheMaximumSizeBytes: 8192,
      ),
      displayDecoder: PixaDisplayDecoderSnapshot(
        selector: 'pixa-display-decoder-v1',
        defaultBackend: 'engine',
        hasRuntimeDisplayBackend: false,
        completionQueueDepth: 0,
        completionsReleasedThisFrame: 3,
        completionFrameScheduled: true,
        backends: <PixaDisplayDecoderBackendSnapshot>[
          PixaDisplayDecoderBackendSnapshot(
            id: 'engine',
            execution: 'flutter',
            streamKind: 'multi-frame-codec',
            usesFlutterEngine: true,
            ownsPipeline: false,
            supportsAnimatedImages: true,
          ),
        ],
      ),
      capabilities: PixaRuntimeCapabilities(
        diskCache: true,
        httpTransport: true,
        exifParser: true,
        pixelProcessors: true,
        runtimePluginAbiVersion: 1,
        runtimePluginRegistryStats: PixaRuntimePluginRegistryStats(
          modules: 2,
          builtInModules: 1,
          hostLinkedModules: 1,
          assetModules: 0,
          linkableModules: 2,
          fetchers: 1,
          decoders: 1,
          processors: 0,
          cacheStores: 0,
        ),
        imageFormats: const <PixaRuntimeImageFormatCapability>[
          PixaRuntimeImageFormatCapability(
            format: PixaImageMetadataFormat.jpeg,
            sniffing: true,
            metadata: true,
            engineDisplay: true,
            runtimeDisplay: true,
            processorDecode: true,
            regionDecode: false,
            animated: false,
            defaultRuntimeDisplay: false,
          ),
          PixaRuntimeImageFormatCapability(
            format: PixaImageMetadataFormat.ico,
            sniffing: true,
            metadata: true,
            engineDisplay: false,
            runtimeDisplay: true,
            processorDecode: true,
            regionDecode: false,
            animated: false,
            defaultRuntimeDisplay: true,
          ),
        ],
        platformStatus: PixaRuntimePlatformStatus(
          platform: 'macOS',
          isWeb: false,
          isSupportedPlatform: true,
          runtimeAvailable: true,
          contract: PixaRuntimePlatformContract.macOS,
          message: 'runtime core available',
        ),
      ),
      platformSelfCheck: PixaRuntimePlatformSelfCheck.evaluate(
        capabilities: PixaRuntimeCapabilities(
          diskCache: true,
          httpTransport: true,
          exifParser: true,
          pixelProcessors: true,
          runtimePluginAbiVersion: 1,
          platformStatus: PixaRuntimePlatformStatus(
            platform: 'macOS',
            isWeb: false,
            isSupportedPlatform: true,
            runtimeAvailable: true,
            contract: PixaRuntimePlatformContract.macOS,
            message: 'runtime core available',
          ),
        ),
        cacheRootPath: '/tmp/pixa-cache',
      ),
      cacheStats: PixaCacheStats(
        memoryEntries: 1,
        memoryBytes: 128,
        memoryHits: 2,
        memoryMisses: 1,
        diskHits: 3,
        diskMisses: 4,
        diskWrites: 5,
        diskCorruptionRecoveries: 6,
        evictions: 7,
        ownedBufferHandlesCreated: 10,
        ownedBufferHandlesFreed: 8,
        progressSessionsCreated: 12,
        progressSessionsFreed: 9,
      ),
      decodedCacheStats: PixaDecodedCacheStats(
        currentSize: 2,
        currentSizeBytes: 256,
        maximumSize: 10,
        maximumSizeBytes: 1024,
        liveImageCount: 1,
      ),
      schedulerStats: PixaSchedulerStats(
        maxConcurrentRuntimeLoads: 3,
        maxQueuedRuntimeLoads: 1024,
        activeRuntimeLoads: 1,
        queueDepth: 2,
        inflightRequests: 3,
        listeners: 4,
        totalQueued: 5,
        totalStarted: 6,
        totalCoalesced: 7,
        totalCompleted: 8,
        totalFailed: 9,
        totalCancelled: 10,
        totalBackpressureDropped: 11,
        runtimeProgressEvents: 11,
        runtimeProgressEventsDropped: 12,
        observerEventsDroppedBySampling: 13,
        dartToRuntimeInputCopies: 14,
        dartToRuntimeInputBytesCopied: 15,
      ),
    );

    final Map<String, Object?> json = snapshot.toJson();
    final Map<String, Object?> cacheStats =
        json['cacheStats']! as Map<String, Object?>;
    final Map<String, Object?> decodedStats =
        json['decodedCacheStats']! as Map<String, Object?>;
    final Map<String, Object?> schedulerStats =
        json['schedulerStats']! as Map<String, Object?>;
    final Map<String, Object?> capabilities =
        json['capabilities']! as Map<String, Object?>;
    final Map<String, Object?> displayDecoder =
        json['displayDecoder']! as Map<String, Object?>;
    final List<Object?> displayDecoderBackends =
        displayDecoder['backends']! as List<Object?>;
    final Map<String, Object?> engineDisplayBackend =
        displayDecoderBackends.single! as Map<String, Object?>;
    final Map<String, Object?> platformContract =
        capabilities['platformContract']! as Map<String, Object?>;
    final Map<String, Object?> pluginStats =
        capabilities['runtimePluginRegistryStats']! as Map<String, Object?>;
    final Map<String, Object?> platformSelfCheck =
        capabilities['platformSelfCheck']! as Map<String, Object?>;
    final List<Object?> imageFormats =
        capabilities['imageFormats']! as List<Object?>;
    final Map<String, Object?> jpegCapability =
        imageFormats.first! as Map<String, Object?>;
    final Map<String, Object?> icoCapability =
        imageFormats.last! as Map<String, Object?>;

    expect(cacheStats['hitRate'], 0.5);
    expect(cacheStats['diskCorruptionRecoveries'], 6);
    expect(cacheStats['liveOwnedBufferHandles'], 2);
    expect(cacheStats['liveProgressSessions'], 3);
    expect(displayDecoder['selector'], 'pixa-display-decoder-v1');
    expect(displayDecoder['defaultBackend'], 'engine');
    expect(displayDecoder['hasRuntimeDisplayBackend'], isFalse);
    expect(displayDecoder['completionQueueDepth'], 0);
    expect(displayDecoder['completionsReleasedThisFrame'], 3);
    expect(displayDecoder['completionFrameScheduled'], isTrue);
    expect(engineDisplayBackend['execution'], 'flutter');
    expect(engineDisplayBackend['streamKind'], 'multi-frame-codec');
    expect(engineDisplayBackend['usesFlutterEngine'], isTrue);
    expect(engineDisplayBackend['ownsPipeline'], isFalse);
    expect(platformContract['platform'], 'macOS');
    expect(capabilities['runtimePluginAbiVersion'], 1);
    expect(pluginStats['hostLinkedModules'], 1);
    expect(pluginStats['canUseSingleHostBinary'], isTrue);
    expect(jpegCapability['format'], 'jpeg');
    expect(jpegCapability['engineDisplay'], isTrue);
    expect(jpegCapability['defaultRuntimeDisplay'], isFalse);
    expect(icoCapability['format'], 'ico');
    expect(icoCapability['engineDisplay'], isFalse);
    expect(icoCapability['defaultRuntimeDisplay'], isTrue);
    expect(platformSelfCheck['passed'], isTrue);
    expect(platformContract['targetAbis'], <String>[
      'macos-arm64',
      'macos-x64',
    ]);
    expect(decodedStats['byteUtilization'], 0.25);
    final Map<String, Object?> config = json['config']! as Map<String, Object?>;
    expect(config['decodedCacheMaximumSize'], 23);
    expect(config['decodedCacheMaximumSizeBytes'], 8192);
    expect(config['maxImageCompletionsPerFrame'], 7);
    expect(config['maxQueuedRuntimeLoads'], 1024);
    expect(config['maxQueuedDecodes'], 256);
    expect(schedulerStats['totalCancelled'], 10);
    expect(schedulerStats['totalBackpressureDropped'], 11);
    expect(schedulerStats['dartToRuntimeInputCopies'], 14);
  });

  test('Pixa decoded cache stats reflect Flutter ImageCache budgets', () {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    final int previousMaximumSize = cache.maximumSize;
    final int previousMaximumSizeBytes = cache.maximumSizeBytes;
    addTearDown(() {
      cache.maximumSize = previousMaximumSize;
      cache.maximumSizeBytes = previousMaximumSizeBytes;
    });

    Pixa.tuneDecodedCache(maximumSize: 17, maximumSizeBytes: 4096);

    final PixaDecodedCacheStats stats = Pixa.decodedCacheStats();
    expect(stats.maximumSize, 17);
    expect(stats.maximumSizeBytes, 4096);
    expect(stats.currentSize, cache.currentSize);
    expect(stats.currentSizeBytes, cache.currentSizeBytes);
    expect(stats.liveImageCount, cache.liveImageCount);
    expect(stats.byteUtilization, cache.currentSizeBytes / 4096);
    expect(() => Pixa.tuneDecodedCache(maximumSize: -1), throwsRangeError);
  });

  test(
    'PixaConfig applies Flutter decoded cache budget during configure',
    () async {
      final ImageCache cache = PaintingBinding.instance.imageCache;
      final int previousMaximumSize = cache.maximumSize;
      final int previousMaximumSizeBytes = cache.maximumSizeBytes;
      addTearDown(() {
        cache.maximumSize = previousMaximumSize;
        cache.maximumSizeBytes = previousMaximumSizeBytes;
      });

      await Pixa.configure(
        const PixaConfig(
          cacheRootPath: '',
          decodedCacheMaximumSize: 19,
          decodedCacheMaximumSizeBytes: 8192,
        ),
      );

      expect(cache.maximumSize, 19);
      expect(cache.maximumSizeBytes, 8192);
      expect(Pixa.config.decodedCacheMaximumSize, 19);
      expect(Pixa.config.decodedCacheMaximumSizeBytes, 8192);
    },
  );

  testWidgets(
    'Pixa.trimMemory clears Flutter decoded cache on critical pressure',
    (WidgetTester tester) async {
      final ImageCache cache = PaintingBinding.instance.imageCache;
      final int previousMaximumSize = cache.maximumSize;
      final int previousMaximumSizeBytes = cache.maximumSizeBytes;
      cache.clear();
      cache.clearLiveImages();
      addTearDown(() {
        cache.clear();
        cache.clearLiveImages();
        cache.maximumSize = previousMaximumSize;
        cache.maximumSizeBytes = previousMaximumSizeBytes;
      });
      final Directory cacheRoot = Directory.systemTemp.createTempSync(
        'pixa-trim-memory-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));
      await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
      final ui.Image image =
          await tester.runAsync(() => createTestImage(width: 1, height: 1)) ??
          (throw StateError('Failed to create decoded cache test image.'));
      addTearDown(image.dispose);
      final Object cacheKey = Object();

      cache.putIfAbsent(
        cacheKey,
        () => OneFrameImageStreamCompleter(
          Future<ImageInfo>.value(ImageInfo(image: image.clone())),
        ),
      );
      await tester.pump();

      expect(cache.containsKey(cacheKey), isTrue);

      await Pixa.trimMemory(level: PixaMemoryTrimLevel.critical);

      expect(cache.containsKey(cacheKey), isFalse);
      expect(Pixa.decodedCacheStats().currentSize, 0);
    },
  );

  test('Pixa.configure rejects invalid runtime and decode budgets', () {
    expect(
      Pixa.configure(const PixaConfig(memoryCacheBytes: -1)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(diskCacheBytes: -1)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(networkConcurrency: 0)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(decodeConcurrency: 0)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(maxImageCompletionsPerFrame: 0)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(maxQueuedRuntimeLoads: -1)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(maxQueuedDecodes: -1)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(decodedCacheMaximumSize: -1)),
      throwsRangeError,
    );
    expect(
      Pixa.configure(const PixaConfig(decodedCacheMaximumSizeBytes: -1)),
      throwsRangeError,
    );
  });

  test('PixaEvent carries timestamp and timeline duration', () {
    final PixaEvent event = PixaEvent(
      requestId: 42,
      stage: PixaStage.complete,
      name: 'request.complete',
      timestampMicros: 100,
      durationMicros: 25,
    );

    expect(event.timestampMicros, 100);
    expect(event.durationMicros, 25);
  });

  test('PixaEvent redacts sensitive request and attribute material', () {
    final PixaEvent event = PixaEvent(
      requestId: 7,
      stage: PixaStage.fetch,
      name: 'fetch.request',
      request: PixaRequest.network(
        'https://images.example.test/a.jpg?token=alpha&size=small',
        headers: const <String, String>{
          'Authorization': 'Bearer alpha',
          'Accept': 'image/webp',
        },
      ),
      attributes: const <String, Object?>{
        'message': 'Authorization=Bearer alpha token=alpha',
        'nested': <String, Object?>{
          'cookie': 'cookie=session-alpha',
          'safe': 'image/webp',
        },
      },
    );

    expect(event.request?.sourceLabel, isNot(contains('alpha')));
    expect(event.request?.headers['Authorization'], '<redacted>');
    expect(event.request?.headers['Accept'], 'image/webp');
    expect(event.attributes.toString(), isNot(contains('alpha')));
    expect(event.attributes.toString(), isNot(contains(r'$1')));
    expect(event.attributes.toString(), contains('image/webp'));
  });

  test('PixaObserverSamplingPolicy defaults to no sampling', () {
    const PixaObserverSamplingPolicy policy = PixaObserverSamplingPolicy.none;

    expect(policy.samplesProgress, isFalse);
    expect(policy.progressInterval, Duration.zero);
    expect(policy.progressSampleRate, 1);
  });

  test('PixaRedirectPolicy has value equality', () {
    const PixaRedirectPolicy defaultPolicy = PixaRedirectPolicy();
    const PixaRedirectPolicy strictPolicy = PixaRedirectPolicy(
      allowCrossHostRedirects: false,
    );

    expect(defaultPolicy, isNot(strictPolicy));
    expect(defaultPolicy.allowCrossHostRedirects, isTrue);
    expect(defaultPolicy.allowHttpsToHttp, isFalse);
  });

  test('PixaRequestLimits encodes runtime request as binary payload', () {
    final PixaRequest request = PixaRequest(
      source: PixaSource.bytes(Uint8List.fromList(<int>[0x47, 0x49, 0x46])),
      processors: const <String>['resize(width=64,height=64)'],
      limits: const PixaRequestLimits(
        maxAnimationFrames: 12,
        maxAnimationDuration: Duration(seconds: 3),
        maxProcessorOutputBytes: 4096,
      ),
    );

    final Uint8List payload = PixaRuntimeLoader.encodeRequest(request);

    expect(payload.take(4), <int>[0x50, 0x58, 0x52, 0x31]);
    expect(payload.first, isNot(0x7b));
    expect(payload.length, lessThan(256));
  });

  test(
    'PixaCacheKey computes primary and secondary hashes in runtime pair',
    () {
      final PixaCacheKey key = PixaCacheKey.fromParts(<Object?>['pixa']);

      expect(key.value, 'bef3f60dc4ff7eed');
      expect(key.materialHash, 0x668135a3077b3346);
    },
  );

  test(
    'sensitive request material partitions cache key without leaking labels',
    () {
      final PixaRequest first = PixaRequest.network(
        'https://images.example.test/avatar.jpg?token=alpha',
        headers: const <String, String>{'Authorization': 'Bearer alpha'},
      );
      final PixaRequest second = PixaRequest.network(
        'https://images.example.test/avatar.jpg?token=bravo',
        headers: const <String, String>{'Authorization': 'Bearer bravo'},
      );

      expect(first.cacheKey, isNot(second.cacheKey));
      expect(first.encodedCacheKey, isNot(second.encodedCacheKey));
      expect(first.cacheKey.debugLabel, isNot(contains('alpha')));
      expect(second.cacheKey.debugLabel, isNot(contains('bravo')));
    },
  );

  test('PixaRequest equality follows stable cache key material', () {
    final PixaRequest first = PixaRequest.network(
      'https://images.example.test/a.jpg',
      targetSize: const PixaTargetSize(width: 64, height: 64),
    );
    final PixaRequest sameIdentity = PixaRequest.network(
      'https://images.example.test/a.jpg',
      targetSize: const PixaTargetSize(width: 64, height: 64),
    );
    final PixaRequest metadataOnly = first.copyWith(
      metadata: const <String, Object?>{'traceId': 'local-only'},
    );
    final PixaRequest differentVariant = first.copyWith(
      targetSize: const PixaTargetSize(width: 128, height: 128),
    );

    expect(first, sameIdentity);
    expect(first, metadataOnly);
    expect(first, isNot(differentVariant));
  });

  test('PixaRequest.copyWith updates limits and processor descriptors', () {
    final PixaRequest original = PixaRequest(
      source: PixaSource.network(
        Uri.parse('https://images.example.test/a.jpg'),
      ),
    );

    final PixaRequest changed = original.copyWith(
      limits: const PixaRequestLimits(maxAnimationFrames: 24),
      processors: const <String>['resize(width=64,height=64)'],
    );

    expect(changed.limits.maxAnimationFrames, 24);
    expect(changed.processors, <String>['resize(width=64,height=64)']);
    expect(changed.cacheKey, isNot(original.cacheKey));
  });

  test('encoded cache key is shared across decode-size variants', () {
    final PixaRequest small = PixaRequest.network(
      'https://images.example.test/a.jpg',
      targetSize: const PixaTargetSize(width: 100, height: 100),
    );
    final PixaRequest large = PixaRequest.network(
      'https://images.example.test/a.jpg',
      targetSize: const PixaTargetSize(width: 500, height: 500),
    );

    expect(small.cacheKey, isNot(large.cacheKey));
    expect(small.encodedCacheKey, large.encodedCacheKey);
  });

  test('raw bytes source key uses full runtime content fingerprint', () {
    final Uint8List first = Uint8List.fromList(<int>[
      ...List<int>.filled(16, 7),
      1,
    ]);
    final Uint8List second = Uint8List.fromList(<int>[
      ...List<int>.filled(16, 7),
      2,
    ]);
    final PixaRequest firstRequest = PixaRequest(
      source: PixaSource.bytes(first),
    );
    final PixaRequest secondRequest = PixaRequest(
      source: PixaSource.bytes(second),
    );

    expect(firstRequest.encodedCacheKey, isNot(secondRequest.encodedCacheKey));
  });

  test('EXIF thumbnail source is keyed separately from full file source', () {
    final PixaRequest full = PixaRequest(
      source: PixaSource.file('/photos/private/full.jpg'),
    );
    final PixaRequest thumbnail = PixaRequest.exifThumbnail(
      '/photos/private/full.jpg',
    );

    expect(thumbnail.source.safeLabel, 'exif-thumbnail:full.jpg');
    expect(thumbnail.encodedCacheKey, isNot(full.encodedCacheKey));
    expect(thumbnail.cacheKey.debugLabel, contains('exif-thumbnail:full.jpg'));
  });

  test('decoder options separate final key while sharing encoded key', () {
    final PixaRequest first = PixaRequest.network(
      'https://images.example.test/a.jpg',
      decoderOptions: const <String, Object?>{
        'colorSpace': 'srgb',
        'allowHardware': true,
      },
    );
    final PixaRequest sameMaterialDifferentOrder = PixaRequest.network(
      'https://images.example.test/a.jpg',
      decoderOptions: const <String, Object?>{
        'allowHardware': true,
        'colorSpace': 'srgb',
      },
    );
    final PixaRequest different = first.copyWith(
      decoderOptions: const <String, Object?>{
        'colorSpace': 'display-p3',
        'allowHardware': true,
      },
    );

    expect(first.cacheKey, sameMaterialDifferentOrder.cacheKey);
    expect(first.cacheKey, isNot(different.cacheKey));
    expect(first.encodedCacheKey, different.encodedCacheKey);
  });

  test('runtime progress drain decodes binary payload', () {
    final Uint8List payload = _binaryProgressPayload();

    final PixaRuntimeProgressDrain drain = decodeRuntimeProgressDrainForTest(
      payload,
    );

    expect(drain.droppedEvents, 2);
    expect(drain.events, hasLength(1));
    expect(drain.events.single.stage, 'fetch');
    expect(drain.events.single.name, 'fetch.progress');
    expect(drain.events.single.receivedBytes, 10);
    expect(drain.events.single.expectedBytes, 20);
    expect(drain.events.single.message, 'chunk');
    expect(drain.events.single.timestampMs, 1234);
  });

  test('runtime progress drain rejects unknown binary fields', () {
    final PixaRuntimeProgressDrain badStage = decodeRuntimeProgressDrainForTest(
      _binaryProgressPayload(stageCode: 99),
    );
    final PixaRuntimeProgressDrain badFlags = decodeRuntimeProgressDrainForTest(
      _binaryProgressPayload(flags: 0x10),
    );

    expect(badStage.events, isEmpty);
    expect(badFlags.events, isEmpty);
  });

  test('runtime cache stats decode binary payload', () {
    final Uint8List payload = _binaryCacheStatsPayload();

    final PixaCacheStats stats = decodeRuntimeCacheStatsForTest(payload);

    expect(stats.memoryEntries, 1);
    expect(stats.memoryBytes, 2);
    expect(stats.memoryHits, 3);
    expect(stats.diskWrites, 7);
    expect(stats.diskCorruptionRecoveries, 8);
    expect(stats.staleRevalidatesInFlight, 14);
    expect(stats.processedMemoryHits, 15);
    expect(stats.processedMemoryMisses, 16);
    expect(stats.processedMemoryEvictions, 17);
    expect(stats.processedDiskHits, 18);
    expect(stats.processedDiskMisses, 19);
    expect(stats.processedDiskStaleHits, 20);
    expect(stats.processedDiskWrites, 21);
    expect(stats.processedDiskCorruptionRecoveries, 22);
    expect(stats.ownedBufferHandlesCreated, 23);
    expect(stats.progressEventsDrained, 30);
  });

  test('runtime plugin registry stats decode binary payload', () {
    final PixaRuntimePluginRegistryStats stats =
        PixaRuntimePluginRegistryStats.decode(_binaryPluginStatsPayload());

    expect(stats.modules, 1);
    expect(stats.builtInModules, 2);
    expect(stats.hostLinkedModules, 3);
    expect(stats.assetModules, 4);
    expect(stats.linkableModules, 5);
    expect(stats.fetchers, 6);
    expect(stats.decoders, 7);
    expect(stats.processors, 8);
    expect(stats.cacheStores, 9);
    expect(stats.canUseSingleHostBinary, isFalse);
  });

  test('runtime failure decodes binary payload', () {
    final Uint8List payload = _binaryFailurePayload();

    final PixaFailure failure = decodeRuntimeFailureForTest(payload);

    expect(failure.stage, PixaStage.fetch);
    expect(failure.retryability, PixaRetryability.retryable);
    expect(failure.safeMessage, 'network timeout');
  });

  test('runtime failure rejects unknown binary fields', () {
    final PixaFailure badStage = decodeRuntimeFailureForTest(
      _binaryFailurePayload(stageCode: 99),
    );
    final PixaFailure badRetry = decodeRuntimeFailureForTest(
      _binaryFailurePayload(retryableCode: 2),
    );

    expect(badStage.retryability, PixaRetryability.unknown);
    expect(badStage.safeMessage, contains('invalid error payload'));
    expect(badRetry.retryability, PixaRetryability.unknown);
    expect(badRetry.safeMessage, contains('invalid error payload'));
  });
}

Uint8List _binaryProgressPayload({int stageCode = 2, int flags = 0x07}) {
  final BytesBuilder builder = BytesBuilder(copy: false);
  builder.add(<int>[0x50, 0x58, 0x50, 0x31]);
  _addUint64(builder, 2);
  _addUint32(builder, 1);
  builder.add(<int>[stageCode]);
  _addString(builder, 'fetch.progress');
  builder.add(<int>[flags]);
  _addUint64(builder, 10);
  _addUint64(builder, 20);
  _addInt64(builder, 1234);
  _addString(builder, 'chunk');
  return builder.takeBytes();
}

Uint8List _binaryCacheStatsPayload() {
  final BytesBuilder builder = BytesBuilder(copy: false);
  builder.add(<int>[0x50, 0x58, 0x53, 0x31]);
  for (int value = 1; value <= 30; value++) {
    _addUint64(builder, value);
  }
  return builder.takeBytes();
}

Uint8List _binaryPluginStatsPayload() {
  final BytesBuilder builder = BytesBuilder(copy: false);
  builder.add(<int>[0x50, 0x58, 0x4d, 0x31]);
  for (int value = 1; value <= 9; value++) {
    _addUint64(builder, value);
  }
  return builder.takeBytes();
}

Uint8List _binaryFailurePayload({int stageCode = 2, int retryableCode = 1}) {
  final BytesBuilder builder = BytesBuilder(copy: false);
  builder.add(<int>[0x50, 0x58, 0x45, 0x31]);
  builder.add(<int>[stageCode, retryableCode]);
  _addString(builder, 'network timeout');
  return builder.takeBytes();
}

void _addUint32(BytesBuilder builder, int value) {
  final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _addUint64(BytesBuilder builder, int value) {
  final ByteData data = ByteData(8)..setUint64(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _addInt64(BytesBuilder builder, int value) {
  final ByteData data = ByteData(8)..setInt64(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _addString(BytesBuilder builder, String value) {
  final Uint8List bytes = Uint8List.fromList(value.codeUnits);
  _addUint32(builder, bytes.length);
  builder.add(bytes);
}
