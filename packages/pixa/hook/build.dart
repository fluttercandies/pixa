import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'plugin_plan.dart';

Future<void> main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    if (input.config.code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError(
        'Pixa runtime core currently requires dynamic loading.',
      );
    }

    final Uri coreManifest = input.packageRoot.resolve(
      'plugins/pixa_plugins.json',
    );
    final List<Uri> officialOptionalManifests = _officialOptionalManifests(
      input,
    );
    final PixaRuntimePluginBuildPlan pluginPlan =
        PixaRuntimePluginBuildPlan.load(
          coreManifest: coreManifest,
          additionalManifests: officialOptionalManifests,
          userManifest: input.userDefines.path('plugin_manifest'),
          userManifestDirectory: input.userDefines.path(
            'plugin_manifest_directory',
          ),
        );
    final Uri pluginPlanOutput = input.outputDirectory.resolve(
      'pixa_plugin_plan.json',
    );
    await File.fromUri(
      pluginPlanOutput,
    ).writeAsString(pluginPlan.toPrettyJson());

    final Uri rustWorkspace = input.packageRoot.resolve('../../rust/');
    final String? targetTriple = _rustTarget(input.config.code);
    final Set<String> cargoFeatures = _cargoFeatures(pluginPlan);
    final List<String> command = <String>[
      'build',
      '--release',
      '-p',
      'pixa_runtime',
      if (cargoFeatures.isNotEmpty) ...<String>[
        '--features',
        cargoFeatures.join(','),
      ],
      if (targetTriple != null) ...<String>['--target', targetTriple],
    ];
    final Map<String, String> environment = Map<String, String>.of(
      Platform.environment,
    );
    environment['PIXA_PLUGIN_PLAN'] = pluginPlanOutput.toFilePath();
    _configureRustToolchainEnvironment(environment);
    _configureNativeRoiEnvironment(
      environment,
      pluginPlan,
      targetTriple: targetTriple,
      outputDirectory: input.outputDirectory,
    );
    _configureAppleCompileEnvironment(
      environment,
      input.config.code,
      targetTriple,
    );
    _configureCrossCompileEnvironment(environment, targetTriple);
    _configureReleaseLinkingEnvironment(environment, targetTriple);
    _clearStaleTurboJpegCmakeCaches(rustWorkspace, targetTriple, cargoFeatures);
    final String cargo = _cargoExecutable(environment);

    final ProcessResult result = await Process.run(
      cargo,
      command,
      workingDirectory: rustWorkspace.toFilePath(),
      environment: environment,
    );
    if (result.exitCode != 0) {
      _throwRustBuildFailure(
        cargo: cargo,
        command: command,
        rustWorkspace: rustWorkspace,
        outputDirectory: input.outputDirectory,
        environment: environment,
        result: result,
      );
    }

    final String libraryName = _libraryName(input.config.code.targetOS);
    final Uri builtLibrary = rustWorkspace.resolve(
      targetTriple == null
          ? 'target/release/$libraryName'
          : 'target/$targetTriple/release/$libraryName',
    );
    final File builtFile = File.fromUri(builtLibrary);
    if (!builtFile.existsSync()) {
      throw StateError(
        'Rust build completed but $builtLibrary was not produced.',
      );
    }

    final Uri bundledLibrary = input.outputDirectory.resolve(libraryName);
    await builtFile.copy(bundledLibrary.toFilePath());

    output.dependencies.addAll(<Uri>[
      ...pluginPlan.dependencies,
      input.packageRoot.resolve('hook/plugin_link_plan.dart'),
      input.packageRoot.resolve('hook/plugin_plan_helpers.dart'),
      ..._rustBuildInputs(rustWorkspace),
    ]);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'pixa_runtime',
        file: bundledLibrary,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}

Never _throwRustBuildFailure({
  required String cargo,
  required List<String> command,
  required Uri rustWorkspace,
  required Uri outputDirectory,
  required Map<String, String> environment,
  required ProcessResult result,
}) {
  final File logFile = File.fromUri(
    outputDirectory.resolve('pixa_rust_build_failure.log'),
  );
  logFile.parent.createSync(recursive: true);
  final String diagnostic =
      '''
Pixa Rust build failed.
command: $cargo ${command.join(' ')}
workingDirectory: ${rustWorkspace.toFilePath()}
exitCode: ${result.exitCode}
CARGO: ${environment['CARGO'] ?? ''}
RUSTC: ${environment['RUSTC'] ?? ''}
TARGET_PATH: ${environment[Platform.isWindows ? 'Path' : 'PATH'] ?? ''}
TURBOJPEG_SOURCE: ${environment['TURBOJPEG_SOURCE'] ?? ''}
TURBOJPEG_STATIC: ${environment['TURBOJPEG_STATIC'] ?? ''}
stdout:
${result.stdout}
stderr:
${result.stderr}
''';
  logFile.writeAsStringSync(diagnostic);
  stderr.writeln('Pixa Rust build failed. Full log: ${logFile.path}');
  stderr.writeln(_tailText(diagnostic, 24000));
  throw ProcessException(
    cargo,
    command,
    'Rust build failed. Full log: ${logFile.path}',
    result.exitCode,
  );
}

String _tailText(String value, int maxChars) {
  if (value.length <= maxChars) {
    return value;
  }
  return value.substring(value.length - maxChars);
}

Set<String> _cargoFeatures(PixaRuntimePluginBuildPlan pluginPlan) {
  final Set<String> features = <String>{};
  for (final PixaRuntimePluginModulePlan module in pluginPlan.modules) {
    if (module.link.isNotEmpty) {
      continue;
    }
    if (module.entrypointSymbol == 'pixa_jpeg_turbo_processor_plugin_init') {
      features.add('jpeg-turbo-roi');
    } else if (module.entrypointSymbol == 'pixa_webp_processor_plugin_init') {
      features.add('webp-roi');
    }
  }
  return features;
}

void _configureNativeRoiEnvironment(
  Map<String, String> environment,
  PixaRuntimePluginBuildPlan pluginPlan, {
  required String? targetTriple,
  required Uri outputDirectory,
}) {
  final Set<String> features = _cargoFeatures(pluginPlan);
  if (features.contains('jpeg-turbo-roi')) {
    environment['TURBOJPEG_SOURCE'] = 'vendor';
    environment['TURBOJPEG_STATIC'] = '1';
    _configureWindowsNasmEnvironment(environment);
    _configureWindowsTurboJpegCmakeEnvironment(
      environment,
      targetTriple,
      outputDirectory,
    );
  }
}

void _configureWindowsTurboJpegCmakeEnvironment(
  Map<String, String> environment,
  String? targetTriple,
  Uri outputDirectory,
) {
  final String? processor = pixaWindowsTurboJpegCmakeSystemProcessor(
    targetTriple,
  );
  if (processor == null || targetTriple == null) {
    return;
  }
  final File toolchain = File.fromUri(
    outputDirectory.resolve('pixa_windows_turbojpeg_toolchain.cmake'),
  );
  toolchain.parent.createSync(recursive: true);
  toolchain.writeAsStringSync(pixaWindowsTurboJpegCmakeToolchain(processor));
  _setTargetCmakeEnvironment(
    environment,
    targetTriple,
    'CMAKE_TOOLCHAIN_FILE',
    toolchain.path,
  );
}

String? pixaWindowsTurboJpegCmakeSystemProcessor(String? targetTriple) {
  return switch (targetTriple) {
    'x86_64-pc-windows-msvc' => 'AMD64',
    'i686-pc-windows-msvc' => 'X86',
    'aarch64-pc-windows-msvc' => 'ARM64',
    _ => null,
  };
}

String pixaWindowsTurboJpegCmakeToolchain(String processor) {
  return '''
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR "$processor" CACHE STRING "Pixa target processor for libjpeg-turbo" FORCE)
''';
}

void _configureWindowsNasmEnvironment(Map<String, String> environment) {
  if (!Platform.isWindows) {
    return;
  }
  final List<String> roots = <String>[
    if (!_isUnset(environment['ProgramFiles'])) environment['ProgramFiles']!,
    if (!_isUnset(environment['ProgramFiles(x86)']))
      environment['ProgramFiles(x86)']!,
  ];
  final List<String> candidates = <String>[
    for (final String root in roots) '$root\\NASM',
    if (!_isUnset(environment['ChocolateyInstall']))
      '${environment['ChocolateyInstall']}\\bin',
    r'C:\ProgramData\chocolatey\bin',
  ];
  for (final String path in candidates) {
    if (File('$path\\nasm.exe').existsSync()) {
      _prependPath(environment, path);
    }
  }
}

void _clearStaleTurboJpegCmakeCaches(
  Uri rustWorkspace,
  String? targetTriple,
  Set<String> cargoFeatures,
) {
  if (targetTriple == null || !cargoFeatures.contains('jpeg-turbo-roi')) {
    return;
  }
  final Directory buildRoot = Directory.fromUri(
    rustWorkspace.resolve('target/$targetTriple/release/build/'),
  );
  if (!buildRoot.existsSync()) {
    return;
  }
  for (final Directory packageBuild
      in buildRoot.listSync().whereType<Directory>()) {
    if (!_pathBasename(packageBuild.path).startsWith('turbojpeg-sys-')) {
      continue;
    }
    final Directory cmakeBuild = Directory('${packageBuild.path}/out/build');
    final File cache = File('${cmakeBuild.path}/CMakeCache.txt');
    if (!cache.existsSync()) {
      continue;
    }
    String cacheText;
    try {
      cacheText = cache.readAsStringSync();
    } on FileSystemException {
      cacheText = '';
    }
    if (targetTriple.contains('android')) {
      if (cacheText.contains('CMAKE_GENERATOR:INTERNAL=Ninja') &&
          cacheText.contains('android.toolchain.cmake')) {
        continue;
      }
      cmakeBuild.deleteSync(recursive: true);
    } else if (targetTriple.contains('windows-msvc')) {
      if (cacheText.contains('pixa_windows_turbojpeg_toolchain.cmake')) {
        continue;
      }
      cmakeBuild.deleteSync(recursive: true);
    }
  }
}

List<Uri> _officialOptionalManifests(BuildInput input) {
  final bool enableAllNativeRoi = _boolUserDefine(
    input,
    'enable_native_roi',
    defaultValue: false,
  );
  final List<Uri> manifests = <Uri>[];
  if (enableAllNativeRoi ||
      _boolUserDefine(input, 'enable_jpeg_turbo_roi', defaultValue: false)) {
    manifests.add(
      input.packageRoot.resolve(
        'plugins/optional/pixa_jpeg_turbo_processor.json',
      ),
    );
  }
  if (enableAllNativeRoi ||
      _boolUserDefine(input, 'enable_webp_roi', defaultValue: false)) {
    manifests.add(
      input.packageRoot.resolve('plugins/optional/pixa_webp_processor.json'),
    );
  }
  if (_boolUserDefine(input, 'enable_mjpeg_video_frame', defaultValue: false)) {
    manifests.add(
      input.packageRoot.resolve('plugins/optional/pixa_mjpeg_video_frame.json'),
    );
  }
  return List<Uri>.unmodifiable(manifests);
}

bool _boolUserDefine(
  BuildInput input,
  String key, {
  required bool defaultValue,
}) {
  final Object? value = input.userDefines[key];
  if (value == null) {
    return defaultValue;
  }
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      '1' || 'true' || 'yes' || 'on' => true,
      '0' || 'false' || 'no' || 'off' => false,
      _ => throw ArgumentError(
        'hooks.user_defines.pixa.$key must be a boolean-like value.',
      ),
    };
  }
  throw ArgumentError('hooks.user_defines.pixa.$key must be a boolean.');
}

String _cargoExecutable(Map<String, String> environment) {
  final String? configured = environment['CARGO'];
  if (configured != null && configured.trim().isNotEmpty) {
    return configured;
  }
  final String? home = environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final File rustupCargo = File('$home/.cargo/bin/cargo');
    if (rustupCargo.existsSync()) {
      return rustupCargo.path;
    }
  }
  return 'cargo';
}

void _configureRustToolchainEnvironment(Map<String, String> environment) {
  final String? home = environment['HOME'];
  if (home == null || home.isEmpty) {
    return;
  }
  final Directory cargoBin = Directory('$home/.cargo/bin');
  if (!cargoBin.existsSync()) {
    return;
  }
  _prependPath(environment, cargoBin.path);

  final File cargo = File('${cargoBin.path}/cargo');
  if (cargo.existsSync() && _isUnset(environment['CARGO'])) {
    environment['CARGO'] = cargo.path;
  }
  final File rustc = File('${cargoBin.path}/rustc');
  if (rustc.existsSync() && _isUnsetOrBareTool(environment['RUSTC'], 'rustc')) {
    environment['RUSTC'] = rustc.path;
  }
  final File rustdoc = File('${cargoBin.path}/rustdoc');
  if (rustdoc.existsSync() &&
      _isUnsetOrBareTool(environment['RUSTDOC'], 'rustdoc')) {
    environment['RUSTDOC'] = rustdoc.path;
  }
}

bool _isUnset(String? value) {
  return value == null || value.trim().isEmpty;
}

bool _isUnsetOrBareTool(String? value, String toolName) {
  if (_isUnset(value)) {
    return true;
  }
  return value!.trim() == toolName;
}

void _prependPath(Map<String, String> environment, String path) {
  final String key = environment.containsKey('Path') ? 'Path' : 'PATH';
  final String separator = Platform.isWindows ? ';' : ':';
  final List<String> entries = (environment[key] ?? '')
      .split(separator)
      .where((String entry) => entry.isNotEmpty)
      .toList();
  if (entries.contains(path)) {
    entries.remove(path);
  }
  environment[key] = <String>[path, ...entries].join(separator);
}

List<Uri> _rustBuildInputs(Uri rustWorkspace) {
  final Set<Uri> inputs = <Uri>{
    rustWorkspace.resolve('Cargo.toml'),
    rustWorkspace.resolve('Cargo.lock'),
    rustWorkspace.resolve('pixa_core/Cargo.toml'),
    rustWorkspace.resolve('pixa_runtime/Cargo.toml'),
    rustWorkspace.resolve('pixa_runtime/build.rs'),
    rustWorkspace.resolve('pixa_runtime/build_json.rs'),
    rustWorkspace.resolve('pixa_runtime/build_render.rs'),
  };
  for (final String sourceDir in <String>[
    'pixa_core/src/',
    'pixa_runtime/src/',
  ]) {
    final Directory directory = Directory.fromUri(
      rustWorkspace.resolve(sourceDir),
    );
    if (!directory.existsSync()) {
      continue;
    }
    for (final FileSystemEntity entity in directory.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.rs')) {
        inputs.add(entity.uri);
      }
    }
  }
  return inputs.toList()..sort(
    (Uri left, Uri right) => left.toString().compareTo(right.toString()),
  );
}

String _libraryName(OS os) {
  return switch (os) {
    OS.android || OS.linux => 'libpixa_runtime.so',
    OS.iOS || OS.macOS => 'libpixa_runtime.dylib',
    OS.windows => 'pixa_runtime.dll',
    _ => throw UnsupportedError('Unsupported Pixa platform target OS: $os'),
  };
}

String? _rustTarget(CodeConfig codeConfig) {
  final OS os = codeConfig.targetOS;
  final Architecture architecture = codeConfig.targetArchitecture;
  return switch ((os, architecture)) {
    (OS.android, Architecture.arm64) => 'aarch64-linux-android',
    (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
    (OS.android, Architecture.x64) => 'x86_64-linux-android',
    (OS.android, Architecture.ia32) => 'i686-linux-android',
    (OS.iOS, Architecture.arm64) =>
      _isIOSSimulator(codeConfig)
          ? 'aarch64-apple-ios-sim'
          : 'aarch64-apple-ios',
    (OS.iOS, Architecture.x64) =>
      _isIOSSimulator(codeConfig) ? 'x86_64-apple-ios' : null,
    (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
    (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
    (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
    (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
    (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
    (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
    _ => null,
  };
}

bool _isIOSSimulator(CodeConfig codeConfig) {
  return codeConfig.targetOS == OS.iOS &&
      codeConfig.iOS.targetSdk.type == IOSSdk.iPhoneSimulator.type;
}

void _configureAppleCompileEnvironment(
  Map<String, String> environment,
  CodeConfig codeConfig,
  String? targetTriple,
) {
  if (targetTriple == null || !targetTriple.contains('apple')) {
    return;
  }
  final String sdk;
  if (codeConfig.targetOS == OS.iOS) {
    sdk = codeConfig.iOS.targetSdk.type;
  } else if (codeConfig.targetOS == OS.macOS) {
    sdk = 'macosx';
  } else {
    return;
  }
  final String sdkRoot = _xcrun(<String>['--sdk', sdk, '--show-sdk-path']);
  final String clang = _xcrun(<String>['--sdk', sdk, '--find', 'clang']);
  final String ar = _xcrun(<String>['--sdk', sdk, '--find', 'ar']);
  final String targetEnv = targetTriple.toUpperCase().replaceAll('-', '_');
  environment['SDKROOT'] = sdkRoot;
  environment['CARGO_TARGET_${targetEnv}_LINKER'] = clang;
  environment['CARGO_TARGET_${targetEnv}_AR'] = ar;
  _setTargetToolEnvironment(environment, 'CC', targetTriple, clang);
  _setTargetToolEnvironment(environment, 'AR', targetTriple, ar);
  _setTargetFlagsEnvironment(environment, 'CFLAGS', targetTriple, <String>[
    '-isysroot',
    sdkRoot,
  ]);
  if (codeConfig.targetOS == OS.macOS) {
    environment.putIfAbsent(
      'MACOSX_DEPLOYMENT_TARGET',
      () => '${codeConfig.macOS.targetVersion}.0',
    );
  } else if (codeConfig.targetOS == OS.iOS) {
    environment.putIfAbsent(
      'IPHONEOS_DEPLOYMENT_TARGET',
      () => '${codeConfig.iOS.targetVersion}.0',
    );
  }
}

void _configureCrossCompileEnvironment(
  Map<String, String> environment,
  String? targetTriple,
) {
  if (targetTriple == null || !targetTriple.contains('android')) {
    return;
  }
  final String ndkPath = _androidNdkPath(environment);
  final String hostTag = _androidNdkHostTag(ndkPath);
  final String targetEnv = targetTriple.toUpperCase().replaceAll('-', '_');
  final String clang = switch (targetTriple) {
    'aarch64-linux-android' => 'aarch64-linux-android21-clang',
    'armv7-linux-androideabi' => 'armv7a-linux-androideabi21-clang',
    'x86_64-linux-android' => 'x86_64-linux-android21-clang',
    'i686-linux-android' => 'i686-linux-android21-clang',
    _ => throw UnsupportedError(
      'Unsupported Android Rust target $targetTriple',
    ),
  };
  final String clangxx = '$clang++';
  final String extension = Platform.isWindows ? '.cmd' : '';
  final File linker = File(
    '$ndkPath/toolchains/llvm/prebuilt/$hostTag/bin/$clang$extension',
  );
  if (!linker.existsSync()) {
    throw StateError('Android NDK linker not found: ${linker.path}');
  }
  final File cxx = File(
    '$ndkPath/toolchains/llvm/prebuilt/$hostTag/bin/$clangxx$extension',
  );
  if (!cxx.existsSync()) {
    throw StateError('Android NDK C++ linker not found: ${cxx.path}');
  }
  final File ar = File(
    '$ndkPath/toolchains/llvm/prebuilt/$hostTag/bin/llvm-ar$extension',
  );
  if (!ar.existsSync()) {
    throw StateError('Android NDK llvm-ar not found: ${ar.path}');
  }
  environment['CARGO_TARGET_${targetEnv}_LINKER'] = linker.path;
  environment['CARGO_TARGET_${targetEnv}_AR'] = ar.path;
  _setTargetToolEnvironment(environment, 'CC', targetTriple, linker.path);
  _setTargetToolEnvironment(environment, 'CXX', targetTriple, cxx.path);
  _setTargetToolEnvironment(environment, 'AR', targetTriple, ar.path);
  _configureAndroidCmakeEnvironment(environment, ndkPath, targetTriple);
}

void _configureReleaseLinkingEnvironment(
  Map<String, String> environment,
  String? targetTriple,
) {
  if (targetTriple == null) {
    return;
  }
  final List<String> codegenOptions = switch (targetTriple) {
    final String target when target.contains('apple') => <String>[
      'link-arg=-Wl,-dead_strip',
    ],
    final String target
        when target.contains('linux') || target.contains('android') =>
      <String>['link-arg=-Wl,--gc-sections', 'link-arg=-Wl,--as-needed'],
    final String target when target.contains('windows-msvc') => <String>[
      'link-arg=/OPT:REF',
      'link-arg=/OPT:ICF',
    ],
    _ => const <String>[],
  };
  _appendTargetRustCodegenOptions(environment, targetTriple, codegenOptions);
}

void _setTargetToolEnvironment(
  Map<String, String> environment,
  String name,
  String targetTriple,
  String value,
) {
  final String upper = targetTriple.toUpperCase().replaceAll('-', '_');
  final String lowerHyphen = targetTriple.toLowerCase();
  final String lowerUnderscore = lowerHyphen.replaceAll('-', '_');
  environment['${name}_$upper'] = value;
  environment['${name}_$lowerHyphen'] = value;
  environment['${name}_$lowerUnderscore'] = value;
}

void _setTargetFlagsEnvironment(
  Map<String, String> environment,
  String name,
  String targetTriple,
  List<String> flags,
) {
  final String value = flags.join(' ');
  final String upper = targetTriple.toUpperCase().replaceAll('-', '_');
  final String lowerHyphen = targetTriple.toLowerCase();
  final String lowerUnderscore = lowerHyphen.replaceAll('-', '_');
  for (final String key in <String>[
    '${name}_$upper',
    '${name}_$lowerHyphen',
    '${name}_$lowerUnderscore',
  ]) {
    final String? existing = environment[key];
    environment[key] = existing == null || existing.trim().isEmpty
        ? value
        : '$existing $value';
  }
}

void _appendTargetRustCodegenOptions(
  Map<String, String> environment,
  String targetTriple,
  List<String> codegenOptions,
) {
  if (codegenOptions.isEmpty) {
    return;
  }
  final String upper = targetTriple.toUpperCase().replaceAll('-', '_');
  final String key = 'CARGO_TARGET_${upper}_RUSTFLAGS';
  final String existing = environment[key]?.trim() ?? '';
  final List<String> additions = <String>[];
  for (final String option in codegenOptions) {
    if (existing.contains(option)) {
      continue;
    }
    additions.addAll(<String>['-C', option]);
  }
  if (additions.isEmpty) {
    return;
  }
  environment[key] = existing.isEmpty
      ? additions.join(' ')
      : '$existing ${additions.join(' ')}';
}

void _configureAndroidCmakeEnvironment(
  Map<String, String> environment,
  String ndkPath,
  String targetTriple,
) {
  final File toolchain = File('$ndkPath/build/cmake/android.toolchain.cmake');
  if (!toolchain.existsSync()) {
    throw StateError(
      'Android NDK CMake toolchain not found: ${toolchain.path}',
    );
  }
  final Directory cmakeBin = _androidCmakeBin(environment);
  final String extension = Platform.isWindows ? '.exe' : '';
  final File cmake = File('${cmakeBin.path}/cmake$extension');
  if (!cmake.existsSync()) {
    throw StateError('Android SDK CMake executable not found: ${cmake.path}');
  }
  final File ninja = File('${cmakeBin.path}/ninja$extension');
  if (!ninja.existsSync()) {
    throw StateError('Android SDK Ninja executable not found: ${ninja.path}');
  }

  _prependPath(environment, cmakeBin.path);
  _setTargetCmakeEnvironment(environment, targetTriple, 'CMAKE', cmake.path);
  _setTargetCmakeEnvironment(
    environment,
    targetTriple,
    'CMAKE_GENERATOR',
    'Ninja',
  );
  _setTargetCmakeEnvironment(
    environment,
    targetTriple,
    'CMAKE_TOOLCHAIN_FILE',
    toolchain.path,
  );
}

void _setTargetCmakeEnvironment(
  Map<String, String> environment,
  String targetTriple,
  String name,
  String value,
) {
  final String lowerHyphen = targetTriple.toLowerCase();
  final String lowerUnderscore = lowerHyphen.replaceAll('-', '_');
  environment['${name}_$lowerHyphen'] = value;
  environment['${name}_$lowerUnderscore'] = value;
  environment.putIfAbsent('TARGET_$name', () => value);
}

String _xcrun(List<String> arguments) {
  final ProcessResult result = Process.runSync('xcrun', arguments);
  if (result.exitCode != 0) {
    throw StateError('xcrun ${arguments.join(' ')} failed: ${result.stderr}');
  }
  final String output = result.stdout.toString().trim();
  if (output.isEmpty) {
    throw StateError('xcrun ${arguments.join(' ')} returned no output.');
  }
  return output;
}

String _androidNdkPath(Map<String, String> environment) {
  final String? explicit =
      environment['ANDROID_NDK_HOME'] ?? environment['ANDROID_NDK_ROOT'];
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  final String? androidHome =
      environment['ANDROID_HOME'] ?? environment['ANDROID_SDK_ROOT'];
  if (androidHome == null || androidHome.isEmpty) {
    throw StateError('ANDROID_NDK_HOME or ANDROID_HOME must be set.');
  }
  final Directory ndkRoot = Directory('$androidHome/ndk');
  if (!ndkRoot.existsSync()) {
    throw StateError('Android NDK directory not found: ${ndkRoot.path}');
  }
  final List<Directory> versions =
      ndkRoot.listSync().whereType<Directory>().toList()
        ..sort((Directory a, Directory b) => b.path.compareTo(a.path));
  if (versions.isEmpty) {
    throw StateError('No Android NDK versions found in ${ndkRoot.path}.');
  }
  return versions.first.path;
}

Directory _androidCmakeBin(Map<String, String> environment) {
  final String? explicit = environment['ANDROID_CMAKE_BIN'];
  if (explicit != null && explicit.isNotEmpty) {
    final Directory directory = Directory(explicit);
    if (!directory.existsSync()) {
      throw StateError('ANDROID_CMAKE_BIN directory not found: $explicit');
    }
    return directory;
  }
  final String? androidHome =
      environment['ANDROID_HOME'] ?? environment['ANDROID_SDK_ROOT'];
  if (androidHome == null || androidHome.isEmpty) {
    throw StateError('ANDROID_HOME must be set to locate Android SDK CMake.');
  }
  final Directory cmakeRoot = Directory('$androidHome/cmake');
  if (!cmakeRoot.existsSync()) {
    throw StateError(
      'Android SDK CMake directory not found: ${cmakeRoot.path}',
    );
  }
  final List<Directory> versions =
      cmakeRoot.listSync().whereType<Directory>().where((Directory directory) {
        return File('${directory.path}/bin/cmake').existsSync() &&
            File('${directory.path}/bin/ninja').existsSync();
      }).toList()..sort(
        (Directory left, Directory right) => _compareDottedVersions(
          _pathBasename(right.path),
          _pathBasename(left.path),
        ),
      );
  if (versions.isEmpty) {
    throw StateError(
      'No Android SDK CMake install with Ninja found in ${cmakeRoot.path}.',
    );
  }
  return Directory('${versions.first.path}/bin');
}

int _compareDottedVersions(String left, String right) {
  final List<int> leftParts = _versionParts(left);
  final List<int> rightParts = _versionParts(right);
  final int length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    final int leftPart = index < leftParts.length ? leftParts[index] : 0;
    final int rightPart = index < rightParts.length ? rightParts[index] : 0;
    final int compared = leftPart.compareTo(rightPart);
    if (compared != 0) {
      return compared;
    }
  }
  return left.compareTo(right);
}

List<int> _versionParts(String value) {
  return value
      .split('.')
      .map((String part) => int.tryParse(part) ?? 0)
      .toList(growable: false);
}

String _androidNdkHostTag(String ndkPath) {
  final Directory prebuilt = Directory('$ndkPath/toolchains/llvm/prebuilt');
  if (!prebuilt.existsSync()) {
    throw StateError(
      'Android NDK prebuilt directory not found: ${prebuilt.path}',
    );
  }
  final String osPrefix = switch (Platform.operatingSystem) {
    'macos' => 'darwin',
    'linux' => 'linux',
    'windows' => 'windows',
    _ => throw UnsupportedError(
      'Unsupported host OS for Android NDK: ${Platform.operatingSystem}',
    ),
  };
  final List<Directory> hosts = prebuilt
      .listSync()
      .whereType<Directory>()
      .where((Directory directory) {
        return _pathBasename(directory.path).startsWith(osPrefix);
      })
      .toList();
  if (hosts.isEmpty) {
    throw StateError('No Android NDK prebuilt host matching $osPrefix.');
  }
  hosts.sort((Directory a, Directory b) => a.path.compareTo(b.path));
  return _pathBasename(hosts.first.path);
}

String _pathBasename(String path) {
  final String normalized = path.endsWith(Platform.pathSeparator)
      ? path.substring(0, path.length - 1)
      : path;
  final int separator = normalized.lastIndexOf(Platform.pathSeparator);
  return separator == -1 ? normalized : normalized.substring(separator + 1);
}
