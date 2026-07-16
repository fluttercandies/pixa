import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final ({String? commit, bool clean}) git = _currentGitState();
  late final ReleasePreflightOptions options;
  try {
    options = ReleasePreflightOptions.parse(
      args,
      currentGitCommit: git.commit,
      currentGitTreeClean: git.clean,
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final ReleasePreflightPlan plan = ReleasePreflightPlan.create(options);
  stdout.writeln(
    'Pixa release preflight: ${plan.steps.length} steps'
    '${options.dryRun ? ' (dry run)' : ''}.',
  );
  for (final ReleasePreflightStep step in plan.steps) {
    stdout.writeln('\n==> ${step.label}');
    stdout.writeln('    ${step.commandLine}');
  }
  if (options.dryRun) {
    return;
  }

  final ReleasePreflightExecutor executor = ReleasePreflightExecutor(
    plan: plan,
    runner: _runReleaseStep,
  );
  try {
    await executor.run();
  } on ReleasePreflightFailure catch (failure) {
    stderr.writeln(failure);
    exitCode = failure.exitCode > 0 ? failure.exitCode : 1;
    return;
  }
  stdout.writeln('\nPixa release preflight passed.');
}

/// Immutable command plan for one release preflight run.
final class ReleasePreflightPlan {
  ReleasePreflightPlan(List<ReleasePreflightStep> steps)
    : steps = List<ReleasePreflightStep>.unmodifiable(steps);

  final List<ReleasePreflightStep> steps;

  factory ReleasePreflightPlan.create(ReleasePreflightOptions options) {
    final String platformReports =
        options.platformReports ?? '<required-platform-reports>';
    final String nativeAssetsLog =
        options.nativeAssetsLog ?? '<required-native-assets-log>';
    final String profileInput =
        options.profileInput ?? '<required-profile-input>';
    final String profileBaseline =
        options.profileBaseline ?? '<required-profile-baseline>';
    final String benchmarkInput =
        options.benchmarkInput ?? '<required-benchmark-input>';
    final String benchmarkBaseline =
        options.benchmarkBaseline ?? '<required-benchmark-baseline>';
    final String gitCommit = options.gitCommit ?? '<current-git-commit>';
    return ReleasePreflightPlan(<ReleasePreflightStep>[
      const ReleasePreflightStep(
        id: 'dart-fix',
        label: 'Apply Dart fixes',
        executable: 'dart',
        arguments: <String>['fix', '--apply'],
      ),
      const ReleasePreflightStep(
        id: 'dart-format',
        label: 'Format Dart sources',
        executable: 'dart',
        arguments: <String>['format', '.'],
      ),
      const ReleasePreflightStep(
        id: 'dart-analyze',
        label: 'Analyze Dart workspace',
        executable: 'dart',
        arguments: <String>['analyze'],
      ),
      const ReleasePreflightStep(
        id: 'release-preflight-self-test',
        label: 'Self-test release preflight contract',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_release_preflight_self_test.dart',
        ],
      ),
      const ReleasePreflightStep(
        id: 'dartdoc-pixa',
        label: 'Generate strict pixa API documentation',
        executable: 'dart',
        arguments: <String>[
          'doc',
          '--validate-links',
          '--output=../../build/dartdoc/pixa',
        ],
        workingDirectory: 'packages/pixa',
      ),
      const ReleasePreflightStep(
        id: 'dartdoc-s3',
        label: 'Generate strict S3 plugin API documentation',
        executable: 'dart',
        arguments: <String>[
          'doc',
          '--validate-links',
          '--output=../../build/dartdoc/pixa_fetcher_s3',
        ],
        workingDirectory: 'packages/pixa_fetcher_s3',
      ),
      const ReleasePreflightStep(
        id: 'dartdoc-mjpeg',
        label: 'Generate strict MJPEG plugin API documentation',
        executable: 'dart',
        arguments: <String>[
          'doc',
          '--validate-links',
          '--output=../../build/dartdoc/pixa_video_frame_mjpeg',
        ],
        workingDirectory: 'packages/pixa_video_frame_mjpeg',
      ),
      const ReleasePreflightStep(
        id: 'flutter-tests',
        label: 'Run Flutter tests',
        executable: 'melos',
        arguments: <String>['run', 'test'],
      ),
      const ReleasePreflightStep(
        id: 'rust-format',
        label: 'Check Rust formatting',
        executable: 'rustup',
        arguments: <String>[
          'run',
          '1.89.0',
          'cargo',
          'fmt',
          '--manifest-path',
          'packages/pixa/native_src/rust/Cargo.toml',
          '--all',
          '--check',
        ],
      ),
      const ReleasePreflightStep(
        id: 'rust-clippy',
        label: 'Run Rust clippy',
        executable: 'rustup',
        arguments: <String>[
          'run',
          '1.89.0',
          'cargo',
          'clippy',
          '--manifest-path',
          'packages/pixa/native_src/rust/Cargo.toml',
          '--target-dir',
          'build/rust-target',
          '--all-targets',
          '--all-features',
          '--',
          '-D',
          'warnings',
        ],
      ),
      const ReleasePreflightStep(
        id: 'rust-audit',
        label: 'Audit Rust dependencies',
        executable: 'rustup',
        arguments: <String>[
          'run',
          '1.89.0',
          'cargo',
          'audit',
          '-f',
          'packages/pixa/native_src/rust/Cargo.lock',
          '-D',
          'warnings',
        ],
      ),
      const ReleasePreflightStep(
        id: 'rust-tests',
        label: 'Run Rust tests',
        executable: 'rustup',
        arguments: <String>[
          'run',
          '1.89.0',
          'cargo',
          'test',
          '--manifest-path',
          'packages/pixa/native_src/rust/Cargo.toml',
          '--target-dir',
          'build/rust-target',
          '--all',
          '--no-fail-fast',
        ],
      ),
      const ReleasePreflightStep(
        id: 'guard-self-test',
        label: 'Self-test architecture guard helpers',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_guard_self_test.dart'],
      ),
      const ReleasePreflightStep(
        id: 'guard',
        label: 'Run architecture guard',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_guard.dart'],
      ),
      const ReleasePreflightStep(
        id: 'platform-self-check',
        label: 'Run host platform self-check',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_platform_self_check.dart'],
      ),
      const ReleasePreflightStep(
        id: 'platform-evidence-self-test',
        label: 'Self-test platform evidence verifier',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_platform_evidence_self_test.dart',
        ],
      ),
      const ReleasePreflightStep(
        id: 'native-assets-log-self-test',
        label: 'Self-test Native Assets log verifier',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_native_assets_log_check_self_test.dart',
        ],
      ),
      ReleasePreflightStep(
        id: 'native-assets-log',
        label: 'Validate Native Assets framework warnings',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_native_assets_log_check.dart',
          '--log=$nativeAssetsLog',
          '--require-git-commit=$gitCommit',
          '--require-mode=profile',
        ],
      ),
      const ReleasePreflightStep(
        id: 'cockpit-wrapper-self-test',
        label: 'Self-test gallery cockpit wrapper',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_gallery_cockpit_acceptance_self_test.dart',
        ],
      ),
      const ReleasePreflightStep(
        id: 'benchmark-self-test',
        label: 'Self-test benchmark report',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_benchmark_report_self_test.dart'],
      ),
      const ReleasePreflightStep(
        id: 'profile-report-self-test',
        label: 'Self-test profile evidence verifier',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_profile_report_self_test.dart'],
      ),
      const ReleasePreflightStep(
        id: 'profile-acceptance-self-test',
        label: 'Self-test profile acceptance runner',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_profile_acceptance_self_test.dart',
        ],
      ),
      const ReleasePreflightStep(
        id: 'pub-smoke-self-test',
        label: 'Self-test hosted dependency smoke',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_pub_dependency_smoke_self_test.dart',
        ],
      ),
      const ReleasePreflightStep(
        id: 'gallery-analyze',
        label: 'Analyze gallery example',
        executable: 'melos',
        arguments: <String>['run', 'example'],
      ),
      const ReleasePreflightStep(
        id: 'gallery-tests',
        label: 'Run gallery corpus and harness tests',
        executable: 'flutter',
        arguments: <String>['test', '--concurrency=1'],
        workingDirectory: 'examples/pixa_gallery',
      ),
      const ReleasePreflightStep(
        id: 'gallery-cockpit',
        label: 'Run gallery cockpit acceptance',
        executable: 'melos',
        arguments: <String>['run', 'example:cockpit'],
      ),
      const ReleasePreflightStep(
        id: 'benchmark-smoke',
        label: 'Run non-release benchmark coverage smoke',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_benchmark_report.dart',
          '--smoke',
        ],
      ),
      ReleasePreflightStep(
        id: 'benchmark-evidence',
        label: 'Validate full benchmark baseline evidence',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_benchmark_report.dart',
          '--verify-evidence=$benchmarkInput',
          '--baseline=$benchmarkBaseline',
          '--output=build/reports/pixa_benchmark_release_report.md',
          '--require-git-commit=$gitCommit',
        ],
      ),
      ReleasePreflightStep(
        id: 'profile-evidence',
        label: 'Validate 120Hz profile, memory, and Picsum evidence',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_profile_report.dart',
          '--input=$profileInput',
          '--baseline=$profileBaseline',
          '--output=build/reports/pixa_profile_scroll_release_report.md',
          '--require-live-network',
        ],
      ),
      const ReleasePreflightStep(
        id: 'publish-dry-run-pixa',
        label: 'Validate pixa publication archive',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_pub_dependency_smoke.dart',
          '--dry-run-package=pixa',
        ],
      ),
      const ReleasePreflightStep(
        id: 'publish-dry-run-s3',
        label: 'Validate S3 plugin publication archive',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_pub_dependency_smoke.dart',
          '--dry-run-package=s3',
        ],
      ),
      const ReleasePreflightStep(
        id: 'publish-dry-run-mjpeg',
        label: 'Validate MJPEG plugin publication archive',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_pub_dependency_smoke.dart',
          '--dry-run-package=mjpeg',
        ],
      ),
      const ReleasePreflightStep(
        id: 'pub-dependency-smoke',
        label: 'Run hosted dependency runtime smoke',
        executable: 'dart',
        arguments: <String>['run', 'tool/pixa_pub_dependency_smoke.dart'],
      ),
      ReleasePreflightStep(
        id: 'platform-evidence',
        label: 'Validate hosted five-platform evidence',
        executable: 'dart',
        arguments: <String>[
          'run',
          'tool/pixa_platform_evidence.dart',
          '--reports=$platformReports',
          '--require-platforms=android,ios,linux,macos,windows',
          '--require-run-mode=integration-test',
          '--require-native-modules=jpeg-turbo-roi,webp-roi',
          '--require-git-commit=$gitCommit',
        ],
      ),
      const ReleasePreflightStep(
        id: 'git-diff-check',
        label: 'Check release diff whitespace',
        executable: 'git',
        arguments: <String>['diff', '--check'],
      ),
    ]);
  }
}

/// One typed external command in the release contract.
final class ReleasePreflightStep {
  const ReleasePreflightStep({
    required this.id,
    required this.label,
    required this.executable,
    required this.arguments,
    this.workingDirectory,
  });

  final String id;
  final String label;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  String get commandLine {
    final String command = <String>[
      executable,
      ...arguments,
    ].map(_quote).join(' ');
    final String? directory = workingDirectory;
    return directory == null
        ? command
        : '(cd ${_quote(directory)} && $command)';
  }
}

/// Injectable operating-system boundary for release commands.
typedef ReleasePreflightRunner =
    Future<int> Function(ReleasePreflightStep step);

/// Executes a release plan sequentially and fails at the first bad command.
final class ReleasePreflightExecutor {
  const ReleasePreflightExecutor({required this.plan, required this.runner});

  final ReleasePreflightPlan plan;
  final ReleasePreflightRunner runner;

  Future<void> run() async {
    for (final ReleasePreflightStep step in plan.steps) {
      final int stepExitCode = await runner(step);
      if (stepExitCode != 0) {
        throw ReleasePreflightFailure(step: step, exitCode: stepExitCode);
      }
    }
  }
}

/// Failure from one concrete command in a release plan.
final class ReleasePreflightFailure implements Exception {
  const ReleasePreflightFailure({required this.step, required this.exitCode});

  final ReleasePreflightStep step;
  final int exitCode;

  @override
  String toString() {
    return 'Pixa release preflight failed at "${step.label}" '
        'with exit code $exitCode.';
  }
}

/// Parsed release preflight command-line options.
final class ReleasePreflightOptions {
  const ReleasePreflightOptions({
    required this.dryRun,
    required this.help,
    required this.platformReports,
    required this.nativeAssetsLog,
    required this.profileInput,
    required this.profileBaseline,
    required this.benchmarkInput,
    required this.benchmarkBaseline,
    required this.gitCommit,
  });

  final bool dryRun;
  final bool help;
  final String? platformReports;
  final String? nativeAssetsLog;
  final String? profileInput;
  final String? profileBaseline;
  final String? benchmarkInput;
  final String? benchmarkBaseline;
  final String? gitCommit;

  factory ReleasePreflightOptions.parse(
    List<String> args, {
    Map<String, String>? environment,
    String? currentGitCommit,
    bool? currentGitTreeClean,
  }) {
    var dryRun = false;
    var help = false;
    String? platformReports =
        environment?['PIXA_PLATFORM_REPORTS'] ??
        Platform.environment['PIXA_PLATFORM_REPORTS'];
    String? nativeAssetsLog =
        environment?['PIXA_NATIVE_ASSETS_LOG'] ??
        Platform.environment['PIXA_NATIVE_ASSETS_LOG'];
    String? profileInput =
        environment?['PIXA_PROFILE_INPUT'] ??
        Platform.environment['PIXA_PROFILE_INPUT'];
    String? profileBaseline =
        environment?['PIXA_PROFILE_BASELINE'] ??
        Platform.environment['PIXA_PROFILE_BASELINE'];
    String? benchmarkInput =
        environment?['PIXA_BENCHMARK_INPUT'] ??
        Platform.environment['PIXA_BENCHMARK_INPUT'];
    String? benchmarkBaseline =
        environment?['PIXA_BENCHMARK_BASELINE'] ??
        Platform.environment['PIXA_BENCHMARK_BASELINE'];
    String? gitCommit =
        environment?['PIXA_PLATFORM_GIT_COMMIT'] ??
        environment?['GITHUB_SHA'] ??
        Platform.environment['PIXA_PLATFORM_GIT_COMMIT'] ??
        Platform.environment['GITHUB_SHA'] ??
        currentGitCommit;
    for (final String arg in args) {
      if (arg.startsWith('--platform-reports=')) {
        platformReports = arg.substring('--platform-reports='.length).trim();
      } else if (arg.startsWith('--native-assets-log=')) {
        nativeAssetsLog = arg.substring('--native-assets-log='.length).trim();
      } else if (arg.startsWith('--profile-input=')) {
        profileInput = arg.substring('--profile-input='.length).trim();
      } else if (arg.startsWith('--profile-baseline=')) {
        profileBaseline = arg.substring('--profile-baseline='.length).trim();
      } else if (arg.startsWith('--benchmark-input=')) {
        benchmarkInput = arg.substring('--benchmark-input='.length).trim();
      } else if (arg.startsWith('--benchmark-baseline=')) {
        benchmarkBaseline = arg
            .substring('--benchmark-baseline='.length)
            .trim();
      } else if (arg.startsWith('--git-commit=')) {
        gitCommit = arg.substring('--git-commit='.length).trim().toLowerCase();
      } else {
        switch (arg) {
          case '--dry-run':
            dryRun = true;
          case '-h' || '--help':
            help = true;
          default:
            throw FormatException('Unknown release preflight argument: $arg');
        }
      }
    }
    if (platformReports != null && platformReports.isEmpty) {
      throw const FormatException('--platform-reports must not be empty.');
    }
    if (nativeAssetsLog != null && nativeAssetsLog.isEmpty) {
      throw const FormatException('--native-assets-log must not be empty.');
    }
    if (profileInput != null && profileInput.isEmpty) {
      throw const FormatException('--profile-input must not be empty.');
    }
    if (profileBaseline != null && profileBaseline.isEmpty) {
      throw const FormatException('--profile-baseline must not be empty.');
    }
    if (benchmarkInput != null && benchmarkInput.isEmpty) {
      throw const FormatException('--benchmark-input must not be empty.');
    }
    if (benchmarkBaseline != null && benchmarkBaseline.isEmpty) {
      throw const FormatException('--benchmark-baseline must not be empty.');
    }
    if (gitCommit != null &&
        !RegExp(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$').hasMatch(gitCommit)) {
      throw const FormatException('--git-commit must be a full Git object id.');
    }
    if (gitCommit != null &&
        currentGitCommit != null &&
        gitCommit != currentGitCommit.toLowerCase()) {
      throw FormatException(
        'Release evidence commit $gitCommit does not match current HEAD '
        '${currentGitCommit.toLowerCase()}.',
      );
    }
    gitCommit = currentGitCommit?.toLowerCase() ?? gitCommit;
    if (!dryRun &&
        !help &&
        (platformReports == null ||
            nativeAssetsLog == null ||
            profileInput == null ||
            profileBaseline == null ||
            benchmarkInput == null ||
            benchmarkBaseline == null ||
            gitCommit == null)) {
      throw const FormatException(
        'Release execution requires platform reports, a Native Assets build '
        'log, current and baseline profile evidence, current and baseline '
        'benchmark evidence, and the current Git commit. Use '
        '--platform-reports=<directory>, '
        '--native-assets-log=<file>, --profile-input=<file>, and '
        '--profile-baseline=<file>, --benchmark-input=<file>, and '
        '--benchmark-baseline=<file>; the commit is resolved from Git.',
      );
    }
    if (!dryRun && !help && currentGitTreeClean != true) {
      throw const FormatException(
        'Release execution requires a clean Git worktree before validation.',
      );
    }
    return ReleasePreflightOptions(
      dryRun: dryRun,
      help: help,
      platformReports: platformReports,
      nativeAssetsLog: nativeAssetsLog,
      profileInput: profileInput,
      profileBaseline: profileBaseline,
      benchmarkInput: benchmarkInput,
      benchmarkBaseline: benchmarkBaseline,
      gitCommit: gitCommit,
    );
  }
}

({String? commit, bool clean}) _currentGitState() {
  final ProcessResult commitResult = Process.runSync('git', const <String>[
    'rev-parse',
    'HEAD',
  ]);
  final String value = commitResult.stdout.toString().trim().toLowerCase();
  final String? commit =
      commitResult.exitCode == 0 &&
          RegExp(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$').hasMatch(value)
      ? value
      : null;
  final ProcessResult statusResult = Process.runSync('git', const <String>[
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
  ]);
  if (statusResult.exitCode != 0) {
    return (commit: commit, clean: false);
  }
  final Iterable<String> changes = const LineSplitter()
      .convert(statusResult.stdout.toString())
      .where((String line) => !_isReleaseLocalUntrackedPath(line));
  return (commit: commit, clean: changes.isEmpty);
}

bool _isReleaseLocalUntrackedPath(String statusLine) {
  if (!statusLine.startsWith('?? ')) {
    return false;
  }
  final String path = statusLine.substring(3).trim();
  return path == 'AGENTS.md' ||
      path == 'GOALS.md' ||
      path == 'REF.md' ||
      path == '.third/' ||
      path.startsWith('.third/') ||
      path == 'docs/' ||
      path.startsWith('docs/');
}

Future<int> _runReleaseStep(ReleasePreflightStep step) async {
  final Process process = await Process.start(
    step.executable,
    step.arguments,
    workingDirectory: step.workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

String _quote(String value) {
  if (value.isEmpty || value.contains(RegExp(r'\s'))) {
    return "'${value.replaceAll("'", r"'\''")}'";
  }
  return value;
}

const String _usage = '''
Usage: dart run tool/pixa_release_preflight.dart [options]

Runs the local release gate in the same order expected before publishing:
Dart fixes/format/analyze/dartdoc, Flutter tests, Rust fmt/clippy/audit/tests,
architecture guard, package publish dry-runs, hosted dependency runtime smoke,
Cockpit acceptance, non-release benchmark smoke, full benchmark/profile
evidence, and hosted five-platform evidence.

Options:
  --platform-reports=<directory>  Required hosted platform report directory.
                                  PIXA_PLATFORM_REPORTS is also accepted.
  --native-assets-log=<file>      Required profile/release Native Assets log.
                                  PIXA_NATIVE_ASSETS_LOG is also accepted.
  --profile-input=<file>          Required current 120Hz profile evidence JSON.
                                  PIXA_PROFILE_INPUT is also accepted.
  --profile-baseline=<file>       Required comparable profile baseline JSON.
                                  PIXA_PROFILE_BASELINE is also accepted.
  --benchmark-input=<file>        Required current full benchmark evidence JSON.
                                  PIXA_BENCHMARK_INPUT is also accepted.
  --benchmark-baseline=<file>     Required comparable benchmark baseline JSON.
                                  PIXA_BENCHMARK_BASELINE is also accepted.
  --git-commit=<object-id>        Commit required in platform evidence.
                                  Defaults to the current Git HEAD.
  --dry-run                       Print the plan without requiring evidence.
  --help                          Show this help text.
''';
