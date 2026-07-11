import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/pipeline.dart';
import 'package:pixa/src/runtime/runtime_memory_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'public bytes snapshot survives dispose and releases owner once',
    () async {
      final PixaCacheStats before = PixaRuntimeMemoryCache.stats();
      final Uint8List expected = _minimalGif();
      final PixaPipelineLoad load = await PixaPipeline(cacheRootPath: '').load(
        PixaRequest.bytes(
          expected,
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );

      final Uint8List snapshot = load.bytes;
      expect(snapshot, expected);
      expect(() => snapshot[0] = 0, throwsUnsupportedError);

      load.dispose();
      load.dispose();

      expect(load.bytes, same(snapshot));
      expect(snapshot, expected);
      final PixaCacheStats after = PixaRuntimeMemoryCache.stats();
      expect(
        after.ownedBufferHandlesCreated - before.ownedBufferHandlesCreated,
        1,
      );
      expect(after.ownedBufferHandlesFreed - before.ownedBufferHandlesFreed, 1);
    },
  );

  test(
    'retained borrowed bytes keep the runtime owner alive until release',
    () async {
      final PixaCacheStats before = PixaRuntimeMemoryCache.stats();
      final Uint8List expected = _minimalGif();
      final PixaPipelineLoad load = await PixaPipeline(cacheRootPath: '').load(
        PixaRequest.bytes(
          expected,
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );

      final PixaPipelineBytesLease retained = load.retainBorrowedBytes();
      final Uint8List borrowed = retained.bytes;
      load.dispose();

      expect(borrowed, expected);
      expect(() => borrowed[0] = 0, throwsUnsupportedError);
      final PixaCacheStats whileRetained = PixaRuntimeMemoryCache.stats();
      expect(
        whileRetained.ownedBufferHandlesFreed - before.ownedBufferHandlesFreed,
        0,
      );

      retained.dispose();
      retained.dispose();

      expect(() => retained.bytes, throwsStateError);
      final PixaCacheStats after = PixaRuntimeMemoryCache.stats();
      expect(
        after.ownedBufferHandlesCreated - before.ownedBufferHandlesCreated,
        1,
      );
      expect(after.ownedBufferHandlesFreed - before.ownedBufferHandlesFreed, 1);
    },
  );
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
