import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TargetPlatform? hostPlatform = _hostTargetPlatform();
  if (hostPlatform != null) {
    debugDefaultTargetPlatformOverride = hostPlatform;
  }
  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'runtime platform self-check passes and can write a JSON report',
    () async {
      final Directory cacheRoot = await Directory.systemTemp.createTemp(
        'pixa-platform-self-check-',
      );
      addTearDown(() => cacheRoot.delete(recursive: true));

      await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
      final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
      final PixaRuntimePlatformSelfCheck selfCheck =
          await _operationalSelfCheck(snapshot.platformSelfCheck, cacheRoot);

      expect(selfCheck.passed, isTrue, reason: _json(selfCheck.toJson()));
      expect(selfCheck.isSupportedPlatform, isTrue);
      expect(
        selfCheck.failedChecks,
        isEmpty,
        reason: _json(selfCheck.toJson()),
      );
      expect(
        selfCheck.checks.map((PixaRuntimePlatformCheck check) => check.name),
        containsAll(<String>[
          'runtimeLibraryLoad',
          'symbolResolution',
          'threadedRuntime',
          'cacheDirectory',
          'networkPolicy',
          'runtimePipelineLoad',
          'cacheDirectoryReadWrite',
          'networkLoopbackFetch',
          'abiArchitecture',
        ]),
      );

      final String? reportPath =
          Platform.environment['PIXA_PLATFORM_SELF_CHECK_REPORT'];
      if (reportPath != null && reportPath.trim().isNotEmpty) {
        final File report = File(reportPath);
        report.parent.createSync(recursive: true);
        report.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'generatedUtc': DateTime.now().toUtc().toIso8601String(),
            'cacheRootPath': cacheRoot.path,
            'evidence': _evidenceMetadata(selfCheck.platform),
            'selfCheck': selfCheck.toJson(),
            'capabilities': snapshot.toJson()['capabilities'],
          }),
        );
      }
    },
  );
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
    final PixaPipelineLoad load = await Pixa.pipeline.load(
      PixaRequest(
        source: PixaSource.bytes(_minimalGif(), id: 'platform-runtime-load'),
        cachePolicy: const PixaCachePolicy.noStore(),
        decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
      ),
    );
    try {
      final image = load.decodeRuntimeRgba(
        maxDecodedPixels: 1,
        maxOutputBytes: 4,
      );
      try {
        final bool valid =
            image.width == 1 &&
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
    final File probe = File('${cacheRoot.path}/pixa-self-check-rw.bin');
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
    unawaited(
      server.forEach((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'gif')
          ..headers.contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      }),
    );
    final PixaPipelineLoad load = await Pixa.pipeline.load(
      PixaRequest.network(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/probe.gif',
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    try {
      final bool valid = load.bytes.length == bytes.length;
      return _check(
        'networkLoopbackFetch',
        valid,
        valid
            ? 'runtime HTTP transport fetched loopback image bytes'
            : 'runtime HTTP transport returned unexpected byte length',
      );
    } finally {
      load.dispose();
    }
  } on Object catch (error) {
    return _check('networkLoopbackFetch', false, error.toString());
  } finally {
    await server?.close(force: true);
  }
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
        ? 'current Dart FFI ABI $abi is in the supported platform matrix'
        : 'current Dart FFI ABI $abi is not in ${expected.join(', ')}',
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

String _json(Object? value) {
  return const JsonEncoder().convert(value);
}

TargetPlatform? _hostTargetPlatform() {
  if (Platform.isMacOS) {
    return TargetPlatform.macOS;
  }
  if (Platform.isWindows) {
    return TargetPlatform.windows;
  }
  if (Platform.isLinux) {
    return TargetPlatform.linux;
  }
  if (Platform.isAndroid) {
    return TargetPlatform.android;
  }
  if (Platform.isIOS) {
    return TargetPlatform.iOS;
  }
  return null;
}

Map<String, Object?> _evidenceMetadata(String platform) {
  return <String, Object?>{
    'platform': _env('PIXA_PLATFORM_EVIDENCE_PLATFORM') ?? platform,
    'runnerOs': Platform.operatingSystem,
    'runMode': _env('PIXA_PLATFORM_EVIDENCE_RUN_MODE') ?? 'flutter-test',
    'deviceId': _env('PIXA_PLATFORM_EVIDENCE_DEVICE_ID'),
    'deviceKind':
        _env('PIXA_PLATFORM_EVIDENCE_DEVICE_KIND') ??
        (Platform.isAndroid || Platform.isIOS ? 'unknown' : 'desktop'),
    'connection':
        _env('PIXA_PLATFORM_EVIDENCE_CONNECTION') ??
        (Platform.isAndroid || Platform.isIOS ? 'unknown' : 'local'),
    'signing':
        _env('PIXA_PLATFORM_EVIDENCE_SIGNING') ??
        (Platform.isIOS ? 'unknown' : 'not-applicable'),
  };
}

String? _env(String name) {
  final String? value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
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
