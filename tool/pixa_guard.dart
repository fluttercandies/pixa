import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const String _rustWorkspacePath = 'packages/pixa/native_src/rust';
const String _rustManifestPath = '$_rustWorkspacePath/Cargo.toml';
const String _rustLockPath = '$_rustWorkspacePath/Cargo.lock';

void main(List<String> args) {
  const String skipDartDependencyCurrency = '--skip-dart-dependency-currency';
  final List<String> unknownArguments = args
      .where((String argument) => argument != skipDartDependencyCurrency)
      .toList(growable: false);
  if (unknownArguments.isNotEmpty) {
    stderr.writeln(
      'Unknown pixa_guard argument(s): ${unknownArguments.join(', ')}',
    );
    exitCode = 64;
    return;
  }
  final Directory root = Directory.current;
  final List<String> failures = <String>[];

  _checkNoMatches(
    root,
    failures,
    label: 'banned runtime dependencies',
    files: _dependencyFiles(root),
    patterns: <RegExp>[
      RegExp(r'\bflutter_rust_bridge\b'),
      RegExp(r'\breqwest\b'),
      RegExp(r'\bhive(?:_ce)?\b'),
      RegExp(r'\bserde_json\b'),
    ],
  );
  _checkNoMatches(
    root,
    failures,
    label: 'hot-path JSON codecs',
    files: _sourceFiles(root),
    patterns: <RegExp>[
      RegExp(r'\bjsonEncode\b'),
      RegExp(r'\bjsonDecode\b'),
      RegExp(r'\bserde_json\b'),
    ],
  );
  _checkNoMatches(
    root,
    failures,
    label: 'unfinished source markers',
    files: _sourceFiles(root),
    patterns: <RegExp>[RegExp(r'\b(?:TODO|FIXME)\b')],
  );
  _checkNoMatches(
    root,
    failures,
    label: 'unsupported image format support surface',
    files: _unsupportedFormatClaimFiles(root),
    patterns: _unsupportedFormatClaimPatterns,
    ignoreLine: _isBrandSvgReferenceLine,
  );
  _checkStableRasterFormatMatrix(root, failures);
  _checkRuntimePackagingDiscipline(root, failures);
  _checkPluginAuthoringDocs(root, failures);
  _checkPipelineExtensibilityDocs(root, failures);
  _checkVideoFramePluginPackage(root, failures);
  _checkCoreProductFeatureDocs(root, failures);
  _checkDeveloperDxDocs(root, failures);
  _checkBrandAssets(root, failures);
  _checkUserFacingReadmes(root, failures);
  _checkSdkCompatibilityContract(root, failures);
  _checkPubHookLayout(root, failures);
  _checkReleaseNeutralReadmeInstallCopy(root, failures);
  _checkPubReleaseReadiness(root, failures);
  _checkReleasePreflightHardening(root, failures);
  _checkAndroid16KbCiEvidence(root, failures);
  _checkExplicitPluginVersionConstraints(root, failures);
  _checkSwiftPackageManagerSupport(root, failures);
  _checkPublicExports(root, failures);
  _checkUnsafeBoundary(root, failures);
  _checkRustResolvedLicenses(root, failures);
  _checkRustDependencyAdvisories(root, failures);
  _checkRustDependencyCurrency(root, failures);
  _checkDartDependencyAdvisories(
    root,
    failures,
    checkCurrency: pixaShouldCheckDartDependencyCurrency(args),
  );

  if (failures.isNotEmpty) {
    stderr.writeln('Pixa guard failed:');
    for (final String failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Pixa guard passed.');
}

bool pixaShouldCheckDartDependencyCurrency(List<String> args) =>
    !args.contains('--skip-dart-dependency-currency');

const String _minimumDartSdk = '>=3.10.0 <4.0.0';
const String _minimumFlutterSdk = '>=3.38.1';
const String _minimumFlutterVersion = '3.38.1';

void _checkSdkCompatibilityContract(Directory root, List<String> failures) {
  const List<String> paths = <String>[
    'pubspec.yaml',
    'packages/pixa/pubspec.yaml',
    'packages/pixa_fetcher_s3/pubspec.yaml',
    'packages/pixa_video_frame_mjpeg/pubspec.yaml',
    'examples/pixa_gallery/pubspec.yaml',
    'tool/pixa_platform_build.dart',
    'tool/pixa_pub_dependency_smoke.dart',
    'packages/pixa/PLUGIN_AUTHORING.md',
    '.github/workflows/ci.yml',
  ];
  final Map<String, String> sources = <String, String>{};
  for (final String path in paths) {
    final File file = File('${root.path}/$path');
    if (file.existsSync()) {
      sources[path] = file.readAsStringSync();
    }
  }
  failures.addAll(pixaSdkCompatibilityFailures(sources));
}

List<String> pixaSdkCompatibilityFailures(Map<String, String> sources) {
  final List<String> failures = <String>[];
  const List<String> packagePubspecs = <String>[
    'packages/pixa/pubspec.yaml',
    'packages/pixa_fetcher_s3/pubspec.yaml',
    'packages/pixa_video_frame_mjpeg/pubspec.yaml',
    'examples/pixa_gallery/pubspec.yaml',
  ];
  final Map<String, YamlMap> pubspecs = <String, YamlMap>{};
  for (final String path in <String>['pubspec.yaml', ...packagePubspecs]) {
    final String? source = sources[path];
    if (source == null) {
      failures.add('SDK compatibility: $path is missing');
      continue;
    }
    try {
      final Object? document = loadYaml(source);
      if (document is! YamlMap) {
        failures.add('SDK compatibility: $path must contain a YAML map');
        continue;
      }
      pubspecs[path] = document;
    } on YamlException catch (error) {
      failures.add('SDK compatibility: $path is invalid YAML: $error');
    }
  }

  for (final MapEntry<String, YamlMap> entry in pubspecs.entries) {
    final Object? environment = entry.value['environment'];
    final Object? dartSdk = environment is YamlMap ? environment['sdk'] : null;
    if (dartSdk != _minimumDartSdk) {
      failures.add(
        'SDK compatibility: ${entry.key} must declare Dart '
        '`$_minimumDartSdk`',
      );
    }
  }
  for (final String path in packagePubspecs) {
    final Object? environment = pubspecs[path]?['environment'];
    final Object? flutterSdk = environment is YamlMap
        ? environment['flutter']
        : null;
    if (pubspecs.containsKey(path) && flutterSdk != _minimumFlutterSdk) {
      failures.add(
        'SDK compatibility: $path must declare Flutter '
        '`$_minimumFlutterSdk`',
      );
    }
  }

  final YamlMap? corePubspec = pubspecs['packages/pixa/pubspec.yaml'];
  final Object? dependencies = corePubspec?['dependencies'];
  if (corePubspec != null &&
      (dependencies is! YamlMap || dependencies['code_assets'] != '^1.2.1')) {
    failures.add(
      'SDK compatibility: packages/pixa/pubspec.yaml must declare '
      '`code_assets: ^1.2.1`',
    );
  }
  if (corePubspec != null &&
      (dependencies is! YamlMap || dependencies['hooks'] != '^2.0.2')) {
    failures.add(
      'SDK compatibility: packages/pixa/pubspec.yaml must declare '
      '`hooks: ^2.0.2`',
    );
  }

  for (final String path in <String>[
    'tool/pixa_platform_build.dart',
    'tool/pixa_pub_dependency_smoke.dart',
    'packages/pixa/PLUGIN_AUTHORING.md',
  ]) {
    final String? source = sources[path];
    if (source == null) {
      failures.add('SDK compatibility: $path is missing');
    } else if (!source.contains('sdk: "$_minimumDartSdk"')) {
      failures.add('SDK compatibility: $path must use Dart `$_minimumDartSdk`');
    }
  }
  final String? pluginGuide = sources['packages/pixa/PLUGIN_AUTHORING.md'];
  if (pluginGuide != null &&
      !pluginGuide.contains('flutter: "$_minimumFlutterSdk"')) {
    failures.add(
      'SDK compatibility: packages/pixa/PLUGIN_AUTHORING.md must use '
      'Flutter `$_minimumFlutterSdk`',
    );
  }

  final String? workflow = sources['.github/workflows/ci.yml'];
  if (workflow == null) {
    failures.add('SDK compatibility: .github/workflows/ci.yml is missing');
  } else {
    if (!workflow.contains('name: Flutter 3.38 Linux')) {
      failures.add(
        'SDK compatibility: CI must name the Flutter 3.38 minimum job',
      );
    }
    if (!workflow.contains('flutter-version: "$_minimumFlutterVersion"')) {
      failures.add(
        'SDK compatibility: CI must test exact Flutter '
        '$_minimumFlutterVersion',
      );
    }
    if (!workflow.contains(
      'dart run tool/pixa_guard.dart --skip-dart-dependency-currency',
    )) {
      failures.add(
        'SDK compatibility: minimum CI must skip only Dart dependency '
        'currency checks',
      );
    }
  }
  return failures;
}

void _checkPubHookLayout(Directory root, List<String> failures) {
  final Directory hookDirectory = Directory('${root.path}/packages/pixa/hook');
  if (!hookDirectory.existsSync()) {
    failures.add('pub hook layout: packages/pixa/hook is missing');
    return;
  }
  final List<String> files = hookDirectory
      .listSync(recursive: true)
      .whereType<File>()
      .map(
        (File file) => _relative(root, file).replaceFirst('packages/pixa/', ''),
      )
      .toList(growable: false);
  failures.addAll(pixaPubHookLayoutFailures(files));
}

List<String> pixaPubHookLayoutFailures(Iterable<String> files) {
  const Set<String> allowed = <String>{'hook/build.dart', 'hook/link.dart'};
  final List<String> rejected =
      files
          .where(
            (String path) =>
                path.startsWith('hook/') && !allowed.contains(path),
          )
          .toList(growable: false)
        ..sort();
  return <String>[
    for (final String path in rejected)
      'pub hook layout: $path is not an allowed pub hook entrypoint; '
          'move hook helpers under lib/src/hook',
  ];
}

final List<RegExp> _unsupportedFormatClaimPatterns = <RegExp>[
  RegExp(
    r'\b(?:svg|avif|heif|heic|jxl|jpeg[-_ ]?xl|openexr|icns|ora|otb)\b',
    caseSensitive: false,
  ),
  RegExp(r'\bpdf\s+preview\b', caseSensitive: false),
  RegExp(r'\b(?:cr2|cr3|nef|arw|dng|raf|orf|rw2)\b', caseSensitive: false),
];

const List<_StableRasterFormat> _stableRasterFormats = <_StableRasterFormat>[
  _StableRasterFormat(
    'tiff',
    'Tiff',
    'TIFF',
    'image/tiff',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'pnm',
    'Pnm',
    'PNM',
    'image/x-portable-anymap',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'qoi',
    'Qoi',
    'QOI',
    'image/qoi',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'tga',
    'Tga',
    'TGA',
    'image/x-tga',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'dds',
    'Dds',
    'DDS',
    'image/vnd.ms-dds',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'hdr',
    'Hdr',
    'HDR',
    'image/vnd.radiance',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'farbfeld',
    'Farbfeld',
    'Farbfeld',
    'image/x-farbfeld',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'pcx',
    'Pcx',
    'PCX',
    'image/x-pcx',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'sgi',
    'Sgi',
    'SGI',
    'image/sgi',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat('wbmp', 'Wbmp', 'WBMP', 'image/vnd.wap.wbmp'),
  _StableRasterFormat(
    'xbm',
    'Xbm',
    'XBM',
    'image/x-xbitmap',
    providerRuntimeDefault: true,
  ),
  _StableRasterFormat(
    'xpm',
    'Xpm',
    'XPM',
    'image/x-xpixmap',
    providerRuntimeDefault: true,
  ),
];

final class _StableRasterFormat {
  const _StableRasterFormat(
    this.id,
    this.rustVariant,
    this.label,
    this.primaryMimeType, {
    this.providerRuntimeDefault = false,
  });

  final String id;
  final String rustVariant;
  final String label;
  final String primaryMimeType;
  final bool providerRuntimeDefault;

  String get dartEnum => 'PixaImageMetadataFormat.$id';
}

Iterable<File> _dependencyFiles(Directory root) sync* {
  final List<String> paths = <String>[
    'pubspec.yaml',
    'pubspec.lock',
    'melos.yaml',
    _rustManifestPath,
    _rustLockPath,
  ];
  for (final String path in paths) {
    final File file = File('${root.path}/$path');
    if (file.existsSync()) {
      yield file;
    }
  }
  yield* _filesUnder(root, 'packages', extensions: <String>{'.yaml'});
  yield* _filesUnder(root, 'examples', extensions: <String>{'.yaml'});
  yield* _filesUnder(root, _rustWorkspacePath, extensions: <String>{'.toml'});
}

Iterable<File> _sourceFiles(Directory root) sync* {
  yield* _filesUnder(
    root,
    'packages',
    extensions: <String>{'.dart', '.yaml', '.toml'},
  );
  yield* _filesUnder(
    root,
    'examples',
    extensions: <String>{'.dart', '.yaml', '.toml'},
  );
  yield* _filesUnder(
    root,
    _rustWorkspacePath,
    extensions: <String>{'.rs', '.toml', '.lock'},
  );
}

Iterable<File> _unsupportedFormatClaimFiles(Directory root) sync* {
  final List<String> exactPaths = <String>[
    'README.md',
    'pubspec.yaml',
    'packages/pixa/lib/src/image_metadata.dart',
    'packages/pixa/lib/src/image_format.dart',
    'packages/pixa/plugins/pixa_plugins.json',
    'packages/pixa/pubspec.yaml',
    'packages/pixa/README.md',
    '$_rustWorkspacePath/pixa_core/Cargo.toml',
    '$_rustWorkspacePath/pixa_core/src/image_format.rs',
    'examples/pixa_gallery/pubspec.yaml',
  ];
  for (final String path in exactPaths) {
    final File file = File('${root.path}/$path');
    if (file.existsSync()) {
      yield file;
    }
  }
}

Iterable<File> _filesUnder(
  Directory root,
  String relativeDir, {
  required Set<String> extensions,
}) sync* {
  final Directory dir = Directory('${root.path}/$relativeDir');
  if (!dir.existsSync()) {
    return;
  }
  for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final String path = entity.path.replaceAll(r'\', '/');
    if (path.contains('/build/') ||
        path.contains('/.dart_tool/') ||
        path.contains('/ephemeral/') ||
        path.contains('/target/')) {
      continue;
    }
    if (extensions.any(path.endsWith)) {
      yield entity;
    }
  }
}

void _checkNoMatches(
  Directory root,
  List<String> failures, {
  required String label,
  required Iterable<File> files,
  required List<RegExp> patterns,
  bool Function(File file, String line)? ignoreLine,
}) {
  for (final File file in files) {
    final List<String> lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index++) {
      final String line = lines[index];
      if (ignoreLine != null && ignoreLine(file, line)) {
        continue;
      }
      for (final RegExp pattern in patterns) {
        if (pattern.hasMatch(line)) {
          failures.add(
            '$label: ${_relative(root, file)}:${index + 1} matches '
            '${pattern.pattern}',
          );
        }
      }
    }
  }
}

bool _isBrandSvgReferenceLine(File file, String line) {
  final String normalizedLine = line.replaceAll(r'\', '/');
  return normalizedLine.contains('assets/brand/pixa-lockup.svg') ||
      normalizedLine.contains('assets/brand/pixa-mark.svg');
}

void _checkStableRasterFormatMatrix(Directory root, List<String> failures) {
  final Map<String, String> sources = <String, String>{};
  for (final String path in <String>[
    '$_rustWorkspacePath/pixa_core/src/image_format.rs',
    '$_rustWorkspacePath/pixa_core/src/metadata.rs',
    '$_rustWorkspacePath/pixa_core/src/pipeline.rs',
    '$_rustWorkspacePath/pixa_core/examples/core_benchmark.rs',
    'tool/pixa_benchmark_report.dart',
    'packages/pixa/lib/src/image_metadata.dart',
    'packages/pixa/lib/src/image_format.dart',
    'packages/pixa/test/image_metadata_test.dart',
    'packages/pixa/test/provider_test.dart',
    'packages/pixa/test/runtime_loader_abi_test.dart',
  ]) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      failures.add('stable raster format matrix: $path is missing');
      continue;
    }
    sources[path] = file.readAsStringSync();
  }
  if (sources.length < 10) {
    return;
  }

  for (final _StableRasterFormat format in _stableRasterFormats) {
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/image_format.rs',
      'RuntimeImageFormat::${format.rustVariant}',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/image_format.rs',
      'format_id: "${format.id}"',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/image_format.rs',
      'primary_mime_type: "${format.primaryMimeType}"',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/image_format.rs',
      'label: "${format.label}"',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/metadata.rs',
      'ImageMetadataFormat::${format.rustVariant}',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/src/pipeline.rs',
      'label: "${format.id}"',
      format,
    );
    _requireToken(
      sources,
      failures,
      '$_rustWorkspacePath/pixa_core/examples/core_benchmark.rs',
      '("${format.id}",',
      format,
    );
    _requireToken(
      sources,
      failures,
      'tool/pixa_benchmark_report.dart',
      'runtime_format_decode_${format.id}_rgba',
      format,
    );
    _requireToken(
      sources,
      failures,
      'packages/pixa/lib/src/image_metadata.dart',
      format.id,
      format,
    );
    _requireToken(
      sources,
      failures,
      'packages/pixa/lib/src/image_format.dart',
      'format: ${format.dartEnum}',
      format,
    );
    _requireToken(
      sources,
      failures,
      'packages/pixa/test/image_metadata_test.dart',
      format.dartEnum,
      format,
    );
    _requireToken(
      sources,
      failures,
      'packages/pixa/test/runtime_loader_abi_test.dart',
      format.dartEnum,
      format,
    );
    if (format.providerRuntimeDefault) {
      _requireToken(
        sources,
        failures,
        'packages/pixa/test/provider_test.dart',
        "'${format.id}':",
        format,
      );
    } else {
      _requireToken(
        sources,
        failures,
        'packages/pixa/test/provider_test.dart',
        'engine-backed ${format.label} can explicitly use runtime display decoding',
        format,
      );
    }
  }
}

void _requireToken(
  Map<String, String> sources,
  List<String> failures,
  String path,
  String token,
  _StableRasterFormat format,
) {
  final String? source = sources[path];
  if (source == null || source.contains(token)) {
    return;
  }
  failures.add(
    'stable raster format matrix: ${format.id} missing `$token` in $path',
  );
}

void _checkRuntimePackagingDiscipline(Directory root, List<String> failures) {
  final Map<String, String> sources = <String, String>{};
  for (final String path in <String>[
    _rustManifestPath,
    '$_rustWorkspacePath/pixa_core/Cargo.toml',
    '$_rustWorkspacePath/pixa_runtime/Cargo.toml',
    '$_rustWorkspacePath/pixa_runtime/build.rs',
    'packages/pixa/hook/build.dart',
    'packages/pixa/plugins/pixa_plugins.json',
    'packages/pixa/plugins/optional/pixa_jpeg_turbo_processor.json',
    'packages/pixa/plugins/optional/pixa_webp_processor.json',
    'packages/pixa_video_frame_mjpeg/pixa_plugin.json',
  ]) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      failures.add('runtime packaging discipline: $path is missing');
      continue;
    }
    sources[path] = file.readAsStringSync();
  }
  if (sources.length < 9) {
    return;
  }
  final File oldMjpegManifest = File(
    '${root.path}/packages/pixa/plugins/optional/pixa_mjpeg_video_frame.json',
  );
  if (oldMjpegManifest.existsSync()) {
    failures.add(
      'runtime packaging discipline: MJPEG video-frame manifest must live in '
      'packages/pixa_video_frame_mjpeg/pixa_plugin.json, not core optional',
    );
  }

  _requireRawToken(
    sources,
    failures,
    'runtime packaging discipline',
    _rustManifestPath,
    '[profile.release]',
  );
  for (final String token in <String>[
    'opt-level = 3',
    'lto = "thin"',
    'codegen-units = 1',
    'panic = "abort"',
    'strip = "symbols"',
  ]) {
    _requireRawToken(
      sources,
      failures,
      'runtime packaging discipline',
      _rustManifestPath,
      token,
    );
  }

  _requireRawPattern(
    sources,
    failures,
    'runtime packaging discipline',
    '$_rustWorkspacePath/pixa_runtime/Cargo.toml',
    RegExp(r'^default\s*=\s*\[\s*\]$', multiLine: true),
    'default feature set must stay empty',
  );
  for (final RegExp pattern in <RegExp>[
    RegExp(r'^libwebp-sys\s*=.*optional\s*=\s*true', multiLine: true),
    RegExp(r'^turbojpeg-sys\s*=.*optional\s*=\s*true', multiLine: true),
  ]) {
    _requireRawPattern(
      sources,
      failures,
      'runtime packaging discipline',
      '$_rustWorkspacePath/pixa_runtime/Cargo.toml',
      pattern,
      pattern.pattern,
    );
  }
  for (final String token in <String>[
    'jpeg-turbo-roi = ["dep:turbojpeg-sys"]',
    'webp-roi = ["dep:libwebp-sys"]',
  ]) {
    _requireRawToken(
      sources,
      failures,
      'runtime packaging discipline',
      '$_rustWorkspacePath/pixa_runtime/Cargo.toml',
      token,
    );
  }

  _requireRawToken(
    sources,
    failures,
    'runtime packaging discipline',
    '$_rustWorkspacePath/pixa_core/Cargo.toml',
    'image = { version = "0.25.10", default-features = false',
  );
  _requireRawToken(
    sources,
    failures,
    'runtime packaging discipline',
    '$_rustWorkspacePath/pixa_core/Cargo.toml',
    'image-extras = { version = "0.1.1", default-features = false',
  );
  for (final String blocked in <String>['avif', 'exr']) {
    if (sources['$_rustWorkspacePath/pixa_core/Cargo.toml']!
        .toLowerCase()
        .contains(blocked)) {
      failures.add(
        'runtime packaging discipline: $_rustWorkspacePath/pixa_core/Cargo.toml must not '
        'enable heavy unsupported image feature `$blocked` by default',
      );
    }
  }

  for (final String token in <String>[
    'enable_native_roi',
    'enable_jpeg_turbo_roi',
    'enable_webp_roi',
    'plugins/optional/pixa_jpeg_turbo_processor.json',
    'plugins/optional/pixa_webp_processor.json',
    'link-arg=-Wl,-dead_strip',
    'link-arg=-Wl,--gc-sections',
    'link-arg=-Wl,--as-needed',
    'link-arg=/OPT:REF',
    'link-arg=/OPT:ICF',
  ]) {
    _requireRawToken(
      sources,
      failures,
      'runtime packaging discipline',
      'packages/pixa/hook/build.dart',
      token,
    );
  }

  for (final String token in <String>[
    'pixa_jpeg_turbo_processor_plugin_init',
    'pixa_webp_processor_plugin_init',
    'pixa_mjpeg_video_frame_plugin_init',
    'require_cargo_feature',
    'jpeg-turbo-roi',
    'webp-roi',
    '../../../plugins/pixa_plugins.json',
  ]) {
    _requireRawToken(
      sources,
      failures,
      'runtime packaging discipline',
      '$_rustWorkspacePath/pixa_runtime/build.rs',
      token,
    );
  }

  _checkDefaultManifestExcludesOptionalNativeRoi(
    root,
    failures,
    sources['packages/pixa/plugins/pixa_plugins.json']!,
  );
  _checkOptionalNativeRoiManifest(
    root,
    failures,
    path: 'packages/pixa/plugins/optional/pixa_jpeg_turbo_processor.json',
    expectedModuleId: 'pixa.processor.jpeg_turbo',
    expectedEntrypoint: 'pixa_jpeg_turbo_processor_plugin_init',
    expectedRoute: 'tile:jpeg',
  );
  _checkOptionalNativeRoiManifest(
    root,
    failures,
    path: 'packages/pixa/plugins/optional/pixa_webp_processor.json',
    expectedModuleId: 'pixa.processor.webp',
    expectedEntrypoint: 'pixa_webp_processor_plugin_init',
    expectedRoute: 'tile:webp',
  );
  _checkOptionalVideoFrameManifest(
    root,
    failures,
    path: 'packages/pixa_video_frame_mjpeg/pixa_plugin.json',
    expectedModuleId: 'pixa.video_frame.mjpeg',
    expectedPackageName: 'pixa_video_frame_mjpeg',
    expectedEntrypoint: 'pixa_mjpeg_video_frame_plugin_init',
    expectedRoute: 'video-frame:mjpeg',
    expectedOutputMime: 'image/jpeg',
  );
}

void _checkPluginAuthoringDocs(Directory root, List<String> failures) {
  final File guide = File('${root.path}/packages/pixa/PLUGIN_AUTHORING.md');
  if (!guide.existsSync()) {
    failures.add('missing packages/pixa/PLUGIN_AUTHORING.md');
    return;
  }
  final String guideText = guide.readAsStringSync();
  for (final String token in <String>[
    'Third-party plugin package layout',
    'pubspec.yaml',
    'PixaPlugin',
    'PixaVersionConstraint',
    'PixaConfig(plugins:',
    'PixaPluginIntegrationCandidate',
    'PixaRegistry.registerAdaptiveIntegration',
    'automatic integration selection',
    'hostRuntimeAvailable',
    'platformAvailable',
    'adaptivePluginIntegrations',
    'resolved package graph',
    'local `path`, a `git` dependency, or a workspace package',
    'must register at least one fetcher, decoder, processor',
    'every descriptor it adds must match the candidate mode',
    'dart pub publish --dry-run',
    'dart pub publish',
    'host-linked runtime modules',
    'Pure Dart mode',
    'Host-merge mode',
    'Standalone FFI mode',
    'Asset module mode',
    'pixa_plugin.json',
    'breaking changes',
  ]) {
    if (!guideText.contains(token)) {
      failures.add('plugin authoring guide missing `$token`');
    }
  }

  const Map<String, String> links = <String, String>{
    'README.md': 'packages/pixa/PLUGIN_AUTHORING.md',
    'README_ZH.md': 'packages/pixa/PLUGIN_AUTHORING.md',
    'packages/pixa/README.md': 'PLUGIN_AUTHORING.md',
    'packages/pixa/README_ZH.md': 'PLUGIN_AUTHORING.md',
  };
  for (final MapEntry<String, String> entry in links.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('missing ${entry.key}');
      continue;
    }
    if (!file.readAsStringSync().contains(entry.value)) {
      failures.add('${entry.key} must link to ${entry.value}');
    }
  }
}

void _checkPipelineExtensibilityDocs(Directory root, List<String> failures) {
  final File guide = File('${root.path}/packages/pixa/PLUGIN_AUTHORING.md');
  if (!guide.existsSync()) {
    failures.add('missing packages/pixa/PLUGIN_AUTHORING.md');
    return;
  }
  final String guideText = guide.readAsStringSync();
  for (final String token in <String>[
    'PixaPluginExecutionKind.platform',
    'PixaPluginExecutionPolicy.runtimeFirstWithPlatform()',
    'PixaPlatformContract',
    'PixaPlatformFetcherDescriptor',
    'PixaPayloadKind',
    'MethodChannel',
    'EventChannel',
    'Pigeon',
    'compiled route plan',
    'platform capability matrix',
    'hot-path safety',
    'cache hit',
    'PixaPluginIntegrationCandidate',
    'PixaRegistry.registerAdaptiveIntegration',
    'automatic integration selection',
    'adaptivePluginIntegrations',
  ]) {
    if (!guideText.contains(token)) {
      failures.add('pipeline extensibility docs missing `$token`');
    }
  }

  const Map<String, List<String>> docs = <String, List<String>>{
    'README.md': <String>[
      'compiled route plan',
      'platform capability matrix',
      'PixaPluginExecutionPolicy.runtimeFirstWithPlatform()',
      'PixaPluginIntegrationCandidate',
      'PixaRegistry.registerAdaptiveIntegration',
      'automatic integration selection',
      'adaptivePluginIntegrations',
      'resolved package graph',
    ],
    'README_ZH.md': <String>[
      'compiled route plan',
      'platform capability matrix',
      'PixaPluginExecutionPolicy.runtimeFirstWithPlatform()',
      'PixaPluginIntegrationCandidate',
      'PixaRegistry.registerAdaptiveIntegration',
      'automatic integration selection',
      'adaptivePluginIntegrations',
      '已解析 package graph',
    ],
    'packages/pixa/README.md': <String>[
      'compiled route plan',
      'platform capability matrix',
      'PixaPluginExecutionPolicy.runtimeFirstWithPlatform()',
      'PixaPluginIntegrationCandidate',
      'PixaRegistry.registerAdaptiveIntegration',
      'automatic integration selection',
      'adaptivePluginIntegrations',
      'resolved package graph',
    ],
    'packages/pixa/README_ZH.md': <String>[
      'compiled route plan',
      'platform capability matrix',
      'PixaPluginExecutionPolicy.runtimeFirstWithPlatform()',
      'PixaPluginIntegrationCandidate',
      'PixaRegistry.registerAdaptiveIntegration',
      'automatic integration selection',
      'adaptivePluginIntegrations',
      '已解析 package graph',
    ],
  };
  for (final MapEntry<String, List<String>> entry in docs.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('missing ${entry.key}');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in entry.value) {
      if (!text.contains(token)) {
        failures.add('${entry.key} missing pipeline docs token `$token`');
      }
    }
  }
}

void _checkVideoFramePluginPackage(Directory root, List<String> failures) {
  const Map<String, List<String>> requiredTokens = <String, List<String>>{
    'packages/pixa_video_frame_mjpeg/pubspec.yaml': <String>[
      'name: pixa_video_frame_mjpeg',
      'resolution: workspace',
      'pixa:',
    ],
    'packages/pixa_video_frame_mjpeg/lib/pixa_video_frame_mjpeg.dart': <String>[
      'PixaMjpegVideoFramePlugin',
      'PixaMjpegVideoFrame.request',
      'PixaMjpegVideoFrame.image',
      'const PixaMjpegVideoFramePlugin();',
      'pixaMjpegVideoFrameDescriptor',
      'PixaRuntimeVideoFrameBackendDescriptor',
      'video-frame:mjpeg',
      'image/jpeg',
    ],
    'packages/pixa_video_frame_mjpeg/pixa_plugin.json': <String>[
      '"moduleId": "pixa.video_frame.mjpeg"',
      '"packageName": "pixa_video_frame_mjpeg"',
      '"entrypointSymbol": "pixa_mjpeg_video_frame_plugin_init"',
      '"fetcherSourceKinds": ["video-frame:mjpeg"]',
      '"videoFrameOutputMimeTypes": ["image/jpeg"]',
    ],
    'packages/pixa_video_frame_mjpeg/README.md': <String>[
      'PixaMjpegVideoFramePlugin',
      'PixaMjpegVideoFrame.request',
      'PixaMjpegVideoFrame.image',
      'pixa_plugin.json',
      'resolved dependency graph',
      'No `hooks.user_defines`',
      'video-frame:mjpeg',
      'image/jpeg',
    ],
    'README.md': <String>[
      'pixa_video_frame_mjpeg',
      'PixaMjpegVideoFramePlugin',
      'does not ship a default video-frame backend',
      "PixaMjpegVideoFramePlugin()",
    ],
    'README_ZH.md': <String>[
      'pixa_video_frame_mjpeg',
      'PixaMjpegVideoFramePlugin',
      '不内置默认 video-frame backend',
      '自动发现',
    ],
    'packages/pixa/README.md': <String>[
      'pixa_video_frame_mjpeg',
      'PixaMjpegVideoFramePlugin',
      'does not ship a default video-frame backend',
      'resolved package graph',
    ],
    'packages/pixa/README_ZH.md': <String>[
      'pixa_video_frame_mjpeg',
      'PixaMjpegVideoFramePlugin',
      '不内置默认 video-frame backend',
      '自动发现',
    ],
    'packages/pixa/PLUGIN_AUTHORING.md': <String>[
      'pixa_video_frame_mjpeg',
      'PixaMjpegVideoFramePlugin',
      'PixaMjpegVideoFrame.request',
      'video-frame:mjpeg',
      'does not expose the MJPEG manifest',
      'resolved package graph',
    ],
  };

  for (final MapEntry<String, List<String>> entry in requiredTokens.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('video-frame plugin package: ${entry.key} is missing');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in entry.value) {
      if (!text.contains(token)) {
        failures.add(
          'video-frame plugin package: ${entry.key} missing `$token`',
        );
      }
    }
  }
}

void _checkCoreProductFeatureDocs(Directory root, List<String> failures) {
  const List<String> tokens = <String>[
    'PixaSourceSet',
    'PixaResponsiveImage',
    'PixaCacheWarmupManifest',
    'Pixa.warmup',
    'PixaImageAnalysis',
    'Pixa.analyze(request)',
  ];
  for (final String path in <String>[
    'README.md',
    'README_ZH.md',
    'packages/pixa/README.md',
  ]) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      failures.add('missing $path');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in tokens) {
      if (!text.contains(token)) {
        failures.add('$path must document `$token`');
      }
    }
  }
}

void _checkDeveloperDxDocs(Directory root, List<String> failures) {
  const Map<String, List<String>> requiredTokens = <String, List<String>>{
    'README.md': <String>[
      'PixaRequest.asset',
      'PixaProvider.custom',
      'PixaImage.runtimePlugin',
      'PixaDebugSnapshot.toDiagnosticString()',
      'PixaLogObserver',
      'PixaS3.provider',
      'PixaS3.image',
    ],
    'README_ZH.md': <String>[
      'PixaRequest.asset',
      'PixaProvider.custom',
      'PixaImage.runtimePlugin',
      'PixaDebugSnapshot.toDiagnosticString()',
      'PixaLogObserver',
      'PixaS3.provider',
      'PixaS3.image',
    ],
    'packages/pixa/README.md': <String>[
      'PixaRequest.asset',
      'PixaProvider.custom',
      'PixaImage.runtimePlugin',
      'PixaDebugSnapshot.toDiagnosticString()',
      'PixaLogObserver',
      'PixaS3.provider',
      'PixaS3.image',
    ],
    'packages/pixa/README_ZH.md': <String>[
      'PixaRequest.asset',
      'PixaProvider.custom',
      'PixaImage.runtimePlugin',
      'PixaDebugSnapshot.toDiagnosticString()',
      'PixaLogObserver',
      'PixaS3.provider',
      'PixaS3.image',
    ],
  };
  for (final MapEntry<String, List<String>> entry in requiredTokens.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('missing ${entry.key}');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in entry.value) {
      if (!text.contains(token)) {
        failures.add('${entry.key} must document Developer DX `$token`');
      }
    }
  }
}

void _checkBrandAssets(Directory root, List<String> failures) {
  const List<String> svgPaths = <String>[
    'packages/pixa/assets/brand/pixa-mark.svg',
    'packages/pixa/assets/brand/pixa-lockup.svg',
  ];
  for (final String path in svgPaths) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      failures.add('brand asset missing: $path');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in <String>[
      'role="img"',
      'aria-labelledby="title desc"',
      '<title id="title">',
      '<desc id="desc">',
    ]) {
      if (!text.contains(token)) {
        failures.add('brand asset $path missing `$token`');
      }
    }
  }

  const Map<String, String> readmeRefs = <String, String>{
    'README.md': 'packages/pixa/assets/brand/pixa-lockup.svg',
    'README_ZH.md': 'packages/pixa/assets/brand/pixa-lockup.svg',
    'packages/pixa/README.md': 'assets/brand/pixa-lockup.svg',
    'packages/pixa/README_ZH.md': 'assets/brand/pixa-lockup.svg',
  };
  for (final MapEntry<String, String> entry in readmeRefs.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('brand README missing: ${entry.key}');
      continue;
    }
    final String text = file.readAsStringSync();
    if (!text.contains(entry.value)) {
      failures.add('${entry.key} must reference `${entry.value}`');
    }
    if (!text.contains('alt="Pixa logo"')) {
      failures.add('${entry.key} must include accessible Pixa logo alt text');
    }
  }
}

void _checkUserFacingReadmes(Directory root, List<String> failures) {
  const Map<String, List<String>> requiredTokens = <String, List<String>>{
    'README.md': <String>[
      '## Install',
      '## Quick Start',
      '## What You Get',
      '## Official Plugins',
      '## Example App',
      '## Documentation Map',
    ],
    'README_ZH.md': <String>[
      '## 安装',
      '## 快速开始',
      '## 你会得到什么',
      '## 官方插件',
      '## 示例应用',
      '## 文档导航',
    ],
    'packages/pixa/README.md': <String>[
      '## Install',
      '## Quick Start',
      '## Requests And Sources',
      '## Responsive Images, Warmup, And Analysis',
      '## Privacy And Limits',
      '## Diagnostics',
    ],
    'packages/pixa/README_ZH.md': <String>[
      '## 安装',
      '## 快速开始',
      '## Request 和 Source',
      '## 响应式图片、预热和分析',
      '## 隐私与资源限制',
      '## 诊断',
    ],
    'packages/pixa_fetcher_s3/README.md': <String>[
      'Official Pixa S3 fetcher package',
      '## Install',
      '## Register',
      '## Use',
      '## Credentials And Privacy',
      'PixaS3.provider',
      'PixaS3.image',
    ],
    'packages/pixa_video_frame_mjpeg/README.md': <String>[
      'Official Pixa MJPEG AVI video-frame backend package',
      '## Install',
      'No `hooks.user_defines`',
      '## Register',
      '## Use',
      '## Failure Behavior',
    ],
    'examples/pixa_gallery/README.md': <String>[
      '# Pixa Gallery Example',
      '## Run',
      '## What To Try',
      '## Notes For App Developers',
    ],
    'examples/pixa_gallery/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md':
        <String>[
          '# Launch Screen Assets',
          'example app',
          'not part of the Pixa library API',
        ],
  };

  for (final MapEntry<String, List<String>> entry in requiredTokens.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('user-facing README missing: ${entry.key}');
      continue;
    }
    final String text = file.readAsStringSync();
    for (final String token in entry.value) {
      if (!text.contains(token)) {
        failures.add('${entry.key} must keep user README token `$token`');
      }
    }
  }
}

void _checkReleaseNeutralReadmeInstallCopy(
  Directory root,
  List<String> failures,
) {
  final Map<String, String> readmes = <String, String>{
    for (final String path in <String>[
      'README.md',
      'README_ZH.md',
      'packages/pixa/README.md',
      'packages/pixa/README_ZH.md',
      'packages/pixa_fetcher_s3/README.md',
      'packages/pixa_video_frame_mjpeg/README.md',
    ])
      path: File('${root.path}/$path').readAsStringSync(),
  };

  final List<RegExp> banned = <RegExp>[
    RegExp(r'first public release', caseSensitive: false),
    RegExp(r'publishing disabled', caseSensitive: false),
    RegExp(r'release owner', caseSensitive: false),
    RegExp(r'published package after', caseSensitive: false),
    RegExp(r'首个公开版本'),
  ];
  for (final MapEntry<String, String> entry in readmes.entries) {
    for (final RegExp pattern in banned) {
      if (pattern.hasMatch(entry.value)) {
        failures.add(
          '${entry.key} contains release-stage README install copy matching '
          '`${pattern.pattern}`',
        );
      }
    }
  }

  failures.addAll(pixaReadmeDependencyInstallFailures(readmes));
}

List<String> pixaReadmeDependencyInstallFailures(Map<String, String> readmes) {
  const Map<String, List<String>> requiredInstallTokens =
      <String, List<String>>{
        'README.md': <String>[
          'pixa: ^1.0.0',
          'Flutter 3.38.1',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
        'README_ZH.md': <String>[
          'pixa: ^1.0.0',
          'Flutter 3.38.1',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
        'packages/pixa/README.md': <String>[
          'pixa: ^1.0.0',
          'Flutter 3.38.1',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
        'packages/pixa/README_ZH.md': <String>[
          'pixa: ^1.0.0',
          'Flutter 3.38.1',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
        'packages/pixa_fetcher_s3/README.md': <String>[
          'pixa_fetcher_s3: ^1.0.0',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
        'packages/pixa_video_frame_mjpeg/README.md': <String>[
          'pixa_video_frame_mjpeg: ^1.0.0',
          'flutter pub get',
          'Future<void> main() async',
          'await Pixa.configure',
        ],
      };
  final List<String> failures = <String>[];
  for (final MapEntry<String, List<String>> required
      in requiredInstallTokens.entries) {
    final String? text = readmes[required.key];
    if (text == null) {
      failures.add('${required.key} is missing from README install checks');
      continue;
    }
    for (final String token in required.value) {
      if (!text.contains(token)) {
        failures.add('${required.key} must keep install token `$token`');
      }
    }
    if (RegExp(r'^\s*path\s*:', multiLine: true).hasMatch(text)) {
      failures.add(
        '${required.key} must not document a path dependency in its user '
        'install flow',
      );
    }
    if (RegExp(
      r'^\s*dependency_overrides\s*:',
      multiLine: true,
    ).hasMatch(text)) {
      failures.add(
        '${required.key} must not require dependency_overrides in its user '
        'install flow',
      );
    }
  }
  return failures;
}

void _checkPubReleaseReadiness(Directory root, List<String> failures) {
  const List<String> packageRoots = <String>[
    'packages/pixa',
    'packages/pixa_fetcher_s3',
    'packages/pixa_video_frame_mjpeg',
  ];

  final File dependencySmoke = File(
    '${root.path}/tool/pixa_pub_dependency_smoke.dart',
  );
  if (!dependencySmoke.existsSync()) {
    failures.add(
      'pub release readiness: tool/pixa_pub_dependency_smoke.dart is missing',
    );
  } else {
    final String dependencySmokeText = dependencySmoke.readAsStringSync();
    for (final String token in <String>[
      'core_only',
      's3_only',
      'mjpeg_only',
      's3_and_mjpeg',
      'all_explicit',
      'Pixa pub dependency matrix smoke passed.',
    ]) {
      if (!dependencySmokeText.contains(token)) {
        failures.add(
          'pub release readiness: dependency smoke must cover `$token`',
        );
      }
    }
  }

  for (final String packageRoot in packageRoots) {
    for (final String fileName in <String>['LICENSE', 'CHANGELOG.md']) {
      final File file = File('${root.path}/$packageRoot/$fileName');
      if (!file.existsSync()) {
        failures.add('pub release readiness: $packageRoot missing $fileName');
      }
    }

    final File pubspec = File('${root.path}/$packageRoot/pubspec.yaml');
    if (!pubspec.existsSync()) {
      failures.add('pub release readiness: $packageRoot missing pubspec.yaml');
      continue;
    }
    final String pubspecText = pubspec.readAsStringSync();
    if (RegExp(
      r'^\s*publish_to:\s*none\s*$',
      multiLine: true,
    ).hasMatch(pubspecText)) {
      failures.add(
        'pub release readiness: $packageRoot must not disable publishing',
      );
    }
    if (RegExp(
      r'^\s*path:\s*\.\./pixa\s*$',
      multiLine: true,
    ).hasMatch(pubspecText)) {
      failures.add(
        'pub release readiness: $packageRoot must not publish a path '
        'dependency on pixa',
      );
    }
  }

  for (final String pluginPackage in <String>[
    'packages/pixa_fetcher_s3',
    'packages/pixa_video_frame_mjpeg',
  ]) {
    final File pubspec = File('${root.path}/$pluginPackage/pubspec.yaml');
    if (!pubspec.existsSync()) {
      continue;
    }
    final String text = pubspec.readAsStringSync();
    if (!RegExp(r'^\s*pixa:\s*\^1\.0\.0\s*$', multiLine: true).hasMatch(text)) {
      failures.add(
        'pub release readiness: $pluginPackage must depend on pixa ^1.0.0',
      );
    }
  }

  const Map<String, String> pluginLibraryPaths = <String, String>{
    'packages/pixa_fetcher_s3': 'lib/pixa_fetcher_s3.dart',
    'packages/pixa_video_frame_mjpeg': 'lib/pixa_video_frame_mjpeg.dart',
  };
  for (final MapEntry<String, String> entry in pluginLibraryPaths.entries) {
    final File library = File('${root.path}/${entry.key}/${entry.value}');
    if (!library.existsSync()) {
      failures.add('pub release readiness: ${library.path} is missing');
      continue;
    }
    if (!library.readAsStringSync().contains(
      "export 'package:pixa/pixa.dart';",
    )) {
      failures.add(
        'pub release readiness: ${entry.key} must re-export '
        'package:pixa/pixa.dart for plugin-only consumers',
      );
    }
  }

  final File buildHook = File('${root.path}/packages/pixa/hook/build.dart');
  if (!buildHook.existsSync()) {
    failures.add(
      'pub release readiness: packages/pixa/hook/build.dart missing',
    );
  } else {
    final String buildHookText = buildHook.readAsStringSync();
    if (!buildHookText.contains("packageRoot.resolve('native_src/rust/')")) {
      failures.add(
        'pub release readiness: build hook must use package-local '
        'native_src/rust',
      );
    }
    if (buildHookText.contains('../../rust/')) {
      failures.add(
        'pub release readiness: build hook must not depend on repository-root '
        '../../rust',
      );
    }
    if (!buildHookText.contains("environment['CARGO_TARGET_DIR']") ||
        !buildHookText.contains("outputDirectory.resolve('cargo_target/')")) {
      failures.add(
        'pub release readiness: build hook must place Cargo target output '
        'under the Native Assets output directory',
      );
    }
  }

  _checkPublishedRustSource(root, failures);
  _checkSingleRustWorkspaceReferences(root, failures);
}

void _checkReleasePreflightHardening(Directory root, List<String> failures) {
  final Map<String, List<String>> requiredTokens = <String, List<String>>{
    'packages/pixa/dartdoc_options.yaml': <String>[
      'ambiguous-reexport',
      'unresolved-doc-reference',
    ],
    'packages/pixa_fetcher_s3/dartdoc_options.yaml': <String>[
      'ambiguous-reexport',
      'unresolved-doc-reference',
    ],
    'packages/pixa_video_frame_mjpeg/dartdoc_options.yaml': <String>[
      'ambiguous-reexport',
      'unresolved-doc-reference',
    ],
    'packages/pixa/.pubignore': <String>['*.iml'],
    'packages/pixa_fetcher_s3/.pubignore': <String>['*.iml'],
    'packages/pixa_video_frame_mjpeg/.pubignore': <String>['*.iml'],
    _rustManifestPath: <String>['rust-version = "'],
    'packages/pixa/hook/build.dart': <String>[
      'pixaValidateRustToolchain',
      'uses the host Rust toolchain',
      r'rustup target add $targetTriple',
    ],
    'tool/pixa_release_preflight.dart': <String>[
      "id: 'release-preflight-self-test'",
      "id: 'dartdoc-pixa'",
      "id: 'dartdoc-s3'",
      "id: 'dartdoc-mjpeg'",
      "id: 'rust-audit'",
      "id: 'guard-self-test'",
      "id: 'profile-report-self-test'",
      "id: 'profile-acceptance-self-test'",
      "id: 'benchmark-evidence'",
      "id: 'profile-evidence'",
      "id: 'gallery-tests'",
      "id: 'native-assets-log-self-test'",
      "id: 'native-assets-log'",
      "id: 'pub-dependency-smoke'",
      "id: 'publish-dry-run-pixa'",
      "id: 'publish-dry-run-s3'",
      "id: 'publish-dry-run-mjpeg'",
      "id: 'platform-evidence'",
      "id: 'git-diff-check'",
      '--platform-reports=',
      '--native-assets-log=',
      '--profile-input=',
      '--profile-baseline=',
      '--benchmark-input=',
      '--benchmark-baseline=',
      '--require-live-network',
      '--require-git-commit=',
    ],
    'tool/pixa_profile_report.dart': <String>[
      'requireLiveNetwork',
      '--require-live-network',
      'Live network evidence is required for release acceptance.',
      '_profileMinimumMemorySamples = 24',
      "_profileToolVersion = 'pixa-profile-v4'",
    ],
    'tool/pixa_benchmark_report.dart': <String>[
      '_benchmarkMaximumRegressionRatio',
      '_benchmarkAbsoluteNoiseNanoseconds',
      '--verify-evidence=',
      '--require-git-commit=',
      'Result: **COVERAGE ONLY**',
      'Baseline benchmark environment is not comparable.',
    ],
    'tool/pixa_profile_acceptance.dart': <String>[
      "'rustc'",
      'profileRustVersionCommand',
    ],
    'tool/pixa_native_assets_log_check.dart': <String>[
      'package:objective_c/objective_c.dylib',
      'objective_c.framework',
      'objective_c1.framework',
      'package:pixa/pixa_runtime',
      'pixa_runtime.framework',
      'pixa_runtime1.framework',
      'mapping is not an approved Flutter toolchain collision',
    ],
    'tool/pixa_pub_dependency_smoke.dart': <String>[
      '--to-archive=',
      'PUB_HOSTED_URL',
      'source: hosted',
      'await Pixa.configure(',
      'Pixa.pipeline.cacheStats()',
      "'test',",
      "'--concurrency=1'",
    ],
    'README.md': <String>[
      "import 'package:flutter/material.dart';",
      "import 'package:pixa/pixa.dart';",
      'Visual Studio',
      'NASM',
      'Android NDK',
      'CMake',
      'Ninja',
    ],
    'README_ZH.md': <String>[
      "import 'package:flutter/material.dart';",
      "import 'package:pixa/pixa.dart';",
      'Visual Studio',
      'NASM',
      'Android NDK',
      'CMake',
      'Ninja',
    ],
    'packages/pixa/README.md': <String>[
      "import 'package:flutter/material.dart';",
      "import 'package:pixa/pixa.dart';",
      "import 'package:pixa/pixa_debug.dart';",
      'Visual Studio',
      'NASM',
      'Android NDK',
      'CMake',
      'Ninja',
    ],
    'packages/pixa/README_ZH.md': <String>[
      "import 'package:flutter/material.dart';",
      "import 'package:pixa/pixa.dart';",
      "import 'package:pixa/pixa_debug.dart';",
      'Visual Studio',
      'NASM',
      'Android NDK',
      'CMake',
      'Ninja',
    ],
    'packages/pixa_video_frame_mjpeg/README.md': <String>[
      'No `hooks.user_defines`',
      'resolved dependency graph',
      "import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';",
    ],
    'packages/pixa_fetcher_s3/README.md': <String>[
      'AWS Signature Version 4',
      "import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';",
      "import 'package:pixa/pixa_debug.dart';",
    ],
  };
  for (final MapEntry<String, List<String>> entry in requiredTokens.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('release preflight hardening: ${entry.key} is missing');
      continue;
    }
    final String source = file.readAsStringSync();
    for (final String token in entry.value) {
      if (!source.contains(token)) {
        failures.add(
          'release preflight hardening: ${entry.key} must contain `$token`',
        );
      }
    }
  }

  for (final String readme in <String>[
    'README.md',
    'README_ZH.md',
    'packages/pixa/README.md',
    'packages/pixa/README_ZH.md',
  ]) {
    final String source = File('${root.path}/$readme').readAsStringSync();
    if (!source.toLowerCase().contains('rustup') ||
        !source.toLowerCase().contains('toolchain')) {
      failures.add(
        'release preflight hardening: $readme must document the Rust '
        'toolchain prerequisite',
      );
    }
  }

  final String s3Pubspec = File(
    '${root.path}/packages/pixa_fetcher_s3/pubspec.yaml',
  ).readAsStringSync();
  if (RegExp(
    r'^description:.*descriptor',
    multiLine: true,
  ).hasMatch(s3Pubspec)) {
    failures.add(
      'release preflight hardening: S3 pub metadata must describe the '
      'production SigV4 fetcher, not a descriptor package',
    );
  }

  final String workflow = File(
    '${root.path}/.github/workflows/ci.yml',
  ).readAsStringSync();
  if (RegExp(r'uses:\s+[^\s#]+@v\d+').hasMatch(workflow)) {
    failures.add(
      'release preflight hardening: CI actions must use immutable pins',
    );
  }
  if (!workflow.contains('rustup toolchain install stable')) {
    failures.add(
      'release preflight hardening: CI must validate rolling Rust stable',
    );
  }
}

void _checkPublishedRustSource(Directory root, List<String> failures) {
  final Directory packageRust = Directory('${root.path}/$_rustWorkspacePath');
  if (!packageRust.existsSync()) {
    failures.add('pub release readiness: $_rustWorkspacePath is missing');
    return;
  }
  final Directory rootRust = Directory('${root.path}/rust');
  if (rootRust.existsSync()) {
    failures.add(
      'pub release readiness: root rust/ must not exist; '
      '$_rustWorkspacePath is the single Rust source of truth',
    );
  }

  final Directory packageTarget = Directory('${packageRust.path}/target');
  if (packageTarget.existsSync()) {
    failures.add(
      'pub release readiness: $_rustWorkspacePath must not include '
      'Cargo target build output',
    );
  }

  for (final String path in <String>[
    _rustManifestPath,
    _rustLockPath,
    '$_rustWorkspacePath/pixa_core/Cargo.toml',
    '$_rustWorkspacePath/pixa_core/src/lib.rs',
    '$_rustWorkspacePath/pixa_runtime/Cargo.toml',
    '$_rustWorkspacePath/pixa_runtime/src/lib.rs',
  ]) {
    if (!File('${root.path}/$path').existsSync()) {
      failures.add('pub release readiness: $path is missing');
    }
  }
}

void _checkAndroid16KbCiEvidence(Directory root, List<String> failures) {
  final String workflow = File(
    '${root.path}/.github/workflows/ci.yml',
  ).readAsStringSync();
  final File acceptanceScript = File(
    '${root.path}/tool/pixa_android_platform_ci.sh',
  );
  if (!acceptanceScript.existsSync()) {
    failures.add('Android 16 KB CI: missing tool/pixa_android_platform_ci.sh');
  }
  failures.addAll(
    pixaAndroid16KbCiFailures(
      '$workflow\n${acceptanceScript.existsSync() ? acceptanceScript.readAsStringSync() : ''}',
    ),
  );
}

List<String> pixaAndroid16KbCiFailures(String workflow) {
  const Map<String, String> required = <String, String>{
    'api-level: 35': 'API 35 emulator',
    'google_apis_ps16k': '16 KB system image',
    'bash tool/pixa_android_platform_ci.sh': 'single Bash action command',
    'set -euo pipefail': 'strict Bash acceptance script',
    'getconf PAGE_SIZE': 'device page-size assertion',
    '16384': '16 KB page-size value',
    '-P 16': 'APK 16 KB ZIP alignment check',
    'lib/x86_64/libpixa_runtime.so': 'x86_64 runtime ELF extraction',
    'llvm-readelf': 'runtime ELF program-header inspection',
    '0x4000': 'minimum 16 KB ELF LOAD alignment',
  };
  return <String>[
    for (final MapEntry<String, String> entry in required.entries)
      if (!workflow.contains(entry.key))
        'Android 16 KB CI: missing ${entry.value} `${entry.key}`',
  ];
}

void _checkSingleRustWorkspaceReferences(
  Directory root,
  List<String> failures,
) {
  const List<String> files = <String>[
    'melos.yaml',
    'pubspec.yaml',
    '.github/workflows/ci.yml',
    'tool/pixa_benchmark_report.dart',
    'tool/pixa_release_preflight.dart',
    'tool/pixa_guard.dart',
  ];
  for (final String path in files) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      continue;
    }
    final String text = file.readAsStringSync();
    final RegExp oldRootCargoPathPattern = RegExp(
      r'''(^|[\s'"])rust/Cargo\.(?:toml|lock)\b''',
      multiLine: true,
    );
    if (oldRootCargoPathPattern.hasMatch(text)) {
      failures.add(
        'pub release readiness: $path must reference $_rustWorkspacePath, '
        'not root rust/Cargo.*',
      );
    }
    if ((text.contains('cargo test') ||
            text.contains('cargo clippy') ||
            text.contains('cargo run')) &&
        !text.contains('--target-dir') &&
        path != 'tool/pixa_guard.dart') {
      failures.add(
        'pub release readiness: $path must route Cargo build output through '
        '--target-dir build/rust-target',
      );
    }
  }
}

void _checkExplicitPluginVersionConstraints(
  Directory root,
  List<String> failures,
) {
  final List<File> files = <File>[
    File('${root.path}/README.md'),
    File('${root.path}/README_ZH.md'),
    File('${root.path}/packages/pixa/README.md'),
    File('${root.path}/packages/pixa/README_ZH.md'),
    File('${root.path}/packages/pixa/PLUGIN_AUTHORING.md'),
    File('${root.path}/packages/pixa/lib/src/plugin.dart'),
    File('${root.path}/packages/pixa/test/plugin_test.dart'),
    File('${root.path}/packages/pixa/test/provider_test.dart'),
    File('${root.path}/packages/pixa_fetcher_s3/README.md'),
    File('${root.path}/packages/pixa_fetcher_s3/pubspec.yaml'),
    File('${root.path}/packages/pixa_video_frame_mjpeg/README.md'),
    File('${root.path}/packages/pixa_video_frame_mjpeg/pubspec.yaml'),
  ];

  final RegExp anyDependency = RegExp(
    r'^\s*(?:pixa|pixa_fetcher_s3|pixa_video_frame_mjpeg):\s*any\s*$',
    multiLine: true,
  );

  for (final File file in files) {
    if (!file.existsSync()) {
      failures.add('explicit plugin version constraints: missing ${file.path}');
      continue;
    }
    final String text = file.readAsStringSync();
    if (text.contains('PixaVersionConstraint.any')) {
      failures.add(
        'explicit plugin version constraints: ${_relative(root, file)} '
        'must not use PixaVersionConstraint.any',
      );
    }
    if (text.contains('PixaVersionConstraint()')) {
      failures.add(
        'explicit plugin version constraints: ${_relative(root, file)} '
        'must not construct an empty PixaVersionConstraint',
      );
    }
    if (anyDependency.hasMatch(text)) {
      failures.add(
        'explicit plugin version constraints: ${_relative(root, file)} '
        'must not use any for Pixa package dependencies',
      );
    }
  }

  final File pluginApi = File('${root.path}/packages/pixa/lib/src/plugin.dart');
  if (pluginApi.existsSync()) {
    final String text = pluginApi.readAsStringSync();
    for (final String token in <String>[
      'required this.minimumInclusive',
      'required this.maximumExclusive',
      'final String minimumInclusive',
      'final String maximumExclusive',
    ]) {
      if (!text.contains(token)) {
        failures.add(
          'explicit plugin version constraints: plugin API missing `$token`',
        );
      }
    }
  }
}

void _checkSwiftPackageManagerSupport(Directory root, List<String> failures) {
  final Map<String, String> sources = <String, String>{};
  for (final String path in <String>[
    'packages/pixa/pubspec.yaml',
    'packages/pixa/ios/pixa/Package.swift',
    'packages/pixa/macos/pixa/Package.swift',
    'packages/pixa/ios/pixa/Sources/pixa/PixaPlugin.swift',
    'packages/pixa/macos/pixa/Sources/pixa/PixaPlugin.swift',
    'packages/pixa/ios/pixa.podspec',
    'packages/pixa/macos/pixa.podspec',
    '.github/workflows/ci.yml',
  ]) {
    final File file = File('${root.path}/$path');
    if (!file.existsSync()) {
      failures.add('SwiftPM support: $path is missing');
      continue;
    }
    sources[path] = file.readAsStringSync();
  }
  if (sources.length < 8) {
    return;
  }

  for (final String token in <String>[
    'plugin:',
    'platforms:',
    'ios:',
    'macos:',
    'pluginClass: PixaPlugin',
  ]) {
    _requireRawToken(
      sources,
      failures,
      'SwiftPM support',
      'packages/pixa/pubspec.yaml',
      token,
    );
  }

  _checkSwiftPackageManifest(
    sources,
    failures,
    path: 'packages/pixa/ios/pixa/Package.swift',
    platformToken: '.iOS("13.0")',
  );
  _checkSwiftPackageManifest(
    sources,
    failures,
    path: 'packages/pixa/macos/pixa/Package.swift',
    platformToken: '.macOS("10.15")',
  );
  _checkDarwinPluginSource(
    sources,
    failures,
    path: 'packages/pixa/ios/pixa/Sources/pixa/PixaPlugin.swift',
    flutterImport: 'import Flutter',
  );
  _checkDarwinPluginSource(
    sources,
    failures,
    path: 'packages/pixa/macos/pixa/Sources/pixa/PixaPlugin.swift',
    flutterImport: 'import FlutterMacOS',
  );
  _checkPodspec(
    sources,
    failures,
    path: 'packages/pixa/ios/pixa.podspec',
    flutterDependency: "s.dependency 'Flutter'",
    platformToken: "s.platform = :ios, '13.0'",
  );
  _checkPodspec(
    sources,
    failures,
    path: 'packages/pixa/macos/pixa.podspec',
    flutterDependency: "s.dependency 'FlutterMacOS'",
    platformToken: "s.platform = :osx, '10.15'",
  );
  _requireRawToken(
    sources,
    failures,
    'SwiftPM support',
    '.github/workflows/ci.yml',
    'flutter config --enable-swift-package-manager',
  );
}

void _checkSwiftPackageManifest(
  Map<String, String> sources,
  List<String> failures, {
  required String path,
  required String platformToken,
}) {
  for (final String token in <String>[
    '// swift-tools-version: 5.9',
    'name: "pixa"',
    platformToken,
    '.library(name: "pixa", targets: ["pixa"])',
    '.package(name: "FlutterFramework", path: "../FlutterFramework")',
    '.product(name: "FlutterFramework", package: "FlutterFramework")',
  ]) {
    _requireRawToken(sources, failures, 'SwiftPM support', path, token);
  }
}

void _checkDarwinPluginSource(
  Map<String, String> sources,
  List<String> failures, {
  required String path,
  required String flutterImport,
}) {
  for (final String token in <String>[
    flutterImport,
    'public class PixaPlugin: NSObject, FlutterPlugin',
    'public static func register(with registrar: FlutterPluginRegistrar)',
  ]) {
    _requireRawToken(sources, failures, 'SwiftPM support', path, token);
  }
  if (sources[path]?.contains('FlutterMethodChannel') == true) {
    failures.add(
      'SwiftPM support: $path must stay registration-only and avoid a method channel',
    );
  }
}

void _checkPodspec(
  Map<String, String> sources,
  List<String> failures, {
  required String path,
  required String flutterDependency,
  required String platformToken,
}) {
  for (final String token in <String>[
    "s.name             = 'pixa'",
    "s.version          = '1.0.0'",
    "s.source_files     = 'pixa/Sources/pixa/**/*'",
    flutterDependency,
    platformToken,
    "s.swift_version = '5.0'",
  ]) {
    _requireRawToken(sources, failures, 'SwiftPM support', path, token);
  }
}

void _requireRawToken(
  Map<String, String> sources,
  List<String> failures,
  String label,
  String path,
  String token,
) {
  final String? source = sources[path];
  if (source == null || source.contains(token)) {
    return;
  }
  failures.add('$label: $path missing `$token`');
}

void _requireRawPattern(
  Map<String, String> sources,
  List<String> failures,
  String label,
  String path,
  RegExp pattern,
  String expectation,
) {
  final String? source = sources[path];
  if (source == null || pattern.hasMatch(source)) {
    return;
  }
  failures.add('$label: $path does not match `$expectation`');
}

void _checkDefaultManifestExcludesOptionalNativeRoi(
  Directory root,
  List<String> failures,
  String source,
) {
  final List<Object?> modules = _manifestModules(
    root,
    failures,
    'packages/pixa/plugins/pixa_plugins.json',
    source,
  );
  const Set<String> optionalModuleIds = <String>{
    'pixa.processor.jpeg_turbo',
    'pixa.processor.webp',
    'pixa.video_frame.mjpeg',
  };
  const Set<String> optionalEntrypoints = <String>{
    'pixa_jpeg_turbo_processor_plugin_init',
    'pixa_webp_processor_plugin_init',
    'pixa_mjpeg_video_frame_plugin_init',
  };
  for (final Object? rawModule in modules) {
    if (rawModule is! Map<String, Object?>) {
      continue;
    }
    final String moduleId = rawModule['moduleId'] as String? ?? '';
    final String entrypoint = rawModule['entrypointSymbol'] as String? ?? '';
    if (optionalModuleIds.contains(moduleId) ||
        optionalEntrypoints.contains(entrypoint)) {
      failures.add(
        'runtime packaging discipline: default core manifest must not include '
        'optional native ROI module `$moduleId`',
      );
    }
    final String deployment = rawModule['deployment'] as String? ?? '';
    if (deployment != 'builtInHostModule' &&
        deployment != 'hostLinkedPluginModule') {
      failures.add(
        'runtime packaging discipline: default module `$moduleId` must be '
        'linkable into the single host binary, not `$deployment`',
      );
    }
  }
}

void _checkOptionalNativeRoiManifest(
  Directory root,
  List<String> failures, {
  required String path,
  required String expectedModuleId,
  required String expectedEntrypoint,
  required String expectedRoute,
}) {
  final File file = File('${root.path}/$path');
  final List<Object?> modules = _manifestModules(
    root,
    failures,
    path,
    file.readAsStringSync(),
  );
  final Map<String, Object?>? module = modules
      .whereType<Map<String, Object?>>()
      .cast<Map<String, Object?>?>()
      .firstWhere(
        (Map<String, Object?>? item) => item?['moduleId'] == expectedModuleId,
        orElse: () => null,
      );
  if (module == null) {
    failures.add(
      'runtime packaging discipline: $path missing module $expectedModuleId',
    );
    return;
  }
  if (module['deployment'] != 'hostLinkedPluginModule' ||
      module['entrypointSymbol'] != expectedEntrypoint ||
      module['hostManagedRuntime'] != true ||
      module['binaryMessages'] != true ||
      module['ownedBuffers'] != true ||
      module['streamHandles'] != true) {
    failures.add(
      'runtime packaging discipline: $path module $expectedModuleId must use '
      'host-linked single-runtime binary message ABI',
    );
  }
  final Object? capabilities = module['capabilities'];
  final Object? routes = module['processorOperations'];
  if (capabilities is! List<Object?> ||
      !capabilities.contains('processor') ||
      routes is! List<Object?> ||
      !routes.contains(expectedRoute)) {
    failures.add(
      'runtime packaging discipline: $path module $expectedModuleId must '
      'declare processor route $expectedRoute',
    );
  }
}

void _checkOptionalVideoFrameManifest(
  Directory root,
  List<String> failures, {
  required String path,
  required String expectedModuleId,
  required String expectedPackageName,
  required String expectedEntrypoint,
  required String expectedRoute,
  required String expectedOutputMime,
}) {
  final File file = File('${root.path}/$path');
  final List<Object?> modules = _manifestModules(
    root,
    failures,
    path,
    file.readAsStringSync(),
  );
  final Map<String, Object?>? module = modules
      .whereType<Map<String, Object?>>()
      .cast<Map<String, Object?>?>()
      .firstWhere(
        (Map<String, Object?>? item) => item?['moduleId'] == expectedModuleId,
        orElse: () => null,
      );
  if (module == null) {
    failures.add(
      'runtime packaging discipline: $path missing module $expectedModuleId',
    );
    return;
  }
  if (module['packageName'] != expectedPackageName ||
      module['deployment'] != 'hostLinkedPluginModule' ||
      module['entrypointSymbol'] != expectedEntrypoint ||
      module['hostManagedRuntime'] != true ||
      module['binaryMessages'] != true ||
      module['ownedBuffers'] != true ||
      module['streamHandles'] != true) {
    failures.add(
      'runtime packaging discipline: $path module $expectedModuleId must use '
      'host-linked single-runtime binary message ABI',
    );
  }
  final Object? capabilities = module['capabilities'];
  final Object? sourceKinds = module['fetcherSourceKinds'];
  final Object? outputMimeTypes = module['videoFrameOutputMimeTypes'];
  if (capabilities is! List<Object?> ||
      !capabilities.contains('fetcher') ||
      sourceKinds is! List<Object?> ||
      !sourceKinds.contains(expectedRoute) ||
      outputMimeTypes is! List<Object?> ||
      !outputMimeTypes.contains(expectedOutputMime)) {
    failures.add(
      'runtime packaging discipline: $path module $expectedModuleId must '
      'declare fetcher route $expectedRoute and output $expectedOutputMime',
    );
  }
}

List<Object?> _manifestModules(
  Directory root,
  List<String> failures,
  String path,
  String source,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    failures.add('runtime packaging discipline: $path invalid JSON: $error');
    return const <Object?>[];
  }
  if (decoded is! Map<String, Object?>) {
    failures.add('runtime packaging discipline: $path root must be an object');
    return const <Object?>[];
  }
  final Object? modules = decoded['modules'];
  if (modules is! List<Object?>) {
    failures.add('runtime packaging discipline: $path modules must be a list');
    return const <Object?>[];
  }
  return modules;
}

void _checkUnsafeBoundary(Directory root, List<String> failures) {
  for (final File file in _filesUnder(
    root,
    _rustWorkspacePath,
    extensions: <String>{'.rs'},
  )) {
    final String path = _relative(root, file);
    final bool allowed =
        path.startsWith('$_rustWorkspacePath/pixa_runtime/') ||
        path.startsWith('$_rustWorkspacePath/pixa_runtime/examples/');
    if (allowed) {
      continue;
    }
    final List<String> lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index++) {
      if (RegExp(r'\bunsafe\b').hasMatch(lines[index])) {
        failures.add(
          'unsafe boundary: $path:${index + 1} keeps unsafe outside the runtime boundary',
        );
      }
    }
  }
}

void _checkRustResolvedLicenses(Directory root, List<String> failures) {
  final ProcessResult result = Process.runSync('cargo', <String>[
    'metadata',
    '--manifest-path',
    _rustManifestPath,
    '--format-version',
    '1',
    '--locked',
  ], workingDirectory: root.path);
  if (result.exitCode != 0) {
    failures.add('rust license audit: cargo metadata failed');
    return;
  }

  final Map<String, Object?> metadata =
      jsonDecode(result.stdout as String) as Map<String, Object?>;
  final List<Object?> packages = metadata['packages']! as List<Object?>;
  final Map<String, Map<String, Object?>> packageById =
      <String, Map<String, Object?>>{};
  for (final Object? package in packages) {
    final Map<String, Object?> typed = package! as Map<String, Object?>;
    packageById[typed['id']! as String] = typed;
  }

  final Map<String, Object?> resolve =
      metadata['resolve']! as Map<String, Object?>;
  final List<Object?> nodes = resolve['nodes']! as List<Object?>;
  for (final Object? node in nodes) {
    final String id = (node! as Map<String, Object?>)['id']! as String;
    final Map<String, Object?> package = packageById[id]!;
    final String name = package['name']! as String;
    final String version = package['version']! as String;
    final String? license = package['license'] as String?;
    final Object? licenseFile = package['license_file'];
    if ((license == null || license.trim().isEmpty) && licenseFile == null) {
      failures.add('rust license audit: $name $version has no license');
      continue;
    }
    if (license != null && _strongCopyleft.hasMatch(license)) {
      failures.add(
        'rust license audit: $name $version uses blocked license $license',
      );
    }
  }
}

final RegExp _strongCopyleft = RegExp(r'\b(?:AGPL|GPL|LGPL|SSPL)\b');

void _checkPublicExports(Directory root, List<String> failures) {
  final Map<String, Set<String>> allowedExports = <String, Set<String>>{
    'packages/pixa/lib/pixa.dart': <String>{
      'src/animation.dart',
      'src/cache_warmup.dart',
      'src/cache/cache_stats.dart',
      'src/config.dart',
      'src/controller.dart',
      'src/failure.dart',
      'src/image_analysis.dart',
      'src/image_metadata.dart',
      'src/large_image/tile_plan.dart',
      'src/observer.dart',
      'src/pipeline.dart',
      'src/pixa.dart',
      'src/plugin.dart',
      'src/prefetch.dart',
      'src/processors.dart',
      'src/progress.dart',
      'src/provider.dart',
      'src/request.dart',
      'src/source.dart',
      'src/source_set.dart',
      'src/widgets/pixa_image.dart',
      'src/widgets/pixa_large_image.dart',
      'src/widgets/pixa_responsive_image.dart',
    },
    'packages/pixa/lib/pixa_plugins.dart': <String>{
      'src/contracts.dart',
      'src/observer.dart',
      'src/plugin.dart',
      'src/registry.dart',
    },
    'packages/pixa/lib/pixa_debug.dart': <String>{
      'src/cache/cache_stats.dart',
      'src/debug/debug_inspector.dart',
      'src/debug/registry_architecture_snapshot.dart',
      'src/display_decoder.dart',
      'src/runtime/capabilities.dart',
      'src/runtime/runtime_plugin_stats.dart',
      'src/scheduler_stats.dart',
    },
  };
  for (final MapEntry<String, Set<String>> entry in allowedExports.entries) {
    final File file = File('${root.path}/${entry.key}');
    if (!file.existsSync()) {
      failures.add('public API surface: ${entry.key} is missing');
      continue;
    }
    final Set<String> exported = _exportPaths(file.readAsStringSync()).toSet();
    final Set<String> unexpected = exported.difference(entry.value);
    final Set<String> missing = entry.value.difference(exported);
    for (final String path in unexpected) {
      failures.add(
        'public API surface: ${entry.key} unexpectedly exports $path',
      );
    }
    for (final String path in missing) {
      failures.add('public API surface: ${entry.key} no longer exports $path');
    }
  }
}

Iterable<String> _exportPaths(String source) sync* {
  final RegExp exportPattern = RegExp(
    r'''export\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  for (final RegExpMatch match in exportPattern.allMatches(source)) {
    yield match.group(1)!;
  }
}

void _checkRustDependencyAdvisories(Directory root, List<String> failures) {
  final File lockFile = File('${root.path}/$_rustLockPath');
  if (!lockFile.existsSync()) {
    failures.add('rust dependency audit: $_rustLockPath is missing');
    return;
  }
  final List<String> args = <String>[
    'audit',
    '-f',
    _rustLockPath,
    '-D',
    'warnings',
  ];
  ProcessResult result = Process.runSync(
    'cargo',
    args,
    workingDirectory: root.path,
  );
  if (result.exitCode != 0 && _isMissingCargoAudit(result)) {
    result = _runCargoAuditExecutable(root);
  }
  if (result.exitCode != 0) {
    failures.add(
      'rust dependency audit: cargo audit failed; install cargo-audit and '
      'resolve vulnerabilities, warnings, unmaintained, unsound, or yanked crates',
    );
  }
}

bool _isMissingCargoAudit(ProcessResult result) {
  final String output = '${result.stdout}\n${result.stderr}'.toLowerCase();
  return output.contains('no such command') ||
      output.contains('audit is not installed') ||
      output.contains('no command named `audit`') ||
      output.contains('no command named \'audit\'');
}

ProcessResult _runCargoAuditExecutable(Directory root) {
  final List<String> args = <String>['-f', _rustLockPath, '-D', 'warnings'];
  final ProcessResult pathResult = Process.runSync(
    'cargo-audit',
    args,
    workingDirectory: root.path,
  );
  if (pathResult.exitCode == 0) {
    return pathResult;
  }
  final String? home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return pathResult;
  }
  final File executable = File('$home/.cargo/bin/cargo-audit');
  if (!executable.existsSync()) {
    return pathResult;
  }
  return Process.runSync(executable.path, args, workingDirectory: root.path);
}

void _checkDartDependencyAdvisories(
  Directory root,
  List<String> failures, {
  required bool checkCurrency,
}) {
  final ProcessResult result = Process.runSync(
    Platform.resolvedExecutable,
    <String>['pub', 'outdated', '--json'],
    workingDirectory: root.path,
  );
  if (result.exitCode != 0) {
    failures.add('dart dependency audit: dart pub outdated failed');
    return;
  }

  final Map<String, Object?> outdated =
      jsonDecode(result.stdout as String) as Map<String, Object?>;
  if (checkCurrency) {
    failures.addAll(pixaDartDependencyCurrencyFailures(outdated));
  }
  final List<Object?> packages = outdated['packages']! as List<Object?>;
  for (final Object? package in packages) {
    final Map<String, Object?> typed = package! as Map<String, Object?>;
    final String name = typed['package']! as String;
    final String kind = typed['kind']! as String;
    if (typed['isCurrentAffectedByAdvisory'] == true) {
      failures.add('dart dependency audit: $name is affected by an advisory');
    }
    if (typed['isCurrentRetracted'] == true) {
      failures.add('dart dependency audit: $name is using a retracted version');
    }
    if (_isDirectDartDependency(kind) && typed['isDiscontinued'] == true) {
      failures.add(
        'dart dependency audit: direct dependency $name is discontinued',
      );
    }
  }
}

/// Returns release failures for dependencies with a compatible Dart upgrade.
List<String> pixaDartDependencyCurrencyFailures(Map<String, Object?> outdated) {
  final Object? rawPackages = outdated['packages'];
  if (rawPackages is! List<Object?>) {
    return <String>['dart dependency currency: invalid outdated output'];
  }
  final List<String> failures = <String>[];
  for (final Object? rawPackage in rawPackages) {
    if (rawPackage is! Map<String, Object?>) {
      failures.add('dart dependency currency: invalid package entry');
      continue;
    }
    final String name = rawPackage['package']?.toString() ?? 'unknown';
    final Object? rawCurrent = rawPackage['current'];
    final Object? rawUpgradable = rawPackage['upgradable'];
    if (rawCurrent is! Map<String, Object?> ||
        rawUpgradable is! Map<String, Object?>) {
      failures.add('dart dependency currency: $name has incomplete versions');
      continue;
    }
    final String? current = rawCurrent['version']?.toString();
    final String? upgradable = rawUpgradable['version']?.toString();
    if (current == null || upgradable == null) {
      failures.add('dart dependency currency: $name has incomplete versions');
    } else if (current != upgradable) {
      failures.add(
        'dart dependency currency: compatible update available for '
        '$name $current -> $upgradable',
      );
    }
  }
  return failures;
}

void _checkRustDependencyCurrency(Directory root, List<String> failures) {
  final ProcessResult result = Process.runSync('cargo', <String>[
    'update',
    '--manifest-path',
    _rustManifestPath,
    '--dry-run',
  ], workingDirectory: root.path);
  if (result.exitCode != 0) {
    failures.add('rust dependency currency: cargo update --dry-run failed');
    return;
  }
  final String output = '${result.stdout}\n${result.stderr}';
  final RegExp lockCount = RegExp(r'Locking\s+\d+\s+packages?');
  if (!lockCount.hasMatch(output)) {
    failures.add('rust dependency currency: unable to parse Cargo dry-run');
  } else if (pixaCargoUpdateDryRunHasCompatibleUpdates(output)) {
    failures.add(
      'rust dependency currency: Cargo.lock has compatible updates; '
      'run cargo update --manifest-path '
      '$_rustManifestPath',
    );
  }
}

/// Whether Cargo's update dry-run reports compatible lockfile changes.
bool pixaCargoUpdateDryRunHasCompatibleUpdates(String output) {
  final RegExpMatch? match = RegExp(
    r'Locking\s+(\d+)\s+packages?',
  ).firstMatch(output);
  return match != null && int.parse(match.group(1)!) > 0;
}

bool _isDirectDartDependency(String kind) {
  return kind == 'direct' || kind == 'dev' || kind == 'direct dev';
}

String _relative(Directory root, File file) {
  final String rootPath = root.path.replaceAll(r'\', '/');
  final String filePath = file.path.replaceAll(r'\', '/');
  final String prefix = '$rootPath/';
  return filePath.startsWith(prefix)
      ? filePath.substring(prefix.length)
      : filePath;
}
