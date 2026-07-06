import 'dart:convert';
import 'dart:io';

List<_BenchmarkCommand> _commands() => <_BenchmarkCommand>[
  _BenchmarkCommand(
    source: 'rust-core',
    executable: 'cargo',
    arguments: <String>[
      'run',
      '--release',
      '--manifest-path',
      'rust/Cargo.toml',
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
      'rust/Cargo.toml',
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
  'request key hot path': <String>['request_cache_key_memoized_hot_path'],
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
  'PIXA_BENCH_DECODE_ITERS': '20',
  'PIXA_BENCH_ANIMATED_ITERS': '10',
};

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  final _Options options = _Options.parse(args);
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
  output.writeAsStringSync(
    _renderReport(
      rows,
      smoke: options.smoke,
      includeJpegTurbo: options.includeJpegTurbo,
      includeWebpRoi: options.includeWebpRoi,
      coverage: coverage,
    ),
  );
  stdout.writeln('Benchmark report written to ${output.path}');
}

String get _usage => '''
Usage: dart run tool/pixa_benchmark_report.dart [--smoke] [--include-jpeg-turbo] [--include-webp-roi] [--output=<path>]

Runs Rust and Flutter benchmark harnesses, checks required production-gallery
coverage, and writes a local Markdown benchmark report.

Options:
  --smoke                Use tiny iteration counts for CI/tool verification.
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
    if (parts.length != 5) {
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

String _renderReport(
  List<_BenchmarkRow> rows, {
  required bool smoke,
  required bool includeJpegTurbo,
  required bool includeWebpRoi,
  required Map<String, List<String>> coverage,
}) {
  final StringBuffer buffer = StringBuffer();
  final DateTime now = DateTime.now().toUtc();
  buffer.writeln('# Pixa Benchmark Report');
  buffer.writeln();
  buffer.writeln('- Generated UTC: ${now.toIso8601String()}');
  buffer.writeln('- Mode: ${smoke ? 'smoke' : 'full'}');
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
  buffer.writeln('- Rust: ${_commandText('rustc', <String>['--version'])}');
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
    required this.includeJpegTurbo,
    required this.includeWebpRoi,
    required this.outputPath,
  });

  final bool smoke;
  final bool includeJpegTurbo;
  final bool includeWebpRoi;
  final String outputPath;

  factory _Options.parse(List<String> args) {
    var smoke = false;
    var includeJpegTurbo = false;
    var includeWebpRoi = false;
    var outputPath = 'build/reports/pixa_benchmark_report.md';
    for (final String arg in args) {
      if (arg == '--smoke') {
        smoke = true;
      } else if (arg == '--include-jpeg-turbo') {
        includeJpegTurbo = true;
      } else if (arg == '--include-webp-roi') {
        includeWebpRoi = true;
      } else if (arg.startsWith('--output=')) {
        outputPath = arg.substring('--output='.length);
      } else {
        throw ArgumentError('Unknown benchmark report argument: $arg');
      }
    }
    return _Options(
      smoke: smoke,
      includeJpegTurbo: includeJpegTurbo,
      includeWebpRoi: includeWebpRoi,
      outputPath: outputPath,
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
}
