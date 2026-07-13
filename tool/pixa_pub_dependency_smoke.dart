import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

const Map<String, String> _packagePaths = <String, String>{
  'pixa': 'packages/pixa',
  'pixa_fetcher_s3': 'packages/pixa_fetcher_s3',
  'pixa_video_frame_mjpeg': 'packages/pixa_video_frame_mjpeg',
};

const Map<String, String> _publishedVersions = <String, String>{
  'pixa': '1.0.0',
  'pixa_fetcher_s3': '1.0.0',
  'pixa_video_frame_mjpeg': '1.0.0',
};

Future<void> main(List<String> args) async {
  late final PubDependencySmokeOptions options;
  try {
    options = PubDependencySmokeOptions.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  final Directory smokeRoot = await Directory.systemTemp.createTemp(
    'pixa_pub_dependency_smoke_',
  );
  final PubDependencySmoke smoke = PubDependencySmoke(
    workspaceRoot: Directory.current.absolute,
    smokeRoot: smokeRoot,
    keepWorkspace: Platform.environment['PIXA_KEEP_PUB_SMOKE'] == '1',
    runner: runPubSmokeCommand,
  );
  await smoke.run(dryRunPackage: options.dryRunPackage);
}

/// Parsed dependency-smoke command-line options.
final class PubDependencySmokeOptions {
  const PubDependencySmokeOptions({
    required this.dryRunPackage,
    required this.help,
  });

  final String? dryRunPackage;
  final bool help;

  factory PubDependencySmokeOptions.parse(List<String> args) {
    String? dryRunPackage;
    var help = false;
    for (final String arg in args) {
      if (arg.startsWith('--dry-run-package=')) {
        final String alias = arg.substring('--dry-run-package='.length).trim();
        dryRunPackage = _packageAliases[alias];
        if (dryRunPackage == null) {
          throw FormatException('Unknown publication package: $alias');
        }
      } else {
        switch (arg) {
          case '-h' || '--help':
            help = true;
          default:
            throw FormatException('Unknown dependency smoke argument: $arg');
        }
      }
    }
    return PubDependencySmokeOptions(dryRunPackage: dryRunPackage, help: help);
  }
}

/// External command used by the hosted-layout dependency smoke.
final class PubSmokeCommand {
  const PubSmokeCommand({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.environment = const <String, String>{},
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;

  String get commandLine => <String>[executable, ...arguments].join(' ');
}

/// Injectable command boundary for dependency smoke orchestration.
typedef PubSmokeRunner = Future<int> Function(PubSmokeCommand command);

/// Tracks accepted hosted-repository requests until shutdown can drain them.
final class HostedRequestTracker {
  final Set<Future<void>> _active = <Future<void>>{};

  void track(Future<void> request) {
    _active.add(request);
    unawaited(request.whenComplete(() => _active.remove(request)));
  }

  Future<void> drain() async {
    while (_active.isNotEmpty) {
      await Future.wait(_active.toList(growable: false));
    }
  }
}

/// Retries one transient TLS handshake while proxying hosted pub metadata.
Future<T> retryHostedProxyHandshake<T>(
  Future<T> Function() operation, {
  Duration retryDelay = const Duration(milliseconds: 100),
}) async {
  try {
    return await operation();
  } on HandshakeException {
    if (retryDelay > Duration.zero) {
      await Future<void>.delayed(retryDelay);
    }
    return operation();
  }
}

/// Builds versioned hosted-layout copies and verifies real consumer apps.
final class PubDependencySmoke {
  const PubDependencySmoke({
    required this.workspaceRoot,
    required this.smokeRoot,
    required this.keepWorkspace,
    required this.runner,
  });

  final Directory workspaceRoot;
  final Directory smokeRoot;
  final bool keepWorkspace;
  final PubSmokeRunner runner;

  Future<void> run({String? dryRunPackage}) async {
    var passed = false;
    _LocalHostedRepository? hostedRepository;
    try {
      final Iterable<String> packageNames = dryRunPackage == null
          ? _packagePaths.keys
          : <String>[dryRunPackage];
      final Directory archivesRoot = Directory('${smokeRoot.path}/archives')
        ..createSync(recursive: true);
      final Map<String, _PublicationArchive> archives =
          <String, _PublicationArchive>{};
      for (final String packageName in packageNames) {
        final File archive = File(
          '${archivesRoot.path}/$packageName-'
          '${_publishedVersions[packageName]}.tar.gz',
        );
        await _runChecked(
          PubSmokeCommand(
            executable: 'dart',
            arguments: <String>[
              'pub',
              'publish',
              '--to-archive=${archive.absolute.path}',
            ],
            workingDirectory:
                '${workspaceRoot.path}/${_packagePaths[packageName]}',
          ),
        );
        if (!archive.existsSync() || archive.lengthSync() == 0) {
          throw StateError(
            'Pub did not create the expected archive: ${archive.path}',
          );
        }
        archives[packageName] = _PublicationArchive.fromWorkspace(
          workspaceRoot: workspaceRoot,
          packageName: packageName,
          archive: archive,
        );
      }
      if (dryRunPackage != null) {
        passed = true;
        stdout.writeln('Pixa $dryRunPackage publication archive passed.');
        return;
      }
      hostedRepository = await _LocalHostedRepository.start(archives);
      final Map<String, String> hostedEnvironment = <String, String>{
        'PUB_HOSTED_URL': hostedRepository.url.toString(),
      };

      for (final _SmokeScenario scenario in _smokeScenarios) {
        final Directory scenarioRoot = Directory(
          '${smokeRoot.path}/apps/${scenario.id}',
        )..createSync(recursive: true);
        stdout.writeln('Pixa pub dependency smoke scenario: ${scenario.id}');
        _writeSmokePackage(scenarioRoot, scenario, hostedRepository.url);
        await _runChecked(
          PubSmokeCommand(
            executable: 'flutter',
            arguments: const <String>['pub', 'get'],
            workingDirectory: scenarioRoot.path,
            environment: hostedEnvironment,
          ),
        );
        await _runChecked(
          PubSmokeCommand(
            executable: 'dart',
            arguments: const <String>['run', 'tool/verify_hosted_lock.dart'],
            workingDirectory: scenarioRoot.path,
            environment: hostedEnvironment,
          ),
        );
        await _runChecked(
          PubSmokeCommand(
            executable: 'flutter',
            arguments: const <String>['analyze'],
            workingDirectory: scenarioRoot.path,
            environment: hostedEnvironment,
          ),
        );
        await _runChecked(
          PubSmokeCommand(
            executable: 'flutter',
            arguments: const <String>['test', '--concurrency=1'],
            workingDirectory: scenarioRoot.path,
            environment: hostedEnvironment,
          ),
        );
      }
      passed = true;
      stdout.writeln('Pixa pub dependency matrix smoke passed.');
    } finally {
      await hostedRepository?.close();
      if (keepWorkspace || !passed) {
        stderr.writeln(
          'Pixa pub dependency smoke workspace: ${smokeRoot.path}',
        );
      } else if (smokeRoot.existsSync()) {
        smokeRoot.deleteSync(recursive: true);
      }
    }
  }

  Future<void> _runChecked(PubSmokeCommand command) async {
    stdout.writeln(
      'Running: ${command.commandLine} in ${command.workingDirectory}',
    );
    final int commandExitCode = await runner(command);
    if (commandExitCode != 0) {
      throw ProcessException(
        command.executable,
        command.arguments,
        'Pixa pub dependency smoke command failed',
        commandExitCode,
      );
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
      PixaMjpegVideoFramePlugin(),
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
      PixaMjpegVideoFramePlugin(),
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

  bool get hasS3 => directPackages.contains('pixa_fetcher_s3');
  bool get hasMjpeg => directPackages.contains('pixa_video_frame_mjpeg');
}

void _requirePackage(Directory root, String relativePath) {
  final File pubspec = File('${root.path}/$relativePath/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw StateError('Missing package pubspec: ${pubspec.path}');
  }
}

final class _PublicationArchive {
  const _PublicationArchive({
    required this.packageName,
    required this.version,
    required this.file,
    required this.sha256Digest,
    required this.pubspec,
  });

  factory _PublicationArchive.fromWorkspace({
    required Directory workspaceRoot,
    required String packageName,
    required File archive,
  }) {
    final String packagePath = _packagePaths[packageName]!;
    _requirePackage(workspaceRoot, packagePath);
    final File pubspecFile = File(
      '${workspaceRoot.path}/$packagePath/pubspec.yaml',
    );
    final Object? decoded = loadYaml(
      pubspecFile.readAsStringSync(),
      sourceUrl: pubspecFile.uri,
    );
    final Object? normalized = _normalizeYaml(decoded);
    if (normalized is! Map<String, Object?>) {
      throw StateError('${pubspecFile.path} must contain a YAML map.');
    }
    final String expectedVersion = _publishedVersions[packageName]!;
    if (normalized['name'] != packageName ||
        normalized['version'] != expectedVersion) {
      throw StateError(
        '${pubspecFile.path} must declare $packageName $expectedVersion.',
      );
    }
    return _PublicationArchive(
      packageName: packageName,
      version: expectedVersion,
      file: archive,
      sha256Digest: sha256.convert(archive.readAsBytesSync()).toString(),
      pubspec: Map<String, Object?>.unmodifiable(normalized),
    );
  }

  final String packageName;
  final String version;
  final File file;
  final String sha256Digest;
  final Map<String, Object?> pubspec;

  String get fileName => '$packageName-$version.tar.gz';
}

Object? _normalizeYaml(Object? value) {
  if (value is Map) {
    final Map<String, Object?> normalized = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw StateError('Pubspec map keys must be strings.');
      }
      normalized[key] = _normalizeYaml(entry.value);
    }
    return normalized;
  }
  if (value is Iterable) {
    return value.map<Object?>(_normalizeYaml).toList(growable: false);
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw StateError('Unsupported pubspec value: ${value.runtimeType}.');
}

final class _LocalHostedRepository {
  _LocalHostedRepository._({
    required HttpServer server,
    required HttpClient proxyClient,
    required HostedRequestTracker requests,
    required Map<String, _PublicationArchive> archives,
  }) : _server = server,
       _proxyClient = proxyClient,
       _requests = requests,
       _archives = Map<String, _PublicationArchive>.unmodifiable(archives);

  static Future<_LocalHostedRepository> start(
    Map<String, _PublicationArchive> archives,
  ) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final HttpClient proxyClient = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30);
    final HostedRequestTracker requests = HostedRequestTracker();
    final _LocalHostedRepository repository = _LocalHostedRepository._(
      server: server,
      proxyClient: proxyClient,
      requests: requests,
      archives: archives,
    );
    server.listen((HttpRequest request) {
      requests.track(repository._handle(request));
    });
    return repository;
  }

  final HttpServer _server;
  final HttpClient _proxyClient;
  final HostedRequestTracker _requests;
  final Map<String, _PublicationArchive> _archives;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> close() async {
    await _server.close(force: false);
    await _requests.drain();
    _proxyClient.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final List<String> segments = request.uri.pathSegments;
      if (segments.length == 3 &&
          segments[0] == 'api' &&
          segments[1] == 'packages' &&
          _archives.containsKey(segments[2])) {
        await _servePackageMetadata(request, _archives[segments[2]]!);
        return;
      }
      if (segments.length == 2 && segments[0] == 'archives') {
        _PublicationArchive? archive;
        for (final _PublicationArchive candidate in _archives.values) {
          if (candidate.fileName == segments[1]) {
            archive = candidate;
            break;
          }
        }
        if (archive != null) {
          await _serveArchive(request, archive);
          return;
        }
      }
      await _proxyToPubDev(request);
    } on Object catch (error, stackTrace) {
      stderr.writeln('Hosted smoke server failed: $error\n$stackTrace');
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.text
          ..write('Hosted smoke server failed.');
        await request.response.close();
      } on Object {
        // The downstream connection may already have closed.
      }
    }
  }

  Future<void> _servePackageMetadata(
    HttpRequest request,
    _PublicationArchive archive,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final Map<String, Object?> version = <String, Object?>{
      'version': archive.version,
      'pubspec': archive.pubspec,
      'archive_url': url.resolve('archives/${archive.fileName}').toString(),
      'archive_sha256': archive.sha256Digest,
      'published': '2026-07-10T00:00:00.000Z',
    };
    final List<int> body = utf8.encode(
      jsonEncode(<String, Object?>{
        'name': archive.packageName,
        'latest': version,
        'versions': <Map<String, Object?>>[version],
      }),
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..contentLength = body.length;
    if (request.method == 'GET') {
      request.response.add(body);
    }
    await request.response.close();
  }

  Future<void> _serveArchive(
    HttpRequest request,
    _PublicationArchive archive,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'application',
        'gzip',
        parameters: const <String, String>{'charset': 'binary'},
      )
      ..contentLength = archive.file.lengthSync();
    if (request.method == 'GET') {
      await request.response.addStream(archive.file.openRead());
    }
    await request.response.close();
  }

  Future<void> _proxyToPubDev(HttpRequest request) async {
    final Uri target = Uri(
      scheme: 'https',
      host: 'pub.dev',
      path: request.uri.path,
      query: request.uri.hasQuery ? request.uri.query : null,
    );
    final bool isIdempotent =
        request.method == 'GET' || request.method == 'HEAD';
    final HttpClientResponse response = isIdempotent
        ? await retryHostedProxyHandshake<HttpClientResponse>(
            () => _openPubDevResponse(request, target, forwardBody: false),
          )
        : await _openPubDevResponse(request, target, forwardBody: true);
    request.response.statusCode = response.statusCode;
    response.headers.forEach((String name, List<String> values) {
      if (name != HttpHeaders.connectionHeader &&
          name != HttpHeaders.contentLengthHeader &&
          name != HttpHeaders.transferEncodingHeader) {
        request.response.headers.set(name, values);
      }
    });
    if (response.contentLength >= 0) {
      request.response.contentLength = response.contentLength;
    }
    await request.response.addStream(response);
    await request.response.close();
  }

  Future<HttpClientResponse> _openPubDevResponse(
    HttpRequest request,
    Uri target, {
    required bool forwardBody,
  }) async {
    final HttpClientRequest upstream = await _proxyClient.openUrl(
      request.method,
      target,
    );
    for (final String header in <String>[
      HttpHeaders.acceptHeader,
      HttpHeaders.acceptEncodingHeader,
      HttpHeaders.ifModifiedSinceHeader,
      HttpHeaders.ifNoneMatchHeader,
      HttpHeaders.userAgentHeader,
    ]) {
      final List<String>? values = request.headers[header];
      if (values != null) {
        upstream.headers.set(header, values);
      }
    }
    if (forwardBody) {
      await upstream.addStream(request);
    }
    return upstream.close();
  }
}

void _writeSmokePackage(
  Directory smokeRoot,
  _SmokeScenario scenario,
  Uri hostedUrl,
) {
  Directory('${smokeRoot.path}/lib').createSync(recursive: true);
  Directory('${smokeRoot.path}/test').createSync(recursive: true);
  Directory('${smokeRoot.path}/tool').createSync(recursive: true);
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
  flutter_test:
    sdk: flutter
  flutter_lints: ">=5.0.0 <7.0.0"
''');
  File('${smokeRoot.path}/lib/main.dart').writeAsStringSync(scenario.mainDart);
  File(
    '${smokeRoot.path}/test/hosted_runtime_smoke_test.dart',
  ).writeAsStringSync(_runtimeSmokeTest(scenario));
  File(
    '${smokeRoot.path}/tool/verify_hosted_lock.dart',
  ).writeAsStringSync(_hostedLockVerifier(scenario, hostedUrl));
}

String _dependencyYaml(_SmokeScenario scenario) {
  final StringBuffer buffer = StringBuffer();
  for (final String packageName in scenario.directPackages) {
    buffer.writeln('  $packageName: ^${_publishedVersions[packageName]}');
  }
  return buffer.toString().trimRight();
}

String _hostedLockVerifier(_SmokeScenario scenario, Uri hostedUrl) {
  final Set<String> packageNames = <String>{...scenario.directPackages};
  if (packageNames.any((String name) => name != 'pixa')) {
    packageNames.add('pixa');
  }
  final String expectedPackages = packageNames
      .map((String name) => "  '$name': '${_publishedVersions[name]}',")
      .join('\n');
  return '''
import 'dart:io';

const Map<String, String> _expectedPackages = <String, String>{
$expectedPackages
};
const String _expectedHostedUrl = '${hostedUrl.origin}';

void main() {
  final File lockfile = File('pubspec.lock');
  if (!lockfile.existsSync()) {
    throw StateError('flutter pub get did not create pubspec.lock');
  }
  final List<String> lines = lockfile.readAsLinesSync();
  for (final MapEntry<String, String> package in _expectedPackages.entries) {
    final int start = lines.indexOf('  \${package.key}:');
    if (start < 0) {
      throw StateError('Missing hosted package \${package.key} in lockfile');
    }
    var end = lines.length;
    for (var index = start + 1; index < lines.length; index += 1) {
      final String line = lines[index];
      if (line.startsWith('  ') && !line.startsWith('    ')) {
        end = index;
        break;
      }
    }
    final String block = lines.sublist(start, end).join(String.fromCharCode(10));
    if (!block.contains('    source: hosted')) {
      throw StateError('\${package.key} did not resolve from hosted source');
    }
    if (!block.contains('    version: "\${package.value}"')) {
      throw StateError('\${package.key} resolved an unexpected version');
    }
    if (!block.contains('      url: "\$_expectedHostedUrl"') &&
        !block.contains('      url: \$_expectedHostedUrl')) {
      throw StateError('\${package.key} bypassed the local hosted archive');
    }
    if (!block.contains('      sha256:')) {
      throw StateError('\${package.key} lock entry is missing archive SHA-256');
    }
  }
  stdout.writeln('Hosted lockfile resolution verified.');
}
''';
}

String _runtimeSmokeTest(_SmokeScenario scenario) {
  final String imports = switch ((scenario.hasS3, scenario.hasMjpeg)) {
    (false, false) => "import 'package:pixa/pixa.dart';",
    (true, false) => "import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';",
    (false, true) =>
      "import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';",
    (true, true) =>
      '''
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';
''',
  };
  final List<String> plugins = <String>[
    if (scenario.hasS3) 'PixaS3FetcherPlugin()',
    if (scenario.hasMjpeg) 'PixaMjpegVideoFramePlugin()',
  ];
  final String pluginList = plugins.isEmpty
      ? 'const <PixaPlugin>[]'
      : 'const <PixaPlugin>[${plugins.join(', ')}]';
  final String routeAssertions =
      '''
${scenario.hasS3 ? '''
      expect(
        Pixa.pipeline.registry
            .compileRoutePlan()
            .fetcherForSourceKind('s3')
            ?.id,
        pixaS3FetcherDescriptorId,
      );
''' : ''}${scenario.hasMjpeg ? '''
      expect(
        Pixa.pipeline.registry
            .compileRoutePlan()
            .fetcherForSourceKind('video-frame:mjpeg')
            ?.id,
        pixaMjpegVideoFrameDescriptorId,
      );
''' : ''}''';
  final String runtimeActions = <String>[
    if (scenario.hasS3) '      await _loadS3ThroughRuntime();',
    if (scenario.hasMjpeg) '      await _loadMjpegThroughRuntime();',
  ].join('\n');
  final String asyncImport = scenario.hasS3 ? "import 'dart:async';\n" : '';
  return '''
$asyncImport
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
$imports

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hosted ${scenario.id} configures and loads the runtime', () async {
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-hosted-${scenario.id}-',
    );
    try {
      await Pixa.configure(
        PixaConfig(cacheRootPath: cacheRoot.path, plugins: $pluginList),
      );
      expect(Pixa.isConfigured, isTrue);
      final PixaCacheStats stats = Pixa.pipeline.cacheStats();
      expect(stats.memoryEntries, greaterThanOrEqualTo(0));
$routeAssertions
      final PixaPipelineLoad coreLoad = await Pixa.pipeline.load(
        PixaRequest.bytes(
          _gifBytes,
          id: 'hosted-${scenario.id}',
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
      );
      try {
        expect(coreLoad.mimeType, 'image/gif');
        expect(coreLoad.bytes, _gifBytes);
      } finally {
        coreLoad.dispose();
      }
$runtimeActions
    } finally {
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    }
  });
}
${scenario.hasS3 ? _s3RuntimeSmokeSource : ''}
${scenario.hasMjpeg ? _mjpegRuntimeSmokeSource : ''}

final Uint8List _gifBytes = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
);
''';
}

const String _s3RuntimeSmokeSource = r'''
Future<void> _loadS3ThroughRuntime() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final Completer<HttpRequest> received = Completer<HttpRequest>();
  server.listen((HttpRequest request) async {
    if (!received.isCompleted) {
      received.complete(request);
    }
    request.response
      ..headers.contentType = ContentType('image', 'gif')
      ..headers.contentLength = _gifBytes.length
      ..add(_gifBytes);
    await request.response.close();
  });
  PixaPipelineLoad? load;
  try {
    load = await Pixa.pipeline.load(
      PixaS3.request(
        bucket: 'gallery-assets',
        key: 'users/42/avatar.gif',
        region: 'us-east-1',
        credentials: const PixaS3Credentials(
          accessKeyId: 'AKIAHOSTED',
          secretAccessKey: 'hosted-secret',
        ),
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        forcePathStyle: true,
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    expect(load.mimeType, 'image/gif');
    expect(load.bytes, _gifBytes);
    final HttpRequest request = await received.future.timeout(
      const Duration(seconds: 10),
    );
    expect(request.uri.path, '/gallery-assets/users/42/avatar.gif');
    expect(
      request.headers.value(HttpHeaders.authorizationHeader),
      startsWith('AWS4-HMAC-SHA256 '),
    );
  } finally {
    load?.dispose();
    await server.close(force: true);
  }
}
''';

const String _mjpegRuntimeSmokeSource = r'''
Future<void> _loadMjpegThroughRuntime() async {
  final File video = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'pixa-hosted-mjpeg-${DateTime.now().microsecondsSinceEpoch}.avi',
  );
  video.writeAsBytesSync(_mjpegAvi(_jpegBytes), flush: true);
  PixaPipelineLoad? load;
  try {
    load = await Pixa.pipeline.load(
      PixaMjpegVideoFrame.request(
        video.path,
        timestamp: Duration.zero,
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    expect(load.mimeType, 'image/jpeg');
    expect(
      PixaImageMetadata.parseEncoded(load.bytes).format,
      PixaImageMetadataFormat.jpeg,
    );
  } finally {
    load?.dispose();
    if (video.existsSync()) {
      video.deleteSync();
    }
  }
}

Uint8List _mjpegAvi(Uint8List jpeg) {
  final Uint8List avih = Uint8List(56);
  final ByteData avihData = ByteData.sublistView(avih);
  avihData
    ..setUint32(0, 1000000, Endian.little)
    ..setUint32(16, 1, Endian.little)
    ..setUint32(32, 2, Endian.little)
    ..setUint32(36, 2, Endian.little);
  final Uint8List hdrl = _listChunk('hdrl', _chunk('avih', avih));
  final Uint8List movi = _listChunk('movi', _chunk('00dc', jpeg));
  final BytesBuilder payload = BytesBuilder(copy: false)
    ..add(ascii.encode('AVI '))
    ..add(hdrl)
    ..add(movi);
  return _chunk('RIFF', payload.takeBytes());
}

Uint8List _listChunk(String type, Uint8List payload) {
  final BytesBuilder data = BytesBuilder(copy: false)
    ..add(ascii.encode(type))
    ..add(payload);
  return _chunk('LIST', data.takeBytes());
}

Uint8List _chunk(String id, List<int> payload) {
  final ByteData size = ByteData(4)
    ..setUint32(0, payload.length, Endian.little);
  final BytesBuilder data = BytesBuilder(copy: false)
    ..add(ascii.encode(id))
    ..add(size.buffer.asUint8List())
    ..add(payload);
  if (payload.length.isOdd) {
    data.addByte(0);
  }
  return data.takeBytes();
}

final Uint8List _jpegBytes = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQO'
  'DwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcH'
  'BwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo'
  'KCgoKCgoKCgoKCgoKCj/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAA'
  'AAAAAAAAAAb/xAAVAQEBAAAAAAAAAAAAAAAAAAAFBv/aAAwDAQACEAMQAAABrBDl'
  'f//EABcQAAMBAAAAAAAAAAAAAAAAAAECBAP/2gAIAQEAAQUCgzQw/wD/xAAXEQAD'
  'AQAAAAAAAAAAAAAAAAAAAQMy/9oACAEDAQE/Aa7Z/8QAGBEAAgMAAAAAAAAAAAAA'
  'AAAAAAIDM3H/2gAIAQIBAT8BntbT/8QAGhAAAgIDAAAAAAAAAAAAAAAAAQIABBNB'
  'Yf/aAAgBAQAGPwKsSik411yf/8QAFhABAQEAAAAAAAAAAAAAAAAAASEA/9oACAE'
  'BAAE/IWZBlRY3/9oADAMBAAIAAwAAABAL/8QAFxEAAwEAAAAAAAAAAAAAAAAAAA'
  'Ghsf/aAAgBAwEBPxCl6f/EABcRAAMBAAAAAAAAAAAAAAAAAAABobH/2gAIAQIBA'
  'T8Qtaz/xAAXEAEBAQEAAAAAAAAAAAAAAAABEQAh/9oACAEBAAE/EHqSlKbKzrv'
  '/2Q==',
);
''';

/// Runs one hosted dependency smoke command with inherited terminal output.
Future<int> runPubSmokeCommand(PubSmokeCommand command) async {
  final Process process = await Process.start(
    command.executable,
    command.arguments,
    workingDirectory: command.workingDirectory,
    environment: command.environment,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

const Map<String, String> _packageAliases = <String, String>{
  'pixa': 'pixa',
  's3': 'pixa_fetcher_s3',
  'mjpeg': 'pixa_video_frame_mjpeg',
};

const String _usage = '''
Usage: dart run tool/pixa_pub_dependency_smoke.dart [options]

Options:
  --dry-run-package=<pixa|s3|mjpeg>  Only stage and dry-run one package.
  --help                             Show this help text.
''';
