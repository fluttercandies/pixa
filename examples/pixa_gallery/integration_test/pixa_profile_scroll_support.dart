part of 'pixa_profile_scroll_test.dart';

PixaRequest _liveNetworkRequest(
  ProfileLiveNetworkRecorder recorder,
  ProfileLiveNetworkSample sample,
) {
  final PixaRequest request = PixaRequest(
    source: PixaSource.network(sample.uri),
    cacheNamespace: profileLiveNetworkCacheNamespace,
    targetSize: const PixaTargetSize(
      width: profileTilePixels,
      height: profileTilePixels,
    ),
    fit: BoxFit.cover,
    cachePolicy: const PixaCachePolicy.noStore(),
    priority: PixaPriority.normal,
  );
  recorder.register(request: request, sample: sample);
  return request;
}

Future<void> _probeCompletedLiveSamples(
  ProfileLiveNetworkRecorder recorder,
  ProfileLiveNetworkCorpus corpus,
) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);
  try {
    final List<int> completed = recorder.completedSampleIndices
        .take(8)
        .toList();
    for (final int index in completed) {
      final ProfileLiveNetworkSample sample = corpus.sampleAt(index);
      recorder.recordProbe(await _probeLiveSample(client, sample));
    }
  } finally {
    client.close(force: true);
  }
}

Future<ProfileLiveNetworkProbe> _probeLiveSample(
  HttpClient client,
  ProfileLiveNetworkSample sample,
) async {
  var pixaBytes = 0;
  var pixaLatencyMicros = 0;
  var pixaMimeType = 'unknown';
  var pixaSha256 = '';
  String? pixaSafeError;
  final Stopwatch pixaStopwatch = Stopwatch()..start();
  try {
    final PixaPipelineLoad load = await Pixa.pipeline.load(
      PixaRequest(
        source: PixaSource.network(sample.uri),
        cacheNamespace: 'pixa-profile-live-identity-probe',
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    try {
      pixaBytes = load.bytes.length;
      pixaMimeType = load.mimeType ?? 'unknown';
      pixaSha256 = sha256.convert(load.bytes).toString();
    } finally {
      load.dispose();
    }
  } on Object catch (error) {
    pixaSafeError = error.runtimeType.toString();
  } finally {
    pixaStopwatch.stop();
    pixaLatencyMicros = pixaStopwatch.elapsedMicroseconds;
  }

  var httpStatusCode = 0;
  var httpRedirectCount = 0;
  var httpBytes = 0;
  var httpLatencyMicros = 0;
  var httpMimeType = 'unknown';
  var httpSha256 = '';
  String? httpSafeError;
  final Stopwatch httpStopwatch = Stopwatch()..start();
  try {
    final HttpClientRequest request = await client.getUrl(sample.uri);
    final HttpClientResponse response = await request.close();
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      body.add(chunk);
    }
    final Uint8List bytes = body.takeBytes();
    httpStatusCode = response.statusCode;
    httpRedirectCount = response.redirects.length;
    httpBytes = bytes.length;
    httpMimeType = response.headers.contentType?.mimeType ?? 'unknown';
    httpSha256 = sha256.convert(bytes).toString();
  } on Object catch (error) {
    httpSafeError = error.runtimeType.toString();
  } finally {
    httpStopwatch.stop();
    httpLatencyMicros = httpStopwatch.elapsedMicroseconds;
  }
  return ProfileLiveNetworkProbe(
    sampleIndex: sample.index,
    pixaBytes: pixaBytes,
    pixaLatencyMicros: pixaLatencyMicros,
    pixaMimeType: pixaMimeType,
    pixaSha256: pixaSha256,
    httpStatusCode: httpStatusCode,
    httpRedirectCount: httpRedirectCount,
    httpBytes: httpBytes,
    httpLatencyMicros: httpLatencyMicros,
    httpMimeType: httpMimeType,
    httpSha256: httpSha256,
    pixaSafeError: pixaSafeError,
    httpSafeError: httpSafeError,
  );
}

Future<ProfileScrollHarnessState> _waitForHarnessState(
  WidgetTester tester,
  GlobalKey<ProfileScrollHarnessState> key,
) async {
  final Stopwatch timeout = Stopwatch()..start();
  while (key.currentState == null) {
    if (timeout.elapsed > const Duration(seconds: 10)) {
      throw StateError('Profile scroll harness did not mount in time.');
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  return key.currentState!;
}

Future<void> _seedDiskCache(ProfileScrollHarnessState harness) async {
  const int batchSize = 24;
  for (var start = 0; start < profileItemCount; start += batchSize) {
    final int end = (start + batchSize).clamp(0, profileItemCount);
    await Future.wait<void>(<Future<void>>[
      for (var index = start; index < end; index += 1)
        Pixa.prefetch(
          harness.requestFor(index),
          target: PixaPrefetchTarget.diskOnly,
        ),
    ]);
  }
}

Future<void> _seedEncodedMemoryCache(
  ProfileScrollHarnessState harness, {
  required int start,
  required int end,
}) async {
  const int batchSize = 24;
  for (var batchStart = start; batchStart < end; batchStart += batchSize) {
    final int batchEnd = (batchStart + batchSize).clamp(start, end);
    await Future.wait<void>(<Future<void>>[
      for (var index = batchStart; index < batchEnd; index += 1)
        Pixa.prefetch(
          harness.requestFor(index),
          target: PixaPrefetchTarget.encodedMemory,
        ),
    ]);
  }
}

Future<int> _countDecodedHits(
  ProfileScrollHarnessState harness, {
  required int start,
  required int end,
}) async {
  var hits = 0;
  for (var index = start; index < end; index += 1) {
    final ImageCacheStatus? status = await PixaProvider(
      request: harness.requestFor(index),
    ).obtainCacheStatus(configuration: ImageConfiguration.empty);
    if (status?.tracked ?? false) {
      hits += 1;
    }
  }
  return hits;
}

Future<void> _exerciseCacheBurst(ProfileScrollHarnessState harness) async {
  for (var repeat = 0; repeat < 4; repeat += 1) {
    await harness.scrollToFraction(0.9, const Duration(milliseconds: 600));
    await harness.scrollToEnd(const Duration(milliseconds: 600));
  }
}

Future<Map<String, Object?>> _captureScenario(
  IntegrationTestWidgetsFlutterBinding binding, {
  required String name,
  required ProfileScrollHarnessState harness,
  required int requestsBefore,
  required int Function() requestCount,
  required Future<void> Function() action,
  int decodedHits = 0,
}) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  final PixaCacheStats cacheBefore = Pixa.cacheStats();
  final PixaDecodedCacheStats decodedBefore = Pixa.decodedCacheStats();
  final PixaSchedulerStats schedulerBefore = Pixa.pipeline.schedulerStats();
  final PixaPredictivePrefetcherSnapshot prefetchBefore =
      harness.prefetchSnapshot;
  final List<FrameTiming> timings = <FrameTiming>[];
  var maxCompletionQueueDepth = 0;
  var maxCompletionsReleasedPerFrame = 0;
  void callback(List<FrameTiming> values) {
    timings.addAll(values);
    final PixaDisplayDecoderSnapshot decoder =
        PixaDebugInspector.displayDecoderSnapshot();
    maxCompletionQueueDepth = math.max(
      maxCompletionQueueDepth,
      decoder.completionQueueDepth,
    );
    maxCompletionsReleasedPerFrame = math.max(
      maxCompletionsReleasedPerFrame,
      decoder.completionsReleasedThisFrame,
    );
  }

  binding.addTimingsCallback(callback);
  try {
    await action();
    await _waitForDrain(harness);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  } finally {
    binding.removeTimingsCallback(callback);
  }
  if (timings.isEmpty) {
    throw StateError('$name did not produce FrameTiming samples.');
  }
  final PixaCacheStats cacheAfter = Pixa.cacheStats();
  final PixaDecodedCacheStats decodedAfter = Pixa.decodedCacheStats();
  final PixaSchedulerStats schedulerAfter = Pixa.pipeline.schedulerStats();
  final PixaPredictivePrefetcherSnapshot prefetchAfter =
      harness.prefetchSnapshot;
  final PixaDisplayDecoderSnapshot finalDecoder =
      PixaDebugInspector.displayDecoderSnapshot();
  final List<int> build =
      timings
          .map((FrameTiming timing) => timing.buildDuration.inMicroseconds)
          .toList()
        ..sort();
  final List<int> raster =
      timings
          .map((FrameTiming timing) => timing.rasterDuration.inMicroseconds)
          .toList()
        ..sort();
  final int overBudget = timings.where((FrameTiming timing) {
    return timing.buildDuration.inMicroseconds > _frameBudgetMicros ||
        timing.rasterDuration.inMicroseconds > _frameBudgetMicros;
  }).length;
  return <String, Object?>{
    'name': name,
    'frameCount': timings.length,
    'build': _timingSummary(build),
    'raster': _timingSummary(raster),
    'overBudgetFrames': overBudget,
    'loopbackRequests': requestCount() - requestsBefore,
    'decodedHits': decodedHits,
    'cacheDelta': <String, Object?>{
      'memoryHits': cacheAfter.memoryHits - cacheBefore.memoryHits,
      'diskHits': cacheAfter.diskHits - cacheBefore.diskHits,
      'memoryMisses': cacheAfter.memoryMisses - cacheBefore.memoryMisses,
      'diskMisses': cacheAfter.diskMisses - cacheBefore.diskMisses,
      'diskWrites': cacheAfter.diskWrites - cacheBefore.diskWrites,
      'processedMemoryHits':
          cacheAfter.processedMemoryHits - cacheBefore.processedMemoryHits,
      'processedDiskHits':
          cacheAfter.processedDiskHits - cacheBefore.processedDiskHits,
    },
    'cacheBefore': <String, Object?>{
      'memoryBytes': cacheBefore.memoryBytes,
      'decodedEntries': decodedBefore.currentSize,
      'decodedBytes': decodedBefore.currentSizeBytes,
    },
    'decodedCache': <String, Object?>{
      'entriesBefore': decodedBefore.currentSize,
      'entriesAfter': decodedAfter.currentSize,
      'bytesBefore': decodedBefore.currentSizeBytes,
      'bytesAfter': decodedAfter.currentSizeBytes,
      'liveAfter': decodedAfter.liveImageCount,
    },
    'schedulerDelta': <String, Object?>{
      'started': schedulerAfter.totalStarted - schedulerBefore.totalStarted,
      'completed':
          schedulerAfter.totalCompleted - schedulerBefore.totalCompleted,
      'cancelled':
          schedulerAfter.totalCancelled - schedulerBefore.totalCancelled,
      'backpressureDropped':
          schedulerAfter.totalBackpressureDropped -
          schedulerBefore.totalBackpressureDropped,
    },
    'prefetchDelta': <String, Object?>{
      'skippedPending':
          prefetchAfter.skippedPending - prefetchBefore.skippedPending,
    },
    'completionPacing': <String, Object?>{
      'configuredMaxPerFrame': 3,
      'maxReleasedPerFrame': maxCompletionsReleasedPerFrame,
      'maxQueueDepth': maxCompletionQueueDepth,
      'finalQueueDepth': finalDecoder.completionQueueDepth,
    },
  };
}

Map<String, int> _timingSummary(List<int> sortedMicros) {
  return <String, int>{
    'p90Micros': _percentile(sortedMicros, 0.90),
    'p99Micros': _percentile(sortedMicros, 0.99),
    'worstMicros': sortedMicros.last,
  };
}

int _percentile(List<int> sortedValues, double percentile) {
  final int index = ((sortedValues.length - 1) * percentile).ceil();
  return sortedValues[index];
}

Map<String, Object?> _memorySample(
  int cycle,
  ProfileScrollHarnessState harness,
) {
  final PixaCacheStats cache = Pixa.cacheStats();
  final PixaDecodedCacheStats decoded = Pixa.decodedCacheStats();
  final PixaSchedulerStats scheduler = Pixa.pipeline.schedulerStats();
  final PixaPredictivePrefetcherSnapshot prefetch = harness.prefetchSnapshot;
  final PixaDebugSnapshot debug = PixaDebugInspector.snapshot();
  return <String, Object?>{
    'cycle': cycle,
    'rssBytes': ProcessInfo.currentRss,
    'runtimeMemoryBytes': cache.memoryBytes,
    'runtimeMemoryEntries': cache.memoryEntries,
    'encodedMemoryBytes': cache.encodedMemoryBytes,
    'encodedMemoryEntries': cache.encodedMemoryEntries,
    'processedMemoryBytes': cache.processedMemoryBytes,
    'processedMemoryEntries': cache.processedMemoryEntries,
    'processedMemoryHits': cache.processedMemoryHits,
    'processedDiskHits': cache.processedDiskHits,
    'decodedCacheBytes': decoded.currentSizeBytes,
    'decodedCacheEntries': decoded.currentSize,
    'decodedLiveEntries': decoded.liveImageCount,
    'decodedRegistryEntries': debug.decodedRegistryEntries,
    'queueDepth': scheduler.queueDepth,
    'inflightRequests': scheduler.inflightRequests,
    'prefetchPending': prefetch.pending,
    'prefetchActive': prefetch.active,
    'liveOwnedBufferHandles': cache.liveOwnedBufferHandles,
    'liveProgressSessions': cache.liveProgressSessions,
    'completionQueueDepth': debug.displayDecoder.completionQueueDepth,
  };
}

Future<void> _waitForDrain(ProfileScrollHarnessState harness) async {
  final Stopwatch timeout = Stopwatch()..start();
  var consecutiveDrainedProbes = 0;
  while (true) {
    final PixaSchedulerStats scheduler = Pixa.pipeline.schedulerStats();
    final PixaPredictivePrefetcherSnapshot prefetch = harness.prefetchSnapshot;
    final PixaDisplayDecoderSnapshot decoder =
        PixaDebugInspector.displayDecoderSnapshot();
    final bool drained =
        scheduler.queueDepth == 0 &&
        scheduler.inflightRequests == 0 &&
        prefetch.pending == 0 &&
        prefetch.active == 0 &&
        prefetch.inFlight == 0 &&
        decoder.completionQueueDepth == 0 &&
        !decoder.completionFrameScheduled;
    if (drained) {
      consecutiveDrainedProbes += 1;
      if (consecutiveDrainedProbes >= 3) {
        return;
      }
    } else {
      consecutiveDrainedProbes = 0;
    }
    if (!drained && timeout.elapsed > const Duration(seconds: 20)) {
      throw StateError(
        'Profile scheduler and prefetch work did not remain drained.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

final class _LoopbackImageServer {
  _LoopbackImageServer._(this._server, this._corpus) {
    _subscription = _server.listen((HttpRequest request) {
      unawaited(_serve(request));
    });
  }

  final HttpServer _server;
  final List<ProfileLoopbackImage> _corpus;
  late final StreamSubscription<HttpRequest> _subscription;
  final List<String> errors = <String>[];
  int requestCount = 0;
  int clientDisconnects = 0;
  Duration responseDelay = const Duration(milliseconds: 3);

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_LoopbackImageServer> start(
    List<ProfileLoopbackImage> corpus,
  ) async {
    if (corpus.isEmpty) {
      throw ArgumentError.value(corpus, 'corpus', 'must not be empty');
    }
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _LoopbackImageServer._(
      server,
      List<ProfileLoopbackImage>.unmodifiable(corpus),
    );
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      requestCount += 1;
      final List<String> segments = request.uri.pathSegments;
      final int? imageIndex = segments.length == 2 && segments.first == 'image'
          ? int.tryParse(segments.last)
          : null;
      if (imageIndex == null || imageIndex < 0) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ProfileLoopbackImage image = _corpus[imageIndex % _corpus.length];
      final List<String> mimeParts = image.mimeType.split('/');
      await Future<void>.delayed(responseDelay);
      final HttpResponse response = request.response
        ..statusCode = HttpStatus.ok
        ..bufferOutput = false
        ..contentLength = image.bytes.length
        ..headers.contentType = ContentType(mimeParts.first, mimeParts.last)
        ..headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=43200')
        ..headers.set(HttpHeaders.etagHeader, '"pixa-profile-${image.id}-v1"');
      final int midpoint = image.bytes.length ~/ 2;
      response.add(image.bytes.sublist(0, midpoint));
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      response.add(image.bytes.sublist(midpoint));
      await response.close();
    } on HttpException {
      clientDisconnects += 1;
      await _closeResponseAfterDisconnect(request.response);
    } on SocketException {
      clientDisconnects += 1;
      await _closeResponseAfterDisconnect(request.response);
    } on Object catch (error, stackTrace) {
      errors.add('$error\n$stackTrace');
      await _closeResponseAfterDisconnect(request.response);
    }
  }

  Future<void> _closeResponseAfterDisconnect(HttpResponse response) async {
    try {
      await response.close();
    } on Object {
      // The peer has already closed the loopback connection.
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
