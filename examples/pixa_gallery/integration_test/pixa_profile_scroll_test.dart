import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FlutterView, FrameTiming;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';
import 'package:pixa_gallery/performance/profile_live_network_corpus.dart';
import 'package:pixa_gallery/performance/profile_live_network_evidence.dart';
import 'package:pixa_gallery/performance/profile_loopback_corpus.dart';
import 'package:pixa_gallery/performance/profile_scroll_harness.dart';

part 'pixa_profile_scroll_support.dart';
part 'pixa_profile_scroll_actions.dart';

const int _mib = 1024 * 1024;
const int _frameBudgetMicros = 8333;
const int _memoryCacheBudget = 48 * _mib;
const int _decodedCacheBudget = 64 * _mib;
const int _decodedCacheEntryBudget = 256;
const int _profileNetworkConcurrency = int.fromEnvironment(
  'PIXA_PROFILE_NETWORK_CONCURRENCY',
  defaultValue: 6,
);
const bool _includeLiveNetwork = bool.fromEnvironment(
  'PIXA_PROFILE_LIVE_NETWORK',
);
const int _liveNetworkCorpusSeed = 20260710;
const int _liveNetworkItemCount = 240;
const int _cacheBurstStart = 1760;
const int _cacheBurstEnd = 2000;

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile gallery scroll remains frame and memory bounded', (
    WidgetTester tester,
  ) async {
    expect(
      kProfileMode,
      isTrue,
      reason: 'Run this acceptance with flutter drive --profile.',
    );
    final ByteData fixtureData = await rootBundle.load(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
      'Icon-App-1024x1024@1x.png',
    );
    final Uint8List fixture = fixtureData.buffer.asUint8List(
      fixtureData.offsetInBytes,
      fixtureData.lengthInBytes,
    );
    final List<ProfileLoopbackImage> loopbackCorpus =
        buildProfileLoopbackCorpus(fixture);
    final _LoopbackImageServer server = await _LoopbackImageServer.start(
      loopbackCorpus,
    );
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-profile-scroll-',
    );
    const ProfileLiveNetworkCorpus liveCorpus = ProfileLiveNetworkCorpus(
      seed: _liveNetworkCorpusSeed,
      itemCount: _liveNetworkItemCount,
    );
    final ProfileLiveNetworkRecorder? liveRecorder = _includeLiveNetwork
        ? ProfileLiveNetworkRecorder(corpus: liveCorpus)
        : null;
    final List<PixaRequest> liveRequests = <PixaRequest>[
      if (liveRecorder != null)
        for (final ProfileLiveNetworkSample sample in liveCorpus.samples)
          _liveNetworkRequest(liveRecorder, sample),
    ];
    addTearDown(() async {
      await server.close();
      if (cacheRoot.existsSync()) {
        await cacheRoot.delete(recursive: true);
      }
    });

    await Pixa.configure(
      PixaConfig(
        memoryCacheBytes: _memoryCacheBudget,
        diskCacheBytes: 128 * _mib,
        networkConcurrency: _profileNetworkConcurrency,
        decodeConcurrency: 2,
        maxImageCompletionsPerFrame: 3,
        maxQueuedRuntimeLoads: 128,
        maxQueuedDecodes: 24,
        decodedCacheMaximumSize: _decodedCacheEntryBudget,
        decodedCacheMaximumSizeBytes: _decodedCacheBudget,
        cacheRootPath: cacheRoot.path,
        observers: <PixaObserver>[?liveRecorder],
      ),
    );
    await Pixa.clearCache();

    final GlobalKey<ProfileScrollHarnessState> harnessKey =
        GlobalKey<ProfileScrollHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ProfileScrollHarness(
          key: harnessKey,
          origin: server.origin,
          prefetchEnabled: false,
          initiallyLoading: false,
        ),
      ),
    );
    final ProfileScrollHarnessState harness = await _waitForHarnessState(
      tester,
      harnessKey,
    );
    await harness.waitUntilAttached();

    final List<Map<String, Object?>> scenarios = <Map<String, Object?>>[];
    var requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'cold_network_loopback',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        action: () async {
          harness.startLoading();
          await tester.pump();
          await harness.scrollToEnd(const Duration(seconds: 6));
        },
      ),
    );

    harness.stopLoading();
    await tester.pump();
    await _waitForDrain(harness);
    await _seedDiskCache(harness);
    await _seedEncodedMemoryCache(
      harness,
      start: _cacheBurstStart,
      end: _cacheBurstEnd,
    );
    await Pixa.clearCache(encoded: false);
    harness.rebuildSameRequests();
    harness.jumpToFraction(0.9);
    await tester.pump();
    requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'encoded_memory_hit_burst',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        action: () async {
          harness.startLoading();
          await tester.pump();
          await _exerciseCacheBurst(harness);
        },
      ),
    );

    harness.stopLoading();
    await tester.pump();
    await _waitForDrain(harness);
    await Pixa.trimMemory(level: PixaMemoryTrimLevel.critical);
    harness.rebuildSameRequests();
    harness.jumpToFraction(0.9);
    await tester.pump();
    requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'disk_hit_burst',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        action: () async {
          harness.startLoading();
          await tester.pump();
          await _exerciseCacheBurst(harness);
        },
      ),
    );

    harness.stopLoading();
    await tester.pump();
    await _waitForDrain(harness);
    final int decodedHits = await _countDecodedHits(
      harness,
      start: _cacheBurstStart,
      end: _cacheBurstEnd,
    );
    harness.rebuildSameRequests();
    harness.jumpToFraction(0.9);
    await tester.pump();
    requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'decoded_hit_burst',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        decodedHits: decodedHits,
        action: () async {
          harness.startLoading();
          await tester.pump();
          await _exerciseCacheBurst(harness);
        },
      ),
    );

    requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'rapid_bidirectional_scroll',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        action: () async {
          for (var cycle = 0; cycle < 3; cycle += 1) {
            await harness.scrollToEnd(const Duration(milliseconds: 900));
            await harness.scrollToStart(const Duration(milliseconds: 900));
          }
        },
      ),
    );

    harness.stopLoading();
    await tester.pump();
    await _waitForDrain(harness);
    await Pixa.clearCache();
    harness.beginColdGeneration();
    harness.setPrefetchEnabled(true);
    server.responseDelay = const Duration(milliseconds: 80);
    await tester.pump();
    requestsBefore = server.requestCount;
    scenarios.add(
      await _captureScenario(
        binding,
        name: 'prefetch_cancellation_completion_pacing',
        harness: harness,
        requestsBefore: requestsBefore,
        requestCount: () => server.requestCount,
        action: () async {
          await _exercisePipelineCancellation(harness);
          final Future<void> supersession =
              _exercisePredictivePrefetchSupersession(harness);
          harness.startLoading();
          await tester.pump();
          await harness.scrollToEnd(const Duration(seconds: 4));
          await supersession;
        },
      ),
    );
    server.responseDelay = const Duration(milliseconds: 3);

    await _seedDecodedCacheForMemory(harness);
    final Map<String, Object?> memoryWarmup = await _warmMemoryPlateau(harness);
    final List<Map<String, Object?>> memorySamples = <Map<String, Object?>>[];
    for (var cycle = 0; cycle < 10; cycle += 1) {
      await harness.scrollToEnd(const Duration(milliseconds: 750));
      await harness.scrollToStart(const Duration(milliseconds: 750));
      await _waitForDrain(harness);
      memorySamples.add(_memorySample(cycle, harness));
    }

    expect(server.errors, isEmpty, reason: server.errors.join('\n'));
    expect(harness.failures, isEmpty, reason: harness.failures.join('\n'));
    Map<String, Object?>? liveNetworkEvidence;
    if (liveRecorder != null) {
      await Pixa.clearCache();
      final GlobalKey<ProfileScrollHarnessState> liveHarnessKey =
          GlobalKey<ProfileScrollHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: ProfileScrollHarness(
            key: liveHarnessKey,
            itemCount: liveRequests.length,
            prefetchEnabled: false,
            initiallyLoading: false,
            requestBuilder: (int index, int generation) => liveRequests[index],
          ),
        ),
      );
      final ProfileScrollHarnessState liveHarness = await _waitForHarnessState(
        tester,
        liveHarnessKey,
      );
      await liveHarness.waitUntilAttached();
      final Map<String, Object?> liveFrameScenario = await _captureScenario(
        binding,
        name: 'seeded_picsum_live_network',
        harness: liveHarness,
        requestsBefore: 0,
        requestCount: () => 0,
        action: () async {
          liveHarness.startLoading();
          await tester.pump();
          await liveHarness.scrollToEnd(const Duration(seconds: 12));
        },
      );
      await _probeCompletedLiveSamples(liveRecorder, liveCorpus);
      liveNetworkEvidence = <String, Object?>{
        ...liveRecorder.buildEvidence(frameScenario: liveFrameScenario),
        'widgetFailures': liveHarness.failures,
      };
    }
    final FlutterView view = binding.platformDispatcher.views.single;
    final double refreshRate = view.display.refreshRate;
    binding.reportData = <String, dynamic>{
      'schemaVersion': 3,
      'evidenceLevel': 'full',
      'toolVersion': 'pixa-profile-v3',
      'runId': const String.fromEnvironment(
        'PIXA_PROFILE_RUN_ID',
        defaultValue: 'unknown',
      ),
      'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'mode': 'profile',
      'environment': <String, Object?>{
        'deviceLabel': const String.fromEnvironment(
          'PIXA_PROFILE_DEVICE_LABEL',
          defaultValue: 'unknown',
        ),
        'deviceIdHash': const String.fromEnvironment(
          'PIXA_PROFILE_DEVICE_ID_HASH',
          defaultValue: 'unknown',
        ),
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'refreshRateHz': refreshRate,
        'flutterVersion': const String.fromEnvironment(
          'PIXA_FLUTTER_VERSION',
          defaultValue: 'unknown',
        ),
        'dartVersion': Platform.version,
        'rustVersion': const String.fromEnvironment(
          'PIXA_RUST_VERSION',
          defaultValue: 'unknown',
        ),
        'gitCommit': const String.fromEnvironment(
          'PIXA_GIT_COMMIT',
          defaultValue: 'unknown',
        ),
        'gitTreeState': const String.fromEnvironment(
          'PIXA_GIT_TREE_STATE',
          defaultValue: 'unknown',
        ),
        'viewportPhysicalWidth': view.physicalSize.width.round(),
        'viewportPhysicalHeight': view.physicalSize.height.round(),
        'devicePixelRatio': view.devicePixelRatio,
      },
      'workload': <String, Object?>{
        'corpusId': 'loopback-mixed-v1',
        'corpusSha256': profileLoopbackCorpusSha256(loopbackCorpus),
        'imageCorpus': <Object?>[
          for (final ProfileLoopbackImage image in loopbackCorpus)
            image.toJson(),
        ],
        'itemCount': profileItemCount,
        'cacheState':
            'cold loopback, encoded/disk/decoded hits, rapid reversal',
        'networkConcurrency': _profileNetworkConcurrency,
        'decodeConcurrency': 2,
        'memoryCacheBudgetBytes': _memoryCacheBudget,
        'decodedCacheBudgetBytes': _decodedCacheBudget,
        'decodedCacheEntryBudget': _decodedCacheEntryBudget,
        'loopbackRequests': server.requestCount,
      },
      'thresholds': <String, Object?>{
        'frameBudgetMicros': _frameBudgetMicros,
        'minimumRefreshRateHz': 119.0,
        'minimumFramesPerScenario': 120,
        'maximumOverBudgetRatio': 0.01,
        'maximumRssPlateauGrowthBytes': 16 * _mib,
        'maximumRssSlopeBytesPerCycle': 1 * _mib,
        'maximumRegistryPlateauGrowthEntries': 32,
        'maximumRegistrySlopeEntriesPerCycle': 4,
      },
      'memoryWarmup': memoryWarmup,
      'scenarios': scenarios,
      'memorySamples': memorySamples,
      'liveNetworkRequested': _includeLiveNetwork,
      'liveNetwork': ?liveNetworkEvidence,
    };

    await tester.pumpWidget(const SizedBox.shrink());
    await Pixa.clearCache();
  });
}
