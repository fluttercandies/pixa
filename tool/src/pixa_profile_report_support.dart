part of '../pixa_profile_report.dart';

void _renderLiveNetwork(
  StringBuffer output,
  Map<String, Object?> liveNetwork, {
  required List<String> supplementalFailures,
}) {
  final List<Map<String, Object?>> samples = _objects(liveNetwork, 'samples');
  final List<Map<String, Object?>> probes = samples
      .where((Map<String, Object?> sample) => sample['identityProbe'] is Map)
      .take(8)
      .toList();
  final List<int> encodedBytes = <int>[
    for (final Map<String, Object?> sample in samples)
      _integer(sample, 'timedPixaBytes'),
  ]..sort();
  final List<int> latencies = <int>[
    for (final Map<String, Object?> sample in samples)
      _integer(sample, 'timedPixaLatencyMicros'),
  ]..sort();
  final Map<String, Object?> frame = _object(liveNetwork, 'frameScenario');
  final Map<String, Object?> build = _object(frame, 'build');
  final Map<String, Object?> raster = _object(frame, 'raster');
  output
    ..writeln()
    ..writeln('## Supplemental Live Network')
    ..writeln()
    ..writeln(
      'Supplemental result: '
      '**${supplementalFailures.isEmpty ? 'PASS' : 'DEGRADED'}**',
    )
    ..writeln()
    ..writeln(
      'Seeded `${_escape(_text(liveNetwork, 'service'))}` corpus '
      '(seed ${_integer(liveNetwork, 'corpusSeed')}), '
      'registered/requested/observed/completed '
      '${_integer(liveNetwork, 'registeredSamples')}/'
      '${_integer(liveNetwork, 'requestedSamples')}/'
      '${_integer(liveNetwork, 'observedSamples')}/'
      '${_integer(liveNetwork, 'completedSamples')} of '
      '${_integer(liveNetwork, 'corpusSamples')} corpus entries; '
      '${_integer(liveNetwork, 'failedSamples')} failed. Cache state: '
      '`${_escape(_text(liveNetwork, 'cacheState'))}`.',
    )
    ..writeln()
    ..writeln(
      'Frame timing: ${_integer(frame, 'frameCount')} frames, build p99 '
      '${_milliseconds(_integer(build, 'p99Micros'))}, raster p99 '
      '${_milliseconds(_integer(raster, 'p99Micros'))}, '
      '${_integer(frame, 'overBudgetFrames')} over budget.',
    );
  if (samples.isEmpty) {
    output
      ..writeln()
      ..writeln('No live image loads were observed.');
  } else {
    output
      ..writeln()
      ..writeln(
        'Observed encoded bytes: ${_bytes(encodedBytes.first)} min, '
        '${_bytes(_percentile(encodedBytes, 0.50))} p50, '
        '${_bytes(_percentile(encodedBytes, 0.90))} p90, '
        '${_bytes(encodedBytes.last)} max, '
        '${_bytes(encodedBytes.fold<int>(0, (int sum, int value) => sum + value))} total.',
      )
      ..writeln(
        'Pixa load latency: '
        '${_milliseconds(_percentile(latencies, 0.50))} p50, '
        '${_milliseconds(_percentile(latencies, 0.90))} p90, '
        '${_milliseconds(_percentile(latencies, 0.99))} p99, '
        '${_milliseconds(latencies.last)} max.',
      )
      ..writeln()
      ..writeln(
        'Showing ${probes.length} identity probes of ${samples.length} timed '
        'loads; each probe is a separate Pixa and HTTP transaction for the '
        'same seeded URL. Full per-image evidence remains in raw JSON.',
      )
      ..writeln()
      ..writeln(
        '| Sample | Source pixels | Timed Pixa bytes | Timed latency | '
        'Independent HTTP | Redirects | MIME identity | SHA-256 | Cache | '
        'Outcome |',
      )
      ..writeln(
        '| ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |',
      );
    for (final Map<String, Object?> sample in probes) {
      final Map<String, Object?> probe = _object(sample, 'identityProbe');
      final int statusCode = _integer(probe, 'httpStatusCode');
      output.writeln(
        '| ${_integer(sample, 'index')} | '
        '${_integer(sample, 'width')}x${_integer(sample, 'height')} | '
        '${_bytes(_integer(sample, 'timedPixaBytes'))} | '
        '${_milliseconds(_integer(sample, 'timedPixaLatencyMicros'))} | '
        '${statusCode > 0 ? 'HTTP $statusCode' : 'n/a'} | '
        '${_integer(probe, 'httpRedirectCount')} | '
        '${_escape(_text(probe, 'pixaMimeType'))} = '
        '${_escape(_text(probe, 'httpMimeType'))} | '
        '${probe['digestMatch'] == true ? 'match' : 'mismatch'} | '
        '${_escape(_text(sample, 'cacheState'))} | '
        '${_escape(_text(sample, 'outcome'))} |',
      );
    }
  }
  output
    ..writeln()
    ..writeln(
      'This scenario supplements the deterministic loopback gate. External '
      'service variability is reported separately and is not the sole '
      'release pass/fail signal.',
    );
  if (supplementalFailures.isNotEmpty) {
    output
      ..writeln()
      ..writeln('Supplemental findings:');
    for (final String failure in supplementalFailures) {
      output.writeln('- $failure');
    }
  }
}

int _percentile(List<int> sortedValues, double percentile) {
  if (sortedValues.isEmpty) {
    return 0;
  }
  final int index = ((sortedValues.length - 1) * percentile).ceil();
  return sortedValues[index];
}

double _theilSenSlope(List<int> values) {
  if (values.length < 2) {
    return 0;
  }
  final List<double> slopes = <double>[];
  for (var first = 0; first < values.length - 1; first += 1) {
    for (var second = first + 1; second < values.length; second += 1) {
      slopes.add((values[second] - values[first]) / (second - first));
    }
  }
  slopes.sort();
  final int middle = slopes.length ~/ 2;
  return slopes.length.isOdd
      ? slopes[middle]
      : (slopes[middle - 1] + slopes[middle]) / 2;
}

int _maximum(List<Map<String, Object?>> values, String field) {
  if (values.isEmpty) {
    return 0;
  }
  return values
      .map((Map<String, Object?> value) => _integer(value, field))
      .reduce(math.max);
}

Map<String, Object?> _object(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate is Map<String, Object?>) {
    return candidate;
  }
  if (candidate is Map) {
    return candidate.map(
      (Object? nestedKey, Object? nestedValue) =>
          MapEntry<String, Object?>(nestedKey.toString(), nestedValue),
    );
  }
  throw FormatException('Expected "$key" to be a JSON object.');
}

Map<String, Object?>? _optionalObject(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate == null) {
    return null;
  }
  if (candidate is Map<String, Object?>) {
    return candidate;
  }
  if (candidate is Map) {
    return candidate.map(
      (Object? nestedKey, Object? nestedValue) =>
          MapEntry<String, Object?>(nestedKey.toString(), nestedValue),
    );
  }
  throw FormatException('Expected "$key" to be a JSON object.');
}

List<Map<String, Object?>> _objects(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate is! List) {
    throw FormatException('Expected "$key" to be a JSON list.');
  }
  return <Map<String, Object?>>[
    for (final Object? entry in candidate)
      if (entry is Map<String, Object?>)
        entry
      else if (entry is Map)
        entry.map(
          (Object? nestedKey, Object? nestedValue) =>
              MapEntry<String, Object?>(nestedKey.toString(), nestedValue),
        )
      else
        throw FormatException('Expected entries in "$key" to be objects.'),
  ];
}

List<Map<String, Object?>>? _optionalObjects(
  Map<String, Object?> value,
  String key,
) {
  if (value[key] == null) {
    return null;
  }
  return _objects(value, key);
}

String _text(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate is String) {
    return candidate;
  }
  throw FormatException('Expected "$key" to be a string.');
}

int _integer(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate is int) {
    return candidate;
  }
  if (candidate is num &&
      candidate.isFinite &&
      candidate == candidate.round()) {
    return candidate.toInt();
  }
  throw FormatException('Expected "$key" to be an integer.');
}

double _number(Map<String, Object?> value, String key) {
  final Object? candidate = value[key];
  if (candidate is num && candidate.isFinite) {
    return candidate.toDouble();
  }
  throw FormatException('Expected "$key" to be a finite number.');
}

String _milliseconds(int micros) => '${(micros / 1000).toStringAsFixed(3)} ms';

String _signedMilliseconds(int micros) {
  final String sign = micros > 0 ? '+' : '';
  return '$sign${(micros / 1000).toStringAsFixed(3)} ms';
}

String _bytes(int value) {
  final int absolute = value.abs();
  final String sign = value < 0 ? '-' : '';
  if (absolute >= 1024 * 1024 * 1024) {
    return '$sign${(absolute / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (absolute >= 1024 * 1024) {
    return '$sign${(absolute / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  if (absolute >= 1024) {
    return '$sign${(absolute / 1024).toStringAsFixed(2)} KiB';
  }
  return '$value B';
}

String _escape(String value) => value.replaceAll('|', r'\|');
