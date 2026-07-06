import 'dart:io';

Future<void> main(List<String> args) async {
  final Directory root = Directory.current;
  final String platform = _platformLabel();
  final String outputPath = _outputPath(root, args, platform);
  final Directory packageDir = Directory('${root.path}/packages/pixa');
  final String flutter = _flutterExecutable();

  await _run(
    packageDir,
    flutter,
    <String>[
      'test',
      'test/platform_self_check_smoke_test.dart',
      '--plain-name',
      'runtime platform self-check passes and can write a JSON report',
    ],
    environment: <String, String>{
      ...Platform.environment,
      'PIXA_PLATFORM_SELF_CHECK_REPORT': outputPath,
      'PIXA_PLATFORM_EVIDENCE_PLATFORM': platform,
      'PIXA_PLATFORM_EVIDENCE_RUN_MODE': 'flutter-test',
      'PIXA_PLATFORM_EVIDENCE_DEVICE_KIND': Platform.isAndroid || Platform.isIOS
          ? 'unknown'
          : 'desktop',
      'PIXA_PLATFORM_EVIDENCE_CONNECTION': Platform.isAndroid || Platform.isIOS
          ? 'unknown'
          : 'local',
      'PIXA_PLATFORM_EVIDENCE_SIGNING': Platform.isIOS
          ? 'unknown'
          : 'not-applicable',
    },
  );

  stdout.writeln('Pixa platform self-check report written to $outputPath');
}

String _outputPath(Directory root, List<String> args, String platform) {
  for (final String arg in args) {
    if (arg.startsWith('--output=')) {
      final String value = arg.substring('--output='.length).trim();
      if (value.isNotEmpty) {
        return File(value).isAbsolute ? value : '${root.path}/$value';
      }
    }
  }
  return '${root.path}/build/reports/pixa_platform_self_check_$platform.json';
}

String _platformLabel() {
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  return Platform.operatingSystem;
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

Future<void> _run(
  Directory workingDirectory,
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory.path,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final int exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(executable, arguments, 'command failed', exitCode);
  }
}
