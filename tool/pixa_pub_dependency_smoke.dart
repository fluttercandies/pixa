import 'dart:io';

Future<void> main() async {
  final Directory root = Directory.current;
  _requirePackage(root, 'packages/pixa');
  _requirePackage(root, 'packages/pixa_fetcher_s3');
  _requirePackage(root, 'packages/pixa_video_frame_mjpeg');

  final Directory smokeRoot = await Directory.systemTemp.createTemp(
    'pixa_pub_dependency_smoke_',
  );
  var keepSmokeRoot = true;
  try {
    _writeSmokePackage(root, smokeRoot);
    await _run('flutter', <String>[
      'pub',
      'get',
    ], workingDirectory: smokeRoot.path);
    await _run('flutter', <String>[
      'analyze',
    ], workingDirectory: smokeRoot.path);
    keepSmokeRoot = false;
    stdout.writeln('Pixa pub dependency smoke passed.');
  } finally {
    if (keepSmokeRoot || Platform.environment['PIXA_KEEP_PUB_SMOKE'] == '1') {
      stderr.writeln('Pixa pub dependency smoke workspace: ${smokeRoot.path}');
    } else {
      smokeRoot.deleteSync(recursive: true);
    }
  }
}

void _requirePackage(Directory root, String relativePath) {
  final File pubspec = File('${root.path}/$relativePath/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw StateError('Missing package pubspec: ${pubspec.path}');
  }
}

void _writeSmokePackage(Directory root, Directory smokeRoot) {
  Directory('${smokeRoot.path}/lib').createSync(recursive: true);
  File('${smokeRoot.path}/pubspec.yaml').writeAsStringSync('''
name: pixa_pub_dependency_smoke
publish_to: none

environment:
  sdk: ">=3.11.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  pixa: ^1.0.0
  pixa_fetcher_s3: ^1.0.0
  pixa_video_frame_mjpeg: ^1.0.0

dev_dependencies:
  flutter_lints: ">=5.0.0 <7.0.0"
''');
  File('${smokeRoot.path}/pubspec_overrides.yaml').writeAsStringSync('''
dependency_overrides:
  pixa:
    path: ${_yamlString('${root.path}/packages/pixa')}
  pixa_fetcher_s3:
    path: ${_yamlString('${root.path}/packages/pixa_fetcher_s3')}
  pixa_video_frame_mjpeg:
    path: ${_yamlString('${root.path}/packages/pixa_video_frame_mjpeg')}
''');
  File('${smokeRoot.path}/lib/main.dart').writeAsStringSync(r'''
import 'package:flutter/widgets.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';

void main() {
  const PixaConfig config = PixaConfig(
    plugins: <PixaPlugin>[
      PixaS3FetcherPlugin(),
      PixaMjpegVideoFramePlugin(),
    ],
  );
  final PixaRequest network = PixaRequest.network(
    'https://example.com/image.png',
  );
  final PixaImage widget = PixaImage.network(
    'https://example.com/image.png',
    width: 96,
    height: 96,
    fit: BoxFit.cover,
  );
  final PixaRequest s3 = PixaS3.request(
    bucket: 'gallery-assets',
    key: 'users/42/avatar.jpg',
    region: 'us-east-1',
    credentials: const PixaS3Credentials(
      accessKeyId: 'AKIAEXAMPLE',
      secretAccessKey: 'secret',
    ),
  );
  final PixaRequest videoFrame = PixaMjpegVideoFrame.request(
    '/videos/camera-roll.avi',
    timestamp: const Duration(seconds: 2),
  );

  assert(config.plugins.length == 2);
  assert(network.source.safeLabel.contains('example.com'));
  assert(widget.request.source.safeLabel.contains('example.com'));
  assert(s3.source.safeLabel == 'runtime-plugin:s3');
  assert(videoFrame.source.safeLabel.startsWith('video-frame:'));
}
''');
}

String _yamlString(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  stdout.writeln(
    'Running: $executable ${arguments.join(' ')} '
    'in $workingDirectory',
  );
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: true,
  );
  if (result.stdout.toString().trim().isNotEmpty) {
    stdout.writeln(result.stdout);
  }
  if (result.stderr.toString().trim().isNotEmpty) {
    stderr.writeln(result.stderr);
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      'Pixa pub dependency smoke command failed',
      result.exitCode,
    );
  }
}
