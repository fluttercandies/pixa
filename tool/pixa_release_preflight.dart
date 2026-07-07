import 'dart:io';

Future<void> main(List<String> args) async {
  final _Options options = _Options.parse(args);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final List<_Step> steps = _releaseSteps();
  stdout.writeln(
    'Pixa release preflight: ${steps.length} steps'
    '${options.dryRun ? ' (dry run)' : ''}.',
  );
  for (final _Step step in steps) {
    stdout.writeln('\n==> ${step.label}');
    stdout.writeln('    ${step.commandLine}');
    if (options.dryRun) {
      continue;
    }
    final int exitCode = await step.run();
    if (exitCode != 0) {
      stderr.writeln(
        'Pixa release preflight failed at "${step.label}" '
        'with exit code $exitCode.',
      );
      exitCode > 0 ? exit(exitCode) : exit(1);
    }
  }
  stdout.writeln('\nPixa release preflight passed.');
}

List<_Step> _releaseSteps() {
  return <_Step>[
    _Step('Apply Dart fixes', 'dart', <String>['fix', '--apply']),
    _Step('Format Dart sources', 'dart', <String>['format', '.']),
    _Step('Analyze Dart workspace', 'dart', <String>['analyze']),
    _Step('Run Flutter tests', 'melos', <String>['run', 'test']),
    _Step('Check Rust formatting', 'cargo', <String>[
      'fmt',
      '--manifest-path',
      'rust/Cargo.toml',
      '--all',
      '--check',
    ]),
    _Step('Run Rust clippy', 'cargo', <String>[
      'clippy',
      '--manifest-path',
      'rust/Cargo.toml',
      '--all-targets',
      '--all-features',
      '--',
      '-D',
      'warnings',
    ]),
    _Step('Run Rust tests', 'cargo', <String>[
      'test',
      '--manifest-path',
      'rust/Cargo.toml',
      '--all',
      '--no-fail-fast',
    ]),
    _Step('Run architecture guard', 'dart', <String>[
      'run',
      'tool/pixa_guard.dart',
    ]),
    _Step('Run platform self-check', 'dart', <String>[
      'run',
      'tool/pixa_platform_self_check.dart',
    ]),
    _Step('Run platform evidence verifier self-test', 'dart', <String>[
      'run',
      'tool/pixa_platform_evidence_self_test.dart',
    ]),
    _Step('Run example smoke wrapper self-test', 'dart', <String>[
      'run',
      'tool/pixa_example_smoke_self_test.dart',
    ]),
    _Step('Run benchmark report self-test', 'dart', <String>[
      'run',
      'tool/pixa_benchmark_report_self_test.dart',
    ]),
    _Step('Run example smoke check', 'melos', <String>['run', 'example']),
    _Step('Generate smoke benchmark report', 'dart', <String>[
      'run',
      'tool/pixa_benchmark_report.dart',
      '--smoke',
    ]),
  ];
}

final class _Step {
  const _Step(this.label, this.executable, this.arguments);

  final String label;
  final String executable;
  final List<String> arguments;

  String get commandLine {
    return <String>[executable, ...arguments].map(_quote).join(' ');
  }

  Future<int> run() async {
    final Process process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

final class _Options {
  const _Options({required this.dryRun, required this.help});

  final bool dryRun;
  final bool help;

  factory _Options.parse(List<String> args) {
    var dryRun = false;
    var help = false;
    for (final String arg in args) {
      switch (arg) {
        case '--dry-run':
          dryRun = true;
        case '-h' || '--help':
          help = true;
        default:
          throw ArgumentError('Unknown release preflight argument: $arg');
      }
    }
    return _Options(dryRun: dryRun, help: help);
  }
}

String _quote(String value) {
  if (value.isEmpty || value.contains(RegExp(r'\s'))) {
    return "'${value.replaceAll("'", r"'\''")}'";
  }
  return value;
}

const String _usage = '''
Usage: dart run tool/pixa_release_preflight.dart [--dry-run]

Runs the local release gate in the same order expected before publishing:
Dart fixes, formatting, analysis, Flutter tests, Rust fmt/clippy/tests,
architecture guard, platform self-check, example smoke, and benchmark smoke.

Options:
  --dry-run  Print the command plan without executing commands.
  --help     Show this help text.
''';
