import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final _Options options = _Options.parse(args);
  final List<_Report> reports = _readReports(options.reportsPath);
  final List<String> failures = <String>[];
  for (final String platform in options.requiredPlatforms) {
    final List<_Report> candidates = _passingReports(reports, platform);
    if (candidates.isEmpty) {
      failures.add('missing passing platform self-check for $platform');
      continue;
    }
    final _Report? accepted = _firstAcceptableReport(
      candidates,
      platform,
      requiredRunMode: options.requiredRunMode,
    );
    if (accepted != null) {
      for (final _RequiredNativeModule module
          in options.requiredNativeModules) {
        final _Report? nativeModuleReport = _firstAcceptableNativeModuleReport(
          candidates,
          platform,
          module,
          requiredRunMode: options.requiredRunMode,
        );
        if (nativeModuleReport != null) {
          continue;
        }
        failures.addAll(
          _nativeModuleReportFailures(
            candidates,
            platform,
            module,
            requiredRunMode: options.requiredRunMode,
          ),
        );
      }
      if (options.requireExampleSmoke) {
        final _Report? exampleReport = _firstAcceptableExampleReport(
          reports,
          platform,
          requiredRunMode: options.requiredRunMode,
        );
        if (exampleReport == null) {
          failures.addAll(
            _exampleReportFailures(
              reports,
              platform,
              requiredRunMode: options.requiredRunMode,
            ),
          );
        }
      }
      continue;
    }
    failures.addAll(
      _reportFailures(
        candidates.first,
        platform,
        requiredRunMode: options.requiredRunMode,
      ),
    );
  }
  if (failures.isNotEmpty) {
    stderr.writeln('Pixa platform evidence is incomplete:');
    for (final String failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Pixa platform evidence passed for '
    '${options.requiredPlatforms.join(', ')}.',
  );
}

const Set<String> _requiredChecks = <String>{
  'runtimeLibraryLoad',
  'symbolResolution',
  'threadedRuntime',
  'cacheDirectory',
  'networkPolicy',
  'runtimePipelineLoad',
  'cacheDirectoryReadWrite',
  'networkLoopbackFetch',
  'abiArchitecture',
};

const Set<String> _requiredNativeModuleChecks = <String>{
  'manifestEntrypoint',
  'nativeLink',
  'processorRoute',
  'runtimeCapability',
};

const Set<String> _requiredExampleSmokeChecks = <String>{
  'runtimePlatformSelfCheck',
  'runtimePipelineLoad',
  'appLaunch',
  'layoutControls',
  'loopbackImageRequest',
  'largeViewerRoute',
  'cacheStats',
};

const _RequiredNativeModule _jpegTurboRoiModule = _RequiredNativeModule(
  aliases: <String>{
    'jpeg-turbo-roi',
    'jpeg_turbo_roi',
    'jpeg-turbo',
    'jpeg_turbo',
  },
  label: 'JPEG Turbo ROI',
  moduleId: 'pixa.processor.jpeg_turbo',
  entrypointSymbol: 'pixa_jpeg_turbo_processor_plugin_init',
  processorOperation: 'tile:jpeg',
);

const _RequiredNativeModule _webpRoiModule = _RequiredNativeModule(
  aliases: <String>{
    'webp-roi',
    'webp_roi',
    'webp-native-roi',
    'webp_native_roi',
  },
  label: 'WebP ROI',
  moduleId: 'pixa.processor.webp',
  entrypointSymbol: 'pixa_webp_processor_plugin_init',
  processorOperation: 'tile:webp',
);

const List<_RequiredNativeModule> _knownNativeModules = <_RequiredNativeModule>[
  _jpegTurboRoiModule,
  _webpRoiModule,
];

final class _Options {
  const _Options({
    required this.reportsPath,
    required this.requiredPlatforms,
    required this.requiredRunMode,
    required this.requiredNativeModules,
    required this.requireExampleSmoke,
  });

  final String reportsPath;
  final List<String> requiredPlatforms;
  final String? requiredRunMode;
  final List<_RequiredNativeModule> requiredNativeModules;
  final bool requireExampleSmoke;

  factory _Options.parse(List<String> args) {
    var reportsPath = 'build/reports';
    var requiredPlatforms = const <String>[
      'android',
      'ios',
      'linux',
      'macos',
      'windows',
    ];
    String? requiredRunMode;
    var requiredNativeModules = const <_RequiredNativeModule>[];
    var requireExampleSmoke = false;
    for (final String arg in args) {
      if (arg.startsWith('--reports=')) {
        reportsPath = arg.substring('--reports='.length).trim();
      } else if (arg.startsWith('--require-platforms=')) {
        requiredPlatforms = arg
            .substring('--require-platforms='.length)
            .split(',')
            .map((String value) => _normalizePlatform(value.trim()))
            .where((String value) => value.isNotEmpty)
            .toList(growable: false);
      } else if (arg.startsWith('--require-run-mode=')) {
        requiredRunMode = _string(
          arg.substring('--require-run-mode='.length).trim(),
        );
      } else if (arg.startsWith('--require-native-modules=')) {
        requiredNativeModules = arg
            .substring('--require-native-modules='.length)
            .split(',')
            .map((String value) => _requiredNativeModule(value.trim()))
            .whereType<_RequiredNativeModule>()
            .toList(growable: false);
      } else if (arg == '--require-example-smoke') {
        requireExampleSmoke = true;
      } else {
        throw ArgumentError('Unknown platform evidence argument: $arg');
      }
    }
    if (reportsPath.isEmpty || requiredPlatforms.isEmpty) {
      throw ArgumentError(
        'reports path and required platforms must be non-empty',
      );
    }
    if (requiredRunMode != null && requiredRunMode.isEmpty) {
      throw ArgumentError('required run mode must be non-empty');
    }
    for (final String platform in requiredPlatforms) {
      if (!_supportedPlatforms.contains(platform)) {
        throw ArgumentError('Unsupported required platform: $platform');
      }
    }
    return _Options(
      reportsPath: reportsPath,
      requiredPlatforms: List<String>.unmodifiable(requiredPlatforms),
      requiredRunMode: requiredRunMode,
      requiredNativeModules: List<_RequiredNativeModule>.unmodifiable(
        requiredNativeModules,
      ),
      requireExampleSmoke: requireExampleSmoke,
    );
  }
}

final class _Report {
  const _Report({
    required this.path,
    required this.platform,
    required this.passed,
    required this.passedChecks,
    required this.evidence,
    required this.nativeModules,
    required this.hasSelfCheck,
    required this.exampleSmokePassed,
    required this.exampleSmokeChecks,
  });

  final String path;
  final String platform;
  final bool passed;
  final Set<String> passedChecks;
  final Map<String, Object?> evidence;
  final List<_NativeModuleReport> nativeModules;
  final bool hasSelfCheck;
  final bool exampleSmokePassed;
  final Set<String> exampleSmokeChecks;
}

final class _NativeModuleReport {
  const _NativeModuleReport({
    required this.path,
    required this.platform,
    required this.moduleId,
    required this.entrypointSymbol,
    required this.processorOperations,
    required this.passed,
    required this.passedChecks,
  });

  final String path;
  final String? platform;
  final String moduleId;
  final String? entrypointSymbol;
  final Set<String> processorOperations;
  final bool passed;
  final Set<String> passedChecks;
}

final class _RequiredNativeModule {
  const _RequiredNativeModule({
    required this.aliases,
    required this.label,
    required this.moduleId,
    required this.entrypointSymbol,
    required this.processorOperation,
  });

  final Set<String> aliases;
  final String label;
  final String moduleId;
  final String entrypointSymbol;
  final String processorOperation;
}

List<_Report> _readReports(String reportsPath) {
  final Directory directory = Directory(reportsPath);
  if (!directory.existsSync()) {
    throw StateError(
      'Platform evidence directory does not exist: $reportsPath',
    );
  }
  final List<_Report> reports = <_Report>[];
  for (final FileSystemEntity entity in directory.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.json')) {
      continue;
    }
    final Object? decoded = jsonDecode(entity.readAsStringSync());
    if (decoded is! Map<String, Object?> ||
        !decoded.containsKey('selfCheck') &&
            !decoded.containsKey('exampleSmoke')) {
      continue;
    }
    reports.add(_parseReport(entity.path, decoded));
  }
  if (reports.isEmpty) {
    throw StateError('No platform evidence JSON reports found in $reportsPath');
  }
  return reports;
}

_Report _parseReport(String path, Map<String, Object?> json) {
  final Map<String, Object?>? selfCheck = json['selfCheck'] is Map
      ? _object(json['selfCheck'], '$path:selfCheck')
      : null;
  final Map<String, Object?> evidence = json['evidence'] is Map
      ? _object(json['evidence'], '$path:evidence')
      : const <String, Object?>{};
  final Map<String, Object?>? exampleSmoke = json['exampleSmoke'] is Map
      ? _object(json['exampleSmoke'], '$path:exampleSmoke')
      : null;
  final String platform = _normalizePlatform(
    _string(evidence['platform']) ??
        _string(selfCheck?['platform']) ??
        _string(exampleSmoke?['platform']) ??
        '',
  );
  final List<Object?> checks = selfCheck?['checks'] is List
      ? _list(selfCheck!['checks'], '$path:selfCheck.checks')
      : const <Object?>[];
  final Set<String> passedChecks = _passedCheckNames(
    checks,
    '$path:selfCheck.checks[]',
  );
  final List<Object?> exampleChecks = exampleSmoke?['checks'] is List
      ? _list(exampleSmoke!['checks'], '$path:exampleSmoke.checks')
      : const <Object?>[];
  return _Report(
    path: path,
    platform: platform,
    passed: selfCheck?['passed'] == true,
    passedChecks: passedChecks,
    evidence: evidence,
    nativeModules: _parseNativeModuleReports(path, json, evidence),
    hasSelfCheck: selfCheck != null,
    exampleSmokePassed: exampleSmoke?['passed'] == true,
    exampleSmokeChecks: _passedCheckNames(
      exampleChecks,
      '$path:exampleSmoke.checks[]',
    ),
  );
}

Set<String> _passedCheckNames(List<Object?> checks, String label) {
  final Set<String> passedChecks = <String>{};
  for (final Object? check in checks) {
    if (check is! Map) {
      continue;
    }
    final Map<String, Object?> typed = _object(check, label);
    if (typed['passed'] != true) {
      continue;
    }
    final String? name = _nonEmptyString(typed['name']);
    if (name != null) {
      passedChecks.add(name);
    }
  }
  return Set<String>.unmodifiable(passedChecks);
}

List<_NativeModuleReport> _parseNativeModuleReports(
  String path,
  Map<String, Object?> json,
  Map<String, Object?> evidence,
) {
  final Object? rawNativeModules =
      json['nativeModules'] ?? evidence['nativeModules'];
  if (rawNativeModules == null) {
    return const <_NativeModuleReport>[];
  }
  final List<Object?> nativeModules = _list(
    rawNativeModules,
    '$path:nativeModules',
  );
  return <_NativeModuleReport>[
    for (final Object? nativeModule in nativeModules)
      _parseNativeModuleReport(
        path,
        _object(nativeModule, '$path:nativeModules[]'),
      ),
  ];
}

_NativeModuleReport _parseNativeModuleReport(
  String path,
  Map<String, Object?> json,
) {
  final Set<String> passedChecks = <String>{};
  final Object? rawChecks = json['checks'];
  if (rawChecks is List) {
    for (final Object? check in _list(
      rawChecks,
      '$path:nativeModules.checks',
    )) {
      if (check is! Map) {
        continue;
      }
      final Map<String, Object?> typed = _object(
        check,
        '$path:nativeModules.checks[]',
      );
      if (typed['passed'] != true) {
        continue;
      }
      final String? name = _nonEmptyString(typed['name']);
      if (name != null) {
        passedChecks.add(name);
      }
    }
  } else if (rawChecks is Map) {
    final Map<String, Object?> typed = _object(
      rawChecks,
      '$path:nativeModules.checks',
    );
    for (final MapEntry<String, Object?> entry in typed.entries) {
      if (entry.value == true) {
        passedChecks.add(entry.key);
      }
    }
  }

  final Object? rawOperations =
      json['processorOperations'] ?? json['processorOperation'];
  final Set<String> processorOperations = <String>{};
  if (rawOperations is String) {
    processorOperations.add(rawOperations.trim().toLowerCase());
  } else if (rawOperations is List) {
    for (final Object? operation in rawOperations) {
      final String? value = _string(operation);
      if (value != null) {
        processorOperations.add(value);
      }
    }
  }

  return _NativeModuleReport(
    path: path,
    platform: _string(json['platform']),
    moduleId: _nonEmptyString(json['moduleId']) ?? '',
    entrypointSymbol: _nonEmptyString(json['entrypointSymbol']),
    processorOperations: Set<String>.unmodifiable(processorOperations),
    passed: json['passed'] == true,
    passedChecks: Set<String>.unmodifiable(passedChecks),
  );
}

List<_Report> _passingReports(List<_Report> reports, String platform) {
  return reports
      .where(
        (_Report report) =>
            report.platform == platform && report.hasSelfCheck && report.passed,
      )
      .toList(growable: false);
}

_Report? _firstAcceptableReport(
  List<_Report> reports,
  String platform, {
  required String? requiredRunMode,
}) {
  for (final _Report report in reports) {
    if (_reportFailures(
      report,
      platform,
      requiredRunMode: requiredRunMode,
    ).isEmpty) {
      return report;
    }
  }
  return null;
}

_Report? _firstAcceptableNativeModuleReport(
  List<_Report> reports,
  String platform,
  _RequiredNativeModule requiredModule, {
  required String? requiredRunMode,
}) {
  for (final _Report report in reports) {
    if (_reportFailures(
      report,
      platform,
      requiredRunMode: requiredRunMode,
    ).isNotEmpty) {
      continue;
    }
    final _NativeModuleReport? nativeModule = _matchingNativeModule(
      report,
      requiredModule,
    );
    if (nativeModule == null) {
      continue;
    }
    if (_nativeModuleFailures(nativeModule, platform, requiredModule).isEmpty) {
      return report;
    }
  }
  return null;
}

List<String> _reportFailures(
  _Report report,
  String platform, {
  required String? requiredRunMode,
}) {
  final List<String> failures = <String>[];
  final List<String> missingChecks = _requiredChecks
      .where((String check) => !report.passedChecks.contains(check))
      .toList(growable: false);
  if (missingChecks.isNotEmpty) {
    failures.add(
      '$platform is missing required checks: ${missingChecks.join(', ')}',
    );
  }
  if (requiredRunMode != null) {
    final String runMode = _string(report.evidence['runMode']) ?? 'unknown';
    if (runMode != requiredRunMode) {
      failures.add(
        '$platform evidence ${report.path} has runMode $runMode, '
        'expected $requiredRunMode',
      );
    }
  }
  return failures;
}

List<String> _nativeModuleReportFailures(
  List<_Report> reports,
  String platform,
  _RequiredNativeModule requiredModule, {
  required String? requiredRunMode,
}) {
  for (final _Report report in reports) {
    if (_reportFailures(
      report,
      platform,
      requiredRunMode: requiredRunMode,
    ).isNotEmpty) {
      continue;
    }
    final _NativeModuleReport? nativeModule = _matchingNativeModule(
      report,
      requiredModule,
    );
    if (nativeModule == null) {
      continue;
    }
    return _nativeModuleFailures(nativeModule, platform, requiredModule);
  }
  return <String>[
    '$platform is missing native module evidence for '
        '${requiredModule.label} (${requiredModule.moduleId})',
  ];
}

_NativeModuleReport? _matchingNativeModule(
  _Report report,
  _RequiredNativeModule requiredModule,
) {
  for (final _NativeModuleReport nativeModule in report.nativeModules) {
    final String moduleId = nativeModule.moduleId.trim().toLowerCase();
    if (moduleId == requiredModule.moduleId ||
        requiredModule.aliases.contains(moduleId)) {
      return nativeModule;
    }
  }
  return null;
}

List<String> _nativeModuleFailures(
  _NativeModuleReport nativeModule,
  String platform,
  _RequiredNativeModule requiredModule,
) {
  final List<String> failures = <String>[];
  if (!nativeModule.passed) {
    failures.add(
      '$platform native module ${requiredModule.moduleId} did not pass',
    );
  }
  if (nativeModule.platform != null && nativeModule.platform != platform) {
    failures.add(
      '$platform native module ${requiredModule.moduleId} reports platform '
      '${nativeModule.platform}',
    );
  }
  if (nativeModule.entrypointSymbol != requiredModule.entrypointSymbol) {
    failures.add(
      '$platform native module ${requiredModule.moduleId} has entrypoint '
      '${nativeModule.entrypointSymbol ?? 'missing'}, expected '
      '${requiredModule.entrypointSymbol}',
    );
  }
  if (!nativeModule.processorOperations.contains(
    requiredModule.processorOperation,
  )) {
    failures.add(
      '$platform native module ${requiredModule.moduleId} does not claim '
      '${requiredModule.processorOperation}',
    );
  }
  final List<String> missingChecks = _requiredNativeModuleChecks
      .where((String check) => !nativeModule.passedChecks.contains(check))
      .toList(growable: false);
  if (missingChecks.isNotEmpty) {
    failures.add(
      '$platform native module ${requiredModule.moduleId} is missing checks: '
      '${missingChecks.join(', ')}',
    );
  }
  return failures;
}

_Report? _firstAcceptableExampleReport(
  List<_Report> reports,
  String platform, {
  required String? requiredRunMode,
}) {
  for (final _Report report in reports.where(
    (_Report report) => report.platform == platform,
  )) {
    if (_exampleReportFailuresForOne(
      report,
      platform,
      requiredRunMode: requiredRunMode,
    ).isEmpty) {
      return report;
    }
  }
  return null;
}

List<String> _exampleReportFailures(
  List<_Report> reports,
  String platform, {
  required String? requiredRunMode,
}) {
  final List<_Report> candidates = reports
      .where((_Report report) => report.platform == platform)
      .toList(growable: false);
  for (final _Report report in candidates) {
    final List<String> failures = _exampleReportFailuresForOne(
      report,
      platform,
      requiredRunMode: requiredRunMode,
    );
    if (!failures.contains('$platform is missing example smoke evidence')) {
      return failures;
    }
  }
  return <String>['$platform is missing example smoke evidence'];
}

List<String> _exampleReportFailuresForOne(
  _Report report,
  String platform, {
  required String? requiredRunMode,
}) {
  final List<String> failures = <String>[];
  if (!report.exampleSmokePassed && report.exampleSmokeChecks.isEmpty) {
    failures.add('$platform is missing example smoke evidence');
    return failures;
  }
  if (!report.exampleSmokePassed) {
    failures.add('$platform example smoke ${report.path} did not pass');
  }
  final List<String> missingChecks = _requiredExampleSmokeChecks
      .where((String check) => !report.exampleSmokeChecks.contains(check))
      .toList(growable: false);
  if (missingChecks.isNotEmpty) {
    failures.add(
      '$platform example smoke is missing required checks: '
      '${missingChecks.join(', ')}',
    );
  }
  if (requiredRunMode != null) {
    final String runMode = _string(report.evidence['runMode']) ?? 'unknown';
    if (runMode != requiredRunMode) {
      failures.add(
        '$platform example smoke ${report.path} has runMode $runMode, '
        'expected $requiredRunMode',
      );
    }
  }
  return failures;
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is Map) {
    final Map<String, Object?> typed = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry
        in value.entries.cast<MapEntry<Object?, Object?>>()) {
      final Object? key = entry.key;
      if (key is! String) {
        throw FormatException('Expected string JSON object key at $label.');
      }
      typed[key] = entry.value;
    }
    return typed;
  }
  throw FormatException('Expected JSON object at $label.');
}

List<Object?> _list(Object? value, String label) {
  if (value is List) {
    return List<Object?>.unmodifiable(value.cast<Object?>());
  }
  throw FormatException('Expected JSON list at $label.');
}

String? _string(Object? value) {
  return value is String && value.trim().isNotEmpty
      ? value.trim().toLowerCase()
      : null;
}

String? _nonEmptyString(Object? value) {
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

_RequiredNativeModule? _requiredNativeModule(String value) {
  if (value.isEmpty) {
    return null;
  }
  final String normalized = value.trim().toLowerCase();
  for (final _RequiredNativeModule module in _knownNativeModules) {
    if (normalized == module.moduleId || module.aliases.contains(normalized)) {
      return module;
    }
  }
  throw ArgumentError('Unsupported required native module: $value');
}

String _normalizePlatform(String value) {
  final String normalized = value.trim().toLowerCase();
  return switch (normalized) {
    'macos' || 'mac os' || 'macosx' || 'macos-x64' || 'macos-arm64' => 'macos',
    'ios' || 'iphoneos' || 'iphonesimulator' => 'ios',
    _ => normalized,
  };
}

const Set<String> _supportedPlatforms = <String>{
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
};

const String _usage = '''
Usage: dart run tool/pixa_platform_evidence.dart [options]

Validates JSON reports written by pixa_platform_self_check.dart or
pixa_platform_build.dart --run-self-check.

Options:
  --reports=<path>               Report directory. Defaults to build/reports.
  --require-platforms=<list>     Comma-separated platforms. Defaults to all five.
  --require-run-mode=<mode>      Require evidence runMode, e.g. integration-test.
  --require-native-modules=<list>
                                Comma-separated optional native module evidence.
                                Supported: jpeg-turbo-roi, webp-roi.
  --require-example-smoke        Require real pixa_gallery example smoke evidence.
  --help                         Show this message.
''';
