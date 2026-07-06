import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

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
      runPrefetch: (
        PixaRequest request, {
        required PixaPrefetchTarget target,
      }) {
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

  test('flutter engine decode benchmark', () async {
    final int iterations = _envInt('PIXA_BENCH_DECODE_ITERS', 500);
    final Uint8List bytes = _minimalGif();
    var decodedPixels = 0;

    final Stopwatch stopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < iterations; iteration++) {
      final ui.ImmutableBuffer buffer =
          await ui.ImmutableBuffer.fromUint8List(bytes);
      final ui.Codec codec =
          await PaintingBinding.instance.instantiateImageCodecWithSize(buffer);
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
