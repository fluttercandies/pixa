import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker/leak_tracker.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/cache/decoded_cache_registry.dart';

void main() {
  test('decoded registry replaces equal keys with the latest cache object', () {
    final PixaDecodedCacheRegistry registry = PixaDecodedCacheRegistry();
    final _RegistryKey first = _RegistryKey('same', hash: 7);
    final _RegistryKey latest = _RegistryKey('same', hash: 7);

    registry.track(namespace: 'a', cacheKey: 'one', key: first);
    registry.track(namespace: 'a', cacheKey: 'one', key: latest);

    expect(registry.entryCount, 1);
    expect(registry.takeCacheKey('one'), <Object>[latest]);
  });

  test('tracking only probes the matching hash bucket', () {
    final PixaDecodedCacheRegistry registry = PixaDecodedCacheRegistry();
    final _RegistryProbe probe = _RegistryProbe();
    final List<_RegistryKey> keys = List<_RegistryKey>.generate(
      256,
      (int index) => _RegistryKey('key-$index', hash: index, probe: probe),
    );

    for (final _RegistryKey key in keys) {
      registry.track(namespace: 'all', cacheKey: key.value, key: key);
    }

    expect(probe.hashReads, keys.length);
    expect(registry.entryCount, keys.length);
    expect(registry.takeNamespace('all'), keys);
  });

  test(
    'released keys are weak and same-hash tracking remains consistent',
    () async {
      final PixaDecodedCacheRegistry registry = PixaDecodedCacheRegistry();
      final WeakReference<_RegistryKey> staleReference = _trackEphemeralKey(
        registry,
        namespace: 'old',
        cacheKey: 'old',
        value: 'stale',
        hash: 11,
      );
      final _RegistryKey current = _RegistryKey('current', hash: 11);
      final _RegistryKey equalCurrent = _RegistryKey('current', hash: 11);

      await forceGC(fullGcCycles: 3);
      expect(staleReference.target, isNull);

      registry.track(namespace: 'new', cacheKey: 'new', key: current);
      registry.track(namespace: 'new', cacheKey: 'new', key: equalCurrent);

      expect(registry.entryCount, 1);
      expect(registry.takeCacheKey('old'), isEmpty);
      expect(registry.takeNamespace('new'), <Object>[equalCurrent]);
    },
  );

  test('clear removes every index and detaches tracked keys', () {
    final PixaDecodedCacheRegistry registry = PixaDecodedCacheRegistry();
    final List<_RegistryKey> keys = <_RegistryKey>[
      _RegistryKey('first', hash: 21),
      _RegistryKey('second', hash: 22),
    ];

    registry.track(namespace: 'all', cacheKey: 'first', key: keys.first);
    registry.track(namespace: 'all', cacheKey: 'second', key: keys.last);
    registry.clear();

    expect(registry.entryCount, 0);
    expect(registry.takeNamespace('all'), isEmpty);
    expect(registry.takeCacheKey('first'), isEmpty);
  });

  test(
    'provider registers only when Flutter ImageCache invokes its loader',
    () async {
      pixaDecodedCacheRegistry.clear();
      addTearDown(pixaDecodedCacheRegistry.clear);
      final PixaProvider provider = PixaProvider.network(
        'https://images.example.test/provider-registration.png',
      );

      final PixaProvider key = await provider.obtainKey(
        ImageConfiguration.empty,
      );

      expect(pixaDecodedCacheRegistry.entryCount, 0);
      provider.loadImage(key, (
        ui.ImmutableBuffer buffer, {
        ui.TargetImageSizeCallback? getTargetSize,
      }) {
        throw StateError('decoder must not run without an image listener');
      });
      expect(pixaDecodedCacheRegistry.entryCount, 1);
      expect(
        pixaDecodedCacheRegistry.takeNamespace(key.request.cacheNamespace),
        <Object>[key],
      );
    },
  );

  testWidgets(
    'registry retains live keys when ImageCache maximumSize is zero',
    (WidgetTester tester) async {
      final ImageCache cache = PaintingBinding.instance.imageCache;
      final int previousMaximumSize = cache.maximumSize;
      final int previousMaximumSizeBytes = cache.maximumSizeBytes;
      cache
        ..clear()
        ..clearLiveImages()
        ..maximumSize = 0;
      pixaDecodedCacheRegistry.clear();
      final _RegistryKey key = _RegistryKey('live', hash: 13);
      final ui.Image image = await _onePixelImage();
      final ImageStreamCompleter completer = OneFrameImageStreamCompleter(
        Future<ImageInfo>.value(ImageInfo(image: image)),
      );
      final ImageStreamListener listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
      );
      completer.addListener(listener);
      addTearDown(() {
        completer.removeListener(listener);
        cache
          ..evict(key)
          ..clear()
          ..clearLiveImages()
          ..maximumSize = previousMaximumSize
          ..maximumSizeBytes = previousMaximumSizeBytes;
        pixaDecodedCacheRegistry.clear();
      });

      pixaDecodedCacheRegistry.track(
        namespace: 'live',
        cacheKey: 'live-key',
        key: key,
      );
      cache.putIfAbsent(key, () => completer);
      await tester.pump();

      expect(cache.statusForKey(key).live, isTrue);
      expect(pixaDecodedCacheRegistry.takeNamespace('live'), <Object>[key]);
      cache.evict(key);
      expect(cache.statusForKey(key).untracked, isTrue);
    },
  );
}

Future<ui.Image> _onePixelImage() {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff112233), ui.BlendMode.src);
  return recorder.endRecording().toImage(1, 1);
}

WeakReference<_RegistryKey> _trackEphemeralKey(
  PixaDecodedCacheRegistry registry, {
  required String namespace,
  required String cacheKey,
  required String value,
  required int hash,
}) {
  final _RegistryKey key = _RegistryKey(value, hash: hash);
  registry.track(namespace: namespace, cacheKey: cacheKey, key: key);
  return WeakReference<_RegistryKey>(key);
}

final class _RegistryProbe {
  int hashReads = 0;
}

final class _RegistryKey {
  _RegistryKey(this.value, {required this.hash, this.probe});

  final String value;
  final int hash;
  final _RegistryProbe? probe;

  @override
  bool operator ==(Object other) {
    return other is _RegistryKey && other.value == value;
  }

  @override
  int get hashCode {
    probe?.hashReads++;
    return hash;
  }
}
