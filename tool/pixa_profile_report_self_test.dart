import 'dart:io';

import 'pixa_profile_report.dart' as profile;

Future<void> main() async {
  _expect(
    profile.profileGitTreeStateFromPorcelain('''
?? .third/
?? AGENTS.md
?? GOALS.md
?? docs/
?? REF.md
''') ==
        'clean',
    'policy-local planning files must not block profile reports',
  );
  _expect(
    profile.profileGitTreeStateFromPorcelain('''
?? GOALS.md
?? packages/pixa/lib/untracked.dart
''') ==
        'dirty',
    'untracked source files must keep profile reports dirty',
  );
  final Map<String, Object?> baseline = _run(
    refreshRateHz: 120,
    buildP99Micros: 7800,
    rasterP99Micros: 7900,
    overBudgetFrames: 1,
    rssSamples: <int>[
      210 * _mib,
      222 * _mib,
      230 * _mib,
      233 * _mib,
      234 * _mib,
      234 * _mib,
    ],
  );
  final Map<String, Object?> passing = _run(
    refreshRateHz: 120,
    buildP99Micros: 7200,
    rasterP99Micros: 7600,
    overBudgetFrames: 1,
    rssSamples: <int>[
      208 * _mib,
      218 * _mib,
      225 * _mib,
      228 * _mib,
      229 * _mib,
      229 * _mib,
    ],
    liveNetwork: _liveNetworkEvidence(),
  );

  final profile.PixaProfileEvaluation accepted = profile.evaluateProfileRun(
    passing,
    baseline: baseline,
  );
  _expect(accepted.passed, 'a bounded 120Hz run should pass');
  _expect(
    accepted.releasePassed,
    'complete requested live evidence should pass',
  );
  _expect(
    accepted.supplementalFailures.isEmpty,
    'complete live-network evidence should pass its supplemental checks',
  );
  final profile.PixaProfileEvaluation missingRequiredLive = profile
      .evaluateProfileRun(
        _run(
          refreshRateHz: 120,
          buildP99Micros: 7200,
          rasterP99Micros: 7600,
          overBudgetFrames: 1,
          rssSamples: <int>[
            208 * _mib,
            218 * _mib,
            225 * _mib,
            228 * _mib,
            229 * _mib,
            229 * _mib,
          ],
        ),
        baseline: baseline,
        requireLiveNetwork: true,
      );
  _expect(
    !missingRequiredLive.releasePassed &&
        missingRequiredLive.supplementalFailures.any(
          (String failure) => failure.contains('required'),
        ),
    'the release gate must reject missing Picsum evidence when required',
  );
  _expect(
    accepted.markdown.contains('120.00 Hz'),
    'report should identify the measured refresh rate',
  );
  _expect(
    accepted.markdown.contains('fixture-120hz-class'),
    'report should retain a non-identifying device class label',
  );
  _expect(
    !accepted.markdown.contains('fixture-device'),
    'report must not persist raw device identifiers',
  );
  _expect(
    accepted.markdown.contains('Baseline delta'),
    'report should contain baseline comparison',
  );
  _expect(
    accepted.markdown.contains('8.333 ms'),
    'report should state the 120Hz frame budget',
  );
  _expect(
    accepted.markdown.contains('picsum.photos'),
    'report should identify the supplemental live image service',
  );
  _expect(
    accepted.markdown.contains('HTTP 200'),
    'report should include measured live-network status codes',
  );
  _expect(
    accepted.markdown.contains('64.00 KiB'),
    'report should include actual live-network encoded bytes',
  );
  _expect(
    accepted.markdown.contains('42.000 ms'),
    'report should include measured live-network latency',
  );
  _expect(
    accepted.markdown.contains('network/no-store'),
    'report should identify the live-network cache state',
  );
  _expect(
    accepted.markdown.contains('loopback-mixed-v1'),
    'report should identify the deterministic mixed corpus',
  );
  _expect(
    accepted.markdown.contains('Peak processed memory'),
    'report should expose processed variant retention separately',
  );
  _expect(
    accepted.markdown.contains('image/bmp'),
    'report should list every deterministic corpus format',
  );
  _expect(
    accepted.markdown.contains('Observed encoded bytes'),
    'report should summarize the full live byte distribution',
  );
  _expect(
    accepted.markdown.contains('Showing 8 identity probes of 240 timed loads'),
    'report should bound its representative live sample table',
  );
  _expect(
    !accepted.markdown.contains('| 29 |'),
    'report should leave full per-image evidence in raw JSON',
  );

  final Map<String, Object?> distributedPacingRun = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final List<Object?> distributedPacingScenarios =
      distributedPacingRun['scenarios']! as List<Object?>;
  final Map<String, Object?> prefetchPacing =
      (distributedPacingScenarios.last!
              as Map<String, Object?>)['completionPacing']!
          as Map<String, Object?>;
  prefetchPacing
    ..['maxReleasedPerFrame'] = 0
    ..['maxQueueDepth'] = 0;
  final profile.PixaProfileEvaluation distributedPacing = profile
      .evaluateProfileRun(distributedPacingRun, baseline: baseline);
  _expect(
    distributedPacing.passed,
    'completion pacing may be proven by a cache burst independently of '
    'prefetch cancellation',
  );

  final Map<String, Object?> missingPacingRun = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  for (final Object? value in missingPacingRun['scenarios']! as List<Object?>) {
    final Map<String, Object?> pacing =
        (value! as Map<String, Object?>)['completionPacing']!
            as Map<String, Object?>;
    pacing
      ..['maxReleasedPerFrame'] = 0
      ..['maxQueueDepth'] = 0;
  }
  final profile.PixaProfileEvaluation missingPacing = profile
      .evaluateProfileRun(missingPacingRun, baseline: baseline);
  _expect(
    !missingPacing.passed &&
        missingPacing.failures.any(
          (String value) => value.contains('frame-budgeted'),
        ),
    'at least one measured scenario must exercise completion pacing',
  );

  final Map<String, Object?> degradedLive = _liveNetworkEvidence();
  degradedLive['unexpectedCacheHits'] = 1;
  final profile.PixaProfileEvaluation degraded = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
      liveNetwork: degradedLive,
    ),
    baseline: baseline,
  );
  _expect(
    degraded.passed,
    'supplemental network variability must not replace the deterministic gate',
  );
  _expect(
    !degraded.releasePassed,
    'degraded requested live evidence must block the combined release gate',
  );
  _expect(
    degraded.supplementalFailures.isNotEmpty,
    'live cache contamination should degrade supplemental evidence',
  );
  _expect(
    degraded.markdown.contains('Supplemental result: **DEGRADED**'),
    'report should clearly separate degraded live evidence',
  );

  final Map<String, Object?> emptyLive = _liveNetworkEvidence()
    ..['registeredSamples'] = 0
    ..['observedSamples'] = 0
    ..['requestedSamples'] = 0
    ..['completedSamples'] = 0
    ..['samples'] = <Object?>[];
  final profile.PixaProfileEvaluation emptySupplement = profile
      .evaluateProfileRun(
        _run(
          refreshRateHz: 120,
          buildP99Micros: 7000,
          rasterP99Micros: 7000,
          overBudgetFrames: 0,
          rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
          liveNetwork: emptyLive,
        ),
        baseline: baseline,
      );
  _expect(emptySupplement.passed, 'an empty supplement must not fail core');
  _expect(
    emptySupplement.supplementalFailures.isNotEmpty,
    'an empty supplement must be explicitly degraded',
  );
  _expect(
    emptySupplement.markdown.contains('No live image loads were observed.'),
    'empty live evidence should render an actionable result instead of crash',
  );

  final profile.PixaProfileEvaluation partialLive = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
      liveNetwork: _liveNetworkEvidence(sampleCount: 30),
    ),
    baseline: baseline,
  );
  _expect(partialLive.passed, 'live evidence remains supplemental');
  _expect(
    partialLive.supplementalFailures.any(
      (String value) => value.contains('240'),
    ),
    'partial live evidence must not be reported as complete',
  );

  final Map<String, Object?> invalidSamples = _liveNetworkEvidence();
  final List<Object?> invalidSampleList =
      invalidSamples['samples']! as List<Object?>;
  final Map<String, Object?> firstInvalid =
      invalidSampleList.first! as Map<String, Object?>;
  final Map<String, Object?> secondInvalid =
      invalidSampleList[1]! as Map<String, Object?>;
  secondInvalid['index'] = firstInvalid['index'];
  firstInvalid['timedPixaBytes'] = 0;
  firstInvalid['timedPixaLatencyMicros'] = 0;
  ((firstInvalid['identityProbe']! as Map<String, Object?>))['httpSha256'] =
      'different-digest';
  final profile.PixaProfileEvaluation invalidLive = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
      liveNetwork: invalidSamples,
    ),
    baseline: baseline,
  );
  _expect(
    invalidLive.supplementalFailures.length >= 3,
    'live evidence must validate indices, timed bytes, latency, and digest',
  );

  final Map<String, Object?> repeatedDimensionsLive = _liveNetworkEvidence();
  final List<Object?> repeatedDimensionSamples =
      repeatedDimensionsLive['samples']! as List<Object?>;
  for (var index = 0; index < repeatedDimensionSamples.length; index += 1) {
    final Map<String, Object?> sample =
        repeatedDimensionSamples[index]! as Map<String, Object?>;
    final ({int width, int height}) size =
        _legacyLiveSizes[index % _legacyLiveSizes.length];
    sample
      ..['width'] = size.width
      ..['height'] = size.height;
  }
  final profile.PixaProfileEvaluation repeatedDimensions = profile
      .evaluateProfileRun(
        _run(
          refreshRateHz: 120,
          buildP99Micros: 7000,
          rasterP99Micros: 7000,
          overBudgetFrames: 0,
          rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
          liveNetwork: repeatedDimensionsLive,
        ),
        baseline: baseline,
      );
  _expect(
    !repeatedDimensions.releasePassed &&
        repeatedDimensions.supplementalFailures.any(
          (String value) => value.contains('240 unique dimensions'),
        ),
    'live evidence must reject a small repeated dimension table',
  );

  final Map<String, Object?> fixedPayloadLive = _liveNetworkEvidence();
  final List<Object?> fixedPayloadSamples =
      fixedPayloadLive['samples']! as List<Object?>;
  for (final Object? value in fixedPayloadSamples) {
    final Map<String, Object?> sample = value! as Map<String, Object?>;
    sample
      ..['contentSeed'] = 1
      ..['width'] = 320
      ..['height'] = 320
      ..['timedPixaBytes'] = 64 * 1024;
    final Object? rawProbe = sample['identityProbe'];
    if (rawProbe case final Map<String, Object?> probe) {
      probe
        ..['pixaBytes'] = 64 * 1024
        ..['httpBytes'] = 64 * 1024;
    }
  }
  final profile.PixaProfileEvaluation fixedPayload = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
      liveNetwork: fixedPayloadLive,
    ),
    baseline: baseline,
  );
  _expect(
    !fixedPayload.releasePassed &&
        fixedPayload.supplementalFailures.any(
          (String value) => value.contains('diversity'),
        ),
    'live evidence must reject one fixed payload repeated across the corpus',
  );

  final profile.PixaProfileEvaluation malformedLive = profile
      .evaluateProfileRun(
        _run(
          refreshRateHz: 120,
          buildP99Micros: 7000,
          rasterP99Micros: 7000,
          overBudgetFrames: 0,
          rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
          liveNetwork: <String, Object?>{
            'enabled': true,
            'service': 'picsum.photos',
          },
        ),
        baseline: baseline,
      );
  _expect(
    malformedLive.passed,
    'malformed supplemental data must not fail core',
  );
  _expect(
    malformedLive.supplementalFailures.isNotEmpty,
    'malformed supplemental data must be explicitly degraded',
  );

  final profile.PixaProfileEvaluation missingRequestedLive = profile
      .evaluateProfileRun(
        _run(
          refreshRateHz: 120,
          buildP99Micros: 7000,
          rasterP99Micros: 7000,
          overBudgetFrames: 0,
          rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
          liveNetworkRequested: true,
        ),
        baseline: baseline,
      );
  _expect(
    missingRequestedLive.markdown.contains('Supplemental result: **DEGRADED**'),
    'a requested but missing live run must remain visible in the report',
  );

  final profile.PixaProfileEvaluation slowDisplay = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 60,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
    ),
    baseline: baseline,
  );
  _expect(!slowDisplay.passed, 'a 60Hz device must not prove 120Hz acceptance');
  _expect(
    slowDisplay.failures.any((String value) => value.contains('refresh rate')),
    'refresh-rate failure should be actionable',
  );

  final profile.PixaProfileEvaluation janky = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 9100,
      rasterP99Micros: 9200,
      overBudgetFrames: 8,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
    ),
    baseline: baseline,
  );
  _expect(!janky.passed, 'over-budget p99 and missed frames must fail');

  final profile.PixaProfileEvaluation growing = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[
        200 * _mib,
        220 * _mib,
        240 * _mib,
        260 * _mib,
        280 * _mib,
        300 * _mib,
      ],
      finalInflight: 1,
      finalCompletionQueue: 1,
    ),
    baseline: baseline,
  );
  _expect(!growing.passed, 'unbounded RSS or in-flight work must fail');
  _expect(
    growing.failures.any((String value) => value.contains('RSS')),
    'RSS failure should identify memory instability',
  );
  _expect(
    growing.failures.any((String value) => value.contains('in-flight')),
    'scheduler drain failure should be reported',
  );
  _expect(
    growing.failures.any((String value) => value.contains('completion queue')),
    'display completion drain failure should be reported',
  );

  final Map<String, Object?> unstableWarmup = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  (unstableWarmup['memoryWarmup']! as Map<String, Object?>)['stable'] = false;
  final profile.PixaProfileEvaluation unstableWarmupEvaluation = profile
      .evaluateProfileRun(unstableWarmup, baseline: baseline);
  _expect(
    !unstableWarmupEvaluation.passed &&
        unstableWarmupEvaluation.failures.any(
          (String value) => value.contains('warmup'),
        ),
    'memory sampling must not begin before cache warmup reaches a plateau',
  );

  final Map<String, Object?> forgedWarmup = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final Map<String, Object?> forgedWarmupData =
      forgedWarmup['memoryWarmup']! as Map<String, Object?>;
  final List<Object?> forgedWarmupSamples =
      forgedWarmupData['samples']! as List<Object?>;
  for (var index = 0; index < forgedWarmupSamples.length; index += 1) {
    (forgedWarmupSamples[index]!
            as Map<String, Object?>)['decodedRegistryEntries'] =
        100 + index * 20;
  }
  final profile.PixaProfileEvaluation forgedWarmupEvaluation = profile
      .evaluateProfileRun(forgedWarmup, baseline: baseline);
  _expect(
    !forgedWarmupEvaluation.passed &&
        forgedWarmupEvaluation.failures.any(
          (String value) => value.contains('warmup samples'),
        ),
    'the verifier must recompute warmup stability from measured samples',
  );

  final Map<String, Object?> underfilledWarmup = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final List<Object?> underfilledWarmupSamples =
      ((underfilledWarmup['memoryWarmup']! as Map<String, Object?>)['samples']!
          as List<Object?>);
  for (final Object? value in underfilledWarmupSamples) {
    final Map<String, Object?> sample = value! as Map<String, Object?>;
    sample
      ..['decodedCacheEntries'] = 40
      ..['decodedRegistryEntries'] = 40;
  }
  final profile.PixaProfileEvaluation underfilledWarmupEvaluation = profile
      .evaluateProfileRun(underfilledWarmup, baseline: baseline);
  _expect(
    !underfilledWarmupEvaluation.passed &&
        underfilledWarmupEvaluation.failures.any(
          (String value) => value.contains('decoded cache capacity'),
        ),
    'memory warmup must exercise most of the configured decoded cache',
  );

  final Map<String, Object?> activeMemorySample = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  ((activeMemorySample['memorySamples']! as List<Object?>)[1]!
          as Map<String, Object?>)['inflightRequests'] =
      1;
  final profile.PixaProfileEvaluation activeMemoryEvaluation = profile
      .evaluateProfileRun(activeMemorySample, baseline: baseline);
  _expect(
    !activeMemoryEvaluation.passed &&
        activeMemoryEvaluation.failures.any(
          (String value) => value.contains('sample 1'),
        ),
    'every plateau sample must be captured after pipeline work drains',
  );

  final Map<String, Object?> inconsistentMemoryAccounting = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  ((inconsistentMemoryAccounting['memorySamples']! as List<Object?>).first!
          as Map<String, Object?>)['processedMemoryBytes'] =
      9 * _mib;
  final profile.PixaProfileEvaluation inconsistentMemoryEvaluation = profile
      .evaluateProfileRun(inconsistentMemoryAccounting, baseline: baseline);
  _expect(
    !inconsistentMemoryEvaluation.passed &&
        inconsistentMemoryEvaluation.failures.any(
          (String value) => value.contains('memory accounting'),
        ),
    'the verifier must reject incomplete Rust cache byte accounting',
  );

  final Map<String, Object?> growingRegistry = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[
      220 * _mib,
      221 * _mib,
      221 * _mib,
      221 * _mib,
      221 * _mib,
      221 * _mib,
    ],
  );
  final List<Object?> registrySamples =
      growingRegistry['memorySamples']! as List<Object?>;
  for (var index = 0; index < registrySamples.length; index += 1) {
    (registrySamples[index]!
            as Map<String, Object?>)['decodedRegistryEntries'] =
        100 + index * 20;
  }
  final profile.PixaProfileEvaluation registryLeak = profile.evaluateProfileRun(
    growingRegistry,
    baseline: baseline,
  );
  _expect(
    !registryLeak.passed &&
        registryLeak.failures.any(
          (String value) => value.contains('Decoded registry'),
        ),
    'decoded registry growth must fail even below an arbitrary entry cap',
  );

  final Map<String, Object?> networkContaminated = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final List<Object?> contaminatedScenarios =
      networkContaminated['scenarios']! as List<Object?>;
  (contaminatedScenarios[1]! as Map<String, Object?>)['loopbackRequests'] = 3;
  final profile.PixaProfileEvaluation contaminated = profile.evaluateProfileRun(
    networkContaminated,
    baseline: baseline,
  );
  _expect(!contaminated.passed, 'cache-hit evidence must not use the network');
  _expect(
    contaminated.failures.any(
      (String value) => value.contains('encoded_memory_hit_burst'),
    ),
    'cache-hit contamination should name the failing scenario',
  );

  final Map<String, Object?> warmedCold = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final Map<String, Object?> coldScenario =
      (warmedCold['scenarios']! as List<Object?>).first!
          as Map<String, Object?>;
  (coldScenario['cacheBefore']! as Map<String, Object?>)['memoryBytes'] = 1;
  final profile.PixaProfileEvaluation warmedColdEvaluation = profile
      .evaluateProfileRun(warmedCold, baseline: baseline);
  _expect(
    !warmedColdEvaluation.passed &&
        warmedColdEvaluation.failures.any(
          (String value) => value.contains('cold_network_loopback'),
        ),
    'cold evidence must prove empty encoded and decoded caches at capture start',
  );

  final profile.PixaProfileEvaluation sameRunBaseline = profile
      .evaluateProfileRun(passing, baseline: passing);
  _expect(
    !sameRunBaseline.passed,
    'one raw artifact must not be accepted as its own baseline',
  );

  final Map<String, Object?> failingBaseline = _run(
    refreshRateHz: 120,
    buildP99Micros: 9000,
    rasterP99Micros: 9000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  final profile.PixaProfileEvaluation invalidBaseline = profile
      .evaluateProfileRun(passing, baseline: failingBaseline);
  _expect(
    !invalidBaseline.passed,
    'a baseline must pass the same core performance and memory gates',
  );

  final Map<String, Object?> dirtyRun = _run(
    refreshRateHz: 120,
    buildP99Micros: 7000,
    rasterP99Micros: 7000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
    gitCommit: '$_fixtureCommit-dirty',
    gitTreeState: 'dirty',
  );
  final profile.PixaProfileEvaluation dirty = profile.evaluateProfileRun(
    dirtyRun,
    baseline: baseline,
    currentGitCommit: _fixtureCommit,
  );
  _expect(
    !dirty.passed,
    'dirty profile evidence must never pass release gates',
  );

  final profile.PixaProfileEvaluation staleHead = profile.evaluateProfileRun(
    _run(
      refreshRateHz: 120,
      buildP99Micros: 7000,
      rasterP99Micros: 7000,
      overBudgetFrames: 0,
      rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
      gitCommit: 'ffffffffffffffffffffffffffffffffffffffff',
    ),
    baseline: baseline,
    currentGitCommit: _fixtureCommit,
  );
  _expect(!staleHead.passed, 'stale non-HEAD evidence must not pass');

  final Map<String, Object?> tamperedThresholds = _run(
    refreshRateHz: 120,
    buildP99Micros: 9000,
    rasterP99Micros: 9000,
    overBudgetFrames: 0,
    rssSamples: <int>[220 * _mib, 221 * _mib, 221 * _mib, 221 * _mib],
  );
  (tamperedThresholds['thresholds']! as Map<String, Object?>)
    ..['frameBudgetMicros'] = 100000
    ..['maximumOverBudgetRatio'] = 1.0;
  final profile.PixaProfileEvaluation tampered = profile.evaluateProfileRun(
    tamperedThresholds,
    baseline: baseline,
  );
  _expect(
    !tampered.passed &&
        tampered.failures.any(
          (String value) => value.contains('verifier-owned'),
        ),
    'raw evidence must not be able to relax verifier-owned thresholds',
  );

  final Directory temp = await Directory.systemTemp.createTemp(
    'pixa-profile-report-self-test-',
  );
  try {
    final File output = File('${temp.path}/nested/report.md');
    await profile.writeProfileReportAtomically(output.path, 'first report');
    await profile.writeProfileReportAtomically(output.path, 'second report');
    _expect(
      await output.readAsString() == 'second report',
      'report replacement must publish the complete new content',
    );
    _expect(
      temp.listSync(recursive: true).whereType<File>().length == 1,
      'atomic report writes must not leave temporary files behind',
    );
  } finally {
    await temp.delete(recursive: true);
  }

  stdout.writeln('Pixa profile report self-test passed.');
}

const int _mib = 1024 * 1024;
const String _fixtureCommit = '0123456789abcdef0123456789abcdef01234567';
var _runSerial = 0;

Map<String, Object?> _run({
  required double refreshRateHz,
  required int buildP99Micros,
  required int rasterP99Micros,
  required int overBudgetFrames,
  required List<int> rssSamples,
  int finalInflight = 0,
  int finalCompletionQueue = 0,
  Map<String, Object?>? liveNetwork,
  bool liveNetworkRequested = false,
  String? runId,
  String gitCommit = _fixtureCommit,
  String gitTreeState = 'clean',
}) {
  const List<String> scenarios = <String>[
    'cold_network_loopback',
    'encoded_memory_hit_burst',
    'disk_hit_burst',
    'decoded_hit_burst',
    'rapid_bidirectional_scroll',
    'prefetch_cancellation_completion_pacing',
  ];
  return <String, Object?>{
    'schemaVersion': 3,
    'evidenceLevel': 'full',
    'toolVersion': 'pixa-profile-v3',
    'runId': runId ?? 'fixture-run-${_runSerial++}',
    'capturedAtUtc': '2026-07-10T12:00:00.000Z',
    'mode': 'profile',
    'environment': <String, Object?>{
      'deviceLabel': 'fixture-120hz-class',
      'deviceIdHash': 'b'.padLeft(64, 'b'),
      'platform': 'ios',
      'osVersion': 'fixture-os',
      'refreshRateHz': refreshRateHz,
      'flutterVersion': '3.44.0',
      'dartVersion': '3.12.0',
      'rustVersion': '1.88.0',
      'gitCommit': gitCommit,
      'gitTreeState': gitTreeState,
      'viewportPhysicalWidth': 3456,
      'viewportPhysicalHeight': 2234,
      'devicePixelRatio': 2.0,
    },
    'workload': <String, Object?>{
      'corpusId': 'loopback-mixed-v1',
      'corpusSha256': 'a'.padLeft(64, 'a'),
      'imageFormat': 'mixed',
      'imageWidth': 1024,
      'imageHeight': 1024,
      'encodedBytes': 39497,
      'imageCorpus': <Object?>[
        <String, Object?>{
          'id': 'app-icon-png',
          'mimeType': 'image/png',
          'width': 1024,
          'height': 1024,
          'encodedBytes': 39497,
        },
        <String, Object?>{
          'id': 'pattern-bmp-192x128',
          'mimeType': 'image/bmp',
          'width': 192,
          'height': 128,
          'encodedBytes': 73782,
        },
      ],
      'itemCount': 2000,
      'cacheState': 'scenario-specific',
      'networkConcurrency': 6,
      'decodeConcurrency': 2,
      'memoryCacheBudgetBytes': 48 * _mib,
      'decodedCacheBudgetBytes': 64 * _mib,
      'decodedCacheEntryBudget': 256,
    },
    'thresholds': <String, Object?>{
      'frameBudgetMicros': 8333,
      'minimumRefreshRateHz': 119.0,
      'minimumFramesPerScenario': 120,
      'maximumOverBudgetRatio': 0.01,
      'maximumRssPlateauGrowthBytes': 16 * _mib,
      'maximumRssSlopeBytesPerCycle': 1 * _mib,
      'maximumRegistryPlateauGrowthEntries': 32,
      'maximumRegistrySlopeEntriesPerCycle': 4,
    },
    'memoryWarmup': <String, Object?>{
      'stable': true,
      'cycles': 4,
      'requiredConsecutiveStableSamples': 3,
      'samples': <Object?>[
        for (var index = 0; index < 4; index += 1)
          <String, Object?>{
            'cycle': index,
            'runtimeMemoryBytes': 40 * _mib,
            'encodedMemoryBytes': 32 * _mib,
            'processedMemoryBytes': 8 * _mib,
            'encodedMemoryEntries': 192,
            'processedMemoryEntries': 64,
            'decodedCacheEntries': 256,
            'decodedRegistryEntries': 256,
            'queueDepth': 0,
            'inflightRequests': 0,
            'prefetchPending': 0,
            'prefetchActive': 0,
            'liveOwnedBufferHandles': 0,
            'liveProgressSessions': 0,
            'completionQueueDepth': 0,
          },
      ],
    },
    'scenarios': <Object?>[
      for (final String name in scenarios)
        <String, Object?>{
          'name': name,
          'frameCount': 240,
          'build': <String, Object?>{
            'p90Micros': buildP99Micros - 1000,
            'p99Micros': buildP99Micros,
            'worstMicros': buildP99Micros + 500,
          },
          'raster': <String, Object?>{
            'p90Micros': rasterP99Micros - 1000,
            'p99Micros': rasterP99Micros,
            'worstMicros': rasterP99Micros + 500,
          },
          'overBudgetFrames': overBudgetFrames,
          'loopbackRequests': switch (name) {
            'encoded_memory_hit_burst' ||
            'disk_hit_burst' ||
            'decoded_hit_burst' => 0,
            _ => 200,
          },
          'cacheDelta': <String, Object?>{
            'memoryHits': name == 'encoded_memory_hit_burst' ? 120 : 0,
            'diskHits': name == 'disk_hit_burst' ? 120 : 0,
            'memoryMisses': name == 'encoded_memory_hit_burst' ? 0 : 200,
            'diskMisses': name == 'disk_hit_burst' ? 0 : 200,
            'diskWrites': name == 'cold_network_loopback' ? 200 : 0,
          },
          'cacheBefore': <String, Object?>{
            'memoryBytes': 0,
            'decodedEntries': 0,
            'decodedBytes': 0,
          },
          'decodedHits': name == 'decoded_hit_burst' ? 120 : 0,
          'schedulerDelta': <String, Object?>{
            'started': 200,
            'completed': 192,
            'cancelled': name == 'prefetch_cancellation_completion_pacing'
                ? 8
                : 0,
            'backpressureDropped': 0,
          },
          'prefetchDelta': <String, Object?>{
            'skippedPending': name == 'prefetch_cancellation_completion_pacing'
                ? 12
                : 0,
          },
          'completionPacing': <String, Object?>{
            'configuredMaxPerFrame': 3,
            'maxReleasedPerFrame': 3,
            'maxQueueDepth': 12,
            'finalQueueDepth': 0,
          },
        },
    ],
    'memorySamples': <Object?>[
      for (var index = 0; index < rssSamples.length; index += 1)
        <String, Object?>{
          'cycle': index,
          'rssBytes': rssSamples[index],
          'runtimeMemoryBytes': 40 * _mib,
          'encodedMemoryBytes': 32 * _mib,
          'processedMemoryBytes': 8 * _mib,
          'encodedMemoryEntries': 192,
          'processedMemoryEntries': 64,
          'decodedCacheBytes': 56 * _mib,
          'decodedCacheEntries': 256,
          'decodedLiveEntries': 12,
          'decodedRegistryEntries': 256,
          'queueDepth': 0,
          'inflightRequests': index == rssSamples.length - 1
              ? finalInflight
              : 0,
          'prefetchPending': 0,
          'prefetchActive': 0,
          'liveOwnedBufferHandles': 0,
          'liveProgressSessions': 0,
          'completionQueueDepth': index == rssSamples.length - 1
              ? finalCompletionQueue
              : 0,
        },
    ],
    'liveNetworkRequested': liveNetworkRequested || liveNetwork != null,
    'liveNetwork': ?liveNetwork,
  };
}

Map<String, Object?> _liveNetworkEvidence({int sampleCount = 240}) {
  return <String, Object?>{
    'enabled': true,
    'service': 'picsum.photos',
    'corpusSeed': 20260710,
    'corpusSamples': 240,
    'registeredSamples': sampleCount,
    'observedSamples': sampleCount,
    'requestedSamples': sampleCount,
    'completedSamples': sampleCount,
    'failedSamples': 0,
    'cancelledSamples': 0,
    'unexpectedCacheHits': 0,
    'widgetFailures': <Object?>[],
    'cacheState': 'network/no-store',
    'frameScenario': <String, Object?>{
      'name': 'seeded_picsum_live_network',
      'frameCount': 720,
      'build': <String, Object?>{
        'p90Micros': 4200,
        'p99Micros': 7100,
        'worstMicros': 9400,
      },
      'raster': <String, Object?>{
        'p90Micros': 3900,
        'p99Micros': 6900,
        'worstMicros': 9100,
      },
      'overBudgetFrames': 2,
      'loopbackRequests': 0,
      'cacheDelta': <String, Object?>{
        'memoryHits': 0,
        'diskHits': 0,
        'memoryMisses': 37,
        'diskMisses': 37,
        'diskWrites': 0,
      },
    },
    'samples': <Object?>[
      for (var index = 0; index < sampleCount; index += 1)
        <String, Object?>{
          'index': index,
          'contentSeed': 20260710000 + index,
          'width': _liveSizeAt(index).width,
          'height': _liveSizeAt(index).height,
          'requested': true,
          'observed': true,
          'timedPixaBytes': (64 + index) * 1024,
          'timedPixaLatencyMicros': 42000 + index * 1000,
          'cacheState': 'network/no-store',
          'outcome': 'completed',
          if (index < 8)
            'identityProbe': <String, Object?>{
              'kind': 'independent-pixa-http-identity',
              'pixaBytes': (64 + index) * 1024,
              'pixaLatencyMicros': 40000 + index * 1000,
              'pixaMimeType': 'image/jpeg',
              'pixaSha256': index.toRadixString(16).padLeft(64, '0'),
              'httpStatusCode': 200,
              'httpRedirectCount': 1,
              'httpBytes': (64 + index) * 1024,
              'httpLatencyMicros': 41000 + index * 1000,
              'httpMimeType': 'image/jpeg',
              'httpSha256': index.toRadixString(16).padLeft(64, '0'),
              'digestMatch': true,
            },
        },
    ],
  };
}

({int width, int height}) _liveSizeAt(int index) {
  if (index.isEven) {
    return (width: 96 + index, height: 1024 - index);
  }
  return (width: 1024 - index, height: 96 + index);
}

const List<({int width, int height})> _legacyLiveSizes =
    <({int width, int height})>[
      (width: 96, height: 96),
      (width: 128, height: 192),
      (width: 192, height: 128),
      (width: 240, height: 320),
      (width: 320, height: 240),
      (width: 320, height: 320),
      (width: 480, height: 270),
      (width: 270, height: 480),
      (width: 640, height: 480),
      (width: 1024, height: 576),
    ];

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
