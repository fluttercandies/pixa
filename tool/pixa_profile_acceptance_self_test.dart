import 'dart:async';
import 'dart:io';

import 'pixa_profile_acceptance.dart' as acceptance;
import 'pixa_native_assets_log_check.dart' as native_assets;

Future<void> main() async {
  final acceptance.MacOSProfileHostState unlockedHost =
      acceptance.MacOSProfileHostState.fromJson(<String, Object?>{
        'screenLocked': false,
        'target': <String, Object?>{
          'bundleIdentifier': 'dev.pixa.pixaGallery',
          'running': true,
          'hidden': false,
          'onScreenWindowCount': 1,
        },
      });
  acceptance.validateMacOSProfileHostState(
    unlockedHost,
    requireTargetVisible: true,
    targetBundleIdentifier: 'dev.pixa.pixaGallery',
  );
  _expectThrowsStateError(
    () => acceptance.validateMacOSProfileHostState(
      acceptance.MacOSProfileHostState.fromJson(<String, Object?>{
        'screenLocked': true,
      }),
      requireTargetVisible: false,
      targetBundleIdentifier: 'dev.pixa.pixaGallery',
    ),
    'locked macOS sessions must be rejected before profile capture',
  );
  acceptance.validateMacOSProfileHostState(
    acceptance.MacOSProfileHostState.fromJson(<String, Object?>{
      'screenLocked': false,
      'target': <String, Object?>{
        'bundleIdentifier': 'dev.pixa.pixaGallery',
        'running': true,
        'hidden': false,
        'onScreenWindowCount': 1,
      },
    }),
    requireTargetVisible: true,
    targetBundleIdentifier: 'dev.pixa.pixaGallery',
  );
  _expect(
    acceptance
            .profileMacOSHostProbeArguments(targetBundleIdentifier: null)
            .join(' ') ==
        'swift tool/pixa_macos_profile_host_state.swift',
    'macOS preflight must use the checked-in host-state probe',
  );
  _expect(
    acceptance
            .profileMacOSHostProbeArguments(
              targetBundleIdentifier: 'dev.pixa.pixaGallery',
              monitorTargetVisible: true,
            )
            .join(' ') ==
        'swift tool/pixa_macos_profile_host_state.swift '
            '--target-bundle-id=dev.pixa.pixaGallery '
            '--monitor-target-visible',
    'macOS target verification must not request application focus',
  );
  final Completer<int> blockedProfileExit = Completer<int>();
  final Completer<int> failedWatchdogExit = Completer<int>();
  var profileTerminated = false;
  await _expectThrowsStateErrorAsync(
    () => acceptance.awaitProfileProcessWithWatchdog(
      profileExit: blockedProfileExit.future,
      terminateProfile: () => profileTerminated = true,
      watchdogExit: failedWatchdogExit.future,
      terminateWatchdog: () {},
    ),
    trigger: () => failedWatchdogExit.complete(3),
    message: 'visibility watchdog failure must reject profile evidence',
  );
  _expect(
    profileTerminated,
    'visibility watchdog failure must terminate the profile process',
  );
  final Completer<int> successfulProfileExit = Completer<int>();
  final Completer<int> blockedWatchdogExit = Completer<int>();
  var watchdogTerminated = false;
  final Future<int> successfulRun = acceptance.awaitProfileProcessWithWatchdog(
    profileExit: successfulProfileExit.future,
    terminateProfile: () {},
    watchdogExit: blockedWatchdogExit.future,
    terminateWatchdog: () => watchdogTerminated = true,
  );
  successfulProfileExit.complete(0);
  _expect(
    await successfulRun == 0 && watchdogTerminated,
    'a completed profile run must stop its visibility watchdog',
  );
  final Completer<int> profileAfterTargetExit = Completer<int>();
  final Completer<int> targetExit = Completer<int>();
  var profileTerminatedAfterTargetExit = false;
  final Future<int> normalTargetExitRun = acceptance
      .awaitProfileProcessWithWatchdog(
        profileExit: profileAfterTargetExit.future,
        terminateProfile: () => profileTerminatedAfterTargetExit = true,
        watchdogExit: targetExit.future,
        terminateWatchdog: () {},
      );
  targetExit.complete(0);
  await Future<void>.delayed(Duration.zero);
  profileAfterTargetExit.complete(0);
  _expect(
    await normalTargetExitRun == 0 && !profileTerminatedAfterTargetExit,
    'normal target teardown must wait for the profile wrapper exit code',
  );
  var triggerCount = 0;
  final acceptance.ProfileOutputTrigger outputTrigger =
      acceptance.ProfileOutputTrigger(
        marker: 'VMServiceFlutterDriver: Connecting',
        action: () async {
          triggerCount += 1;
        },
      );
  await outputTrigger.observe('VMServiceFlutterDri');
  await outputTrigger.observe('ver: Connecting to the app');
  await outputTrigger.observe('VMServiceFlutterDriver: Connecting again');
  await outputTrigger.finish();
  _expect(
    triggerCount == 1,
    'profile output trigger must survive chunk boundaries and run once',
  );
  _expect(
    acceptance.profileRustVersionCommand().join(' ') == 'rustc --version',
    'profile metadata must probe the host Rust compiler',
  );
  _expect(
    acceptance.profileGitTreeStateFromPorcelain('''
?? .third/
?? AGENTS.md
?? GOALS.md
?? docs/
?? REF.md
''') ==
        'clean',
    'local planning files excluded from Git by policy must not block evidence',
  );
  _expect(
    acceptance.profileGitTreeStateFromPorcelain('''
?? GOALS.md
?? packages/pixa/lib/untracked.dart
''') ==
        'dirty',
    'untracked source files must keep profile evidence dirty',
  );
  _expect(
    acceptance.profileGitTreeStateFromPorcelain(' M GOALS.md') == 'dirty',
    'tracked changes must never be hidden by the local planning filter',
  );
  final String deviceIdHash = 'a'.padLeft(64, 'a');
  final List<String> arguments = acceptance.buildProfileDriveArguments(
    deviceId: 'fixture-device',
    deviceLabel: 'fixture-120hz-class',
    deviceIdHash: deviceIdHash,
    flutterVersion: '3.44.0',
    rustVersion: 'rustc 1.88.0',
    gitCommit: '0123456789abcdef0123456789abcdef01234567',
    gitTreeState: 'clean',
    runId: 'fixture-run-1',
    networkConcurrency: 128,
    includeLiveNetwork: true,
  );

  _expect(arguments.contains('drive'), 'runner should invoke flutter drive');
  _expect(arguments.contains('--profile'), 'runner must force profile mode');
  _expect(
    arguments.contains('-dfixture-device'),
    'runner should select the measured device explicitly',
  );
  _expect(
    arguments.contains('--driver=test_driver/pixa_profile_scroll_driver.dart'),
    'runner should use the profile response driver',
  );
  _expect(
    arguments.contains(
      '--target=integration_test/pixa_profile_scroll_test.dart',
    ),
    'runner should target the FrameTiming integration test',
  );
  for (final String define in <String>[
    '--dart-define=PIXA_PROFILE_DEVICE_ID_HASH=$deviceIdHash',
    '--dart-define=PIXA_PROFILE_DEVICE_LABEL=fixture-120hz-class',
    '--dart-define=PIXA_FLUTTER_VERSION=3.44.0',
    '--dart-define=PIXA_RUST_VERSION=rustc 1.88.0',
    '--dart-define=PIXA_GIT_COMMIT=0123456789abcdef0123456789abcdef01234567',
    '--dart-define=PIXA_GIT_TREE_STATE=clean',
    '--dart-define=PIXA_PROFILE_RUN_ID=fixture-run-1',
    '--dart-define=PIXA_PROFILE_NETWORK_CONCURRENCY=128',
    '--dart-define=PIXA_PROFILE_LIVE_NETWORK=true',
  ]) {
    _expect(arguments.contains(define), 'missing metadata define: $define');
  }
  _expect(
    !arguments.any(
      (String argument) =>
          argument.startsWith('--dart-define=PIXA_PROFILE_DEVICE_ID='),
    ),
    'raw device identifiers must not be persisted in profile evidence',
  );

  final Directory temp = await Directory.systemTemp.createTemp(
    'pixa-profile-acceptance-self-test-',
  );
  try {
    final Directory cleanRepository = Directory('${temp.path}/clean-git')
      ..createSync();
    final ProcessResult gitInit = await Process.run('rtk', <String>[
      'proxy',
      'git',
      'init',
      '--quiet',
    ], workingDirectory: cleanRepository.path);
    _expect(gitInit.exitCode == 0, 'clean Git fixture must initialize');
    _expect(
      await acceptance.readProfileGitStatusPorcelain(cleanRepository) == '',
      'machine-readable Git status must preserve empty porcelain output',
    );

    final File driverRaw = File('${temp.path}/driver/raw.json');
    final File requestedRaw = File('${temp.path}/custom/evidence.json');
    final File staleReport = File('${temp.path}/custom/report.md');
    await driverRaw.parent.create(recursive: true);
    await driverRaw.writeAsString('{"fresh":true}');
    await staleReport.parent.create(recursive: true);
    await staleReport.writeAsString('stale PASS');

    await acceptance.removeProfileArtifacts(<String>[staleReport.path]);
    await acceptance.moveProfileRawArtifact(
      driverRawPath: driverRaw.path,
      requestedRawPath: requestedRaw.path,
    );

    _expect(
      !staleReport.existsSync(),
      'stale reports must be removed up front',
    );
    _expect(!driverRaw.existsSync(), 'driver raw should be moved, not copied');
    _expect(
      await requestedRaw.readAsString() == '{"fresh":true}',
      'custom --raw paths must receive the fresh driver artifact',
    );

    final Directory project = Directory('${temp.path}/gallery')..createSync();
    final File artifact = File(
      '${project.path}/.dart_tool/lib/libpixa_runtime.dylib',
    );
    await artifact.parent.create(recursive: true);
    await artifact.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    final File rawBuildLog = File('${temp.path}/native.raw.log')
      ..writeAsStringSync('Running build hooks...\n');
    final File nativeLog = File('${temp.path}/native.log');

    final File discovered = await acceptance.locatePixaRuntimeArtifact(project);
    await acceptance.writeNativeAssetsEvidenceLog(
      output: nativeLog,
      rawBuildLog: rawBuildLog,
      platform: 'macos',
      mode: 'profile',
      gitCommit: '0123456789abcdef0123456789abcdef01234567',
      gitTreeState: 'clean',
      artifact: discovered,
      exitCode: 0,
    );

    final native_assets.NativeAssetFrameworkWarningReport nativeReport =
        native_assets.NativeAssetFrameworkWarningReport.parse(
          await nativeLog.readAsString(),
          requiredGitCommit: '0123456789abcdef0123456789abcdef01234567',
          requiredMode: 'profile',
        );
    _expect(nativeReport.passed, 'captured Native Assets evidence must pass');
    _expect(
      nativeReport.artifactBytes == 4,
      'artifact evidence should record measured bytes',
    );
    _expect(
      acceptance.profilePlatformFromTarget('darwin-arm64') == 'macos' &&
          acceptance.profilePlatformFromTarget('android-arm64') == 'android',
      'Flutter target platforms should map to release platform ids',
    );
  } finally {
    await temp.delete(recursive: true);
  }

  stdout.writeln('Pixa profile acceptance self-test passed.');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

void _expectThrowsStateError(void Function() body, String message) {
  try {
    body();
  } on StateError {
    return;
  }
  throw StateError(message);
}

Future<void> _expectThrowsStateErrorAsync(
  Future<void> Function() body, {
  required void Function() trigger,
  required String message,
}) async {
  final Future<void> result = body();
  trigger();
  try {
    await result;
  } on StateError {
    return;
  }
  throw StateError(message);
}
