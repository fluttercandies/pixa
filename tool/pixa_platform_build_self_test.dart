import 'dart:convert';
import 'dart:io';

import 'pixa_platform_build.dart' as build;

void main() {
  _limitsAndroidBuildResources();
  _collectsNativeHookFailureDiagnostics();
  _requiresOperationalNativeRoiEvidence();
  _requiresDecodableJpegRoiFixture();
  _requiresOpaqueLossyWebpRoiFixture();
  final String passingReport = _reportText(passed: true);
  final String passingOutput = _outputWithReport(
    passingReport,
    suffix: '1 test passed.\n',
  );

  _expect(
    build.extractPixaPlatformSelfCheckReport(passingOutput) == passingReport,
    'extracts the last platform report marker payload',
  );
  _expect(
    build.hasFlutterTestPassedMarker(passingOutput),
    'detects Flutter test pass marker',
  );
  _expect(
    build.isPassingPixaPlatformSelfCheckReport(passingReport),
    'accepts passing platform self-check report',
  );
  _expect(
    build.acceptsNonZeroPixaPlatformSelfCheckExit(passingOutput, passingReport),
    'accepts non-zero exit only with report and pass marker',
  );
  final String goldenProxyFailureOutput = _outputWithReport(
    passingReport,
    suffix: '''
streamListen: (-32602) Invalid params
streamListen: invalid 'streamId' parameter: integration_test.VmServiceProxyGoldenFileComparator
loading /tmp/probe/integration_test/pixa_self_check_test.dart (failed)
Pixa runtime platform self-check passes
00:00 +0 -1: 0 tests passed, 1 failed.
''',
  );
  _expect(
    build.acceptsNonZeroPixaPlatformSelfCheckExit(
      goldenProxyFailureOutput,
      passingReport,
    ),
    'accepts the Flutter device golden proxy failure after Pixa passes',
  );

  _expect(
    !build.acceptsNonZeroPixaPlatformSelfCheckExit(
      _outputWithReport(passingReport, suffix: 'Test failed.\n'),
      passingReport,
    ),
    'rejects non-zero exit without Flutter pass marker',
  );
  _expect(
    !build.isPassingPixaPlatformSelfCheckReport(_reportText(passed: false)),
    'rejects failed platform self-check report',
  );
  _expect(
    !build.isPassingPixaPlatformSelfCheckReport(
      _reportText(passed: true, failedCheck: true),
    ),
    'rejects inconsistent passing report with failed check',
  );
  _expect(
    build.tryExtractPixaPlatformSelfCheckReport('no marker') == null,
    'returns null for missing marker in tolerant extraction',
  );
  _expect(
    build.platformSelfCheckExitTimeoutForTesting() >=
        const Duration(minutes: 20),
    'allows slow iOS simulator self-check startup',
  );
  _expect(
    build.platformSelfCheckMaxAttemptsForTesting() >= 2,
    'retries hosted simulator launch hangs without hiding failures',
  );
  _expect(
    build
        .pixaPlatformSelfCheckCommandForTesting('emulator-5554')
        .contains('--no-dds'),
    'platform self-check does not depend on the debug service',
  );
  _expect(
    build.shouldRetryPixaPlatformSelfCheckTimeoutForTesting(
      'Running Xcode build...\nXcode build done.\n',
      null,
    ),
    'retries timeout with no self-check report or pass marker',
  );
  _expect(
    !build.shouldRetryPixaPlatformSelfCheckTimeoutForTesting(
      passingOutput,
      passingReport,
    ),
    'does not retry once a passing report exists',
  );

  stdout.writeln('Pixa platform build self-test passed.');
}

void _collectsNativeHookFailureDiagnostics() {
  final Directory temp = Directory.systemTemp.createTempSync(
    'pixa-native-hook-diagnostics-',
  );
  try {
    final File hookStderr = File(
      '${temp.path}/.dart_tool/hooks_runner/pixa/hash/stderr.txt',
    );
    hookStderr.parent.createSync(recursive: true);
    hookStderr.writeAsStringSync('developer prompt failed');
    final File rustFailure = File(
      '${temp.path}/build/pixa_rust_build_failure.log',
    );
    rustFailure.parent.createSync(recursive: true);
    rustFailure.writeAsStringSync('cargo failed');
    final File unrelated = File(
      '${temp.path}/.dart_tool/hooks_runner/objective_c/hash/stderr.txt',
    );
    unrelated.parent.createSync(recursive: true);
    unrelated.writeAsStringSync('unrelated');

    final List<File> diagnostics = build.pixaNativeBuildDiagnosticFiles(temp);

    _expect(diagnostics.length == 2, 'collects both Pixa native diagnostics');
    _expect(
      diagnostics.any((File file) => file.path == hookStderr.path),
      'collects Pixa hook stderr before Cargo starts',
    );
    _expect(
      diagnostics.any((File file) => file.path == rustFailure.path),
      'collects the Rust build failure log',
    );
    _expect(
      diagnostics.every((File file) => file.path != unrelated.path),
      'does not print unrelated package hook logs',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _limitsAndroidBuildResources() {
  final Directory temp = Directory.systemTemp.createTempSync(
    'pixa-android-build-resources-',
  );
  try {
    final File properties = File('${temp.path}/android/gradle.properties');
    properties.parent.createSync(recursive: true);
    properties.writeAsStringSync('''
org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G
android.useAndroidX=true
''');

    build.pixaConfigureAndroidBuildResources(temp);

    final String configured = properties.readAsStringSync();
    _expect(
      configured.contains('org.gradle.jvmargs=-Xmx2G'),
      'Android probe should cap the Gradle daemon heap',
    );
    _expect(
      configured.contains('kotlin.daemon.jvmargs=-Xmx1G'),
      'Android probe should cap the Kotlin daemon heap',
    );
    _expect(
      !configured.contains('-Xmx8G'),
      'Android probe should remove the Flutter template 8 GB heap',
    );
    _expect(
      configured.contains('android.useAndroidX=true'),
      'Android resource limits should preserve unrelated properties',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _requiresDecodableJpegRoiFixture() {
  final String source = File(
    'tool/pixa_platform_build.dart',
  ).readAsStringSync();
  final int start = source.indexOf('Uint8List _jpegRoiFixture()');
  final int end = source.indexOf('Uint8List _webpRoiFixture()', start);
  _expect(start >= 0 && end > start, 'finds the JPEG ROI fixture source');
  final String fixtureSource = source.substring(start, end);
  final String encoded = RegExp(r"'([^']*)'")
      .allMatches(fixtureSource)
      .map((RegExpMatch match) => match.group(1)!)
      .join();
  final List<int> fixture = base64Decode(encoded);
  _expect(
    fixture.length >= 4 &&
        fixture[0] == 0xff &&
        fixture[1] == 0xd8 &&
        fixture[fixture.length - 2] == 0xff &&
        fixture[fixture.length - 1] == 0xd9,
    'JPEG ROI fixture has valid SOI and EOI markers',
  );
  final ({int width, int height}) dimensions = _jpegDimensions(fixture);
  _expect(
    dimensions.width == 64 && dimensions.height == 64,
    'JPEG ROI fixture is 64x64',
  );
}

({int width, int height}) _jpegDimensions(List<int> bytes) {
  for (int offset = 2; offset + 8 < bytes.length; offset++) {
    if (bytes[offset] != 0xff) {
      continue;
    }
    final int marker = bytes[offset + 1];
    if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
      return (
        height: bytes[offset + 5] << 8 | bytes[offset + 6],
        width: bytes[offset + 7] << 8 | bytes[offset + 8],
      );
    }
  }
  throw StateError('JPEG ROI fixture does not contain a supported SOF marker');
}

void _requiresOpaqueLossyWebpRoiFixture() {
  final String source = File(
    'tool/pixa_platform_build.dart',
  ).readAsStringSync();
  final int start = source.indexOf('Uint8List _webpRoiFixture()');
  final int end = source.indexOf('Uint8List _minimalGif()', start);
  _expect(start >= 0 && end > start, 'finds the WebP ROI fixture source');
  final String fixtureSource = source.substring(start, end);
  _expect(
    fixtureSource.contains('VlA4I'),
    'WebP native ROI evidence must use an opaque lossy VP8 fixture',
  );
  _expect(
    !fixtureSource.contains('VlA4T'),
    'WebP native ROI evidence must not use a VP8L full-frame fixture',
  );
}

void _requiresOperationalNativeRoiEvidence() {
  final String source = File(
    'tool/pixa_platform_build.dart',
  ).readAsStringSync();
  for (final String forbidden in <String>[
    "<String, Object?>{'name': 'manifestEntrypoint', 'passed': true}",
    "<String, Object?>{'name': 'nativeLink', 'passed': true}",
    "<String, Object?>{'name': 'processorRoute', 'passed': true}",
  ]) {
    _expect(
      !source.contains(forbidden),
      'native ROI evidence must not self-declare `$forbidden`',
    );
  }
  for (final String required in <String>[
    'PixaRuntimePluginModuleSnapshot',
    'pixa.processor.jpeg_turbo',
    'pixa_jpeg_turbo_processor_plugin_init',
    'tile:jpeg',
    'pixa.processor.webp',
    'pixa_webp_processor_plugin_init',
    'tile:webp',
    '_runNativeRoiProcessorCheck',
    '_jpegRoiFixture',
    '_webpRoiFixture',
    'PixaImageMetadata.parseEncoded',
    'PixaImageMetadataFormat.png',
  ]) {
    _expect(
      source.contains(required),
      'platform probe must contain operational native ROI evidence `$required`',
    );
  }
}

String _outputWithReport(String reportText, {required String suffix}) {
  return 'PIXA_PLATFORM_SELF_CHECK_REPORT_JSON:'
      '${base64Url.encode(utf8.encode(reportText))}\n'
      '$suffix';
}

String _reportText({required bool passed, bool failedCheck = false}) {
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'generatedUtc': '2026-07-06T00:00:00.000000Z',
    'evidence': <String, Object?>{
      'platform': 'ios',
      'runnerOs': 'ios',
      'runMode': 'integration-test',
      'deviceKind': 'simulator',
      'connection': 'local',
      'signing': 'debug',
    },
    'selfCheck': <String, Object?>{
      'platform': 'ios',
      'passed': passed,
      'checks': <Map<String, Object?>>[
        <String, Object?>{'name': 'runtimeLibrary', 'passed': true},
        <String, Object?>{
          'name': 'runtimePipelineLoad',
          'passed': !failedCheck,
        },
      ],
    },
  });
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
