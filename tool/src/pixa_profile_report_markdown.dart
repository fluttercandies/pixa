part of '../pixa_profile_report.dart';

String _renderMarkdown(
  Map<String, Object?> run, {
  required Map<String, Object?>? baseline,
  required List<String> failures,
  required List<String> supplementalFailures,
  required _MemoryEvaluation memory,
  required bool releasePassed,
}) {
  final Map<String, Object?> environment = _object(run, 'environment');
  final Map<String, Object?> workload = _object(run, 'workload');
  final List<Map<String, Object?>> scenarios = _objects(run, 'scenarios');
  final StringBuffer output = StringBuffer()
    ..writeln('# Pixa 120Hz Profile Scroll Report')
    ..writeln()
    ..writeln('Result: **${releasePassed ? 'PASS' : 'FAIL'}**')
    ..writeln()
    ..writeln('## Environment')
    ..writeln()
    ..writeln('| Field | Measured value |')
    ..writeln('| --- | --- |')
    ..writeln(
      '| Device class | ${_escape(_text(environment, 'deviceLabel'))} |',
    )
    ..writeln(
      '| Device id hash | `${_escape(_text(environment, 'deviceIdHash'))}` |',
    )
    ..writeln('| Platform | ${_escape(_text(environment, 'platform'))} |')
    ..writeln('| OS | ${_escape(_text(environment, 'osVersion'))} |')
    ..writeln(
      '| Refresh rate | ${_number(environment, 'refreshRateHz').toStringAsFixed(2)} Hz |',
    )
    ..writeln('| Flutter | ${_escape(_text(environment, 'flutterVersion'))} |')
    ..writeln('| Dart | ${_escape(_text(environment, 'dartVersion'))} |')
    ..writeln('| Rust | ${_escape(_text(environment, 'rustVersion'))} |')
    ..writeln('| Git commit | `${_escape(_text(environment, 'gitCommit'))}` |')
    ..writeln('| Build mode | `${_escape(_text(run, 'mode'))}` |')
    ..writeln()
    ..writeln('## Workload')
    ..writeln();
  _renderWorkload(output, workload);
  output
    ..writeln()
    ..writeln(
      'Concurrency: network ${_integer(workload, 'networkConcurrency')}, '
      'decode ${_integer(workload, 'decodeConcurrency')}. Cache budgets: '
      'encoded ${_bytes(_integer(workload, 'memoryCacheBudgetBytes'))}, '
      'decoded ${_bytes(_integer(workload, 'decodedCacheBudgetBytes'))}.',
    )
    ..writeln()
    ..writeln('## Thresholds')
    ..writeln()
    ..writeln(
      '- Frame budget: ${_milliseconds(_profileFrameBudgetMicros)} '
      '(${_profileMinimumRefreshRateHz.toStringAsFixed(2)} Hz minimum).',
    )
    ..writeln(
      '- Each scenario: at least '
      '$_profileMinimumFramesPerScenario frames, build and '
      'raster p99 within budget, no more than '
      '${(_profileMaximumOverBudgetRatio * 100).toStringAsFixed(2)}% '
      'over-budget frames.',
    )
    ..writeln(
      '- RSS plateau: growth no more than '
      '${_bytes(_profileMaximumRssPlateauGrowthBytes)}; slope '
      'no more than '
      '${_bytes(_profileMaximumRssSlopeBytesPerCycle)}/cycle.',
    )
    ..writeln(
      '- Decoded registry plateau: growth no more than '
      '$_profileMaximumRegistryPlateauGrowthEntries entries; slope no more '
      'than $_profileMaximumRegistrySlopeEntriesPerCycle entries/cycle.',
    )
    ..writeln()
    ..writeln('## Frame Timing')
    ..writeln()
    ..writeln(
      '| Scenario | Frames | Build p90 | Build p99 | Build worst | '
      'Raster p90 | Raster p99 | Raster worst | Over budget | Network | '
      'Encoded hits |',
    )
    ..writeln(
      '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | '
      '---: | ---: |',
    );
  for (final Map<String, Object?> scenario in scenarios) {
    final Map<String, Object?> build = _object(scenario, 'build');
    final Map<String, Object?> raster = _object(scenario, 'raster');
    final Map<String, Object?> cacheDelta = _object(scenario, 'cacheDelta');
    final int frames = _integer(scenario, 'frameCount');
    final int missed = _integer(scenario, 'overBudgetFrames');
    output.writeln(
      '| `${_escape(_text(scenario, 'name'))}` | $frames | '
      '${_milliseconds(_integer(build, 'p90Micros'))} | '
      '${_milliseconds(_integer(build, 'p99Micros'))} | '
      '${_milliseconds(_integer(build, 'worstMicros'))} | '
      '${_milliseconds(_integer(raster, 'p90Micros'))} | '
      '${_milliseconds(_integer(raster, 'p99Micros'))} | '
      '${_milliseconds(_integer(raster, 'worstMicros'))} | '
      '$missed (${frames == 0 ? 'n/a' : '${(missed / frames * 100).toStringAsFixed(2)}%'}) | '
      '${_integer(scenario, 'loopbackRequests')} | '
      '${_integer(cacheDelta, 'memoryHits') + _integer(cacheDelta, 'diskHits')} |',
    );
  }

  final Map<String, Object?>? liveNetwork = _optionalObject(run, 'liveNetwork');
  if (liveNetwork != null && liveNetwork['enabled'] == true) {
    try {
      _renderLiveNetwork(
        output,
        liveNetwork,
        supplementalFailures: supplementalFailures,
      );
    } on FormatException {
      output
        ..writeln()
        ..writeln('## Supplemental Live Network')
        ..writeln()
        ..writeln('Supplemental result: **DEGRADED**')
        ..writeln()
        ..writeln(
          'Live network evidence was incomplete and could not be rendered.',
        )
        ..writeln()
        ..writeln('Supplemental findings:');
      for (final String failure in supplementalFailures) {
        output.writeln('- $failure');
      }
    }
  } else if (run['liveNetworkRequested'] == true) {
    output
      ..writeln()
      ..writeln('## Supplemental Live Network')
      ..writeln()
      ..writeln('Supplemental result: **DEGRADED**')
      ..writeln()
      ..writeln('The requested live network result was not recorded.')
      ..writeln()
      ..writeln('Supplemental findings:');
    for (final String failure in supplementalFailures) {
      output.writeln('- $failure');
    }
  }

  output
    ..writeln()
    ..writeln('## Memory Stability')
    ..writeln()
    ..writeln('| Metric | Measured |')
    ..writeln('| --- | ---: |')
    ..writeln('| RSS plateau growth | ${_bytes(memory.plateauGrowthBytes)} |')
    ..writeln(
      '| Theil-Sen RSS slope | '
      '${_bytes(memory.slopeBytesPerCycle.round())}/cycle |',
    )
    ..writeln(
      '| Peak Rust memory cache | ${_bytes(memory.maxRuntimeMemoryBytes)} |',
    )
    ..writeln('| Peak encoded memory | ${_bytes(memory.maxEncodedBytes)} |')
    ..writeln('| Peak processed memory | ${_bytes(memory.maxProcessedBytes)} |')
    ..writeln('| Peak decoded cache | ${_bytes(memory.maxDecodedBytes)} |')
    ..writeln(
      '| Peak decoded registry | ${memory.maxRegistryEntries} entries |',
    )
    ..writeln(
      '| Decoded registry plateau growth | '
      '${memory.registryPlateauGrowthEntries} entries |',
    )
    ..writeln(
      '| Decoded registry Theil-Sen slope | '
      '${memory.registrySlopeEntriesPerCycle.toStringAsFixed(2)} entries/cycle |',
    )
    ..writeln()
    ..writeln('## Baseline delta')
    ..writeln();
  if (baseline == null) {
    output.writeln('No comparable baseline was supplied.');
  } else {
    output
      ..writeln('| Scenario | Build p99 delta | Raster p99 delta |')
      ..writeln('| --- | ---: | ---: |');
    final Map<String, Map<String, Object?>> baselineScenarios =
        <String, Map<String, Object?>>{
          for (final Map<String, Object?> scenario in _objects(
            baseline,
            'scenarios',
          ))
            _text(scenario, 'name'): scenario,
        };
    for (final Map<String, Object?> scenario in scenarios) {
      final String name = _text(scenario, 'name');
      final Map<String, Object?>? previous = baselineScenarios[name];
      if (previous == null) {
        output.writeln('| `$name` | unavailable | unavailable |');
        continue;
      }
      final int buildDelta =
          _integer(_object(scenario, 'build'), 'p99Micros') -
          _integer(_object(previous, 'build'), 'p99Micros');
      final int rasterDelta =
          _integer(_object(scenario, 'raster'), 'p99Micros') -
          _integer(_object(previous, 'raster'), 'p99Micros');
      output.writeln(
        '| `$name` | ${_signedMilliseconds(buildDelta)} | '
        '${_signedMilliseconds(rasterDelta)} |',
      );
    }
  }

  output
    ..writeln()
    ..writeln('## Gate Details')
    ..writeln();
  if (failures.isEmpty) {
    output.writeln('All profile performance and memory gates passed.');
  } else {
    for (final String failure in failures) {
      output.writeln('- $failure');
    }
  }
  return output.toString();
}

void _renderWorkload(StringBuffer output, Map<String, Object?> workload) {
  final List<Map<String, Object?>>? corpus = _optionalObjects(
    workload,
    'imageCorpus',
  );
  if (corpus == null) {
    output.writeln(
      '${_integer(workload, 'itemCount')} images; '
      '${_integer(workload, 'imageWidth')}x${_integer(workload, 'imageHeight')} '
      '${_escape(_text(workload, 'imageFormat')).toUpperCase()}; '
      '${_bytes(_integer(workload, 'encodedBytes'))} encoded each; '
      '${_escape(_text(workload, 'cacheState'))} cache state.',
    );
    return;
  }
  output
    ..writeln(
      '${_integer(workload, 'itemCount')} images drawn from deterministic '
      '`${_escape(_text(workload, 'corpusId'))}`; '
      '${_escape(_text(workload, 'cacheState'))} cache state.',
    )
    ..writeln()
    ..writeln('| Corpus image | MIME | Source pixels | Encoded bytes |')
    ..writeln('| --- | --- | ---: | ---: |');
  for (final Map<String, Object?> image in corpus) {
    output.writeln(
      '| `${_escape(_text(image, 'id'))}` | '
      '${_escape(_text(image, 'mimeType'))} | '
      '${_integer(image, 'width')}x${_integer(image, 'height')} | '
      '${_bytes(_integer(image, 'encodedBytes'))} |',
    );
  }
}
