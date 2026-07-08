import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final platform = options.platform ?? _hostDesktopPlatform();
  final deviceId = options.deviceId ?? _defaultDeviceId(platform);
  final projectDir = Directory(options.projectDir).absolute;
  final workflowFile = File(options.workflow).absolute;
  final outputRoot = Directory(
    options.outputRoot ?? 'build/reports/pixa_gallery_cockpit_$platform',
  ).absolute;

  if (!projectDir.existsSync()) {
    throw StateError(
      'Gallery example directory does not exist: ${projectDir.path}',
    );
  }
  if (!workflowFile.existsSync()) {
    throw StateError(
      'Cockpit workflow file does not exist: ${workflowFile.path}',
    );
  }

  outputRoot.createSync(recursive: true);

  if (!options.skipPubGet) {
    final pubGetCode = await _run('flutter', const <String>[
      'pub',
      'get',
    ], workingDirectory: projectDir.path);
    if (pubGetCode != 0) {
      exit(pubGetCode);
    }
  }

  final workflow = _workflowForPlatform(
    workflowFile.readAsStringSync(),
    platform,
  );
  final configFile = File(
    '${outputRoot.path}${Platform.pathSeparator}validate_task.yaml',
  );
  configFile.writeAsStringSync(
    _validateTaskConfig(
      projectDir: projectDir.path,
      platform: platform,
      deviceId: deviceId,
      sessionPort: options.sessionPort,
      launchTimeoutSeconds: options.launchTimeoutSeconds,
      outputRoot: outputRoot.path,
      scriptPath:
          '${outputRoot.path}${Platform.pathSeparator}pixa_gallery_acceptance.yaml',
      workflow: workflow,
    ),
  );

  stdout.writeln('Pixa gallery cockpit acceptance');
  stdout.writeln('  platform: $platform');
  stdout.writeln('  deviceId: $deviceId');
  stdout.writeln('  config: ${configFile.path}');

  final result = await _runCaptured(Platform.resolvedExecutable, <String>[
    'run',
    'cockpit',
    'validate-task',
    '--config',
    configFile.path,
    '--stdout-format',
    'json',
  ], workingDirectory: projectDir.path);
  final stdoutText = result.stdout as String;
  final stderrText = result.stderr as String;
  stderr.write(stderrText);
  if (result.exitCode != 0) {
    stdout.write(stdoutText);
    exit(result.exitCode);
  }

  final resultFile = File(
    '${outputRoot.path}${Platform.pathSeparator}validation_result.json',
  );
  resultFile.writeAsStringSync(stdoutText);
  final decoded = const JsonDecoder().convert(stdoutText);
  if (decoded is! Map<String, Object?>) {
    stdout.write(stdoutText);
    throw const FormatException(
      'Cockpit validation result must be a JSON map.',
    );
  }
  final classification = decoded['classification'];
  final next = decoded['recommendedNextStep'];
  stdout.writeln('  result: ${resultFile.path}');
  stdout.writeln('  classification: $classification');
  if (next != null) {
    stdout.writeln('  next: $next');
  }
  if (classification != 'completed') {
    final failureSummary = _failureSummary(decoded);
    if (failureSummary != null) {
      stderr.writeln('Cockpit acceptance failed: $failureSummary');
    }
    exit(1);
  }
}

Future<int> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<ProcessResult> _runCaptured(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory);
}

String? _failureSummary(Map<String, Object?> result) {
  final runTaskResult = result['runTaskResult'];
  if (runTaskResult is! Map<String, Object?>) {
    return null;
  }
  final bundleSummary = runTaskResult['bundleSummary'];
  if (bundleSummary is! Map<String, Object?>) {
    return null;
  }
  final manifest = bundleSummary['manifest'];
  if (manifest is! Map<String, Object?>) {
    return null;
  }
  final summary = manifest['failureSummary'];
  return summary is String && summary.isNotEmpty ? summary : null;
}

String _workflowForPlatform(String source, String platform) {
  final platformPattern = RegExp(r'^platform:\s*\S+\s*$', multiLine: true);
  if (!platformPattern.hasMatch(source)) {
    throw const FormatException('Cockpit workflow must declare a platform.');
  }
  return source.replaceFirst(platformPattern, 'platform: $platform');
}

String _validateTaskConfig({
  required String projectDir,
  required String platform,
  required String deviceId,
  required int sessionPort,
  required int launchTimeoutSeconds,
  required String outputRoot,
  required String scriptPath,
  required String workflow,
}) {
  return '''
runTask:
  launch:
    projectDir: ${_yaml(projectDir)}
    target: cockpit/main.dart
    platform: ${_yaml(platform)}
    deviceId: ${_yaml(deviceId)}
    sessionPort: $sessionPort
    launchTimeoutSeconds: $launchTimeoutSeconds
  outputRoot: ${_yaml(outputRoot)}
  persistScriptPath: ${_yaml(scriptPath)}
  liveRunDisplayName: Pixa gallery cockpit acceptance
  baseline:
    captureScreenshot: true
    screenshotName: pixa-gallery-baseline
    includeSnapshot: true
  requirements:
    requireScreenshotEvidence: true
  script:
${_indent(workflow, 4)}
validation:
  expectedClassification: completed
  requirePrimaryScreenshot: true
  requireArtifactFiles: true
''';
}

String _indent(String value, int spaces) {
  final prefix = ' ' * spaces;
  return value
      .split('\n')
      .map((line) => line.isEmpty ? prefix : '$prefix$line')
      .join('\n');
}

String _yaml(String value) => "'${value.replaceAll("'", "''")}'";

String _hostDesktopPlatform() {
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  throw UnsupportedError(
    'Pass --platform and --device-id for this host platform.',
  );
}

String _defaultDeviceId(String platform) {
  return switch (platform) {
    'linux' || 'macos' || 'windows' => platform,
    _ => throw ArgumentError(
      '--device-id is required when --platform=$platform.',
    ),
  };
}

final class _Options {
  const _Options({
    required this.help,
    required this.projectDir,
    required this.workflow,
    required this.platform,
    required this.deviceId,
    required this.outputRoot,
    required this.sessionPort,
    required this.launchTimeoutSeconds,
    required this.skipPubGet,
  });

  final bool help;
  final String projectDir;
  final String workflow;
  final String? platform;
  final String? deviceId;
  final String? outputRoot;
  final int sessionPort;
  final int launchTimeoutSeconds;
  final bool skipPubGet;

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    var help = false;
    var skipPubGet = false;
    for (final arg in args) {
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--skip-pub-get') {
        skipPubGet = true;
      } else if (arg.startsWith('--') && arg.contains('=')) {
        final separator = arg.indexOf('=');
        values[arg.substring(2, separator)] = arg.substring(separator + 1);
      } else {
        throw ArgumentError('Unknown argument: $arg');
      }
    }
    return _Options(
      help: help,
      projectDir: values['project-dir'] ?? 'examples/pixa_gallery',
      workflow:
          values['workflow'] ??
          'examples/pixa_gallery/cockpit/pixa_gallery_acceptance.yaml',
      platform: values['platform'],
      deviceId: values['device-id'],
      outputRoot: values['output-root'],
      sessionPort: int.parse(values['session-port'] ?? '47331'),
      launchTimeoutSeconds: int.parse(
        values['launch-timeout-seconds'] ?? '240',
      ),
      skipPubGet: skipPubGet,
    );
  }
}

const _usage = '''
Usage: dart run tool/pixa_gallery_cockpit_acceptance.dart [options]

Runs the gallery example cockpit acceptance workflow through validate-task.

Options:
  --platform=<platform>                android, ios, linux, macos, or windows.
  --device-id=<id>                     Required for android and ios.
  --project-dir=<path>                 Defaults to examples/pixa_gallery.
  --workflow=<path>                    Defaults to the committed acceptance YAML.
  --output-root=<path>                 Defaults to build/reports/pixa_gallery_cockpit_<platform>.
  --session-port=<port>                Defaults to 47331.
  --launch-timeout-seconds=<seconds>   Defaults to 240.
  --skip-pub-get                       Do not run flutter pub get first.
''';
