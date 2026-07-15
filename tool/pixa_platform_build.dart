import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final _Options options = _Options.parse(args);
  final String platform = options.platform;
  final Directory root = Directory.current;
  final String gitCommit = _gitCommit(root);
  final Directory probe = Directory(
    '${root.path}/.dart_tool/pixa_platform_probe/$platform',
  );
  if (probe.existsSync()) {
    probe.deleteSync(recursive: true);
  }
  probe.createSync(recursive: true);

  final String flutter = _flutterExecutable();
  await _run(root, flutter, <String>[
    'create',
    '--platforms=$platform',
    '--project-name',
    'pixa_platform_probe',
    '--org',
    'dev.pixa',
    probe.path,
  ]);
  if (platform == 'android') {
    pixaConfigureAndroidBuildResources(probe);
  }
  _configureProbePlatformPermissions(platform, probe);
  _writeProbeApp(root, probe, options, gitCommit);
  await _run(probe, flutter, <String>['pub', 'get']);
  await _run(probe, flutter, _buildCommand(platform), diagnosticRoot: probe);
  if (options.runSelfCheck) {
    final Map<String, String> environment = options.selfCheckEnvironment(root);
    await _runSelfCheck(
      probe,
      flutter,
      _selfCheckCommand(options.deviceId),
      environment: environment,
      reportPath: environment['PIXA_PLATFORM_SELF_CHECK_REPORT'],
    );
  }
}

final class _Options {
  const _Options({
    required this.platform,
    required this.runSelfCheck,
    required this.deviceId,
    required this.reportOutput,
    required this.deviceKind,
    required this.connection,
    required this.signing,
    required this.enableJpegTurboRoi,
    required this.enableWebpRoi,
  });

  final String platform;
  final bool runSelfCheck;
  final String? deviceId;
  final String? reportOutput;
  final String? deviceKind;
  final String? connection;
  final String? signing;
  final bool enableJpegTurboRoi;
  final bool enableWebpRoi;

  factory _Options.parse(List<String> args) {
    String? platform;
    var runSelfCheck = false;
    String? deviceId;
    String? reportOutput;
    String? deviceKind;
    String? connection;
    String? signing;
    var enableJpegTurboRoi = false;
    var enableWebpRoi = false;
    for (final String arg in args) {
      if (arg.startsWith('--platform=')) {
        platform = arg.substring('--platform='.length);
      } else if (arg == '--run-self-check') {
        runSelfCheck = true;
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
      } else if (arg == '--enable-native-roi') {
        enableJpegTurboRoi = true;
        enableWebpRoi = true;
      } else if (arg == '--enable-jpeg-turbo-roi') {
        enableJpegTurboRoi = true;
      } else if (arg == '--enable-webp-roi') {
        enableWebpRoi = true;
      } else {
        _usage();
      }
    }
    if (platform == null || !_supportedPlatforms.contains(platform)) {
      _usage();
    }
    if (deviceId != null && deviceId.isEmpty ||
        reportOutput != null && reportOutput.isEmpty ||
        deviceKind != null && deviceKind.isEmpty ||
        connection != null && connection.isEmpty ||
        signing != null && signing.isEmpty) {
      _usage();
    }
    return _Options(
      platform: platform,
      runSelfCheck: runSelfCheck,
      deviceId: deviceId,
      reportOutput: reportOutput,
      deviceKind: deviceKind,
      connection: connection,
      signing: signing,
      enableJpegTurboRoi: enableJpegTurboRoi,
      enableWebpRoi: enableWebpRoi,
    );
  }

  List<String> get nativeRoiModules {
    return <String>[
      if (enableJpegTurboRoi) 'jpeg-turbo-roi',
      if (enableWebpRoi) 'webp-roi',
    ];
  }

  Map<String, String> selfCheckEnvironment(Directory root) {
    final String outputPath = reportOutput == null
        ? '${root.path}/build/reports/pixa_platform_self_check_${platform}_probe.json'
        : (File(reportOutput!).isAbsolute
              ? reportOutput!
              : '${root.path}/$reportOutput');
    return <String, String>{
      ...Platform.environment,
      'PIXA_PLATFORM_SELF_CHECK_REPORT': outputPath,
      'PIXA_PLATFORM_EVIDENCE_PLATFORM': platform,
      'PIXA_PLATFORM_EVIDENCE_RUN_MODE': 'integration-test',
      'PIXA_PLATFORM_EVIDENCE_DEVICE_ID': ?deviceId,
      'PIXA_PLATFORM_EVIDENCE_DEVICE_KIND':
          deviceKind ?? _defaultDeviceKind(platform),
      'PIXA_PLATFORM_EVIDENCE_CONNECTION':
          connection ?? _defaultConnection(platform),
      'PIXA_PLATFORM_EVIDENCE_SIGNING': signing ?? _defaultSigning(platform),
      if (nativeRoiModules.isNotEmpty)
        'PIXA_PLATFORM_NATIVE_ROI_MODULES': nativeRoiModules.join(','),
    };
  }
}

Never _usage() {
  stderr.writeln(
    'Usage: dart run tool/pixa_platform_build.dart '
    '--platform=<android|ios|linux|macos|windows> '
    '[--run-self-check] [--device=<flutter-device-id>] '
    '[--report-output=<path>] [--device-kind=<desktop|emulator|simulator>] '
    '[--connection=<local|usb|wireless>] [--signing=<debug|development|release|not-applicable>] '
    '[--enable-native-roi|--enable-jpeg-turbo-roi|--enable-webp-roi]',
  );
  exit(64);
}

const Set<String> _supportedPlatforms = <String>{
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
};

const String _androidGradleJvmArgs =
    'org.gradle.jvmargs=-Xmx2G -XX:MaxMetaspaceSize=1G '
    '-XX:ReservedCodeCacheSize=256m -XX:+HeapDumpOnOutOfMemoryError';
const String _androidKotlinDaemonJvmArgs =
    'kotlin.daemon.jvmargs=-Xmx1G -XX:MaxMetaspaceSize=512m '
    '-XX:ReservedCodeCacheSize=256m';

/// Caps Android build daemons so the generated probe can coexist with an AVD.
void pixaConfigureAndroidBuildResources(Directory project) {
  final File properties = File('${project.path}/android/gradle.properties');
  if (!properties.existsSync()) {
    throw StateError(
      'Generated Android Gradle properties are missing: ${properties.path}',
    );
  }
  final List<String> configured = <String>[];
  var hasGradleArgs = false;
  var hasKotlinArgs = false;
  for (final String line in properties.readAsLinesSync()) {
    if (line.startsWith('org.gradle.jvmargs=')) {
      configured.add(_androidGradleJvmArgs);
      hasGradleArgs = true;
    } else if (line.startsWith('kotlin.daemon.jvmargs=')) {
      configured.add(_androidKotlinDaemonJvmArgs);
      hasKotlinArgs = true;
    } else {
      configured.add(line);
    }
  }
  if (!hasGradleArgs) {
    configured.insert(0, _androidGradleJvmArgs);
  }
  if (!hasKotlinArgs) {
    configured.add(_androidKotlinDaemonJvmArgs);
  }
  properties.writeAsStringSync('${configured.join('\n')}\n');
}

void _configureProbePlatformPermissions(String platform, Directory probe) {
  if (platform == 'macos') {
    for (final String name in <String>[
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      final File file = File('${probe.path}/macos/Runner/$name');
      _ensureEntitlement(file, 'com.apple.security.network.client');
      _ensureEntitlement(file, 'com.apple.security.network.server');
    }
  }
}

void _ensureEntitlement(File file, String key) {
  if (!file.existsSync()) {
    return;
  }
  final String source = file.readAsStringSync();
  if (source.contains('<key>$key</key>')) {
    return;
  }
  file.writeAsStringSync(
    source.replaceFirst('</dict>', '\t<key>$key</key>\n\t<true/>\n</dict>'),
  );
}

void _writeProbeApp(
  Directory root,
  Directory probe,
  _Options options,
  String gitCommit,
) {
  final String hookUserDefines = _hookUserDefines(options);
  File('${probe.path}/pubspec.yaml').writeAsStringSync('''
name: pixa_platform_probe
description: Platform build probe for Pixa runtime assets.
publish_to: none

environment:
  sdk: ">=3.11.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  pixa:
    path: ${_pubspecPath(root, probe)}

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter

flutter:
  uses-material-design: true
$hookUserDefines
''');
  File('${probe.path}/lib/main.dart').writeAsStringSync('''
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final PixaRuntimePlatformSelfCheck selfCheck = await _runPixaSelfCheck();
  runApp(_ProbeApp(selfCheck: selfCheck));
}

Future<PixaRuntimePlatformSelfCheck> _runPixaSelfCheck() async {
  await Pixa.configure();
  final PixaRuntimePlatformSelfCheck selfCheck =
      PixaDebugInspector.snapshot().platformSelfCheck;
  if (!selfCheck.passed) {
    throw StateError('Pixa platform self-check failed: \${selfCheck.toJson()}');
  }
  return selfCheck;
}

final class _ProbeApp extends StatelessWidget {
  const _ProbeApp({required this.selfCheck});

  final PixaRuntimePlatformSelfCheck selfCheck;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Semantics(
            label: 'pixa-runtime-\${selfCheck.platform}',
            child: PixaImage.memory(
              'probe',
              Uint8List.fromList(const <int>[
                71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0,
                255, 255, 255, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 76,
                1, 0, 59,
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
''');
  Directory('${probe.path}/integration_test').createSync(recursive: true);
  File(
    '${probe.path}/integration_test/pixa_self_check_test.dart',
  ).writeAsStringSync('''
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pixa runtime platform self-check passes', (tester) async {
    final Directory cacheRoot =
        await Directory.systemTemp.createTemp('pixa-platform-probe-');
    addTearDown(() {
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    });
    await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    final PixaRuntimePlatformSelfCheck selfCheck =
        await _operationalSelfCheck(snapshot.platformSelfCheck, cacheRoot);
    expect(
      selfCheck.passed,
      isTrue,
      reason: selfCheck.toJson().toString(),
    );
    final List<Map<String, Object?>> nativeModules =
        await _nativeRoiEvidence(
      snapshot,
      selfCheck.platform,
      ${_dartStringListLiteral(options.nativeRoiModules)},
    );
    if (nativeModules.isNotEmpty) {
      expect(
        nativeModules.every((Map<String, Object?> module) =>
            module['passed'] == true),
        isTrue,
        reason: nativeModules.toString(),
      );
    }
    final String reportText = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'generatedUtc': DateTime.now().toUtc().toIso8601String(),
        'evidence': <String, Object?>{
          'platform': ${_dartStringLiteral(options.platform)},
          'runnerOs': Platform.operatingSystem,
          'runMode': 'integration-test',
          'gitCommit': ${_dartStringLiteral(gitCommit)},
          'deviceId': ${_dartStringLiteral(options.deviceId)},
          'deviceKind': ${_dartStringLiteral(options.deviceKind ?? _defaultDeviceKind(options.platform))},
          'connection': ${_dartStringLiteral(options.connection ?? _defaultConnection(options.platform))},
          'signing': ${_dartStringLiteral(options.signing ?? _defaultSigning(options.platform))},
        },
        'selfCheck': selfCheck.toJson(),
        'capabilities': snapshot.toJson()['capabilities'],
        if (nativeModules.isNotEmpty) 'nativeModules': nativeModules,
      },
    );
    _writeReportFile(reportText);
    final String reportMarker = 'PIXA_PLATFORM_SELF_CHECK_REPORT_JSON:' +
        base64Url.encode(utf8.encode(reportText));
    // ignore: avoid_print
    print(reportMarker);
  });
}

Future<PixaRuntimePlatformSelfCheck> _operationalSelfCheck(
  PixaRuntimePlatformSelfCheck base,
  Directory cacheRoot,
) async {
  final List<PixaRuntimePlatformCheck> checks =
      List<PixaRuntimePlatformCheck>.of(base.checks);
  checks.add(await _runtimePipelineLoadCheck());
  checks.add(_cacheDirectoryReadWriteCheck(cacheRoot));
  checks.add(await _networkLoopbackFetchCheck());
  checks.add(_abiArchitectureCheck(base.platform));
  return PixaRuntimePlatformSelfCheck(
    platform: base.platform,
    isWeb: base.isWeb,
    isSupportedPlatform: base.isSupportedPlatform,
    passed: checks.every(
      (PixaRuntimePlatformCheck check) => !check.required || check.passed,
    ),
    checks: List<PixaRuntimePlatformCheck>.unmodifiable(checks),
  );
}

Future<PixaRuntimePlatformCheck> _runtimePipelineLoadCheck() async {
  try {
    final PixaPipelineLoad load = await Pixa.pipeline.load(PixaRequest(
      source: PixaSource.bytes(_minimalGif(), id: 'platform-runtime-load'),
      cachePolicy: const PixaCachePolicy.noStore(),
      decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
    ));
    try {
      final image = load.decodeRuntimeRgba(
        maxDecodedPixels: 1,
        maxOutputBytes: 4,
      );
      try {
        final bool valid = image.width == 1 &&
            image.height == 1 &&
            image.rowBytes == 4 &&
            image.bytes.length == 4;
        return _check(
          'runtimePipelineLoad',
          valid,
          valid
              ? 'runtime pipeline loaded and decoded an owned buffer'
              : 'runtime decoded buffer had unexpected shape',
        );
      } finally {
        image.dispose();
      }
    } finally {
      load.dispose();
    }
  } on Object catch (error) {
    return _check('runtimePipelineLoad', false, error.toString());
  }
}

PixaRuntimePlatformCheck _cacheDirectoryReadWriteCheck(Directory cacheRoot) {
  try {
    cacheRoot.createSync(recursive: true);
    final File probe = File('\${cacheRoot.path}/pixa-self-check-rw.bin');
    probe.writeAsBytesSync(<int>[0x70, 0x69, 0x78, 0x61], flush: true);
    final bool valid = probe.readAsBytesSync().join(',') == '112,105,120,97';
    probe.deleteSync();
    return _check(
      'cacheDirectoryReadWrite',
      valid,
      valid
          ? 'cache directory accepted write, read, flush, and delete'
          : 'cache directory read-back did not match written bytes',
    );
  } on Object catch (error) {
    return _check('cacheDirectoryReadWrite', false, error.toString());
  }
}

Future<PixaRuntimePlatformCheck> _networkLoopbackFetchCheck() async {
  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final Uint8List bytes = _minimalGif();
    final String endpoint =
        'http://\${InternetAddress.loopbackIPv4.address}:\${server.port}/probe.gif';
    unawaited(server.forEach((HttpRequest request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'gif')
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    }));
    await _waitForDartLoopback(endpoint, bytes.length);
    Object? lastError;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        final PixaPipelineLoad load =
            await Pixa.pipeline.load(PixaRequest.network(
          endpoint,
          cachePolicy: const PixaCachePolicy.noStore(),
        ));
        try {
          final bool valid = load.bytes.length == bytes.length;
          return _check(
            'networkLoopbackFetch',
            valid,
            valid
                ? 'runtime HTTP transport fetched loopback image bytes from \$endpoint'
                : 'runtime HTTP transport returned \${load.bytes.length} bytes from \$endpoint',
          );
        } finally {
          load.dispose();
        }
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
      }
    }
    return _check(
      'networkLoopbackFetch',
      false,
      'runtime HTTP transport could not fetch \$endpoint after retries: \$lastError',
    );
  } on Object catch (error) {
    return _check('networkLoopbackFetch', false, error.toString());
  } finally {
    await server?.close(force: true);
  }
}

Future<void> _waitForDartLoopback(String endpoint, int expectedBytes) async {
  Object? lastError;
  for (var attempt = 0; attempt < 8; attempt++) {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1);
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse(endpoint));
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 2));
      final List<int> body =
          await response.fold<List<int>>(<int>[], (List<int> value, List<int> chunk) {
        value.addAll(chunk);
        return value;
      }).timeout(const Duration(seconds: 2));
      if (response.statusCode == HttpStatus.ok && body.length == expectedBytes) {
        return;
      }
      lastError =
          'status=\${response.statusCode}, bytes=\${body.length}, expected=\$expectedBytes';
    } on Object catch (error) {
      lastError = error;
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(Duration(milliseconds: 30 * (attempt + 1)));
  }
  throw StateError('Dart loopback readiness failed for \$endpoint: \$lastError');
}

PixaRuntimePlatformCheck _abiArchitectureCheck(String platform) {
  final String abi = _currentAbiLabel();
  final Set<String> expected = switch (platform.toLowerCase()) {
    'android' => <String>{'arm64-v8a', 'armeabi-v7a', 'x86_64'},
    'ios' => <String>{'ios-arm', 'ios-arm64', 'ios-x64'},
    'macos' => <String>{'macos-arm64', 'macos-x64'},
    'windows' => <String>{'windows-x64'},
    'linux' => <String>{'linux-x64', 'linux-arm64'},
    _ => const <String>{},
  };
  final bool valid = expected.contains(abi);
  return _check(
    'abiArchitecture',
    valid,
    valid
        ? 'current Dart FFI ABI \$abi is in the supported platform matrix'
        : 'current Dart FFI ABI \$abi is not in \${expected.join(', ')}',
  );
}

String _currentAbiLabel() {
  return switch (ffi.Abi.current()) {
    ffi.Abi.androidArm => 'armeabi-v7a',
    ffi.Abi.androidArm64 => 'arm64-v8a',
    ffi.Abi.androidX64 => 'x86_64',
    ffi.Abi.iosArm => 'ios-arm',
    ffi.Abi.iosArm64 => 'ios-arm64',
    ffi.Abi.iosX64 => 'ios-x64',
    ffi.Abi.macosArm64 => 'macos-arm64',
    ffi.Abi.macosX64 => 'macos-x64',
    ffi.Abi.windowsX64 => 'windows-x64',
    ffi.Abi.linuxX64 => 'linux-x64',
    ffi.Abi.linuxArm64 => 'linux-arm64',
    final ffi.Abi abi => abi.toString(),
  };
}

PixaRuntimePlatformCheck _check(String name, bool passed, String message) {
  return PixaRuntimePlatformCheck(
    name: name,
    passed: passed,
    required: true,
    message: message,
  );
}

void _writeReportFile(String reportText) {
  final String? reportPath =
      Platform.environment['PIXA_PLATFORM_SELF_CHECK_REPORT'];
  if (reportPath == null || reportPath.trim().isEmpty) {
    return;
  }
  try {
    final File report = File(reportPath);
    report.parent.createSync(recursive: true);
    report.writeAsStringSync(reportText);
  } catch (error) {
    // ignore: avoid_print
    print('PIXA_PLATFORM_SELF_CHECK_REPORT_FILE_WRITE_FAILED:' +
        error.toString());
  }
}

Future<List<Map<String, Object?>>> _nativeRoiEvidence(
  PixaDebugSnapshot snapshot,
  String platform,
  List<String> requestedModules,
) async {
  final Set<String> modules = requestedModules
      .map((String value) => value.trim().toLowerCase())
      .where((String value) => value.isNotEmpty)
      .toSet();
  if (modules.isEmpty) {
    return const <Map<String, Object?>>[];
  }
  final PixaRuntimePluginRegistryStats stats =
      snapshot.capabilities.runtimePluginRegistryStats;
  return <Map<String, Object?>>[
    if (modules.contains('jpeg-turbo-roi'))
      await _nativeRoiModuleEvidence(
        platform: platform,
        stats: stats,
        moduleId: 'pixa.processor.jpeg_turbo',
        entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
        processorOperation: 'tile:jpeg',
        fixture: _jpegRoiFixture(),
        expectedFormat: PixaImageMetadataFormat.jpeg,
        tileX: 16,
        tileY: 16,
      ),
    if (modules.contains('webp-roi'))
      await _nativeRoiModuleEvidence(
        platform: platform,
        stats: stats,
        moduleId: 'pixa.processor.webp',
        entrypointSymbol: 'pixa_webp_processor_plugin_init',
        processorOperation: 'tile:webp',
        fixture: _webpRoiFixture(),
        expectedFormat: PixaImageMetadataFormat.webp,
        tileX: 15,
        tileY: 17,
      ),
  ];
}

Future<Map<String, Object?>> _nativeRoiModuleEvidence({
  required String platform,
  required PixaRuntimePluginRegistryStats stats,
  required String moduleId,
  required String entrypointSymbol,
  required String processorOperation,
  required Uint8List fixture,
  required PixaImageMetadataFormat expectedFormat,
  required int tileX,
  required int tileY,
}) async {
  final PixaRuntimePluginModuleSnapshot? module = stats.moduleById(moduleId);
  final _NativeRoiProcessorCheck processorCheck =
      await _runNativeRoiProcessorCheck(
    moduleId: moduleId,
    fixture: fixture,
    expectedFormat: expectedFormat,
    tileX: tileX,
    tileY: tileY,
  );
  final bool manifestEntrypoint =
      module?.entrypointSymbol == entrypointSymbol;
  final bool nativeLink =
      module?.deployment ==
          PixaRuntimePluginDeployment.hostLinkedPluginModule &&
      processorCheck.passed;
  final bool processorRoute =
      module?.processorOperations.contains(processorOperation) == true;
  final bool runtimeCapability =
      module != null && stats.canUseSingleHostBinary && processorCheck.passed;
  final List<Map<String, Object?>> checks = <Map<String, Object?>>[
    <String, Object?>{
      'name': 'manifestEntrypoint',
      'passed': manifestEntrypoint,
      'detail': module == null
          ? 'runtime registry did not contain the expected module'
          : 'observed entrypoint: ' +
              (module.entrypointSymbol ?? '<none>'),
    },
    <String, Object?>{
      'name': 'nativeLink',
      'passed': nativeLink,
      'detail': processorCheck.detail,
    },
    <String, Object?>{
      'name': 'processorRoute',
      'passed': processorRoute,
      'detail': 'observed routes: ' +
          (module?.processorOperations.join(',') ?? '<none>'),
    },
    <String, Object?>{
      'name': 'runtimeCapability',
      'passed': runtimeCapability,
      'detail': processorCheck.detail,
    },
  ];
  return <String, Object?>{
    'platform': platform,
    'moduleId': moduleId,
    'entrypointSymbol': entrypointSymbol,
    'processorOperations': <String>[processorOperation],
    'passed': checks.every((Map<String, Object?> check) =>
        check['passed'] == true),
    'checks': checks,
  };
}

final class _NativeRoiProcessorCheck {
  const _NativeRoiProcessorCheck({required this.passed, required this.detail});

  final bool passed;
  final String detail;
}

Future<_NativeRoiProcessorCheck> _runNativeRoiProcessorCheck({
  required String moduleId,
  required Uint8List fixture,
  required PixaImageMetadataFormat expectedFormat,
  required int tileX,
  required int tileY,
}) async {
  try {
    final PixaImageMetadata input = PixaImageMetadata.parseEncoded(fixture);
    if (input.format != expectedFormat ||
        input.width != 64 ||
        input.height != 64) {
      return _NativeRoiProcessorCheck(
        passed: false,
        detail: 'fixture metadata was not the expected 64x64 format',
      );
    }
    final PixaPipelineLoad load = await Pixa.pipeline.load(
      PixaRequest(
        source: PixaSource.bytes(fixture, id: 'platform-roi-' + moduleId),
        processors: <String>[
          PixaProcessors.tileCropResize(
            x: tileX,
            y: tileY,
            width: 16,
            height: 16,
            decodedWidth: 8,
            decodedHeight: 8,
            filter: PixaResizeFilter.nearest,
          ),
        ],
        cachePolicy: const PixaCachePolicy.noStore(),
        limits: const PixaRequestLimits(
          maxEncodedBytes: 4096,
          maxDecodedPixels: 512,
          maxProcessorOutputBytes: 8192,
        ),
      ),
    );
    try {
      final Uint8List output = load.bytes;
      final bool pngMagic = output.length >= 8 &&
          output[0] == 0x89 &&
          output[1] == 0x50 &&
          output[2] == 0x4e &&
          output[3] == 0x47 &&
          output[4] == 0x0d &&
          output[5] == 0x0a &&
          output[6] == 0x1a &&
          output[7] == 0x0a;
      final PixaImageMetadata metadata =
          PixaImageMetadata.parseEncoded(output);
      final bool valid = pngMagic &&
          metadata.format == PixaImageMetadataFormat.png &&
          metadata.width == 8 &&
          metadata.height == 8;
      return _NativeRoiProcessorCheck(
        passed: valid,
        detail: valid
            ? 'runtime processed a 64x64 fixture under a 512-pixel full-frame '
                'budget into a valid 8x8 PNG'
            : 'runtime ROI output was not a valid 8x8 PNG',
      );
    } finally {
      load.dispose();
    }
  } on Object catch (error) {
    return _NativeRoiProcessorCheck(
      passed: false,
      detail: 'runtime ROI execution failed: ' + error.toString(),
    );
  }
}

Uint8List _jpegRoiFixture() {
  return base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQE'
    'BAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/'
    'wAALCABAAEABAREA/8QAFgABAQEAAAAAAAAAAAAAAAAAAAcJ/8QAGRAAAwEB'
    'AQAAAAAAAAAAAAAAABahYwFT/9oACAEBAAA/ANLWTShk0oZNKGTShk0oZNKG'
    'TShk0pKGbvpQzd9KGbvpQzd9KGbvpQzd9KGbvpQzd9KSlk0oZNKGTShk0oZN'
    'KGTShk0oZNKSpk0oZNKGTShk0oZNKGTShk0oZNKSdk0oZNKGTShk0oZNKGTS'
    'hk0oZNKSlk0oZNKGTShk0oZNKGTShk0oZNKSlm56UM3PShm56UM3PShm56UM'
    '3PShm56UM3PSkoZNKGTShk0oZNKGTShk0oZNKGTSn//Z',
  );
}

Uint8List _webpRoiFixture() {
  return base64Decode(
    'UklGRnoAAABXRUJQVlA4IG4AAACQBgCdASpAAEAAPhkKhEEhBQKBvwQAYS0g'
    'Anmj7HZ/+qCr/QRvMpezFCn4J4SmZVNDTk02VVOQd+LjR1kgAP7/2xNtFuX1'
    '5AYOrLqvT8DtBLNr0MeqmoYSI8YTDqoSmCFBMIVPosvKajNyefoAAA==',
  );
}

Uint8List _minimalGif() {
  return Uint8List.fromList(<int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xff,
    0xff,
    0xff,
    0x2c,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x4c,
    0x01,
    0x00,
    0x3b,
  ]);
}
''');
}

String _gitCommit(Directory root) {
  final ProcessResult result = Process.runSync('git', const <String>[
    'rev-parse',
    'HEAD',
  ], workingDirectory: root.path);
  final String value = result.stdout.toString().trim().toLowerCase();
  if (result.exitCode != 0 ||
      !RegExp(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$').hasMatch(value)) {
    throw StateError(
      'Unable to resolve the Git commit for platform evidence: '
      '${result.stderr}',
    );
  }
  return value;
}

String _hookUserDefines(_Options options) {
  if (!options.enableJpegTurboRoi && !options.enableWebpRoi) {
    return '';
  }
  final StringBuffer buffer = StringBuffer()
    ..writeln()
    ..writeln('hooks:')
    ..writeln('  user_defines:')
    ..writeln('    pixa:');
  if (options.enableJpegTurboRoi && options.enableWebpRoi) {
    buffer.writeln('      enable_native_roi: true');
  } else {
    if (options.enableJpegTurboRoi) {
      buffer.writeln('      enable_jpeg_turbo_roi: true');
    }
    if (options.enableWebpRoi) {
      buffer.writeln('      enable_webp_roi: true');
    }
  }
  return buffer.toString();
}

String _pubspecPath(Directory root, Directory probe) {
  return _relativePath(probe.uri, root.uri.resolve('packages/pixa'));
}

String _dartStringLiteral(String? value) {
  return value == null ? 'null' : jsonEncode(value);
}

String _dartStringListLiteral(Iterable<String> values) {
  return 'const <String>[${values.map(_dartStringLiteral).join(', ')}]';
}

String _relativePath(Uri fromDir, Uri toDir) {
  final List<String> from = fromDir.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .toList();
  final List<String> to = toDir.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .toList();
  var shared = 0;
  while (shared < from.length &&
      shared < to.length &&
      from[shared] == to[shared]) {
    shared++;
  }
  final List<String> parts = <String>[
    for (var index = shared; index < from.length; index++) '..',
    ...to.skip(shared),
  ];
  return parts.join('/');
}

List<String> _buildCommand(String platform) {
  return switch (platform) {
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
    _ => throw StateError('Unsupported platform $platform'),
  };
}

List<String> _selfCheckCommand(String? deviceId) {
  return <String>[
    'test',
    '--no-dds',
    'integration_test/pixa_self_check_test.dart',
    if (deviceId != null) ...<String>['-d', deviceId],
  ];
}

List<String> pixaPlatformSelfCheckCommandForTesting(String? deviceId) {
  return List<String>.unmodifiable(_selfCheckCommand(deviceId));
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
    'android' || 'ios' => 'unknown',
    'linux' || 'macos' || 'windows' => 'local',
    _ => 'unknown',
  };
}

String _defaultSigning(String platform) {
  return switch (platform) {
    'ios' => 'unknown',
    'android' => 'debug',
    'linux' || 'macos' || 'windows' => 'not-applicable',
    _ => 'unknown',
  };
}

Future<void> _run(
  Directory workingDirectory,
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  Directory? diagnosticRoot,
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
    _printRustBuildDiagnostics(diagnosticRoot ?? workingDirectory);
    throw ProcessException(executable, arguments, 'command failed', exitCode);
  }
}

void _printRustBuildDiagnostics(Directory root) {
  for (final File log in pixaNativeBuildDiagnosticFiles(root)) {
    stderr.writeln('=== ${log.path} ===');
    stderr.writeln(_tailText(log.readAsStringSync(), 24000));
  }
}

List<File> pixaNativeBuildDiagnosticFiles(Directory root) {
  if (!root.existsSync()) {
    return const <File>[];
  }
  final List<File> logs = <File>[];
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final String normalizedPath = entity.path.replaceAll('\\', '/');
    final bool isRustFailure = normalizedPath.endsWith(
      '/pixa_rust_build_failure.log',
    );
    final bool isPixaHookStderr =
        normalizedPath.contains('/hooks_runner/pixa/') &&
        normalizedPath.endsWith('/stderr.txt');
    if (isRustFailure || isPixaHookStderr) {
      logs.add(entity);
    }
  }
  logs.sort((File left, File right) => left.path.compareTo(right.path));
  return logs;
}

String _tailText(String value, int maxChars) {
  if (value.length <= maxChars) {
    return value;
  }
  return value.substring(value.length - maxChars);
}

Future<void> _runSelfCheck(
  Directory workingDirectory,
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String? reportPath,
}) async {
  for (var attempt = 1; attempt <= _selfCheckMaxAttempts; attempt++) {
    final String attemptLabel = _selfCheckMaxAttempts == 1
        ? ''
        : ' (attempt $attempt/$_selfCheckMaxAttempts)';
    stdout.writeln('> $executable ${arguments.join(' ')}$attemptLabel');
    if (reportPath != null && reportPath.trim().isNotEmpty) {
      final File staleReport = File(reportPath);
      if (staleReport.existsSync()) {
        staleReport.deleteSync();
      }
    }
    final Process process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory.path,
      environment: environment,
    );
    final StringBuffer output = StringBuffer();
    final Future<void> stdoutDone = process.stdout
        .transform(utf8.decoder)
        .forEach((String chunk) {
          stdout.write(chunk);
          output.write(chunk);
        });
    final Future<void> stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach((String chunk) {
          stderr.write(chunk);
          output.write(chunk);
        });
    final Future<int> exitCodeFuture = process.exitCode;
    late final int exitCode;
    try {
      exitCode = await exitCodeFuture.timeout(_selfCheckExitTimeout);
    } on TimeoutException {
      final String capturedOutput = output.toString();
      final String? reportText =
          _readExistingPlatformSelfCheckReport(reportPath) ??
          tryExtractPixaPlatformSelfCheckReport(capturedOutput);
      if (reportText != null &&
          acceptsNonZeroPixaPlatformSelfCheckExit(capturedOutput, reportText)) {
        await _terminateProcess(process, exitCodeFuture);
        await stdoutDone;
        await stderrDone;
        _writePlatformSelfCheckReportIfMissing(reportPath, reportText);
        stdout.writeln(
          'Pixa platform self-check accepted timed-out flutter test after '
          'validating the self-check report and Flutter test pass marker.',
        );
        return;
      }
      await _terminateProcess(process, exitCodeFuture);
      await stdoutDone;
      await stderrDone;
      if (attempt < _selfCheckMaxAttempts &&
          _shouldRetryPixaPlatformSelfCheckTimeout(
            capturedOutput,
            reportText,
          )) {
        stdout.writeln(
          'Pixa platform self-check timed out without a report; retrying '
          'once to tolerate hosted simulator launch hangs.',
        );
        continue;
      }
      throw TimeoutException(
        'Pixa platform self-check did not exit within '
        '${_selfCheckExitTimeout.inMinutes} minutes.\n'
        '${_tailText(capturedOutput, 24000)}',
        _selfCheckExitTimeout,
      );
    }
    await stdoutDone;
    await stderrDone;
    final String capturedOutput = output.toString();
    if (exitCode != 0) {
      final String? reportText =
          _readExistingPlatformSelfCheckReport(reportPath) ??
          tryExtractPixaPlatformSelfCheckReport(capturedOutput);
      if (reportText != null &&
          acceptsNonZeroPixaPlatformSelfCheckExit(capturedOutput, reportText)) {
        _writePlatformSelfCheckReportIfMissing(reportPath, reportText);
        stdout.writeln(
          'Pixa platform self-check accepted non-zero flutter test exit '
          '$exitCode after validating the self-check report and Flutter test '
          'pass marker.',
        );
        return;
      }
      throw ProcessException(executable, arguments, 'command failed', exitCode);
    }
    if (reportPath == null || reportPath.trim().isEmpty) {
      return;
    }
    final File report = File(reportPath);
    if (report.existsSync() && report.lengthSync() > 0) {
      return;
    }
    _writePlatformSelfCheckReportIfMissing(
      reportPath,
      extractPixaPlatformSelfCheckReport(capturedOutput),
    );
    return;
  }
}

const Duration _selfCheckExitTimeout = Duration(minutes: 20);
const int _selfCheckMaxAttempts = 2;

Duration platformSelfCheckExitTimeoutForTesting() => _selfCheckExitTimeout;
int platformSelfCheckMaxAttemptsForTesting() => _selfCheckMaxAttempts;

bool shouldRetryPixaPlatformSelfCheckTimeoutForTesting(
  String output,
  String? reportText,
) {
  return _shouldRetryPixaPlatformSelfCheckTimeout(output, reportText);
}

bool _shouldRetryPixaPlatformSelfCheckTimeout(
  String output,
  String? reportText,
) {
  return reportText == null && !hasFlutterTestPassedMarker(output);
}

Future<void> _terminateProcess(
  Process process,
  Future<int> exitCodeFuture,
) async {
  if (process.kill()) {
    try {
      await exitCodeFuture.timeout(const Duration(seconds: 5));
      return;
    } on Object {
      process.kill(ProcessSignal.sigkill);
    }
  }
}

String extractPixaPlatformSelfCheckReport(String output) {
  const String marker = 'PIXA_PLATFORM_SELF_CHECK_REPORT_JSON:';
  final int index = output.lastIndexOf(marker);
  if (index < 0) {
    throw StateError('Pixa platform self-check did not emit report payload.');
  }
  final int valueStart = index + marker.length;
  final int valueEnd = output.indexOf(RegExp(r'\s'), valueStart);
  final String encoded = output
      .substring(valueStart, valueEnd < 0 ? output.length : valueEnd)
      .trim();
  return utf8.decode(base64Url.decode(encoded));
}

String? tryExtractPixaPlatformSelfCheckReport(String output) {
  try {
    return extractPixaPlatformSelfCheckReport(output);
  } on Object {
    return null;
  }
}

bool acceptsNonZeroPixaPlatformSelfCheckExit(String output, String reportText) {
  return hasFlutterTestPassedMarker(output) &&
      isPassingPixaPlatformSelfCheckReport(reportText);
}

bool hasFlutterTestPassedMarker(String output) {
  return RegExp(
        r'(^|\n)[^\d\n]*\d+\s+tests?\s+passed\.',
        multiLine: true,
      ).hasMatch(output.replaceAll('\r\n', '\n')) ||
      output.contains('All tests passed!');
}

bool isPassingPixaPlatformSelfCheckReport(String reportText) {
  try {
    final Object? decoded = jsonDecode(reportText);
    if (decoded is! Map<String, Object?>) {
      return false;
    }
    final Object? evidence = decoded['evidence'];
    if (evidence is! Map || evidence['runMode'] != 'integration-test') {
      return false;
    }
    final Object? selfCheck = decoded['selfCheck'];
    if (selfCheck is! Map || selfCheck['passed'] != true) {
      return false;
    }
    final Object? platform = selfCheck['platform'];
    if (platform is! String || platform.trim().isEmpty) {
      return false;
    }
    final Object? checks = selfCheck['checks'];
    if (checks is! List || checks.isEmpty) {
      return false;
    }
    return checks.every((Object? check) {
      return check is Map && check['passed'] == true;
    });
  } on Object {
    return false;
  }
}

String? _readExistingPlatformSelfCheckReport(String? reportPath) {
  if (reportPath == null || reportPath.trim().isEmpty) {
    return null;
  }
  final File report = File(reportPath);
  if (!report.existsSync() || report.lengthSync() <= 0) {
    return null;
  }
  return report.readAsStringSync();
}

void _writePlatformSelfCheckReportIfMissing(
  String? reportPath,
  String reportText,
) {
  if (reportPath == null || reportPath.trim().isEmpty) {
    return;
  }
  final File report = File(reportPath);
  if (report.existsSync() && report.lengthSync() > 0) {
    return;
  }
  report.parent.createSync(recursive: true);
  report.writeAsStringSync(reportText);
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
