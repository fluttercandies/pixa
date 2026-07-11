import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'pixa_native_assets_log_check.dart' show nativeAssetsEvidencePrefix;

const String _profileRustToolchainVersion = '1.89.0';

/// Exact Rust compiler probe used for release profile metadata.
List<String> profileRustVersionCommand() => const <String>[
  'rustup',
  'run',
  _profileRustToolchainVersion,
  'rustc',
  '--version',
];

/// Maps Flutter target-platform identifiers to Pixa release platform ids.
String profilePlatformFromTarget(String targetPlatform) {
  final String normalized = targetPlatform.trim().toLowerCase();
  if (normalized.startsWith('android')) {
    return 'android';
  }
  if (normalized.startsWith('ios')) {
    return 'ios';
  }
  if (normalized.startsWith('darwin') || normalized.startsWith('macos')) {
    return 'macos';
  }
  if (normalized.startsWith('linux')) {
    return 'linux';
  }
  if (normalized.startsWith('windows')) {
    return 'windows';
  }
  throw StateError('Unsupported Flutter target platform: $targetPlatform');
}

/// Locates the Native Assets runtime copied into a Flutter project output.
Future<File> locatePixaRuntimeArtifact(Directory project) async {
  final Directory nativeAssets = Directory('${project.path}/.dart_tool/lib');
  if (!await nativeAssets.exists()) {
    throw StateError(
      'Native Assets output directory does not exist: ${nativeAssets.path}',
    );
  }
  final List<File> candidates = <File>[];
  await for (final FileSystemEntity entity in nativeAssets.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && _isPixaRuntimeArtifact(entity)) {
      candidates.add(entity);
    }
  }
  if (candidates.isEmpty) {
    throw StateError(
      'Pixa runtime artifact was not produced under ${nativeAssets.path}.',
    );
  }
  candidates.sort((File left, File right) {
    return right.lastModifiedSync().compareTo(left.lastModifiedSync());
  });
  final File artifact = candidates.first;
  if (await artifact.length() <= 0) {
    throw StateError('Pixa runtime artifact is empty: ${artifact.path}');
  }
  return artifact;
}

bool _isPixaRuntimeArtifact(File file) {
  final String name = file.uri.pathSegments.last.toLowerCase();
  return name == 'libpixa_runtime.dylib' ||
      name == 'libpixa_runtime.so' ||
      name == 'pixa_runtime.dll' ||
      name == 'pixa_runtime';
}

/// Writes a structured, commit-bound Native Assets build evidence log.
Future<void> writeNativeAssetsEvidenceLog({
  required File output,
  required File rawBuildLog,
  required String platform,
  required String mode,
  required String gitCommit,
  required String gitTreeState,
  required File? artifact,
  required int exitCode,
}) async {
  await output.parent.create(recursive: true);
  final IOSink sink = output.openWrite();
  try {
    sink.writeln(
      '$nativeAssetsEvidencePrefix${jsonEncode(<String, Object?>{'schema': 1, 'event': 'buildStart', 'platform': platform, 'mode': mode, 'gitCommit': gitCommit, 'gitTreeState': gitTreeState})}',
    );
    if (await rawBuildLog.exists()) {
      await sink.addStream(rawBuildLog.openRead());
      sink.writeln();
    }
    if (artifact != null && await artifact.exists()) {
      final int bytes = await artifact.length();
      final Digest digest = await sha256.bind(artifact.openRead()).first;
      sink.writeln(
        '$nativeAssetsEvidencePrefix${jsonEncode(<String, Object?>{'schema': 1, 'event': 'artifact', 'asset': 'package:pixa/pixa_runtime', 'path': artifact.absolute.path, 'bytes': bytes, 'sha256': digest.toString()})}',
      );
    }
    sink.writeln(
      '$nativeAssetsEvidencePrefix${jsonEncode(<String, Object?>{'schema': 1, 'event': 'buildComplete', 'status': exitCode == 0 ? 'succeeded' : 'failed', 'exitCode': exitCode})}',
    );
  } finally {
    await sink.flush();
    await sink.close();
  }
}

/// Builds the exact foreground Flutter command used for profile evidence.
List<String> buildProfileDriveArguments({
  required String deviceId,
  required String deviceLabel,
  required String deviceIdHash,
  required String flutterVersion,
  required String rustVersion,
  required String gitCommit,
  required String gitTreeState,
  required String runId,
  int networkConcurrency = 6,
  bool includeLiveNetwork = false,
}) {
  if (networkConcurrency <= 0) {
    throw RangeError.range(networkConcurrency, 1, null, 'networkConcurrency');
  }
  return <String>[
    'flutter',
    'drive',
    '--profile',
    '-d$deviceId',
    '--driver=test_driver/pixa_profile_scroll_driver.dart',
    '--target=integration_test/pixa_profile_scroll_test.dart',
    '--dart-define=PIXA_PROFILE_DEVICE_ID_HASH=$deviceIdHash',
    '--dart-define=PIXA_PROFILE_DEVICE_LABEL=$deviceLabel',
    '--dart-define=PIXA_FLUTTER_VERSION=$flutterVersion',
    '--dart-define=PIXA_RUST_VERSION=$rustVersion',
    '--dart-define=PIXA_GIT_COMMIT=$gitCommit',
    '--dart-define=PIXA_GIT_TREE_STATE=$gitTreeState',
    '--dart-define=PIXA_PROFILE_RUN_ID=$runId',
    '--dart-define=PIXA_PROFILE_NETWORK_CONCURRENCY=$networkConcurrency',
    '--dart-define=PIXA_PROFILE_LIVE_NETWORK=$includeLiveNetwork',
  ];
}

Future<void> main(List<String> arguments) async {
  final _Options options = _Options.parse(arguments);
  if (options.showHelp) {
    stdout.writeln(_usage);
    return;
  }
  if (options.deviceId == null || options.deviceId!.trim().isEmpty) {
    stderr.writeln('Missing required --device=<flutter-device-id>.');
    stdout.writeln(_usage);
    exitCode = 64;
    return;
  }

  final Directory root = File.fromUri(Platform.script).parent.parent;
  final Directory gallery = Directory('${root.path}/examples/pixa_gallery');
  final File driverRaw = File(
    '${root.path}/build/reports/pixa_profile_scroll_raw.json',
  );
  final File raw = File('${root.path}/${options.rawPath}');
  final File output = File('${root.path}/${options.outputPath}');
  final File nativeAssetsLog = File(
    '${root.path}/${options.nativeAssetsLogPath}',
  );
  final File rawNativeAssetsLog = File('${nativeAssetsLog.path}.raw');
  await removeProfileArtifacts(<String>{
    driverRaw.path,
    raw.path,
    output.path,
    nativeAssetsLog.path,
    rawNativeAssetsLog.path,
  });

  final String deviceId = options.deviceId!;
  final ({String name, String targetPlatform}) device = await _resolveDevice(
    root,
    deviceId,
  );
  final String deviceName = device.name;
  final String evidencePlatform = profilePlatformFromTarget(
    device.targetPlatform,
  );
  final String deviceLabel = options.deviceName ?? 'flutter-profile-device';
  final String deviceIdHash = sha256.convert(utf8.encode(deviceId)).toString();
  final Map<String, Object?> flutter = _jsonObject(
    jsonDecode(
      await _runForOutput(root, <String>['flutter', '--version', '--machine']),
    ),
    'flutter --version --machine',
  );
  final String flutterVersion = flutter['flutterVersion']?.toString() ?? '';
  if (flutterVersion.isEmpty) {
    throw StateError('Flutter did not report flutterVersion.');
  }
  final String rustVersion = await _runForOutput(
    root,
    profileRustVersionCommand(),
  );
  final ({String commit, String treeState}) git = await _gitIdentity(root);
  if (git.treeState != 'clean') {
    throw StateError(
      'Profile evidence must be captured from a clean Git worktree.',
    );
  }
  final String runId =
      '${git.commit.substring(0, 12)}-'
      '${DateTime.now().toUtc().microsecondsSinceEpoch}';

  stdout.writeln(
    'Running Pixa profile scroll acceptance on $deviceName ($deviceId).',
  );
  await rawNativeAssetsLog.parent.create(recursive: true);
  final int driveExitCode = await _runForeground(
    gallery,
    buildProfileDriveArguments(
      deviceId: deviceId,
      deviceLabel: deviceLabel,
      deviceIdHash: deviceIdHash,
      flutterVersion: flutterVersion,
      rustVersion: rustVersion,
      gitCommit: git.commit,
      gitTreeState: git.treeState,
      runId: runId,
      networkConcurrency: options.networkConcurrency,
      includeLiveNetwork: options.includeLiveNetwork,
    ),
    captureLog: rawNativeAssetsLog,
  );
  File? runtimeArtifact;
  Object? artifactError;
  if (driveExitCode == 0) {
    try {
      runtimeArtifact = await locatePixaRuntimeArtifact(gallery);
    } on Object catch (error) {
      artifactError = error;
    }
  }
  await writeNativeAssetsEvidenceLog(
    output: nativeAssetsLog,
    rawBuildLog: rawNativeAssetsLog,
    platform: evidencePlatform,
    mode: 'profile',
    gitCommit: git.commit,
    gitTreeState: git.treeState,
    artifact: runtimeArtifact,
    exitCode: artifactError == null ? driveExitCode : 1,
  );
  if (await rawNativeAssetsLog.exists()) {
    await rawNativeAssetsLog.delete();
  }
  if (driveExitCode != 0) {
    exitCode = driveExitCode;
    return;
  }
  if (artifactError != null) {
    throw StateError('$artifactError');
  }
  await moveProfileRawArtifact(
    driverRawPath: driverRaw.path,
    requestedRawPath: raw.path,
  );
  if (!raw.existsSync()) {
    throw StateError('Profile driver passed but did not write ${raw.path}.');
  }
  if (options.captureOnly) {
    stdout.writeln(
      'Profile evidence captured without gate evaluation: ${raw.path}',
    );
    return;
  }

  final File baseline = File('${root.path}/${options.baselinePath}');
  if (!baseline.existsSync()) {
    throw StateError(
      'Comparable baseline not found at ${baseline.path}. Run once with '
      '--capture-only, preserve that raw JSON as the baseline, then rerun.',
    );
  }
  final int reportExitCode = await _runForeground(root, <String>[
    'dart',
    'run',
    'tool/pixa_profile_report.dart',
    '--input=${raw.path}',
    '--baseline=${baseline.path}',
    '--output=${output.path}',
  ]);
  if (reportExitCode != 0) {
    exitCode = reportExitCode;
  }
}

Future<({String name, String targetPlatform})> _resolveDevice(
  Directory root,
  String deviceId,
) async {
  final Object? decoded = jsonDecode(
    await _runForOutput(root, <String>['flutter', 'devices', '--machine']),
  );
  if (decoded is! List) {
    throw FormatException('flutter devices --machine did not return a list.');
  }
  for (final Object? entry in decoded) {
    if (entry is Map && entry['id']?.toString() == deviceId) {
      final String name = entry['name']?.toString() ?? '';
      final String targetPlatform = entry['targetPlatform']?.toString() ?? '';
      if (name.isNotEmpty && targetPlatform.isNotEmpty) {
        return (name: name, targetPlatform: targetPlatform);
      }
    }
  }
  throw StateError('Flutter device "$deviceId" is not currently available.');
}

Future<({String commit, String treeState})> _gitIdentity(Directory root) async {
  final String commit = await _runForOutput(root, <String>[
    'git',
    'rev-parse',
    'HEAD',
  ]);
  final String changes = await _runForOutput(root, <String>[
    'git',
    'status',
    '--porcelain',
  ]);
  return (commit: commit, treeState: changes.isEmpty ? 'clean' : 'dirty');
}

/// Removes stale raw and report artifacts before a new acceptance run.
Future<void> removeProfileArtifacts(Iterable<String> paths) async {
  for (final String path in paths.toSet()) {
    final File file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// Moves the fixed integration-driver output to the requested raw path.
Future<void> moveProfileRawArtifact({
  required String driverRawPath,
  required String requestedRawPath,
}) async {
  final File source = File(driverRawPath);
  if (!await source.exists()) {
    throw StateError('Profile driver did not write $driverRawPath.');
  }
  if (source.absolute.path == File(requestedRawPath).absolute.path) {
    return;
  }
  final File destination = File(requestedRawPath);
  await destination.parent.create(recursive: true);
  if (await destination.exists()) {
    await destination.delete();
  }
  await source.rename(destination.path);
}

Future<String> _runForOutput(
  Directory workingDirectory,
  List<String> arguments,
) async {
  final ProcessResult result = await Process.run(
    'rtk',
    arguments,
    workingDirectory: workingDirectory.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'rtk',
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout.toString().trim();
}

Future<int> _runForeground(
  Directory workingDirectory,
  List<String> arguments, {
  File? captureLog,
}) async {
  final Process process = await Process.start(
    'rtk',
    arguments,
    workingDirectory: workingDirectory.path,
    mode: ProcessStartMode.normal,
  );
  final Future<int> processExit = process.exitCode;
  final IOSink? logSink = captureLog?.openWrite();
  Future<void> forward(Stream<List<int>> stream, IOSink terminal) async {
    await for (final List<int> chunk in stream) {
      terminal.add(chunk);
      logSink?.add(chunk);
    }
  }

  try {
    await Future.wait<void>(<Future<void>>[
      forward(process.stdout, stdout),
      forward(process.stderr, stderr),
    ]);
    return await processExit;
  } finally {
    await processExit;
    if (logSink != null) {
      await logSink.flush();
      await logSink.close();
    }
  }
}

Map<String, Object?> _jsonObject(Object? value, String source) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (Object? key, Object? nestedValue) =>
          MapEntry<String, Object?>(key.toString(), nestedValue),
    );
  }
  throw FormatException('$source did not return a JSON object.');
}

final class _Options {
  const _Options({
    required this.deviceId,
    required this.deviceName,
    required this.rawPath,
    required this.baselinePath,
    required this.outputPath,
    required this.nativeAssetsLogPath,
    required this.networkConcurrency,
    required this.includeLiveNetwork,
    required this.captureOnly,
    required this.showHelp,
  });

  factory _Options.parse(List<String> arguments) {
    String? deviceId;
    String? deviceName;
    var rawPath = 'build/reports/pixa_profile_scroll_raw.json';
    var baselinePath = 'build/reports/pixa_profile_scroll_baseline.json';
    var outputPath = 'build/reports/pixa_profile_scroll_report.md';
    var nativeAssetsLogPath =
        'build/reports/pixa_profile_native_assets_evidence.log';
    var networkConcurrency = 6;
    var includeLiveNetwork = false;
    var captureOnly = false;
    var showHelp = false;
    for (final String argument in arguments) {
      if (argument.startsWith('--device=')) {
        deviceId = argument.substring('--device='.length);
      } else if (argument.startsWith('--device-name=')) {
        deviceName = argument.substring('--device-name='.length);
      } else if (argument.startsWith('--raw=')) {
        rawPath = argument.substring('--raw='.length);
      } else if (argument.startsWith('--baseline=')) {
        baselinePath = argument.substring('--baseline='.length);
      } else if (argument.startsWith('--output=')) {
        outputPath = argument.substring('--output='.length);
      } else if (argument.startsWith('--native-assets-log=')) {
        nativeAssetsLogPath = argument.substring('--native-assets-log='.length);
      } else if (argument.startsWith('--network-concurrency=')) {
        networkConcurrency = int.parse(
          argument.substring('--network-concurrency='.length),
        );
        if (networkConcurrency <= 0) {
          throw RangeError.range(
            networkConcurrency,
            1,
            null,
            'networkConcurrency',
          );
        }
      } else if (argument == '--live-network') {
        includeLiveNetwork = true;
      } else if (argument == '--capture-only') {
        captureOnly = true;
      } else if (argument == '--help' || argument == '-h') {
        showHelp = true;
      } else {
        throw ArgumentError('Unknown profile acceptance argument: $argument');
      }
    }
    if (nativeAssetsLogPath.trim().isEmpty) {
      throw ArgumentError('--native-assets-log must not be empty.');
    }
    return _Options(
      deviceId: deviceId,
      deviceName: deviceName,
      rawPath: rawPath,
      baselinePath: baselinePath,
      outputPath: outputPath,
      nativeAssetsLogPath: nativeAssetsLogPath,
      networkConcurrency: networkConcurrency,
      includeLiveNetwork: includeLiveNetwork,
      captureOnly: captureOnly,
      showHelp: showHelp,
    );
  }

  final String? deviceId;
  final String? deviceName;
  final String rawPath;
  final String baselinePath;
  final String outputPath;
  final String nativeAssetsLogPath;
  final int networkConcurrency;
  final bool includeLiveNetwork;
  final bool captureOnly;
  final bool showHelp;
}

const String _usage = '''
Usage: dart run tool/pixa_profile_acceptance.dart --device=<id> [options]

Runs the gallery integration test in profile mode on a named Flutter device.
Options:
  --device-name=<name>  Override the name read from flutter devices.
  --network-concurrency=<count>
                        Select positive Pixa network concurrency without an
                        arbitrary public upper limit (default: 6).
  --live-network        Add the seeded Picsum supplemental network scenario.
  --capture-only        Capture raw JSON without comparing a baseline.
  --raw=<path>          Raw evidence path under the repository root.
  --baseline=<path>     Comparable baseline JSON path.
  --output=<path>       Markdown report path.
  --native-assets-log=<path>
                        Structured Native Assets evidence log path.
''';
