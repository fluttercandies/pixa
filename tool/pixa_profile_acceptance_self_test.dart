import 'dart:io';

import 'pixa_profile_acceptance.dart' as acceptance;

Future<void> main() async {
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
