import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

part 'src/pixa_profile_report_markdown.dart';
part 'src/pixa_profile_report_support.dart';

const int _profileSchemaVersion = 3;
const String _profileToolVersion = 'pixa-profile-v3';
const Set<String> _requiredScenarios = <String>{
  'cold_network_loopback',
  'encoded_memory_hit_burst',
  'disk_hit_burst',
  'decoded_hit_burst',
  'rapid_bidirectional_scroll',
  'prefetch_cancellation_completion_pacing',
};
const int _profileFrameBudgetMicros = 8333;
const double _profileMinimumRefreshRateHz = 119.0;
const int _profileMinimumFramesPerScenario = 120;
const double _profileMaximumOverBudgetRatio = 0.01;
const int _profileMaximumRssPlateauGrowthBytes = 16 * 1024 * 1024;
const int _profileMaximumRssSlopeBytesPerCycle = 1024 * 1024;
const int _profileMaximumRegistryPlateauGrowthEntries = 32;
const int _profileMaximumRegistrySlopeEntriesPerCycle = 4;
const int _profileMemoryWarmupStableSamples = 3;
const int _profileMemoryWarmupMaxEncodedDriftBytes = 1024 * 1024;
const int _profileMemoryWarmupMaxEntryDrift = 4;
const int _profileDecodedCacheEntryBudget = 256;
const int _profileDecodedCacheWarmupMinimumEntries = 231;
const int _profileLiveNetworkSamples = 240;
const int _profileLiveNetworkIdentityProbes = 8;
const int _profileLiveNetworkSeed = 20260710;
const int _profileLiveNetworkMinimumDimension = 96;
const int _profileLiveNetworkMaximumDimension = 1024;

/// Independently evaluated result for one profile-mode scroll run.
final class PixaProfileEvaluation {
  const PixaProfileEvaluation({
    required this.passed,
    required this.releasePassed,
    required this.failures,
    required this.supplementalFailures,
    required this.markdown,
  });

  final bool passed;
  final bool releasePassed;
  final List<String> failures;
  final List<String> supplementalFailures;
  final String markdown;
}

/// Evaluates raw device evidence and renders a release-reviewable report.
PixaProfileEvaluation evaluateProfileRun(
  Map<String, Object?> run, {
  Map<String, Object?>? baseline,
  String? currentGitCommit,
  bool requireLiveNetwork = false,
}) {
  final List<String> failures = <String>[];
  final _MemoryEvaluation memory = _evaluateCoreProfileRun(
    run,
    failures,
    currentGitCommit: currentGitCommit,
  );
  final List<String> supplementalFailures = <String>[
    ..._evaluateLiveNetwork(run),
    if (requireLiveNetwork && run['liveNetworkRequested'] != true)
      'Live network evidence is required for release acceptance.',
  ];
  if (baseline == null) {
    failures.add('A comparable baseline profile run is required.');
  } else {
    final List<String> baselineFailures = <String>[];
    _evaluateCoreProfileRun(baseline, baselineFailures);
    for (final String failure in baselineFailures) {
      failures.add('Baseline evidence failed: $failure');
    }
    _validateBaseline(run, baseline, failures);
  }

  final List<String> immutableFailures = List<String>.unmodifiable(failures);
  final bool corePassed = immutableFailures.isEmpty;
  final bool liveNetworkGateEnabled =
      requireLiveNetwork || run['liveNetworkRequested'] == true;
  final bool releasePassed =
      corePassed && (!liveNetworkGateEnabled || supplementalFailures.isEmpty);
  return PixaProfileEvaluation(
    passed: corePassed,
    releasePassed: releasePassed,
    failures: immutableFailures,
    supplementalFailures: List<String>.unmodifiable(supplementalFailures),
    markdown: _renderMarkdown(
      run,
      baseline: baseline,
      failures: immutableFailures,
      supplementalFailures: supplementalFailures,
      memory: memory,
      releasePassed: releasePassed,
    ),
  );
}

_MemoryEvaluation _evaluateCoreProfileRun(
  Map<String, Object?> run,
  List<String> failures, {
  String? currentGitCommit,
}) {
  if (_integer(run, 'schemaVersion') != _profileSchemaVersion) {
    failures.add('Unsupported profile evidence schema version.');
  }
  if (_text(run, 'evidenceLevel') != 'full') {
    failures.add('Performance evidence level must be full.');
  }
  if (_text(run, 'toolVersion') != _profileToolVersion) {
    failures.add('Performance evidence tool version is unsupported.');
  }
  if (_text(run, 'runId').trim().isEmpty) {
    failures.add('Performance evidence runId must not be empty.');
  }
  final DateTime? capturedAt = DateTime.tryParse(_text(run, 'capturedAtUtc'));
  if (capturedAt == null || !capturedAt.isUtc) {
    failures.add('Performance evidence capture time must be valid UTC.');
  }
  if (_text(run, 'mode') != 'profile') {
    failures.add('Performance evidence must be captured in profile mode.');
  }
  _validateReportedThresholds(run, failures);

  final Map<String, Object?> environment = _object(run, 'environment');
  final double refreshRate = _number(environment, 'refreshRateHz');

  if (refreshRate < _profileMinimumRefreshRateHz) {
    failures.add(
      'Measured refresh rate ${refreshRate.toStringAsFixed(2)} Hz is below '
      '${_profileMinimumRefreshRateHz.toStringAsFixed(2)} Hz.',
    );
  }
  for (final String field in <String>[
    'deviceLabel',
    'deviceIdHash',
    'platform',
    'osVersion',
    'flutterVersion',
    'dartVersion',
    'rustVersion',
    'gitCommit',
  ]) {
    final String value = _text(environment, field);
    if (value.trim().isEmpty || value == 'unknown') {
      failures.add('Environment field "$field" must contain measured data.');
    }
  }
  if (!_isSha256(_text(environment, 'deviceIdHash'))) {
    failures.add('Environment deviceIdHash must be a SHA-256 digest.');
  }
  final String gitCommit = _text(environment, 'gitCommit');
  if (!_isGitCommit(gitCommit)) {
    failures.add('Environment gitCommit must be a full hexadecimal revision.');
  }
  if (_text(environment, 'gitTreeState') != 'clean' ||
      gitCommit.contains('dirty')) {
    failures.add(
      'Performance evidence must be captured from a clean Git tree.',
    );
  }
  if (currentGitCommit != null && gitCommit != currentGitCommit) {
    failures.add(
      'Performance evidence Git commit $gitCommit does not match current HEAD '
      '$currentGitCommit.',
    );
  }
  if (_integer(environment, 'viewportPhysicalWidth') <= 0 ||
      _integer(environment, 'viewportPhysicalHeight') <= 0 ||
      _number(environment, 'devicePixelRatio') <= 0) {
    failures.add(
      'Viewport dimensions and device pixel ratio must be measured.',
    );
  }
  final Map<String, Object?> workload = _object(run, 'workload');
  if (!_isSha256(_text(workload, 'corpusSha256'))) {
    failures.add('Workload corpusSha256 must be a SHA-256 digest.');
  }

  final List<Map<String, Object?>> scenarios = _objects(run, 'scenarios');
  final Map<String, Map<String, Object?>> scenarioByName =
      <String, Map<String, Object?>>{
        for (final Map<String, Object?> scenario in scenarios)
          _text(scenario, 'name'): scenario,
      };
  if (scenarioByName.length != scenarios.length) {
    failures.add('Profile scenario names must be unique.');
  }
  final Set<String> missingScenarios = _requiredScenarios.difference(
    scenarioByName.keys.toSet(),
  );
  if (missingScenarios.isNotEmpty) {
    failures.add(
      'Missing required profile scenarios: ${missingScenarios.join(', ')}.',
    );
  }
  for (final String name in _requiredScenarios) {
    final Map<String, Object?>? scenario = scenarioByName[name];
    if (scenario == null) {
      continue;
    }
    final int frameCount = _integer(scenario, 'frameCount');
    final Map<String, Object?> build = _object(scenario, 'build');
    final Map<String, Object?> raster = _object(scenario, 'raster');
    final int buildP99 = _integer(build, 'p99Micros');
    final int rasterP99 = _integer(raster, 'p99Micros');
    final int overBudgetFrames = _integer(scenario, 'overBudgetFrames');
    if (frameCount < _profileMinimumFramesPerScenario) {
      failures.add(
        '$name captured $frameCount frames; at least '
        '$_profileMinimumFramesPerScenario are required.',
      );
    }
    if (buildP99 > _profileFrameBudgetMicros) {
      failures.add(
        '$name build p99 ${_milliseconds(buildP99)} exceeds '
        '${_milliseconds(_profileFrameBudgetMicros)}.',
      );
    }
    if (rasterP99 > _profileFrameBudgetMicros) {
      failures.add(
        '$name raster p99 ${_milliseconds(rasterP99)} exceeds '
        '${_milliseconds(_profileFrameBudgetMicros)}.',
      );
    }
    final double ratio = frameCount == 0
        ? double.infinity
        : overBudgetFrames / frameCount;
    if (ratio > _profileMaximumOverBudgetRatio) {
      failures.add(
        '$name has ${(ratio * 100).toStringAsFixed(2)}% over-budget frames; '
        'limit is '
        '${(_profileMaximumOverBudgetRatio * 100).toStringAsFixed(2)}%.',
      );
    }
    _validateScenarioBehavior(name, scenario, failures);
  }
  _validateCompletionPacing(scenarioByName.values, failures);
  return _evaluateMemory(run, failures);
}

void _validateReportedThresholds(
  Map<String, Object?> run,
  List<String> failures,
) {
  final Map<String, Object?> reported = _object(run, 'thresholds');
  const Map<String, Object> expected = <String, Object>{
    'frameBudgetMicros': _profileFrameBudgetMicros,
    'minimumRefreshRateHz': _profileMinimumRefreshRateHz,
    'minimumFramesPerScenario': _profileMinimumFramesPerScenario,
    'maximumOverBudgetRatio': _profileMaximumOverBudgetRatio,
    'maximumRssPlateauGrowthBytes': _profileMaximumRssPlateauGrowthBytes,
    'maximumRssSlopeBytesPerCycle': _profileMaximumRssSlopeBytesPerCycle,
    'maximumRegistryPlateauGrowthEntries':
        _profileMaximumRegistryPlateauGrowthEntries,
    'maximumRegistrySlopeEntriesPerCycle':
        _profileMaximumRegistrySlopeEntriesPerCycle,
  };
  for (final MapEntry<String, Object> threshold in expected.entries) {
    if (reported[threshold.key] != threshold.value) {
      failures.add(
        'Reported threshold "${threshold.key}" does not match the '
        'verifier-owned value ${threshold.value}.',
      );
    }
  }
}

void _validateScenarioBehavior(
  String name,
  Map<String, Object?> scenario,
  List<String> failures,
) {
  final int networkRequests = _integer(scenario, 'loopbackRequests');
  final Map<String, Object?> cacheDelta = _object(scenario, 'cacheDelta');
  final int memoryHits = _integer(cacheDelta, 'memoryHits');
  final int diskHits = _integer(cacheDelta, 'diskHits');
  switch (name) {
    case 'cold_network_loopback':
      final Map<String, Object?> cacheBefore = _object(scenario, 'cacheBefore');
      if (networkRequests <= 0 ||
          _integer(cacheDelta, 'memoryMisses') <= 0 ||
          _integer(cacheDelta, 'diskMisses') <= 0 ||
          _integer(cacheDelta, 'diskWrites') <= 0) {
        failures.add(
          '$name must prove origin requests, cache misses, and disk writes.',
        );
      }
      if (_integer(cacheBefore, 'memoryBytes') != 0 ||
          _integer(cacheBefore, 'decodedEntries') != 0 ||
          _integer(cacheBefore, 'decodedBytes') != 0) {
        failures.add('$name must begin with empty encoded and decoded caches.');
      }
    case 'encoded_memory_hit_burst':
      if (networkRequests != 0 || memoryHits <= 0 || diskHits != 0) {
        failures.add(
          '$name must use encoded memory hits only with no origin requests.',
        );
      }
    case 'disk_hit_burst':
      if (networkRequests != 0 || memoryHits != 0 || diskHits <= 0) {
        failures.add('$name must use disk hits only with no origin requests.');
      }
    case 'decoded_hit_burst':
      if (networkRequests != 0 ||
          memoryHits != 0 ||
          diskHits != 0 ||
          _integer(scenario, 'decodedHits') <= 0) {
        failures.add(
          '$name must prove decoded hits without encoded or origin access.',
        );
      }
    case 'prefetch_cancellation_completion_pacing':
      final Map<String, Object?> scheduler = _object(
        scenario,
        'schedulerDelta',
      );
      final Map<String, Object?> prefetch = _object(scenario, 'prefetchDelta');
      if (_integer(scheduler, 'cancelled') <= 0 ||
          _integer(prefetch, 'skippedPending') <= 0) {
        failures.add(
          '$name must record scheduler cancellation and stale prefetch skips.',
        );
      }
    case 'rapid_bidirectional_scroll':
      break;
  }
}

void _validateCompletionPacing(
  Iterable<Map<String, Object?>> scenarios,
  List<String> failures,
) {
  var observedQueuedCompletion = false;
  var observedReleasedCompletion = false;
  for (final Map<String, Object?> scenario in scenarios) {
    final String name = _text(scenario, 'name');
    final Map<String, Object?> pacing = _object(scenario, 'completionPacing');
    final int configured = _integer(pacing, 'configuredMaxPerFrame');
    final int maxReleased = _integer(pacing, 'maxReleasedPerFrame');
    final int maxQueueDepth = _integer(pacing, 'maxQueueDepth');
    final int finalQueueDepth = _integer(pacing, 'finalQueueDepth');
    if (configured != 3 ||
        maxReleased < 0 ||
        maxReleased > configured ||
        maxQueueDepth < 0 ||
        finalQueueDepth != 0) {
      failures.add(
        '$name must report bounded, drained image completion pacing.',
      );
    }
    observedQueuedCompletion = observedQueuedCompletion || maxQueueDepth > 0;
    observedReleasedCompletion = observedReleasedCompletion || maxReleased > 0;
  }
  if (!observedQueuedCompletion || !observedReleasedCompletion) {
    failures.add(
      'Profile scenarios must prove queued and frame-budgeted image '
      'completion pacing.',
    );
  }
}

List<String> _evaluateLiveNetwork(Map<String, Object?> run) {
  final Object? rawLive = run['liveNetwork'];
  if (rawLive == null) {
    if (run['liveNetworkRequested'] == true) {
      return const <String>[
        'Live network evidence was requested but no result was recorded.',
      ];
    }
    return const <String>[];
  }
  final Map<String, Object?> live;
  if (rawLive is Map<String, Object?>) {
    live = rawLive;
  } else if (rawLive is Map) {
    live = rawLive.map(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key.toString(), value),
    );
  } else {
    return const <String>['Live network evidence must be a JSON object.'];
  }
  if (live['enabled'] != true) {
    return const <String>['Live network evidence was not enabled.'];
  }
  try {
    return _evaluateLiveNetworkObject(live);
  } on FormatException catch (error) {
    return <String>['Live network evidence is incomplete: ${error.message}'];
  }
}

List<String> _evaluateLiveNetworkObject(Map<String, Object?> live) {
  final List<String> failures = <String>[];
  if (_text(live, 'service') != 'picsum.photos') {
    failures.add('Live network service must be picsum.photos.');
  }
  if (_integer(live, 'corpusSeed') != _profileLiveNetworkSeed) {
    failures.add('Live network corpus seed must be $_profileLiveNetworkSeed.');
  }
  final int corpusSamples = _integer(live, 'corpusSamples');
  final int registered = _integer(live, 'registeredSamples');
  final int requested = _integer(live, 'requestedSamples');
  final int observed = _integer(live, 'observedSamples');
  final int completed = _integer(live, 'completedSamples');
  final int failed = _integer(live, 'failedSamples');
  final int cancelled = _integer(live, 'cancelledSamples');
  if (corpusSamples != _profileLiveNetworkSamples ||
      registered != _profileLiveNetworkSamples ||
      requested != _profileLiveNetworkSamples ||
      observed != _profileLiveNetworkSamples ||
      completed != _profileLiveNetworkSamples) {
    failures.add(
      'Live network coverage must be $_profileLiveNetworkSamples samples; '
      'measured corpus=$corpusSamples, registered=$registered, '
      'requested=$requested, observed=$observed, completed=$completed.',
    );
  }
  if (failed != 0 || cancelled != 0) {
    failures.add(
      'Live network recorded $failed failed and $cancelled cancelled loads.',
    );
  }
  final int unexpectedCacheHits = _integer(live, 'unexpectedCacheHits');
  if (unexpectedCacheHits != 0) {
    failures.add(
      'Live no-store scenario recorded $unexpectedCacheHits cache hits.',
    );
  }
  final Object? widgetFailures = live['widgetFailures'];
  if (widgetFailures is! List) {
    failures.add('Live network widget failures were not recorded.');
  } else if (widgetFailures.isNotEmpty) {
    failures.add(
      'Live network widget reported ${widgetFailures.length} failures.',
    );
  }
  if (_text(live, 'cacheState') != 'network/no-store') {
    failures.add('Live network cache state must be network/no-store.');
  }

  final Map<String, Object?> frame = _object(live, 'frameScenario');
  final int frameCount = _integer(frame, 'frameCount');
  final int buildP99 = _integer(_object(frame, 'build'), 'p99Micros');
  final int rasterP99 = _integer(_object(frame, 'raster'), 'p99Micros');
  final int overBudget = _integer(frame, 'overBudgetFrames');
  if (frameCount < _profileMinimumFramesPerScenario ||
      buildP99 > _profileFrameBudgetMicros ||
      rasterP99 > _profileFrameBudgetMicros) {
    failures.add('Live network FrameTiming did not meet the 120Hz thresholds.');
  }
  final double overBudgetRatio = frameCount == 0
      ? double.infinity
      : overBudget / frameCount;
  if (overBudgetRatio > _profileMaximumOverBudgetRatio) {
    failures.add(
      'Live network over-budget ratio '
      '${(overBudgetRatio * 100).toStringAsFixed(2)}% exceeded the limit.',
    );
  }

  final List<Map<String, Object?>> samples = _objects(live, 'samples');
  if (samples.length != _profileLiveNetworkSamples) {
    failures.add(
      'Live network raw sample list must contain '
      '$_profileLiveNetworkSamples entries; measured ${samples.length}.',
    );
  }
  final Set<int> indices = <int>{};
  final Set<int> contentSeeds = <int>{};
  final Set<(int, int)> dimensions = <(int, int)>{};
  final Set<int> encodedByteSizes = <int>{};
  var hasLandscape = false;
  var hasPortrait = false;
  var dimensionsInRange = true;
  var probeCount = 0;
  for (final Map<String, Object?> sample in samples) {
    final int index = _integer(sample, 'index');
    if (!indices.add(index)) {
      failures.add('Live network sample index $index is duplicated.');
    }
    if (sample['requested'] != true || sample['observed'] != true) {
      failures.add(
        'Live network sample $index was not requested and observed.',
      );
    }
    if (_text(sample, 'outcome') != 'completed') {
      failures.add('Live network sample $index did not complete.');
    }
    if (_text(sample, 'cacheState') != 'network/no-store') {
      failures.add('Live network sample $index was cache contaminated.');
    }
    contentSeeds.add(_integer(sample, 'contentSeed'));
    final int width = _integer(sample, 'width');
    final int height = _integer(sample, 'height');
    dimensions.add((width, height));
    dimensionsInRange =
        dimensionsInRange &&
        width >= _profileLiveNetworkMinimumDimension &&
        width <= _profileLiveNetworkMaximumDimension &&
        height >= _profileLiveNetworkMinimumDimension &&
        height <= _profileLiveNetworkMaximumDimension;
    hasLandscape = hasLandscape || width > height;
    hasPortrait = hasPortrait || height > width;
    final int timedBytes = _integer(sample, 'timedPixaBytes');
    final int timedLatency = _integer(sample, 'timedPixaLatencyMicros');
    encodedByteSizes.add(timedBytes);
    if (timedBytes <= 0 || timedLatency <= 0) {
      failures.add(
        'Live network sample $index did not record positive Pixa bytes and latency.',
      );
    }
    final Map<String, Object?>? probe = _optionalObject(
      sample,
      'identityProbe',
    );
    if (probe == null) {
      continue;
    }
    probeCount += 1;
    _validateLiveIdentityProbe(
      probe,
      sampleIndex: index,
      timedPixaBytes: timedBytes,
      failures: failures,
    );
  }
  final Set<int> expectedIndices = <int>{
    for (var index = 0; index < _profileLiveNetworkSamples; index += 1) index,
  };
  if (indices.length != expectedIndices.length ||
      !indices.containsAll(expectedIndices)) {
    failures.add('Live network indices must uniquely cover 0..239.');
  }
  if (dimensions.length != _profileLiveNetworkSamples) {
    failures.add(
      'Live network corpus must contain $_profileLiveNetworkSamples unique '
      'dimensions; measured ${dimensions.length}.',
    );
  }
  if (!dimensionsInRange) {
    failures.add(
      'Live network dimensions must stay within '
      '$_profileLiveNetworkMinimumDimension..'
      '$_profileLiveNetworkMaximumDimension pixels.',
    );
  }
  if (contentSeeds.length != _profileLiveNetworkSamples ||
      encodedByteSizes.length < 8 ||
      !hasLandscape ||
      !hasPortrait) {
    failures.add(
      'Live network corpus diversity is insufficient: '
      'unique seeds=${contentSeeds.length}, '
      'encoded byte sizes=${encodedByteSizes.length}, '
      'landscape=$hasLandscape, portrait=$hasPortrait.',
    );
  }
  if (probeCount < _profileLiveNetworkIdentityProbes) {
    failures.add(
      'Live network requires at least $_profileLiveNetworkIdentityProbes '
      'independent identity probes; measured $probeCount.',
    );
  }
  return failures;
}

void _validateLiveIdentityProbe(
  Map<String, Object?> probe, {
  required int sampleIndex,
  required int timedPixaBytes,
  required List<String> failures,
}) {
  if (_text(probe, 'kind') != 'independent-pixa-http-identity') {
    failures.add('Live network sample $sampleIndex has an unknown probe kind.');
  }
  final int pixaBytes = _integer(probe, 'pixaBytes');
  final int httpBytes = _integer(probe, 'httpBytes');
  final int pixaLatency = _integer(probe, 'pixaLatencyMicros');
  final int httpLatency = _integer(probe, 'httpLatencyMicros');
  final int statusCode = _integer(probe, 'httpStatusCode');
  final int redirects = _integer(probe, 'httpRedirectCount');
  final String pixaMime = _text(probe, 'pixaMimeType');
  final String httpMime = _text(probe, 'httpMimeType');
  final String pixaSha256 = _text(probe, 'pixaSha256');
  final String httpSha256 = _text(probe, 'httpSha256');
  final bool validDigests = _isSha256(pixaSha256) && _isSha256(httpSha256);
  if (statusCode < 200 || statusCode >= 300 || redirects < 0) {
    failures.add(
      'Live network sample $sampleIndex identity probe returned HTTP '
      '$statusCode with $redirects redirects.',
    );
  }
  if (pixaBytes <= 0 ||
      httpBytes <= 0 ||
      pixaLatency <= 0 ||
      httpLatency <= 0) {
    failures.add(
      'Live network sample $sampleIndex identity probe lacks bytes or latency.',
    );
  }
  if (timedPixaBytes != pixaBytes || pixaBytes != httpBytes) {
    failures.add(
      'Live network sample $sampleIndex byte identity does not match.',
    );
  }
  if (pixaMime != httpMime || !pixaMime.startsWith('image/')) {
    failures.add(
      'Live network sample $sampleIndex MIME identity does not match.',
    );
  }
  if (!validDigests ||
      pixaSha256 != httpSha256 ||
      probe['digestMatch'] != true) {
    failures.add(
      'Live network sample $sampleIndex SHA-256 identity does not match.',
    );
  }
}

bool _isSha256(String value) {
  return value.length == 64 && _isLowerHex(value);
}

bool _isGitCommit(String value) {
  return (value.length == 40 || value.length == 64) && _isLowerHex(value);
}

bool _isLowerHex(String value) {
  if (value.isEmpty) {
    return false;
  }
  for (final int codeUnit in value.codeUnits) {
    final bool digit = codeUnit >= 0x30 && codeUnit <= 0x39;
    final bool lowerHex = codeUnit >= 0x61 && codeUnit <= 0x66;
    if (!digit && !lowerHex) {
      return false;
    }
  }
  return true;
}

_MemoryEvaluation _evaluateMemory(
  Map<String, Object?> run,
  List<String> failures,
) {
  final Map<String, Object?> workload = _object(run, 'workload');
  if (_integer(workload, 'decodedCacheEntryBudget') !=
      _profileDecodedCacheEntryBudget) {
    failures.add(
      'Decoded cache entry budget must match the verifier-owned '
      '$_profileDecodedCacheEntryBudget entries.',
    );
  }
  final Map<String, Object?>? warmup = _optionalObject(run, 'memoryWarmup');
  if (warmup == null) {
    failures.add(
      'Memory warmup must reach a stable cache plateau before sampling.',
    );
  } else {
    _validateMemoryWarmup(warmup, failures);
  }
  final List<Map<String, Object?>> samples = _objects(run, 'memorySamples');
  if (samples.length < 4) {
    failures.add('At least four long-scroll memory samples are required.');
  }
  if (samples.isEmpty) {
    return const _MemoryEvaluation.empty();
  }

  final int plateauStart = samples.length ~/ 2;
  final List<Map<String, Object?>> plateau = samples.sublist(plateauStart);
  final List<int> rss = <int>[
    for (final Map<String, Object?> sample in plateau)
      _integer(sample, 'rssBytes'),
  ];
  final int rssGrowth = rss.last - rss.reduce(math.min);
  final double rssSlope = _theilSenSlope(rss);
  final List<int> registry = <int>[
    for (final Map<String, Object?> sample in plateau)
      _integer(sample, 'decodedRegistryEntries'),
  ];
  final int registryGrowth = registry.last - registry.reduce(math.min);
  final double registrySlope = _theilSenSlope(registry);
  if (rssGrowth > _profileMaximumRssPlateauGrowthBytes) {
    failures.add(
      'RSS plateau growth ${_bytes(rssGrowth)} exceeds '
      '${_bytes(_profileMaximumRssPlateauGrowthBytes)}.',
    );
  }
  if (rssSlope > _profileMaximumRssSlopeBytesPerCycle) {
    failures.add(
      'RSS slope ${_bytes(rssSlope.round())}/cycle exceeds '
      '${_bytes(_profileMaximumRssSlopeBytesPerCycle)}/cycle.',
    );
  }
  if (registryGrowth > _profileMaximumRegistryPlateauGrowthEntries) {
    failures.add(
      'Decoded registry plateau growth $registryGrowth entries exceeds '
      '$_profileMaximumRegistryPlateauGrowthEntries.',
    );
  }
  if (registrySlope > _profileMaximumRegistrySlopeEntriesPerCycle) {
    failures.add(
      'Decoded registry slope ${registrySlope.toStringAsFixed(2)} '
      'entries/cycle exceeds '
      '$_profileMaximumRegistrySlopeEntriesPerCycle.',
    );
  }

  final int runtimeMemoryBudget = _integer(workload, 'memoryCacheBudgetBytes');
  final int decodedBudget = _integer(workload, 'decodedCacheBudgetBytes');
  for (var index = 0; index < samples.length; index += 1) {
    _validateRuntimeMemoryAccounting(
      samples[index],
      label: 'Memory sample $index',
      failures: failures,
    );
  }
  final int maxRuntimeMemory = _maximum(samples, 'runtimeMemoryBytes');
  final int maxEncoded = _maximum(samples, 'encodedMemoryBytes');
  final int maxProcessed = _maximum(samples, 'processedMemoryBytes');
  final int maxDecoded = _maximum(samples, 'decodedCacheBytes');
  final int maxRegistry = _maximum(samples, 'decodedRegistryEntries');
  if (maxRuntimeMemory > runtimeMemoryBudget) {
    failures.add(
      'Rust memory cache ${_bytes(maxRuntimeMemory)} exceeds budget '
      '${_bytes(runtimeMemoryBudget)}.',
    );
  }
  if (maxDecoded > decodedBudget) {
    failures.add(
      'Decoded cache ${_bytes(maxDecoded)} exceeds budget '
      '${_bytes(decodedBudget)}.',
    );
  }
  for (var index = 0; index < samples.length; index += 1) {
    _validateDrainedSample(
      samples[index],
      label: 'Memory sample $index',
      failures: failures,
    );
  }
  return _MemoryEvaluation(
    plateauGrowthBytes: rssGrowth,
    slopeBytesPerCycle: rssSlope,
    maxRuntimeMemoryBytes: maxRuntimeMemory,
    maxEncodedBytes: maxEncoded,
    maxProcessedBytes: maxProcessed,
    maxDecodedBytes: maxDecoded,
    maxRegistryEntries: maxRegistry,
    registryPlateauGrowthEntries: registryGrowth,
    registrySlopeEntriesPerCycle: registrySlope,
  );
}

void _validateMemoryWarmup(Map<String, Object?> warmup, List<String> failures) {
  if (warmup['stable'] != true) {
    failures.add(
      'Memory warmup must reach a stable cache plateau before sampling.',
    );
  }
  final List<Map<String, Object?>> samples = _objects(warmup, 'samples');
  final int cycles = _integer(warmup, 'cycles');
  final int reportedRequired = _integer(
    warmup,
    'requiredConsecutiveStableSamples',
  );
  if (cycles != samples.length ||
      samples.length < _profileMemoryWarmupStableSamples ||
      reportedRequired != _profileMemoryWarmupStableSamples) {
    failures.add(
      'Memory warmup samples must contain at least '
      '$_profileMemoryWarmupStableSamples measured cycles and match the '
      'verifier-owned stability window.',
    );
    return;
  }
  for (var index = 0; index < samples.length; index += 1) {
    _validateRuntimeMemoryAccounting(
      samples[index],
      label: 'Memory warmup sample $index',
      failures: failures,
    );
    _validateDrainedSample(
      samples[index],
      label: 'Memory warmup sample $index',
      failures: failures,
    );
  }
  final List<Map<String, Object?>> stableWindow = samples.sublist(
    samples.length - _profileMemoryWarmupStableSamples,
  );
  final List<int> runtimeMemory = <int>[
    for (final Map<String, Object?> sample in stableWindow)
      _integer(sample, 'runtimeMemoryBytes'),
  ];
  final List<int> decoded = <int>[
    for (final Map<String, Object?> sample in stableWindow)
      _integer(sample, 'decodedCacheEntries'),
  ];
  final List<int> registry = <int>[
    for (final Map<String, Object?> sample in stableWindow)
      _integer(sample, 'decodedRegistryEntries'),
  ];
  final bool stable =
      runtimeMemory.reduce(math.max) - runtimeMemory.reduce(math.min) <=
          _profileMemoryWarmupMaxEncodedDriftBytes &&
      decoded.reduce(math.max) - decoded.reduce(math.min) <=
          _profileMemoryWarmupMaxEntryDrift &&
      registry.reduce(math.max) - registry.reduce(math.min) <=
          _profileMemoryWarmupMaxEntryDrift &&
      runtimeMemory.every((int value) => value > 0) &&
      decoded.every((int value) => value > 0) &&
      registry.every((int value) => value > 0);
  if (!stable) {
    failures.add(
      'Memory warmup samples do not prove a stable non-empty encoded, '
      'decoded, and registry plateau.',
    );
  }
  if (decoded.reduce(math.min) < _profileDecodedCacheWarmupMinimumEntries) {
    failures.add(
      'Memory warmup must exercise at least '
      '$_profileDecodedCacheWarmupMinimumEntries/'
      '$_profileDecodedCacheEntryBudget decoded cache capacity entries.',
    );
  }
}

void _validateRuntimeMemoryAccounting(
  Map<String, Object?> sample, {
  required String label,
  required List<String> failures,
}) {
  final int runtimeBytes = _integer(sample, 'runtimeMemoryBytes');
  final int encodedBytes = _integer(sample, 'encodedMemoryBytes');
  final int processedBytes = _integer(sample, 'processedMemoryBytes');
  if (runtimeBytes != encodedBytes + processedBytes) {
    failures.add(
      '$label memory accounting must equal encoded plus processed bytes.',
    );
  }
}

void _validateDrainedSample(
  Map<String, Object?> sample, {
  required String label,
  required List<String> failures,
}) {
  for (final (String field, String resource) in <(String, String)>[
    ('queueDepth', 'queue'),
    ('inflightRequests', 'in-flight requests'),
    ('prefetchPending', 'prefetch pending work'),
    ('prefetchActive', 'prefetch active work'),
    ('liveOwnedBufferHandles', 'owned runtime buffers'),
    ('liveProgressSessions', 'runtime progress sessions'),
    ('completionQueueDepth', 'display completion queue'),
  ]) {
    final int value = _integer(sample, field);
    if (value != 0) {
      failures.add('$label $resource must drain to zero; measured $value.');
    }
  }
}

void _validateBaseline(
  Map<String, Object?> run,
  Map<String, Object?> baseline,
  List<String> failures,
) {
  if (_text(run, 'runId') == _text(baseline, 'runId')) {
    failures.add('Baseline must come from a different profile run.');
  }
  if (_integer(baseline, 'schemaVersion') != _profileSchemaVersion) {
    failures.add('Baseline profile evidence schema is not comparable.');
  }
  final Map<String, Object?> currentEnvironment = _object(run, 'environment');
  final Map<String, Object?> baselineEnvironment = _object(
    baseline,
    'environment',
  );
  for (final String field in <String>[
    'deviceIdHash',
    'platform',
    'viewportPhysicalWidth',
    'viewportPhysicalHeight',
    'devicePixelRatio',
  ]) {
    if (currentEnvironment[field] != baselineEnvironment[field]) {
      failures.add('Baseline $field does not match the current run.');
    }
  }
  final double refreshDelta =
      (_number(currentEnvironment, 'refreshRateHz') -
              _number(baselineEnvironment, 'refreshRateHz'))
          .abs();
  if (refreshDelta > 1.0) {
    failures.add('Baseline refresh rate is not comparable to the current run.');
  }
  final Map<String, Object?> workload = _object(run, 'workload');
  final Map<String, Object?> baselineWorkload = _object(baseline, 'workload');
  for (final String field in <String>[
    'corpusId',
    'itemCount',
    'networkConcurrency',
    'decodeConcurrency',
    'memoryCacheBudgetBytes',
    'decodedCacheBudgetBytes',
    'decodedCacheEntryBudget',
    'corpusSha256',
  ]) {
    if (workload[field] != baselineWorkload[field]) {
      failures.add('Baseline workload field "$field" is not comparable.');
    }
  }
  if (jsonEncode(workload['imageCorpus']) !=
      jsonEncode(baselineWorkload['imageCorpus'])) {
    failures.add('Baseline image corpus is not comparable.');
  }
}

final class _MemoryEvaluation {
  const _MemoryEvaluation({
    required this.plateauGrowthBytes,
    required this.slopeBytesPerCycle,
    required this.maxRuntimeMemoryBytes,
    required this.maxEncodedBytes,
    required this.maxProcessedBytes,
    required this.maxDecodedBytes,
    required this.maxRegistryEntries,
    required this.registryPlateauGrowthEntries,
    required this.registrySlopeEntriesPerCycle,
  });

  const _MemoryEvaluation.empty()
    : plateauGrowthBytes = 0,
      slopeBytesPerCycle = 0,
      maxRuntimeMemoryBytes = 0,
      maxEncodedBytes = 0,
      maxProcessedBytes = 0,
      maxDecodedBytes = 0,
      maxRegistryEntries = 0,
      registryPlateauGrowthEntries = 0,
      registrySlopeEntriesPerCycle = 0;

  final int plateauGrowthBytes;
  final double slopeBytesPerCycle;
  final int maxRuntimeMemoryBytes;
  final int maxEncodedBytes;
  final int maxProcessedBytes;
  final int maxDecodedBytes;
  final int maxRegistryEntries;
  final int registryPlateauGrowthEntries;
  final double registrySlopeEntriesPerCycle;
}

Future<void> main(List<String> arguments) async {
  var inputPath = 'build/reports/pixa_profile_scroll_raw.json';
  var baselinePath = 'build/reports/pixa_profile_scroll_baseline.json';
  var outputPath = 'build/reports/pixa_profile_scroll_report.md';
  var requireLiveNetwork = false;
  for (final String argument in arguments) {
    if (argument.startsWith('--input=')) {
      inputPath = argument.substring('--input='.length);
    } else if (argument.startsWith('--baseline=')) {
      baselinePath = argument.substring('--baseline='.length);
    } else if (argument.startsWith('--output=')) {
      outputPath = argument.substring('--output='.length);
    } else if (argument == '--require-live-network') {
      requireLiveNetwork = true;
    } else if (argument == '--help' || argument == '-h') {
      stdout.writeln(
        'Usage: dart run tool/pixa_profile_report.dart '
        '[--input=<raw.json>] [--baseline=<baseline.json>] '
        '[--output=<report.md>] [--require-live-network]',
      );
      return;
    } else {
      throw ArgumentError('Unknown profile report argument: $argument');
    }
  }

  final File output = File(outputPath);
  if (await output.exists()) {
    await output.delete();
  }
  final ({String commit, bool clean}) git = await _currentGitState();
  if (!git.clean) {
    throw StateError(
      'Profile reports can only be generated from a clean Git worktree.',
    );
  }
  final Map<String, Object?> run = await _readJsonObject(inputPath);
  final Map<String, Object?> baseline = await _readJsonObject(baselinePath);
  final PixaProfileEvaluation evaluation = evaluateProfileRun(
    run,
    baseline: baseline,
    currentGitCommit: git.commit,
    requireLiveNetwork: requireLiveNetwork,
  );
  await writeProfileReportAtomically(output.path, evaluation.markdown);
  stdout.writeln(
    'Pixa profile acceptance '
    '${evaluation.releasePassed ? 'passed' : 'failed'}: '
    '${output.path}',
  );
  if (!evaluation.releasePassed) {
    for (final String failure in evaluation.failures) {
      stderr.writeln('- $failure');
    }
    for (final String failure in evaluation.supplementalFailures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
  }
}

/// Publishes a complete report without exposing a partially written file.
Future<void> writeProfileReportAtomically(String path, String contents) async {
  final File output = File(path);
  await output.parent.create(recursive: true);
  final File temporary = File(
    '$path.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(output.path);
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

Future<({String commit, bool clean})> _currentGitState() async {
  final String commit = await _gitOutput(<String>['git', 'rev-parse', 'HEAD']);
  final String status = await _gitOutput(<String>[
    'git',
    'status',
    '--porcelain',
  ]);
  return (commit: commit, clean: status.isEmpty);
}

Future<String> _gitOutput(List<String> arguments) async {
  final ProcessResult result = await Process.run('rtk', arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      'rtk',
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout.toString().trim();
}

Future<Map<String, Object?>> _readJsonObject(String path) async {
  final Object? decoded = jsonDecode(await File(path).readAsString());
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.map(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key.toString(), value),
    );
  }
  throw FormatException('$path must contain a JSON object.');
}
