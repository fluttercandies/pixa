import 'dart:convert';
import 'dart:io';

import 'pixa_benchmark_report.dart' as report;

Future<void> main() async {
  final Set<String> coverage = report.requiredBenchmarkCoverageNames().toSet();
  for (final String requiredName in <String>[
    'scroll_prefetch_planning',
    'scroll_prefetch_rapid_overlap',
    'scroll_prefetch_recent_eviction',
    'image_completion_frame_gate_burst',
    'request_cache_key_memoized_hot_path',
    'format_route_capability_lookup',
    'runtime_only_route_plan_hot_path',
  ]) {
    _expect(
      coverage.contains(requiredName),
      'required benchmark coverage is missing $requiredName',
    );
  }
  for (final List<String> command in report.benchmarkRustCommands()) {
    _expect(
      command.take(4).join(' ') == 'rustup run 1.96.0 cargo',
      'Rust benchmarks must execute through the packaged 1.96.0 toolchain',
    );
  }
  _expect(
    report.benchmarkRustVersionCommand().join(' ') ==
        'rustup run 1.96.0 rustc --version',
    'benchmark metadata must report the same pinned Rust toolchain',
  );
  final Directory temp = await Directory.systemTemp.createTemp(
    'pixa_benchmark_report_test_',
  );
  try {
    const String commit = '0123456789abcdef0123456789abcdef01234567';
    final File baseline = File('${temp.path}/baseline.json');
    final File current = File('${temp.path}/current.json');
    final File output = File('${temp.path}/report.md');
    await baseline.writeAsString(
      jsonEncode(_evidence(coverage, runId: 'baseline', gitCommit: commit)),
    );
    await current.writeAsString(
      jsonEncode(
        _evidence(
          coverage,
          runId: 'current',
          gitCommit: commit,
          averageNanoseconds: 1100,
        ),
      ),
    );

    ProcessResult result = await _verify(
      current: current,
      baseline: baseline,
      output: output,
      commit: commit,
    );
    _expect(result.exitCode == 0, 'comparable full evidence should pass');
    final String passingReport = await output.readAsString();
    _expect(
      passingReport.contains('Result: **PASS**') &&
          passingReport.contains('Maximum regression ratio') &&
          passingReport.contains('Baseline comparison'),
      'full report must expose result, verifier thresholds, and baseline',
    );

    final Map<String, Object?> regressed = _evidence(
      coverage,
      runId: 'regressed',
      gitCommit: commit,
      averageNanoseconds: 1100,
    );
    final List<Object?> rows = regressed['rows']! as List<Object?>;
    (rows.first! as Map<String, Object?>)['avgNs'] = 5000;
    await current.writeAsString(jsonEncode(regressed));
    result = await _verify(
      current: current,
      baseline: baseline,
      output: output,
      commit: commit,
    );
    _expect(result.exitCode != 0, 'regressed full evidence must fail');
    final String failingReport = await output.readAsString();
    _expect(
      failingReport.contains('Result: **FAIL**') &&
          failingReport.contains(coverage.first),
      'regression report should name the failed benchmark',
    );

    await current.writeAsString(
      jsonEncode(
        _evidence(
          coverage,
          runId: 'smoke',
          gitCommit: commit,
          evidenceLevel: 'smoke',
        ),
      ),
    );
    result = await _verify(
      current: current,
      baseline: baseline,
      output: output,
      commit: commit,
    );
    _expect(
      result.exitCode != 0 && '${result.stderr}'.contains('release evidence'),
      'smoke evidence must never qualify for release',
    );

    await current.writeAsString(
      jsonEncode(
        _evidence(
          coverage,
          runId: 'stale',
          gitCommit: 'ffffffffffffffffffffffffffffffffffffffff',
        ),
      ),
    );
    result = await _verify(
      current: current,
      baseline: baseline,
      output: output,
      commit: commit,
    );
    _expect(
      result.exitCode != 0 && '${result.stderr}'.contains('current commit'),
      'stale benchmark evidence must be rejected',
    );
  } finally {
    await temp.delete(recursive: true);
  }
  stdout.writeln('Pixa benchmark report self-test passed.');
}

Map<String, Object?> _evidence(
  Set<String> coverage, {
  required String runId,
  required String gitCommit,
  String evidenceLevel = 'full',
  int averageNanoseconds = 1000,
}) {
  return <String, Object?>{
    'schemaVersion': 1,
    'evidenceLevel': evidenceLevel,
    'runId': runId,
    'capturedAtUtc': '2026-07-16T00:00:00.000Z',
    'gitCommit': gitCommit,
    'gitTreeState': 'clean',
    'environmentFingerprint': 'a'.padLeft(64, 'a'),
    'environment': <String, Object?>{
      'operatingSystem': 'fixture',
      'operatingSystemVersion': 'fixture-os',
      'architecture': 'arm64',
      'processors': 8,
      'dart': 'fixture-dart',
      'rust': 'fixture-rust',
      'flutter': 'fixture-flutter',
    },
    'features': <String, Object?>{'jpegTurboRoi': false, 'webpRoi': false},
    'thresholds': <String, Object?>{
      'maximumRegressionRatio': 0.35,
      'absoluteNoiseNanoseconds': 100,
    },
    'requiredCoverage': coverage.toList()..sort(),
    'rows': <Object?>[
      for (final String name in coverage)
        <String, Object?>{
          'source': 'fixture',
          'name': name,
          'iterations': 1000,
          'totalUs': 1000,
          'avgNs': averageNanoseconds,
          'bytes': 0,
        },
    ],
  };
}

Future<ProcessResult> _verify({
  required File current,
  required File baseline,
  required File output,
  required String commit,
}) {
  return Process.run(Platform.resolvedExecutable, <String>[
    'run',
    'tool/pixa_benchmark_report.dart',
    '--verify-evidence=${current.path}',
    '--baseline=${baseline.path}',
    '--output=${output.path}',
    '--require-git-commit=$commit',
  ]);
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
