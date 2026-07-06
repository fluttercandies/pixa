import 'dart:convert';
import 'dart:io';

import 'pixa_platform_build.dart' as build;

void main() {
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

  stdout.writeln('Pixa platform build self-test passed.');
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
