import 'dart:convert';
import 'dart:io';

import 'package:cockpit/cockpit.dart' as cockpit;

import 'pixa_gallery_cockpit_acceptance.dart' as acceptance;

void main() {
  _mobilePlatformsUseCiSizedLaunchBudget();
  _androidCiEnablesHardwareAcceleration();
  _androidCiUsesOneEmulatorForPlatformAcceptance();
  _androidCiReleasesProbeBuildResources();
  _androidCiUsesNonPersistentBuildProcesses();
  _androidCiPrebuildsCockpitBeforeStartingTheEmulator();
  _androidAcceptanceReusesThePrebuiltCockpitApk();
  _androidCiUsesCiSizedEmulatorBootBudget();
  _androidCiCapturesCockpitDiagnosticsOnFailure();
  _androidCiCapturesLiveCockpitDiagnostics();
  _androidAcceptanceUsesRemoteOnlyHostCapture();
  _androidAcceptanceBuildsOnlyTheEmulatorAbi();
  _androidAcceptanceDelaysBaselineUntilWorkbench();
  _androidAcceptanceStabilizesRemoteCommandsBeforeWorkflow();
  _cockpitEntrypointStartsRemoteBeforeGalleryBootstrap();
  _workflowAllowsSlowGalleryBootstrap();
  _windowsFlutterRootResolvesBat();
  _nonWindowsFlutterRootResolvesBinary();
  _failedValidationResultKeepsEvidence();
  stdout.writeln('Pixa gallery cockpit acceptance self-test passed.');
}

void _androidCiReleasesProbeBuildResources() {
  final String script = File(
    'tool/pixa_android_platform_ci.sh',
  ).readAsStringSync();
  final String properties = File(
    'examples/pixa_gallery/android/gradle.properties',
  ).readAsStringSync();
  final int probe = script.indexOf('dart run tool/pixa_platform_build.dart');
  final int stop = script.indexOf(
    '.dart_tool/pixa_platform_probe/android/android/gradlew --stop',
    probe,
  );
  final int cockpit = script.indexOf(
    'bash tool/pixa_android_cockpit_ci.sh',
    probe,
  );

  _expect(probe >= 0, 'Android platform probe should exist.');
  _expect(
    stop > probe && cockpit > stop,
    'Android CI should stop the probe Gradle daemon before Cockpit.',
  );
  _expect(
    properties.contains('org.gradle.jvmargs=-Xmx2G') &&
        properties.contains('kotlin.daemon.jvmargs=-Xmx1G') &&
        !properties.contains('-Xmx8G'),
    'Android gallery builds should fit beside the CI emulator.',
  );
}

void _androidCiUsesNonPersistentBuildProcesses() {
  final String script = File(
    'tool/pixa_android_platform_ci.sh',
  ).readAsStringSync();
  final String buildEnvironment = File(
    'tool/pixa_android_ci_build_env.sh',
  ).readAsStringSync();
  final int helper = buildEnvironment.indexOf(
    'run_memory_bounded_android_build()',
  );
  final int probe = script.indexOf(
    'run_memory_bounded_android_build dart run '
    'tool/pixa_platform_build.dart',
  );
  final int cockpit = script.indexOf(
    'run_memory_bounded_android_build bash '
    'tool/pixa_android_cockpit_ci.sh',
  );

  _expect(
    helper >= 0 &&
        script.contains('source tool/pixa_android_ci_build_env.sh') &&
        probe >= 0 &&
        cockpit > probe,
    'Android CI should bound both serial Android builds.',
  );
  _expect(
    buildEnvironment.contains('-Dorg.gradle.daemon=false') &&
        buildEnvironment.contains('-Dorg.gradle.workers.max=2'),
    'Android CI should avoid persistent Gradle daemons and bound workers.',
  );
  _expect(
    buildEnvironment.contains(
      'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy=in-process',
    ),
    'Android CI should compile Kotlin inside the bounded Gradle process.',
  );
}

void _androidCiPrebuildsCockpitBeforeStartingTheEmulator() {
  final String workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const String prebuildStep = '- name: Prebuild Android gallery Cockpit APK';
  const String emulatorStep =
      '- name: Build and run Android platform acceptance';
  final int prebuild = workflow.indexOf(prebuildStep);
  final int emulator = workflow.indexOf(emulatorStep);
  final File script = File('tool/pixa_android_cockpit_prebuild_ci.sh');

  _expect(
    prebuild >= 0 && emulator > prebuild,
    'Android Cockpit should build before the memory-heavy emulator starts.',
  );
  _expect(
    script.existsSync(),
    'Android CI should provide a dedicated Cockpit prebuild script.',
  );
  final String source = script.readAsStringSync();
  for (final String required in <String>[
    'flutter build apk',
    '--target cockpit/main.dart',
    '--target-platform=android-x64',
    'FLUTTER_COCKPIT_REMOTE_ENABLED=true',
    'FLUTTER_COCKPIT_REMOTE_LAUNCH_ID=',
    'PIXA_ANDROID_COCKPIT_PREBUILT_APK',
    'dart compilation-server shutdown',
  ]) {
    _expect(
      source.contains(required),
      'Android Cockpit prebuild should include $required.',
    );
  }
}

void _androidAcceptanceReusesThePrebuiltCockpitApk() {
  final String ciScript = File(
    'tool/pixa_android_cockpit_ci.sh',
  ).readAsStringSync();
  final String acceptanceSource = File(
    'tool/pixa_gallery_cockpit_acceptance.dart',
  ).readAsStringSync();

  for (final String required in <String>[
    '--prebuilt-android-apk=',
    '--prebuilt-android-launch-id=',
    'PIXA_ANDROID_COCKPIT_PREBUILT_APK',
    'PIXA_ANDROID_COCKPIT_LAUNCH_ID',
  ]) {
    _expect(
      ciScript.contains(required),
      'Android Cockpit CI should pass $required to acceptance.',
    );
  }
  for (final String required in <String>[
    'CockpitAndroidRemoteSessionLauncher',
    'CockpitRemoteSessionLaunchOptions',
    'prebuiltAndroidApk',
    'prebuiltAndroidLaunchId',
    'isCockpitAndroidBuildApkCommand',
  ]) {
    _expect(
      acceptanceSource.contains(required),
      'Android acceptance should reuse the APK through $required.',
    );
  }
  _expect(
    acceptance.isCockpitAndroidBuildApkCommand(
      '/opt/flutter/bin/flutter',
      const <String>['build', 'apk', '--debug'],
    ),
    'Prebuilt Android acceptance should skip only Flutter APK builds.',
  );
  _expect(
    !acceptance.isCockpitAndroidBuildApkCommand('adb', const <String>[
      'install',
      '-r',
      'app-debug.apk',
    ]),
    'Prebuilt Android acceptance should still execute adb installation.',
  );
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

void _androidCiUsesOneEmulatorForPlatformAcceptance() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const acceptanceStep = '- name: Build and run Android platform acceptance';
  final acceptanceIndex = workflow.indexOf(acceptanceStep);

  _expect(
    acceptanceIndex >= 0,
    'Android platform acceptance step should exist.',
  );
  _expect(
    RegExp(
          r'reactivecircus/android-emulator-runner@',
        ).allMatches(workflow).length ==
        1,
    'Android platform probe and cockpit acceptance should share one emulator.',
  );

  final nextStepIndex = workflow.indexOf(
    '\n      - name:',
    acceptanceIndex + 1,
  );
  final acceptanceBlock = workflow.substring(
    acceptanceIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  final script = File('tool/pixa_android_platform_ci.sh').readAsStringSync();
  _expect(
    acceptanceBlock.contains('script: bash tool/pixa_android_platform_ci.sh') &&
        script.contains('dart run tool/pixa_platform_build.dart') &&
        script.contains('bash tool/pixa_android_cockpit_ci.sh'),
    'One Android emulator step should run both platform acceptance surfaces.',
  );
}

void _androidCiEnablesHardwareAcceleration() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const kvmStep = '- name: Enable Android emulator KVM acceleration';
  final kvmIndex = workflow.indexOf(kvmStep);
  const probeStep = '- name: Build and run Android platform acceptance';
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
    timeouts.length == 1,
    'Android CI should declare one emulator boot timeout.',
  );
  _expect(
    timeouts.every((timeout) => timeout == 2700),
    'Android emulator boot timeouts should allow slow CI boot.',
  );
}

void _androidCiCapturesCockpitDiagnosticsOnFailure() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final platformScript = File(
    'tool/pixa_android_platform_ci.sh',
  ).readAsStringSync();
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  const cockpitStep = '- name: Build and run Android platform acceptance';
  final cockpitIndex = workflow.indexOf(cockpitStep);
  _expect(cockpitIndex >= 0, 'Android cockpit acceptance step should exist.');
  final nextStepIndex = workflow.indexOf('\n      - name:', cockpitIndex + 1);
  final cockpitBlock = workflow.substring(
    cockpitIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  _expect(
    cockpitBlock.contains('script: bash tool/pixa_android_platform_ci.sh') &&
        platformScript.contains('bash tool/pixa_android_cockpit_ci.sh'),
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

void _androidAcceptanceBuildsOnlyTheEmulatorAbi() {
  final android = acceptance.cockpitLaunchConfigurationForPlatform('android');
  final macos = acceptance.cockpitLaunchConfigurationForPlatform('macos');

  _expect(
    android.flutterArgs.length == 1 &&
        android.flutterArgs.single == '--target-platform=android-x64',
    'Android Cockpit should build only the ABI used by its x64 emulator.',
  );
  _expect(
    macos.isEmpty,
    'Non-Android Cockpit launch configuration should remain unchanged.',
  );
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
    androidConfig.contains("- '--target-platform=android-x64'"),
    'Android validate-task config should preserve the x64-only launch.',
  );
  _expect(
    macosConfig.contains('captureScreenshot: true'),
    'Non-Android validate-task config should keep automatic baseline capture.',
  );
  _expect(
    !macosConfig.contains('--target-platform'),
    'Non-Android validate-task config should not select an Android ABI.',
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
