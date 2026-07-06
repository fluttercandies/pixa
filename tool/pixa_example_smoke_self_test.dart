import 'dart:convert';
import 'dart:io';

import 'pixa_example_smoke.dart' as smoke;

void main() {
  final String passingReport = _reportText(passed: true);
  final String passingOutput = _outputWithReport(
    passingReport,
    suffix: '1 test passed.\n',
  );

  _expect(
    smoke.extractPixaExampleSmokeReport(passingOutput) == passingReport,
    'extracts the last smoke report marker payload',
  );
  _expect(
    smoke.hasFlutterTestPassedMarker(passingOutput),
    'detects Flutter test pass marker',
  );
  _expect(
    smoke.isPassingPixaExampleSmokeReport(passingReport),
    'accepts passing smoke report',
  );
  _expect(
    smoke.acceptsNonZeroPixaExampleSmokeExit(passingOutput, passingReport),
    'accepts non-zero exit only with report and pass marker',
  );

  _expect(
    !smoke.acceptsNonZeroPixaExampleSmokeExit(
      _outputWithReport(passingReport, suffix: 'Test failed.\n'),
      passingReport,
    ),
    'rejects non-zero exit without Flutter pass marker',
  );
  _expect(
    !smoke.isPassingPixaExampleSmokeReport(_reportText(passed: false)),
    'rejects failed smoke report',
  );
  _expect(
    !smoke.isPassingPixaExampleSmokeReport(
      _reportText(passed: true, failedCheck: true),
    ),
    'rejects inconsistent passing report with failed check',
  );
  _expect(
    smoke.tryExtractPixaExampleSmokeReport('no marker') == null,
    'returns null for missing marker in tolerant extraction',
  );

  stdout.writeln('Pixa example smoke self-test passed.');
}

String _outputWithReport(String reportText, {required String suffix}) {
  return 'PIXA_EXAMPLE_SMOKE_REPORT_JSON:'
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
    },
    'exampleSmoke': <String, Object?>{
      'platform': 'ios',
      'passed': passed,
      'checks': <Map<String, Object?>>[
        <String, Object?>{'name': 'appLaunch', 'passed': true},
        <String, Object?>{'name': 'largeViewerRoute', 'passed': !failedCheck},
      ],
    },
  });
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
