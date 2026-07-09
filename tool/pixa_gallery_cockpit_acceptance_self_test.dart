import 'dart:convert';
import 'dart:io';

import 'package:cockpit/cockpit.dart' as cockpit;

import 'pixa_gallery_cockpit_acceptance.dart' as acceptance;

void main() {
  _mobilePlatformsUseCiSizedLaunchBudget();
  _androidCiEnablesHardwareAcceleration();
  _androidCiUsesFreshEmulatorForCockpitAcceptance();
  _androidCiUsesCiSizedEmulatorBootBudget();
  _androidCiCapturesCockpitDiagnosticsOnFailure();
  _androidCiCapturesLiveCockpitDiagnostics();
  _androidAcceptanceUsesRemoteOnlyHostCapture();
  _androidAcceptanceDelaysBaselineUntilWorkbench();
  _androidAcceptanceStabilizesRemoteCommandsBeforeWorkflow();
  _cockpitEntrypointStartsRemoteBeforeGalleryBootstrap();
  _workflowAllowsSlowGalleryBootstrap();
  _windowsFlutterRootResolvesBat();
  _nonWindowsFlutterRootResolvesBinary();
  _failedValidationResultKeepsEvidence();
  stdout.writeln('Pixa gallery cockpit acceptance self-test passed.');
}

void _mobilePlatformsUseCiSizedLaunchBudget() {
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('android') == 2160,
    'Android cockpit acceptance should allow CI cold build and install.',
  );
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('ios') == 2160,
    'iOS cockpit acceptance should allow CI cold simulator build.',
  );
  _expect(
    acceptance.defaultLaunchTimeoutSecondsForPlatform('macos') == 240,
    'Desktop cockpit acceptance should keep the normal launch budget.',
  );
}

void _cockpitEntrypointStartsRemoteBeforeGalleryBootstrap() {
  final source = File(
    'examples/pixa_gallery/cockpit/main.dart',
  ).readAsStringSync();
  _expect(
    !source.contains('runApp(await'),
    'Cockpit entrypoint should not await gallery bootstrap before runApp.',
  );
  _expect(
    source.contains('FutureBuilder'),
    'Cockpit entrypoint should bootstrap the gallery inside the running app.',
  );
}

void _workflowAllowsSlowGalleryBootstrap() {
  final workflow = File(
    'examples/pixa_gallery/cockpit/pixa_gallery_acceptance.yaml',
  ).readAsStringSync();
  final match = RegExp(
    r'stepId:\s*wait-gallery-workbench[\s\S]*?maxAttempts:\s*(\d+)[\s\S]*?delayMs:\s*(\d+)',
  ).firstMatch(workflow);
  _expect(match != null, 'Cockpit workflow should wait for Gallery Workbench.');
  final attempts = int.parse(match!.group(1)!);
  final delayMs = int.parse(match.group(2)!);
  _expect(
    attempts * delayMs >= 120000,
    'Cockpit workflow should allow slow Android gallery bootstrap.',
  );
}

void _androidCiUsesFreshEmulatorForCockpitAcceptance() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const probeStep = '- name: Build and run Android platform probe';
  const cockpitStep = '- name: Run Android gallery cockpit acceptance';
  final probeIndex = workflow.indexOf(probeStep);
  final cockpitIndex = workflow.indexOf(cockpitStep);

  _expect(probeIndex >= 0, 'Android platform probe step should exist.');
  _expect(
    cockpitIndex > probeIndex,
    'Android cockpit acceptance should run after the platform probe.',
  );

  final nextStepIndex = workflow.indexOf('\n      - name:', probeIndex + 1);
  final probeBlock = workflow.substring(
    probeIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  _expect(
    !probeBlock.contains('pixa_gallery_cockpit_acceptance.dart'),
    'Android platform probe should not reuse its emulator for cockpit acceptance.',
  );
}

void _androidCiEnablesHardwareAcceleration() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const kvmStep = '- name: Enable Android emulator KVM acceleration';
  final kvmIndex = workflow.indexOf(kvmStep);
  const probeStep = '- name: Build and run Android platform probe';
  final probeIndex = workflow.indexOf(probeStep);
  _expect(kvmIndex >= 0, 'Android CI should enable KVM acceleration.');
  _expect(
    probeIndex > kvmIndex,
    'Android CI should enable KVM before starting any emulator.',
  );
  final nextStepIndex = workflow.indexOf('\n      - name:', kvmIndex + 1);
  final kvmBlock = workflow.substring(
    kvmIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  _expect(
    kvmBlock.contains('/dev/kvm'),
    'Android KVM acceleration step should configure /dev/kvm access.',
  );
}

void _androidCiUsesCiSizedEmulatorBootBudget() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final matches = RegExp(
    r'emulator-boot-timeout:\s*(\d+)',
  ).allMatches(workflow);
  final timeouts = <int>[for (final m in matches) int.parse(m.group(1)!)];
  _expect(
    timeouts.length == 2,
    'Android CI should declare boot timeouts for both emulator runs.',
  );
  _expect(
    timeouts.every((timeout) => timeout == 2700),
    'Android emulator boot timeouts should allow slow CI boot.',
  );
}

void _androidCiCapturesCockpitDiagnosticsOnFailure() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  const cockpitStep = '- name: Run Android gallery cockpit acceptance';
  final cockpitIndex = workflow.indexOf(cockpitStep);
  _expect(cockpitIndex >= 0, 'Android cockpit acceptance step should exist.');
  final nextStepIndex = workflow.indexOf('\n      - name:', cockpitIndex + 1);
  final cockpitBlock = workflow.substring(
    cockpitIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  _expect(
    cockpitBlock.contains('bash tool/pixa_android_cockpit_ci.sh'),
    'Android cockpit acceptance should run through a single shell script.',
  );
  for (final required in <String>[
    'android-diagnostics',
    'adb devices -l',
    'adb -s emulator-5554 forward --list',
    'adb -s emulator-5554 logcat -c',
    'pidof dev.pixa.pixa_gallery',
    'dumpsys activity processes',
    'logcat -d -v time -t 2000',
  ]) {
    _expect(
      script.contains(required),
      'Android cockpit failure diagnostics should collect $required.',
    );
  }
  _expect(
    script.contains(r'exit "$status"'),
    'Android cockpit CI script should preserve the acceptance exit code.',
  );
}

void _androidCiCapturesLiveCockpitDiagnostics() {
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  for (final required in <String>[
    'live-logcat.txt',
    'live-adb-heartbeat.txt',
    'live-process-snapshot.txt',
    'pixa_android_cockpit_monitor',
    'cleanup_live_diagnostics',
  ]) {
    _expect(
      script.contains(required),
      'Android cockpit live diagnostics should include $required.',
    );
  }
}

void _androidAcceptanceUsesRemoteOnlyHostCapture() {
  _expect(
    acceptance.usesRemoteOnlyHostCaptureForPlatform('android'),
    'Android cockpit acceptance should use remote-only host capture.',
  );
  for (final platform in <String>['ios', 'linux', 'macos', 'windows']) {
    _expect(
      !acceptance.usesRemoteOnlyHostCaptureForPlatform(platform),
      '$platform cockpit acceptance should keep the default capture strategy.',
    );
  }

  final source = File(
    'tool/pixa_gallery_cockpit_acceptance.dart',
  ).readAsStringSync();
  for (final required in <String>[
    'usesRemoteOnlyHostCaptureForPlatform',
    'CockpitCaptureStrategyResolver',
    '_remoteOnlyAndroidCaptureStrategyResolver',
    'CockpitRemoteCaptureAdapter',
    'adbAdapterFactory',
  ]) {
    _expect(
      source.contains(required),
      'Android cockpit acceptance should force remote Flutter screenshot capture.',
    );
  }
}

void _androidAcceptanceDelaysBaselineUntilWorkbench() {
  _expect(
    !acceptance.baselineCaptureScreenshotForPlatform('android'),
    'Android cockpit acceptance should disable automatic baseline capture.',
  );
  for (final platform in <String>['ios', 'linux', 'macos', 'windows']) {
    _expect(
      acceptance.baselineCaptureScreenshotForPlatform(platform),
      '$platform cockpit acceptance should keep automatic baseline capture.',
    );
  }

  final workflowSource = File(
    'examples/pixa_gallery/cockpit/pixa_gallery_acceptance.yaml',
  ).readAsStringSync();
  final androidWorkflow = acceptance.workflowForAcceptance(
    workflowSource,
    'android',
  );
  final macosWorkflow = acceptance.workflowForAcceptance(
    workflowSource,
    'macos',
  );
  _expect(
    androidWorkflow.contains('platform: android'),
    'Android cockpit acceptance should generate an Android workflow.',
  );
  _expect(
    macosWorkflow.contains('platform: macos'),
    'macOS cockpit acceptance should keep the macOS workflow platform.',
  );
  _expect(
    !macosWorkflow.contains('commandId: baseline_capture'),
    'Non-Android cockpit acceptance should not inject a manual baseline.',
  );
  _expect(
    androidWorkflow.contains('commandId: baseline_capture'),
    'Android manual baseline should keep the canonical baseline command id.',
  );
  final waitIndex = androidWorkflow.indexOf('wait-gallery-workbench');
  final baselineIndex = androidWorkflow.indexOf('commandId: baseline_capture');
  final parsedAndroidWorkflow = cockpit.cockpitControlScriptFromText(
    androidWorkflow,
  );
  _expect(
    parsedAndroidWorkflow.workflowSteps.isNotEmpty,
    'Android workflow should parse after injecting the manual baseline.',
  );
  _expect(
    waitIndex >= 0 && baselineIndex > waitIndex,
    'Android manual baseline should run after the Gallery Workbench wait.',
  );
  _expect(
    androidWorkflow.indexOf('assert-source-control') > baselineIndex,
    'Android manual baseline should run before the first post-baseline assertion.',
  );

  final androidConfig = _sampleValidateTaskConfig(
    platform: 'android',
    workflow: androidWorkflow,
  );
  final macosConfig = _sampleValidateTaskConfig(
    platform: 'macos',
    workflow: macosWorkflow,
  );
  _expect(
    androidConfig.contains('captureScreenshot: false'),
    'Android validate-task config should disable automatic baseline capture.',
  );
  _expect(
    macosConfig.contains('captureScreenshot: true'),
    'Non-Android validate-task config should keep automatic baseline capture.',
  );
}

String _sampleValidateTaskConfig({
  required String platform,
  required String workflow,
}) {
  return acceptance.validateTaskConfig(
    projectDir: '/tmp/pixa_gallery',
    platform: platform,
    deviceId: platform,
    sessionPort: 47331,
    launchTimeoutSeconds: 240,
    outputRoot: '/tmp/pixa_gallery_cockpit',
    scriptPath: '/tmp/pixa_gallery_cockpit/workflow.yaml',
    workflow: workflow,
  );
}

void _androidAcceptanceStabilizesRemoteCommandsBeforeWorkflow() {
  final source = File(
    'tool/pixa_gallery_cockpit_acceptance.dart',
  ).readAsStringSync();
  for (final required in <String>[
    'androidRemoteCommandSurfaceStableSeconds',
    '_launchWithAndroidRemoteCommandSurfaceStabilization',
    'waitForAndroidRemoteCommandSurface',
    'client.ping()',
    'client.ready()',
    'client.readStatus()',
    'client.readSnapshot()',
    'client.waitForUiIdle(',
  ]) {
    _expect(
      source.contains(required),
      'Android cockpit acceptance should stabilize remote commands with $required.',
    );
  }
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
