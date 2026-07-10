import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('pipeline preserves user-selected network concurrency above 32', () {
    final PixaPipeline pipeline = PixaPipeline(
      cacheRootPath: 'unused',
      maxConcurrentRuntimeLoads: 64,
    );

    expect(pipeline.maxConcurrentRuntimeLoads, 64);
    expect(pipeline.schedulerStats().maxConcurrentRuntimeLoads, 64);
  });

  test('public pipeline rejects invalid scheduler bounds at runtime', () {
    expect(
      () => PixaPipeline(cacheRootPath: 'unused', maxConcurrentRuntimeLoads: 0),
      throwsRangeError,
    );
    expect(
      () => PixaPipeline(cacheRootPath: 'unused', maxQueuedRuntimeLoads: -1),
      throwsRangeError,
    );
  });
}
