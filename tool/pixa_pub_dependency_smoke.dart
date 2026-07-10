import 'dart:io';

const Map<String, String> _packagePaths = <String, String>{
  'pixa': 'packages/pixa',
  'pixa_fetcher_s3': 'packages/pixa_fetcher_s3',
  'pixa_video_frame_mjpeg': 'packages/pixa_video_frame_mjpeg',
};

const Map<String, String> _publishedConstraints = <String, String>{
  'pixa': '^1.0.0',
  'pixa_fetcher_s3': '^1.0.0',
  'pixa_video_frame_mjpeg': '^1.0.0',
};

Future<void> main() async {
  final Directory root = Directory.current;
  for (final String packagePath in _packagePaths.values) {
    _requirePackage(root, packagePath);
  }

  final Directory smokeRoot = await Directory.systemTemp.createTemp(
    'pixa_pub_dependency_smoke_',
  );
  var keepSmokeRoot = true;
  try {
    for (final _SmokeScenario scenario in _smokeScenarios) {
      final Directory scenarioRoot = Directory(
        '${smokeRoot.path}/${scenario.id}',
      )..createSync(recursive: true);
      stdout.writeln('Pixa pub dependency smoke scenario: ${scenario.id}');
      _writeSmokePackage(root, scenarioRoot, scenario);
      await _run('flutter', <String>[
        'pub',
        'get',
      ], workingDirectory: scenarioRoot.path);
      await _run('flutter', <String>[
        'analyze',
      ], workingDirectory: scenarioRoot.path);
    }
    keepSmokeRoot = false;
    stdout.writeln('Pixa pub dependency matrix smoke passed.');
  } finally {
    if (keepSmokeRoot || Platform.environment['PIXA_KEEP_PUB_SMOKE'] == '1') {
      stderr.writeln('Pixa pub dependency smoke workspace: ${smokeRoot.path}');
    } else {
      smokeRoot.deleteSync(recursive: true);
    }
  }
}

final List<_SmokeScenario> _smokeScenarios = <_SmokeScenario>[
  _SmokeScenario(
    id: 'core_only',
    directPackages: <String>['pixa'],
    mainDart: r'''
import 'package:flutter/widgets.dart';
import 'package:pixa/pixa.dart';

void main() {
  const PixaConfig config = PixaConfig();
  final PixaRequest request = PixaRequest.network(
    'https://example.com/image.png',
  );
  final PixaImage image = PixaImage.network(
    'https://example.com/image.png',
    width: 96,
    height: 96,
    fit: BoxFit.cover,
  );

  assert(config.plugins.isEmpty);
  assert(request.source.safeLabel.contains('example.com'));
  assert(image.request.source.safeLabel.contains('example.com'));
}
''',
  ),
  _SmokeScenario(
    id: 's3_only',
    directPackages: <String>['pixa_fetcher_s3'],
    mainDart: r'''
import 'package:flutter/widgets.dart';
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';

void main() {
  const PixaConfig config = PixaConfig(
    plugins: <PixaPlugin>[PixaS3FetcherPlugin()],
  );
  final PixaRequest request = PixaS3.request(
    bucket: 'gallery-assets',
    key: 'users/42/avatar.jpg',
    region: 'us-east-1',
    credentials: const PixaS3Credentials(
      accessKeyId: 'AKIAEXAMPLE',
      secretAccessKey: 'secret',
    ),
  );
  final PixaProvider provider = PixaS3.provider(
    bucket: 'gallery-assets',
    key: 'users/42/avatar.jpg',
    region: 'us-east-1',
    credentials: const PixaS3Credentials(
      accessKeyId: 'AKIAEXAMPLE',
      secretAccessKey: 'secret',
    ),
    targetWidth: 96,
    fit: BoxFit.cover,
  );
  final PixaImage image = PixaS3.image(
    bucket: 'gallery-assets',
    key: 'users/42/avatar.jpg',
    region: 'us-east-1',
    credentials: const PixaS3Credentials(
      accessKeyId: 'AKIAEXAMPLE',
      secretAccessKey: 'secret',
    ),
    width: 96,
    height: 96,
    fit: BoxFit.cover,
  );

  assert(config.plugins.length == 1);
  assert(request.source.safeLabel == 'runtime-plugin:s3');
  assert(provider.request.source.safeLabel == 'runtime-plugin:s3');
  assert(image.request.source.safeLabel == 'runtime-plugin:s3');
}
''',
  ),
  _SmokeScenario(
    id: 'mjpeg_only',
    directPackages: <String>['pixa_video_frame_mjpeg'],
    mainDart: r'''
import 'package:flutter/widgets.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';

void main() {
  const PixaConfig config = PixaConfig(
    plugins: <PixaPlugin>[
      PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true),
    ],
  );
  final PixaRequest request = PixaMjpegVideoFrame.request(
    '/videos/camera-roll.avi',
    timestamp: const Duration(seconds: 2),
  );
  final PixaImage image = PixaMjpegVideoFrame.image(
    '/videos/camera-roll.avi',
    timestamp: const Duration(seconds: 2),
    width: 320,
    height: 180,
    fit: BoxFit.cover,
  );

  assert(config.plugins.length == 1);
  assert(request.source.safeLabel.startsWith('video-frame:'));
  assert(image.request.source.safeLabel.startsWith('video-frame:'));
}
''',
  ),
  _SmokeScenario(
    id: 's3_and_mjpeg',
    directPackages: <String>['pixa_fetcher_s3', 'pixa_video_frame_mjpeg'],
    mainDart: r'''
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';

void main() {
  const PixaConfig config = PixaConfig(
    plugins: <PixaPlugin>[
      PixaS3FetcherPlugin(),
      PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true),
    ],
  );
  final List<PixaRequest> requests = <PixaRequest>[
    PixaS3.request(
      bucket: 'gallery-assets',
      key: 'users/42/avatar.jpg',
      region: 'us-east-1',
      credentials: const PixaS3Credentials(
        accessKeyId: 'AKIAEXAMPLE',
        secretAccessKey: 'secret',
      ),
    ),
    PixaMjpegVideoFrame.request(
      '/videos/camera-roll.avi',
      timestamp: const Duration(seconds: 2),
    ),
  ];

  assert(config.plugins.length == 2);
  assert(requests.length == 2);
}
''',
  ),
  _SmokeScenario(
    id: 'all_explicit',
    directPackages: <String>[
      'pixa',
      'pixa_fetcher_s3',
      'pixa_video_frame_mjpeg',
    ],
    mainDart: r'''
import 'package:flutter/widgets.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart'
    hide PixaConfig, PixaImage, PixaPlugin, PixaRequest;
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart'
    hide PixaConfig, PixaImage, PixaPlugin, PixaRequest;

void main() {
  const PixaConfig config = PixaConfig(
    plugins: <PixaPlugin>[
      PixaS3FetcherPlugin(),
      PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true),
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
''',
  ),
];

final class _SmokeScenario {
  const _SmokeScenario({
    required this.id,
    required this.directPackages,
    required this.mainDart,
  });

  final String id;
  final List<String> directPackages;
  final String mainDart;
}

void _requirePackage(Directory root, String relativePath) {
  final File pubspec = File('${root.path}/$relativePath/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw StateError('Missing package pubspec: ${pubspec.path}');
  }
}

void _writeSmokePackage(
  Directory root,
  Directory smokeRoot,
  _SmokeScenario scenario,
) {
  Directory('${smokeRoot.path}/lib').createSync(recursive: true);
  File('${smokeRoot.path}/pubspec.yaml').writeAsStringSync('''
name: pixa_pub_dependency_smoke_${scenario.id}
publish_to: none

environment:
  sdk: ">=3.11.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
${_dependencyYaml(scenario)}

dev_dependencies:
  flutter_lints: ">=5.0.0 <7.0.0"
''');
  File('${smokeRoot.path}/pubspec_overrides.yaml').writeAsStringSync('''
dependency_overrides:
${_dependencyOverrideYaml(root, scenario)}
''');
  File('${smokeRoot.path}/lib/main.dart').writeAsStringSync(scenario.mainDart);
}

String _dependencyYaml(_SmokeScenario scenario) {
  final StringBuffer buffer = StringBuffer();
  for (final String packageName in scenario.directPackages) {
    buffer.writeln('  $packageName: ${_publishedConstraints[packageName]}');
  }
  return buffer.toString().trimRight();
}

String _dependencyOverrideYaml(Directory root, _SmokeScenario scenario) {
  final Set<String> packageNames = <String>{...scenario.directPackages};
  if (packageNames.any((String name) => name != 'pixa')) {
    packageNames.add('pixa');
  }

  final StringBuffer buffer = StringBuffer();
  for (final String packageName in _packagePaths.keys) {
    if (!packageNames.contains(packageName)) {
      continue;
    }
    buffer
      ..writeln('  $packageName:')
      ..writeln(
        '    path: ${_yamlString('${root.path}/${_packagePaths[packageName]}')}',
      );
  }
  return buffer.toString().trimRight();
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
