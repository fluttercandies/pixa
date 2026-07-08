import 'dart:convert';
import 'dart:io';

import 'pixa_gallery_cockpit_acceptance.dart' as acceptance;

void main() {
  _mobilePlatformsUseCiSizedLaunchBudget();
  _windowsFlutterRootResolvesBat();
  _nonWindowsFlutterRootResolvesBinary();
  _failedValidationResultKeepsEvidence();
  stdout.writeln('Pixa gallery cockpit acceptance self-test passed.');
}

void _mobilePlatformsUseCiSizedLaunchBudget() {
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('android') == 720,
    'Android cockpit acceptance should allow CI cold build and install.',
  );
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('ios') == 720,
    'iOS cockpit acceptance should allow CI cold simulator build.',
  );
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('macos') == 240,
    'Desktop cockpit acceptance should keep the normal launch budget.',
  );
}

void _windowsFlutterRootResolvesBat() {
  final resolved = acceptance.flutterExecutableForPlatform(
    environment: <String, String>{
      'FLUTTER_ROOT':
          r'C:\hostedtoolcache\windows\flutter\stable-3.44.5-x64\flutter',
    },
    isWindows: true,
  );
  _expect(
    resolved ==
        'C:/hostedtoolcache/windows/flutter/stable-3.44.5-x64/flutter/bin/flutter.bat',
    'Windows Flutter executable should resolve through FLUTTER_ROOT.',
  );
}

void _nonWindowsFlutterRootResolvesBinary() {
  final resolved = acceptance.flutterExecutableForPlatform(
    environment: <String, String>{'FLUTTER_ROOT': '/opt/flutter'},
    isWindows: false,
  );
  _expect(
    resolved == '/opt/flutter/bin/flutter',
    'Non-Windows Flutter executable should resolve through FLUTTER_ROOT.',
  );
}

void _failedValidationResultKeepsEvidence() {
  final temp = Directory.systemTemp.createTempSync(
    'pixa_gallery_cockpit_acceptance_self_test_',
  );
  try {
    final stdoutText = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'classification': 'blocked_by_environment',
        'recommendedNextStep': 'needs_relaunch',
        'blockedReason': 'remote session did not become reachable',
        'validationFailures': <Object?>[
          <String, Object?>{
            'code': 'targetUnreachable',
            'message': 'The target could not be reached reliably.',
            'details': <String, Object?>{
              'gate': 'targetReachable',
              'failureCodes': <String>['targetUnreachable'],
            },
          },
        ],
        'runTaskResult': <String, Object?>{
          'classification': 'blocked_by_environment',
          'recommendedNextStep': 'needs_relaunch',
          'blockedReason': 'launch did not attach to the app',
          'bundleSummary': <String, Object?>{
            'manifest': <String, Object?>{
              'failureSummary': 'Target did not become reachable.',
            },
            'gateSummary': <String, Object?>{
              'gates': <String, Object?>{
                'targetReachable': false,
                'executionFinished': true,
                'bundleWritten': true,
              },
              'failureCodes': <String, Object?>{
                'targetReachable': <String>['targetUnreachable'],
              },
            },
          },
        },
      },
    );

    final resultFile = acceptance.writeValidationResult(
      outputRoot: temp,
      stdoutText: stdoutText,
    );
    _expect(resultFile.existsSync(), 'validation result should be written.');

    final decoded = jsonDecode(resultFile.readAsStringSync());
    _expect(decoded is Map<String, Object?>, 'validation JSON should decode.');
    final summary = acceptance.validationFailureSummary(
      decoded as Map<String, Object?>,
    );
    _expect(summary != null, 'failure summary should be present.');
    _expect(
      summary!.contains('Target did not become reachable.'),
      'summary should include manifest failure summary.',
    );
    _expect(
      summary.contains('remote session did not become reachable'),
      'summary should include blocked reason.',
    );
    _expect(
      summary.contains('targetReachable=false'),
      'summary should include failed gate values.',
    );
    _expect(
      summary.contains('targetUnreachable'),
      'summary should include gate failure codes.',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
