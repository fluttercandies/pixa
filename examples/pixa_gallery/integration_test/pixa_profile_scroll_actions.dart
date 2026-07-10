part of 'pixa_profile_scroll_test.dart';

const int _memoryWarmupMaximumCycles = 12;
const int _memoryWarmupStableSamples = 3;
const int _memoryWarmupMaxEncodedDriftBytes = 1024 * 1024;
const int _memoryWarmupMaxEntryDrift = 4;
const int _memoryWarmupDecodedSeedBatchSize = 16;

Future<void> _exercisePipelineCancellation(
  ProfileScrollHarnessState harness,
) async {
  final List<PixaPipelineHandle> handles = <PixaPipelineHandle>[];
  final List<Future<void>> outcomes = <Future<void>>[];
  for (var index = 400; index < 412; index += 1) {
    final PixaPipelineHandle handle = Pixa.pipeline.startLoad(
      harness.requestFor(index),
    );
    handles.add(handle);
    outcomes.add(_expectCancelled(handle));
  }
  for (final PixaPipelineHandle handle in handles) {
    handle.cancel();
  }
  await Future.wait<void>(outcomes);
}

Future<void> _expectCancelled(PixaPipelineHandle handle) async {
  try {
    final PixaPipelineLoad load = await handle.future;
    load.dispose();
    throw StateError(
      'Profile cancellation load ${handle.requestId} completed before cancel.',
    );
  } on PixaFailure catch (failure) {
    if (failure.stage != PixaStage.cancel) {
      rethrow;
    }
  }
}

Future<void> _exercisePredictivePrefetchSupersession(
  ProfileScrollHarnessState harness,
) async {
  final List<Future<void>> batches = <Future<void>>[];
  for (final int first in <int>[0, 240, 480, 720, 960, 1200, 1440, 1760]) {
    batches.add(
      harness.prefetchAround(
        firstVisibleIndex: first,
        lastVisibleIndex: math.min(first + 19, profileItemCount - 1),
      ),
    );
  }
  await Future.wait<void>(batches);
}

Future<void> _seedDecodedCacheForMemory(
  ProfileScrollHarnessState harness,
) async {
  for (
    var start = 0;
    start < _decodedCacheEntryBudget;
    start += _memoryWarmupDecodedSeedBatchSize
  ) {
    final int end = math.min(
      start + _memoryWarmupDecodedSeedBatchSize,
      _decodedCacheEntryBudget,
    );
    await Future.wait<void>(<Future<void>>[
      for (var index = start; index < end; index += 1)
        Pixa.prefetch(
          harness.requestFor(index),
          target: PixaPrefetchTarget.decodedPrewarm,
          context: harness.context,
        ),
    ]);
  }
  await _waitForDrain(harness);
}

Future<Map<String, Object?>> _warmMemoryPlateau(
  ProfileScrollHarnessState harness,
) async {
  final List<Map<String, Object?>> samples = <Map<String, Object?>>[];
  for (var cycle = 0; cycle < _memoryWarmupMaximumCycles; cycle += 1) {
    await harness.scrollToEnd(const Duration(milliseconds: 750));
    await harness.scrollToStart(const Duration(milliseconds: 750));
    await _waitForDrain(harness);
    samples.add(_memorySample(cycle, harness));
    if (_memoryWarmupIsStable(samples)) {
      return <String, Object?>{
        'stable': true,
        'cycles': samples.length,
        'requiredConsecutiveStableSamples': _memoryWarmupStableSamples,
        'samples': samples,
      };
    }
  }
  return <String, Object?>{
    'stable': false,
    'cycles': samples.length,
    'requiredConsecutiveStableSamples': _memoryWarmupStableSamples,
    'samples': samples,
  };
}

bool _memoryWarmupIsStable(List<Map<String, Object?>> samples) {
  if (samples.length < _memoryWarmupStableSamples) {
    return false;
  }
  final List<Map<String, Object?>> window = samples.sublist(
    samples.length - _memoryWarmupStableSamples,
  );
  final List<int> encoded = <int>[
    for (final Map<String, Object?> sample in window)
      sample['encodedMemoryBytes']! as int,
  ];
  final List<int> decoded = <int>[
    for (final Map<String, Object?> sample in window)
      sample['decodedCacheEntries']! as int,
  ];
  final List<int> registry = <int>[
    for (final Map<String, Object?> sample in window)
      sample['decodedRegistryEntries']! as int,
  ];
  return window.every(_memorySampleIsDrained) &&
      encoded.every((int value) => value > 0) &&
      decoded.every((int value) => value > 0) &&
      registry.every((int value) => value > 0) &&
      _range(encoded) <= _memoryWarmupMaxEncodedDriftBytes &&
      _range(decoded) <= _memoryWarmupMaxEntryDrift &&
      _range(registry) <= _memoryWarmupMaxEntryDrift;
}

bool _memorySampleIsDrained(Map<String, Object?> sample) {
  return sample['queueDepth'] == 0 &&
      sample['inflightRequests'] == 0 &&
      sample['prefetchPending'] == 0 &&
      sample['prefetchActive'] == 0 &&
      sample['liveOwnedBufferHandles'] == 0 &&
      sample['liveProgressSessions'] == 0 &&
      sample['completionQueueDepth'] == 0;
}

int _range(List<int> values) {
  return values.reduce(math.max) - values.reduce(math.min);
}
