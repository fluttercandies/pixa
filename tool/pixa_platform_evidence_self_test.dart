import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final Directory root = Directory.current;
  final Directory temp =
      await Directory.systemTemp.createTemp('pixa-platform-evidence-test-');
  try {
    await _acceptsDesktopEvidence(root, temp);
    await _requiresRequestedRunMode(root, temp);
    await _acceptsNativeModuleEvidence(root, temp);
    await _acceptsDesktopNativeModuleEvidence(root, temp);
    await _acceptsHostedCiNativeModuleEvidence(root, temp);
    await _acceptsHostedCiExampleSmokeEvidence(root, temp);
    await _rejectsMissingRequiredChecks(root, temp);
    await _rejectsMissingNativeModuleCheck(root, temp);
    await _rejectsMissingExampleSmokeCheck(root, temp);
    stdout.writeln('Pixa platform evidence self-test passed.');
  } finally {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}

Future<void> _acceptsHostedCiExampleSmokeEvidence(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/hosted-ci-example-smoke')
    ..createSync();
  const Map<String, ({String deviceKind, String connection, String signing})>
      platformEvidence =
      <String, ({String deviceKind, String connection, String signing})>{
    'android': (
      deviceKind: 'emulator',
      connection: 'local',
      signing: 'debug',
    ),
    'ios': (
      deviceKind: 'simulator',
      connection: 'local',
      signing: 'debug',
    ),
    'linux': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
    'macos': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
    'windows': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
  };
  for (final MapEntry<String,
          ({String deviceKind, String connection, String signing})> entry
      in platformEvidence.entries) {
    _writeReport(
      reports,
      '${entry.key}-platform.json',
      platform: entry.key,
      deviceKind: entry.value.deviceKind,
      connection: entry.value.connection,
      signing: entry.value.signing,
      runMode: 'integration-test',
    );
    _writeExampleReport(
      reports,
      '${entry.key}-example.json',
      platform: entry.key,
      deviceKind: entry.value.deviceKind,
      connection: entry.value.connection,
      signing: entry.value.signing,
      runMode: 'integration-test',
    );
  }
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=android,ios,linux,macos,windows',
    '--require-run-mode=integration-test',
    '--require-example-smoke',
  ]);
  _expectExit(result, 0, 'hosted CI example smoke evidence should pass');
}

Future<void> _acceptsDesktopEvidence(Directory root, Directory temp) async {
  final Directory reports = Directory('${temp.path}/desktop')..createSync();
  for (final String platform in <String>['linux', 'macos', 'windows']) {
    _writeReport(
      reports,
      '$platform.json',
      platform: platform,
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    );
  }
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=linux,macos,windows',
  ]);
  _expectExit(result, 0, 'desktop reports should pass');
}

Future<void> _requiresRequestedRunMode(Directory root, Directory temp) async {
  final Directory reports = Directory('${temp.path}/run-mode')..createSync();
  _writeReport(
    reports,
    '00-macos-flutter-test.json',
    platform: 'macos',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    runMode: 'flutter-test',
  );
  _writeReport(
    reports,
    '01-macos-integration-test.json',
    platform: 'macos',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    runMode: 'integration-test',
  );
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=macos',
    '--require-run-mode=integration-test',
  ]);
  _expectExit(result, 0, 'run mode requirement should choose matching report');
}

Future<void> _acceptsNativeModuleEvidence(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/native-modules')
    ..createSync();
  _writeReport(
    reports,
    'macos.json',
    platform: 'macos',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    nativeModules: <Map<String, Object?>>[
      _nativeModule(
        moduleId: 'pixa.processor.jpeg_turbo',
        entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
        processorOperation: 'tile:jpeg',
      ),
      _nativeModule(
        moduleId: 'pixa.processor.webp',
        entrypointSymbol: 'pixa_webp_processor_plugin_init',
        processorOperation: 'tile:webp',
      ),
    ],
  );
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=macos',
    '--require-native-modules=jpeg-turbo-roi,webp-roi',
  ]);
  _expectExit(result, 0, 'native module evidence should pass');
}

Future<void> _acceptsDesktopNativeModuleEvidence(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/desktop-native-modules')
    ..createSync();
  for (final String platform in <String>['linux', 'macos', 'windows']) {
    _writeReport(
      reports,
      '$platform.json',
      platform: platform,
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
      runMode: 'integration-test',
      nativeModules: <Map<String, Object?>>[
        _nativeModule(
          platform: platform,
          moduleId: 'pixa.processor.jpeg_turbo',
          entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
          processorOperation: 'tile:jpeg',
        ),
        _nativeModule(
          platform: platform,
          moduleId: 'pixa.processor.webp',
          entrypointSymbol: 'pixa_webp_processor_plugin_init',
          processorOperation: 'tile:webp',
        ),
      ],
    );
  }
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=linux,macos,windows',
    '--require-run-mode=integration-test',
    '--require-native-modules=jpeg-turbo-roi,webp-roi',
  ]);
  _expectExit(result, 0, 'desktop native ROI evidence should pass');
}

Future<void> _acceptsHostedCiNativeModuleEvidence(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/hosted-ci-native-modules')
    ..createSync();
  const Map<String, ({String deviceKind, String connection, String signing})>
      platformEvidence =
      <String, ({String deviceKind, String connection, String signing})>{
    'android': (
      deviceKind: 'emulator',
      connection: 'local',
      signing: 'debug',
    ),
    'ios': (
      deviceKind: 'simulator',
      connection: 'local',
      signing: 'debug',
    ),
    'linux': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
    'macos': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
    'windows': (
      deviceKind: 'desktop',
      connection: 'local',
      signing: 'not-applicable',
    ),
  };
  for (final MapEntry<String,
          ({String deviceKind, String connection, String signing})> entry
      in platformEvidence.entries) {
    _writeReport(
      reports,
      '${entry.key}.json',
      platform: entry.key,
      deviceKind: entry.value.deviceKind,
      connection: entry.value.connection,
      signing: entry.value.signing,
      runMode: 'integration-test',
      nativeModules: <Map<String, Object?>>[
        _nativeModule(
          platform: entry.key,
          moduleId: 'pixa.processor.jpeg_turbo',
          entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
          processorOperation: 'tile:jpeg',
        ),
        _nativeModule(
          platform: entry.key,
          moduleId: 'pixa.processor.webp',
          entrypointSymbol: 'pixa_webp_processor_plugin_init',
          processorOperation: 'tile:webp',
        ),
      ],
    );
  }
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=android,ios,linux,macos,windows',
    '--require-run-mode=integration-test',
    '--require-native-modules=jpeg-turbo-roi,webp-roi',
  ]);
  _expectExit(result, 0, 'hosted CI native ROI evidence should pass');
}

Future<void> _rejectsMissingRequiredChecks(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/missing-checks')
    ..createSync();
  _writeReport(
    reports,
    'linux.json',
    platform: 'linux',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    checks: _requiredChecks.where((String check) => check != 'networkPolicy'),
  );
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=linux',
  ]);
  _expectExit(result, 1, 'missing networkPolicy check should fail');
  final String output = '${result.stdout}\n${result.stderr}';
  if (!output.contains('networkPolicy')) {
    throw StateError('Expected networkPolicy failure, got:\n$output');
  }
}

Future<void> _rejectsMissingNativeModuleCheck(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/native-missing-check')
    ..createSync();
  _writeReport(
    reports,
    'macos.json',
    platform: 'macos',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    nativeModules: <Map<String, Object?>>[
      _nativeModule(
        moduleId: 'pixa.processor.jpeg_turbo',
        entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
        processorOperation: 'tile:jpeg',
        checks: _requiredNativeModuleChecks
            .where((String check) => check != 'nativeLink'),
      ),
    ],
  );
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=macos',
    '--require-native-modules=jpeg-turbo-roi',
  ]);
  _expectExit(result, 1, 'missing nativeLink check should fail');
  final String output = '${result.stdout}\n${result.stderr}';
  if (!output.contains('nativeLink')) {
    throw StateError('Expected nativeLink failure, got:\n$output');
  }
}

Future<void> _rejectsMissingExampleSmokeCheck(
  Directory root,
  Directory temp,
) async {
  final Directory reports = Directory('${temp.path}/example-missing-check')
    ..createSync();
  _writeReport(
    reports,
    'linux-platform.json',
    platform: 'linux',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    runMode: 'integration-test',
  );
  _writeExampleReport(
    reports,
    'linux-example.json',
    platform: 'linux',
    deviceKind: 'desktop',
    connection: 'local',
    signing: 'not-applicable',
    runMode: 'integration-test',
    checks: _requiredExampleSmokeChecks
        .where((String check) => check != 'loopbackImageRequest'),
  );
  final ProcessResult result = await _runVerifier(root, reports, <String>[
    '--require-platforms=linux',
    '--require-run-mode=integration-test',
    '--require-example-smoke',
  ]);
  _expectExit(result, 1, 'missing example smoke check should fail');
  final String output = '${result.stdout}\n${result.stderr}';
  if (!output.contains('loopbackImageRequest')) {
    throw StateError(
      'Expected loopbackImageRequest example failure, got:\n$output',
    );
  }
}

Future<ProcessResult> _runVerifier(
  Directory root,
  Directory reports,
  List<String> args,
) {
  return Process.run(
    Platform.resolvedExecutable,
    <String>[
      'run',
      'tool/pixa_platform_evidence.dart',
      '--reports=${reports.path}',
      ...args,
    ],
    workingDirectory: root.path,
  );
}

void _writeReport(
  Directory reports,
  String name, {
  required String platform,
  required String deviceKind,
  required String connection,
  required String signing,
  String runMode = 'self-test',
  Iterable<String> checks = _requiredChecks,
  List<Map<String, Object?>> nativeModules = const <Map<String, Object?>>[],
}) {
  File('${reports.path}/$name').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'generatedUtc': '2026-07-06T00:00:00.000Z',
      'evidence': <String, Object?>{
        'platform': platform,
        'runnerOs': Platform.operatingSystem,
        'runMode': runMode,
        'deviceKind': deviceKind,
        'connection': connection,
        'signing': signing,
      },
      'selfCheck': <String, Object?>{
        'platform': platform,
        'passed': true,
        'checks': <Object?>[
          for (final String check in checks)
            <String, Object?>{'name': check, 'passed': true},
        ],
      },
      if (nativeModules.isNotEmpty) 'nativeModules': nativeModules,
    }),
  );
}

void _writeExampleReport(
  Directory reports,
  String name, {
  required String platform,
  required String deviceKind,
  required String connection,
  required String signing,
  String runMode = 'integration-test',
  Iterable<String> checks = _requiredExampleSmokeChecks,
}) {
  File('${reports.path}/$name').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'generatedUtc': '2026-07-06T00:00:00.000Z',
      'evidence': <String, Object?>{
        'platform': platform,
        'runnerOs': Platform.operatingSystem,
        'runMode': runMode,
        'deviceKind': deviceKind,
        'connection': connection,
        'signing': signing,
      },
      'exampleSmoke': <String, Object?>{
        'platform': platform,
        'passed': true,
        'checks': <Object?>[
          for (final String check in checks)
            <String, Object?>{'name': check, 'passed': true},
        ],
      },
    }),
  );
}

Map<String, Object?> _nativeModule({
  String? platform,
  required String moduleId,
  required String entrypointSymbol,
  required String processorOperation,
  Iterable<String> checks = _requiredNativeModuleChecks,
}) {
  return <String, Object?>{
    if (platform != null) 'platform': platform,
    'moduleId': moduleId,
    'entrypointSymbol': entrypointSymbol,
    'processorOperations': <String>[processorOperation],
    'passed': true,
    'checks': <Object?>[
      for (final String check in checks)
        <String, Object?>{'name': check, 'passed': true},
    ],
  };
}

void _expectExit(ProcessResult result, int expected, String label) {
  if (result.exitCode == expected) {
    return;
  }
  throw StateError(
    '$label: expected exit $expected, got ${result.exitCode}\n'
    'stdout:\n${result.stdout}\n'
    'stderr:\n${result.stderr}',
  );
}

const Set<String> _requiredChecks = <String>{
  'runtimeLibraryLoad',
  'symbolResolution',
  'threadedRuntime',
  'cacheDirectory',
  'networkPolicy',
  'runtimePipelineLoad',
  'cacheDirectoryReadWrite',
  'networkLoopbackFetch',
  'abiArchitecture',
};

const Set<String> _requiredNativeModuleChecks = <String>{
  'manifestEntrypoint',
  'nativeLink',
  'processorRoute',
  'runtimeCapability',
};

const Set<String> _requiredExampleSmokeChecks = <String>{
  'runtimePlatformSelfCheck',
  'runtimePipelineLoad',
  'appLaunch',
  'layoutControls',
  'loopbackImageRequest',
  'largeViewerRoute',
  'cacheStats',
};
