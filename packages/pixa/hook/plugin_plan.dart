import 'dart:convert';
import 'dart:io';

part 'plugin_link_plan.dart';
part 'plugin_plan_helpers.dart';

const int pixaPluginManifestSchema = 1;
const int pixaPluginAbiVersion = 1;
const String pixaPluginManifestFileName = 'pixa_plugin.json';

/// Discovers runtime manifests shipped by packages in a resolved app graph.
///
/// Each manifest is bound to the package that owns its root directory so a
/// dependency cannot claim another package's runtime identity.
List<Uri> pixaDiscoverResolvedPluginManifests(Uri packageConfigUri) {
  final File packageConfig = File.fromUri(packageConfigUri);
  if (!packageConfig.existsSync()) {
    throw StateError(
      'Dart package configuration does not exist: ${packageConfig.path}',
    );
  }
  final Object? decoded = json.decode(packageConfig.readAsStringSync());
  if (decoded is! Map<Object?, Object?>) {
    throw StateError('Dart package configuration must be an object.');
  }
  final Object? rawPackages = decoded['packages'];
  if (rawPackages is! List<Object?>) {
    throw StateError('Dart package configuration must contain packages.');
  }

  final List<({String packageName, Uri manifest})> discovered =
      <({String packageName, Uri manifest})>[];
  for (final Object? rawPackage in rawPackages) {
    if (rawPackage is! Map<Object?, Object?>) {
      throw StateError('Dart package configuration entry must be an object.');
    }
    final Object? rawName = rawPackage['name'];
    final Object? rawRoot = rawPackage['rootUri'];
    if (rawName is! String || rawName.trim().isEmpty || rawRoot is! String) {
      throw StateError(
        'Dart package configuration entry requires name and rootUri.',
      );
    }
    final Uri packageRoot = packageConfigUri.resolve(
      rawRoot.endsWith('/') ? rawRoot : '$rawRoot/',
    );
    if (packageRoot.scheme != 'file') {
      continue;
    }
    final Uri manifestUri = packageRoot.resolve(pixaPluginManifestFileName);
    if (!File.fromUri(manifestUri).existsSync()) {
      continue;
    }
    final _PixaRuntimePluginManifestInput manifest = _readManifestInput(
      manifestUri,
    );
    final Object? rawModules = manifest.json['modules'];
    if (rawModules is! List<Object?>) {
      throw StateError(
        'Resolved Pixa manifest from "$rawName" must contain modules.',
      );
    }
    for (final Object? rawModule in rawModules) {
      if (rawModule is! Map<Object?, Object?> ||
          rawModule['packageName'] != rawName) {
        throw StateError(
          'Resolved Pixa manifest from "$rawName" must declare '
          'packageName "$rawName" on every module.',
        );
      }
    }
    discovered.add((packageName: rawName, manifest: manifestUri));
  }
  discovered.sort(
    (
      ({String packageName, Uri manifest}) left,
      ({String packageName, Uri manifest}) right,
    ) => left.packageName.compareTo(right.packageName),
  );
  return List<Uri>.unmodifiable(
    discovered.map(
      (({String packageName, Uri manifest}) entry) => entry.manifest,
    ),
  );
}

final class PixaRuntimePluginBuildPlan {
  const PixaRuntimePluginBuildPlan({
    required this.modules,
    this.dependencies = const <Uri>[],
  });

  factory PixaRuntimePluginBuildPlan.load({
    required Uri coreManifest,
    Iterable<Uri> additionalManifests = const <Uri>[],
    Uri? userManifest,
    Uri? userManifestDirectory,
  }) {
    final List<Uri> additionalManifestUris = additionalManifests.toList(
      growable: false,
    );
    final List<Uri> manifestUris = <Uri>[
      coreManifest,
      ...additionalManifestUris,
    ];
    final List<Uri> dependencyUris = <Uri>[
      coreManifest,
      ...additionalManifestUris,
    ];
    if (userManifest != null) {
      manifestUris.add(userManifest);
      dependencyUris.add(userManifest);
    }
    if (userManifestDirectory != null) {
      dependencyUris.add(userManifestDirectory);
      final Directory directory = Directory.fromUri(userManifestDirectory);
      if (!directory.existsSync()) {
        throw StateError(
          'Pixa runtime plugin manifest directory does not exist: '
          '${directory.path}',
        );
      }
      final List<File> files =
          directory
              .listSync()
              .whereType<File>()
              .where((File file) => file.path.endsWith('.json'))
              .toList()
            ..sort((File a, File b) => a.path.compareTo(b.path));
      final Iterable<Uri> fileUris = files.map((File file) => file.uri);
      manifestUris.addAll(fileUris);
      dependencyUris.addAll(files.map((File file) => file.uri));
    }

    return PixaRuntimePluginBuildPlan._fromManifestInputs(
      manifestUris.map(_readManifestInput),
      dependencies: dependencyUris,
    );
  }

  factory PixaRuntimePluginBuildPlan.fromManifestMaps(
    Iterable<Map<String, Object?>> manifests, {
    Iterable<Uri> dependencies = const <Uri>[],
  }) {
    return PixaRuntimePluginBuildPlan._fromManifestInputs(
      manifests.map((Map<String, Object?> manifest) {
        return _PixaRuntimePluginManifestInput(manifest, baseUri: null);
      }),
      dependencies: dependencies,
    );
  }

  factory PixaRuntimePluginBuildPlan._fromManifestInputs(
    Iterable<_PixaRuntimePluginManifestInput> manifests, {
    Iterable<Uri> dependencies = const <Uri>[],
  }) {
    final Map<String, PixaRuntimePluginModulePlan> modules =
        <String, PixaRuntimePluginModulePlan>{};
    for (final _PixaRuntimePluginManifestInput manifestInput in manifests) {
      final Map<String, Object?> manifest = manifestInput.json;
      final Object? schema = manifest['schema'];
      if (schema != pixaPluginManifestSchema) {
        throw StateError('Unsupported Pixa runtime plugin manifest schema.');
      }
      final Object? rawModules = manifest['modules'];
      if (rawModules is! List<Object?>) {
        throw StateError(
          'Pixa runtime plugin manifest modules must be a list.',
        );
      }
      for (final Object? rawModule in rawModules) {
        if (rawModule is! Map<Object?, Object?>) {
          throw StateError('Pixa runtime plugin module must be an object.');
        }
        final PixaRuntimePluginModulePlan module =
            PixaRuntimePluginModulePlan.fromJson(
              _stringMap(rawModule),
              baseUri: manifestInput.baseUri,
            );
        final PixaRuntimePluginModulePlan? existing = modules[module.moduleId];
        if (existing != null) {
          throw StateError(
            'Duplicate Pixa runtime plugin module "${module.moduleId}" from '
            '${existing.packageName ?? 'unknown package'} and '
            '${module.packageName ?? 'unknown package'}.',
          );
        }
        modules[module.moduleId] = module;
      }
    }
    _validateUniqueRouteClaims(
      modules.values,
      (PixaRuntimePluginModulePlan module) => module.fetcherSourceKinds,
      'fetcher source kind',
    );
    _validateUniqueRouteClaims(
      modules.values,
      (PixaRuntimePluginModulePlan module) => module.decoderMimeTypes,
      'decoder MIME type',
    );
    _validateUniqueRouteClaims(
      modules.values,
      (PixaRuntimePluginModulePlan module) => module.decoderFormatIds,
      'decoder format id',
    );
    _validateUniqueDecoderSignatures(modules.values);
    _validateUniqueRouteClaims(
      modules.values,
      (PixaRuntimePluginModulePlan module) => module.processorOperations,
      'processor operation',
    );
    _validateUniqueRouteClaims(
      modules.values,
      (PixaRuntimePluginModulePlan module) => module.cacheStoreNamespaces,
      'cache store namespace',
    );
    final List<PixaRuntimePluginModulePlan> sortedModules =
        modules.values.toList()..sort(
          (PixaRuntimePluginModulePlan a, PixaRuntimePluginModulePlan b) =>
              a.moduleId.compareTo(b.moduleId),
        );
    return PixaRuntimePluginBuildPlan(
      modules: sortedModules,
      dependencies: List<Uri>.unmodifiable(dependencies),
    );
  }

  final List<PixaRuntimePluginModulePlan> modules;
  final List<Uri> dependencies;

  int get builtInHostModules => modules
      .where(
        (PixaRuntimePluginModulePlan module) =>
            module.deployment == 'builtInHostModule',
      )
      .length;

  int get hostLinkedPluginModules => modules
      .where(
        (PixaRuntimePluginModulePlan module) =>
            module.deployment == 'hostLinkedPluginModule',
      )
      .length;

  int get assetModules => modules
      .where(
        (PixaRuntimePluginModulePlan module) =>
            module.deployment == 'assetModule',
      )
      .length;

  int get linkableModules => modules
      .where(
        (PixaRuntimePluginModulePlan module) => module.canLinkIntoHostBinary,
      )
      .length;

  bool get canUseSingleHostBinary {
    return assetModules == 0 && linkableModules == modules.length;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'schema': pixaPluginManifestSchema,
      'abiVersion': pixaPluginAbiVersion,
      'modules': modules
          .map((PixaRuntimePluginModulePlan module) => module.toJson())
          .toList(growable: false),
      'stats': <String, Object?>{
        'modules': modules.length,
        'builtInHostModules': builtInHostModules,
        'hostLinkedPluginModules': hostLinkedPluginModules,
        'assetModules': assetModules,
        'linkableModules': linkableModules,
        'canUseSingleHostBinary': canUseSingleHostBinary,
      },
    };
  }

  String toPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }
}

void _validateUniqueRouteClaims(
  Iterable<PixaRuntimePluginModulePlan> modules,
  Set<String> Function(PixaRuntimePluginModulePlan module) claimsFor,
  String label,
) {
  final Map<String, String> owners = <String, String>{};
  for (final PixaRuntimePluginModulePlan module in modules) {
    for (final String claim in claimsFor(module)) {
      final String normalized = claim.trim().toLowerCase();
      final String? existing = owners[normalized];
      if (existing != null) {
        throw StateError(
          'Duplicate Pixa runtime plugin $label "$claim" from $existing and '
          '${module.moduleId}.',
        );
      }
      owners[normalized] = module.moduleId;
    }
  }
}

void _validateUniqueDecoderSignatures(
  Iterable<PixaRuntimePluginModulePlan> modules,
) {
  final Map<String, String> owners = <String, String>{};
  for (final PixaRuntimePluginModulePlan module in modules) {
    for (final PixaRuntimeDecoderSignaturePlan signature
        in module.decoderSignatures) {
      final String? existing = owners[signature.routeKey];
      if (existing != null) {
        throw StateError(
          'Duplicate Pixa runtime plugin decoder signature '
          '"${signature.routeKey}" from $existing and ${module.moduleId}.',
        );
      }
      owners[signature.routeKey] = module.moduleId;
    }
  }
}

final class _PixaRuntimePluginManifestInput {
  const _PixaRuntimePluginManifestInput(this.json, {required this.baseUri});

  final Map<String, Object?> json;
  final Uri? baseUri;
}

final class PixaRuntimePluginModulePlan {
  const PixaRuntimePluginModulePlan({
    required this.moduleId,
    required this.deployment,
    required this.abiVersion,
    required this.capabilities,
    this.packageName,
    this.implementationLanguage,
    this.assetId,
    this.entrypointSymbol,
    this.hostManagedRuntime = true,
    this.binaryMessages = true,
    this.ownedBuffers = true,
    this.streamHandles = true,
    this.link = const PixaRuntimePluginLinkPlan.empty(),
    this.fetcherSourceKinds = const <String>{},
    this.videoFrameOutputMimeTypes = const <String>{},
    this.videoFrameNearest = true,
    this.videoFrameExact = false,
    this.decoderFormatIds = const <String>{},
    this.decoderMimeTypes = const <String>{},
    this.decoderSignatures = const <PixaRuntimeDecoderSignaturePlan>[],
    this.decoderCapabilities =
        const PixaRuntimeDecoderCapabilitiesPlan.runtimeRaster(),
    this.processorOperations = const <String>{},
    this.cacheStoreNamespaces = const <String>{},
  });

  factory PixaRuntimePluginModulePlan.fromJson(
    Map<String, Object?> json, {
    Uri? baseUri,
  }) {
    final String moduleId = _requiredString(json, 'moduleId');
    final String deployment = _requiredString(json, 'deployment');
    final int abiVersion =
        _optionalInt(json, 'abiVersion') ?? pixaPluginAbiVersion;
    final Set<String> capabilities = _stringSet(json, 'capabilities');
    final PixaRuntimePluginModulePlan module = PixaRuntimePluginModulePlan(
      moduleId: moduleId,
      deployment: deployment,
      abiVersion: abiVersion,
      capabilities: capabilities,
      packageName: _optionalString(json, 'packageName'),
      implementationLanguage: _optionalString(json, 'implementationLanguage'),
      assetId: _optionalString(json, 'assetId'),
      entrypointSymbol: _optionalString(json, 'entrypointSymbol'),
      hostManagedRuntime: _optionalBool(json, 'hostManagedRuntime') ?? true,
      binaryMessages: _optionalBool(json, 'binaryMessages') ?? true,
      ownedBuffers: _optionalBool(json, 'ownedBuffers') ?? true,
      streamHandles: _optionalBool(json, 'streamHandles') ?? true,
      link: PixaRuntimePluginLinkPlan.fromJson(
        _optionalObjectMap(json, 'link'),
        baseUri: baseUri,
      ),
      fetcherSourceKinds: _optionalStringSet(json, 'fetcherSourceKinds'),
      videoFrameOutputMimeTypes: _optionalStringSet(
        json,
        'videoFrameOutputMimeTypes',
      ),
      videoFrameNearest: _optionalBool(json, 'videoFrameNearest') ?? true,
      videoFrameExact: _optionalBool(json, 'videoFrameExact') ?? false,
      decoderFormatIds: _optionalStringSet(json, 'decoderFormatIds'),
      decoderMimeTypes: _optionalStringSet(json, 'decoderMimeTypes'),
      decoderSignatures: _optionalDecoderSignatures(json),
      decoderCapabilities: PixaRuntimeDecoderCapabilitiesPlan.fromJson(
        _optionalObjectMap(json, 'decoderCapabilities'),
      ),
      processorOperations: _optionalStringSet(json, 'processorOperations'),
      cacheStoreNamespaces: _optionalStringSet(json, 'cacheStoreNamespaces'),
    );
    module.validate();
    return module;
  }

  final String moduleId;
  final String deployment;
  final int abiVersion;
  final Set<String> capabilities;
  final String? packageName;
  final String? implementationLanguage;
  final String? assetId;
  final String? entrypointSymbol;
  final bool hostManagedRuntime;
  final bool binaryMessages;
  final bool ownedBuffers;
  final bool streamHandles;
  final PixaRuntimePluginLinkPlan link;
  final Set<String> fetcherSourceKinds;
  final Set<String> videoFrameOutputMimeTypes;
  final bool videoFrameNearest;
  final bool videoFrameExact;
  final Set<String> decoderFormatIds;
  final Set<String> decoderMimeTypes;
  final List<PixaRuntimeDecoderSignaturePlan> decoderSignatures;
  final PixaRuntimeDecoderCapabilitiesPlan decoderCapabilities;
  final Set<String> processorOperations;
  final Set<String> cacheStoreNamespaces;

  bool get canLinkIntoHostBinary {
    return deployment == 'builtInHostModule' ||
        deployment == 'hostLinkedPluginModule';
  }

  void validate() {
    if (moduleId.trim().isEmpty) {
      throw StateError('Pixa runtime plugin module id must not be empty.');
    }
    if (abiVersion != pixaPluginAbiVersion) {
      throw StateError('Unsupported Pixa runtime plugin ABI version.');
    }
    if (!const <String>{
      'builtInHostModule',
      'hostLinkedPluginModule',
      'assetModule',
    }.contains(deployment)) {
      throw StateError('Unsupported Pixa runtime plugin deployment.');
    }
    if (capabilities.isEmpty ||
        !capabilities.any(
          const <String>{
            'fetcher',
            'decoder',
            'processor',
            'cacheStore',
          }.contains,
        )) {
      throw StateError('Pixa runtime plugin module exposes no capability.');
    }
    if (!hostManagedRuntime ||
        !binaryMessages ||
        !ownedBuffers ||
        !streamHandles) {
      throw StateError(
        'Pixa runtime plugin modules must use host runtime, binary messages, '
        'owned buffers and stream handles.',
      );
    }
    _validateRouteClaim('fetcher', fetcherSourceKinds, 'fetcherSourceKinds');
    _validateVideoFrameRoutes();
    _validateDecoderRouteClaims();
    _validateRouteClaim(
      'processor',
      processorOperations,
      'processorOperations',
    );
    _validateRouteClaim(
      'cacheStore',
      cacheStoreNamespaces,
      'cacheStoreNamespaces',
    );
    if (deployment == 'hostLinkedPluginModule' &&
        (entrypointSymbol == null || entrypointSymbol!.trim().isEmpty)) {
      throw StateError('Host-linked Pixa runtime plugin requires entrypoint.');
    }
    if (deployment == 'assetModule') {
      if (assetId == null || assetId!.trim().isEmpty) {
        throw StateError('Pixa asset module requires assetId.');
      }
      if (entrypointSymbol == null || entrypointSymbol!.trim().isEmpty) {
        throw StateError('Pixa asset module requires entrypoint.');
      }
      if (link.isNotEmpty) {
        throw StateError(
          'Pixa asset module link metadata belongs to its own asset.',
        );
      }
    }
    link.validate();
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'moduleId': moduleId,
      'deployment': deployment,
      'abiVersion': abiVersion,
      'capabilities': capabilities.toList()..sort(),
      if (packageName != null) 'packageName': packageName,
      if (implementationLanguage != null)
        'implementationLanguage': implementationLanguage,
      if (assetId != null) 'assetId': assetId,
      if (entrypointSymbol != null) 'entrypointSymbol': entrypointSymbol,
      'hostManagedRuntime': hostManagedRuntime,
      'binaryMessages': binaryMessages,
      'ownedBuffers': ownedBuffers,
      'streamHandles': streamHandles,
      'canLinkIntoHostBinary': canLinkIntoHostBinary,
      if (link.isNotEmpty) 'link': link.toJson(),
      if (fetcherSourceKinds.isNotEmpty)
        'fetcherSourceKinds': _sortedList(fetcherSourceKinds),
      if (videoFrameOutputMimeTypes.isNotEmpty)
        'videoFrameOutputMimeTypes': _sortedList(videoFrameOutputMimeTypes),
      if (_claimsVideoFrameRoute) 'videoFrameNearest': videoFrameNearest,
      if (_claimsVideoFrameRoute) 'videoFrameExact': videoFrameExact,
      if (decoderFormatIds.isNotEmpty)
        'decoderFormatIds': _sortedList(decoderFormatIds),
      if (decoderMimeTypes.isNotEmpty)
        'decoderMimeTypes': _sortedList(decoderMimeTypes),
      if (decoderSignatures.isNotEmpty)
        'decoderSignatures': decoderSignatures
            .map(
              (PixaRuntimeDecoderSignaturePlan signature) => signature.toJson(),
            )
            .toList(growable: false),
      if (capabilities.contains('decoder'))
        'decoderCapabilities': decoderCapabilities.toJson(),
      if (processorOperations.isNotEmpty)
        'processorOperations': _sortedList(processorOperations),
      if (cacheStoreNamespaces.isNotEmpty)
        'cacheStoreNamespaces': _sortedList(cacheStoreNamespaces),
    };
  }

  void _validateRouteClaim(
    String capability,
    Set<String> claims,
    String field,
  ) {
    if (claims.isNotEmpty && !capabilities.contains(capability)) {
      throw StateError(
        'Pixa runtime plugin "$field" requires $capability capability.',
      );
    }
    if (capabilities.contains(capability) && claims.isEmpty) {
      throw StateError(
        'Pixa runtime plugin "$field" must declare route claims.',
      );
    }
  }

  void _validateDecoderRouteClaims() {
    final bool hasDecoder = capabilities.contains('decoder');
    final bool hasRoutes =
        decoderMimeTypes.isNotEmpty ||
        decoderFormatIds.isNotEmpty ||
        decoderSignatures.isNotEmpty;
    if (!hasDecoder && hasRoutes) {
      throw StateError(
        'Pixa runtime plugin decoder routes require decoder capability.',
      );
    }
    if (hasDecoder && !hasRoutes) {
      throw StateError(
        'Pixa runtime plugin decoder route claims must declare MIME types, '
        'format ids or signatures.',
      );
    }
    _validateNonEmptyRouteValues(decoderMimeTypes, 'decoderMimeTypes');
    _validateNonEmptyRouteValues(decoderFormatIds, 'decoderFormatIds');
    if (hasDecoder) {
      decoderCapabilities.validate();
    }
  }

  bool get _claimsVideoFrameRoute {
    return fetcherSourceKinds.any(_isVideoFrameSourceKind);
  }

  void _validateVideoFrameRoutes() {
    final bool hasVideoFrameRoute = _claimsVideoFrameRoute;
    _validateNonEmptyRouteValues(
      videoFrameOutputMimeTypes,
      'videoFrameOutputMimeTypes',
    );
    if (!hasVideoFrameRoute) {
      if (videoFrameOutputMimeTypes.isNotEmpty) {
        throw StateError(
          'Pixa runtime plugin video-frame output MIME contract requires a '
          'video-frame fetcher source kind.',
        );
      }
      return;
    }
    if (videoFrameOutputMimeTypes.isEmpty) {
      throw StateError(
        'Pixa runtime plugin video-frame output MIME contract is required for '
        'video-frame fetcher routes.',
      );
    }
    if (!videoFrameNearest && !videoFrameExact) {
      throw StateError(
        'Pixa runtime plugin video-frame route must support nearest or exact '
        'frame selection.',
      );
    }
    for (final String mimeType in videoFrameOutputMimeTypes) {
      final String normalized = mimeType.split(';').first.trim().toLowerCase();
      if (!_supportedVideoFrameOutputMimeTypes.contains(normalized)) {
        throw StateError(
          'Pixa runtime plugin video-frame output MIME "$mimeType" is not in '
          'the supported display format matrix.',
        );
      }
    }
  }
}

final class PixaRuntimeDecoderCapabilitiesPlan {
  const PixaRuntimeDecoderCapabilitiesPlan({
    required this.metadataProbe,
    required this.staticDecode,
    required this.animatedDecode,
    required this.progressiveDecode,
    required this.regionDecode,
    required this.processorInput,
    required this.streamingInput,
    required this.defaultRuntimeDisplay,
    required this.zeroCopyInput,
    required this.ownedOutputBuffers,
    required this.stable,
  });

  const PixaRuntimeDecoderCapabilitiesPlan.runtimeRaster({
    this.animatedDecode = false,
    this.progressiveDecode = false,
    this.regionDecode = false,
    this.defaultRuntimeDisplay = false,
  }) : metadataProbe = true,
       staticDecode = true,
       processorInput = true,
       streamingInput = true,
       zeroCopyInput = true,
       ownedOutputBuffers = true,
       stable = true;

  factory PixaRuntimeDecoderCapabilitiesPlan.fromJson(
    Map<String, Object?>? json,
  ) {
    if (json == null) {
      return const PixaRuntimeDecoderCapabilitiesPlan.runtimeRaster();
    }
    return PixaRuntimeDecoderCapabilitiesPlan(
      metadataProbe: _optionalBool(json, 'metadataProbe') ?? true,
      staticDecode: _optionalBool(json, 'staticDecode') ?? true,
      animatedDecode: _optionalBool(json, 'animatedDecode') ?? false,
      progressiveDecode: _optionalBool(json, 'progressiveDecode') ?? false,
      regionDecode: _optionalBool(json, 'regionDecode') ?? false,
      processorInput: _optionalBool(json, 'processorInput') ?? true,
      streamingInput: _optionalBool(json, 'streamingInput') ?? true,
      defaultRuntimeDisplay:
          _optionalBool(json, 'defaultRuntimeDisplay') ?? false,
      zeroCopyInput: _optionalBool(json, 'zeroCopyInput') ?? true,
      ownedOutputBuffers: _optionalBool(json, 'ownedOutputBuffers') ?? true,
      stable: _optionalBool(json, 'stable') ?? true,
    );
  }

  final bool metadataProbe;
  final bool staticDecode;
  final bool animatedDecode;
  final bool progressiveDecode;
  final bool regionDecode;
  final bool processorInput;
  final bool streamingInput;
  final bool defaultRuntimeDisplay;
  final bool zeroCopyInput;
  final bool ownedOutputBuffers;
  final bool stable;

  bool get hotPathSafe {
    return stable && zeroCopyInput && ownedOutputBuffers;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'metadataProbe': metadataProbe,
      'staticDecode': staticDecode,
      'animatedDecode': animatedDecode,
      'progressiveDecode': progressiveDecode,
      'regionDecode': regionDecode,
      'processorInput': processorInput,
      'streamingInput': streamingInput,
      'defaultRuntimeDisplay': defaultRuntimeDisplay,
      'zeroCopyInput': zeroCopyInput,
      'ownedOutputBuffers': ownedOutputBuffers,
      'stable': stable,
    };
  }

  void validate() {
    if (!staticDecode && !animatedDecode && !metadataProbe) {
      throw StateError(
        'Pixa runtime decoder capabilities expose no decode or metadata path.',
      );
    }
    if (regionDecode && !metadataProbe) {
      throw StateError(
        'Pixa runtime decoder region decode requires metadata probe.',
      );
    }
    if (!hotPathSafe) {
      throw StateError(
        'Pixa runtime decoder capabilities must be stable and use zero-copy '
        'input with owned output buffers.',
      );
    }
  }
}

final class PixaRuntimeDecoderSignaturePlan {
  const PixaRuntimeDecoderSignaturePlan({
    required this.offset,
    required this.magicHex,
    required this.mimeType,
    this.formatId,
  });

  factory PixaRuntimeDecoderSignaturePlan.fromJson(Map<String, Object?> json) {
    final int? offset = _optionalInt(json, 'offset');
    if (offset == null || offset < 0) {
      throw StateError(
        'Pixa runtime plugin decoder signature offset must be non-negative.',
      );
    }
    final String magicHex = _normalizeSignatureHex(
      _requiredString(json, 'magicHex'),
    );
    final int magicBytes = magicHex.length ~/ 2;
    if (magicBytes > 64) {
      throw StateError(
        'Pixa runtime plugin decoder signature must be at most 64 bytes.',
      );
    }
    if (offset + magicBytes > 4096) {
      throw StateError(
        'Pixa runtime plugin decoder signature must fit in the first 4096 '
        'header bytes.',
      );
    }
    final String mimeType = _requiredString(
      json,
      'mimeType',
    ).split(';').first.trim().toLowerCase();
    if (mimeType.isEmpty) {
      throw StateError(
        'Pixa runtime plugin decoder signature MIME type must not be empty.',
      );
    }
    final String? rawFormatId = _optionalString(json, 'formatId');
    final String? formatId = rawFormatId?.trim().toLowerCase();
    if (formatId != null && formatId.isEmpty) {
      throw StateError(
        'Pixa runtime plugin decoder signature format id must not be empty.',
      );
    }
    return PixaRuntimeDecoderSignaturePlan(
      offset: offset,
      magicHex: magicHex,
      mimeType: mimeType,
      formatId: formatId,
    );
  }

  final int offset;
  final String magicHex;
  final String mimeType;
  final String? formatId;

  String get routeKey => '$offset:$magicHex';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'offset': offset,
      'magicHex': magicHex,
      'mimeType': mimeType,
      if (formatId != null) 'formatId': formatId,
    };
  }
}

void _validateNonEmptyRouteValues(Set<String> claims, String field) {
  for (final String claim in claims) {
    if (claim.trim().isEmpty) {
      throw StateError('Pixa runtime plugin "$field" contains an empty route.');
    }
  }
}

bool _isVideoFrameSourceKind(String sourceKind) {
  final String normalized = sourceKind.trim().toLowerCase();
  return normalized == 'video-frame' || normalized.startsWith('video-frame:');
}

const Set<String> _supportedVideoFrameOutputMimeTypes = <String>{
  'image/jpeg',
  'image/jpg',
  'image/pjpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-bmp',
  'image/x-ms-bmp',
  'image/vnd.wap.wbmp',
  'image/x-icon',
  'image/vnd.microsoft.icon',
  'image/tiff',
  'image/tiff-fx',
  'image/x-portable-anymap',
  'image/x-portable-arbitrarymap',
  'image/x-portable-bitmap',
  'image/x-portable-graymap',
  'image/x-portable-pixmap',
  'image/qoi',
  'image/x-qoi',
  'image/tga',
  'image/x-tga',
  'application/x-tga',
  'image/vnd.ms-dds',
  'image/vnd-ms.dds',
  'image/x-dds',
  'image/vnd.radiance',
  'image/x-hdr',
  'image/x-radiance',
  'image/hdr',
  'image/x-farbfeld',
  'image/x-pcx',
  'image/vnd.zbrush.pcx',
  'image/sgi',
  'image/x-sgi',
  'image/x-rgb',
  'image/x-xbitmap',
  'image/x-xbm',
  'image/x-xpixmap',
  'image/x-xpm',
};

List<PixaRuntimeDecoderSignaturePlan> _optionalDecoderSignatures(
  Map<String, Object?> json,
) {
  final Object? raw = json['decoderSignatures'];
  if (raw == null) {
    return const <PixaRuntimeDecoderSignaturePlan>[];
  }
  if (raw is! List<Object?>) {
    throw StateError('Pixa runtime plugin "decoderSignatures" must be a list.');
  }
  final List<PixaRuntimeDecoderSignaturePlan> signatures =
      <PixaRuntimeDecoderSignaturePlan>[];
  for (final Object? value in raw) {
    if (value is! Map<Object?, Object?>) {
      throw StateError(
        'Pixa runtime plugin decoder signature must be an object.',
      );
    }
    signatures.add(PixaRuntimeDecoderSignaturePlan.fromJson(_stringMap(value)));
  }
  signatures.sort(
    (
      PixaRuntimeDecoderSignaturePlan left,
      PixaRuntimeDecoderSignaturePlan right,
    ) => left.routeKey.compareTo(right.routeKey),
  );
  return List<PixaRuntimeDecoderSignaturePlan>.unmodifiable(signatures);
}

String _normalizeSignatureHex(String value) {
  final String normalized = value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (normalized.isEmpty || normalized.length.isOdd) {
    throw StateError(
      'Pixa runtime plugin decoder signature magicHex must contain full '
      'bytes.',
    );
  }
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(normalized)) {
    throw StateError(
      'Pixa runtime plugin decoder signature magicHex must be hexadecimal.',
    );
  }
  return normalized;
}
