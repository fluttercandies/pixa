import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'src/pixa_profile_git_state.dart';

const int _benchmarkEvidenceSchemaVersion = 1;
const double _benchmarkMaximumRegressionRatio = 0.35;
const int _benchmarkAbsoluteNoiseNanoseconds = 100;

List<_BenchmarkCommand> _commands() => <_BenchmarkCommand>[
  _BenchmarkCommand(
    source: 'rust-core',
    executable: 'cargo',
    arguments: <String>[
      'run',
      '--release',
      '--manifest-path',
      'packages/pixa/native_src/rust/Cargo.toml',
      '--target-dir',
      'build/rust-target',
      '-p',
      'pixa_core',
      '--example',
      'core_benchmark',
    ],
  ),
  _BenchmarkCommand(
    source: 'rust-runtime',
    executable: 'cargo',
    arguments: <String>[
      'run',
      '--release',
      '--manifest-path',
      'packages/pixa/native_src/rust/Cargo.toml',
      '--target-dir',
      'build/rust-target',
      '-p',
      'pixa_runtime',
      '--example',
      'runtime_benchmark',
    ],
  ),
  _BenchmarkCommand(
    source: 'flutter',
    executable: Platform.resolvedExecutable,
    arguments: <String>[
      'run',
      'melos',
      'exec',
      '--scope=pixa',
      '--concurrency=1',
      '--',
      _flutterExecutable(),
      'test',
      'benchmark/predictive_prefetch_benchmark_test.dart',
    ],
  ),
];

const Map<String, List<String>> _requiredCoverage = <String, List<String>>{
  'memory hit': <String>['encoded_memory_hit_32px_png'],
  'disk hit': <String>['encoded_disk_hit_32px_png'],
  'network fetch': <String>['origin_fetch_coalesced_network_variants'],
  'decode and resize': <String>[
    'flutter_decode_min_gif',
    'processor_resize_96_to_48_png',
  ],
  'region decode': <String>[
    'processor_tile_region_png_128',
    'processor_tile_region_bmp_128',
    'processor_tile_region_farbfeld_128',
  ],
  'stable raster format matrix': <String>[
    'runtime_format_decode_tiff_rgba',
    'runtime_format_decode_pnm_rgba',
    'runtime_format_decode_qoi_rgba',
    'runtime_format_decode_tga_rgba',
    'runtime_format_decode_dds_rgba',
    'runtime_format_decode_hdr_rgba',
    'runtime_format_decode_farbfeld_rgba',
    'runtime_format_decode_pcx_rgba',
    'runtime_format_decode_sgi_rgba',
    'runtime_format_decode_wbmp_rgba',
    'runtime_format_decode_xbm_rgba',
    'runtime_format_decode_xpm_rgba',
  ],
  'scroll prefetch': <String>['scroll_prefetch_planning'],
  'rapid scroll prefetch': <String>['scroll_prefetch_rapid_overlap'],
  'prefetch recent eviction': <String>['scroll_prefetch_recent_eviction'],
  'image completion pacing': <String>['image_completion_frame_gate_burst'],
  'request key hot path': <String>['request_cache_key_memoized_hot_path'],
  'format route hot path': <String>['format_route_capability_lookup'],
  'runtime-only route plan hot path': <String>[
    'runtime_only_route_plan_hot_path',
  ],
  'animated image': <String>['flutter_animated_gif_frames'],
  'runtime ABI overhead': <String>['runtime_small_fnv1a64_32b'],
};

const Map<String, List<String>> _jpegTurboCoverage = <String, List<String>>{
  'JPEG Turbo ROI': <String>['processor_tile_region_jpeg_turbo_16'],
};

const Map<String, List<String>> _webpRoiCoverage = <String, List<String>>{
  'WebP ROI': <String>['processor_tile_region_webp_native_16'],
};

const Map<String, String> _smokeEnvironment = <String, String>{
  'PIXA_BENCH_HASH_ITERS': '1000',
  'PIXA_BENCH_MEMORY_ITERS': '50',
  'PIXA_BENCH_DISK_ITERS': '20',
  'PIXA_BENCH_DISK_INDEX_ITERS': '50',
  'PIXA_BENCH_ORIGIN_FANOUT': '4',
  'PIXA_BENCH_ORIGIN_BATCHES': '2',
  'PIXA_BENCH_PROCESSOR_ITERS': '5',
  'PIXA_BENCH_REGION_ITERS': '3',
  'PIXA_BENCH_FORMAT_DECODE_ITERS': '3',
  'PIXA_BENCH_RUNTIME_SMALL_ITERS': '1000',
  'PIXA_BENCH_RUNTIME_STATS_ITERS': '50',
  'PIXA_BENCH_RUNTIME_PROGRESS_ITERS': '10',
  'PIXA_BENCH_RUNTIME_LARGE_BUFFER_ITERS': '3',
  'PIXA_BENCH_JPEG_TURBO_ITERS': '3',
  'PIXA_BENCH_WEBP_ROI_ITERS': '3',
  'PIXA_BENCH_PREFETCH_ITERS': '8',
  'PIXA_BENCH_PREFETCH_VISIBLE': '120',
  'PIXA_BENCH_PREFETCH_ITEMS': '2000',
  'PIXA_BENCH_REQUEST_KEY_ITERS': '50000',
  'PIXA_BENCH_COMPLETION_BURST_IMAGES': '8',
  'PIXA_BENCH_COMPLETION_FRAME_BUDGET': '2',
  'PIXA_BENCH_DECODE_ITERS': '20',
  'PIXA_BENCH_ANIMATED_ITERS': '10',
};

void main(List<String> args) {
  try {
    _run(args);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

void _run(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  final _Options options = _Options.parse(args);
  if (options.verifyEvidencePath != null) {
    final _BenchmarkEvidence current = _readBenchmarkEvidence(
      options.verifyEvidencePath!,
    );
    final _BenchmarkEvidence baseline = _readBenchmarkEvidence(
      options.baselinePath!,
    );
    final _BenchmarkEvaluation evaluation = _evaluateBenchmarkEvidence(
      current,
      baseline,
      requiredGitCommit: options.requiredGitCommit,
    );
    _writeBenchmarkEvaluation(options.outputPath, evaluation);
    if (!evaluation.passed) {
      for (final String failure in evaluation.failures) {
        stderr.writeln(failure);
      }
      exitCode = 1;
    }
    return;
  }

  final ({String commit, String treeState})? git = options.smoke
      ? null
      : _benchmarkGitIdentity();
  if (git != null && git.treeState != 'clean') {
    throw StateError('Full benchmark evidence requires a clean Git worktree.');
  }
  if (git != null &&
      options.requiredGitCommit != null &&
      git.commit != options.requiredGitCommit) {
    throw StateError(
      'Full benchmark evidence Git commit ${git.commit} does not match '
      'required current commit ${options.requiredGitCommit}.',
    );
  }

  final List<_BenchmarkRow> rows = <_BenchmarkRow>[];
  final Map<String, String> environment = <String, String>{
    ...Platform.environment,
    if (options.smoke) ..._smokeEnvironment,
    if (options.includeJpegTurbo) 'PIXA_BENCH_JPEG_TURBO': '1',
    if (options.includeWebpRoi) 'PIXA_BENCH_WEBP_ROI': '1',
  };
  final Map<String, List<String>> coverage = _coverageFor(options);

  for (final _BenchmarkCommand command in _commands()) {
    stdout.writeln('Running ${command.source} benchmark...');
    final ProcessResult result = Process.runSync(
      command.executable,
      command.arguments,
      workingDirectory: Directory.current.path,
      environment: environment,
    );
    final String output = '${result.stdout}\n${result.stderr}';
    rows.addAll(_parseRows(output, command.source));
    if (result.exitCode != 0) {
      stderr.writeln(output.trim());
      exitCode = result.exitCode;
      return;
    }
  }

  final List<String> missing = _missingCoverage(rows, coverage);
  if (missing.isNotEmpty) {
    stderr.writeln('Benchmark coverage is incomplete:');
    for (final String item in missing) {
      stderr.writeln('- $item');
    }
    exitCode = 1;
    return;
  }

  final File output = File(options.outputPath);
  output.parent.createSync(recursive: true);
  if (options.smoke) {
    output.writeAsStringSync(
      _renderSmokeReport(
        rows,
        includeJpegTurbo: options.includeJpegTurbo,
        includeWebpRoi: options.includeWebpRoi,
        coverage: coverage,
      ),
    );
    stdout.writeln('Benchmark coverage smoke written to ${output.path}');
    return;
  }

  final _BenchmarkEvidence current = _captureBenchmarkEvidence(
    rows,
    gitCommit: git!.commit,
    includeJpegTurbo: options.includeJpegTurbo,
    includeWebpRoi: options.includeWebpRoi,
    coverage: coverage,
  );
  _writeBenchmarkEvidence(options.evidenceOutputPath!, current);
  if (options.captureOnly) {
    output.writeAsStringSync(_renderCapturedBaseline(current));
    stdout.writeln(
      'Benchmark baseline captured at ${options.evidenceOutputPath}',
    );
    return;
  }
  final _BenchmarkEvidence baseline = _readBenchmarkEvidence(
    options.baselinePath!,
  );
  final _BenchmarkEvaluation evaluation = _evaluateBenchmarkEvidence(
    current,
    baseline,
    requiredGitCommit: options.requiredGitCommit ?? git.commit,
  );
  _writeBenchmarkEvaluation(options.outputPath, evaluation);
  if (!evaluation.passed) {
    for (final String failure in evaluation.failures) {
      stderr.writeln(failure);
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Benchmark report written to ${output.path}');
}

List<String> requiredBenchmarkCoverageNames() {
  return _requiredCoverage.values
      .expand((List<String> names) => names)
      .toList(growable: false);
}

/// Exact Rust benchmark commands, exposed for release-contract self-tests.
List<List<String>> benchmarkRustCommands() => _commands()
    .where((_BenchmarkCommand command) => command.source.startsWith('rust-'))
    .map(
      (_BenchmarkCommand command) => <String>[
        command.executable,
        ...command.arguments,
      ],
    )
    .toList(growable: false);

/// Exact pinned Rust compiler probe used in benchmark evidence metadata.
List<String> benchmarkRustVersionCommand() => <String>['rustc', '--version'];

String get _usage => '''
Usage: dart run tool/pixa_benchmark_report.dart [options]

Runs Rust and Flutter benchmark harnesses, checks required production-gallery
coverage, and writes a local Markdown benchmark report.

Options:
  --smoke                Run coverage-only smoke mode; never release evidence.
  --capture-only         Capture a clean full baseline without evaluating it.
  --baseline=<path>      Comparable full benchmark evidence JSON.
  --evidence-output=<path>
                         Full evidence JSON written for a benchmark run.
  --verify-evidence=<path>
                         Verify existing full evidence without rerunning benchmarks.
  --require-git-commit=<commit>
                         Require current evidence to match this full Git commit.
  --include-jpeg-turbo   Require the opt-in JPEG Turbo ROI benchmark. Requires PIXA_PLUGIN_PLAN
                         to enable pixa_jpeg_turbo_processor_plugin_init.
  --include-webp-roi     Require the opt-in WebP ROI benchmark. Requires PIXA_PLUGIN_PLAN
                         to enable pixa_webp_processor_plugin_init.
  --output=<path>        Report path. Defaults to build/reports/pixa_benchmark_report.md.
  --help                 Show this message.
''';

Iterable<_BenchmarkRow> _parseRows(String output, String source) sync* {
  for (final String rawLine in const LineSplitter().convert(output)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line == 'name,iterations,total_us,avg_ns,bytes') {
      continue;
    }
    final List<String> parts = line.split(',');
    if (parts.length < 5) {
      continue;
    }
    final int? iterations = int.tryParse(parts[1]);
    final int? totalUs = int.tryParse(parts[2]);
    final num? avgNs = num.tryParse(parts[3]);
    final int? bytes = int.tryParse(parts[4]);
    if (iterations == null ||
        totalUs == null ||
        avgNs == null ||
        bytes == null) {
      continue;
    }
    yield _BenchmarkRow(
      source: source,
      name: parts[0],
      iterations: iterations,
      totalUs: totalUs,
      avgNs: avgNs,
      bytes: bytes,
    );
  }
}

Map<String, List<String>> _coverageFor(_Options options) {
  return <String, List<String>>{
    ..._requiredCoverage,
    if (options.includeJpegTurbo) ..._jpegTurboCoverage,
    if (options.includeWebpRoi) ..._webpRoiCoverage,
  };
}

List<String> _missingCoverage(
  List<_BenchmarkRow> rows,
  Map<String, List<String>> coverage,
) {
  final Set<String> names = rows.map((_BenchmarkRow row) => row.name).toSet();
  final List<String> missing = <String>[];
  for (final MapEntry<String, List<String>> entry in coverage.entries) {
    final List<String> missingNames = entry.value
        .where((String requiredName) => !names.contains(requiredName))
        .toList(growable: false);
    if (missingNames.isNotEmpty) {
      missing.add('${entry.key}: ${missingNames.join(', ')}');
    }
  }
  return missing;
}

String _renderSmokeReport(
  List<_BenchmarkRow> rows, {
  required bool includeJpegTurbo,
  required bool includeWebpRoi,
  required Map<String, List<String>> coverage,
}) {
  final StringBuffer buffer = StringBuffer();
  final DateTime now = DateTime.now().toUtc();
  buffer.writeln('# Pixa Benchmark Report');
  buffer.writeln();
  buffer.writeln('Result: **COVERAGE ONLY**');
  buffer.writeln();
  buffer.writeln('Release evidence: **NOT EVALUATED**');
  buffer.writeln();
  buffer.writeln(
    'Smoke mode validates command execution and required benchmark names only. '
    'It cannot satisfy release performance evidence.',
  );
  buffer.writeln();
  buffer.writeln('- Generated UTC: ${now.toIso8601String()}');
  buffer.writeln('- Mode: smoke');
  buffer.writeln(
    '- JPEG Turbo ROI: ${includeJpegTurbo ? 'enabled' : 'disabled'}',
  );
  buffer.writeln('- WebP ROI: ${includeWebpRoi ? 'enabled' : 'disabled'}');
  buffer.writeln(
    '- Host: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  buffer.writeln('- Dart: ${Platform.version.split('\n').first}');
  buffer.writeln(
    '- Git: ${_commandText('git', <String>['rev-parse', '--short', 'HEAD'])}',
  );
  buffer.writeln('- Rust: ${_pinnedRustVersion()}');
  buffer.writeln('- Flutter: ${_flutterVersion()}');
  buffer.writeln();
  buffer.writeln('## Coverage');
  buffer.writeln();
  for (final String coverageName in coverage.keys) {
    buffer.writeln('- $coverageName: covered');
  }
  buffer.writeln();
  buffer.writeln('## Results');
  buffer.writeln();
  buffer.writeln(
    '| Source | Benchmark | Iterations | Total us | Avg ns | Bytes |',
  );
  buffer.writeln('| --- | --- | ---: | ---: | ---: | ---: |');
  for (final _BenchmarkRow row in rows) {
    buffer.writeln(
      '| ${row.source} | `${row.name}` | ${row.iterations} | '
      '${row.totalUs} | ${row.avgNs} | ${row.bytes} |',
    );
  }
  return buffer.toString();
}

_BenchmarkEvidence _captureBenchmarkEvidence(
  List<_BenchmarkRow> rows, {
  required String gitCommit,
  required bool includeJpegTurbo,
  required bool includeWebpRoi,
  required Map<String, List<String>> coverage,
}) {
  final Map<String, Object?> environment = _benchmarkEnvironment();
  final String fingerprint = sha256
      .convert(utf8.encode(jsonEncode(environment)))
      .toString();
  final List<String> requiredCoverage =
      coverage.values.expand((List<String> names) => names).toSet().toList()
        ..sort();
  return _BenchmarkEvidence(
    schemaVersion: _benchmarkEvidenceSchemaVersion,
    evidenceLevel: 'full',
    runId:
        '${gitCommit.substring(0, 12)}-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}',
    capturedAtUtc: DateTime.now().toUtc().toIso8601String(),
    gitCommit: gitCommit,
    gitTreeState: 'clean',
    environmentFingerprint: fingerprint,
    environment: environment,
    includeJpegTurbo: includeJpegTurbo,
    includeWebpRoi: includeWebpRoi,
    maximumRegressionRatio: _benchmarkMaximumRegressionRatio,
    absoluteNoiseNanoseconds: _benchmarkAbsoluteNoiseNanoseconds,
    requiredCoverage: requiredCoverage,
    rows: List<_BenchmarkRow>.unmodifiable(rows),
  );
}

_BenchmarkEvaluation _evaluateBenchmarkEvidence(
  _BenchmarkEvidence current,
  _BenchmarkEvidence baseline, {
  String? requiredGitCommit,
}) {
  final List<String> failures = <String>[];
  _validateBenchmarkEvidence(
    current,
    label: 'Current',
    requiredGitCommit: requiredGitCommit,
    failures: failures,
  );
  _validateBenchmarkEvidence(baseline, label: 'Baseline', failures: failures);
  if (current.runId == baseline.runId) {
    failures.add('Baseline must come from a different benchmark run.');
  }
  if (current.environmentFingerprint != baseline.environmentFingerprint) {
    failures.add('Baseline benchmark environment is not comparable.');
  }
  if (current.includeJpegTurbo != baseline.includeJpegTurbo ||
      current.includeWebpRoi != baseline.includeWebpRoi) {
    failures.add('Baseline benchmark feature set is not comparable.');
  }
  if (!_sameStrings(current.requiredCoverage, baseline.requiredCoverage)) {
    failures.add('Baseline required benchmark coverage is not comparable.');
  }

  final Map<String, _BenchmarkRow> currentRows = _rowsByName(
    current.rows,
    label: 'Current',
    failures: failures,
  );
  final Map<String, _BenchmarkRow> baselineRows = _rowsByName(
    baseline.rows,
    label: 'Baseline',
    failures: failures,
  );
  final List<_BenchmarkComparison> comparisons = <_BenchmarkComparison>[];
  for (final String name in current.requiredCoverage) {
    final _BenchmarkRow? currentRow = currentRows[name];
    final _BenchmarkRow? baselineRow = baselineRows[name];
    if (currentRow == null) {
      failures.add('Current benchmark evidence is missing $name.');
      continue;
    }
    if (baselineRow == null) {
      failures.add('Baseline benchmark evidence is missing $name.');
      continue;
    }
    if (currentRow.source != baselineRow.source) {
      failures.add('Benchmark $name source does not match the baseline.');
    }
    if (currentRow.iterations != baselineRow.iterations) {
      failures.add('Benchmark $name iteration count does not match baseline.');
    }
    final double allowedNanoseconds =
        baselineRow.avgNs * (1 + _benchmarkMaximumRegressionRatio) +
        _benchmarkAbsoluteNoiseNanoseconds;
    final bool passed = currentRow.avgNs <= allowedNanoseconds;
    if (!passed) {
      failures.add(
        'Benchmark $name average ${currentRow.avgNs.toStringAsFixed(1)} ns '
        'exceeds allowed ${allowedNanoseconds.toStringAsFixed(1)} ns.',
      );
    }
    comparisons.add(
      _BenchmarkComparison(
        current: currentRow,
        baseline: baselineRow,
        allowedNanoseconds: allowedNanoseconds,
        passed: passed,
      ),
    );
  }
  comparisons.sort(
    (_BenchmarkComparison left, _BenchmarkComparison right) =>
        left.current.name.compareTo(right.current.name),
  );
  return _BenchmarkEvaluation(
    current: current,
    baseline: baseline,
    comparisons: List<_BenchmarkComparison>.unmodifiable(comparisons),
    failures: List<String>.unmodifiable(failures),
  );
}

void _validateBenchmarkEvidence(
  _BenchmarkEvidence evidence, {
  required String label,
  String? requiredGitCommit,
  required List<String> failures,
}) {
  if (evidence.schemaVersion != _benchmarkEvidenceSchemaVersion) {
    failures.add('$label benchmark evidence schema is unsupported.');
  }
  if (evidence.evidenceLevel != 'full') {
    failures.add(
      '$label benchmark evidence is ${evidence.evidenceLevel}; full release '
      'evidence is required.',
    );
  }
  if (evidence.runId.isEmpty) {
    failures.add('$label benchmark evidence has no run id.');
  }
  if (!_isFullGitCommit(evidence.gitCommit)) {
    failures.add('$label benchmark evidence has an invalid Git commit.');
  }
  if (requiredGitCommit != null && evidence.gitCommit != requiredGitCommit) {
    failures.add(
      '$label benchmark evidence commit ${evidence.gitCommit} does not match '
      'required current commit $requiredGitCommit.',
    );
  }
  if (evidence.gitTreeState != 'clean') {
    failures.add('$label benchmark evidence must come from a clean Git tree.');
  }
  if (!_isSha256(evidence.environmentFingerprint)) {
    failures.add('$label benchmark environment fingerprint is invalid.');
  }
  if (DateTime.tryParse(evidence.capturedAtUtc) == null) {
    failures.add('$label benchmark capture timestamp is invalid.');
  }
  if (evidence.maximumRegressionRatio != _benchmarkMaximumRegressionRatio ||
      evidence.absoluteNoiseNanoseconds != _benchmarkAbsoluteNoiseNanoseconds) {
    failures.add('$label benchmark thresholds do not match the verifier.');
  }
  final List<String> expected = _expectedBenchmarkCoverage(
    includeJpegTurbo: evidence.includeJpegTurbo,
    includeWebpRoi: evidence.includeWebpRoi,
  );
  if (!_sameStrings(evidence.requiredCoverage, expected)) {
    failures.add('$label required benchmark coverage is incomplete.');
  }
  for (final _BenchmarkRow row in evidence.rows) {
    if (row.name.isEmpty ||
        row.source.isEmpty ||
        row.iterations <= 0 ||
        row.totalUs < 0 ||
        row.avgNs <= 0 ||
        row.bytes < 0) {
      failures.add('$label benchmark row ${row.name} is invalid.');
    }
  }
}

Map<String, _BenchmarkRow> _rowsByName(
  List<_BenchmarkRow> rows, {
  required String label,
  required List<String> failures,
}) {
  final Map<String, _BenchmarkRow> result = <String, _BenchmarkRow>{};
  for (final _BenchmarkRow row in rows) {
    if (result.containsKey(row.name)) {
      failures.add('$label benchmark evidence duplicates ${row.name}.');
    } else {
      result[row.name] = row;
    }
  }
  return result;
}

List<String> _expectedBenchmarkCoverage({
  required bool includeJpegTurbo,
  required bool includeWebpRoi,
}) {
  final List<String> names = <String>[
    ..._requiredCoverage.values.expand((List<String> value) => value),
    if (includeJpegTurbo)
      ..._jpegTurboCoverage.values.expand((List<String> value) => value),
    if (includeWebpRoi)
      ..._webpRoiCoverage.values.expand((List<String> value) => value),
  ];
  return names.toSet().toList()..sort();
}

bool _sameStrings(List<String> left, List<String> right) {
  final List<String> sortedLeft = left.toSet().toList()..sort();
  final List<String> sortedRight = right.toSet().toList()..sort();
  if (sortedLeft.length != left.length ||
      sortedRight.length != right.length ||
      sortedLeft.length != sortedRight.length) {
    return false;
  }
  for (var index = 0; index < sortedLeft.length; index += 1) {
    if (sortedLeft[index] != sortedRight[index]) {
      return false;
    }
  }
  return true;
}

String _renderBenchmarkEvaluation(_BenchmarkEvaluation evaluation) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# Pixa Benchmark Report')
    ..writeln()
    ..writeln('Result: **${evaluation.passed ? 'PASS' : 'FAIL'}**')
    ..writeln()
    ..writeln('- Evidence level: full')
    ..writeln('- Current run: `${evaluation.current.runId}`')
    ..writeln('- Current Git: `${evaluation.current.gitCommit}`')
    ..writeln('- Baseline run: `${evaluation.baseline.runId}`')
    ..writeln('- Baseline Git: `${evaluation.baseline.gitCommit}`')
    ..writeln(
      '- Environment fingerprint: '
      '`${evaluation.current.environmentFingerprint}`',
    )
    ..writeln()
    ..writeln('## Thresholds')
    ..writeln()
    ..writeln(
      '- Maximum regression ratio: '
      '${(_benchmarkMaximumRegressionRatio * 100).toStringAsFixed(0)}%.',
    )
    ..writeln(
      '- Absolute timing noise allowance: '
      '$_benchmarkAbsoluteNoiseNanoseconds ns.',
    )
    ..writeln('- Every required benchmark must exist in both full runs.')
    ..writeln()
    ..writeln('## Baseline comparison')
    ..writeln()
    ..writeln(
      '| Source | Benchmark | Baseline ns | Current ns | Allowed ns | Delta | Status |',
    )
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: | --- |');
  for (final _BenchmarkComparison comparison in evaluation.comparisons) {
    final double delta =
        (comparison.current.avgNs / comparison.baseline.avgNs - 1) * 100;
    buffer.writeln(
      '| ${comparison.current.source} | `${comparison.current.name}` | '
      '${comparison.baseline.avgNs.toStringAsFixed(1)} | '
      '${comparison.current.avgNs.toStringAsFixed(1)} | '
      '${comparison.allowedNanoseconds.toStringAsFixed(1)} | '
      '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}% | '
      '${comparison.passed ? 'PASS' : 'FAIL'} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('## Gate Details')
    ..writeln();
  if (evaluation.failures.isEmpty) {
    buffer.writeln('All full benchmark baseline gates passed.');
  } else {
    for (final String failure in evaluation.failures) {
      buffer.writeln('- $failure');
    }
  }
  return buffer.toString();
}

String _renderCapturedBaseline(_BenchmarkEvidence evidence) {
  return '''# Pixa Benchmark Baseline

Result: **BASELINE CAPTURED**

This artifact is full benchmark input for a later comparison. It is not a
release PASS result by itself.

- Run: `${evidence.runId}`
- Git: `${evidence.gitCommit}`
- Environment fingerprint: `${evidence.environmentFingerprint}`
- Required benchmarks: ${evidence.requiredCoverage.length}
''';
}

void _writeBenchmarkEvaluation(String path, _BenchmarkEvaluation evaluation) {
  final File output = File(path);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(_renderBenchmarkEvaluation(evaluation));
}

void _writeBenchmarkEvidence(String path, _BenchmarkEvidence evidence) {
  final File output = File(path);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync('${jsonEncode(evidence.toJson())}\n');
}

_BenchmarkEvidence _readBenchmarkEvidence(String path) {
  final File file = File(path);
  if (!file.existsSync()) {
    throw FormatException('Benchmark evidence not found: $path');
  }
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException('Benchmark evidence must be a JSON object: $path');
  }
  return _BenchmarkEvidence.fromJson(Map<String, Object?>.from(decoded));
}

({String commit, String treeState}) _benchmarkGitIdentity() {
  final String commit = _commandText('git', <String>['rev-parse', 'HEAD']);
  if (!_isFullGitCommit(commit)) {
    throw StateError('Unable to resolve the full Git commit for benchmarks.');
  }
  final ProcessResult status = Process.runSync('git', const <String>[
    'status',
    '--porcelain',
  ]);
  if (status.exitCode != 0) {
    throw StateError('Unable to inspect the Git tree for benchmarks.');
  }
  return (
    commit: commit,
    treeState: classifyPixaProfileGitTreeState('${status.stdout}'),
  );
}

Map<String, Object?> _benchmarkEnvironment() {
  return <String, Object?>{
    'operatingSystem': Platform.operatingSystem,
    'operatingSystemVersion': Platform.operatingSystemVersion,
    'architecture': _hostArchitecture(),
    'processors': Platform.numberOfProcessors,
    'dart': Platform.version.split('\n').first,
    'rust': _pinnedRustVersion(),
    'flutter': _flutterVersion(),
  };
}

String _hostArchitecture() {
  if (Platform.isWindows) {
    return Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'unknown';
  }
  return _commandText('uname', const <String>['-m']);
}

String _pinnedRustVersion() {
  final List<String> command = benchmarkRustVersionCommand();
  return _commandText(command.first, command.sublist(1));
}

bool _isFullGitCommit(String value) {
  return RegExp(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$').hasMatch(value);
}

bool _isSha256(String value) {
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}

String _commandText(String executable, List<String> arguments) {
  final ProcessResult result = Process.runSync(executable, arguments);
  if (result.exitCode != 0) {
    return 'unavailable';
  }
  final String text = (result.stdout as String).trim();
  if (text.isEmpty) {
    return 'unavailable';
  }
  return text.replaceAll('\n', ' ');
}

String _flutterVersion() {
  final ProcessResult result = Process.runSync(_flutterExecutable(), <String>[
    '--version',
    '--machine',
  ]);
  if (result.exitCode != 0) {
    return 'unavailable';
  }
  try {
    final Map<String, Object?> data =
        jsonDecode(result.stdout as String) as Map<String, Object?>;
    return '${data['flutterVersion']} (${data['channel']}), '
        'dart ${data['dartSdkVersion']}, engine ${data['engineRevision']}';
  } on Object {
    final String text = (result.stdout as String).trim();
    return text.isEmpty ? 'unavailable' : text.replaceAll('\n', ' ');
  }
}

String _flutterExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (Platform.isWindows) {
    if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
      return '${flutterRoot.replaceAll(r'\', '/')}/bin/flutter.bat';
    }
    return 'flutter.bat';
  }
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    return '$flutterRoot/bin/flutter';
  }
  return 'flutter';
}

final class _Options {
  const _Options({
    required this.smoke,
    required this.captureOnly,
    required this.includeJpegTurbo,
    required this.includeWebpRoi,
    required this.outputPath,
    required this.baselinePath,
    required this.evidenceOutputPath,
    required this.verifyEvidencePath,
    required this.requiredGitCommit,
  });

  final bool smoke;
  final bool captureOnly;
  final bool includeJpegTurbo;
  final bool includeWebpRoi;
  final String outputPath;
  final String? baselinePath;
  final String? evidenceOutputPath;
  final String? verifyEvidencePath;
  final String? requiredGitCommit;

  factory _Options.parse(List<String> args) {
    var smoke = false;
    var captureOnly = false;
    var includeJpegTurbo = false;
    var includeWebpRoi = false;
    var outputPath = 'build/reports/pixa_benchmark_report.md';
    String? baselinePath;
    String? evidenceOutputPath;
    String? verifyEvidencePath;
    String? requiredGitCommit;
    for (final String arg in args) {
      if (arg == '--smoke') {
        smoke = true;
      } else if (arg == '--capture-only') {
        captureOnly = true;
      } else if (arg == '--include-jpeg-turbo') {
        includeJpegTurbo = true;
      } else if (arg == '--include-webp-roi') {
        includeWebpRoi = true;
      } else if (arg.startsWith('--output=')) {
        outputPath = arg.substring('--output='.length);
      } else if (arg.startsWith('--baseline=')) {
        baselinePath = arg.substring('--baseline='.length);
      } else if (arg.startsWith('--evidence-output=')) {
        evidenceOutputPath = arg.substring('--evidence-output='.length);
      } else if (arg.startsWith('--verify-evidence=')) {
        verifyEvidencePath = arg.substring('--verify-evidence='.length);
      } else if (arg.startsWith('--require-git-commit=')) {
        requiredGitCommit = arg
            .substring('--require-git-commit='.length)
            .toLowerCase();
      } else {
        throw ArgumentError('Unknown benchmark report argument: $arg');
      }
    }
    for (final MapEntry<String, String?> path in <String, String?>{
      '--output': outputPath,
      '--baseline': baselinePath,
      '--evidence-output': evidenceOutputPath,
      '--verify-evidence': verifyEvidencePath,
    }.entries) {
      if (path.value != null && path.value!.trim().isEmpty) {
        throw ArgumentError('${path.key} must not be empty.');
      }
    }
    if (requiredGitCommit != null && !_isFullGitCommit(requiredGitCommit)) {
      throw ArgumentError('--require-git-commit must be a full Git commit.');
    }
    if (smoke &&
        (captureOnly ||
            baselinePath != null ||
            evidenceOutputPath != null ||
            verifyEvidencePath != null ||
            requiredGitCommit != null)) {
      throw ArgumentError(
        '--smoke is coverage-only and cannot be combined with full evidence '
        'options.',
      );
    }
    if (verifyEvidencePath != null) {
      if (baselinePath == null) {
        throw ArgumentError('--verify-evidence requires --baseline.');
      }
      if (captureOnly ||
          evidenceOutputPath != null ||
          includeJpegTurbo ||
          includeWebpRoi) {
        throw ArgumentError(
          '--verify-evidence cannot be combined with benchmark execution '
          'options.',
        );
      }
    } else if (!smoke) {
      if (evidenceOutputPath == null) {
        throw ArgumentError('Full benchmark runs require --evidence-output.');
      }
      if (captureOnly && baselinePath != null) {
        throw ArgumentError('--capture-only must not use --baseline.');
      }
      if (!captureOnly && baselinePath == null) {
        throw ArgumentError('Full benchmark evaluation requires --baseline.');
      }
    }
    return _Options(
      smoke: smoke,
      captureOnly: captureOnly,
      includeJpegTurbo: includeJpegTurbo,
      includeWebpRoi: includeWebpRoi,
      outputPath: outputPath,
      baselinePath: baselinePath,
      evidenceOutputPath: evidenceOutputPath,
      verifyEvidencePath: verifyEvidencePath,
      requiredGitCommit: requiredGitCommit,
    );
  }
}

final class _BenchmarkCommand {
  const _BenchmarkCommand({
    required this.source,
    required this.executable,
    required this.arguments,
  });

  final String source;
  final String executable;
  final List<String> arguments;
}

final class _BenchmarkRow {
  const _BenchmarkRow({
    required this.source,
    required this.name,
    required this.iterations,
    required this.totalUs,
    required this.avgNs,
    required this.bytes,
  });

  final String source;
  final String name;
  final int iterations;
  final int totalUs;
  final num avgNs;
  final int bytes;

  factory _BenchmarkRow.fromJson(Map<String, Object?> json) {
    return _BenchmarkRow(
      source: _requiredString(json, 'source'),
      name: _requiredString(json, 'name'),
      iterations: _requiredInt(json, 'iterations'),
      totalUs: _requiredInt(json, 'totalUs'),
      avgNs: _requiredNumber(json, 'avgNs'),
      bytes: _requiredInt(json, 'bytes'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source,
    'name': name,
    'iterations': iterations,
    'totalUs': totalUs,
    'avgNs': avgNs,
    'bytes': bytes,
  };
}

final class _BenchmarkEvidence {
  const _BenchmarkEvidence({
    required this.schemaVersion,
    required this.evidenceLevel,
    required this.runId,
    required this.capturedAtUtc,
    required this.gitCommit,
    required this.gitTreeState,
    required this.environmentFingerprint,
    required this.environment,
    required this.includeJpegTurbo,
    required this.includeWebpRoi,
    required this.maximumRegressionRatio,
    required this.absoluteNoiseNanoseconds,
    required this.requiredCoverage,
    required this.rows,
  });

  factory _BenchmarkEvidence.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> features = _requiredObject(json, 'features');
    final Map<String, Object?> thresholds = _requiredObject(json, 'thresholds');
    final List<Object?> rawRows = _requiredList(json, 'rows');
    return _BenchmarkEvidence(
      schemaVersion: _requiredInt(json, 'schemaVersion'),
      evidenceLevel: _requiredString(json, 'evidenceLevel'),
      runId: _requiredString(json, 'runId'),
      capturedAtUtc: _requiredString(json, 'capturedAtUtc'),
      gitCommit: _requiredString(json, 'gitCommit'),
      gitTreeState: _requiredString(json, 'gitTreeState'),
      environmentFingerprint: _requiredString(json, 'environmentFingerprint'),
      environment: _requiredObject(json, 'environment'),
      includeJpegTurbo: _requiredBool(features, 'jpegTurboRoi'),
      includeWebpRoi: _requiredBool(features, 'webpRoi'),
      maximumRegressionRatio: _requiredNumber(
        thresholds,
        'maximumRegressionRatio',
      ).toDouble(),
      absoluteNoiseNanoseconds: _requiredInt(
        thresholds,
        'absoluteNoiseNanoseconds',
      ),
      requiredCoverage: List<String>.unmodifiable(
        _requiredList(
          json,
          'requiredCoverage',
        ).map((Object? value) => value?.toString() ?? ''),
      ),
      rows: List<_BenchmarkRow>.unmodifiable(
        rawRows.map(
          (Object? value) =>
              _BenchmarkRow.fromJson(_jsonObject(value, 'benchmark row')),
        ),
      ),
    );
  }

  final int schemaVersion;
  final String evidenceLevel;
  final String runId;
  final String capturedAtUtc;
  final String gitCommit;
  final String gitTreeState;
  final String environmentFingerprint;
  final Map<String, Object?> environment;
  final bool includeJpegTurbo;
  final bool includeWebpRoi;
  final double maximumRegressionRatio;
  final int absoluteNoiseNanoseconds;
  final List<String> requiredCoverage;
  final List<_BenchmarkRow> rows;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'evidenceLevel': evidenceLevel,
    'runId': runId,
    'capturedAtUtc': capturedAtUtc,
    'gitCommit': gitCommit,
    'gitTreeState': gitTreeState,
    'environmentFingerprint': environmentFingerprint,
    'environment': environment,
    'features': <String, Object?>{
      'jpegTurboRoi': includeJpegTurbo,
      'webpRoi': includeWebpRoi,
    },
    'thresholds': <String, Object?>{
      'maximumRegressionRatio': maximumRegressionRatio,
      'absoluteNoiseNanoseconds': absoluteNoiseNanoseconds,
    },
    'requiredCoverage': requiredCoverage,
    'rows': <Object?>[for (final _BenchmarkRow row in rows) row.toJson()],
  };
}

final class _BenchmarkEvaluation {
  const _BenchmarkEvaluation({
    required this.current,
    required this.baseline,
    required this.comparisons,
    required this.failures,
  });

  final _BenchmarkEvidence current;
  final _BenchmarkEvidence baseline;
  final List<_BenchmarkComparison> comparisons;
  final List<String> failures;

  bool get passed => failures.isEmpty;
}

final class _BenchmarkComparison {
  const _BenchmarkComparison({
    required this.current,
    required this.baseline,
    required this.allowedNanoseconds,
    required this.passed,
  });

  final _BenchmarkRow current;
  final _BenchmarkRow baseline;
  final double allowedNanoseconds;
  final bool passed;
}

Map<String, Object?> _requiredObject(Map<String, Object?> json, String key) {
  return _jsonObject(json[key], key);
}

Map<String, Object?> _jsonObject(Object? value, String label) {
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  throw FormatException('Benchmark evidence $label must be an object.');
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is List) {
    return List<Object?>.from(value);
  }
  throw FormatException('Benchmark evidence $key must be a list.');
}

String _requiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Benchmark evidence $key must be a string.');
}

int _requiredInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Benchmark evidence $key must be an integer.');
}

num _requiredNumber(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is num) {
    return value;
  }
  throw FormatException('Benchmark evidence $key must be numeric.');
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Benchmark evidence $key must be boolean.');
}
