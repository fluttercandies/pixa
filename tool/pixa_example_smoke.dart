import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final _Options options = _Options.parse(args);
  final Directory root = Directory.current;
  final Directory example = Directory('${root.path}/examples/pixa_gallery');
  if (!example.existsSync()) {
    throw StateError('Missing gallery example: ${example.path}');
  }

  final String flutter = _flutterExecutable();
  await _run(example, flutter, <String>['pub', 'get']);
  await _run(example, flutter, _buildCommand(options));
  await _runSmoke(
    example,
    flutter,
    _testCommand(options),
    environment: options.environment(root),
    reportPath: options.reportPath(root),
  );
}

final class _Options {
  const _Options({
    required this.platform,
    required this.deviceId,
    required this.reportOutput,
    required this.deviceKind,
    required this.connection,
    required this.signing,
  });

  final String platform;
  final String? deviceId;
  final String? reportOutput;
  final String? deviceKind;
  final String? connection;
  final String? signing;

  factory _Options.parse(List<String> args) {
    String? platform;
    String? deviceId;
    String? reportOutput;
    String? deviceKind;
    String? connection;
    String? signing;
    for (final String arg in args) {
      if (arg.startsWith('--platform=')) {
        platform = arg.substring('--platform='.length).trim().toLowerCase();
      } else if (arg.startsWith('--device=')) {
        deviceId = arg.substring('--device='.length).trim();
      } else if (arg.startsWith('--report-output=')) {
        reportOutput = arg.substring('--report-output='.length).trim();
      } else if (arg.startsWith('--device-kind=')) {
        deviceKind = arg.substring('--device-kind='.length).trim();
      } else if (arg.startsWith('--connection=')) {
        connection = arg.substring('--connection='.length).trim();
      } else if (arg.startsWith('--signing=')) {
        signing = arg.substring('--signing='.length).trim();
      } else {
        _usageAndExit();
      }
    }
    if (platform == null || !_supportedPlatforms.contains(platform)) {
      _usageAndExit();
    }
    if (deviceId != null && deviceId.isEmpty ||
        reportOutput != null && reportOutput.isEmpty ||
        deviceKind != null && deviceKind.isEmpty ||
        connection != null && connection.isEmpty ||
        signing != null && signing.isEmpty) {
      _usageAndExit();
    }
    return _Options(
      platform: platform,
      deviceId: deviceId,
      reportOutput: reportOutput,
      deviceKind: deviceKind,
      connection: connection,
      signing: signing,
    );
  }

  String reportPath(Directory root) {
    if (reportOutput == null) {
      return '${root.path}/build/reports/pixa_example_smoke_$platform.json';
    }
    return File(reportOutput!).isAbsolute
        ? reportOutput!
        : '${root.path}/$reportOutput';
  }

  Map<String, String> environment(Directory root) {
    return <String, String>{
      ...Platform.environment,
      'PIXA_EXAMPLE_SMOKE_REPORT': reportPath(root),
      'PIXA_EXAMPLE_EVIDENCE_PLATFORM': platform,
      if (deviceId != null) 'PIXA_EXAMPLE_EVIDENCE_DEVICE_ID': deviceId!,
      'PIXA_EXAMPLE_EVIDENCE_DEVICE_KIND':
          deviceKind ?? _defaultDeviceKind(platform),
      'PIXA_EXAMPLE_EVIDENCE_CONNECTION':
          connection ?? _defaultConnection(platform),
      'PIXA_EXAMPLE_EVIDENCE_SIGNING': signing ?? _defaultSigning(platform),
    };
  }
}

List<String> _buildCommand(_Options options) {
  return switch (options.platform) {
    'android' => <String>['build', 'apk', '--debug'],
    'ios' => <String>[
        'build',
        'ios',
        '--debug',
        '--simulator',
        '--no-codesign',
      ],
    'linux' => <String>['build', 'linux', '--debug'],
    'macos' => <String>['build', 'macos', '--debug'],
    'windows' => <String>['build', 'windows', '--debug'],
    _ => throw StateError('Unsupported platform ${options.platform}'),
  };
}

List<String> _testCommand(_Options options) {
  return <String>[
    'test',
    'integration_test/pixa_gallery_smoke_test.dart',
    '-d',
    options.deviceId ?? options.platform,
  ];
}

Future<void> _run(
  Directory workingDirectory,
  String executable,
  List<String> arguments,
) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final int exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(executable, arguments, 'command failed', exitCode);
  }
}

Future<void> _runSmoke(
  Directory workingDirectory,
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String reportPath,
}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final File staleReport = File(reportPath);
  if (staleReport.existsSync()) {
    staleReport.deleteSync();
  }
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory.path,
    environment: environment,
  );
  final StringBuffer output = StringBuffer();
  final Future<void> stdoutDone =
      process.stdout.transform(utf8.decoder).forEach((String chunk) {
    stdout.write(chunk);
    output.write(chunk);
  });
  final Future<void> stderrDone =
      process.stderr.transform(utf8.decoder).forEach((String chunk) {
    stderr.write(chunk);
    output.write(chunk);
  });
  final int exitCode = await process.exitCode;
  await stdoutDone;
  await stderrDone;
  if (exitCode != 0) {
    throw ProcessException(executable, arguments, 'command failed', exitCode);
  }
  final File report = File(reportPath);
  if (report.existsSync() && report.lengthSync() > 0) {
    return;
  }
  report.parent.createSync(recursive: true);
  report.writeAsStringSync(_extractSmokeReport(output.toString()));
}

String _extractSmokeReport(String output) {
  const String marker = 'PIXA_EXAMPLE_SMOKE_REPORT_JSON:';
  final int index = output.lastIndexOf(marker);
  if (index < 0) {
    throw StateError('Pixa example smoke did not emit report payload.');
  }
  final int valueStart = index + marker.length;
  final int valueEnd = output.indexOf(RegExp(r'\s'), valueStart);
  final String encoded = output
      .substring(valueStart, valueEnd < 0 ? output.length : valueEnd)
      .trim();
  return utf8.decode(base64Url.decode(encoded));
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

String _defaultDeviceKind(String platform) {
  return switch (platform) {
    'android' => 'emulator',
    'ios' => 'simulator',
    'linux' || 'macos' || 'windows' => 'desktop',
    _ => 'unknown',
  };
}

String _defaultConnection(String platform) {
  return switch (platform) {
    'android' || 'ios' || 'linux' || 'macos' || 'windows' => 'local',
    _ => 'unknown',
  };
}

String _defaultSigning(String platform) {
  return switch (platform) {
    'android' => 'debug',
    'ios' => 'debug',
    'linux' || 'macos' || 'windows' => 'not-applicable',
    _ => 'unknown',
  };
}

Never _usageAndExit() {
  stderr.writeln(_usage);
  exit(64);
}

const Set<String> _supportedPlatforms = <String>{
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
};

const String _usage = '''
Usage: dart run tool/pixa_example_smoke.dart --platform=<android|ios|linux|macos|windows>
  [--device=<flutter-device-id>] [--report-output=<path>]
  [--device-kind=<desktop|emulator|simulator>]
  [--connection=<local|usb|wireless>] [--signing=<debug|development|release|not-applicable>]
''';
