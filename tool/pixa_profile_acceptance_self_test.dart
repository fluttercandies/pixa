import 'dart:io';

import 'pixa_profile_acceptance.dart' as acceptance;
import 'pixa_native_assets_log_check.dart' as native_assets;

Future<void> main() async {
  _expect(
    acceptance.profileRustVersionCommand().join(' ') ==
        'rustup run 1.89.0 rustc --version',
    'profile metadata must probe the pinned release toolchain',
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
