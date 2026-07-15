import 'dart:convert';
import 'dart:io';

import 'package:cockpit/cockpit.dart' as cockpit;

import 'pixa_gallery_cockpit_acceptance.dart' as acceptance;

void main() {
  _mobilePlatformsUseCiSizedLaunchBudget();
  _androidCiSeparatesCockpitFromHardwareAcceleration();
  _androidCiIsolatesPlatformProbeFromCockpit();
  _androidCockpitSeparatesUiFrom16KbAcceptance();
  _androidCockpitPinsReproducibleEmulatorBuild();
  _androidCiReleasesProbeBuildResources();
  _androidCiUsesNonPersistentBuildProcesses();
  _androidBuildPrerequisiteRetrySucceedsOnThirdAttempt();
  _androidBuildPrerequisiteRetryStopsAtConfiguredLimit();
  _androidCiPrebuildsCockpitBeforeStartingTheEmulator();
  _androidAcceptanceReusesThePrebuiltCockpitApk();
  _androidCiUsesCiSizedEmulatorBootBudget();
  _androidCockpitUsesStableGuestMemoryBudget();
  _androidCiCapturesCockpitDiagnosticsOnFailure();
  _androidCiCapturesLiveCockpitDiagnostics();
  _androidCiCapturesQemuExitStatus();
  _windowsNativeDependencyInstallRetriesTransientFailure();
  _androidAcceptanceUsesRemoteOnlyHostCapture();
  _androidAcceptanceBuildsOnlyTheEmulatorAbi();
  _androidAcceptanceDelaysBaselineUntilWorkbench();
  _androidAcceptanceStabilizesRemoteCommandsBeforeWorkflow();
  _androidRemoteCommandTraceIsStructured();
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

  _expect(probe >= 0, 'Android platform probe should exist.');
  _expect(
    stop > probe,
    'Android CI should stop the probe Gradle daemon after acceptance.',
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
  final String prebuild = File(
    'tool/pixa_android_cockpit_prebuild_ci.sh',
  ).readAsStringSync();
  final int cockpitBuild = prebuild.indexOf(
    'run_memory_bounded_android_build_with_retry 3 flutter build apk',
  );

  _expect(
    helper >= 0 &&
        script.contains('source tool/pixa_android_ci_build_env.sh') &&
        probe >= 0 &&
        cockpitBuild >= 0,
    'Android CI should bound both isolated Android builds.',
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

void _androidBuildPrerequisiteRetrySucceedsOnThirdAttempt() {
  final result = _runAndroidBuildRetryProbe(
    maxAttempts: 3,
    successfulAttempt: 3,
  );
  _expect(
    result.exitCode == 0,
    'Android build prerequisite retry should recover on the third attempt: '
    '${result.stderr}',
  );
  _expect(
    result.attempts == 3,
    'Android build prerequisite retry should run exactly three attempts.',
  );
}

void _androidBuildPrerequisiteRetryStopsAtConfiguredLimit() {
  final result = _runAndroidBuildRetryProbe(
    maxAttempts: 3,
    successfulAttempt: 4,
  );
  _expect(
    result.exitCode != 0,
    'Android build prerequisite retry should preserve terminal failure.',
  );
  _expect(
    result.attempts == 3,
    'Android build prerequisite retry should stop at the configured limit.',
  );
}

({int exitCode, int attempts, String stderr}) _runAndroidBuildRetryProbe({
  required int maxAttempts,
  required int successfulAttempt,
}) {
  final temp = Directory.systemTemp.createTempSync(
    'pixa_android_build_retry_self_test_',
  );
  try {
    final counter = File('${temp.path}/attempts.txt');
    final probe = File('${temp.path}/probe.sh')
      ..writeAsStringSync('''
#!/usr/bin/env bash
set -euo pipefail
counter_file="\$1"
successful_attempt="\$2"
attempt=0
if [[ -f "\$counter_file" ]]; then
  attempt="\$(<"\$counter_file")"
fi
attempt="\$((attempt + 1))"
printf '%s' "\$attempt" >"\$counter_file"
if (( attempt < successful_attempt )); then
  exit 75
fi
''');
    final process = Process.runSync('bash', <String>[
      '-c',
      '''
source tool/pixa_android_ci_build_env.sh
PIXA_ANDROID_BUILD_RETRY_DELAY_SECONDS=0 \\
  run_memory_bounded_android_build_with_retry "\$1" bash "\$2" "\$3" "\$4"
''',
      '_',
      '$maxAttempts',
      probe.path,
      counter.path,
      '$successfulAttempt',
    ]);
    return (
      exitCode: process.exitCode,
      attempts: counter.existsSync()
          ? int.parse(counter.readAsStringSync())
          : 0,
      stderr: process.stderr.toString(),
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _androidCiPrebuildsCockpitBeforeStartingTheEmulator() {
  final String workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const String prebuildStep = '- name: Prebuild Android gallery Cockpit APK';
  const String emulatorStep =
      '- name: Build and run Android Cockpit acceptance';
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
    'run_memory_bounded_android_build_with_retry 3 flutter build apk',
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
  _expect(
    !source.contains('./android/gradlew'),
    'Android Cockpit must not invoke the ignored Gradle wrapper directly.',
  );
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
    acceptance.defaultLaunchTimeoutSecondsForPlatform('macos') == 600,
    'macOS cockpit acceptance should allow a cold Native Assets build.',
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

void _androidCiIsolatesPlatformProbeFromCockpit() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final platformScript = File(
    'tool/pixa_android_platform_ci.sh',
  ).readAsStringSync();

  _expect(
    workflow.contains('\n  android-cockpit:\n'),
    'Android Cockpit should have an isolated CI job.',
  );
  _expect(
    RegExp(
          r'reactivecircus/android-emulator-runner@',
        ).allMatches(workflow).length ==
        2,
    'Android platform probe and cockpit acceptance should use isolated emulators.',
  );
  _expect(
    platformScript.contains('dart run tool/pixa_platform_build.dart') &&
        !platformScript.contains('bash tool/pixa_android_cockpit_ci.sh'),
    'The Android platform job should not reuse its guest for Cockpit.',
  );
  _expect(
    RegExp(
      r'platform-evidence:[\s\S]*?needs:[\s\S]*?- android-cockpit',
    ).hasMatch(workflow),
    'Platform evidence should require isolated Android Cockpit acceptance.',
  );
}

void _androidCiSeparatesCockpitFromHardwareAcceleration() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const kvmStep = '- name: Enable Android emulator KVM acceleration';
  final kvmMatches = kvmStep.allMatches(workflow).toList(growable: false);
  _expect(
    kvmMatches.length == 1,
    'Only the Android platform probe should enable KVM acceleration.',
  );
  final cockpitStart = workflow.indexOf('\n  android-cockpit:\n');
  final platformStart = workflow.indexOf('\n  platform-build:\n');
  _expect(
    cockpitStart >= 0 && platformStart > cockpitStart,
    'Android Cockpit and platform jobs should both exist.',
  );
  final cockpitJob = workflow.substring(cockpitStart, platformStart);
  final platformJobs = workflow.substring(platformStart);
  _expect(
    cockpitJob.contains('disable-linux-hw-accel: true') &&
        !cockpitJob.contains('/dev/kvm'),
    'Rich Android Cockpit acceptance should avoid the crashing Linux KVM path.',
  );
  _expect(
    platformJobs.contains(kvmStep) && platformJobs.contains('/dev/kvm'),
    'Android platform and 16 KB acceptance should keep KVM acceleration.',
  );
}

void _androidCockpitSeparatesUiFrom16KbAcceptance() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final cockpitStart = workflow.indexOf('\n  android-cockpit:\n');
  final platformStart = workflow.indexOf('\n  platform-build:\n');
  _expect(
    cockpitStart >= 0 && platformStart > cockpitStart,
    'Android Cockpit and platform jobs should both exist.',
  );
  final cockpitJob = workflow.substring(cockpitStart, platformStart);
  final platformJob = workflow.substring(platformStart);
  _expect(
    cockpitJob.contains('api-level: 30') &&
        cockpitJob.contains('target: google_atd\n') &&
        !cockpitJob.contains('google_apis_ps16k'),
    'Android UI acceptance should use the lightweight stable ATD image.',
  );
  _expect(
    platformJob.contains('target: google_apis_ps16k'),
    'Android 16 KB acceptance should keep the ps16k system image.',
  );
}

void _androidCockpitPinsReproducibleEmulatorBuild() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final cockpitStart = workflow.indexOf('\n  android-cockpit:\n');
  final platformStart = workflow.indexOf('\n  platform-build:\n');
  _expect(
    cockpitStart >= 0 && platformStart > cockpitStart,
    'Android Cockpit and platform jobs should both exist.',
  );
  final cockpitJob = workflow.substring(cockpitStart, platformStart);
  _expect(
    cockpitJob.contains(
      'emulator-build: 15261927 # Reproducible diagnostic baseline',
    ),
    'Android Cockpit should pin a reproducible emulator diagnostic baseline.',
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
    'Android CI should declare two isolated emulator boot timeouts.',
  );
  _expect(
    timeouts.every((timeout) => timeout == 2700),
    'Android emulator boot timeouts should allow slow CI boot.',
  );
}

void _androidCockpitUsesStableGuestMemoryBudget() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  final cockpitStart = workflow.indexOf('\n  android-cockpit:\n');
  final platformStart = workflow.indexOf('\n  platform-build:\n');
  _expect(
    cockpitStart >= 0 && platformStart > cockpitStart,
    'Android Cockpit and platform jobs should both exist.',
  );
  final cockpitJob = workflow.substring(cockpitStart, platformStart);
  final platformJob = workflow.substring(platformStart);
  _expect(
    cockpitJob.contains('ram-size: 2048M'),
    'Android Cockpit should use the proven ATD guest RAM budget.',
  );
  _expect(
    cockpitJob.contains('-memory 2048'),
    'Android Cockpit should override duplicate AVD profile RAM settings.',
  );
  _expect(
    script.contains('/proc/meminfo') &&
        script.contains('required_guest_ram_kib=1900000'),
    'Android Cockpit should reject an emulator that did not receive 2 GB RAM.',
  );
  _expect(
    platformJob.contains('ram-size: 2048M'),
    'The passing Android platform probe should keep its smaller RAM budget.',
  );
}

void _androidCiCapturesCockpitDiagnosticsOnFailure() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  const cockpitStep = '- name: Build and run Android Cockpit acceptance';
  final cockpitIndex = workflow.indexOf(cockpitStep);
  _expect(cockpitIndex >= 0, 'Android cockpit acceptance step should exist.');
  final nextStepIndex = workflow.indexOf('\n      - name:', cockpitIndex + 1);
  final cockpitBlock = workflow.substring(
    cockpitIndex,
    nextStepIndex == -1 ? workflow.length : nextStepIndex,
  );
  _expect(
    cockpitBlock.contains('script: bash tool/pixa_android_cockpit_ci.sh'),
    'Android cockpit acceptance should run through its isolated shell script.',
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

void _windowsNativeDependencyInstallRetriesTransientFailure() {
  final workflow = File('.github/workflows/ci.yml').readAsStringSync();
  const step = '- name: Install Windows native ROI build dependencies';
  final start = workflow.indexOf(step);
  final end = workflow.indexOf('\n      - name:', start + step.length);
  _expect(start >= 0 && end > start, 'Windows NASM install step should exist.');
  final block = workflow.substring(start, end);
  _expect(
    block.contains(r'$maxAttempts = 3') &&
        block.contains(r'Start-Sleep') &&
        block.contains('choco install nasm'),
    'Windows NASM install should retry transient Chocolatey failures.',
  );
}

void _androidCiCapturesLiveCockpitDiagnostics() {
  final script = File('tool/pixa_android_cockpit_ci.sh').readAsStringSync();
  for (final required in <String>[
    'live-logcat.txt',
    'live-adb-heartbeat.txt',
    'live-process-snapshot.txt',
    'pixa_android_cockpit_monitor',
    'capture_host_emulator_diagnostics',
    'host-memory.txt',
    '/sys/fs/cgroup/memory.events',
    'host-qemu-process.txt',
    'host-kernel.log',
    'host-emulator-crash.txt',
    '/tmp/android-runner/emu-crash-',
    'cleanup_live_diagnostics',
  ]) {
    _expect(
      script.contains(required),
      'Android cockpit live diagnostics should include $required.',
    );
  }
}

void _androidCiCapturesQemuExitStatus() {
  const scriptPath = 'tool/pixa_android_cockpit_ci.sh';
  final script = File(scriptPath).readAsStringSync();
  final selfTest = Process.runSync('bash', <String>[scriptPath, '--self-test']);
  _expect(
    selfTest.exitCode == 0,
    'Android Cockpit diagnostics should self-test Linux proc stat parsing: '
    '${selfTest.stderr}',
  );
  for (final required in <String>[
    'qemu-pid.txt',
    'qemu-process-timeline.txt',
    'qemu-exit-proc.txt',
    'pixa_proc_stat_field',
    'pixa_qemu_monitor',
    'qemu_start_time',
    'exit_code_raw',
  ]) {
    _expect(
      script.contains(required),
      'Android Cockpit diagnostics should preserve QEMU evidence with $required.',
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
    'action: client.ping',
    'action: client.ready',
    'action: client.readStatus',
    'action: client.readSnapshot',
    'client.waitForUiIdle(',
  ]) {
    _expect(
      source.contains(required),
      'Android cockpit acceptance should stabilize remote commands with $required.',
    );
  }
}

void _androidRemoteCommandTraceIsStructured() {
  final line = acceptance.androidRemoteCommandTraceLine(
    timestamp: DateTime.utc(2026, 7, 15, 12, 34, 56),
    attempt: 3,
    command: 'readSnapshot',
    phase: 'success',
    result: 'snapshot_received',
  );
  final decoded = jsonDecode(line) as Map<String, Object?>;
  _expect(
    decoded['timestampUtc'] == '2026-07-15T12:34:56.000Z' &&
        decoded['attempt'] == 3 &&
        decoded['command'] == 'readSnapshot' &&
        decoded['phase'] == 'success' &&
        decoded['result'] == 'snapshot_received',
    'Android remote command traces should be timestamped structured records.',
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
