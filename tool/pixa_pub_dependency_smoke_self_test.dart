import 'dart:io';

import 'pixa_pub_dependency_smoke.dart';

Future<void> main() async {
  final Directory root = Directory.current.absolute;
  final Directory temp = await Directory.systemTemp.createTemp(
    'pixa-pub-smoke-self-test-',
  );
  final List<PubSmokeCommand> commands = <PubSmokeCommand>[];
  try {
    final PubDependencySmoke smoke = PubDependencySmoke(
      workspaceRoot: root,
      smokeRoot: temp,
      keepWorkspace: true,
      runner: (PubSmokeCommand command) async {
        commands.add(command);
        for (final String argument in command.arguments) {
          if (argument.startsWith('--to-archive=')) {
            final File archive = File(
              argument.substring('--to-archive='.length),
            );
            archive.parent.createSync(recursive: true);
            archive.writeAsBytesSync(<int>[0x1f, 0x8b]);
          }
        }
        return 0;
      },
    );
    await smoke.run();

    _expectHostedPackageLayout(root, temp);
    _expectRuntimeScenario(temp, 'core_only', hasS3: false, hasMjpeg: false);
    _expectRuntimeScenario(temp, 's3_only', hasS3: true, hasMjpeg: false);
    _expectRuntimeScenario(temp, 'mjpeg_only', hasS3: false, hasMjpeg: true);
    _expectRuntimeScenario(temp, 's3_and_mjpeg', hasS3: true, hasMjpeg: true);
    _expectRuntimeScenario(temp, 'all_explicit', hasS3: true, hasMjpeg: true);
    _expectCommands(commands);
    stdout.writeln('Pixa pub dependency smoke self-test passed.');
  } finally {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}

void _expectHostedPackageLayout(Directory root, Directory temp) {
  final File coreArchive = File('${temp.path}/archives/pixa-1.0.0.tar.gz');
  _expect(
    coreArchive.existsSync(),
    'Pub should create the exact core publication archive',
  );
  _expect(
    !Directory('${temp.path}/publish').existsSync(),
    'publication smoke must not substitute a manually copied source tree',
  );
  _expect(
    !Directory('${temp.path}/hosted').existsSync(),
    'hosted resolution should serve Pub archives instead of path copies',
  );
  for (final String packageName in <String>[
    'pixa',
    'pixa_fetcher_s3',
    'pixa_video_frame_mjpeg',
  ]) {
    final File pubignore = File(
      '${root.path}/packages/$packageName/.pubignore',
    );
    _expect(pubignore.existsSync(), '$packageName should define .pubignore');
    _expect(
      pubignore.readAsStringSync().contains('*.iml'),
      '$packageName should exclude IntelliJ module files from publication',
    );
  }
}

void _expectRuntimeScenario(
  Directory temp,
  String id, {
  required bool hasS3,
  required bool hasMjpeg,
}) {
  final Directory app = Directory('${temp.path}/apps/$id');
  final File overrides = File('${app.path}/pubspec_overrides.yaml');
  final String pubspec = File('${app.path}/pubspec.yaml').readAsStringSync();
  final String runtimeTest = File(
    '${app.path}/test/hosted_runtime_smoke_test.dart',
  ).readAsStringSync();
  final String lockVerifier = File(
    '${app.path}/tool/verify_hosted_lock.dart',
  ).readAsStringSync();

  _expect(
    !overrides.existsSync(),
    '$id must not bypass hosted resolution with dependency overrides',
  );
  _expect(
    pubspec.contains('^1.0.0'),
    '$id should resolve version constraints through the hosted server',
  );
  _expect(
    runtimeTest.contains('await Pixa.configure('),
    '$id should configure the real runtime',
  );
  _expect(
    runtimeTest.contains('await Pixa.pipeline.load('),
    '$id should execute a real runtime pipeline load',
  );
  _expect(
    lockVerifier.contains('source: hosted') &&
        lockVerifier.contains('_expectedHostedUrl'),
    '$id should verify hosted lockfile provenance',
  );
  _expect(
    runtimeTest.contains("import 'dart:async';") == hasS3,
    '$id should import dart:async exactly when S3 runtime code needs it',
  );
  if (hasS3) {
    _expect(
      runtimeTest.contains('HttpServer.bind(') &&
          runtimeTest.contains('InternetAddress.loopbackIPv4'),
      '$id should execute the real S3 SigV4 runtime fetcher',
    );
  }
  if (hasMjpeg) {
    _expect(
      !pubspec.contains('plugin_manifest_directory'),
      '$id should not require app-owned Native Assets configuration',
    );
    _expect(
      runtimeTest.contains("fetcherForSourceKind('video-frame:mjpeg')"),
      '$id should verify the MJPEG capability route',
    );
    _expect(
      runtimeTest.contains('_mjpegAvi('),
      '$id should execute the host-linked MJPEG runtime module',
    );
    _expect(
      runtimeTest.contains('PixaMjpegVideoFramePlugin()') &&
          !runtimeTest.contains('hostRuntimeAvailable: true'),
      '$id should use the zero-configuration MJPEG plugin API',
    );
  }
}

void _expectCommands(List<PubSmokeCommand> commands) {
  final Iterable<PubSmokeCommand> tests = commands.where(
    (PubSmokeCommand command) =>
        command.commandLine.contains('flutter test --concurrency=1'),
  );
  final Iterable<PubSmokeCommand> vendors = commands.where(
    (PubSmokeCommand command) => command.commandLine.contains(
      'pixa_video_frame_mjpeg:pixa_mjpeg_vendor',
    ),
  );
  final Iterable<PubSmokeCommand> dryRuns = commands.where(
    (PubSmokeCommand command) =>
        command.commandLine.contains('dart pub publish --to-archive='),
  );
  final Iterable<PubSmokeCommand> lockChecks = commands.where(
    (PubSmokeCommand command) =>
        command.commandLine.contains('dart run tool/verify_hosted_lock.dart'),
  );
  _expect(
    tests.length == 5,
    'every dependency scenario should load the runtime',
  );
  _expect(
    vendors.isEmpty,
    'hosted MJPEG dependencies must not require manifest vendoring',
  );
  _expect(
    dryRuns.length == 3,
    'every package should run a publication dry-run',
  );
  _expect(
    dryRuns.every(
      (PubSmokeCommand command) => command.workingDirectory.startsWith(
        '${Directory.current.path}'
        '${Platform.pathSeparator}packages${Platform.pathSeparator}',
      ),
    ),
    'Pub must archive the real source package with its own file selector',
  );
  _expect(
    lockChecks.length == 5,
    'every scenario should verify hosted lockfile resolution',
  );
  for (final String scenario in <String>[
    'mjpeg_only',
    's3_and_mjpeg',
    'all_explicit',
  ]) {
    final List<String> sequence = commands
        .where(
          (PubSmokeCommand command) => command.workingDirectory.endsWith(
            '${Platform.pathSeparator}apps${Platform.pathSeparator}$scenario',
          ),
        )
        .map((PubSmokeCommand command) => command.commandLine)
        .toList(growable: false);
    _expect(
      sequence.length == 4 &&
          sequence[0] == 'flutter pub get' &&
          sequence[1] == 'dart run tool/verify_hosted_lock.dart' &&
          sequence[2] == 'flutter analyze' &&
          sequence[3] == 'flutter test --concurrency=1',
      '$scenario should resolve and run without app-owned hook setup',
    );
  }
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
