import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa_gallery/performance/profile_live_network_corpus.dart';
import 'package:pixa_gallery/performance/profile_live_network_evidence.dart';

void main() {
  test('live recorder separates timed Pixa evidence from identity probes', () {
    const ProfileLiveNetworkCorpus corpus = ProfileLiveNetworkCorpus(
      seed: 20260710,
      itemCount: 1,
    );
    final ProfileLiveNetworkSample sample = corpus.sampleAt(0);
    final PixaRequest request = PixaRequest(
      source: PixaSource.network(sample.uri),
      cacheNamespace: profileLiveNetworkCacheNamespace,
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    final ProfileLiveNetworkRecorder recorder = ProfileLiveNetworkRecorder(
      corpus: corpus,
    )..register(request: request, sample: sample);

    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.request,
        name: 'request.start',
        request: request,
      ),
    );
    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.fetch,
        name: 'fetch.complete',
        request: request,
        progress: const PixaProgress(
          requestId: 1,
          stage: PixaStage.fetch,
          receivedBytes: 65536,
          expectedBytes: 65536,
        ),
      ),
    );
    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.complete,
        name: 'runtime.load.complete',
        request: request,
        durationMicros: 40000,
        attributes: const <String, Object?>{'bytes': 65536},
      ),
    );
    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.complete,
        name: 'request.complete',
        request: request,
        durationMicros: 42000,
      ),
    );
    recorder.recordProbe(
      const ProfileLiveNetworkProbe(
        sampleIndex: 0,
        pixaBytes: 65536,
        pixaLatencyMicros: 40000,
        pixaMimeType: 'image/jpeg',
        pixaSha256: 'same-digest',
        httpStatusCode: 200,
        httpRedirectCount: 1,
        httpBytes: 65536,
        httpLatencyMicros: 41000,
        httpMimeType: 'image/jpeg',
        httpSha256: 'same-digest',
      ),
    );

    final Map<String, Object?> evidence = recorder.buildEvidence(
      frameScenario: _frameScenario,
    );
    final List<Object?> samples = evidence['samples']! as List<Object?>;
    final Map<String, Object?> measured =
        samples.single! as Map<String, Object?>;

    expect(evidence['registeredSamples'], 1);
    expect(evidence['requestedSamples'], 1);
    expect(evidence['observedSamples'], 1);
    expect(evidence['completedSamples'], 1);
    expect(evidence['failedSamples'], 0);
    expect(evidence['unexpectedCacheHits'], 0);
    expect(measured['timedPixaBytes'], 65536);
    expect(measured['timedPixaLatencyMicros'], 42000);
    expect(measured['cacheState'], 'network/no-store');
    expect(measured['outcome'], 'completed');
    final Map<String, Object?> probe =
        measured['identityProbe']! as Map<String, Object?>;
    expect(probe['kind'], 'independent-pixa-http-identity');
    expect(probe['pixaBytes'], 65536);
    expect(probe['pixaMimeType'], 'image/jpeg');
    expect(probe['httpStatusCode'], 200);
    expect(probe['httpRedirectCount'], 1);
    expect(probe['httpBytes'], 65536);
    expect(probe['httpMimeType'], 'image/jpeg');
    expect(probe['digestMatch'], isTrue);
  });

  test(
    'live recorder preserves the full registered corpus and unique indices',
    () {
      const ProfileLiveNetworkCorpus corpus = ProfileLiveNetworkCorpus(
        seed: 20260710,
        itemCount: 3,
      );
      final ProfileLiveNetworkRecorder recorder = ProfileLiveNetworkRecorder(
        corpus: corpus,
      );
      for (final ProfileLiveNetworkSample sample in corpus.samples) {
        recorder.register(request: _requestFor(sample), sample: sample);
      }

      expect(
        () => recorder.register(
          request: _requestFor(corpus.sampleAt(0)),
          sample: corpus.sampleAt(0),
        ),
        throwsStateError,
      );

      final Map<String, Object?> evidence = recorder.buildEvidence(
        frameScenario: _frameScenario,
      );
      final List<Object?> samples = evidence['samples']! as List<Object?>;
      expect(evidence['registeredSamples'], 3);
      expect(evidence['requestedSamples'], 0);
      expect(evidence['observedSamples'], 0);
      expect(samples, hasLength(3));
      expect(
        samples.map(
          (Object? value) => (value! as Map<String, Object?>)['index'],
        ),
        <int>[0, 1, 2],
      );
    },
  );

  test('live recorder exposes cache contamination and typed failure', () {
    const ProfileLiveNetworkCorpus corpus = ProfileLiveNetworkCorpus(
      seed: 20260710,
      itemCount: 1,
    );
    final ProfileLiveNetworkSample sample = corpus.sampleAt(0);
    final PixaRequest request = PixaRequest(
      source: PixaSource.network(sample.uri),
      cacheNamespace: profileLiveNetworkCacheNamespace,
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    final ProfileLiveNetworkRecorder recorder = ProfileLiveNetworkRecorder(
      corpus: corpus,
    )..register(request: request, sample: sample);

    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.cacheLookup,
        name: 'cache.memory.hit',
        request: request,
      ),
    );
    recorder.onPixaEvent(
      PixaEvent(
        requestId: 1,
        stage: PixaStage.fetch,
        name: 'request.failure',
        request: request,
        failure: PixaFailure(
          requestId: 1,
          stage: PixaStage.fetch,
          safeMessage: 'network unavailable',
          retryability: PixaRetryability.retryable,
        ),
      ),
    );

    final Map<String, Object?> evidence = recorder.buildEvidence(
      frameScenario: _frameScenario,
    );
    final Map<String, Object?> measured =
        (evidence['samples']! as List<Object?>).single! as Map<String, Object?>;

    expect(evidence['completedSamples'], 0);
    expect(evidence['failedSamples'], 1);
    expect(evidence['unexpectedCacheHits'], 1);
    expect(measured['cacheState'], 'unexpected-memory-hit');
    expect(measured['outcome'], 'failed');
    expect(measured['safeError'], 'network unavailable');
  });
}

PixaRequest _requestFor(ProfileLiveNetworkSample sample) {
  return PixaRequest(
    source: PixaSource.network(sample.uri),
    cacheNamespace: profileLiveNetworkCacheNamespace,
    cachePolicy: const PixaCachePolicy.noStore(),
  );
}

const Map<String, Object?> _frameScenario = <String, Object?>{
  'name': 'seeded_picsum_live_network',
  'frameCount': 240,
  'build': <String, Object?>{
    'p90Micros': 3000,
    'p99Micros': 7000,
    'worstMicros': 9000,
  },
  'raster': <String, Object?>{
    'p90Micros': 3000,
    'p99Micros': 7000,
    'worstMicros': 9000,
  },
  'overBudgetFrames': 1,
};
