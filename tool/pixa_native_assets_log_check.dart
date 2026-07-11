import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  late final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final File log = File(options.logPath);
  if (!log.existsSync()) {
    stderr.writeln('Native Assets build log does not exist: ${log.path}');
    exitCode = 1;
    return;
  }
  final NativeAssetFrameworkWarningReport report =
      NativeAssetFrameworkWarningReport.parse(
        log.readAsStringSync(),
        requiredGitCommit: options.requiredGitCommit,
        requiredMode: options.requiredMode,
      );
  final File output = File(options.outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n',
  );

  final List<String> failures = report.failures;
  if (failures.isNotEmpty) {
    stderr.writeln('Pixa Native Assets log validation failed:');
    for (final String failure in failures) {
      stderr.writeln('- $failure');
    }
    stderr.writeln('Report: ${output.path}');
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Pixa Native Assets log passed with ${report.warnings.length} '
    'classified framework warning(s). Report: ${output.path}',
  );
}

/// One framework-name collision emitted by Flutter Native Assets.
final class NativeAssetFrameworkWarning {
  const NativeAssetFrameworkWarning({
    required this.asset,
    required this.selectedFramework,
    required this.ignoredFramework,
    required this.classification,
  });

  final String asset;
  final String selectedFramework;
  final String ignoredFramework;
  final String classification;

  Map<String, Object?> toJson() => <String, Object?>{
    'asset': asset,
    'selectedFramework': selectedFramework,
    'ignoredFramework': ignoredFramework,
    'classification': classification,
  };
}

/// Parsed Native Assets framework warnings and release-blocking mismatches.
final class NativeAssetFrameworkWarningReport {
  const NativeAssetFrameworkWarningReport({
    required this.warnings,
    required this.failures,
    required this.hasPixaRuntimeEvidence,
    required this.platform,
    required this.mode,
    required this.gitCommit,
    required this.gitTreeState,
    required this.artifactPath,
    required this.artifactBytes,
    required this.artifactSha256,
    required this.buildCompleted,
  });

  final List<NativeAssetFrameworkWarning> warnings;
  final List<String> failures;
  final bool hasPixaRuntimeEvidence;
  final String? platform;
  final String? mode;
  final String? gitCommit;
  final String? gitTreeState;
  final String? artifactPath;
  final int? artifactBytes;
  final String? artifactSha256;
  final bool buildCompleted;

  bool get passed => failures.isEmpty && hasPixaRuntimeEvidence;

  factory NativeAssetFrameworkWarningReport.parse(
    String source, {
    String? requiredGitCommit,
    String? requiredMode,
  }) {
    final List<NativeAssetFrameworkWarning> warnings =
        <NativeAssetFrameworkWarning>[];
    final List<String> failures = <String>[];
    final List<({int line, Map<String, Object?> event})> evidenceEvents =
        <({int line, Map<String, Object?> event})>[];
    final Set<String> parsedLines = <String>{};
    for (final RegExpMatch match in _frameworkWarningPattern.allMatches(
      source,
    )) {
      final String asset = match.group(1)!;
      final String selected = match.group(2)!;
      final String ignored = match.group(3)!;
      final String? classification = _knownClassification(
        asset,
        selected,
        ignored,
      );
      if (classification == null) {
        failures.add(
          '$asset selected $selected and ignored $ignored; this framework '
          'mapping is not an approved Flutter toolchain collision',
        );
      } else {
        warnings.add(
          NativeAssetFrameworkWarning(
            asset: asset,
            selectedFramework: selected,
            ignoredFramework: ignored,
            classification: classification,
          ),
        );
      }
      parsedLines.add(match.group(0)!);
    }
    final List<String> sourceLines = const LineSplitter().convert(source);
    for (var lineIndex = 0; lineIndex < sourceLines.length; lineIndex += 1) {
      final String line = sourceLines[lineIndex];
      if (line.contains(
            'has different framework names for different architectures',
          ) &&
          !parsedLines.any(line.contains)) {
        failures.add(
          'unparsed Native Assets framework warning: ${line.trim()}',
        );
      }
      if (line.startsWith(nativeAssetsEvidencePrefix)) {
        final String payload = line.substring(
          nativeAssetsEvidencePrefix.length,
        );
        try {
          final Object? decoded = jsonDecode(payload);
          if (decoded is! Map<Object?, Object?>) {
            failures.add(
              'Native Assets evidence on line ${lineIndex + 1} is not an object',
            );
          } else {
            evidenceEvents.add((
              line: lineIndex + 1,
              event: decoded.map(
                (Object? key, Object? value) =>
                    MapEntry<String, Object?>(key.toString(), value),
              ),
            ));
          }
        } on FormatException catch (error) {
          failures.add(
            'Native Assets evidence on line ${lineIndex + 1} is invalid JSON: '
            '$error',
          );
        }
      }
    }
    final RegExpMatch? buildFailure = _buildFailurePattern.firstMatch(source);
    if (buildFailure != null) {
      failures.add(
        'Native Assets log contains build failure text: '
        '${buildFailure.group(0)!.trim()}',
      );
    }
    for (final ({int line, Map<String, Object?> event}) entry
        in evidenceEvents) {
      if (entry.event['schema'] != 1) {
        failures.add(
          'Native Assets evidence on line ${entry.line} must use schema 1.',
        );
      }
      if (!const <String>{
        'buildStart',
        'artifact',
        'buildComplete',
      }.contains(entry.event['event'])) {
        failures.add(
          'Native Assets evidence on line ${entry.line} has an unknown event.',
        );
      }
    }

    final List<({int line, Map<String, Object?> event})> starts = evidenceEvents
        .where((entry) => entry.event['event'] == 'buildStart')
        .toList(growable: false);
    final List<({int line, Map<String, Object?> event})> artifacts =
        evidenceEvents
            .where(
              (entry) =>
                  entry.event['event'] == 'artifact' &&
                  entry.event['asset'] == 'package:pixa/pixa_runtime',
            )
            .toList(growable: false);
    final List<({int line, Map<String, Object?> event})> completions =
        evidenceEvents
            .where((entry) => entry.event['event'] == 'buildComplete')
            .toList(growable: false);
    if (starts.length != 1) {
      failures.add(
        'Native Assets log must contain exactly one buildStart event.',
      );
    }
    if (artifacts.isEmpty) {
      failures.add(
        'Native Assets log must contain a Pixa runtime artifact event.',
      );
    }
    if (completions.length != 1) {
      failures.add(
        'Native Assets log must contain exactly one buildComplete event.',
      );
    }

    final Map<String, Object?>? start = starts.length == 1
        ? starts.single.event
        : null;
    final Map<String, Object?>? artifact = artifacts.isNotEmpty
        ? artifacts.last.event
        : null;
    final Map<String, Object?>? completion = completions.length == 1
        ? completions.single.event
        : null;
    final String? platform = _stringField(start, 'platform');
    final String? mode = _stringField(start, 'mode');
    final String? gitCommit = _stringField(start, 'gitCommit');
    final String? gitTreeState = _stringField(start, 'gitTreeState');
    final String? artifactPath = _stringField(artifact, 'path');
    final int? artifactBytes = _intField(artifact, 'bytes');
    final String? artifactSha256 = _stringField(artifact, 'sha256');
    final bool buildCompleted =
        completion?['status'] == 'succeeded' && completion?['exitCode'] == 0;

    if (!const <String>{
      'android',
      'ios',
      'linux',
      'macos',
      'windows',
    }.contains(platform)) {
      failures.add('Native Assets buildStart platform is unsupported.');
    }
    if (!const <String>{'profile', 'release'}.contains(mode)) {
      failures.add('Native Assets buildStart mode must be profile or release.');
    }
    if (requiredMode != null && mode != requiredMode) {
      failures.add(
        'Native Assets evidence mode $mode does not match required '
        '$requiredMode.',
      );
    }
    if (gitCommit == null || !_fullGitCommitPattern.hasMatch(gitCommit)) {
      failures.add('Native Assets buildStart must contain a full Git commit.');
    } else if (requiredGitCommit != null && gitCommit != requiredGitCommit) {
      failures.add(
        'Native Assets evidence Git commit $gitCommit does not match required '
        '$requiredGitCommit.',
      );
    }
    if (gitTreeState != 'clean') {
      failures.add('Native Assets evidence must come from a clean Git tree.');
    }
    if (artifactPath == null || artifactPath.trim().isEmpty) {
      failures.add('Pixa runtime artifact path must not be empty.');
    }
    if (artifactBytes == null || artifactBytes <= 0) {
      failures.add('Pixa runtime artifact byte size must be positive.');
    }
    if (artifactSha256 == null || !_sha256Pattern.hasMatch(artifactSha256)) {
      failures.add('Pixa runtime artifact must contain SHA-256 evidence.');
    }
    if (!buildCompleted) {
      failures.add('Native Assets build did not complete successfully.');
    }
    if (starts.length == 1 &&
        artifacts.isNotEmpty &&
        completions.length == 1 &&
        !(starts.single.line < artifacts.last.line &&
            artifacts.last.line < completions.single.line)) {
      failures.add('Native Assets evidence events are out of order.');
    }
    return NativeAssetFrameworkWarningReport(
      warnings: List<NativeAssetFrameworkWarning>.unmodifiable(warnings),
      failures: List<String>.unmodifiable(failures),
      hasPixaRuntimeEvidence: artifact != null,
      platform: platform,
      mode: mode,
      gitCommit: gitCommit,
      gitTreeState: gitTreeState,
      artifactPath: artifactPath,
      artifactBytes: artifactBytes,
      artifactSha256: artifactSha256,
      buildCompleted: buildCompleted,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'passed': passed,
    'hasPixaRuntimeEvidence': hasPixaRuntimeEvidence,
    'platform': platform,
    'mode': mode,
    'gitCommit': gitCommit,
    'gitTreeState': gitTreeState,
    'artifact': <String, Object?>{
      'path': artifactPath,
      'bytes': artifactBytes,
      'sha256': artifactSha256,
    },
    'buildCompleted': buildCompleted,
    'warnings': <Object?>[for (final warning in warnings) warning.toJson()],
    'failures': failures,
  };
}

String? _stringField(Map<String, Object?>? value, String key) {
  final Object? field = value?[key];
  return field is String ? field : null;
}

int? _intField(Map<String, Object?>? value, String key) {
  final Object? field = value?[key];
  return field is int ? field : null;
}

const String nativeAssetsEvidencePrefix = 'PIXA_NATIVE_ASSETS_EVIDENCE_JSON:';

final RegExp _frameworkWarningPattern = RegExp(
  r'Code asset "([^"]+)" has different framework names for different '
  r'architectures\. Picking "([^"]+)" and ignoring "([^"]+)"\.',
);
final RegExp _fullGitCommitPattern = RegExp(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _buildFailurePattern = RegExp(
  r'BUILD FAILED|Rust build failed|Unhandled exception|ProcessException|'
  r'(^|\s)Error:',
  caseSensitive: false,
  multiLine: true,
);

String? _knownClassification(String asset, String selected, String ignored) {
  const Map<String, Set<String>> known = <String, Set<String>>{
    'package:objective_c/objective_c.dylib': <String>{
      'objective_c.framework',
      'objective_c1.framework',
    },
    'package:pixa/pixa_runtime': <String>{
      'pixa_runtime.framework',
      'pixa_runtime1.framework',
    },
  };
  final Set<String>? expected = known[asset];
  if (expected == null ||
      !expected.contains(selected) ||
      !expected.contains(ignored) ||
      selected == ignored) {
    return null;
  }
  return 'flutter-3.44-framework-name-collision';
}

final class _Options {
  const _Options({
    required this.logPath,
    required this.outputPath,
    required this.requiredGitCommit,
    required this.requiredMode,
  });

  final String logPath;
  final String outputPath;
  final String? requiredGitCommit;
  final String? requiredMode;

  factory _Options.parse(List<String> args) {
    String? logPath;
    var outputPath = 'build/reports/pixa_native_assets_log_report.json';
    String? requiredGitCommit;
    String? requiredMode;
    for (final String arg in args) {
      if (arg.startsWith('--log=')) {
        logPath = arg.substring('--log='.length).trim();
      } else if (arg.startsWith('--output=')) {
        outputPath = arg.substring('--output='.length).trim();
      } else if (arg.startsWith('--require-git-commit=')) {
        requiredGitCommit = arg
            .substring('--require-git-commit='.length)
            .trim()
            .toLowerCase();
      } else if (arg.startsWith('--require-mode=')) {
        requiredMode = arg.substring('--require-mode='.length).trim();
      } else {
        throw FormatException('Unknown Native Assets log argument: $arg');
      }
    }
    if (logPath == null || logPath.isEmpty) {
      throw const FormatException('--log=<file> is required.');
    }
    if (outputPath.isEmpty) {
      throw const FormatException('--output must not be empty.');
    }
    if (requiredGitCommit != null &&
        !_fullGitCommitPattern.hasMatch(requiredGitCommit)) {
      throw const FormatException(
        '--require-git-commit must be a full Git object id.',
      );
    }
    if (requiredMode != null &&
        !const <String>{'profile', 'release'}.contains(requiredMode)) {
      throw const FormatException('--require-mode must be profile or release.');
    }
    return _Options(
      logPath: logPath,
      outputPath: outputPath,
      requiredGitCommit: requiredGitCommit,
      requiredMode: requiredMode,
    );
  }
}

const String _usage = '''
Usage: dart run tool/pixa_native_assets_log_check.dart --log=<file> [options]

Options:
  --output=<file>                 JSON evidence output path.
  --require-git-commit=<sha>      Require evidence from one exact Git commit.
  --require-mode=<profile|release>
                                  Require one Flutter build mode.
  --help                          Show this help text.
''';
