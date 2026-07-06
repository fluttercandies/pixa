import 'dart:typed_data';

import 'runtime_binary.dart';

/// runtime plugin host registry counters.
final class PixaRuntimePluginRegistryStats {
  /// Creates a runtime plugin registry stats snapshot.
  const PixaRuntimePluginRegistryStats({
    required this.modules,
    required this.builtInModules,
    required this.hostLinkedModules,
    required this.assetModules,
    required this.linkableModules,
    required this.fetchers,
    required this.decoders,
    required this.processors,
    required this.cacheStores,
  });

  /// Empty registry stats.
  const PixaRuntimePluginRegistryStats.empty()
    : this(
        modules: 0,
        builtInModules: 0,
        hostLinkedModules: 0,
        assetModules: 0,
        linkableModules: 0,
        fetchers: 0,
        decoders: 0,
        processors: 0,
        cacheStores: 0,
      );

  /// Decodes the internal `PXM1` binary stats payload.
  factory PixaRuntimePluginRegistryStats.decode(Uint8List bytes) {
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(bytes);
    if (!reader.readMagic(0x50, 0x58, 0x4d, 0x31)) {
      throw const FormatException('Invalid runtime plugin stats payload.');
    }
    final PixaRuntimePluginRegistryStats stats = PixaRuntimePluginRegistryStats(
      modules: reader.readUint64(),
      builtInModules: reader.readUint64(),
      hostLinkedModules: reader.readUint64(),
      assetModules: reader.readUint64(),
      linkableModules: reader.readUint64(),
      fetchers: reader.readUint64(),
      decoders: reader.readUint64(),
      processors: reader.readUint64(),
      cacheStores: reader.readUint64(),
    );
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

  /// runtime decoder capabilities.
  final int decoders;

  /// runtime processor capabilities.
  final int processors;

  /// runtime cache-store capabilities.
  final int cacheStores;

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
      'decoders': decoders,
      'processors': processors,
      'cacheStores': cacheStores,
      'canUseSingleHostBinary': canUseSingleHostBinary,
    };
  }
}
