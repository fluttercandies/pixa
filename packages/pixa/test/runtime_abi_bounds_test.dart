import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/cache_key.dart';
import 'package:pixa/src/runtime/runtime_bridge.dart';
import 'package:pixa/src/runtime/runtime_disk_cache.dart';
import 'package:pixa/src/runtime/runtime_loader.dart';
import 'package:pixa/src/runtime/runtime_memory_cache.dart';

const int _portableUintPtrMax = 0xffffffff;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (String name, bool Function() configure)
      in <(String, bool Function())>[
        (
          'memory cache bytes',
          () => PixaRuntimeBridge.configure(
            memoryCacheBytes: _portableUintPtrMax + 1,
            diskCacheBytes: 1,
            networkConcurrency: 1,
          ),
        ),
        (
          'disk cache bytes',
          () => PixaRuntimeBridge.configure(
            memoryCacheBytes: 1,
            diskCacheBytes: _portableUintPtrMax + 1,
            networkConcurrency: 1,
          ),
        ),
        (
          'network concurrency',
          () => PixaRuntimeBridge.configure(
            memoryCacheBytes: 1,
            diskCacheBytes: 1,
            networkConcurrency: _portableUintPtrMax + 1,
          ),
        ),
      ]) {
    test('runtime configure rejects non-portable $name', () {
      addTearDown(_restoreRuntimeConfig);

      expect(configure, throwsRangeError);
    });
  }

  test('runtime configure accepts concurrency above the former cap', () {
    addTearDown(_restoreRuntimeConfig);

    expect(
      PixaRuntimeBridge.configure(
        memoryCacheBytes: 1,
        diskCacheBytes: 1,
        networkConcurrency: 64,
      ),
      isTrue,
    );
  });

  for (final (String name, PixaConfig config) in <(String, PixaConfig)>[
    (
      'memory cache bytes',
      const PixaConfig(memoryCacheBytes: _portableUintPtrMax + 1),
    ),
    (
      'disk cache bytes',
      const PixaConfig(diskCacheBytes: _portableUintPtrMax + 1),
    ),
  ]) {
    test('Pixa.configure rejects non-portable $name', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'pixa-config-bounds-',
      );
      addTearDown(() async {
        await Pixa.configure(PixaConfig(cacheRootPath: root.path));
        await root.delete(recursive: true);
      });

      await expectLater(
        Pixa.configure(
          PixaConfig(
            memoryCacheBytes: config.memoryCacheBytes,
            diskCacheBytes: config.diskCacheBytes,
            cacheRootPath: root.path,
          ),
        ),
        throwsRangeError,
      );
    });
  }

  test('Pixa.configure accepts user-selected high concurrency', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'pixa-config-concurrency-',
    );
    addTearDown(() async {
      await Pixa.configure(PixaConfig(cacheRootPath: root.path));
      await root.delete(recursive: true);
    });

    await expectLater(
      Pixa.configure(
        PixaConfig(networkConcurrency: 64, cacheRootPath: root.path),
      ),
      completes,
    );
  });

  test('memory trim rejects a non-portable byte target', () {
    expect(
      () => PixaRuntimeMemoryCache.trimToBytes(_portableUintPtrMax + 1),
      throwsRangeError,
    );
  });

  test('owned buffer creation rejects a non-portable length first', () {
    expect(
      () => PixaRuntimeOwnedBuffer.takePointer(
        nullptr.cast<Uint8>(),
        _portableUintPtrMax + 1,
      ),
      throwsRangeError,
    );
  });

  test('memory cache rejects negative TTL before runtime ingress', () {
    final PixaCacheKey key = PixaCacheKey.fromParts(<Object?>['negative-ttl']);
    addTearDown(PixaRuntimeMemoryCache.clear);

    expect(
      () => PixaRuntimeMemoryCache.writeProcessed(
        namespace: 'bounds',
        key: key,
        bytes: Uint8List(1),
        ttl: const Duration(milliseconds: -1),
      ),
      throwsArgumentError,
    );
  });

  test('disk cache rejects negative TTL before runtime ingress', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'pixa-disk-ttl-',
    );
    addTearDown(() => root.delete(recursive: true));
    final PixaRuntimeDiskCache cache = PixaRuntimeDiskCache(
      rootPath: root.path,
    );

    expect(
      () => cache.write(
        namespace: 'bounds',
        key: PixaCacheKey.fromParts(<Object?>['negative-disk-ttl']),
        bytes: Uint8List(1),
        ttl: const Duration(milliseconds: -1),
      ),
      throwsArgumentError,
    );
  });
}

bool _restoreRuntimeConfig() {
  return PixaRuntimeBridge.configure(
    memoryCacheBytes: 96 * 1024 * 1024,
    diskCacheBytes: 512 * 1024 * 1024,
    networkConcurrency: 6,
  );
}
