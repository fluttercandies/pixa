import 'dart:math' as math;

import 'package:pixa/pixa.dart';

import 'profile_live_network_corpus.dart';

const String profileLiveNetworkCacheNamespace = 'pixa-profile-live-network';

/// Independent Pixa and HTTP identity evidence for one corpus sample.
final class ProfileLiveNetworkProbe {
  const ProfileLiveNetworkProbe({
    required this.sampleIndex,
    required this.pixaBytes,
    required this.pixaLatencyMicros,
    required this.pixaMimeType,
    required this.pixaSha256,
    required this.httpStatusCode,
    required this.httpRedirectCount,
    required this.httpBytes,
    required this.httpLatencyMicros,
    required this.httpMimeType,
    required this.httpSha256,
    this.pixaSafeError,
    this.httpSafeError,
  });

  final int sampleIndex;
  final int pixaBytes;
  final int pixaLatencyMicros;
  final String pixaMimeType;
  final String pixaSha256;
  final int httpStatusCode;
  final int httpRedirectCount;
  final int httpBytes;
  final int httpLatencyMicros;
  final String httpMimeType;
  final String httpSha256;
  final String? pixaSafeError;
  final String? httpSafeError;

  bool get digestMatch => pixaSha256.isNotEmpty && pixaSha256 == httpSha256;
}

/// Records timed Pixa events and separate representative identity probes.
final class ProfileLiveNetworkRecorder implements PixaObserver {
  ProfileLiveNetworkRecorder({required this.corpus});

  final ProfileLiveNetworkCorpus corpus;
  final Map<String, _LiveRecord> _recordsByCacheKey = <String, _LiveRecord>{};
  final Map<int, _LiveRecord> _recordsByIndex = <int, _LiveRecord>{};
  int _unexpectedCacheHits = 0;

  void register({
    required PixaRequest request,
    required ProfileLiveNetworkSample sample,
  }) {
    if (corpus.sampleAt(sample.index) != sample) {
      throw ArgumentError.value(
        sample,
        'sample',
        'must belong to the configured live-network corpus',
      );
    }
    if (_recordsByIndex.containsKey(sample.index)) {
      throw StateError(
        'Live-network sample ${sample.index} was registered twice.',
      );
    }
    if (_recordsByCacheKey.containsKey(request.cacheKey.value)) {
      throw StateError('Live-network request cache key was registered twice.');
    }
    final _LiveRecord record = _LiveRecord(sample);
    _recordsByCacheKey[request.cacheKey.value] = record;
    _recordsByIndex[sample.index] = record;
  }

  List<int> get completedSampleIndices {
    return <int>[
      for (final _LiveRecord record in _recordsByIndex.values)
        if (record.outcome == 'completed') record.sample.index,
    ]..sort();
  }

  void recordProbe(ProfileLiveNetworkProbe probe) {
    final _LiveRecord? record = _recordsByIndex[probe.sampleIndex];
    if (record == null) {
      throw StateError(
        'Live-network probe ${probe.sampleIndex} was not registered.',
      );
    }
    record.probe = probe;
  }

  @override
  void onPixaEvent(PixaEvent event) {
    final PixaRequestSnapshot? request = event.request;
    if (request == null ||
        request.cacheNamespace != profileLiveNetworkCacheNamespace) {
      return;
    }
    final _LiveRecord? record = _recordsByCacheKey[request.cacheKey];
    if (record == null) {
      return;
    }
    record.observed = true;
    if (event.name == 'request.start') {
      record.requested = true;
    }
    if (event.name.contains('memory.hit')) {
      record.cacheState = 'unexpected-memory-hit';
      _unexpectedCacheHits += 1;
    } else if (event.name.contains('disk.hit')) {
      record.cacheState = 'unexpected-disk-hit';
      _unexpectedCacheHits += 1;
    }
    final int? progressBytes = event.progress?.receivedBytes;
    if (progressBytes != null) {
      record.actualBytes = math.max(record.actualBytes, progressBytes);
    }
    final Object? runtimeBytes = event.attributes['bytes'];
    if (runtimeBytes is int && runtimeBytes >= 0) {
      record.actualBytes = math.max(record.actualBytes, runtimeBytes);
    }
    final PixaFailure? failure = event.failure;
    if (failure != null) {
      record
        ..outcome = 'failed'
        ..safeError = failure.safeMessage;
    } else if (event.name == 'request.complete') {
      record
        ..outcome = 'completed'
        ..latencyMicros = event.durationMicros ?? record.latencyMicros;
    } else if (event.stage == PixaStage.cancel) {
      record.outcome = 'cancelled';
    }
  }

  Map<String, Object?> buildEvidence({
    required Map<String, Object?> frameScenario,
  }) {
    final List<_LiveRecord> records = _recordsByIndex.values.toList()
      ..sort(
        (_LiveRecord first, _LiveRecord second) =>
            first.sample.index.compareTo(second.sample.index),
      );
    return <String, Object?>{
      'enabled': true,
      'service': 'picsum.photos',
      'corpusSeed': corpus.seed,
      'corpusSamples': corpus.itemCount,
      'registeredSamples': records.length,
      'requestedSamples': records
          .where((_LiveRecord record) => record.requested)
          .length,
      'observedSamples': records
          .where((_LiveRecord record) => record.observed)
          .length,
      'completedSamples': records
          .where((_LiveRecord record) => record.outcome == 'completed')
          .length,
      'failedSamples': records
          .where((_LiveRecord record) => record.outcome == 'failed')
          .length,
      'cancelledSamples': records
          .where((_LiveRecord record) => record.outcome == 'cancelled')
          .length,
      'unexpectedCacheHits': _unexpectedCacheHits,
      'cacheState': 'network/no-store',
      'frameScenario': frameScenario,
      'samples': <Object?>[
        for (final _LiveRecord record in records) record.toJson(),
      ],
    };
  }
}

final class _LiveRecord {
  _LiveRecord(this.sample);

  final ProfileLiveNetworkSample sample;
  bool requested = false;
  bool observed = false;
  int actualBytes = 0;
  int latencyMicros = 0;
  String cacheState = 'network/no-store';
  String outcome = 'started';
  String? safeError;
  ProfileLiveNetworkProbe? probe;

  Map<String, Object?> toJson() {
    final ProfileLiveNetworkProbe? probe = this.probe;
    return <String, Object?>{
      'index': sample.index,
      'contentSeed': sample.contentSeed,
      'width': sample.width,
      'height': sample.height,
      'requested': requested,
      'observed': observed,
      'timedPixaBytes': actualBytes,
      'timedPixaLatencyMicros': latencyMicros,
      'cacheState': cacheState,
      'outcome': outcome,
      if (safeError != null) 'safeError': safeError,
      if (probe != null)
        'identityProbe': <String, Object?>{
          'kind': 'independent-pixa-http-identity',
          'pixaBytes': probe.pixaBytes,
          'pixaLatencyMicros': probe.pixaLatencyMicros,
          'pixaMimeType': probe.pixaMimeType,
          'pixaSha256': probe.pixaSha256,
          'httpStatusCode': probe.httpStatusCode,
          'httpRedirectCount': probe.httpRedirectCount,
          'httpBytes': probe.httpBytes,
          'httpLatencyMicros': probe.httpLatencyMicros,
          'httpMimeType': probe.httpMimeType,
          'httpSha256': probe.httpSha256,
          'digestMatch': probe.digestMatch,
          if (probe.pixaSafeError != null) 'pixaSafeError': probe.pixaSafeError,
          if (probe.httpSafeError != null) 'httpSafeError': probe.httpSafeError,
        },
    };
  }
}
