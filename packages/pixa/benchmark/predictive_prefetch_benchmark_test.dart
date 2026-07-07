import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';
import 'package:pixa/src/image_format_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('predictive scroll prefetch planning benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_PREFETCH_ITERS', 160);
    final int visibleCount = _envInt('PIXA_BENCH_PREFETCH_VISIBLE', 1000);
    final int itemCount = _envInt('PIXA_BENCH_PREFETCH_ITEMS', 20_000);
    var scheduled = 0;
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: (int index) => PixaRequest.network(
        'https://images.example.test/gallery/$index.jpg',
        targetSize: const PixaTargetSize(width: 160, height: 160),
      ),
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 256,
      backwardItemCount: 64,
      maxConcurrent: 16,
      recentCapacity: 4096,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        scheduled += 1;
        return Future<void>.value();
      },
    );

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final int firstVisible = iteration * 37;
      final int lastVisible = firstVisible + visibleCount - 1;
      await prefetcher.prefetchAround(
        firstVisibleIndex: firstVisible,
        lastVisibleIndex: lastVisible,
        itemCount: itemCount,
      );
    }
    stopwatch.stop();

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / iterations;
    // CSV row, aligned with Rust benchmark output shape.
    // ignore: avoid_print
    print(
      'scroll_prefetch_planning,$iterations,$totalMicros,'
      '${avgMicros.toStringAsFixed(1)},$scheduled',
    );
    expect(scheduled, greaterThan(0));
  });

  test('predictive scroll rapid-overlap planning benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_PREFETCH_RAPID_ITERS', 240);
    final int visibleCount = _envInt('PIXA_BENCH_PREFETCH_VISIBLE', 1000);
    final int itemCount = _envInt('PIXA_BENCH_PREFETCH_ITEMS', 50_000);
    final int maxAvgMicros = _envInt(
      'PIXA_BENCH_PREFETCH_RAPID_MAX_AVG_MICROS',
      8000,
    );
    final Completer<void> firstCompletion = Completer<void>();
    final List<Future<void>> batches = <Future<void>>[];
    var scheduled = 0;
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: (int index) => PixaRequest.network(
        'https://images.example.test/gallery/$index.jpg',
        targetSize: const PixaTargetSize(width: 160, height: 160),
      ),
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 256,
      backwardItemCount: 64,
      maxConcurrent: 1,
      recentCapacity: 4096,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        scheduled += 1;
        if (scheduled == 1) {
          return firstCompletion.future;
        }
        return Future<void>.value();
      },
    );

    batches.add(
      prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: visibleCount - 1,
        itemCount: itemCount,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 1; iteration <= iterations; iteration++) {
      final int firstVisible = iteration * 37;
      final int lastVisible = firstVisible + visibleCount - 1;
      batches.add(
        prefetcher.prefetchAround(
          firstVisibleIndex: firstVisible,
          lastVisibleIndex: lastVisible,
          itemCount: itemCount,
        ),
      );
    }
    stopwatch.stop();

    final PixaPredictivePrefetcherSnapshot snapshot = prefetcher.snapshot();
    firstCompletion.complete();
    await Future.wait(batches);

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / iterations;
    // ignore: avoid_print
    print(
      'scroll_prefetch_rapid_overlap,$iterations,$totalMicros,'
      '${avgMicros.toStringAsFixed(1)},$scheduled,'
      '${snapshot.skippedPending},${snapshot.currentPending}',
    );
    expect(snapshot.skippedPending, greaterThan(0));
    expect(snapshot.stalePending, 0);
    expect(avgMicros, lessThan(maxAvgMicros));
  });

  test('predictive prefetch recent eviction benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_RECENT_EVICT_ITERS', 12000);
    final int recentCapacity = _envInt(
      'PIXA_BENCH_RECENT_EVICT_CAPACITY',
      4096,
    );
    final int maxAvgMicros = _envInt(
      'PIXA_BENCH_RECENT_EVICT_MAX_AVG_MICROS',
      70,
    );
    var scheduled = 0;
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: (int index) => PixaRequest.network(
        'https://images.example.test/recent/$index.jpg',
        targetSize: const PixaTargetSize(width: 96, height: 96),
      ),
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 1,
      backwardItemCount: 0,
      maxConcurrent: 1,
      recentCapacity: recentCapacity,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        scheduled += 1;
        return Future<void>.value();
      },
    );

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      await prefetcher.prefetchAround(
        firstVisibleIndex: iteration,
        lastVisibleIndex: iteration,
        itemCount: iterations + 2,
      );
    }
    stopwatch.stop();

    final PixaPredictivePrefetcherSnapshot snapshot = prefetcher.snapshot();
    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / iterations;
    // ignore: avoid_print
    print(
      'scroll_prefetch_recent_eviction,$iterations,$totalMicros,'
      '${avgMicros.toStringAsFixed(1)},$scheduled,'
      '${snapshot.recent}',
    );
    expect(scheduled, iterations);
    expect(snapshot.recent, recentCapacity);
    expect(avgMicros, lessThan(maxAvgMicros));
  });

  test('request cache key memoized hot path benchmark', () {
    final int iterations = _envInt('PIXA_BENCH_REQUEST_KEY_ITERS', 200000);
    final int maxAvgNs = _envInt('PIXA_BENCH_REQUEST_KEY_MAX_AVG_NS', 350);
    final PixaRequest request =
        PixaRequest.network(
          'https://images.example.test/gallery/full.jpg?token=secret&sig=hidden',
          headers: const <String, String>{
            'Authorization': 'Bearer private-token',
            'Accept': 'image/webp,image/*,*/*',
          },
          targetSize: const PixaTargetSize(width: 480, height: 320),
          cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
          retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 3),
          decoderOptions: const <String, Object?>{
            'displayBackend': 'engine',
            'formatId': 'jpeg',
          },
        ).copyWith(
          processors: <String>[
            PixaProcessors.resize(
              width: 480,
              height: 320,
              mode: PixaResizeMode.exact,
            ),
            PixaProcessors.fastBlur(0.8),
          ],
        );

    final Object cacheKey = request.cacheKey;
    final Object encodedCacheKey = request.encodedCacheKey;
    var checksum = 0;
    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final Object current = request.cacheKey;
      final Object encoded = request.encodedCacheKey;
      checksum = (checksum + current.hashCode + encoded.hashCode) & 0x7fffffff;
      if (!identical(current, cacheKey) ||
          !identical(encoded, encodedCacheKey)) {
        fail('PixaRequest cache keys must remain memoized per request object.');
      }
    }
    stopwatch.stop();

    final int reads = iterations * 2;
    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgNs = totalMicros * 1000 / reads;
    // ignore: avoid_print
    print(
      'request_cache_key_memoized_hot_path,$reads,$totalMicros,'
      '${avgNs.toStringAsFixed(1)},$checksum',
    );
    expect(avgNs, lessThan(maxAvgNs));
  });

  test('format route capability lookup hot path benchmark', () {
    final int iterations = _envInt('PIXA_BENCH_FORMAT_ROUTE_ITERS', 60000);
    final int maxAvgNs = _envInt('PIXA_BENCH_FORMAT_ROUTE_MAX_AVG_NS', 900);
    const PixaImageFormatCatalog catalog = PixaImageFormatCatalog();
    var runtimeDefaults = 0;

    expect(
      catalog.routeForMimeType('image/x-icon')?.defaultRuntimeDisplay,
      isTrue,
    );
    expect(
      catalog.routeForMimeType('image/png')?.defaultRuntimeDisplay,
      isFalse,
    );

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final PixaImageFormatRoute? route = catalog.routeForMimeType(
        iteration.isEven ? 'image/x-icon' : 'image/png',
      );
      if (route == null) {
        fail('built-in image MIME should resolve to a route');
      }
      if (route.defaultRuntimeDisplay) {
        runtimeDefaults += 1;
      }
    }
    stopwatch.stop();

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgNs = totalMicros * 1000 / iterations;
    // ignore: avoid_print
    print(
      'format_route_capability_lookup,$iterations,$totalMicros,'
      '${avgNs.toStringAsFixed(1)},$runtimeDefaults',
    );
    expect(runtimeDefaults, iterations ~/ 2);
    expect(avgNs, lessThan(maxAvgNs));
  });

  test('image completion frame gate burst benchmark', () async {
    final int imageCount = _envInt('PIXA_BENCH_COMPLETION_BURST_IMAGES', 12);
    final int frameBudget = _envInt('PIXA_BENCH_COMPLETION_FRAME_BUDGET', 3);
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-bench-completion-burst-',
    );
    addTearDown(() => cacheRoot.delete(recursive: true));
    await Pixa.configure(
      PixaConfig(
        cacheRootPath: cacheRoot.path,
        decodeConcurrency: imageCount,
        maxImageCompletionsPerFrame: frameBudget,
      ),
    );
    await _waitForCompletionGateIdle();

    final Uint8List bytes = _minimalGif();
    final List<Completer<void>> decodeReturned = List<Completer<void>>.generate(
      imageCount,
      (_) => Completer<void>(),
    );
    final List<Completer<ImageInfo>> delivered =
        List<Completer<ImageInfo>>.generate(
          imageCount,
          (_) => Completer<ImageInfo>(),
        );
    final List<ImageInfo> retainedImages = <ImageInfo>[];
    addTearDown(() {
      for (final ImageInfo image in retainedImages) {
        image.dispose();
      }
    });

    Future<ui.Codec> decodeAt(
      int index,
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      decodeReturned[index].complete();
      return codec;
    }

    final List<PixaProvider> providers = List<PixaProvider>.generate(
      imageCount,
      (int index) => PixaProvider(
        request: PixaRequest(
          source: PixaSource.custom(
            'completion-burst-bench-$index',
            () async => bytes,
          ),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      ),
    );
    final List<ImageStreamCompleter> completers =
        List<ImageStreamCompleter>.generate(
          imageCount,
          (int index) => providers[index].loadImage(
            providers[index],
            (
              ui.ImmutableBuffer buffer, {
              ui.TargetImageSizeCallback? getTargetSize,
            }) => decodeAt(index, buffer, getTargetSize: getTargetSize),
          ),
        );
    final List<ImageStreamListener> listeners =
        List<ImageStreamListener>.generate(imageCount, (int index) {
          return ImageStreamListener((ImageInfo image, bool synchronousCall) {
            if (!delivered[index].isCompleted) {
              retainedImages.add(image);
              delivered[index].complete(image);
            } else {
              image.dispose();
            }
          });
        });
    addTearDown(() {
      for (var index = 0; index < imageCount; index += 1) {
        completers[index].removeListener(listeners[index]);
      }
    });

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var index = 0; index < imageCount; index += 1) {
      completers[index].addListener(listeners[index]);
    }
    await Future.wait<void>(
      decodeReturned.map((Completer<void> completer) => completer.future),
    ).timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);

    final Map<String, Object?> firstSnapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> firstDisplayDecoder =
        firstSnapshot['displayDecoder']! as Map<String, Object?>;
    final int firstQueueDepth =
        firstDisplayDecoder['completionQueueDepth']! as int;
    final int firstReleasedThisFrame =
        firstDisplayDecoder['completionsReleasedThisFrame']! as int;
    final int firstDelivered = delivered
        .where((Completer<ImageInfo> completer) => completer.isCompleted)
        .length;

    expect(firstQueueDepth, greaterThan(0));
    expect(firstReleasedThisFrame, lessThanOrEqualTo(frameBudget));
    expect(firstDisplayDecoder['completionFrameScheduled'], isTrue);
    expect(firstDelivered, lessThan(imageCount));

    for (var attempt = 0; attempt < imageCount + 4; attempt += 1) {
      if (delivered.every(
        (Completer<ImageInfo> completer) => completer.isCompleted,
      )) {
        break;
      }
      _pumpFlutterFrame();
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait<ImageInfo>(
      delivered.map((Completer<ImageInfo> completer) => completer.future),
    ).timeout(const Duration(seconds: 5));
    stopwatch.stop();

    final Map<String, Object?> drainedSnapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> drainedDisplayDecoder =
        drainedSnapshot['displayDecoder']! as Map<String, Object?>;
    expect(drainedDisplayDecoder['completionQueueDepth'], 0);

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / imageCount;
    // ignore: avoid_print
    print(
      'image_completion_frame_gate_burst,$imageCount,$totalMicros,'
      '${avgMicros.toStringAsFixed(1)},$firstQueueDepth,'
      '$firstReleasedThisFrame,$firstDelivered,$frameBudget',
    );
  });

  test('flutter engine decode benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_DECODE_ITERS', 500);
    final Uint8List bytes = _minimalGif();
    var decodedPixels = 0;

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      final ui.Codec codec = await PaintingBinding.instance
          .instantiateImageCodecWithSize(buffer);
      final ui.FrameInfo frame = await codec.getNextFrame();
      decodedPixels += frame.image.width * frame.image.height;
      frame.image.dispose();
      codec.dispose();
    }
    stopwatch.stop();

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / iterations;
    // ignore: avoid_print
    print(
      'flutter_decode_min_gif,$iterations,$totalMicros,'
      '${avgMicros.toStringAsFixed(1)},$decodedPixels',
    );
    expect(decodedPixels, iterations);
  });

  test('flutter animated GIF frame benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_ANIMATED_ITERS', 200);
    final Uint8List bytes = _animatedGif();
    var decodedFrames = 0;

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      for (var frame = 0; frame < codec.frameCount; frame++) {
        final ui.FrameInfo frameInfo = await codec.getNextFrame();
        decodedFrames += 1;
        frameInfo.image.dispose();
      }
      codec.dispose();
    }
    stopwatch.stop();

    final int totalMicros = stopwatch.elapsedMicroseconds;
    final double avgMicros = totalMicros / decodedFrames;
    // ignore: avoid_print
    print(
      'flutter_animated_gif_frames,$iterations,$totalMicros,'
      '${(avgMicros * 1000).toStringAsFixed(1)},$decodedFrames',
    );
    expect(decodedFrames, iterations * 2);
  });
}

Duration _testFrameTimestamp = Duration.zero;

void _pumpFlutterFrame() {
  final SchedulerBinding binding = SchedulerBinding.instance;
  _testFrameTimestamp += const Duration(milliseconds: 1);
  binding.handleBeginFrame(_testFrameTimestamp);
  binding.handleDrawFrame();
}

Future<void> _waitForCompletionGateIdle() async {
  for (var attempt = 0; attempt < 12; attempt += 1) {
    final Map<String, Object?> snapshot = PixaDebugInspector.snapshot()
        .toJson();
    final Map<String, Object?> displayDecoder =
        snapshot['displayDecoder']! as Map<String, Object?>;
    if (displayDecoder['completionQueueDepth'] == 0 &&
        displayDecoder['completionFrameScheduled'] == false) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final Map<String, Object?> snapshot = PixaDebugInspector.snapshot().toJson();
  throw StateError('Pixa completion gate did not become idle: $snapshot');
}

int _envInt(String name, int fallback) {
  final String? value = Platform.environment[name];
  if (value == null) {
    return fallback;
  }
  return int.tryParse(value).takeIfPositive() ?? fallback;
}

extension on int? {
  int? takeIfPositive() {
    final int? value = this;
    return value == null || value <= 0 ? null : value;
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
    0x44,
    0x01,
    0x00,
    0x3b,
  ]);
}

Uint8List _animatedGif() {
  return base64Decode(
    'R0lGODlhAQABAPAAAP8AAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAA'
    'AAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAgAAA/////wICRAEAOw==',
  );
}
