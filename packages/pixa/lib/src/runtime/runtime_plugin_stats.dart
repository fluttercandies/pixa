import 'dart:convert';
import 'dart:typed_data';

import 'runtime_binary.dart';

const List<int> _pxm2Magic = <int>[0x50, 0x58, 0x4d, 0x32];
const int _pxm2MaxPayloadBytes = 1024 * 1024;
const int _pxm2MaxModules = 1024;
const int _pxm2MaxStringBytes = 16 * 1024;
const int _pxm2MaxStringListItems = 1024;

/// Deployment shape for a module registered in the Rust runtime host.
enum PixaRuntimePluginDeployment {
  /// The module is compiled directly into Pixa's runtime host.
  builtInHostModule,

  /// The module is linked into Pixa's host binary at app build time.
  hostLinkedPluginModule,

  /// The module is loaded through an explicit runtime asset boundary.
  assetModule,

  /// The module delegates to a process or platform service.
  external,
}

/// Immutable runtime plugin module diagnostics.
final class PixaRuntimePluginModuleSnapshot {
  /// Creates a runtime plugin module snapshot.
  PixaRuntimePluginModuleSnapshot({
    required this.moduleId,
    required this.deployment,
    required this.entrypointSymbol,
    required List<String> processorOperations,
  }) : processorOperations = List<String>.unmodifiable(processorOperations);

  /// Stable module id inside the runtime host.
  final String moduleId;

  /// How the module is deployed relative to the runtime host.
  final PixaRuntimePluginDeployment deployment;

  /// Native initialization symbol, or null for modules without one.
  final String? entrypointSymbol;

  /// Processor route claims exposed by this module.
  final List<String> processorOperations;

  /// JSON-like representation for debug surfaces.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'moduleId': moduleId,
      'deployment': deployment.name,
      'entrypointSymbol': entrypointSymbol,
      'processorOperations': processorOperations,
    };
  }
}

/// runtime plugin host registry counters.
final class PixaRuntimePluginRegistryStats {
  /// Creates a runtime plugin registry stats snapshot.
  PixaRuntimePluginRegistryStats({
    required this.modules,
    required this.builtInModules,
    required this.hostLinkedModules,
    required this.assetModules,
    required this.linkableModules,
    required this.fetchers,
    required this.videoFrameFetchers,
    required this.videoFrameEncodedOutputFetchers,
    required List<String> videoFrameSourceKinds,
    required List<String> videoFrameOutputMimeTypes,
    required this.decoders,
    required this.processors,
    required this.cacheStores,
    List<PixaRuntimePluginModuleSnapshot> moduleSnapshots =
        const <PixaRuntimePluginModuleSnapshot>[],
  }) : videoFrameSourceKinds = List<String>.unmodifiable(videoFrameSourceKinds),
       videoFrameOutputMimeTypes = List<String>.unmodifiable(
         videoFrameOutputMimeTypes,
       ),
       moduleSnapshots = List<PixaRuntimePluginModuleSnapshot>.unmodifiable(
         moduleSnapshots,
       );

  /// Empty registry stats.
  const PixaRuntimePluginRegistryStats.empty()
    : modules = 0,
      builtInModules = 0,
      hostLinkedModules = 0,
      assetModules = 0,
      linkableModules = 0,
      fetchers = 0,
      videoFrameFetchers = 0,
      videoFrameEncodedOutputFetchers = 0,
      videoFrameSourceKinds = const <String>[],
      videoFrameOutputMimeTypes = const <String>[],
      decoders = 0,
      processors = 0,
      cacheStores = 0,
      moduleSnapshots = const <PixaRuntimePluginModuleSnapshot>[];

  /// Decodes the internal `PXM2` binary diagnostics payload.
  factory PixaRuntimePluginRegistryStats.decode(Uint8List bytes) {
    if (bytes.length > _pxm2MaxPayloadBytes) {
      throw const FormatException('PXM2 payload exceeds byte limit.');
    }
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(bytes);
    if (!reader.readMagic(
      _pxm2Magic[0],
      _pxm2Magic[1],
      _pxm2Magic[2],
      _pxm2Magic[3],
    )) {
      throw const FormatException('Invalid runtime plugin stats payload.');
    }
    final int modules = reader.readUint64();
    if (modules > _pxm2MaxModules) {
      throw const FormatException('PXM2 module count exceeds item limit.');
    }
    final PixaRuntimePluginRegistryStats stats = PixaRuntimePluginRegistryStats(
      modules: modules,
      builtInModules: reader.readUint64(),
      hostLinkedModules: reader.readUint64(),
      assetModules: reader.readUint64(),
      linkableModules: reader.readUint64(),
      fetchers: reader.readUint64(),
      videoFrameFetchers: reader.readUint64(),
      videoFrameEncodedOutputFetchers: reader.readUint64(),
      decoders: reader.readUint64(),
      processors: reader.readUint64(),
      cacheStores: reader.readUint64(),
      videoFrameSourceKinds: _readStringList(reader),
      videoFrameOutputMimeTypes: _readStringList(reader),
      moduleSnapshots: _readPluginModuleSnapshots(reader),
    );
    if (stats.moduleSnapshots.length != stats.modules) {
      throw const FormatException(
        'Runtime plugin module count does not match its snapshots.',
      );
    }
    if (!reader.isComplete) {
      throw const FormatException('Trailing runtime plugin stats bytes.');
    }
    return stats;
  }

  /// Unique runtime plugin modules registered in the host.
  final int modules;

  /// Built-in host modules.
  final int builtInModules;

  /// Host-linked modules folded into the final runtime binary.
  final int hostLinkedModules;

  /// Asset modules loaded through a separate boundary.
  final int assetModules;

  /// Modules that can share one final runtime host binary.
  final int linkableModules;

  /// runtime fetcher capabilities.
  final int fetchers;

  /// runtime video-frame fetcher capabilities.
  final int videoFrameFetchers;

  /// runtime video-frame fetchers that declare encoded image output.
  final int videoFrameEncodedOutputFetchers;

  /// Runtime video-frame source kinds registered in the host.
  final List<String> videoFrameSourceKinds;

  /// Encoded image MIME types that runtime video-frame backends may output.
  final List<String> videoFrameOutputMimeTypes;

  /// runtime decoder capabilities.
  final int decoders;

  /// runtime processor capabilities.
  final int processors;

  /// runtime cache-store capabilities.
  final int cacheStores;

  /// Runtime modules in stable module-id order.
  final List<PixaRuntimePluginModuleSnapshot> moduleSnapshots;

  /// Returns the runtime module with [moduleId], when registered.
  PixaRuntimePluginModuleSnapshot? moduleById(String moduleId) {
    for (final PixaRuntimePluginModuleSnapshot module in moduleSnapshots) {
      if (module.moduleId == moduleId) {
        return module;
      }
    }
    return null;
  }

  /// True when the registry does not require additional runtime binaries.
  bool get canUseSingleHostBinary {
    return assetModules == 0 && linkableModules == modules;
  }

  /// JSON-like representation for debug surfaces.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'modules': modules,
      'builtInModules': builtInModules,
      'hostLinkedModules': hostLinkedModules,
      'assetModules': assetModules,
      'linkableModules': linkableModules,
      'fetchers': fetchers,
      'videoFrameFetchers': videoFrameFetchers,
      'videoFrameEncodedOutputFetchers': videoFrameEncodedOutputFetchers,
      'videoFrameSourceKinds': videoFrameSourceKinds,
      'videoFrameOutputMimeTypes': videoFrameOutputMimeTypes,
      'decoders': decoders,
      'processors': processors,
      'cacheStores': cacheStores,
      'moduleSnapshots': <Map<String, Object?>>[
        for (final PixaRuntimePluginModuleSnapshot module in moduleSnapshots)
          module.toJson(),
      ],
      'canUseSingleHostBinary': canUseSingleHostBinary,
    };
  }
}

List<String> _readStringList(PixaRuntimeBinaryReader reader) {
  final int count = reader.readUint32();
  if (count > _pxm2MaxStringListItems) {
    throw const FormatException('PXM2 string list exceeds item limit.');
  }
  return List<String>.unmodifiable(<String>[
    for (int index = 0; index < count; index++)
      reader.readString(maxByteLength: _pxm2MaxStringBytes),
  ]);
}

List<PixaRuntimePluginModuleSnapshot> _readPluginModuleSnapshots(
  PixaRuntimeBinaryReader reader,
) {
  final int count = reader.readUint32();
  if (count > _pxm2MaxModules) {
    throw const FormatException('PXM2 module count exceeds item limit.');
  }
  final List<PixaRuntimePluginModuleSnapshot> snapshots =
      <PixaRuntimePluginModuleSnapshot>[];
  final List<String> moduleIds = <String>[];
  for (int index = 0; index < count; index++) {
    final String moduleId = reader.readString(
      maxByteLength: _pxm2MaxStringBytes,
    );
    if (moduleId.isEmpty) {
      throw const FormatException('Runtime plugin module id is empty.');
    }
    moduleIds.add(moduleId);
    final PixaRuntimePluginDeployment deployment = _readPluginDeployment(
      reader,
    );
    final String? entrypointSymbol = _readOptionalString(reader);
    final List<String> processorOperations = _readStringList(reader);
    _validateStrictUtf8Order(
      processorOperations,
      'Runtime plugin processor operations',
    );
    snapshots.add(
      PixaRuntimePluginModuleSnapshot(
        moduleId: moduleId,
        deployment: deployment,
        entrypointSymbol: entrypointSymbol,
        processorOperations: processorOperations,
      ),
    );
  }
  _validateStrictUtf8Order(moduleIds, 'Runtime plugin module snapshots');
  return List<PixaRuntimePluginModuleSnapshot>.unmodifiable(snapshots);
}

void _validateStrictUtf8Order(List<String> values, String label) {
  for (int index = 1; index < values.length; index++) {
    if (_compareUtf8Strings(values[index - 1], values[index]) >= 0) {
      throw FormatException('$label are not strictly sorted.');
    }
  }
}

int _compareUtf8Strings(String left, String right) {
  final List<int> leftBytes = utf8.encode(left);
  final List<int> rightBytes = utf8.encode(right);
  final int commonLength = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (int index = 0; index < commonLength; index++) {
    final int comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

PixaRuntimePluginDeployment _readPluginDeployment(
  PixaRuntimeBinaryReader reader,
) {
  return switch (reader.readUint8()) {
    0 => PixaRuntimePluginDeployment.builtInHostModule,
    1 => PixaRuntimePluginDeployment.hostLinkedPluginModule,
    2 => PixaRuntimePluginDeployment.assetModule,
    3 => PixaRuntimePluginDeployment.external,
    _ => throw const FormatException(
      'Invalid runtime plugin module deployment.',
    ),
  };
}

String? _readOptionalString(PixaRuntimeBinaryReader reader) {
  return switch (reader.readUint8()) {
    0 => null,
    1 => reader.readString(maxByteLength: _pxm2MaxStringBytes),
    _ => throw const FormatException(
      'Invalid runtime plugin optional string tag.',
    ),
  };
}
